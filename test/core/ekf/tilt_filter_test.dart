import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/tilt_filter.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';

void main() {
  group('TiltFilter', () {
    test('initializes gravity from first sample', () {
      final filter = TiltFilter();
      final output = filter.update(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ),
      );

      expect(output, isNotNull);
      expect(output!.gravityDevice[2], closeTo(1.0, 1e-3));
      expect(output.gravityDevice[0].abs(), lessThan(1e-3));
      expect(output.gravityDevice[1].abs(), lessThan(1e-3));
    });

    test('updates gravity toward accelerometer when variance is low', () {
      final filter = TiltFilter();
      filter.update(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ),
      );

      TiltFilterOutput? output;
      for (int i = 1; i <= 50; i++) {
        output = filter.update(
          ImuSample(
            ax: 9.81,
            ay: 0.0,
            az: 0.0,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: Duration(milliseconds: 20 * i),
          ),
        );
      }

      expect(output, isNotNull);
      expect(output!.gravityDevice[0], greaterThan(0.2));
    });

    test('skips updates on invalid dt', () {
      final filter = TiltFilter();
      filter.update(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ),
      );

      final output = filter.update(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(seconds: 1),
        ),
      );

      expect(output, isNotNull);
    });
  });
}
