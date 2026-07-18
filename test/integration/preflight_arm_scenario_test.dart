// ARM-TIME RELIABILITY PREFLIGHT — realistic device journeys, end to end.
//
// The pure decision logic (ReliabilityPreflightService over FakeReliabilityProbe)
// is already truth-tabled in test/reliability/*. This file is deliberately a
// LEVEL UP: it drives whole India-market device situations through the arm flow
// and proves the two things those unit tests can't:
//
//   1. The REAL arm-flow wiring is FAIL-OPEN. A `block` verdict (notifications
//      off — the alarm literally cannot show) must NEVER prevent arming. We prove
//      this through the actual production UI (showReliabilityPreflightDialog): the
//      only path forward on a block is "Proceed anyway" — there is no cancel/deny
//      that could gate arming — and after it, control returns to the caller which
//      arms. Reliability is advisory, never a hard gate.
//
//   2. The REAL device adapter (ReliabilityPreflightRunner.run() over the concrete
//      PlatformReliabilityProbe) never crashes the arm path and always yields a
//      usable, non-gating result — even headless, where the OS plugins are absent.
//
// Device-only caveat: the EXACT per-permission truth PlatformReliabilityProbe
// reports (real notification/exact-alarm/battery/location OS states) is verifiable
// only on a real Android device. Headless we can still prove the arm path is
// crash-safe and fail-open regardless of what the probe returns — which is the
// reliability-critical property.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/reliability/reliability_preflight_service.dart';
import 'package:geowake2/services/reliability/reliability_preflight_runner.dart';

/// Words that would betray implementation jargon in user-facing copy. If any
/// appears in an issue's title/message, the copy has leaked internals. (OS-label
/// terms a real user sees — "notifications", "battery saver", "Alarms &
/// reminders", "precise location" — are intentionally NOT here.)
const List<String> _jargon = <String>[
  'permission',
  'optimization',
  'doze',
  'foreground',
  'fgs',
  'geofenc',
  'kalman',
  'ekf',
  'sdk',
  'null',
  'boolean',
  'exactalarm',
  'whitelist',
  'exemption',
];

/// Build a probe that models a concrete device's OS state. `true` is the good
/// value for each precondition; `manufacturer` drives OEM-aggressiveness.
FakeReliabilityProbe _device({
  required String manufacturer,
  bool notifications = true,
  bool exactAlarm = true,
  bool batteryExempt = true,
  bool precise = true,
}) =>
    FakeReliabilityProbe(
      oem: manufacturer,
      notifications: notifications,
      exactAlarm: exactAlarm,
      batteryExempt: batteryExempt,
      precise: precise,
    );

Future<PreflightResult> _preflight(FakeReliabilityProbe probe) =>
    ReliabilityPreflightService(probe).check();

int _minSeverityIndex(List<PreflightIssue> issues) =>
    issues.map((i) => i.severity.index).reduce((a, b) => a < b ? a : b);

void main() {
  // ===========================================================================
  // Realistic device situations, driven through the REAL decision logic.
  // ===========================================================================
  group('Scenario preflight verdicts (real ReliabilityPreflightService)', () {
    test(
        'S1 — well-configured Pixel (all green, non-aggressive) => OK, arming proceeds',
        () async {
      final r = await _preflight(_device(manufacturer: 'Google'));

      expect(r.isOk, isTrue);
      expect(r.level, PreflightLevel.ok);
      expect(r.issues, isEmpty);
      expect(r.blocking, isEmpty);
      // A Pixel must not trip OEM-aggressiveness sharpening.
      expect(ReliabilityPreflightService.isAggressiveOem('Google'), isFalse);
    });

    test(
        'S2 — Xiaomi/MIUI, battery-opt ON + exact-alarm OFF => WARN, actionable, most-severe-first',
        () async {
      // "battery-opt ON" for the app == the app is NOT exempt from battery saver.
      final r = await _preflight(_device(
        manufacturer: 'Xiaomi',
        batteryExempt: false,
        exactAlarm: false,
      ));

      expect(r.level, PreflightLevel.warn);
      expect(r.hasWarnings, isTrue);
      expect(r.isBlocked, isFalse);
      expect(r.issues, hasLength(2));

      final battery = r.issueOf(PreflightIssueCode.batteryOptimization);
      final exact = r.issueOf(PreflightIssueCode.exactAlarm);
      expect(battery, isNotNull, reason: 'battery risk must surface');
      expect(exact, isNotNull, reason: 'exact-alarm risk must surface');

      // On an aggressive MIUI ROM both are sharpened to a STRONG warn (the ROM is
      // the #1 cause of a missed wake-up), not a soft advisory.
      expect(battery!.severity, PreflightSeverity.warn);
      expect(exact!.severity, PreflightSeverity.warn);

      // Most-severe-first: severity index is non-decreasing and the first issue is
      // the most severe present.
      for (var i = 1; i < r.issues.length; i++) {
        expect(r.issues[i - 1].severity.index,
            lessThanOrEqualTo(r.issues[i].severity.index),
            reason: 'issues must be ordered most-severe-first');
      }
      expect(r.issues.first.severity.index, _minSeverityIndex(r.issues));

      // Actionable: each issue deep-links to the screen that fixes it.
      expect(battery.fixAction,
          PreflightFixAction.openBatteryOptimizationSettings);
      expect(exact.fixAction, PreflightFixAction.openExactAlarmSettings);
    });

    test(
        'S3 — notifications OFF => BLOCK, yet the result is advisory-only (fail-open contract)',
        () async {
      // Samsung is a common India device; notifications off on ANY device blocks.
      final r =
          await _preflight(_device(manufacturer: 'samsung', notifications: false));

      // It genuinely IS a block: without notifications the alarm can never show.
      expect(r.isBlocked, isTrue);
      expect(r.level, PreflightLevel.block);
      expect(r.blocking, hasLength(1));
      expect(r.blocking.single.code, PreflightIssueCode.notifications);
      expect(r.blocking.single.severity, PreflightSeverity.block);
      // The block is ranked first so the UI leads with it.
      expect(r.issues.first.code, PreflightIssueCode.notifications);

      // FAIL-OPEN semantics on the result itself: the API exposes ONLY
      // informational getters — exactly one of ok/blocked/warn is true — and no
      // gate. "Blocked" is an actionable invitation to fix, never a hard stop, so
      // a caller that treats reliability as advisory can always proceed.
      final trueFlags =
          [r.isOk, r.isBlocked, r.hasWarnings].where((b) => b).length;
      expect(trueFlags, 1, reason: 'level getters are mutually exclusive');
      expect(r.blocking.single.fixAction,
          PreflightFixAction.openNotificationSettings);
      expect(r.blocking.single.message.trim(), isNotEmpty);
    });

    test('S4 — approximate-only location => WARN, actionable', () async {
      final r =
          await _preflight(_device(manufacturer: 'Google', precise: false));

      expect(r.level, PreflightLevel.warn);
      expect(r.hasWarnings, isTrue);
      expect(r.isBlocked, isFalse);
      expect(r.issues, hasLength(1));

      final loc = r.issueOf(PreflightIssueCode.preciseLocation);
      expect(loc, isNotNull);
      expect(loc!.severity, PreflightSeverity.warn);
      expect(loc.fixAction, PreflightFixAction.openLocationSettings);
    });
  });

  // ===========================================================================
  // Every surfaced issue must be user-facing (jargon-free, real sentence) AND
  // carry a valid fixAction — across all the scenario devices at once.
  // ===========================================================================
  group('issue copy is user-facing and every issue is actionable', () {
    const knownActions = <String>{
      PreflightFixAction.openNotificationSettings,
      PreflightFixAction.openExactAlarmSettings,
      PreflightFixAction.openBatteryOptimizationSettings,
      PreflightFixAction.openLocationSettings,
    };

    test('across S1..S4 + a worst-case device', () async {
      final devices = <FakeReliabilityProbe>[
        _device(manufacturer: 'Xiaomi', batteryExempt: false, exactAlarm: false),
        _device(manufacturer: 'samsung', notifications: false),
        _device(manufacturer: 'Google', precise: false),
        // worst case: an aggressive OEM with everything wrong at once.
        _device(
          manufacturer: 'oneplus',
          notifications: false,
          exactAlarm: false,
          batteryExempt: false,
          precise: false,
        ),
      ];

      for (final probe in devices) {
        final r = await _preflight(probe);
        for (final issue in r.issues) {
          expect(issue.title.trim(), isNotEmpty,
              reason: '${issue.code}: title must be non-empty');
          expect(issue.message.trim(), isNotEmpty,
              reason: '${issue.code}: message must be non-empty');
          expect(issue.message.trim().length, greaterThan(12),
              reason: '${issue.code}: message must be a real sentence');
          expect(knownActions, contains(issue.fixAction),
              reason: '${issue.code}: fixAction must be a known deep-link key');

          final haystack = '${issue.title}\n${issue.message}'.toLowerCase();
          for (final term in _jargon) {
            expect(haystack.contains(term), isFalse,
                reason: '${issue.code}: copy leaked jargon "$term"');
          }
        }
      }
    });
  });

  // ===========================================================================
  // FAIL-OPEN arm flow through the REAL production UI.
  // A block never gates arming; a well-configured device is never interrupted.
  // ===========================================================================
  group('arm flow is fail-open (real showReliabilityPreflightDialog)', () {
    testWidgets('well-configured device: no dialog, arming proceeds',
        (tester) async {
      final result = await _preflight(_device(manufacturer: 'Google'));
      expect(result.isOk, isTrue);

      var armed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await showReliabilityPreflightDialog(context, result);
                armed = true; // arm flow continues after the (skipped) dialog.
              },
              child: const Text('Arm'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Arm'));
      await tester.pumpAndSettle();

      // OK result => no interruption at all.
      expect(find.byType(AlertDialog), findsNothing);
      expect(armed, isTrue);
    });

    testWidgets(
        'notifications-off BLOCK: dialog offers ONLY "Proceed anyway"; arming proceeds',
        (tester) async {
      final result =
          await _preflight(_device(manufacturer: 'samsung', notifications: false));
      expect(result.isBlocked, isTrue, reason: 'precondition: this is a block');

      var armed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await showReliabilityPreflightDialog(context, result);
                armed = true; // reached only after the dialog is dismissed.
              },
              child: const Text('Arm'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Arm'));
      await tester.pumpAndSettle();

      // The real arm-time dialog appears for a block, leading with the block copy.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Your alarm may not be able to wake you'), findsOneWidget);
      // It is actionable (a "Fix" deep-link for the notifications issue)...
      expect(find.text('Fix'), findsOneWidget);
      // ...and CRUCIALLY its only way forward is to proceed. There is NO
      // cancel/deny that could gate arming — reliability is never a hard gate.
      expect(find.text('Proceed anyway'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Got it'), findsNothing);
      // The arm flow is still parked on the dialog — not yet armed.
      expect(armed, isFalse);

      await tester.tap(find.text('Proceed anyway'));
      await tester.pumpAndSettle();

      // Control returns to the caller, which proceeds to arm despite the block.
      expect(find.byType(AlertDialog), findsNothing);
      expect(armed, isTrue,
          reason: 'a block must NEVER prevent arming (fail-open)');
    });
  });

  // ===========================================================================
  // REAL device-adapter wiring: ReliabilityPreflightRunner.run() over the
  // concrete PlatformReliabilityProbe. Headless the OS plugins are unavailable;
  // the arm path must still not crash and must stay fail-open.
  // ===========================================================================
  group('real runner wiring never crashes / never gates arming', () {
    testWidgets(
        'run() yields a usable result and the arm flow proceeds whatever it says',
        (tester) async {
      // Reaching the next line at all proves run() did not throw — the arm path
      // is crash-safe even when every OS probe is unavailable. run() touches real
      // platform channels + a timeout Timer, so it MUST execute under runAsync
      // (a bare await in testWidgets' fake-async zone would never fire the timer).
      final result = (await tester.runAsync(ReliabilityPreflightRunner.run))!;
      expect(result, isNotNull);
      // Exactly one level is reported — a coherent verdict, never a broken state.
      final trueFlags =
          [result.isOk, result.isBlocked, result.hasWarnings].where((b) => b);
      expect(trueFlags.length, 1);

      var armed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await showReliabilityPreflightDialog(context, result);
                armed = true;
              },
              child: const Text('Arm'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Arm'));
      await tester.pumpAndSettle();

      // Whatever the (environment-dependent) verdict, the ONLY action lets the
      // rider proceed — never abort — so arming always goes through.
      if (!result.isOk && result.issues.isNotEmpty) {
        final proceedLabel = result.isBlocked ? 'Proceed anyway' : 'Got it';
        expect(find.text(proceedLabel), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
        await tester.tap(find.text(proceedLabel));
        await tester.pumpAndSettle();
      }

      expect(find.byType(AlertDialog), findsNothing);
      expect(armed, isTrue,
          reason: 'the real arm flow must never be gated by reliability');
    });
  });
}
