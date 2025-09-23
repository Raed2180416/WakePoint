// lib/services/sensor_fusion.dart
import 'dart:async';
import 'dart:math';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// A simple sensor fusion manager that performs dead reckoning using accelerometer data.
/// In production, you would likely use a full Extended Kalman Filter.
class SensorFusionManager {
  late double _initialLat;
  late double _initialLon;
  double _posX = 0.0; // Displacement in meters eastwards.
  double _posY = 0.0; // Displacement in meters northwards.
  double _velX = 0.0; // Velocity in m/s eastwards.
  double _velY = 0.0; // Velocity in m/s northwards.
  DateTime _lastUpdate = DateTime.now();

  final StreamController<LatLng> _positionController =
      StreamController<LatLng>.broadcast();

  /// Exposes a stream of fused positions.
  Stream<LatLng> get fusedPositionStream => _positionController.stream;

  /// Accept an optional accelerometer stream for testing.
  final Stream<AccelerometerEvent> accelerometerStream;
  
  SensorFusionManager({
    required LatLng initialPosition,
    Stream<AccelerometerEvent>? accelerometerStream,
  }) : accelerometerStream = accelerometerStream ?? accelerometerEvents {
    _initialLat = initialPosition.latitude;
    _initialLon = initialPosition.longitude;
    _lastUpdate = DateTime.now();
    _positionController.add(initialPosition);
  }

  StreamSubscription? _accelerometerSubscription;

  /// Starts the sensor fusion process.
  void startFusion() {
    _accelerometerSubscription = accelerometerStream.listen((AccelerometerEvent event) {
      final now = DateTime.now();
      final dt = now.difference(_lastUpdate).inMilliseconds / 1000.0;
      _lastUpdate = now;

      // Update velocities (simple integration).
      _velX += event.x * dt;
      _velY += event.y * dt;

      // Update displacements.
      _posX += _velX * dt;
      _posY += _velY * dt;

      // Convert displacement to lat/lon changes.
      final dLat = _posY / 111320; // approximate conversion
      final dLon = _posX / (111320 * cos(_initialLat * pi / 180));
      final fusedLat = _initialLat + dLat;
      final fusedLon = _initialLon + dLon;
      final fusedPosition = LatLng(fusedLat, fusedLon);

      _positionController.add(fusedPosition);
    });
  }

  /// Stops the sensor fusion process.
  void stopFusion() {
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
  }

  /// Resets the fusion manager state with a new initial position.
  void reset(LatLng initialPosition) {
    _initialLat = initialPosition.latitude;
    _initialLon = initialPosition.longitude;
    _posX = 0.0;
    _posY = 0.0;
    _velX = 0.0;
    _velY = 0.0;
    _lastUpdate = DateTime.now();
    _positionController.add(initialPosition);
  }

  void dispose() {
    stopFusion();
    _positionController.close();
  }
}

// This file is not a real test; provide an empty main to satisfy the test runner.
void main() {}
