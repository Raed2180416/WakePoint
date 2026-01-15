import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';

TransitLegStops _metroLeg({
  required double start,
  required double end,
  required String lineName,
  String fromStop = 'A',
  String toStop = 'B',
}) {
  return TransitLegStops(
    legStartMeters: start,
    legEndMeters: end,
    numStops: 0,
    stopPositions: const [],
    stopMeters: const [],
    lineName: lineName,
    isMetro: true,
    stopNames: [fromStop, toStop],
  );
}

TransitLegStops _walkLeg({
  required double start,
  required double end,
  required String name,
}) {
  return TransitLegStops(
    legStartMeters: start,
    legEndMeters: end,
    numStops: 0,
    stopPositions: const [],
    stopMeters: const [],
    lineName: 'Walk to $name',
    isMetro: false,
  );
}

void main() {
  group('Time-mode switchpoint targeting (universal shapes)', () {
    test(
      'Metro leg uses next boundary target (earlier than leg end) for time-mode switch alarm',
      () {
        // Metro journey:
        //   Metro leg: 0..10000
        //   Walk leg: 10000..10100
        // Event boundary (transfer) is at 6000 (inside the metro leg).
        // At progress=5000, an ETA to 6000 should be under threshold,
        // while ETA to leg end would not. This asserts we target the boundary.
        final legs = [
          _metroLeg(start: 0, end: 10000, lineName: 'Green'),
          _walkLeg(start: 10000, end: 10100, name: 'Exit'),
        ];

        final events = <RouteEventBoundary>[
          RouteEventBoundary(
            meters: 6000,
            type: AlarmEventType.transfer,
            label: 'Transfer @ 6000',
            associatedLegIndex: 0,
          ),
        ];

        final trigger = AlarmEvaluator.evaluateCoinciding(
          mode: AlarmMode.time,
          userValue: 4.0, // 240s
          progressMeters: 5000,
          allEvents: events,
          firedEventIndexes: <int>{},
          firedLegIds: <String>{},
          isMetroLeg: true,
          transitLegs: legs,
          currentLegIndex: 0,
          isFinalLeg: false,
          stepBoundsMeters: const [],
          stepDurationsSeconds: const [],
          currentSpeedMps: 10.0, // buffered ETA = remaining/10 * 1.2
        );

        expect(trigger, isNotNull);
        expect(trigger!.eventType, AlarmEventType.transfer);
        expect(trigger.message, contains('Transfer'));
      },
    );

    test(
      'Metro→non-metro: time-mode switch alarm is allowed on the metro leg (not suppressed)',
      () {
        // Metro journey:
        //   Metro leg: 0..10000
        //   Walk leg: 10000..10300
        // Boundary is at end of metro leg; alarm should be raised on the metro leg.
        final legs = [
          _metroLeg(start: 0, end: 10000, lineName: 'Purple'),
          _walkLeg(start: 10000, end: 10300, name: 'Exit'),
        ];

        final events = <RouteEventBoundary>[
          RouteEventBoundary(
            meters: 10000,
            type: AlarmEventType.modeChange,
            label: 'Start walking',
            associatedLegIndex: 0,
          ),
        ];

        final trigger = AlarmEvaluator.evaluateCoinciding(
          mode: AlarmMode.time,
          userValue: 4.0, // 240s
          progressMeters: 9800,
          allEvents: events,
          firedEventIndexes: <int>{},
          firedLegIds: <String>{},
          isMetroLeg: true,
          transitLegs: legs,
          currentLegIndex: 0,
          isFinalLeg: false,
          stepBoundsMeters: const [],
          stepDurationsSeconds: const [],
          currentSpeedMps: 10.0,
        );

        expect(trigger, isNotNull);
        expect(trigger!.eventType, AlarmEventType.modeChange);
      },
    );

    test(
      'Post-last-metro short connector leg is suppressed (prevents immediate boundary alarm)',
      () {
        // Metro journey:
        //   Metro leg: 0..10000
        //   Walk connector: 10000..10300 (short)
        //   Drive leg: 10300..20000
        // When already past the metro, the short connector should not generate
        // a time-mode switch/mode-change alarm.
        final legs = [
          _metroLeg(start: 0, end: 10000, lineName: 'Green'),
          _walkLeg(start: 10000, end: 10300, name: 'Exit'),
          TransitLegStops(
            legStartMeters: 10300,
            legEndMeters: 20000,
            numStops: 0,
            stopPositions: const [],
            stopMeters: const [],
            lineName: 'Drive',
            isMetro: false,
          ),
        ];

        final events = <RouteEventBoundary>[
          RouteEventBoundary(
            meters: 10000,
            type: AlarmEventType.modeChange,
            label: 'Leave metro',
          ),
        ];

        final trigger = AlarmEvaluator.evaluateCoinciding(
          mode: AlarmMode.time,
          userValue: 4.0, // 240s
          progressMeters: 10250,
          allEvents: events,
          firedEventIndexes: <int>{},
          firedLegIds: <String>{},
          isMetroLeg: false,
          transitLegs: legs,
          currentLegIndex: 1,
          isFinalLeg: false,
          stepBoundsMeters: const [],
          stepDurationsSeconds: const [],
          currentSpeedMps: 10.0,
        );

        expect(trigger, isNull);
      },
    );

    test('Post-last-metro connector leg is NOT suppressed when it is long', () {
      // Same as above, but connector is long enough that a warning may be useful.
      final legs = [
        _metroLeg(start: 0, end: 10000, lineName: 'Green'),
        _walkLeg(start: 10000, end: 11050, name: 'LongExit'), // 1050m
        TransitLegStops(
          legStartMeters: 11050,
          legEndMeters: 20000,
          numStops: 0,
          stopPositions: const [],
          stopMeters: const [],
          lineName: 'Drive',
          isMetro: false,
        ),
      ];

      final events = <RouteEventBoundary>[
        RouteEventBoundary(
          meters: 10000,
          type: AlarmEventType.modeChange,
          label: 'Leave metro',
        ),
        RouteEventBoundary(
          meters: 11050,
          type: AlarmEventType.modeChange,
          label: 'Start driving',
          associatedLegIndex: 1,
        ),
      ];

      final trigger = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.time,
        userValue: 4.0, // 240s
        progressMeters: 10900,
        allEvents: events,
        firedEventIndexes: <int>{},
        firedLegIds: <String>{},
        isMetroLeg: false,
        transitLegs: legs,
        currentLegIndex: 1,
        isFinalLeg: false,
        stepBoundsMeters: const [],
        stepDurationsSeconds: const [],
        currentSpeedMps: 10.0,
      );

      expect(trigger, isNotNull);
      expect(trigger!.eventType, AlarmEventType.modeChange);
    });

    test(
      'Switch targeting does not pick a boundary far beyond this leg (within/near-end guard)',
      () {
        // If the next event boundary is far beyond the current leg end, we should
        // not use it as the time-mode target for this leg.
        //
        // Setup: On metro leg 0..10000, progress=9000.
        // With correct logic (target=legEnd), ETA is small and should fire.
        // If the code incorrectly targets a far boundary at 20000, ETA would be large
        // and would NOT fire.
        final legs = [
          _metroLeg(start: 0, end: 10000, lineName: 'Green'),
          _walkLeg(start: 10000, end: 10200, name: 'Exit'),
        ];

        final events = <RouteEventBoundary>[
          RouteEventBoundary(
            meters: 20000,
            type: AlarmEventType.transfer,
            label: 'Far future boundary',
          ),
        ];

        final trigger = AlarmEvaluator.evaluateCoinciding(
          mode: AlarmMode.time,
          userValue: 4.0, // 240s
          progressMeters: 9000,
          allEvents: events,
          firedEventIndexes: <int>{},
          firedLegIds: <String>{},
          isMetroLeg: true,
          transitLegs: legs,
          currentLegIndex: 0,
          isFinalLeg: false,
          stepBoundsMeters: const [],
          stepDurationsSeconds: const [],
          currentSpeedMps: 10.0,
        );

        expect(trigger, isNotNull);
      },
    );
  });
}
