// lib/screens/monetization/post_arrival_screen.dart
//
// The POST-ARRIVAL screen — pushed ONLY after the wake alarm has been dismissed
// (never during it). It turns the moment a rider steps off transit into a clean,
// trust-first surface with, in priority order:
//
//   A. "You've arrived at <station> ✓" + the arrival time.
//   B. A FREE, one-tap "I've arrived — share" row (JourneyShareService). This is
//      the viral growth loop and carries NO entitlement check — never gated.
//   C. The existing PostArrivalCardWidget (last-mile ride / food / directions
//      intent), deep-linked out via url_launcher. Generic provider links until
//      affiliate ids land.
//   D. An OPTIONAL, dismissible rewarded "free day of Pro" strip — never
//      forced, never on the alarm, and never shown to Pro.
//   E. A frequency-capped interstitial (AdPolicy.frequencyCappedPlacements,
//      every 3 completed rides), attempted once right after this screen
//      mounts. Never shown to Pro / an active day-pass (AdService's own
//      gate), and skipped for this visit the moment the user engages the
//      rewarded flow in D (see _rewardedEngaged) so the two monetization
//      surfaces never stack on the same arrival.
//
// CORE-SAFETY: this screen is reached only by a pushReplacement AFTER
// TrackingService.completeEndTracking() has already torn tracking down. Nothing
// here runs on, blocks, delays, reorders, or gates the never-late fire or the
// alarm teardown. The routing decision (`decidePostArrival`) is pure and
// swallows every error so a bad input can only ever fall back to Home — it can
// never crash the dismiss path. The interstitial attempt (E) is fired from a
// post-frame callback, strictly AFTER this screen has mounted — i.e. strictly
// after tracking has fully ended — and is itself fail-open (AdService never
// throws), so it can never delay or block arriving at this screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/monetization/ad_policy.dart';
import '../../services/monetization/ad_service.dart';
import '../../services/monetization/monetization_service.dart';
import '../../services/monetization/post_arrival_service.dart';
import '../../services/monetization/premium_service.dart';
import '../../services/share/journey_share_service.dart';
import '../../services/share/share_link_builder.dart';
import '../../widgets/post_arrival_card.dart';

/// The outcome of the post-dismiss routing decision. Pure data — no navigation,
/// no side effects — so it is exhaustively unit-testable.
class PostArrivalDecision {
  /// True → push `/postArrival` with [card]; false → fall back to Home (`/`).
  final bool goPostArrival;
  final PostArrivalCard? card;

  const PostArrivalDecision._(this.goPostArrival, this.card);

  const PostArrivalDecision.home() : this._(false, null);
  const PostArrivalDecision.show(PostArrivalCard card) : this._(true, card);
}

/// Decide whether to show the post-arrival screen, given the monetization
/// readiness and the dismissed-alarm flag. PURE and total: any thrown
/// [PostArrivalPrivacyError] / [ArgumentError] from card construction (e.g. a
/// station name that trips the PII guard) is swallowed and resolves to Home, so
/// the alarm-dismiss path can never be broken by a bad input.
PostArrivalDecision decidePostArrival({
  required bool isReady,
  required bool alarmDismissed,
  String? stationName,
  String? city,
}) {
  try {
    if (isReady && PostArrivalService.shouldShow(alarmDismissed: alarmDismissed)) {
      final card = PostArrivalService.build(
        stationName: (stationName ?? '').trim(),
        city: (city == null || city.trim().isEmpty) ? null : city.trim(),
      );
      return PostArrivalDecision.show(card);
    }
  } catch (_) {
    // PostArrivalPrivacyError is an Error, ArgumentError too — catch BOTH.
  }
  return const PostArrivalDecision.home();
}

class PostArrivalScreen extends StatefulWidget {
  /// Optional direct-injection of the card (tests). In production the card is
  /// read from the route arguments.
  final PostArrivalCard? card;

  const PostArrivalScreen({super.key, this.card});

  /// THE ONE post-dismiss entry point, called from maptracking's END-TRACKING
  /// handlers AFTER `AlarmPlayer.stop()` + `completeEndTracking()` have already
  /// run. It never awaits anything ahead of that teardown (the caller has
  /// finished it), never throws, and ALWAYS lands the app somewhere — either on
  /// `/postArrival` or, failing that, on Home.
  static Future<void> routeAfterDismiss(
    BuildContext context, {
    String? stationName,
    String? city,
  }) async {
    // Count the completed ride for the ad frequency cap. Fire-and-forget: the
    // in-memory counter bumps synchronously, and we never block navigation on
    // the persisted write.
    try {
      unawaited(MonetizationService.instance.recordRide());
    } catch (_) {/* never matters */}

    final decision = decidePostArrival(
      isReady: MonetizationService.instance.isReady,
      alarmDismissed: true,
      stationName: stationName,
      city: city,
    );

    if (!context.mounted) return;
    if (decision.goPostArrival && decision.card != null) {
      Navigator.pushReplacementNamed(
        context,
        '/postArrival',
        arguments: decision.card,
      );
    } else {
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  @override
  State<PostArrivalScreen> createState() => _PostArrivalScreenState();
}

class _PostArrivalScreenState extends State<PostArrivalScreen> {
  final _mon = MonetizationService.instance;

  /// Frozen at first build so the "arrived at h:mm" time is the dismiss moment.
  late final DateTime _arrivedAt;
  bool _rewardedDismissed = false;
  bool _sharing = false;

  /// Set the moment the user engages the rewarded "watch a video" flow (D).
  /// Guards the frequency-capped interstitial (E) from ever firing for this
  /// visit once the user has chosen the rewarded path instead — the two
  /// monetization surfaces must never stack on the same arrival.
  bool _rewardedEngaged = false;
  bool _interstitialAttempted = false;

  /// Set once the interstitial (E) has actually been shown for this visit.
  /// Guards the OTHER direction: hides the rewarded strip (D) for the rest
  /// of this screen's lifetime once the interstitial has fired, so the two
  /// surfaces never appear together even though they share one counter.
  bool _interstitialShown = false;

  PostArrivalCard? _cachedCard;

  @override
  void initState() {
    super.initState();
    _arrivedAt = DateTime.now();
    // Post-frame: this screen has already fully mounted (i.e. tracking has
    // already ended) by the time this runs, and it never blocks first paint.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowInterstitial());
  }

  // --- E. Frequency-capped interstitial (post-arrival only) -----------------

  Future<void> _maybeShowInterstitial() async {
    if (_interstitialAttempted || _rewardedEngaged) return;
    _interstitialAttempted = true;
    if (!_mon.isReady) return;
    final premium = _mon.premiumOrNull;
    if (premium == null) return;
    // Re-check right before actually showing anything: engaging the rewarded
    // flow is synchronous UI, but this stays defensive against a future
    // change that makes AdService.maybeShowInterstitial genuinely async
    // before its own internal gate check.
    if (_rewardedEngaged) return;
    final shown = await AdService.instance.maybeShowInterstitial(
      placement: AdPlacement.postArrival,
      premium: premium,
      ridesSinceLastAd: _mon.ridesSinceLastAd,
    );
    if (shown) {
      await _mon.markAdShown();
      // Hide the rewarded strip for the rest of this visit — it may already
      // be rendered from the first build (ridesSinceLastAd resetting alone
      // doesn't trigger a rebuild), so this is an explicit belt-and-braces
      // guard against showing both surfaces on the same arrival.
      if (mounted) setState(() => _interstitialShown = true);
    }
  }

  /// Resolve the card: explicit constructor arg → route arguments → a safe
  /// generic fallback so the screen can never crash on a missing/odd argument.
  PostArrivalCard _resolveCard() {
    if (_cachedCard != null) return _cachedCard!;
    final fromArg = widget.card ??
        (ModalRoute.of(context)?.settings.arguments as PostArrivalCard?);
    _cachedCard = fromArg ?? _fallbackCard();
    return _cachedCard!;
  }

  PostArrivalCard _fallbackCard() {
    try {
      return PostArrivalService.build(stationName: '');
    } catch (_) {
      // Should never happen (empty name is always clean), but stay total.
      return const PostArrivalCard(
        title: "You've arrived",
        stationName: '',
        actions: [],
      );
    }
  }

  void _goHome() {
    if (mounted) Navigator.of(context).pushReplacementNamed('/');
  }

  // --- B. FREE share (never gated) -----------------------------------------

  Future<void> _shareArrived(PostArrivalCard card) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      // Flip any active shares to "arrived" (fail-safe, fire-and-forget) so a
      // follower's link shows the trip completed.
      unawaited(JourneyShareService.instance.markArrived());
      final message = ShareLinkBuilder.buildArrivedMessage(
        destLabel: card.stationName.isEmpty ? null : card.stationName,
      );
      await Share.share(message, subject: "I've arrived · GeoWake");
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open share just now")),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  // --- C. Last-mile intent (generic deep-links until affiliate ids) ---------

  Future<void> _onCardAction(String kind, PostArrivalCard card) async {
    switch (kind) {
      case PostArrivalActionKind.rideHailing:
        await _showRideChooser(card);
        break;
      case PostArrivalActionKind.food:
        await _open(_mapsSearchUrl('restaurants near ${card.stationName}'));
        break;
      case PostArrivalActionKind.directions:
        await _open(_mapsSearchUrl(card.stationName));
        break;
      case PostArrivalActionKind.dismiss:
      default:
        _goHome();
    }
  }

  Future<void> _showRideChooser(PostArrivalCard card) async {
    // Generic provider links — no affiliate ids yet (External Needs §3). The
    // card carries NO coordinates, so we only ever open a provider entry point.
    const providers = <_RideProvider>[
      _RideProvider('Rapido', 'https://www.rapido.bike/'),
      _RideProvider('Namma Yatri', 'https://nammayatri.in/'),
      _RideProvider('Uber', 'https://m.uber.com/'),
      _RideProvider('Ola', 'https://book.olacabs.com/'),
    ];
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(children: [
                Icon(Icons.local_taxi,
                    color: Theme.of(ctx).colorScheme.primary),
                const SizedBox(width: 12),
                Text('Book a ride from the station',
                    style: Theme.of(ctx).textTheme.titleMedium),
              ]),
            ),
            for (final p in providers)
              ListTile(
                key: Key('ride_provider_${p.name}'),
                leading: const Icon(Icons.open_in_new),
                title: Text(p.name),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _open(p.url);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _mapsSearchUrl(String query) =>
      'https://www.google.com/maps/search/?api=1&query='
      '${Uri.encodeComponent(query)}';

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open that just now")),
        );
      }
    }
  }

  // --- D. Optional rewarded "free day of Pro" strip -------------------------

  bool _shouldOfferRewarded() {
    if (_rewardedDismissed) return false;
    // Never stack with the interstitial (E) on the same visit.
    if (_interstitialShown) return false;
    if (!_mon.isReady) return false;
    final premium = _mon.premiumOrNull;
    if (premium == null || premium.isPro) return false; // null/loading → hide
    final policy = const AdPolicy();
    final eligible = policy.canShow(
      AdPlacement.postArrival,
      isPro: false,
      ridesSinceLastAd: _mon.ridesSinceLastAd,
    );
    if (!eligible) return false;
    return policy.shouldOfferRewardedUnlock(
      isPro: false,
      dayPassActive: premium.hasActiveDayPass,
    );
  }

  Future<void> _watchForDayPass() async {
    // Mark BEFORE the async gap so a not-yet-started interstitial attempt
    // (see _maybeShowInterstitial's re-check) never fires once the user has
    // chosen the rewarded path.
    _rewardedEngaged = true;
    final premium = _mon.premiumOrNull;
    if (premium == null) return;
    await AdService.instance.showRewarded(
      premium: premium,
      onReward: () async {
        await _mon.grantRewardedDayPass();
        await _mon.markAdShown(); // reset the frequency-cap counter
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Pro unlocked for 24 hours ✓')),
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final card = _resolveCard();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Arrived'),
        actions: [
          TextButton(
            key: const Key('post_arrival_done'),
            onPressed: _goHome,
            child: const Text('Done'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // A. Header ---------------------------------------------------------
          Row(
            children: [
              Icon(Icons.check_circle, color: scheme.primary, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.title,
                      key: const Key('post_arrival_screen_title'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      'Arrived at ${ShareLinkBuilder.formatEta(_arrivedAt)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // B. FREE share row — first, prominent, NEVER gated -----------------
          Card(
            color: scheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Let them know you made it',
                    style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Share a free 'I've arrived' note with anyone following "
                    'along. No account needed.',
                    style: TextStyle(color: scheme.onSecondaryContainer),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('post_arrival_share'),
                    onPressed: _sharing ? null : () => _shareArrived(card),
                    icon: _sharing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.ios_share),
                    label: const Text("I've arrived — share"),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // C. Last-mile intent card (existing widget) ------------------------
          PostArrivalCardWidget(
            card: card,
            onAction: (kind) => _onCardAction(kind, card),
          ),

          // D. Optional rewarded strip — reactive so it vanishes on unlock ----
          ValueListenableBuilder<EntitlementTier>(
            valueListenable: _mon.tierListenable,
            builder: (context, _, __) {
              if (!_shouldOfferRewarded()) return const SizedBox.shrink();
              return Card(
                key: const Key('post_arrival_rewarded_strip'),
                margin: const EdgeInsets.only(top: 8),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Try GeoWake Pro free',
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            Text(
                              'Watch a short video for a free day of Pro.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _watchForDayPass,
                        child: const Text('Watch'),
                      ),
                      IconButton(
                        key: const Key('post_arrival_rewarded_dismiss'),
                        tooltip: 'Dismiss',
                        icon: const Icon(Icons.close),
                        onPressed: () =>
                            setState(() => _rewardedDismissed = true),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RideProvider {
  final String name;
  final String url;
  const _RideProvider(this.name, this.url);
}
