// lib/services/reliability/reliability_probe_impl.dart
//
// Concrete ReliabilityProbe backed by the real platform plugins. The preflight
// LOGIC lives in reliability_preflight_service.dart (pure + unit-tested against
// FakeReliabilityProbe); this is the thin device adapter it reads through.
//
// NOTE: behaviour of these plugin calls is device-verifiable only (they return
// real OS permission states). The mapping here is deliberately conservative:
// on any error we return the "not-granted"/safe-to-warn value so the preflight
// errs toward warning the user rather than falsely reporting all-clear.

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakepoint_native/wakepoint_native.dart';

import 'reliability_preflight_service.dart';

class PlatformReliabilityProbe implements ReliabilityProbe {
  const PlatformReliabilityProbe();

  @override
  Future<bool> get exactAlarmAllowed async {
    if (!Platform.isAndroid) return true; // iOS schedules notifications freely
    try {
      // With USE_EXACT_ALARM (declared in the manifest) this is auto-granted on
      // Android 13+; SCHEDULE_EXACT_ALARM may require the user toggle on 14+.
      final s = await Permission.scheduleExactAlarm.status;
      return s.isGranted || s.isLimited || s.isProvisional;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> get batteryOptExempt async {
    if (!Platform.isAndroid) return true;
    try {
      final s = await Permission.ignoreBatteryOptimizations.status;
      return s.isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> get notificationsEnabled async {
    try {
      final s = await Permission.notification.status;
      return s.isGranted || s.isProvisional;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> get preciseLocation async {
    try {
      final acc = await Geolocator.getLocationAccuracy();
      return acc == LocationAccuracyStatus.precise;
    } catch (_) {
      return true; // unknown => don't nag; the accuracy gate still protects us
    }
  }

  @override
  Future<bool> get dndBypassGranted async {
    // isNotificationPolicyAccessGranted(): without it the alarm channel's
    // setBypassDnd(true) silently no-ops. Unknown => assume granted (don't nag).
    if (!Platform.isAndroid) return true;
    return WakepointNative.isNotificationPolicyAccessGranted();
  }

  @override
  Future<bool> get dndActive async {
    // currentInterruptionFilter != ALL. Unknown => false (DND off => nothing to
    // warn about), matching the conservative "don't nag on unknown" stance.
    if (!Platform.isAndroid) return false;
    return WakepointNative.isDndActive();
  }

  @override
  Future<bool> get fullScreenIntentAllowed async {
    // canUseFullScreenIntent() (API 34+). Unknown/older => true.
    return WakepointNative.canUseFullScreenIntent();
  }

  @override
  Future<String> get manufacturer async {
    if (!Platform.isAndroid) return Platform.operatingSystem;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.manufacturer.toLowerCase();
    } catch (_) {
      return '';
    }
  }
}
