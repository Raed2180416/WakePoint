import 'dart:async';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/simulation_client.dart';
import 'package:logging/logging.dart';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

/// Manages the location data source, switching between real GPS and Simulation.
/// Handles speed smoothing and overrides.
class LocationManager {
  // Singleton pattern
  static final LocationManager _instance = LocationManager._internal();
  factory LocationManager() => _instance;
  LocationManager._internal();

  /// Test mode flag - when true, skip Geolocator platform calls
  static bool isTestMode = false;

  final _log = Logger('LocationManager');

  // Stream controller for the unified location output (Real or Simulated)
  final _positionController = StreamController<Position>.broadcast();
  Stream<Position> get positionStream => _positionController.stream;

  // Internal state
  StreamSubscription<Position>? _realGpsSubscription;
  StreamSubscription<Position>? _simSubscription;
  final SimulationClient _simulationClient = SimulationClient();

  bool _isSimulationMode = false;
  bool _simulationPositionsReceived = false;

  // Speed Smoothing State
  double? _speedEmaMps;

  // For consistent speed estimation across real GPS and simulation.
  Position? _lastSpeedPosition;
  DateTime? _lastSpeedTimestamp;

  /// Returns the current smoothed speed in m/s, or 0.0 if unknown.
  double get currentSpeedMps => _speedEmaMps ?? 0.0;

  // Configuration
  final LocationSettings _locationSettings = const LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 0, // Receive all updates for smoothing
  );

  /// Starts the location stream.
  /// Always starts Real GPS initially.
  /// Also connects SimulationClient to listen for overrides.
  Future<void> start() async {
    _log.info('Starting LocationManager');

    // Stop and cleanup existing streams
    await stop();

    // 1. Start Real GPS (Default)
    _startRealGps();

    // 2. Connect Simulation Client for seamless failover/override
    _connectSimulation();
  }

  Future<void> stop() async {
    _log.info('Stopping LocationManager');
    await _realGpsSubscription?.cancel();
    _realGpsSubscription = null;

    await _simSubscription?.cancel();
    _simSubscription = null;

    _simulationClient.disconnect();

    _isSimulationMode = false;
    _simulationPositionsReceived = false;
    _speedEmaMps = null;
    _lastSpeedPosition = null;
    _lastSpeedTimestamp = null;
  }

  // Test Support
  Stream<Position>? testModeStream;

  void _startRealGps() {
    // In test mode without testModeStream, skip Geolocator platform calls
    if (isTestMode && testModeStream == null) {
      _log.info('Test mode: skipping Geolocator platform calls');
      return; // Allow injectPosition to work without Geolocator
    }
    final stream =
        testModeStream ??
        Geolocator.getPositionStream(locationSettings: _locationSettings);
    _realGpsSubscription = stream.listen(
      _onRealPosition,
      onError: (e) {
        _log.severe('Real GPS Stream Error', e);
      },
    );
  }

  void _connectSimulation() {
    // Listen to the simulation client's stream.
    // If it emits data, we interpret that as the dashboard taking control.
    _simSubscription = _simulationClient.positionStream.listen(
      (pos) {
        if (!_isSimulationMode) {
          _isSimulationMode = true;
          _log.info(
            'Auto-switching to Simulation Mode (First position received)',
          );
          // CRITICAL: Reset alarm state when simulation begins so that
          // firedLegIds from previous sessions don't carry over.
          _simulationClient.onAlarmReset?.call();
          dev.log(
            'LocationManager: Called onAlarmReset on simulation mode entry',
            name: 'LocationManager',
          );
        }
        _simulationPositionsReceived = true;
        _processPosition(pos, isSimulated: true);
      },
      onError: (e) {
        _log.warning('Simulation Stream Error', e);
      },
    );

    // Also explicitly connect the client logic which handles the WebSocket
    _simulationClient.connect();

    // Set up the explicit callback - this fires BEFORE the position stream emits
    // so we use it as the primary reset trigger.
    _simulationClient.onFirstPositionReceived = () {
      if (!_isSimulationMode) {
        _isSimulationMode = true;
        _simulationPositionsReceived = true;
        // CRITICAL: Reset alarm state when simulation begins so that
        // firedLegIds from previous sessions don't carry over.
        _simulationClient.onAlarmReset?.call();
        dev.log(
          'LocationManager: Called onAlarmReset on simulation mode entry (from onFirstPositionReceived)',
          name: 'LocationManager',
        );
      }
    };

    // Reset simulation mode when dashboard disconnects, so next connection triggers reset
    _simulationClient.onDisconnected = () {
      dev.log(
        'LocationManager: Simulation disconnected, resetting simulation mode',
        name: 'LocationManager',
      );
      _isSimulationMode = false;
      _simulationPositionsReceived = false;
    };
  }

  /// Injects a position (used by Tests or other internal sources).
  void injectPosition(Position pos) {
    // If we manually inject, we force simulation mode
    if (!_isSimulationMode) {
      _isSimulationMode = true;
    }
    _simulationPositionsReceived = true;
    _processPosition(pos, isSimulated: true);
  }

  void _onRealPosition(Position pos) {
    // If we are in simulation mode (active dashboard), ignore real GPS
    if (_isSimulationMode && _simulationPositionsReceived) {
      return;
    }
    _processPosition(pos, isSimulated: false);
  }

  void _processPosition(Position pos, {required bool isSimulated}) {
    // 1) Normalize speed so simulation and real GPS behave the same.
    // We derive speed from successive points (distance / dt), but guard hard
    // against GPS jitter producing huge spikes (which makes ETA wildly optimistic).
    double dtSeconds = 0.0;
    double derivedSpeedMps = 0.0;
    double dMeters = 0.0;
    try {
      final ts = pos.timestamp;
      if (_lastSpeedPosition != null && _lastSpeedTimestamp != null) {
        dtSeconds = ts.difference(_lastSpeedTimestamp!).inMilliseconds / 1000.0;
        if (dtSeconds.isFinite && dtSeconds > 0.0) {
          dMeters = Geolocator.distanceBetween(
            _lastSpeedPosition!.latitude,
            _lastSpeedPosition!.longitude,
            pos.latitude,
            pos.longitude,
          );

          // Treat small movements within the accuracy radius as jitter.
          final acc =
              (pos.accuracy.isFinite && pos.accuracy > 0) ? pos.accuracy : 25.0;
          final double jitterMeters =
              isSimulated ? 0.0 : (acc * 0.6).clamp(3.0, 30.0);

          final double minDt = isSimulated ? 0.05 : 0.8;
          if (dtSeconds >= minDt && dMeters >= jitterMeters) {
            final raw = dMeters / dtSeconds;
            // Clamp to a sane upper bound to prevent ETA collapse.
            derivedSpeedMps = raw.isFinite ? raw.clamp(0.0, 40.0) : 0.0;
          }
        }
      }
      _lastSpeedPosition = pos;
      _lastSpeedTimestamp = ts;
    } catch (_) {
      dtSeconds = 0.0;
      derivedSpeedMps = 0.0;
    }

    // Prefer platform speed when it's present, but stay conservative when
    // derived speed spikes (noise). When both exist, use the smaller unless
    // platform speed looks "stuck" at ~0 while derived indicates real motion.
    double? platformSpeedMps;
    try {
      final s = pos.speed;
      if (s.isFinite && s >= 0) {
        platformSpeedMps = s.clamp(0.0, 40.0);
      }
    } catch (_) {
      platformSpeedMps = null;
    }

    double normalizedSpeedMps;
    if (platformSpeedMps != null && derivedSpeedMps > 0) {
      if (platformSpeedMps < 0.5 && derivedSpeedMps > 1.5) {
        normalizedSpeedMps = derivedSpeedMps;
      } else {
        normalizedSpeedMps = min(platformSpeedMps, derivedSpeedMps);
      }
    } else {
      normalizedSpeedMps =
          (derivedSpeedMps > 0) ? derivedSpeedMps : (platformSpeedMps ?? 0.0);
    }

    // Final spike guard: cap sudden jumps relative to prior EMA.
    if (_speedEmaMps != null && normalizedSpeedMps.isFinite) {
      final double dt = dtSeconds.isFinite && dtSeconds > 0 ? dtSeconds : 1.0;
      const double maxAccel = 3.0; // m/s^2 conservative
      final maxIncrease = (maxAccel * dt) + 1.0; // small allowance
      final cap = (_speedEmaMps! + maxIncrease).clamp(0.0, 40.0);
      if (normalizedSpeedMps > cap) {
        normalizedSpeedMps = cap;
      }
    }

    // 2) Speed smoothing (EMA) for downstream consumers.
    double smoothedSpeed = normalizedSpeedMps;
    if (normalizedSpeedMps >= 0) {
      if (_speedEmaMps == null) {
        _speedEmaMps = normalizedSpeedMps;
      } else {
        // Alpha = 0.2 (Keep 80% history) -> moderately smooth
        _speedEmaMps = (_speedEmaMps! * 0.8) + (normalizedSpeedMps * 0.2);
        smoothedSpeed = _speedEmaMps!;
      }
    }

    // 3) Emit a Position with the normalized speed so ETA/alarm logic sees
    // the same type of speed signal in both simulation and real GPS runs.
    final out = Position(
      latitude: pos.latitude,
      longitude: pos.longitude,
      timestamp: pos.timestamp,
      accuracy: pos.accuracy,
      altitude: pos.altitude,
      heading: pos.heading,
      speed: normalizedSpeedMps,
      speedAccuracy: pos.speedAccuracy,
      altitudeAccuracy: pos.altitudeAccuracy,
      headingAccuracy: pos.headingAccuracy,
    );

    _positionController.add(out);

    // Debug logging for simulation
    if (isSimulated) {
      // Periodic logging to reduce spam? Or detailed for now.
      // Keeping it moderate.
      if (pos.timestamp.second % 5 == 0) {
        dev.log(
          "SimPos: ${pos.latitude.toStringAsFixed(5)},${pos.longitude.toStringAsFixed(5)} Spd: ${smoothedSpeed.toStringAsFixed(1)}",
          name: "LocationManager",
        );
      }
    }
  }

  // --- Broadcast Delegation ---

  /// Delegates to SimulationClient.broadcastState
  void broadcastState({
    required bool alarmFired,
    bool active = true,
    double? remainingStops,
    Map<String, dynamic>? debugInfo,
    // Unpacked params from TrackingService state
    required double? apiEtaSeconds,
    required double? smoothedETA,
    required double? distanceTravelledMeters,
    required String? alarmMode,
    required double? alarmValue,
    required bool destinationAlarmFired,
    required DateTime? lastAlarmFiredAt,
  }) {
    if (!_simulationClient.active) return;

    final now = DateTime.now();
    final recentAlarm =
        lastAlarmFiredAt != null &&
        now.difference(lastAlarmFiredAt).inSeconds <= 5;

    final double etaRaw = apiEtaSeconds ?? smoothedETA ?? 0.0;
    final int etaSeconds = etaRaw.isFinite ? etaRaw.round() : 0;
    dev.log(
      'ETA_DEBUG broadcastState: apiEta=$apiEtaSeconds, smoothedETA=$smoothedETA, etaRaw=$etaRaw, etaSec=$etaSeconds',
      name: 'LocationManager',
    );
    final double distance =
        (distanceTravelledMeters?.isFinite ?? false)
            ? distanceTravelledMeters!
            : 0.0;

    _simulationClient.broadcastState(
      etaSeconds: etaSeconds,
      distanceTravelled: distance,
      alarmMode: alarmMode ?? 'distance',
      alarmValue: alarmValue ?? 0.0,
      alarmFired: alarmFired || destinationAlarmFired || recentAlarm,
      active: active,
      remainingStops: remainingStops,
      debugInfo: debugInfo,
    );
  }

  /// Delegates to SimulationClient.broadcastRoute
  void broadcastRoute({
    String? routeKey,
    required String destinationName,
    required List<Map<String, dynamic>> points,
    List<Map<String, dynamic>>? segments,
    List<Map<String, dynamic>>? switchPoints,
    List<Map<String, dynamic>>? events,
    List<double>? stopMeters,
    List<Map<String, dynamic>>? transitLegs,
    List<Map<String, dynamic>>? inactiveRoutes,
    bool? transitMode,
    Map<String, dynamic>? routeDebug,
  }) {
    _simulationClient.broadcastRoute(
      routeKey: routeKey,
      destinationName: destinationName,
      points: points,
      segments: segments,
      switchPoints: switchPoints,
      events: events,
      stopMeters: stopMeters,
      transitLegs: transitLegs,
      inactiveRoutes: inactiveRoutes,
      transitMode: transitMode,
      routeDebug: routeDebug,
    );
  }

  /// Callback for alarm reset
  set onAlarmReset(VoidCallback? callback) =>
      _simulationClient.onAlarmReset = callback;

  /// Callback for route switch requests from dashboard
  set onSwitchRoute(void Function(String routeKey)? callback) =>
      _simulationClient.onSwitchRoute = callback;

  /// Delegates to SimulationClient.broadcastPosition for device location sync.
  void broadcastPosition({
    required double lat,
    required double lng,
    double? heading,
    double? speed,
  }) {
    _simulationClient.broadcastPosition(
      lat: lat,
      lng: lng,
      heading: heading,
      speed: speed,
    );
  }
}
