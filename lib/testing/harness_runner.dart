// lib/testing/harness_runner.dart
//
// GeoWake charter §7.3 — HEADLESS SCENARIO HARNESS.
//
// Maps a JSON scenario spec → [EkfTestController] → JSON metrics, so hundreds of
// never-late / EKF scenarios can be swept from the CLI and diffed against a
// golden baseline. Nothing in this file changes production never-late behaviour:
// it only *drives* the existing replay controller and *reads back* the results
// the controller already computes (the reachability cone fire, the EKF alarm
// fire, and the EKF ground-truth drift metrics).
//
// USAGE
//   dart run lib/testing/harness_runner.dart scenario.json          # one scenario
//   dart run lib/testing/harness_runner.dart sweep.json             # {"scenarios":[...]}
//   dart run lib/testing/harness_runner.dart scenario.json -o out.json
//
// The JSON is either a single spec object, a bare JSON array of specs, or an
// object with a top-level "scenarios" array. Output is a JSON object (single) or
// array (sweep) written to stdout (or -o <file>).
//
// UNIT-TESTABLE CORE
//   [runScenario] is the pure spec→metrics function (deterministic: the replay
//   engine uses a seeded RNG + fixed-step deterministic playback). It is `async`
//   only because the underlying replay engine is timer-driven — there is no
//   hidden global state, so a `flutter test` can call it directly with an
//   in-memory polyline spec and assert on the returned map.
//
// SPEC SCHEMA (all keys optional unless noted)
//   {
//     "id":            "human label for this scenario",
//     "route":         "<named-route>"  |  [[lat,lng], ...]  |  [{"lat":..,"lng":..}, ...],
//     "warpFactor":    100.0,                     // replay speed-up (0.1..200)
//     "gpsDropout":    { "mode": "tunnelSimulation", "windows": [[startS,endS], ...] },
//     "vLine":         28.0,                       // informational (see note below)
//     "vehicleType":   "HEAVY_RAIL",              // informational (see note below)
//     "alarm":         { "mode": "stops", "value": 2 },
//     "reach":         { "dwellMinSeconds": 20, "dynamicLeversEnabled": false,
//                        "curveTrusted": false, "hardTMaxSeconds": null },
//     "tolerances":    { "requireNeverLate": true, "requireFired": true,
//                        "maxEarlySeconds": 600, "maxEarlyMeters": 3000,
//                        "maxEkfDriftMeters": 500 }
//   }
//
// NAMED ROUTES map to [TestRouteId] (accepts either the enum name
// "majesticToNallurHalli" or the asset id "majestic_to_nallur_halli"). Named
// routes load their geometry from bundled assets and therefore require a Flutter
// asset binding (a `flutter test` context or an app runtime). A polyline route
// needs no assets and runs under a plain `dart run`.
//
// NOTE ON vLine / vehicleType: [EkfTestController] owns its own reachability
// tracker and does not currently expose a hook to override V_LINE per run, so
// these fields are parsed, validated, and echoed into the output for traceability
// but are NOT injected into the controller's cone (doing so would require editing
// the controller, which this build step must not touch). They become live the
// moment the controller grows a setter.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/ekf/ekf_test_controller.dart';
import 'package:geowake2/core/ekf/imu_replay_engine_v2.dart';
import 'package:geowake2/core/reachability/reachability.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PUBLIC ENTRY POINTS
// ─────────────────────────────────────────────────────────────────────────────

/// CLI entry point: `dart run lib/testing/harness_runner.dart <spec.json> [-o out.json]`.
Future<void> main(List<String> args) async {
  final positional = <String>[];
  String? outPath;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '-o' || a == '--out') {
      if (i + 1 >= args.length) {
        stderr.writeln('error: $a requires a file path argument');
        exitCode = 64; // EX_USAGE
        return;
      }
      outPath = args[++i];
    } else if (a == '-h' || a == '--help') {
      stdout.writeln(_usage);
      return;
    } else {
      positional.add(a);
    }
  }

  if (positional.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }

  final specFile = File(positional.first);
  if (!specFile.existsSync()) {
    stderr.writeln('error: scenario file not found: ${positional.first}');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  Object? decoded;
  try {
    decoded = jsonDecode(await specFile.readAsString());
  } catch (e) {
    stderr.writeln('error: could not parse JSON in ${positional.first}: $e');
    exitCode = 65; // EX_DATAERR
    return;
  }

  final specs = _extractSpecs(decoded);
  if (specs.isEmpty) {
    stderr.writeln('error: no scenario spec(s) found in ${positional.first}');
    exitCode = 65;
    return;
  }

  final Object output;
  if (specs.length == 1 && !_isSweep(decoded)) {
    output = await runScenario(specs.single);
  } else {
    output = await sweep(specs);
  }

  final rendered = const JsonEncoder.withIndent('  ').convert(output);
  if (outPath != null) {
    await File(outPath).writeAsString('$rendered\n');
    stderr.writeln('wrote ${specs.length} result(s) to $outPath');
  } else {
    stdout.writeln(rendered);
  }

  // Non-zero exit if any scenario failed its tolerances, so CI can gate on it.
  final results = output is List ? output : <Object?>[output];
  final anyFailed = results.any((r) =>
      r is Map && (r['ok'] != true || r['withinTolerances'] == false));
  if (anyFailed) exitCode = 1;
}

/// Run a list of scenario specs and return a JSON-ready list of metric maps.
Future<List<Map<String, dynamic>>> sweep(List<Map<String, dynamic>> specs) async {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < specs.length; i++) {
    final result = await runScenario(specs[i]);
    result['index'] = i;
    out.add(result);
  }
  return out;
}

/// Pure spec → metrics. Drives an [EkfTestController] through one replay and
/// returns a JSON-serialisable map of the never-late reachability fire, the EKF
/// alarm fire, and the EKF ground-truth drift, plus a tolerance verdict.
///
/// Never throws for expected failure modes (missing polyline loader, asset load
/// failure, empty route): those come back as `{ "ok": false, "error": ... }` so
/// a sweep continues. Deterministic given the same spec.
Future<Map<String, dynamic>> runScenario(Map<String, dynamic> spec) async {
  final id = _asString(spec['id']) ?? _asString(spec['name']);
  final started = DateTime.now();

  final controller = EkfTestController();
  controller.logVerbosity = 0; // headless: no per-tick console spam
  controller.injectGps = false; // no legacy TrackingService wiring needed
  controller.injectImu = false;

  try {
    // ── Reachability config (must be set BEFORE the route loads: the controller
    //    seeds the cone during load) ──────────────────────────────────────────
    controller.reachConfig = _parseReachConfig(spec['reach']);

    final alarm = _asMap(spec['alarm']);
    final alarmMode = _asString(alarm?['mode'])?.toLowerCase();
    final alarmValue = _asNum(alarm?['value']);
    if (alarmMode == 'stops' && alarmValue != null) {
      controller.reachWakeStopsBeforeDestination =
          alarmValue.round().clamp(0, 1 << 20).toInt();
    }

    // ── Playback tuning ────────────────────────────────────────────────────
    final warpFactor = _asDouble(spec['warpFactor']) ?? 100.0;
    controller.warpFactor = warpFactor;

    final dropout = _asMap(spec['gpsDropout']);
    final dropoutModeStr =
        _asString(dropout?['mode']) ?? _asString(spec['gpsDropoutMode']);
    final gpsMode = _parseGpsDropoutMode(dropoutModeStr);
    controller.gpsDropoutMode = gpsMode;

    final windows = _parseWindows(dropout?['windows']);
    final speedMps = _asDouble(spec['speedMps']) ?? 12.0;
    final stops = _parsePolyline(_asList(spec['stops']) ?? const []);

    // ── Load the route (polyline OR named metro route) ──────────────────────
    final loadInfo = await _loadRoute(
      controller,
      spec['route'],
      blackoutWindows:
          windows.map((w) => GpsBlackoutWindow(w[0], w[1])).toList(),
      speedMps: speedMps,
      stops: stops,
    );
    if (loadInfo.error != null) {
      return _errorResult(spec, id, loadInfo.error!, started);
    }

    final route = controller.route;
    if (route == null || route.fullPolyline.isEmpty) {
      return _errorResult(
          spec, id, 'route loaded but has no geometry', started);
    }

    // Re-apply playback config post-load (a polyline loader may build a fresh
    // engine); the setters forward straight to the constructed engine.
    controller.warpFactor = warpFactor;
    controller.gpsDropoutMode = gpsMode;

    // ── Drive to completion ─────────────────────────────────────────────────
    final done = Completer<void>();
    controller.onFinished = () {
      if (!done.isCompleted) done.complete();
    };

    final routeDurationSeconds = route.totalDurationSeconds;
    // Deterministic replay advances 0.01·warp sim-seconds per 10 ms real tick,
    // so real wall time ≈ routeDuration / warp. Give it 3× headroom + a floor.
    final expectedRealSeconds =
        (warpFactor > 0 ? routeDurationSeconds / warpFactor : routeDurationSeconds);
    final timeoutSeconds =
        (expectedRealSeconds * 3 + 15).ceil().clamp(30, 600).toInt();

    var timedOut = false;
    controller.play();
    await done.future.timeout(
      Duration(seconds: timeoutSeconds),
      onTimeout: () {
        timedOut = true;
        controller.pause();
      },
    );

    // ── Collect metrics ─────────────────────────────────────────────────────
    final result = _buildMetrics(
      spec: spec,
      id: id,
      controller: controller,
      route: route,
      gpsMode: gpsMode,
      warpFactor: warpFactor,
      windows: windows,
      loadInfo: loadInfo,
      timedOut: timedOut,
      startedAt: started,
    );
    return result;
  } catch (e, st) {
    return _errorResult(spec, id, 'unhandled: $e', started, stack: '$st');
  } finally {
    controller.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// METRIC ASSEMBLY
// ─────────────────────────────────────────────────────────────────────────────

Map<String, dynamic> _buildMetrics({
  required Map<String, dynamic> spec,
  required String? id,
  required EkfTestController controller,
  required TestRoute route,
  required GpsDropoutMode gpsMode,
  required double warpFactor,
  required List<List<double>> windows,
  required _LoadInfo loadInfo,
  required bool timedOut,
  required DateTime startedAt,
}) {
  final reach = controller.reachResult;
  final trueArrival = controller.reachTrueTargetArrivalSeconds;
  final alarm = controller.alarmResult;

  final reachFired = reach != null;

  // Never-late lead: seconds between the cone firing and ground-truth arrival at
  // the wake target. Positive ⇒ fired before the train got there (never-late).
  double? leadSeconds;
  double? leadSecondsVsRouteEnd;
  if (reach != null) {
    leadSecondsVsRouteEnd = _finiteOrNull(reach.leadSeconds);
    if (trueArrival != null && trueArrival.isFinite) {
      leadSeconds = trueArrival - reach.fireElapsedSeconds;
    } else {
      // Ground truth never reached the target within the run (fired before the
      // route even got there): treat the full remaining route as the lead.
      leadSeconds = leadSecondsVsRouteEnd;
    }
  }

  // neverLate: the cone MUST fire, and MUST fire at/before ground-truth arrival.
  // A run that never fired is a *worse* failure (never-fire), flagged separately.
  const eps = 1e-6;
  final bool neverLate;
  if (!reachFired) {
    neverLate = false;
  } else if (trueArrival != null && trueArrival.isFinite) {
    neverLate = reach.fireElapsedSeconds <= trueArrival + eps;
  } else {
    neverLate = true; // fired before truth reached the target
  }

  // "stopsEarly": how far ahead of reality the cone fired — the safe early margin
  // we tighten. Reported in both meters (sMax − trueProgress) and seconds.
  final earlyMeters = reach != null ? _finiteOrNull(reach.earlyMeters) : null;
  final earlySeconds = leadSeconds;

  final metrics = <String, dynamic>{
    'ok': true,
    'error': null,
    'id': id,
    if (timedOut) 'timedOut': true,

    // ── Run summary ─────────────────────────────────────────────────────────
    'ranSeconds': _round(controller.elapsedSeconds, 1),
    'finished': controller.isFinished,
    'routeMeters': _round(route.totalMeters, 0),
    'routeDurationSeconds': _round(route.totalDurationSeconds, 1),
    'stationCount': route.allStations.length,
    'routeSource': loadInfo.source,

    // ── Never-late reachability cone (the load-bearing safety path) ──────────
    'fired': reachFired,
    'reachFired': reachFired,
    'neverFired': !reachFired,
    'neverLate': neverLate,
    'fireTimeSeconds': reach != null ? _round(reach.fireElapsedSeconds, 1) : null,
    'reachTrueTargetArrivalSeconds':
        (trueArrival != null && trueArrival.isFinite)
            ? _round(trueArrival, 1)
            : null,
    'reachTargetMeters': reach != null ? _round(reach.targetMeters, 0) : null,
    'sMaxAtFireMeters':
        reach != null ? _roundOrInf(reach.sMaxMeters, 0) : null,
    'trueProgressAtFireMeters':
        reach != null ? _round(reach.trueProgressMeters, 0) : null,
    'leadSeconds': leadSeconds == null ? null : _round(leadSeconds, 1),
    'leadSecondsVsRouteEnd':
        leadSecondsVsRouteEnd == null ? null : _round(leadSecondsVsRouteEnd, 1),
    'stopsEarly': earlyMeters == null ? null : _round(earlyMeters, 0),
    'earlyMeters': earlyMeters == null ? null : _round(earlyMeters, 0),
    'earlySeconds': earlySeconds == null ? null : _round(earlySeconds, 1),

    // ── EKF point-estimate alarm (real AlarmEvaluator over EKF progress) ─────
    'ekfAlarmFired': controller.alarmFired,
    'ekfAlarmEventType': alarm?.eventType,
    'ekfAlarmFireTimeSeconds':
        alarm != null ? _round(alarm.fireElapsedSeconds, 1) : null,
    'ekfAlarmLeadSeconds': alarm != null ? _round(alarm.leadSeconds, 1) : null,
    'ekfAlarmLeadErrorMeters':
        alarm != null ? _round(alarm.leadErrorMeters, 1) : null,

    // ── EKF ground-truth accuracy (dead-reckoning quality) ──────────────────
    'ekfDriftMeters': _round(controller.ekfMaxDrift, 1),
    'ekfRmseMeters': _round(controller.ekfRmse, 1),
    'ekfMaxBlackoutErrorMeters': _round(controller.ekfMaxBlackoutError, 1),
    'ekfCurrentErrorMeters': _round(controller.ekfCurrentError, 1),

    // ── Config echo (traceability + diff stability) ─────────────────────────
    'config': {
      'warpFactor': warpFactor,
      'gpsDropoutMode': gpsMode.name,
      'gpsDropoutWindows': windows.map((w) => [w[0], w[1]]).toList(),
      // Polyline routes apply windows exactly (per-window suppression); named
      // routes have no such hook, so their windows only pick the dropout mode.
      'gpsDropoutWindowsApplied': loadInfo.windowsApplied,
      'reachWakeStopsBeforeDestination':
          controller.reachWakeStopsBeforeDestination,
      'reachConfig': _reachConfigJson(controller.reachConfig),
      'vLine': _asDouble(spec['vLine']),
      'vehicleType': _asString(spec['vehicleType']),
      'vLineApplied': false, // controller owns its V_LINE; no override hook yet
    },

    'wallClockMillis': DateTime.now().difference(startedAt).inMilliseconds,
  };

  // ── Tolerance verdict ─────────────────────────────────────────────────────
  final verdict = _evaluateTolerances(
    tolerances: _asMap(spec['tolerances']),
    reachFired: reachFired,
    neverLate: neverLate,
    earlyMeters: earlyMeters,
    earlySeconds: earlySeconds,
    ekfDriftMeters: controller.ekfMaxDrift,
    timedOut: timedOut,
  );
  metrics['withinTolerances'] = verdict.isEmpty;
  metrics['toleranceViolations'] = verdict;

  return metrics;
}

/// Returns the list of tolerance-violation strings (empty ⇒ all satisfied).
/// Defaults are conservative: even with no explicit tolerances a run must fire
/// and must be never-late, because a silent never-fire is the cardinal sin.
List<String> _evaluateTolerances({
  required Map<String, dynamic>? tolerances,
  required bool reachFired,
  required bool neverLate,
  required double? earlyMeters,
  required double? earlySeconds,
  required double ekfDriftMeters,
  required bool timedOut,
}) {
  final t = tolerances ?? const <String, dynamic>{};
  final violations = <String>[];

  final requireFired = _asBool(t['requireFired']) ?? true;
  final requireNeverLate = _asBool(t['requireNeverLate']) ?? true;

  if (timedOut) {
    violations.add('run timed out before natural completion');
  }
  if (requireFired && !reachFired) {
    violations.add('reachability cone never fired (never-fire)');
  }
  if (requireNeverLate && reachFired && !neverLate) {
    violations.add('LATE FIRE: cone fired after ground-truth target arrival');
  }

  final maxEarlySeconds = _asDouble(t['maxEarlySeconds']);
  if (maxEarlySeconds != null &&
      earlySeconds != null &&
      earlySeconds > maxEarlySeconds) {
    violations.add(
        'fired ${earlySeconds.toStringAsFixed(0)}s early > maxEarlySeconds $maxEarlySeconds');
  }

  final maxEarlyMeters = _asDouble(t['maxEarlyMeters']);
  if (maxEarlyMeters != null &&
      earlyMeters != null &&
      earlyMeters > maxEarlyMeters) {
    violations.add(
        'cone ${earlyMeters.toStringAsFixed(0)}m ahead of truth > maxEarlyMeters $maxEarlyMeters');
  }

  final maxEkfDrift = _asDouble(t['maxEkfDriftMeters']);
  if (maxEkfDrift != null && ekfDriftMeters.isFinite && ekfDriftMeters > maxEkfDrift) {
    violations.add(
        'EKF drift ${ekfDriftMeters.toStringAsFixed(0)}m > maxEkfDriftMeters $maxEkfDrift');
  }

  return violations;
}

// ─────────────────────────────────────────────────────────────────────────────
// ROUTE LOADING
// ─────────────────────────────────────────────────────────────────────────────

class _LoadInfo {
  final String source; // 'polyline' | 'namedRoute' | 'none'
  final String? error;
  final bool windowsApplied;
  const _LoadInfo({
    required this.source,
    this.error,
    this.windowsApplied = false,
  });
}

/// Load the scenario route into [controller]. A JSON list ⇒ a polyline route
/// driven through [EkfTestController.loadRouteFromPolyline] (which models
/// [blackoutWindows] as real per-window GPS suppression and [stops] as ZUPT
/// dwell points). A JSON string ⇒ a named [TestRouteId] loaded from bundled
/// assets. Named routes have no per-window blackout hook, so their [windows]
/// only select the [GpsDropoutMode]; polyline routes apply them exactly.
Future<_LoadInfo> _loadRoute(
  EkfTestController controller,
  Object? routeSpec, {
  required List<GpsBlackoutWindow> blackoutWindows,
  required double speedMps,
  required List<LatLng> stops,
}) async {
  if (routeSpec is List) {
    final points = _parsePolyline(routeSpec);
    if (points.length < 2) {
      return const _LoadInfo(
        source: 'polyline',
        error: 'polyline route needs >= 2 valid [lat,lng] points',
      );
    }
    try {
      await controller.loadRouteFromPolyline(
        points,
        speedMps: speedMps,
        blackoutWindows: blackoutWindows,
        stops: stops,
      );
      return _LoadInfo(
        source: 'polyline',
        windowsApplied: blackoutWindows.isNotEmpty,
      );
    } catch (e) {
      return _LoadInfo(
          source: 'polyline', error: 'loadRouteFromPolyline threw: $e');
    }
  }

  if (routeSpec is String) {
    final routeId = _parseRouteId(routeSpec);
    if (routeId == null) {
      return _LoadInfo(
        source: 'namedRoute',
        error: 'unknown named route "$routeSpec" (expected one of: '
            '${TestRouteId.values.map((r) => r.name).join(", ")})',
      );
    }
    try {
      await controller.loadRoute(routeId);
      return const _LoadInfo(source: 'namedRoute');
    } catch (e) {
      // Named routes read bundled assets → need a Flutter asset binding.
      return _LoadInfo(
        source: 'namedRoute',
        error: 'named-route asset load failed ($e). Named routes require a '
            'Flutter asset binding (flutter test / app runtime); use a polyline '
            'route for a plain `dart run`.',
      );
    }
  }

  return const _LoadInfo(
    source: 'none',
    error: 'spec.route must be a polyline (JSON array) or a named-route string',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// SPEC PARSING HELPERS
// ─────────────────────────────────────────────────────────────────────────────

ReachabilityConfig _parseReachConfig(Object? raw) {
  final m = _asMap(raw);
  if (m == null) return const ReachabilityConfig();
  return ReachabilityConfig(
    dwellMinSeconds: _asDouble(m['dwellMinSeconds']) ?? 0.0,
    hardTMaxSeconds: _asDouble(m['hardTMaxSeconds']),
    aMaxMps2: _asDouble(m['aMaxMps2']) ?? 2.5,
    dMaxMps2: _asDouble(m['dMaxMps2']) ?? 3.5,
    aLatEffMps2: _asDouble(m['aLatEffMps2']) ?? 7.0,
    dynamicLeversEnabled: _asBool(m['dynamicLeversEnabled']) ?? false,
    curveTrusted: _asBool(m['curveTrusted']) ?? false,
    curveSigmaPosMeters: _asDouble(m['curveSigmaPosMeters']) ?? 5.0,
    curveChordMeters: _asDouble(m['curveChordMeters']) ?? 160.0,
    curveNoiseK: _asDouble(m['curveNoiseK']) ?? 3.0,
  );
}

Map<String, dynamic> _reachConfigJson(ReachabilityConfig c) => {
      'dwellMinSeconds': c.dwellMinSeconds,
      'hardTMaxSeconds': c.hardTMaxSeconds,
      'dynamicLeversEnabled': c.dynamicLeversEnabled,
      'curveTrusted': c.curveTrusted,
      'aMaxMps2': c.aMaxMps2,
      'dMaxMps2': c.dMaxMps2,
      'aLatEffMps2': c.aLatEffMps2,
    };

/// Map a string to a [GpsDropoutMode] (accepts the enum name, case-insensitive,
/// and a few friendly aliases). Defaults to [GpsDropoutMode.normal].
GpsDropoutMode _parseGpsDropoutMode(String? s) {
  if (s == null) return GpsDropoutMode.normal;
  final key = s.trim().toLowerCase().replaceAll(RegExp(r'[_\s-]'), '');
  for (final m in GpsDropoutMode.values) {
    if (m.name.toLowerCase() == key) return m;
  }
  switch (key) {
    case 'tunnel':
    case 'underground':
      return GpsDropoutMode.tunnelSimulation;
    case 'dropout':
    case 'blackout':
    case 'complete':
    case 'none':
      return GpsDropoutMode.completeDropout;
    case 'canyon':
    case 'urban':
      return GpsDropoutMode.urbanCanyon;
    case 'degraded':
    case 'accuracy':
      return GpsDropoutMode.accuracyDegraded;
    case 'intermittent':
    case 'random':
      return GpsDropoutMode.intermittent;
    default:
      return GpsDropoutMode.normal;
  }
}

/// Map a string to a [TestRouteId]. Accepts the enum name
/// ("majesticToNallurHalli") or the underlying asset id
/// ("majestic_to_nallur_halli").
TestRouteId? _parseRouteId(String s) {
  final norm = s.trim().toLowerCase().replaceAll(RegExp(r'[_\s-]'), '');
  for (final r in TestRouteId.values) {
    if (r.name.toLowerCase() == norm) return r;
  }
  return null;
}

/// Parse a JSON polyline: a list of `[lat,lng]` pairs or `{"lat":..,"lng":..}`
/// objects. Silently skips malformed / out-of-range entries.
List<LatLng> _parsePolyline(List<dynamic> raw) {
  final points = <LatLng>[];
  for (final e in raw) {
    double? lat;
    double? lng;
    if (e is List && e.length >= 2) {
      lat = _asDouble(e[0]);
      lng = _asDouble(e[1]);
    } else if (e is Map) {
      lat = _asDouble(e['lat'] ?? e['latitude']);
      lng = _asDouble(e['lng'] ?? e['lon'] ?? e['longitude']);
    }
    if (lat == null || lng == null) continue;
    if (lat.abs() > 90 || lng.abs() > 180) continue;
    points.add(LatLng(lat, lng));
  }
  return points;
}

/// Parse GPS-dropout windows as a list of `[startSeconds, endSeconds]` pairs.
List<List<double>> _parseWindows(Object? raw) {
  final out = <List<double>>[];
  if (raw is! List) return out;
  for (final w in raw) {
    if (w is List && w.length >= 2) {
      final a = _asDouble(w[0]);
      final b = _asDouble(w[1]);
      if (a != null && b != null && b >= a) out.add([a, b]);
    } else if (w is Map) {
      final a = _asDouble(w['start'] ?? w['from']);
      final b = _asDouble(w['end'] ?? w['to']);
      if (a != null && b != null && b >= a) out.add([a, b]);
    }
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI / STRUCTURE HELPERS
// ─────────────────────────────────────────────────────────────────────────────

const String _usage = '''
GeoWake scenario harness (charter §7.3)

  dart run lib/testing/harness_runner.dart <spec.json> [-o out.json]

<spec.json> is one of:
  - a single scenario object            -> emits one metrics object
  - a JSON array of scenario objects    -> emits a metrics array (sweep)
  - { "scenarios": [ ... ] }            -> emits a metrics array (sweep)

Exit code 1 if any scenario fails its tolerances (or errors); 0 otherwise.
See the file header for the full spec schema.''';

bool _isSweep(Object? decoded) =>
    decoded is List || (decoded is Map && decoded['scenarios'] is List);

List<Map<String, dynamic>> _extractSpecs(Object? decoded) {
  Iterable<Object?> raw;
  if (decoded is List) {
    raw = decoded;
  } else if (decoded is Map && decoded['scenarios'] is List) {
    raw = decoded['scenarios'] as List;
  } else if (decoded is Map) {
    raw = [decoded];
  } else {
    return const [];
  }
  return raw
      .whereType<Map>()
      .map((m) => m.map((k, v) => MapEntry('$k', v)))
      .toList();
}

Map<String, dynamic> _errorResult(
  Map<String, dynamic> spec,
  String? id,
  String message,
  DateTime startedAt, {
  String? stack,
}) {
  return <String, dynamic>{
    'ok': false,
    'error': message,
    if (stack != null) 'stack': stack,
    'id': id,
    'fired': false,
    'reachFired': false,
    'neverFired': true,
    'neverLate': false,
    'withinTolerances': false,
    'toleranceViolations': [message],
    'wallClockMillis': DateTime.now().difference(startedAt).inMilliseconds,
  };
}

// ── Typed JSON accessors (tolerant of int/double/string mixing) ──────────────

Map<String, dynamic>? _asMap(Object? v) {
  if (v is Map) return v.map((k, val) => MapEntry('$k', val));
  return null;
}

String? _asString(Object? v) => v is String ? v : null;

List<dynamic>? _asList(Object? v) => v is List ? v : null;

num? _asNum(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v);
  return null;
}

double? _asDouble(Object? v) {
  final n = _asNum(v);
  return n?.toDouble();
}

bool? _asBool(Object? v) {
  if (v is bool) return v;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true') return true;
    if (s == 'false') return false;
  }
  return null;
}

// ── Numeric rendering (stable, JSON-friendly) ────────────────────────────────

double? _finiteOrNull(double v) => v.isFinite ? v : null;

/// Round to [places] decimals; non-finite ⇒ null (JSON has no NaN/Infinity).
double? _round(double v, int places) {
  if (!v.isFinite) return null;
  final f = math.pow(10, places).toDouble();
  return (v * f).round() / f;
}

/// Like [_round] but renders +/-infinity as the string "inf"/"-inf" (used for
/// the reach bound, which is legitimately +inf under the T_max watchdog).
Object? _roundOrInf(double v, int places) {
  if (v.isFinite) return _round(v, places);
  if (v == double.infinity) return 'inf';
  if (v == double.negativeInfinity) return '-inf';
  return null;
}
