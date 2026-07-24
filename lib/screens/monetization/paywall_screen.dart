// lib/screens/monetization/paywall_screen.dart
//
// The single upsell surface for GeoWake Pro. Reached ONLY via ProGate.run (a
// locked tap) or the drawer "Go Premium". Trust-first: the top line always
// reminds the user the never-late alarm is free forever — Pro is convenience,
// never safety.
//
// PRICING: a prepaid pass ladder (₹7 daily / ₹35 weekly / ₹99 monthly / ₹899
// yearly). All prepaid, no auto-renew — every purchase is a plain one-time UPI
// charge (no RBI e-mandate), and each pass grants full Pro for its duration.
// See PASS_PRICING_ANALYSIS.md and docs/business_os/03_monetization.md.
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

// Served as static pages by the always-on Railway backend (see
// geowake-server/src/routes/legal.js). geowake.app did not resolve; this domain
// is live. Override at build time once a branded domain exists.
const String _kPrivacyUrl = String.fromEnvironment(
  'GEOWAKE_PRIVACY_URL',
  defaultValue: 'https://geowake-production.up.railway.app/legal/privacy',
);
const String _kTermsUrl = String.fromEnvironment(
  'GEOWAKE_TERMS_URL',
  defaultValue: 'https://geowake-production.up.railway.app/legal/terms',
);

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

/// A prepaid pass option in the ladder.
class _Pass {
  final String sku;
  final String label; // "Monthly"
  final String duration; // "30 days"
  final String fallbackPrice; // shown if store metadata is unavailable
  final String? badge; // "Popular" / "Best value"
  const _Pass(this.sku, this.label, this.duration, this.fallbackPrice,
      [this.badge]);
}

const List<_Pass> _kPasses = [
  _Pass(PremiumProducts.proDaily, 'Daily', '1 day', '₹7'),
  _Pass(PremiumProducts.proWeekly, 'Weekly', '7 days', '₹35'),
  _Pass(PremiumProducts.proMonthly, 'Monthly', '30 days', '₹99', 'Popular'),
  _Pass(PremiumProducts.proYearly, 'Yearly', '365 days', '₹899', 'Best value'),
];

class GeoWakePaywallScreen extends StatefulWidget {
  const GeoWakePaywallScreen({super.key});

  @override
  State<GeoWakePaywallScreen> createState() => _GeoWakePaywallScreenState();
}

class _GeoWakePaywallScreenState extends State<GeoWakePaywallScreen> {
  final _mon = MonetizationService.instance;

  // Live store prices per SKU, seeded with the hardcoded fallbacks so the UI is
  // never blank while store metadata loads.
  final Map<String, String> _prices = {
    for (final p in _kPasses) p.sku: p.fallbackPrice,
  };

  // Default selection: Monthly — the anchor tier the ladder funnels toward.
  String _selectedSku = PremiumProducts.proMonthly;
  bool _busy = false;
  bool _restoreBusy = false;

  @override
  void initState() {
    super.initState();
    _loadPrices();
  }

  Future<void> _loadPrices() async {
    for (final p in _kPasses) {
      final price = await _mon.priceOrFallback(p.sku, p.fallbackPrice);
      if (!mounted) return;
      setState(() => _prices[p.sku] = price);
    }
  }

  Future<void> _buySelected() async {
    if (_busy) return;
    setState(() => _busy = true);
    final sku = _selectedSku;
    final ok = await _mon.buyPass(sku);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _snack('Welcome to GeoWake Pro 🎉');
      Navigator.of(context).maybePop();
    } else {
      final pending = _mon.pendingPurchasesListenable.value;
      if (pending.contains(sku)) {
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
    // Restore recovers a legacy one-time unlock; prepaid passes are consumed and
    // not restorable, so a "nothing found" here is expected for pass users.
    _snack(owned.contains(PremiumService.proProductId)
        ? 'Pro restored ✓'
        : 'No restorable purchase found. Passes renew by buying again.');
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
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
              Text('Your commute on autopilot.',
                  style: text.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
              const SizedBox(height: 4),
              Text(
                'Pick a pass. No auto-renew — it simply ends, and you renew '
                'whenever you like.',
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

              // UPI pending purchase banner — shows when the selected pass's UPI
              // payment is processing. Critical for India (UPI is dominant).
              ValueListenableBuilder<Set<String>>(
                valueListenable: _mon.pendingPurchasesListenable,
                builder: (context, pending, _) {
                  final hasPendingPass =
                      pending.any((id) => _prices.containsKey(id));
                  if (!hasPendingPass) return const SizedBox.shrink();
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
              const SizedBox(height: 20),

              // ── Pass ladder ──────────────────────────────────────────────
              Text('Choose your pass',
                  style: text.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              for (final pass in _kPasses)
                _PassTile(
                  pass: pass,
                  price: _prices[pass.sku] ?? pass.fallbackPrice,
                  selected: pass.sku == _selectedSku,
                  onTap: _busy
                      ? null
                      : () => setState(() => _selectedSku = pass.sku),
                ),
              const SizedBox(height: 16),

              // CTA — buys the selected pass.
              FilledButton(
                onPressed: _busy ? null : _buySelected,
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
                        'Get ${_selectedLabel()} — ${_prices[_selectedSku] ?? ''}',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
              const SizedBox(height: 8),

              // Rewarded day pass — the FREE path to Pro.
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

  String _selectedLabel() {
    for (final p in _kPasses) {
      if (p.sku == _selectedSku) return '${p.label} Pro';
    }
    return 'Pro';
  }
}

class _PassTile extends StatelessWidget {
  final _Pass pass;
  final String price;
  final bool selected;
  final VoidCallback? onTap;
  const _PassTile({
    required this.pass,
    required this.price,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '${pass.label} pass, $price for ${pass.duration}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: 0.5),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(children: [
                Text(pass.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(width: 8),
                Text('· ${pass.duration}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
                if (pass.badge != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.tertiary,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(pass.badge!,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: scheme.onTertiary)),
                  ),
                ],
              ]),
            ),
            Text(price,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
          ]),
        ),
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
