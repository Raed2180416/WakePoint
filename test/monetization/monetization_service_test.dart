// Integration test for the assembled MonetizationService facade (headless:
// mocked SharedPreferences + FakePurchaseBackend). Verifies entitlement load,
// purchase flow, and the ad ride-counter — without any real store/ad SDK.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/monetization/purchase_backend.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Reset the singleton's readiness by re-initialising with a fresh fake.
    MonetizationService.instance.premium =
        PremiumService(backend: FakePurchaseBackend());
  });

  test('assembles a free user by default; core alarm always usable', () async {
    final fake = FakePurchaseBackend()..buyShouldSucceed = true;
    final svc = MonetizationService.instance;
    // Force re-init path by constructing a fresh premium through init override.
    await svc.init(backendOverride: fake);
    expect(svc.premium.isPro, isFalse);
    expect(svc.premium.canUseCoreAlarm, isTrue);
    expect(svc.premium.isAdFree, isFalse);
  });

  test('ride counter persists and resets on ad shown', () async {
    SharedPreferences.setMockInitialValues({});
    final svc = MonetizationService.instance;
    await svc.markAdShown();
    expect(svc.ridesSinceLastAd, 0);
    await svc.recordRide();
    await svc.recordRide();
    expect(svc.ridesSinceLastAd, 2);
    // Persisted across a fresh SharedPreferences read.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('gw_rides_since_last_ad'), 2);
    await svc.markAdShown();
    expect(svc.ridesSinceLastAd, 0);
  });

  test('buying Pro through the fake backend flips premium gates', () async {
    final fake = FakePurchaseBackend()..buyShouldSucceed = true;
    final premium = PremiumService(backend: fake);
    expect(premium.isPro, isFalse);
    final ok = await premium.buyPro();
    expect(ok, isTrue);
    expect(premium.isPro, isTrue);
    expect(premium.isAdFree, isTrue);
    // Core reliability is free regardless.
    expect(premium.canUseCoreAlarm, isTrue);
  });
}
