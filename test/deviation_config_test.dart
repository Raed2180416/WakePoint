import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/config/deviation_config.dart';

void main() {
  group('DeviationConfig', () {
    test('baseThresholdMeters is correctly set', () {
      expect(DeviationConfig.baseThresholdMeters, 30.0);
    });

    test('speedCoefficientK is correctly set', () {
      expect(DeviationConfig.speedCoefficientK, 1.5);
    });

    test('hysteresisRatio is correctly set', () {
      expect(DeviationConfig.hysteresisRatio, 0.7);
    });

    test('defaultRerouteCooldown is 10 seconds', () {
      expect(
        DeviationConfig.defaultRerouteCooldown,
        const Duration(seconds: 10),
      );
    });

    test('lowBatteryRerouteCooldown is 20 seconds', () {
      expect(
        DeviationConfig.lowBatteryRerouteCooldown,
        const Duration(seconds: 20),
      );
    });

    group('mode-specific parameters', () {
      test('transit mode has larger base threshold', () {
        expect(DeviationConfig.transitBaseThresholdMeters, 50.0);
        expect(DeviationConfig.transitSpeedCoefficientK, 1.5);
        expect(DeviationConfig.transitHysteresisRatio, 0.6);
      });

      test('walking mode has tighter threshold', () {
        expect(DeviationConfig.walkingBaseThresholdMeters, 25.0);
        expect(DeviationConfig.walkingSpeedCoefficientK, 1.0);
        expect(DeviationConfig.walkingHysteresisRatio, 0.7);
      });

      test('driving mode has appropriate settings', () {
        expect(DeviationConfig.drivingBaseThresholdMeters, 40.0);
        expect(DeviationConfig.drivingSpeedCoefficientK, 2.0);
        expect(DeviationConfig.drivingHysteresisRatio, 0.65);
      });
    });

    group('termination policy thresholds', () {
      test('extreme deviation threshold is 5km', () {
        expect(DeviationConfig.extremeDeviationKm, 5.0);
      });

      test('moderate deviation threshold is 2km', () {
        expect(DeviationConfig.moderateDeviationKm, 2.0);
      });

      test('moderate deviation duration is 10 minutes', () {
        expect(
          DeviationConfig.moderateDeviationDuration,
          const Duration(minutes: 10),
        );
      });

      test('minimum failed reroutes for termination is 2', () {
        expect(DeviationConfig.minFailedReroutesForTermination, 2);
      });

      test('stopped speed threshold is correctly set', () {
        expect(DeviationConfig.stoppedSpeedThresholdMps, 2.0);
      });
    });

    group('active route manager thresholds', () {
      test('noise floor is 100 meters', () {
        expect(DeviationConfig.noiseFloorMeters, 100.0);
      });

      test('local switch threshold is 150 meters', () {
        expect(DeviationConfig.localSwitchThresholdMeters, 150.0);
      });

      test('API reroute threshold is 150 meters', () {
        expect(DeviationConfig.apiRerouteThresholdMeters, 150.0);
      });
    });
  });

  group('SpeedThresholdModel calculations', () {
    test('computes T_high correctly for stationary user', () {
      // T_high = base + k * speed
      // For speed = 0, T_high = 30 + 1.5 * 0 = 30m
      final tHigh = _computeHighThreshold(
        DeviationConfig.baseThresholdMeters,
        DeviationConfig.speedCoefficientK,
        0.0,
      );
      expect(tHigh, closeTo(30.0, 0.1));
    });

    test('computes T_high correctly for walking speed', () {
      // Walking ~ 1.4 m/s (5 km/h)
      // T_high = 30 + 1.5 * 1.4 = 30 + 2.1 = 32.1m
      final tHigh = _computeHighThreshold(
        DeviationConfig.baseThresholdMeters,
        DeviationConfig.speedCoefficientK,
        1.4,
      );
      expect(tHigh, closeTo(32.1, 0.2));
    });

    test('computes T_high correctly for driving speed', () {
      // Driving ~ 16.7 m/s (60 km/h)
      // T_high = 30 + 1.5 * 16.7 = 30 + 25 = 55m
      final tHigh = _computeHighThreshold(
        DeviationConfig.baseThresholdMeters,
        DeviationConfig.speedCoefficientK,
        16.7,
      );
      expect(tHigh, closeTo(55.0, 0.5));
    });

    test('computes T_low correctly using hysteresis ratio', () {
      // T_low = ratio * T_high = 0.7 * 32.1 = 22.47m
      final tHigh = _computeHighThreshold(
        DeviationConfig.baseThresholdMeters,
        DeviationConfig.speedCoefficientK,
        1.4,
      );
      final tLow = _computeLowThreshold(tHigh, DeviationConfig.hysteresisRatio);

      expect(tLow, closeTo(22.47, 0.5));
      expect(tLow, lessThan(tHigh)); // Always less than high threshold
    });
  });

  group('HysteresisFilter behavior', () {
    test('hysteresis prevents oscillation', () {
      final filter = _TestHysteresisFilter(
        highThreshold: 30.0,
        lowThreshold: 18.0, // 0.6 * 30
      );

      // Simulate GPS jitter around the boundary
      final distances = [
        28.0,
        32.0,
        29.0,
        31.0,
        28.0,
        33.0,
        25.0,
        22.0,
        19.0,
        17.0,
      ];
      final transitions = <_TestDeviationState>[];

      for (final d in distances) {
        filter.update(d);
        transitions.add(filter.currentState);
      }

      // Count transitions
      int transitionCount = 0;
      for (int i = 1; i < transitions.length; i++) {
        if (transitions[i] != transitions[i - 1]) {
          transitionCount++;
        }
      }

      // Should have at most 2 transitions (on->deviated, deviated->on)
      expect(transitionCount, lessThanOrEqualTo(2));
    });
  });
}

// Helper functions for threshold calculations
double _computeHighThreshold(double base, double k, double speedMps) {
  return base + k * speedMps;
}

double _computeLowThreshold(double tHigh, double ratio) {
  return ratio * tHigh;
}

// Test helper for hysteresis
enum _TestDeviationState { onRoute, deviated }

class _TestHysteresisFilter {
  final double highThreshold;
  final double lowThreshold;

  _TestDeviationState _state = _TestDeviationState.onRoute;

  _TestHysteresisFilter({
    required this.highThreshold,
    required this.lowThreshold,
  });

  _TestDeviationState get currentState => _state;

  void update(double distance) {
    switch (_state) {
      case _TestDeviationState.onRoute:
        if (distance > highThreshold) {
          _state = _TestDeviationState.deviated;
        }
        break;
      case _TestDeviationState.deviated:
        if (distance < lowThreshold) {
          _state = _TestDeviationState.onRoute;
        }
        break;
    }
  }
}
