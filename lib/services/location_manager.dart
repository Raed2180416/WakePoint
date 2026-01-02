import 'dart:async';
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
  LocationSettings _locationSettings = const LocationSettings(
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

    // Set up the explicit callback as a backup/indicator
    _simulationClient.onFirstPositionReceived = () {
      if (!_isSimulationMode) {
        _isSimulationMode = true;
        _simulationPositionsReceived = true;
      }
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
    // Prefer a derived speed from successive points (distance / dt), since raw
    // GPS speed quality varies by device and simulation may not provide it.
    double derivedSpeedMps = 0.0;
    try {
      final ts = pos.timestamp;
      if (_lastSpeedPosition != null && _lastSpeedTimestamp != null) {
        final dtSeconds =
            ts.difference(_lastSpeedTimestamp!).inMilliseconds / 1000.0;
        if (dtSeconds > 0.0) {
          final dMeters = Geolocator.distanceBetween(
            _lastSpeedPosition!.latitude,
            _lastSpeedPosition!.longitude,
            pos.latitude,
            pos.longitude,
          );
          final raw = dMeters / dtSeconds;
          derivedSpeedMps = raw.isFinite ? raw.clamp(0.0, 60.0) : 0.0;
        }
      }
      _lastSpeedPosition = pos;
      _lastSpeedTimestamp = ts;
    } catch (_) {
      derivedSpeedMps = 0.0;
    }

    final normalizedSpeedMps = derivedSpeedMps;

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
    required String destinationName,
    required List<Map<String, dynamic>> points,
    List<Map<String, dynamic>>? segments,
    List<Map<String, dynamic>>? switchPoints,
    List<Map<String, dynamic>>? events,
    List<double>? stopMeters,
    List<Map<String, dynamic>>? transitLegs,
    List<Map<String, dynamic>>? inactiveRoutes,
    bool? transitMode,
  }) {
    _simulationClient.broadcastRoute(
      destinationName: destinationName,
      points: points,
      segments: segments,
      switchPoints: switchPoints,
      events: events,
      stopMeters: stopMeters,
      transitLegs: transitLegs,
      inactiveRoutes: inactiveRoutes,
      transitMode: transitMode,
    );
  }

  /// Callback for alarm reset
  set onAlarmReset(VoidCallback? callback) =>
      _simulationClient.onAlarmReset = callback;

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
