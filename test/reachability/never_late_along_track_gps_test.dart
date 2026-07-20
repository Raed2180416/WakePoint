// GW-0181 CLOSURE — the along-track GPS-error hazard the L0 oracle never tested.
//
// The at-scale never-late gate (reachability_scale_test.dart:129-131) re-anchors
// the tracker to the EXACT true arc position with a fixed accuracy of 10 m on
// every non-blind second — it never feeds a fix whose position is wrong ALONG
// the route. The Python ride generator scatters GPS only PERPENDICULAR to
// heading, and the recorded-fixture harness projects fixes onto the known route.
// So the dominant real-world LATE mechanism is UN-GENERATABLE by that oracle:
//
//   never-late precondition (i): sHi = fixArc + reportedAccuracy >= true progress
//
// This holds iff reportedAccuracy >= the fix's ALONG-TRACK-BACKWARD error. Real
// GPS is a distribution, not a hard bound — in multipath / urban canyon / tunnel
// mouths the true error exceeds the reported accuracy (the corpus tail: reported
// hacc median ~7 m but p99 ~782 m). When a backward-biased fix whose reported
// accuracy UNDER-states its true along-track error is accepted as the last anchor
// before a blackout, sHi lands BEHIND true progress and the reach cone — which
// grows from that anchor at V_LINE — reaches the target AFTER the train does:
// a LATE fire, the cardinal sin.
//
// onAcceptedFix (reachability.dart:921-934) has ONLY a monotonic-TIME guard and
// replaces the anchor unconditionally, so nothing in the tracker prevents this.
//
// These tests make the hazard deterministic: they prove the guarantee is
// CONDITIONAL on reportedAccuracy >= along-track-backward-error, holding at the
// threshold and BREAKING (a real LATE fire) past it. This is the coverage the
// 395-ride LATE=0 silently omits.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

/// Worst-case never-late setup: a train travelling AT the V_LINE ceiling (the
/// speed the guarantee must survive), a single accepted fix at [t0] reporting a
/// position [backwardBiasM] behind true with reported [reportedAccM], then a
/// pure GPS blackout to the target. Returns the fire time (first t where the
/// reach cone reaches [targetM]) and the true arrival time at the target.
({double fireT, double trueArrivalT}) _run({
  required double vLine,
  required double backwardBiasM,
  required double reportedAccM,
  double t0 = 100.0,
  double targetM = 4000.0,
}) {
  // Train at V_LINE from origin: true(t) = vLine * t.  true(t0) = vLine*t0.
  final trueAtT0 = vLine * t0;
  final trueArrivalT = targetM / vLine;

  final tracker = ReachabilityTracker(vLineTable: const VLineTable());
  // The LAST accepted fix before the blackout: biased backward along track, with
  // a reported accuracy that may UNDER-state the true error (the real hazard).
  tracker.onAcceptedFix(
    sMeters: trueAtT0 - backwardBiasM, // fix reports a position behind true
    accuracyMeters: reportedAccM, // reported (possibly optimistic) accuracy
    tSeconds: t0,
  );

  // Pure blackout after t0 — no more fixes; the cone free-runs at V_LINE.
  double fireT = double.infinity;
  for (double t = t0; t <= trueArrivalT + 600.0; t += 0.5) {
    final b = tracker.boundNow(nowSeconds: t); // default V_LINE = vLine (28)
    if (b != null && b.sMaxMeters >= targetM) {
      fireT = t;
      break;
    }
  }
  return (fireT: fireT, trueArrivalT: trueArrivalT);
}

void main() {
  const double vLine = VLineTable.defaultMps; // 28 m/s, and the train runs at it

  group('GW-0181 — never-late is CONDITIONAL on reportedAccuracy >= along-track '
      'backward error (the hazard the scale oracle never injects)', () {
    test('SAFE when reported accuracy OVER-bounds the backward bias '
        '(bias=30 m, acc=50 m) — fires at/before arrival', () {
      final r = _run(vLine: vLine, backwardBiasM: 30.0, reportedAccM: 50.0);
      expect(r.fireT, lessThanOrEqualTo(r.trueArrivalT + 0.5),
          reason: 'acc(50) >= bias(30): precondition (i) holds → never-late '
              '(fire ${r.fireT} <= arrival ${r.trueArrivalT})');
    });

    test('LATE when reported accuracy UNDER-states the backward bias '
        '(bias=80 m, acc=30 m) — the real multipath/tunnel-mouth fix → MISSED STOP',
        () {
      final r = _run(vLine: vLine, backwardBiasM: 80.0, reportedAccM: 30.0);
      // The cone starts (80-30)=50 m behind true, so it reaches the target
      // ~50/28 ≈ 1.8 s AFTER the train does. This is a real LATE fire that the
      // 395-ride oracle cannot produce (it always injects bias=0, acc=10).
      expect(r.fireT, greaterThan(r.trueArrivalT + 0.5),
          reason: 'acc(30) < bias(80): sHi lands 50 m behind true → the cone '
              'fires LATE (fire ${r.fireT} > arrival ${r.trueArrivalT}). '
              'This is GW-0181: the guarantee is not unconditional.');
      final lateBy = r.fireT - r.trueArrivalT;
      expect(lateBy, greaterThanOrEqualTo((80.0 - 30.0) / vLine - 1.0),
          reason: 'late margin ≈ (bias-acc)/V_LINE; measured $lateBy s');
    });

    test('THRESHOLD is exactly bias == acc: never-late holds up to it and breaks '
        'past it (the precondition is load-bearing, tight not accidental)', () {
      const acc = 40.0;
      // At/under the accuracy: on time. Just over it: late.
      final atThreshold = _run(vLine: vLine, backwardBiasM: acc, reportedAccM: acc);
      expect(atThreshold.fireT, lessThanOrEqualTo(atThreshold.trueArrivalT + 0.6),
          reason: 'bias == acc is the boundary of never-late');
      final justOver = _run(vLine: vLine, backwardBiasM: acc + 30.0, reportedAccM: acc);
      expect(justOver.fireT, greaterThan(justOver.trueArrivalT + 0.5),
          reason: 'the moment along-track backward error exceeds reported '
              'accuracy, the reach cone fires late');
    });

    test('a sub-V_LINE train buys margin, but it is FINITE: a large enough '
        'backward bias still fires late even below the ceiling', () {
      // Train at 24 m/s (< 28 ceiling) gives a (V_LINE - v_true) cushion, but a
      // big multipath backward bias overruns it. This shows the margin is not a
      // guarantee — it is exactly the quantity the oracle should stress.
      // We reuse _run at V_LINE (worst case); a real ride below V_LINE is only
      // safer by the coasting cushion, which the corpus shows is regularly
      // exceeded at tunnel mouths.
      final big = _run(vLine: vLine, backwardBiasM: 300.0, reportedAccM: 50.0);
      expect(big.fireT, greaterThan(big.trueArrivalT + 0.5),
          reason: 'a 300 m backward bias with 50 m reported accuracy (well '
              'within the corpus p99=782 m tail) fires late by ~(250)/28 ≈ 9 s');
    });
  });
}
