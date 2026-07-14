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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

import '../../all_india_stops.dart';
import 'ekf_types.dart';

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

  /// Captured Real Route (JSON Geometry + Log Motion)
  capturedRealRoute,
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
      id:
          json['id'] ??
          json['name']?.toString().toLowerCase().replaceAll(' ', '_') ??
          '',
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
  double get totalMeters =>
      cumulativeMeters.isEmpty ? 0 : cumulativeMeters.last;
}

/// Complete test route with all legs.
class TestRoute {
  final TestRouteId id;
  final String name;
  final String description;
  final List<TestRouteLeg> legs;
  final List<LatLng> fullPolyline;
  final List<LatLng> groundTruthPolyline; // Full GPS log path for visualization
  final List<double> fullCumulativeMeters;
  final double totalMeters;
  final double totalDurationSeconds;

  const TestRoute({
    required this.id,
    required this.name,
    required this.description,
    required this.legs,
    required this.fullPolyline,
    this.groundTruthPolyline = const [],
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
// LOG PARSING
// ─────────────────────────────────────────────────────────────────────────────

class LogLocation {
  final int timeNs;
  final double secondsElapsed;
  final double bearingAccuracy;
  final double speedAccuracy;
  final double speed;
  final double bearing;
  final double altitude;
  final double longitude;
  final double latitude;

  const LogLocation({
    required this.timeNs,
    required this.secondsElapsed,
    required this.bearingAccuracy,
    required this.speedAccuracy,
    required this.speed,
    required this.bearing,
    required this.altitude,
    required this.longitude,
    required this.latitude,
  });
}

class LogImu {
  final int timeNs;
  final double secondsElapsed;
  final double x;
  final double y;
  final double z;

  const LogImu({
    required this.timeNs,
    required this.secondsElapsed,
    required this.x,
    required this.y,
    required this.z,
  });
}

/// Gravity sensor log entry (Android TYPE_GRAVITY).
/// Format: time,seconds_elapsed,z,y,x
class LogGravity {
  final int timeNs;
  final double secondsElapsed;
  final double x;
  final double y;
  final double z;

  const LogGravity({
    required this.timeNs,
    required this.secondsElapsed,
    required this.x,
    required this.y,
    required this.z,
  });
}

/// Orientation sensor log entry (Android TYPE_ORIENTATION).
/// Format: time,seconds_elapsed,qz,qy,qx,qw,roll,pitch,yaw
class LogOrientation {
  final int timeNs;
  final double secondsElapsed;
  final double qx;
  final double qy;
  final double qz;
  final double qw;
  final double roll;
  final double pitch;
  final double yaw;

  const LogOrientation({
    required this.timeNs,
    required this.secondsElapsed,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.qw,
    required this.roll,
    required this.pitch,
    required this.yaw,
  });
}

class LogParser {
  static Future<List<LogLocation>> parseLocationLog(String path) async {
    // Use rootBundle to load assets, as File() generally doesn't work for bundled assets
    final content = await rootBundle.loadString(path);
    final lines = const LineSplitter().convert(content);
    final result = <LogLocation>[];

    // Skip header
    for (var i = 1; i < lines.length; i++) {
      final parts = lines[i].split(',');
      if (parts.length < 9) continue;

      try {
        result.add(
          LogLocation(
            timeNs: int.parse(parts[0]),
            secondsElapsed: double.parse(parts[1]),
            bearingAccuracy: double.parse(parts[2]),
            speedAccuracy: double.parse(parts[3]),
            // parts[4] is verticalAccuracy
            // parts[5] is horizontalAccuracy
            speed: double.parse(parts[6]),
            bearing: double.parse(parts[7]),
            altitude: double.parse(parts[8]),
            longitude: double.parse(parts[9]),
            latitude: double.parse(parts[10]),
          ),
        );
      } catch (e) {
        debugPrint('Error parsing location line $i: $e');
      }
    }
    return result;
  }

  static Future<List<LogImu>> parseImuLog(String path) async {
    final content = await rootBundle.loadString(path);
    final lines = const LineSplitter().convert(content);
    final result = <LogImu>[];

    // Skip header
    for (var i = 1; i < lines.length; i++) {
      final parts = lines[i].split(',');
      if (parts.length < 5) continue;

      try {
        result.add(
          LogImu(
            timeNs: int.parse(parts[0]),
            secondsElapsed: double.parse(parts[1]),

            // Let's assume standard sensors_plus order but mapping based on header analysis from user logs
            // User log header: time,seconds_elapsed,z,y,x
            // But standard is x,y,z.
            // Implementation Note: Code uses x, y, z. We will map strictly by position.
            // IF the file is z,y,x:
            // parts[2] = z
            // parts[3] = y
            // parts[4] = x
            x: double.parse(parts[4]),
            y: double.parse(parts[3]),
            z: double.parse(parts[2]),
          ),
        );
      } catch (e) {
        debugPrint('Error parsing IMU line $i: $e');
      }
    }
    return result;
  }

  /// Parse Gravity.csv log file.
  /// Format: time,seconds_elapsed,z,y,x
  static Future<List<LogGravity>> parseGravityLog(String path) async {
    final content = await rootBundle.loadString(path);
    final lines = const LineSplitter().convert(content);
    final result = <LogGravity>[];

    // Skip header
    for (var i = 1; i < lines.length; i++) {
      final parts = lines[i].split(',');
      if (parts.length < 5) continue;

      try {
        result.add(
          LogGravity(
            timeNs: int.parse(parts[0]),
            secondsElapsed: double.parse(parts[1]),
            // File format: z,y,x (same as IMU)
            x: double.parse(parts[4]),
            y: double.parse(parts[3]),
            z: double.parse(parts[2]),
          ),
        );
      } catch (e) {
        debugPrint('Error parsing gravity line $i: $e');
      }
    }
    return result;
  }

  /// Parse Orientation.csv log file.
  /// Format: time,seconds_elapsed,qz,qy,qx,qw,roll,pitch,yaw
  static Future<List<LogOrientation>> parseOrientationLog(String path) async {
    final content = await rootBundle.loadString(path);
    final lines = const LineSplitter().convert(content);
    final result = <LogOrientation>[];

    // Skip header
    for (var i = 1; i < lines.length; i++) {
      final parts = lines[i].split(',');
      if (parts.length < 9) continue;

      try {
        result.add(
          LogOrientation(
            timeNs: int.parse(parts[0]),
            secondsElapsed: double.parse(parts[1]),
            qz: double.parse(parts[2]),
            qy: double.parse(parts[3]),
            qx: double.parse(parts[4]),
            qw: double.parse(parts[5]),
            roll: double.parse(parts[6]),
            pitch: double.parse(parts[7]),
            yaw: double.parse(parts[8]),
          ),
        );
      } catch (e) {
        debugPrint('Error parsing orientation line $i: $e');
      }
    }
    return result;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// IMU REPLAY ENGINE V2
// ─────────────────────────────────────────────────────────────────────────────

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

  /// Whether to use deterministic fixed-step replay (simulation time).
  /// When true, IMU/GPS timestamps and dt are derived from a fixed step,
  /// not wall-clock time. This makes replay deterministic across runs.
  bool deterministicReplay = true;

  /// Whether to add realistic noise to IMU data.
  bool enableImuNoise = true;

  /// Whether to simulate station dwell times.
  bool enableDwellTimes = true;

  /// Logging verbosity (0=none, 1=events, 2=detailed, 3=all).
  int logVerbosity = 2;

  /// Callback for external EKF state injection.
  void Function(double progressMeters, double velocity)? onEkfStateRequest;

  // Log Replay State
  bool _isLogReplayMode = false;
  List<LogLocation> _logLocations = [];
  List<LogImu> _logAccels = [];
  List<LogImu> _logGyros = [];
  List<LogGravity> _logGravity = [];
  List<LogOrientation> _logOrientation = [];
  int _logLocIndex = 0;
  int _logAccelIndex = 0;
  int _logGyroIndex = 0;
  int _logGravityIndex = 0;
  int _logOrientationIndex = 0;
  double _logStartTimeSeconds = 0.0;
  LogImu? _lastLogAccel;

  // Unified Log State
  bool _isUnifiedLogReplayMode = false;
  List<UnifiedRouteLogTick> _unifiedLogTicks = [];
  int _unifiedLogIndex = 0;
  LatLng? _lastUnifiedGpsPos;
  double? _lastUnifiedGpsTime;
  double _lastUnifiedGpsSpeed = 0.0;

  // ─────────────────────────────────────────────────────────────────────────
  // State
  // ─────────────────────────────────────────────────────────────────────────

  TestRoute? _route;
  double _elapsedSeconds = 0.0;
  bool _isPlaying = false;
  bool _finished = false;
  Timer? _playbackTimer;
  DateTime? _lastTickTime;
  final math.Random _random = math.Random(42); // Seeded for reproducibility
  static const double _fixedTickSeconds = 0.01; // 100 Hz fixed step

  // GPS dropout state
  // ignore: unused_field - Reserved for GPS timing analysis
  DateTime? _lastGpsTime;
  double? _lastGpsElapsed;
  // ignore: unused_field - Reserved for tunnel visualization
  bool _inTunnel = false;
  double _nextIntermittentDropout = 0;
  double _intermittentDropoutEnd = 0;

  // Track if completeDropout has emitted its initial GPS (resets when mode changes)
  bool _completeDropoutInitialEmitted = false;
  GpsDropoutMode _lastDropoutMode = GpsDropoutMode.normal;

  // Motion state
  SimulatedMotionState _motionState = SimulatedMotionState.stationary;
  double _currentSpeed = 0.0;
  double _stationaryDuration = 0.0;

  // Logging
  final List<ReplayLogEntry> _logs = [];

  // ─────────────────────────────────────────────────────────────────────────
  // Stream Controllers
  // ─────────────────────────────────────────────────────────────────────────

  final _accelController = StreamController<AccelerometerEvent>.broadcast();
  final _gyroController = StreamController<GyroscopeEvent>.broadcast();
  final _gpsController = StreamController<Position>.broadcast();
  final _tickController = StreamController<ReplayTickResultV2>.broadcast();
  final _logController = StreamController<ReplayLogEntry>.broadcast();
  final _imuSampleController = StreamController<ImuSample>.broadcast();
  final _gravityController = StreamController<GravitySample>.broadcast();
  final _orientationController = StreamController<OrientationSample>.broadcast();

  // ─────────────────────────────────────────────────────────────────────────
  // Public Streams
  // ─────────────────────────────────────────────────────────────────────────

  Stream<AccelerometerEvent> get accelerometerStream => _accelController.stream;
  Stream<GyroscopeEvent> get gyroscopeStream => _gyroController.stream;
  Stream<Position> get gpsStream => _gpsController.stream;
  Stream<ReplayTickResultV2> get tickStream => _tickController.stream;
  Stream<ReplayLogEntry> get logStream => _logController.stream;
  Stream<ImuSample> get imuSampleStream => _imuSampleController.stream;
  Stream<GravitySample> get gravityStream => _gravityController.stream;
  Stream<OrientationSample> get orientationStream =>
      _orientationController.stream;

  // ─────────────────────────────────────────────────────────────────────────
  // Public Properties
  // ─────────────────────────────────────────────────────────────────────────

  TestRoute? get route => _route;
  bool get isPlaying => _isPlaying;

  /// True once playback has auto-paused at the end of the route/log.
  /// Distinguishes a natural end-of-run pause from a user pause/stop so the
  /// dashboard can surface a FINISHED state instead of RUNNING/STOP.
  bool get isFinished => _finished;

  /// Invoked once when playback reaches the natural end and auto-pauses.
  void Function()? onFinished;

  double get elapsedSeconds => _elapsedSeconds;
  double get progress =>
      _route == null
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
        await _loadMetroRoute(routeId);
        break;
      case TestRouteId.rajajinargarToNallurHalli:
        await _loadMetroRoute(routeId);
        break;
      case TestRouteId.nallurHalliToVijayanagar:
        // Placeholder for pure log replay where route is derived from log
        break;
      case TestRouteId.koramangalaToIndiranagar:
        await _loadNonMetroRoute(routeId);
        break;
      case TestRouteId.mgRoadToAirport:
        await _loadMultiModalRoute(routeId);
        break;
      case TestRouteId.capturedRealRoute:
        // Special mode: Loaded via separate method loadCapturedRouteReplay
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

  /// Loads a special replay mode fusing a JSON ground truth route with CSV logs.
  Future<void> loadCapturedRouteReplay(
    String routeJsonPath,
    String logDir,
  ) async {
    _reset();
    _isLogReplayMode = true;

    // 1. Load Ground Truth Geometry from JSON
    try {
      final jsonString = await rootBundle.loadString(routeJsonPath);
      final jsonMap = jsonDecode(jsonString);
      final routes = jsonMap['routes'] as List;
      if (routes.isEmpty) throw Exception('No routes in JSON');

      final polylinePoints = <LatLng>[];
      // Decode overview polyline or legs? Directions API usually has 'overview_polyline'
      // But the file content shown earlier had 'routes' -> 'legs' -> 'steps' structure possibly.
      // Let's look for overview_polyline points first, or recursively decode legs.
      // Based on typical Directions API:
      if (routes[0]['overview_polyline'] != null) {
        final encoded = routes[0]['overview_polyline']['points'];
        polylinePoints.addAll(_decodePolyline(encoded));
      } else {
        // Fallback to leg steps if overview missing
        final legs = routes[0]['legs'] as List;
        for (final leg in legs) {
          final steps = leg['steps'] as List;
          for (final step in steps) {
            final encoded = step['polyline']['points'];
            polylinePoints.addAll(_decodePolyline(encoded));
          }
        }
      }

      if (polylinePoints.isEmpty) throw Exception('Failed to decode polyline');

      // Calculate cumulative meters for the route
      final cumMeters = _computeCumulativeMeters(polylinePoints);

      _route = TestRoute(
        id: TestRouteId.capturedRealRoute,
        name: 'Captured Real Route',
        description: 'Ground Truth from JSON + Real Logs',
        legs: [], // We treat it as one giant leg for now
        fullPolyline: polylinePoints,
        fullCumulativeMeters: cumMeters,
        totalMeters: cumMeters.last,
        totalDurationSeconds: 0, // Will be updated from log
      );
    } catch (e) {
      debugPrint('Error loading route JSON: $e');
      return;
    }

    // 2. Load Logs
    await _loadLogFiles(logDir);

    // 3. Align and Fuse
    // Set total duration based on log duration
    if (_route != null && _logAccels.isNotEmpty) {
      final duration =
          _logAccels.last.secondsElapsed - _logAccels.first.secondsElapsed;

      // Load stations from all_india_stops.dart snapped to the route
      final stations = _findAndSnapStations(_route!.fullPolyline);

      // Create a single leg to hold the data (geometry + stations)
      final leg = TestRouteLeg(
        id: 'captured_leg_0',
        type: LegType.metro,
        name: 'Captured Metro Leg',
        polyline: _route!.fullPolyline,
        cumulativeMeters: _route!.fullCumulativeMeters,
        stations: stations,
        startTimeSeconds: 0,
        endTimeSeconds: duration,
        averageSpeedMps: _route!.totalMeters / duration,
        hasGpsInTunnel: false,
      );

      // Re-create route with proper leg
      _route = TestRoute(
        id: _route!.id,
        name: _route!.name,
        description: _route!.description,
        legs: [leg],
        fullPolyline: _route!.fullPolyline,
        fullCumulativeMeters: _route!.fullCumulativeMeters,
        totalMeters: _route!.totalMeters,
        totalDurationSeconds: duration,
      );
    }
  }

  List<LatLng> _decodePolyline(String encoded) {
    if (encoded.isEmpty) return [];
    final List<LatLng> points = [];
    int index = 0;
    int len = encoded.length;
    int lat = 0;
    int lng = 0;

    // Clean input just in case
    encoded = encoded.trim();
    len = encoded.length;

    try {
      while (index < len) {
        int b, shift = 0, result = 0;
        do {
          b = encoded.codeUnitAt(index++) - 63;
          result |= (b & 0x1f) << shift;
          shift += 5;
        } while (b >= 0x20);
        int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
        lat += dlat;

        shift = 0;
        result = 0;
        do {
          b = encoded.codeUnitAt(index++) - 63;
          result |= (b & 0x1f) << shift;
          shift += 5;
        } while (b >= 0x20);
        int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
        lng += dlng;

        final latDouble = lat.toDouble() / 1E5;
        final lngDouble = lng.toDouble() / 1E5;

        // STRICT FILTER: Bangalore Bounds only
        // Lat: 12.0 to 14.0
        // Lng: 77.0 to 78.0
        // This removes any outliers/garbage from decoding errors
        if (latDouble > 12.0 &&
            latDouble < 14.0 &&
            lngDouble > 77.0 &&
            lngDouble < 78.0) {
          points.add(LatLng(latDouble, lngDouble));
        }
      }
    } catch (e) {
      _log('ERROR', 'POLYLINE', 'Decoding error at index $index: $e');
    }
    return points;
  }

  Future<void> _loadLogFiles(String directory) async {
    _logLocations = await LogParser.parseLocationLog('$directory/Location.csv');
    _logAccels = await LogParser.parseImuLog('$directory/Accelerometer.csv');
    _logGyros = await LogParser.parseImuLog('$directory/Gyroscope.csv');

    // Load optional gravity and orientation logs
    try {
      _logGravity = await LogParser.parseGravityLog('$directory/Gravity.csv');
      debugPrint('Loaded ${_logGravity.length} gravity samples');
    } catch (e) {
      debugPrint('Gravity.csv not available: $e');
      _logGravity = [];
    }

    try {
      _logOrientation = await LogParser.parseOrientationLog(
        '$directory/Orientation.csv',
      );
      debugPrint('Loaded ${_logOrientation.length} orientation samples');
    } catch (e) {
      debugPrint('Orientation.csv not available: $e');
      _logOrientation = [];
    }

    if (_logLocations.isEmpty) {
      throw Exception('No location data found in logs');
    }
    if (_logAccels.isEmpty) {
      throw Exception('No accelerometer data found in logs');
    }
    if (_logGyros.isEmpty) throw Exception('No gyroscope data found in logs');

    _logStartTimeSeconds = _logLocations.first.secondsElapsed;
  }

  Future<void> loadUnifiedRouteLog(String path) async {
    _reset();
    _isUnifiedLogReplayMode = true;
    _log('LOAD', 'INFO', 'Loading unified log: $path');

    final content = await rootBundle.loadString(path);
    final json = jsonDecode(content);

    final metadata = json['metadata'];
    final ticks =
        (json['ticks'] as List)
            .map((t) => UnifiedRouteLogTick.fromJson(t))
            .toList();
    _unifiedLogTicks = ticks;
    _unifiedLogIndex = 0;

    final polyString = metadata['green_polyline'] as String? ?? '';
    final polyPoints = _decodePolyline(polyString);
    final googleRoutePoints = await _loadGoogleRouteFromLog();

    // DEBUG: Analyse Polyline
    if (polyPoints.isNotEmpty) {
      double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
      for (var p in polyPoints) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      _log(
        'DEBUG',
        'POLYLINE',
        'Decoded ${polyPoints.length} points. Bounds: [${minLat.toStringAsFixed(4)}, ${minLng.toStringAsFixed(4)}] to [${maxLat.toStringAsFixed(4)}, ${maxLng.toStringAsFixed(4)}]',
      );
      if (minLat < 12.0 || maxLat > 14.0 || minLng < 77.0 || maxLng > 78.0) {
        _log(
          'ERROR',
          'POLYLINE',
          'Polyline contains outliers! Dumping first 5: ${polyPoints.take(5).toList()}',
        );
      }
    } else {
      _log(
        'ERROR',
        'POLYLINE',
        'Decoded points is EMPTY. String length: ${polyString.length}',
      );
    }

    // Calculate cumulative meters
    final cumMeters = _computeCumulativeMeters(polyPoints);
    double duration = (metadata['duration'] as num).toDouble();

    // Parse stations from metadata
    final detectedStops = (metadata['detected_stops'] as List?) ?? [];
    final stations = <TestRouteStation>[];

    for (var s in detectedStops) {
      final ref = s['ref'] ?? {};
      if (ref['lat'] != null) {
        stations.add(
          TestRouteStation(
            id: s['name'],
            name: s['name'],
            position: LatLng(ref['lat'], ref['lng']),
            cumulativeMeters: 0, // Todo: calculate projection
            dwellTimeSeconds: 20,
            arrivalTimeSeconds: s['time'],
            isUnderground: true,
          ),
        );
      }
    }

    _route = TestRoute(
      id: TestRouteId.capturedRealRoute,
      name: 'Unified Log Replay',
      description: 'Log Replay',
      legs: [
        TestRouteLeg(
          id: 'unified_leg',
          type: LegType.metro,
          name: 'Unified Metro Leg',
          polyline: polyPoints,
          cumulativeMeters: cumMeters,
          stations: stations,
          startTimeSeconds: 0,
          endTimeSeconds: duration,
          averageSpeedMps: cumMeters.isNotEmpty ? cumMeters.last / duration : 0,
          hasGpsInTunnel: false,
        ),
      ],
      fullPolyline: googleRoutePoints.isNotEmpty ? googleRoutePoints : polyPoints,
      groundTruthPolyline: polyPoints,
      fullCumulativeMeters: cumMeters,
      totalMeters: cumMeters.isNotEmpty ? cumMeters.last : 0,
      totalDurationSeconds: duration,
    );

    _log(
      'LOAD',
      'EVENT',
      'Loaded ${_unifiedLogTicks.length} ticks from unified log',
    );
  }

  Future<void> loadFromLog(String logDirectory, TestRouteId routeId) async {
    _log('LOAD', 'INFO', 'Loading log from: $logDirectory');

    // 1. Parse Logs FIRST to get the GPS data
    try {
      _logLocations = await LogParser.parseLocationLog(
        '$logDirectory/Location.csv',
      );
      _logAccels = await LogParser.parseImuLog(
        '$logDirectory/Accelerometer.csv',
      );
      _logGyros = await LogParser.parseImuLog('$logDirectory/Gyroscope.csv');

      if (_logLocations.isEmpty) throw Exception('No location data found');

      // 2. Build route polyline from log GPS data (sampled every ~50m or 10 points)
      final logPolyline = <LatLng>[];
      final logCumulativeMeters = <double>[];
      final groundTruthPolyline = <LatLng>[]; // Full density for visualization
      double cumulativeDistance = 0.0;
      LatLng? lastPoint;

      final definedGroundTruth = await _tryLoadGroundTruthPolyline(routeId);
      if (definedGroundTruth != null) {
        _log(
          'LOAD',
          'INFO',
          'Using defined ground truth (${definedGroundTruth.length} pts)',
        );
        groundTruthPolyline.addAll(definedGroundTruth);
      }

      for (int i = 0; i < _logLocations.length; i++) {
        final loc = _logLocations[i];
        final point = LatLng(loc.latitude, loc.longitude);

        if (lastPoint != null) {
          final dist = _haversineDistance(lastPoint, point);
          cumulativeDistance += dist;
        }

        // Only use log as ground truth if we don't have a defined one
        if (definedGroundTruth == null) {
          groundTruthPolyline.add(point);
        }

        // Sample every 10 points or at minimum distance of 30m (for playback)
        if (i == 0 || i == _logLocations.length - 1 || i % 10 == 0) {
          logPolyline.add(point);
          logCumulativeMeters.add(cumulativeDistance);
        }
        lastPoint = point;
      }

      final totalDuration =
          _logLocations.last.secondsElapsed -
          _logLocations.first.secondsElapsed;
      final totalMeters = cumulativeDistance;

      // 3. Create a simple route from the log data
      final leg = TestRouteLeg(
        id: 'log_replay',
        type: LegType.metro,
        name: 'Log Replay: $logDirectory',
        polyline: logPolyline,
        cumulativeMeters: logCumulativeMeters,
        stations: await _tryLoadStations(routeId) ?? [],
        startTimeSeconds: 0,
        endTimeSeconds: totalDuration,
        averageSpeedMps: totalMeters / totalDuration,
        hasGpsInTunnel: false,
      );

      _route = TestRoute(
        id: routeId,
        name: 'Log Replay Route',
        description: 'Route reconstructed from GPS log data',
        legs: [leg],
        fullPolyline:
            groundTruthPolyline.isNotEmpty ? groundTruthPolyline : logPolyline,
        groundTruthPolyline:
            groundTruthPolyline, // Use the preferred ground truth
        fullCumulativeMeters: logCumulativeMeters,
        totalMeters: totalMeters,
        totalDurationSeconds: totalDuration,
      );

      _isLogReplayMode = true;
      _logStartTimeSeconds = _logLocations.first.secondsElapsed;

      _log('LOAD', 'EVENT', 'Log loaded successfully', {
        'locations': _logLocations.length,
        'accels': _logAccels.length,
        'gyros': _logGyros.length,
        'polylinePoints': logPolyline.length,
        'totalMeters': totalMeters.toStringAsFixed(0),
        'duration': totalDuration.toStringAsFixed(0),
      });

      _reset();
    } catch (e) {
      _log('LOAD', 'ERROR', 'Failed to load logs: $e');
      _isLogReplayMode = false;
      rethrow;
    }
  }

  Future<void> _loadMetroRoute(TestRouteId routeId) async {
    final jsonStr = await rootBundle.loadString(
      'assets/ekf_test_routes/bengaluru_metro_routes.json',
    );
    final data = json.decode(jsonStr) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>;

    final routeIdStr =
        {
          TestRouteId.majesticToNallurHalli: 'majestic_to_nallur_halli',
          TestRouteId.rajajinargarToNallurHalli: 'rajajinagar_to_nallur_halli',
          TestRouteId.nallurHalliToVijayanagar: 'nallur_halli_to_vijayanagar',
        }[routeId]!;

    final routeData = routes.firstWhere(
      (r) => r['id'] == routeIdStr,
      orElse: () => throw Exception('Route not found: $routeIdStr'),
    );

    // Parse stations
    final stations =
        (routeData['stations'] as List<dynamic>)
            .map((s) => TestRouteStation.fromJson(s as Map<String, dynamic>))
            .toList();

    // Parse polyline with proper interpolation
    final rawPolyline =
        (routeData['polyline_points'] as List<dynamic>)
            .map(
              (p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
            )
            .toList();

    final cumMeters =
        (routeData['cumulative_meters'] as List<dynamic>)
            .map((m) => (m as num).toDouble())
            .toList();

    // Interpolate polyline for smoother simulation
    final (interpolated, interpolatedCum) = _interpolatePolyline(
      rawPolyline,
      cumMeters,
      10.0,
    );

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
      description:
          'Metro route from ${stations.first.name} to ${stations.last.name}',
      legs: [leg],
      fullPolyline: interpolated,
      fullCumulativeMeters: interpolatedCum,
      totalMeters: totalMeters,
      totalDurationSeconds: duration,
    );
  }

  /// Try to load ground truth polyline from routes JSON
  Future<List<LatLng>?> _tryLoadGroundTruthPolyline(TestRouteId routeId) async {
    try {
      final jsonStr = await rootBundle.loadString(
        'assets/ekf_test_routes/bengaluru_metro_routes.json',
      );
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      final routes = data['routes'] as List<dynamic>;

      final routeIdStr =
          {
            TestRouteId.nallurHalliToVijayanagar: 'nallur_halli_to_vijayanagar',
          }[routeId];

      if (routeIdStr == null) return null;

      final routeData = routes.firstWhere(
        (r) => r['id'] == routeIdStr,
        orElse: () => null,
      );

      if (routeData == null) return null;

      final rawPolyline =
          (routeData['polyline_points'] as List<dynamic>)
              .map(
                (p) =>
                    LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()),
              )
              .toList();

      return rawPolyline.isNotEmpty ? rawPolyline : null;
    } catch (e) {
      _log('LOAD', 'WARN', 'Failed to load ground truth for $routeId: $e');
      return null;
    }
  }

  Future<List<TestRouteStation>?> _tryLoadStations(TestRouteId routeId) async {
    try {
      final jsonStr = await rootBundle.loadString(
        'assets/ekf_test_routes/bengaluru_metro_routes.json',
      );
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      final routes = data['routes'] as List<dynamic>;

      // Determine the JSON ID for the requested route
      final routeIdStr =
          {
            TestRouteId.majesticToNallurHalli: 'majestic_to_nallur_halli',
            TestRouteId.rajajinargarToNallurHalli:
                'rajajinagar_to_nallur_halli',
            TestRouteId.nallurHalliToVijayanagar: 'nallur_halli_to_vijayanagar',
            // Default logical mapping for others if needed
          }[routeId];

      if (routeIdStr == null) return null;

      final routeData = routes.firstWhere(
        (r) => r['id'] == routeIdStr,
        orElse: () => null,
      );

      if (routeData == null) return null;

      return (routeData['stations'] as List<dynamic>)
          .map((s) => TestRouteStation.fromJson(s as Map<String, dynamic>))
          .toList();
    } catch (e) {
      _log('LOAD', 'WARN', 'Failed to load stations for $routeId: $e');
      return null;
    }
  }

  /// Finds stations from all_india_stops.dart within 500m of the polyline
  /// and snaps them to the closest point on the route.
  List<TestRouteStation> _findAndSnapStations(List<LatLng> polyline) {
    if (polyline.isEmpty) return [];

    final routeStations = <TestRouteStation>[];
    const double captureRadiusMeters = 500.0;

    // Convert all_india_stops to potential candidates
    // Performance: Filter by bounding box first if optimization needed, but 1200 stops is fast enough.
    for (final stop in allIndiaStops) {
      final stopPos = LatLng(
        (stop['lat'] as num).toDouble(),
        (stop['lng'] as num).toDouble(),
      );

      // 1. Check if ANY point on polyline is within 500m
      // Improve efficiency: only snap if 'near'
      final (
        closestPoint,
        distMeters,
        progressMeters,
      ) = _findClosestPointOnPolyline(stopPos, polyline);

      if (distMeters <= captureRadiusMeters) {
        // Calculate arrival time based on progress (assuming avg speed of ~9m/s or 32km/h for simplicity)
        // Ideally we'd map this to the log's timeline, but linear estimation is sufficient for station markers.
        // We know total distance is _route!.totalMeters and total duration is pre-calculated.
        double avgSpeed = 10.0;
        if (_route != null && _route!.totalDurationSeconds > 0) {
          avgSpeed = _route!.totalMeters / _route!.totalDurationSeconds;
        }

        routeStations.add(
          TestRouteStation(
            id: stop['id']?.toString() ?? 'unknown',
            name: stop['name']?.toString() ?? 'Unknown Station',
            // Use the SNAPPED position on the route for the test engine logic
            position: closestPoint,
            cumulativeMeters: progressMeters,
            // Calculate approximate arrival time
            arrivalTimeSeconds: progressMeters / avgSpeed,
            dwellTimeSeconds: 25.0,
            isUnderground:
                true, // Assume metro is underground for simplicity in this test
          ),
        );
      }
    }

    // Sort by order of appearance on path
    routeStations.sort(
      (a, b) => a.cumulativeMeters.compareTo(b.cumulativeMeters),
    );

    _log(
      'LOAD',
      'EVENT',
      'Snapped ${routeStations.length} stations from all_india_stops',
    );
    return routeStations;
  }

  /// Returns (ProjectedPoint, DistanceToPolyline, CumulativeDistAlongPolyline)
  (LatLng, double, double) _findClosestPointOnPolyline(
    LatLng point,
    List<LatLng> polyline,
  ) {
    double minDst = double.infinity;
    LatLng bestProj = polyline.first;
    double bestProgress = 0.0;

    // Pre-calculate cumulative distances for accuracy
    // (This is expensive to do for every point, ideally cached)
    final polyDist = _computeCumulativeMeters(polyline);

    for (int i = 0; i < polyline.length - 1; i++) {
      final p1 = polyline[i];
      final p2 = polyline[i + 1];

      final (proj, tFraction) = _projectPointOnSegment(point, p1, p2);
      final dist = _haversineDistance(point, proj);

      if (dist < minDst) {
        minDst = dist;
        bestProj = proj;
        // tFraction is 0..1 fraction of segment.
        // Segment length:
        final segLen = polyDist[i + 1] - polyDist[i];
        bestProgress = polyDist[i] + (segLen * tFraction);
      }
    }

    return (bestProj, minDst, bestProgress);
  }

  (LatLng, double) _projectPointOnSegment(LatLng p, LatLng a, LatLng b) {
    final ap = _toCartesian(p.latitude - a.latitude, p.longitude - a.longitude);
    final ab = _toCartesian(b.latitude - a.latitude, b.longitude - a.longitude);

    final dot = ap.x * ab.x + ap.y * ab.y;
    final lenSq = ab.x * ab.x + ab.y * ab.y;

    double t = (lenSq == 0) ? 0.0 : (dot / lenSq);
    t = t.clamp(0.0, 1.0);

    final lat = a.latitude + (b.latitude - a.latitude) * t;
    final lng = a.longitude + (b.longitude - a.longitude) * t;

    return (LatLng(lat, lng), t);
  }

  math.Point<double> _toCartesian(double dLat, double dLng) {
    // Determine approx meters
    // Lat deg ~ 111000m
    // Lng deg ~ 111000 * cos(lat)
    const metersPerLat = 111320.0;
    // rough approx at equator/mid-lat, sufficient for small segments
    const metersPerLng = 111320.0;
    return math.Point(dLat * metersPerLat, dLng * metersPerLng);
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
    final fullCum = [...walkCum, ...autoCum.map((m) => m + walkCum.last)];

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
    _finished = false;
    if (!deterministicReplay) {
      _lastTickTime = DateTime.now();
    } else {
      _lastTickTime = null;
    }
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
    _finished = false;
    _log('CTRL', 'EVENT', 'Playback stopped');
  }

  /// Mark playback as naturally finished (end of route/log reached) and
  /// auto-pause. Idempotent: only fires the [onFinished] callback once.
  void _finish() {
    if (_finished) return;
    _finished = true;
    pause();
    _log('CTRL', 'EVENT', 'Playback completed');
    onFinished?.call();
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

    _intermittentDropoutEnd = 0;

    _isLogReplayMode = false;
    _isUnifiedLogReplayMode = false;
    _unifiedLogIndex = 0;
    _unifiedLogTicks = [];

    if (_isLogReplayMode) {
      _logLocIndex = 0;
      _logAccelIndex = 0;
      _logGyroIndex = 0;
      _logGravityIndex = 0;
      _logOrientationIndex = 0;
      _lastLogAccel = null;
      // Initialize elapsed time to start of log relative to 0
      // Actually we want playback _elapsedSeconds to run from 0 to Duration
      // We will map _elapsedSeconds to log.secondsElapsed
    }
  }

  void dispose() {
    _playbackTimer?.cancel();
    _accelController.close();
    _gyroController.close();
    _gpsController.close();
    _tickController.close();
    _logController.close();
    _imuSampleController.close();
    _gravityController.close();
    _orientationController.close();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Tick Processing
  // ─────────────────────────────────────────────────────────────────────────

  void _tick() {
    final route = _route;
    if (route == null) return;

    // Calculate warped delta
    final now = DateTime.now();
    final realDelta =
        _lastTickTime == null
            ? _fixedTickSeconds
            : (now.difference(_lastTickTime!).inMicroseconds / 1000000.0);
    if (!deterministicReplay) {
      _lastTickTime = now;
    }

    final warpedDelta =
        (deterministicReplay ? _fixedTickSeconds : realDelta) * warpFactor;
    _elapsedSeconds += warpedDelta;

    final simTime =
        deterministicReplay
            ? DateTime.fromMicrosecondsSinceEpoch(
              (_elapsedSeconds * 1e6).round(),
            )
            : now;

    if (_isLogReplayMode) {
      _tickLogReplay(warpedDelta);
      return;
    }

    if (_isUnifiedLogReplayMode) {
      _tickUnifiedLogReplay(); // Ticks are driven by elapsedSeconds
      return;
    }

    // Check for end
    if (_elapsedSeconds >= route.totalDurationSeconds) {
      _elapsedSeconds = route.totalDurationSeconds;
      _finish();
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
    _accelController.add(AccelerometerEvent(accelX, accelY, accelZ, simTime));
    _gyroController.add(GyroscopeEvent(gyroX, gyroY, gyroZ, simTime));
    _imuSampleController.add(
      ImuSample(
        ax: accelX,
        ay: accelY,
        az: accelZ,
        gx: gyroX,
        gy: gyroY,
        gz: gyroZ,
        timestamp: Duration(microseconds: simTime.microsecondsSinceEpoch),
      ),
    );

    // GPS handling
    final gpsResult = _computeGpsState(position, leg);
    if (gpsResult.shouldEmit) {
      _gpsController.add(
        _createPosition(
          position,
          bearing,
          _currentSpeed,
          gpsResult.accuracy,
          simTime,
        ),
      );
      _lastGpsTime = simTime;
      _lastGpsElapsed = _elapsedSeconds;
    }

    // ZUPT detection
    final isZupt =
        _stationaryDuration > 0.5; // 500ms stationary = ZUPT candidate
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
      timeSinceLastGps:
          _lastGpsElapsed != null
              ? Duration(
                milliseconds:
                    ((_elapsedSeconds - _lastGpsElapsed!) * 1000).round(),
              )
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
    if (idx >= route.fullPolyline.length - 1) {
      idx = route.fullPolyline.length - 2;
    }

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
    if (idx >= route.fullPolyline.length - 1) {
      idx = route.fullPolyline.length - 2;
    }

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
      } else {
        next ??= station;
      }
    }

    return (last, next);
  }

  void _updateMotionState(
    double delta,
    TestRouteLeg? leg,
    TestRouteStation? last,
    TestRouteStation? next,
  ) {
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
        _motionState =
            _currentSpeed < targetSpeed * 0.9
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

  ({LatLng? position, double accuracy, bool shouldEmit}) _computeGpsState(
    LatLng truePosition,
    TestRouteLeg? leg,
  ) {
    final isMetro = leg?.type == LegType.metro;

    switch (gpsDropoutMode) {
      case GpsDropoutMode.normal:
        // Reset dropout tracking when back to normal mode
        if (_lastDropoutMode != GpsDropoutMode.normal) {
          _lastDropoutMode = GpsDropoutMode.normal;
          _completeDropoutInitialEmitted = false;
        }
        return (position: truePosition, accuracy: 10.0, shouldEmit: true);

      case GpsDropoutMode.completeDropout:
        // Reset flag if mode just changed to completeDropout
        if (_lastDropoutMode != GpsDropoutMode.completeDropout) {
          _completeDropoutInitialEmitted = false;
          _lastDropoutMode = GpsDropoutMode.completeDropout;
        }
        if (!_completeDropoutInitialEmitted) {
          // Emit one initial position, then stop
          _completeDropoutInitialEmitted = true;
          return (position: truePosition, accuracy: 10.0, shouldEmit: true);
        }
        return (position: null, accuracy: 0.0, shouldEmit: false);

      case GpsDropoutMode.tunnelSimulation:
        if (isMetro) {
          // Only emit GPS at stations
          final (_, next) = _stationsAtTime(_elapsedSeconds);
          if (next != null) {
            final metersToNext = next.cumulativeMeters - progressMeters;
            if (metersToNext < 50 ||
                metersToNext > (next.cumulativeMeters - 50)) {
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
        if (_elapsedSeconds >= _intermittentDropoutEnd &&
            _intermittentDropoutEnd > 0) {
          // Schedule next dropout
          _nextIntermittentDropout =
              _elapsedSeconds + 10 + _random.nextDouble() * 20;
          _intermittentDropoutEnd =
              _nextIntermittentDropout + 5 + _random.nextDouble() * 10;
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

  Position _createPosition(
    LatLng pos,
    double bearing,
    double speed,
    double accuracy,
    DateTime timestamp,
  ) {
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
      timestamp: timestamp,
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

  (double x, double y, double z) _generateGyroscope(
    double delta,
    double bearing,
  ) {
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
          result.add(
            LatLng(
              p1.latitude + t * (p2.latitude - p1.latitude),
              p1.longitude + t * (p2.longitude - p1.longitude),
            ),
          );
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
      result.add(
        LatLng(
          start.latitude + t * (end.latitude - start.latitude),
          start.longitude + t * (end.longitude - start.longitude),
        ),
      );
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

  Future<List<LatLng>> _loadGoogleRouteFromLog() async {
    try {
      final content = await rootBundle.loadString('route_log_extracted.json');
      final json = jsonDecode(content) as Map<String, dynamic>;
      final directions = json['directions'] as Map<String, dynamic>?;
      final routes = directions?['routes'] as List?;
      if (routes == null || routes.isEmpty) return [];
      final overview = routes.first['overview_polyline'] as Map<String, dynamic>?;
      final points = overview?['points'] as String?;
      if (points == null || points.isEmpty) return [];
      return _decodePolyline(points);
    } catch (_) {
      return [];
    }
  }

  double _haversineDistance(LatLng p1, LatLng p2) {
    const R = 6371000.0;
    final dLat = _degToRad(p2.latitude - p1.latitude);
    final dLon = _degToRad(p2.longitude - p1.longitude);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
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
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    return (_radToDeg(math.atan2(y, x)) + 360) % 360;
  }

  double _degToRad(double deg) => deg * (math.pi / 180);
  double _radToDeg(double rad) => rad * (180 / math.pi);

  // ─────────────────────────────────────────────────────────────────────────
  // Logging
  // ─────────────────────────────────────────────────────────────────────────

  // ─────────────────────────────────────────────────────────────────────────
  // Log Replay Logic
  // ─────────────────────────────────────────────────────────────────────────

  void _tickLogReplay(double delta) {
    if (_route == null) return;

    // Current replay time in log time domain
    final logTime = _logStartTimeSeconds + _elapsedSeconds;

    // End detection: once we've advanced past the last logged location sample
    // there is nothing left to replay, so auto-finish (mirrors route/unified).
    if (_logLocations.isNotEmpty &&
        logTime > _logLocations.last.secondsElapsed) {
      _finish();
      return;
    }

    // 1. Process IMU Events up to current time
    // Accelerometer
    while (_logAccelIndex < _logAccels.length &&
        _logAccels[_logAccelIndex].secondsElapsed <= logTime) {
      final sample = _logAccels[_logAccelIndex];
      // Use log timestamp converted to DateTime for proper EKF integration
      final sampleTime = DateTime.fromMicrosecondsSinceEpoch(
        (sample.secondsElapsed * 1e6).round(),
      );
      _accelController.add(
        AccelerometerEvent(sample.x, sample.y, sample.z, sampleTime),
      );
      _lastLogAccel = sample;
      _logAccelIndex++;
    }

    // Gyroscope
    while (_logGyroIndex < _logGyros.length &&
        _logGyros[_logGyroIndex].secondsElapsed <= logTime) {
      final sample = _logGyros[_logGyroIndex];
      // Use log timestamp converted to DateTime for proper EKF integration
      final sampleTime = DateTime.fromMicrosecondsSinceEpoch(
        (sample.secondsElapsed * 1e6).round(),
      );
      _gyroController.add(
        GyroscopeEvent(sample.x, sample.y, sample.z, sampleTime),
      );
      if (_lastLogAccel != null) {
        _imuSampleController.add(
          ImuSample(
            ax: _lastLogAccel!.x,
            ay: _lastLogAccel!.y,
            az: _lastLogAccel!.z,
            gx: sample.x,
            gy: sample.y,
            gz: sample.z,
            timestamp: Duration(
              microseconds: sampleTime.microsecondsSinceEpoch,
            ),
          ),
        );
      }
      _logGyroIndex++;
    }

    // Gravity
    while (_logGravityIndex < _logGravity.length &&
        _logGravity[_logGravityIndex].secondsElapsed <= logTime) {
      final sample = _logGravity[_logGravityIndex];
      _gravityController.add(
        GravitySample(
          x: sample.x,
          y: sample.y,
          z: sample.z,
          timestamp: Duration(
            microseconds: (sample.secondsElapsed * 1e6).round(),
          ),
        ),
      );
      _logGravityIndex++;
    }

    // Orientation
    while (_logOrientationIndex < _logOrientation.length &&
        _logOrientation[_logOrientationIndex].secondsElapsed <= logTime) {
      final sample = _logOrientation[_logOrientationIndex];
      _orientationController.add(
        OrientationSample(
          azimuth: sample.yaw,
          pitch: sample.pitch,
          roll: sample.roll,
          timestamp: Duration(
            microseconds: (sample.secondsElapsed * 1e6).round(),
          ),
        ),
      );
      _logOrientationIndex++;
    }

    // 2. Process Location (Interpolate if needed, but for now just taking latest valid)
    // Find latest location sample <= logTime
    LogLocation? currentLoc;
    while (_logLocIndex < _logLocations.length &&
        _logLocations[_logLocIndex].secondsElapsed <= logTime) {
      currentLoc = _logLocations[_logLocIndex];
      _logLocIndex++;
    }

    // If we have a current location, process it
    if (currentLoc != null) {
      final rawPos = LatLng(currentLoc.latitude, currentLoc.longitude);

      // Snap to Ground Truth
      // Returns (ProjectedPoint, DistanceToPolyline, CumulativeDistAlongPolyline)
      final (snappedPos, _, pm) = _findClosestPointOnPolyline(
        rawPos,
        _route!.fullPolyline,
      );

      final progressMeters = pm;
      final progress =
          _route!.totalMeters > 0 ? progressMeters / _route!.totalMeters : 0.0;

      // Identify ZUPT
      final isZupt = currentLoc.speed < 0.8; // Relaxed threshold for log noise
      if (isZupt) {
        _stationaryDuration += delta;
      } else {
        _stationaryDuration = 0.0;
      }

      // ───────────────────────────────────────────────────────────────────────
      // NEW: Station Proximity & Snap Logic
      // ───────────────────────────────────────────────────────────────────────

      // Find nearest station
      TestRouteStation? nearestStation;
      double minStationDist = double.infinity;

      for (final station in _route!.allStations) {
        final dist = _haversineDistance(snappedPos, station.position);
        if (dist < minStationDist) {
          minStationDist = dist;
          nearestStation = station;
        }
      }

      // Define "At Station" logic:
      // 1. Within 50m of station center
      // 2. Speed is low (< 2.0 m/s) OR we are stationary
      // 3. Optional: We haven't just left this station (hysteresis could be added but simpler for now)
      final isNearStation = minStationDist < 50.0;
      final isSlow = currentLoc.speed < 2.0;

      final isAtStation = isNearStation && (isSlow || isZupt);

      // Populate last/next stations for UI context
      // If we are at a station, it's the "last" one we visited (or current)
      // If we are moving, logic is more complex without strictly ordered legs,
      // but nearest is a good proxy for "current/next" in this replay context.
      TestRouteStation? lastStation;
      TestRouteStation? nextStation;

      if (nearestStation != null) {
        if (progressMeters > nearestStation.cumulativeMeters) {
          lastStation = nearestStation;
          // We'd need to find the NEXT one in the list
          // Simple lookup:
          final idx = _route!.allStations.indexOf(nearestStation);
          if (idx != -1 && idx < _route!.allStations.length - 1) {
            nextStation = _route!.allStations[idx + 1];
          }
        } else {
          nextStation = nearestStation;
          final idx = _route!.allStations.indexOf(nearestStation);
          if (idx != -1 && idx > 0) {
            lastStation = _route!.allStations[idx - 1];
          }
        }
      }

      // Emit Tick
      final result = ReplayTickResultV2(
        elapsedSeconds: _elapsedSeconds,
        progress: progress,
        progressMeters: progressMeters,
        position: snappedPos, // Ground Truth for visualization
        bearing: currentLoc.bearing,
        speedMps: currentLoc.speed,
        motionState:
            isZupt
                ? SimulatedMotionState.stopped
                : SimulatedMotionState.cruising,

        // GPS Output Logic
        // In Log Replay, 'gpsPosition' is the RAW LOG position (noisy)
        // 'position' above is the SNAPPED/GROUND TRUTH position
        gpsPosition:
            gpsDropoutMode == GpsDropoutMode.completeDropout ? null : rawPos,
        gpsAccuracy:
            currentLoc
                .speedAccuracy, // Using speed accuracy as proxy or default? Log has bearing/speed acc.
        // Let's use a default if position acc missing, but we have bearingAcc/speedAcc.
        // Actually log header had bearingAccuracy, speedAccuracy.
        // Let's assume 10m if missing.
        gpsAvailable: gpsDropoutMode != GpsDropoutMode.completeDropout,
        dropoutMode: gpsDropoutMode,

        accelX:
            _logAccels.isNotEmpty
                ? _logAccels[math.min(_logAccelIndex, _logAccels.length - 1)].x
                : 0,
        accelY:
            _logAccels.isNotEmpty
                ? _logAccels[math.min(_logAccelIndex, _logAccels.length - 1)].y
                : 0,
        accelZ:
            _logAccels.isNotEmpty
                ? _logAccels[math.min(_logAccelIndex, _logAccels.length - 1)].z
                : 9.8,

        gyroX:
            _logGyros.isNotEmpty
                ? _logGyros[math.min(_logGyroIndex, _logGyros.length - 1)].x
                : 0,
        gyroY:
            _logGyros.isNotEmpty
                ? _logGyros[math.min(_logGyroIndex, _logGyros.length - 1)].y
                : 0,
        gyroZ:
            _logGyros.isNotEmpty
                ? _logGyros[math.min(_logGyroIndex, _logGyros.length - 1)].z
                : 0,

        isZuptCandidate: isZupt,
        zuptDurationSeconds: isZupt ? _stationaryDuration : null,
        // Calculate stations...
        isAtStation: isAtStation,
        lastStation: lastStation,
        nextStation: nextStation,
      );

      _tickController.add(result);

      // Emit GPS event if enabled
      if (result.gpsAvailable) {
        // Apply manual dropout if requested (Dashboard "Deactivate GPS")
        if (gpsDropoutMode != GpsDropoutMode.completeDropout) {
          final gpsTime = DateTime.fromMicrosecondsSinceEpoch(
            (currentLoc.secondsElapsed * 1e6).round(),
          );
          _gpsController.add(
            Position(
              latitude: rawPos.latitude,
              longitude: rawPos.longitude,
              timestamp: gpsTime,
              accuracy: 10.0, // Default or estimate
              altitude: currentLoc.altitude,
              heading: currentLoc.bearing,
              speed: currentLoc.speed,
              speedAccuracy: currentLoc.speedAccuracy,
              headingAccuracy: currentLoc.bearingAccuracy,
              altitudeAccuracy: 0.0,
            ),
          );
        }
      }
    }
  }

  void _log(
    String category,
    String level,
    String message, [
    Map<String, dynamic>? data,
  ]) {
    if (logVerbosity == 0) return;
    if (logVerbosity == 1 && level != 'EVENT') return;
    if (logVerbosity == 2 && level == 'DEBUG') return;

    final entry = ReplayLogEntry(
      timestamp:
          deterministicReplay
              ? DateTime.fromMicrosecondsSinceEpoch(
                (_elapsedSeconds * 1e6).round(),
              )
              : DateTime.now(),
      elapsedSeconds: _elapsedSeconds,
      category: category,
      level: level,
      message: message,
      data: data,
    );

    _logs.add(entry);

    _logController.add(entry);
  }

  void clearLogs() => _logs.clear();
}

// ─────────────────────────────────────────────────────────────────────────────
// UNIFIED LOG TYPES
// ─────────────────────────────────────────────────────────────────────────────

class UnifiedRouteLogTick {
  final double t;
  final double? lat;
  final double? lng;
  final bool isGpsInterpolated;
  final double accelX;
  final double accelY;
  final double accelZ;
  final double gyroX;
  final double gyroY;
  final double gyroZ;
  final bool isAtStation;
  final String? stationId;

  UnifiedRouteLogTick({
    required this.t,
    this.lat,
    this.lng,
    this.isGpsInterpolated = false,
    this.accelX = 0,
    this.accelY = 0,
    this.accelZ = 0,
    this.gyroX = 0,
    this.gyroY = 0,
    this.gyroZ = 0,
    this.isAtStation = false,
    this.stationId,
  });

  factory UnifiedRouteLogTick.fromJson(Map<String, dynamic> json) {
    return UnifiedRouteLogTick(
      t: (json['t'] as num).toDouble(),
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
      isGpsInterpolated: json['gps_interp'] == true,
      accelX: (json['ax'] as num).toDouble(),
      accelY: (json['ay'] as num).toDouble(),
      accelZ: (json['az'] as num).toDouble(),
      gyroX: (json['gx'] as num).toDouble(),
      gyroY: (json['gy'] as num).toDouble(),
      gyroZ: (json['gz'] as num).toDouble(),
      isAtStation: json['station'] != null,
      stationId: json['station'] as String?,
    );
  }
}

extension ImuReplayEngineExt on ImuReplayEngineV2 {
  void _tickUnifiedLogReplay() {
    if (_unifiedLogTicks.isEmpty) return;

    // Advance index
    while (_unifiedLogIndex < _unifiedLogTicks.length - 1 &&
        _unifiedLogTicks[_unifiedLogIndex + 1].t <= _elapsedSeconds) {
      _unifiedLogIndex++;
    }

    final tick = _unifiedLogTicks[_unifiedLogIndex];

    final sampleTime = DateTime.fromMicrosecondsSinceEpoch(
      (_elapsedSeconds * 1e6).round(),
    );

    // Emit IMU
    _accelController.add(
      AccelerometerEvent(tick.accelX, tick.accelY, tick.accelZ, sampleTime),
    );
    _gyroController.add(
      GyroscopeEvent(tick.gyroX, tick.gyroY, tick.gyroZ, sampleTime),
    );
    _imuSampleController.add(
      ImuSample(
        ax: tick.accelX,
        ay: tick.accelY,
        az: tick.accelZ,
        gx: tick.gyroX,
        gy: tick.gyroY,
        gz: tick.gyroZ,
        timestamp: Duration(microseconds: sampleTime.microsecondsSinceEpoch),
      ),
    );

    // GPS
    if (!tick.isGpsInterpolated && tick.lat != null) {
      if (_lastUnifiedGpsPos != null && _lastUnifiedGpsTime != null) {
        final dt = _elapsedSeconds - _lastUnifiedGpsTime!;
        if (dt > 0) {
          final dist = _haversineDistance(
            _lastUnifiedGpsPos!,
            LatLng(tick.lat!, tick.lng!),
          );
          _lastUnifiedGpsSpeed = dist / dt;
        }
      }
      _lastUnifiedGpsPos = LatLng(tick.lat!, tick.lng!);
      _lastUnifiedGpsTime = _elapsedSeconds;

      _gpsController.add(
        Position(
          latitude: tick.lat!,
          longitude: tick.lng!,
          timestamp: sampleTime,
          accuracy: 10.0,
          altitude: 0,
          heading: 0,
          speed: _lastUnifiedGpsSpeed,
          speedAccuracy: 0,
          altitudeAccuracy: 0,
          headingAccuracy: 0,
          isMocked: true,
        ),
      );
    }

    // Tick Result
    if (_route != null && _route!.fullPolyline.isNotEmpty) {
      final rawPos =
          tick.lat != null && tick.lng != null
              ? LatLng(tick.lat!, tick.lng!)
              : _route!.fullPolyline.first;

      final (snappedPos, _, pm) = _findClosestPointOnPolyline(
        rawPos,
        _route!.fullPolyline,
      );

      final progressMeters = pm;
      final progress =
          _route!.totalMeters > 0 ? progressMeters / _route!.totalMeters : 0.0;

      final isZupt = tick.isAtStation;

      _tickController.add(
        ReplayTickResultV2(
          elapsedSeconds: _elapsedSeconds,
          progress: progress,
          progressMeters: progressMeters,
          position: snappedPos,
          bearing: 0,
          speedMps: _lastUnifiedGpsSpeed,
          motionState:
              isZupt
                  ? SimulatedMotionState.stopped
                  : SimulatedMotionState.cruising,
          gpsPosition: (!tick.isGpsInterpolated && tick.lat != null)
              ? rawPos
              : null,
          gpsAccuracy: 10.0,
          gpsAvailable: !tick.isGpsInterpolated && tick.lat != null,
          dropoutMode:
              (tick.isGpsInterpolated || tick.lat == null)
                  ? GpsDropoutMode.tunnelSimulation
                  : GpsDropoutMode.normal,
          accelX: tick.accelX,
          accelY: tick.accelY,
          accelZ: tick.accelZ,
          gyroX: tick.gyroX,
          gyroY: tick.gyroY,
          gyroZ: tick.gyroZ,
          isZuptCandidate: isZupt,
          zuptDurationSeconds: isZupt ? 1.0 : null,
          isAtStation: tick.isAtStation,
          currentLeg: _route?.legs.firstOrNull,
        ),
      );
    }

    // End
    if (_elapsedSeconds >= (_route?.totalDurationSeconds ?? 0)) {
      _finish();
    }
  }
}
