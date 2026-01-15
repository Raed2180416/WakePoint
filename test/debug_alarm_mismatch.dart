import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  test('Debug Data Mismatch: API=5 stops, matched=3 stops', () {
    // 1. Create a "Broken" JSON that mimics an API vs matching mismatch
    // API says 5 stops ("numStops": 5), but we only matched 3 positions.
    final brokenLegJson = {
      'legStartMeters': 0.0,
      'legEndMeters': 1000.0,
      'numStops': 5, // <--- API SAYS 5
      'stopPositions': [
        {'lat': 10.0, 'lng': 10.0},
        {'lat': 10.001, 'lng': 10.001},
        {'lat': 10.002, 'lng': 10.002},
      ], // <--- MATCH FOUND 3
      'stopMeters': [100.0, 500.0, 900.0],
      'lineName': 'Metro Line',
      'isActualPositions': true, // <--- MATCHED POSITIONS
      'isMetro': true,
      'stopNames': ['A', 'B', 'C'],
    };

    // 2. Deserialize (This should trigger HEALING)
    print('Deserializing Broken Leg...');
    final leg = TransitLegStops.fromJson(brokenLegJson);

    // 3. Verify Healing
    print('Leg numStops after deserialization: ${leg.numStops}');
    expect(
      leg.numStops,
      3,
      reason: "Data Healing should have clamped numStops to 3",
    );

    // 4. Setup Alarm Evaluator context
    // Target: "1 stop prior"
    // Event is at the end (Station C).
    // Event Stop Count (using leg structure) should now be 3 (sum of leg stops).
    final event = RouteEventBoundary(
      meters: 1000.0,
      type: 'final_station',
      label: 'Station C',
      associatedLegIndex: 0, // Explicitly mapped
    );

    // 5. Evaluate at 850m (Approaching Station C, passed B)
    // Progress: passed A(100), B(500). Count = 2.
    // Remaining = Total(3) - Progress(2) = 1.
    // Threshold = 1.
    // Should FIRE.

    print('Evaluating Alarm at 850m (Past 2 stops)...');
    final trigger = AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.stops,
      userValue: 1, // 1 stop prior
      progressMeters: 850.0,
      allEvents: [event],
      firedEventIndexes: {},
      firedLegIds: {},
      isMetroLeg: true,
      transitLegs: [leg],
      currentLegIndex: 0,
      isFinalLeg: true,
    );

    if (trigger != null) {
      print('SUCCESS: Alarm Triggered! RemStops: ${trigger.remainingStops}');
    } else {
      print('FAILURE: Alarm did NOT trigger.');
    }

    expect(
      trigger,
      isNotNull,
      reason: "Alarm should fire now that data is consistent",
    );
  });
}
