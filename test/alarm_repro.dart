import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  test('AlarmEvaluator should respect firedLegIndexes for PreBoarding', () {
    // 1. Setup Mock Leg (Walking Leg, index 0)
    final leg = TransitLegStops(
      legStartMeters: 0,
      legEndMeters: 1000,
      numStops: 0,
      lineName: 'Walk',
      stopMeters: [],
      stopNames: [],
      stopPositions: [],
      isMetro: false,
    );

    final firedLegs = <String>{};

    // 2. Evaluate at 500m (50% progress, > 40% rule)
    final trigger1 = AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.stops,
      userValue: 1.0,
      progressMeters: 500.0,
      allEvents: [],
      firedEventIndexes: {},
      firedLegIds: firedLegs,
      isMetroLeg: false,
      transitLegs: [leg],
      currentLegIndex: 0,
      isFinalLeg: false, // PreBoarding only fires if NOT final leg
    );

    expect(trigger1, isNotNull, reason: 'Should fire first time');
    expect(trigger1!.eventType, equals(AlarmEventType.preBoarding));

    // 3. Simulate AlarmController marking it as fired
    if (trigger1.legIndex != null) {
      firedLegs.add(leg.legId);
    }

    // 4. Evaluate AGAIN at same position
    final trigger2 = AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.stops,
      userValue: 1.0,
      progressMeters: 500.0, // Same position
      allEvents: [],
      firedEventIndexes: {},
      firedLegIds: firedLegs,
      isMetroLeg: false,
      transitLegs: [leg],
      currentLegIndex: 0,
      isFinalLeg: false,
    );

    expect(trigger2, isNull, reason: 'Should NOT fire second time');
  });
}
