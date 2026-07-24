// test/reachability/reachability_test.dart
//
// DETERMINISTIC PROOF that the reachability Protection Level never fires late.
//
// The central theorem: for ANY train trajectory whose speed never exceeds
// V_LINE, the reachability bound s_max(t) is an upper bound on true arc-progress
// at every instant, given a valid anchor. We prove it by exhaustively simulating
// thousands of seeded-random bounded trajectories and asserting the invariant at
// every sampled time — then we prove each of the three preconditions is
// load-bearing by showing that violating it produces an actual late fire.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';

/// A deterministic bounded-speed train simulator.
///
/// Advances progress in fixed steps, choosing a speed in [0, trueMaxMps] each
/// step. Optionally enforces a minimum dwell at each station (models a stopping
/// service). Records (t, progress) samples so tests can assert bounds.
class _TrainSim {
  final double trueMaxMps;
  final double stepSeconds;
  final List<double> stationMeters;
  final double dwellSeconds; // 0 => express-style, never dwells
  final math.Random rng;

  double t = 0.0;
  double progress = 0.0;
  int _nextStationIdx = 0;
  double _dwellRemaining = 0.0;

  _TrainSim({
    required this.trueMaxMps,
    required this.stationMeters,
    this.dwellSeconds = 0.0,
    required int seed,
  }) : stepSeconds = 1.0, rng = math.Random(seed);

  /// One tick. Returns the (t, progress) after the tick.
  void step() {
    t += stepSeconds;
    if (_dwellRemaining > 0) {
      _dwellRemaining = math.max(0.0, _dwellRemaining - stepSeconds);
      return; // stopped at a station, no progress
    }
    // Random speed in [0, trueMax]; occasionally full speed to stress the bound.
    final speed = (rng.nextDouble() < 0.3)
        ? trueMaxMps
        : rng.nextDouble() * trueMaxMps;
    final nextPos = progress + speed * stepSeconds;

    // If we would pass the next station, stop AT it and begin dwelling.
    if (_nextStationIdx < stationMeters.length &&
        nextPos >= stationMeters[_nextStationIdx]) {
      progress = stationMeters[_nextStationIdx];
      _nextStationIdx++;
      _dwellRemaining = dwellSeconds;
    } else {
      progress = nextPos;
    }
  }
}

void main() {
  group('Reachability free-run bound is never-late (core theorem)', () {
    test('s_max >= true progress for thousands of bounded trajectories', () {
      const vLine = VLineTable.defaultMps; // 28 m/s ceiling
      int checks = 0;
      for (int seed = 0; seed < 400; seed++) {
        // True max strictly <= vLine (precondition ii holds).
        final trueMax = 5.0 + (seed % 20); // 5..24 m/s, all <= 28
        final sim = _TrainSim(
          trueMaxMps: trueMax.toDouble(),
          stationMeters: const [],
          seed: seed,
        );

        // Establish an anchor at a random early moment with realistic accuracy.
        // Run a few ticks first, then anchor to the true state (perfect fix).
        final warmup = 3 + (seed % 5);
        for (int i = 0; i < warmup; i++) {
          sim.step();
        }
        final anchor = ReachabilityAnchor(
          sMeters: sim.progress,
          accuracyMeters: 15.0, // typical GPS accuracy, overbounds forward
          tSeconds: sim.t,
        );

        // Simulate a long blackout and assert the invariant every tick.
        for (int i = 0; i < 1200; i++) {
          sim.step();
          final b = Reachability.bound(
            anchor: anchor,
            nowSeconds: sim.t,
            vLineMps: vLine,
          );
          checks++;
          expect(
            b.sMaxMeters,
            greaterThanOrEqualTo(sim.progress - 1e-6),
            reason:
                'LATE-FIRE VIOLATION seed=$seed t=${sim.t}: bound=${b.sMaxMeters} '
                '< true progress=${sim.progress}',
          );
        }
      }
      expect(checks, greaterThan(400 * 1000));
    });

    test('bound grows exactly linearly at V_LINE from the overbounded anchor',
        () {
      final anchor = ReachabilityAnchor(
        sMeters: 1000.0,
        accuracyMeters: 20.0,
        tSeconds: 100.0,
      );
      final b = Reachability.bound(
        anchor: anchor,
        nowSeconds: 100.0 + 60.0, // 60 s later
        vLineMps: 28.0,
      );
      // s0_hi = 1020; + 28*60 = 1680 => 2700
      expect(b.sMaxMeters, closeTo(1020.0 + 28.0 * 60.0, 1e-9));
      expect(b.dtSeconds, closeTo(60.0, 1e-9));
    });
  });

  group('The three preconditions are load-bearing (violation => late fire)', () {
    test('(ii) V_LINE below true max speed CAN underestimate (fires late)', () {
      // Train genuinely faster than the (wrong) V_LINE we plug in.
      final sim = _TrainSim(
        trueMaxMps: 30.0,
        stationMeters: const [],
        seed: 7,
      );
      for (int i = 0; i < 5; i++) {
        sim.step();
      }
      final anchor = ReachabilityAnchor(
        sMeters: sim.progress,
        accuracyMeters: 0.0,
        tSeconds: sim.t,
      );
      bool sawUnderestimate = false;
      for (int i = 0; i < 300; i++) {
        sim.step();
        final b = Reachability.bound(
          anchor: anchor,
          nowSeconds: sim.t,
          vLineMps: 20.0, // WRONG: below the train's 30 m/s true max
        );
        if (b.sMaxMeters < sim.progress - 1.0) {
          sawUnderestimate = true;
          break;
        }
      }
      expect(sawUnderestimate, isTrue,
          reason:
              'Precondition (ii) must be load-bearing: an under-set V_LINE '
              'should be able to underestimate true progress.');
    });

    test('(i) an anchor planted BEHIND true position underestimates (late)', () {
      final sim = _TrainSim(
        trueMaxMps: 20.0,
        stationMeters: const [],
        seed: 11,
      );
      for (int i = 0; i < 20; i++) {
        sim.step();
      }
      // Phantom: anchor claims we are 2 km behind where we truly are.
      final phantomAnchor = ReachabilityAnchor(
        sMeters: sim.progress - 2000.0,
        accuracyMeters: 10.0,
        tSeconds: sim.t,
      );
      final b = Reachability.bound(
        anchor: phantomAnchor,
        nowSeconds: sim.t, // no elapsed time => bound ~ anchor.sHi
        vLineMps: 28.0,
      );
      expect(b.sMaxMeters, lessThan(sim.progress),
          reason:
              'A phantom anchor behind true position defeats the guarantee — '
              'this is why precondition (i) (real anchor) is mandatory.');
    });

    test('(iii) resetting t on a non-true tick shrinks dt and underestimates',
        () {
      final sim = _TrainSim(
        trueMaxMps: 20.0,
        stationMeters: const [],
        seed: 13,
      );
      // True anchor at t0.
      for (int i = 0; i < 5; i++) {
        sim.step();
      }
      final trueAnchor = ReachabilityAnchor(
        sMeters: sim.progress,
        accuracyMeters: 10.0,
        tSeconds: sim.t,
      );
      // Run a long real blackout.
      for (int i = 0; i < 120; i++) {
        sim.step();
      }
      final now = sim.t;

      // Correct bound (dt from the true anchor) is a valid upper bound.
      final correct = Reachability.bound(
        anchor: trueAnchor,
        nowSeconds: now,
        vLineMps: 28.0,
      );
      expect(correct.sMaxMeters, greaterThanOrEqualTo(sim.progress - 1e-6));

      // BUG shape: a snapped dwell wrongly reset t to "now-5s" without moving
      // the anchor position. dt collapses => bound underestimates.
      final bogusAnchor = ReachabilityAnchor(
        sMeters: trueAnchor.sMeters,
        accuracyMeters: 10.0,
        tSeconds: now - 5.0, // pretends the fix is fresh
      );
      final bogus = Reachability.bound(
        anchor: bogusAnchor,
        nowSeconds: now,
        vLineMps: 28.0,
      );
      expect(bogus.sMaxMeters, lessThan(sim.progress),
          reason:
              'Resetting t on a non-true tick collapses dt and fires late — '
              'why the anchor must reset ONLY on a gate-passing fix.');
    });
  });

  group('Stop-count topology cap: safe when dwell lower-bounds hold, tighter',
      () {
    final stations = <double>[for (int i = 1; i <= 20; i++) i * 800.0]; // 800m spacing

    test('cap stays an upper bound for a stopping service (dwell >= dwellMin)',
        () {
      const vLine = 28.0;
      const dwellMin = 15.0;
      final topo = RouteTopology(stationMeters: stations, dwellMinSeconds: dwellMin);
      const config = ReachabilityConfig(dwellMinSeconds: dwellMin);

      int checks = 0;
      for (int seed = 100; seed < 260; seed++) {
        // Train dwells AT LEAST dwellMin (here exactly dwellMin..dwellMin+10).
        final sim = _TrainSim(
          trueMaxMps: 22.0, // <= vLine
          stationMeters: stations,
          dwellSeconds: dwellMin + (seed % 10).toDouble(),
          seed: seed,
        );
        for (int i = 0; i < 5; i++) {
          sim.step();
        }
        final anchor = ReachabilityAnchor(
          sMeters: sim.progress,
          accuracyMeters: 10.0,
          tSeconds: sim.t,
        );
        for (int i = 0; i < 900; i++) {
          sim.step();
          final b = Reachability.bound(
            anchor: anchor,
            nowSeconds: sim.t,
            vLineMps: vLine,
            topology: topo,
            config: config,
          );
          checks++;
          expect(b.sMaxMeters, greaterThanOrEqualTo(sim.progress - 1e-6),
              reason:
                  'Topology cap must remain an UPPER bound seed=$seed t=${sim.t}');
        }
      }
      expect(checks, greaterThan(0));
    });

    test('cap is strictly tighter than free-run after several stations', () {
      const vLine = 28.0;
      const dwellMin = 20.0;
      final topo = RouteTopology(stationMeters: stations, dwellMinSeconds: dwellMin);
      const config = ReachabilityConfig(dwellMinSeconds: dwellMin);
      final anchor = ReachabilityAnchor(
        sMeters: 0.0,
        accuracyMeters: 0.0,
        tSeconds: 0.0,
      );
      // After 600 s the train must have paid dwell at multiple stations.
      final b = Reachability.bound(
        anchor: anchor,
        nowSeconds: 600.0,
        vLineMps: vLine,
        topology: topo,
        config: config,
      );
      expect(b.sMaxMeters, lessThan(b.freeRunMeters - 100.0),
          reason: 'The stop-count cap should tighten the bound meaningfully.');
    });

    test('cap UNDERESTIMATES for an express skipping dwells (precondition)', () {
      const vLine = 28.0;
      const dwellMin = 20.0;
      final topo = RouteTopology(stationMeters: stations, dwellMinSeconds: dwellMin);
      const config = ReachabilityConfig(dwellMinSeconds: dwellMin);
      // Express that never dwells but respects vLine.
      final sim = _TrainSim(
        trueMaxMps: 27.0,
        stationMeters: stations,
        dwellSeconds: 0.0, // VIOLATES the dwellMin lower bound
        seed: 5,
      );
      final anchor = ReachabilityAnchor(
        sMeters: 0.0,
        accuracyMeters: 0.0,
        tSeconds: 0.0,
      );
      bool sawUnderestimate = false;
      for (int i = 0; i < 600; i++) {
        sim.step();
        final b = Reachability.bound(
          anchor: anchor,
          nowSeconds: sim.t,
          vLineMps: vLine,
          topology: topo,
          config: config,
        );
        if (b.sMaxMeters < sim.progress - 1.0) {
          sawUnderestimate = true;
          break;
        }
      }
      expect(sawUnderestimate, isTrue,
          reason:
              'A non-stopping express violates the dwell lower bound, so the '
              'topology cap is only safe when dwellMin truly lower-bounds dwell. '
              'The free-run bound (dwellMin=0) stays safe unconditionally.');
    });

    test('free-run bound (dwellMin=0) stays safe even for the express', () {
      const vLine = 28.0;
      final sim = _TrainSim(
        trueMaxMps: 27.0,
        stationMeters: stations,
        dwellSeconds: 0.0,
        seed: 5,
      );
      final anchor = ReachabilityAnchor(
        sMeters: 0.0,
        accuracyMeters: 0.0,
        tSeconds: 0.0,
      );
      for (int i = 0; i < 600; i++) {
        sim.step();
        final b = Reachability.bound(
          anchor: anchor,
          nowSeconds: sim.t,
          vLineMps: vLine, // no topology => unconditional free-run
        );
        expect(b.sMaxMeters, greaterThanOrEqualTo(sim.progress - 1e-6));
      }
    });
  });

  group('T_max watchdog + cold-start closure', () {
    test('hard T_max forces a fire regardless of geometry', () {
      final anchor = ReachabilityAnchor(
        sMeters: 0.0,
        accuracyMeters: 0.0,
        tSeconds: 0.0,
      );
      const config = ReachabilityConfig(hardTMaxSeconds: 300.0);
      final before = Reachability.bound(
        anchor: anchor,
        nowSeconds: 299.0,
        vLineMps: 28.0,
        config: config,
      );
      expect(before.watchdogTripped, isFalse);
      final after = Reachability.bound(
        anchor: anchor,
        nowSeconds: 301.0,
        vLineMps: 28.0,
        config: config,
      );
      expect(after.watchdogTripped, isTrue);
      expect(Reachability.reachesTarget(after, 1e9), isTrue,
          reason: 'Watchdog must fire even for an unreachably-far target.');
    });

    test('cold-start tracker fires with ZERO real fixes (closes GLMT-03)', () {
      // The EKF path shows GLMT-03: never initialises -> never fires. The
      // reachability tracker seeds at trip origin and fires by physics alone.
      final tracker = ReachabilityTracker();
      tracker.seedColdStart(tSeconds: 0.0, sMeters: 0.0);
      const targetMeters = 24071.0; // matches the synthetic cold-start target

      double? fireTime;
      for (double now = 1.0; now <= 4000.0; now += 1.0) {
        final b = tracker.boundNow(nowSeconds: now);
        if (b != null && Reachability.reachesTarget(b, targetMeters)) {
          fireTime = now;
          break;
        }
      }
      expect(fireTime, isNotNull,
          reason: 'Cold start MUST eventually fire by reachability.');
      // Earliest-possible arrival at the metro default V_LINE: 24071/28 ~= 860 s.
      // Fire at/after (never earlier than the physics could allow).
      expect(fireTime!,
          greaterThanOrEqualTo(targetMeters / VLineTable.defaultMps - 1.0));
    });
  });

  group('Fire timing on a concrete line is always at-or-before true arrival',
      () {
    test('across a family of blackout start times and durations', () {
      const vLine = 28.0;
      const targetMeters = 12000.0;
      int scenarios = 0;
      for (int seed = 300; seed < 360; seed++) {
        final sim = _TrainSim(
          trueMaxMps: 18.0, // realistic metro cruise, <= vLine
          stationMeters: const [],
          seed: seed,
        );
        // Find the true arrival time at the target.
        double? trueArrival;
        final tracker = ReachabilityTracker();
        // Anchor once at t=0 (worst case: never re-anchors during the ride).
        tracker.seedColdStart(tSeconds: 0.0, sMeters: 0.0);
        double? fireTime;
        for (int i = 0; i < 5000; i++) {
          sim.step();
          if (trueArrival == null && sim.progress >= targetMeters) {
            trueArrival = sim.t;
          }
          if (fireTime == null) {
            final b = tracker.boundNow(nowSeconds: sim.t);
            if (b != null && Reachability.reachesTarget(b, targetMeters)) {
              fireTime = sim.t;
            }
          }
          if (trueArrival != null && fireTime != null) break;
        }
        expect(fireTime, isNotNull);
        expect(trueArrival, isNotNull);
        scenarios++;
        expect(fireTime!, lessThanOrEqualTo(trueArrival! + 1e-6),
            reason:
                'NEVER LATE: fire@$fireTime must be <= true arrival@$trueArrival '
                'seed=$seed');
      }
      expect(scenarios, 60);
    });
  });

  group('effectiveProgress + anchor bookkeeping', () {
    test('effectiveProgress takes the max of statistical and physics bounds',
        () {
      // Physics dominates.
      expect(
        Reachability.effectiveProgress(
          deadReckonedProgressMeters: 1000.0,
          sigmaCushionMeters: 100.0,
          reachableBoundMeters: 1500.0,
        ),
        1500.0,
      );
      // Statistical dominates.
      expect(
        Reachability.effectiveProgress(
          deadReckonedProgressMeters: 1000.0,
          sigmaCushionMeters: 600.0,
          reachableBoundMeters: 1500.0,
        ),
        1600.0,
      );
      // Null reachable => statistical only.
      expect(
        Reachability.effectiveProgress(
          deadReckonedProgressMeters: 1000.0,
          sigmaCushionMeters: 100.0,
          reachableBoundMeters: null,
        ),
        1100.0,
      );
    });

    test('onAcceptedFix resets dt; monotonic guard rejects stale timestamps',
        () {
      final tracker = ReachabilityTracker();
      tracker.onAcceptedFix(sMeters: 500.0, accuracyMeters: 10.0, tSeconds: 100.0);
      final b1 = tracker.boundNow(nowSeconds: 160.0)!;
      expect(b1.dtSeconds, closeTo(60.0, 1e-9));

      // Fresh accepted fix resets the anchor => dt shrinks.
      tracker.onAcceptedFix(sMeters: 2000.0, accuracyMeters: 8.0, tSeconds: 155.0);
      final b2 = tracker.boundNow(nowSeconds: 160.0)!;
      expect(b2.dtSeconds, closeTo(5.0, 1e-9));
      expect(b2.sMaxMeters, closeTo(2008.0 + VLineTable.defaultMps * 5.0, 1e-6));

      // Stale timestamp is ignored (monotonic guard).
      tracker.onAcceptedFix(sMeters: 9999.0, accuracyMeters: 8.0, tSeconds: 150.0);
      final b3 = tracker.boundNow(nowSeconds: 160.0)!;
      expect(b3.sMaxMeters, closeTo(2008.0 + VLineTable.defaultMps * 5.0, 1e-6),
          reason: 'Stale (earlier) fix must not move the anchor.');
    });

    test('VLineTable resolves RRTS/express/default and honours overrides', () {
      const table = VLineTable(overrides: {'delhi|blue': 30.0});
      expect(table.forLine(city: 'Delhi', lineName: 'Blue'), 30.0);
      expect(table.forLine(lineName: 'Airport Express'),
          VLineTable.expressMps);
      // An unmatched conventional metro line resolves to the metro default
      // (correct over-bound for ~80-90 km/h metros); the narrow fast-line residual
      // is documented in forLine and closed by the dataset.
      expect(table.forLine(lineName: 'Green'), VLineTable.defaultMps);
      // FINDING 2 mitigation: Mumbai suburban ("...suburban"/"local") now resolves
      // to the express tier so a ~120 km/h EMU doesn't fall to the metro default.
      expect(table.forLine(lineName: 'Mumbai Suburban'), VLineTable.expressMps);
      expect(table.forLine(lineName: 'Western Local'), VLineTable.expressMps);
      // RRTS / Namo Bharat / Delhi-Meerut must resolve to the high ceiling.
      expect(table.forLine(city: 'delhimeerutrrts', lineName: '1 2'),
          VLineTable.rrtsMps);
      expect(table.forLine(lineName: 'Namo Bharat'), VLineTable.rrtsMps);
      expect(table.forLine(lineName: 'RapidX'), VLineTable.rrtsMps);
      expect(VLineTable.rrtsMps, greaterThan(VLineTable.expressMps));
    });

    test('RRTS ceiling closes precondition (ii) for a 160 km/h regional train',
        () {
      // Delhi-Meerut RRTS runs ~160 km/h (44.4 m/s), far above the 28 m/s metro
      // default. With the correct RRTS V_LINE the physics bound stays safe;
      // with the metro default it would UNDERESTIMATE and fire late.
      const table = VLineTable();
      final vRrts = table.forLine(city: 'delhimeerutrrts', lineName: '1 2');
      final vMetroWrong = VLineTable.defaultMps;
      final sim = _TrainSim(
        trueMaxMps: 44.4, // 160 km/h RRTS
        stationMeters: const [],
        seed: 42,
      );
      for (int i = 0; i < 5; i++) {
        sim.step();
      }
      final anchor = ReachabilityAnchor(
        sMeters: sim.progress,
        accuracyMeters: 10.0,
        tSeconds: sim.t,
      );
      bool wrongUnderestimated = false;
      for (int i = 0; i < 400; i++) {
        sim.step();
        final safe = Reachability.bound(
            anchor: anchor, nowSeconds: sim.t, vLineMps: vRrts);
        final wrong = Reachability.bound(
            anchor: anchor, nowSeconds: sim.t, vLineMps: vMetroWrong);
        // Correct RRTS ceiling: always an upper bound (never late).
        expect(safe.sMaxMeters, greaterThanOrEqualTo(sim.progress - 1e-6),
            reason: 'RRTS ceiling must keep the bound safe at t=${sim.t}');
        // Metro default: provably underestimates for this fast train.
        if (wrong.sMaxMeters < sim.progress - 1.0) wrongUnderestimated = true;
      }
      expect(wrongUnderestimated, isTrue,
          reason: 'Metro V_LINE on an RRTS line is a real late-fire hazard — '
              'exactly why looksRrts() routes it to the higher ceiling.');
    });
  });
}
