import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('AlarmEvaluator Rewrite (State Machine)', () {
    // Helper to create dummy TransitLegStops
    TransitLegStops createLeg({
      required bool isMetro,
      required int numStops,
      required double startMeters,
      required double length,
    }) {
      return TransitLegStops(
        legStartMeters: startMeters,
        legEndMeters: startMeters + length,
        numStops: numStops,
        stopPositions: List.generate(numStops, (_) => const LatLng(0, 0)),
        stopMeters: List.generate(
          numStops,
          (i) => startMeters + ((i + 1) * (length / (numStops + 1))),
        ),
        lineName: isMetro ? 'Metro Line' : 'Walk',
        isActualPositions: true,
        isMetro: isMetro,
        stopNames: List.generate(numStops, (i) => 'Stop $i'),
      );
    }

    test('Scenario 1: Walk -> Metro -> Walk', () {
      // Leg 0: Walk (0-1000m)
      // Leg 1: Metro (1000-5000m, 10 stops)
      // Leg 2: Walk (5000-6000m) - FINAL

      final legs = [
        createLeg(isMetro: false, numStops: 0, startMeters: 0, length: 1000),
        createLeg(isMetro: true, numStops: 10, startMeters: 1000, length: 4000),
        createLeg(isMetro: false, numStops: 0, startMeters: 5000, length: 1000),
      ];

      final firedLegs = <String>{};
      final firedEvents =
          <int>{}; // Not strictly used by new logic but good for compat

      // ----------------------------------------------------------------
      // LEG 0: Walk (Preboarding for Metro)
      // ----------------------------------------------------------------

      // At 300m (30%): No Alarm
      var result = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 1.0, // 1 stop prior
        progressMeters: 300.0,
        allEvents: [], // New logic shouldn't rely on this list for triggers
        firedEventIndexes: firedEvents,
        firedLegIds: firedLegs,
        isMetroLeg: false, // Currently on walk leg
        transitLegs: legs,
        currentLegIndex: 0,
        isFinalLeg: false,
      );
      expect(result, isNull, reason: "Walk leg at 30% should not fire");

      // At 500m (50%): FIRE Preboarding (>=40% progress)
      result = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 1.0,
        progressMeters: 500.0,
        allEvents: [],
        firedEventIndexes: firedEvents,
        firedLegIds: firedLegs,
        isMetroLeg: false,
        transitLegs: legs,
        currentLegIndex: 0,
        isFinalLeg: false,
      );
      expect(result, isNotNull, reason: "Walk leg at 50% should fire 60% rule");
      expect(result?.eventType, AlarmEventType.preBoarding);

      firedLegs.add(legs[0].legId); // Mark Leg 0 as done

      // At 900m (90%): No Alarm (Already fired)
      result = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 1.0,
        progressMeters: 900.0,
        allEvents: [],
        firedEventIndexes: firedEvents,
        firedLegIds: firedLegs,
        isMetroLeg: false,
        transitLegs: legs,
        currentLegIndex: 0,
        isFinalLeg: false,
      );
      expect(result, isNull, reason: "Already fired for Leg 0");

      // ----------------------------------------------------------------
      // LEG 1: Metro (Switch/Get Off)
      // ----------------------------------------------------------------

      // Stop 8 (Passed 8/10). Target is 1 stop prior (9/10).
      // Leg 1 starts at 1000. Stops are distributed.
      // Let's force stopsPassed injection if possible, or simulate meters.
      // Since current evaluator calculates stops from meters, we rely on TransferUtils.countStopsPassed.
      // Leg 1: 1000-5000. 10 stops.
      // Stop 8 meter ~= 1000 + (8+1)*(4000/11) = 1000 + 3272 = 4272m.

      // At 4000m (~7 stops passed). Target is 1 stop prior (ie stop index >= 10-1 = 9).
      // Wait, 1 stop prior means we alert BEFORE the last stop.
      // The last stop is the alighting station.
      // If numStops=10, the stops are indices 0..9.
      // If we want 1 stop prior, we fire when we PASS stop index 8 (which is the one before 9).

      // Let's test at 4500m (passed ~9 stops).
      result = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 1.0,
        progressMeters: 4700.0,
        allEvents: [],
        firedEventIndexes: firedEvents,
        firedLegIds: firedLegs,
        isMetroLeg: true,
        transitLegs: legs,
        currentLegIndex: 1,
        isFinalLeg: false, // Next leg is walk
      );
      expect(result, isNotNull, reason: "Passed N-1 stops on Metro");
      expect(
        result?.eventType,
        AlarmEventType.modeChange,
      ); // Metro -> Walk is a mode change

      firedLegs.add(legs[1].legId);

      // ----------------------------------------------------------------
      // LEG 2: Walk (Final Destination)
      // ----------------------------------------------------------------

      // Leg 2: 5000-6000.
      // 60% rule = 5000 + 0.6*1000 = 5600m.

      // At 5200m (20%): No Alarm
      result = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 1.0,
        progressMeters: 5200.0,
        allEvents: [],
        firedEventIndexes: firedEvents,
        firedLegIds: firedLegs,
        isMetroLeg: false,
        transitLegs: legs,
        currentLegIndex: 2,
        isFinalLeg: true,
      );
      expect(result, isNull);

      // At 5700m (70%): Fire Destination
      result = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 1.0,
        progressMeters: 5700.0,
        allEvents: [],
        firedEventIndexes: firedEvents,
        firedLegIds: firedLegs,
        isMetroLeg: false,
        transitLegs: legs,
        currentLegIndex: 2,
        isFinalLeg: true,
      );
      expect(result, isNotNull);
      expect(result?.eventType, AlarmEventType.finalDestination);
    });
  });
}
