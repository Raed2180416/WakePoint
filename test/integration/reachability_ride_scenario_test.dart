// test/integration/reachability_ride_scenario_test.dart
//
// REALISTIC MULTI-PHASE METRO RIDES driven tick-by-tick through the REAL
// AlarmEvaluator.evaluateCoinciding + the REAL ReachabilityTracker physics.
//
// Unlike reachability_scenarios_test.dart (which probes the evaluator/physics
// point-wise and parametrically), this file simulates whole rides second by
// second: a physical train advances at a true speed, GPS blinks in and out
// (blackouts, re-anchors, cold start), and on every tick we feed the evaluator
//   - progressMeters       = the dead-reckoned/EKF estimate (frozen in a
//                            blackout, NaN before cold-start init), and
//   - reachableProgressBoundMeters = the ReachabilityTracker's physics bound
//                            (grows with wall-clock while GPS is lost).
//
// THE WAKE-ALARM CARDINAL SIN IS FIRING LATE. Every journey asserts NEVER-LATE:
// the tick at which the alarm fires is at or before the tick at which the true
// (physical) train first reaches the "N stops remain" target. The target is
// derived from the same stop geometry the evaluator uses, so we never hand-roll
// the number under test.
//
// Metro leg geometry (matches TransferUtils' stop placement):
//   leg [0, 10000] m, 9 intermediate stops at 1000,2000,...,9000 m; the
//   alighting station is the leg end (10000 m) and counts as the +1 target stop.
//   "N stops prior" fires when remainingStopsToTarget <= N, where
//     remainingStopsToTarget = (9 - passedIntermediate) + 1.
//   For N=2 that needs passedIntermediate >= 8, i.e. EFFECTIVE progress must
//   reach the 8th intermediate stop at 8000 m. So 8000 m is the exact physical
//   point where "2 stops remain" — the never-late target for N=2 used below.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/core/reachability/reachability.dart';

void main() {
  // ------------------------------------------------------------------ geometry
  const double kLength = 10000.0;
  const int kNumStops = 9;
  const double kTargetN2 = 8000.0; // effective-progress fire target for N=2
  const double kMetroTrueSpeed = 16.0; // <= V_LINE default (28 m/s)
  const double kRrtsTrueSpeed = 44.0; //  <= RRTS ceiling (53 m/s), > metro (28)

  TransitLegStops metroLeg({
    String lineName = 'Metro Line',
    int numStops = kNumStops,
    double length = kLength,
  }) {
    return TransitLegStops(
      legStartMeters: 0.0,
      legEndMeters: length,
      numStops: numStops,
      stopPositions: List.generate(numStops, (_) => const LatLng(0, 0)),
      stopMeters: List.generate(
        numStops,
        (i) => (i + 1) * (length / (numStops + 1)),
      ),
      lineName: lineName,
      isActualPositions: true,
      isMetro: true,
      stopNames: List.generate(numStops, (i) => 'Stop $i'),
    );
  }

  // First tick (on the 1 s grid from t=0) at which the physical train reaches
  // the never-late target. This is the "true arrival at N-stops-remain".
  double trueTargetTick(double trueSpeed, {double target = kTargetN2}) {
    for (double t = 0.0; t <= 100000.0; t += 1.0) {
      if (trueSpeed * t >= target) return t;
    }
    return double.infinity;
  }

  // ------------------------------------------------------------- ride recorder
  final trace = <_Tick>[]; // per-tick snapshot of the LAST simulated ride

  // Drive one ride second-by-second through the REAL evaluator + tracker.
  //
  // blackouts: half-open [start, end) wall-clock windows where GPS is lost.
  //            Use double.infinity for an open-ended (never-returns) blackout.
  // coldStart: no GPS ever; tracker seeded at origin; EKF progress is NaN.
  // feedReach: when false, reachableProgressBoundMeters is withheld (null) —
  //            models the legacy statistical-only path, used to prove the
  //            reachability contribution is load-bearing (never-fire otherwise).
  // reachVLineOverride: compute the physics bound with THIS ceiling instead of
  //            the tracker's line-resolved ceiling (used to show that an
  //            under-spec'd ceiling fires LATE).
  _Ride simulateRide({
    required double trueSpeed,
    required TransitLegStops leg,
    String? reachLineName,
    double? reachVLineOverride,
    List<List<double>> blackouts = const [],
    bool coldStart = false,
    bool feedReach = true,
    double userValue = 2.0,
    double maxT = 1500.0,
  }) {
    trace.clear();
    final tracker = ReachabilityTracker();
    if (coldStart) tracker.seedColdStart(tSeconds: 0.0, sMeters: 0.0);
    final legs = <TransitLegStops>[leg];

    bool inBlackout(double t) {
      for (final b in blackouts) {
        if (t >= b[0] && t < b[1]) return true;
      }
      return false;
    }

    double dr = coldStart ? double.nan : 0.0; // dead-reckoned/EKF estimate
    final ride = _Ride(tracker);

    for (double t = 0.0; t <= maxT; t += 1.0) {
      final trueProgress = trueSpeed * t;
      final gpsPresent = !coldStart && !inBlackout(t);

      // A real accepted fix resets the anchor and re-syncs the EKF estimate.
      if (gpsPresent) {
        tracker.onAcceptedFix(
          sMeters: trueProgress,
          accuracyMeters: 0.0, // tightest (adversarial) anchor: no fwd padding
          tSeconds: t,
        );
        dr = trueProgress;
      }
      // else: blackout — the EKF dead-reckon stalls (frozen), which is exactly
      // the underground reality this whole subsystem defends against.

      double? reach;
      if (feedReach) {
        if (reachVLineOverride != null) {
          final a = tracker.anchor;
          if (a != null) {
            reach = Reachability.bound(
              anchor: a,
              nowSeconds: t,
              vLineMps: reachVLineOverride,
            ).sMaxMeters;
          }
        } else {
          final b = tracker.boundNow(nowSeconds: t, lineName: reachLineName);
          reach = b?.sMaxMeters;
        }
        if (reach != null && !reach.isFinite) reach = null;
      }

      final double progressArg = coldStart ? double.nan : dr;
      final trig = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: userValue,
        progressMeters: progressArg,
        allEvents: const <RouteEventBoundary>[],
        firedEventIndexes: <int>{},
        firedLegIds: <String>{},
        isMetroLeg: true,
        transitLegs: legs,
        currentLegIndex: 0,
        isFinalLeg: true,
        positionSigmaMeters: 0.0,
        reachableProgressBoundMeters: reach,
      );

      final tick = _Tick(
        t: t,
        trueProgress: trueProgress,
        dr: progressArg,
        reach: reach,
        anchorS: tracker.anchor?.sMeters,
        gpsPresent: gpsPresent,
        fired: trig != null,
      );
      trace.add(tick);
      ride.lastTick = tick;

      if (trig != null) {
        ride.fireT = t;
        ride.trigger = trig;
        ride.trueProgAtFire = trueProgress;
        break;
      }
    }
    return ride;
  }

  // Shared never-late + physics-justified assertions for a firing ride.
  void expectNeverLate(_Ride ride, double trueSpeed, {String? because}) {
    final target = trueTargetTick(trueSpeed);
    expect(ride.fireT, isNotNull,
        reason: 'NEVER-FIRE is a cardinal sin: alarm must fire. ${because ?? ''}');
    expect(ride.fireT!, lessThanOrEqualTo(target),
        reason: 'LATE FIRE: fired@${ride.fireT} > trueTargetTick@$target. '
            '${because ?? ''}');
    expect(ride.trigger!.eventType, AlarmEventType.finalDestination);
    // Fired exactly at the N=2 boundary (2 stops remaining), not sloppily early.
    expect(ride.trigger!.remainingStops, 2.0,
        reason: 'expected the fire to land at the "2 stops remain" boundary');
  }

  // ==========================================================================
  // (1) GPS present the whole ride: reachability is INERT (anchor refreshed
  //     every tick, accuracy 0 => reach == dead-reckoned == true progress).
  //     The alarm fires ON the stop target, exactly as the legacy path would.
  // ==========================================================================
  test('(1) full-GPS ride: reachability inert, fires on-time at the target', () {
    final withReach = simulateRide(
      trueSpeed: kMetroTrueSpeed,
      leg: metroLeg(),
      reachLineName: 'Metro Line',
      maxT: 700.0,
    );
    expectNeverLate(withReach, kMetroTrueSpeed);

    final target = trueTargetTick(kMetroTrueSpeed); // 500 s
    // On-time (not merely at/before): a healthy-GPS ride fires exactly at the
    // target tick — reachability neither delays nor advances it.
    expect(withReach.fireT, target);
    expect(withReach.trueProgAtFire, closeTo(kTargetN2, 1e-6));
    expect(withReach.lastGpsPresent, isTrue,
        reason: 'a full-GPS ride fires while GPS is present');

    // INERTNESS: an identical ride with the reach bound WITHHELD fires at the
    // same tick — proof reachability contributed nothing while GPS was healthy.
    final withoutReach = simulateRide(
      trueSpeed: kMetroTrueSpeed,
      leg: metroLeg(),
      feedReach: false,
      maxT: 700.0,
    );
    expect(withoutReach.fireT, withReach.fireT,
        reason: 'reachability must be inert when GPS is present every tick');
  });

  // ==========================================================================
  // (2) Mid-ride blackout that NEVER returns: the EKF freezes, dead-reckoned
  //     progress stalls, and only the growing physics bound can fire the alarm.
  //     Must fire strictly BEFORE the true arrival (early is safe).
  // ==========================================================================
  test('(2) mid-ride blackout (no return): reach-driven fire, never late', () {
    final ride = simulateRide(
      trueSpeed: kMetroTrueSpeed,
      leg: metroLeg(),
      reachLineName: 'Metro Line',
      blackouts: const [
        [100.0, double.infinity]
      ],
      maxT: 700.0,
    );
    expectNeverLate(ride, kMetroTrueSpeed);

    // Fired DURING the blackout, driven purely by physics (GPS absent, and the
    // frozen dead-reckoned progress is far short of the target).
    expect(ride.lastGpsPresent, isFalse);
    expect(ride.trueProgAtFire!, lessThan(kTargetN2),
        reason: 'physics fires early: the train is not yet at the target');
    expect(ride.fireT!, lessThan(trueTargetTick(kMetroTrueSpeed)));

    // LOAD-BEARING: the SAME blackout with the reach bound withheld NEVER fires
    // within the whole simulated window — the exact never-fire hazard that
    // reachability closes.
    final legacy = simulateRide(
      trueSpeed: kMetroTrueSpeed,
      leg: metroLeg(),
      feedReach: false,
      blackouts: const [
        [100.0, double.infinity]
      ],
      maxT: 1500.0,
    );
    expect(legacy.fireT, isNull,
        reason: 'frozen dead-reckoning with no physics bound is a never-fire');
  });

  // ==========================================================================
  // (3) Blackout THEN re-anchor: GPS returns before the physics bound reaches
  //     the target. The anchor jumps forward and the bound tightens; the ride
  //     then finishes under GPS and still fires no later than the target.
  // ==========================================================================
  test('(3) blackout then re-anchor: bound tightens, still never late', () {
    final ride = simulateRide(
      trueSpeed: kMetroTrueSpeed,
      leg: metroLeg(),
      reachLineName: 'Metro Line',
      blackouts: const [
        [100.0, 250.0]
      ],
      maxT: 700.0,
    );
    expectNeverLate(ride, kMetroTrueSpeed);
    // Finished under GPS (re-acquired), fired at the target tick.
    expect(ride.lastGpsPresent, isTrue);
    expect(ride.fireT, trueTargetTick(kMetroTrueSpeed));

    // Mid-blackout: the physics bound grew above the FROZEN dead-reckon but did
    // NOT reach the target (so no premature commit before GPS returned).
    final mid = trace.firstWhere((e) => e.t == 200.0);
    expect(mid.gpsPresent, isFalse);
    expect(mid.reach, isNotNull);
    expect(mid.reach!, greaterThan(mid.dr),
        reason: 'reach must grow while dead-reckon is frozen');
    expect(mid.reach!, lessThan(kTargetN2));

    // Re-anchor at t=250 jumps the anchor FORWARD and TIGHTENS the bound.
    final post = trace.firstWhere((e) => e.t == 251.0);
    expect(post.gpsPresent, isTrue);
    expect(post.anchorS!, greaterThan(mid.anchorS!),
        reason: 're-anchor must move the anchor forward to the fresh fix');
    expect(post.reach!, lessThan(mid.reach!),
        reason: 're-anchor must tighten (reduce) the reachability bound');
  });

  // ==========================================================================
  // (4) TWO separate blackouts on one ride. GPS recovers between them; the
  //     second blackout is the one that fires (by physics). Never late.
  // ==========================================================================
  test('(4) two separate blackouts: still fires at/before target', () {
    final ride = simulateRide(
      trueSpeed: kMetroTrueSpeed,
      leg: metroLeg(),
      reachLineName: 'Metro Line',
      blackouts: const [
        [100.0, 200.0],
        [300.0, double.infinity],
      ],
      maxT: 700.0,
    );
    expectNeverLate(ride, kMetroTrueSpeed);

    // Fired inside the SECOND blackout, by physics, before true arrival.
    expect(ride.lastGpsPresent, isFalse);
    expect(ride.fireT!, greaterThan(300.0));
    expect(ride.fireT!, lessThan(trueTargetTick(kMetroTrueSpeed)));
    expect(ride.trueProgAtFire!, lessThan(kTargetN2));

    // Sanity: the ride actually recovered GPS between the two blackouts.
    final between = trace.firstWhere((e) => e.t == 250.0);
    expect(between.gpsPresent, isTrue);
  });

  // ==========================================================================
  // (5) RRTS line ('Namo Bharat', true speed ~44 m/s). The tracker resolves the
  //     RRTS ceiling (53 m/s), which overbounds the true speed -> safe. A metro
  //     ceiling (28 m/s) would UNDER-bound the true speed and fire LATE; we show
  //     both to prove the ceiling routing is what keeps it safe.
  // ==========================================================================
  test('(5) RRTS Namo Bharat: RRTS ceiling stays safe (metro ceiling is late)',
      () {
    // Ceiling routing sanity: the line name must resolve to the RRTS ceiling.
    expect(
      const VLineTable().forLine(lineName: 'Namo Bharat'),
      VLineTable.rrtsMps,
    );
    expect(kRrtsTrueSpeed, lessThan(VLineTable.rrtsMps)); // precondition (ii)
    expect(kRrtsTrueSpeed, greaterThan(VLineTable.defaultMps)); // metro underbounds

    final rrts = simulateRide(
      trueSpeed: kRrtsTrueSpeed,
      leg: metroLeg(lineName: 'Namo Bharat'),
      reachLineName: 'Namo Bharat', // -> rrtsMps = 53 m/s
      blackouts: const [
        [50.0, double.infinity]
      ],
      maxT: 500.0,
    );
    expectNeverLate(rrts, kRrtsTrueSpeed);
    expect(rrts.lastGpsPresent, isFalse);
    expect(rrts.trueProgAtFire!, lessThan(kTargetN2));

    // CONTRAST: same ride, but the physics bound is (wrongly) computed with the
    // metro default ceiling (28 m/s) — below the true 44 m/s. The bound now
    // lags the real train and the alarm fires LATE. This is precisely the late
    // hazard the RRTS ceiling exists to prevent.
    final wrongCeiling = simulateRide(
      trueSpeed: kRrtsTrueSpeed,
      leg: metroLeg(lineName: 'Namo Bharat'),
      reachVLineOverride: VLineTable.defaultMps, // 28 m/s: under-spec'd
      blackouts: const [
        [50.0, double.infinity]
      ],
      maxT: 500.0,
    );
    expect(wrongCeiling.fireT, isNotNull);
    expect(wrongCeiling.fireT!, greaterThan(trueTargetTick(kRrtsTrueSpeed)),
        reason: 'a metro ceiling under-bounds RRTS true speed and fires LATE — '
            'this is why looksRrts() must route Namo Bharat to rrtsMps');
  });

  // ==========================================================================
  // (6) Cold start: no GPS from t0, tracker seeded at the trip origin, EKF
  //     never initialises (progress is NaN). The alarm must still fire, driven
  //     entirely by physics, at or before the true arrival.
  // ==========================================================================
  test('(6) cold start (no GPS ever): fires by physics, never late', () {
    final ride = simulateRide(
      trueSpeed: kMetroTrueSpeed,
      leg: metroLeg(),
      reachLineName: 'Metro Line',
      coldStart: true,
      maxT: 700.0,
    );
    expectNeverLate(ride, kMetroTrueSpeed);

    // GPS never present; the dead-reckoned/EKF estimate stayed NaN the whole
    // ride, so the fire is 100% physics-driven.
    expect(ride.lastGpsPresent, isFalse);
    expect(ride.lastDrIsNaN, isTrue,
        reason: 'cold-start EKF-not-initialised should stay NaN');
    expect(ride.trueProgAtFire!, lessThan(kTargetN2));
    expect(ride.fireT!, lessThan(trueTargetTick(kMetroTrueSpeed)));

    // LOAD-BEARING: with NaN progress and NO reach bound, the alarm NEVER fires
    // (max(NaN, cushion) is NaN, every stop test is false) — the cold-start
    // never-fire hole reachability closes.
    final legacy = simulateRide(
      trueSpeed: kMetroTrueSpeed,
      leg: metroLeg(),
      coldStart: true,
      feedReach: false,
      maxT: 1500.0,
    );
    expect(legacy.fireT, isNull,
        reason: 'NaN progress without a physics bound is a proven never-fire');
  });

  // Fixture sanity: the stop model the evaluator uses matches our assumption.
  test('fixture sanity: 9 intermediate stops at 1000..9000 m; 8000 = N=2 target',
      () {
    expect(metroLeg().stopMeters, <double>[
      1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000,
    ]);
  });
}

// Per-tick snapshot recorded during a ride.
class _Tick {
  final double t;
  final double trueProgress;
  final double dr; // dead-reckoned/EKF estimate fed to the evaluator
  final double? reach; // physics bound fed to the evaluator (null = withheld)
  final double? anchorS; // tracker anchor arc-progress at this tick
  final bool gpsPresent;
  final bool fired;

  _Tick({
    required this.t,
    required this.trueProgress,
    required this.dr,
    required this.reach,
    required this.anchorS,
    required this.gpsPresent,
    required this.fired,
  });
}

// Outcome of one simulated ride.
class _Ride {
  final ReachabilityTracker tracker;
  double? fireT;
  AlarmTrigger? trigger;
  double? trueProgAtFire;

  // The final tick simulated in this ride (the fire tick if it fired, else the
  // last tick reached). Set on the ride object so it survives later rides
  // reusing the shared `trace` buffer.
  _Tick? lastTick;

  _Ride(this.tracker);

  bool get lastGpsPresent => lastTick!.gpsPresent;
  bool get lastDrIsNaN => lastTick!.dr.isNaN;
}
