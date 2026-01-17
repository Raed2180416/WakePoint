// ImuReplayEngine V2 - Advanced IMU/GPS Simulation for EKF Testing
//
// Features:
// - Precise route replay with Google Maps geometry
// - GPS dropout simulation (complete dropout, intermittent, accuracy degradation)
// - Realistic IMU generation based on motion profile (acceleration, braking, curves)
// - ZUPT detection simulation at stations
// - Speed profiles per route segment (metro vs walking vs driving)
// - Station dwell time simulation
// - Detailed logging for debugging ZUPT, snaps, and EKF state
// - Time warp with correct physics
// - Multi-leg route support (metro + non-metro)
//
// Usage with dashboard:
// ```dart
// final engine = ImuReplayEngineV2();
// await engine.loadTestRoute(TestRouteId.majesticToNallurHalli);
// engine.gpsDropoutMode = GpsDropoutMode.tunnelSimulation;
// engine.play();
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ENUMS & TYPES
// ─────────────────────────────────────────────────────────────────────────────

/// Available test routes.
enum TestRouteId {
  /// Majestic → Nallur Halli (18 metro stations, ~20km, ~38min)
  majesticToNallurHalli,

  /// Rajajinagar → Nallur Halli (23 metro stations, ~22km, ~57min)
  rajajinargarToNallurHalli,

  /// Nallur Halli → Vijayanagar (21 metro stations, ~23km, ~45min)
  nallurHalliToVijayanagar,

  /// Non-metro: Koramangala → Indiranagar (mixed walking + driving, ~5km)
  koramangalaToIndiranagar,

  /// Multi-modal: MG Road → Airport (metro + driving, ~35km)
  mgRoadToAirport,
}

/// GPS dropout simulation modes.
enum GpsDropoutMode {
  /// Normal GPS - continuous updates.
  normal,

  /// Complete dropout - no GPS updates at all.
  completeDropout,

  /// Tunnel simulation - GPS drops during metro underground sections.
  tunnelSimulation,

  /// Intermittent - random dropouts every 10-30 seconds.
  intermittent,

  /// Accuracy degradation - GPS stays on but accuracy drops to 50-200m.
  accuracyDegraded,

  /// Urban canyon - accuracy varies 15-100m randomly.
  urbanCanyon,
}

/// Motion state for IMU simulation.
enum SimulatedMotionState {
  stationary,
  accelerating,
  cruising,
  braking,
  stopped, // At station
}

/// Type of route leg.
enum LegType {
  metro,
  walking,
  driving,
  transit, // Bus/other transit
}

// ─────────────────────────────────────────────────────────────────────────────
// DATA CLASSES
// ─────────────────────────────────────────────────────────────────────────────

/// A station/stop along the route.
class TestRouteStation {
  final String id;
  final String name;
  final LatLng position;
  final double cumulativeMeters;
  final double dwellTimeSeconds;
  final double arrivalTimeSeconds;
  final bool isUnderground; // For tunnel GPS dropout simulation

  const TestRouteStation({
    required this.id,
    required this.name,
    required this.position,
    required this.cumulativeMeters,
    required this.dwellTimeSeconds,
    required this.arrivalTimeSeconds,
    this.isUnderground = true,
  });

  factory TestRouteStation.fromJson(Map<String, dynamic> json) {
    return TestRouteStation(
      id: json['id'] ?? json['name']?.toString().toLowerCase().replaceAll(' ', '_') ?? '',
      name: json['name'] ?? '',
      position: LatLng(
        (json['lat'] as num).toDouble(),
        (json['lng'] as num).toDouble(),
      ),
      cumulativeMeters: (json['cumulative_meters'] as num?)?.toDouble() ?? 0.0,
      dwellTimeSeconds: (json['dwell_time'] as num?)?.toDouble() ?? 25.0,
      arrivalTimeSeconds: (json['time_elapsed'] as num?)?.toDouble() ?? 0.0,
      isUnderground: json['is_underground'] as bool? ?? true,
    );
  }
}

/// A leg of the route (metro, walking, driving).
class TestRouteLeg {
  final String id;
  final LegType type;
  final String name; // e.g., "Purple Line" or "Walk to station"
  final List<LatLng> polyline;
  final List<double> cumulativeMeters;
  final List<TestRouteStation> stations;
  final double startTimeSeconds;
  final double endTimeSeconds;
  final double averageSpeedMps;
  final bool hasGpsInTunnel;

  const TestRouteLeg({
    required this.id,
    required this.type,
    required this.name,
    required this.polyline,
    required this.cumulativeMeters,
    required this.stations,
    required this.startTimeSeconds,
    required this.endTimeSeconds,
    required this.averageSpeedMps,
    this.hasGpsInTunnel = false,
  });

  double get durationSeconds => endTimeSeconds - startTimeSeconds;
  double get totalMeters => cumulativeMeters.isEmpty ? 0 : cumulativeMeters.last;
}

/// Complete test route with all legs.
class TestRoute {
  final TestRouteId id;
  final String name;
  final String description;
  final List<TestRouteLeg> legs;
  final List<LatLng> fullPolyline;
  final List<double> fullCumulativeMeters;
  final double totalMeters;
  final double totalDurationSeconds;

  const TestRoute({
    required this.id,
    required this.name,
    required this.description,
    required this.legs,
    required this.fullPolyline,
    required this.fullCumulativeMeters,
    required this.totalMeters,
    required this.totalDurationSeconds,
  });

  /// Get all stations across all legs.
  List<TestRouteStation> get allStations =>
      legs.expand((leg) => leg.stations).toList();

  /// Get leg containing a given elapsed time.
  TestRouteLeg? legAtTime(double elapsedSeconds) {
    for (final leg in legs) {
      if (elapsedSeconds >= leg.startTimeSeconds &&
          elapsedSeconds <= leg.endTimeSeconds) {
        return leg;
      }
    }
    return legs.isNotEmpty ? legs.last : null;
  }
}

/// Result of a replay tick with detailed state.
class ReplayTickResultV2 {
  final double elapsedSeconds;
  final double progress; // 0.0 to 1.0
  final double progressMeters;
  final LatLng position;
  final double bearing;
  final double speedMps;
  final SimulatedMotionState motionState;

  // GPS state
  final LatLng? gpsPosition;
  final double? gpsAccuracy;
  final bool gpsAvailable;
  final GpsDropoutMode dropoutMode;
  final Duration? timeSinceLastGps;

  // IMU data
  final double accelX, accelY, accelZ;
  final double gyroX, gyroY, gyroZ;

  // Route state
  final TestRouteLeg? currentLeg;
  final TestRouteStation? lastStation;
  final TestRouteStation? nextStation;
  final double? metersToNextStation;
  final double? secondsToNextStation;

  // ZUPT/EKF hints
  final bool isZuptCandidate; // Stationary long enough for ZUPT
  final double? zuptDurationSeconds;
  final bool isAtStation; // Currently stopped at a station

  const ReplayTickResultV2({
    required this.elapsedSeconds,
    required this.progress,
    required this.progressMeters,
    required this.position,
    required this.bearing,
    required this.speedMps,
    required this.motionState,
    required this.gpsPosition,
    required this.gpsAccuracy,
    required this.gpsAvailable,
    required this.dropoutMode,
    this.timeSinceLastGps,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
    this.currentLeg,
    this.lastStation,
    this.nextStation,
    this.metersToNextStation,
    this.secondsToNextStation,
    required this.isZuptCandidate,
    this.zuptDurationSeconds,
    required this.isAtStation,
  });
}

/// Log entry for debugging.
class ReplayLogEntry {
  final DateTime timestamp;
  final double elapsedSeconds;
  final String category; // GPS, IMU, ZUPT, SNAP, STATION, EKF
  final String level; // DEBUG, INFO, WARN, EVENT
  final String message;
  final Map<String, dynamic>? data;

  const ReplayLogEntry({
    required this.timestamp,
    required this.elapsedSeconds,
    required this.category,
    required this.level,
    required this.message,
    this.data,
  });

  @override
  String toString() {
    final dataStr = data != null ? ' ${jsonEncode(data)}' : '';
    return '[${elapsedSeconds.toStringAsFixed(1)}s] [$category] $level: $message$dataStr';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// IMU REPLAY ENGINE V2
// ─────────────────────────────────────────────────────────────────────────────

/// Advanced IMU replay engine for EKF testing.
class ImuReplayEngineV2 {
  // ─────────────────────────────────────────────────────────────────────────
  // Configuration
  // ─────────────────────────────────────────────────────────────────────────

  /// GPS dropout simulation mode.
  GpsDropoutMode gpsDropoutMode = GpsDropoutMode.normal;

  /// Time warp factor (1.0 = realtime, 2.0 = 2x speed).
  double warpFactor = 1.0;

  /// Whether to add realistic noise to IMU data.
  bool enableImuNoise = true;

  /// Whether to simulate station dwell times.
  bool enableDwellTimes = true;

  /// Logging verbosity (0=none, 1=events, 2=detailed, 3=all).
  int logVerbosity = 2;

  /// Callback for external EKF state injection.
  void Function(double progressMeters, double velocity)? onEkfStateRequest;

  // ─────────────────────────────────────────────────────────────────────────
  // State
  // ─────────────────────────────────────────────────────────────────────────

  TestRoute? _route;
  double _elapsedSeconds = 0.0;
  bool _isPlaying = false;
  Timer? _playbackTimer;
  DateTime? _lastTickTime;
  final math.Random _random = math.Random(42); // Seeded for reproducibility

  // GPS dropout state
  // ignore: unused_field - Reserved for GPS timing analysis
  DateTime? _lastGpsTime;
  double? _lastGpsElapsed;
  // ignore: unused_field - Reserved for tunnel visualization
  bool _inTunnel = false;
  double _nextIntermittentDropout = 0;
  double _intermittentDropoutEnd = 0;

  // Motion state
  SimulatedMotionState _motionState = SimulatedMotionState.stationary;
  double _currentSpeed = 0.0;
  double _stationaryDuration = 0.0;

  // Logging
  final List<ReplayLogEntry> _logs = [];
  static const int _maxLogs = 1000;

  // ─────────────────────────────────────────────────────────────────────────
  // Stream Controllers
  // ─────────────────────────────────────────────────────────────────────────

  final _accelController = StreamController<AccelerometerEvent>.broadcast();
  final _gyroController = StreamController<GyroscopeEvent>.broadcast();
  final _gpsController = StreamController<Position>.broadcast();
  final _tickController = StreamController<ReplayTickResultV2>.broadcast();
  final _logController = StreamController<ReplayLogEntry>.broadcast();

  // ─────────────────────────────────────────────────────────────────────────
  // Public Streams
  // ─────────────────────────────────────────────────────────────────────────

  Stream<AccelerometerEvent> get accelerometerStream => _accelController.stream;
  Stream<GyroscopeEvent> get gyroscopeStream => _gyroController.stream;
  Stream<Position> get gpsStream => _gpsController.stream;
  Stream<ReplayTickResultV2> get tickStream => _tickController.stream;
  Stream<ReplayLogEntry> get logStream => _logController.stream;

  // ─────────────────────────────────────────────────────────────────────────
  // Public Properties
  // ─────────────────────────────────────────────────────────────────────────

  TestRoute? get route => _route;
  bool get isPlaying => _isPlaying;
  double get elapsedSeconds => _elapsedSeconds;
  double get progress => _route == null
      ? 0.0
      : (_elapsedSeconds / _route!.totalDurationSeconds).clamp(0.0, 1.0);
  double get progressMeters => progress * (_route?.totalMeters ?? 0);
  List<ReplayLogEntry> get logs => List.unmodifiable(_logs);
  SimulatedMotionState get motionState => _motionState;
  double get currentSpeed => _currentSpeed;

  // ─────────────────────────────────────────────────────────────────────────
  // Route Loading
  // ─────────────────────────────────────────────────────────────────────────

  /// Load a predefined test route.
  Future<void> loadTestRoute(TestRouteId routeId) async {
    _log('LOAD', 'INFO', 'Loading route: ${routeId.name}');

    switch (routeId) {
      case TestRouteId.majesticToNallurHalli:
      case TestRouteId.rajajinargarToNallurHalli:
      case TestRouteId.nallurHalliToVijayanagar:
        await _loadMetroRoute(routeId);
        break;
      case TestRouteId.koramangalaToIndiranagar:
        await _loadNonMetroRoute(routeId);
        break;
      case TestRouteId.mgRoadToAirport:
        await _loadMultiModalRoute(routeId);
        break;
    }

    _reset();
    _log('LOAD', 'EVENT', 'Route loaded: ${_route?.name}', {
      'legs': _route?.legs.length,
      'stations': _route?.allStations.length,
      'totalMeters': _route?.totalMeters,
      'durationMinutes': (_route?.totalDurationSeconds ?? 0) / 60,
    });
  }

  Future<void> _loadMetroRoute(TestRouteId routeId) async {
    final jsonStr = await rootBundle.loadString(
      'assets/ekf_test_routes/bengaluru_metro_routes.json',
    );
    final data = json.decode(jsonStr) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>;

    final routeIdStr = {
      TestRouteId.majesticToNallurHalli: 'majestic_to_nallur_halli',
      TestRouteId.rajajinargarToNallurHalli: 'rajajinagar_to_nallur_halli',
      TestRouteId.nallurHalliToVijayanagar: 'nallur_halli_to_vijayanagar',
    }[routeId]!;

    final routeData = routes.firstWhere(
      (r) => r['id'] == routeIdStr,
      orElse: () => throw Exception('Route not found: $routeIdStr'),
    );

    // Parse stations
    final stations = (routeData['stations'] as List<dynamic>)
        .map((s) => TestRouteStation.fromJson(s as Map<String, dynamic>))
        .toList();

    // Parse polyline with proper interpolation
    final rawPolyline = (routeData['polyline_points'] as List<dynamic>)
        .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
        .toList();

    final cumMeters = (routeData['cumulative_meters'] as List<dynamic>)
        .map((m) => (m as num).toDouble())
        .toList();

    // Interpolate polyline for smoother simulation
    final (interpolated, interpolatedCum) = _interpolatePolyline(rawPolyline, cumMeters, 10.0);

    final duration = (routeData['duration_seconds'] as num).toDouble();
    final totalMeters = (routeData['total_meters'] as num).toDouble();

    // Create single metro leg
    final leg = TestRouteLeg(
      id: routeIdStr,
      type: LegType.metro,
      name: routeData['name'] as String,
      polyline: interpolated,
      cumulativeMeters: interpolatedCum,
      stations: stations,
      startTimeSeconds: 0,
      endTimeSeconds: duration,
      averageSpeedMps: totalMeters / duration,
      hasGpsInTunnel: false,
    );

    _route = TestRoute(
      id: routeId,
      name: routeData['name'] as String,
      description: 'Metro route from ${stations.first.name} to ${stations.last.name}',
      legs: [leg],
      fullPolyline: interpolated,
      fullCumulativeMeters: interpolatedCum,
      totalMeters: totalMeters,
      totalDurationSeconds: duration,
    );
  }

  Future<void> _loadNonMetroRoute(TestRouteId routeId) async {
    // Create synthetic non-metro route: Koramangala → Indiranagar
    // This simulates a mix of walking + auto-rickshaw ride

    const walkStart = LatLng(12.9347, 77.6266); // Koramangala 5th Block
    const autoPickup = LatLng(12.9410, 77.6280); // Auto stand
    const destination = LatLng(12.9784, 77.6408); // Indiranagar

    // Walking segment (10 minutes, ~800m)
    final walkPoints = _generateSmoothPath(walkStart, autoPickup, 20);
    final walkCum = _computeCumulativeMeters(walkPoints);

    final walkLeg = TestRouteLeg(
      id: 'walk_to_auto',
      type: LegType.walking,
      name: 'Walk to auto stand',
      polyline: walkPoints,
      cumulativeMeters: walkCum,
      stations: [],
      startTimeSeconds: 0,
      endTimeSeconds: 600,
      averageSpeedMps: 1.3, // ~5 km/h walking
      hasGpsInTunnel: true,
    );

    // Auto segment (20 minutes, ~4.5km)
    final autoPoints = _generateSmoothPath(autoPickup, destination, 50);
    final autoCum = _computeCumulativeMeters(autoPoints);

    final autoLeg = TestRouteLeg(
      id: 'auto_ride',
      type: LegType.driving,
      name: 'Auto rickshaw to Indiranagar',
      polyline: autoPoints,
      cumulativeMeters: autoCum,
      stations: [],
      startTimeSeconds: 600,
      endTimeSeconds: 1800,
      averageSpeedMps: 3.75, // ~13.5 km/h in traffic
      hasGpsInTunnel: true,
    );

    final fullPoly = [...walkPoints, ...autoPoints];
    final fullCum = [
      ...walkCum,
      ...autoCum.map((m) => m + walkCum.last),
    ];

    _route = TestRoute(
      id: routeId,
      name: 'Koramangala to Indiranagar',
      description: 'Non-metro route: Walking + Auto rickshaw',
      legs: [walkLeg, autoLeg],
      fullPolyline: fullPoly,
      fullCumulativeMeters: fullCum,
      totalMeters: fullCum.last,
      totalDurationSeconds: 1800,
    );
  }

  Future<void> _loadMultiModalRoute(TestRouteId routeId) async {
    // Multi-modal: MG Road → Airport
    // Walking to MG Road Metro → Metro to Baiyappanahalli → Cab to Airport

    // Segment 1: Walk to MG Road metro (5 min, 400m)
    const walkStart = LatLng(12.9750, 77.6100);
    const mgRoadMetro = LatLng(12.9756, 77.6066);

    final walkPoints = _generateSmoothPath(walkStart, mgRoadMetro, 10);
    final walkCum = _computeCumulativeMeters(walkPoints);

    final walkLeg = TestRouteLeg(
      id: 'walk_to_mg_road',
      type: LegType.walking,
      name: 'Walk to MG Road Metro',
      polyline: walkPoints,
      cumulativeMeters: walkCum,
      stations: [],
      startTimeSeconds: 0,
      endTimeSeconds: 300,
      averageSpeedMps: 1.3,
      hasGpsInTunnel: true,
    );

    // Segment 2: Metro MG Road → Baiyappanahalli (15 min, 8km)
    const baiyappanahalli = LatLng(12.9895, 77.6674);
    final metroPoints = _generateSmoothPath(mgRoadMetro, baiyappanahalli, 40);
    final metroCum = _computeCumulativeMeters(metroPoints);

    final metroStations = [
      TestRouteStation(
        id: 'mg_road',
        name: 'MG Road',
        position: mgRoadMetro,
        cumulativeMeters: 0,
        dwellTimeSeconds: 30,
        arrivalTimeSeconds: 300,
      ),
      TestRouteStation(
        id: 'trinity',
        name: 'Trinity',
        position: const LatLng(12.9766, 77.6183),
        cumulativeMeters: 1500,
        dwellTimeSeconds: 25,
        arrivalTimeSeconds: 450,
      ),
      TestRouteStation(
        id: 'halasuru',
        name: 'Halasuru',
        position: const LatLng(12.9821, 77.6211),
        cumulativeMeters: 2500,
        dwellTimeSeconds: 25,
        arrivalTimeSeconds: 550,
      ),
      TestRouteStation(
        id: 'indiranagar',
        name: 'Indiranagar',
        position: const LatLng(12.9778, 77.6408),
        cumulativeMeters: 4500,
        dwellTimeSeconds: 25,
        arrivalTimeSeconds: 750,
      ),
      TestRouteStation(
        id: 'sv_road',
        name: 'Swami Vivekananda Road',
        position: const LatLng(12.9758, 77.6585),
        cumulativeMeters: 6500,
        dwellTimeSeconds: 25,
        arrivalTimeSeconds: 950,
      ),
      TestRouteStation(
        id: 'baiyappanahalli',
        name: 'Baiyappanahalli',
        position: baiyappanahalli,
        cumulativeMeters: 8000,
        dwellTimeSeconds: 0,
        arrivalTimeSeconds: 1200,
      ),
    ];

    final metroLeg = TestRouteLeg(
      id: 'metro_mg_to_bai',
      type: LegType.metro,
      name: 'Purple Line: MG Road → Baiyappanahalli',
      polyline: metroPoints,
      cumulativeMeters: metroCum,
      stations: metroStations,
      startTimeSeconds: 300,
      endTimeSeconds: 1200,
      averageSpeedMps: 8.9, // ~32 km/h average metro speed
      hasGpsInTunnel: false,
    );

    // Segment 3: Cab to Airport (45 min, 27km)
    const airport = LatLng(13.1989, 77.7068);
    final cabPoints = _generateSmoothPath(baiyappanahalli, airport, 80);
    final cabCum = _computeCumulativeMeters(cabPoints);

    final cabLeg = TestRouteLeg(
      id: 'cab_to_airport',
      type: LegType.driving,
      name: 'Cab to Kempegowda Airport',
      polyline: cabPoints,
      cumulativeMeters: cabCum,
      stations: [],
      startTimeSeconds: 1200,
      endTimeSeconds: 3900,
      averageSpeedMps: 10.0, // ~36 km/h in traffic
      hasGpsInTunnel: true,
    );

    final fullPoly = [...walkPoints, ...metroPoints, ...cabPoints];
    final fullCum = [
      ...walkCum,
      ...metroCum.map((m) => m + walkCum.last),
      ...cabCum.map((m) => m + walkCum.last + metroCum.last),
    ];

    _route = TestRoute(
      id: routeId,
      name: 'MG Road to Airport',
      description: 'Multi-modal: Walk + Metro + Cab',
      legs: [walkLeg, metroLeg, cabLeg],
      fullPolyline: fullPoly,
      fullCumulativeMeters: fullCum,
      totalMeters: fullCum.last,
      totalDurationSeconds: 3900,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Playback Controls
  // ─────────────────────────────────────────────────────────────────────────

  void play() {
    if (_route == null || _isPlaying) return;

    _isPlaying = true;
    _lastTickTime = DateTime.now();
    _playbackTimer?.cancel();
    _playbackTimer = Timer.periodic(
      const Duration(milliseconds: 10), // 100 Hz
      (_) => _tick(),
    );

    _log('CTRL', 'EVENT', 'Playback started', {
      'warpFactor': warpFactor,
      'gpsDropoutMode': gpsDropoutMode.name,
    });
  }

  void pause() {
    _isPlaying = false;
    _playbackTimer?.cancel();
    _log('CTRL', 'EVENT', 'Playback paused', {'elapsed': _elapsedSeconds});
  }

  void stop() {
    pause();
    _reset();
    _log('CTRL', 'EVENT', 'Playback stopped');
  }

  void seekTo(double seconds) {
    _elapsedSeconds = seconds.clamp(0.0, _route?.totalDurationSeconds ?? 0.0);
    _updateStateForSeek();
    _log('CTRL', 'INFO', 'Seeked to ${_elapsedSeconds.toStringAsFixed(1)}s');
  }

  void seekToProgress(double progress) {
    seekTo(progress * (_route?.totalDurationSeconds ?? 0.0));
  }

  void _reset() {
    _elapsedSeconds = 0.0;
    _lastGpsTime = null;
    _lastGpsElapsed = null;
    _inTunnel = false;
    _motionState = SimulatedMotionState.stationary;
    _currentSpeed = 0.0;
    _stationaryDuration = 0.0;
    _nextIntermittentDropout = 10 + _random.nextDouble() * 20;
    _intermittentDropoutEnd = 0;
  }

  void dispose() {
    _playbackTimer?.cancel();
    _accelController.close();
    _gyroController.close();
    _gpsController.close();
    _tickController.close();
    _logController.close();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Tick Processing
  // ─────────────────────────────────────────────────────────────────────────

  void _tick() {
    final route = _route;
    if (route == null) return;

    // Calculate warped delta
    final now = DateTime.now();
    final realDelta = _lastTickTime == null
        ? 0.01
        : (now.difference(_lastTickTime!).inMicroseconds / 1000000.0);
    _lastTickTime = now;

    final warpedDelta = realDelta * warpFactor;
    _elapsedSeconds += warpedDelta;

    // Check for end
    if (_elapsedSeconds >= route.totalDurationSeconds) {
      _elapsedSeconds = route.totalDurationSeconds;
      pause();
      _log('CTRL', 'EVENT', 'Playback completed');
      return;
    }

    // Calculate current state
    final position = _positionAtTime(_elapsedSeconds);
    final bearing = _bearingAtTime(_elapsedSeconds);
    final leg = route.legAtTime(_elapsedSeconds);
    final (lastStation, nextStation) = _stationsAtTime(_elapsedSeconds);

    // Update motion state
    _updateMotionState(warpedDelta, leg, lastStation, nextStation);

    // Generate IMU data
    final (accelX, accelY, accelZ) = _generateAccelerometer(warpedDelta);
    final (gyroX, gyroY, gyroZ) = _generateGyroscope(warpedDelta, bearing);

    // Emit IMU
    _accelController.add(AccelerometerEvent(accelX, accelY, accelZ, now));
    _gyroController.add(GyroscopeEvent(gyroX, gyroY, gyroZ, now));

    // GPS handling
    final gpsResult = _computeGpsState(position, leg);
    if (gpsResult.shouldEmit) {
      _gpsController.add(_createPosition(
        position,
        bearing,
        _currentSpeed,
        gpsResult.accuracy,
      ));
      _lastGpsTime = now;
      _lastGpsElapsed = _elapsedSeconds;
    }

    // ZUPT detection
    final isZupt = _stationaryDuration > 0.5; // 500ms stationary = ZUPT candidate
    final isAtStation = _motionState == SimulatedMotionState.stopped;

    if (isZupt && logVerbosity >= 2) {
      _log('ZUPT', 'DEBUG', 'ZUPT candidate', {
        'duration': _stationaryDuration,
        'speed': _currentSpeed,
        'atStation': isAtStation,
      });
    }

    // Calculate distances
    double? metersToNext;
    double? secondsToNext;
    if (nextStation != null) {
      metersToNext = nextStation.cumulativeMeters - progressMeters;
      final avgSpeed = leg?.averageSpeedMps ?? 10.0;
      secondsToNext = metersToNext / avgSpeed;
    }

    // Emit tick result
    final result = ReplayTickResultV2(
      elapsedSeconds: _elapsedSeconds,
      progress: progress,
      progressMeters: progressMeters,
      position: position,
      bearing: bearing,
      speedMps: _currentSpeed,
      motionState: _motionState,
      gpsPosition: gpsResult.position,
      gpsAccuracy: gpsResult.accuracy,
      gpsAvailable: gpsResult.shouldEmit,
      dropoutMode: gpsDropoutMode,
      timeSinceLastGps: _lastGpsElapsed != null
          ? Duration(milliseconds: ((_elapsedSeconds - _lastGpsElapsed!) * 1000).round())
          : null,
      accelX: accelX,
      accelY: accelY,
      accelZ: accelZ,
      gyroX: gyroX,
      gyroY: gyroY,
      gyroZ: gyroZ,
      currentLeg: leg,
      lastStation: lastStation,
      nextStation: nextStation,
      metersToNextStation: metersToNext,
      secondsToNextStation: secondsToNext,
      isZuptCandidate: isZupt,
      zuptDurationSeconds: isZupt ? _stationaryDuration : null,
      isAtStation: isAtStation,
    );

    _tickController.add(result);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Position/Motion Calculation
  // ─────────────────────────────────────────────────────────────────────────

  LatLng _positionAtTime(double elapsed) {
    final route = _route;
    if (route == null || route.fullPolyline.isEmpty) {
      return const LatLng(0, 0);
    }

    final progress = (elapsed / route.totalDurationSeconds).clamp(0.0, 1.0);
    final targetMeters = progress * route.totalMeters;

    // Find segment in polyline
    int idx = 0;
    for (int i = 0; i < route.fullCumulativeMeters.length - 1; i++) {
      if (targetMeters >= route.fullCumulativeMeters[i] &&
          targetMeters <= route.fullCumulativeMeters[i + 1]) {
        idx = i;
        break;
      }
    }
    if (idx >= route.fullPolyline.length - 1) idx = route.fullPolyline.length - 2;

    final segStart = route.fullCumulativeMeters[idx];
    final segEnd = route.fullCumulativeMeters[idx + 1];
    final segLen = segEnd - segStart;
    final t = segLen > 0 ? (targetMeters - segStart) / segLen : 0.0;

    final p1 = route.fullPolyline[idx];
    final p2 = route.fullPolyline[idx + 1];

    return LatLng(
      p1.latitude + t * (p2.latitude - p1.latitude),
      p1.longitude + t * (p2.longitude - p1.longitude),
    );
  }

  double _bearingAtTime(double elapsed) {
    final route = _route;
    if (route == null || route.fullPolyline.length < 2) return 0.0;

    final progress = (elapsed / route.totalDurationSeconds).clamp(0.0, 1.0);
    final targetMeters = progress * route.totalMeters;

    int idx = 0;
    for (int i = 0; i < route.fullCumulativeMeters.length - 1; i++) {
      if (targetMeters <= route.fullCumulativeMeters[i + 1]) {
        idx = i;
        break;
      }
    }
    if (idx >= route.fullPolyline.length - 1) idx = route.fullPolyline.length - 2;

    final p1 = route.fullPolyline[idx];
    final p2 = route.fullPolyline[idx + 1];

    return _calculateBearing(p1, p2);
  }

  (TestRouteStation?, TestRouteStation?) _stationsAtTime(double elapsed) {
    final route = _route;
    if (route == null) return (null, null);

    TestRouteStation? last;
    TestRouteStation? next;

    for (final station in route.allStations) {
      if (station.arrivalTimeSeconds <= elapsed) {
        last = station;
      } else if (next == null) {
        next = station;
      }
    }

    return (last, next);
  }

  void _updateMotionState(double delta, TestRouteLeg? leg, TestRouteStation? last, TestRouteStation? next) {
    final route = _route;
    if (route == null || leg == null) return;

    // Check if at station
    bool atStation = false;
    if (last != null && enableDwellTimes) {
      final timeSinceArrival = _elapsedSeconds - last.arrivalTimeSeconds;
      if (timeSinceArrival >= 0 && timeSinceArrival < last.dwellTimeSeconds) {
        atStation = true;
      }
    }

    // Target speed based on context
    double targetSpeed;
    if (atStation) {
      targetSpeed = 0.0;
      _motionState = SimulatedMotionState.stopped;
    } else if (next != null) {
      // Approach braking zone (start braking 200m before station)
      final metersToNext = next.cumulativeMeters - progressMeters;
      if (metersToNext < 200 && metersToNext > 0) {
        targetSpeed = leg.averageSpeedMps * (metersToNext / 200);
        _motionState = SimulatedMotionState.braking;
      } else {
        targetSpeed = leg.averageSpeedMps;
        _motionState = _currentSpeed < targetSpeed * 0.9
            ? SimulatedMotionState.accelerating
            : SimulatedMotionState.cruising;
      }
    } else {
      targetSpeed = leg.averageSpeedMps;
      _motionState = SimulatedMotionState.cruising;
    }

    // Smooth speed transition
    const accelRate = 1.2; // m/s²
    const brakeRate = 2.0; // m/s²

    if (_currentSpeed < targetSpeed) {
      _currentSpeed = math.min(_currentSpeed + accelRate * delta, targetSpeed);
    } else if (_currentSpeed > targetSpeed) {
      _currentSpeed = math.max(_currentSpeed - brakeRate * delta, targetSpeed);
    }

    // Track stationary duration for ZUPT
    if (_currentSpeed < 0.1) {
      _stationaryDuration += delta;
    } else {
      _stationaryDuration = 0.0;
    }
  }

  void _updateStateForSeek() {
    final leg = _route?.legAtTime(_elapsedSeconds);
    _currentSpeed = leg?.averageSpeedMps ?? 0.0;
    _stationaryDuration = 0.0;
    _motionState = SimulatedMotionState.cruising;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // GPS Simulation
  // ─────────────────────────────────────────────────────────────────────────

  ({LatLng? position, double accuracy, bool shouldEmit}) _computeGpsState(LatLng truePosition, TestRouteLeg? leg) {
    final isMetro = leg?.type == LegType.metro;

    switch (gpsDropoutMode) {
      case GpsDropoutMode.normal:
        return (position: truePosition, accuracy: 10.0, shouldEmit: true);

      case GpsDropoutMode.completeDropout:
        if (_lastGpsElapsed == null) {
          // Emit one initial position
          return (position: truePosition, accuracy: 10.0, shouldEmit: true);
        }
        return (position: null, accuracy: 0.0, shouldEmit: false);

      case GpsDropoutMode.tunnelSimulation:
        if (isMetro) {
          // Only emit GPS at stations
          final (_, next) = _stationsAtTime(_elapsedSeconds);
          if (next != null) {
            final metersToNext = next.cumulativeMeters - progressMeters;
            if (metersToNext < 50 || metersToNext > (next.cumulativeMeters - 50)) {
              // Near station - GPS available briefly
              return (position: truePosition, accuracy: 25.0, shouldEmit: true);
            }
          }
          return (position: null, accuracy: 0.0, shouldEmit: false);
        }
        return (position: truePosition, accuracy: 12.0, shouldEmit: true);

      case GpsDropoutMode.intermittent:
        if (_elapsedSeconds > _nextIntermittentDropout &&
            _elapsedSeconds < _intermittentDropoutEnd) {
          return (position: null, accuracy: 0.0, shouldEmit: false);
        }
        if (_elapsedSeconds >= _intermittentDropoutEnd && _intermittentDropoutEnd > 0) {
          // Schedule next dropout
          _nextIntermittentDropout = _elapsedSeconds + 10 + _random.nextDouble() * 20;
          _intermittentDropoutEnd = _nextIntermittentDropout + 5 + _random.nextDouble() * 10;
        }
        return (position: truePosition, accuracy: 12.0, shouldEmit: true);

      case GpsDropoutMode.accuracyDegraded:
        final degradedAccuracy = 50 + _random.nextDouble() * 150;
        final offset = LatLng(
          truePosition.latitude + (_random.nextDouble() - 0.5) * 0.001,
          truePosition.longitude + (_random.nextDouble() - 0.5) * 0.001,
        );
        return (position: offset, accuracy: degradedAccuracy, shouldEmit: true);

      case GpsDropoutMode.urbanCanyon:
        final accuracy = 15 + _random.nextDouble() * 85;
        final jitter = accuracy / 111000; // Convert meters to degrees
        final offset = LatLng(
          truePosition.latitude + (_random.nextDouble() - 0.5) * jitter,
          truePosition.longitude + (_random.nextDouble() - 0.5) * jitter,
        );
        return (position: offset, accuracy: accuracy, shouldEmit: true);
    }
  }

  Position _createPosition(LatLng pos, double bearing, double speed, double accuracy) {
    return Position(
      latitude: pos.latitude,
      longitude: pos.longitude,
      altitude: 900, // Bengaluru elevation
      speed: speed,
      heading: bearing,
      accuracy: accuracy,
      altitudeAccuracy: 3.0,
      headingAccuracy: 10.0,
      speedAccuracy: 0.5,
      timestamp: DateTime.now(),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // IMU Simulation
  // ─────────────────────────────────────────────────────────────────────────

  (double x, double y, double z) _generateAccelerometer(double delta) {
    const gravity = 9.81;

    // Base gravity reading (device roughly level, screen up)
    double x = 0.0;
    double y = 0.0;
    double z = gravity;

    // Add motion-based acceleration
    switch (_motionState) {
      case SimulatedMotionState.accelerating:
        y += 0.5 + _random.nextDouble() * 0.3; // Forward acceleration
        break;
      case SimulatedMotionState.braking:
        y -= 0.8 + _random.nextDouble() * 0.4; // Braking deceleration
        break;
      case SimulatedMotionState.cruising:
        // Small vibrations from vehicle
        x += (_random.nextDouble() - 0.5) * 0.2;
        y += (_random.nextDouble() - 0.5) * 0.15;
        break;
      case SimulatedMotionState.stationary:
      case SimulatedMotionState.stopped:
        // Minimal noise
        x += (_random.nextDouble() - 0.5) * 0.02;
        y += (_random.nextDouble() - 0.5) * 0.02;
        z += (_random.nextDouble() - 0.5) * 0.02;
        break;
    }

    // Add noise if enabled
    if (enableImuNoise) {
      x += (_random.nextDouble() - 0.5) * 0.1;
      y += (_random.nextDouble() - 0.5) * 0.1;
      z += (_random.nextDouble() - 0.5) * 0.05;
    }

    return (x, y, z);
  }

  (double x, double y, double z) _generateGyroscope(double delta, double bearing) {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;

    // Add small rotations during curves
    // TODO: Calculate actual angular velocity from bearing changes

    // Add noise if enabled
    if (enableImuNoise) {
      x += (_random.nextDouble() - 0.5) * 0.02;
      y += (_random.nextDouble() - 0.5) * 0.02;
      z += (_random.nextDouble() - 0.5) * 0.01;
    }

    return (x, y, z);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  (List<LatLng>, List<double>) _interpolatePolyline(
    List<LatLng> original,
    List<double> cumMeters,
    double maxSegmentLength,
  ) {
    if (original.length < 2) return (original, cumMeters);

    final result = <LatLng>[original.first];
    final resultCum = <double>[cumMeters.first];

    for (int i = 0; i < original.length - 1; i++) {
      final p1 = original[i];
      final p2 = original[i + 1];
      final dist = cumMeters[i + 1] - cumMeters[i];

      if (dist > maxSegmentLength) {
        final segments = (dist / maxSegmentLength).ceil();
        for (int j = 1; j <= segments; j++) {
          final t = j / segments;
          result.add(LatLng(
            p1.latitude + t * (p2.latitude - p1.latitude),
            p1.longitude + t * (p2.longitude - p1.longitude),
          ));
          resultCum.add(cumMeters[i] + t * dist);
        }
      } else {
        result.add(p2);
        resultCum.add(cumMeters[i + 1]);
      }
    }

    return (result, resultCum);
  }

  List<LatLng> _generateSmoothPath(LatLng start, LatLng end, int numPoints) {
    final result = <LatLng>[];
    for (int i = 0; i <= numPoints; i++) {
      final t = i / numPoints;
      result.add(LatLng(
        start.latitude + t * (end.latitude - start.latitude),
        start.longitude + t * (end.longitude - start.longitude),
      ));
    }
    return result;
  }

  List<double> _computeCumulativeMeters(List<LatLng> points) {
    final result = <double>[0.0];
    for (int i = 1; i < points.length; i++) {
      final dist = _haversineDistance(points[i - 1], points[i]);
      result.add(result.last + dist);
    }
    return result;
  }

  double _haversineDistance(LatLng p1, LatLng p2) {
    const R = 6371000.0;
    final dLat = _degToRad(p2.latitude - p1.latitude);
    final dLon = _degToRad(p2.longitude - p1.longitude);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(p1.latitude)) *
            math.cos(_degToRad(p2.latitude)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c;
  }

  double _calculateBearing(LatLng p1, LatLng p2) {
    final dLon = _degToRad(p2.longitude - p1.longitude);
    final lat1 = _degToRad(p1.latitude);
    final lat2 = _degToRad(p2.latitude);

    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    return (_radToDeg(math.atan2(y, x)) + 360) % 360;
  }

  double _degToRad(double deg) => deg * (math.pi / 180);
  double _radToDeg(double rad) => rad * (180 / math.pi);

  // ─────────────────────────────────────────────────────────────────────────
  // Logging
  // ─────────────────────────────────────────────────────────────────────────

  void _log(String category, String level, String message, [Map<String, dynamic>? data]) {
    if (logVerbosity == 0) return;
    if (logVerbosity == 1 && level != 'EVENT') return;
    if (logVerbosity == 2 && level == 'DEBUG') return;

    final entry = ReplayLogEntry(
      timestamp: DateTime.now(),
      elapsedSeconds: _elapsedSeconds,
      category: category,
      level: level,
      message: message,
      data: data,
    );

    _logs.add(entry);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    _logController.add(entry);
  }

  void clearLogs() => _logs.clear();
}
