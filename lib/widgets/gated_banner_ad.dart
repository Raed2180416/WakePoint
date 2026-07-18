// lib/widgets/gated_banner_ad.dart
//
// A banner ad that renders NOTHING unless a real ad is loaded AND policy permits
// it. All the "should we show an ad here" logic lives in AdService/AdPolicy (Pro
// => null, forbidden surface => null, no fill => null); this widget only trusts
// that null contract and collapses to zero height otherwise. That fixes the old
// stub bug where a fixed-height grey bar showed even to paying Pro users.

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

  @override
  void initState() {
    super.initState();
    // Monetization may not have finished init at first paint — treat "not ready"
    // as "no ad" (render nothing) rather than crashing on the late `premium`.
    final premium = MonetizationService.instance.premiumOrNull;
    if (premium == null) return;
    _ad = AdService.instance.createBanner(
      placement: widget.placement,
      premium: premium,
      onLoaded: () {
        if (mounted) setState(() => _loaded = true);
      },
      onFailed: () {
        if (mounted) {
          setState(() {
            _ad = null;
            _loaded = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
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
