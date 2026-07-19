// Headless tests for the GeoWake home-screen widget (FEATURES_SPEC §3.6-A).
// No device, no home_widget plugin, no native side — everything under test is
// pure logic (state resolver, arm-decision truth table, URI parsing) plus the
// SharedPreferences-backed pending-arm handoff and active-session guard.
//
// Load-bearing assertions:
//   * a non-Pro / not-yet-loaded user resolves to the LOCKED render state
//     (never a working arm);
//   * an active session ALWAYS wins over an arm candidate (no double-arm);
//   * headless one-tap arm is permitted ONLY when perms + cached route +
//     clean preflight all hold; every other combination opens the app;
//   * the widget URI parser is scheme-agnostic and null-safe;
//   * the background interactivity callback queues an arm ONLY when idle and
//     never while a journey is active (shared guard).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/widget/widget_arm_handler.dart';
import 'package:geowake2/services/widget/widget_render_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TrackingStateStore.resetCacheForTests();
  });

  group('resolveRenderState (state precedence)', () {
    test('not Pro ⇒ locked, regardless of active/candidate', () {
      expect(
        resolveRenderState(
            canUseWidget: false, isActive: true, hasCandidate: true),
        WidgetRenderState.locked,
      );
      expect(
        resolveRenderState(
            canUseWidget: false, isActive: false, hasCandidate: false),
        WidgetRenderState.locked,
      );
    });

    test('active session wins over an arm candidate (no double-arm)', () {
      expect(
        resolveRenderState(
            canUseWidget: true, isActive: true, hasCandidate: true),
        WidgetRenderState.active,
      );
    });

    test('Pro + idle + candidate ⇒ idle (arm card)', () {
      expect(
        resolveRenderState(
            canUseWidget: true, isActive: false, hasCandidate: true),
        WidgetRenderState.idle,
      );
    });

    test('Pro + idle + no candidate ⇒ empty', () {
      expect(
        resolveRenderState(
            canUseWidget: true, isActive: false, hasCandidate: false),
        WidgetRenderState.empty,
      );
    });
  });

  group('WidgetArmDecision.evaluate (one-tap safety truth table)', () {
    test('all clear ⇒ headless', () {
      expect(
        WidgetArmDecision.evaluate(
          permsGranted: true,
          hasCachedRouteForOrigin: true,
          preflight: WidgetPreflightState.ok,
        ),
        WidgetArmMode.headless,
      );
    });

    test('missing perms ⇒ launchApp', () {
      expect(
        WidgetArmDecision.evaluate(
          permsGranted: false,
          hasCachedRouteForOrigin: true,
          preflight: WidgetPreflightState.ok,
        ),
        WidgetArmMode.launchApp,
      );
    });

    test('no cached route ⇒ launchApp', () {
      expect(
        WidgetArmDecision.evaluate(
          permsGranted: true,
          hasCachedRouteForOrigin: false,
          preflight: WidgetPreflightState.ok,
        ),
        WidgetArmMode.launchApp,
      );
    });

    test('warn / block / unknown preflight ⇒ launchApp (never silent-arm)', () {
      for (final p in const [
        WidgetPreflightState.warn,
        WidgetPreflightState.block,
        WidgetPreflightState.unknown,
      ]) {
        expect(
          WidgetArmDecision.evaluate(
            permsGranted: true,
            hasCachedRouteForOrigin: true,
            preflight: p,
          ),
          WidgetArmMode.launchApp,
          reason: 'preflight $p must not headless-arm',
        );
      }
    });
  });

  group('WidgetArmRequest.parse (scheme-agnostic, null-safe)', () {
    test('null URI ⇒ unknown', () {
      expect(WidgetArmRequest.parse(null).action, WidgetAction.unknown);
    });

    test('geowake://arm?routeId=abc', () {
      final r = WidgetArmRequest.parse(Uri.parse('geowake://arm?routeId=abc'));
      expect(r.action, WidgetAction.arm);
      expect(r.routeId, 'abc');
    });

    test('verb in path segment: geowake://widget/arm?routeId=xy', () {
      final r =
          WidgetArmRequest.parse(Uri.parse('geowake://widget/arm?routeId=xy'));
      expect(r.action, WidgetAction.arm);
      expect(r.routeId, 'xy');
    });

    test('package default scheme homeWidget://arm', () {
      final r = WidgetArmRequest.parse(Uri.parse('homeWidget://arm?routeId=z'));
      expect(r.action, WidgetAction.arm);
      expect(r.routeId, 'z');
    });

    test('arm with blank routeId ⇒ null id', () {
      final r = WidgetArmRequest.parse(Uri.parse('geowake://arm?routeId='));
      expect(r.action, WidgetAction.arm);
      expect(r.routeId, isNull);
    });

    test('open with paywall flag', () {
      final r = WidgetArmRequest.parse(Uri.parse('geowake://open?paywall=1'));
      expect(r.action, WidgetAction.open);
      expect(r.paywall, isTrue);
    });

    test('stop', () {
      expect(WidgetArmRequest.parse(Uri.parse('geowake://stop')).action,
          WidgetAction.stop);
    });

    test('unrecognised verb ⇒ unknown', () {
      expect(WidgetArmRequest.parse(Uri.parse('geowake://frobnicate')).action,
          WidgetAction.unknown);
    });

    test('builders round-trip through the parser', () {
      final arm = WidgetArmRequest.parse(WidgetArmHandler.buildArmUri('r1'));
      expect(arm.action, WidgetAction.arm);
      expect(arm.routeId, 'r1');

      final open = WidgetArmRequest.parse(
          WidgetArmHandler.buildOpenUri(paywall: true));
      expect(open.action, WidgetAction.open);
      expect(open.paywall, isTrue);

      final stop = WidgetArmRequest.parse(WidgetArmHandler.buildStopUri());
      expect(stop.action, WidgetAction.stop);
    });
  });

  group('pending-arm handoff', () {
    test('consumePendingArm reads once then clears', () async {
      SharedPreferences.setMockInitialValues(
          {WidgetArmHandler.pendingArmKey: 'route-42'});
      final first = await WidgetArmHandler.instance.consumePendingArm();
      expect(first, 'route-42');
      final second = await WidgetArmHandler.instance.consumePendingArm();
      expect(second, isNull, reason: 'must be single-shot');
    });

    test('empty / absent pending ⇒ null', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await WidgetArmHandler.instance.consumePendingArm(), isNull);
    });
  });

  group('background interactivity callback (shared active-session guard)', () {
    test('idle: an arm tap queues the pending route', () async {
      SharedPreferences.setMockInitialValues({});
      await TrackingStateStore.setActive(false);
      await widgetInteractivityCallback(WidgetArmHandler.buildArmUri('r7'));
      expect(await WidgetArmHandler.instance.consumePendingArm(), 'r7');
    });

    test('active journey: an arm tap is IGNORED (never double-arm)', () async {
      SharedPreferences.setMockInitialValues({});
      await TrackingStateStore.setActive(true);
      await widgetInteractivityCallback(WidgetArmHandler.buildArmUri('r9'));
      expect(await WidgetArmHandler.instance.consumePendingArm(), isNull);
    });

    test('non-arm actions are ignored by the background callback', () async {
      SharedPreferences.setMockInitialValues({});
      await TrackingStateStore.setActive(false);
      await widgetInteractivityCallback(WidgetArmHandler.buildStopUri());
      expect(await WidgetArmHandler.instance.consumePendingArm(), isNull);
    });
  });
}
