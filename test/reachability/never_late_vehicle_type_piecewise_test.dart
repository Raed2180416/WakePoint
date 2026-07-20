// Deterministic never-late coverage for two holes the at-scale oracle
// (test/scale/reachability_scale_test.dart) STRUCTURALLY CANNOT catch, because
// that oracle injects each ride's certified V_LINE ceiling as a per-line
// override (so `forLine` returns the override before any keyword/vehicle logic
// runs, and every ride is single-leg). These two classes are the real residual
// late-risk in the shipped engine, so they get their own metamorphic proofs:
//
//   A. V_LINE NAME-COLLISION → vehicle-type floor (GW-0076). A fast service
//      reported with a generic, non-keyword name ("Orange Line" for the Delhi
//      Airport Express; "Western Line" for Mumbai Suburban) resolves to the
//      metro default (28 m/s) and UNDER-bounds a train that truly runs ~39 m/s
//      → a LATE fire during a GPS blackout. The Google Directions vehicle.type
//      (HEAVY_RAIL/COMMUTER) closes it name-free. We prove: (i) the resolver
//      lifts the ceiling, (ii) the lift is monotone (never lowers), and (iii)
//      end-to-end the un-lifted bound fires LATE while the lifted bound does not.
//
//   B. PIECEWISE MULTI-LEG V_LINE (P0-03). A slow metro leg feeding a fast RRTS
//      leg has a position-dependent ceiling. Flat-max V_LINE over all forward
//      legs applies the RRTS ceiling to the metro stretch and fires ~2x early;
//      piecewise integration is both never-late (each span's ceiling still
//      over-bounds that span's true speed) AND strictly tighter. We prove both.
//
// All math is pure and time is injected explicitly, so every assertion is
// deterministic and reproducible.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

/// First time (s) at which the reachability bound reaches [targetMeters] for a
/// tracker whose anchor is FROZEN at (s=0, t=0) — i.e. a pure GPS blackout from
/// the origin. Marches wall time in 1 s steps and NEVER re-anchors (blackout).
double? _fireTime(ReachabilityTracker tracker, double targetMeters,
    {String? lineName, String? vehicleType, double tEnd = 3600.0}) {
  for (double t = 0.0; t <= tEnd; t += 1.0) {
    final b = tracker.boundNow(
        nowSeconds: t, lineName: lineName, vehicleType: vehicleType);
    if (b != null && b.sMaxMeters >= targetMeters) return t;
  }
  return null;
}

void main() {
  group('A. V_LINE name-collision closed by the vehicle-type floor (GW-0076)', () {
    const table = VLineTable();

    test('generic name alone falls to the metro default (the under-bound)', () {
      // "Orange Line" matches no keyword tier → metro default. This IS the hole.
      expect(table.forLine(lineName: 'Orange Line'), VLineTable.defaultMps);
      expect(table.forLine(lineName: 'Western Line'), VLineTable.defaultMps);
    });

    test('HEAVY_RAIL / COMMUTER vehicle.type lifts a generic name to the RRTS '
        'ceiling, name-free', () {
      expect(table.forLine(lineName: 'Orange Line', vehicleType: 'HEAVY_RAIL'),
          VLineTable.rrtsMps);
      expect(table.forLine(lineName: 'Western Line', vehicleType: 'COMMUTER_TRAIN'),
          VLineTable.rrtsMps);
      expect(table.forLine(lineName: 'Anything', vehicleType: 'RAIL'),
          VLineTable.rrtsMps);
    });

    test('HIGH_SPEED / LONG_DISTANCE vehicle.type lifts to the absolute ceiling',
        () {
      expect(
          table.forLine(lineName: 'X', vehicleType: 'HIGH_SPEED_TRAIN'),
          VLineTable.absoluteCeilingMps);
      expect(
          table.forLine(lineName: 'X', vehicleType: 'LONG_DISTANCE_TRAIN'),
          VLineTable.absoluteCeilingMps);
    });

    test('a genuine SUBWAY/METRO_RAIL gets NO lift — Nagpur "Orange Line" stays '
        'a 90 km/h metro (no over-early fire)', () {
      expect(table.forLine(lineName: 'Orange Line', vehicleType: 'SUBWAY'),
          VLineTable.defaultMps);
      expect(table.forLine(lineName: 'Orange Line', vehicleType: 'METRO_RAIL'),
          VLineTable.defaultMps);
      expect(table.forLine(lineName: 'Orange Line', vehicleType: 'TRAM'),
          VLineTable.defaultMps);
    });

    test('the vehicle floor is a FLOOR, never a cap: it cannot lower a '
        'keyword-resolved ceiling', () {
      // "Airport Express" keyword-resolves to expressMps (39). A SUBWAY floor
      // (null lift) must not drag it back down to the metro default.
      final kw = table.forLine(lineName: 'Airport Express');
      expect(kw, VLineTable.expressMps);
      expect(table.forLine(lineName: 'Airport Express', vehicleType: 'SUBWAY'),
          greaterThanOrEqualTo(kw));
      // An RRTS-branded name with a weaker vehicle class keeps the RRTS ceiling.
      final rrtsKw = table.forLine(lineName: 'Namo Bharat RapidX');
      expect(rrtsKw, VLineTable.rrtsMps);
      expect(
          table.forLine(lineName: 'Namo Bharat RapidX', vehicleType: 'SUBWAY'),
          greaterThanOrEqualTo(rrtsKw));
    });

    test('METAMORPHIC never-late: generic-named fast line fires LATE without the '
        'vehicle floor, ON TIME with it', () {
      // A train that truly runs at expressMps (39 m/s) on a leg Google names
      // "Orange Line" but classes HEAVY_RAIL. Anchor frozen at the origin
      // (pure blackout). Fire target 6 km down the line.
      const double vTrue = VLineTable.expressMps; // 39 m/s true top speed
      const double target = 6000.0;
      final double trueArrival = target / vTrue; // when the train truly arrives

      ReachabilityTracker mkTracker() {
        final t = ReachabilityTracker(vLineTable: const VLineTable());
        t.seedColdStart(tSeconds: 0.0, sMeters: 0.0);
        return t;
      }

      // (1) WITHOUT the vehicle floor: V_LINE = 28 < 39 → s_max grows slower
      // than the train → the bound reaches the target AFTER the train does.
      final lateFire =
          _fireTime(mkTracker(), target, lineName: 'Orange Line');
      expect(lateFire, isNotNull);
      expect(lateFire!, greaterThan(trueArrival),
          reason: 'un-lifted generic-name bound must demonstrate the LATE hole '
              '(fire ${lateFire.toStringAsFixed(0)}s > true arrival '
              '${trueArrival.toStringAsFixed(0)}s)');

      // (2) WITH the vehicle floor: V_LINE = 53 >= 39 → s_max outruns the train
      // → the bound fires at or before true arrival. NEVER-LATE restored.
      final safeFire = _fireTime(mkTracker(), target,
          lineName: 'Orange Line', vehicleType: 'HEAVY_RAIL');
      expect(safeFire, isNotNull);
      expect(safeFire!, lessThanOrEqualTo(trueArrival + 1.0),
          reason: 'vehicle-type-lifted bound must be never-late (fire '
              '${safeFire.toStringAsFixed(0)}s <= true arrival '
              '${trueArrival.toStringAsFixed(0)}s)');
      // And it is strictly earlier than the un-lifted (late) fire.
      expect(safeFire, lessThan(lateFire));
    });
  });

  group('B. Piecewise multi-leg V_LINE is never-late AND tighter than flat-max '
      '(P0-03)', () {
    // Two legs: a metro stretch [0, 5000) @ ceiling 28 m/s feeding an RRTS
    // stretch [5000, 15000) @ ceiling 53 m/s. The TRUE train runs strictly
    // BELOW each ceiling (24 then 48 m/s) — the realistic case where V_LINE
    // over-bounds true speed — so never-late must hold with a real margin.
    const double sBoundary = 5000.0;
    const double sEnd = 15000.0;
    const double vCeil1 = VLineTable.defaultMps; // 28
    const double vCeil2 = VLineTable.rrtsMps; // 53
    const double vTrue1 = 24.0;
    const double vTrue2 = 48.0;
    final segments = <VLineSegment>[
      VLineSegment(sBoundary, vCeil1),
      VLineSegment(sEnd, vCeil2),
    ];
    const anchor = ReachabilityAnchor(
        sMeters: 0.0, accuracyMeters: 0.0, tSeconds: 0.0);

    // True arc progress at wall time t (integrate the true per-leg speeds).
    double trueS(double t) {
      final tBoundary = sBoundary / vTrue1;
      if (t <= tBoundary) return vTrue1 * t;
      return sBoundary + vTrue2 * (t - tBoundary);
    }

    test('never-late (>= true) and tighter (<= flat-max) at every instant, with '
        'a strictly-tighter region on the slow leg', () {
      var everStrictlyTighter = false;
      for (double t = 0.0; t <= 320.0; t += 1.0) {
        final piecewise = Reachability.bound(
          anchor: anchor,
          nowSeconds: t,
          vLineMps: vCeil2, // tail / flat-max speed
          vLineSegments: segments,
        );
        final flat = Reachability.bound(
          anchor: anchor,
          nowSeconds: t,
          vLineMps: vCeil2, // flat max over all legs
        );
        final truth = trueS(t);

        // NEVER-LATE: the piecewise bound is an UPPER bound on true progress.
        expect(piecewise.sMaxMeters, greaterThanOrEqualTo(truth - 1e-6),
            reason: 'piecewise UNDER-bounded true progress at t=$t '
                '(sMax=${piecewise.sMaxMeters} < true=$truth) → LATE');

        // TIGHTER: never looser than the flat-max free-run.
        expect(piecewise.sMaxMeters, lessThanOrEqualTo(flat.sMaxMeters + 1e-6),
            reason: 'piecewise looser than flat-max at t=$t');

        if (piecewise.sMaxMeters < flat.sMaxMeters - 1.0) {
          everStrictlyTighter = true;
        }
      }
      expect(everStrictlyTighter, isTrue,
          reason: 'piecewise must be strictly tighter than flat-max somewhere '
              'on the slow leg (the whole point of P0-03)');
    });

    test('anchor sitting on the slow leg: the march still over-bounds a train '
        'that crosses into the fast leg mid-blackout (never-late)', () {
      // Anchor 4 km in (still on the metro leg). Train continues at vTrue1 to
      // the boundary, then vTrue2. Segments span ALL legs so the arc from 4 km
      // to 5 km is correctly ceiled at the metro 28 (not the RRTS 53).
      const double s0 = 4000.0;
      const behind = ReachabilityAnchor(
          sMeters: s0, accuracyMeters: 0.0, tSeconds: 0.0);
      double trueSFrom4k(double t) {
        final tBoundary = (sBoundary - s0) / vTrue1;
        if (t <= tBoundary) return s0 + vTrue1 * t;
        return sBoundary + vTrue2 * (t - tBoundary);
      }

      for (double t = 0.0; t <= 220.0; t += 1.0) {
        final b = Reachability.bound(
          anchor: behind,
          nowSeconds: t,
          vLineMps: vCeil2,
          vLineSegments: segments,
        );
        expect(b.sMaxMeters, greaterThanOrEqualTo(trueSFrom4k(t) - 1e-6),
            reason: 'anchor-behind piecewise UNDER-bounded at t=$t → LATE');
      }
    });
  });
}
