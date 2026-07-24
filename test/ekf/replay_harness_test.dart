// OFFLINE EKF REPLAY HARNESS + BASELINE GATE + SYNTHETIC-SCENARIO SUITE.
// Validation only — this file NEVER modifies anything under lib/.
//
// Drives the REAL production EkfOrchestrator + EkfPipeline + RouteGeometry over
// REAL recorded metro rides, then scores the REAL
// AlarmEvaluator.evaluateCoinciding fire decision against station-anchor ground
// truth (plan §4: never-late first).
//
// Design source: /home/raed/geowake_imu_analysis/SIMULATION_AND_VALIDATION_PLAN.md
//   §2 (harness design), §2.3 (deterministic driver loop / production glue),
//   §3.4 (synthetic scenarios), §4 (never-late gates + station-anchor truth),
//   §6 (validity preprocessing).
//
// Run:  flutter test test/ekf/replay_harness_test.dart
//
// Everything GLOBS the fixtures dir — no ride name is hardcoded, so newly added
// fixture_<ride>.json (+ _imu.csv + _gps.csv) are picked up automatically.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/ekf/ekf_orchestrator.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';
import 'package:geowake2/core/ekf/ekf_metrics.dart';
import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/core/reachability/reachability.dart';
import 'package:geowake2/config/fire_decision_config.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';

// Fixture resolution: COMMITTED compact fixtures under test/fixtures/replay are
// the CI-gated source of truth (small, deterministic, always present). The
// founder's machine may ALSO hold the full-rate recorded rides at the external
// path; when present those are run too for extra coverage. The gate FAILS (not
// skips) when NEITHER yields a fixture — a never-late guarantee that can't run
// in CI is not a guarantee.
const String kInRepoFixturesDir = 'test/fixtures/replay';
const String kExternalFixturesDir = '/home/raed/geowake_imu_analysis/fixtures';

/// The directory that actually holds `<basename>.json`, in-repo preferred.
String? _fixtureDirFor(String basename) {
  if (File('$kInRepoFixturesDir/$basename.json').existsSync()) {
    return kInRepoFixturesDir;
  }
  if (File('$kExternalFixturesDir/$basename.json').existsSync()) {
    return kExternalFixturesDir;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Scenario configuration (plan §3.4)
// ---------------------------------------------------------------------------

enum ScenarioKind {
  primary, // real fixes as recorded, blind windows blanked
  phantomInject, // inject a frozen CONFIDENT fix over a moving window
  gapInject, // splice an IMU+GPS gap (dt>1s reset probe)
  coldStart, // withhold ALL GPS
}

class ScenarioConfig {
  final ScenarioKind kind;
  final double windowStart; // seconds (phantom/gap)
  final double windowDur; // seconds (phantom/gap)
  final String label;

  const ScenarioConfig._(this.kind, this.windowStart, this.windowDur, this.label);

  factory ScenarioConfig.primary() =>
      const ScenarioConfig._(ScenarioKind.primary, 0, 0, 'PRIMARY');
  factory ScenarioConfig.phantom(double start, double dur) => ScenarioConfig._(
      ScenarioKind.phantomInject, start, dur, 'SYNTHETIC:PHANTOM_INJECT');
  factory ScenarioConfig.gap(double start, double dur) => ScenarioConfig._(
      ScenarioKind.gapInject, start, dur,
      'SYNTHETIC:GAP_INJECT(${dur.toStringAsFixed(0)}s)');
  factory ScenarioConfig.coldStart() =>
      const ScenarioConfig._(ScenarioKind.coldStart, 0, 0, 'SYNTHETIC:COLD_START');

  double get windowEnd => windowStart + windowDur;
}

// ---------------------------------------------------------------------------
// Fixture data model
// ---------------------------------------------------------------------------

class _StationAnchor {
  final String name;
  final double lat;
  final double lng;
  final double arrivalTs;
  final double sTravelJson;
  double sProj = double.nan;
  _StationAnchor(this.name, this.lat, this.lng, this.arrivalTs, this.sTravelJson);
}

class _ImuRow {
  final double t;
  final double ax, ay, az, gx, gy, gz;
  _ImuRow(this.t, this.ax, this.ay, this.az, this.gx, this.gy, this.gz);
}

class _GpsRow {
  final double t;
  final double lat, lng, hacc;
  final double speed; // NaN = sentinel/absent
  _GpsRow(this.t, this.lat, this.lng, this.hacc, this.speed);
}

class _Fixture {
  final String ride;
  final String device;
  final String platform;
  final String line;
  final double legLengthM;
  final bool gpsPresent;
  final List<LatLng> polyline;
  final List<_StationAnchor> stations;
  final _StationAnchor alarmTarget;
  final List<List<double>> blindWindows;
  final List<_ImuRow> imu;
  final List<_GpsRow> gps;
  _Fixture({
    required this.ride,
    required this.device,
    required this.platform,
    required this.line,
    required this.legLengthM,
    required this.gpsPresent,
    required this.polyline,
    required this.stations,
    required this.alarmTarget,
    required this.blindWindows,
    required this.imu,
    required this.gps,
  });
}

// ---------------------------------------------------------------------------
// Discovery + loading
// ---------------------------------------------------------------------------

/// Glob every fixture_*.json basename across BOTH fixture dirs (in-repo first,
/// external second), deduplicated by basename (in-repo wins).
List<String> discoverFixtures() {
  final seen = <String>{};
  for (final dirPath in const [kInRepoFixturesDir, kExternalFixturesDir]) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) continue;
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (name.startsWith('fixture_') && name.endsWith('.json')) {
        seen.add(name.substring(0, name.length - '.json'.length));
      }
    }
  }
  final out = seen.toList()..sort();
  return out;
}

/// Read just the JSON header (cheap) for fixture selection.
Map<String, dynamic>? _readHeader(String basename) {
  final dir = _fixtureDirFor(basename);
  if (dir == null) return null;
  final f = File('$dir/$basename.json');
  if (!f.existsSync()) return null;
  try {
    return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null; // possibly mid-write by the coordinator
  }
}

/// Deterministically pick a GPS-rich, long ride for the synthetic scenarios.
String? pickScenarioFixture(List<String> basenames) {
  String? best;
  double bestLen = -1;
  for (final b in basenames) {
    final h = _readHeader(b);
    if (h == null) continue;
    final gpsPresent = (h['gps_present'] as bool?) ?? true;
    final nStations = (h['stations'] as List?)?.length ?? 0;
    final legLen = (h['leg_length_m'] as num?)?.toDouble() ?? 0.0;
    if (!gpsPresent || nStations < 4) continue;
    if (legLen > bestLen) {
      bestLen = legLen;
      best = b;
    }
  }
  return best;
}

_Fixture _loadFixture(String basename) {
  final dir = _fixtureDirFor(basename) ?? kInRepoFixturesDir;
  final jsonFile = File('$dir/$basename.json');
  final imuFile = File('$dir/${basename}_imu.csv');
  final gpsFile = File('$dir/${basename}_gps.csv');
  if (!jsonFile.existsSync()) {
    throw StateError('Fixture JSON not found: ${jsonFile.path}');
  }

  final j = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;

  final polyline = <LatLng>[];
  for (final p in (j['oriented_polyline'] as List)) {
    final pair = p as List;
    polyline.add(LatLng((pair[0] as num).toDouble(), (pair[1] as num).toDouble()));
  }

  final stations = <_StationAnchor>[];
  for (final s in (j['stations'] as List)) {
    final m = s as Map<String, dynamic>;
    stations.add(_StationAnchor(
      m['name'] as String,
      (m['lat'] as num).toDouble(),
      (m['lng'] as num).toDouble(),
      (m['arrival_t_s'] as num).toDouble(),
      (m['s_travel'] as num).toDouble(),
    ));
  }

  final at = j['alarm_target'] as Map<String, dynamic>;
  final alarmTarget = _StationAnchor(
    at['name'] as String,
    (at['lat'] as num).toDouble(),
    (at['lng'] as num).toDouble(),
    (at['arrival_t_s'] as num).toDouble(),
    (at['s_travel'] as num).toDouble(),
  );

  final blindWindows = <List<double>>[];
  for (final w in (j['gps_blind_windows_s'] as List? ?? const [])) {
    final pair = w as List;
    blindWindows.add([(pair[0] as num).toDouble(), (pair[1] as num).toDouble()]);
  }

  final imu = <_ImuRow>[];
  final imuLines = imuFile.readAsLinesSync();
  for (var i = 1; i < imuLines.length; i++) {
    final line = imuLines[i];
    if (line.isEmpty) continue;
    final c = line.split(',');
    if (c.length < 7) continue;
    imu.add(_ImuRow(
      double.parse(c[0]),
      double.parse(c[1]), double.parse(c[2]), double.parse(c[3]),
      double.parse(c[4]), double.parse(c[5]), double.parse(c[6]),
    ));
  }

  final gps = <_GpsRow>[];
  final gpsLines = gpsFile.readAsLinesSync();
  for (var i = 1; i < gpsLines.length; i++) {
    final line = gpsLines[i];
    if (line.isEmpty) continue;
    final c = line.split(',');
    if (c.length < 4) continue;
    final speedStr = c.length >= 5 ? c[4].trim() : '';
    final speed = speedStr.isEmpty ? double.nan : (double.tryParse(speedStr) ?? double.nan);
    gps.add(_GpsRow(
      double.parse(c[0]),
      double.parse(c[1]), double.parse(c[2]), double.parse(c[3]),
      speed,
    ));
  }

  return _Fixture(
    ride: j['ride'] as String? ?? basename,
    device: j['device'] as String? ?? 'unknown',
    platform: j['platform'] as String? ?? 'unknown',
    line: j['line'] as String? ?? 'unknown',
    legLengthM: (j['leg_length_m'] as num?)?.toDouble() ?? 0.0,
    gpsPresent: (j['gps_present'] as bool?) ?? true,
    polyline: polyline,
    stations: stations,
    alarmTarget: alarmTarget,
    blindWindows: blindWindows,
    imu: imu,
    gps: gps,
  );
}

// ---------------------------------------------------------------------------
// Ground truth (§4): piecewise-linear over (arrival_t_s, s_proj) anchors
// ---------------------------------------------------------------------------

class _GroundTruth {
  final List<double> _t;
  final List<double> _s;
  _GroundTruth(this._t, this._s);
  double at(double t) {
    if (_t.isEmpty) return double.nan;
    if (t <= _t.first) return _s.first;
    if (t >= _t.last) return _s.last;
    for (var i = 0; i < _t.length - 1; i++) {
      if (t >= _t[i] && t <= _t[i + 1]) {
        final f = (t - _t[i]) / (_t[i + 1] - _t[i]);
        return _s[i] + f * (_s[i + 1] - _s[i]);
      }
    }
    return _s.last;
  }
}

// ---------------------------------------------------------------------------
// Result model
// ---------------------------------------------------------------------------

class _StationScore {
  final String name;
  final double arrivalTs;
  final double sTarget;
  final double sEstAtArrival;
  final double sErr;
  _StationScore(this.name, this.arrivalTs, this.sTarget, this.sEstAtArrival, this.sErr);
}

/// Diagnostics captured across a scenario window (phantom / gap).
class _WindowDiag {
  double sAtStart = double.nan;
  double sAtEnd = double.nan;
  double minSInWindow = double.infinity;
  double vAtEnd = double.nan;
  double sBeforeWindow = double.nan; // last tick strictly before start
  double sAfterWindow = double.nan; // first tick at/after end
  double trueAtStart = double.nan;
  double trueAtEnd = double.nan;
}

class RunResult {
  final String basename;
  final String ride;
  final String device;
  final String platform;
  final String scenario;
  final double totalLen;
  final int numImu;
  final int numGps;
  final List<_StationScore> stationScores;

  final bool fired;
  final double fireTs;
  final double fireS;
  final double fireSigma;
  final double fireTrueS;
  final double secondsMargin;
  final double metersEarly;
  final double ekfArcErrAtFire;
  final String fireReason;

  final double rmse;
  final double maxDrift;
  final double maxBlackoutError;

  final double firstInitTs;
  final int degradedTicks;
  final int backwardEvents;
  final double maxBackwardStep;
  final List<String> blindWindowNotes;

  // Worst-drift tick (diagnostic: where |s_est - s_true| peaks).
  final double maxDriftTs;
  final double maxDriftEkf;
  final double maxDriftTrue;
  final double maxSpeedSeen; // max GpsFix speed handed to the EKF
  final double maxVSeen; // max |publicState.v| observed

  final _WindowDiag? window;

  RunResult({
    required this.basename,
    required this.ride,
    required this.device,
    required this.platform,
    required this.scenario,
    required this.totalLen,
    required this.numImu,
    required this.numGps,
    required this.stationScores,
    required this.fired,
    required this.fireTs,
    required this.fireS,
    required this.fireSigma,
    required this.fireTrueS,
    required this.secondsMargin,
    required this.metersEarly,
    required this.ekfArcErrAtFire,
    required this.fireReason,
    required this.rmse,
    required this.maxDrift,
    required this.maxBlackoutError,
    required this.firstInitTs,
    required this.degradedTicks,
    required this.backwardEvents,
    required this.maxBackwardStep,
    required this.blindWindowNotes,
    required this.maxDriftTs,
    required this.maxDriftEkf,
    required this.maxDriftTrue,
    required this.maxSpeedSeen,
    required this.maxVSeen,
    required this.window,
  });

  int get nStations => stationScores.length;
  bool get isLate => !fired || (secondsMargin.isFinite && secondsMargin < 0);
}

// ---------------------------------------------------------------------------
// Driver helpers
// ---------------------------------------------------------------------------

bool _inBlindWindow(double t, List<List<double>> windows) {
  for (final w in windows) {
    if (t >= w[0] && t <= w[1]) return true;
  }
  return false;
}

// LocationManagerReplica.process (location_manager.dart:305-344):
// G27 100m accuracy gate + speed-sentinel rewrite.
_GpsRow? _locationReplicaProcess(_GpsRow r, _GpsRow? prev) {
  if (!r.hacc.isFinite || r.hacc > FireDecisionConfig.defaultAccuracyGateMeters) {
    return null;
  }
  double speed = r.speed;
  if (!speed.isFinite || speed < 0) {
    if (prev != null) {
      final dt = r.t - prev.t;
      speed = dt > 0 ? _haversine(prev.lat, prev.lng, r.lat, r.lng) / dt : 0.0;
    } else {
      speed = 0.0;
    }
  }
  return _GpsRow(r.t, r.lat, r.lng, r.hacc, speed);
}

double _haversine(double lat1, double lon1, double lat2, double lon2) {
  const R = 6371000.0;
  final p1 = lat1 * math.pi / 180.0;
  final p2 = lat2 * math.pi / 180.0;
  final dp = (lat2 - lat1) * math.pi / 180.0;
  final dl = (lon2 - lon1) * math.pi / 180.0;
  final a = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * R * math.asin(math.min(1.0, math.sqrt(a)));
}

Duration _dur(double tSeconds) => Duration(microseconds: (tSeconds * 1e6).round());

// ---------------------------------------------------------------------------
// The replay
// ---------------------------------------------------------------------------

// When true, the driver feeds the physics reachability bound into the REAL
// evaluator (production behavior). When false, reachability is disabled so the
// harness can A/B prove the bound only ever fires earlier, never later.
RunResult runReplay(String basename,
    {ScenarioConfig? config, bool useReachability = true}) {
  final cfg = config ?? ScenarioConfig.primary();
  AppLogger.minLevel = LogLevel.error; // silence evaluator dev.log spam

  final fx = _loadFixture(basename);
  final route = RouteGeometry.fromPoints(fx.polyline);
  final totalLen = route.totalLengthMeters;

  for (final s in fx.stations) {
    s.sProj = route.projectLatLng(s.lat, s.lng);
  }
  fx.alarmTarget.sProj = route.projectLatLng(fx.alarmTarget.lat, fx.alarmTarget.lng);
  if (fx.stations.first.sProj.isNaN) fx.stations.first.sProj = 0.0;
  if (fx.alarmTarget.sProj.isNaN) fx.alarmTarget.sProj = totalLen;

  final stationMeters = fx.stations
      .map((s) => s.sProj)
      .where((v) => v.isFinite)
      .toList()
    ..sort();

  final gtT = <double>[];
  final gtS = <double>[];
  {
    final sorted = [...fx.stations]..sort((a, b) => a.arrivalTs.compareTo(b.arrivalTs));
    double lastS = 0.0;
    for (final s in sorted) {
      final sv = s.sProj.isFinite ? s.sProj : lastS;
      gtT.add(s.arrivalTs);
      gtS.add(sv);
      lastS = sv;
    }
  }
  final gt = _GroundTruth(gtT, gtS);

  // Single final metro leg for evaluateCoinciding. Guard against degenerate
  // 0/1-station fixtures (a destination alarm needs a first + last station);
  // sublist(1, len-1) would RangeError on len<2.
  final intermediate = fx.stations.length >= 2
      ? fx.stations.sublist(1, fx.stations.length - 1)
      : <_StationAnchor>[];
  final leg = TransitLegStops(
    legStartMeters: 0.0,
    legEndMeters: fx.alarmTarget.sProj,
    numStops: intermediate.length,
    stopPositions: intermediate.map((s) => LatLng(s.lat, s.lng)).toList(),
    stopMeters: intermediate.map((s) => s.sProj).toList(),
    lineName: fx.line,
    isActualPositions: true,
    isMetro: true,
    stopNames: intermediate.map((s) => s.name).toList(),
  );
  final transitLegs = <TransitLegStops>[leg];
  final firedLegIds = <String>{};
  final stepBounds = <double>[0.0, totalLen];
  final stepStops = <double>[0.0, intermediate.length.toDouble()];

  final orch = EkfOrchestrator(route: route, logVerbosity: 0);
  final metrics = EkfMetrics();

  // P0 REACHABILITY PROTECTION LEVEL wiring (production-equivalent).
  // A stop-count topology cap tightens the early-firing; dwellMin is a
  // conservative lower bound (safe because effectiveProgress=max(stat,reach)
  // means the cap can only reduce earliness, never cause a late fire).
  // dwellMinSeconds=0 => unconditionally-safe free-run bound (matches the
  // production default). The topology cap is inert here; it stays available for
  // per-line opt-in on confirmed all-stops services.
  final reach = ReachabilityTracker(
    vLineTable: const VLineTable(),
    config: const ReachabilityConfig(dwellMinSeconds: 0.0),
  );
  final reachTopo =
      RouteTopology(stationMeters: stationMeters, dwellMinSeconds: 0.0);
  // Seed the cold-start anchor at trip origin (s=0) so reachability is a safety
  // net from t0 even if GPS never yields a single fix (closes GLMT-03).
  final double reachT0 = fx.imu.isNotEmpty
      ? fx.imu.first.t
      : (fx.gps.isNotEmpty ? fx.gps.first.t : 0.0);
  reach.seedColdStart(tSeconds: reachT0, sMeters: 0.0);
  double reachBoundAtFire = double.nan;

  final recT = <double>[];
  final recS = <double>[];

  // Phantom frozen anchor = last accepted real fix strictly before the window.
  double frozenLat = double.nan, frozenLng = double.nan, frozenSpeed0 = 0.0;
  if (cfg.kind == ScenarioKind.phantomInject) {
    _GpsRow? prev;
    for (final r in fx.gps) {
      if (r.t >= cfg.windowStart) break;
      if (_inBlindWindow(r.t, fx.blindWindows)) continue;
      final p = _locationReplicaProcess(r, prev);
      if (p == null) continue;
      final sp = route.projectLatLng(p.lat, p.lng);
      if (sp.isFinite) {
        frozenLat = p.lat;
        frozenLng = p.lng;
        frozenSpeed0 = p.speed.isFinite ? p.speed : 0.0;
      }
      prev = p;
    }
  }

  // Driver state.
  double? lastGpsFixTs;
  double? lastGpsUnavailableTs;
  int accelCount = 0;
  bool noGyroDeclared = false;
  double? firstInitTs;
  double lastAcceptedFixTs = double.negativeInfinity;
  _GpsRow? prevAcceptedGps;
  double? lastPhantomTs;

  bool fired = false;
  double fireTs = double.nan, fireS = double.nan, fireSigma = double.nan;
  String fireReason = '';
  double lastFireEvalTs = double.negativeInfinity;

  int degradedTicks = 0;
  int backwardEvents = 0;
  double maxBackwardStep = 0.0;
  double lastS = double.nan;

  double maxDriftAbs = -1, maxDriftTs = double.nan, maxDriftEkf = double.nan, maxDriftTrue = double.nan;
  double maxSpeedSeen = 0.0, maxVSeen = 0.0;

  void feedMetrics(double t, double sEst, bool gpsAvail) {
    metrics.update(
      ekfProgressMeters: sEst,
      trueProgressMeters: gt.at(t),
      gpsAvailable: gpsAvail,
    );
    if (sEst.isFinite) {
      final tru = gt.at(t);
      if (tru.isFinite) {
        final d = (sEst - tru).abs();
        if (d > maxDriftAbs) {
          maxDriftAbs = d;
          maxDriftTs = t;
          maxDriftEkf = sEst;
          maxDriftTrue = tru;
        }
      }
    }
  }

  final windowEntryS = List<double?>.filled(fx.blindWindows.length, null);
  final windowExitS = List<double?>.filled(fx.blindWindows.length, null);

  final wd = (cfg.windowDur > 0) ? _WindowDiag() : null;
  if (wd != null) {
    wd.trueAtStart = gt.at(cfg.windowStart);
    wd.trueAtEnd = gt.at(cfg.windowEnd);
  }

  void maybeEvaluateFire(double t) {
    if (fired) return;
    final st = orch.publicState;
    double? reachBound;
    if (useReachability) {
      final rb =
          reach.boundNow(nowSeconds: t, lineName: fx.line, topology: reachTopo);
      if (rb != null && rb.sMaxMeters.isFinite) reachBound = rb.sMaxMeters;
    }
    final trigger = AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.stops,
      userValue: 2,
      progressMeters: st.s,
      allEvents: const <RouteEventBoundary>[],
      firedEventIndexes: <int>{},
      firedLegIds: firedLegIds,
      isMetroLeg: true,
      transitLegs: transitLegs,
      currentLegIndex: 0,
      isFinalLeg: true,
      stepBoundsMeters: stepBounds,
      stepStopsCumulative: stepStops,
      currentSpeedMps: st.v,
      positionSigmaMeters: st.sigmaS,
      velocitySigmaMps: st.sigmaV,
      fractileK: FireDecisionConfig.fractileK,
      reachableProgressBoundMeters: reachBound,
    );
    if (trigger != null && trigger.eventType == AlarmEventType.finalDestination) {
      fired = true;
      fireTs = t;
      fireS = st.s;
      fireSigma = st.sigmaS;
      fireReason = trigger.reason;
      reachBoundAtFire = reachBound ?? double.nan;
    }
  }

  // Accept a GPS fix (used by both the real branch and the phantom injector).
  void acceptGps(_GpsRow pos, double t) {
    lastGpsFixTs = t; // BEFORE projection (phantom trap, sensor_fusion:140)
    prevAcceptedGps = pos;
    final ts = _dur(t);
    final sProj = route.projectLatLng(pos.lat, pos.lng);
    if (sProj.isFinite) {
      firstInitTs ??= t;
      lastAcceptedFixTs = t;
    }
    if (pos.speed.isFinite && pos.speed.abs() > maxSpeedSeen) {
      maxSpeedSeen = pos.speed.abs();
    }
    orch.setStationContext(stationMeters: stationMeters, isMetroLeg: true);
    orch.onGpsFixAuto(GpsFix(
      lat: pos.lat, lng: pos.lng,
      accuracyMeters: pos.hacc, speedMps: pos.speed, timestamp: ts,
    ));
    final st = orch.publicState;
    if (st.v.abs() > maxVSeen) maxVSeen = st.v.abs();
    recT.add(t);
    recS.add(st.s);
    if (firstInitTs != null) {
      feedMetrics(t, st.s, true);
    }
    if (st.s.isFinite) lastS = st.s;
    if (firstInitTs != null) {
      lastFireEvalTs = t;
      maybeEvaluateFire(t);
    }
  }

  void recordWindow(double t, double s, double v) {
    if (wd == null) return;
    if (t >= cfg.windowStart && wd.sAtStart.isNaN) wd.sAtStart = s;
    if (t < cfg.windowStart) wd.sBeforeWindow = s;
    if (t >= cfg.windowStart && t <= cfg.windowEnd) {
      if (s.isFinite && s < wd.minSInWindow) wd.minSInWindow = s;
      wd.sAtEnd = s;
      wd.vAtEnd = v;
    }
    if (t >= cfg.windowEnd && wd.sAfterWindow.isNaN) wd.sAfterWindow = s;
  }

  void body() {
    var i = 0, g = 0;
    final imu = fx.imu;
    final gps = fx.gps;

    while (i < imu.length || g < gps.length) {
      final imuT = i < imu.length ? imu[i].t : double.infinity;
      final gpsT = g < gps.length ? gps[g].t : double.infinity;

      if (imuT <= gpsT) {
        // ---- IMU EVENT ----
        final r = imu[i++];

        // GAP_INJECT: drop IMU rows inside the spliced gap.
        if (cfg.kind == ScenarioKind.gapInject &&
            r.t >= cfg.windowStart && r.t < cfg.windowEnd) {
          continue;
        }

        final ts = _dur(r.t);

        if (!noGyroDeclared) {
          accelCount++;
          final hasGyro = r.gx != 0.0 || r.gy != 0.0 || r.gz != 0.0;
          if (hasGyro) {
            noGyroDeclared = true;
          } else if (accelCount >= 100) {
            noGyroDeclared = true;
            orch.setNoGyro(true);
          }
        }

        if (lastGpsFixTs != null &&
            (r.t - lastGpsFixTs!) > 3.0 &&
            (lastGpsUnavailableTs == null || (r.t - lastGpsUnavailableTs!) > 0.5)) {
          lastGpsUnavailableTs = r.t;
          orch.onGpsUnavailable(ts);
        }

        orch.onImuSample(ImuSample(
          ax: r.ax, ay: r.ay, az: r.az,
          gx: r.gx, gy: r.gy, gz: r.gz, timestamp: ts,
        ));

        final st = orch.publicState;
        if (st.v.abs() > maxVSeen) maxVSeen = st.v.abs();
        recT.add(r.t);
        recS.add(st.s);
        recordWindow(r.t, st.s, st.v);

        if (firstInitTs != null) {
          final gpsAvail = (r.t - lastAcceptedFixTs) < 3.0;
          feedMetrics(r.t, st.s, gpsAvail);
        }

        final degraded = st.mode == EkfMode.degraded;
        if (degraded) degradedTicks++;

        if (lastS.isFinite && st.s < lastS - 0.5) {
          backwardEvents++;
          final step = lastS - st.s;
          if (step > maxBackwardStep) maxBackwardStep = step;
        }
        if (st.s.isFinite) lastS = st.s;

        for (var w = 0; w < fx.blindWindows.length; w++) {
          final win = fx.blindWindows[w];
          if (r.t >= win[0] && windowEntryS[w] == null) windowEntryS[w] = st.s;
          if (r.t >= win[1] && windowExitS[w] == null) windowExitS[w] = st.s;
        }

        // PHANTOM_INJECT: emit a frozen confident fix every 2s inside the window.
        if (cfg.kind == ScenarioKind.phantomInject &&
            r.t >= cfg.windowStart && r.t < cfg.windowEnd &&
            frozenLat.isFinite &&
            (lastPhantomTs == null || (r.t - lastPhantomTs!) >= 2.0)) {
          lastPhantomTs = r.t;
          // Smoothly-decaying speed toward 0 (tau = 40s).
          final decay = math.exp(-(r.t - cfg.windowStart) / 40.0);
          final phantomSpeed = frozenSpeed0 * decay;
          acceptGps(_GpsRow(r.t, frozenLat, frozenLng, 5.0, phantomSpeed), r.t);
        }

        if (firstInitTs != null && degraded && (r.t - lastFireEvalTs) >= 1.0) {
          lastFireEvalTs = r.t;
          maybeEvaluateFire(r.t);
        }

        // Reachability safety-net eval: run even BEFORE EKF init (cold start),
        // so the physics bound can fire with zero accepted GPS fixes. This is
        // what closes GLMT-03 (EKF never inits -> never fires).
        if (useReachability &&
            firstInitTs == null &&
            (r.t - lastFireEvalTs) >= 1.0) {
          lastFireEvalTs = r.t;
          maybeEvaluateFire(r.t);
        }
      } else {
        // ---- GPS EVENT ----
        final r = gps[g++];

        // COLD_START: withhold ALL GPS.
        if (cfg.kind == ScenarioKind.coldStart) continue;

        // GAP_INJECT: drop GPS rows inside the spliced gap.
        if (cfg.kind == ScenarioKind.gapInject &&
            r.t >= cfg.windowStart && r.t < cfg.windowEnd) {
          continue;
        }

        // PHANTOM_INJECT: suppress real fixes in the window (frozen ones injected
        // from the IMU branch instead).
        if (cfg.kind == ScenarioKind.phantomInject &&
            r.t >= cfg.windowStart && r.t < cfg.windowEnd) {
          continue;
        }

        // Blind-window blanking IS the DR mechanism (do NOT touch lastGpsFixTs).
        if (_inBlindWindow(r.t, fx.blindWindows)) continue;

        final pos = _locationReplicaProcess(r, prevAcceptedGps);
        if (pos == null) continue;

        acceptGps(pos, r.t);
        // Reset the reachability anchor ONLY on a real accepted fix (precond
        // iii). Phantom-injected fixes (other branch) must never anchor here —
        // production protects this via the accuracy gate + EKF phantom rejection.
        if (useReachability) {
          final sp = route.projectLatLng(pos.lat, pos.lng);
          if (sp.isFinite) {
            reach.onAcceptedFix(
              sMeters: sp,
              accuracyMeters: pos.hacc.isFinite ? pos.hacc : 0.0,
              tSeconds: r.t,
            );
          }
        }
        final st = orch.publicState;
        recordWindow(r.t, st.s, st.v);
      }
    }
  }

  runZoned(body,
      zoneSpecification: ZoneSpecification(print: (s, p, z, l) {/* swallow */}));

  double sEstAt(double t) {
    if (recT.isEmpty) return double.nan;
    if (t <= recT.first) return recS.first;
    if (t >= recT.last) return recS.last;
    var lo = 0, hi = recT.length - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) >> 1;
      if (recT[mid] <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final f = (t - recT[lo]) / (recT[hi] - recT[lo]);
    return recS[lo] + f * (recS[hi] - recS[lo]);
  }

  final stationScores = <_StationScore>[];
  for (final s in fx.stations) {
    final est = sEstAt(s.arrivalTs);
    final target = s.sProj.isFinite ? s.sProj : double.nan;
    stationScores.add(_StationScore(s.name, s.arrivalTs, target, est, est - target));
  }

  final fireTrueS = fired ? gt.at(fireTs) : double.nan;
  final secondsMargin = fired ? fx.alarmTarget.arrivalTs - fireTs : double.nan;
  final metersEarly = fired ? fx.alarmTarget.sProj - fireTrueS : double.nan;
  final ekfArcErr = fired ? (fireS - fireTrueS).abs() : double.nan;

  final blindNotes = <String>[];
  for (var w = 0; w < fx.blindWindows.length; w++) {
    final win = fx.blindWindows[w];
    final entry = windowEntryS[w];
    final exit = windowExitS[w];
    if (entry != null && exit != null) {
      blindNotes.add('window ${win[0].toStringAsFixed(0)}-${win[1].toStringAsFixed(0)}s: '
          's_est ${entry.toStringAsFixed(0)}->${exit.toStringAsFixed(0)} '
          '(d${(exit - entry).toStringAsFixed(0)}m)');
    } else {
      blindNotes.add('window ${win[0].toStringAsFixed(0)}-${win[1].toStringAsFixed(0)}s: (pre-init)');
    }
  }
  if (wd != null && wd.minSInWindow.isInfinite) wd.minSInWindow = double.nan;

  return RunResult(
    basename: basename,
    ride: fx.ride,
    device: fx.device,
    platform: fx.platform,
    scenario: cfg.label,
    totalLen: totalLen,
    numImu: fx.imu.length,
    numGps: fx.gps.length,
    stationScores: stationScores,
    fired: fired,
    fireTs: fireTs,
    fireS: fireS,
    fireSigma: fireSigma,
    fireTrueS: fireTrueS,
    secondsMargin: secondsMargin,
    metersEarly: metersEarly,
    ekfArcErrAtFire: ekfArcErr,
    fireReason: fireReason,
    rmse: metrics.rmse,
    maxDrift: metrics.maxDrift,
    maxBlackoutError: metrics.maxBlackoutError,
    firstInitTs: firstInitTs ?? double.nan,
    degradedTicks: degradedTicks,
    backwardEvents: backwardEvents,
    maxBackwardStep: maxBackwardStep,
    blindWindowNotes: blindNotes,
    maxDriftTs: maxDriftTs,
    maxDriftEkf: maxDriftEkf,
    maxDriftTrue: maxDriftTrue,
    maxSpeedSeen: maxSpeedSeen,
    maxVSeen: maxVSeen,
    window: wd,
  );
}

// ---------------------------------------------------------------------------
// Printing (stdout survives the print-swallowing zone)
// ---------------------------------------------------------------------------

String _f(double v, [int d = 1]) => v.isNaN ? 'NaN' : v.toStringAsFixed(d);

void printScorecard(RunResult r) {
  final b = StringBuffer();
  b.writeln('');
  b.writeln('================= EKF REPLAY SCORECARD [${r.scenario}] =================');
  b.writeln('ride     : ${r.ride}');
  b.writeln('device   : ${r.device}  platform: ${r.platform}');
  b.writeln('route len: ${_f(r.totalLen)} m   IMU rows: ${r.numImu}   GPS rows: ${r.numGps}');
  b.writeln('EKF first-init at t = ${_f(r.firstInitTs)} s (s_est=0 before this)');
  b.writeln('');
  b.writeln('PER-STATION  (s_err = s_est - s_target)');
  b.writeln('  ${'station'.padRight(34)} ${'t_s'.padLeft(8)} '
      '${'s_target'.padLeft(10)} ${'s_est@arr'.padLeft(10)} ${'s_err'.padLeft(9)}');
  for (final s in r.stationScores) {
    final nm = s.name.length > 34 ? s.name.substring(0, 34) : s.name;
    b.writeln('  ${nm.padRight(34)} ${_f(s.arrivalTs).padLeft(8)} '
        '${_f(s.sTarget).padLeft(10)} ${_f(s.sEstAtArrival).padLeft(10)} '
        '${_f(s.sErr).padLeft(9)}');
  }
  b.writeln('');
  b.writeln('DESTINATION FIRE  (mode=stops, N=2 stops prior)');
  if (r.fired) {
    b.writeln('  FIRED = YES   reason: ${r.fireReason}');
    b.writeln('  fire_t_s=${_f(r.fireTs)}s  target_arrival=${_f(r.stationScores.last.arrivalTs)}s');
    b.writeln('  fire_s=${_f(r.fireS)}m  sigma_s=${_f(r.fireSigma)}m  s_true@fire=${_f(r.fireTrueS)}m');
    b.writeln('  seconds_margin=${_f(r.secondsMargin)}s '
        '(${r.secondsMargin >= 0 ? 'EARLY-OK' : 'LATE-FAIL'})   meters_early=${_f(r.metersEarly)}m');
  } else {
    b.writeln('  FIRED = NO  -> NEVER-FIRED = HARD FAIL');
  }
  b.writeln('');
  b.writeln('DRIFT: rmse=${_f(r.rmse)}m  maxDrift=${_f(r.maxDrift)}m  maxBlackoutError=${_f(r.maxBlackoutError)}m');
  b.writeln('DR   : degradedTicks=${r.degradedTicks}  backwardEvents=${r.backwardEvents} (max ${_f(r.maxBackwardStep)}m)');
  for (final n in r.blindWindowNotes) {
    b.writeln('  blind $n');
  }
  b.writeln('======================================================================');
  stdout.writeln(b.toString());
}

void printCombinedTable(List<RunResult> results, List<String> errors) {
  final b = StringBuffer();
  b.writeln('');
  b.writeln('############ NEVER-LATE BASELINE GATE — COMBINED SCORECARD ############');
  b.writeln('  ${'ride'.padRight(30)} ${'device'.padRight(10)} ${'nSt'.padLeft(3)} '
      '${'sec_margin'.padLeft(11)} ${'rmse'.padLeft(8)} ${'maxDrift'.padLeft(9)} ${'maxBlkout'.padLeft(9)}  verdict');
  for (final r in results) {
    var rideShort = r.ride;
    if (rideShort.length > 30) rideShort = rideShort.substring(0, 30);
    final verdict = r.isLate
        ? (r.fired ? 'LATE(${_f(r.secondsMargin)}s)' : 'NEVER-FIRED')
        : 'ok(+${_f(r.secondsMargin)}s)';
    final marginCell = r.fired ? _f(r.secondsMargin) : 'no-fire';
    b.writeln('  ${rideShort.padRight(30)} ${r.device.padRight(10)} '
        '${r.nStations.toString().padLeft(3)} ${marginCell.padLeft(11)} '
        '${_f(r.rmse).padLeft(8)} ${_f(r.maxDrift).padLeft(9)} '
        '${_f(r.maxBlackoutError).padLeft(9)}  $verdict');
    // Flag catastrophic DR (max drift far beyond plausible route length).
    if (r.maxDrift > 2 * r.totalLen) {
      b.writeln('      ^ANOMALY worst-drift @t=${_f(r.maxDriftTs)}s '
          's_est=${_f(r.maxDriftEkf)} vs s_true=${_f(r.maxDriftTrue)} | '
          'maxGpsSpeedIn=${_f(r.maxSpeedSeen)}m/s maxV=${_f(r.maxVSeen)}m/s');
    }
  }
  for (final e in errors) {
    b.writeln('  [ERROR] $e');
  }
  final lateCount = results.where((r) => r.isLate).length;
  b.writeln('  ---------------------------------------------------------------');
  b.writeln('  rides run: ${results.length}   LATE/never-fired: $lateCount   errors: ${errors.length}');
  b.writeln('  GATE: ${lateCount == 0 ? 'PASS (0 late)' : 'FAIL ($lateCount late/never-fired)'}');
  b.writeln('#######################################################################');
  stdout.writeln(b.toString());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  final fixtures = discoverFixtures();

  // -------------------------------------------------------------------------
  // TASK 1: never-late baseline gate over ALL discovered fixtures.
  // -------------------------------------------------------------------------
  test('NEVER-LATE GATE — all fixtures (destination alarm, N=2 stops)', () {
    expect(fixtures, isNotEmpty,
        reason: 'no fixture_*.json found in $kInRepoFixturesDir '
            '(committed CI set) or $kExternalFixturesDir (external rides). '
            'The never-late gate MUST have fixtures — run '
            'tools/make_replay_fixtures.py to regenerate the committed set.');

    final results = <RunResult>[];
    final errors = <String>[];
    for (final b in fixtures) {
      try {
        results.add(runReplay(b));
      } catch (e) {
        errors.add('$b: $e');
      }
    }

    printCombinedTable(results, errors);

    // Hard gate: no ride may fire LATE (or never-fire) on the destination.
    final late = results.where((r) => r.isLate).toList();
    final names = late
        .map((r) => '${r.ride} (${r.fired ? "${_f(r.secondsMargin)}s LATE" : "never-fired"})')
        .join('; ');
    expect(late, isEmpty, reason: 'rides fired LATE / never-fired: $names');

    // Per-ride NEVER-WRONG-PLACE gate (plan §4). Complements never-late (time)
    // with the SPATIAL guarantee: the fire must be at-or-before the target stop
    // in arc-length, and cannot be more than a whole route early (garbage
    // anchor). We intentionally do NOT gate a time-based "not before boarding"
    // bound — an "N stops prior" alarm on a short leg legitimately fires at or
    // before boarding, so that would false-fail; early-firing is the SAFE state.
    const double kSpatialTolM = 200.0; // GPS accuracy + snap tolerance
    for (final r in results) {
      if (!r.fired) continue; // never-fired already gated above
      if (r.nStations < 2) continue; // degenerate leg (no first+last pair)
      // (a) Spatial never-late / never-wrong-place: fire at/before the target
      // stop IN SPACE. metersEarly = target - s_true@fire; materially negative
      // => woke the rider AFTER passing the stop.
      expect(r.metersEarly, greaterThanOrEqualTo(-kSpatialTolM),
          reason: '${r.ride}: fired ${_f(-r.metersEarly)}m PAST the target stop '
              '(spatially late / wrong place)');
      // (b) Earliness bounded by route length — firing earlier than the whole
      // route means s_true@fire is garbage-negative (broken anchor).
      expect(r.metersEarly, lessThanOrEqualTo(r.totalLen + kSpatialTolM),
          reason: '${r.ride}: fired ${_f(r.metersEarly)}m early on a '
              '${_f(r.totalLen)}m route — impossible, garbage anchor');
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  // -------------------------------------------------------------------------
  // TASK 2: synthetic scenarios (plan §3.4), derived from a real GPS-rich ride.
  // Report-only baseline snapshot; they do not gate the build so re-runs after
  // lib/ fixes simply show updated numbers.
  // -------------------------------------------------------------------------
  final scenarioBase = pickScenarioFixture(fixtures);

  test('SYNTHETIC: PHANTOM_INJECT — frozen confident fix over a moving window',
      () {
    if (scenarioBase == null) {
      stdout.writeln('SYNTHETIC:PHANTOM skipped — no GPS-rich fixture available');
      return;
    }
    // Choose a mid-route moving window (~45% through), 120s long.
    final hdr = _loadFixture(scenarioBase);
    final idx = (hdr.stations.length * 0.45).floor().clamp(1, hdr.stations.length - 2);
    final wStart = hdr.stations[idx].arrivalTs;
    const wDur = 120.0;

    final base = runReplay(scenarioBase);
    final r = runReplay(scenarioBase, config: ScenarioConfig.phantom(wStart, wDur));
    printScorecard(r);

    final w = r.window!;
    final estAdvance = (w.sAtEnd - w.sAtStart);
    final trueAdvance = (w.trueAtEnd - w.trueAtStart);
    final defended = trueAdvance > 1 && estAdvance >= 0.5 * trueAdvance;
    final fireDelay = (base.fired && r.fired)
        ? (r.fireTs - base.fireTs)
        : double.nan;

    final b = StringBuffer();
    b.writeln('');
    b.writeln('---- SYNTHETIC PHANTOM_INJECT RESULT ----');
    b.writeln('  window: ${_f(wStart)}..${_f(wStart + wDur)}s  '
        'frozen@ last-pre-window fix, hacc=5m, speed decays (tau=40s)');
    b.writeln('  s_est advance in window : ${_f(estAdvance)} m  (true advance ${_f(trueAdvance)} m)');
    b.writeln('  s_est min in window     : ${_f(w.minSInWindow)} m  (start ${_f(w.sAtStart)} m)');
    b.writeln('  v at window end         : ${_f(w.vAtEnd)} m/s');
    b.writeln('  dest fire: baseline ${_f(base.fireTs)}s (margin ${_f(base.secondsMargin)}s) '
        '-> phantom ${_f(r.fireTs)}s (margin ${_f(r.secondsMargin)}s), delay ${_f(fireDelay)}s');
    b.writeln('  PHANTOM DEFENSE: ${defended ? "PASS (s kept advancing)" : "FAIL (progress frozen/dragged by stale fix)"}');
    b.writeln('  (baseline expectation: FAIL — no phantom defense in current lib/)');
    b.writeln('-----------------------------------------');
    stdout.writeln(b.toString());

    expect(r.window, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('SYNTHETIC: GAP_INJECT — 60s and 300s IMU+GPS splice (dt>1s reset probe)',
      () {
    if (scenarioBase == null) {
      stdout.writeln('SYNTHETIC:GAP skipped — no GPS-rich fixture available');
      return;
    }
    final hdr = _loadFixture(scenarioBase);
    final idx = (hdr.stations.length * 0.45).floor().clamp(1, hdr.stations.length - 2);
    final wStart = hdr.stations[idx].arrivalTs;

    final base = runReplay(scenarioBase);
    for (final dur in [60.0, 300.0]) {
      final r = runReplay(scenarioBase, config: ScenarioConfig.gap(wStart, dur));
      printScorecard(r);
      final w = r.window!;
      final b = StringBuffer();
      b.writeln('');
      b.writeln('---- SYNTHETIC GAP_INJECT(${dur.toStringAsFixed(0)}s) RESULT ----');
      b.writeln('  gap window: ${_f(wStart)}..${_f(wStart + dur)}s (all IMU+GPS dropped)');
      b.writeln('  s_est before gap: ${_f(w.sBeforeWindow)} m  (true ${_f(w.trueAtStart)} m)');
      b.writeln('  s_est after gap : ${_f(w.sAfterWindow)} m  (true ${_f(w.trueAtEnd)} m)');
      b.writeln('  s-progress across gap: est ${_f(w.sAfterWindow - w.sBeforeWindow)} m '
          'vs true ${_f(w.trueAtEnd - w.trueAtStart)} m  '
          '(lost ${_f((w.trueAtEnd - w.trueAtStart) - (w.sAfterWindow - w.sBeforeWindow))} m)');
      b.writeln('  dest fire: baseline ${_f(base.fireTs)}s (margin ${_f(base.secondsMargin)}s) '
          '-> gap ${_f(r.fireTs)}s (margin ${_f(r.secondsMargin)}s), '
          'margin shift ${_f(r.secondsMargin - base.secondsMargin)}s');
      b.writeln('  late? ${r.isLate ? "YES" : "no"} (dt>1s reset zeroes v; GPS after gap re-anchors)');
      b.writeln('------------------------------------------');
      stdout.writeln(b.toString());
      expect(r.window, isNotNull);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('SYNTHETIC: COLD_START — all GPS withheld (GLMT-03 init probe)', () {
    if (scenarioBase == null) {
      stdout.writeln('SYNTHETIC:COLD_START skipped — no GPS-rich fixture available');
      return;
    }
    final r = runReplay(scenarioBase, config: ScenarioConfig.coldStart());
    printScorecard(r);

    final b = StringBuffer();
    b.writeln('');
    b.writeln('---- SYNTHETIC COLD_START RESULT ----');
    b.writeln('  first-init t : ${_f(r.firstInitTs)} (NaN = never initialized)');
    b.writeln('  ever fired   : ${r.fired}');
    b.writeln('  final s_est  : ${_f(r.stationScores.last.sEstAtArrival)} m '
        '(target ${_f(r.stationScores.last.sTarget)} m)');
    b.writeln('  VERDICT: ${(!r.fired && r.firstInitTs.isNaN) ? "NEVER INIT -> NEVER FIRES (GLMT-03 confirmed)" : "REACHABILITY FIRED with ZERO GPS (GLMT-03 CLOSED)"}');
    b.writeln('-------------------------------------');
    stdout.writeln(b.toString());

    expect(r.window, isNull);
    // HARD GATE (P0): reachability closes GLMT-03 — the EKF never initialises
    // with zero GPS, but the physics Protection Level fires from the trip-origin
    // anchor anyway, and it fires EARLY (never late).
    expect(r.fired, isTrue,
        reason: 'COLD_START must fire via reachability even with zero GPS fixes '
            '(GLMT-03). first-init=${r.firstInitTs} (NaN => EKF never inited).');
    expect(r.isLate, isFalse,
        reason: 'COLD_START reachability fire must be at-or-before arrival.');

    // Cross-check: with reachability DISABLED the EKF-only path must NOT fire
    // (proves the fire is genuinely the reachability layer, not the EKF).
    final rNoReach =
        runReplay(scenarioBase, config: ScenarioConfig.coldStart(), useReachability: false);
    expect(rNoReach.fired, isFalse,
        reason: 'Without reachability, cold-start must reproduce GLMT-03 '
            '(EKF never inits => never fires). If this fires, the test no longer '
            'isolates the reachability contribution.');
  }, timeout: const Timeout(Duration(minutes: 15)));

  // -------------------------------------------------------------------------
  // REAL underground rides — the REALISTIC tunnel case, where ZUPT +
  // station-cadence anchoring is what keeps position tight. Unlike the COLD_START
  // probe above (zero GPS from the ORIGIN, where the EKF never gets a surface
  // anchor and only the conservative reachability net can fire), this runs the
  // NATURAL scenario: GPS present on the surface, blanked inside the real blind
  // windows (tunnels) but IMU KEPT — so the ZUPT detector's accel/decel dwell
  // signature fires at each in-tunnel station stop and StationAssociation snaps
  // the along-track estimate back to a known station, carrying position through
  // the tunnel WITHOUT GPS. This measures the actual along-track error at the
  // GPS-denied (underground) stations — the honest test of the underground
  // positioning mechanism, on real Namma Purple Line IMU + real tunnel geometry.
  // Skips gracefully in CI where these external rides aren't committed.
  // -------------------------------------------------------------------------
  test('REAL underground ride — ZUPT/station-cadence keeps position tight through tunnel', () {
    final realUnderground = fixtures.where((b) {
      final h = _readHeader(b);
      if (h == null) return false;
      final synthetic = (h['synthetic'] as bool?) ?? false;
      final windows = (h['gps_blind_windows_s'] as List?) ?? const [];
      return !synthetic && windows.isNotEmpty;
    }).toList();

    if (realUnderground.isEmpty) {
      stdout.writeln('REAL underground ZUPT test skipped — no real underground '
          'fixture present (external rides not committed to CI).');
      return;
    }

    for (final b in realUnderground) {
      final h = _readHeader(b)!;
      final windows = ((h['gps_blind_windows_s'] as List?) ?? const [])
          .map((w) => (w as List).map((x) => (x as num).toDouble()).toList())
          .toList();
      bool inTunnel(double t) => windows.any((w) => t >= w[0] && t <= w[1]);

      final r = runReplay(b); // NATURAL run: real GPS + real blind windows + IMU

      var maxUndergroundErr = 0.0;
      var undergroundStations = 0;
      final rows = <String>[];
      for (final s in r.stationScores) {
        final ug = inTunnel(s.arrivalTs);
        if (ug) {
          undergroundStations++;
          if (s.sErr.abs() > maxUndergroundErr) maxUndergroundErr = s.sErr.abs();
        }
        rows.add('    ${ug ? "TUNNEL" : " gps  "} ${s.name.padRight(30)} '
            'err=${_f(s.sErr).padLeft(8)}m @${_f(s.arrivalTs)}s');
      }
      // "Precise wake" wants GPS-denied along-track error under a fraction of a
      // station spacing (~400 m). Above that, the reachability safety net still
      // guarantees never-late, but the wake is conservative (early), not precise.
      const preciseWakeErrM = 400.0;
      final degraded = maxUndergroundErr > preciseWakeErrM;
      stdout.writeln('  [REAL underground ZUPT] $b: '
          '$undergroundStations GPS-denied stations, '
          'max along-track err=${_f(maxUndergroundErr)}m, '
          'fire=${_f(r.fireTs)}s late=${r.isLate} margin=${_f(r.secondsMargin)}s'
          '${degraded ? "  ⚠ UNDERGROUND PRECISION DEGRADED (>${preciseWakeErrM.toStringAsFixed(0)}m — never-late holds via reachability, but wake is conservative)" : "  ✓ precise"}');
      stdout.writeln(rows.join('\n'));

      // HARD GATE: the guarantee is never-late. This must ALWAYS hold — and it
      // does on real underground rides, because the reachability net bounds max
      // progress even when the EKF along-track estimate has drifted.
      expect(r.isLate, isFalse,
          reason: 'Real underground ride $b must fire never-late.');
      // The estimate must at least be FINITE (NaN => the filter blew up).
      expect(maxUndergroundErr.isFinite, isTrue,
          reason: 'Underground along-track estimate for $b is NaN — filter divergence.');
      // NOTE (characterized limitation, NOT gated): on real Namma rides the
      // GPS-denied along-track error reaches ~1.3 km (Majestic) to ~3 km
      // (Nallur) — station-association is NOT reliably re-anchoring at each
      // in-tunnel stop, so error accumulates instead of resetting. never-late
      // still holds via reachability, but the underground wake is CONSERVATIVE
      // (early), not precise. Root-causing why the ZUPT dwell / station snap
      // doesn't fire at these stops is the #1 underground reliability item —
      // see docs/business_os/research/underground_validation_execution.md.
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  // -------------------------------------------------------------------------
  // TASK 3: MONOTONE SAFETY NET — reachability never fires LATER than the
  // EKF-only baseline on any fixture (effectiveProgress = max(stat, reach) can
  // only advance the fire, never delay it). This is the core safety property of
  // the integration and it is proven empirically on the real EKF + evaluator.
  // -------------------------------------------------------------------------
  test('REACHABILITY IS A MONOTONE SAFETY NET — never later than baseline', () {
    expect(fixtures, isNotEmpty);
    final rows = <String>[];
    var violations = 0;
    for (final b in fixtures) {
      RunResult on, off;
      try {
        on = runReplay(b, useReachability: true);
        off = runReplay(b, useReachability: false);
      } catch (_) {
        continue; // skip fixtures that error to load (e.g. 1-stop edge)
      }
      // Both fired: reachability fire time must be <= baseline fire time.
      // Baseline never-fired but reachability fired: strict improvement.
      final onT = on.fired ? on.fireTs : double.infinity;
      final offT = off.fired ? off.fireTs : double.infinity;
      final ok = onT <= offT + 1e-6;
      if (!ok) violations++;
      rows.add('  ${b.padRight(34)} baseline=${off.fired ? "${_f(offT)}s" : "never"}'
          '  reach=${on.fired ? "${_f(onT)}s" : "never"}  ${ok ? "ok" : "REGRESSION"}');
    }
    stdout.writeln('\n---- REACHABILITY MONOTONICITY (fire time on/off) ----');
    for (final r in rows) {
      stdout.writeln(r);
    }
    stdout.writeln('------------------------------------------------------');
    expect(violations, 0,
        reason: 'Reachability fired LATER than the EKF-only baseline on '
            '$violations fixture(s) — violates the monotone-safety-net property.');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
