// AT-SCALE never-late validation for MULTIPLE SIMULTANEOUS WAKE TARGETS.
//
// The single-target companion (test/scale/reachability_scale_test.dart) proves
// never-late for ONE "wake 2 stops before destination" alarm across the whole
// generated route matrix. This test extends that guarantee to the MULTI-TARGET
// case a Pro user arms in practice: several wake points on the SAME ride, each at
// a different stop offset before the destination (N ∈ {0,1,2,3,4}). Every target
// is driven INDEPENDENTLY through the REAL production math — the same shipped
// ReachabilityTracker + VLineTable + Reachability.bound the single-target gate
// uses — not a re-implementation.
//
// A target N stops before the end is never-late iff its alarm fires at or before
// the ground-truth arrival time at that stop. We assert this for EVERY (ride, N)
// pair, so one late fire on any offset on any route fails the gate.
//
// NOTE: an earlier revision of this test imported a planned
// AlarmTarget/IntermediateTargetEvaluator layer that was never landed; those
// symbols do not exist in lib/. This restored version drives the multi-target
// guarantee purely through the shipped reachability primitives — each offset is a
// distinct arc-position target evaluated by the same bound-reaches-target rule as
// production, which is exactly what "wake N stops before" means at the engine.
//
// The rides live outside the repo (large, generated) and the committed subset
// lives under test/fixtures/scale. The test SKIPS cleanly when both are absent
// (CI without the fixtures), and runs when present.
//
// Run: flutter test test/scale/multi_target_scale_test.dart

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
  // Need at least 3 stations so multiple distinct stop-offsets exist.
  if (sS.length < 3) return null;
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

/// True arc-position (m) at wall-clock [t] given the station time/space samples.
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

/// The wake targets for one ride: each entry is a stop-offset N before the
/// destination, its arc-position, and the ground-truth arrival time there.
class _Target {
  final int nStops;
  final double sMeters;
  final double trueArrivalT;
  _Target(this.nStops, this.sMeters, this.trueArrivalT);
}

/// Build the distinct multi-target set for a ride: destination (N=0) plus every
/// requested earlier offset that maps to a real, strictly-earlier station.
List<_Target> _targetsFor(_Ride r, List<int> offsets) {
  final n = r.stationS.length;
  final out = <_Target>[];
  final seenIdx = <int>{};
  for (final nStops in offsets) {
    final idx = n - 1 - nStops;
    if (idx < 0) continue; // offset larger than this (short) ride — skip.
    if (!seenIdx.add(idx)) continue; // clamped duplicate — keep targets distinct.
    out.add(_Target(nStops, r.stationS[idx], r.stationT[idx]));
  }
  return out;
}

/// Drive the REAL ReachabilityTracker once over one ride and return the fire time
/// for EACH target (the first moment the shipped bound reaches that target's
/// arc-position), or null for a target that never fired.
///
/// One pass serves every target: the tracker state is identical regardless of how
/// many wake points are armed, so the offsets are genuinely simultaneous — the
/// exact multi-alarm scenario. The fire rule (bound.sMaxMeters >= target) mirrors
/// production and the single-target scale gate.
Map<int, double?> _simMulti(_Ride r, List<_Target> targets) {
  // Use the ride's certified ceiling via a per-line override so VLineTable.forLine
  // resolves exactly the ceiling the ground truth respects.
  final table =
      VLineTable(overrides: {'|${r.line.toLowerCase()}': r.vlineCeiling});
  final tracker = ReachabilityTracker(vLineTable: table);

  final fired = <int, double?>{for (final t in targets) t.nStops: null};
  var remaining = targets.length;

  bool inBlind(double t) {
    for (final w in r.blind) {
      if (t >= w[0] && t <= w[1]) return true;
    }
    return false;
  }

  tracker.seedColdStart(tSeconds: 0.0, sMeters: r.stationS.first);
  final tEnd = r.destT + 120;
  for (double t = 0.0; t <= tEnd && remaining > 0; t += 1.0) {
    if (!inBlind(t)) {
      // GPS live: re-anchor to the true position, forward-overbounded by a
      // typical accuracy (mirrors production onAcceptedFix on a real fix).
      tracker.onAcceptedFix(
          sMeters: _trueS(t, r.stationT, r.stationS),
          accuracyMeters: 10.0,
          tSeconds: t);
    }
    final b = tracker.boundNow(nowSeconds: t, lineName: r.line);
    if (b == null) continue;
    for (final tgt in targets) {
      if (fired[tgt.nStops] == null && b.sMaxMeters >= tgt.sMeters) {
        fired[tgt.nStops] = t;
        remaining--;
      }
    }
  }
  return fired;
}

void main() {
  final dir = Directory(kScaleRidesDir);
  final rideIds = dir.existsSync()
      ? (dir.listSync().whereType<Directory>().map((e) => e.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last)).toList()
      : <String>[];
  rideIds.sort();

  // Offsets armed on every ride: destination + 1/2/3/4 stops before. Short rides
  // drop the offsets that don't map to a real earlier station (see _targetsFor).
  const List<int> kOffsets = [0, 1, 2, 3, 4];

  test(
      'MULTI-TARGET AT SCALE — every wake offset never-late on every generated '
      'route (real Dart)', () {
    if (rideIds.isEmpty) {
      // Scale rides not present (e.g. CI) — nothing to assert. The committed
      // replay + single-target gates cover the never-late guarantee in CI.
      stdout.writeln('scale rides absent at $kScaleRidesDir — skipping '
          '(this is expected off the founder machine).');
      return;
    }

    var rides = 0;
    var targetsRan = 0, neverFired = 0, late = 0;
    final problems = <String>[];
    // Per-offset tally so the log shows coverage across N, not just a total.
    final ranByN = <int, int>{};

    for (final id in rideIds) {
      final r = _load(id);
      if (r == null) continue;
      rides++;

      final targets = _targetsFor(r, kOffsets);
      final fires = _simMulti(r, targets);

      for (final tgt in targets) {
        targetsRan++;
        ranByN[tgt.nStops] = (ranByN[tgt.nStops] ?? 0) + 1;
        final fireT = fires[tgt.nStops];
        if (fireT == null) {
          neverFired++;
          problems.add('$id/N=${tgt.nStops} never-fired');
          continue;
        }
        // NEVER-LATE (hard): fire at or before the true arrival at this target.
        if (fireT > tgt.trueArrivalT + 1.0) {
          late++;
          problems.add('$id/N=${tgt.nStops} LATE '
              '(fire ${fireT.toStringAsFixed(0)}s > arrival '
              '${tgt.trueArrivalT.toStringAsFixed(0)}s)');
        }
      }
    }

    final coverage = (ranByN.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => 'N=${e.key}:${e.value}')
        .join(' ');
    stdout.writeln('MULTI-TARGET scale: rides=$rides targets=$targetsRan '
        'never-fired=$neverFired LATE=$late');
    stdout.writeln('  per-offset coverage: $coverage');

    // NEVER-LATE — hard gates. A late (or missing) fire on ANY armed offset on
    // ANY route is the one unforgivable bug.
    expect(neverFired, 0,
        reason: 'targets that never fired: ${problems.take(10).join("; ")}');
    expect(late, 0,
        reason: 'LATE fires through the real reachability code: '
            '${problems.take(10).join("; ")}');
    expect(targetsRan, greaterThan(10),
        reason: 'expected the committed scale subset (>=3-station rides) to '
            'yield many (ride,offset) targets');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
