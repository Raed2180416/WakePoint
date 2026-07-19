// Wave 0 — entitlement gates: the new Pro getters, the always-free invariants,
// the rewarded day-pass, and the price-with-fallback seam.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/monetization/purchase_backend.dart';

void main() {
  group('Wave 0 gates', () {
    late FakePurchaseBackend backend;
    late PremiumService p;

    setUp(() {
      backend = FakePurchaseBackend();
      p = PremiumService(backend: backend);
    });

    test('core + single active route are ALWAYS free, any tier', () {
      expect(p.canUseCoreAlarm, isTrue);
      expect(p.canUseBasicReliability, isTrue);
      expect(p.canUseBackstopAlarm, isTrue);
      expect(p.canUseSingleActiveRoute, isTrue);
      expect(PremiumService.isAlwaysFree('coreAlarm'), isTrue);
    });

    test('new Pro gates flip false→true on unlock', () async {
      expect(p.isPro, isFalse);
      expect(p.canUseGuardianMode, isFalse);

      expect(await p.buyPro(), isTrue);

      expect(p.isPro, isTrue);
      expect(p.canUseGuardianMode, isTrue);
    });

    test('rewarded day-pass grants Pro then expires', () async {
      var now = 1000;
      final pp = PremiumService(backend: backend, nowMs: () => now);
      expect(pp.isPro, isFalse);
      await pp.grantRewardedDayPass(duration: const Duration(hours: 24));
      expect(pp.isPro, isTrue);
      expect(pp.canUseGuardianMode, isTrue);
      now += const Duration(hours: 25).inMilliseconds;
      expect(pp.isPro, isFalse); // expired
      expect(pp.canUseGuardianMode, isFalse);
    });

    test('queryPrice yields a price, and null exercises the caller fallback', () async {
      expect(await backend.queryPrice(PremiumService.proProductId), '₹199.00');
      final noMeta = FakePurchaseBackend(priceString: null);
      expect(await noMeta.queryPrice('x'), isNull);
    });
  });
}
