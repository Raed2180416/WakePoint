import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  group('AlarmEvaluator Bug Repro', () {
    test('Metro Leg 1 transfer alarm timing', () {
      // Scenario:
      // Leg 1: Driving 0-1000m
      // Leg 2: Metro 1 1000-5000m (4000m len). 4 stops (including arrival).
      // Leg 3: Metro 2 5000-8000m (3000m len). 3 stops.
      // Leg 4: Walking 8000-9000m.

      // Stops generation (simulating TransferUtils behavior)
      // Current behavior: k / (numStops + 1).
      // 4 stops. 5 segments. 1000 + 4000 * (k/5).
      // k=1: 1800
      // k=2: 2600
      // k=3: 3400
      // k=4: 4200
      // End: 5000
      // Note: 4th stop is at 4200. Gap 4200->5000 is 800m.

      final leg1 = TransitLegStops(
        legStartMeters: 0,
        legEndMeters: 1000,
        numStops: 0,
        stopPositions: [],
        stopMeters: [],
        lineName: 'Car',
        isMetro: false,
      );

      final leg2 = TransitLegStops(
        legStartMeters: 1000,
        legEndMeters: 5000,
        numStops: 4,
        stopPositions: [],
        stopMeters: [
          1800.0,
          2600.0,
          3400.0,
          4200.0,
        ], // As per current interpolation logic
        lineName: 'Blue Line',
        isMetro: true,
      );

      final leg3 = TransitLegStops(
        legStartMeters: 5000,
        legEndMeters: 8000,
        numStops: 3,
        stopPositions: [],
        stopMeters: [5750.0, 6500.0, 7250.0], // 3 stops -> div 4. 3000/4=750.
        lineName: 'Red Line',
        isMetro: true,
      );

      final transitLegs = [leg1, leg2, leg3];

      // Event: Transfer at 5000m
      final transferEvent = RouteEventBoundary(
        meters: 5000.0,
        type: AlarmEventType.transfer,
        label: 'Switch to Red Line',
      );

      final allEvents = [
        RouteEventBoundary(meters: 1000, type: AlarmEventType.preBoarding),
        transferEvent,
        RouteEventBoundary(
          meters: 8000,
          type: AlarmEventType.finalDestination,
        ), // Simplified
      ];

      final firedEvents = <int>{};
      final firedLegs = <String>{};

      // User wants alarm 1 stop prior.
      // Stop 3 is at 3400. Stop 4 is at 4200.
      // After passing 3400 (stop 3), we have passed 3 stops.
      // Remaining = 4 - 3 = 1.
      // So Alarm should fire immediately after 3400m?
      // Or if N=1 means "At the stop before destination".
      // Stop 4 is the destination "phantom". Stop 3 is the one before.
      // We want to know when it fires.

      // Test point 1: 3500m. Passed 3 stops (1800, 2600, 3400).
      // Remaining: 1.
      // Should fire.

      var result = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 1.0, // 1 stop prior
        progressMeters: 3500.0,
        allEvents: allEvents,
        firedEventIndexes: firedEvents,
        firedLegIds: firedLegs,
        isMetroLeg: true,
        transitLegs: transitLegs,
        currentLegIndex: 1,
        isFinalLeg: false,
      );

      print(
        'At 3500m (Expected Fire): ${result?.message} reason=${result?.reason}',
      );

      // Test point 2: 4300m. Passed 4 stops (1800, 2600, 3400, 4200).
      // Remaining: 0.
      // Should fire "Arriving".

      result = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 1.0,
        progressMeters: 4300.0,
        allEvents: allEvents,
        firedEventIndexes: firedEvents,
        firedLegIds: firedLegs,
        isMetroLeg: true,
        transitLegs: transitLegs,
        currentLegIndex: 1,
        isFinalLeg: false,
      );

      print(
        'At 4300m (Expected Arriving): ${result?.message} reason=${result?.reason}',
      );
    });
  });
}
