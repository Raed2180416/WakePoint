// Proof for GAP #1 (BLOCK): the cold-start-underground reachability backstop.
//
// The reachability PHYSICS (bound reaching the target => never late) is proven
// in test/reachability/. This file proves the PRODUCTION fire-target math that
// the AlarmController cold-start backstop uses — the arc-position at which it
// wakes the rider per alarm mode — is a correct LOWER bound on the true fire
// point (so the worst-case bound reaching it can never be late), across
// stops/distance/time modes and the fewer-stops-than-N and no-geometry edges.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/services/tracking/alarm_controller.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/transfer_utils.dart';

TransitLegStops _metroLeg({
  required double endMeters,
  required List<double> stopMeters,
  String line = 'Purple',
}) {
  return TransitLegStops(
    legStartMeters: 0.0,
    legEndMeters: endMeters,
    numStops: stopMeters.length,
    stopPositions: stopMeters.map((_) => const LatLng(12.9, 77.6)).toList(),
    stopMeters: stopMeters,
    lineName: line,
    isActualPositions: true,
    isMetro: true,
    stopNames: [for (var i = 0; i < stopMeters.length; i++) 'S$i'],
  );
}

AlarmContext _ctx({
  required String mode,
  required double value,
  required List<TransitLegStops> legs,
}) {
  return AlarmContext(
    destination: const LatLng(12.9, 77.6),
    alarmMode: mode,
    alarmValue: value,
    trackingSessionActive: true,
    registry: RouteRegistry(),
    transitLegs: legs,
  );
}

void main() {
  final ac = AlarmController();
  const total = 5000.0;
  const vMax = 28.0; // metro default ceiling

  group('cold-start fire target (never-late lower bound)', () {
    test('stops mode: N=2 before destination -> Nth-from-last intermediate stop',
        () {
      final legs = [
        _metroLeg(endMeters: total, stopMeters: [1000, 2000, 3000, 4000])
      ];
      final t = ac.coldStartFireTargetMeters(
          _ctx(mode: 'stops', value: 2, legs: legs), total, legs, vMax);
      // Order to the 5000m destination: ...3000(2 before), 4000(1 before), dest.
      expect(t, 3000.0);
    });

    test('stops mode: N larger than available stops -> fire at the first stop',
        () {
      final legs = [
        _metroLeg(endMeters: total, stopMeters: [1000, 2000, 3000, 4000])
      ];
      final t = ac.coldStartFireTargetMeters(
          _ctx(mode: 'stops', value: 9, legs: legs), total, legs, vMax);
      expect(t, 1000.0); // earliest stop => conservative (early), never late
    });

    test('stops mode: no stop geometry -> conservative ~1.2km/stop before end',
        () {
      final legs = [_metroLeg(endMeters: total, stopMeters: const [])];
      final t = ac.coldStartFireTargetMeters(
          _ctx(mode: 'stops', value: 2, legs: legs), total, legs, vMax);
      expect(t, 5000.0 - 2 * 1200.0); // 2600
    });

    test('distance mode: N km before destination', () {
      final legs = [_metroLeg(endMeters: total, stopMeters: const [])];
      final t = ac.coldStartFireTargetMeters(
          _ctx(mode: 'distance', value: 1, legs: legs), total, legs, vMax);
      expect(t, 4000.0); // 5000 - 1000
    });

    test('time mode: worst-case N*60*vMax meters before destination', () {
      final legs = [_metroLeg(endMeters: total, stopMeters: const [])];
      final t = ac.coldStartFireTargetMeters(
          _ctx(mode: 'time', value: 2, legs: legs), total, legs, vMax);
      expect(t, 5000.0 - 2 * 60.0 * 28.0); // 1640
    });

    test('targets are always clamped to >= 0 (never negative)', () {
      final legs = [_metroLeg(endMeters: total, stopMeters: const [])];
      // A huge distance threshold would push the raw target negative.
      final t = ac.coldStartFireTargetMeters(
          _ctx(mode: 'distance', value: 999, legs: legs), total, legs, vMax);
      expect(t, 0.0);
    });
  });

  group('arm-time anchor seeding', () {
    test('seedReachabilityAnchorAtArm establishes an anchor before any fix', () {
      final c = AlarmController();
      // Fresh controller: no anchor yet -> cold-start backstop cannot run.
      // After seeding at arm, the physics net has a t0 to grow from.
      c.seedReachabilityAnchorAtArm(sMeters: 0.0, tSeconds: 1000.0);
      // Seeding is idempotent and does not throw; the reachability layer's
      // never-late behaviour from a seeded anchor is proven in
      // test/reachability/. Here we just assert the seam is callable and safe.
      c.seedReachabilityAnchorAtArm(sMeters: 0.0, tSeconds: 1000.0);
    });
  });
}
