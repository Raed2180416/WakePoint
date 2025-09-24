// Annotated copy of lib/services/sensor_fusion.dart
// Purpose: Explain simple dead-reckoning via accelerometer with drift limiting.

import 'dart:async'; // StreamController and subscriptions
import 'dart:math';   // cos, pi for degree conversions
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng output
import 'package:sensors_plus/sensors_plus.dart'; // Accelerometer stream

// A lightweight sensor fusion manager for dead reckoning during GPS dropouts.
// Integrates damped acceleration to velocity, then to displacement, with periodic resets
// to limit drift. Emits fused LatLng positions relative to an initial anchor.
class SensorFusionManager {
  late double _initialLat; // Anchor latitude (degrees)
  late double _initialLon; // Anchor longitude (degrees)
  double _posX = 0.0;      // Displacement east (meters)
  double _posY = 0.0;      // Displacement north (meters)
  double _velX = 0.0;      // Velocity east (m/s)
  double _velY = 0.0;      // Velocity north (m/s)
  DateTime _lastUpdate = DateTime.now();

  // Limit integration window to reduce accumulated error
  final Duration maxFusionDuration = const Duration(seconds: 10);
  late DateTime _fusionStartTime;

  // Damping factor (0..1): larger means stronger decay of previous velocity
  final double accelerationDecayFactor = 0.9;

  final StreamController<LatLng> _positionController = StreamController<LatLng>.broadcast();
  Stream<LatLng> get fusedPositionStream => _positionController.stream; // Fused outputs

  // Optional injected accelerometer stream for testing
  final Stream<AccelerometerEvent> accelerometerStream;

  SensorFusionManager({ required LatLng initialPosition, Stream<AccelerometerEvent>? accelerometerStream, })
      : accelerometerStream = accelerometerStream ?? accelerometerEvents {
    _initialLat = initialPosition.latitude;
    _initialLon = initialPosition.longitude;
    _lastUpdate = DateTime.now();
    _fusionStartTime = DateTime.now();
    _positionController.add(initialPosition); // Emit initial as baseline
  }

  StreamSubscription? _accelerometerSubscription;

  // Start integrating accelerometer events
  void startFusion() {
    _accelerometerSubscription = accelerometerStream.listen((AccelerometerEvent event) {
      final now = DateTime.now();
      final dt = now.difference(_lastUpdate).inMilliseconds / 1000.0;
      _lastUpdate = now;

      // Reset after maxFusionDuration to bound drift
      if (now.difference(_fusionStartTime) > maxFusionDuration) {
        _velX = 0.0; _velY = 0.0; _posX = 0.0; _posY = 0.0;
        _fusionStartTime = now;
      }

      // Damped velocity integration
      _velX = _velX * accelerationDecayFactor + event.x * dt * (1 - accelerationDecayFactor);
      _velY = _velY * accelerationDecayFactor + event.y * dt * (1 - accelerationDecayFactor);

      // Displacement update
      _posX += _velX * dt;
      _posY += _velY * dt;

      // Convert meters to degrees (approximate, small area assumption)
      final dLat = _posY / 111320.0;
      final dLon = _posX / (111320.0 * cos(_initialLat * pi / 180.0));
      final fusedLat = _initialLat + dLat;
      final fusedLon = _initialLon + dLon;
      _positionController.add(LatLng(fusedLat, fusedLon));
    });
  }

  // Stop listening and clear subscription
  void stopFusion() { _accelerometerSubscription?.cancel(); _accelerometerSubscription = null; }

  // Reset anchors and integrators, emit new initial
  void reset(LatLng initialPosition) {
    _initialLat = initialPosition.latitude;
    _initialLon = initialPosition.longitude;
    _posX = 0.0; _posY = 0.0; _velX = 0.0; _velY = 0.0;
    _lastUpdate = DateTime.now();
    _fusionStartTime = DateTime.now();
    _positionController.add(initialPosition);
  }

  void dispose() { stopFusion(); _positionController.close(); }
}
