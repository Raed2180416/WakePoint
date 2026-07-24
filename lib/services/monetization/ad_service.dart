// lib/services/monetization/ad_service.dart
//
// Concrete google_mobile_ads adapter, GATED by the pure, unit-tested AdPolicy +
// PremiumService so the "never during alarm/wake/lockscreen" and "Pro is ad-free"
// rules are enforced by construction, not by discipline at each call site.
//
// DEVICE-VERIFY: ad rendering + fill can only be validated on a real device with
// real AdMob unit IDs. This adapter is deliberately fail-open — any ad error is
// swallowed; ads NEVER block or delay the alarm. Test unit IDs are used until
// real ones are supplied via [configure].

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_policy.dart';
import 'premium_service.dart';

class AdService {
  AdService._();
  static final AdService instance = AdService._();

  final AdPolicy _policy = const AdPolicy();
  bool _initialized = false;

  // Google's official TEST ad unit IDs — safe to ship until real IDs are set.
  // https://developers.google.com/admob/android/test-ads
  static const String _testBanner = 'ca-app-pub-3940256099942544/6300978111';
  static const String _testInterstitial =
      'ca-app-pub-3940256099942544/1033173712';
  static const String _testRewarded = 'ca-app-pub-3940256099942544/5224354917';

  String _bannerUnitId = _testBanner;
  String _interstitialUnitId = _testInterstitial;
  String _rewardedUnitId = _testRewarded;

  /// Supply real AdMob unit IDs (from remote config / build) before going live.
  void configure({String? banner, String? interstitial, String? rewarded}) {
    if (banner != null && banner.isNotEmpty) _bannerUnitId = banner;
    if (interstitial != null && interstitial.isNotEmpty) {
      _interstitialUnitId = interstitial;
    }
    if (rewarded != null && rewarded.isNotEmpty) _rewardedUnitId = rewarded;
  }

  Future<void> init() async {
    if (_initialized) return;
    // Ads exist only on mobile. Skipping other platforms (Linux/macOS/tests)
    // avoids touching the AdMob method channel where it isn't registered — that
    // throws an UNCAUGHT MissingPluginException on a separate async path that a
    // local try/catch can't contain (and would fail headless tests / crash desktop).
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await MobileAds.instance.initialize();
      _initialized = true;
    } catch (e) {
      if (kDebugMode) debugPrint('AdService init failed: $e');
    }
  }

  /// Build a banner for a permitted placement, or null when policy forbids it
  /// (Pro user, forbidden surface, etc.). Caller adds the returned widget size.
  BannerAd? createBanner({
    required AdPlacement placement,
    required PremiumService premium,
    AdSize size = AdSize.banner,
    void Function()? onLoaded,
    void Function()? onFailed,
  }) {
    if (!_gate(placement, premium, ridesSinceLastAd: 0)) return null;
    try {
      final ad = BannerAd(
        adUnitId: _bannerUnitId,
        size: size,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (_) => onLoaded?.call(),
          onAdFailedToLoad: (ad, err) {
            ad.dispose();
            onFailed?.call();
          },
        ),
      );
      ad.load();
      return ad;
    } catch (_) {
      onFailed?.call();
      return null;
    }
  }

  /// Show an interstitial at a permitted, frequency-capped placement
  /// (post-arrival only, every 3 rides — after tracking has fully ended and
  /// the wake alarm is dismissed). No-op (returns false) when policy forbids.
  /// Never throws, never during an ongoing trip or the alarm/wake path.
  Future<bool> maybeShowInterstitial({
    required AdPlacement placement,
    required PremiumService premium,
    required int ridesSinceLastAd,
  }) async {
    if (!_gate(placement, premium, ridesSinceLastAd: ridesSinceLastAd)) {
      return false;
    }
    try {
      final completer = _Once<bool>();
      await InterstitialAd.load(
        adUnitId: _interstitialUnitId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            ad.show();
            completer.complete(true);
          },
          onAdFailedToLoad: (_) => completer.complete(false),
        ),
      );
      return await completer.future;
    } catch (_) {
      return false;
    }
  }

  /// Show a rewarded ad; invokes [onReward] exactly once if the user earns it
  /// (used for the "premium for a day" unlock). Never throws.
  Future<void> showRewarded({
    required PremiumService premium,
    required VoidCallback onReward,
  }) async {
    if (premium.isPro) return; // already premium
    try {
      await RewardedAd.load(
        adUnitId: _rewardedUnitId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            ad.show(onUserEarnedReward: (_, __) => onReward());
          },
          onAdFailedToLoad: (_) {},
        ),
      );
    } catch (_) {/* rewarded ads are best-effort */}
  }

  bool _gate(AdPlacement placement, PremiumService premium,
      {required int ridesSinceLastAd}) {
    if (!_initialized) return false;
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    return _policy.canShow(
      placement,
      isPro: premium.isPro,
      ridesSinceLastAd: ridesSinceLastAd,
    );
  }
}

/// A one-shot completer that ignores a second completion (ad callbacks can race).
class _Once<T> {
  final Completer<T> _c = Completer<T>();
  Future<T> get future => _c.future;
  void complete(T v) {
    if (!_c.isCompleted) _c.complete(v);
  }
}
