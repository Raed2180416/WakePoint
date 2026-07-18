// test/ios/ios_backstop_edgecases_test.dart
//
// EDGE-CASE + ERROR-PATH attack on the iOS reachability backstop planner
// (lib/services/ios/ios_backstop_planner.dart). The cardinal sin for a wake
// alarm is firing LATE or never firing, so every test here pushes the planner
// toward that failure mode with degenerate distances, corrupt progress, invalid
// radii, non-finite clocks and a scheduler that throws — and asserts the SAFE
// (never-late / never-never-fire) outcome.
//
// This file deliberately does NOT repeat the happy-path coverage already in
// ios_backstop_planner_test.dart (single-distance RRTS<metro, express ceiling,
// basic rings, basic arm, the no-progress never-late sweep). Everything below
// is a boundary, a corrupt input, a race/failure path, or a stronger property.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';
import 'package:geowake2/services/ios/ios_backstop_planner.dart';

/// Scheduler seam that can be told to throw on the time-backstop notification or
/// on a ring registration, while still RECORDING every attempt so a test can
/// prove the planner tried to arm the *other* independent backstop.
class _ThrowingScheduler implements IosScheduler {
  final bool throwOnNotification;
  final bool throwOnFirstRegion;

  final List<ScheduledNotification> scheduledNotifications =
      <ScheduledNotification>[];
  final List<GeofenceRing> attemptedRegions = <GeofenceRing>[];
  final List<GeofenceRing> monitoredRegions = <GeofenceRing>[];
  int _regionCalls = 0;

  _ThrowingScheduler({
    this.throwOnNotification = false,
    this.throwOnFirstRegion = false,
  });

  @override
  Future<void> scheduleLocalNotification(int epochMs, String id) async {
    if (throwOnNotification) {
      throw StateError('scheduleLocalNotification boom');
    }
    scheduledNotifications.add(ScheduledNotification(epochMs, id));
  }

  @override
  Future<void> monitorRegion(GeofenceRing ring) async {
    attemptedRegions.add(ring); // record the attempt BEFORE any throw
    _regionCalls++;
    if (throwOnFirstRegion && _regionCalls == 1) {
      throw StateError('monitorRegion boom');
    }
    monitoredRegions.add(ring);
  }
}

void main() {
  const double t0 = 1700000000000.0; // fixed "now" in epoch ms

  double earliestFor({
    required double distance,
    String? city,
    String? lineName,
    double? progress,
    double now = t0,
  }) {
    return IosBackstopPlanner.plan(
      routeDistanceMeters: distance,
      nowEpochMs: now,
      city: city,
      lineName: lineName,
      originProgressMeters: progress,
    ).earliestArrivalEpochMs;
  }

  group('degenerate routeDistance — must schedule something, never never-fire',
      () {
    test('distance 0 fires immediately (at now), not never', () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: 0.0,
        nowEpochMs: t0,
      );
      expect(p.earliestArrivalEpochMs, closeTo(t0, 1e-6));
      // Still a real, arm-able plan with both rings.
      expect(p.rings.length, 2);
    });

    test('negative distance clamps remaining to zero (fire at now)', () {
      // A negative route length is corrupt; remaining must floor at 0 so the
      // backstop fires immediately rather than computing a negative travel time
      // that would schedule the alarm in the PAST-of-past or go nonsensical.
      expect(earliestFor(distance: -5000.0), closeTo(t0, 1e-6));
      expect(earliestFor(distance: -0.0001), closeTo(t0, 1e-6));
    });

    test('+infinite distance fires immediately (never never-fires)', () {
      expect(earliestFor(distance: double.infinity), closeTo(t0, 1e-6));
    });

    test('-infinite distance fires immediately', () {
      expect(earliestFor(distance: double.negativeInfinity), closeTo(t0, 1e-6));
    });

    test('NaN distance fires immediately', () {
      expect(earliestFor(distance: double.nan), closeTo(t0, 1e-6));
    });

    test('astronomically large distance overflows travel-time but arm still '
        'schedules a finite epoch (no NaN, no crash)', () async {
      // (1e308 / 28) * 1000 overflows to +inf, so earliestArrivalEpochMs is
      // +inf. arm() floors that to a finite int (0 => 1970 => fires immediately)
      // rather than propagating a non-finite epoch to the platform layer.
      final plan = IosBackstopPlanner.plan(
        routeDistanceMeters: 1e308,
        nowEpochMs: t0,
      );
      final scheduler = FakeIosScheduler();
      await IosBackstopPlanner.arm(plan, scheduler);
      final n = scheduler.scheduledNotifications.single;
      expect(n.epochMs.isFinite, isTrue);
      expect(n.epochMs, 0); // floor(+inf) guarded to 0 -> past -> fires now
      // Rings still armed (the geofence backstop is unaffected by overflow).
      expect(scheduler.monitoredRegions.length, 2);
    });
  });

  group('earliest-arrival is a lower bound — never later than now', () {
    test('earliestArrival >= now for a sweep of finite distances/progress', () {
      final rng = math.Random(7);
      for (var i = 0; i < 2000; i++) {
        final dist = rng.nextDouble() * 50000.0; // 0..50 km (incl. ~0)
        final prog = rng.nextBool() ? rng.nextDouble() * 60000.0 : null;
        final e = earliestFor(distance: dist, progress: prog);
        // The backstop must never be scheduled BEFORE the clock we were handed.
        expect(e, greaterThanOrEqualTo(t0 - 1e-6),
            reason: 'scheduled before now: dist=$dist progress=$prog e=$e');
      }
    });

    test('any strictly-positive remaining distance fires strictly after now',
        () {
      expect(earliestFor(distance: 5000.0), greaterThan(t0));
      expect(earliestFor(distance: 1.0), greaterThan(t0));
    });
  });

  group('never-late property WITH origin progress (rider mid-route)', () {
    // The no-progress sweep already lives in the sibling file. This sweep proves
    // the invariant still holds once the rider is PART-WAY along: for a rider at
    // the supplied progress travelling at any speed <= V_LINE, the scheduled
    // earliest-arrival is at or before the true arrival.
    test('earliest <= true arrival for supplied progress, all lines/speeds', () {
      final rng = math.Random(1234);
      final lines = <List<String?>>[
        <String?>['Bengaluru', 'Purple Line'], // metro default (28)
        <String?>['Delhi', 'Airport Express'], // express (39)
        <String?>['delhimeerutrrts', 'Namo Bharat'], // RRTS (53)
      ];

      for (var i = 0; i < 4000; i++) {
        final line = lines[rng.nextInt(lines.length)];
        final city = line[0];
        final lineName = line[1];
        final vLine =
            const VLineTable().forLine(city: city, lineName: lineName);

        final distance = 1000.0 + rng.nextDouble() * 40000.0;
        final progress = rng.nextDouble() * (distance * 0.9); // in [0, 0.9*D)
        final remaining = distance - progress;
        // Fastest admissible train: speed strictly within (0, V_LINE].
        final trueSpeed = (0.05 + rng.nextDouble() * 0.95) * vLine;

        final e = earliestFor(
          distance: distance,
          city: city,
          lineName: lineName,
          progress: progress,
        );
        final trueArrival = t0 + (remaining / trueSpeed) * 1000.0;
        expect(e, lessThanOrEqualTo(trueArrival + 1e-6),
            reason: 'LATE with progress: line=$city/$lineName vLine=$vLine '
                'dist=$distance prog=$progress speed=$trueSpeed');
      }
    });

    test('at exactly V_LINE with progress, earliest EQUALS true arrival', () {
      const distance = 20000.0;
      const progress = 7000.0;
      for (final line in <List<String?>>[
        <String?>[null, null],
        <String?>['Delhi', 'Airport Express'],
        <String?>['delhimeerutrrts', 'Namo Bharat'],
      ]) {
        final vLine =
            const VLineTable().forLine(city: line[0], lineName: line[1]);
        final e = earliestFor(
          distance: distance,
          city: line[0],
          lineName: line[1],
          progress: progress,
        );
        final trueArrival = t0 + ((distance - progress) / vLine) * 1000.0;
        expect(e, closeTo(trueArrival, 1e-6),
            reason: 'not equal at V_LINE for ${line[0]}/${line[1]}');
      }
    });
  });

  group('faster ceiling => earlier fire (RRTS < express < metro)', () {
    test('strict ordering holds across many distances', () {
      final rng = math.Random(99);
      for (var i = 0; i < 1000; i++) {
        final distance = 200.0 + rng.nextDouble() * 60000.0;
        final metro = earliestFor(
            distance: distance, city: 'Bengaluru', lineName: 'Purple Line');
        final express = earliestFor(
            distance: distance, city: 'Delhi', lineName: 'Airport Express');
        final rrts = earliestFor(
            distance: distance,
            city: 'delhimeerutrrts',
            lineName: 'Namo Bharat');
        // A higher V_LINE ceiling shortens the earliest travel time.
        expect(rrts, lessThan(express),
            reason: 'RRTS not earlier than express at dist=$distance');
        expect(express, lessThan(metro),
            reason: 'express not earlier than metro at dist=$distance');
      }
    });
  });

  group('corrupt originProgress is treated as no-progress (full distance)', () {
    // Documents the planner's actual fallback: a non-finite / non-positive
    // progress is ignored and the FULL route distance is used. Using the full
    // remaining distance is the never-late-safe choice for a rider AT the origin
    // (which is when the backstop is armed): it yields the LATEST earliest that
    // is still <= true arrival for an origin rider at V_LINE.
    test('NaN progress -> full distance', () {
      final withNan =
          earliestFor(distance: 12000.0, progress: double.nan);
      final noProgress = earliestFor(distance: 12000.0);
      expect(withNan, closeTo(noProgress, 1e-6));
      expect(withNan,
          closeTo(t0 + (12000.0 / VLineTable.defaultMps) * 1000.0, 1e-6));
    });

    test('negative progress -> full distance', () {
      final e = earliestFor(distance: 12000.0, progress: -4000.0);
      expect(e, closeTo(t0 + (12000.0 / VLineTable.defaultMps) * 1000.0, 1e-6));
    });

    test('+infinite progress -> full distance (not remaining 0)', () {
      final e = earliestFor(distance: 12000.0, progress: double.infinity);
      expect(e, closeTo(t0 + (12000.0 / VLineTable.defaultMps) * 1000.0, 1e-6));
    });

    test('progress exactly equal to routeDistance fires at now', () {
      expect(earliestFor(distance: 8000.0, progress: 8000.0),
          closeTo(t0, 1e-6));
    });

    test('progress a hair beyond routeDistance clamps to now', () {
      expect(earliestFor(distance: 8000.0, progress: 8000.0001),
          closeTo(t0, 1e-6));
    });
  });

  group('non-finite clock (nowEpochMs) degrades safely', () {
    test('NaN now is replaced with 0 => finite earliest', () {
      final e = earliestFor(distance: 10000.0, now: double.nan);
      expect(e.isFinite, isTrue);
      expect(e, closeTo((10000.0 / VLineTable.defaultMps) * 1000.0, 1e-6));
    });

    test('+infinite now is replaced with 0 => finite earliest', () {
      final e = earliestFor(distance: 10000.0, now: double.infinity);
      expect(e.isFinite, isTrue);
      expect(e, closeTo((10000.0 / VLineTable.defaultMps) * 1000.0, 1e-6));
    });

    test('NaN now with degenerate distance is still finite (fires at 0)', () {
      final e = earliestFor(distance: double.nan, now: double.nan);
      expect(e, 0.0);
    });
  });

  group('ring radius sanitisation — invalid falls back to a sane default', () {
    void expectSaneRadii(BackstopPlan p) {
      expect(p.rings.length, 2);
      for (final r in p.rings) {
        expect(r.radiusMeters.isFinite && r.radiusMeters > 0, isTrue,
            reason: 'insane radius: ${r.radiusMeters} for ${r.kind}');
      }
    }

    test('radius 0 falls back to a positive finite default', () {
      expectSaneRadii(IosBackstopPlanner.plan(
        routeDistanceMeters: 8000.0,
        nowEpochMs: t0,
        destinationRadiusMeters: 0.0,
        preStopRadiusMeters: 0.0,
      ));
    });

    test('+infinite / -infinite radius falls back to default', () {
      expectSaneRadii(IosBackstopPlanner.plan(
        routeDistanceMeters: 8000.0,
        nowEpochMs: t0,
        destinationRadiusMeters: double.infinity,
        preStopRadiusMeters: double.negativeInfinity,
      ));
    });

    test('negative radius falls back to default', () {
      expectSaneRadii(IosBackstopPlanner.plan(
        routeDistanceMeters: 8000.0,
        nowEpochMs: t0,
        destinationRadiusMeters: -200.0,
        preStopRadiusMeters: -0.0001,
      ));
    });

    test('valid radii are preserved exactly', () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: 8000.0,
        nowEpochMs: t0,
        destinationRadiusMeters: 123.0,
        preStopRadiusMeters: 456.0,
      );
      expect(
          p.rings
              .firstWhere((r) => r.kind == GeofenceRingKind.destination)
              .radiusMeters,
          123.0);
      expect(
          p.rings
              .firstWhere((r) => r.kind == GeofenceRingKind.preStop)
              .radiusMeters,
          456.0);
    });
  });

  group('two rings are ALWAYS emitted', () {
    test('both rings present even under NaN distance + all-invalid radii', () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: double.nan,
        nowEpochMs: t0,
        destinationRadiusMeters: double.nan,
        preStopRadiusMeters: -1.0,
      );
      expect(p.rings.length, 2);
      expect(p.rings.map((r) => r.kind).toSet(),
          {GeofenceRingKind.destination, GeofenceRingKind.preStop});
      // Distinct ids so iOS does not de-dupe the two regions into one.
      expect(p.rings.map((r) => r.id).toSet().length, 2);
      for (final r in p.rings) {
        expect(r.radiusMeters.isFinite && r.radiusMeters > 0, isTrue);
      }
    });

    test('rings list is unmodifiable (cannot be mutated out from under arm)',
        () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: 8000.0,
        nowEpochMs: t0,
      );
      expect(
        () => p.rings.add(const GeofenceRing(
            id: 'x', radiusMeters: 100.0, kind: GeofenceRingKind.destination)),
        throwsUnsupportedError,
      );
    });

    test('custom ring ids flow through to the emitted rings', () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: 8000.0,
        nowEpochMs: t0,
        destinationRingId: 'custom_dest_ring',
        preStopRingId: 'custom_pre_ring',
      );
      expect(
          p.rings
              .firstWhere((r) => r.kind == GeofenceRingKind.destination)
              .id,
          'custom_dest_ring');
      expect(
          p.rings.firstWhere((r) => r.kind == GeofenceRingKind.preStop).id,
          'custom_pre_ring');
    });
  });

  group('arm() epoch conversion never rounds LATER than earliest-arrival', () {
    test('fractional earliest is FLOORED (pulled earlier), not rounded up',
        () async {
      // 1000 m / 28 m/s * 1000 = 35714.2857... ms -> floor keeps us earlier.
      final plan = IosBackstopPlanner.plan(
        routeDistanceMeters: 1000.0,
        nowEpochMs: t0,
      );
      final scheduler = FakeIosScheduler();
      await IosBackstopPlanner.arm(plan, scheduler);
      final n = scheduler.scheduledNotifications.single;
      expect(n.epochMs, plan.earliestArrivalEpochMs.floor());
      expect(n.epochMs.toDouble(),
          lessThanOrEqualTo(plan.earliestArrivalEpochMs));
      expect(n.id, IosBackstopPlanner.backstopNotificationId);
    });

    test('non-finite earliest in a plan is scheduled as epoch 0, not NaN/inf',
        () async {
      const rings = <GeofenceRing>[
        GeofenceRing(
            id: 'd', radiusMeters: 200.0, kind: GeofenceRingKind.destination),
        GeofenceRing(
            id: 'p', radiusMeters: 500.0, kind: GeofenceRingKind.preStop),
      ];
      for (final bad in <double>[double.infinity, double.nan]) {
        final scheduler = FakeIosScheduler();
        await IosBackstopPlanner.arm(
          BackstopPlan(earliestArrivalEpochMs: bad, rings: rings),
          scheduler,
        );
        expect(scheduler.scheduledNotifications.single.epochMs, 0,
            reason: 'non-finite earliest $bad must floor to 0, never propagate');
        expect(scheduler.monitoredRegions.length, 2);
      }
    });
  });

  group('arm() resilience — a throwing scheduler must not disarm the OTHER '
      'backstop (attack: single failure => never fires)', () {
    late BackstopPlan plan;
    setUp(() {
      plan = IosBackstopPlanner.plan(
        routeDistanceMeters: 12000.0,
        nowEpochMs: t0,
        lineName: 'Blue Line',
      );
    });

    test('time-backstop notification throwing must NOT prevent the geofence '
        'rings being armed', () async {
      final scheduler = _ThrowingScheduler(throwOnNotification: true);
      // We tolerate arm surfacing the error, but the INDEPENDENT geofence
      // backstop must still have been attempted — otherwise one flaky plugin
      // call silently leaves the rider with NO iOS backstop at all.
      try {
        await IosBackstopPlanner.arm(plan, scheduler);
      } catch (_) {
        // swallow: the point under test is what got armed, not the throw.
      }
      expect(scheduler.attemptedRegions.length, plan.rings.length,
          reason:
              'geofence rings must be armed even if the time backstop throws');
    });

    test('a ring registration throwing must NOT prevent the remaining rings',
        () async {
      final scheduler = _ThrowingScheduler(throwOnFirstRegion: true);
      try {
        await IosBackstopPlanner.arm(plan, scheduler);
      } catch (_) {}
      // Both the destination and pre-stop rings are safety-critical; a failure
      // registering one must not skip the other.
      expect(scheduler.attemptedRegions.length, plan.rings.length,
          reason:
              'a failing ring must not prevent registering the other ring');
    });
  });
}
