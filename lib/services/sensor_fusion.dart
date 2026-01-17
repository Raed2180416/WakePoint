// lib/services/sensor_fusion.dart
//
// ============================================================================
// ⚠️  DEPRECATED - DO NOT USE IN PRODUCTION  ⚠️
// ============================================================================
//
// This file contains a PLACEHOLDER dead reckoning implementation that has
// fundamental accuracy issues:
//
// 1. UNBOUNDED DRIFT: Accelerometer integration accumulates error rapidly
// 2. 10-SECOND RESET: Position "snaps back" to anchor every 10 seconds
// 3. NO SENSOR CALIBRATION: Raw accelerometer values are used directly
// 4. NO ORIENTATION TRACKING: Assumes device is always level
// 5. NO GPS FUSION: This runs independently, not fused with GPS
//
// This will be COMPLETELY REPLACED with a proper Extended Kalman Filter (EKF)
// implementation that:
// - Fuses GPS, accelerometer, gyroscope, and magnetometer
// - Properly handles sensor biases and calibration
// - Provides uncertainty estimates (covariance)
// - Gracefully handles GPS dropout with bounded drift
//
// See: docs/ekf_planning/ for the replacement implementation plan.
//
// CURRENT STATUS: NOT WIRED INTO TRACKING SERVICE
// The TrackingService does NOT call this class. It exists only for reference.
// ============================================================================

import 'dart:async';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geowake2/core/ekf/ekf_orchestrator.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';
import 'package:geowake2/services/transfer_utils.dart';

/// @deprecated This class will be completely replaced with EKF implementation.
///
/// A basic dead reckoning implementation using accelerometer data.
///
/// ⚠️ WARNING: This implementation has severe accuracy limitations:
/// - Drift accumulates within seconds
/// - Position resets every 10 seconds (loses all progress)
/// - No sensor calibration or bias compensation
/// - No orientation tracking (assumes level device)
///
/// DO NOT RELY ON THIS FOR PRODUCTION USE.
@Deprecated('Will be replaced with EKF implementation - see docs/ekf_planning/')
class SensorFusionManager {
  late double _initialLat;
  late double _initialLon;
  double _posX = 0.0; // Displacement in meters eastwards.
  double _posY = 0.0; // Displacement in meters northwards.
  double _velX = 0.0; // Velocity in m/s eastwards.
  double _velY = 0.0; // Velocity in m/s northwards.
  DateTime _lastUpdate = DateTime.now();

  // Maximum duration for sensor fusion before resetting integration (limits drift).
  final Duration maxFusionDuration = const Duration(seconds: 10);
  late DateTime _fusionStartTime;

  // Damping factor to reduce noise impact, value between 0 and 1.
  // Higher value means more damping.
  final double accelerationDecayFactor = 0.9;

  final StreamController<LatLng> _positionController =
      StreamController<LatLng>.broadcast();

  /// Exposes a stream of fused positions.
  Stream<LatLng> get fusedPositionStream => _positionController.stream;

  /// Optional EKF public state stream (not wired into app yet).
  Stream<EkfPublicState> get ekfStateStream => _ekfStateController.stream;
  EkfPublicState? get lastEkfState => _lastEkfState;

  /// Accept an optional accelerometer stream (for testing).
  final Stream<AccelerometerEvent>? accelerometerStream;
  /// Accept an optional gyroscope stream (for testing).
  final Stream<GyroscopeEvent>? gyroscopeStream;
  /// Optional EKF route geometry (enables EKF path when provided).
  RouteGeometry? _routeGeometry;
  /// Flag to enable EKF path (default false to avoid regression).
  bool _enableEkf;

  final StreamController<EkfPublicState> _ekfStateController =
      StreamController<EkfPublicState>.broadcast();
  EkfPublicState? _lastEkfState;

  EkfOrchestrator? _ekfOrchestrator;
  bool _fftEnabled = true;
  List<TransitLegStops> _transitLegStops = const [];

  /// Callback for station snap confirmed events from EKF (§24.2).
  void Function(StationSnapConfirmed)? onStationSnapConfirmed;

  SensorFusionManager({
    required LatLng initialPosition,
    Stream<AccelerometerEvent>? accelerometerStream,
    Stream<GyroscopeEvent>? gyroscopeStream,
     RouteGeometry? routeGeometry,
     bool enableEkf = false,
  }) : accelerometerStream = accelerometerStream,
       gyroscopeStream = gyroscopeStream,
       _routeGeometry = routeGeometry,
       _enableEkf = enableEkf {
    _initialLat = initialPosition.latitude;
    _initialLon = initialPosition.longitude;
    _lastUpdate = DateTime.now();
    _fusionStartTime = DateTime.now();
    _positionController.add(initialPosition);

    if (_enableEkf && _routeGeometry != null) {
      _ekfOrchestrator = EkfOrchestrator(route: _routeGeometry!);
      _ekfOrchestrator!.setFftEnabled(_fftEnabled);
      _ekfOrchestrator!.onStationSnapConfirmed = _handleStationSnapConfirmed;
    }
  }

  void _handleStationSnapConfirmed(StationSnapConfirmed event) {
    onStationSnapConfirmed?.call(event);
  }

  void setFftEnabled(bool enabled) {
    _fftEnabled = enabled;
    _ekfOrchestrator?.setFftEnabled(enabled);
  }

  void updateRouteGeometry(RouteGeometry? geometry) {
    _routeGeometry = geometry;
    _enableEkf = geometry != null;
    if (!_enableEkf || _routeGeometry == null) {
      _ekfOrchestrator = null;
      _lastEkfState = null;
      return;
    }

    _ekfOrchestrator = EkfOrchestrator(route: _routeGeometry!);
    _ekfOrchestrator!.setFftEnabled(_fftEnabled);
    _ekfOrchestrator!.onStationSnapConfirmed = _handleStationSnapConfirmed;
    _lastEkfState = null;
  }

  void updateGps(Position position) {
    final ekf = _ekfOrchestrator;
    if (ekf == null) return;
    final timestamp = Duration(
      microseconds: _imuClock?.elapsedMicroseconds ??
          DateTime.now().millisecondsSinceEpoch * 1000,
    );
    final sGps = _routeGeometry?.projectLatLng(
      position.latitude,
      position.longitude,
    );
    if (sGps != null && sGps.isFinite) {
      final leg = _legForProgress(sGps);
      if (leg != null) {
        ekf.setStationContext(
          stationMeters: leg.stopMeters,
          isMetroLeg: leg.isMetro,
        );
      } else {
        ekf.setStationContext(stationMeters: const [], isMetroLeg: false);
      }
    }
    ekf.onGpsFixAuto(
      GpsFix(
        lat: position.latitude,
        lng: position.longitude,
        accuracyMeters: position.accuracy,
        speedMps: position.speed,
        timestamp: timestamp,
      ),
    );
  }

  void updateTransitLegStops(List<TransitLegStops> stops) {
    _transitLegStops = stops;
  }

  StreamSubscription? _accelerometerSubscription;
  StreamSubscription? _gyroscopeSubscription;
  GyroscopeEvent? _lastGyro;
  Stopwatch? _imuClock;

  /// Starts sensor fusion by listening to accelerometer events.
  void startFusion() {
    try {
      _imuClock ??= Stopwatch()..start();
      _lastGyro = null;

      // Lazily resolve the default sensors stream so unit/widget tests that
      // don't have the plugin registered don't throw during construction.
      final Stream<AccelerometerEvent> stream =
          (accelerometerStream ?? accelerometerEvents).handleError((_) {});

      _accelerometerSubscription = stream.listen(
        (AccelerometerEvent event) {
          final now = DateTime.now();
          final dt = now.difference(_lastUpdate).inMilliseconds / 1000.0;
          _lastUpdate = now;

          // Check if fusion has been running longer than the maximum duration.
          if (now.difference(_fusionStartTime) > maxFusionDuration) {
            // Reset integration to limit accumulated error.
            _velX = 0.0;
            _velY = 0.0;
            _posX = 0.0;
            _posY = 0.0;
            _fusionStartTime = now;
            // Optionally, update _initialLat and _initialLon with the last fused position.
          }

          // Apply damping to current velocity and then integrate acceleration.
          _velX =
              _velX * accelerationDecayFactor +
              event.x * dt * (1 - accelerationDecayFactor);
          _velY =
              _velY * accelerationDecayFactor +
              event.y * dt * (1 - accelerationDecayFactor);

          // Update displacement based on damped velocity.
          _posX += _velX * dt;
          _posY += _velY * dt;

          // Convert displacement to change in latitude and longitude (approximate conversion).
          final dLat = _posY / 111320; // meters to degrees latitude.
          final dLon = _posX / (111320 * cos(_initialLat * pi / 180));
          final fusedLat = _initialLat + dLat;
          final fusedLon = _initialLon + dLon;
          _positionController.add(LatLng(fusedLat, fusedLon));

          final ekf = _ekfOrchestrator;
          if (ekf != null) {
            final timestamp = Duration(
              microseconds: _imuClock?.elapsedMicroseconds ??
                  now.millisecondsSinceEpoch * 1000,
            );
            final gx = _lastGyro?.x ?? 0.0;
            final gy = _lastGyro?.y ?? 0.0;
            final gz = _lastGyro?.z ?? 0.0;
            ekf.onImuSample(
              ImuSample(
                ax: event.x,
                ay: event.y,
                az: event.z,
                gx: gx,
                gy: gy,
                gz: gz,
                timestamp: timestamp,
              ),
            );
            _lastEkfState = ekf.publicState;
            _ekfStateController.add(_lastEkfState!);
          }
        },
        onError: (_) {
          // If the platform stream errors (e.g., MissingPluginException), disable fusion.
          _accelerometerSubscription?.cancel();
          _accelerometerSubscription = null;
        },
        cancelOnError: true,
      );

      final gyroStream = gyroscopeStream ?? gyroscopeEvents;
      _gyroscopeSubscription = gyroStream.handleError((_) {}).listen(
        (GyroscopeEvent event) {
          _lastGyro = event;
        },
        onError: (_) {
          _gyroscopeSubscription?.cancel();
          _gyroscopeSubscription = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      // In widget/unit tests or unsupported platforms, sensors_plus may not be registered.
      // Treat sensor fusion as unavailable instead of crashing.
      _accelerometerSubscription = null;
      _gyroscopeSubscription = null;
    }
  }

  /// Stops sensor fusion.
  void stopFusion() {
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    _gyroscopeSubscription?.cancel();
    _gyroscopeSubscription = null;
    _imuClock = null;
    _lastGyro = null;
  }

  /// Resets the fusion manager with a new initial position.
  void reset(LatLng initialPosition) {
    _initialLat = initialPosition.latitude;
    _initialLon = initialPosition.longitude;
    _posX = 0.0;
    _posY = 0.0;
    _velX = 0.0;
    _velY = 0.0;
    _lastUpdate = DateTime.now();
    _fusionStartTime = DateTime.now();
    _positionController.add(initialPosition);
    _imuClock = Stopwatch()..start();
    _lastGyro = null;
    _transitLegStops = const [];
  }

  TransitLegStops? _legForProgress(double s) {
    for (final leg in _transitLegStops) {
      if (s >= leg.legStartMeters && s <= leg.legEndMeters) {
        return leg;
      }
    }
    return null;
  }

  void dispose() {
    stopFusion();
    _positionController.close();
    _ekfStateController.close();
  }
}
