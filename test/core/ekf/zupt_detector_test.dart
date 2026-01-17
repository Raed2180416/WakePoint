import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/zupt_detector.dart';

void main() {
  group('ZuptDetector', () {
    test('confirms only after dwell duration', () {
      final detector = ZuptDetector();

      bool confirmed = false;
      for (var i = 0; i < 6; i++) {
        confirmed = detector.update(
          timestamp: Duration(seconds: i),
          motion: MotionState.stationary,
          velocityMps: 0.05,
          accelVariance: 1e-4,
          gyroVariance: 1e-5,
        );
      }

      expect(confirmed, isTrue);
    });

    test('does not confirm when motion is human', () {
      final detector = ZuptDetector();
      final confirmed = detector.update(
        timestamp: const Duration(seconds: 10),
        motion: MotionState.human,
        velocityMps: 0.05,
        accelVariance: 1e-4,
        gyroVariance: 1e-5,
      );

      expect(confirmed, isFalse);
    });
  });
}
