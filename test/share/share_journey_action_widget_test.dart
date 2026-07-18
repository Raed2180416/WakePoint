// Widget tests for the FREE ShareJourneyAction AppBar button.
//
// The action is the top of the growth loop and must never gate: it renders and
// opens the free share sheet with no entitlement dependency whatsoever.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/share/journey_share_service.dart';
import 'package:geowake2/widgets/share/share_journey_action.dart';

Widget _host() {
  return MaterialApp(
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Tracking'),
        actions: const [ShareJourneyAction(destLabel: 'Indiranagar')],
      ),
      body: const SizedBox.shrink(),
    ),
  );
}

void main() {
  setUp(() {
    // Ensure a clean, non-sharing baseline.
    JourneyShareService.instance.isSharing.value = false;
  });

  testWidgets('renders as an AppBar action with no entitlement dependency',
      (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    expect(find.byKey(const Key('share_journey_action')), findsOneWidget);
    // Not sharing → the "share" icon, not the live "podcasts" icon.
    expect(find.byIcon(Icons.ios_share), findsOneWidget);
  });

  testWidgets('tap opens the free share sheet', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    await tester.tap(find.byKey(const Key('share_journey_action')));
    await tester.pumpAndSettle();

    // The free "Share ride status" sheet is shown — no paywall, no gate.
    // "Share ride status" is both the sheet title and the send button label.
    expect(find.text('Share ride status'), findsWidgets);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('reflects the live sharing state', (tester) async {
    JourneyShareService.instance.isSharing.value = true;
    await tester.pumpWidget(_host());
    await tester.pump();
    expect(find.byIcon(Icons.podcasts), findsOneWidget);
    JourneyShareService.instance.isSharing.value = false;
  });
}
