import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/data_asset/data_asset_config.dart';
import 'package:geowake2/services/data_asset/differential_privacy.dart';
import 'package:geowake2/services/data_asset/k_anonymity_filter.dart';
import 'package:geowake2/services/data_asset/od_cell.dart';

OdCell _cell(int users, {int count = 10}) => OdCell(
      key: const OdCellKey(
        originStationId: 'A',
        destStationId: 'B',
        hourBin: 8,
        dayType: DayType.weekday,
      ),
      count: count,
      contributingUsers: users,
    );

void main() {
  group('KAnonymityFilter', () {
    test('drops cells below k, keeps at/above k (boundary inclusive)', () {
      final input = [
        _cell(kOdKAnonymityThreshold - 1),
        _cell(kOdKAnonymityThreshold), // exactly k -> kept
        _cell(kOdKAnonymityThreshold + 50),
      ];
      final out = KAnonymityFilter.suppress(input);
      expect(out.length, 2);
      expect(out.every((c) => c.contributingUsers >= kOdKAnonymityThreshold),
          isTrue);
    });

    test('single-device snapshot (users≈1) is fully suppressed', () {
      final out = KAnonymityFilter.suppress([_cell(1), _cell(1)]);
      expect(out, isEmpty);
    });
  });

  group('LaplaceMechanism', () {
    final mech = LaplaceMechanism();

    test('seeded RNG is deterministic', () {
      final a = mech.noisyCount(50,
          epsilon: kEpsilonPerCell,
          sensitivity: kPerUserMaxCountPerCellPerDay,
          rng: math.Random(42));
      final b = mech.noisyCount(50,
          epsilon: kEpsilonPerCell,
          sensitivity: kPerUserMaxCountPerCellPerDay,
          rng: math.Random(42));
      expect(a, b);
    });

    test('empirical mean ≈ true count within tolerance', () {
      final rng = math.Random(7);
      const trueCount = 500;
      const n = 20000;
      var sum = 0;
      for (var i = 0; i < n; i++) {
        sum += mech.noisyCount(trueCount,
            epsilon: kEpsilonPerCell, sensitivity: 1, rng: rng);
      }
      final mean = sum / n;
      // Laplace is unbiased pre-clamp; at trueCount=500 clamping is negligible.
      expect((mean - trueCount).abs() < 5, isTrue,
          reason: 'mean=$mean should be within 5 of $trueCount');
    });

    test('negative noisy results clamp to 0', () {
      // trueCount 0 with large scale sometimes goes negative -> must clamp.
      final rng = math.Random(1);
      for (var i = 0; i < 1000; i++) {
        final v = mech.noisyCount(0, epsilon: 0.1, sensitivity: 1, rng: rng);
        expect(v >= 0, isTrue);
      }
    });

    test('dpDisclosure pins model + epsilon + sensitivity bound', () {
      final d = LaplaceMechanism.dpDisclosure();
      expect(d['model'], DpModel.central.name);
      expect(d['epsilonPerCell'], kEpsilonPerCell);
      expect(d['sensitivity'], kPerUserMaxCountPerCellPerDay);
      expect(d['kAnonymityThreshold'], kOdKAnonymityThreshold);
      expect(d['noiseAppliedAt'], 'merge');
    });
  });

  group('config tripwire', () {
    test('stated constants equal the DP disclosure', () {
      final d = LaplaceMechanism.dpDisclosure();
      expect(kEpsilonPerCell, 0.44);
      expect(kPerUserDailyEpsilonCap, 1.76);
      expect(kOdKAnonymityThreshold, 100);
      expect(kMinContributingUsersCatchment, 100);
      expect(kPerUserMaxCellsPerDay, 4);
      expect(kPerUserMaxCountPerCellPerDay, 1);
      expect(d['perUserDailyEpsilon'], kPerUserDailyEpsilonCap);
      expect(d['perUserMaxCellsPerDay'], kPerUserMaxCellsPerDay);
      // The daily budget is the stated per-cell epsilon times the cell cap.
      expect(kEpsilonPerCell * kPerUserMaxCellsPerDay,
          closeTo(kPerUserDailyEpsilonCap, 1e-9));
    });
  });
}
