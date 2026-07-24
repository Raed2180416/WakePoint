// Deterministic, headless tests for the prepaid pass ladder (₹7 daily / ₹35
// weekly / ₹99 monthly / ₹899 yearly). Passes are CONSUMABLE (re-buyable each
// period) and grant time-based Pro via the same expiry mechanism the rewarded
// day-pass uses, so `isPro` needs no change. See PASS_PRICING_ANALYSIS.md.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/monetization/purchase_backend.dart';

void main() {
  group('PremiumService — prepaid pass ladder', () {
    test('each SKU maps to its documented Pro duration', () {
      expect(PremiumService.passDurationFor(PremiumProducts.proDaily),
          const Duration(hours: 24));
      expect(PremiumService.passDurationFor(PremiumProducts.proWeekly),
          const Duration(days: 7));
      expect(PremiumService.passDurationFor(PremiumProducts.proMonthly),
          const Duration(days: 30));
      expect(PremiumService.passDurationFor(PremiumProducts.proYearly),
          const Duration(days: 365));
    });

    test('an unknown SKU falls back to the shortest duration (never over-grants)',
        () {
      expect(PremiumService.passDurationFor('geowake_pro_bogus'),
          const Duration(hours: 24));
    });

    test('buying a monthly pass grants Pro and flips the gates', () async {
      var now = 1000;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => now,
      );
      final ok = await svc.buyPass(PremiumProducts.proMonthly);

      expect(ok, isTrue);
      expect(svc.isPro, isTrue);
      expect(svc.isAdFree, isTrue);
      expect(svc.canUseCustomAlarmSounds, isTrue);
      // A pass is NOT the permanent one-time unlock.
      expect(svc.hasProOneTime, isFalse);
    });

    test('a pass lapses at expiry — Pro falls back to free (fail toward free)',
        () async {
      var now = 0;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => now,
      );
      await svc.buyPass(PremiumProducts.proDaily); // 24h
      expect(svc.isPro, isTrue);

      now = const Duration(hours: 24, minutes: 1).inMilliseconds; // past expiry
      expect(svc.isPro, isFalse);
      expect(svc.isAdFree, isFalse);
      // Core alarm is ALWAYS free regardless of entitlement.
      expect(svc.canUseCoreAlarm, isTrue);
    });

    test('a pass EXTENDS, never shortens, an existing longer entitlement',
        () async {
      var now = 0;
      final svc = PremiumService(
        backend: FakePurchaseBackend(),
        nowMs: () => now,
      );
      await svc.buyPass(PremiumProducts.proYearly); // ~365d
      final yearlyExpiry = svc.dayPassExpiryMs;

      // Buying a daily on top must NOT shorten the yearly entitlement.
      await svc.buyPass(PremiumProducts.proDaily);
      expect(svc.dayPassExpiryMs, yearlyExpiry);
      expect(svc.isPro, isTrue);
    });

    test('a pass is CONSUMABLE — re-buyable, and never appears as owned/restorable',
        () async {
      final fake = FakePurchaseBackend();
      final svc = PremiumService(backend: fake);

      await svc.buyPass(PremiumProducts.proWeekly);
      await svc.buyPass(PremiumProducts.proWeekly); // renew

      // Went through the consumable path twice...
      expect(fake.consumableBuyCalls,
          [PremiumProducts.proWeekly, PremiumProducts.proWeekly]);
      // ...and consumables are consumed, so nothing is "owned"/restorable.
      expect(fake.owned, isEmpty);
      expect(await svc.restorePurchases(), isEmpty);
    });

    test('a declined pass purchase leaves the user free', () async {
      final svc = PremiumService(
        backend: FakePurchaseBackend(buyShouldSucceed: false),
      );
      final ok = await svc.buyPass(PremiumProducts.proMonthly);
      expect(ok, isFalse);
      expect(svc.isPro, isFalse);
    });

    test('an invalid SKU is rejected without touching the backend', () async {
      final fake = FakePurchaseBackend();
      final svc = PremiumService(backend: fake);
      final ok = await svc.buyPass('geowake_pro_bogus');
      expect(ok, isFalse);
      expect(fake.consumableBuyCalls, isEmpty);
      expect(svc.isPro, isFalse);
    });

    test('passLadder lists all four SKUs in ascending order', () {
      expect(PremiumProducts.passLadder, [
        PremiumProducts.proDaily,
        PremiumProducts.proWeekly,
        PremiumProducts.proMonthly,
        PremiumProducts.proYearly,
      ]);
    });
  });
}
