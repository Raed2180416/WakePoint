// ZUPT degraded-mode gating — regression tests for the real-ride failure where
// false ZUPT confirms during GPS-denied in-tunnel cruising pinned velocity to
// zero and froze the along-track estimate ~1.3 km behind truth (Majestic
// 2025-12-21 fixture; see underground_validation_execution.md).
//
// Scenario values are taken from the ride's instrumented probe:
//  - smooth cruise: accelVar ≈ 0.026-0.09, gyroVar ≈ 0.0026-0.025,
//    motion=vehicle, EKF v pinned at 0.0 (never learned before GPS loss)
//  - real dwell:    same quiet IMU but motion classifier = stationary.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/zupt_detector.dart';

void main() {
  Duration t(double s) => Duration(microseconds: (s * 1e6).round());

  /// Feed [d] a constant condition for [seconds] at 10 Hz; returns true if any
  /// update confirmed ZUPT.
  bool feed(
    ZuptDetector d, {
    required double from,
    required double seconds,
    required MotionState motion,
    required double v,
    required double accelVar,
    required double gyroVar,
    required bool isDegraded,
  }) {
    var confirmed = false;
    for (var i = 0; i <= (seconds * 10).round(); i++) {
      confirmed |= d.update(
        timestamp: t(from + i / 10.0),
        motion: motion,
        velocityMps: v,
        accelVariance: accelVar,
        gyroVariance: gyroVar,
        isDegraded: isDegraded,
      );
    }
    return confirmed;
  }

  group('ZUPT degraded-mode gating (real-ride regression)', () {
    test(
        'DEGRADED + smooth cruise + pinned-zero velocity must NOT confirm '
        '(the Majestic false-ZUPT storm)', () {
      final d = ZuptDetector();
      // Real cruise signature from the ride: quiet-but-not-classifier-stationary,
      // v pinned at 0 because GPS was lost before speed was learned.
      final confirmed = feed(d,
          from: 44,
          seconds: 5,
          motion: MotionState.vehicle,
          v: 0.0,
          accelVar: 0.026, // passes imuQuiet AND ultra-quiet accel threshold
          gyroVar: 0.0026, // passes ultra-quiet gyro threshold
          isDegraded: true);
      expect(confirmed, isFalse,
          reason: 'velocity-gated paths are invalid during GPS denial; '
              'without classifier corroboration this is a moving train');
    });

    test('DEGRADED + ultra-quiet + classifier-stationary DOES confirm '
        '(real in-tunnel dwell)', () {
      final d = ZuptDetector();
      final confirmed = feed(d,
          from: 0,
          seconds: 5,
          motion: MotionState.stationary,
          v: 0.0,
          accelVar: 0.05,
          gyroVar: 0.004,
          isDegraded: true);
      expect(confirmed, isTrue,
          reason: 'a genuine dwell (ultra-quiet + stationary hint) must still '
              'anchor during GPS denial');
    });

    test('DEGRADED + quiet-but-not-ultra-quiet + stationary hint does NOT '
        'confirm (velocity paths disabled)', () {
      final d = ZuptDetector();
      final confirmed = feed(d,
          from: 0,
          seconds: 5,
          motion: MotionState.stationary,
          v: 0.0,
          accelVar: 0.5, // imuQuiet (<1.0) but NOT ultra-quiet (>=0.15)
          gyroVar: 0.2, //  quiet (<0.40) but NOT ultra-quiet (>=0.05)
          isDegraded: true);
      expect(confirmed, isFalse);
    });

    test('NORMAL mode behaviour unchanged: quiet + low velocity confirms', () {
      final d = ZuptDetector();
      final confirmed = feed(d,
          from: 0,
          seconds: 5,
          motion: MotionState.vehicle, // classifier lag tolerated in normal mode
          v: 0.1,
          accelVar: 0.3,
          gyroVar: 0.05,
          isDegraded: false);
      expect(confirmed, isTrue,
          reason: 'GPS-corroborated velocity makes the velocity-gated path '
              'trustworthy in normal mode (e.g. pre-departure dwell)');
    });

    test('NORMAL mode: moving train (noisy IMU) still never confirms', () {
      final d = ZuptDetector();
      final confirmed = feed(d,
          from: 0,
          seconds: 5,
          motion: MotionState.vehicle,
          v: 12.0,
          accelVar: 1.5,
          gyroVar: 0.5,
          isDegraded: false);
      expect(confirmed, isFalse);
    });
  });
}
