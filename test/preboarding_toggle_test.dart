import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Preboarding toggle', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TrackingStateStore.resetCacheForTests();
    });

    test('defaults to enabled', () async {
      expect(await TrackingStateStore.preboardingEnabled(), isTrue);
    });

    test('can be disabled and persists', () async {
      await TrackingStateStore.setPreboardingEnabled(false);
      expect(await TrackingStateStore.preboardingEnabled(), isFalse);
    });

    test(
      'AlarmEvaluator still produces preBoarding triggers (suppression is in AlarmController)',
      () {
        final transitLegs = <TransitLegStops>[
          TransitLegStops(
            legStartMeters: 0,
            legEndMeters: 1000,
            numStops: 0,
            stopPositions: const [],
            stopMeters: const [],
            lineName: 'Bus',
            isMetro: false,
          ),
          TransitLegStops(
            legStartMeters: 1000,
            legEndMeters: 5000,
            numStops: 5,
            stopPositions: const [],
            stopMeters: const [],
            lineName: 'Green Line',
            isMetro: true,
          ),
        ];

        // This progress is past the 40% driven-portion threshold (0.4 * 1000 = 400).
        final trigger = AlarmEvaluator.evaluateCoinciding(
          mode: AlarmMode.stops,
          userValue: 1,
          progressMeters: 450,
          allEvents: const [],
          firedEventIndexes: <int>{},
          firedLegIds: <String>{},
          isMetroLeg: false,
          transitLegs: transitLegs,
          currentLegIndex: 0,
          isFinalLeg: false,
        );

        expect(trigger, isNotNull);
        expect(trigger!.eventType, AlarmEventType.preBoarding);
        expect(trigger.message, contains('Approaching metro station'));
      },
    );
  });
}
