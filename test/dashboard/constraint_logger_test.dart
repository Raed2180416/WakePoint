/// Tests for constraint logger.
import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/dashboard/constraint_logger.dart';

void main() {
  group('ConstraintLogger', () {
    setUp(() {
      ConstraintLogger.resetForTesting();
    });

    test('singleton instance works', () {
      final logger1 = ConstraintLogger.instance;
      final logger2 = ConstraintLogger.instance;
      expect(identical(logger1, logger2), isTrue);
    });

    test('logs events correctly', () {
      final logger = ConstraintLogger.instance;
      final event = ConstraintEvent.info(
        timestamp: DateTime.now(),
        title: 'Test Event',
        description: 'Test description',
      );

      logger.log(event);

      expect(logger.eventCount, 1);
      expect(logger.events.first.title, 'Test Event');
    });

    test('clear() removes all events', () {
      final logger = ConstraintLogger.instance;
      logger.log(
        ConstraintEvent.info(timestamp: DateTime.now(), title: 'Event 1'),
      );
      logger.log(
        ConstraintEvent.info(timestamp: DateTime.now(), title: 'Event 2'),
      );

      expect(logger.eventCount, 2);

      logger.clear();

      expect(logger.eventCount, 0);
    });

    test('eventsOfType filters correctly', () {
      final logger = ConstraintLogger.instance;
      final now = DateTime.now();

      logger.log(
        ConstraintEvent.deviationDetected(
          timestamp: now,
          offsetMeters: 50,
          thresholdMeters: 30,
        ),
      );
      logger.log(ConstraintEvent.info(timestamp: now, title: 'Info'));
      logger.log(
        ConstraintEvent.deviationSustained(
          timestamp: now,
          duration: const Duration(seconds: 5),
          offsetMeters: 50,
        ),
      );

      final deviationEvents = logger.eventsOfType(
        ConstraintEventType.deviationDetected,
      );
      expect(deviationEvents.length, 1);

      final infoEvents = logger.eventsOfType(ConstraintEventType.info);
      expect(infoEvents.length, 1);
    });

    test('lastEvents returns correct count', () {
      final logger = ConstraintLogger.instance;
      final now = DateTime.now();

      for (int i = 0; i < 10; i++) {
        logger.log(ConstraintEvent.info(timestamp: now, title: 'Event $i'));
      }

      final last5 = logger.lastEvents(5);
      expect(last5.length, 5);
      expect(last5.first.title, 'Event 5');
      expect(last5.last.title, 'Event 9');
    });

    test('eventStream emits new events', () async {
      final logger = ConstraintLogger.instance;
      final events = <ConstraintEvent>[];
      final sub = logger.eventStream.listen(events.add);

      logger.log(
        ConstraintEvent.info(timestamp: DateTime.now(), title: 'Event 1'),
      );
      logger.log(
        ConstraintEvent.info(timestamp: DateTime.now(), title: 'Event 2'),
      );

      await Future.delayed(Duration.zero);

      expect(events.length, 2);
      expect(events[0].title, 'Event 1');
      expect(events[1].title, 'Event 2');

      await sub.cancel();
    });

    test('eventsSince filters by timestamp', () {
      final logger = ConstraintLogger.instance;
      final base = DateTime(2025, 1, 7, 12, 0, 0);

      logger.log(ConstraintEvent.info(timestamp: base, title: 'Event 1'));
      logger.log(
        ConstraintEvent.info(
          timestamp: base.add(const Duration(minutes: 1)),
          title: 'Event 2',
        ),
      );
      logger.log(
        ConstraintEvent.info(
          timestamp: base.add(const Duration(minutes: 2)),
          title: 'Event 3',
        ),
      );

      final since = logger.eventsSince(base.add(const Duration(seconds: 30)));
      expect(since.length, 2);
      expect(since[0].title, 'Event 2');
    });
  });

  group('ConstraintEvent factories', () {
    final now = DateTime.now();

    test('deviationDetected creates correct event', () {
      final event = ConstraintEvent.deviationDetected(
        timestamp: now,
        offsetMeters: 45.5,
        thresholdMeters: 30,
      );

      expect(event.type, ConstraintEventType.deviationDetected);
      expect(event.title, 'Deviation Detected');
      expect(event.details['offsetMeters'], 45.5);
      expect(event.details['thresholdMeters'], 30);
      expect(event.description, contains('45.5m'));
    });

    test('deviationSustained creates correct event', () {
      final event = ConstraintEvent.deviationSustained(
        timestamp: now,
        duration: const Duration(seconds: 10),
        offsetMeters: 50,
      );

      expect(event.type, ConstraintEventType.deviationSustained);
      expect(event.title, 'Deviation Sustained');
      expect(event.details['durationMs'], 10000);
    });

    test('rerouteTriggered creates correct event', () {
      final event = ConstraintEvent.rerouteTriggered(
        timestamp: now,
        reason: 'Test reason',
      );

      expect(event.type, ConstraintEventType.rerouteTriggered);
      expect(event.title, 'Reroute Triggered');
      expect(event.details['reason'], 'Test reason');
    });

    test('rerouteSuccess creates correct event', () {
      final event = ConstraintEvent.rerouteSuccess(
        timestamp: now,
        newRoutePoints: 150,
      );

      expect(event.type, ConstraintEventType.rerouteSuccess);
      expect(event.title, 'Reroute Success');
      expect(event.details['newRoutePoints'], 150);
    });

    test('rerouteFailed creates correct event', () {
      final event = ConstraintEvent.rerouteFailed(
        timestamp: now,
        error: 'Network error',
      );

      expect(event.type, ConstraintEventType.rerouteFailed);
      expect(event.title, 'Reroute Failed');
      expect(event.details['error'], 'Network error');
    });

    test('warpFactorChange creates correct event', () {
      final event = ConstraintEvent.warpFactorChange(
        timestamp: now,
        oldFactor: 1.0,
        newFactor: 100.0,
      );

      expect(event.type, ConstraintEventType.warpFactorChange);
      expect(event.title, contains('100x'));
      expect(event.details['oldFactor'], 1.0);
      expect(event.details['newFactor'], 100.0);
    });
  });
}
