// Widget test for the post-arrival card (MONETIZATION §C flagship placement).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/services/monetization/post_arrival_service.dart';
import 'package:geowake2/widgets/post_arrival_card.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders station title + ride-hailing primary CTA', (t) async {
    final card = PostArrivalService.build(stationName: 'Indiranagar');
    await t.pumpWidget(_host(PostArrivalCardWidget(card: card, onAction: (_) {})));

    expect(find.byKey(const Key('post_arrival_card')), findsOneWidget);
    expect(find.textContaining('Indiranagar'), findsOneWidget);
    // The primary last-mile CTA must be present and rendered as the prominent
    // FilledButton (the key is ON the button, so assert its type directly).
    final cta = find.byKey(
        Key('post_arrival_action_${PostArrivalActionKind.rideHailing}'));
    expect(cta, findsOneWidget);
    expect(t.widget(cta), isA<FilledButton>());
  });

  testWidgets('tapping an action invokes onAction with its kind', (t) async {
    String? tapped;
    final card = PostArrivalService.build(
      stationName: 'MG Road',
      nearby: const [LastMileOption(label: 'Coffee nearby', kind: 'food')],
    );
    await t.pumpWidget(
        _host(PostArrivalCardWidget(card: card, onAction: (k) => tapped = k)));

    await t.tap(find.byKey(
        Key('post_arrival_action_${PostArrivalActionKind.rideHailing}')));
    expect(tapped, PostArrivalActionKind.rideHailing);

    await t.tap(find
        .byKey(Key('post_arrival_action_${PostArrivalActionKind.food}')));
    expect(tapped, PostArrivalActionKind.food);
  });

  testWidgets('the card is gated until the alarm is dismissed', (t) async {
    // Governance: shouldShow must be false during the alarm, true after.
    expect(PostArrivalService.shouldShow(alarmDismissed: false), isFalse);
    expect(PostArrivalService.shouldShow(alarmDismissed: true), isTrue);
  });
}
