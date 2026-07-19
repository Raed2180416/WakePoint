// Widget tests for PostArrivalScreen.
//
// Focus: the FREE share row renders with NO entitlement dependency (works even
// when MonetizationService was never initialized), the rewarded strip is hidden
// for a not-ready/free-uninitialized state, and the existing last-mile card is
// mounted.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/screens/monetization/post_arrival_screen.dart';
import 'package:geowake2/services/monetization/post_arrival_service.dart';

Widget _host(PostArrivalCard card) {
  return MaterialApp(
    initialRoute: '/postArrival',
    routes: {
      '/': (_) => const Scaffold(body: Center(child: Text('HOME'))),
      '/postArrival': (_) => PostArrivalScreen(card: card),
    },
  );
}

void main() {
  testWidgets('renders the arrival header from the card', (tester) async {
    final card = PostArrivalService.build(stationName: 'Indiranagar');
    await tester.pumpWidget(_host(card));
    await tester.pump();

    final titleFinder = find.byKey(const Key('post_arrival_screen_title'));
    expect(titleFinder, findsOneWidget);
    expect(tester.widget<Text>(titleFinder).data, "You've arrived at Indiranagar");
  });

  testWidgets('FREE share row is present with no initialized entitlement',
      (tester) async {
    // MonetizationService is NOT initialized in this test — the share row must
    // still render and be usable (basic share is never gated).
    final card = PostArrivalService.build(stationName: 'MG Road');
    await tester.pumpWidget(_host(card));
    await tester.pump();

    expect(find.byKey(const Key('post_arrival_share')), findsOneWidget);
    expect(find.text("I've arrived — share"), findsOneWidget);
  });

  testWidgets('rewarded strip is hidden when monetization is not ready',
      (tester) async {
    final card = PostArrivalService.build(stationName: 'Indiranagar');
    await tester.pumpWidget(_host(card));
    await tester.pump();

    expect(find.byKey(const Key('post_arrival_rewarded_strip')), findsNothing);
  });

  testWidgets('mounts the existing last-mile PostArrivalCardWidget',
      (tester) async {
    final card = PostArrivalService.build(stationName: 'Indiranagar');
    await tester.pumpWidget(_host(card));
    await tester.pump();

    expect(find.byKey(const Key('post_arrival_card')), findsOneWidget);
    // The primary ride-hailing CTA from the existing card is rendered.
    expect(
      find.byKey(const Key(
          'post_arrival_action_${PostArrivalActionKind.rideHailing}')),
      findsOneWidget,
    );
  });

  testWidgets('Done replaces to Home', (tester) async {
    final card = PostArrivalService.build(stationName: 'Indiranagar');
    await tester.pumpWidget(_host(card));
    await tester.pump();

    await tester.tap(find.byKey(const Key('post_arrival_done')));
    await tester.pumpAndSettle();

    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('falls back to a generic card when no argument is supplied',
      (tester) async {
    // No card injected and no route arguments — the screen must not crash.
    await tester.pumpWidget(
      const MaterialApp(home: PostArrivalScreen()),
    );
    await tester.pump();

    // "You've arrived" appears both in the screen header and inside the card;
    // the screen must not crash, and the free share row must still render.
    expect(find.byKey(const Key('post_arrival_screen_title')), findsOneWidget);
    expect(find.byKey(const Key('post_arrival_share')), findsOneWidget);
  });
}
