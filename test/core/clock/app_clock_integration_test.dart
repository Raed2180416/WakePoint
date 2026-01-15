/// Integration tests for AppClock time warp functionality.
///
/// These tests verify that the time warp feature correctly accelerates
/// time-dependent logic in the deviation/reroute/alarm pipeline while
/// maintaining correct real-world behavior at 1x warp.
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/services/deviation_monitor.dart';
import 'package:geowake2/services/reroute_policy.dart';
import 'package:geowake2/services/tracking_termination_policy.dart';

void main() {
  group('Time Warp Integration', () {
    tearDown(() {
      // Always reset to real clock after each test
      AppClock.reset();
    });

    group('DeviationMonitor with time warp', () {
      test('sustain detection at 1x takes real duration', () async {
        // At 1x warp, 100ms sustain should take ~100ms real time
        final monitor = DeviationMonitor(
          sustainDuration: const Duration(milliseconds: 100),
        );

        final states = <DeviationState>[];
        final sub = monitor.stream.listen(states.add);

        // First ingestion starts deviation
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states, isNotEmpty, reason: 'First ingest should emit state');
        expect(states.last.offroute, isTrue);
        expect(states.last.sustained, isFalse);

        // Wait less than sustain duration
        await Future.delayed(const Duration(milliseconds: 50));
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.sustained, isFalse);

        // Wait longer than sustain duration total
        await Future.delayed(const Duration(milliseconds: 60));
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.sustained, isTrue);

        await sub.cancel();
        monitor.dispose();
      });

      test('sustain detection accelerated at 100x', () async {
        // Enable time warp
        AppClock().enableSimulation();
        AppClock().setWarpFactor(100.0);

        // 5 second sustain duration
        final monitor = DeviationMonitor(
          sustainDuration: const Duration(seconds: 5),
        );

        final states = <DeviationState>[];
        final sub = monitor.stream.listen(states.add);

        // Start deviation
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states, isNotEmpty);
        expect(states.last.offroute, isTrue);
        expect(states.last.sustained, isFalse);

        // 70ms real = 7s virtual > 5s sustain threshold
        await Future.delayed(const Duration(milliseconds: 70));
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));

        // Should now be sustained
        expect(
          states.last.sustained,
          isTrue,
          reason: '70ms at 100x = 7s virtual > 5s sustain',
        );

        await sub.cancel();
        monitor.dispose();
      });

      test('return to route resets sustain timer', () async {
        AppClock().enableSimulation();
        AppClock().setWarpFactor(50.0);

        final monitor = DeviationMonitor(
          sustainDuration: const Duration(seconds: 3),
        );

        final states = <DeviationState>[];
        final sub = monitor.stream.listen(states.add);

        // Start deviation
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states, isNotEmpty);
        expect(states.last.offroute, isTrue);

        // Wait 40ms real = 2s virtual (less than 3s sustain)
        await Future.delayed(const Duration(milliseconds: 40));
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.sustained, isFalse);

        // Return to route (offset below low threshold)
        monitor.ingest(offsetMeters: 5, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.offroute, isFalse);

        // Deviate again - timer should restart
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.offroute, isTrue);
        expect(states.last.sustained, isFalse);

        // Wait 80ms real = 4s virtual > 3s sustain
        await Future.delayed(const Duration(milliseconds: 80));
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.sustained, isTrue);

        await sub.cancel();
        monitor.dispose();
      });
    });

    group('ReroutePolicy with time warp', () {
      test('cooldown respected at 1x warp', () async {
        final policy = ReroutePolicy(
          cooldown: const Duration(milliseconds: 100),
        );

        final decisions = <RerouteDecision>[];
        final sub = policy.stream.listen(decisions.add);

        // First deviation triggers reroute
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions, isNotEmpty);
        expect(decisions.last.shouldReroute, isTrue);

        // Immediate second call - cooldown active
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions.last.shouldReroute, isFalse);

        // Wait less than cooldown
        await Future.delayed(const Duration(milliseconds: 50));
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions.last.shouldReroute, isFalse);

        // Wait past cooldown
        await Future.delayed(const Duration(milliseconds: 60));
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions.last.shouldReroute, isTrue);

        await sub.cancel();
        policy.dispose();
      });

      test('cooldown accelerated at 100x warp', () async {
        AppClock().enableSimulation();
        AppClock().setWarpFactor(100.0);

        // 10 second cooldown
        final policy = ReroutePolicy(cooldown: const Duration(seconds: 10));

        final decisions = <RerouteDecision>[];
        final sub = policy.stream.listen(decisions.add);

        // First deviation triggers reroute
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions, isNotEmpty);
        expect(decisions.last.shouldReroute, isTrue);

        // Immediately - cooldown active
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions.last.shouldReroute, isFalse);

        // 50ms real = 5s virtual < 10s cooldown
        await Future.delayed(const Duration(milliseconds: 50));
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions.last.shouldReroute, isFalse);

        // 70ms more = 130ms total = 13s virtual > 10s cooldown
        await Future.delayed(const Duration(milliseconds: 70));
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions.last.shouldReroute, isTrue);

        await sub.cancel();
        policy.dispose();
      });

      test('cooldown respects warp factor change mid-session', () async {
        AppClock().enableSimulation();
        AppClock().setWarpFactor(10.0);

        final policy = ReroutePolicy(cooldown: const Duration(seconds: 10));

        final decisions = <RerouteDecision>[];
        final sub = policy.stream.listen(decisions.add);

        // First reroute
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions, isNotEmpty);
        expect(decisions.last.shouldReroute, isTrue);

        // 500ms at 10x = 5s virtual < 10s cooldown
        await Future.delayed(const Duration(milliseconds: 500));
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions.last.shouldReroute, isFalse);

        // Increase warp to 100x
        AppClock().setWarpFactor(100.0);

        // 70ms more at 100x = 7s more virtual
        // Total: 5s + 7s = 12s > 10s cooldown
        await Future.delayed(const Duration(milliseconds: 70));
        policy.onSustainedDeviation(at: AppClock().now());
        await Future.delayed(const Duration(milliseconds: 10));
        expect(decisions.last.shouldReroute, isTrue);

        await sub.cancel();
        policy.dispose();
      });
    });

    group('TrackingTerminationPolicy with time warp', () {
      test('deviation duration calculated correctly at 1x', () async {
        final policy = TrackingTerminationPolicy();
        policy.setDestination(const LatLng(12.9716, 77.5946)); // Bengaluru

        // Start deviation
        policy.onDeviationStart(
          position: const LatLng(12.9720, 77.5950),
          at: AppClock().now(),
        );

        // Wait 50ms
        await Future.delayed(const Duration(milliseconds: 50));

        final duration = policy.currentDeviationDuration;
        expect(duration, isNotNull);
        expect(duration!.inMilliseconds, greaterThanOrEqualTo(40));
        expect(duration.inMilliseconds, lessThan(200));

        policy.reset();
      });

      test('deviation duration accelerated at 100x', () async {
        AppClock().enableSimulation();
        AppClock().setWarpFactor(100.0);

        final policy = TrackingTerminationPolicy();
        policy.setDestination(const LatLng(12.9716, 77.5946));

        // Start deviation
        policy.onDeviationStart(
          position: const LatLng(12.9720, 77.5950),
          at: AppClock().now(),
        );

        // Wait 50ms real = 5s virtual
        await Future.delayed(const Duration(milliseconds: 50));

        final duration = policy.currentDeviationDuration;
        expect(duration, isNotNull);
        // Should be ~5000ms (5s virtual), allow generous bounds
        expect(duration!.inMilliseconds, greaterThan(3000));
        expect(duration.inMilliseconds, lessThan(8000));

        policy.reset();
      });

      test('failed reroute counting works correctly', () async {
        final policy = TrackingTerminationPolicy();
        final destination = const LatLng(12.9716, 77.5946);
        policy.setDestination(destination);

        // Start deviation
        final deviationStart = const LatLng(12.9750, 77.5980);
        policy.onDeviationStart(position: deviationStart, at: AppClock().now());

        // Register failed reroutes
        expect(policy.failedRerouteAttempts, equals(0));
        policy.onRerouteFailed();
        expect(policy.failedRerouteAttempts, equals(1));
        policy.onRerouteFailed();
        expect(policy.failedRerouteAttempts, equals(2));
        policy.onRerouteFailed();
        expect(policy.failedRerouteAttempts, equals(3));

        // Reset should clear counter
        policy.reset();
        expect(policy.failedRerouteAttempts, equals(0));
      });
    });

    group('Cross-component time warp consistency', () {
      test('deviation -> reroute flow respects time warp', () async {
        AppClock().enableSimulation();
        AppClock().setWarpFactor(100.0);

        // Set up components with real-world durations
        final devMonitor = DeviationMonitor(
          sustainDuration: const Duration(seconds: 5), // 5s sustain
        );
        final reroutePolicy = ReroutePolicy(
          cooldown: const Duration(seconds: 10), // 10s cooldown
        );

        final deviationStates = <DeviationState>[];
        final rerouteDecisions = <RerouteDecision>[];

        final devSub = devMonitor.stream.listen(deviationStates.add);
        final rerouteSub = reroutePolicy.stream.listen(rerouteDecisions.add);

        // Wire deviation monitor to reroute policy
        devMonitor.stream.listen((state) {
          if (state.sustained) {
            reroutePolicy.onSustainedDeviation(at: state.at);
          }
        });

        // Start deviation
        devMonitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(deviationStates, isNotEmpty);
        expect(deviationStates.last.offroute, isTrue);
        expect(deviationStates.last.sustained, isFalse);

        // 70ms real = 7s virtual > 5s sustain
        await Future.delayed(const Duration(milliseconds: 70));
        devMonitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 20));

        expect(
          deviationStates.last.sustained,
          isTrue,
          reason: 'Deviation should be sustained after 7s virtual',
        );
        expect(rerouteDecisions.isNotEmpty, isTrue);
        expect(
          rerouteDecisions.last.shouldReroute,
          isTrue,
          reason: 'First sustained deviation should trigger reroute',
        );

        // Immediately trigger another call - cooldown active
        devMonitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 20));

        // Store count
        final decisionsCount = rerouteDecisions.length;

        // 120ms real = 12s virtual > 10s cooldown
        await Future.delayed(const Duration(milliseconds: 120));
        devMonitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 20));

        // New reroute should be allowed
        expect(rerouteDecisions.length, greaterThan(decisionsCount));
        expect(
          rerouteDecisions.last.shouldReroute,
          isTrue,
          reason: 'Reroute should be allowed after cooldown expires',
        );

        await devSub.cancel();
        await rerouteSub.cancel();
        devMonitor.dispose();
        reroutePolicy.dispose();
      });

      test('time warp disabled returns to real-world timing', () async {
        // First enable warp
        AppClock().enableSimulation();
        AppClock().setWarpFactor(100.0);

        final monitor = DeviationMonitor(
          sustainDuration: const Duration(seconds: 5),
        );

        final states = <DeviationState>[];
        final sub = monitor.stream.listen(states.add);

        // Start deviation
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));

        // At 100x, 70ms = 7s should trigger sustain
        await Future.delayed(const Duration(milliseconds: 70));
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.sustained, isTrue);

        // Disable warp
        AppClock().disableSimulation();
        expect(AppClock().isSimulating, isFalse);
        expect(AppClock().warpFactor, 1.0);

        // Reset and start new deviation
        monitor.reset();
        states.clear();

        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.sustained, isFalse);

        // At 1x, 100ms should NOT trigger 5s sustain
        await Future.delayed(const Duration(milliseconds: 100));
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(
          states.last.sustained,
          isFalse,
          reason:
              '100ms real time should not exceed 5s sustain threshold at 1x',
        );

        await sub.cancel();
        monitor.dispose();
      });
    });

    group('Real-world behavior preservation', () {
      test('components work correctly without simulation enabled', () async {
        // Verify default behavior is unchanged
        expect(AppClock().isSimulating, isFalse);
        expect(AppClock().warpFactor, 1.0);

        final monitor = DeviationMonitor(
          sustainDuration: const Duration(milliseconds: 100),
        );

        final states = <DeviationState>[];
        final sub = monitor.stream.listen(states.add);

        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.sustained, isFalse);

        await Future.delayed(const Duration(milliseconds: 110));
        monitor.ingest(offsetMeters: 50, speedMps: 5);
        await Future.delayed(const Duration(milliseconds: 10));
        expect(states.last.sustained, isTrue);

        await sub.cancel();
        monitor.dispose();
      });

      test('rapid state changes handled correctly', () async {
        AppClock().enableSimulation();
        AppClock().setWarpFactor(50.0);

        final monitor = DeviationMonitor(
          sustainDuration: const Duration(seconds: 2),
        );

        final states = <DeviationState>[];
        final sub = monitor.stream.listen(states.add);

        // Rapid state changes
        for (int i = 0; i < 20; i++) {
          final offset = (i % 2 == 0) ? 50.0 : 5.0; // Alternate on/off route
          monitor.ingest(offsetMeters: offset, speedMps: 5);
          await Future.delayed(const Duration(milliseconds: 10));
        }

        // Should have toggled many times, never sustained (each on-route resets)
        expect(
          states.where((s) => s.sustained).isEmpty,
          isTrue,
          reason: 'Rapid toggling should prevent sustain accumulation',
        );

        await sub.cancel();
        monitor.dispose();
      });
    });
  });
}
