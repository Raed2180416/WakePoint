// test/reachability/reachability_edgecases_test.dart
//
// EDGE-CASE + ERROR-PATH assault on the reachability Protection Level.
//
// The core theorem ("s_max is never below true progress") is proven over random
// trajectories in reachability_test.dart. This file attacks the *degenerate and
// corrupt inputs* that a real device throws at the math: a NaN/negative clock, a
// future or malformed anchor, a zero/NaN/negative V_LINE, an empty/duplicate/
// negative/unsorted topology, overflowing elapsed time, and NaN plumbing through
// effectiveProgress. For every one of these the requirement is identical to the
// theorem: the returned bound MUST stay an UPPER bound on true progress
// (never-late) or FAIL SAFE (fire early). A frozen, shrinking, or NaN bound that
// silently suppresses the alarm is the cardinal sin for a wake alarm and is
// asserted against here even where the current implementation does not yet honour
// it (those cases are marked SUSPECTED DEFECT).
//
// These cases are deliberately disjoint from reachability_test.dart (which owns
// the random-trajectory theorem, the three-precondition violations, the stopping
// cap-vs-express sims, and the RRTS/express table resolution).

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

/// Convenience: an anchor at [s] meters progress with [acc] accuracy at time [t].
ReachabilityAnchor _a(double s, {double acc = 0.0, double t = 0.0}) =>
    ReachabilityAnchor(sMeters: s, accuracyMeters: acc, tSeconds: t);

void main() {
  // ------------------------------------------------------------------
  group('Elapsed-time (dt) sanitisation', () {
    test('now before the anchor (negative dt) clamps dt to 0 and freezes at '
        'the overbounded anchor — a valid upper bound', () {
      final anchor = _a(1000.0, acc: 20.0, t: 100.0); // sHi = 1020
      final b = Reachability.bound(
        anchor: anchor,
        nowSeconds: 40.0, // 60 s BEFORE the anchor
        vLineMps: 28.0,
      );
      expect(b.dtSeconds, 0.0);
      expect(b.sMaxMeters, closeTo(1020.0, 1e-9));
      expect(b.freeRunMeters, closeTo(1020.0, 1e-9));
      // Never-late: at an earlier wall-clock time a monotone train had progress
      // <= its progress at t=100 (<=1000), so 1020 is a genuine upper bound.
      expect(b.sMaxMeters, greaterThanOrEqualTo(1000.0));
    });

    test('anchor timestamp far in the FUTURE still yields dt=0, never a '
        'negative (shrinking) bound', () {
      final anchor = _a(500.0, acc: 5.0, t: 5000.0); // sHi = 505, t in future
      final b = Reachability.bound(
        anchor: anchor,
        nowSeconds: 0.0,
        vLineMps: 28.0,
      );
      expect(b.dtSeconds, 0.0);
      expect(b.sMaxMeters, closeTo(505.0, 1e-9));
      // Critically, the bound is NOT below the anchor snap (no phantom rewind).
      expect(b.sMaxMeters, greaterThanOrEqualTo(500.0));
    });

    test('huge elapsed time that overflows the double fails SAFE (+inf => '
        'fires for any finite target)', () {
      final anchor = _a(0.0, t: 0.0);
      final b = Reachability.bound(
        anchor: anchor,
        nowSeconds: 1e308, // 56 * 1e308 overflows past double.maxFinite
        vLineMps: VLineTable.absoluteCeilingMps,
      );
      expect(b.sMaxMeters, double.infinity);
      expect(b.dtSeconds, 1e308); // dt itself is preserved, only the product blows
      expect(Reachability.reachesTarget(b, 1e12), isTrue,
          reason: 'An overflowing blackout must fire, never wrap or freeze.');
    });

    test('huge elapsed time with a topology cap still fails safe (no NaN, '
        'fires)', () {
      final topo = RouteTopology(stationMeters: const [800.0, 1600.0]);
      final b = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 1e308,
        vLineMps: VLineTable.absoluteCeilingMps,
        topology: topo,
        config: const ReachabilityConfig(dwellMinSeconds: 20.0),
      );
      expect(b.sMaxMeters.isNaN, isFalse,
          reason: 'The capped bound must never degrade to NaN.');
      expect(Reachability.reachesTarget(b, 1e12), isTrue);
    });

    test('SUSPECTED DEFECT: a NaN clock freezes the bound at the anchor and the '
        'watchdog cannot trip — the alarm can never fire', () {
      // now = NaN (a corrupt/absent clock read). dt = NaN => dt.isFinite is
      // false => dtClamped collapses to 0 => freeRun = anchor.sHi and the
      // watchdog test `dtClamped >= hardTMax` (0 >= 300) is false. Nothing ever
      // grows the bound, so reachesTarget() is false forever.
      final b = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: double.nan,
        vLineMps: 28.0,
        config: const ReachabilityConfig(hardTMaxSeconds: 300.0),
      );
      // Safe behaviour on an un-boundable clock is to FAIL SAFE (fire): either
      // trip the watchdog or return a non-finite (fire-forcing) bound.
      expect(
        b.watchdogTripped || !b.sMaxMeters.isFinite,
        isTrue,
        reason: 'NaN clock must fail safe (fire), not silently freeze the bound '
            'at the anchor and suppress the alarm forever. Current: '
            'sMax=${b.sMaxMeters}, watchdog=${b.watchdogTripped}.',
      );
    });

    test('SUSPECTED DEFECT: a NaN anchor timestamp freezes dt to 0 (same '
        'never-fire failure)', () {
      final b = Reachability.bound(
        anchor: _a(0.0, t: double.nan),
        nowSeconds: 500.0,
        vLineMps: 28.0,
        config: const ReachabilityConfig(hardTMaxSeconds: 300.0),
      );
      expect(
        b.watchdogTripped || !b.sMaxMeters.isFinite,
        isTrue,
        reason: 'A NaN anchor time must fail safe, not collapse dt to 0.',
      );
    });
  });

  // ------------------------------------------------------------------
  group('V_LINE sanitisation (must fall back to a safe ceiling, never '
      'underestimate)', () {
    // Anchor at 100 m, no accuracy inflation, so sHi = 100 exactly.
    final anchor = _a(100.0, t: 0.0);
    const dt = 10.0;
    final expectedCeiling = 100.0 + VLineTable.absoluteCeilingMps * dt;

    test('V_LINE == 0 uses the absolute ceiling, not a frozen bound', () {
      final b = Reachability.bound(
          anchor: anchor, nowSeconds: dt, vLineMps: 0.0);
      expect(b.sMaxMeters, closeTo(expectedCeiling, 1e-9));
      expect(b.sMaxMeters, greaterThan(anchor.sHi),
          reason: 'A 0 speed must NOT freeze the bound (that never fires).');
    });

    test('V_LINE == NaN uses the absolute ceiling', () {
      final b = Reachability.bound(
          anchor: anchor, nowSeconds: dt, vLineMps: double.nan);
      expect(b.sMaxMeters, closeTo(expectedCeiling, 1e-9));
      expect(b.sMaxMeters.isNaN, isFalse);
    });

    test('V_LINE negative uses the ceiling — the bound GROWS, never shrinks', () {
      // If -30 leaked through, freeRun = 100 + (-30)*10 = -200 (a shrinking bound
      // is a guaranteed late fire). It must instead grow at the ceiling.
      final b = Reachability.bound(
          anchor: anchor, nowSeconds: dt, vLineMps: -30.0);
      expect(b.sMaxMeters, closeTo(expectedCeiling, 1e-9));
      expect(b.sMaxMeters, greaterThan(anchor.sHi));
    });

    test('V_LINE == -infinity uses the ceiling', () {
      final b = Reachability.bound(
          anchor: anchor, nowSeconds: dt, vLineMps: double.negativeInfinity);
      expect(b.sMaxMeters, closeTo(expectedCeiling, 1e-9));
    });

    test('degenerate V_LINE bound is monotonically increasing in time', () {
      final early = Reachability.bound(
          anchor: anchor, nowSeconds: 10.0, vLineMps: 0.0);
      final late = Reachability.bound(
          anchor: anchor, nowSeconds: 20.0, vLineMps: 0.0);
      expect(late.sMaxMeters, greaterThan(early.sMaxMeters),
          reason: 'Worst-case reach must never decrease as time elapses.');
    });
  });

  // ------------------------------------------------------------------
  group('Anchor accuracy sanitisation (sHi must never rewind behind sMeters)',
      () {
    test('negative accuracy does NOT subtract from the anchor', () {
      final anchor = _a(500.0, acc: -100.0); // must NOT become 400
      expect(anchor.sHi, 500.0);
      final b = Reachability.bound(
          anchor: anchor, nowSeconds: 10.0, vLineMps: 28.0);
      expect(b.sMaxMeters, closeTo(500.0 + 28.0 * 10.0, 1e-9));
    });

    test('NaN accuracy collapses the overbound to 0 (no NaN leak)', () {
      final anchor = _a(500.0, acc: double.nan);
      expect(anchor.sHi, 500.0);
      final b = Reachability.bound(
          anchor: anchor, nowSeconds: 10.0, vLineMps: 28.0);
      expect(b.sMaxMeters.isNaN, isFalse);
      expect(b.sMaxMeters, closeTo(780.0, 1e-9));
    });

    test('infinite accuracy collapses the overbound to 0 (finite bound)', () {
      final anchor = _a(500.0, acc: double.infinity);
      expect(anchor.sHi, 500.0);
      final b = Reachability.bound(
          anchor: anchor, nowSeconds: 10.0, vLineMps: 28.0);
      expect(b.sMaxMeters.isFinite, isTrue);
    });

    test('sHi >= sMeters holds for the full battery of accuracy values', () {
      for (final acc in <double>[
        0.0,
        15.0,
        1000.0,
        -1.0,
        -1e9,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final anchor = _a(750.0, acc: acc);
        expect(anchor.sHi, greaterThanOrEqualTo(750.0),
            reason: 'accuracy=$acc must never place the anchor behind its snap.');
      }
    });
  });

  // ------------------------------------------------------------------
  group('Topology cap: empty / single / duplicate / negative / unsorted', () {
    const dwellMin = 20.0;
    const config = ReachabilityConfig(dwellMinSeconds: dwellMin);

    test('empty topology behaves exactly like no topology (unconditional '
        'free-run)', () {
      final empty = RouteTopology(stationMeters: const []);
      expect(empty.isEmpty, isTrue);
      final withEmpty = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        topology: empty,
        config: config,
      );
      final without = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
      );
      expect(withEmpty.sMaxMeters, closeTo(without.sMaxMeters, 1e-9));
      expect(withEmpty.sMaxMeters, closeTo(2800.0, 1e-9));
    });

    test('single-station cap is tighter than free-run and stays an upper bound',
        () {
      final topo = RouteTopology(stationMeters: const [800.0]);
      final b = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        topology: topo,
        config: config,
      );
      // Fastest train: 800/28 s to the stop, 20 s dwell, coast the rest at 28.
      expect(b.freeRunMeters, closeTo(2800.0, 1e-9));
      expect(b.sMaxMeters, closeTo(2240.0, 1e-6));
      expect(b.sMaxMeters, lessThan(b.freeRunMeters));
      // Never-late against a concrete stopping train (cruise 22 m/s, dwell 20 s):
      // reaches 800 at ~36.4 s, departs ~56.4 s, then 22*(100-56.4) => ~1760 m.
      final trueProgressAt100 = 800.0 + 22.0 * (100.0 - (800.0 / 22.0) - 20.0);
      expect(b.sMaxMeters, greaterThanOrEqualTo(trueProgressAt100));
    });

    test('duplicate stations never double-count dwell (would under-bound => '
        'late)', () {
      final single = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        topology: RouteTopology(stationMeters: const [800.0]),
        config: config,
      );
      final dup = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        topology: RouteTopology(stationMeters: const [800.0, 800.0, 800.0]),
        config: config,
      );
      expect(dup.sMaxMeters, closeTo(single.sMaxMeters, 1e-9),
          reason: 'A repeated station must not subtract dwell more than once.');
    });

    test('stations behind the anchor (negative / <= sHi) are skipped, not '
        'applied', () {
      final baseline = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        topology: RouteTopology(stationMeters: const [800.0]),
        config: config,
      );
      final withBehind = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        // -500 and -100 are behind the origin; 0.0 sits exactly at the anchor.
        topology:
            RouteTopology(stationMeters: const [-500.0, -100.0, 0.0, 800.0]),
        config: config,
      );
      expect(withBehind.sMaxMeters, closeTo(baseline.sMaxMeters, 1e-9));
      // And it can only ever be <= free-run (a behind station must not inflate).
      expect(withBehind.sMaxMeters, lessThanOrEqualTo(withBehind.freeRunMeters));
    });

    test('RouteTopology sorts unsorted input; the cap uses ascending order', () {
      final topo = RouteTopology(stationMeters: const [1200.0, 400.0, 800.0]);
      expect(topo.stationMeters, orderedEquals(const [400.0, 800.0, 1200.0]));
      // Non-decreasing invariant the cap loop relies on.
      for (int i = 1; i < topo.stationMeters.length; i++) {
        expect(topo.stationMeters[i],
            greaterThanOrEqualTo(topo.stationMeters[i - 1]));
      }
      final unsorted = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 200.0,
        vLineMps: 28.0,
        topology: topo,
        config: config,
      );
      final presorted = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 200.0,
        vLineMps: 28.0,
        topology:
            RouteTopology(stationMeters: const [400.0, 800.0, 1200.0]),
        config: config,
      );
      expect(unsorted.sMaxMeters, closeTo(presorted.sMaxMeters, 1e-9));
    });

    test('the cap only reduces the bound (min(freeRun, capped)) and stays an '
        'upper bound across a dt sweep', () {
      final stations = <double>[for (int i = 1; i <= 15; i++) i * 800.0];
      final topo = RouteTopology(stationMeters: stations);
      double prev = double.negativeInfinity;
      for (double now = 0.0; now <= 2000.0; now += 25.0) {
        final b = Reachability.bound(
          anchor: _a(0.0, t: 0.0),
          nowSeconds: now,
          vLineMps: 28.0,
          topology: topo,
          config: config,
        );
        expect(b.sMaxMeters, lessThanOrEqualTo(b.freeRunMeters + 1e-6));
        // Monotone in time: worst-case reach can only grow.
        expect(b.sMaxMeters, greaterThanOrEqualTo(prev - 1e-6),
            reason: 'Capped bound went DOWN as time elapsed (late-fire risk) '
                'at now=$now.');
        prev = b.sMaxMeters;
      }
    });

    test('cap is driven ONLY by config.dwellMinSeconds; topology.dwellMinSeconds '
        'is inert (ignoring it is the safe/looser direction)', () {
      final topoWithDwell =
          RouteTopology(stationMeters: const [800.0], dwellMinSeconds: 20.0);
      // config dwell = 0 => cap disabled even though the topology carries 20.
      final capOff = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        topology: topoWithDwell,
        config: const ReachabilityConfig(dwellMinSeconds: 0.0),
      );
      expect(capOff.sMaxMeters, closeTo(2800.0, 1e-9),
          reason: 'config dwell=0 must degrade to unconditional free-run.');
      // config dwell = 20 with a topology that declares 0 => cap DOES apply.
      final capOn = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        topology: RouteTopology(
            stationMeters: const [800.0], dwellMinSeconds: 0.0),
        config: const ReachabilityConfig(dwellMinSeconds: 20.0),
      );
      expect(capOn.sMaxMeters, closeTo(2240.0, 1e-6));
    });

    test('negative config dwell disables the cap (never inflates the bound)',
        () {
      final b = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        topology: RouteTopology(stationMeters: const [800.0]),
        config: const ReachabilityConfig(dwellMinSeconds: -10.0),
      );
      expect(b.sMaxMeters, closeTo(2800.0, 1e-9));
      expect(b.sMaxMeters, closeTo(b.freeRunMeters, 1e-9));
    });
  });

  // ------------------------------------------------------------------
  group('Hard T_max watchdog boundary', () {
    test('trips EXACTLY at the boundary (dt == hardTMax, inclusive >=)', () {
      const config = ReachabilityConfig(hardTMaxSeconds: 300.0);
      final b = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 300.0, // dt == 300 exactly
        vLineMps: 28.0,
        config: config,
      );
      expect(b.watchdogTripped, isTrue);
      expect(b.sMaxMeters, double.infinity);
      expect(Reachability.reachesTarget(b, 1e9), isTrue);
    });

    test('does NOT trip just below the boundary', () {
      const config = ReachabilityConfig(hardTMaxSeconds: 300.0);
      final b = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 299.9999,
        vLineMps: 28.0,
        config: config,
      );
      expect(b.watchdogTripped, isFalse);
      expect(b.sMaxMeters.isFinite, isTrue);
    });

    test('hardTMax == 0 fires immediately (fail-safe, dt=0 >= 0)', () {
      const config = ReachabilityConfig(hardTMaxSeconds: 0.0);
      final b = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 0.0,
        vLineMps: 28.0,
        config: config,
      );
      expect(b.watchdogTripped, isTrue);
      expect(Reachability.reachesTarget(b, 1e9), isTrue);
    });

    test('negative hardTMax fires immediately (fail-safe)', () {
      const config = ReachabilityConfig(hardTMaxSeconds: -5.0);
      final b = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 0.0,
        vLineMps: 28.0,
        config: config,
      );
      expect(b.watchdogTripped, isTrue);
    });

    test('NaN hardTMax degrades gracefully to free-run (no crash, no spurious '
        'trip)', () {
      const config = ReachabilityConfig(hardTMaxSeconds: double.nan);
      final b = Reachability.bound(
        anchor: _a(0.0, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
        config: config,
      );
      expect(b.watchdogTripped, isFalse);
      expect(b.sMaxMeters, closeTo(2800.0, 1e-9));
    });
  });

  // ------------------------------------------------------------------
  group('effectiveProgress must never propagate NaN or drop a fire-forcing '
      'bound', () {
    test('NaN dead-reckoned + finite reach falls back to the reach (no NaN)',
        () {
      final r = Reachability.effectiveProgress(
        deadReckonedProgressMeters: double.nan,
        sigmaCushionMeters: 100.0,
        reachableBoundMeters: 1500.0,
      );
      expect(r.isNaN, isFalse);
      expect(r, 1500.0);
    });

    test('NaN sigma cushion + finite reach falls back to the reach', () {
      final r = Reachability.effectiveProgress(
        deadReckonedProgressMeters: 1000.0,
        sigmaCushionMeters: double.nan,
        reachableBoundMeters: 1500.0,
      );
      expect(r, 1500.0);
    });

    test('a -infinity (garbage) reach is dropped in favour of the statistical '
        'bound', () {
      final r = Reachability.effectiveProgress(
        deadReckonedProgressMeters: 1000.0,
        sigmaCushionMeters: 100.0,
        reachableBoundMeters: double.negativeInfinity,
      );
      expect(r, 1100.0);
    });

    test('both statistical and reach unusable returns NaN (documented residual '
        'risk)', () {
      // No physics bound + uninitialised EKF: there is genuinely nothing to fire
      // on from this combiner. Callers must supply a reach bound during a
      // blackout (the tracker does). Pinning the behaviour so a refactor cannot
      // silently start returning a finite value that masks the gap.
      final r = Reachability.effectiveProgress(
        deadReckonedProgressMeters: double.nan,
        sigmaCushionMeters: 100.0,
        reachableBoundMeters: null,
      );
      expect(r.isNaN, isTrue);
    });

    test('SUSPECTED DEFECT: a +infinity reach (watchdog/overflow "fire now") is '
        'silently discarded, returning the smaller statistical bound', () {
      // reachability.dart documents: "an infinite ReachabilityBound.sMaxMeters
      // always fires". But effectiveProgress guards `reachableBoundMeters
      // .isFinite`, which rejects +inf exactly like NaN, so the fire-forcing
      // bound is dropped and the (finite, smaller) statistical value is used —
      // which can sit below the target and SUPPRESS the fire.
      final r = Reachability.effectiveProgress(
        deadReckonedProgressMeters: 1000.0,
        sigmaCushionMeters: 100.0,
        reachableBoundMeters: double.infinity,
      );
      expect(r, double.infinity,
          reason: 'An infinite physics bound is the strongest possible fire '
              'signal and must dominate the max(), never be discarded. '
              'Current returns $r.');
    });
  });

  // ------------------------------------------------------------------
  group('ReachabilityTracker edge cases (anchor lifecycle)', () {
    test('boundNow is null before any anchor exists', () {
      final t = ReachabilityTracker();
      expect(t.hasAnchor, isFalse);
      expect(t.boundNow(nowSeconds: 100.0), isNull);
    });

    test('seedColdStart is idempotent — a later re-seed must NOT move the anchor '
        '(that would collapse dt and fire late)', () {
      final t = ReachabilityTracker();
      t.seedColdStart(tSeconds: 0.0, sMeters: 0.0);
      // A second seed with a later time / further progress must be ignored.
      t.seedColdStart(tSeconds: 100.0, sMeters: 5000.0);
      expect(t.anchor!.tSeconds, 0.0);
      expect(t.anchor!.sMeters, 0.0);
      final b = t.boundNow(nowSeconds: 100.0)!;
      // dt stays the full 100 s from the original seed, not 0.
      expect(b.dtSeconds, closeTo(100.0, 1e-9));
    });

    test('reset() clears the anchor; boundNow returns null again', () {
      final t = ReachabilityTracker();
      t.onAcceptedFix(sMeters: 100.0, accuracyMeters: 5.0, tSeconds: 10.0);
      expect(t.hasAnchor, isTrue);
      t.reset();
      expect(t.hasAnchor, isFalse);
      expect(t.boundNow(nowSeconds: 50.0), isNull);
    });

    test('an equal-timestamp accepted fix is NOT rejected by the < guard (moves '
        'the anchor)', () {
      final t = ReachabilityTracker();
      t.onAcceptedFix(sMeters: 500.0, accuracyMeters: 10.0, tSeconds: 100.0);
      // Same timestamp, fresher progress: guard is `tSeconds < anchor.tSeconds`,
      // so equality passes through and updates the anchor.
      t.onAcceptedFix(sMeters: 2000.0, accuracyMeters: 8.0, tSeconds: 100.0);
      expect(t.anchor!.sMeters, 2000.0);
    });

    test('an unknown/absent line resolves to the default ceiling; an RRTS line '
        'to the higher one (tracker wiring never underestimates)', () {
      final t = ReachabilityTracker();
      t.seedColdStart(tSeconds: 0.0, sMeters: 0.0);
      final metro = t.boundNow(nowSeconds: 10.0)!; // lineName null => default
      expect(metro.sMaxMeters,
          closeTo(VLineTable.defaultMps * 10.0, 1e-9));
      final rrts = t.boundNow(nowSeconds: 10.0, lineName: 'Namo Bharat')!;
      expect(rrts.sMaxMeters, closeTo(VLineTable.rrtsMps * 10.0, 1e-9));
      expect(rrts.sMaxMeters, greaterThan(metro.sMaxMeters));
    });
  });

  // ------------------------------------------------------------------
  group('Corrupt anchor position', () {
    test('SUSPECTED DEFECT: a NaN anchor position produces a NaN bound that '
        'suppresses the alarm forever', () {
      final b = Reachability.bound(
        anchor: _a(double.nan, t: 0.0),
        nowSeconds: 100.0,
        vLineMps: 28.0,
      );
      // FIXED: a corrupt (NaN) anchor position must fail SAFE — force a fire —
      // never silently suppress the alarm via a NaN bound. The bound is now the
      // fire-forcing sentinel rather than NaN.
      expect(b.sMaxMeters.isNaN, isFalse);
      expect(Reachability.reachesTarget(b, 12000.0), isTrue,
          reason: 'A NaN anchor position must fail safe (fire), not suppress '
              'the alarm via a NaN bound.');
    });
  });
}
