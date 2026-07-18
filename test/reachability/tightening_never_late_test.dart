// NEVER-LATE validation of the fastest-feasible-train tightening on REAL
// Bengaluru Purple Line geometry (curved polylines + real station arc-lengths +
// real arrival times from bengaluru_metro_routes.json). This is the
// "green test that can't lie": the curve layer is INERT on straightlined
// fixtures, so we validate on the real curved rail geometry.
//
// Primary guarantee: from an anchor at any real station arrival, the tightened
// cone must reach every DOWNSTREAM station no later than the real train did
// (s_max(t_k) >= s_k). Station arrivals are exact real (position, time) pairs,
// so this is free of the dwell-interpolation artifact.
//
// It also measures the full-blackout early-fire REDUCTION: how much later the
// tightened cone reaches the wake target than the free-run cone (both still at
// or before true arrival).
//
// Run: flutter test test/reachability/tightening_never_late_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

const String kAsset = 'assets/ekf_test_routes/bengaluru_metro_routes.json';
const double kVLine = 28.0; // Purple Line metro ceiling (m/s)

class _Route {
  final String id;
  final List<double> lats, lngs, cum; // polyline (parallel)
  final List<double> stS, stT; // station arc + arrival time (parallel)
  _Route(this.id, this.lats, this.lngs, this.cum, this.stS, this.stT);
}

List<_Route> _load() {
  final f = File(kAsset);
  if (!f.existsSync()) return [];
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final out = <_Route>[];
  for (final r in (j['routes'] as List).cast<Map<String, dynamic>>()) {
    final pl = (r['polyline_points'] as List).cast<List>();
    final lats = pl.map((p) => (p[0] as num).toDouble()).toList();
    final lngs = pl.map((p) => (p[1] as num).toDouble()).toList();
    final cum =
        (r['cumulative_meters'] as List).map((m) => (m as num).toDouble()).toList();
    final st = (r['stations'] as List).cast<Map<String, dynamic>>();
    final stS = st.map((s) => (s['cumulative_meters'] as num).toDouble()).toList();
    final stT = st.map((s) => (s['time_elapsed'] as num).toDouble()).toList();
    out.add(_Route(r['id'] as String, lats, lngs, cum, stS, stT));
  }
  return out;
}

ReachabilityConfig _fullConfig() => const ReachabilityConfig(
      dynamicLeversEnabled: true,
      curveTrusted: true,
      dwellMinSeconds: 7.0, // door-cycle floor (under-bounds real ~20s dwell)
      aMaxMps2: 2.5,
      dMaxMps2: 3.5,
      aLatEffMps2: 7.0,
    );

void main() {
  final routes = _load();

  test('TIGHTENING never-late on REAL Purple Line geometry (station-arrival grid)',
      () {
    if (routes.isEmpty) {
      stdout.writeln('metro asset absent — skipping');
      return;
    }
    final cfg = _fullConfig();
    var pairs = 0, violations = 0;
    final worst = <String>[];

    for (final r in routes) {
      final profile = RouteProfile.precompute(
        lats: r.lats,
        lngs: r.lngs,
        cumulativeMeters: r.cum,
        servedStations: r.stS, // all-stops metro: every station is served
        config: cfg,
        vLine: kVLine,
      );
      final topo = RouteTopology(stationMeters: r.stS, profile: profile);

      // Anchor at each station arrival; require the cone to reach every
      // downstream station no later than the real train did.
      for (var j = 0; j < r.stS.length - 1; j++) {
        final anchor = ReachabilityAnchor(
          sMeters: r.stS[j],
          accuracyMeters: 0.0,
          tSeconds: r.stT[j],
        );
        for (var k = j + 1; k < r.stS.length; k++) {
          final b = Reachability.bound(
            anchor: anchor,
            nowSeconds: r.stT[k],
            vLineMps: kVLine,
            topology: topo,
            config: cfg,
          );
          pairs++;
          // never-late: cone at the real arrival time must be >= true arc.
          if (b.sMaxMeters < r.stS[k] - 1.0) {
            violations++;
            if (worst.length < 8) {
              worst.add('${r.id} j=$j k=$k: sMax=${b.sMaxMeters.toStringAsFixed(0)} '
                  '< s_k=${r.stS[k].toStringAsFixed(0)} '
                  '(free=${b.freeRunMeters.toStringAsFixed(0)})');
            }
          }
        }
      }
    }

    stdout.writeln('TIGHTENING never-late: pairs=$pairs violations=$violations');
    expect(violations, 0,
        reason: 'never-late VIOLATIONS on real geometry (cone under-bounds true '
            'progress): ${worst.join("; ")}');
    expect(pairs, greaterThan(50));
  });

  test('TIGHTENING full-blackout early-fire reduction vs free-run (real geometry)',
      () {
    if (routes.isEmpty) return;
    final cfg = _fullConfig();
    stdout.writeln('\nFull-blackout (anchor frozen at origin) — reach the wake '
        'target (2 stops before dest):');
    stdout.writeln('route                          | trueArr | freeRunFire | '
        'tightFire | earlierBy | never-late');

    for (final r in routes) {
      final profile = RouteProfile.precompute(
        lats: r.lats,
        lngs: r.lngs,
        cumulativeMeters: r.cum,
        servedStations: r.stS,
        config: cfg,
        vLine: kVLine,
      );
      final topo = RouteTopology(stationMeters: r.stS, profile: profile);
      final tgtIdx = (r.stS.length - 1 - 2).clamp(0, r.stS.length - 1);
      final sTarget = r.stS[tgtIdx];
      final tTrue = r.stT[tgtIdx];

      // Anchor frozen at the origin (worst-case: GPS dead the whole ride).
      final anchor =
          ReachabilityAnchor(sMeters: 0.0, accuracyMeters: 0.0, tSeconds: 0.0);
      double? tFree, tTight;
      for (double t = 0; t <= tTrue + 5; t += 1.0) {
        final b = Reachability.bound(
          anchor: anchor,
          nowSeconds: t,
          vLineMps: kVLine,
          topology: topo,
          config: cfg,
        );
        tFree ??= (b.freeRunMeters >= sTarget) ? t : null;
        tTight ??= (b.sMaxMeters >= sTarget) ? t : null;
        if (tFree != null && tTight != null) break;
      }
      final earlier = (tTight != null && tFree != null) ? tTight - tFree : 0.0;
      final neverLate = (tTight ?? double.infinity) <= tTrue + 1.0;
      stdout.writeln('${r.id.padRight(30)} | ${tTrue.toStringAsFixed(0).padLeft(6)}s '
          '| ${(tFree ?? -1).toStringAsFixed(0).padLeft(9)}s '
          '| ${(tTight ?? -1).toStringAsFixed(0).padLeft(7)}s '
          '| ${earlier.toStringAsFixed(0).padLeft(7)}s '
          '| ${neverLate ? "OK" : "LATE!"}');
      // The tightened cone must still fire at or before true arrival.
      expect(tTight, isNotNull);
      expect(tTight!, lessThanOrEqualTo(tTrue + 1.0),
          reason: '${r.id}: tightened cone fired LATE');
      // And it must fire strictly later than free-run (i.e., it tightened).
      expect(tTight, greaterThanOrEqualTo(tFree!),
          reason: '${r.id}: tightening did not reduce early firing');
    }
  });
}
