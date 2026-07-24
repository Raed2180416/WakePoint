// Edge-case & error-path tests for the monetization layer.
//
// Companion to monetization_test.dart / post_arrival_test.dart — this file does
// NOT re-cover the happy paths those already prove. It attacks the boundaries
// and failure modes a real user hits:
//   * day-pass expiry at the EXACT millisecond boundary;
//   * re-granting a pass must extend-not-shorten and NEVER regress an active one;
//   * a permanent Pro unlock must never regress when a day-pass expires;
//   * billing/persistence I/O that throws must never corrupt entitlement;
//   * corrupt/partial persisted blobs must fail SAFE to free, never leak Pro;
//   * the frequency cap at every boundary (rides 0,1,2,cap-1,cap,huge, negative);
//   * the reliability guardrail: an ad is NEVER shown on alarm/wake/lockScreen —
//     for free users, at any ride count, under any (even degenerate) cap;
//   * the core alarm gate stays TRUE for free AND after a day-pass expires;
//   * the post-arrival card is PII-free at every input surface (station, city,
//     injected nearby labels) and is gated behind alarm dismissal.
//
// Headless & deterministic: a FakePurchaseBackend + injected clock/persistence,
// no SDK, no device.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/monetization/ad_policy.dart';
import 'package:geowake2/services/monetization/post_arrival_service.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/monetization/purchase_backend.dart';

void main() {
  // ===========================================================================
  // PremiumService — rewarded day-pass, EXACT boundary + extend/never-regress
  // ===========================================================================
  group('PremiumService — day-pass millisecond boundary', () {
    test('expiry boundary is exclusive: active at expiry-1, expired AT expiry',
        () async {
      var clock = 1000;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );

      await svc.grantRewardedDayPass(duration: const Duration(milliseconds: 100));
      final expiry = svc.dayPassExpiryMs;
      expect(expiry, 1100, reason: 'grant computes now + duration exactly');

      // One ms before expiry: fully active and ad-free.
      clock = expiry - 1;
      expect(svc.hasActiveDayPass, isTrue);
      expect(svc.isPro, isTrue);
      expect(svc.isAdFree, isTrue);

      // AT the exact expiry millisecond: expired (now < expiry is false).
      clock = expiry;
      expect(svc.hasActiveDayPass, isFalse,
          reason: 'now == expiry means the pass has elapsed');
      expect(svc.isPro, isFalse);
      expect(svc.isAdFree, isFalse);
      expect(svc.tier, EntitlementTier.free);

      // One ms after: still expired.
      clock = expiry + 1;
      expect(svc.hasActiveDayPass, isFalse);
      expect(svc.isPro, isFalse);
    });

    test('a shorter re-grant while active NEVER shortens the pass', () async {
      var clock = 0;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );

      await svc.grantRewardedDayPass(duration: const Duration(hours: 48));
      final longExpiry = svc.dayPassExpiryMs;

      // Later, while the long pass is still active, grant a *much* shorter one.
      clock = const Duration(hours: 1).inMilliseconds;
      expect(svc.hasActiveDayPass, isTrue);
      await svc.grantRewardedDayPass(duration: const Duration(minutes: 5));

      // The expiry must not have been pulled in.
      expect(svc.dayPassExpiryMs, longExpiry,
          reason: 'extend-not-shorten: a shorter re-grant cannot regress it');

      // And the pass really does survive until the ORIGINAL long expiry.
      clock = longExpiry - 1;
      expect(svc.hasActiveDayPass, isTrue);
      clock = longExpiry;
      expect(svc.hasActiveDayPass, isFalse);
    });

    test('an equal-expiry re-grant is a no-op; a longer one extends', () async {
      var clock = 500;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );
      await svc.grantRewardedDayPass(duration: const Duration(hours: 24));
      final first = svc.dayPassExpiryMs;

      // Re-grant at the SAME instant with the SAME duration → identical expiry,
      // condition is strict `>`, so state is unchanged (no-op, never regresses).
      await svc.grantRewardedDayPass(duration: const Duration(hours: 24));
      expect(svc.dayPassExpiryMs, first);

      // A genuinely longer grant extends it.
      await svc.grantRewardedDayPass(duration: const Duration(hours: 72));
      expect(svc.dayPassExpiryMs, greaterThan(first));
    });

    test('zero-duration grant yields no active pass and cannot regress one',
        () async {
      var clock = 10000;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );

      // From scratch: a zero-length pass is never "active" (now < now is false).
      await svc.grantRewardedDayPass(duration: Duration.zero);
      expect(svc.hasActiveDayPass, isFalse);
      expect(svc.isPro, isFalse);

      // With an active pass, a zero-duration grant must not disturb it.
      await svc.grantRewardedDayPass(duration: const Duration(hours: 24));
      final expiry = svc.dayPassExpiryMs;
      expect(svc.hasActiveDayPass, isTrue);
      await svc.grantRewardedDayPass(duration: Duration.zero);
      expect(svc.dayPassExpiryMs, expiry, reason: 'zero grant must not shorten');
      expect(svc.hasActiveDayPass, isTrue);
    });

    test('a NEGATIVE-duration grant never produces or regresses an active pass',
        () async {
      var clock = 1000000;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );

      // Establish a real, active pass.
      await svc.grantRewardedDayPass(duration: const Duration(hours: 24));
      final good = svc.dayPassExpiryMs;
      expect(svc.hasActiveDayPass, isTrue);

      // A negative grant computes an expiry in the past → strictly less than the
      // active expiry → must be ignored, leaving the pass intact.
      await svc.grantRewardedDayPass(duration: const Duration(hours: -100));
      expect(svc.dayPassExpiryMs, good);
      expect(svc.hasActiveDayPass, isTrue);
    });
  });

  // ===========================================================================
  // PremiumService — permanent Pro must NEVER regress
  // ===========================================================================
  group('PremiumService — permanent Pro never regresses', () {
    test('a day-pass expiring does NOT drop a permanent Pro owner to free',
        () async {
      var clock = 5000;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );

      // Own permanent Pro AND take a short day-pass on top.
      expect(await svc.buyPro(), isTrue);
      await svc.grantRewardedDayPass(duration: const Duration(minutes: 1));
      expect(svc.isPro, isTrue);
      expect(svc.hasProOneTime, isTrue);

      // Advance far past the day-pass expiry.
      clock = svc.dayPassExpiryMs + const Duration(days: 365).inMilliseconds;
      expect(svc.hasActiveDayPass, isFalse, reason: 'the day-pass has expired');
      expect(svc.isPro, isTrue,
          reason: 'the permanent unlock must survive the day-pass expiry');
      expect(svc.hasProOneTime, isTrue);
      expect(svc.tier, EntitlementTier.pro);
      expect(svc.isAdFree, isTrue);
    });

    test('buying Pro while a day-pass is active keeps isPro true past expiry',
        () async {
      var clock = 0;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );
      await svc.grantRewardedDayPass(duration: const Duration(hours: 2));
      expect(await svc.buyPro(), isTrue);

      clock = const Duration(hours: 999).inMilliseconds;
      expect(svc.hasActiveDayPass, isFalse);
      expect(svc.isPro, isTrue);
    });
  });

  // ===========================================================================
  // PremiumService — billing I/O that THROWS must never corrupt entitlement
  // ===========================================================================
  group('PremiumService — buyPro/restore error paths', () {
    test('buyPro surfaces a genuine billing error but never grants Pro',
        () async {
      final svc = PremiumService(
        backend: FakePurchaseBackend(throwOnBuy: true),
      );

      // Per the backend contract, a genuine error propagates to the caller...
      await expectLater(svc.buyPro(), throwsA(isA<StateError>()));

      // ...but the entitlement state must be untouched (never granted on error).
      expect(svc.isPro, isFalse);
      expect(svc.hasProOneTime, isFalse);
      expect(svc.tier, EntitlementTier.free);
    });

    test('after a billing error the service is NOT corrupted — a later buy works',
        () async {
      final backend = FakePurchaseBackend(throwOnBuy: true);
      final svc = PremiumService(backend: backend);

      // First attempt errors; the UI-layer catch is modelled by swallowing it.
      try {
        await svc.buyPro();
      } catch (_) {}
      expect(svc.isPro, isFalse);

      // The billing problem clears; a retry must grant cleanly.
      backend.throwOnBuy = false;
      expect(await svc.buyPro(), isTrue);
      expect(svc.isPro, isTrue);
      expect(svc.hasProOneTime, isTrue);
    });

    test('a persistence failure during buyPro still grants Pro this session',
        () async {
      // Backend succeeds, but writing the entitlement blob throws. buyPro must
      // NOT crash and must still report the (in-memory) grant.
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        load: (k) async => null,
        save: (k, v) async => throw StateError('disk full'),
      );
      expect(await svc.buyPro(), isTrue, reason: 'persist failure is best-effort');
      expect(svc.isPro, isTrue);
      expect(svc.hasProOneTime, isTrue);
    });

    test('a persistence failure during grantRewardedDayPass does not throw',
        () async {
      var clock = 0;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        load: (k) async => null,
        save: (k, v) async => throw StateError('disk full'),
        nowMs: () => clock,
      );
      // Must complete normally and keep the in-session pass active.
      await svc.grantRewardedDayPass(duration: const Duration(hours: 1));
      expect(svc.hasActiveDayPass, isTrue);
      expect(svc.isPro, isTrue);
    });

    test('restore surfaces its error but never grants Pro; retry recovers',
        () async {
      final backend = FakePurchaseBackend(
        initiallyOwned: {PremiumProducts.proOneTime},
        throwOnRestore: true,
      );
      final svc = PremiumService(backend: backend);

      await expectLater(svc.restorePurchases(), throwsA(isA<StateError>()));
      expect(svc.isPro, isFalse, reason: 'a failed restore grants nothing');

      // Store settles; restore now re-grants the owned unlock.
      backend.throwOnRestore = false;
      final owned = await svc.restorePurchases();
      expect(owned, contains(PremiumProducts.proOneTime));
      expect(svc.isPro, isTrue);
      expect(svc.hasProOneTime, isTrue);
    });

    test('restore with nothing owned leaves the user free (never throws)',
        () async {
      final svc = PremiumService(backend: FakePurchaseBackend());
      final owned = await svc.restorePurchases();
      expect(owned, isEmpty);
      expect(svc.isPro, isFalse);
    });
  });

  // ===========================================================================
  // PremiumService — corrupt / partial persisted blobs must fail SAFE to free
  // ===========================================================================
  group('PremiumService — corrupt persistence fails safe to free', () {
    Future<PremiumService> loadedFrom(String? raw, {int now = 0}) async {
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        load: (k) async => raw,
        save: (k, v) async {},
        nowMs: () => now,
      );
      await svc.load();
      return svc;
    }

    test('a whole matrix of malformed blobs never throws and never grants Pro',
        () async {
      // Evaluated with the clock far in the future, so even a blob that parses
      // to some stray small day-pass expiry (';100') reads as long-expired —
      // the invariant under test is "no premium leaks", not clock arithmetic.
      const farFuture = 10000000000; // ms — past any junk expiry below
      const malformed = <String>[
        '',                    // empty
        'garbage',             // no delimiter
        '1',                   // pro flag only, no expiry
        '1;',                  // truncated write: expiry missing
        ';',                   // both empty
        ';100',                // pro flag missing (lenient) — expiry long past
        '1;abc',               // expiry not a number
        'x;100',               // non-numeric pro flag → not owned
        'abc;def',             // both junk
        '1;100;200',           // extra field (length != 2)
        '1; 100',              // whitespace breaks int.tryParse → fail safe
        '{"pro":true}',        // legacy/foreign JSON
        '1;1e9',               // scientific notation not accepted by tryParse
      ];
      for (final raw in malformed) {
        final svc = await loadedFrom(raw, now: farFuture);
        expect(svc.isPro, isFalse, reason: 'blob "$raw" must not grant premium');
        expect(svc.hasProOneTime, isFalse,
            reason: 'blob "$raw" must not grant a permanent unlock');
      }
    });

    test('a pro flag with a CORRUPT expiry must NOT leak the permanent unlock',
        () async {
      // The decoder returns before assigning _proOwned when the expiry fails to
      // parse — so a "1;<garbage>" blob leaves the user FREE, not Pro.
      for (final raw in const ['1;abc', '1;', '1;;', '1; 5']) {
        final svc = await loadedFrom(raw);
        expect(svc.hasProOneTime, isFalse,
            reason: 'partial blob "$raw" must not resurrect Pro');
        expect(svc.isPro, isFalse);
      }
    });

    test('a valid pro-only blob round-trips to a permanent unlock', () async {
      final svc = await loadedFrom('1;0', now: 999999);
      expect(svc.hasProOneTime, isTrue);
      expect(svc.isPro, isTrue);
      expect(svc.hasActiveDayPass, isFalse, reason: 'expiry 0 is not a day-pass');
    });

    test('a valid day-pass-only blob is honoured / expires by the clock',
        () async {
      // pro=0, expiry far in the future relative to the injected clock.
      final active = await loadedFrom('0;1000000', now: 500);
      expect(active.hasProOneTime, isFalse);
      expect(active.hasActiveDayPass, isTrue);
      expect(active.isPro, isTrue);

      // Same blob, but the clock is already past expiry → free.
      final expired = await loadedFrom('0;1000000', now: 1000000);
      expect(expired.hasActiveDayPass, isFalse);
      expect(expired.isPro, isFalse);
    });

    test('a loader that THROWS is caught and leaves the user free', () async {
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        load: (k) async => throw StateError('read failed'),
        save: (k, v) async {},
      );
      await svc.load(); // must not throw
      expect(svc.isPro, isFalse);
    });
  });

  // ===========================================================================
  // AdPolicy — reliability guardrail: NO ad on the alarm path, ever
  // ===========================================================================
  group('AdPolicy — alarm/wake/lockScreen is never monetized', () {
    const hugeRides = 9223372036854775807; // int max
    const forbidden = <AdPlacement>[
      AdPlacement.alarm,
      AdPlacement.wake,
      AdPlacement.lockScreen,
    ];

    test('free user, huge ride count, tiny cap → still NO ad on the alarm path',
        () {
      for (final cap in const [0, 1, 3, 999]) {
        final policy = AdPolicy(frequencyCapRides: cap);
        for (final p in forbidden) {
          expect(
            policy.canShow(p, isPro: false, ridesSinceLastAd: hugeRides),
            isFalse,
            reason: 'no ad at $p even with cap=$cap and rides=$hugeRides',
          );
          // Also at zero and negative counters — never allowed.
          expect(policy.canShow(p, isPro: false, ridesSinceLastAd: 0), isFalse);
          expect(policy.canShow(p, isPro: false, ridesSinceLastAd: -50), isFalse);
        }
      }
    });

    test('the forbidden set exactly is the alarm/wake/lock trio', () {
      expect(AdPolicy.alwaysForbiddenPlacements, {
        AdPlacement.alarm,
        AdPlacement.wake,
        AdPlacement.lockScreen,
      });
      // And none of them is ad-eligible.
      for (final p in forbidden) {
        expect(AdPolicy.adEligiblePlacements.contains(p), isFalse);
      }
    });

    test('a Pro user sees no ad anywhere — even degenerate cap + huge counter',
        () {
      const policy = AdPolicy(frequencyCapRides: 0); // "show every ride" for free
      for (final p in AdPlacement.values) {
        expect(
          policy.canShow(p, isPro: true, ridesSinceLastAd: hugeRides),
          isFalse,
          reason: 'Pro is ad-free at $p regardless of cap/counter',
        );
      }
    });
  });

  // ===========================================================================
  // AdPolicy — frequency cap boundaries
  // ===========================================================================
  group('AdPolicy — frequency cap boundaries', () {
    test('cap=3 sweep: rides 0,1,2 suppress; 3 and above show', () {
      const policy = AdPolicy(); // cap = 3
      const expected = <int, bool>{
        0: false, // cap - 3
        1: false,
        2: false, // cap - 1  (last suppressed)
        3: true, //  cap      (first shown)
        4: true,
        5: true,
      };
      expected.forEach((rides, show) {
        expect(
          policy.canShow(AdPlacement.routeArming,
              isPro: false, ridesSinceLastAd: rides),
          show,
          reason: 'cap=3, rides=$rides should be ${show ? "shown" : "suppressed"}',
        );
      });
    });

    test('negative ride counters never show a frequency-capped ad', () {
      const policy = AdPolicy();
      for (final rides in const [-1, -3, -1000]) {
        expect(
          policy.canShow(AdPlacement.routeArming,
              isPro: false, ridesSinceLastAd: rides),
          isFalse,
          reason: 'a negative counter is below any cap',
        );
      }
    });

    test('low-intrusion banners ignore the ride counter entirely', () {
      const policy = AdPolicy();
      for (final p in const [AdPlacement.mapTracking, AdPlacement.postArrival]) {
        for (final rides in const [-100, 0, 1, 2, 999999]) {
          expect(
            policy.canShow(p, isPro: false, ridesSinceLastAd: rides),
            isTrue,
            reason: '$p is uncapped for free users (rides=$rides)',
          );
        }
      }
    });

    test('cap=0 shows the capped ad every ride (0 >= 0) but Pro still overrides',
        () {
      const policy = AdPolicy(frequencyCapRides: 0);
      expect(
        policy.canShow(AdPlacement.routeArming,
            isPro: false, ridesSinceLastAd: 0),
        isTrue,
      );
      expect(
        policy.canShow(AdPlacement.routeArming,
            isPro: true, ridesSinceLastAd: 0),
        isFalse,
      );
    });

    test('rewarded unlock truth table is complete (incl. Pro && dayPassActive)',
        () {
      const policy = AdPolicy();
      // Only a free user without an active pass is nagged.
      expect(policy.shouldOfferRewardedUnlock(isPro: false, dayPassActive: false),
          isTrue);
      expect(policy.shouldOfferRewardedUnlock(isPro: false, dayPassActive: true),
          isFalse);
      expect(policy.shouldOfferRewardedUnlock(isPro: true, dayPassActive: false),
          isFalse);
      // The fourth corner: Pro AND an active pass → still never offered.
      expect(policy.shouldOfferRewardedUnlock(isPro: true, dayPassActive: true),
          isFalse);
    });
  });

  // ===========================================================================
  // Cross-cutting: alarm gate stays TRUE and the alarm path stays ad-free
  // across the ENTIRE entitlement lifecycle (free → day-pass → expired).
  // ===========================================================================
  group('core alarm gate + ad guardrail across the entitlement lifecycle', () {
    test('coreAlarm & safety getters stay TRUE for free and after expiry', () {
      final svc = PremiumService(backend: FakePurchaseBackend());

      void assertSafetyCore() {
        expect(svc.canUseCoreAlarm, isTrue);
        expect(svc.canUseBasicReliability, isTrue);
        expect(svc.canUseBackstopAlarm, isTrue);
        expect(svc.canUseSingleActiveRoute, isTrue);
      }

      assertSafetyCore(); // brand-new free user
      expect(svc.isPro, isFalse);

      // The documented always-free set really is universally always-free.
      for (final c in PremiumService.alwaysFreeCapabilities) {
        expect(PremiumService.isAlwaysFree(c), isTrue);
      }
      // ...and a premium capability is NOT in that set (guards over-broadening).
      expect(PremiumService.isAlwaysFree('multipleAlarms'), isFalse);
    });

    test('through free → day-pass → expired, the alarm is gated ON and ad-free',
        () async {
      var clock = 0;
      const policy = AdPolicy();
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );

      void assertAlarmSafe() {
        // Alarm capability never turns off.
        expect(svc.canUseCoreAlarm, isTrue);
        expect(svc.canUseBackstopAlarm, isTrue);
        // And no ad can ever ride on the alarm/wake/lock path.
        for (final p in AdPolicy.alwaysForbiddenPlacements) {
          expect(
            policy.canShow(p, isPro: svc.isPro, ridesSinceLastAd: 100000),
            isFalse,
          );
        }
      }

      // Phase 1: free.
      expect(svc.isPro, isFalse);
      assertAlarmSafe();

      // Phase 2: active day-pass (Pro).
      await svc.grantRewardedDayPass(duration: const Duration(hours: 24));
      expect(svc.isPro, isTrue);
      assertAlarmSafe();

      // Phase 3: day-pass expired → back to free, alarm STILL safe.
      clock = svc.dayPassExpiryMs + 1;
      expect(svc.isPro, isFalse);
      assertAlarmSafe();
    });
  });

  // ===========================================================================
  // PostArrivalService — PII must never leak through ANY input surface
  // ===========================================================================
  group('PostArrivalService — privacy at every input surface', () {
    test('build() rejects a coordinate pair leaked into the CITY field', () {
      expect(
        () => PostArrivalService.build(
          stationName: 'Indiranagar',
          city: '12.9716, 77.5946',
        ),
        throwsA(isA<PostArrivalPrivacyError>()),
      );
    });

    test('build() rejects PII carried by an injected nearby label', () {
      // A high-precision decimal in a *food* label must be caught at build.
      expect(
        () => PostArrivalService.build(
          stationName: 'Indiranagar',
          nearby: const [
            LastMileOption(label: 'Cafe at 12.97159', kind: 'food'),
          ],
        ),
        throwsA(isA<PostArrivalPrivacyError>()),
      );
      // An email in a directions label, too.
      expect(
        () => PostArrivalService.build(
          stationName: 'Indiranagar',
          nearby: const [
            LastMileOption(label: 'Ask rider@example.com', kind: 'directions'),
          ],
        ),
        throwsA(isA<PostArrivalPrivacyError>()),
      );
    });

    test('build() rejects a long digit-run (phone/id) station name', () {
      expect(
        () => PostArrivalService.build(stationName: 'Bay 9876543210'),
        throwsA(isA<PostArrivalPrivacyError>()),
      );
    });

    test('a discarded ride-hailing nearby option is never PII-validated', () {
      // Injected ride-hailing is deduped away BEFORE validation, so even a
      // PII-looking label on it cannot throw — it simply never reaches a field.
      final card = PostArrivalService.build(
        stationName: 'Indiranagar',
        nearby: const [
          LastMileOption(label: 'Ola from 12.97159, 77.59', kind: 'rideHailing'),
          LastMileOption(label: 'Coffee', kind: 'food'),
        ],
      );
      expect(card.validate, returnsNormally);
      // The surviving ride-hailing action is the clean synthesised primary.
      expect(card.primaryAction!.label, 'Book a ride from the station');
      expect(
        card.actions.map((a) => a.kind).toList(),
        [
          PostArrivalActionKind.rideHailing,
          PostArrivalActionKind.food,
          PostArrivalActionKind.dismiss,
        ],
      );
    });

    test('validate() rejects a negative and a semicolon-separated coord pair',
        () {
      const negPair = PostArrivalCard(
        title: "You've arrived",
        stationName: '-12.9716,-77.5946',
        actions: [
          PostArrivalAction(
            label: 'Book a ride from the station',
            kind: PostArrivalActionKind.rideHailing,
            isPrimary: true,
          ),
        ],
      );
      expect(negPair.validate, throwsA(isA<PostArrivalPrivacyError>()));

      const semiPair = PostArrivalCard(
        title: "You've arrived",
        stationName: '12.9716; 77.5946',
        actions: [
          PostArrivalAction(
            label: 'Book a ride from the station',
            kind: PostArrivalActionKind.rideHailing,
            isPrimary: true,
          ),
        ],
      );
      expect(semiPair.validate, throwsA(isA<PostArrivalPrivacyError>()));
    });

    test('the guard does not over-reject ordinary names / low-precision numbers',
        () {
      // Real station names with modest numbers must pass cleanly.
      final card = PostArrivalService.build(
        stationName: 'Platform 2 - Sector 21',
        city: 'Bengaluru',
        nearby: const [
          LastMileOption(label: 'Cafe Coffee Day (Gate 1.5)', kind: 'food'),
          LastMileOption(label: 'Walk to 100ft Road', kind: 'directions'),
        ],
      );
      expect(card.validate, returnsNormally);

      // Boundary: exactly 3 fractional digits is NOT flagged; 4+ IS.
      expect(
        () => PostArrivalService.build(stationName: 'Zone 12.500'),
        returnsNormally,
      );
      expect(
        () => PostArrivalService.build(stationName: 'Zone 12.5000'),
        throwsA(isA<PostArrivalPrivacyError>()),
      );
    });

    test('primaryAction is null when no action is flagged primary', () {
      const card = PostArrivalCard(
        title: "You've arrived",
        stationName: 'Indiranagar',
        actions: [
          PostArrivalAction(label: 'Not now', kind: PostArrivalActionKind.dismiss),
        ],
      );
      expect(card.primaryAction, isNull);
      // A dismiss-only card is still structurally clean.
      expect(card.validate, returnsNormally);
    });

    test('the post-arrival card is gated behind alarm dismissal', () {
      // The card must never compete with the alarm: hidden until dismissed.
      expect(PostArrivalService.shouldShow(alarmDismissed: false), isFalse);
      expect(PostArrivalService.shouldShow(alarmDismissed: true), isTrue);
    });
  });
}
