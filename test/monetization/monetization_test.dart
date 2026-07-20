// Deterministic, headless tests for the monetization layer (MONETIZATION.md +
// HANDOFF §2/§5). No device, no real IAP/ads SDK — a FakePurchaseBackend and an
// in-memory persistence pair drive every path.
//
// The load-bearing assertions:
//   * reliability/safety is NEVER gated (free tier keeps the alarm);
//   * Pro removes ads everywhere; free gets ads only on allowed placements;
//   * the every-3-rides frequency cap works;
//   * a rewarded unlock grants premium for a day (and expires);
//   * restore re-grants entitlement.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/monetization/ad_policy.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/monetization/purchase_backend.dart';

void main() {
  group('AdPolicy', () {
    const policy = AdPolicy(); // frequencyCapRides = 3

    test('Pro removes ads on EVERY placement, capped or not', () {
      for (final p in AdPlacement.values) {
        expect(
          policy.canShow(p, isPro: true, ridesSinceLastAd: 999),
          isFalse,
          reason: 'Pro must never see an ad at $p',
        );
      }
    });

    test('alarm / wake / lock-screen are NEVER monetized (even for free)', () {
      for (final p in AdPolicy.alwaysForbiddenPlacements) {
        expect(
          policy.canShow(p, isPro: false, ridesSinceLastAd: 100),
          isFalse,
          reason: 'reliability guardrail: no ad at $p',
        );
      }
    });

    test('free sees low-intrusion banners on arming & map (uncapped)', () {
      expect(
        policy.canShow(AdPlacement.routeArming,
            isPro: false, ridesSinceLastAd: 0),
        isTrue,
      );
      expect(
        policy.canShow(AdPlacement.mapTracking,
            isPro: false, ridesSinceLastAd: 0),
        isTrue,
      );
    });

    test('post-arrival interstitial respects the every-3-rides cap', () {
      // Below the cap: suppressed.
      expect(
        policy.canShow(AdPlacement.postArrival,
            isPro: false, ridesSinceLastAd: 0),
        isFalse,
      );
      expect(
        policy.canShow(AdPlacement.postArrival,
            isPro: false, ridesSinceLastAd: 2),
        isFalse,
      );
      // At/above the cap: allowed.
      expect(
        policy.canShow(AdPlacement.postArrival,
            isPro: false, ridesSinceLastAd: 3),
        isTrue,
      );
      expect(
        policy.canShow(AdPlacement.postArrival,
            isPro: false, ridesSinceLastAd: 7),
        isTrue,
      );
    });

    test('custom frequency cap is honoured', () {
      const strict = AdPolicy(frequencyCapRides: 5);
      expect(
        strict.canShow(AdPlacement.postArrival,
            isPro: false, ridesSinceLastAd: 4),
        isFalse,
      );
      expect(
        strict.canShow(AdPlacement.postArrival,
            isPro: false, ridesSinceLastAd: 5),
        isTrue,
      );
    });

    test('rewarded unlock is offered to free-without-daypass only', () {
      expect(
        policy.shouldOfferRewardedUnlock(isPro: false, dayPassActive: false),
        isTrue,
      );
      // Already unlocked today ⇒ don't nag.
      expect(
        policy.shouldOfferRewardedUnlock(isPro: false, dayPassActive: true),
        isFalse,
      );
      // Pro ⇒ never offer.
      expect(
        policy.shouldOfferRewardedUnlock(isPro: true, dayPassActive: false),
        isFalse,
      );
    });
  });

  group('FakePurchaseBackend', () {
    test('buyOneTime grants ownership and logs the call', () async {
      final backend = FakePurchaseBackend();
      final ok = await backend.buyOneTime(PremiumProducts.proOneTime);
      expect(ok, isTrue);
      expect(backend.owned, contains(PremiumProducts.proOneTime));
      expect(backend.buyCalls, [PremiumProducts.proOneTime]);
    });

    test('restore returns previously-owned products', () async {
      final backend =
          FakePurchaseBackend(initiallyOwned: {PremiumProducts.proOneTime});
      final owned = await backend.restore();
      expect(owned, contains(PremiumProducts.proOneTime));
      expect(backend.restoreCalls, 1);
    });

    test('declined buy neither grants nor throws', () async {
      final backend = FakePurchaseBackend(buyShouldSucceed: false);
      final ok = await backend.buyOneTime(PremiumProducts.proOneTime);
      expect(ok, isFalse);
      expect(backend.owned, isEmpty);
    });
  });

  group('PremiumService — reliability is NEVER gated', () {
    test('a brand-new free user keeps the entire alarm/safety core', () {
      final svc = PremiumService(backend: FakePurchaseBackend());
      expect(svc.isPro, isFalse, reason: 'default tier is free');
      expect(svc.tier, EntitlementTier.free);

      // The invariant: reliability/safety works on free.
      expect(svc.canUseCoreAlarm, isTrue);
      expect(svc.canUseBasicReliability, isTrue);
      expect(svc.canUseBackstopAlarm, isTrue);
      expect(svc.canUseSingleActiveRoute, isTrue);

      // Every documented always-free capability really is always free.
      for (final c in PremiumService.alwaysFreeCapabilities) {
        expect(PremiumService.isAlwaysFree(c), isTrue);
      }

      // Convenience features are gated off for free.
      expect(svc.isAdFree, isFalse);
      expect(svc.canUseWidget, isFalse);
    });

    test('reliability stays free even for a Pro user (never regresses)', () {
      final svc = PremiumService(backend: FakePurchaseBackend());
      // Simulate Pro via a day-pass grant; core getters are still true.
      return svc.grantRewardedDayPass().then((_) {
        expect(svc.isPro, isTrue);
        expect(svc.canUseCoreAlarm, isTrue);
        expect(svc.canUseBasicReliability, isTrue);
      });
    });
  });

  group('PremiumService — one-time Pro unlock', () {
    test('buying Pro flips every premium gate and removes ads', () async {
      final svc = PremiumService(backend: FakePurchaseBackend());
      final ok = await svc.buyPro();

      expect(ok, isTrue);
      expect(svc.isPro, isTrue);
      expect(svc.hasProOneTime, isTrue);
      expect(svc.tier, EntitlementTier.pro);

      expect(svc.isAdFree, isTrue);
      expect(svc.canUseCustomAlarmSounds, isTrue);
      expect(svc.canUseWidget, isTrue);
    });

    test('a declined purchase leaves the user free', () async {
      final svc = PremiumService(
        backend: FakePurchaseBackend(buyShouldSucceed: false),
      );
      final ok = await svc.buyPro();
      expect(ok, isFalse);
      expect(svc.isPro, isFalse);
      expect(svc.canUseWidget, isFalse);
    });

    test('Pro, once bought, removes ads on every placement via AdPolicy',
        () async {
      const policy = AdPolicy();
      final svc = PremiumService(backend: FakePurchaseBackend());
      await svc.buyPro();
      for (final p in AdPlacement.values) {
        expect(
          policy.canShow(p, isPro: svc.isPro, ridesSinceLastAd: 3),
          isFalse,
        );
      }
    });
  });

  group('PremiumService — rewarded "premium for a day"', () {
    test('a rewarded unlock grants premium for exactly the pass window',
        () async {
      var clock = 1000; // epoch ms
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );

      expect(svc.isPro, isFalse);
      await svc.grantRewardedDayPass(); // default 24h

      // Within the window: premium + ad-free.
      expect(svc.isPro, isTrue);
      expect(svc.hasActiveDayPass, isTrue);
      expect(svc.isAdFree, isTrue);
      expect(svc.hasProOneTime, isFalse, reason: 'day-pass is not permanent');

      // Just before expiry: still active.
      clock = 1000 + const Duration(hours: 24).inMilliseconds - 1;
      expect(svc.isPro, isTrue);

      // After expiry: back to free.
      clock = 1000 + const Duration(hours: 24).inMilliseconds + 1;
      expect(svc.hasActiveDayPass, isFalse);
      expect(svc.isPro, isFalse);
      expect(svc.isAdFree, isFalse);
    });

    test('granting again extends but never shortens the pass', () async {
      var clock = 0;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => clock,
      );
      await svc.grantRewardedDayPass(duration: const Duration(hours: 24));
      final firstExpiry = svc.dayPassExpiryMs;

      // A shorter grant later must not pull the expiry in.
      clock = 1000;
      await svc.grantRewardedDayPass(duration: const Duration(minutes: 1));
      expect(svc.dayPassExpiryMs, firstExpiry);

      // A longer grant extends it.
      await svc.grantRewardedDayPass(duration: const Duration(hours: 48));
      expect(svc.dayPassExpiryMs, greaterThan(firstExpiry));
    });
  });

  group('PremiumService — restore & persistence', () {
    test('restore re-grants Pro when the store account owns it', () async {
      final backend =
          FakePurchaseBackend(initiallyOwned: {PremiumProducts.proOneTime});
      final svc = PremiumService(backend: backend);

      expect(svc.isPro, isFalse); // not loaded yet
      final owned = await svc.restorePurchases();

      expect(owned, contains(PremiumProducts.proOneTime));
      expect(svc.isPro, isTrue);
      expect(svc.hasProOneTime, isTrue);
    });

    test('restore with nothing owned leaves the user free', () async {
      final svc = PremiumService(backend: FakePurchaseBackend());
      final owned = await svc.restorePurchases();
      expect(owned, isEmpty);
      expect(svc.isPro, isFalse);
    });

    test('entitlement persists across service instances (shared store)',
        () async {
      final store = <String, String>{};
      Future<String?> load(String k) async => store[k];
      Future<void> save(String k, String v) async => store[k] = v;

      final first = PremiumService(
        backend: FakePurchaseBackend(),
        load: load,
        save: save,
      );
      await first.buyPro();
      expect(first.isPro, isTrue);
      expect(store[PremiumService.persistKey], isNotNull);

      // A fresh instance over the same store must recover Pro after load().
      final second = PremiumService(
        backend: FakePurchaseBackend(),
        load: load,
        save: save,
      );
      expect(second.isPro, isFalse, reason: 'not loaded yet');
      await second.load();
      expect(second.isPro, isTrue);
      expect(second.hasProOneTime, isTrue);
    });

    test('a persisted day-pass expiry is honoured on reload', () async {
      final store = <String, String>{};
      Future<String?> load(String k) async => store[k];
      Future<void> save(String k, String v) async => store[k] = v;
      var clock = 5000;

      final first = PremiumService(
        backend: FakePurchaseBackend(),
        load: load,
        save: save,
        nowMs: () => clock,
      );
      await first.grantRewardedDayPass(duration: const Duration(hours: 24));

      final second = PremiumService(
        backend: FakePurchaseBackend(),
        load: load,
        save: save,
        nowMs: () => clock,
      );
      await second.load();
      expect(second.hasActiveDayPass, isTrue);

      // Advance past expiry: reload sees it as free.
      clock = 5000 + const Duration(hours: 24).inMilliseconds + 1;
      final third = PremiumService(
        backend: FakePurchaseBackend(),
        load: load,
        save: save,
        nowMs: () => clock,
      );
      await third.load();
      expect(third.hasActiveDayPass, isFalse);
      expect(third.isPro, isFalse);
    });

    test('corrupt persisted blob falls back to free (never throws)', () async {
      final store = <String, String>{
        PremiumService.persistKey: '{not valid json',
      };
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        load: (k) async => store[k],
        save: (k, v) async => store[k] = v,
      );
      await svc.load(); // must not throw
      expect(svc.isPro, isFalse);
    });
  });
}
