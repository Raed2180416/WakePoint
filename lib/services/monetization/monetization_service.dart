// lib/services/monetization/monetization_service.dart
//
// App-level facade that assembles the monetization stack: PremiumService (the
// unit-tested entitlement logic) backed by the real store adapter and
// SharedPreferences persistence, plus the ride counter that drives the ad
// frequency cap. Everything degrades gracefully — if the store is unavailable
// or prefs fail, the user is simply a free (never a broken) user, and the core
// alarm is never affected (PremiumService.canUseCoreAlarm is always true).

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ad_service.dart';
import 'premium_service.dart';
import 'purchase_backend.dart';
import 'purchase_backend_impl.dart';

class MonetizationService {
  MonetizationService._();
  static final MonetizationService instance = MonetizationService._();

  static const String _ridesKey = 'gw_rides_since_last_ad';

  /// Hardcoded fallback price shown if the store metadata is unavailable, so the
  /// paywall CTA never blanks. Matches the Play Console SKU list price (₹199).
  static const String proPriceFallback = '₹199';

  late PremiumService premium;
  PurchaseBackend? _backend;
  bool _ready = false;

  /// Reactive entitlement tier. UI wraps this in a [ValueListenableBuilder] so a
  /// purchase / rewarded day-pass instantly hides ads + unlocks Pro with no
  /// restart. UI MUST mutate entitlement through this facade (buyPro /
  /// restorePurchases / grantRewardedDayPass), never PremiumService directly, so
  /// the notifier stays in sync.
  final ValueNotifier<EntitlementTier> tierListenable =
      ValueNotifier<EntitlementTier>(EntitlementTier.free);

  void _syncTier() {
    tierListenable.value = _ready ? premium.tier : EntitlementTier.free;
  }

  /// True once [init] has assembled the entitlement stack.
  bool get isReady => _ready;

  /// Safe accessor for callers that may run before [init] completes (e.g. a
  /// banner widget mounting at first paint) — null until ready.
  PremiumService? get premiumOrNull => _ready ? premium : null;

  int _ridesSinceLastAd = 0;
  int get ridesSinceLastAd => _ridesSinceLastAd;

  /// Assemble + load entitlement. Call once at app start before reading gates.
  /// [backendOverride] lets tests inject a FakePurchaseBackend.
  Future<void> init({PurchaseBackend? backendOverride}) async {
    if (_ready) return;
    try {
      if (backendOverride != null) {
        _backend = backendOverride;
      } else {
        final iap = IapPurchaseBackend();
        await iap.init();
        _backend = iap;
      }
      premium = PremiumService(
        backend: _backend!,
        load: (k) async => (await SharedPreferences.getInstance()).getString(k),
        save: (k, v) async =>
            (await SharedPreferences.getInstance()).setString(k, v),
      );
      // Grant Pro whenever ownership arrives asynchronously (a UPI/pending
      // purchase that clears after buyPro timed out, or a late restore). Sync
      // the reactive tier so a late-arriving purchase instantly unlocks the UI.
      _backend!.onEntitlementChanged = (owned) async {
        await premium.applyOwnedProducts(owned);
        _syncTier();
      };
      await premium.load();
      final prefs = await SharedPreferences.getInstance();
      _ridesSinceLastAd = prefs.getInt(_ridesKey) ?? 0;
      _ready = true;
      _syncTier();
      // Ad SDK init is slow and non-essential — never block startup on it.
      // ignore: discarded_futures
      AdService.instance.init();
    } catch (_) {
      // Fall back to a free, in-memory-backed premium so the app still runs.
      _backend ??= FakePurchaseBackend();
      premium = PremiumService(backend: _backend!);
      _ready = true;
      _syncTier();
    }
  }

  // ── Entitlement mutations — call THESE from UI, not PremiumService, so the
  //    reactive [tierListenable] stays in sync. ──────────────────────────────

  /// Buy the one-time Pro unlock. Returns true iff granted.
  Future<bool> buyPro() async {
    if (!_ready) return false;
    final ok = await premium.buyPro();
    _syncTier();
    return ok;
  }

  /// Restore prior purchases (reinstall / new device). Returns owned product ids.
  Future<Set<String>> restorePurchases() async {
    if (!_ready) return <String>{};
    final owned = await premium.restorePurchases();
    _syncTier();
    return owned;
  }

  /// Grant a rewarded "Pro for a day" pass (call after a rewarded video completes).
  Future<void> grantRewardedDayPass({
    Duration duration = PremiumService.rewardedDayPassDuration,
  }) async {
    if (!_ready) return;
    await premium.grantRewardedDayPass(duration: duration);
    _syncTier();
  }

  /// Localized Pro price string, falling back to [proPriceFallback] if the store
  /// metadata is unavailable — so the paywall CTA never blanks or crashes.
  Future<String> proPriceOrFallback() async {
    try {
      final p = await _backend?.queryPrice(PremiumService.proProductId);
      if (p != null && p.trim().isNotEmpty) return p;
    } catch (_) {/* fall through */}
    return proPriceFallback;
  }

  /// Count a completed ride and persist it (drives the ad frequency cap).
  Future<void> recordRide() async {
    _ridesSinceLastAd++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_ridesKey, _ridesSinceLastAd);
    } catch (_) {/* best effort */}
  }

  /// Reset the counter after an ad was shown.
  Future<void> markAdShown() async {
    _ridesSinceLastAd = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_ridesKey, 0);
    } catch (_) {/* best effort */}
  }
}
