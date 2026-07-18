// lib/widgets/post_arrival_card.dart
//
// The post-arrival contextual card — MONETIZATION.md §C, the highest-leverage,
// non-creepy placement ("intent, not impressions"). Shown ONLY after the wake
// alarm is dismissed (PostArrivalService.shouldShow), it serves the rider's real
// last-mile need (book a ride, food, directions) at the moment they step off the
// train. The model is PII-free by construction (PostArrivalService validates).

import 'package:flutter/material.dart';

import 'package:geowake2/services/monetization/post_arrival_service.dart';

/// Renders a [PostArrivalCard]. [onAction] receives the tapped action's kind
/// (see [PostArrivalActionKind]); the host wires it to the affiliate deep-link
/// (Rapido/Ola/Uber) or a dismiss.
class PostArrivalCardWidget extends StatelessWidget {
  final PostArrivalCard card;
  final void Function(String kind) onAction;

  const PostArrivalCardWidget({
    super.key,
    required this.card,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary =
        card.actions.where((a) => a.isPrimary).toList(growable: false);
    final secondary =
        card.actions.where((a) => !a.isPrimary).toList(growable: false);

    return Card(
      key: const Key('post_arrival_card'),
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              card.title,
              key: const Key('post_arrival_title'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final a in primary)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.icon(
                  key: Key('post_arrival_action_${a.kind}'),
                  icon: Icon(_iconFor(a.kind)),
                  label: Text(a.label),
                  onPressed: () => onAction(a.kind),
                ),
              ),
            if (secondary.isNotEmpty)
              Wrap(
                spacing: 8,
                children: [
                  for (final a in secondary)
                    OutlinedButton.icon(
                      key: Key('post_arrival_action_${a.kind}'),
                      icon: Icon(_iconFor(a.kind)),
                      label: Text(a.label),
                      onPressed: () => onAction(a.kind),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String kind) {
    switch (kind) {
      case PostArrivalActionKind.rideHailing:
        return Icons.local_taxi;
      case PostArrivalActionKind.food:
        return Icons.restaurant;
      case PostArrivalActionKind.directions:
        return Icons.directions_walk;
      case PostArrivalActionKind.dismiss:
      default:
        return Icons.close;
    }
  }
}
