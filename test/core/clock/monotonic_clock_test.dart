// Regression guard for the P0 never-late bug that clock-jump SIMULATION found:
// reachability measured (t - t0) off the WALL clock (AppClock.now), so a backward
// wall-clock jump (NTP correction / manual set / DST) froze the worst-case cone
// and produced a reproducible ~28-minute LATE fire. The fix routes reachability
// timing through AppClock.monotonicSeconds (Stopwatch-based, never backward).
//
// This proves (a) monotonicSeconds is non-decreasing, and (b) the reachability
// bound keeps growing under a monotonic clock but WOULD freeze under a backward
// clock — i.e. why the monotonic source is load-bearing for never-late.

import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/core/reachability/reachability.dart';

void main() {
  test('monotonicSeconds is non-decreasing (immune to wall-clock direction)',
      () async {
    double last = AppClock().monotonicSeconds();
    for (var i = 0; i < 1000; i++) {
      final now = AppClock().monotonicSeconds();
      expect(now, greaterThanOrEqualTo(last));
      last = now;
    }
    final before = AppClock().monotonicSeconds();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final after = AppClock().monotonicSeconds();
    expect(after, greaterThan(before)); // real elapsed time advanced it forward
  });

  group('reachability bound vs clock direction', () {
    const anchor = ReachabilityAnchor(
        sMeters: 1000.0, accuracyMeters: 10.0, tSeconds: 100.0);

    test('MONOTONIC (forward) time => the cone keeps growing (never-late)', () {
      // t0 = 100; evaluate at 130, 160, 190 (always forward, as a monotonic
      // clock guarantees). The bound must strictly increase.
      double prev = -1;
      for (final t in [130.0, 160.0, 190.0]) {
        final b = Reachability.bound(
            anchor: anchor, nowSeconds: t, vLineMps: 28.0);
        expect(b.sMaxMeters, greaterThan(prev));
        prev = b.sMaxMeters;
      }
    });

    test('BACKWARD wall-clock time => the cone FREEZES (the bug we fixed)', () {
      // If the clock jumps BACKWARD (t < t0), dt clamps to 0 and the bound
      // freezes at the anchor's forward-overbounded position — no growth, so a
      // pending fire never triggers => LATE. This is exactly what a raw wall
      // clock allowed; the monotonic clock makes it unreachable in production.
      final frozen = Reachability.bound(
          anchor: anchor, nowSeconds: 40.0 /* < t0=100 */, vLineMps: 28.0);
      expect(frozen.sMaxMeters, closeTo(anchor.sHi, 1e-9)); // 1010, no growth
      expect(frozen.dtSeconds, 0.0);
    });
  });
}
