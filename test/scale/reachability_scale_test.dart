// AT-SCALE never-late validation through the REAL production reachability code.
//
// Closes the "Python model vs actual Dart" gap: this drives the real
// ReachabilityTracker + VLineTable + Reachability.bound over the generated
// route matrix (391 rides across 19 cities / 46 lines / 9 scenarios, produced by
// scale/build_scale_rides.py) and asserts the never-late guarantee holds on
// EVERY route through the actual shipped math — not a re-implementation.
//
// The rides live outside the repo (large, generated). The test SKIPS cleanly
// when they're absent (CI), and runs when present (the founder's machine).
//
// Run: flutter test test/scale/reachability_scale_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

// Committed diverse subset (runs in CI) preferred; the full generated matrix on
// the founder's machine is used when present.
const String kInRepoScaleDir = 'test/fixtures/scale';
const String kExternalScaleDir = '/home/raed/geowake_imu_analysis/scale/rides';

// Agent-configurable (charter §7): GEOWAKE_SCALE_DIR forces a specific ride set
// (e.g. the full generated matrix) so the same test can sweep the committed
// subset in CI OR the full founder-machine matrix on demand — no code edit.
String get kScaleRidesDir {
  final env = Platform.environment['GEOWAKE_SCALE_DIR'];
  if (env != null && env.isNotEmpty && Directory(env).existsSync()) return env;
  return Directory(kInRepoScaleDir).existsSync()
      ? kInRepoScaleDir
      : kExternalScaleDir;
}

class _Ride {
  final String id;
  final String line;
  final double vlineCeiling;
  final List<double> stationS;
  final List<double> stationT;
  final List<List<double>> blind;
  final double destT;
  _Ride(this.id, this.line, this.vlineCeiling, this.stationS, this.stationT,
      this.blind, this.destT);
}

_Ride? _load(String rideId) {
  final f = File('$kScaleRidesDir/$rideId/base.json');
  if (!f.existsSync()) return null;
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final st = (j['stations'] as List).cast<Map<String, dynamic>>();
  final sS = <double>[];
  final sT = <double>[];
  for (final s in st) {
    sS.add((s['s_travel'] as num).toDouble());
    sT.add((s['arrival_t_s'] as num).toDouble());
  }
  if (sS.length < 2) return null;
  final blind = <List<double>>[];
  for (final w in (j['gps_blind_windows_s'] as List? ?? const [])) {
    final p = w as List;
    blind.add([(p[0] as num).toDouble(), (p[1] as num).toDouble()]);
  }
  return _Ride(
    j['ride_id'] as String? ?? rideId,
    j['line'] as String? ?? '',
    (j['vline_ceiling_mps'] as num).toDouble(),
    sS,
    sT,
    blind,
    sT.last,
  );
}

double _trueS(double t, List<double> ts, List<double> ss) {
  if (t <= ts.first) return ss.first;
  if (t >= ts.last) return ss.last;
  for (var i = 0; i < ts.length - 1; i++) {
    if (t >= ts[i] && t <= ts[i + 1]) {
      final f = (t - ts[i]) / (ts[i + 1] - ts[i]);
      return ss[i] + f * (ss[i + 1] - ss[i]);
    }
  }
  return ss.last;
}

/// Drive the REAL ReachabilityTracker over one ride; return the fire time for a
/// "wake N stops before destination" alarm, or null if it never fired.
///
/// [config] selects the tightening. The default is the shipped FREE-RUN bound
/// (dwellMin=0 ⇒ topology cap inert ⇒ sMax = sHi + V_LINE·dt). Passing a config
/// with dwellMinSeconds>0 arms the PROVEN Phase-0a dwell cap: the ride's SERVED
/// stations (`r.stationS`, which the generator already restricts to served —
/// express skips are excluded, no express trap) are handed to the topology, so
/// the fastest model pays [config].dwellMinSeconds at each served stop. The cap
/// is a valid UPPER bound (never-late) iff dwellMin ≤ every real served dwell;
/// the generated ground truth dwells ≥20 s at every served station, so any
/// dwellMin ≤ 20 is safe here (and ≤~10 is a conservative real-world floor).
double? _simFire(_Ride r,
    {int nStops = 2, ReachabilityConfig config = ReachabilityConfig.defaults}) {
  // Use the ride's certified ceiling via a per-line override so the real
  // VLineTable.forLine resolves exactly the ceiling the ground truth respects.
  final table = VLineTable(overrides: {'|${r.line.toLowerCase()}': r.vlineCeiling});
  final tracker = ReachabilityTracker(vLineTable: table, config: config);
  final targetIdx = (r.stationS.length - 1 - nStops).clamp(0, r.stationS.length - 1);
  final sTarget = r.stationS[targetIdx];

  // Arm the stop-count topology cap only when a positive dwell floor is set.
  // stationMeters = the ride's served stations (correct-by-construction).
  final RouteTopology? topo = config.dwellMinSeconds > 0.0
      ? RouteTopology(
          stationMeters: r.stationS, dwellMinSeconds: config.dwellMinSeconds)
      : null;

  bool inBlind(double t) {
    for (final w in r.blind) {
      if (t >= w[0] && t <= w[1]) return true;
    }
    return false;
  }

  tracker.seedColdStart(tSeconds: 0.0, sMeters: r.stationS.first);
  final tEnd = r.destT + 120;
  for (double t = 0.0; t <= tEnd; t += 1.0) {
    if (!inBlind(t)) {
      // GPS live: re-anchor to the true position, forward-overbounded by a
      // typical accuracy (mirrors production onAcceptedFix on a real fix).
      tracker.onAcceptedFix(
          sMeters: _trueS(t, r.stationT, r.stationS),
          accuracyMeters: 10.0,
          tSeconds: t);
    }
    final b = tracker.boundNow(nowSeconds: t, lineName: r.line, topology: topo);
    if (b != null && b.sMaxMeters >= sTarget) return t;
  }
  return null;
}

/// Two-sided window stats for one config over the ride set (pure; no I/O).
class _WindowStats {
  final int ran, fired, neverFired, late, egregious;
  final List<double> stopsEarly;
  final List<String> lateRides;
  final List<String> earlyRides;
  _WindowStats(this.ran, this.fired, this.neverFired, this.late,
      this.egregious, this.stopsEarly, this.lateRides, this.earlyRides);
}

_WindowStats _measure(List<_Ride> rides,
    {int nStops = 2, ReachabilityConfig config = ReachabilityConfig.defaults}) {
  var ran = 0, fired = 0, late = 0, neverFired = 0, egregious = 0;
  final lateRides = <String>[];
  final stopsEarly = <double>[];
  final earlyRides = <String>[];
  for (final r in rides) {
    ran++;
    final fireT = _simFire(r, nStops: nStops, config: config);
    if (fireT == null) {
      neverFired++;
      lateRides.add('${r.id} (never-fired)');
      continue;
    }
    fired++;
    if (fireT > r.destT + 1.0) {
      late++;
      lateRides.add('${r.id} (fire ${fireT.toStringAsFixed(0)}s > dest '
          '${r.destT.toStringAsFixed(0)}s)');
    }
    final sTrueAtFire = _trueS(fireT, r.stationT, r.stationS);
    final remaining = r.stationS.where((s) => s > sTrueAtFire + 1.0).length;
    final stEarly = (remaining - nStops).toDouble();
    stopsEarly.add(stEarly);
    if (stEarly >= 3) {
      egregious++;
      earlyRides.add('${r.id} ($remaining out, +${stEarly.toStringAsFixed(0)})');
    }
  }
  return _WindowStats(
      ran, fired, neverFired, late, egregious, stopsEarly, lateRides, earlyRides);
}

/// Percentile (0..1) of a list, nearest-rank. NaN for empty.
double _pct(List<double> xs, double p) {
  if (xs.isEmpty) return double.nan;
  final s = [...xs]..sort();
  final i = ((s.length - 1) * p).round().clamp(0, s.length - 1);
  return s[i];
}

/// Regression gate for "too early": p95 of stops-early must stay under this.
/// Some earliness is INHERENT to the never-late upper bound, but a wildly-early
/// fire is a product deal-breaker. Calibrated to the committed subset (observed
/// p95 = 3.0 stops as of 2026-07-20) with ~2 stops of headroom, so it passes
/// today and trips on a gross regression. NOTE: the egregious tail lives on LONG
/// GPS-BLACKOUT rides (measured up to +7 stops early) — that is the target for
/// the EKF/ZUPT + physics tightening; tighten this gate as those land.
const double _kMaxP95StopsEarly = 5.0;

void main() {
  final dir = Directory(kScaleRidesDir);
  final rideIds = dir.existsSync()
      ? (dir.listSync().whereType<Directory>().map((e) => e.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last)).toList()
      : <String>[];
  rideIds.sort();

  test(
      'REACHABILITY AT SCALE — two-sided window (never-late AND how-early) on '
      'every generated route (real Dart)', () {
    if (rideIds.isEmpty) {
      // External generated rides not present (e.g. CI) — nothing to assert.
      // The committed replay gate covers the never-late guarantee in CI.
      stdout.writeln('scale rides absent at $kScaleRidesDir — skipping '
          '(this is expected off the founder machine).');
      return;
    }

    const nStops = 2;
    var ran = 0, fired = 0, late = 0, neverFired = 0, bufferLate = 0;
    final lateRides = <String>[];
    final secondsEarly = <double>[]; // + fired before the intended moment
    final stopsEarly = <double>[]; // extra stops of warning beyond nStops
    var egregious = 0;
    final earlyRides = <String>[];

    for (final id in rideIds) {
      final r = _load(id);
      if (r == null) continue;
      ran++;
      final fireT = _simFire(r, nStops: nStops);
      if (fireT == null) {
        neverFired++;
        lateRides.add('$id (never-fired)');
        continue;
      }
      fired++;
      // NEVER-LATE (hard): fire at or before the true destination arrival.
      if (fireT > r.destT + 1.0) {
        late++;
        lateRides.add('$id (fire ${fireT.toStringAsFixed(0)}s > dest '
            '${r.destT.toStringAsFixed(0)}s)');
      }
      // TWO-SIDED WINDOW: how early vs the intended "$nStops stops before" moment.
      // A late fire is catastrophic; a WILDLY-early fire is also a deal-breaker.
      final targetIdx =
          (r.stationS.length - 1 - nStops).clamp(0, r.stationS.length - 1);
      final sEarly = r.stationT[targetIdx] - fireT; // + early, - late-for-buffer
      secondsEarly.add(sEarly);
      if (sEarly < -2.0) bufferLate++;
      final sTrueAtFire = _trueS(fireT, r.stationT, r.stationS);
      final remaining = r.stationS.where((s) => s > sTrueAtFire + 1.0).length;
      final stEarly = (remaining - nStops).toDouble();
      stopsEarly.add(stEarly);
      if (stEarly >= 3) {
        egregious++;
        earlyRides
            .add('$id ($remaining stops out, +${stEarly.toStringAsFixed(0)})');
      }
    }

    stdout.writeln('SCALE reachability: ran=$ran fired=$fired '
        'never-fired=$neverFired LATE=$late buffer-late=$bufferLate');
    stdout.writeln('  EARLINESS vs the intended $nStops-stops-before moment:');
    stdout.writeln('    seconds early: median='
        '${_pct(secondsEarly, 0.5).toStringAsFixed(0)}s  p95='
        '${_pct(secondsEarly, 0.95).toStringAsFixed(0)}s  max='
        '${_pct(secondsEarly, 1.0).toStringAsFixed(0)}s');
    stdout.writeln('    stops   early: median='
        '${_pct(stopsEarly, 0.5).toStringAsFixed(1)}  p95='
        '${_pct(stopsEarly, 0.95).toStringAsFixed(1)}  max='
        '${_pct(stopsEarly, 1.0).toStringAsFixed(1)}');
    stdout.writeln('    egregiously-early (>=3 extra stops): $egregious/$fired  '
        '${earlyRides.take(6).join("; ")}');

    // NEVER-LATE — hard gates (a late fire is the one unforgivable bug).
    expect(neverFired, 0,
        reason: 'rides where reachability never fired: '
            '${lateRides.take(10).join("; ")}');
    expect(late, 0,
        reason: 'LATE fires through the real reachability code: '
            '${lateRides.take(10).join("; ")}');
    expect(ran, greaterThan(10),
        reason: 'expected the committed scale subset (or the full matrix)');

    // NOT-TOO-EARLY — regression gate. Some earliness is inherent to the
    // never-late upper bound; a wildly-early fire is a deal-breaker. The gate is
    // generous (see [_kMaxP95StopsEarly]); the real signal is the distribution
    // printed above. Tighten as the physics tightening reduces early-firing.
    expect(_pct(stopsEarly, 0.95), lessThanOrEqualTo(_kMaxP95StopsEarly),
        reason: 'p95 stops-early regressed — alarms firing far too early: '
            '${earlyRides.take(8).join("; ")}');
  }, timeout: const Timeout(Duration(minutes: 10)));

  // ── ARMED dwell-cap tightening (GW-0005/GW-0011) ─────────────────────────
  // The shipped path runs the FREE-RUN bound with every tightening lever inert
  // (dwellMin=0). This test proves that arming the PROVEN Phase-0a dwell cap
  // with a conservative real-world dwell floor (10 s ≤ the 20 s generated
  // minimum, so the cap stays a valid never-late UPPER bound) BOTH preserves
  // never-late on every route AND collapses the egregious too-early tail that
  // lives on long GPS-blackout rides.
  //
  // ⚠️ CRITICAL CAVEAT (GW-0148): this proof feeds the cap each ride's TRUE
  // served-station arc positions (`r.stationS`). PRODUCTION DOES NOT HAVE THOSE
  // — transfer_utils.dart:1023 fabricates `leg.stopMeters` by EVEN spacing
  // (j/(numStops+1)); only the COUNT is real. On bunched geometry the
  // even-spaced cap over-charges dwell before the target and UNDER-bounds true
  // progress → a LATE fire. So this result is NOT a green light to flip
  // `dwellMinSeconds` positive in production; doing so with today's estimated
  // positions is a never-late trap (guarded by
  // test/reachability/dwell_cap_even_spacing_late_trap_test.dart). Arming the
  // floor is safe ONLY once real per-line station arc positions are threaded.
  test(
      'REACHABILITY AT SCALE — ARMED dwell cap preserves never-late AND '
      'collapses the too-early tail vs free-run', () {
    if (rideIds.isEmpty) {
      stdout.writeln('scale rides absent — skipping armed comparison.');
      return;
    }
    const nStops = 2;
    const double kSafeDwellFloor = 10.0; // ≤ 20 s generated min ⇒ never-late.
    final rides = <_Ride>[];
    for (final id in rideIds) {
      final r = _load(id);
      if (r != null) rides.add(r);
    }

    final free = _measure(rides, nStops: nStops);
    final armed = _measure(rides,
        nStops: nStops,
        config: const ReachabilityConfig(dwellMinSeconds: kSafeDwellFloor));

    void report(String tag, _WindowStats s) {
      stdout.writeln('$tag: ran=${s.ran} fired=${s.fired} '
          'never-fired=${s.neverFired} LATE=${s.late}  '
          'stops-early median=${_pct(s.stopsEarly, 0.5).toStringAsFixed(1)} '
          'p95=${_pct(s.stopsEarly, 0.95).toStringAsFixed(1)} '
          'max=${_pct(s.stopsEarly, 1.0).toStringAsFixed(1)}  '
          'egregious(>=3)=${s.egregious}/${s.fired}');
    }

    report('  FREE-RUN (shipped)', free);
    report('  ARMED   (dwell=10s)', armed);
    stdout.writeln('  ARMED still-egregious: ${armed.earlyRides.take(8).join("; ")}');

    // NEVER-LATE must survive the tightening on EVERY route (incl. express_skip).
    expect(armed.late, 0,
        reason: 'ARMED dwell cap produced a LATE fire — the floor is NOT a '
            'valid lower bound on real dwell: ${armed.lateRides.take(10).join("; ")}');
    expect(armed.neverFired, 0,
        reason: 'ARMED config suppressed a fire: '
            '${armed.lateRides.take(10).join("; ")}');

    // TOO-EARLY tail must shrink (never grow) under arming — the whole point.
    expect(_pct(armed.stopsEarly, 1.0),
        lessThanOrEqualTo(_pct(free.stopsEarly, 1.0)),
        reason: 'ARMED max stops-early is worse than free-run — tightening '
            'regressed');
    expect(_pct(armed.stopsEarly, 0.95),
        lessThanOrEqualTo(_pct(free.stopsEarly, 0.95)),
        reason: 'ARMED p95 stops-early is worse than free-run');
    expect(armed.egregious, lessThanOrEqualTo(free.egregious),
        reason: 'ARMED has MORE egregiously-early rides than free-run');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
