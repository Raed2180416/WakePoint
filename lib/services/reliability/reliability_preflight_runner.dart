// lib/services/reliability/reliability_preflight_runner.dart
//
// Thin facade so the arm flow can run the HANDOFF §1 P1.3 pre-trip reliability
// preflight in one line, plus a warning dialog. The decision LOGIC is the
// unit-tested ReliabilityPreflightService; this only wires the real probe and
// the UI. Everything here is fail-open — a preflight failure must never block
// the user from arming their alarm.

import 'dart:io' show Platform;

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../oem_autostart_service.dart';
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
                        onPressed: () => applyReliabilityFix(issue.fixAction),
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

/// Opens the OS settings screen that resolves a given [PreflightFixAction].
/// Split behind an interface so the routing (which action -> which screen) is
/// unit-testable with a spy, without touching a real platform channel.
abstract class PreflightFixLauncher {
  const PreflightFixLauncher();
  Future<void> openNotificationSettings();
  Future<void> openExactAlarmSettings();
  Future<void> openBatteryOptimizationSettings();
  Future<void> openLocationSettings();
  Future<void> openDndAccessSettings();
  Future<void> openFullScreenIntentSettings();

  /// Fallback for an unrecognised action: the app's own settings page.
  Future<void> openAppSettingsFallback();
}

/// #19: route EACH fix action to its real deep-link. There is deliberately no
/// fall-through collapsing the known actions to the app-settings page anymore —
/// only a genuinely unknown action reaches
/// [PreflightFixLauncher.openAppSettingsFallback].
Future<void> applyReliabilityFix(
  String fixAction, {
  PreflightFixLauncher launcher = const PlatformPreflightFixLauncher(),
}) async {
  try {
    switch (fixAction) {
      case PreflightFixAction.openNotificationSettings:
        await launcher.openNotificationSettings();
        break;
      case PreflightFixAction.openExactAlarmSettings:
        await launcher.openExactAlarmSettings();
        break;
      case PreflightFixAction.openBatteryOptimizationSettings:
        await launcher.openBatteryOptimizationSettings();
        break;
      case PreflightFixAction.openLocationSettings:
        await launcher.openLocationSettings();
        break;
      case PreflightFixAction.openDndAccessSettings:
        await launcher.openDndAccessSettings();
        break;
      case PreflightFixAction.openFullScreenIntentSettings:
        await launcher.openFullScreenIntentSettings();
        break;
      default:
        await launcher.openAppSettingsFallback();
    }
  } catch (_) {/* best effort — opening a settings screen must never throw up */}
}

/// Real device launcher: OEM autostart deep-links for the battery/allowlist
/// screens (the plain battery page does not cover MIUI/ColorOS/… allowlists),
/// the framework Settings intents for DND + full-screen-intent, and the
/// app_settings screens for the OS-standard ones. Every method is best-effort.
class PlatformPreflightFixLauncher extends PreflightFixLauncher {
  const PlatformPreflightFixLauncher();

  @override
  Future<void> openNotificationSettings() =>
      AppSettings.openAppSettings(type: AppSettingsType.notification);

  @override
  Future<void> openExactAlarmSettings() =>
      AppSettings.openAppSettings(type: AppSettingsType.alarm);

  @override
  Future<void> openBatteryOptimizationSettings() async {
    await OemAutostartService.openAutoStartSettings();
  }

  @override
  Future<void> openLocationSettings() =>
      AppSettings.openAppSettings(type: AppSettingsType.location);

  @override
  Future<void> openDndAccessSettings() =>
      _launchIntent('android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS');

  @override
  Future<void> openFullScreenIntentSettings() async {
    if (!Platform.isAndroid) return;
    final pkg = (await PackageInfo.fromPlatform()).packageName;
    await _launchIntent(
      'android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT',
      data: 'package:$pkg',
    );
  }

  @override
  Future<void> openAppSettingsFallback() => openAppSettings();

  Future<void> _launchIntent(String action, {String? data}) async {
    if (!Platform.isAndroid) return;
    try {
      final intent = AndroidIntent(
        action: action,
        data: data,
        flags: const <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await intent.launch();
    } catch (_) {
      await openAppSettings();
    }
  }
}
