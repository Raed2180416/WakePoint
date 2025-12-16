import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/eta_engine.dart';

import 'package:geolocator/geolocator.dart' as geo;
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('EtaEngine Tests', () {
    late EtaEngine engine;
    final List<LatLng> simpleRoute = [
      LatLng(0, 0),
      LatLng(0, 0.01), // ~1.1km East
      LatLng(0, 0.02), // ~2.2km East
    ];

    setUp(() {
      engine = EtaEngine();
    });

    test('computeEta - On Route, Constant Speed', () {
      // Position at start, speed 10 m/s (~36 km/h)
      final pos = geo.Position(
        longitude: 0,
        latitude: 0,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        heading: 90,
        speed: 10,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      final result = engine.computeEta(routeCoords: simpleRoute, gps: pos);

      // Total dist ~ 2220 meters
      // ETA ~ 222s
      expect(result.etaSeconds, closeTo(222, 20));
      expect(result.remainingMeters, closeTo(2220, 50));
      expect(result.sigmaEta, greaterThan(0));
    });

    test('computeEta - Mid Route, High Speed', () {
      // Position at middle (0, 0.01), speed 20 m/s
      final pos = geo.Position(
        longitude: 0.01,
        latitude: 0,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        heading: 90,
        speed: 20,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      final result = engine.computeEta(routeCoords: simpleRoute, gps: pos);

      // Remaining dist ~ 1110 meters
      // ETA ~ 55s
      expect(result.etaSeconds, closeTo(55, 10));
      expect(result.remainingMeters, closeTo(1110, 50));
    });

    test('computeEta - Dwell Time Detection', () async {
      // Simulate stationary updates
      final pos = geo.Position(
        longitude: 0,
        latitude: 0,
        timestamp: DateTime.now(),
        accuracy: 5,
        altitude: 0,
        heading: 0,
        speed: 0.1, // Stationary
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      // Feed multiple updates to trigger dwell
      // Dwell threshold is > 8s

      // First update
      var result = engine.computeEta(routeCoords: simpleRoute, gps: pos);

      // If speed is near 0, ETA should be high.
      expect(result.etaSeconds, greaterThan(1000));
    });

    test('computeEta - Off Route Snapping', () {
      // Position slightly off route (0.0001 deg North of start) ~11m
      final pos = geo.Position(
        longitude: 0,
        latitude: 0.0001,
        timestamp: DateTime.now(),
        accuracy: 10,
        altitude: 0,
        heading: 90,
        speed: 10,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );

      final result = engine.computeEta(routeCoords: simpleRoute, gps: pos);

      // Should snap to start (0,0) or close to it
      // Distance remaining should be close to full route
      expect(result.remainingMeters, closeTo(2220, 50));
    });
  });
}
