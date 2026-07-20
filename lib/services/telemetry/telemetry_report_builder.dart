// lib/services/telemetry/telemetry_report_builder.dart
//
// Assembles a privacy-safe diagnostics blob for the user-initiated "Report a
// problem" flow. It contains the app version, COARSE device info (model / OEM /
// Android version — no identifiers), and recent telemetry events — which are
// PII- and coordinate-FREE by construction (see telemetry_service.dart: the
// typed funnels never accept a lat/lng, and error strings + stacks are scrubbed
// of home paths and truncated).
//
// The user always PREVIEWS the exact text before sending, and egress is strictly
// user-initiated (the OS share sheet / their email app) — nothing is ever
// uploaded silently. This deliberately does NOT touch the network.

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'telemetry_service.dart';

class TelemetryReportBuilder {
  const TelemetryReportBuilder._();

  /// Build the full diagnostics text. [userNote] is the user's own description;
  /// [crashedLastSession] adds a one-line marker when reporting after a crash.
  static Future<String> build({
    String userNote = '',
    bool crashedLastSession = false,
    int maxEvents = 120,
  }) async {
    final sb = StringBuffer();
    sb.writeln('GeoWake — problem report');
    sb.writeln('=========================');

    final note = userNote.trim();
    if (note.isNotEmpty) {
      sb
        ..writeln('What happened:')
        ..writeln(note)
        ..writeln();
    }
    if (crashedLastSession) {
      sb.writeln('⚠ The app ran into an unexpected error last session.');
    }

    sb.write(await _environmentBlock());

    sb.writeln('Recent events (oldest → newest, PII-free):');
    final events = TelemetryService.instance.memorySink?.events ?? const [];
    if (events.isEmpty) {
      sb.writeln('(no telemetry captured this session)');
    } else {
      final start = events.length > maxEvents ? events.length - maxEvents : 0;
      for (var i = start; i < events.length; i++) {
        sb.writeln(events[i].toJsonLine());
      }
    }
    return sb.toString();
  }

  static Future<String> _environmentBlock() async {
    final sb = StringBuffer();
    try {
      final info = await PackageInfo.fromPlatform();
      sb.writeln('App: ${info.appName} ${info.version}+${info.buildNumber}');
    } catch (_) {
      sb.writeln('App: (version unavailable)');
    }
    try {
      final a = await DeviceInfoPlugin().androidInfo;
      sb.writeln(
        'Device: ${a.manufacturer} ${a.model} · Android '
        '${a.version.release} (SDK ${a.version.sdkInt})',
      );
    } catch (_) {/* non-Android or unavailable — omit */}
    sb.writeln();
    return sb.toString();
  }
}
