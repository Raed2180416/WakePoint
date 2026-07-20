// EKF Test Controller - Wires ImuReplayEngineV2 into Dashboard
//
// Provides:
// - Stream injection for GPS, accelerometer, gyroscope to TrackingService
// - Dashboard integration with visualization callbacks
// - Detailed logging for ZUPT, station snaps, and EKF state
// - Test scenario presets (GPS dropout patterns, station stopping, etc.)

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/core/reachability/reachability.dart';

import 'imu_replay_engine_v2.dart';
import 'ekf_types.dart';
import 'ekf_orchestrator.dart';
import 'ekf_metrics.dart';
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
  final List<LatLng> routePolyline; // Google Maps ground truth (orange)
  final List<LatLng> groundTruthPolyline; // Full GPS log path (purple line)
  final List<LatLng> rawGpsTrail; // Raw GPS fixes as they happen (green)
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
    this.rawGpsTrail = const [],
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

/// Result of the in-sim alarm decision, evaluated against the EKF's estimated
/// progress using the real [AlarmEvaluator].
class EkfAlarmResult {
  /// Event type from the alarm evaluator (e.g. 'destination').
  final String eventType;

  /// Human-readable message from the evaluator.
  final String message;

  /// Sim elapsed time (seconds) when the alarm fired, per EKF progress.
  final double fireElapsedSeconds;

  /// EKF-estimated progress (meters) at fire time.
  final double ekfProgressMeters;

  /// Ground-truth progress (meters) at fire time.
  final double trueProgressMeters;

  /// Total route length (meters).
  final double routeMeters;

  /// Total route duration (seconds), used as the ground-truth arrival time.
  final double routeDurationSeconds;

  const EkfAlarmResult({
    required this.eventType,
    required this.message,
    required this.fireElapsedSeconds,
    required this.ekfProgressMeters,
    required this.trueProgressMeters,
    required this.routeMeters,
    required this.routeDurationSeconds,
  });

  /// Signed EKF position error at fire time (ekf - true), meters.
  /// Positive => EKF ran ahead of reality so the alarm fired early.
  double get leadErrorMeters => ekfProgressMeters - trueProgressMeters;

  /// Seconds of warning the user got: gap between fire time and the true
  /// arrival time (route duration). Positive => fired before true arrival.
  double get leadSeconds => routeDurationSeconds - fireElapsedSeconds;
}

/// Result of the in-sim REACHABILITY decision: the never-late physics upper
/// bound s_max(t) reaching the fire target. This is the load-bearing safety
/// path (independent of the EKF point estimate) — it fires at/before true
/// arrival by construction, so [leadSeconds] must always be >= 0. The gap to
/// true progress ([earlyMeters]) is the (safe) early-firing distance we tighten.
class EkfReachResult {
  /// Sim elapsed time (seconds) when the reachability bound reached the target.
  final double fireElapsedSeconds;

  /// The provable upper-bound arc-progress s_max at fire time (meters).
  final double sMaxMeters;

  /// Ground-truth progress (meters) at fire time.
  final double trueProgressMeters;

  /// Fire target (meters along route) — the destination arc-length.
  final double targetMeters;

  /// Total route duration (seconds) = the ground-truth arrival time.
  final double routeDurationSeconds;

  const EkfReachResult({
    required this.fireElapsedSeconds,
    required this.sMaxMeters,
    required this.trueProgressMeters,
    required this.targetMeters,
    required this.routeDurationSeconds,
  });

  /// Metres the provable cone is ahead of true progress at fire (>= 0). This is
  /// the safe early-firing margin the tightening work aims to shrink.
  double get earlyMeters => sMaxMeters - trueProgressMeters;

  /// Seconds before true arrival that the cone fired. Positive => never-late.
  double get leadSeconds => routeDurationSeconds - fireElapsedSeconds;
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
    _warpFactor = value.clamp(0.1, 200.0);
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
  bool _isFinished = false;
  StreamSubscription? _tickSub;
  StreamSubscription? _logSub;
  StreamSubscription? _accelSub; // Raw IMU from engine
  StreamSubscription? _gyroSub; // Raw IMU from engine
  StreamSubscription? _imuSub; // Combined IMU samples

  // Ground-truth accuracy metrics (EKF vs simulator truth per tick).
  final EkfMetrics _metrics = EkfMetrics();

  // In-sim alarm decision state (evaluated against EKF progress).
  bool _alarmFired = false;
  EkfAlarmResult? _alarmResult;

  // In-sim REACHABILITY (never-late upper-bound) decision state. Independent of
  // the EKF point estimate: driven only by accepted GPS fixes + the physics
  // cone, so it survives a total GPS blackout and can never fire late.
  ReachabilityTracker? _reach;
  bool _reachFired = false;
  EkfReachResult? _reachResult;
  double _reachTargetMeters = 0.0;
  double? _reachTrueTargetArrivalSeconds;
  RouteTopology? _reachTopology;

  /// Wake this many stops before the destination (0 = fire at the destination
  /// arc-length itself). A real wake alarm fires a few stops early, so the cone
  /// reaches the target comfortably before arrival rather than exactly at it.
  int reachWakeStopsBeforeDestination = 0;

  /// Reachability tuning. Defaults to the INERT free-run config; set
  /// dynamicLeversEnabled/curveTrusted/dwellMinSeconds to exercise the
  /// fastest-feasible-train tightening through the playground engine on the
  /// real curved metro geometry.
  ReachabilityConfig reachConfig = const ReachabilityConfig();

  /// Called when the playback engine auto-finishes (end of route/log).
  void Function()? onFinished;

  /// Called once when the in-sim alarm fires against EKF progress.
  void Function(EkfAlarmResult)? onAlarm;

  /// Called once when the never-late reachability cone reaches the target.
  void Function(EkfReachResult)? onReach;

  /// The reachability (never-late) result for the current run, if it fired.
  EkfReachResult? get reachResult => _reachResult;

  /// Sim time (seconds) when GROUND-TRUTH progress first reached the reach
  /// target. The cone is never-late iff it fired at or before this instant.
  double? get reachTrueTargetArrivalSeconds => _reachTrueTargetArrivalSeconds;

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
  final List<LatLng> _rawGpsTrail = []; // Raw GPS fixes for green trail
  LatLng? _lastRawGpsPosition;
  DateTime? _lastZuptLogTime;

  // ─────────────────────────────────────────────────────────────────────────
  // Public Properties
  // ─────────────────────────────────────────────────────────────────────────

  bool get isActive => _isActive;
  bool get isPlaying => _engine?.isPlaying ?? false;
  bool get isFinished => _isFinished || (_engine?.isFinished ?? false);
  double get elapsedSeconds => _engine?.elapsedSeconds ?? 0.0;
  double get progress => _engine?.progress ?? 0.0;
  double get progressMeters => _engine?.progressMeters ?? 0.0;
  TestRoute? get route => _engine?.route;
  List<EkfTestLogEntry> get logs => List.unmodifiable(_logs);

  // ─── Ground-truth metrics (surfaced in the dashboard metrics panel) ───────
  EkfMetrics get metrics => _metrics;
  double get ekfCurrentError => _metrics.currentError;
  double get ekfMaxDrift => _metrics.maxDrift;
  double get ekfRmse => _metrics.rmse;
  double get ekfMaxBlackoutError => _metrics.maxBlackoutError;

  // ─── In-sim alarm ─────────────────────────────────────────────────────────
  bool get alarmFired => _alarmFired;
  EkfAlarmResult? get alarmResult => _alarmResult;

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
    'currentErrorM': _metrics.currentError.toStringAsFixed(1),
    'maxDriftM': _metrics.maxDrift.toStringAsFixed(1),
    'rmseM': _metrics.rmse.toStringAsFixed(1),
    'maxBlackoutErrorM': _metrics.maxBlackoutError.toStringAsFixed(1),
    'alarmFired': _alarmFired,
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

    // Wire the REAL EKF so every scenario preset dead-reckons through GPS
    // dropout (previously only the log loaders initialised the orchestrator).
    _initializeEkf();
    _subscribeToEngineImu();

    // Subscribe to engine events (leak-free, wires FINISHED callback)
    _resubscribeEngine();

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
  ///
  /// Builds a fresh engine, applies the current GPS-dropout/warp config, wires
  /// the REAL EKF (orchestrator + IMU stream) and subscribes leak-free so route
  /// presets dead-reckon through GPS dropout just like the log loaders.
  Future<void> loadRoute(TestRouteId routeId) async {
    _engine = ImuReplayEngineV2();
    _engine!.logVerbosity = logVerbosity;
    _engine!.gpsDropoutMode = _gpsDropoutMode;
    _engine!.warpFactor = _warpFactor;

    await _engine!.loadTestRoute(routeId);

    // Wire the REAL EKF (was previously only done in the log loaders).
    _initializeEkf();
    _subscribeToEngineImu();

    // Subscribe to engine events (leak-free, wires FINISHED callback)
    _resubscribeEngine();

    _isActive = true;
    _resetStatistics();

    _log(EkfTestLogCategory.control, 'INFO', 'Loaded route: ${routeId.name}', {
      'gpsMode': _gpsDropoutMode.name,
      'warpFactor': _warpFactor,
    });
  }

  /// Load an ARBITRARY polyline (real/recorded trip) for synthesized replay.
  ///
  /// Wires the same pipeline as [loadRoute] (fresh engine → dropout/warp config
  /// → REAL EKF + IMU stream → leak-free subscriptions) but drives the engine
  /// from any [polyline] via [ImuReplayEngineV2.loadFromPolyline], so arbitrary
  /// recorded trips exercise the never-late engine, not just canned metro
  /// routes. [stops] become ZUPT dwell points and [blackoutWindows] model
  /// tunnel / no-signal stretches (simulation seconds).
  Future<void> loadRouteFromPolyline(
    List<LatLng> polyline, {
    double speedMps = 12.0,
    List<GpsBlackoutWindow> blackoutWindows = const [],
    double dtSeconds = 1.0,
    List<LatLng> stops = const [],
    double dwellSeconds = 25.0,
    String name = 'Synthetic Polyline Route',
    String description =
        'Synthesized EKF/IMU/GPS timeline from an arbitrary polyline',
    LegType legType = LegType.metro,
    bool isUnderground = false,
  }) async {
    _engine = ImuReplayEngineV2();
    _engine!.logVerbosity = logVerbosity;
    _engine!.gpsDropoutMode = _gpsDropoutMode;
    _engine!.warpFactor = _warpFactor;

    await _engine!.loadFromPolyline(
      polyline,
      speedMps: speedMps,
      blackoutWindows: blackoutWindows,
      dtSeconds: dtSeconds,
      stops: stops,
      dwellSeconds: dwellSeconds,
      name: name,
      description: description,
      legType: legType,
      isUnderground: isUnderground,
    );

    // Wire the REAL EKF (orchestrator + IMU stream), leak-free subscriptions.
    _initializeEkf();
    _subscribeToEngineImu();
    _resubscribeEngine();

    _isActive = true;
    _resetStatistics();

    _log(
      EkfTestLogCategory.control,
      'INFO',
      'Loaded polyline route: $name',
      {
        'points': polyline.length,
        'speedMps': speedMps,
        'stops': stops.length,
        'blackoutWindows': blackoutWindows.length,
        'gpsMode': _gpsDropoutMode.name,
        'warpFactor': _warpFactor,
      },
    );
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

    // Subscribe to engine events (leak-free, wires FINISHED callback)
    _resubscribeEngine();

    _isActive = true;
    _resetStatistics();

    _log(
      EkfTestLogCategory.control,
      'EVENT',
      'Loaded log replay: ${routeId.name}',
      {'directory': logDirectory},
    );
  }

  /// Load a unified log (JSON) for replay.
  Future<void> loadUnifiedLog(String jsonPath) async {
    _scenario = TestScenario.logReplay;
    _engine = ImuReplayEngineV2();
    _engine!.logVerbosity = logVerbosity;

    await _engine!.loadUnifiedRouteLog(jsonPath);

    // Initialize EKF with route geometry
    _initializeEkf();

    // Subscribe to raw IMU streams
    _subscribeToEngineImu();

    // Subscribe to engine events (leak-free, wires FINISHED callback)
    _resubscribeEngine();

    _isActive = true;
    _resetStatistics();

    _log(EkfTestLogCategory.control, 'EVENT', 'Loaded Unified Log: $jsonPath');
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

    // Subscribe to engine events (leak-free, wires FINISHED callback)
    _resubscribeEngine();

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
    final stationMeters =
        route.allStations.map((s) => s.cumulativeMeters).toList();
    _ekfOrchestrator!.setStationContext(
      stationMeters: stationMeters,
      isMetroLeg: true, // Metro route for now
    );

    // Hook station snap callback
    _ekfOrchestrator!.onStationSnapConfirmed = _onEkfStationSnap;

    // Wire the never-late REACHABILITY cone alongside the EKF (read-only). The
    // cone is the provable upper bound on progress; unlike the EKF estimate it
    // must fire at/before the true arrival on every route (never-late).
    _initReachability(route);

    _log(EkfTestLogCategory.ekf, 'EVENT', 'EKF initialized', {
      'routeLength': _routeGeometry!.totalLengthMeters.toStringAsFixed(0),
      'stations': stationMeters.length,
      'stationMeters':
          stationMeters.take(5).map((m) => m.toStringAsFixed(0)).join(', ') +
          (stationMeters.length > 5 ? '...' : ''),
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

  /// (Re)subscribe to the engine's tick/log streams, cancelling any prior
  /// subscriptions first. Loaders previously leaked subscriptions by assigning
  /// `_tickSub`/`_logSub` without cancelling the old engine's listeners; this
  /// centralises that so every load path is leak-free and wires the
  /// end-of-run (FINISHED) callback.
  void _resubscribeEngine() {
    _tickSub?.cancel();
    _logSub?.cancel();

    _isFinished = false;
    _tickSub = _engine!.tickStream.listen(_onTick);
    _logSub = _engine!.logStream.listen(_onEngineLog);

    _engine!.onFinished = () {
      _isFinished = true;
      _log(EkfTestLogCategory.control, 'EVENT', 'Playback finished', statistics);
      onFinished?.call();
    };
  }

  /// Seed the never-late reachability cone for this route. Cold-start anchor at
  /// the trip origin (s=0, t=0) so the cone is valid from t=0 even if GPS never
  /// yields a single underground fix. Fire target = final destination arc-length
  /// (the same destination the in-sim [AlarmEvaluator] fires on), so the two
  /// paths are directly comparable.
  void _initReachability(TestRoute route) {
    _reach = ReachabilityTracker(config: reachConfig);
    _reachFired = false;
    _reachResult = null;
    _reachTrueTargetArrivalSeconds = null;
    _reachTopology = null;

    // Target = the wake point N stops before the destination (falls back to the
    // destination arc-length if the route has too few stations).
    final stations = route.allStations;
    final stops = reachWakeStopsBeforeDestination;
    if (stops > 0 && stations.length >= stops + 1) {
      _reachTargetMeters = stations[stations.length - 1 - stops].cumulativeMeters;
    } else {
      // Too few stations for a stop-based target: wake a fixed lead-distance
      // before the destination so the target is reached before the final tick.
      const leadMeters = 400.0;
      _reachTargetMeters = (route.totalMeters - leadMeters)
          .clamp(route.totalMeters * 0.5, route.totalMeters);
    }

    // Build the fastest-feasible velocity profile so the dynamic levers (accel +
    // terminal braking + curve + dwell) tighten the cone. Only when enabled —
    // otherwise the tracker stays on the inert free-run path. Served stations =
    // this route's stops ∪ target (correct-by-construction, no express trap).
    final poly = route.fullPolyline;
    final cum = route.fullCumulativeMeters;
    if (reachConfig.dynamicLeversEnabled &&
        poly.length >= 3 &&
        poly.length == cum.length) {
      final vLine = _reach!.vLineTable.forLine(lineName: null);
      final served = <double>[
        ...stations.map((s) => s.cumulativeMeters),
        route.totalMeters,
      ];
      final profile = RouteProfile.precompute(
        lats: poly.map((p) => p.latitude).toList(),
        lngs: poly.map((p) => p.longitude).toList(),
        cumulativeMeters: cum,
        servedStations: served,
        config: reachConfig,
        vLine: vLine,
      );
      _reachTopology = RouteTopology(
        stationMeters: served,
        dwellMinSeconds: reachConfig.dwellMinSeconds,
        profile: profile,
      );
    }

    _reach!.seedColdStart(tSeconds: 0.0, sMeters: 0.0);
  }

  /// Run the never-late reachability decision for this tick. Anchors ONLY on
  /// accepted real GPS fixes (never on a dead-reckoned tick), then fires the
  /// first time the provable upper bound s_max reaches the target. Read-only;
  /// fires at most once per run.
  void _evaluateReachability(ReplayTickResultV2 tick) {
    final reach = _reach;
    if (reach == null) return;
    final now = tick.elapsedSeconds;

    // Record when GROUND TRUTH first reaches the wake target (independent of the
    // fire, so it is captured even on the ticks after firing). The never-late
    // guarantee is exactly fireElapsed <= this instant.
    if (_reachTrueTargetArrivalSeconds == null &&
        tick.progressMeters >= _reachTargetMeters) {
      _reachTrueTargetArrivalSeconds = now;
    }

    if (_reachFired) return;

    // Anchor on an accepted real GPS fix. The along-route s of a real fix is the
    // map-matched progress (here the tick's true progress); the tracker forward-
    // overbounds by GPS accuracy internally, preserving the never-late bound.
    if (tick.gpsAvailable && tick.gpsPosition != null) {
      reach.onAcceptedFix(
        sMeters: tick.progressMeters,
        accuracyMeters: tick.gpsAccuracy ?? 15.0,
        tSeconds: now,
      );
    }

    final bound = reach.boundNow(nowSeconds: now, topology: _reachTopology);
    if (bound == null || bound.sMaxMeters < _reachTargetMeters) return;

    _reachFired = true;
    final route = _engine?.route;
    final result = EkfReachResult(
      fireElapsedSeconds: now,
      sMaxMeters: bound.sMaxMeters,
      trueProgressMeters: tick.progressMeters,
      targetMeters: _reachTargetMeters,
      routeDurationSeconds: route?.totalDurationSeconds ?? 0.0,
    );
    _reachResult = result;

    _log(EkfTestLogCategory.alarm, 'EVENT',
        '🛡️ REACH (never-late): cone reached target', {
      'fireElapsedS': now.toStringAsFixed(1),
      'sMaxM': bound.sMaxMeters.isFinite
          ? bound.sMaxMeters.toStringAsFixed(0)
          : 'inf',
      'trueProgressM': tick.progressMeters.toStringAsFixed(0),
      'targetM': _reachTargetMeters.toStringAsFixed(0),
      'earlyMetersVsTrue': result.earlyMeters.isFinite
          ? result.earlyMeters.toStringAsFixed(0)
          : 'inf',
      'leadSecondsVsArrival': result.leadSeconds.toStringAsFixed(1),
    });

    onReach?.call(result);
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

  /// Run the REAL alarm decision (destination) against the EKF's estimated
  /// progress, read-only. Fires at most once per run. Uses the evaluator's
  /// fallback (no transit-leg context) path: a single final-destination event
  /// at the route end, so the genuine "direct fire < 200m" rule decides.
  void _evaluateAlarm({
    required double ekfProgressMeters,
    required double trueProgressMeters,
    required double ekfVelocityMps,
  }) {
    if (_alarmFired) return;

    final route = _engine?.route;
    if (route == null) return;
    final totalMeters = route.totalMeters;
    if (totalMeters <= 0) return;
    if (!ekfProgressMeters.isFinite) return;

    final ekfState = _ekfOrchestrator?.publicState;

    // Single destination event at the route end; empty transit legs selects the
    // evaluator's fallback destination rules (direct-fire < 200m).
    final destination = RouteEventBoundary(
      meters: totalMeters,
      type: AlarmEventType.finalDestination,
    );

    final AlarmTrigger? trigger = AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.distance,
      userValue: 0,
      progressMeters: ekfProgressMeters,
      allEvents: [destination],
      firedEventIndexes: const {},
      firedLegIds: const {},
      isMetroLeg: route.allStations.isNotEmpty,
      transitLegs: const [],
      currentLegIndex: 0,
      isFinalLeg: true,
      currentSpeedMps: ekfVelocityMps,
      positionSigmaMeters: ekfState?.sigmaS,
      velocitySigmaMps: ekfState?.sigmaV,
    );

    if (trigger == null) return;

    _alarmFired = true;
    final result = EkfAlarmResult(
      eventType: trigger.eventType,
      message: trigger.message,
      fireElapsedSeconds: elapsedSeconds,
      ekfProgressMeters: ekfProgressMeters,
      trueProgressMeters: trueProgressMeters,
      routeMeters: totalMeters,
      routeDurationSeconds: route.totalDurationSeconds,
    );
    _alarmResult = result;

    _log(EkfTestLogCategory.alarm, 'EVENT', '🔔 ALARM: ${trigger.message}', {
      'eventType': trigger.eventType,
      'reason': trigger.reason,
      'fireElapsedS': result.fireElapsedSeconds.toStringAsFixed(1),
      'ekfProgressM': ekfProgressMeters.toStringAsFixed(0),
      'trueProgressM': trueProgressMeters.toStringAsFixed(0),
      'leadErrorM': result.leadErrorMeters.toStringAsFixed(1),
      'leadSeconds': result.leadSeconds.toStringAsFixed(1),
    });

    onAlarm?.call(result);
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
    _rawGpsTrail.clear();
    _lastRawGpsPosition = null;
    _lastZuptLogTime = null;

    // Reset ground-truth metrics and in-sim alarm state
    _metrics.reset();
    _alarmFired = false;
    _alarmResult = null;
    _tickCount = 0;

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
    // 3.2 GROUND-TRUTH METRICS (EKF estimate vs simulator truth)
    // ─────────────────────────────────────────────────────────────────────
    if (_ekfOrchestrator != null && ekfProgressMeters != null) {
      _metrics.update(
        ekfProgressMeters: ekfProgressMeters,
        trueProgressMeters: tick.progressMeters,
        gpsAvailable: tick.gpsAvailable,
      );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3.3 IN-SIM ALARM DECISION (real AlarmEvaluator, EKF progress)
    // ─────────────────────────────────────────────────────────────────────
    if (ekfProgressMeters != null) {
      _evaluateAlarm(
        ekfProgressMeters: ekfProgressMeters,
        trueProgressMeters: tick.progressMeters,
        ekfVelocityMps: ekfVelocityMps,
      );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3.4 IN-SIM REACHABILITY (never-late upper bound, EKF-independent)
    // ─────────────────────────────────────────────────────────────────────
    _evaluateReachability(tick);

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
      final isDegraded =
          _ekfOrchestrator!.gpsDegraded || ekfState.mode == EkfMode.degraded;
      final predEnabled = _ekfOrchestrator!.predictionEnabled;

      _log(
        EkfTestLogCategory.ekf,
        'COMPARE',
        '📊 tick $_tickCount: true=${trueProgress.toStringAsFixed(0)} ekf=${ekfS.toStringAsFixed(0)} err=${error.toStringAsFixed(0)} v=${ekfState.v.toStringAsFixed(2)} σs=${ekfState.sigmaS.toStringAsFixed(0)} mode=${ekfState.mode.name} degraded=$isDegraded gps=${tick.gpsAvailable} pred=$predEnabled',
        {
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
        },
      );
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
      _log(
        EkfTestLogCategory.zupt,
        'STATION_STOP',
        '🚉 Engine at station: ${tick.lastStation?.name ?? "unknown"}',
        {
          'simSpeed': tick.speedMps.toStringAsFixed(2),
          'simMotion': tick.motionState.name,
          'ekfMotion': ekfMotion.name, // <-- What EKF thinks motion is
          'accelVar': accelVar.toStringAsExponential(2), // <-- Current variance
          'gyroVar': gyroVar.toStringAsExponential(2),
          'ekfV': ekfState.v.toStringAsFixed(2),
          'ekfMode': ekfState.mode.name,
          'gpsAvailable': tick.gpsAvailable,
          'predictionEnabled': _ekfOrchestrator!.predictionEnabled,
        },
      );

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
            'position':
                '${ekfPosition.latitude.toStringAsFixed(5)}, ${ekfPosition.longitude.toStringAsFixed(5)}',
          });
        }
      }
    }

    // Track raw GPS position for ghost marker comparison and GPS trail
    if (tick.gpsPosition != null) {
      _lastRawGpsPosition = tick.gpsPosition;
      // Add to raw GPS trail for green polyline visualization
      // Only add if significantly different from last point (>5m) to avoid clutter
      if (_rawGpsTrail.isEmpty ||
          _haversineDistance(_rawGpsTrail.last, tick.gpsPosition!) > 5.0) {
        _rawGpsTrail.add(tick.gpsPosition!);
      }
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
      truePosition: tick.position, // Ground truth (snapped to route)
      gpsPosition: tick.gpsPosition, // Raw GPS from log
      ekfPosition: ekfPosition, // EKF estimated position (ghost marker)
      rawGpsPosition: _lastRawGpsPosition,
      trueProgressMeters: tick.progressMeters,
      gpsProgressMeters: tick.gpsAvailable ? tick.progressMeters : null,
      ekfProgressMeters: ekfProgressMeters, // EKF estimated progress
      speedMps: ekfVelocityMps, // EKF velocity (not GPS speed)
      ekfSigmaS: ekfSigmaS,
      ekfSigmaV: ekfSigmaV,
      gpsAvailable: tick.gpsAvailable,
      isZuptCandidate: ekfZuptActive, // From EKF, not primitive threshold
      isAtStation: tick.isAtStation,
      motionState: tick.motionState,
      currentStation: tick.lastStation,
      nextStation: tick.nextStation,
      metersToNext: tick.metersToNextStation,
      routePolyline: _engine?.route?.fullPolyline ?? [],
      groundTruthPolyline: _engine?.route?.groundTruthPolyline ?? [],
      rawGpsTrail: List.unmodifiable(_rawGpsTrail),
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
        if (tick.gpsAvailable &&
            tick.gpsPosition != null &&
            _routeGeometry != null) {
          gpsProgress = _routeGeometry!.projectLatLng(
            tick.gpsPosition!.latitude,
            tick.gpsPosition!.longitude,
          );
        }

        final errorM =
            (gpsProgress != null && !ekfState.s.isNaN)
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
      if (level == 'EVENT' ||
          level == 'COMPARE' ||
          level == 'MODE' ||
          level == 'ZUPT' ||
          level == 'STATION_STOP' ||
          level == 'PIPELINE' ||
          level == 'IMU' ||
          level == 'PHYSICS') {
        debugPrint(entry.toColoredString());
      }
    }
  }

  void clearLogs() {
    _logs.clear();
    _engine?.clearLogs();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Utility Functions
  // ─────────────────────────────────────────────────────────────────────────

  /// Haversine distance between two LatLng points in meters.
  double _haversineDistance(LatLng a, LatLng b) {
    const R = 6371000.0; // Earth radius in meters
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;

    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));

    return R * c;
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
