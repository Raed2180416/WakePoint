// test/ios/ios_backstop_planner_test.dart
//
// Headless proof that the iOS reachability backstop planner (HANDOFF §6) is
// NEVER-LATE: the scheduled local-notification time it computes is always at or
// before the true arrival for any train whose speed never exceeds V_LINE, and
// arm() drives the injected scheduler with exactly one notification plus the
// geofence rings. No device, no plugin, no wall clock.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/reachability/reachability.dart';
import 'package:geowake2/services/ios/ios_backstop_planner.dart';

void main() {
  const double t0 = 1700000000000.0; // fixed "now" in epoch ms

  group('IosBackstopPlanner.plan — earliest arrival', () {
    test('12 km ride: RRTS earliest-arrival is earlier than metro', () {
      const double distance = 12000.0; // 12 km

      final metro = IosBackstopPlanner.plan(
        routeDistanceMeters: distance,
        nowEpochMs: t0,
        city: 'Bengaluru',
        lineName: 'Purple Line',
      );
      final rrts = IosBackstopPlanner.plan(
        routeDistanceMeters: distance,
        nowEpochMs: t0,
        city: 'delhimeerutrrts',
        lineName: 'Namo Bharat',
      );

      // A higher V_LINE (RRTS) means a shorter earliest travel time, so the
      // RRTS notification is scheduled EARLIER than the metro one.
      expect(rrts.earliestArrivalEpochMs,
          lessThan(metro.earliestArrivalEpochMs));

      // And each matches distance / V_LINE * 1000 exactly.
      final metroTravelMs = (distance / VLineTable.defaultMps) * 1000.0;
      final rrtsTravelMs = (distance / VLineTable.rrtsMps) * 1000.0;
      expect(metro.earliestArrivalEpochMs, closeTo(t0 + metroTravelMs, 1e-6));
      expect(rrts.earliestArrivalEpochMs, closeTo(t0 + rrtsTravelMs, 1e-6));
    });

    test('express line uses the express ceiling', () {
      const double distance = 12000.0;
      final express = IosBackstopPlanner.plan(
        routeDistanceMeters: distance,
        nowEpochMs: t0,
        city: 'Delhi',
        lineName: 'Airport Express',
      );
      final expected = t0 + (distance / VLineTable.expressMps) * 1000.0;
      expect(express.earliestArrivalEpochMs, closeTo(expected, 1e-6));
      // Express is faster than metro default, so earlier.
      expect(express.earliestArrivalEpochMs,
          lessThan(t0 + (distance / VLineTable.defaultMps) * 1000.0));
    });

    test('originProgressMeters shrinks the remaining distance', () {
      const double distance = 12000.0;
      const double progressed = 4500.0;
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: distance,
        nowEpochMs: t0,
        lineName: 'Green Line',
        originProgressMeters: progressed,
      );
      final expected =
          t0 + ((distance - progressed) / VLineTable.defaultMps) * 1000.0;
      expect(p.earliestArrivalEpochMs, closeTo(expected, 1e-6));
    });

    test('already-past progress clamps remaining to zero (fire at now)', () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: 5000.0,
        nowEpochMs: t0,
        originProgressMeters: 9000.0, // beyond the route
      );
      expect(p.earliestArrivalEpochMs, closeTo(t0, 1e-6));
    });

    test('non-finite distance fires immediately (never never-fires)', () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: double.nan,
        nowEpochMs: t0,
      );
      expect(p.earliestArrivalEpochMs, closeTo(t0, 1e-6));
    });
  });

  group('IosBackstopPlanner.plan — rings', () {
    test('emits a destination ring and a pre-stop ring', () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: 8000.0,
        nowEpochMs: t0,
      );
      expect(p.rings.length, 2);

      final dest = p.rings
          .firstWhere((r) => r.kind == GeofenceRingKind.destination);
      final pre =
          p.rings.firstWhere((r) => r.kind == GeofenceRingKind.preStop);

      expect(dest.radiusMeters,
          IosBackstopPlanner.defaultDestinationRadiusMeters);
      expect(pre.radiusMeters, IosBackstopPlanner.defaultPreStopRadiusMeters);
      expect(dest.id, isNotEmpty);
      expect(pre.id, isNotEmpty);
      expect(dest.id, isNot(pre.id));
    });

    test('radius inputs are honoured', () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: 8000.0,
        nowEpochMs: t0,
        destinationRadiusMeters: 150.0,
        preStopRadiusMeters: 750.0,
      );
      expect(
          p.rings
              .firstWhere((r) => r.kind == GeofenceRingKind.destination)
              .radiusMeters,
          150.0);
      expect(
          p.rings
              .firstWhere((r) => r.kind == GeofenceRingKind.preStop)
              .radiusMeters,
          750.0);
    });

    test('invalid radius falls back to a sane default', () {
      final p = IosBackstopPlanner.plan(
        routeDistanceMeters: 8000.0,
        nowEpochMs: t0,
        destinationRadiusMeters: -1.0,
        preStopRadiusMeters: double.nan,
      );
      for (final r in p.rings) {
        expect(r.radiusMeters.isFinite && r.radiusMeters > 0, isTrue);
      }
    });
  });

  group('IosBackstopPlanner.arm', () {
    test('schedules exactly one notification and all rings', () async {
      final plan = IosBackstopPlanner.plan(
        routeDistanceMeters: 12000.0,
        nowEpochMs: t0,
        lineName: 'Blue Line',
      );
      final scheduler = FakeIosScheduler();

      await IosBackstopPlanner.arm(plan, scheduler);

      // Exactly one notification, at the plan's earliest-arrival time.
      expect(scheduler.scheduledNotifications.length, 1);
      final n = scheduler.scheduledNotifications.single;
      expect(n.id, IosBackstopPlanner.backstopNotificationId);
      // Floored to int, and never rounded LATER than the earliest-arrival.
      expect(n.epochMs, lessThanOrEqualTo(plan.earliestArrivalEpochMs.ceil()));
      expect(n.epochMs.toDouble(),
          closeTo(plan.earliestArrivalEpochMs, 1.0));

      // Every ring is monitored, once each.
      expect(scheduler.monitoredRegions.length, plan.rings.length);
      expect(
        scheduler.monitoredRegions.map((r) => r.kind).toSet(),
        {GeofenceRingKind.destination, GeofenceRingKind.preStop},
      );
    });
  });

  group('never-late invariant', () {
    // For any true speed <= V_LINE, the scheduled earliest-arrival must be at or
    // before the true arrival. We sweep speeds, distances and lines.
    test('earliestArrival <= true arrival for all speeds <= V_LINE', () {
      final rng = math.Random(42);
      final lines = <List<String?>>[
        <String?>['Bengaluru', 'Purple Line'], // metro default
        <String?>['Delhi', 'Airport Express'], // express
        <String?>['delhimeerutrrts', 'Namo Bharat'], // RRTS
      ];

      for (var i = 0; i < 5000; i++) {
        final line = lines[rng.nextInt(lines.length)];
        final city = line[0];
        final lineName = line[1];
        final vLine =
            const VLineTable().forLine(city: city, lineName: lineName);

        final distance = 500.0 + rng.nextDouble() * 40000.0; // 0.5–40 km
        // A true speed strictly within (0, V_LINE]. The train can never exceed
        // V_LINE (precondition ii), so this is the fastest admissible train.
        final trueSpeed = (0.05 + rng.nextDouble() * 0.95) * vLine;

        final plan = IosBackstopPlanner.plan(
          routeDistanceMeters: distance,
          nowEpochMs: t0,
          city: city,
          lineName: lineName,
        );

        final trueArrival = t0 + (distance / trueSpeed) * 1000.0;
        expect(
          plan.earliestArrivalEpochMs,
          lessThanOrEqualTo(trueArrival + 1e-6),
          reason:
              'late fire: line=$city/$lineName vLine=$vLine trueSpeed=$trueSpeed '
              'dist=$distance earliest=${plan.earliestArrivalEpochMs} '
              'trueArrival=$trueArrival',
        );
      }
    });

    test('at exactly V_LINE the earliest-arrival equals the true arrival', () {
      const double distance = 15000.0;
      final vLine = const VLineTable()
          .forLine(city: 'delhimeerutrrts', lineName: 'Namo Bharat');
      final plan = IosBackstopPlanner.plan(
        routeDistanceMeters: distance,
        nowEpochMs: t0,
        city: 'delhimeerutrrts',
        lineName: 'Namo Bharat',
      );
      final trueArrival = t0 + (distance / vLine) * 1000.0;
      expect(plan.earliestArrivalEpochMs, closeTo(trueArrival, 1e-6));
    });
  });
}
