// Widget test for the arm-time reliability preflight DIALOG (the integrated
// UI surface). Verifies it renders the issues + per-issue Fix actions, and that
// a BLOCK verdict honestly refuses to arm (offers "Cancel", not a dismissible
// "Proceed anyway"), while a WARN verdict is advisory ("Got it").
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/services/reliability/reliability_preflight_service.dart';
import 'package:geowake2/services/reliability/reliability_preflight_runner.dart';

Future<void> _open(WidgetTester t, PreflightResult result) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => Center(
          child: ElevatedButton(
            onPressed: () => showReliabilityPreflightDialog(ctx, result),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('BLOCK (notifications off) shows issues + a Fix + "Cancel"',
      (t) async {
    final result = await ReliabilityPreflightService(
      FakeReliabilityProbe(notifications: false, oem: 'xiaomi'),
    ).check();
    expect(result.isBlocked, isTrue);

    await _open(t, result);

    // A dialog is up with the blocking title and the notifications issue copy.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('wake'), findsWidgets);
    // Per-issue Fix action(s) are offered.
    expect(find.widgetWithText(TextButton, 'Fix'), findsWidgets);
    // Honest refusal: a BLOCK offers "Cancel" (no silent arming of a channel the
    // OS won't let us deliver), not a dismissible "Proceed anyway".
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Proceed anyway'), findsNothing);
  });

  testWidgets('WARN (aggressive OEM, no exact-alarm/battery) shows "Got it"',
      (t) async {
    final result = await ReliabilityPreflightService(
      FakeReliabilityProbe(
          exactAlarm: false, batteryExempt: false, oem: 'oppo'),
    ).check();
    expect(result.hasWarnings, isTrue);

    await _open(t, result);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Got it'), findsOneWidget); // non-blocking dismissal
  });

  testWidgets('OK state shows no dialog (nothing to nag about)', (t) async {
    final result = await ReliabilityPreflightService(
      FakeReliabilityProbe(), // all good, non-aggressive
    ).check();
    expect(result.isOk, isTrue);

    await _open(t, result);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
