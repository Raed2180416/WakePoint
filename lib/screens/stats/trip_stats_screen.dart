// lib/screens/stats/trip_stats_screen.dart
//
// The Trip Stats surface. Route: /tripStats.
//
// FREE, always (the growth loop): the headline count and the "Share my stats"
// button that exports the branded [ShareStatCard] image. These make NO
// entitlement read.
//
// PRO (canUseTripStatsDashboard): the rich detail panels — streaks, hour
// histogram, top lines, distinct stations — are blurred behind an in-place
// paywall overlay for free users. The single gate goes through ProGate.run so a
// grep enumerates it. Entitlement is read null-safely via the facade
// (premiumOrNull → null resolves to FREE), wrapped in the reactive
// tierListenable so a purchase unlocks with no restart.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/stats/stat_card_exporter.dart';
import 'package:geowake2/services/stats/trip_stats_service.dart';
import 'package:geowake2/services/stats/trip_stats_summary.dart';
import 'package:geowake2/widgets/monetization/pro_gate.dart';
import 'package:geowake2/widgets/stats/share_stat_card.dart';

class TripStatsScreen extends StatefulWidget {
  const TripStatsScreen({super.key});

  @override
  State<TripStatsScreen> createState() => _TripStatsScreenState();
}

class _TripStatsScreenState extends State<TripStatsScreen> {
  final GlobalKey _cardBoundaryKey = GlobalKey();
  Future<TripStatsSummary>? _summaryFuture;
  ShareStatCardData _cardData = ShareStatCardData.monthlyHeadline(0);
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _summaryFuture = TripStatsService.instance.summary().then((s) {
        // Keep the off-screen share card in sync with the latest headline.
        if (mounted) {
          setState(() {
            _cardData = ShareStatCardData.monthlyHeadline(s.monthWokenOnTime);
          });
        }
        return s;
      });
    });
  }

  bool get _isPro =>
      MonetizationService.instance.premiumOrNull?.canUseTripStatsDashboard ??
      false;

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final result = await StatCardExporter.shareCard(_cardBoundaryKey);
    if (!mounted) return;
    setState(() => _sharing = false);
    if (!result.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't create your GeoWake stat card. Try again."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GeoWake · Trip stats')),
      // Rebuild when entitlement changes (purchase / day-pass) so the paywall
      // overlay lifts instantly.
      body: ValueListenableBuilder<EntitlementTier>(
        valueListenable: MonetizationService.instance.tierListenable,
        builder: (context, _, __) {
          return FutureBuilder<TripStatsSummary>(
            future: _summaryFuture,
            builder: (context, snap) {
              final summary = snap.data ?? TripStatsSummary.empty;
              return Stack(
                children: [
                  RefreshIndicator(
                    onRefresh: () async => _reload(),
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _HeadlineCard(
                          count: summary.monthWokenOnTime,
                          lifetime: summary.lifetimeWokenOnTime,
                        ),
                        const SizedBox(height: 12),
                        _ShareRow(sharing: _sharing, onShare: _share),
                        const SizedBox(height: 20),
                        Text(
                          'Your commute, in detail',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        _DetailPanels(summary: summary, locked: !_isPro),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                  // Off-screen (but painted) card used purely as the export
                  // source. Positioned far off-canvas so it never shows yet is
                  // laid out & painted (Offstage would skip painting → toImage
                  // fails).
                  Positioned(
                    left: -100000,
                    top: 0,
                    child: RepaintBoundary(
                      key: _cardBoundaryKey,
                      child: ShareStatCard(data: _cardData),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _HeadlineCard extends StatelessWidget {
  final int count;
  final int lifetime;
  const _HeadlineCard({required this.count, required this.lifetime});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$count',
                style: theme.textTheme.displayMedium
                    ?.copyWith(fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(
              count == 1
                  ? 'GeoWake woke you for your stop once this month'
                  : 'times GeoWake woke you for your stop this month',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('$lifetime on-time wake-ups all time',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}

class _ShareRow extends StatelessWidget {
  final bool sharing;
  final VoidCallback onShare;
  const _ShareRow({required this.sharing, required this.onShare});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        icon: sharing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.ios_share),
        label: Text(sharing ? 'Preparing…' : 'Share my stats'),
        onPressed: sharing ? null : onShare,
      ),
    );
  }
}

/// The Pro detail panels, blurred + overlaid with a paywall CTA when [locked].
class _DetailPanels extends StatelessWidget {
  final TripStatsSummary summary;
  final bool locked;
  const _DetailPanels({required this.summary, required this.locked});

  @override
  Widget build(BuildContext context) {
    final panels = Column(
      children: [
        _StatTile(
          icon: Icons.local_fire_department,
          label: 'Current streak',
          value: '${summary.currentStreakDays} days',
        ),
        _StatTile(
          icon: Icons.emoji_events,
          label: 'Longest streak',
          value: '${summary.longestStreakDays} days',
        ),
        _StatTile(
          icon: Icons.schedule,
          label: 'Busiest hour',
          value: summary.busiestHour == null
              ? '—'
              : _formatHour(summary.busiestHour!),
        ),
        _StatTile(
          icon: Icons.train,
          label: 'Favourite line',
          value: summary.favoriteLine?.line ?? '—',
        ),
        _StatTile(
          icon: Icons.place,
          label: 'Stations visited',
          value: '${summary.distinctStations}',
        ),
      ],
    );

    if (!locked) return panels;

    return Stack(
      children: [
        // Blur + soften the real content behind the overlay.
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: Opacity(opacity: 0.5, child: panels),
        ),
        Positioned.fill(
          child: _TripStatsPaywall(),
        ),
      ],
    );
  }

  static String _formatHour(int h) {
    final period = h < 12 ? 'AM' : 'PM';
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return '$hour12 $period';
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatTile(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: Text(value,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ),
    );
  }
}

/// The in-place upsell shown over the blurred Pro panels. The ONE gate call.
class _TripStatsPaywall extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ProBadge(),
            const SizedBox(height: 12),
            Text(
              'Unlock your full GeoWake stats',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Streaks, patterns and your favourite lines. '
              'Sharing your headline count stays free.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                // Single choke point. `allowed` is a null-safe read; a locked
                // user (this branch) always resolves false → paywall.
                final allowed = MonetizationService
                        .instance.premiumOrNull?.canUseTripStatsDashboard ??
                    false;
                ProGate.run(
                  context,
                  allowed: allowed,
                  source: PaywallSource.tripStats,
                  onAllowed: () {},
                );
              },
              child: const Text('See what Pro unlocks'),
            ),
          ],
        ),
      ),
    );
  }
}
