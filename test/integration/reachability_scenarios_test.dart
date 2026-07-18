// test/integration/reachability_scenarios_test.dart
//
// CROSS-CUTTING RELIABILITY: the REAL AlarmEvaluator.evaluateCoinciding driven
// with the REAL Reachability physics bound, on small synthetic metro legs.
//
// The cardinal sin for a wake alarm is firing LATE or never firing. Every test
// here attacks exactly that: it drives the stops-mode metro path with a
// dead-reckoned progress that is stuck/frozen/NaN (the underground GPS-blackout
// reality) and a physics reachability bound that grows with wall-clock time, and
// asserts the alarm ALWAYS fires at-or-before the earliest possible true arrival
// at the "N stops remain" target — never later, and never never.
//
// The evaluator's stops-metro branch folds reachability in via
//   effectiveProgressForStops = Reachability.effectiveProgress(
//       deadReckoned = progressMeters,
//       sigmaCushion = k * clamp(sigmaS, 0, 300),
//       reachableBound = reachableProgressBoundMeters)
// counting a stop "reached" as soon as EITHER upper bound passes it. These tests
// exercise that fold end-to-end against the real physics in reachability.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/core/reachability/reachability.dart';
import 'package:geowake2/config/fire_decision_config.dart';

void main() {
  // --------------------------------------------------------------------------
  // Synthetic metro leg: [0, 10000] m with 9 intermediate stops.
  //
  // TransferUtils places intermediate stop j at start + j/(n+1) * length, i.e.
  // 1000, 2000, ..., 9000 m. The alighting station is the leg end (10000 m) and
  // counts as the +1 "target" stop.
  //
  // "N stops prior" fires when remainingStopsToTarget <= N, where
  //   remainingStopsToTarget = (9 - passedIntermediate) + 1.
  // For N = 2 that means passedIntermediate >= 8, i.e. effective progress must
  // reach the 8th intermediate stop at 8000 m. So 8000 m is the exact physical
  // point at which "2 stops remain" — the never-late target for N = 2.
  // --------------------------------------------------------------------------
  const double kLength = 10000.0;
  const int kNumStops = 9;
  const double kVLine = VLineTable.defaultMps; // 28 m/s
  const double kTargetN2 = 8000.0; // effective-progress fire target for N=2

  TransitLegStops metroLeg({
    int numStops = kNumStops,
    double startMeters = 0.0,
    double length = kLength,
  }) {
    return TransitLegStops(
      legStartMeters: startMeters,
      legEndMeters: startMeters + length,
      numStops: numStops,
      stopPositions: List.generate(numStops, (_) => const LatLng(0, 0)),
      stopMeters: List.generate(
        numStops,
        (i) => startMeters + ((i + 1) * (length / (numStops + 1))),
      ),
      lineName: 'Metro Line',
      isActualPositions: true,
      isMetro: true,
      stopNames: List.generate(numStops, (i) => 'Stop $i'),
    );
  }

  final defaultLegs = [metroLeg()];

  AlarmTrigger? evalStops({
    required double progress,
    double userValue = 2.0,
    double? reach,
    double sigma = 0.0,
    List<TransitLegStops>? legs,
    bool isFinalLeg = true,
    Set<String>? fired,
  }) {
    return AlarmEvaluator.evaluateCoinciding(
      mode: AlarmMode.stops,
      userValue: userValue,
      progressMeters: progress,
      allEvents: const <RouteEventBoundary>[],
      firedEventIndexes: <int>{},
      firedLegIds: fired ?? <String>{},
      isMetroLeg: true,
      transitLegs: legs ?? defaultLegs,
      currentLegIndex: 0,
      isFinalLeg: isFinalLeg,
      positionSigmaMeters: sigma,
      reachableProgressBoundMeters: reach,
    );
  }

  // Real physics bound from an anchor. Mirrors the production path
  // (Reachability.bound) so we never hand-roll the number under test.
  double reachBoundAt({
    required double anchorS,
    required double anchorAcc,
    required double t0,
    required double now,
    double vLine = kVLine,
  }) {
    final b = Reachability.bound(
      anchor: ReachabilityAnchor(
        sMeters: anchorS,
        accuracyMeters: anchorAcc,
        tSeconds: t0,
      ),
      nowSeconds: now,
      vLineMps: vLine,
    );
    return b.sMaxMeters;
  }

  // ==========================================================================
  // (1) GPS blackout longer than the whole route: reachability MUST eventually
  //     fire. The dead-reckoned/EKF estimate never initialises (cold start ->
  //     NaN) or is frozen, yet the alarm must never be a never-fire.
  // ==========================================================================
  group('(1) blackout longer than route — never never-fire', () {
    test(
        'cold start: NaN dead-reckoned progress + physics bound still fires, '
        'and never earlier than physics allows', () {
      // Real cold-start bootstrap: seed the anchor at trip origin, zero real
      // fixes ever arrive (fully underground from t0).
      final tracker = ReachabilityTracker()
        ..seedColdStart(tSeconds: 0.0, sMeters: 0.0);

      double? fireT;
      String? evType;
      for (double now = 1.0; now <= 3000.0; now += 1.0) {
        final b = tracker.boundNow(nowSeconds: now, lineName: 'Metro Line');
        final reach =
            (b != null && b.sMaxMeters.isFinite) ? b.sMaxMeters : null;
        final trig = evalStops(progress: double.nan, reach: reach);
        if (trig != null) {
          fireT = now;
          evType = trig.eventType;
          break;
        }
      }

      // NEVER never-fire: a physics fire happens even with NaN progress.
      expect(fireT, isNotNull,
          reason: 'Cold-start NaN progress must still fire by reachability.');
      expect(evType, AlarmEventType.finalDestination);
      // Physics floor: cannot reach 8000 m before 8000/28 s at V_LINE. The
      // fire is at/after that — proving it is the physics bound driving it, not
      // some spurious early/late path.
      expect(fireT!, greaterThanOrEqualTo(kTargetN2 / kVLine - 1.0));
    });

    test(
        'WITHOUT reachability, NaN dead-reckoned progress NEVER fires '
        '(the hole reachability closes)', () {
      // Same cold-start blackout but reachableProgressBoundMeters == null.
      // math.max(NaN, cushion) is NaN, every "stop reached" test is false, and
      // the alarm silently never fires. This is the exact never-fire hazard.
      for (double now = 1.0; now <= 3000.0; now += 25.0) {
        expect(evalStops(progress: double.nan, reach: null), isNull,
            reason: 'Legacy path with NaN progress must be a proven no-fire '
                'so the reachability closure is load-bearing.');
      }
    });

    test('frozen finite progress, blackout > full traversal: fires by physics',
        () {
      // GPS died at 500 m; EKF froze there. Blackout runs far past the time a
      // real train would have finished the whole 10 km route.
      const s0 = 500.0;
      double? fireT;
      for (double now = 0.0; now <= 3000.0; now += 1.0) {
        final reach = reachBoundAt(
            anchorS: s0, anchorAcc: 0.0, t0: 0.0, now: now);
        final trig = evalStops(progress: s0, reach: reach);
        if (trig != null) {
          fireT = now;
          break;
        }
      }
      expect(fireT, isNotNull);
      // reach reaches 8000 at (8000-500)/28 s; fire no earlier than that.
      expect(fireT!, greaterThanOrEqualTo((kTargetN2 - s0) / kVLine - 1.0));
    });
  });

  // ==========================================================================
  // (2) EKF progress frozen (dead-reckoned stuck) but reachable bound growing:
  //     must still fire at/before true arrival. Also demonstrates that the
  //     statistical path ALONE (frozen progress, even with a huge but CLAMPED
  //     sigma) can never reach the target — reachability is what saves it.
  // ==========================================================================
  group('(2) frozen progress, growing reach — fires at/before arrival', () {
    test('frozen at 5000 m: reach-driven fire precedes a 15 m/s true arrival',
        () {
      const s0 = 5000.0; // last real fix before the tunnel
      const trueSpeed = 15.0; // <= V_LINE
      final trueArrival = kTargetN2 / trueSpeed; // when 2 stops truly remain

      double? fireT;
      for (double now = 0.0; now <= 3000.0; now += 1.0) {
        final reach = reachBoundAt(
            anchorS: s0, anchorAcc: 0.0, t0: 0.0, now: now);
        final trig = evalStops(progress: s0, reach: reach);
        if (trig != null) {
          fireT = now;
          expect(trig.eventType, AlarmEventType.finalDestination);
          break;
        }
      }
      expect(fireT, isNotNull, reason: 'Frozen EKF must not suppress the fire.');
      // NEVER LATE.
      expect(fireT!, lessThanOrEqualTo(trueArrival + 1e-6));
    });

    test(
        'frozen progress alone (reach=null) NEVER fires — reachability is '
        'load-bearing', () {
      const s0 = 5000.0; // 5 intermediate stops passed => 5 remain, N=2 => no
      for (double now = 0.0; now <= 3000.0; now += 30.0) {
        expect(evalStops(progress: s0, reach: null), isNull);
      }
    });

    test(
        'CLAMP GAP: a huge sigma cushion (capped at k*300=600 m) still cannot '
        'reach the target from 7000 m, but the UNCLAMPED reach bound does', () {
      // Statistical alone: 7000 + min(sigma,300)*2 <= 7600 < 8000 => no fire,
      // no matter how large sigma grows. This is the clamped-sigma late hazard.
      expect(evalStops(progress: 7000.0, sigma: 100000.0, reach: null), isNull,
          reason: 'Clamped sigma cushion tops out at 600 m and cannot span '
              '7000->8000; relying on it alone would fire late.');
      // Reachability is unclamped: a physics bound at/after 8000 fires.
      expect(evalStops(progress: 7000.0, sigma: 100000.0, reach: kTargetN2),
          isNotNull);
    });
  });

  // ==========================================================================
  // NEVER-LATE crown: sweep a family of blackout start times and true speeds,
  // driving evaluateCoinciding with the real physics bound each tick. The fire
  // must land at-or-before the true arrival at the "2 stops remain" point for
  // EVERY case — and never never-fire.
  // ==========================================================================
  group('never-late across blackout start times and true speeds', () {
    test('fire tick <= true arrival for every (t0, trueSpeed)', () {
      int scenarios = 0;
      // True speeds strictly below V_LINE (28 m/s) so the physics fire lands
      // comfortably before true arrival even after 1 s time-sampling. (At the
      // exact V_LINE ceiling fire == arrival in the continuous limit; the
      // reachability unit tests cover that measure-zero boundary continuously.)
      for (final trueSpeed in <double>[8, 12, 16, 20, 24]) {
        for (final t0 in <double>[0.0, 60.0]) {
          final s0 = trueSpeed * t0; // real fix at the moment GPS died
          // Keep the anchor short of the target so the reach bound is the driver.
          expect(s0, lessThan(kTargetN2));
          final trueArrival = kTargetN2 / trueSpeed;

          double? fireT;
          double reachAtFire = double.nan;
          for (double now = t0; now <= t0 + 4000.0; now += 1.0) {
            final reach = reachBoundAt(
                anchorS: s0, anchorAcc: 0.0, t0: t0, now: now);
            final trig = evalStops(progress: s0, reach: reach);
            if (trig != null) {
              fireT = now;
              reachAtFire = reach;
              expect(trig.eventType, AlarmEventType.finalDestination);
              break;
            }
          }

          expect(fireT, isNotNull,
              reason: 'never never-fire (trueSpeed=$trueSpeed, t0=$t0)');
          // Physics-justified, not spurious: frozen progress (s0 < target,
          // sigma 0) can never fire on its own, so the reach bound MUST have
          // reached the target at the fire tick.
          expect(reachAtFire, greaterThanOrEqualTo(kTargetN2 - 1e-6),
              reason: 'fire was not driven by the reach bound reaching target');
          // NEVER LATE.
          expect(fireT!, lessThanOrEqualTo(trueArrival + 1e-6),
              reason:
                  'LATE FIRE: fire@$fireT > trueArrival@$trueArrival '
                  '(trueSpeed=$trueSpeed, t0=$t0)');
          scenarios++;
        }
      }
      expect(scenarios, 10);
    });

    test('reach just below target does not fire; at/above target does', () {
      // Exactly characterises the fire boundary as the physics target crossing.
      expect(evalStops(progress: 0.0, reach: kTargetN2 - 1.0), isNull);
      expect(evalStops(progress: 0.0, reach: kTargetN2), isNotNull);
    });
  });

  // ==========================================================================
  // (3) Reach bound and dead-reckoned progress DISAGREE: effectiveProgress is
  //     their max, so combining is NEVER later than either signal alone. We
  //     assert the crisp equivalence over a grid:
  //       fires(P, R)  <=>  fires_statistical(P)  OR  fires_reach(R)
  //     where fires_statistical uses reach=null (effProg = P) and fires_reach
  //     uses progress=0 (effProg = max(0,R) = R).
  // ==========================================================================
  group('(3) effectiveProgress = max(dead-reckoned, reach) — never later', () {
    bool fires(double progress, {double? reach}) =>
        evalStops(progress: progress, reach: reach, sigma: 0.0) != null;

    test('combined fires iff statistical-alone OR reach-alone fires', () {
      const progresses = <double>[0, 3000, 7000, 7999, 8000, 8500, 9500, 12000];
      const reaches = <double>[0, 1000, 5000, 7999, 8000, 8600, 1e9];
      int cases = 0;
      for (final p in progresses) {
        for (final r in reaches) {
          final statAlone = fires(p, reach: null); // effProg = p
          final reachAlone = fires(0.0, reach: r); // effProg = r
          final combined = fires(p, reach: r); // effProg = max(p, r)
          expect(combined, statAlone || reachAlone,
              reason: 'max() must fire exactly when either input would '
                  '(p=$p, r=$r): stat=$statAlone reach=$reachAlone '
                  'combined=$combined');
          // And combining can only advance, never delay: whenever either input
          // fires, the combination fires too.
          if (statAlone || reachAlone) {
            expect(combined, isTrue);
          }
          cases++;
        }
      }
      expect(cases, progresses.length * reaches.length);
    });

    test('a below-progress reach bound cannot delay a fire the EKF already earns',
        () {
      // EKF already at the target; a lagging reach bound must not suppress it.
      expect(evalStops(progress: 8000.0, reach: null), isNotNull);
      expect(evalStops(progress: 8000.0, reach: 100.0), isNotNull);
      expect(evalStops(progress: 8000.0, reach: 0.0), isNotNull);
    });
  });

  // ==========================================================================
  // (4) A reach bound far PAST the target fires immediately (watchdog-like),
  //     never suppressed — regardless of frozen/zero progress or threshold.
  // ==========================================================================
  group('(4) reach far past target fires immediately, never suppressed', () {
    test('huge finite reach fires now for every threshold N in 1..9', () {
      for (int n = 1; n <= kNumStops; n++) {
        final trig = evalStops(
            progress: 0.0, userValue: n.toDouble(), reach: 1e9);
        expect(trig, isNotNull, reason: 'N=$n must fire on a far-past bound.');
        expect(trig!.eventType, AlarmEventType.finalDestination);
      }
    });

    test('reach past the leg end fires even with zero progress and zero sigma',
        () {
      expect(evalStops(progress: 0.0, sigma: 0.0, reach: kLength + 5000.0),
          isNotNull);
    });

    test('not suppressed by an unrelated already-fired leg id', () {
      // firedLegIds contains some OTHER leg's id; this leg has not fired.
      final trig = evalStops(
        progress: 0.0,
        reach: 1e9,
        fired: <String>{'SomeOtherLine_A_B'},
      );
      expect(trig, isNotNull);
    });

    test(
        'FIXED: an INFINITE reach (T_max watchdog / corrupt-input fail-safe) '
        'now FORCES a fire through the evaluator, never suppressed', () {
      // Previously effectiveProgress and the controller both filtered infinity
      // (isFinite guard), silently dropping the strongest possible fire signal —
      // a never-fire footgun if the watchdog were ever enabled. Both layers now
      // pass +infinity through: it makes every stop count as reached and fires.
      final trig = evalStops(progress: 0.0, reach: double.infinity);
      expect(trig, isNotNull,
          reason: 'an infinite (fire-forcing) reach must fire the alarm');
      expect(trig!.eventType, AlarmEventType.finalDestination);
      // The pure predicate also fires on an infinite bound.
      expect(
        Reachability.reachesTarget(
          const ReachabilityBound(
            sMaxMeters: double.infinity,
            freeRunMeters: 0,
            dtSeconds: 999,
            watchdogTripped: true,
          ),
          kTargetN2,
        ),
        isTrue,
      );
    });
  });

  // ==========================================================================
  // (5) Passing null reachableProgressBoundMeters reproduces the legacy
  //     (statistical-only) behavior EXACTLY: effProg = progress + k*clamp(sigma).
  // ==========================================================================
  group('(5) null reach == legacy statistical-only behavior', () {
    double cushion(double sigma) =>
        FireDecisionConfig.fractileK *
        sigma.clamp(0.0, FireDecisionConfig.maxFractileSigmaMeters);

    bool statisticalFires(double progress, double sigma) =>
        (progress + cushion(sigma)) >= kTargetN2 - 1e-9;

    test('reach=null matches the closed-form statistical predicate', () {
      final samples = <List<double>>[
        [7800, 0], // 7800 < 8000 -> no
        [8000, 0], // exactly at target -> yes
        [7900, 100], // +200 -> 8100 -> yes
        [7900, 40], // +80 -> 7980 -> no
        [7000, 100000], // cushion capped at 600 -> 7600 -> no
        [7500, 100000], // capped 600 -> 8100 -> yes
        [12000, 0], // well past -> yes
      ];
      for (final s in samples) {
        final p = s[0];
        final sigma = s[1];
        final fired = evalStops(progress: p, sigma: sigma, reach: null) != null;
        expect(fired, statisticalFires(p, sigma),
            reason: 'legacy mismatch at progress=$p sigma=$sigma');
      }
    });

    test('a reach bound below the statistical value is a no-op (identical)', () {
      // If reach never exceeds progress+cushion, results must be byte-for-byte
      // identical to the legacy null-reach behavior.
      for (final p in <double>[0, 3000, 7900, 8000, 9000]) {
        for (final sigma in <double>[0, 100, 100000]) {
          final legacy = evalStops(progress: p, sigma: sigma, reach: null);
          final belowReach = evalStops(
              progress: p, sigma: sigma, reach: p - 1.0); // strictly below p
          expect(legacy == null, belowReach == null,
              reason: 'below-progress reach altered legacy result at p=$p '
                  'sigma=$sigma');
        }
      }
    });
  });

  // ==========================================================================
  // Fallback path (no transit-leg context): the destination direct-fire and
  // 60%-remaining rules also fold reachability in. This is another never-late
  // surface a real user hits when leg extraction is missing.
  // ==========================================================================
  group('fallback destination path folds reachability (never late)', () {
    final destEvents = <RouteEventBoundary>[
      RouteEventBoundary(meters: 10000.0, type: AlarmEventType.finalDestination),
    ];

    AlarmTrigger? evalFallback({
      required double progress,
      double? reach,
      double sigma = 0.0,
      List<double> stepBounds = const [],
    }) {
      return AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.distance,
        userValue: 1.0,
        progressMeters: progress,
        allEvents: destEvents,
        firedEventIndexes: <int>{},
        firedLegIds: <String>{},
        isMetroLeg: false,
        transitLegs: const <TransitLegStops>[], // empty => fallback path
        currentLegIndex: 0,
        isFinalLeg: true,
        stepBoundsMeters: stepBounds,
        positionSigmaMeters: sigma,
        reachableProgressBoundMeters: reach,
      );
    }

    test('direct-fire (<200 m) triggered by physics bound with frozen progress',
        () {
      const s0 = 100.0; // frozen far from destination
      // No fire while the bound is short of 9800 m (dest - 200).
      expect(evalFallback(progress: s0, reach: 9000.0), isNull);
      // Bound within 200 m of the 10 km destination => direct fire.
      final trig = evalFallback(progress: s0, reach: 9850.0);
      expect(trig, isNotNull);
      expect(trig!.eventType, AlarmEventType.finalDestination);
    });

    test('direct-fire timing never late vs true arrival', () {
      const s0 = 100.0;
      const trueSpeed = 12.0;
      final trueArrival = 10000.0 / trueSpeed;
      double? fireT;
      for (double now = 0.0; now <= 3000.0; now += 1.0) {
        final reach = reachBoundAt(
            anchorS: s0, anchorAcc: 0.0, t0: 0.0, now: now);
        if (evalFallback(progress: s0, reach: reach) != null) {
          fireT = now;
          break;
        }
      }
      expect(fireT, isNotNull);
      expect(fireT!, lessThanOrEqualTo(trueArrival + 1e-6));
    });

    test('60%-remaining rule advanced by the reach bound', () {
      // Two steps: 0..3000 (first leg), 3000..10000 (final leg).
      // finalLegStart=3000, len=7000, threshold = 3000 + 0.4*7000 = 5800.
      const stepBounds = <double>[3000.0, 10000.0];
      // Frozen at 200 m; below the 5800 m threshold with no reach => no fire.
      expect(
          evalFallback(progress: 200.0, reach: null, stepBounds: stepBounds),
          isNull);
      // A reach bound at 5800 m crosses the 40%-progress threshold => fire.
      final trig = evalFallback(
          progress: 200.0, reach: 5800.0, stepBounds: stepBounds);
      expect(trig, isNotNull);
      expect(trig!.eventType, AlarmEventType.finalDestination);
    });
  });

  // ==========================================================================
  // Monotonicity guard: for a fixed dead-reckoned progress, increasing the
  // physics bound can only advance (never retract) the fire. A wake alarm that
  // "un-fires" as evidence of progress accumulates would be a late-fire bug.
  // ==========================================================================
  group('monotonic: more reach never un-fires', () {
    test('once fired at reach R, every reach >= R also fires', () {
      const progress = 3000.0;
      double? firstFire;
      for (double r = 0.0; r <= kLength; r += 100.0) {
        final fired = evalStops(progress: progress, reach: r) != null;
        if (fired && firstFire == null) firstFire = r;
        if (firstFire != null && r >= firstFire) {
          expect(fired, isTrue,
              reason: 'reach=$r un-fired after firing at $firstFire');
        }
      }
      expect(firstFire, isNotNull);
      // Fire onset must be exactly at the 2-stops target (8000 m).
      expect(firstFire!, closeTo(kTargetN2, 100.0));
    });

    test('mixing sigma and reach still only advances firing', () {
      // Sweep both; the fired region must be up-closed in max(P+cushion, R).
      for (final sigma in <double>[0, 150, 100000]) {
        double? onset;
        for (double r = 0.0; r <= kLength; r += 250.0) {
          final fired =
              evalStops(progress: 2000.0, sigma: sigma, reach: r) != null;
          if (fired && onset == null) onset = r;
          if (onset != null) {
            expect(fired, isTrue,
                reason: 'non-monotone at sigma=$sigma reach=$r');
          }
        }
        // With progress 2000 and clamped cushion <=600, only reach can reach
        // 8000; onset must exist and sit at/above the target minus a step.
        expect(onset, isNotNull, reason: 'sigma=$sigma never fired via reach');
        expect(onset!, greaterThanOrEqualTo(kTargetN2 - 250.0));
      }
    });
  });

  // A cheap sanity that our fixture math matches the evaluator's stop model.
  test('fixture sanity: N=2 target is exactly the 8000 m intermediate stop', () {
    expect(defaultLegs.single.stopMeters, <double>[
      1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000,
    ]);
    // effProg just below 8000 => 3 stops remain (no fire); at 8000 => 2 (fire).
    expect(evalStops(progress: 7999.999, reach: null), isNull);
    expect(evalStops(progress: 8000.0, reach: null), isNotNull);
    expect(kVLine, VLineTable.defaultMps);
  });
}
