import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A fake GPS provider that simulates a user moving along a predefined route.
class MockLocationProvider {
  final _controller = StreamController<Position>();
  Stream<Position> get positionStream => _controller.stream;

  /// Simulates the journey by feeding route points into the stream.
  Future<void> playRoute(List<LatLng> route) async {
    for (int i = 0; i < route.length; i++) {
      final point = route[i];

      final fakePosition = Position(
        latitude: point.latitude,
        longitude: point.longitude,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: 0.0,
        headingAccuracy: 0.0,
        speed: 15.0, // meters per second (~54 km/h)
        speedAccuracy: 1.0,
      );

      _controller.add(fakePosition);
      // Wait for a tiny moment to allow the stream to be processed.
      await Future.delayed(const Duration(milliseconds: 50));
    }
    await _controller.close();
  }

  void dispose() {
    _controller.close();
  }
}

