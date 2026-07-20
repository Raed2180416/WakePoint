// GUARD TEST for GW-0148 — the dwell-cap even-spacing LATE trap.
//
// The at-scale ARMED comparison (test/scale/reachability_scale_test.dart) shows
// that arming the topology dwell cap (config.dwellMinSeconds = 10 s) keeps
// never-late AND cuts the too-early tail -36%. That proof feeds the cap the
// ride's TRUE served-station arc positions. PRODUCTION DOES NOT HAVE THOSE: the
// stop positions handed to the cap are FABRICATED by even spacing —
// transfer_utils.dart:1023 places the j-th of n intermediate stops at
// fraction j/(n+1) of the leg polyline; only the COUNT comes from Google. On a
// line whose real stops are NOT evenly spaced (bunched near one end — common on
// suburban/express-then-local runs), the even-spaced model charges MORE dwell
// before the target arc than the real train pays, so the capped worst-case
// progress UNDER-bounds true progress => a physics LATE fire in stops mode.
//
// This test locks that in: with a positive dwell floor, the even-spaced cap
// fires STRICTLY LATER than the true-position cap on bunched geometry — and
// since a real train's dwells occur at the TRUE stations, the true-position cap
// is the tight-but-valid never-late bound, so firing later than it = firing
// after the train could already be at the stop = LATE. It also pins the current
// production posture as SAFE: with dwellMinSeconds = 0 (what alarm_controller
// ships) the cap is inert and both geometries reduce to the identical free-run
// fire, so the trap only springs if someone flips the floor positive without
// first threading true station positions.
//
// If this test ever fails because the two fire times converged, it means real
// station positions are now threaded (or even-spacing was removed) — at which
// point arming the floor becomes safe and this guard should be revisited.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

/// First time (s) at which the topology-capped worst-case progress reaches
/// [targetMeters], for an anchor frozen at the leg origin (pure blackout).
double _capFireTime({
  required List<double> stationMeters,
  required double dwellMinSeconds,
  required double targetMeters,
  double vLineMps = VLineTable.defaultMps,
  double tEnd = 2000.0,
}) {
  const anchor =
      ReachabilityAnchor(sMeters: 0.0, accuracyMeters: 0.0, tSeconds: 0.0);
  final topo = RouteTopology(stationMeters: stationMeters, dwellMinSeconds: 0.0);
  final cfg = ReachabilityConfig(dwellMinSeconds: dwellMinSeconds);
  for (double t = 0.0; t <= tEnd; t += 0.5) {
    final b = Reachability.bound(
      anchor: anchor,
      nowSeconds: t,
      vLineMps: vLineMps,
      topology: topo,
      config: cfg,
    );
    if (b.sMaxMeters >= targetMeters) return t;
  }
  return double.infinity;
}

void main() {
  // A 10 km leg with 5 intermediate stops BUNCHED near the end (a long express
  // outer run then closely-spaced inner stops — realistic for suburban lines).
  const double legLen = 10000.0;
  const int numStops = 5;
  const double target = 8000.0; // a true served stop
  const double dwellFloor = 10.0; // the "proven" tail-cut floor

  // TRUE served positions (what the never-late proof assumes it has).
  final trueStops = <double>[6000, 7000, 8000, 9000, 9500];
  // PRODUCTION even-spacing (transfer_utils.dart:1023): j/(numStops+1) * legLen.
  final evenStops = <double>[
    for (int j = 1; j <= numStops; j++) (j / (numStops + 1)) * legLen,
  ];

  test('production even-spacing places stops uniformly, NOT at the bunched true '
      'positions (the root of the trap)', () {
    // Sanity: the two geometries genuinely disagree, and before the target the
    // even-spaced model has MORE stops than reality (=> charges more dwell).
    expect(evenStops, [1666.67, 3333.33, 5000.0, 6666.67, 8333.33]
        .map((e) => closeTo(e, 0.5)));
    final trueBeforeTarget = trueStops.where((s) => s < target).length; // 2
    final evenBeforeTarget = evenStops.where((s) => s < target).length; // 4
    expect(trueBeforeTarget, 2);
    expect(evenBeforeTarget, 4);
    expect(evenBeforeTarget, greaterThan(trueBeforeTarget),
        reason: 'even-spacing over-counts pre-target stops on bunched geometry');
  });

  test('with dwellMinSeconds = 0 (production default) the cap is INERT: both '
      'geometries give the identical free-run fire (production is SAFE today)',
      () {
    final evenFire = _capFireTime(
        stationMeters: evenStops, dwellMinSeconds: 0.0, targetMeters: target);
    final trueFire = _capFireTime(
        stationMeters: trueStops, dwellMinSeconds: 0.0, targetMeters: target);
    final freeRun = target / VLineTable.defaultMps; // 8000/28 = 285.7 s
    expect(evenFire, closeTo(trueFire, 0.5));
    expect(evenFire, closeTo(freeRun, 1.0),
        reason: 'dwellMin=0 => topology cap degrades to free-run; the shipped '
            'alarm_controller value keeps the bound unconditionally safe');
  });

  test('LATE TRAP: with a positive dwell floor, even-spacing fires STRICTLY '
      'LATER than the true-position bound on bunched geometry => can miss the '
      'stop (why dwellMinSeconds must stay 0 until true positions are threaded)',
      () {
    final trueFire = _capFireTime(
        stationMeters: trueStops,
        dwellMinSeconds: dwellFloor,
        targetMeters: target);
    final evenFire = _capFireTime(
        stationMeters: evenStops,
        dwellMinSeconds: dwellFloor,
        targetMeters: target);

    // The true-position cap is the tight-but-valid never-late bound: it charges
    // dwell exactly where the real train dwells (2 stops before the target), so
    // a real train reaches the target no earlier than trueFire.
    // The even-spaced cap charges 4 dwells before the target (2 phantom extra),
    // so it insists s_max is still short of the target for ~2*dwellFloor longer.
    expect(evenFire, greaterThan(trueFire + dwellFloor),
        reason: 'even-spacing must delay the fire by ~ the extra phantom dwell '
            '(true=$trueFire s, even=$evenFire s) — firing after the real '
            'train reaches the stop is a LATE fire');

    // Quantify the never-late violation the wiring would introduce.
    final lateBy = evenFire - trueFire;
    expect(lateBy, greaterThanOrEqualTo(2 * dwellFloor - 1.0),
        reason: 'the two phantom pre-target dwells (${2 * dwellFloor}s) are the '
            'late margin even-spacing would inject; measured $lateBy s');
  });
}
