import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/stop_logic_engine.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('StopLogicEngine Tests', () {
    late StopLogicEngine engine;

    // Mock Data
    final List<double> stepBounds = [1000, 2000, 3000]; // 3 steps, 1km each
    final List<double> stepStops = [2, 5, 8]; // Cumulative stops: 2, 5, 8
    final List<RouteEventBoundary> routeEvents = [
      RouteEventBoundary(
        type: 'transfer',
        meters: 1500.0,
        label: 'Switch Train',
      ),
    ];

    setUp(() {
      engine = StopLogicEngine();
    });

    // Helper to create a dummy Position
    Position createPosition(double lat, double lng) {
      return Position(
        longitude: lng,
        latitude: lat,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        heading: 0,
        speed: 0,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );
    }

    test('calculateRemainingStops - Before Switch', () {
      final result = engine.calculateRemainingStops(
        progressMeters: 500,
        stepBoundsMeters: stepBounds,
        stepStopsCumulative: stepStops,
        routeEvents: routeEvents,
        firedEventIndexes: {},
      );

      expect(result, isNotNull);
      expect(result!.targetName, contains('Switch Train'));
      expect(result.remainingStops, closeTo(2.5, 0.1));
    });

    test('calculateRemainingStops - After Switch', () {
      final result = engine.calculateRemainingStops(
        progressMeters: 1800,
        stepBoundsMeters: stepBounds,
        stepStopsCumulative: stepStops,
        routeEvents: routeEvents,
        firedEventIndexes: {0}, // Switch fired
      );

      expect(result, isNotNull);
      expect(result!.targetName, contains('Destination'));
      expect(result.remainingStops, closeTo(3.6, 0.1));
    });

    test('checkPreBoarding - Approaching Station', () {
      final station = LatLng(10, 10);
      final currentPos = createPosition(10, 10.005); // ~550m away
      final startPos = LatLng(10, 11); // Far away

      final result = engine.checkPreBoarding(
        currentPosition: currentPos,
        firstTransitBoarding: station,
        startPosition: startPos,
      );

      expect(result, isNotNull);
      expect(result!.shouldTrigger, isTrue);
      expect(result.shouldSuppress, isFalse);
    });

    test('checkPreBoarding - Suppress if started near station', () {
      final station = LatLng(10, 10);
      final currentPos = createPosition(10, 10.001); // ~110m away
      final startPos = LatLng(10, 10.001); // Also near

      final result = engine.checkPreBoarding(
        currentPosition: currentPos,
        firstTransitBoarding: station,
        startPosition: startPos,
      );

      expect(result, isNotNull);
      expect(result!.shouldTrigger, isFalse);
      expect(result.shouldSuppress, isTrue);
    });

    test('checkPreBoarding - Far from station', () {
      final station = LatLng(52.520, 13.400);
      final currentPos = createPosition(52.500, 13.400); // Far away
      final startPos = LatLng(52.500, 13.400);

      final result = engine.checkPreBoarding(
        currentPosition: currentPos,
        firstTransitBoarding: station,
        startPosition: startPos,
      );

      expect(result, isNotNull);
      expect(result!.shouldTrigger, isFalse);
    });
  });
}
