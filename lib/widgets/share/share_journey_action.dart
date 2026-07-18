// lib/widgets/share/share_journey_action.dart
//
// The FREE "Share journey" AppBar action for the live tracking screen — a friend
// can follow along BEFORE/DURING the trip. It is the top of the organic growth
// loop, so it carries NO entitlement check anywhere (test-enforced): any user,
// one tap.
//
// It only opens the existing free share sheet (showJourneyShareSheet), which in
// turn calls JourneyShareService.startBasicShare — a read-only, fail-safe path
// that never touches the arm → track → alarm spine. Tapping it can neither
// delay, gate, nor obstruct the never-late alarm.

import 'package:flutter/material.dart';

import '../../services/share/journey_share_service.dart';
import 'share_sheet.dart';

/// A drop-in `AppBar.actions` button that opens GeoWake's free journey-share
/// sheet. [destLabel] enriches the share copy; [etaProvider] is pulled lazily at
/// tap time so the message carries the freshest ETA without this widget having
/// to rebuild.
class ShareJourneyAction extends StatelessWidget {
  final String? destLabel;
  final DateTime? Function()? etaProvider;

  const ShareJourneyAction({
    super.key,
    this.destLabel,
    this.etaProvider,
  });

  @override
  Widget build(BuildContext context) {
    // Live "You're sharing" affordance: once a share is active the icon flips to
    // a filled state so the user always knows a link is live and can revoke it.
    return ValueListenableBuilder<bool>(
      valueListenable: JourneyShareService.instance.isSharing,
      builder: (context, sharing, _) {
        return IconButton(
          key: const Key('share_journey_action'),
          tooltip: sharing
              ? "You're sharing your ride status · GeoWake"
              : 'Share ride status · GeoWake',
          icon: Icon(sharing ? Icons.podcasts : Icons.ios_share),
          onPressed: () => _onPressed(context, sharing),
        );
      },
    );
  }

  Future<void> _onPressed(BuildContext context, bool sharing) async {
    // If already sharing, offer to stop; otherwise open the share sheet. Both
    // paths are fail-safe and free.
    if (sharing) {
      final stop = await showModalBottomSheet<bool>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Icon(Icons.podcasts,
                      color: Theme.of(ctx).colorScheme.primary),
                  const SizedBox(width: 12),
                  Text("You're sharing your journey",
                      style: Theme.of(ctx).textTheme.titleLarge),
                ]),
                const SizedBox(height: 8),
                const Text(
                  'Anyone with your link can see when you arrive. You can stop '
                  'sharing anytime.',
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop sharing'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Keep sharing'),
                ),
              ],
            ),
          ),
        ),
      );
      if (stop == true) {
        // Fire-and-forget; revokeAll never throws.
        await JourneyShareService.instance.revokeAll();
      }
      return;
    }

    await showJourneyShareSheet(
      context,
      destLabel: destLabel,
      eta: etaProvider?.call(),
    );
  }
}
