// lib/screens/monetization/paywall_screen.dart
//
// The single upsell surface for GeoWake Pro. Reached ONLY via ProGate.run (a
// locked tap) or the drawer "Go Premium". Trust-first: the top line always
// reminds the user the never-late alarm is free forever — Pro is convenience,
// never safety.
//
// INDIA-SPECIFIC UX: Shows a "Payment processing…" banner when a UPI purchase
// is in PENDING state, with clear messaging that Pro will unlock automatically
// once payment clears. Distinguishes cancel vs error in snackbar messages.

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

/// GeoWake Pro benefits. Deliberately narrow: this app is position-dependent
/// (a wake alarm you set for wherever you are), so "saved routes", "offline
/// packs", and "recurring auto-arm" don't fit — you must be online + present to
/// plan/start a route. Transfer/interchange alarms already ship FREE.
const List<_ProItem> _kItems = [
  _ProItem(Icons.favorite, 'Guardian mode',
      'Auto-share your journey with family + an "arrived safely" alert.',
      PaywallSource.guardian),
  _ProItem(Icons.shield, 'Anti-theft mode',
      'Loud alarm if someone snatches your phone while you sleep on transit.',
      PaywallSource.antiTheft),
  _ProItem(Icons.music_note, 'Custom & escalating alarm',
      'Your own sounds, ramping volume that won\'t let you sleep through it.',
      PaywallSource.customSound),
  _ProItem(Icons.widgets, 'Home widget',
      'One-tap arm from your home screen.', PaywallSource.widget),
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
  bool _restoreBusy = false;

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
      // Check if the purchase is pending (UPI) — different message.
      final pending = _mon.pendingPurchasesListenable.value;
      if (pending.contains(PremiumService.proProductId)) {
        _snack('Payment processing — Pro will unlock automatically once it clears.');
      } else {
        _snack('Purchase didn\'t complete. You can try again anytime.');
      }
    }
  }

  Future<void> _restore() async {
    if (_restoreBusy) return;
    setState(() => _restoreBusy = true);
    final owned = await _mon.restorePurchases();
    if (!mounted) return;
    setState(() => _restoreBusy = false);
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
    final text = Theme.of(context).textTheme;

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
              // Hero headline
              Text('Your commute on autopilot.',
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
              const SizedBox(height: 4),
              Text(
                'One-time purchase. Yours forever. No subscription.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
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

              // UPI pending purchase banner — shows when a UPI payment is
              // processing. Critical for India where UPI is the dominant rail.
              ValueListenableBuilder<Set<String>>(
                valueListenable: _mon.pendingPurchasesListenable,
                builder: (context, pending, _) {
                  if (!pending.contains(PremiumService.proProductId)) {
                    return const SizedBox.shrink();
                  }
                  return Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: scheme.tertiary.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onTertiaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Payment processing…',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onTertiaryContainer,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Your UPI payment is being verified. Pro will '
                                'unlock automatically once it clears — usually '
                                'within a few minutes. You can close this screen.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onTertiaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

              // Benefits list
              for (final item in _kItems)
                _ValueRow(item: item, highlight: item.source == source),
              const SizedBox(height: 24),

              // CTA button
              FilledButton(
                onPressed: _busy ? null : _buy,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        'Unlock forever — $_price',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
              const SizedBox(height: 8),

              // Rewarded day pass
              if (_mon.premiumOrNull?.isPro == false)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _watchForDayPass,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Watch a short video for a free day of Pro'),
                ),
              const SizedBox(height: 12),

              // Restore + legal links
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                TextButton(
                  onPressed: _restoreBusy ? null : _restore,
                  child: _restoreBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Restore purchase'),
                ),
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: highlight ? scheme.primaryContainer : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: highlight
            ? Border.all(color: scheme.primary.withValues(alpha: 0.3), width: 1.5)
            : null,
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: highlight
                ? scheme.primary.withValues(alpha: 0.15)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            item.icon,
            color: highlight ? scheme.onPrimaryContainer : scheme.primary,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 2),
              Text(item.subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  )),
            ],
          ),
        ),
        if (highlight)
          Icon(Icons.check_circle, color: scheme.primary, size: 20),
      ]),
    );
  }
}

class _AlreadyPro extends StatelessWidget {
  final VoidCallback onDone;
  const _AlreadyPro({required this.onDone});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.verified, size: 40, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 20),
          Text('You\'re on GeoWake Pro',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              )),
          const SizedBox(height: 8),
          Text('Thanks for supporting GeoWake.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              )),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: onDone,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            ),
            child: const Text('Done'),
          ),
        ]),
      ),
    );
  }
}
