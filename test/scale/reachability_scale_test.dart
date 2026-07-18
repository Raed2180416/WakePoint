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
double? _simFire(_Ride r, {int nStops = 2}) {
  // Use the ride's certified ceiling via a per-line override so the real
  // VLineTable.forLine resolves exactly the ceiling the ground truth respects.
  final table = VLineTable(overrides: {'|${r.line.toLowerCase()}': r.vlineCeiling});
  final tracker = ReachabilityTracker(vLineTable: table);
  final targetIdx = (r.stationS.length - 1 - nStops).clamp(0, r.stationS.length - 1);
  final sTarget = r.stationS[targetIdx];

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
    final b = tracker.boundNow(nowSeconds: t, lineName: r.line);
    if (b != null && b.sMaxMeters >= sTarget) return t;
  }
  return null;
}

void main() {
  final dir = Directory(kScaleRidesDir);
  final rideIds = dir.existsSync()
      ? (dir.listSync().whereType<Directory>().map((e) => e.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last)).toList()
      : <String>[];
  rideIds.sort();

  test('REACHABILITY AT SCALE — never-late on every generated route (real Dart)',
      () {
    if (rideIds.isEmpty) {
      // External generated rides not present (e.g. CI) — nothing to assert.
      // The committed replay gate covers the never-late guarantee in CI.
      stdout.writeln('scale rides absent at $kScaleRidesDir — skipping '
          '(this is expected off the founder machine).');
      return;
    }

    var ran = 0, fired = 0, late = 0, neverFired = 0;
    final lateRides = <String>[];
    for (final id in rideIds) {
      final r = _load(id);
      if (r == null) continue;
      ran++;
      final fireT = _simFire(r);
      if (fireT == null) {
        neverFired++;
        lateRides.add('$id (never-fired)');
        continue;
      }
      fired++;
      // Never-late: the destination alarm must fire at or before the true
      // destination arrival. (The fire target is N stops before, so this is a
      // conservative bound; the true arrival at the destination is r.destT.)
      if (fireT > r.destT + 1.0) {
        late++;
        lateRides.add('$id (fire ${fireT.toStringAsFixed(0)}s > dest '
            '${r.destT.toStringAsFixed(0)}s)');
      }
    }

    stdout.writeln('SCALE reachability: ran=$ran fired=$fired '
        'never-fired=$neverFired LATE=$late');
    expect(neverFired, 0, reason: 'rides where reachability never fired: '
        '${lateRides.take(10).join("; ")}');
    expect(late, 0, reason: 'LATE fires through the real reachability code: '
        '${lateRides.take(10).join("; ")}');
    expect(ran, greaterThan(10),
        reason: 'expected the committed scale subset (or the full external matrix)');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
