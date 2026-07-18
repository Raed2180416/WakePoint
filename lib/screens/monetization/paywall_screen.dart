// lib/screens/monetization/paywall_screen.dart
//
// The single upsell surface for GeoWake Pro. Reached ONLY via ProGate.run (a
// locked tap) or the drawer "Go Premium". Trust-first: the top line always
// reminds the user the never-late alarm is free forever — Pro is convenience,
// never safety.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/monetization/ad_service.dart';
import '../../services/monetization/monetization_service.dart';
import '../../services/monetization/premium_service.dart';
import '../../widgets/monetization/pro_gate.dart';

/// Founder-hosted policy URLs (External Needs §4). Safe placeholders until the
/// real pages exist — the buttons no-op gracefully if the URL can't open.
const String _kPrivacyUrl = 'https://geowake.app/privacy';
const String _kTermsUrl = 'https://geowake.app/terms';

class _ProItem {
  final IconData icon;
  final String title;
  final String subtitle;
  final PaywallSource? source; // for highlight
  const _ProItem(this.icon, this.title, this.subtitle, [this.source]);
}

/// Lead items first (recurring auto-arm, Guardian) per the monetization design.
const List<_ProItem> _kItems = [
  _ProItem(Icons.schedule, 'Recurring auto-arm',
      'Your commute arms itself — set it once, never tap again.',
      PaywallSource.recurringAutoArm),
  _ProItem(Icons.favorite, 'Guardian mode',
      'Auto-share your journey with family + an "arrived safely" alert.',
      PaywallSource.guardian),
  // NOTE: transfer/interchange alarms (wake at each transfer + the destination
  // across a multi-leg journey) already ship and are FREE — do NOT list them as
  // a Pro benefit.
  _ProItem(Icons.bookmark, 'Unlimited saved routes',
      'Pin every commute you take.', PaywallSource.savedRoutes),
  _ProItem(Icons.music_note, 'Custom & escalating alarm',
      'Your own sounds, ramping volume that won\'t let you sleep through it.',
      PaywallSource.customSound),
  _ProItem(Icons.download_for_offline, 'Offline all-cities pack',
      'Every metro, no data needed.', PaywallSource.offline),
  _ProItem(Icons.widgets, 'Home widget & Wear OS',
      'One-tap arm from your home screen or wrist.', PaywallSource.widget),
  _ProItem(Icons.insights, 'Trip stats',
      'Streaks, patterns, and your on-time record.', PaywallSource.tripStats),
  _ProItem(Icons.block, 'Ad-free', 'No ads, anywhere.'),
];

class GeoWakePaywallScreen extends StatefulWidget {
  const GeoWakePaywallScreen({super.key});

  @override
  State<GeoWakePaywallScreen> createState() => _GeoWakePaywallScreenState();
}

class _GeoWakePaywallScreenState extends State<GeoWakePaywallScreen> {
  final _mon = MonetizationService.instance;
  String _price = MonetizationService.proPriceFallback;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadPrice();
  }

  Future<void> _loadPrice() async {
    final p = await _mon.proPriceOrFallback();
    if (mounted) setState(() => _price = p);
  }

  Future<void> _buy() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _mon.buyPro();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _snack('Welcome to GeoWake Pro 🎉');
      Navigator.of(context).maybePop();
    } else {
      _snack('Purchase didn\'t complete. You can try again anytime.');
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);
    final owned = await _mon.restorePurchases();
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(owned.contains(PremiumService.proProductId)
        ? 'Pro restored ✓'
        : 'No previous purchase found.');
  }

  Future<void> _watchForDayPass() async {
    final premium = _mon.premiumOrNull;
    if (premium == null) return;
    await AdService.instance.showRewarded(
      premium: premium,
      onReward: () async {
        await _mon.grantRewardedDayPass();
        if (mounted) _snack('Pro unlocked for 24 hours ✓');
      },
    );
  }

  void _snack(String m) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {/* no-op if unopenable */}
  }

  @override
  Widget build(BuildContext context) {
    final source =
        ModalRoute.of(context)?.settings.arguments as PaywallSource?;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('GeoWake Pro')),
      body: ValueListenableBuilder<EntitlementTier>(
        valueListenable: _mon.tierListenable,
        builder: (context, tier, _) {
          if (tier == EntitlementTier.pro) {
            return _AlreadyPro(onDone: () => Navigator.of(context).maybePop());
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Text('Your commute on autopilot.',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              // Trust strip — ALWAYS at the top.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(children: [
                  Icon(Icons.verified_user, color: scheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Your never-late alarm is free forever. Pro adds '
                      'convenience, not safety.',
                      style: TextStyle(color: scheme.onSecondaryContainer),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              for (final item in _kItems)
                _ValueRow(item: item, highlight: item.source == source),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _buy,
                child: Text(_busy ? 'Please wait…' : 'Unlock forever — $_price'),
              ),
              const SizedBox(height: 8),
              if (_mon.premiumOrNull?.isPro == false)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _watchForDayPass,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Watch a short video for a free day of Pro'),
                ),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                TextButton(onPressed: _busy ? null : _restore,
                    child: const Text('Restore purchase')),
                const Text('·'),
                TextButton(onPressed: () => _open(_kTermsUrl),
                    child: const Text('Terms')),
                TextButton(onPressed: () => _open(_kPrivacyUrl),
                    child: const Text('Privacy')),
              ]),
            ],
          );
        },
      ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  final _ProItem item;
  final bool highlight;
  const _ValueRow({required this.item, required this.highlight});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: highlight ? scheme.primaryContainer : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(item.icon, color: scheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(item.subtitle,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ]),
    );
  }
}

class _AlreadyPro extends StatelessWidget {
  final VoidCallback onDone;
  const _AlreadyPro({required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.verified, size: 64),
        const SizedBox(height: 12),
        Text('You\'re on GeoWake Pro',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Thanks for supporting GeoWake.'),
        const SizedBox(height: 16),
        FilledButton(onPressed: onDone, child: const Text('Done')),
      ]),
    );
  }
}
