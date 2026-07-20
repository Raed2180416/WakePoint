// lib/widgets/gated_banner_ad.dart
//
// A banner ad that renders NOTHING unless a real ad is loaded AND policy permits
// it. All the "should we show an ad here" logic lives in AdService/AdPolicy (Pro
// => null, forbidden surface => null, no fill => null); this widget only trusts
// that null contract and collapses to zero height otherwise. That fixes the old
// stub bug where a fixed-height grey bar showed even to paying Pro users.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'package:geowake2/services/monetization/ad_policy.dart';
import 'package:geowake2/services/monetization/ad_service.dart';
import 'package:geowake2/services/monetization/monetization_service.dart';

class GatedBannerAd extends StatefulWidget {
  final AdPlacement placement;
  const GatedBannerAd({super.key, required this.placement});

  @override
  State<GatedBannerAd> createState() => _GatedBannerAdState();
}

class _GatedBannerAdState extends State<GatedBannerAd> {
  BannerAd? _ad;
  bool _loaded = false;

  // Ad SDK init (MonetizationService/AdService) is fired unawaited at startup, so
  // at first paint `premium` may be null and AdService may not be initialized —
  // in which case createBanner returns null. The old code asked exactly ONCE in
  // initState and, if that was too early, the banner stayed blank for the whole
  // session (the reported "test ad disappeared" on-device). We instead retry a
  // bounded number of times until the SDK is ready (or a real no-fill occurs),
  // closing that mount-before-init window. Pro users keep getting null and the
  // widget stays correctly collapsed.
  Timer? _retry;
  int _attempts = 0;
  static const int _maxAttempts = 6;
  static const Duration _retryEvery = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _tryCreate();
  }

  void _scheduleRetry() {
    if (_attempts >= _maxAttempts) return;
    _retry?.cancel();
    _retry = Timer(_retryEvery, () {
      if (mounted) _tryCreate();
    });
  }

  void _tryCreate() {
    if (!mounted || _ad != null) return;
    _attempts++;
    // Not ready yet ⇒ retry rather than give up for the session.
    final premium = MonetizationService.instance.premiumOrNull;
    if (premium == null) {
      _scheduleRetry();
      return;
    }
    final ad = AdService.instance.createBanner(
      placement: widget.placement,
      premium: premium,
      onLoaded: () {
        if (mounted) setState(() => _loaded = true);
      },
      onFailed: () {
        if (!mounted) return;
        setState(() {
          _ad?.dispose();
          _ad = null;
          _loaded = false;
        });
        _scheduleRetry();
      },
    );
    if (ad == null) {
      // AdService not initialized yet (or Pro / forbidden surface ⇒ no ad). The
      // bounded retry covers the init race; for Pro it simply exhausts quietly.
      _scheduleRetry();
      return;
    }
    _ad = ad;
  }

  @override
  void dispose() {
    _retry?.cancel();
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    // Collapse to nothing until a real ad is loaded — never reserve empty space
    // (Pro users and no-fill must see zero-height, not a grey bar).
    if (ad == null || !_loaded) return const SizedBox.shrink();
    return SizedBox(
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }
}
