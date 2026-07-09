// IMU Replay Engine for EKF Testing
//
// Streams recorded IMU data (accelerometer, gyroscope, GPS) for
// testing the EKF pipeline with real-world sensor recordings.
//
// Features:
// - Time warp (0.5x to 10x speed)
// - GPS dropout simulation (toggle to suppress GPS updates)
// - Seek to specific position
// - Station annotation markers
// - Integration with unified dashboard

import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

/// A single timestamped sensor sample.
class TimestampedSample {
  final double secondsElapsed;
  final double x;
  final double y;
  final double z;

  TimestampedSample({
    required this.secondsElapsed,
    required this.x,
    required this.y,
    required this.z,
  });
}

/// A GPS sample from recorded data.
class RecordedGpsSample {
  final double secondsElapsed;
  final double latitude;
  final double longitude;
  final double altitude;
  final double speed;
  final double bearing;
  final double horizontalAccuracy;
  final double verticalAccuracy;

  RecordedGpsSample({
    required this.secondsElapsed,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.speed,
    required this.bearing,
    required this.horizontalAccuracy,
    required this.verticalAccuracy,
  });

  Position toPosition() {
    return Position(
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      speed: speed,
      heading: bearing,
      accuracy: horizontalAccuracy,
      altitudeAccuracy: verticalAccuracy,
      headingAccuracy: 0,
      speedAccuracy: 0,
      timestamp: DateTime.now(),
    );
  }

  LatLng toLatLng() => LatLng(latitude, longitude);
}

/// A station annotation from recorded data.
class RecordedStationAnnotation {
  final double secondsElapsed;
  final String name;
  final String officialName;
  final double cumulativeMeters;

  RecordedStationAnnotation({
    required this.secondsElapsed,
    required this.name,
    required this.officialName,
    required this.cumulativeMeters,
  });
}

/// Result of a replay tick - contains all current data.
class ReplayTickResult {
  final double elapsedSeconds;
  final double progress; // 0.0 to 1.0
  final LatLng? gpsPosition;
  final double? gpsAccuracy;
  final bool gpsDroppedOut;
  final AccelerometerEvent? accelerometerEvent;
  final GyroscopeEvent? gyroscopeEvent;
  final RecordedStationAnnotation? currentStation;
  final RecordedStationAnnotation? nextStation;
  final double? speedMps;

  ReplayTickResult({
    required this.elapsedSeconds,
    required this.progress,
    this.gpsPosition,
    this.gpsAccuracy,
    required this.gpsDroppedOut,
    this.accelerometerEvent,
    this.gyroscopeEvent,
    this.currentStation,
    this.nextStation,
    this.speedMps,
  });
}

/// State of the replay engine.
enum ReplayState {
  idle,
  loading,
  ready,
  playing,
  paused,
  finished,
}

/// A complete recorded route with all sensor data.
class RecordedRoute {
  final String id;
  final String name;
  final String folderPath;
  final List<TimestampedSample> accelerometerData;
  final List<TimestampedSample> gyroscopeData;
  final List<RecordedGpsSample> gpsData;
  final List<RecordedStationAnnotation> stations;
  final List<LatLng> polyline;
  final List<double> stationMeters;
  final double durationSeconds;
  final double totalMeters;
  final bool isMetro;

  RecordedRoute({
    required this.id,
    required this.name,
    required this.folderPath,
    required this.accelerometerData,
    required this.gyroscopeData,
    required this.gpsData,
    required this.stations,
    required this.polyline,
    required this.stationMeters,
    required this.durationSeconds,
    required this.totalMeters,
    required this.isMetro,
  });

  /// Get the GPS sample closest to a given elapsed time.
  RecordedGpsSample? gpsAt(double elapsed) {
    if (gpsData.isEmpty) return null;
    return gpsData.reduce((a, b) =>
        (a.secondsElapsed - elapsed).abs() < (b.secondsElapsed - elapsed).abs()
            ? a
            : b);
  }

  /// Get the station at or before a given elapsed time.
  RecordedStationAnnotation? stationAt(double elapsed) {
    for (int i = stations.length - 1; i >= 0; i--) {
      if (stations[i].secondsElapsed <= elapsed) {
        return stations[i];
      }
    }
    return null;
  }

  /// Get the next upcoming station after a given elapsed time.
  RecordedStationAnnotation? nextStationAfter(double elapsed) {
    for (final s in stations) {
      if (s.secondsElapsed > elapsed) {
        return s;
      }
    }
    return null;
  }
}

/// IMU Replay Engine for testing EKF with recorded data.
///
/// Usage:
/// ```dart
/// final engine = ImuReplayEngine();
/// await engine.loadRoute('majestic_to_nallur_halli');
///
/// engine.accelerometerStream.listen((event) { ... });
/// engine.gyroscopeStream.listen((event) { ... });
/// engine.gpsStream.listen((position) { ... });
///
/// engine.setWarpFactor(2.0); // 2x speed
/// engine.setGpsDropout(true); // Simulate GPS loss
/// engine.play();
/// ```
class ImuReplayEngine {
  // ─────────────────────────────────────────────────────────────────────
  // State
  // ─────────────────────────────────────────────────────────────────────

  ReplayState _state = ReplayState.idle;
  RecordedRoute? _route;
  double _elapsedSeconds = 0.0;
  double _warpFactor = 1.0;
  bool _gpsDropout = false;
  Timer? _playbackTimer;
  DateTime? _lastTickTime;

  // Indices into sensor arrays for efficient lookup
  int _accelIndex = 0;
  int _gyroIndex = 0;
  int _gpsIndex = 0;

  // Stream controllers
  final _accelerometerController = StreamController<AccelerometerEvent>.broadcast();
  final _gyroscopeController = StreamController<GyroscopeEvent>.broadcast();
  final _gpsController = StreamController<Position>.broadcast();
  final _tickController = StreamController<ReplayTickResult>.broadcast();
  final _stateController = StreamController<ReplayState>.broadcast();

  // ─────────────────────────────────────────────────────────────────────
  // Public API - Streams
  // ─────────────────────────────────────────────────────────────────────

  /// Stream of accelerometer events (matches sensors_plus format).
  Stream<AccelerometerEvent> get accelerometerStream => _accelerometerController.stream;

  /// Stream of gyroscope events (matches sensors_plus format).
  Stream<GyroscopeEvent> get gyroscopeStream => _gyroscopeController.stream;

  /// Stream of GPS positions (only emitted when GPS dropout is false).
  Stream<Position> get gpsStream => _gpsController.stream;

  /// Stream of replay ticks with all current data.
  Stream<ReplayTickResult> get tickStream => _tickController.stream;

  /// Stream of state changes.
  Stream<ReplayState> get stateStream => _stateController.stream;

  // ─────────────────────────────────────────────────────────────────────
  // Public API - Properties
  // ─────────────────────────────────────────────────────────────────────

  /// Current replay state.
  ReplayState get state => _state;

  /// Currently loaded route.
  RecordedRoute? get route => _route;

  /// Current elapsed time in seconds.
  double get elapsedSeconds => _elapsedSeconds;

  /// Progress through the route (0.0 to 1.0).
  double get progress => _route == null ? 0.0 : (_elapsedSeconds / _route!.durationSeconds).clamp(0.0, 1.0);

  /// Current warp factor.
  double get warpFactor => _warpFactor;

  /// Whether GPS dropout is simulated.
  bool get gpsDropout => _gpsDropout;

  /// Duration of loaded route in seconds.
  double get durationSeconds => _route?.durationSeconds ?? 0.0;

  /// Total meters of loaded route.
  double get totalMeters => _route?.totalMeters ?? 0.0;

  /// Current GPS position (null if dropout or no data).
  LatLng? get currentGpsPosition {
    if (_gpsDropout || _route == null) return null;
    final gps = _route!.gpsAt(_elapsedSeconds);
    return gps?.toLatLng();
  }

  /// Current station (most recently passed).
  RecordedStationAnnotation? get currentStation {
    return _route?.stationAt(_elapsedSeconds);
  }

  /// Next upcoming station.
  RecordedStationAnnotation? get nextStation {
    return _route?.nextStationAfter(_elapsedSeconds);
  }

  /// All stations in the route.
  List<RecordedStationAnnotation> get stations => _route?.stations ?? [];

  /// Route polyline.
  List<LatLng> get polyline => _route?.polyline ?? [];

  // ─────────────────────────────────────────────────────────────────────
  // Public API - Controls
  // ─────────────────────────────────────────────────────────────────────

  /// Load a route from pre-processed assets.
  ///
  /// [routeId] should match one of:
  /// - 'majestic_to_nallur_halli'
  /// - 'rajajinagar_to_nallur_halli'
  /// - 'nallur_halli_to_vijayanagar'
  Future<void> loadRoute(String routeId) async {
    _setState(ReplayState.loading);

    try {
      // Load route metadata from assets
      final jsonStr = await rootBundle.loadString(
        'assets/ekf_test_routes/bengaluru_metro_routes.json',
      );
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      final routes = data['routes'] as List<dynamic>;

      final routeData = routes.firstWhere(
        (r) => r['id'] == routeId,
        orElse: () => throw Exception('Route not found: $routeId'),
      );

      // Parse route data
      final stations = (routeData['stations'] as List<dynamic>)
          .map((s) => RecordedStationAnnotation(
                secondsElapsed: (s['time_elapsed'] as num).toDouble(),
                name: s['recorded_name'] as String,
                officialName: s['name'] as String,
                cumulativeMeters: (s['cumulative_meters'] as num).toDouble(),
              ))
          .toList();

      final polyline = (routeData['polyline_points'] as List<dynamic>)
          .map((p) => LatLng(
                (p[0] as num).toDouble(),
                (p[1] as num).toDouble(),
              ))
          .toList();

      final stationMeters = (routeData['cumulative_meters'] as List<dynamic>)
          .map((m) => (m as num).toDouble())
          .toList();

      // For now, generate synthetic IMU data based on GPS motion
      // TODO: Load actual IMU data from recorded CSV files
      final gpsData = _generateSyntheticGps(
        polyline,
        stationMeters,
        stations,
        (routeData['duration_seconds'] as num).toDouble(),
      );

      final accelData = _generateSyntheticAccelerometer(gpsData);
      final gyroData = _generateSyntheticGyroscope(gpsData);

      _route = RecordedRoute(
        id: routeId,
        name: routeData['name'] as String,
        folderPath: '',
        accelerometerData: accelData,
        gyroscopeData: gyroData,
        gpsData: gpsData,
        stations: stations,
        polyline: polyline,
        stationMeters: stationMeters,
        durationSeconds: (routeData['duration_seconds'] as num).toDouble(),
        totalMeters: (routeData['total_meters'] as num).toDouble(),
        isMetro: true,
      );

      _reset();
      _setState(ReplayState.ready);
    } catch (e) {
      print('Error loading route: $e');
      _setState(ReplayState.idle);
      rethrow;
    }
  }

  /// Set the warp factor (playback speed multiplier).
  void setWarpFactor(double factor) {
    _warpFactor = factor.clamp(0.1, 200.0);
  }

  /// Enable/disable GPS dropout simulation.
  void setGpsDropout(bool dropout) {
    _gpsDropout = dropout;
  }

  /// Start or resume playback.
  void play() {
    if (_state != ReplayState.ready && _state != ReplayState.paused) {
      return;
    }

    _lastTickTime = DateTime.now();
    _playbackTimer?.cancel();
    _playbackTimer = Timer.periodic(
      const Duration(milliseconds: 10), // 100 Hz tick rate
      (_) => _tick(),
    );
    _setState(ReplayState.playing);
  }

  /// Pause playback.
  void pause() {
    if (_state != ReplayState.playing) return;
    _playbackTimer?.cancel();
    _setState(ReplayState.paused);
  }

  /// Stop and reset playback.
  void stop() {
    _playbackTimer?.cancel();
    _reset();
    _setState(ReplayState.ready);
  }

  /// Seek to a specific time.
  void seekTo(double seconds) {
    _elapsedSeconds = seconds.clamp(0.0, _route?.durationSeconds ?? 0.0);
    _updateIndices();
    _emitCurrentState();
  }

  /// Seek to a specific progress (0.0 to 1.0).
  void seekToProgress(double progress) {
    seekTo(progress * (_route?.durationSeconds ?? 0.0));
  }

  /// Dispose resources.
  void dispose() {
    _playbackTimer?.cancel();
    _accelerometerController.close();
    _gyroscopeController.close();
    _gpsController.close();
    _tickController.close();
    _stateController.close();
  }

  // ─────────────────────────────────────────────────────────────────────
  // Private Methods
  // ─────────────────────────────────────────────────────────────────────

  void _setState(ReplayState state) {
    if (_state != state) {
      _state = state;
      _stateController.add(state);
    }
  }

  void _reset() {
    _elapsedSeconds = 0.0;
    _accelIndex = 0;
    _gyroIndex = 0;
    _gpsIndex = 0;
  }

  void _updateIndices() {
    final route = _route;
    if (route == null) return;

    // Find the correct index for each sensor stream
    while (_accelIndex < route.accelerometerData.length - 1 &&
        route.accelerometerData[_accelIndex + 1].secondsElapsed <= _elapsedSeconds) {
      _accelIndex++;
    }
    while (_gyroIndex < route.gyroscopeData.length - 1 &&
        route.gyroscopeData[_gyroIndex + 1].secondsElapsed <= _elapsedSeconds) {
      _gyroIndex++;
    }
    while (_gpsIndex < route.gpsData.length - 1 &&
        route.gpsData[_gpsIndex + 1].secondsElapsed <= _elapsedSeconds) {
      _gpsIndex++;
    }
  }

  void _tick() {
    final route = _route;
    if (route == null) return;

    // Calculate elapsed time since last tick
    final now = DateTime.now();
    final realDelta = _lastTickTime == null
        ? 0.01
        : (now.difference(_lastTickTime!).inMicroseconds / 1000000.0);
    _lastTickTime = now;

    // Apply warp factor
    final warpedDelta = realDelta * _warpFactor;
    _elapsedSeconds += warpedDelta;

    // Check for end of route
    if (_elapsedSeconds >= route.durationSeconds) {
      _elapsedSeconds = route.durationSeconds;
      _playbackTimer?.cancel();
      _setState(ReplayState.finished);
      _emitCurrentState();
      return;
    }

    // Emit sensor events for this tick
    _emitSensorEvents(warpedDelta);
    _emitCurrentState();
  }

  void _emitSensorEvents(double delta) {
    final route = _route;
    if (route == null) return;

    // Emit accelerometer events that fall within this tick
    while (_accelIndex < route.accelerometerData.length &&
        route.accelerometerData[_accelIndex].secondsElapsed <= _elapsedSeconds) {
      final sample = route.accelerometerData[_accelIndex];
      _accelerometerController.add(AccelerometerEvent(sample.x, sample.y, sample.z, DateTime.now()));
      _accelIndex++;
    }

    // Emit gyroscope events
    while (_gyroIndex < route.gyroscopeData.length &&
        route.gyroscopeData[_gyroIndex].secondsElapsed <= _elapsedSeconds) {
      final sample = route.gyroscopeData[_gyroIndex];
      _gyroscopeController.add(GyroscopeEvent(sample.x, sample.y, sample.z, DateTime.now()));
      _gyroIndex++;
    }

    // Emit GPS events (unless dropout is enabled)
    if (!_gpsDropout) {
      while (_gpsIndex < route.gpsData.length &&
          route.gpsData[_gpsIndex].secondsElapsed <= _elapsedSeconds) {
        final sample = route.gpsData[_gpsIndex];
        _gpsController.add(sample.toPosition());
        _gpsIndex++;
      }
    }
  }

  void _emitCurrentState() {
    final route = _route;
    if (route == null) return;

    final gps = route.gpsAt(_elapsedSeconds);
    final currentStn = route.stationAt(_elapsedSeconds);
    final nextStn = route.nextStationAfter(_elapsedSeconds);

    _tickController.add(ReplayTickResult(
      elapsedSeconds: _elapsedSeconds,
      progress: progress,
      gpsPosition: _gpsDropout ? null : gps?.toLatLng(),
      gpsAccuracy: _gpsDropout ? null : gps?.horizontalAccuracy,
      gpsDroppedOut: _gpsDropout,
      currentStation: currentStn,
      nextStation: nextStn,
      speedMps: gps?.speed,
    ));
  }

  // ─────────────────────────────────────────────────────────────────────
  // Synthetic Data Generation (for initial testing)
  // ─────────────────────────────────────────────────────────────────────

  /// Generate synthetic GPS data from polyline + timing.
  List<RecordedGpsSample> _generateSyntheticGps(
    List<LatLng> polyline,
    List<double> cumMeters,
    List<RecordedStationAnnotation> stations,
    double durationSeconds,
  ) {
    if (polyline.isEmpty || stations.isEmpty) return [];

    final samples = <RecordedGpsSample>[];
    const gpsInterval = 1.0; // 1 Hz GPS

    for (double t = 0; t <= durationSeconds; t += gpsInterval) {
      // Interpolate position based on station timing
      final progress = t / durationSeconds;
      final targetMeters = progress * (cumMeters.isEmpty ? 0 : cumMeters.last);

      // Find segment
      int segIdx = 0;
      for (int i = 0; i < cumMeters.length - 1; i++) {
        if (targetMeters >= cumMeters[i] && targetMeters <= cumMeters[i + 1]) {
          segIdx = i;
          break;
        }
      }
      if (segIdx >= polyline.length - 1) segIdx = polyline.length - 2;
      if (segIdx < 0) segIdx = 0;

      final segStart = cumMeters[segIdx];
      final segEnd = cumMeters[segIdx + 1];
      final segLen = segEnd - segStart;
      final localProgress = segLen > 0 ? (targetMeters - segStart) / segLen : 0.0;

      final lat = polyline[segIdx].latitude +
          localProgress * (polyline[segIdx + 1].latitude - polyline[segIdx].latitude);
      final lng = polyline[segIdx].longitude +
          localProgress * (polyline[segIdx + 1].longitude - polyline[segIdx].longitude);

      // Estimate speed (average ~40 km/h = 11 m/s for metro)
      final speed = 11.0;

      samples.add(RecordedGpsSample(
        secondsElapsed: t,
        latitude: lat,
        longitude: lng,
        altitude: 900, // Bengaluru altitude
        speed: speed,
        bearing: 90, // TODO: Calculate actual bearing
        horizontalAccuracy: 15, // Good GPS
        verticalAccuracy: 3,
      ));
    }

    return samples;
  }

  /// Generate synthetic accelerometer data.
  List<TimestampedSample> _generateSyntheticAccelerometer(List<RecordedGpsSample> gpsData) {
    final samples = <TimestampedSample>[];
    if (gpsData.isEmpty) return samples;

    const imuInterval = 0.01; // 100 Hz
    final duration = gpsData.last.secondsElapsed;

    for (double t = 0; t <= duration; t += imuInterval) {
      // Gravity-dominated reading (device roughly level)
      samples.add(TimestampedSample(
        secondsElapsed: t,
        x: 0.1 * (t % 1.0 - 0.5), // Small noise
        y: 0.1 * ((t + 0.3) % 1.0 - 0.5),
        z: 9.81, // Gravity
      ));
    }

    return samples;
  }

  /// Generate synthetic gyroscope data.
  List<TimestampedSample> _generateSyntheticGyroscope(List<RecordedGpsSample> gpsData) {
    final samples = <TimestampedSample>[];
    if (gpsData.isEmpty) return samples;

    const imuInterval = 0.01; // 100 Hz
    final duration = gpsData.last.secondsElapsed;

    for (double t = 0; t <= duration; t += imuInterval) {
      // Near-zero angular velocity (stable device)
      samples.add(TimestampedSample(
        secondsElapsed: t,
        x: 0.01 * (t % 0.5 - 0.25), // Small drift
        y: 0.01 * ((t + 0.2) % 0.5 - 0.25),
        z: 0.01 * ((t + 0.4) % 0.5 - 0.25),
      ));
    }

    return samples;
  }
}
