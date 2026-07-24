// Regression tests for the frequency-capped post-arrival interstitial (E)
// wired in PostArrivalScreen. Before this fix:
//   - AdService.maybeShowInterstitial had zero production call sites — the
//     "every 3 rides" interstitial documented in ad_policy.dart/ad_service.dart
//     never actually fired anywhere.
//   - AdPolicy.frequencyCappedPlacements had been moved from {postArrival} to
//     {routeArming}, but post_arrival_screen.dart's rewarded-offer gate still
//     keyed off AdPlacement.postArrival, which (no longer capped) made canShow
//     fall through to unconditional true — the rewarded "free day of Pro"
//     strip showed on EVERY arrival instead of every 3rd ride.
//
// AdService can't actually render an ad headless (no AdMob SDK / platform
// channel in tests — see AdService._gate's `!_initialized` / non-mobile-host
// checks), so these tests exercise the REAL call path end-to-end (the widget
// really invokes AdService.instance.maybeShowInterstitial(placement:
// AdPlacement.postArrival, ...) from its post-frame callback) and assert on
// the two externally-observable contracts: (1) the attempt never crashes or
// blocks the screen, and (2) the rewarded strip's own eligibility again
// correctly respects the every-3-rides cap at the postArrival placement.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/screens/monetization/post_arrival_screen.dart';
import 'package:geowake2/services/monetization/monetization_service.dart';
import 'package:geowake2/services/monetization/post_arrival_service.dart';
import 'package:geowake2/services/monetization/premium_service.dart';
import 'package:geowake2/services/monetization/purchase_backend.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  final mon = MonetizationService.instance;

  setUpAll(() async {
    // MonetizationService.init() reads/writes SharedPreferences (the ride
    // counter, PremiumService persistence) — without a mock store, those
    // calls hit a real, unregistered platform channel headless.
    SharedPreferences.setMockInitialValues({});
    await mon.init(backendOverride: FakePurchaseBackend());
  });

  testWidgets(
      'a free user AT the interstitial cap: the post-frame interstitial '
      'attempt never crashes the screen, and the rewarded strip (still the '
      'only surface that can actually render headless) is shown', (tester) async {
    mon.premium = PremiumService(backend: FakePurchaseBackend());
    // Drive ridesSinceLastAd to the cap (3) via the real facade counter.
    await mon.markAdShown(); // reset to a known 0 first
    await mon.recordRide();
    await mon.recordRide();
    await mon.recordRide();
    expect(mon.ridesSinceLastAd, 3);

    final card = PostArrivalService.build(stationName: 'Indiranagar');
    await tester.pumpWidget(_host(card));
    // Flush the post-frame callback that fires _maybeShowInterstitial().
    await tester.pumpAndSettle();

    // AdService can't actually show an ad headless (uninitialized SDK / no
    // platform channel), so it fails open (returns false) and the screen
    // must still be fully usable — this is the "never blocks arriving at
    // this screen" contract from the class doc comment.
    expect(find.byKey(const Key('post_arrival_screen_title')), findsOneWidget);
    // Since the interstitial genuinely never displayed, the rewarded strip
    // must still be offered normally — the new _interstitialShown guard must
    // not suppress it just because an attempt was MADE.
    expect(find.byKey(const Key('post_arrival_rewarded_strip')), findsOneWidget);
  });

  testWidgets(
      'a free user BELOW the cap: the rewarded strip is hidden (the '
      'documented every-3-rides floor, restored)', (tester) async {
    mon.premium = PremiumService(backend: FakePurchaseBackend());
    await mon.markAdShown(); // ridesSinceLastAd -> 0, below the cap of 3

    final card = PostArrivalService.build(stationName: 'MG Road');
    await tester.pumpWidget(_host(card));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('post_arrival_rewarded_strip')), findsNothing,
        reason: 'below the frequency cap, neither the interstitial nor the '
            'rewarded offer should appear');
  });

  testWidgets(
      'a Pro user: no rewarded strip, and the interstitial attempt (which '
      'internally gates on isPro) never crashes the screen', (tester) async {
    mon.premium = PremiumService(backend: FakePurchaseBackend());
    await mon.premium.buyPro();
    await mon.markAdShown();
    await mon.recordRide();
    await mon.recordRide();
    await mon.recordRide();

    final card = PostArrivalService.build(stationName: 'Whitefield');
    await tester.pumpWidget(_host(card));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('post_arrival_screen_title')), findsOneWidget);
    expect(find.byKey(const Key('post_arrival_rewarded_strip')), findsNothing,
        reason: 'Pro must never see any monetization surface here');
  });

  testWidgets(
      'tapping Watch on the rewarded strip does not crash even though it '
      'races the interstitial post-frame attempt', (tester) async {
    mon.premium = PremiumService(backend: FakePurchaseBackend());
    await mon.markAdShown();
    await mon.recordRide();
    await mon.recordRide();
    await mon.recordRide();

    final card = PostArrivalService.build(stationName: 'Koramangala');
    await tester.pumpWidget(_host(card));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('post_arrival_rewarded_strip')), findsOneWidget);
    await tester.tap(find.text('Watch'));
    await tester.pumpAndSettle();

    // AdService.showRewarded is fail-open headless too — the screen must
    // still be alive and responsive afterwards.
    expect(find.byKey(const Key('post_arrival_screen_title')), findsOneWidget);
  });
}
