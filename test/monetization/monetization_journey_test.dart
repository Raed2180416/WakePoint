// End-to-end MONETIZATION USER JOURNEYS through the assembled stack (headless:
// SharedPreferences.setMockInitialValues + FakePurchaseBackend, no real store/
// ad SDK). These are integration arcs that CHAIN the real code paths — the
// MonetizationService facade's ride counter, PremiumService's entitlement brain,
// AdPolicy's placement rules, and the REAL SharedPreferences persistence seam —
// rather than re-testing the pure helpers already covered by
// monetization_test.dart / monetization_edgecases_test.dart.
//
// The load-bearing invariants under attack (a wake-alarm's cardinal sins):
//   * the core alarm / reliability is NEVER gated, in ANY entitlement phase;
//   * NO ad is ever eligible on the alarm / wake / lock-screen path;
//   * a PAYMENT DECLINE (clean or throwing) leaves the user FREE, leaks nothing
//     into persistence, and never crashes the entitlement state;
//   * no path grants the permanent Pro unlock without a CONFIRMED purchase or a
//     store-confirmed restore.
//
// NOTE on the facade: MonetizationService is a process-wide singleton with a
// one-shot init() that cannot be reset headlessly, so a genuinely "fresh" facade
// cannot be constructed twice in one process. Journeys that need a fresh install
// / relaunch drive [prefsBackedPremium] — a PremiumService wired to the REAL
// SharedPreferences store EXACTLY as MonetizationService.init wires it — which is
// the faithful stand-in for the facade's entitlement brain over the same store.
// Ad RENDERING/fill is device-only (AdService needs a real device + AdMob IDs);
// here we test the eligibility policy seam and prove the adapter is fail-closed
// headless.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/monetization/ad_policy.dart';
import 'package:geowake2/services/monetization/ad_service.dart';
import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/monetization/purchase_backend.dart';

// The facade's private ride-counter key (mirrors MonetizationService._ridesKey).
const String _ridesKey = 'gw_rides_since_last_ad';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A PremiumService wired to the REAL SharedPreferences store, identical to the
  // wiring inside MonetizationService.init — the assembled stack's entitlement
  // brain, exercised directly over the mock store.
  PremiumService prefsBackedPremium(
    PurchaseBackend backend, {
    int Function()? nowMs,
  }) {
    return PremiumService(
      backend: backend,
      load: (k) async => (await SharedPreferences.getInstance()).getString(k),
      save: (k, v) async =>
          (await SharedPreferences.getInstance()).setString(k, v),
      nowMs: nowMs,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Force the process-singleton facade into a deterministic, FREE, zero-counter
    // state so journeys are order-independent (its one-shot init cannot be reset).
    final svc = MonetizationService.instance;
    svc.premium = PremiumService(backend: FakePurchaseBackend());
    await svc.markAdShown(); // ride counter -> 0, persisted under _ridesKey
  });

  // ===========================================================================
  // JOURNEY 1 — a FREE user rides repeatedly: the post-arrival interstitial
  // becomes eligible only once the facade's ride counter crosses the cap;
  // low-intrusion banners are ALWAYS eligible; the alarm path is NEVER eligible.
  // ===========================================================================
  group('Journey 1 — free rider hits the frequency cap', () {
    test('3 rides make post-arrival eligible; banners always; alarm never',
        () async {
      final svc = MonetizationService.instance;
      // Drive the real facade assembly (one-shot; free-user assertions hold
      // whether or not this call re-wires the singleton this run).
      await svc.init(backendOverride: FakePurchaseBackend());
      expect(svc.premium.isPro, isFalse);
      expect(svc.premium.canUseCoreAlarm, isTrue);

      const policy = AdPolicy(); // cap = 3
      bool eligible(AdPlacement p) => policy.canShow(
            p,
            isPro: svc.premium.isPro,
            ridesSinceLastAd: svc.ridesSinceLastAd,
          );

      void assertBannersOnAlarmNever() {
        // Low-intrusion banners are always eligible for a free user...
        expect(eligible(AdPlacement.mapTracking), isTrue);
        expect(eligible(AdPlacement.routeArming), isTrue);
        // ...and the alarm / wake / lock-screen NEVER are, at any ride count.
        for (final p in AdPolicy.alwaysForbiddenPlacements) {
          expect(eligible(p), isFalse, reason: 'no ad on the alarm path ($p)');
        }
      }

      // Counter 0: below the cap → post-arrival interstitial suppressed; banners on; alarm off.
      expect(svc.ridesSinceLastAd, 0);
      expect(eligible(AdPlacement.postArrival), isFalse);
      assertBannersOnAlarmNever();

      // Rides 1 and 2: still under the cap.
      await svc.recordRide();
      expect(svc.ridesSinceLastAd, 1);
      expect(eligible(AdPlacement.postArrival), isFalse);
      assertBannersOnAlarmNever();

      await svc.recordRide();
      expect(svc.ridesSinceLastAd, 2);
      expect(eligible(AdPlacement.postArrival), isFalse);

      // Ride 3: hits the cap → the post-arrival interstitial becomes eligible.
      await svc.recordRide();
      expect(svc.ridesSinceLastAd, 3);
      expect(eligible(AdPlacement.postArrival), isTrue);
      // Crossing the cap must NOT open the alarm path or change banner rules.
      assertBannersOnAlarmNever();

      // The counter is persisted to the REAL store under the facade's key.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_ridesKey), 3);
    });

    test('after an ad is shown, markAdShown resets the cap for another 3 rides',
        () async {
      final svc = MonetizationService.instance;
      const policy = AdPolicy();
      bool postArrivalEligible() => policy.canShow(
            AdPlacement.postArrival,
            isPro: svc.premium.isPro,
            ridesSinceLastAd: svc.ridesSinceLastAd,
          );

      // Reach the cap.
      await svc.recordRide();
      await svc.recordRide();
      await svc.recordRide();
      expect(postArrivalEligible(), isTrue);

      // The app shows the post-arrival interstitial, then resets the counter.
      await svc.markAdShown();
      expect(svc.ridesSinceLastAd, 0);
      // Immediately suppressed again — no back-to-back interstitials.
      expect(postArrivalEligible(), isFalse);

      // Two more rides: still suppressed.
      await svc.recordRide();
      await svc.recordRide();
      expect(postArrivalEligible(), isFalse);
      // The third ride re-opens eligibility.
      await svc.recordRide();
      expect(postArrivalEligible(), isTrue);
    });
  });

  // ===========================================================================
  // JOURNEY 2 — PAYMENT DECLINE: the user stays FREE, nothing leaks into
  // persistence, and the entitlement path never crashes.
  // ===========================================================================
  group('Journey 2 — payment decline leaks no entitlement', () {
    test('a clean decline (returns false) stays free and persists nothing',
        () async {
      final backend = FakePurchaseBackend(buyShouldSucceed: false);
      final premium = prefsBackedPremium(backend);
      await premium.load(); // fresh install: nothing owned
      expect(premium.isPro, isFalse);

      final ok = await premium.buyPro();
      expect(ok, isFalse, reason: 'a declined charge is false, never a grant');
      expect(premium.isPro, isFalse);
      expect(premium.hasProOneTime, isFalse);
      expect(backend.buyCalls, [PremiumService.proProductId],
          reason: 'the purchase was genuinely attempted');

      // Nothing may be written to the store — a decline must not resurrect Pro
      // on the next launch.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PremiumService.persistKey), isNull);

      // Premium gates stay locked; the core alarm stays free.
      expect(premium.isAdFree, isFalse);
      expect(premium.canUseCoreAlarm, isTrue);

      // A fresh brain over the same store confirms: still free after relaunch.
      final relaunch = prefsBackedPremium(FakePurchaseBackend());
      await relaunch.load();
      expect(relaunch.isPro, isFalse);
    });

    test('a THROWING billing error never grants Pro, never taints the store',
        () async {
      final backend = FakePurchaseBackend(throwOnBuy: true);
      final premium = prefsBackedPremium(backend);
      await premium.load();

      // Per the backend contract a genuine error propagates to the caller (the
      // UI layer is expected to catch it) — but it must NEVER leak entitlement.
      await expectLater(premium.buyPro(), throwsA(isA<StateError>()));
      expect(premium.isPro, isFalse);
      expect(premium.hasProOneTime, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PremiumService.persistKey), isNull,
          reason: 'a failed charge must write no entitlement blob');

      // Model the app-level catch: the error is swallowed, the app keeps running,
      // and the entitlement is NOT corrupted — a later retry can still succeed.
      backend.throwOnBuy = false;
      final relaunch = prefsBackedPremium(FakePurchaseBackend());
      await relaunch.load();
      expect(relaunch.isPro, isFalse);
    });
  });

  // ===========================================================================
  // JOURNEY 3 — a successful buyPro: every premium gate flips, the core alarm
  // stays free, ads disappear EVERYWHERE, and the unlock persists to the store.
  // ===========================================================================
  group('Journey 3 — buying Pro unlocks premium and kills ads', () {
    test('buyPro flips gates, keeps alarm free, removes ads, and persists',
        () async {
      final backend = FakePurchaseBackend(); // buyShouldSucceed defaults true
      final premium = prefsBackedPremium(backend);
      await premium.load();
      expect(premium.isPro, isFalse);

      const policy = AdPolicy();
      // While free, the route-arming banner is eligible (uncapped).
      expect(
        policy.canShow(AdPlacement.routeArming,
            isPro: premium.isPro, ridesSinceLastAd: 3),
        isTrue,
      );

      final ok = await premium.buyPro();
      expect(ok, isTrue);
      expect(premium.isPro, isTrue);
      expect(premium.hasProOneTime, isTrue);
      expect(premium.tier, EntitlementTier.pro);

      // Every premium gate flips on.
      expect(premium.isAdFree, isTrue);
      expect(premium.canUseCustomAlarmSounds, isTrue);
      expect(premium.canUseWidget, isTrue);

      // The core alarm / reliability is STILL free — never gated behind Pro.
      expect(premium.canUseCoreAlarm, isTrue);
      expect(premium.canUseBasicReliability, isTrue);
      expect(premium.canUseBackstopAlarm, isTrue);
      expect(premium.canUseSingleActiveRoute, isTrue);

      // Ads are gone EVERYWHERE now — even the previously-eligible surfaces at or
      // above the cap — and the rewarded upsell stops.
      for (final p in AdPlacement.values) {
        expect(
          policy.canShow(p, isPro: premium.isPro, ridesSinceLastAd: 999),
          isFalse,
          reason: 'Pro is ad-free at $p',
        );
      }
      expect(
        policy.shouldOfferRewardedUnlock(
            isPro: premium.isPro, dayPassActive: premium.hasActiveDayPass),
        isFalse,
      );

      // The unlock is persisted to the REAL store and survives a relaunch — with
      // an offline backend (owns nothing, never queried).
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PremiumService.persistKey), '1;0');
      final relaunch = prefsBackedPremium(FakePurchaseBackend());
      await relaunch.load();
      expect(relaunch.isPro, isTrue);
      expect(relaunch.hasProOneTime, isTrue);
    });
  });

  // ===========================================================================
  // JOURNEY 4 — a rewarded day-pass: premium for the window, then EXPIRES back
  // to free by a fixed clock. Ads vanish during the window and RETURN after.
  // ===========================================================================
  group('Journey 4 — rewarded day-pass window then expiry', () {
    test('grant → premium for 24h (no ads); expiry → free again (ads return)',
        () async {
      var clock = 1000; // epoch ms
      final premium = prefsBackedPremium(FakePurchaseBackend(), nowMs: () => clock);
      await premium.load();
      const policy = AdPolicy();

      // Free before: the upsell is offered and ads exist on eligible surfaces.
      expect(premium.isPro, isFalse);
      expect(
        policy.shouldOfferRewardedUnlock(
            isPro: premium.isPro, dayPassActive: premium.hasActiveDayPass),
        isTrue,
      );
      expect(
        policy.canShow(AdPlacement.routeArming,
            isPro: premium.isPro, ridesSinceLastAd: 3),
        isTrue,
      );
      expect(
        policy.canShow(AdPlacement.mapTracking,
            isPro: premium.isPro, ridesSinceLastAd: 0),
        isTrue,
      );

      // User watches a rewarded video → premium for a day.
      await premium.grantRewardedDayPass(); // default 24h
      expect(premium.isPro, isTrue);
      expect(premium.hasActiveDayPass, isTrue);
      expect(premium.hasProOneTime, isFalse,
          reason: 'a rewarded pass is NOT the permanent paid unlock');
      expect(premium.isAdFree, isTrue);

      // Within the window: no ad anywhere, and the upsell stops nagging.
      for (final p in AdPlacement.values) {
        expect(
          policy.canShow(p, isPro: premium.isPro, ridesSinceLastAd: 999),
          isFalse,
        );
      }
      expect(
        policy.shouldOfferRewardedUnlock(
            isPro: premium.isPro, dayPassActive: premium.hasActiveDayPass),
        isFalse,
      );
      expect(premium.canUseCoreAlarm, isTrue);

      // The pass persisted to the REAL store: a relaunch mid-window is premium.
      final midClock = 1000 + const Duration(hours: 12).inMilliseconds;
      final relaunchMid =
          prefsBackedPremium(FakePurchaseBackend(), nowMs: () => midClock);
      await relaunchMid.load();
      expect(relaunchMid.isPro, isTrue);
      expect(relaunchMid.hasActiveDayPass, isTrue);

      // Just before expiry: still premium.
      clock = 1000 + const Duration(hours: 24).inMilliseconds - 1;
      expect(premium.isPro, isTrue);

      // At/after expiry: reverts to free — ads return, upsell re-offered.
      clock = 1000 + const Duration(hours: 24).inMilliseconds;
      expect(premium.hasActiveDayPass, isFalse);
      expect(premium.isPro, isFalse);
      expect(premium.isAdFree, isFalse);
      expect(premium.hasProOneTime, isFalse,
          reason: 'the window never granted a permanent unlock');
      expect(
        policy.shouldOfferRewardedUnlock(
            isPro: premium.isPro, dayPassActive: premium.hasActiveDayPass),
        isTrue,
      );
      expect(
        policy.canShow(AdPlacement.routeArming,
            isPro: premium.isPro, ridesSinceLastAd: 3),
        isTrue,
      );
      expect(
        policy.canShow(AdPlacement.mapTracking,
            isPro: premium.isPro, ridesSinceLastAd: 0),
        isTrue,
      );

      // The alarm path was NEVER monetized in ANY phase.
      for (final p in AdPolicy.alwaysForbiddenPlacements) {
        expect(
          policy.canShow(p, isPro: false, ridesSinceLastAd: 999999),
          isFalse,
        );
      }

      // A relaunch AFTER expiry loads as free from the same store.
      final postClock = 1000 + const Duration(hours: 25).inMilliseconds;
      final relaunchPost =
          prefsBackedPremium(FakePurchaseBackend(), nowMs: () => postClock);
      await relaunchPost.load();
      expect(relaunchPost.isPro, isFalse);
    });
  });

  // ===========================================================================
  // JOURNEY 5 — RESTORE on a new install: local store empty, but the store
  // account owns Pro → restore re-grants it and writes it locally.
  // ===========================================================================
  group('Journey 5 — restore on a fresh install re-grants Pro', () {
    test('empty local store + owned in store → restore grants and persists',
        () async {
      // Fresh install: local prefs empty (setUp), store account owns the unlock.
      final backend =
          FakePurchaseBackend(initiallyOwned: {PremiumProducts.proOneTime});
      final premium = prefsBackedPremium(backend);

      await premium.load();
      expect(premium.isPro, isFalse,
          reason: 'nothing is persisted locally on a fresh install');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PremiumService.persistKey), isNull);

      // User taps "Restore purchases".
      final owned = await premium.restorePurchases();
      expect(owned, contains(PremiumProducts.proOneTime));
      expect(backend.restoreCalls, 1);
      expect(premium.isPro, isTrue);
      expect(premium.hasProOneTime, isTrue);

      // Restore wrote the entitlement locally → a subsequent OFFLINE relaunch
      // (backend owns nothing, never queried) still recovers Pro.
      expect(prefs.getString(PremiumService.persistKey), '1;0');
      final relaunchOffline = prefsBackedPremium(FakePurchaseBackend());
      await relaunchOffline.load();
      expect(relaunchOffline.isPro, isTrue);
      expect(relaunchOffline.hasProOneTime, isTrue);
    });

    test('restore with nothing owned stays free and fabricates no entitlement',
        () async {
      final backend = FakePurchaseBackend(); // owns nothing
      final premium = prefsBackedPremium(backend);
      await premium.load();

      final owned = await premium.restorePurchases();
      expect(owned, isEmpty);
      expect(premium.isPro, isFalse);
      expect(premium.hasProOneTime, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PremiumService.persistKey), isNull,
          reason: 'a fruitless restore must not invent a paid unlock');
    });
  });

  // ===========================================================================
  // JOURNEY 6 — entitlement persists across a FRESH brain over the same store,
  // recovered from local persistence WITHOUT re-querying the billing backend.
  // ===========================================================================
  group('Journey 6 — Pro persists across a relaunch (no backend re-query)', () {
    test('buy once; a fresh brain loads Pro from the store without the backend',
        () async {
      final firstBackend = FakePurchaseBackend();
      final first = prefsBackedPremium(firstBackend);
      await first.load();
      expect(await first.buyPro(), isTrue);
      expect(first.isPro, isTrue);
      expect(firstBackend.buyCalls.length, 1);

      // A brand-new brain over the SAME store, whose backend owns NOTHING and
      // must NOT be consulted, recovers Pro purely from local persistence.
      final secondBackend = FakePurchaseBackend();
      final second = prefsBackedPremium(secondBackend);
      expect(second.isPro, isFalse, reason: 'not loaded yet');
      await second.load();
      expect(second.isPro, isTrue);
      expect(second.hasProOneTime, isTrue);
      // Recovery is purely local — no purchase or restore is issued on load.
      expect(secondBackend.buyCalls, isEmpty);
      expect(secondBackend.restoreCalls, 0);
    });
  });

  // ===========================================================================
  // CROSS-CUTTING INVARIANTS — the core alarm is free in EVERY phase, and the
  // permanent unlock appears ONLY after a confirmed purchase.
  // ===========================================================================
  group('cross-cutting — alarm always free; Pro only on confirmed purchase', () {
    test('walk free → declined → day-pass → bought → expired, alarm stays free',
        () async {
      var clock = 0;
      final backend = FakePurchaseBackend(buyShouldSucceed: false);
      final premium = prefsBackedPremium(backend, nowMs: () => clock);
      await premium.load();

      void assertCoreFree() {
        expect(premium.canUseCoreAlarm, isTrue);
        expect(premium.canUseBasicReliability, isTrue);
        expect(premium.canUseBackstopAlarm, isTrue);
        expect(premium.canUseSingleActiveRoute, isTrue);
      }

      // Phase: fresh free.
      assertCoreFree();
      expect(premium.hasProOneTime, isFalse);

      // Phase: a declined purchase — no permanent unlock materialises.
      expect(await premium.buyPro(), isFalse);
      assertCoreFree();
      expect(premium.hasProOneTime, isFalse);

      // Phase: a rewarded day-pass — premium WITHOUT a purchase, but it is NOT
      // the permanent one-time unlock.
      await premium.grantRewardedDayPass();
      expect(premium.isPro, isTrue);
      expect(premium.hasProOneTime, isFalse,
          reason: 'a rewarded pass is never the paid unlock');
      assertCoreFree();

      // Phase: the charge finally succeeds — NOW (and only now) the permanent
      // unlock flips on.
      backend.buyShouldSucceed = true;
      expect(await premium.buyPro(), isTrue);
      expect(premium.hasProOneTime, isTrue);
      assertCoreFree();

      // Phase: the day-pass expires; the permanent unlock survives, alarm free.
      clock = const Duration(days: 400).inMilliseconds;
      expect(premium.hasActiveDayPass, isFalse);
      expect(premium.isPro, isTrue,
          reason: 'the permanent unlock outlives the pass');
      assertCoreFree();
    });
  });

  // ===========================================================================
  // AD ADAPTER — device-only rendering. Headless, the concrete AdService is
  // fail-closed: it returns null/false and NEVER throws, so no ad can ride the
  // alarm path even at the adapter. (Real fill needs a device + AdMob IDs.)
  // ===========================================================================
  group('AdService adapter is fail-closed headless (device-verify rendering)',
      () {
    test('createBanner returns null and maybeShowInterstitial false, no throw',
        () async {
      final premium = PremiumService(backend: FakePurchaseBackend());
      // Uninitialized SDK + non-mobile host → the adapter must refuse to build
      // or show anything, on EVERY placement, without throwing.
      for (final p in AdPlacement.values) {
        expect(
          AdService.instance.createBanner(placement: p, premium: premium),
          isNull,
          reason: 'no banner headless at $p',
        );
        expect(
          await AdService.instance.maybeShowInterstitial(
            placement: p,
            premium: premium,
            ridesSinceLastAd: 999,
          ),
          isFalse,
          reason: 'no interstitial headless at $p',
        );
      }
    });
  });
}
