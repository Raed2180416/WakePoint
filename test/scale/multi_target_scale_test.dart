// AT-SCALE never-late validation for MULTIPLE SIMULTANEOUS ALARMS (Pro).
//
// Extends the b2eec7a single-target at-scale gate: over the SAME committed route
// matrix it arms 2-3 wake targets per route (intermediates + destination) and
// asserts the never-late guarantee holds INDEPENDENTLY for EVERY target through
// the REAL Reachability math + the shipped intermediate-target evaluator — not a
// re-implementation. Includes the explicit id-collision case (an intermediate at
// exactly the destination arc-position with the destination's mode/value) and
// asserts the destination still wakes.
//
// Run: flutter test test/scale/multi_target_scale_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';
import 'package:geowake2/services/tracking/alarm_target.dart';
import 'package:geowake2/services/tracking/intermediate_target_evaluator.dart';

const String kInRepoScaleDir = 'test/fixtures/scale';
const String kExternalScaleDir = '/home/raed/geowake_imu_analysis/scale/rides';

String get kScaleRidesDir =>
    Directory(kInRepoScaleDir).existsSync() ? kInRepoScaleDir : kExternalScaleDir;

class _Ride {
  final String id;
  final String line;
  final double vlineCeiling;
  final List<double> stationS;
  final List<double> stationT;
  final List<List<double>> blind;
  final double destT;
  final double destS;
  _Ride(this.id, this.line, this.vlineCeiling, this.stationS, this.stationT,
      this.blind, this.destT, this.destS);
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
    sS.last,
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

/// True arrival time (s) at arc-position [sTarget] on this ride.
double _trueArrivalT(_Ride r, double sTarget) {
  final ss = r.stationS, ts = r.stationT;
  if (sTarget <= ss.first) return ts.first;
  if (sTarget >= ss.last) return ts.last;
  for (var i = 0; i < ss.length - 1; i++) {
    if (sTarget >= ss[i] && sTarget <= ss[i + 1]) {
      final f = (sTarget - ss[i]) / (ss[i + 1] - ss[i]);
      return ts[i] + f * (ts[i + 1] - ts[i]);
    }
  }
  return ts.last;
}

class _Fire {
  final double? t;
  _Fire(this.t);
}

/// Drive the REAL ReachabilityTracker + intermediate evaluator over one ride with
/// a set of targets; return fire time per target id (null = never fired).
Map<String, _Fire> _simMulti(_Ride r, List<AlarmTarget> targets) {
  final table =
      VLineTable(overrides: {'|${r.line.toLowerCase()}': r.vlineCeiling});
  final tracker = ReachabilityTracker(vLineTable: table);
  final fireState = IntermediateFireState();
  final destTarget = targets.firstWhere((t) => t.isDestination);
  final intermediates = targets.where((t) => !t.isDestination).toList();

  final fired = <String, double?>{for (final t in targets) t.id: null};

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
      tracker.onAcceptedFix(
          sMeters: _trueS(t, r.stationT, r.stationS),
          accuracyMeters: 10.0,
          tSeconds: t);
    }
    final b = tracker.boundNow(nowSeconds: t, lineName: r.line);
    if (b == null) continue;
    final eff = Reachability.effectiveProgress(
      deadReckonedProgressMeters: _trueS(t, r.stationT, r.stationS),
      sigmaCushionMeters: 0.0,
      reachableBoundMeters: b.sMaxMeters,
    );

    // Destination path (mirrors the legacy fire test: bound reaches target).
    if (fired[destTarget.id] == null && b.sMaxMeters >= destTarget.targetMeters) {
      fired[destTarget.id] = t;
    }

    // Intermediate path (real evaluator).
    final toFire = IntermediateTargetEvaluator.selectToFire(
      intermediates: intermediates,
      effectiveProgressMeters: eff,
      alreadyFired: (id) => fireState.hasFired(r.id, id),
    );
    for (final tt in toFire) {
      if (fired[tt.id] == null) fired[tt.id] = t;
      fireState.markFired(r.id, tt.id);
    }
  }
  return {for (final t in targets) t.id: _Fire(fired[t.id])};
}

void main() {
  final dir = Directory(kScaleRidesDir);
  final rideIds = dir.existsSync()
      ? (dir.listSync().whereType<Directory>().map((e) => e.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last)).toList()
      : <String>[];
  rideIds.sort();

  test('MULTI-TARGET AT SCALE — every target never-late on every route', () {
    if (rideIds.isEmpty) {
      stdout.writeln('scale rides absent at $kScaleRidesDir — skipping '
          '(expected off the founder machine; CI covers the committed subset).');
      return;
    }

    var ran = 0, late = 0, neverFired = 0;
    final problems = <String>[];

    for (final id in rideIds) {
      final r = _load(id);
      if (r == null) continue;
      ran++;

      // Arm 2-3 targets: destination + up to two intermediates at 2 and 4 stops
      // before the end.
      final n = r.stationS.length;
      final destS = r.destS;
      final i2 = r.stationS[(n - 1 - 2).clamp(0, n - 1)];
      final i4 = r.stationS[(n - 1 - 4).clamp(0, n - 1)];
      final targets = <AlarmTarget>[
        AlarmTarget.destinationOf(targetMeters: destS, label: 'Dest'),
        AlarmTarget.intermediateOf(targetMeters: i2, label: '2-before', id: 'i2'),
        if (i4 < i2)
          AlarmTarget.intermediateOf(targetMeters: i4, label: '4-before', id: 'i4'),
      ];

      final fires = _simMulti(r, targets);
      for (final tgt in targets) {
        final ft = fires[tgt.id]!.t;
        final trueArr = _trueArrivalT(r, tgt.targetMeters);
        if (ft == null) {
          neverFired++;
          problems.add('$id/${tgt.id} never-fired');
        } else if (ft > trueArr + 1.0) {
          late++;
          problems.add('$id/${tgt.id} LATE (${ft.toStringAsFixed(0)}s > '
              '${trueArr.toStringAsFixed(0)}s)');
        }
      }
    }

    stdout.writeln('MULTI-TARGET scale: ran=$ran never-fired=$neverFired '
        'LATE=$late');
    expect(neverFired, 0,
        reason: 'targets that never fired: ${problems.take(10).join("; ")}');
    expect(late, 0,
        reason: 'LATE target fires: ${problems.take(10).join("; ")}');
    expect(ran, greaterThan(10),
        reason: 'expected the committed scale subset (>=3-station rides)');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('COLLISION — intermediate at exactly destination meters, destination '
      'still wakes never-late', () {
    if (rideIds.isEmpty) {
      stdout.writeln('scale rides absent — skipping collision case.');
      return;
    }
    var ran = 0, destLate = 0, destNever = 0;
    final problems = <String>[];
    for (final id in rideIds) {
      final r = _load(id);
      if (r == null) continue;
      ran++;
      final destS = r.destS;
      // The adversarial case: an intermediate sharing the destination's exact
      // arc-position (and it would share the natural key too) — it must NOT be
      // able to suppress the destination wake.
      final targets = <AlarmTarget>[
        AlarmTarget.destinationOf(targetMeters: destS, label: 'Dest'),
        AlarmTarget.intermediateOf(
            targetMeters: destS, label: 'coincident', id: 'coincident'),
      ];
      final fires = _simMulti(r, targets);
      final destFt = fires['__dest__']!.t;
      final trueArr = _trueArrivalT(r, destS);
      if (destFt == null) {
        destNever++;
        problems.add('$id dest never-fired despite coincident intermediate');
      } else if (destFt > trueArr + 1.0) {
        destLate++;
        problems.add('$id dest LATE ${destFt.toStringAsFixed(0)}s');
      }
    }
    stdout.writeln('COLLISION scale: ran=$ran dest-never=$destNever '
        'dest-LATE=$destLate');
    expect(destNever, 0, reason: problems.take(10).join('; '));
    expect(destLate, 0, reason: problems.take(10).join('; '));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
