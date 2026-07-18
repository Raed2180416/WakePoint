// The India-critical path: a PENDING (UPI/netbanking) purchase that CLEARS after
// buyPro already returned must still grant Pro — the user paid, so they must not
// be stranded on Free until a manual restore.
import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/monetization/purchase_backend.dart';

void main() {
  test('a late-arriving (pending/UPI) purchase grants Pro via the backend callback',
      () async {
    final backend = FakePurchaseBackend()..buyShouldSucceed = false; // "still pending"
    final premium = PremiumService(backend: backend);
    // Wire the same callback MonetizationService.init wires.
    backend.onEntitlementChanged = (owned) => premium.applyOwnedProducts(owned);

    // buyPro returns false (the UPI charge hasn't cleared yet) — user is Free.
    final immediate = await premium.buyPro();
    expect(immediate, isFalse);
    expect(premium.isPro, isFalse);

    // Minutes later the UPI mandate clears; the store delivers the purchase on
    // its stream. This must grant Pro without any further user action.
    backend.simulateLatePurchase(PremiumProducts.proOneTime);
    // Let the async applyOwnedProducts persist.
    await Future<void>.delayed(Duration.zero);

    expect(premium.isPro, isTrue,
        reason: 'a cleared UPI purchase must grant Pro even after buyPro gave up');
    expect(premium.hasProOneTime, isTrue);
  });

  test('applyOwnedProducts is idempotent and never grants without the product',
      () async {
    final backend = FakePurchaseBackend();
    final premium = PremiumService(backend: backend);
    await premium.applyOwnedProducts({'some.other.sku'});
    expect(premium.isPro, isFalse); // wrong product => no grant
    await premium.applyOwnedProducts({PremiumProducts.proOneTime});
    expect(premium.isPro, isTrue);
    await premium.applyOwnedProducts({PremiumProducts.proOneTime}); // idempotent
    expect(premium.isPro, isTrue);
  });
}
