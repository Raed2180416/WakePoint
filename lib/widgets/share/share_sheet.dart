// lib/widgets/share/share_sheet.dart
//
// The FREE "Share your journey" bottom sheet — the viral growth loop. Carries
// NO entitlement check anywhere: any user, one tap. Builds a GeoWake share
// message + `/j/{id}` link and hands it to the OS share sheet via share_plus.
//
// Never touches the arm/track/alarm spine; a share failure only shows a
// SnackBar.

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/share/journey_share_service.dart';

/// Show the free share sheet. [destLabel]/[eta] are best-known trip context used
/// only to enrich the message copy (never PII coordinates).
Future<void> showJourneyShareSheet(
  BuildContext context, {
  String? destLabel,
  DateTime? eta,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ShareSheet(destLabel: destLabel, eta: eta),
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({this.destLabel, this.eta});
  final String? destLabel;
  final DateTime? eta;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  bool _busy = false;

  Future<void> _share() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final started = await JourneyShareService.instance.startBasicShare(
        destLabel: widget.destLabel,
        eta: widget.eta,
      );
      // Hand to the OS share sheet — WhatsApp / SMS / anything.
      await Share.share(started.message, subject: 'My ride status · GeoWake');
      if (mounted) Navigator.of(context).maybePop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn\'t open share just now')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The human-readable status the recipient will see (no URL) — for the
  /// in-sheet preview. Mirrors ShareLinkBuilder.buildBasicMessage's copy.
  String _statusPreview() {
    final d = widget.destLabel?.trim();
    final dest = (d != null && d.isNotEmpty) ? ' to $d' : '';
    final e = widget.eta;
    final when = e != null
        ? ' — arriving ~${e.toLocal().hour}:${e.toLocal().minute.toString().padLeft(2, '0')}'
        : '';
    return 'On my way$dest$when';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.ios_share, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text('Share ride status', style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 12),
            // Preview: exactly what your friend sees, so sharing is a clear,
            // one-time consent moment (it's a location share).
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(children: [
                const Icon(Icons.directions_transit, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _statusPreview(),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Text(
              'Send via WhatsApp, SMS — anywhere. If they don\'t have GeoWake '
              'they\'ll still see your status and can get the app. Free, for '
              'everyone.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _busy ? null : _share,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: const Text('Share ride status'),
            ),
          ],
        ),
      ),
    );
  }
}
