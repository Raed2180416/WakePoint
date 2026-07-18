// lib/services/telemetry/telemetry_session.dart
//
// Fire-and-forget session/device telemetry for the reliability funnel
// (HANDOFF §3): stamp every event with the device·OEM·Android-version breakdown
// and record the arm-time permission states, so aggregated data can answer
// "which phones fail to wake their riders?". PII-free (no coordinates, no ids).
// Fail-open — never throws into, or delays, the arming flow.

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'package:geowake2/services/reliability/reliability_probe_impl.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';

/// Populate device context and emit session-start + alarm-armed events. Call
/// UNAWAITED from the arming flow.
Future<void> recordSessionStart({
  required String alarmMode,
  required double alarmValue,
  String? city,
  String? line,
}) async {
  try {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      TelemetryService.instance.setDeviceContext(
        manufacturer: info.manufacturer,
        model: info.model,
        androidSdkInt: info.version.sdkInt,
        platform: 'android',
      );
    } else if (Platform.isIOS) {
      final info = await DeviceInfoPlugin().iosInfo;
      TelemetryService.instance.setDeviceContext(
        manufacturer: 'Apple',
        model: info.utsname.machine,
        platform: 'ios',
      );
    }
  } catch (_) {/* device context is best-effort */}

  try {
    const probe = PlatformReliabilityProbe();
    // Read all four in parallel so the arm path is never blocked for long.
    final results = await Future.wait<bool>([
      probe.preciseLocation,
      probe.notificationsEnabled,
      probe.exactAlarmAllowed,
      probe.batteryOptExempt,
    ]);
    TelemetryService.instance.sessionStart(
      locationPrecise: results[0],
      notificationsEnabled: results[1],
      exactAlarmAllowed: results[2],
      batteryOptExempt: results[3],
    );
    TelemetryService.instance
        .alarmArmed(mode: alarmMode, value: alarmValue, city: city, line: line);
  } catch (_) {/* telemetry must never break arming */}
}
