// lib/services/sensor_fusion.dart
import 'dart:async';
import 'dart:math';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// A sensor fusion manager that performs dead reckoning using accelerometer data.
/// In production you might use a full Extended Kalman Filter.
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

  /// Accept an optional accelerometer stream (for testing).
  final Stream<AccelerometerEvent>? accelerometerStream;

  SensorFusionManager({
    required LatLng initialPosition,
    Stream<AccelerometerEvent>? accelerometerStream,
  }) : accelerometerStream = accelerometerStream {
    _initialLat = initialPosition.latitude;
    _initialLon = initialPosition.longitude;
    _lastUpdate = DateTime.now();
    _fusionStartTime = DateTime.now();
    _positionController.add(initialPosition);
  }

  StreamSubscription? _accelerometerSubscription;

  /// Starts sensor fusion by listening to accelerometer events.
  void startFusion() {
    try {
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
        },
        onError: (_) {
          // If the platform stream errors (e.g., MissingPluginException), disable fusion.
          _accelerometerSubscription?.cancel();
          _accelerometerSubscription = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      // In widget/unit tests or unsupported platforms, sensors_plus may not be registered.
      // Treat sensor fusion as unavailable instead of crashing.
      _accelerometerSubscription = null;
    }
  }

  /// Stops sensor fusion.
  void stopFusion() {
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
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
  }

  void dispose() {
    stopFusion();
    _positionController.close();
  }
}
