// Pure tests for the post-dismiss routing decision. This is the load-bearing
// core-safety guarantee: the alarm-dismiss path can NEVER be broken by
// post-arrival logic — a bad input can only ever resolve to Home.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/screens/monetization/post_arrival_screen.dart';
import 'package:geowake2/services/monetization/post_arrival_service.dart';

void main() {
  group('decidePostArrival', () {
    test('not ready → Home (never show a half-initialized surface)', () {
      final d = decidePostArrival(
        isReady: false,
        alarmDismissed: true,
        stationName: 'Indiranagar',
      );
      expect(d.goPostArrival, isFalse);
      expect(d.card, isNull);
    });

    test('alarm not dismissed → Home (never during the ring)', () {
      final d = decidePostArrival(
        isReady: true,
        alarmDismissed: false,
        stationName: 'Indiranagar',
      );
      expect(d.goPostArrival, isFalse);
    });

    test('ready + dismissed + valid station → show a validated card', () {
      final d = decidePostArrival(
        isReady: true,
        alarmDismissed: true,
        stationName: 'Indiranagar',
      );
      expect(d.goPostArrival, isTrue);
      expect(d.card, isNotNull);
      expect(d.card!.title, "You've arrived at Indiranagar");
      // The card is already validated by PostArrivalService.build.
      expect(d.card!.primaryAction, isNotNull);
    });

    test('empty station → generic card, still shows', () {
      final d = decidePostArrival(
        isReady: true,
        alarmDismissed: true,
        stationName: '   ',
      );
      expect(d.goPostArrival, isTrue);
      expect(d.card!.title, "You've arrived");
    });

    test('PII-looking station (build throws) → Home, no throw', () {
      // A long digit-run trips PostArrivalCard's PII guard, which throws a
      // PostArrivalPrivacyError (an Error, not an Exception). The decision must
      // swallow it and fall back to Home rather than break the dismiss path.
      late PostArrivalDecision d;
      expect(() {
        d = decidePostArrival(
          isReady: true,
          alarmDismissed: true,
          stationName: 'Station 9876543',
        );
      }, returnsNormally);
      expect(d.goPostArrival, isFalse);
      expect(d.card, isNull);

      // Sanity: prove the raw build really does throw for this input.
      expect(
        () => PostArrivalService.build(stationName: 'Station 9876543'),
        throwsA(isA<PostArrivalPrivacyError>()),
      );
    });
  });
}
