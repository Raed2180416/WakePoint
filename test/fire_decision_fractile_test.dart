// Tests for the "never fire late" fire-decision cluster (G10-G13, G27).
//
// These prove the NEW uncertainty-aware behavior that the pre-existing suite
// never exercises (it passes no EKF sigma, so it stays on median behavior).
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/config/fire_decision_config.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:math';

void main() {
  TransitLegStops metroLeg({
    required int numStops,
    required double startMeters,
    required double length,
  }) {
    return TransitLegStops(
      legStartMeters: startMeters,
      legEndMeters: startMeters + length,
      numStops: numStops,
      stopPositions: List.generate(numStops, (_) => const LatLng(0, 0)),
      stopMeters: List.generate(
        numStops,
        (i) => startMeters + ((i + 1) * (length / (numStops + 1))),
      ),
      lineName: 'Metro Line',
      isActualPositions: true,
      isMetro: true,
      stopNames: List.generate(numStops, (i) => 'Stop $i'),
    );
  }

  group('etaSigmaSeconds (G12 — ETA uncertainty)', () {
    test('first-order propagation matches the closed form', () {
      // sigmaEta = sqrt((sigmaS/v)^2 + (eta*sigmaV/v)^2)
      // = sqrt((50/10)^2 + (100*1/10)^2) = sqrt(25 + 100) = sqrt(125)
      final s = AlarmEvaluator.etaSigmaSeconds(
        etaSeconds: 100,
        speedMps: 10,
        sigmaSMeters: 50,
        sigmaVMps: 1,
      );
      expect(s, closeTo(sqrt(125), 1e-6));
    });

    test('GAP #21: keeps a POSITIVE cushion when speed is unusable '
        '(previously degraded to 0 => median firing / late-risk underground)', () {
      final s = AlarmEvaluator.etaSigmaSeconds(
          etaSeconds: 100, speedMps: 0.3, sigmaSMeters: 50, sigmaVMps: 1);
      // Velocity is floored to etaSigmaSpeedFloorMps so position/velocity
      // uncertainty still yields a real ETA cushion instead of collapsing to 0.
      expect(s, greaterThan(0.0));
      final vf = FireDecisionConfig.etaSigmaSpeedFloorMps;
      final expected =
          sqrt(pow(50 / vf, 2).toDouble() + pow(100 * 1 / vf, 2).toDouble());
      expect(s, closeTo(expected, 1e-6));
    });

    test('degrades to 0 when no EKF sigma is available (back-compat)', () {
      expect(
        AlarmEvaluator.etaSigmaSeconds(
            etaSeconds: 100, speedMps: 10, sigmaSMeters: null, sigmaVMps: null),
        0.0,
      );
    });

    test('monotonic: larger position sigma => larger ETA sigma', () {
      final lo = AlarmEvaluator.etaSigmaSeconds(
          etaSeconds: 100, speedMps: 10, sigmaSMeters: 20, sigmaVMps: 0.5);
      final hi = AlarmEvaluator.etaSigmaSeconds(
          etaSeconds: 100, speedMps: 10, sigmaSMeters: 200, sigmaVMps: 0.5);
      expect(hi, greaterThan(lo));
    });
  });

  group('G13 — position-uncertainty stop cushion fires EARLIER, never later', () {
    // Metro leg 1000-5000m, 10 intermediate stops at 1000+(i+1)*363.6:
    // 1363, 1727, 2091, 2455, 2818, 3182, 3545, 3909, 4273, 4636.
    // "3 stops prior": fire when remainingIntermediate+1 <= 3  (>=8 stops passed).
    final legs = [metroLeg(numStops: 10, startMeters: 1000, length: 4000)];

    AlarmTrigger? eval(double progress, {double? sigmaS}) =>
        AlarmEvaluator.evaluateCoinciding(
          mode: AlarmMode.stops,
          userValue: 3.0,
          progressMeters: progress,
          allEvents: const [],
          firedEventIndexes: <int>{},
          firedLegIds: <String>{},
          isMetroLeg: true,
          transitLegs: legs,
          currentLegIndex: 0,
          isFinalLeg: false,
          positionSigmaMeters: sigmaS,
        );

    test('at 3800m with no uncertainty: does NOT fire (remaining=4 > 3)', () {
      expect(eval(3800.0, sigmaS: 0.0), isNull);
    });

    test('at 3800m with sigmaS=100 (k=2 → +200m cushion): FIRES (remaining=3)', () {
      // effective progress 4000m crosses the 8th stop (3909m) → fires early.
      expect(eval(3800.0, sigmaS: 100.0), isNotNull);
    });

    test('the cushion can only advance firing, never delay it', () {
      // If the median (sigma=0) already fires, a cushion must also fire.
      final fireProgress = 4300.0; // well past the 8th stop
      expect(eval(fireProgress, sigmaS: 0.0), isNotNull);
      expect(eval(fireProgress, sigmaS: 300.0), isNotNull);
    });
  });

  group('FireDecisionConfig sanity', () {
    test('fractile k is a positive safety margin', () {
      expect(FireDecisionConfig.fractileK, greaterThan(0));
    });
    test('approximate-location gate is well above normal GPS accuracy', () {
      expect(FireDecisionConfig.approximateLocationAccuracyMeters,
          greaterThan(FireDecisionConfig.defaultAccuracyGateMeters));
    });
  });
}
