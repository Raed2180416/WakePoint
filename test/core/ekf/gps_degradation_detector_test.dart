import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/gps_degradation_detector.dart';

void main() {
  group('GpsDegradationDetector', () {
    test('enters degraded after consecutive bad fixes', () {
      final detector = GpsDegradationDetector();

      detector.onGpsFix(
        timestamp: const Duration(seconds: 1),
        hasFix: true,
        accuracyMeters: 200,
        innovationSigma: 5,
      );
      detector.onGpsFix(
        timestamp: const Duration(seconds: 2),
        hasFix: true,
        accuracyMeters: 200,
        innovationSigma: 5,
      );
      detector.onGpsFix(
        timestamp: const Duration(seconds: 3),
        hasFix: true,
        accuracyMeters: 200,
        innovationSigma: 5,
      );

      expect(detector.isDegraded, isTrue);
    });

    test('recovers after hold + good fixes', () {
      final detector = GpsDegradationDetector();

      detector.onGpsFix(
        timestamp: const Duration(seconds: 1),
        hasFix: true,
        accuracyMeters: 200,
        innovationSigma: 5,
      );
      detector.onGpsFix(
        timestamp: const Duration(seconds: 2),
        hasFix: true,
        accuracyMeters: 200,
        innovationSigma: 5,
      );
      detector.onGpsFix(
        timestamp: const Duration(seconds: 3),
        hasFix: true,
        accuracyMeters: 200,
        innovationSigma: 5,
      );

      detector.onGpsFix(
        timestamp: const Duration(seconds: 20),
        hasFix: true,
        accuracyMeters: 10,
        innovationSigma: 1,
      );
      detector.onGpsFix(
        timestamp: const Duration(seconds: 21),
        hasFix: true,
        accuracyMeters: 10,
        innovationSigma: 1,
      );
      detector.onGpsFix(
        timestamp: const Duration(seconds: 22),
        hasFix: true,
        accuracyMeters: 10,
        innovationSigma: 1,
      );

      expect(detector.isDegraded, isFalse);
    });
  });
}
