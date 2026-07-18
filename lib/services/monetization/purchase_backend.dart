// lib/services/monetization/purchase_backend.dart
//
// The billing seam for the monetization layer. The concrete `in_app_purchase`
// implementation is wired in centrally during integration — this file (and the
// whole monetization module) NEVER imports the platform SDK, so the entitlement
// logic stays pure and unit-testable headless.
//
// India-first note (MONETIZATION §B, HANDOFF §5): the primary product is a
// ONE-TIME non-consumable "Pro" unlock (Indians prefer one-time over subs), so
// the backend only needs a one-time purchase + a restore path. Subscriptions,
// if ever added, can extend this interface without touching PremiumService.

import 'dart:async';

/// Where entitlement purchases actually happen. Implemented by a concrete
/// `in_app_purchase`-backed class at integration time; faked in tests.
abstract class PurchaseBackend {
  /// Fired whenever the set of owned product ids changes on the store's
  /// ASYNCHRONOUS purchase stream — crucially including a PENDING purchase
  /// (UPI / netbanking, the dominant rails in India) that CLEARS long after
  /// [buyOneTime] already timed out and returned false. Wire this to
  /// PremiumService so a late-arriving purchase still grants Pro instead of
  /// leaving a paying user on Free until a manual restore.
  void Function(Set<String> owned)? onEntitlementChanged;

  /// Attempt a one-time (non-consumable) purchase of [productId].
  ///
  /// Returns `true` iff the purchase completed and the entitlement is now owned
  /// by the store account. Implementations should return `false` (not throw) on
  /// user-cancel; genuine errors may throw and are handled by the caller.
  Future<bool> buyOneTime(String productId);

  /// Restore previously-owned non-consumable purchases (e.g. after reinstall or
  /// on a new device signed into the same store account).
  ///
  /// Returns the set of owned product ids — empty if nothing is owned. Must not
  /// throw for the "nothing to restore" case.
  Future<Set<String>> restore();

  /// The localized store price string for [productId] (e.g. "₹199.00"), or null
  /// if the store metadata is unavailable. Callers MUST fall back to a hardcoded
  /// price so a metadata failure never blanks the paywall CTA.
  Future<String?> queryPrice(String productId);
}

/// In-memory [PurchaseBackend] for tests and headless runs. Deterministic and
/// SDK-free: it records every call and lets a test script success/decline/throw.
class FakePurchaseBackend implements PurchaseBackend {
  @override
  void Function(Set<String> owned)? onEntitlementChanged;

  final Set<String> _owned;

  /// When `false`, [buyOneTime] resolves `false` (simulates a user-cancel or a
  /// declined charge) and does NOT grant ownership.
  bool buyShouldSucceed;

  /// When `true`, [buyOneTime] throws (simulates a billing error).
  bool throwOnBuy;

  /// When `true`, [restore] throws (simulates a restore error).
  bool throwOnRestore;

  /// Price string [queryPrice] returns (null simulates unavailable store
  /// metadata, exercising the caller's hardcoded fallback).
  String? priceString;

  /// Call log — product ids passed to [buyOneTime], in order.
  final List<String> buyCalls = <String>[];

  /// Number of times [restore] was invoked.
  int restoreCalls = 0;

  FakePurchaseBackend({
    Set<String>? initiallyOwned,
    this.buyShouldSucceed = true,
    this.throwOnBuy = false,
    this.throwOnRestore = false,
    this.priceString = '₹199.00',
  }) : _owned = <String>{...?initiallyOwned};

  /// Products currently owned in the fake store (read-only view).
  Set<String> get owned => Set<String>.unmodifiable(_owned);

  @override
  Future<bool> buyOneTime(String productId) async {
    buyCalls.add(productId);
    if (throwOnBuy) {
      throw StateError('FakePurchaseBackend: buy failed for $productId');
    }
    if (!buyShouldSucceed) return false;
    _owned.add(productId);
    onEntitlementChanged?.call(<String>{..._owned});
    return true;
  }

  /// Test hook: simulate a PENDING purchase clearing AFTER buyOneTime gave up —
  /// ownership arrives on the stream and must still grant entitlement.
  void simulateLatePurchase(String productId) {
    _owned.add(productId);
    onEntitlementChanged?.call(<String>{..._owned});
  }

  @override
  Future<Set<String>> restore() async {
    restoreCalls++;
    if (throwOnRestore) {
      throw StateError('FakePurchaseBackend: restore failed');
    }
    return <String>{..._owned};
  }

  @override
  Future<String?> queryPrice(String productId) async => priceString;
}
