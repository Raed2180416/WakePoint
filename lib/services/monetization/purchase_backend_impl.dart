// lib/services/monetization/purchase_backend_impl.dart
//
// Concrete PurchaseBackend over `in_app_purchase` (v3.3.0 / Play Billing 7.1.1).
// The entitlement LOGIC lives in premium_service.dart (unit-tested against
// FakePurchaseBackend); this is the store adapter.
//
// DESIGN: FAIL-CLOSED. A purchase is reported successful ONLY when the store
// delivers a `purchased`/`restored` status on the purchase stream — never on a
// timeout, error, cancellation, or a merely-"started" buy flow. That guarantees
// we never grant Pro without a real transaction (and we always completePurchase
// so the store doesn't refund/retry).
//
// INDIA-SPECIFIC (UPI): UPI payments frequently enter a PENDING state that can
// take minutes to hours to clear. We track pending purchases and expose a
// [pendingProductIds] stream so the UI can show "Payment processing…" instead
// of silently doing nothing. When a pending purchase clears, the stream fires
// again with `purchased` status and entitlement is granted — even if the
// buyOneTime() call already timed out.
//
// RESTORE: Each restore()/queryPastPurchases() call gets its OWN completer
// (queued in _restoreWaiters) that resolves when restored purchases arrive on
// the stream, with a timeout fallback — instead of a fixed delay. This is
// what lets launch-time reconciliation and a user-triggered restore run
// concurrently without one call clobbering or stealing the other's signal.
//
// LAUNCH RECONCILIATION: [queryPastPurchases] is called at app start to catch
// purchases completed while the app wasn't running (e.g. a UPI payment that
// cleared overnight). This is the Google-recommended pattern.
//
// DEVICE-VERIFY: real payment flows (pending, deferred, interrupted, restore
// across devices) can only be validated with a store sandbox account on-device.
// The persistent stream listener here is the canonical pattern for exactly those
// asynchronous/late-arriving purchases.

import 'dart:async';
import 'dart:developer' as dev;

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'purchase_backend.dart';

class IapPurchaseBackend implements PurchaseBackend {
  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  @override
  void Function(Set<String> owned)? onEntitlementChanged;

  /// Fired when a purchase enters or leaves the PENDING state, so the UI can
  /// show/hide a "Payment processing…" message. Critical for India (UPI).
  void Function(Set<String> pendingIds)? onPendingChanged;

  final Set<String> _owned = <String>{};
  final Set<String> _pendingProductIds = <String>{};
  final Map<String, Completer<bool>> _pendingBuys = <String, Completer<bool>>{};

  /// Pending restore-completion waiters. `restore()` (user-triggered) and
  /// `queryPastPurchases()` (launch-time reconciliation, fired unawaited from
  /// MonetizationService.init on every app start) can be in flight
  /// concurrently — e.g. the user taps "Restore purchase" within seconds of a
  /// cold start. Each call registers its OWN completer here instead of
  /// sharing a single field, so a fast call's `finally` can never null out a
  /// slower call's still-pending completer (the original bug: both methods
  /// wrote the same `_restoreCompleter` field, so whichever call started
  /// second silently clobbered the first's reference, and the first call's
  /// `finally` could null the field out from under the second). `_onPurchases`
  /// completes and clears every pending waiter on any owned-set change.
  final List<Completer<Set<String>>> _restoreWaiters = <Completer<Set<String>>>[];

  bool _available = false;

  static const String _tokenKeyPrefix = 'gw_purchase_token_';

  /// Products with a currently PENDING purchase (e.g. UPI payment processing).
  Set<String> get pendingProductIds => Set<String>.unmodifiable(_pendingProductIds);

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
    bool pendingChanged = false;
    bool ownedChanged = false;

    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          _owned.add(p.productID);
          _pendingProductIds.remove(p.productID);
          pendingChanged = true;
          ownedChanged = true;
          _pendingBuys[p.productID]?.complete(true);
          // Persist purchase token for server-side verification + support.
          _persistPurchaseToken(p);
          // Notify PremiumService EVEN IF no buy is in flight — this is the path
          // that grants Pro for a UPI/pending purchase that clears minutes after
          // buyOneTime already timed out. Without it, the user is charged but
          // stays Free until a manual restore.
          break;
        case PurchaseStatus.error:
          _pendingProductIds.remove(p.productID);
          pendingChanged = true;
          _pendingBuys[p.productID]?.complete(false);
          if (p.error != null) {
            dev.log('IAP purchase error: ${p.error!.code} — ${p.error!.message}',
                name: 'IAP');
          }
          break;
        case PurchaseStatus.canceled:
          _pendingProductIds.remove(p.productID);
          pendingChanged = true;
          _pendingBuys[p.productID]?.complete(false);
          break;
        case PurchaseStatus.pending:
          // UPI / bank transfer — payment initiated but not yet confirmed.
          // Do NOT resolve the buy completer — wait for purchased or error.
          // Track for UI feedback.
          if (!_pendingProductIds.contains(p.productID)) {
            _pendingProductIds.add(p.productID);
            pendingChanged = true;
          }
          dev.log('IAP purchase pending for ${p.productID} — likely UPI/bank transfer',
              name: 'IAP');
          break;
      }
      // Always acknowledge so the store finalises the transaction.
      if (p.pendingCompletePurchase) {
        _iap.completePurchase(p);
      }
    }

    if (ownedChanged) {
      onEntitlementChanged?.call(<String>{..._owned});
    }
    if (pendingChanged) {
      onPendingChanged?.call(<String>{..._pendingProductIds});
    }

    // Resolve every pending restore()/queryPastPurchases() waiter if we got
    // any restored purchases. Each in-flight call has its own completer, so
    // this never leaves a concurrent caller waiting on a wrong/cleared field.
    if (ownedChanged && _restoreWaiters.isNotEmpty) {
      final owned = <String>{..._owned};
      for (final waiter in _restoreWaiters) {
        if (!waiter.isCompleted) waiter.complete(owned);
      }
      _restoreWaiters.clear();
    }
  }

  /// Persist the purchase token for server-side verification and support/refund
  /// tracking. Best-effort — never blocks the purchase flow.
  Future<void> _persistPurchaseToken(PurchaseDetails p) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_tokenKeyPrefix${p.productID}', p.purchaseID ?? '');
    } catch (_) {/* best-effort */}
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
      // 5 minutes allows for UPI collection flows that require user action.
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
    // Own completer for THIS call — never shared with a concurrent
    // queryPastPurchases()/restore() invocation (see _restoreWaiters doc).
    final completer = Completer<Set<String>>();
    _restoreWaiters.add(completer);
    try {
      // Resolves when restored purchases arrive on the stream, with a timeout
      // fallback. This is more reliable than a fixed delay.
      await _iap.restorePurchases();
      // Restored purchases arrive asynchronously on the stream. Wait up to 5s
      // for them; if none arrive, return current owned set (possibly empty).
      return await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => Set<String>.from(_owned),
      );
    } catch (_) {
      return <String>{};
    } finally {
      _restoreWaiters.remove(completer);
    }
  }

  /// Query existing purchases at app launch. This catches purchases completed
  /// while the app wasn't running (e.g. a UPI payment that cleared overnight).
  /// Google recommends calling this on every app launch / foreground.
  ///
  /// On the Flutter `in_app_purchase` plugin, the purchase stream replays
  /// unconsumed purchases on listener attach, so this is partially handled by
  /// the persistent stream. However, calling restorePurchases() with a short
  /// timeout ensures we reconcile even if the stream missed events.
  Future<void> queryPastPurchases() async {
    if (!_available) return;
    // Own completer for THIS call — see _restoreWaiters doc for why this must
    // never be a single shared field with restore().
    final completer = Completer<Set<String>>();
    _restoreWaiters.add(completer);
    try {
      // The plugin's restorePurchases triggers the stream to replay existing
      // non-consumed purchases. We use a short timeout since we just want to
      // reconcile quickly at launch.
      await _iap.restorePurchases();
      await completer.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => <String>{},
      );
    } catch (_) {
      // Fail-open — existing owned set is unchanged.
    } finally {
      _restoreWaiters.remove(completer);
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
