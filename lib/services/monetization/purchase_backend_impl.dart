// lib/services/monetization/purchase_backend_impl.dart
//
// Concrete PurchaseBackend over `in_app_purchase`. The entitlement LOGIC lives
// in premium_service.dart (unit-tested against FakePurchaseBackend); this is the
// store adapter.
//
// DESIGN: FAIL-CLOSED. A purchase is reported successful ONLY when the store
// delivers a `purchased`/`restored` status on the purchase stream — never on a
// timeout, error, cancellation, or a merely-"started" buy flow. That guarantees
// we never grant Pro without a real transaction (and we always completePurchase
// so the store doesn't refund/retry).
//
// DEVICE-VERIFY: real payment flows (pending, deferred, interrupted, restore
// across devices) can only be validated with a store sandbox account on-device.
// The persistent stream listener here is the canonical pattern for exactly those
// asynchronous/late-arriving purchases.

import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

import 'purchase_backend.dart';

class IapPurchaseBackend implements PurchaseBackend {
  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  @override
  void Function(Set<String> owned)? onEntitlementChanged;

  final Set<String> _owned = <String>{};
  final Map<String, Completer<bool>> _pendingBuys = <String, Completer<bool>>{};

  bool _available = false;

  /// Set up the long-lived purchase-stream listener. Call once at app start,
  /// BEFORE reading any entitlement, so late/pending/restored purchases are
  /// captured. Safe to call when the store is unavailable (stays fail-closed).
  Future<void> init() async {
    try {
      _available = await _iap.isAvailable();
      if (!_available) return;
      _sub = _iap.purchaseStream.listen(
        _onPurchases,
        onError: (_) {/* keep listening; individual buys will time out closed */},
      );
    } catch (_) {
      _available = false;
    }
  }

  void _onPurchases(List<PurchaseDetails> purchases) {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          _owned.add(p.productID);
          _pendingBuys[p.productID]?.complete(true);
          // Notify PremiumService EVEN IF no buy is in flight — this is the path
          // that grants Pro for a UPI/pending purchase that clears minutes after
          // buyOneTime already timed out. Without it, the user is charged but
          // stays Free until a manual restore.
          onEntitlementChanged?.call(<String>{..._owned});
          break;
        case PurchaseStatus.error:
        case PurchaseStatus.canceled:
          _pendingBuys[p.productID]?.complete(false);
          break;
        case PurchaseStatus.pending:
          break; // wait; do not resolve
      }
      // Always acknowledge so the store finalises the transaction.
      if (p.pendingCompletePurchase) {
        _iap.completePurchase(p);
      }
    }
  }

  @override
  Future<bool> buyOneTime(String productId) async {
    if (!_available) return false;
    Completer<bool>? completer;
    try {
      final resp = await _iap.queryProductDetails({productId});
      if (resp.productDetails.isEmpty) return false;
      final product = resp.productDetails.firstWhere(
        (d) => d.id == productId,
        orElse: () => resp.productDetails.first,
      );
      completer = Completer<bool>();
      _pendingBuys[productId] = completer;
      final started = await _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
      if (!started) return false;
      // Resolve ONLY on a real stream event; time out fail-closed.
      return await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    } finally {
      if (completer != null) _pendingBuys.remove(productId);
    }
  }

  @override
  Future<Set<String>> restore() async {
    if (!_available) return <String>{};
    try {
      await _iap.restorePurchases();
      // Restored purchases arrive asynchronously on the stream; give them a beat.
      await Future<void>.delayed(const Duration(seconds: 2));
      return Set<String>.from(_owned);
    } catch (_) {
      return <String>{};
    }
  }

  @override
  Future<String?> queryPrice(String productId) async {
    if (!_available) return null;
    try {
      final resp = await _iap.queryProductDetails({productId});
      if (resp.productDetails.isEmpty) return null;
      final product = resp.productDetails.firstWhere(
        (d) => d.id == productId,
        orElse: () => resp.productDetails.first,
      );
      return product.price; // localized store string, e.g. "₹199.00"
    } catch (_) {
      return null; // caller falls back to the hardcoded price
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}
