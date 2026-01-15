import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/clock/app_clock.dart';

void main() {
  group('AppClock', () {
    tearDown(() {
      // Always reset to real clock after each test
      AppClock.reset();
    });

    group('Singleton behavior', () {
      test('factory returns same instance', () {
        final clock1 = AppClock();
        final clock2 = AppClock();
        expect(identical(clock1, clock2), isTrue);
      });

      test('reset creates fresh instance', () {
        final clock1 = AppClock();
        clock1.enableSimulation();
        AppClock.reset();
        final clock2 = AppClock();

        expect(clock2.isSimulating, isFalse);
        expect(clock2.warpFactor, 1.0);
      });

      test('install replaces singleton', () {
        final original = AppClock();
        final custom = _TestableAppClock();
        AppClock.install(custom);

        expect(identical(AppClock(), custom), isTrue);
        expect(identical(AppClock(), original), isFalse);
      });
    });

    group('Real-time mode (default)', () {
      test('now() returns approximately DateTime.now()', () {
        final clock = AppClock();
        final before = DateTime.now();
        final clockTime = clock.now();
        final after = DateTime.now();

        expect(clockTime.isAfter(before) || clockTime == before, isTrue);
        expect(clockTime.isBefore(after) || clockTime == after, isTrue);
      });

      test('isSimulating is false by default', () {
        expect(AppClock().isSimulating, isFalse);
      });

      test('warpFactor is 1.0 by default', () {
        expect(AppClock().warpFactor, 1.0);
      });

      test('since() returns real elapsed duration', () async {
        final clock = AppClock();
        final start = clock.now();

        await Future.delayed(const Duration(milliseconds: 50));

        final elapsed = clock.since(start);
        expect(elapsed.inMilliseconds, greaterThanOrEqualTo(40));
        expect(elapsed.inMilliseconds, lessThan(200)); // Allow for test jitter
      });

      test('hasElapsed() works correctly', () async {
        final clock = AppClock();
        final start = clock.now();

        expect(
          clock.hasElapsed(start, const Duration(milliseconds: 50)),
          isFalse,
        );

        await Future.delayed(const Duration(milliseconds: 60));

        expect(
          clock.hasElapsed(start, const Duration(milliseconds: 50)),
          isTrue,
        );
      });
    });

    group('Simulation mode', () {
      test('enableSimulation() activates simulation mode', () {
        final clock = AppClock();
        expect(clock.isSimulating, isFalse);

        clock.enableSimulation();
        expect(clock.isSimulating, isTrue);
      });

      test('disableSimulation() deactivates and resets warp', () {
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(100.0);

        clock.disableSimulation();
        expect(clock.isSimulating, isFalse);
        expect(clock.warpFactor, 1.0);
      });

      test('enableSimulation with startAt sets initial virtual time', () {
        final clock = AppClock();
        final customStart = DateTime(2025, 6, 15, 12, 30, 0);

        clock.enableSimulation(startAt: customStart);

        // At warp 1.0, time should be very close to customStart
        final now = clock.now();
        expect(now.difference(customStart).inSeconds.abs(), lessThan(1));
      });
    });

    group('Warp factor', () {
      test('setWarpFactor rejects values below 1.0', () {
        final clock = AppClock();
        expect(() => clock.setWarpFactor(0.5), throwsA(isA<ArgumentError>()));
      });

      test('setWarpFactor rejects values above 500.0', () {
        final clock = AppClock();
        expect(() => clock.setWarpFactor(501.0), throwsA(isA<ArgumentError>()));
      });

      test('setWarpFactor accepts boundary values', () {
        final clock = AppClock();
        clock.setWarpFactor(1.0);
        expect(clock.warpFactor, 1.0);

        clock.setWarpFactor(500.0);
        expect(clock.warpFactor, 500.0);
      });

      test(
        'warp factor 1.0 returns real time even in simulation mode',
        () async {
          final clock = AppClock();
          clock.enableSimulation();
          // Default warp is 1.0

          await Future.delayed(const Duration(milliseconds: 50));
          final clockTime = clock.now();
          final realTime = DateTime.now();

          // Should be very close to real time
          final diff = clockTime.difference(realTime).inMilliseconds.abs();
          expect(diff, lessThan(20));
        },
      );
    });

    group('Time warping math', () {
      test('warp factor 10x accelerates time 10x', () async {
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(10.0);

        final start = clock.now();
        await Future.delayed(const Duration(milliseconds: 100));
        final elapsed = clock.since(start);

        // 100ms real time at 10x = ~1000ms virtual time
        // Allow ±200ms for test timing variance
        expect(elapsed.inMilliseconds, greaterThan(800));
        expect(elapsed.inMilliseconds, lessThan(1400));
      });

      test('warp factor 100x accelerates time 100x', () async {
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(100.0);

        final start = clock.now();
        await Future.delayed(const Duration(milliseconds: 50));
        final elapsed = clock.since(start);

        // 50ms real time at 100x = ~5000ms virtual time
        // Allow generous bounds for test timing variance
        expect(elapsed.inMilliseconds, greaterThan(3000));
        expect(elapsed.inMilliseconds, lessThan(8000));
      });

      test(
        'changing warp factor mid-simulation preserves virtual time',
        () async {
          final clock = AppClock();
          clock.enableSimulation();
          clock.setWarpFactor(10.0);

          // Advance 100ms real = ~1000ms virtual
          await Future.delayed(const Duration(milliseconds: 100));
          final timeBeforeChange = clock.now();

          // Change to 50x
          clock.setWarpFactor(50.0);
          final timeAfterChange = clock.now();

          // Virtual time should be continuous (within small delta)
          final diff =
              timeAfterChange.difference(timeBeforeChange).inMilliseconds.abs();
          expect(diff, lessThan(100)); // Should be nearly identical
        },
      );

      test('hasElapsed respects warp factor', () async {
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(100.0);

        final start = clock.now();

        // 10ms real at 100x = 1000ms virtual
        await Future.delayed(const Duration(milliseconds: 15));

        // 500ms virtual should have elapsed
        expect(
          clock.hasElapsed(start, const Duration(milliseconds: 500)),
          isTrue,
        );

        // 5000ms virtual may or may not have elapsed (depends on timing)
        // But definitely less than 10s virtual shouldn't have passed in 15ms real
        // Actually at 100x, 15ms = 1500ms virtual, so 1000ms definitely elapsed
        expect(clock.hasElapsed(start, const Duration(seconds: 1)), isTrue);
      });
    });

    group('Timer utilities', () {
      test(
        'createPeriodicTimer fires at real intervals with warped time',
        () async {
          final clock = AppClock();
          clock.enableSimulation();
          clock.setWarpFactor(50.0);

          final timestamps = <DateTime>[];
          final timer = clock.createPeriodicTimer(
            const Duration(milliseconds: 20),
            (now) => timestamps.add(now),
          );

          // Let it fire a few times
          await Future.delayed(const Duration(milliseconds: 100));
          timer.cancel();

          // Should have fired ~4-5 times in 100ms at 20ms intervals
          expect(timestamps.length, greaterThanOrEqualTo(3));
          expect(timestamps.length, lessThanOrEqualTo(7));

          // Virtual time between callbacks should be ~1000ms (20ms * 50x)
          if (timestamps.length >= 2) {
            final virtualDelta =
                timestamps[1].difference(timestamps[0]).inMilliseconds;
            expect(virtualDelta, greaterThan(500)); // ~1000ms expected
            expect(virtualDelta, lessThan(2000));
          }
        },
      );

      test('createTimer fires once with warped time', () async {
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(10.0);

        DateTime? capturedTime;
        final timer = clock.createTimer(
          const Duration(milliseconds: 50),
          (now) => capturedTime = now,
        );

        await Future.delayed(const Duration(milliseconds: 100));

        expect(capturedTime, isNotNull);
        timer.cancel(); // No-op but good practice
      });
    });

    group('DateTimeClockExtension', () {
      test('elapsed uses AppClock', () async {
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(20.0);

        final start = clock.now();
        await Future.delayed(const Duration(milliseconds: 50));

        // 50ms at 20x = ~1000ms virtual
        final elapsed = start.elapsed;
        expect(elapsed.inMilliseconds, greaterThan(500));
      });

      test('hasElapsed extension uses AppClock', () async {
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(100.0);

        final start = clock.now();
        await Future.delayed(const Duration(milliseconds: 20));

        // 20ms at 100x = 2000ms virtual
        expect(start.hasElapsed(const Duration(seconds: 1)), isTrue);
      });
    });

    group('Real-world behavior preservation', () {
      test('disabled simulation returns exact DateTime.now()', () {
        final clock = AppClock();
        // Ensure simulation is disabled
        clock.disableSimulation();

        for (int i = 0; i < 10; i++) {
          final clockNow = clock.now();
          final realNow = DateTime.now();

          // Should be within 1ms of each other
          final diff = clockNow.difference(realNow).inMicroseconds.abs();
          expect(diff, lessThan(5000)); // 5ms tolerance
        }
      });

      test(
        'warp factor 1.0 in simulation mode still returns real time',
        () async {
          final clock = AppClock();
          clock.enableSimulation();
          // Warp factor defaults to 1.0

          final start = DateTime.now();
          await Future.delayed(const Duration(milliseconds: 100));

          final clockElapsed = clock.since(start);
          final realElapsed = DateTime.now().difference(start);

          // Should be nearly identical
          final diff =
              (clockElapsed.inMilliseconds - realElapsed.inMilliseconds).abs();
          expect(diff, lessThan(20));
        },
      );

      test('typical cooldown check works correctly at 1x', () async {
        // Simulate how reroute_policy.dart checks cooldown
        final clock = AppClock();
        const cooldown = Duration(seconds: 1);

        final lastRerouteAt = clock.now();

        // Immediately after: cooldown active
        expect(clock.hasElapsed(lastRerouteAt, cooldown), isFalse);

        // Wait less than cooldown
        await Future.delayed(const Duration(milliseconds: 100));
        expect(clock.hasElapsed(lastRerouteAt, cooldown), isFalse);
      });

      test('typical cooldown check accelerated at 100x', () async {
        // Same cooldown check but with warp
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(100.0);
        const cooldown = Duration(seconds: 10); // 10 second cooldown

        final lastRerouteAt = clock.now();

        // Immediately after: cooldown active
        expect(clock.hasElapsed(lastRerouteAt, cooldown), isFalse);

        // 150ms real at 100x = 15s virtual > 10s cooldown
        await Future.delayed(const Duration(milliseconds: 150));
        expect(clock.hasElapsed(lastRerouteAt, cooldown), isTrue);
      });

      test('deviation sustain detection at 1x', () async {
        // Simulate deviation_monitor.dart sustain check
        final clock = AppClock();
        const sustainDuration = Duration(seconds: 5);

        final deviationStarted = clock.now();

        // Not sustained immediately
        expect(clock.hasElapsed(deviationStarted, sustainDuration), isFalse);

        // Still not sustained after 100ms
        await Future.delayed(const Duration(milliseconds: 100));
        expect(clock.hasElapsed(deviationStarted, sustainDuration), isFalse);
      });

      test('deviation sustain detection at 500x', () async {
        // Same sustain check but with max warp
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(500.0);
        const sustainDuration = Duration(seconds: 5);

        final deviationStarted = clock.now();

        // Not sustained immediately
        expect(clock.hasElapsed(deviationStarted, sustainDuration), isFalse);

        // 20ms real at 500x = 10s virtual > 5s sustain
        await Future.delayed(const Duration(milliseconds: 20));
        expect(clock.hasElapsed(deviationStarted, sustainDuration), isTrue);
      });
    });

    group('Edge cases', () {
      test('handles very small warp factors', () {
        final clock = AppClock();
        clock.setWarpFactor(1.0);
        expect(clock.warpFactor, 1.0);

        clock.setWarpFactor(1.001);
        expect(clock.warpFactor, closeTo(1.001, 0.0001));
      });

      test('handles rapid enable/disable cycles', () {
        final clock = AppClock();

        for (int i = 0; i < 100; i++) {
          clock.enableSimulation();
          clock.setWarpFactor((i % 499) + 1.0);
          clock.disableSimulation();
        }

        expect(clock.isSimulating, isFalse);
        expect(clock.warpFactor, 1.0);
      });

      test('handles rapid warp factor changes', () async {
        final clock = AppClock();
        clock.enableSimulation();

        final start = clock.now();

        // Rapidly change warp factor
        for (int i = 1; i <= 100; i++) {
          clock.setWarpFactor(i * 5.0.clamp(1.0, 500.0));
          await Future.delayed(const Duration(microseconds: 100));
        }

        // Time should have advanced
        final elapsed = clock.since(start);
        expect(elapsed.inMilliseconds, greaterThan(0));
      });

      test('now() is monotonically increasing at fixed warp', () async {
        final clock = AppClock();
        clock.enableSimulation();
        clock.setWarpFactor(10.0);

        DateTime? previous;
        for (int i = 0; i < 50; i++) {
          final current = clock.now();
          if (previous != null) {
            expect(
              current.isAfter(previous) || current == previous,
              isTrue,
              reason: 'Time should not go backwards',
            );
          }
          previous = current;
          await Future.delayed(const Duration(microseconds: 100));
        }
      });
    });
  });
}

/// Testable mock clock for custom clock injection tests.
/// Uses composition instead of inheritance since AppClock constructor is private.
class _TestableAppClock implements AppClock {
  DateTime? fixedTime;
  final AppClock _delegate = AppClock();

  @override
  DateTime now() => fixedTime ?? _delegate.now();

  @override
  bool get isSimulating => _delegate.isSimulating;

  @override
  double get warpFactor => _delegate.warpFactor;

  @override
  void setWarpFactor(double factor) => _delegate.setWarpFactor(factor);

  @override
  void enableSimulation({DateTime? startAt}) =>
      _delegate.enableSimulation(startAt: startAt);

  @override
  void disableSimulation() => _delegate.disableSimulation();

  @override
  Duration since(DateTime past) => now().difference(past);

  @override
  bool hasElapsed(DateTime since, Duration duration) =>
      now().difference(since) >= duration;

  @override
  Timer createPeriodicTimer(
    Duration interval,
    void Function(DateTime now) callback,
  ) => Timer.periodic(interval, (_) => callback(now()));

  @override
  Timer createTimer(Duration duration, void Function(DateTime now) callback) =>
      Timer(duration, () => callback(now()));
}
