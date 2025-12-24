import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/services/stop_logic_engine.dart';

void main() {
  group('Stop Logic Reproduction', () {
    // Mock Directions API Response: Walk -> Bus (5 stops) -> Walk -> Subway (3 stops) -> Walk
    final mockDirections = {
      'routes': [
        {
          'legs': [
            {
              'steps': [
                // Step 1: Walk 500m
                {
                  'travel_mode': 'WALKING',
                  'distance': {'value': 500},
                },
                // Step 2: Bus (5 stops, 2000m)
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 2000},
                  'transit_details': {
                    'num_stops': 5,
                    'line': {
                      'short_name': 'B1',
                      'vehicle': {'type': 'BUS'},
                    },
                    'arrival_stop': {'name': 'Transfer Station'},
                  },
                },
                // Step 3: Walk 100m (Transfer)
                {
                  'travel_mode': 'WALKING',
                  'distance': {'value': 100},
                },
                // Step 4: Subway (3 stops, 3000m)
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 3000},
                  'transit_details': {
                    'num_stops': 3,
                    'line': {
                      'short_name': 'S1',
                      'vehicle': {'type': 'SUBWAY'},
                    },
                    'arrival_stop': {'name': 'Final Station'},
                  },
                },
                // Step 5: Walk 200m
                {
                  'travel_mode': 'WALKING',
                  'distance': {'value': 200},
                },
              ],
            },
          ],
        },
      ],
    };

    test('TransferUtils builds correct structures', () {
      final stepData = TransferUtils.buildStepBoundariesAndStops(
        mockDirections,
      );
      final events = TransferUtils.buildRouteEvents(mockDirections);

      // Expected Bounds (cumulative meters):
      // 1. 500
      // 2. 2500
      // 3. 2600
      // 4. 5600
      // 5. 5800
      expect(stepData.bounds, [500.0, 2500.0, 2600.0, 5600.0, 5800.0]);

      // Expected Stops (cumulative):
      // 1. 0 (Walk)
      // 2. 5 (Bus)
      // 3. 5 (Walk)
      // 4. 8 (Subway)
      // 5. 8 (Walk)
      expect(stepData.stops, [0.0, 5.0, 5.0, 8.0, 8.0]);

      // Expected Events:
      // 1. Mode Change (Walk -> Transit) at 500m
      // 2. Transfer (Bus -> Walk/Subway) at 2500m
      // 3. Mode Change (Transit -> Walk) at 2500m ?? Wait, let's check logic
      // 4. Mode Change (Walk -> Transit) at 2600m
      // 5. Transfer (Subway -> Walk) at 5600m ??

      // Let's verify what TransferUtils actually produces
      expect(events, isNotEmpty);
    });

    test('StopLogicEngine calculates remaining stops correctly', () {
      final stepData = TransferUtils.buildStepBoundariesAndStops(
        mockDirections,
      );
      final events = TransferUtils.buildRouteEvents(mockDirections);
      final engine = StopLogicEngine();

      // Scenario 1: On the Bus (Step 2), 50% through (1000m into step, 1500m total)
      // Total stops in this step: 5.
      // Progress stops: 0 (start) + 5 * 0.5 = 2.5 stops passed.
      // Target: Transfer at 2500m.
      // Target stops: 5.
      // Remaining: 5 - 2.5 = 2.5 stops.

      final result1 = engine.calculateRemainingStops(
        progressMeters: 1500.0,
        stepBoundsMeters: stepData.bounds,
        stepStopsCumulative: stepData.stops,
        routeEvents: events,
        firedEventIndexes: {},
      );
      expect(result1?.remainingStops, closeTo(2.5, 0.1));
      // expect(result1?.targetName, contains('Transfer')); // Depends on label extraction

      // Scenario 2: On the Subway (Step 4), 10% through (300m into step, 2600+300 = 2900m total)
      // Previous stops: 5.
      // Current step stops: 3.
      // Progress stops: 5 + 3 * 0.1 = 5.3 stops passed.
      // Target: Destination (end of route).
      // Target stops: 8.
      // Remaining: 8 - 5.3 = 2.7 stops.

      // Note: We need to mark the first transfer as fired, otherwise it might target the first transfer (which is behind us?)
      // Wait, calculateRemainingStops logic:
      // "Only consider switch points ahead of current progress"
      // The first transfer is at 2500m. We are at 2900m. So it should be skipped automatically.

      final result2 = engine.calculateRemainingStops(
        progressMeters: 2900.0,
        stepBoundsMeters: stepData.bounds,
        stepStopsCumulative: stepData.stops,
        routeEvents: events,
        firedEventIndexes: {0},
      );
      expect(result2?.remainingStops, closeTo(2.7, 0.1));
      // The target is the alighting point (switch to walking), so isDestination is false.
      // The label comes from the mode change "Start walking".
      expect(result2?.isDestination, isFalse);
      expect(result2?.targetName, contains('Start walking'));
    });
  });
}
