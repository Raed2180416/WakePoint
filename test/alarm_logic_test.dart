import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/stop_logic_engine.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  group('StopLogicEngine Integration Tests', () {
    late StopLogicEngine engine;

    setUp(() {
      engine = StopLogicEngine();
    });

    test('calculateRemainingStops returns correct values', () {
      final stepBounds = [1000.0, 2000.0];
      final stepStops = [2.0, 5.0];
      final routeEvents = <RouteEventBoundary>[];

      // 500m progress -> 50% of first step (2 stops) -> 1 stop passed
      // Target is end of route (2000m) -> 5 stops total
      // Remaining = 5 - 1 = 4 stops
      final result = engine.calculateRemainingStops(
        progressMeters: 500.0,
        stepBoundsMeters: stepBounds,
        stepStopsCumulative: stepStops,
        routeEvents: routeEvents,
        firedEventIndexes: {},
      );

      expect(result, isNotNull);
      expect(result!.remainingStops, closeTo(4.0, 0.1));
      expect(result.isDestination, isTrue);
    });

    test('calculateRemainingStops handles switch points', () {
      final stepBounds = [1000.0, 2000.0];
      final stepStops = [2.0, 5.0];
      final routeEvents = [
        RouteEventBoundary(meters: 1500.0, label: 'Switch', type: 'transfer'),
      ];

      // 500m progress -> 1 stop passed
      // Target is switch at 1500m
      // 1500m is 50% of second step (starts 1000m, ends 2000m, stops 2->5)
      // Stops at 1500m = 2 + (3 * 0.5) = 3.5 stops
      // Remaining = 3.5 - 1 = 2.5 stops
      final result = engine.calculateRemainingStops(
        progressMeters: 500.0,
        stepBoundsMeters: stepBounds,
        stepStopsCumulative: stepStops,
        routeEvents: routeEvents,
        firedEventIndexes: {},
      );

      expect(result, isNotNull);
      expect(result!.remainingStops, closeTo(2.5, 0.1));
      expect(result.targetName, equals('Switch'));
      expect(result.isDestination, isFalse);
    });
  });
}
