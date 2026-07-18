// lib/services/reliability/reliability_preflight_runner.dart
//
// Thin facade so the arm flow can run the HANDOFF §1 P1.3 pre-trip reliability
// preflight in one line, plus a warning dialog. The decision LOGIC is the
// unit-tested ReliabilityPreflightService; this only wires the real probe and
// the UI. Everything here is fail-open — a preflight failure must never block
// the user from arming their alarm.

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'reliability_preflight_service.dart';
import 'reliability_probe_impl.dart';

class ReliabilityPreflightRunner {
  /// Run the preflight against the real device state. Returns an OK result on
  /// any error so callers never have to guard.
  static Future<PreflightResult> run() async {
    const okResult = PreflightResult(level: PreflightLevel.ok, issues: []);
    try {
      final service =
          ReliabilityPreflightService(const PlatformReliabilityProbe());
      // Bound the whole check: a misbehaving permission plugin can HANG a
      // platform-channel call (not throw), which a try/catch can't catch. A
      // hanging preflight must NEVER block the arm flow — time out to "ok" so
      // the user can always proceed (reliability is never gated).
      return await service.check().timeout(
            const Duration(seconds: 4),
            onTimeout: () => okResult,
          );
    } catch (_) {
      return okResult;
    }
  }
}

/// Show the preflight result and return whether arming should PROCEED.
///
/// GAP #4 (BLOCK, fixed): a `block`-severity verdict (today: notifications
/// disabled → the wake can physically never appear) now HONESTLY REFUSES to arm
/// instead of offering a dismissible "Proceed anyway". This is not paywalling or
/// gating the core alarm — reliability is never sold — it is refusing to make a
/// promise the OS won't let us keep. `warn`-severity issues still proceed (the
/// user is advised, not blocked). Returns:
///   • true  → proceed to arm (ok, or warn-level advisory acknowledged)
///   • false → do NOT arm (a blocking channel issue; guide the user to fix it)
Future<bool> showReliabilityPreflightDialog(
  BuildContext context,
  PreflightResult result,
) async {
  if (result.isOk || result.issues.isEmpty) return true;
  final blocking = result.isBlocked;
  final proceed = await showDialog<bool>(
    context: context,
    // A blocking issue can't be dismissed by tapping away — the choice (Fix or
    // Cancel) must be explicit so we never silently arm a dead channel.
    barrierDismissible: !blocking,
    builder: (ctx) => AlertDialog(
      title: Text(blocking
          ? "Your alarm can't wake you yet"
          : 'Make your alarm more reliable'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (blocking)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'GeoWake will not arm an alarm it cannot deliver. Fix the '
                  'issue below, then tap Start again.',
                ),
              ),
            for (final issue in result.issues) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(child: Text(issue.message)),
                    if (issue.fixAction.isNotEmpty)
                      TextButton(
                        onPressed: () => _applyFix(issue.fixAction),
                        child: const Text('Fix'),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: blocking
          ? [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Got it'),
              ),
            ],
    ),
  );
  // Dismissed (back button / barrier): proceed only if the issue is non-blocking.
  return proceed ?? !blocking;
}

/// Deep-link to the right settings screen for a fix action. Best-effort; all
/// unknown actions fall back to the app's own settings page.
Future<void> _applyFix(String fixAction) async {
  try {
    switch (fixAction) {
      case PreflightFixAction.openExactAlarmSettings:
      case PreflightFixAction.openBatteryOptimizationSettings:
      case PreflightFixAction.openNotificationSettings:
      case PreflightFixAction.openLocationSettings:
      default:
        await openAppSettings();
    }
  } catch (_) {/* best effort */}
}
