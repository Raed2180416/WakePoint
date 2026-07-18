// Proof for GAP #21: the ETA sigma no longer collapses to 0 when speed is
// unobservable (the normal underground state), so the critical-fractile fire
// test keeps a positive cushion instead of degrading to firing at the median.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/config/fire_decision_config.dart';

void main() {
  group('GAP #21 ETA sigma floor', () {
    test('speed <= 0.5 m/s (underground) yields a POSITIVE cushion from sigmaS',
        () {
      final sigma = AlarmEvaluator.etaSigmaSeconds(
        etaSeconds: 300.0,
        speedMps: 0.0, // stale underground speed
        sigmaSMeters: 120.0, // EKF position uncertainty
        sigmaVMps: 0.0,
      );
      // With the velocity floor, cushion = sigmaS / vFloor > 0 (was 0 before).
      expect(sigma, greaterThan(0.0));
      expect(sigma,
          closeTo(120.0 / FireDecisionConfig.etaSigmaSpeedFloorMps, 1e-6));
    });

    test('observable speed still uses the real speed (no behavior change)', () {
      final sigma = AlarmEvaluator.etaSigmaSeconds(
        etaSeconds: 300.0,
        speedMps: 10.0,
        sigmaSMeters: 120.0,
        sigmaVMps: 0.0,
      );
      expect(sigma, closeTo(120.0 / 10.0, 1e-6));
    });

    test('non-finite ETA still returns 0', () {
      expect(
        AlarmEvaluator.etaSigmaSeconds(
          etaSeconds: double.nan,
          speedMps: 0.0,
          sigmaSMeters: 120.0,
          sigmaVMps: 0.0,
        ),
        0.0,
      );
    });

    test('no position uncertainty => 0 cushion even with the floor', () {
      // A floor on velocity only matters when there IS position uncertainty to
      // convert into time; with sigmaS=0 and sigmaV=0 the cushion is legitimately 0.
      expect(
        AlarmEvaluator.etaSigmaSeconds(
          etaSeconds: 300.0,
          speedMps: 0.0,
          sigmaSMeters: 0.0,
          sigmaVMps: 0.0,
        ),
        0.0,
      );
    });
  });
}
