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
import 'ekf_orchestrator.dart';
import 'route_geometry.dart';

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

  /// Replay from CSV logs (ground truth + sensor data)
  logReplay,
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
  final LatLng? rawGpsPosition; // Raw GPS for ghost marker during dropout
  final double trueProgressMeters;
  final double? gpsProgressMeters;
  final double? ekfProgressMeters;
  final double speedMps;
  final double? ekfSigmaS; // EKF position uncertainty
  final double? ekfSigmaV; // EKF velocity uncertainty
  final bool gpsAvailable;
  final bool isZuptCandidate;
  final bool isAtStation;
  final SimulatedMotionState motionState;
  final TestRouteStation? currentStation;
  final TestRouteStation? nextStation;
  final double? metersToNext;
  final List<LatLng> routePolyline;
  final List<LatLng> groundTruthPolyline; // Full GPS log path (purple line)
  final List<TestRouteStation> allStations;
  final List<LatLng>
  ekfSnappedStations; // EKF-detected station positions (purple dots)
  final List<LatLng> zuptPositions; // ZUPT event locations (green dots)
  final String? currentLegName;
  final LegType? currentLegType;
  final bool ekfDegraded; // Whether EKF is in degraded mode

  const EkfTestVisualization({
    required this.truePosition,
    this.gpsPosition,
    this.ekfPosition,
    this.rawGpsPosition,
    required this.trueProgressMeters,
    this.gpsProgressMeters,
    this.ekfProgressMeters,
    required this.speedMps,
    this.ekfSigmaS,
    this.ekfSigmaV,
    required this.gpsAvailable,
    required this.isZuptCandidate,
    required this.isAtStation,
    required this.motionState,
    this.currentStation,
    this.nextStation,
    this.metersToNext,
    required this.routePolyline,
    this.groundTruthPolyline = const [],
    required this.allStations,
    this.ekfSnappedStations = const [],
    this.zuptPositions = const [],
    this.currentLegName,
    this.currentLegType,
    this.ekfDegraded = false,
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

enum EkfTestLogCategory { gps, imu, zupt, snap, station, ekf, control, alarm }

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
  EkfOrchestrator? _ekfOrchestrator;
  RouteGeometry? _routeGeometry;
  bool _isActive = false;
  StreamSubscription? _tickSub;
  StreamSubscription? _logSub;
  StreamSubscription? _accelSub; // Raw IMU from engine
  StreamSubscription? _gyroSub;  // Raw IMU from engine
  StreamSubscription? _imuSub;   // Combined IMU samples

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
  // ignore: unused_field - Reserved for future EKF state diffing
  EkfStateSnapshot? _lastEkfState;
  TestRouteStation? _lastStation;
  bool _lastGpsAvailable = true;
  int _zuptEventCount = 0;
  int _stationSnapCount = 0;
  int _tickCount = 0; // Global tick counter for diagnostic logging

  // Visualization tracking - positions for map markers
  final List<LatLng> _zuptPositions = [];
  final List<LatLng> _ekfSnappedStations = [];
  LatLng? _lastRawGpsPosition;
  DateTime? _lastZuptLogTime;

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
    'gpsDropouts':
        _logs
            .where(
              (l) =>
                  l.category == EkfTestLogCategory.gps &&
                  l.message.contains('dropout'),
            )
            .length,
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
      TestScenario.logReplay => TestRouteId.nallurHalliToVijayanagar,
      TestScenario.custom => TestRouteId.majesticToNallurHalli,
    };

    await _engine!.loadTestRoute(routeId);

    // Subscribe to engine events
    _tickSub = _engine!.tickStream.listen(_onTick);
    _logSub = _engine!.logStream.listen(_onEngineLog);

    _isActive = true;
    _resetStatistics();

    _log(
      EkfTestLogCategory.control,
      'EVENT',
      'Initialized scenario: ${scenario.name}',
      {
        'route': routeId.name,
        'gpsMode': _gpsDropoutMode.name,
        'warpFactor': _warpFactor,
      },
    );
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

  /// Load a log for replay.
  Future<void> loadLog(String logDirectory, TestRouteId routeId) async {
    _scenario = TestScenario.logReplay;
    _engine = ImuReplayEngineV2();
    _engine!.logVerbosity = logVerbosity;

    await _engine!.loadFromLog(logDirectory, routeId);

    // Initialize EKF with route geometry
    _initializeEkf();
    
    // Subscribe to raw IMU streams for high-frequency EKF updates
    _subscribeToEngineImu();

    // Subscribe to engine events
    _tickSub = _engine!.tickStream.listen(_onTick);
    _logSub = _engine!.logStream.listen(_onEngineLog);

    _isActive = true;
    _resetStatistics();

    _log(
      EkfTestLogCategory.control,
      'EVENT',
      'Loaded log replay: ${routeId.name}',
      {'directory': logDirectory},
    );
  }

  /// Load captured real route replay (JSON + Log).
  Future<void> loadCapturedReplay() async {
    _scenario = TestScenario.logReplay;
    _engine = ImuReplayEngineV2();
    _engine!.logVerbosity = logVerbosity;

    await _engine!.loadCapturedRouteReplay(
      'assets/ekf_test_routes/captured_route.json',
      'assets/logs/Nallur_to_Vijaynagar',
    );

    // Initialize EKF with route geometry
    _initializeEkf();
    
    // Subscribe to raw IMU streams for high-frequency EKF updates
    _subscribeToEngineImu();

    // Subscribe to engine events
    _tickSub = _engine!.tickStream.listen(_onTick);
    _logSub = _engine!.logStream.listen(_onEngineLog);

    _isActive = true;
    _resetStatistics();

    _log(EkfTestLogCategory.control, 'EVENT', 'Loaded captured real replay');
  }

  /// Initialize EKF orchestrator with route from engine.
  void _initializeEkf() {
    final route = _engine?.route;
    if (route == null || route.fullPolyline.isEmpty) {
      _log(EkfTestLogCategory.ekf, 'ERROR', 'Cannot init EKF: no route');
      return;
    }

    // Create RouteGeometry from polyline
    _routeGeometry = RouteGeometry.fromPoints(route.fullPolyline);

    // Create EKF Orchestrator with logging
    _ekfOrchestrator = EkfOrchestrator(
      route: _routeGeometry!,
      logVerbosity: logVerbosity,
      onLog: (tag, message, data) {
        // Route orchestrator logs through our logging system
        _log(EkfTestLogCategory.ekf, tag, '[EKF] $message', data);
      },
    );

    // Configure station context for metro leg
    final stationMeters = route.allStations
        .map((s) => s.cumulativeMeters)
        .toList();
    _ekfOrchestrator!.setStationContext(
      stationMeters: stationMeters,
      isMetroLeg: true, // Metro route for now
    );

    // Hook station snap callback
    _ekfOrchestrator!.onStationSnapConfirmed = _onEkfStationSnap;

    _log(EkfTestLogCategory.ekf, 'EVENT', 'EKF initialized', {
      'routeLength': _routeGeometry!.totalLengthMeters.toStringAsFixed(0),
      'stations': stationMeters.length,
      'stationMeters': stationMeters.take(5).map((m) => m.toStringAsFixed(0)).join(', ') + (stationMeters.length > 5 ? '...' : ''),
    });
  }
  
  /// Subscribe to raw IMU streams from the engine for high-frequency EKF updates.
  /// This is critical for proper dead reckoning - IMU must be fed at ~50Hz, not tick rate.
  void _subscribeToEngineImu() {
    if (_engine == null || _ekfOrchestrator == null) return;
    
    // Cancel existing subscriptions
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _imuSub?.cancel();

    // Prefer combined IMU stream (deterministic ordering)
    _imuSub = _engine!.imuSampleStream.listen((sample) {
      _ekfOrchestrator!.onImuSample(sample);
    });
    _log(EkfTestLogCategory.ekf, 'EVENT', 'Subscribed to combined IMU stream');
  }

  /// Called when EKF confirms a station snap (for purple dots).
  void _onEkfStationSnap(StationSnapConfirmed snap) {
    // Project stationMeters onto route to get position for purple dot
    final route = _engine?.route;
    if (route != null && route.fullPolyline.isNotEmpty) {
      final pos = _projectMetersToPosition(snap.stationMeters, route);
      if (pos != null) {
        _ekfSnappedStations.add(pos);
      }
    }

    _stationSnapCount++;
    _log(EkfTestLogCategory.snap, 'EVENT', 'EKF station snap confirmed', {
      'stationIndex': snap.stationIndex,
      'stationMeters': snap.stationMeters.toStringAsFixed(0),
      'sigmaS': snap.sigmaS.toStringAsFixed(1),
    });
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
      case TestScenario.logReplay:
        _gpsDropoutMode = GpsDropoutMode.normal;
        _warpFactor = 1.0;
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
    _zuptPositions.clear();
    _ekfSnappedStations.clear();
    _lastRawGpsPosition = null;
    _lastZuptLogTime = null;
    
    // Reset EKF orchestrator if exists
    _ekfOrchestrator?.reset();
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
    _log(
      EkfTestLogCategory.control,
      'INFO',
      'Seeked to ${seconds.toStringAsFixed(1)}s',
    );
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
    // Update EKF elapsed time (convert seconds to Duration)
    final tickDuration = Duration(
      microseconds: (tick.elapsedSeconds * 1e6).round(),
    );

    // ─────────────────────────────────────────────────────────────────────
    // 1. IMU is now fed via raw stream subscription (_subscribeToEngineImu)
    //    This ensures ~50Hz IMU updates, not sparse tick updates.
    // ─────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────
    // 2. FEED GPS TO EKF WHEN AVAILABLE, OR NOTIFY UNAVAILABLE
    // ─────────────────────────────────────────────────────────────────────
    if (_ekfOrchestrator != null) {
      if (tick.gpsAvailable && tick.gpsPosition != null) {
        final gpsFix = GpsFix(
          lat: tick.gpsPosition!.latitude,
          lng: tick.gpsPosition!.longitude,
          accuracyMeters: tick.gpsAccuracy ?? 15.0,
          speedMps: tick.speedMps,
          timestamp: tickDuration,
        );
        _ekfOrchestrator!.onGpsFixAuto(gpsFix);
      } else {
        // Notify orchestrator that GPS is unavailable for this tick
        // This allows GPS degradation detector to track fix timeout
        _ekfOrchestrator!.onGpsUnavailable(tickDuration);
      }
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. GET EKF STATE FOR VISUALIZATION
    // ─────────────────────────────────────────────────────────────────────
    LatLng? ekfPosition;
    double? ekfProgressMeters;
    double ekfVelocityMps = tick.speedMps; // Fallback to GPS speed
    
    if (_ekfOrchestrator != null && _routeGeometry != null) {
      final ekfState = _ekfOrchestrator!.publicState;
      ekfProgressMeters = ekfState.s;
      ekfVelocityMps = ekfState.v;
      
      // Project EKF progress (meters along route) to LatLng for ghost marker
      if (!ekfState.s.isNaN && ekfState.s >= 0) {
        ekfPosition = _routeGeometry!.positionAt(ekfState.s);
      }
    }
    
    // ─────────────────────────────────────────────────────────────────────
    // 3.5 DETAILED TICK COMPARISON LOGGING
    // - Every 50 ticks when GPS available
    // - Every 10 ticks when GPS unavailable (to debug DR)
    // ─────────────────────────────────────────────────────────────────────
    _tickCount++;
    final logInterval = tick.gpsAvailable ? 50 : 10; // More frequent in dropout
    if (_tickCount % logInterval == 0 && _ekfOrchestrator != null) {
      final ekfState = _ekfOrchestrator!.publicState;
      final trueProgress = tick.progressMeters;
      final ekfS = ekfState.s;
      final error = ekfS.isNaN ? double.nan : (ekfS - trueProgress);
      final isDegraded = _ekfOrchestrator!.gpsDegraded || ekfState.mode == EkfMode.degraded;
      final predEnabled = _ekfOrchestrator!.predictionEnabled;
      
      _log(EkfTestLogCategory.ekf, 'COMPARE', 
        '📊 tick $_tickCount: true=${trueProgress.toStringAsFixed(0)} ekf=${ekfS.toStringAsFixed(0)} err=${error.toStringAsFixed(0)} v=${ekfState.v.toStringAsFixed(2)} σs=${ekfState.sigmaS.toStringAsFixed(0)} mode=${ekfState.mode.name} degraded=$isDegraded gps=${tick.gpsAvailable} pred=$predEnabled', {
        'tick': _tickCount,
        'trueProgress': trueProgress.toStringAsFixed(0),
        'ekfProgress': ekfS.toStringAsFixed(0),
        'error': error.toStringAsFixed(0),
        'velocity': ekfState.v.toStringAsFixed(2),
        'sigmaS': ekfState.sigmaS.toStringAsFixed(0),
        'sigmaV': ekfState.sigmaV.toStringAsFixed(2),
        'mode': ekfState.mode.name,
        'degraded': isDegraded,
        'gpsAvailable': tick.gpsAvailable,
        'bias': ekfState.biasA.toStringAsFixed(4),
        'predictionEnabled': predEnabled,
      });
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. INJECT STREAMS FOR LEGACY TRACKINGSERVICE (if needed)
    // ─────────────────────────────────────────────────────────────────────
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

    if (injectImu) {
      _accelController.add(
        AccelerometerEvent(
          tick.accelX,
          tick.accelY,
          tick.accelZ,
          DateTime.now(),
        ),
      );
      _gyroController.add(
        GyroscopeEvent(tick.gyroX, tick.gyroY, tick.gyroZ, DateTime.now()),
      );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. TRACK GPS STATE CHANGES
    // ─────────────────────────────────────────────────────────────────────
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

    // ─────────────────────────────────────────────────────────────────────
    // 6. TRACK STATION ARRIVALS (from log)
    // ─────────────────────────────────────────────────────────────────────
    if (tick.lastStation != null && tick.lastStation != _lastStation) {
      _lastStation = tick.lastStation;
      _log(
        EkfTestLogCategory.station,
        'EVENT',
        'Arrived at: ${tick.lastStation!.name}',
        {
          'cumulativeMeters': tick.lastStation!.cumulativeMeters
              .toStringAsFixed(0),
          'elapsed': tick.elapsedSeconds.toStringAsFixed(0),
        },
      );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6.5 LOG WHEN ENGINE SAYS WE'RE AT STATION (debug ZUPT)
    // ─────────────────────────────────────────────────────────────────────
    if (tick.isAtStation && _ekfOrchestrator != null) {
      final ekfState = _ekfOrchestrator!.publicState;
      final accelVar = _ekfOrchestrator!.currentAccelVariance;
      final gyroVar = _ekfOrchestrator!.currentGyroVariance;
      final ekfMotion = _ekfOrchestrator!.currentMotionState;
      _log(EkfTestLogCategory.zupt, 'STATION_STOP',
        '🚉 Engine at station: ${tick.lastStation?.name ?? "unknown"}', {
        'simSpeed': tick.speedMps.toStringAsFixed(2),
        'simMotion': tick.motionState.name,
        'ekfMotion': ekfMotion.name,  // <-- What EKF thinks motion is
        'accelVar': accelVar.toStringAsExponential(2),  // <-- Current variance
        'gyroVar': gyroVar.toStringAsExponential(2),
        'ekfV': ekfState.v.toStringAsFixed(2),
        'ekfMode': ekfState.mode.name,
        'gpsAvailable': tick.gpsAvailable,
        'predictionEnabled': _ekfOrchestrator!.predictionEnabled,
      });

      // During GPS dropout, force a ZUPT on station dwell to reduce drift.
      if (!tick.gpsAvailable && tick.speedMps.abs() < 0.3) {
        _ekfOrchestrator!.forceZupt(tickDuration, source: 'station_dwell');
      }
    }
    
    // ─────────────────────────────────────────────────────────────────────
    // 7. TRACK ZUPT FROM EKF (not primitive speed threshold)
    // ─────────────────────────────────────────────────────────────────────
    bool ekfZuptActive = false;
    if (_ekfOrchestrator != null) {
      final ekfState = _ekfOrchestrator!.publicState;
      // EKF detects ZUPT when velocity is very low and uncertainty is low
      // NOTE: Don't add markers for every ZUPT - only station snaps are meaningful
      ekfZuptActive = ekfState.v.abs() < 0.3 && ekfState.sigmaV < 1.0;
      
      if (ekfZuptActive && ekfPosition != null) {
        final now = DateTime.now();
        if (_lastZuptLogTime == null ||
            now.difference(_lastZuptLogTime!).inMilliseconds > 1000) {
          _lastZuptLogTime = now;
          _zuptEventCount++;
          // Don't add to _zuptPositions - these clutter the map with spurious markers
          // _zuptPositions.add(ekfPosition);  // DISABLED: causes ghost marker spam
          _log(EkfTestLogCategory.zupt, 'EVENT', 'EKF ZUPT detected', {
            'ekfVelocity': ekfState.v.toStringAsFixed(2),
            'sigmaV': ekfState.sigmaV.toStringAsFixed(2),
            'position': '${ekfPosition.latitude.toStringAsFixed(5)}, ${ekfPosition.longitude.toStringAsFixed(5)}',
          });
        }
      }
    }

    // Track raw GPS position for ghost marker comparison
    if (tick.gpsPosition != null) {
      _lastRawGpsPosition = tick.gpsPosition;
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. BUILD VISUALIZATION WITH EKF STATE
    // ─────────────────────────────────────────────────────────────────────
    double? ekfSigmaS;
    double? ekfSigmaV;
    bool ekfDegraded = false;
    
    if (_ekfOrchestrator != null) {
      final ekfState = _ekfOrchestrator!.publicState;
      ekfSigmaS = ekfState.sigmaS;
      ekfSigmaV = ekfState.sigmaV;
      ekfDegraded = _ekfOrchestrator!.gpsDegraded;
    }
    
    final viz = EkfTestVisualization(
      truePosition: tick.position,  // Ground truth (snapped to route)
      gpsPosition: tick.gpsPosition,  // Raw GPS from log
      ekfPosition: ekfPosition,  // EKF estimated position (ghost marker)
      rawGpsPosition: _lastRawGpsPosition,
      trueProgressMeters: tick.progressMeters,
      gpsProgressMeters: tick.gpsAvailable ? tick.progressMeters : null,
      ekfProgressMeters: ekfProgressMeters,  // EKF estimated progress
      speedMps: ekfVelocityMps,  // EKF velocity (not GPS speed)
      ekfSigmaS: ekfSigmaS,
      ekfSigmaV: ekfSigmaV,
      gpsAvailable: tick.gpsAvailable,
      isZuptCandidate: ekfZuptActive,  // From EKF, not primitive threshold
      isAtStation: tick.isAtStation,
      motionState: tick.motionState,
      currentStation: tick.lastStation,
      nextStation: tick.nextStation,
      metersToNext: tick.metersToNextStation,
      routePolyline: _engine?.route?.fullPolyline ?? [],
      groundTruthPolyline: _engine?.route?.groundTruthPolyline ?? [],
      allStations: _engine?.route?.allStations ?? [],
      ekfSnappedStations: List.unmodifiable(_ekfSnappedStations),
      zuptPositions: List.unmodifiable(_zuptPositions),
      currentLegName: tick.currentLeg?.name,
      currentLegType: tick.currentLeg?.type,
      ekfDegraded: ekfDegraded,
    );

    onVisualizationUpdate?.call(viz);

    // ─────────────────────────────────────────────────────────────────────
    // 9. PERIODIC EKF STATE LOGGING + GPS vs EKF COMPARISON
    // ─────────────────────────────────────────────────────────────────────
    if (_ekfOrchestrator != null && logVerbosity >= 1) {
      final ekfState = _ekfOrchestrator!.publicState;
      // Log every 5 seconds at verbosity 2, or every second at verbosity 3
      final logPeriod = logVerbosity >= 3 ? 10 : 50;
      if ((tick.elapsedSeconds * 10).round() % logPeriod == 0) {
        // Calculate GPS progress for comparison
        double? gpsProgress;
        if (tick.gpsAvailable && tick.gpsPosition != null && _routeGeometry != null) {
          gpsProgress = _routeGeometry!.projectLatLng(
            tick.gpsPosition!.latitude, 
            tick.gpsPosition!.longitude,
          );
        }
        
        final errorM = (gpsProgress != null && !ekfState.s.isNaN)
            ? (ekfState.s - gpsProgress).abs().toStringAsFixed(1)
            : 'N/A';
        
        _log(EkfTestLogCategory.ekf, 'COMPARE', 'GPS vs EKF', {
          'ekf_s': ekfState.s.toStringAsFixed(0),
          'gps_s': gpsProgress?.toStringAsFixed(0) ?? 'N/A',
          'error_m': errorM,
          'ekf_v': ekfState.v.toStringAsFixed(2),
          'gps_v': tick.speedMps.toStringAsFixed(2),
          'σs': ekfState.sigmaS.toStringAsFixed(1),
          'σv': ekfState.sigmaV.toStringAsFixed(2),
          'mode': ekfState.mode.name,
          'gps_avail': tick.gpsAvailable,
          'pred_enabled': _ekfOrchestrator!.predictionEnabled,
        });
      }
    }
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
  // External EKF State Injection (Legacy - for manual testing)
  // ─────────────────────────────────────────────────────────────────────────

  /// Called by external code to report EKF state for logging/visualization.
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
      lastSnappedStationIndex: null,
      lastSnappedStationName: null,
    );

    _lastEkfState = snapshot;
    onEkfStateUpdate?.call(snapshot);

    if (logVerbosity >= 3) {
      _log(EkfTestLogCategory.ekf, 'DEBUG', 'EKF state', snapshot.toJson());
    }
  }

  /// Project meters along route to LatLng position.
  LatLng? _projectMetersToPosition(double meters, TestRoute route) {
    final polyline = route.fullPolyline;
    final cumMeters = route.fullCumulativeMeters;
    if (polyline.isEmpty || cumMeters.isEmpty) return null;

    // Find segment containing the meters value
    for (int i = 0; i < cumMeters.length - 1; i++) {
      if (meters >= cumMeters[i] && meters <= cumMeters[i + 1]) {
        final segmentLen = cumMeters[i + 1] - cumMeters[i];
        if (segmentLen <= 0) return polyline[i];

        final t = (meters - cumMeters[i]) / segmentLen;
        final p1 = polyline[i];
        final p2 = polyline[i + 1];
        return LatLng(
          p1.latitude + (p2.latitude - p1.latitude) * t,
          p1.longitude + (p2.longitude - p1.longitude) * t,
        );
      }
    }

    // Beyond route end - return last point
    return polyline.last;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Logging
  // ─────────────────────────────────────────────────────────────────────────

  void _log(
    EkfTestLogCategory category,
    String level,
    String message, [
    Map<String, dynamic>? data,
  ]) {
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

    onLogEntry?.call(entry);

    // Also print to console in debug mode
    // Print EVENT/COMPARE/MODE/ZUPT/STATION_STOP level always, and PIPELINE/IMU for detailed EKF debugging
    if (kDebugMode) {
      if (level == 'EVENT' || level == 'COMPARE' || level == 'MODE' || level == 'ZUPT' || level == 'STATION_STOP' || level == 'PIPELINE' || level == 'IMU' || level == 'PHYSICS') {
        debugPrint(entry.toColoredString());
      }
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
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _imuSub?.cancel();
    _engine?.dispose();
    _gpsController.close();
    _accelController.close();
    _gyroController.close();
    _isActive = false;
  }
}
