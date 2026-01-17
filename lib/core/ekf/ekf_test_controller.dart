// EKF Test Controller - Wires ImuReplayEngineV2 into Dashboard
//
// Provides:
// - Stream injection for GPS, accelerometer, gyroscope to TrackingService
// - Dashboard integration with visualization callbacks
// - Detailed logging for ZUPT, station snaps, and EKF state
// - Test scenario presets (GPS dropout patterns, station stopping, etc.)

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

import 'imu_replay_engine_v2.dart';
import 'ekf_types.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TEST SCENARIOS
// ─────────────────────────────────────────────────────────────────────────────

/// Predefined test scenarios for different testing objectives.
enum TestScenario {
  /// Normal metro ride with GPS available (baseline)
  metroWithGps,

  /// Metro ride with complete GPS dropout - tests pure IMU/EKF
  metroGpsDropout,

  /// Metro ride with tunnel-style dropout (GPS only near stations)
  metroTunnelDropout,

  /// Non-metro route with good GPS (validates non-metro leg handling)
  nonMetroNormalGps,

  /// Mixed route: metro + non-metro with varying GPS
  multiModalRoute,

  /// Stress test: intermittent GPS with random dropouts
  intermittentGps,

  /// Urban canyon: degraded GPS accuracy simulation
  urbanCanyonGps,

  /// Custom configuration (use setters for fine control)
  custom,
}

/// Result of EKF state query for logging/visualization.
class EkfStateSnapshot {
  final double elapsedSeconds;
  final double progressMeters;
  final double velocityMps;
  final double sigmaPosition;
  final double sigmaVelocity;
  final EkfMode mode;
  final MotionState motionState;
  final bool zuptActive;
  final int? lastSnappedStationIndex;
  final String? lastSnappedStationName;

  const EkfStateSnapshot({
    required this.elapsedSeconds,
    required this.progressMeters,
    required this.velocityMps,
    required this.sigmaPosition,
    required this.sigmaVelocity,
    required this.mode,
    required this.motionState,
    required this.zuptActive,
    this.lastSnappedStationIndex,
    this.lastSnappedStationName,
  });

  Map<String, dynamic> toJson() => {
        'elapsed': elapsedSeconds.toStringAsFixed(1),
        'progress': progressMeters.toStringAsFixed(0),
        'velocity': velocityMps.toStringAsFixed(2),
        'sigmaS': sigmaPosition.toStringAsFixed(1),
        'sigmaV': sigmaVelocity.toStringAsFixed(2),
        'mode': mode.name,
        'motion': motionState.name,
        'zupt': zuptActive,
        if (lastSnappedStationName != null) 'station': lastSnappedStationName,
      };
}

/// Visualization data for the dashboard.
class EkfTestVisualization {
  final LatLng truePosition;
  final LatLng? gpsPosition;
  final LatLng? ekfPosition; // Projected from EKF progress
  final double trueProgressMeters;
  final double? gpsProgressMeters;
  final double? ekfProgressMeters;
  final double speedMps;
  final bool gpsAvailable;
  final bool isZuptCandidate;
  final bool isAtStation;
  final SimulatedMotionState motionState;
  final TestRouteStation? currentStation;
  final TestRouteStation? nextStation;
  final double? metersToNext;
  final List<LatLng> routePolyline;
  final List<TestRouteStation> allStations;
  final String? currentLegName;
  final LegType? currentLegType;

  const EkfTestVisualization({
    required this.truePosition,
    this.gpsPosition,
    this.ekfPosition,
    required this.trueProgressMeters,
    this.gpsProgressMeters,
    this.ekfProgressMeters,
    required this.speedMps,
    required this.gpsAvailable,
    required this.isZuptCandidate,
    required this.isAtStation,
    required this.motionState,
    this.currentStation,
    this.nextStation,
    this.metersToNext,
    required this.routePolyline,
    required this.allStations,
    this.currentLegName,
    this.currentLegType,
  });
}

/// Log entry for EKF test events.
class EkfTestLogEntry {
  final DateTime timestamp;
  final double elapsedSeconds;
  final EkfTestLogCategory category;
  final String level;
  final String message;
  final Map<String, dynamic>? data;

  const EkfTestLogEntry({
    required this.timestamp,
    required this.elapsedSeconds,
    required this.category,
    required this.level,
    required this.message,
    this.data,
  });

  @override
  String toString() {
    final cat = category.name.toUpperCase().padRight(8);
    final dataStr = data != null ? ' $data' : '';
    return '[${elapsedSeconds.toStringAsFixed(1).padLeft(7)}s] [$cat] $level: $message$dataStr';
  }

  String toColoredString() {
    final emoji = switch (category) {
      EkfTestLogCategory.gps => gpsAvailable ? '📡' : '🚫',
      EkfTestLogCategory.imu => '📊',
      EkfTestLogCategory.zupt => '⏹️',
      EkfTestLogCategory.snap => '📍',
      EkfTestLogCategory.station => '🚉',
      EkfTestLogCategory.ekf => '🧮',
      EkfTestLogCategory.control => '🎮',
      EkfTestLogCategory.alarm => '🔔',
    };
    return '$emoji $this';
  }

  bool get gpsAvailable => data?['gpsAvailable'] == true;
}

enum EkfTestLogCategory {
  gps,
  imu,
  zupt,
  snap,
  station,
  ekf,
  control,
  alarm,
}

// ─────────────────────────────────────────────────────────────────────────────
// EKF TEST CONTROLLER
// ─────────────────────────────────────────────────────────────────────────────

/// Controller that wires ImuReplayEngineV2 into the dashboard and tracking system.
class EkfTestController {
  EkfTestController();

  // ─────────────────────────────────────────────────────────────────────────
  // Configuration
  // ─────────────────────────────────────────────────────────────────────────

  /// Current test scenario.
  TestScenario _scenario = TestScenario.custom;
  TestScenario get scenario => _scenario;

  /// Time warp factor.
  double _warpFactor = 1.0;
  double get warpFactor => _warpFactor;
  set warpFactor(double value) {
    _warpFactor = value.clamp(0.1, 20.0);
    _engine?.warpFactor = _warpFactor;
  }

  /// GPS dropout mode.
  GpsDropoutMode _gpsDropoutMode = GpsDropoutMode.normal;
  GpsDropoutMode get gpsDropoutMode => _gpsDropoutMode;
  set gpsDropoutMode(GpsDropoutMode mode) {
    _gpsDropoutMode = mode;
    _engine?.gpsDropoutMode = mode;
    _log(EkfTestLogCategory.control, 'INFO', 'GPS dropout mode: ${mode.name}');
  }

  /// Whether to inject IMU data into the tracking system.
  bool injectImu = true;

  /// Whether to inject GPS data into the tracking system.
  bool injectGps = true;

  /// Log verbosity (0=none, 1=events, 2=detailed, 3=all).
  int logVerbosity = 2;

  // ─────────────────────────────────────────────────────────────────────────
  // Engine & State
  // ─────────────────────────────────────────────────────────────────────────

  ImuReplayEngineV2? _engine;
  bool _isActive = false;
  StreamSubscription? _tickSub;
  StreamSubscription? _logSub;

  // External stream injection (for TrackingService)
  final _gpsController = StreamController<Position>.broadcast();
  final _accelController = StreamController<AccelerometerEvent>.broadcast();
  final _gyroController = StreamController<GyroscopeEvent>.broadcast();

  /// GPS stream for injection into LocationManager.
  Stream<Position> get gpsStream => _gpsController.stream;

  /// Accelerometer stream for injection into SensorFusionManager.
  Stream<AccelerometerEvent> get accelerometerStream => _accelController.stream;

  /// Gyroscope stream for injection into SensorFusionManager.
  Stream<GyroscopeEvent> get gyroscopeStream => _gyroController.stream;

  // Visualization callbacks
  void Function(EkfTestVisualization)? onVisualizationUpdate;
  void Function(EkfTestLogEntry)? onLogEntry;
  void Function(EkfStateSnapshot)? onEkfStateUpdate;

  // State tracking
  final List<EkfTestLogEntry> _logs = [];
  static const int _maxLogs = 500;
  // ignore: unused_field - Reserved for future EKF state diffing
  EkfStateSnapshot? _lastEkfState;
  TestRouteStation? _lastStation;
  bool _lastGpsAvailable = true;
  int _zuptEventCount = 0;
  int _stationSnapCount = 0;

  // ─────────────────────────────────────────────────────────────────────────
  // Public Properties
  // ─────────────────────────────────────────────────────────────────────────

  bool get isActive => _isActive;
  bool get isPlaying => _engine?.isPlaying ?? false;
  double get elapsedSeconds => _engine?.elapsedSeconds ?? 0.0;
  double get progress => _engine?.progress ?? 0.0;
  double get progressMeters => _engine?.progressMeters ?? 0.0;
  TestRoute? get route => _engine?.route;
  List<EkfTestLogEntry> get logs => List.unmodifiable(_logs);

  /// Statistics for the current test run.
  Map<String, dynamic> get statistics => {
        'zuptEvents': _zuptEventCount,
        'stationSnaps': _stationSnapCount,
        'gpsDropouts': _logs.where((l) =>
            l.category == EkfTestLogCategory.gps &&
            l.message.contains('dropout')).length,
        'elapsedSeconds': elapsedSeconds.toStringAsFixed(1),
        'progressMeters': progressMeters.toStringAsFixed(0),
        'scenario': _scenario.name,
      };

  // ─────────────────────────────────────────────────────────────────────────
  // Initialization
  // ─────────────────────────────────────────────────────────────────────────

  /// Initialize with a test scenario.
  Future<void> initialize(TestScenario scenario) async {
    _scenario = scenario;
    _engine = ImuReplayEngineV2();
    _engine!.logVerbosity = logVerbosity;

    // Configure based on scenario
    _configureForScenario(scenario);

    // Load appropriate route
    final routeId = switch (scenario) {
      TestScenario.metroWithGps ||
      TestScenario.metroGpsDropout ||
      TestScenario.metroTunnelDropout => TestRouteId.majesticToNallurHalli,
      TestScenario.nonMetroNormalGps => TestRouteId.koramangalaToIndiranagar,
      TestScenario.multiModalRoute => TestRouteId.mgRoadToAirport,
      TestScenario.intermittentGps ||
      TestScenario.urbanCanyonGps => TestRouteId.rajajinargarToNallurHalli,
      TestScenario.custom => TestRouteId.majesticToNallurHalli,
    };

    await _engine!.loadTestRoute(routeId);

    // Subscribe to engine events
    _tickSub = _engine!.tickStream.listen(_onTick);
    _logSub = _engine!.logStream.listen(_onEngineLog);

    _isActive = true;
    _resetStatistics();

    _log(EkfTestLogCategory.control, 'EVENT',
        'Initialized scenario: ${scenario.name}', {
      'route': routeId.name,
      'gpsMode': _gpsDropoutMode.name,
      'warpFactor': _warpFactor,
    });
  }

  /// Load a specific route for custom testing.
  Future<void> loadRoute(TestRouteId routeId) async {
    if (_engine == null) {
      _engine = ImuReplayEngineV2();
    }
    await _engine!.loadTestRoute(routeId);
    _resetStatistics();

    _log(EkfTestLogCategory.control, 'INFO', 'Loaded route: ${routeId.name}');
  }

  void _configureForScenario(TestScenario scenario) {
    switch (scenario) {
      case TestScenario.metroWithGps:
        _gpsDropoutMode = GpsDropoutMode.normal;
        _warpFactor = 1.0;
        break;
      case TestScenario.metroGpsDropout:
        _gpsDropoutMode = GpsDropoutMode.completeDropout;
        _warpFactor = 2.0; // Faster for testing
        break;
      case TestScenario.metroTunnelDropout:
        _gpsDropoutMode = GpsDropoutMode.tunnelSimulation;
        _warpFactor = 1.5;
        break;
      case TestScenario.nonMetroNormalGps:
        _gpsDropoutMode = GpsDropoutMode.normal;
        _warpFactor = 1.0;
        break;
      case TestScenario.multiModalRoute:
        _gpsDropoutMode = GpsDropoutMode.tunnelSimulation;
        _warpFactor = 2.0;
        break;
      case TestScenario.intermittentGps:
        _gpsDropoutMode = GpsDropoutMode.intermittent;
        _warpFactor = 1.5;
        break;
      case TestScenario.urbanCanyonGps:
        _gpsDropoutMode = GpsDropoutMode.urbanCanyon;
        _warpFactor = 1.0;
        break;
      case TestScenario.custom:
        // Keep current settings
        break;
    }

    _engine?.gpsDropoutMode = _gpsDropoutMode;
    _engine?.warpFactor = _warpFactor;
  }

  void _resetStatistics() {
    _zuptEventCount = 0;
    _stationSnapCount = 0;
    _lastStation = null;
    _lastGpsAvailable = true;
    _logs.clear();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Playback Controls
  // ─────────────────────────────────────────────────────────────────────────

  void play() {
    _engine?.play();
    _log(EkfTestLogCategory.control, 'EVENT', 'Playback started', {
      'warpFactor': _warpFactor,
      'gpsMode': _gpsDropoutMode.name,
    });
  }

  void pause() {
    _engine?.pause();
    _log(EkfTestLogCategory.control, 'EVENT', 'Playback paused');
  }

  void stop() {
    _engine?.stop();
    _log(EkfTestLogCategory.control, 'EVENT', 'Playback stopped', statistics);
  }

  void seekTo(double seconds) {
    _engine?.seekTo(seconds);
    _log(EkfTestLogCategory.control, 'INFO',
        'Seeked to ${seconds.toStringAsFixed(1)}s');
  }

  void seekToProgress(double progress) {
    _engine?.seekToProgress(progress);
  }

  /// Toggle GPS dropout mode on/off.
  void toggleGpsDropout() {
    if (_gpsDropoutMode == GpsDropoutMode.normal) {
      gpsDropoutMode = GpsDropoutMode.completeDropout;
    } else {
      gpsDropoutMode = GpsDropoutMode.normal;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Tick Processing
  // ─────────────────────────────────────────────────────────────────────────

  void _onTick(ReplayTickResultV2 tick) {
    // Inject GPS if enabled and available
    if (injectGps && tick.gpsAvailable && tick.gpsPosition != null) {
      final pos = Position(
        latitude: tick.gpsPosition!.latitude,
        longitude: tick.gpsPosition!.longitude,
        altitude: 900,
        speed: tick.speedMps,
        heading: tick.bearing,
        accuracy: tick.gpsAccuracy ?? 15.0,
        altitudeAccuracy: 3.0,
        headingAccuracy: 10.0,
        speedAccuracy: 0.5,
        timestamp: DateTime.now(),
      );
      _gpsController.add(pos);
    }

    // Inject IMU
    if (injectImu) {
      _accelController.add(AccelerometerEvent(
        tick.accelX,
        tick.accelY,
        tick.accelZ,
        DateTime.now(),
      ));
      _gyroController.add(GyroscopeEvent(
        tick.gyroX,
        tick.gyroY,
        tick.gyroZ,
        DateTime.now(),
      ));
    }

    // Track GPS state changes
    if (tick.gpsAvailable != _lastGpsAvailable) {
      _lastGpsAvailable = tick.gpsAvailable;
      if (tick.gpsAvailable) {
        _log(EkfTestLogCategory.gps, 'EVENT', 'GPS restored', {
          'accuracy': tick.gpsAccuracy,
          'dropoutDuration': tick.timeSinceLastGps?.inSeconds,
        });
      } else {
        _log(EkfTestLogCategory.gps, 'EVENT', 'GPS dropout started', {
          'mode': tick.dropoutMode.name,
        });
      }
    }

    // Track station arrivals
    if (tick.lastStation != null && tick.lastStation != _lastStation) {
      _lastStation = tick.lastStation;
      _stationSnapCount++;
      _log(EkfTestLogCategory.station, 'EVENT',
          'Arrived at: ${tick.lastStation!.name}', {
        'cumulativeMeters': tick.lastStation!.cumulativeMeters.toStringAsFixed(0),
        'elapsed': tick.elapsedSeconds.toStringAsFixed(0),
      });
    }

    // Track ZUPT events
    if (tick.isZuptCandidate && tick.zuptDurationSeconds != null) {
      if (tick.zuptDurationSeconds! > 1.0 &&
          (tick.zuptDurationSeconds! % 1.0) < 0.02) {
        // Log every second of ZUPT
        _zuptEventCount++;
        _log(EkfTestLogCategory.zupt, 'DEBUG', 'ZUPT active', {
          'duration': tick.zuptDurationSeconds!.toStringAsFixed(1),
          'atStation': tick.isAtStation,
          'speed': tick.speedMps.toStringAsFixed(2),
        });
      }
    }

    // Build visualization
    final viz = EkfTestVisualization(
      truePosition: tick.position,
      gpsPosition: tick.gpsPosition,
      ekfPosition: null, // TODO: Get from actual EKF
      trueProgressMeters: tick.progressMeters,
      gpsProgressMeters: tick.gpsAvailable ? tick.progressMeters : null,
      ekfProgressMeters: null, // TODO: Get from actual EKF
      speedMps: tick.speedMps,
      gpsAvailable: tick.gpsAvailable,
      isZuptCandidate: tick.isZuptCandidate,
      isAtStation: tick.isAtStation,
      motionState: tick.motionState,
      currentStation: tick.lastStation,
      nextStation: tick.nextStation,
      metersToNext: tick.metersToNextStation,
      routePolyline: _engine?.route?.fullPolyline ?? [],
      allStations: _engine?.route?.allStations ?? [],
      currentLegName: tick.currentLeg?.name,
      currentLegType: tick.currentLeg?.type,
    );

    onVisualizationUpdate?.call(viz);
  }

  void _onEngineLog(ReplayLogEntry entry) {
    // Convert to EkfTestLogEntry
    final category = switch (entry.category) {
      'GPS' => EkfTestLogCategory.gps,
      'IMU' => EkfTestLogCategory.imu,
      'ZUPT' => EkfTestLogCategory.zupt,
      'SNAP' => EkfTestLogCategory.snap,
      'STATION' => EkfTestLogCategory.station,
      'EKF' => EkfTestLogCategory.ekf,
      'CTRL' || 'LOAD' => EkfTestLogCategory.control,
      _ => EkfTestLogCategory.control,
    };

    _log(category, entry.level, entry.message, entry.data);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // External EKF State Injection
  // ─────────────────────────────────────────────────────────────────────────

  /// Called by EKF to report its state for logging/visualization.
  void reportEkfState(EkfPublicState state) {
    final snapshot = EkfStateSnapshot(
      elapsedSeconds: elapsedSeconds,
      progressMeters: state.s,
      velocityMps: state.v,
      sigmaPosition: state.sigmaS,
      sigmaVelocity: state.sigmaV,
      mode: state.mode,
      motionState: state.motion,
      zuptActive: state.v.abs() < 0.1 && state.sigmaV < 0.5,
      lastSnappedStationIndex: null, // TODO
      lastSnappedStationName: null, // TODO
    );

    _lastEkfState = snapshot;
    onEkfStateUpdate?.call(snapshot);

    if (logVerbosity >= 3) {
      _log(EkfTestLogCategory.ekf, 'DEBUG', 'EKF state', snapshot.toJson());
    }
  }

  /// Called when EKF confirms a station snap.
  void reportStationSnap(StationSnapConfirmed snap) {
    _log(EkfTestLogCategory.snap, 'EVENT', 'Station snap confirmed', {
      'stationIndex': snap.stationIndex,
      'stationMeters': snap.stationMeters.toStringAsFixed(0),
      'sigmaS': snap.sigmaS.toStringAsFixed(1),
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Logging
  // ─────────────────────────────────────────────────────────────────────────

  void _log(EkfTestLogCategory category, String level, String message,
      [Map<String, dynamic>? data]) {
    if (logVerbosity == 0) return;
    if (logVerbosity == 1 && level != 'EVENT') return;
    if (logVerbosity == 2 && level == 'DEBUG') return;

    final entry = EkfTestLogEntry(
      timestamp: DateTime.now(),
      elapsedSeconds: elapsedSeconds,
      category: category,
      level: level,
      message: message,
      data: data,
    );

    _logs.add(entry);
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    onLogEntry?.call(entry);

    // Also print to console in debug mode
    if (kDebugMode && level == 'EVENT') {
      debugPrint(entry.toColoredString());
    }
  }

  void clearLogs() {
    _logs.clear();
    _engine?.clearLogs();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Cleanup
  // ─────────────────────────────────────────────────────────────────────────

  void dispose() {
    _tickSub?.cancel();
    _logSub?.cancel();
    _engine?.dispose();
    _gpsController.close();
    _accelController.close();
    _gyroController.close();
    _isActive = false;
  }
}
