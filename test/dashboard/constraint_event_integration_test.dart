import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/dashboard/constraint_logger.dart';
import 'package:geowake2/services/deviation_monitor.dart';
import 'package:geowake2/services/reroute_policy.dart';

void main() {
  group('DeviationMonitor constraint logging', () {
    late DeviationMonitor monitor;
    late List<ConstraintEvent> capturedEvents;
    late StreamSubscription<ConstraintEvent> sub;

    setUp(() {
      AppClock.reset();
      ConstraintLogger.instance.clear();
      monitor = DeviationMonitor(sustainDuration: const Duration(seconds: 2));
      capturedEvents = [];
      sub = ConstraintLogger.instance.eventStream.listen(capturedEvents.add);
    });

    tearDown(() async {
      await sub.cancel();
      monitor.dispose();
      ConstraintLogger.instance.clear();
      AppClock.reset();
    });

    test('logs deviationDetected when threshold exceeded', () async {
      final baseTime = DateTime(2025, 1, 7, 10, 0, 0);

      // Under threshold - no event
      monitor.ingest(offsetMeters: 10, speedMps: 5, at: baseTime);
      await Future.delayed(const Duration(milliseconds: 10));
      expect(capturedEvents, isEmpty);

      // Over threshold - event logged
      // threshold = 15 + 1.5 * 5 = 22.5m
      monitor.ingest(
        offsetMeters: 25,
        speedMps: 5,
        at: baseTime.add(const Duration(seconds: 1)),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 1);
      expect(capturedEvents.first.type, ConstraintEventType.deviationDetected);
      expect(capturedEvents.first.title, 'Deviation Detected');
      expect(capturedEvents.first.details['offsetMeters'], 25);
    });

    test('logs deviationSustained after duration', () async {
      final baseTime = DateTime(2025, 1, 7, 10, 0, 0);

      // Start deviation
      monitor.ingest(offsetMeters: 30, speedMps: 5, at: baseTime);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 1);
      expect(capturedEvents.first.type, ConstraintEventType.deviationDetected);

      // Continue deviation - not yet sustained
      monitor.ingest(
        offsetMeters: 30,
        speedMps: 5,
        at: baseTime.add(const Duration(seconds: 1)),
      );
      await Future.delayed(const Duration(milliseconds: 10));
      expect(capturedEvents.length, 1);

      // Sustain threshold reached (2 seconds)
      monitor.ingest(
        offsetMeters: 30,
        speedMps: 5,
        at: baseTime.add(const Duration(seconds: 2)),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 2);
      expect(capturedEvents.last.type, ConstraintEventType.deviationSustained);
      expect(capturedEvents.last.title, 'Deviation Sustained');
    });

    test('logs backOnRoute when returning', () async {
      final baseTime = DateTime(2025, 1, 7, 10, 0, 0);

      // Start deviation
      monitor.ingest(offsetMeters: 30, speedMps: 5, at: baseTime);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 1);

      // Return to route (below low threshold = 0.7 * 22.5 = 15.75m)
      monitor.ingest(
        offsetMeters: 10,
        speedMps: 5,
        at: baseTime.add(const Duration(seconds: 1)),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 2);
      expect(capturedEvents.last.type, ConstraintEventType.backOnRoute);
      expect(capturedEvents.last.title, 'Back on Route');
    });
  });

  group('ReroutePolicy constraint logging', () {
    late ReroutePolicy policy;
    late List<ConstraintEvent> capturedEvents;
    late StreamSubscription<ConstraintEvent> sub;

    setUp(() {
      AppClock.reset();
      ConstraintLogger.instance.clear();
      policy = ReroutePolicy(cooldown: const Duration(seconds: 10));
      capturedEvents = [];
      sub = ConstraintLogger.instance.eventStream.listen(capturedEvents.add);
    });

    tearDown(() async {
      await sub.cancel();
      policy.dispose();
      ConstraintLogger.instance.clear();
      AppClock.reset();
    });

    test('logs rerouteTriggered on first deviation', () async {
      final time = DateTime(2025, 1, 7, 10, 0, 0);

      policy.onSustainedDeviation(at: time);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 1);
      expect(capturedEvents.first.type, ConstraintEventType.rerouteTriggered);
      expect(capturedEvents.first.title, 'Reroute Triggered');
    });

    test('logs rerouteSkipped during cooldown', () async {
      final time1 = DateTime(2025, 1, 7, 10, 0, 0);
      final time2 = time1.add(const Duration(seconds: 5)); // Within cooldown

      policy.onSustainedDeviation(at: time1);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 1);
      expect(capturedEvents.first.type, ConstraintEventType.rerouteTriggered);

      policy.onSustainedDeviation(at: time2);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 2);
      expect(capturedEvents.last.type, ConstraintEventType.rerouteSkipped);
      expect(capturedEvents.last.details['reason'], 'cooldown');
    });

    test('logs rerouteSkipped when offline', () async {
      final time = DateTime(2025, 1, 7, 10, 0, 0);

      policy.setOnline(false);
      policy.onSustainedDeviation(at: time);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 1);
      expect(capturedEvents.first.type, ConstraintEventType.rerouteSkipped);
      expect(capturedEvents.first.details['reason'], 'offline');
    });

    test('logs rerouteTriggered after cooldown expires', () async {
      final time1 = DateTime(2025, 1, 7, 10, 0, 0);
      final time2 = time1.add(const Duration(seconds: 15)); // After cooldown

      policy.onSustainedDeviation(at: time1);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 1);
      expect(capturedEvents.first.type, ConstraintEventType.rerouteTriggered);

      policy.onSustainedDeviation(at: time2);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 2);
      expect(capturedEvents.last.type, ConstraintEventType.rerouteTriggered);
    });
  });

  group('ConstraintLogger integration with time warp', () {
    late DeviationMonitor monitor;
    late List<ConstraintEvent> capturedEvents;
    late StreamSubscription<ConstraintEvent> sub;

    setUp(() {
      AppClock.reset();
      ConstraintLogger.instance.clear();
      monitor = DeviationMonitor(sustainDuration: const Duration(seconds: 5));
      capturedEvents = [];
      sub = ConstraintLogger.instance.eventStream.listen(capturedEvents.add);
    });

    tearDown(() async {
      await sub.cancel();
      monitor.dispose();
      ConstraintLogger.instance.clear();
      AppClock.reset();
    });

    test(
      'events use warped timestamps when AppClock is in simulation mode',
      () async {
        final startVirtual = DateTime(2025, 1, 7, 10, 0, 0);

        AppClock().enableSimulation(startAt: startVirtual);
        AppClock().setWarpFactor(100); // 100x warp

        // Small delay to let virtual time advance
        await Future.delayed(const Duration(milliseconds: 50));

        // Now trigger a deviation
        monitor.ingest(offsetMeters: 30, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));

        expect(capturedEvents.length, 1);

        // The timestamp should be in the "virtual" time domain
        // At 100x warp, 50ms real = 5000ms virtual = 5 seconds
        final eventTime = capturedEvents.first.timestamp;
        final expectedMinVirtual = startVirtual.add(const Duration(seconds: 1));

        expect(eventTime.isAfter(startVirtual), isTrue);
        expect(eventTime.isAfter(expectedMinVirtual), isTrue);
      },
    );

    test('sustain detection uses warped time correctly', () async {
      final startVirtual = DateTime(2025, 1, 7, 10, 0, 0);

      AppClock().enableSimulation(startAt: startVirtual);
      AppClock().setWarpFactor(100); // 100x warp - 5s sustain = 50ms real

      // Trigger deviation
      monitor.ingest(offsetMeters: 30, speedMps: 5);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 1);
      expect(capturedEvents.first.type, ConstraintEventType.deviationDetected);

      // Wait 60ms real time = 6 seconds virtual time (> 5s sustain)
      await Future.delayed(const Duration(milliseconds: 60));

      // Trigger another ingest to check sustain
      monitor.ingest(offsetMeters: 30, speedMps: 5);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(capturedEvents.length, 2);
      expect(capturedEvents.last.type, ConstraintEventType.deviationSustained);
    });
  });

  group('Full integration flow', () {
    test('deviation → sustain → reroute flow logs all events', () async {
      AppClock.reset();
      ConstraintLogger.instance.clear();

      final monitor = DeviationMonitor(
        sustainDuration: const Duration(seconds: 2),
      );
      final policy = ReroutePolicy(cooldown: const Duration(seconds: 10));

      final capturedEvents = <ConstraintEvent>[];
      final sub = ConstraintLogger.instance.eventStream.listen(
        capturedEvents.add,
      );

      final baseTime = DateTime(2025, 1, 7, 10, 0, 0);

      // 1. Initial deviation detected
      monitor.ingest(offsetMeters: 30, speedMps: 5, at: baseTime);
      await Future.delayed(const Duration(milliseconds: 10));

      // 2. Sustain reached
      monitor.ingest(
        offsetMeters: 30,
        speedMps: 5,
        at: baseTime.add(const Duration(seconds: 2)),
      );
      await Future.delayed(const Duration(milliseconds: 10));

      // 3. Reroute triggered (based on sustained state)
      policy.onSustainedDeviation(at: baseTime.add(const Duration(seconds: 2)));
      await Future.delayed(const Duration(milliseconds: 10));

      // Verify event sequence
      expect(capturedEvents.length, 3);
      expect(capturedEvents[0].type, ConstraintEventType.deviationDetected);
      expect(capturedEvents[1].type, ConstraintEventType.deviationSustained);
      expect(capturedEvents[2].type, ConstraintEventType.rerouteTriggered);

      // Verify timestamps are in order
      expect(capturedEvents[0].timestamp, baseTime);
      expect(
        capturedEvents[1].timestamp,
        baseTime.add(const Duration(seconds: 2)),
      );
      expect(
        capturedEvents[2].timestamp,
        baseTime.add(const Duration(seconds: 2)),
      );

      await sub.cancel();
      monitor.dispose();
      policy.dispose();
      ConstraintLogger.instance.clear();
      AppClock.reset();
    });
  });
}
