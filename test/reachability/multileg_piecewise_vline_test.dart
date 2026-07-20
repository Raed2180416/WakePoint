// test/reachability/multileg_piecewise_vline_test.dart
//
// P0-too-early regression: multi-leg mode-max inflated the CURRENT (slow) leg's
// blackout bound by the FASTEST downstream leg's V_LINE (e.g. RRTS 53 m/s on a
// slow metro leg), firing ~2x early. The fix integrates V_LINE PIECEWISE per leg
// (Reachability.bound(vLineSegments:...)) so the bound grows at the current
// leg's ceiling until the reachable position crosses that leg's end, only then
// adopting a faster downstream ceiling.
//
// These cases assert BOTH sides of the promise on a metro -> RRTS 2-leg ride:
//   * the metro-leg target no longer fires ~2x early (the flat-max regression),
//   * the bound is STILL never-late — it over-bounds any admissible true train
//     and, past the leg boundary, correctly adopts the faster RRTS ceiling.
//
// The scale oracle injects each ride's certified V_LINE as a scalar override and
// therefore cannot exercise the per-leg piecewise resolution — this file owns it.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

ReachabilityAnchor _a(double s, {double acc = 0.0, double t = 0.0}) =>
    ReachabilityAnchor(sMeters: s, accuracyMeters: acc, tSeconds: t);

// A metro leg [0, 3000) at 28 m/s feeding an RRTS leg [3000, 20000) at 53 m/s.
const double _metroV = VLineTable.defaultMps; // 28
const double _rrtsV = VLineTable.rrtsMps; // 53
final List<VLineSegment> _segments = <VLineSegment>[
  const VLineSegment(3000.0, _metroV),
  const VLineSegment(20000.0, _rrtsV),
];

double _piecewiseSMax(double sHi, double dt) => Reachability.bound(
      anchor: _a(sHi, t: 0.0),
      nowSeconds: dt,
      vLineMps: _rrtsV, // flat max = tail speed
      vLineSegments: _segments,
    ).sMaxMeters;

double _flatSMax(double sHi, double dt) => Reachability.bound(
      anchor: _a(sHi, t: 0.0),
      nowSeconds: dt,
      vLineMps: _rrtsV, // the OLD flat-max behaviour (no segments)
    ).sMaxMeters;

void main() {
  group('multi-leg piecewise V_LINE — metro leg with a downstream RRTS leg', () {
    const sHi = 1000.0; // last real fix, mid metro leg
    const target = 2500.0; // wake stop ON the metro leg

    test('does NOT fire ~2x early: at dt where the flat max already reached the '
        'metro-leg target, the piecewise bound is still short of it', () {
      // Flat max reaches 2500 at dt = (2500-1000)/53 = 28.3 s.
      // Piecewise (metro 28) reaches 2500 at dt = (2500-1000)/28 = 53.6 s.
      const dt = 30.0; // past the flat-max fire, before the true/piecewise fire

      final flat = _flatSMax(sHi, dt);
      final piece = _piecewiseSMax(sHi, dt);

      expect(flat, greaterThanOrEqualTo(target),
          reason: 'the OLD flat max fires here (the ~2x-early regression)');
      expect(piece, lessThan(target),
          reason: 'the fix must NOT fire here — still provably on the metro leg');
      // The bound grows at the metro ceiling, not the RRTS one.
      expect(piece, closeTo(sHi + _metroV * dt, 1e-6));
    });

    test('still fires (reaches the metro-leg target) once the metro-speed march '
        'gets there — ~53.6 s, i.e. ~1.9x later than the flat max', () {
      expect(_piecewiseSMax(sHi, 53.0), lessThan(target));
      expect(_piecewiseSMax(sHi, 55.0), greaterThanOrEqualTo(target));
    });

    test('NEVER-LATE: over-bounds any admissible metro train (real top speed '
        '<= 28) at every instant, so it fires no later than true arrival', () {
      const trueV = 25.0; // a real fast metro train, still <= the 28 ceiling
      double trueProgress(double t) => sHi + trueV * t;
      double trueArrival = (target - sHi) / trueV; // 60 s

      for (double t = 0; t <= 80; t += 0.5) {
        // The physics bound is an UPPER bound on true progress at all times.
        expect(_piecewiseSMax(sHi, t), greaterThanOrEqualTo(trueProgress(t)),
            reason: 'bound under true progress at t=$t => LATE fire');
      }
      // Fire (bound >= target) happens at ~53.6 s, strictly before arrival 60 s.
      final fireTime = (target - sHi) / _metroV; // 53.57 s
      expect(fireTime, lessThan(trueArrival));
      expect(_piecewiseSMax(sHi, fireTime + 0.1), greaterThanOrEqualTo(target));
    });

    test('piecewise is never looser than the flat max (cannot add early fire): '
        'sMax_piecewise <= sMax_flat for every dt', () {
      for (double dt = 0; dt <= 120; dt += 1.0) {
        expect(_piecewiseSMax(sHi, dt),
            lessThanOrEqualTo(_flatSMax(sHi, dt) + 1e-6));
      }
    });
  });

  group('multi-leg piecewise V_LINE — target on the FAST downstream leg', () {
    // Never-late in the OTHER direction: once the reachable position crosses the
    // metro/RRTS boundary the bound MUST adopt the RRTS ceiling, or a target on
    // the fast leg would fire late.
    const sHi = 2900.0; // near the end of the metro leg at the last real fix
    const target = 6000.0; // wake stop on the RRTS leg

    test('adopts the RRTS ceiling PAST the boundary — over-bounds a train that '
        'runs metro-then-RRTS, firing no later than its arrival', () {
      // Worst-case march: 2900->3000 at 28 (3.571 s), then 3000->6000 at 53.
      const tToBoundary = (3000.0 - sHi) / _metroV; // 3.571 s
      final fireTime = tToBoundary + (target - 3000.0) / _rrtsV; // ~60.16 s

      // A real train: metro 26 to the boundary, then RRTS 50 (both <= ceilings).
      const trueMetroV = 26.0, trueRrtsV = 50.0;
      final trueToBoundary = (3000.0 - sHi) / trueMetroV;
      final trueArrival = trueToBoundary + (target - 3000.0) / trueRrtsV;

      expect(fireTime, lessThan(trueArrival),
          reason: 'the bound must fire before the real train arrives');
      expect(_piecewiseSMax(sHi, fireTime + 0.1), greaterThanOrEqualTo(target));

      // And it over-bounds that true train at every instant.
      double trueProgress(double t) {
        if (t <= trueToBoundary) return sHi + trueMetroV * t;
        return 3000.0 + trueRrtsV * (t - trueToBoundary);
      }

      for (double t = 0; t <= 80; t += 0.5) {
        expect(_piecewiseSMax(sHi, t), greaterThanOrEqualTo(trueProgress(t)),
            reason: 'bound under true progress at t=$t => LATE fire');
      }
    });
  });
}
