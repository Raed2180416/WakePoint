// lib/screens/friends_rides_screen.dart
//
// "Friends' rides" — the FOLLOWER surface. Lists the share ids the user is
// following with a live, ROUTE-RELATIVE status ("On the way to X — arriving
// ~8:42", "N min away"). Additive UI only: it reads FollowedRidesService and
// never touches the arm → track → alarm spine. Raw GPS is NEVER shown.

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/share/followed_rides_service.dart';
import '../services/share/share_deep_link.dart';

class FriendsRidesScreen extends StatefulWidget {
  const FriendsRidesScreen({super.key});

  @override
  State<FriendsRidesScreen> createState() => _FriendsRidesScreenState();
}

class _FriendsRidesScreenState extends State<FriendsRidesScreen> {
  final _service = FollowedRidesService.instance;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Poll while this screen is open; also refresh once on entry.
    _service.startPolling();
    unawaited(_service.refreshAll());
    // Repaint every 30 s so the "N min away" line stays current between polls.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  Future<void> _addByLink() async {
    final controller = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text("Follow a friend's ride"),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Paste a GeoWake link',
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text),
                child: const Text('Follow'),
              ),
            ],
          ),
    );
    if (link == null || link.trim().isEmpty) return;
    final parsed = ShareDeepLinkParser.parseString(link.trim());
    if (parsed == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That doesn't look like a GeoWake link")),
      );
      return;
    }
    // Optional LOCAL nickname so the list reads "Amma · On the way to Home"
    // instead of a bare destination. Stored only on this device — no account,
    // no login, and nothing about the name is ever sent to the backend.
    if (!mounted) return;
    final name = await _promptNickname();
    await _service.follow(parsed.id, token: parsed.token, label: name);
  }

  /// Small optional "who is this?" prompt. Returns the trimmed name, or null if
  /// skipped/empty. Purely local — the name is never transmitted anywhere.
  Future<String?> _promptNickname() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Who is this? (optional)'),
            content: TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'e.g. Amma, Rahul'),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Skip'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text),
                child: const Text('Save'),
              ),
            ],
          ),
    );
    final trimmed = name?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Friends' rides")),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addByLink,
        icon: const Icon(Icons.add_link),
        label: const Text('Follow'),
      ),
      body: ValueListenableBuilder<List<FollowedRide>>(
        valueListenable: _service.rides,
        builder: (context, rides, _) {
          if (rides.isEmpty) return const _EmptyState();
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: rides.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = rides[i];
              final away = FollowedRideFormat.minutesAway(r, nowMs: _nowMs);
              final headline = FollowedRideFormat.headline(r);
              final name = r.label?.trim();
              final hasName = name != null && name.isNotEmpty;
              // With a nickname: the name is the title and the route status the
              // subtitle. Without one: the route-relative headline is the title
              // (unchanged behaviour).
              final subtitleText =
                  hasName
                      ? [headline, if (away != null) away].join(' · ')
                      : away;
              return ListTile(
                leading: CircleAvatar(
                  child:
                      hasName
                          ? Text(name.substring(0, 1).toUpperCase())
                          : const Icon(Icons.directions_walk),
                ),
                title: Text(hasName ? name : headline),
                subtitle:
                    (subtitleText == null || subtitleText.isEmpty)
                        ? null
                        : Text(subtitleText),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Stop following',
                  onPressed: () => _service.unfollow(r.id),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodyMedium?.color?.withValues(alpha: 0.7);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.group_outlined, size: 56, color: muted),
            const SizedBox(height: 16),
            Text(
              "You're not following anyone yet",
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              "Paste or open a friend's GeoWake link to see when they'll arrive.",
              style: TextStyle(color: muted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
