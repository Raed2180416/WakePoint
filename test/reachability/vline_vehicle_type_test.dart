// P0-01 (GW-0016) — V_LINE line-name-collision never-late fix.
//
// The reachability free-run bound is s_max = sHi + V_LINE*dt. Precondition (ii)
// requires V_LINE >= the line's true max speed, or the bound UNDER-bounds during
// a GPS blackout and the alarm fires LATE. Before this fix, VLineTable.forLine
// resolved V_LINE from the (collidable) Google Directions LINE NAME only, so a
// fast service reported with a slow/generic name — Delhi Airport Express as
// "Orange Line" (~135 km/h), Mumbai Suburban as "Western Line" (~120 km/h) —
// fell to defaultMps=28 m/s and could fire late. The fix adds a NAME-FREE
// vehicle-class floor from `transit_details.line.vehicle.type` and takes the
// MAX (monotone ⇒ can only fire earlier, never later).
//
// The at-scale oracle (test/scale/reachability_scale_test.dart) CANNOT catch this
// because it injects each ride's certified V_LINE as a per-line override, which
// short-circuits forLine before the tier logic. Hence this dedicated test.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

void main() {
  const table = VLineTable();

  group('VLineTable.forLine — name-free vehicle-class floor closes GAP #9', () {
    test('the collision hole: a fast line with a slow NAME alone under-bounds', () {
      // Documents the pre-fix hazard: with no vehicle type, "Orange Line" (which
      // collides with Nagpur's genuine 90 km/h metro) resolves to the 28 m/s
      // metro default — an under-bound for a 135 km/h Airport Express.
      expect(table.forLine(lineName: 'Orange Line'), VLineTable.defaultMps);
      expect(table.forLine(lineName: 'Western Line'), VLineTable.defaultMps);
    });

    test('HEAVY_RAIL/RAIL/COMMUTER_TRAIN lift to the RRTS class-max (never-late)', () {
      // Google lumps suburban EMUs and ~160 km/h mainline expresses under
      // HEAVY_RAIL, so never-late forces the class-max ceiling (53 m/s).
      for (final vt in ['HEAVY_RAIL', 'RAIL', 'COMMUTER_TRAIN', 'heavy_rail']) {
        expect(table.forLine(lineName: 'Western Line', vehicleType: vt),
            VLineTable.rrtsMps,
            reason: 'vehicleType=$vt must lift a slow-named fast line to RRTS');
        expect(table.forLine(lineName: 'Orange Line', vehicleType: vt),
            VLineTable.rrtsMps);
      }
    });

    test('HIGH_SPEED/LONG_DISTANCE lift to the absolute ceiling', () {
      expect(table.forLine(lineName: 'Vande Bharat', vehicleType: 'HIGH_SPEED_TRAIN'),
          VLineTable.absoluteCeilingMps);
      expect(table.forLine(lineName: 'X', vehicleType: 'LONG_DISTANCE_TRAIN'),
          VLineTable.absoluteCeilingMps);
    });

    test('a genuine SUBWAY/metro is NOT over-fired (no lift)', () {
      // Nagpur "Orange Line" IS a 90 km/h metro (type SUBWAY): stays at 28 m/s so
      // it does not fire ~2x early on a blackout.
      expect(table.forLine(lineName: 'Orange Line', vehicleType: 'SUBWAY'),
          VLineTable.defaultMps);
      expect(table.forLine(lineName: 'Blue Line', vehicleType: 'METRO_RAIL'),
          VLineTable.defaultMps);
      expect(table.forLine(lineName: 'Green Line', vehicleType: 'TRAM'),
          VLineTable.defaultMps);
    });

    test('keyword tier still wins when it is higher than the vehicle floor', () {
      // RRTS branding is caught by looksRrts even if vehicle.type is absent/low.
      expect(table.forLine(lineName: 'Namo Bharat RapidX'), VLineTable.rrtsMps);
      // express keyword (39) vs SUBWAY floor (null) → keyword.
      expect(table.forLine(lineName: 'Airport Express'), VLineTable.expressMps);
      // express-named but HEAVY_RAIL typed → max(39, 53) = 53.
      expect(
          table.forLine(lineName: 'Airport Express', vehicleType: 'HEAVY_RAIL'),
          VLineTable.rrtsMps);
    });

    test('operator override pin still short-circuits everything', () {
      const pinned = VLineTable(overrides: {'|western line': 30.0});
      expect(
          pinned.forLine(lineName: 'Western Line', vehicleType: 'HEAVY_RAIL'),
          30.0,
          reason: 'a certified pin must win over the vehicle-class floor');
    });

    test('MONOTONICITY: adding a vehicleType can only RAISE V_LINE (never lower)', () {
      const names = ['Orange Line', 'Western Line', 'Blue Line', 'Namo Bharat',
        'Airport Express', 'Suburban Local', null];
      const types = ['SUBWAY', 'METRO_RAIL', 'HEAVY_RAIL', 'RAIL',
        'COMMUTER_TRAIN', 'HIGH_SPEED_TRAIN', 'TRAM', 'UNKNOWN', null];
      for (final n in names) {
        final base = table.forLine(lineName: n);
        for (final t in types) {
          final lifted = table.forLine(lineName: n, vehicleType: t);
          expect(lifted, greaterThanOrEqualTo(base),
              reason: 'forLine("$n", $t)=$lifted must be >= forLine("$n")=$base '
                  '(monotone raise ⇒ never-late preserved)');
        }
      }
    });
  });

  group('Never-late integration: the fix covers a blackout the default would miss', () {
    // A Mumbai-Suburban leg named "Western Line", true top speed ~33.3 m/s
    // (120 km/h). Anchor at s=0 t=0; the train truly reaches s=1665 m at t=50 s
    // (33.3 m/s). During a GPS blackout the reach bound must stay >= true progress.
    test('vehicleType=HEAVY_RAIL bound covers the fast train; the 28 m/s default under-bounds', () {
      const anchor = ReachabilityAnchor(sMeters: 0, accuracyMeters: 0, tSeconds: 0);
      const trueSpeed = 33.3; // 120 km/h
      const t = 50.0;
      final trueProgress = trueSpeed * t; // 1665 m

      final vFixed = table.forLine(lineName: 'Western Line', vehicleType: 'HEAVY_RAIL');
      final vBuggy = table.forLine(lineName: 'Western Line'); // 28 m/s (old hole)

      final boundFixed = Reachability.bound(
          anchor: anchor, nowSeconds: t, vLineMps: vFixed);
      final boundBuggy = Reachability.bound(
          anchor: anchor, nowSeconds: t, vLineMps: vBuggy);

      // The FIX is never-late: the bound over-bounds true progress.
      expect(boundFixed.sMaxMeters, greaterThanOrEqualTo(trueProgress),
          reason: 'fixed V_LINE=$vFixed must over-bound the 33.3 m/s train');
      // The OLD default would have UNDER-bounded (demonstrates the closed hole).
      expect(boundBuggy.sMaxMeters, lessThan(trueProgress),
          reason: 'the 28 m/s default under-bounds a 120 km/h train → late');
    });
  });
}
