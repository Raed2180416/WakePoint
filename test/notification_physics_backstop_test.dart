// P0-00 (GW-0080) — the OS process-death backstop must be PHYSICS-never-late,
// not a frozen ETA. Before this fix the setAlarmClock backstop was scheduled
// from smoothedETA, which freezes during a GPS blackout (recomputed only on real
// fixes) so its fire instant marches forward (postponed); on process death
// mid-blackout the sole surviving wake could fire LATE.
//
// This tests the pure, deterministic never-late math
// (AlarmController.backstopPhysicsFireInSeconds). The end-to-end
// min(eta, physics) arming is never-WORSE by construction (min can only move the
// backstop EARLIER than today's ETA-based time) and needs on-device L2
// validation (Doze + process kill) — see docs/testing/TESTING_SESSION_LOG.md.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/tracking/alarm_controller.dart';

void main() {
  group('backstopPhysicsFireInSeconds — physics never-late instant', () {
    test('fires at or before true arrival (V_LINE over-bounds true speed)', () {
      // Anchor at s=0,t=0; target 2800 m; V_LINE=28 m/s ⇒ reach at 100 s.
      // A true train at 24 m/s (< V_LINE) arrives at 2800/24 = 116.7 s.
      const vLine = 28.0, target = 2800.0;
      final fireIn = AlarmController.backstopPhysicsFireInSeconds(
        anchorSHiMeters: 0, anchorTSeconds: 0,
        targetMeters: target, vLineMps: vLine, nowSeconds: 0);
      expect(fireIn, closeTo(100.0, 1e-9));
      const trueArrival = 2800.0 / 24.0; // 116.7 s
      expect(fireIn!, lessThanOrEqualTo(trueArrival),
          reason: 'physics fire must be at-or-before true arrival');
    });

    test('NO postpone: now + result is a FIXED instant as now advances', () {
      // Frozen anchor (last real fix at s=500,t=10); as nowSeconds sweeps a
      // blackout, the absolute fire instant (nowSeconds + result) is constant.
      const anchorS = 500.0, anchorT = 10.0, target = 5000.0, vLine = 28.0;
      double? absInstant;
      for (final now in [10.0, 30.0, 90.0, 150.0]) {
        final r = AlarmController.backstopPhysicsFireInSeconds(
          anchorSHiMeters: anchorS, anchorTSeconds: anchorT,
          targetMeters: target, vLineMps: vLine, nowSeconds: now)!;
        final abs = now + r; // absolute instant on the same clock
        absInstant ??= abs;
        expect(abs, closeTo(absInstant, 1e-9),
            reason: 'the fire instant must not drift with now (no postpone bug)');
      }
      // And that fixed instant == anchorT + (target-anchorS)/vLine.
      expect(absInstant, closeTo(anchorT + (target - anchorS) / vLine, 1e-9));
    });

    test('already reached ⇒ non-positive (fire now)', () {
      final r = AlarmController.backstopPhysicsFireInSeconds(
        anchorSHiMeters: 0, anchorTSeconds: 0,
        targetMeters: 1000.0, vLineMps: 28.0, nowSeconds: 100.0); // reach at 35.7s
      expect(r, isNotNull);
      expect(r!, lessThan(0.0));
    });

    test('faster V_LINE ⇒ EARLIER (monotone; the GW-0076 lift helps here too)', () {
      double fireAt(double v) => AlarmController.backstopPhysicsFireInSeconds(
          anchorSHiMeters: 0, anchorTSeconds: 0,
          targetMeters: 3000.0, vLineMps: v, nowSeconds: 0)!;
      expect(fireAt(53.0), lessThan(fireAt(28.0)),
          reason: 'a higher never-late V_LINE fires the backstop earlier');
    });

    test('null on non-finite / non-positive inputs (falls back to ETA path)', () {
      expect(AlarmController.backstopPhysicsFireInSeconds(
          anchorSHiMeters: 0, anchorTSeconds: 0, targetMeters: 100,
          vLineMps: 0, nowSeconds: 0), isNull);
      expect(AlarmController.backstopPhysicsFireInSeconds(
          anchorSHiMeters: double.nan, anchorTSeconds: 0, targetMeters: 100,
          vLineMps: 28, nowSeconds: 0), isNull);
      expect(AlarmController.backstopPhysicsFireInSeconds(
          anchorSHiMeters: 0, anchorTSeconds: 0, targetMeters: double.infinity,
          vLineMps: 28, nowSeconds: 0), isNull);
    });
  });
}
