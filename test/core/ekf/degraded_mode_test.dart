import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/degraded_mode.dart';

void main() {
  group('DegradedMode', () {
    test('enters degraded when sigma exceeds threshold', () {
      final mode = DegradedMode(maxSigmaMeters: 150);
      mode.update(
        timestamp: const Duration(seconds: 1),
        sigmaS: 200,
        gpsRecovered: false,
      );
      expect(mode.isDegraded, isTrue);
    });

    test('enters degraded when ZUPT overdue', () {
      final mode = DegradedMode(maxZuptGap: const Duration(minutes: 10));
      mode.update(
        timestamp: const Duration(minutes: 11),
        sigmaS: 10,
        gpsRecovered: false,
      );
      expect(mode.isDegraded, isTrue);
    });

    test('recovers on GPS recovery', () {
      final mode = DegradedMode(maxSigmaMeters: 150);
      mode.update(
        timestamp: const Duration(seconds: 1),
        sigmaS: 200,
        gpsRecovered: false,
      );
      mode.update(
        timestamp: const Duration(seconds: 3),
        sigmaS: 50,
        gpsRecovered: true,
      );
      expect(mode.isDegraded, isFalse);
    });
  });
}
