// NEGATIVE / guard tests for the fastest-feasible-train tightening. Each proves
// a mandatory guard is LOAD-BEARING: remove it (mis-set the constant / corrupt
// the served set) and the pointwise never-late assertion s_max >= s_true FAILS.
// (TIGHTENING_IMPL.md §6.)
//
// R1/R6 (downhill accel / at-rest seed) are structurally avoided by seeding the
// departure speed at V_LINE rather than a certified-at-rest 0 — so there is no
// accel-from-rest late path at the anchor to guard against here.
//
// Run: flutter test test/reachability/tightening_guards_test.dart

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

const double kVLine = 28.0;

/// A straight route of [n] samples at [ds] m spacing along a meridian, so arc
/// length == index*ds. Returns (lats, lngs, cumulative).
(List<double>, List<double>, List<double>) _straight(int n, double ds) {
  const lat0 = 12.95, lng0 = 77.6;
  const mPerDegLat = 111320.0;
  final lats = <double>[], lngs = <double>[], cum = <double>[];
  for (var i = 0; i < n; i++) {
    lats.add(lat0 + (i * ds) / mPerDegLat);
    lngs.add(lng0);
    cum.add(i * ds);
  }
  return (lats, lngs, cum);
}

/// A circular arc of radius [r] m, [n] samples at ~[ds] m arc spacing. Constant
/// curvature 1/r, so a train may corner at sqrt(aLat/r).
(List<double>, List<double>, List<double>) _arc(int n, double ds, double r) {
  const lat0 = 12.95, lng0 = 77.6;
  const mPerDegLat = 111320.0;
  final cosLat = math.cos(lat0 * math.pi / 180.0);
  final lats = <double>[], lngs = <double>[], cum = <double>[];
  for (var i = 0; i < n; i++) {
    final theta = (i * ds) / r; // arc angle
    final x = r * math.sin(theta); // east (m)
    final y = r * (1 - math.cos(theta)); // north (m)
    lats.add(lat0 + y / mPerDegLat);
    lngs.add(lng0 + x / (mPerDegLat * cosLat));
    cum.add(i * ds);
  }
  return (lats, lngs, cum);
}

/// Max s_true(t) − s_max(t) over a constant-speed true train from an anchor at
/// the origin; positive => a never-late VIOLATION (cone fell behind true).
double _maxUnderBound({
  required List<double> lats,
  required List<double> lngs,
  required List<double> cum,
  required List<double> served,
  required ReachabilityConfig cfg,
  required double vTrue,
  required double tEnd,
}) {
  final profile = RouteProfile.precompute(
    lats: lats,
    lngs: lngs,
    cumulativeMeters: cum,
    servedStations: served,
    config: cfg,
    vLine: kVLine,
  );
  final topo = RouteTopology(stationMeters: served, profile: profile);
  final anchor =
      ReachabilityAnchor(sMeters: 0.0, accuracyMeters: 0.0, tSeconds: 0.0);
  final total = cum.last;
  var worst = -1e9;
  for (double t = 0; t <= tEnd; t += 1.0) {
    final sTrue = math.min(vTrue * t, total);
    final b = Reachability.bound(
      anchor: anchor,
      nowSeconds: t,
      vLineMps: kVLine,
      topology: topo,
      config: cfg,
    );
    worst = math.max(worst, sTrue - b.sMaxMeters);
  }
  return worst;
}

void main() {
  test('INERT by default — levers off ⇒ cone is bit-identical to free-run', () {
    final (lats, lngs, cum) = _straight(121, 25.0); // 3000 m
    final profile = RouteProfile.precompute(
      lats: lats,
      lngs: lngs,
      cumulativeMeters: cum,
      servedStations: const [1500.0],
      config: ReachabilityConfig.defaults,
      vLine: kVLine,
    );
    final topo = RouteTopology(stationMeters: const [1500.0], profile: profile);
    final anchor =
        ReachabilityAnchor(sMeters: 0.0, accuracyMeters: 0.0, tSeconds: 0.0);
    for (double t = 0; t <= 120; t += 5) {
      final b = Reachability.bound(
        anchor: anchor,
        nowSeconds: t,
        vLineMps: kVLine,
        topology: topo,
        config: ReachabilityConfig.defaults, // dynamicLevers OFF, dwell 0
      );
      // With every lever inert the tightening path must not run at all.
      expect(b.sMaxMeters, closeTo(b.freeRunMeters, 1e-9),
          reason: 'default config must be inert (== free-run) at t=$t');
    }
  });

  group('R10 — served-set correctness is load-bearing (express-skip)', () {
    // A train cruising at V_LINE that does NOT stop. If a phantom station is
    // (wrongly) marked served, the cone brakes+dwells there and falls behind.
    final (lats, lngs, cum) = _straight(161, 25.0); // 4000 m
    const cfg = ReachabilityConfig(
      dynamicLeversEnabled: true,
      dwellMinSeconds: 7.0,
      aMaxMps2: 2.5,
      dMaxMps2: 3.5,
    );

    test('CORRECT served set (no stop in-segment) ⇒ never-late', () {
      final under = _maxUnderBound(
        lats: lats, lngs: lngs, cum: cum,
        served: const [], // express: no stop within the observed segment
        cfg: cfg, vTrue: kVLine, tEnd: 200,
      );
      expect(under, lessThanOrEqualTo(1.0),
          reason: 'cone must not under-bound a non-stopping V_LINE train');
    });

    test('PHANTOM served stop ⇒ FAILS never-late (guard removed)', () {
      final under = _maxUnderBound(
        lats: lats, lngs: lngs, cum: cum,
        served: const [2000.0, 4000.0], // phantom mid-route stop the express skips
        cfg: cfg, vTrue: kVLine, tEnd: 200,
      );
      // The mandatory guard (served-from-route, express default all_stops=false)
      // exists precisely because this under-bounds ⇒ would fire LATE.
      expect(under, greaterThan(1.0),
          reason: 'a phantom served stop MUST under-bound a non-stopping train '
              '(this is why served-set correctness is mandatory)');
    });
  });

  group('R7 — curve aLatEff is load-bearing', () {
    // A 150 m-radius arc; a true train corners at sqrt(5.0*150)=27.4 m/s.
    final (lats, lngs, cum) = _arc(120, 25.0, 150.0); // ~3000 m of arc
    final vTrue = math.sqrt(5.0 * 150.0); // ~27.4, below the 7.0-overturning cap

    ReachabilityConfig cfg(double aLat) => ReachabilityConfig(
          dynamicLeversEnabled: true,
          curveTrusted: true,
          aLatEffMps2: aLat,
          curveSigmaPosMeters: 2.0, // tight (clean synthetic geometry)
        );

    test('aLatEff = 7.0 (empty-car overturning) ⇒ never-late', () {
      final under = _maxUnderBound(
        lats: lats, lngs: lngs, cum: cum, served: const [3000.0 - 25.0],
        cfg: cfg(7.0), vTrue: vTrue, tEnd: 140,
      );
      expect(under, lessThanOrEqualTo(1.0),
          reason: 'aLatEff=7 must keep the curve ceiling above true cornering');
    });

    test('aLatEff = 1.3 (comfort — too low) ⇒ FAILS never-late', () {
      final under = _maxUnderBound(
        lats: lats, lngs: lngs, cum: cum, served: const [3000.0 - 25.0],
        cfg: cfg(1.3), vTrue: vTrue, tEnd: 140,
      );
      expect(under, greaterThan(1.0),
          reason: 'a comfort aLatEff caps the ceiling below a fast-cornering '
              'train ⇒ under-bounds ⇒ LATE (this is why 7.0 is mandatory)');
    });
  });
}
