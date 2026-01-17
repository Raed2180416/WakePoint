import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/core/ekf/ekf_pipeline.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';

void main() {
  group('EkfPipeline core updates', () {
    test('ZUPT update drives velocity toward zero', () {
      final ekf = EkfPipeline(
        config: const EkfConfig(),
        route: RouteGeometry.fromPoints(
          const [
            LatLng(12.0, 77.0),
            LatLng(12.0, 77.001),
          ],
        ),
      );

      ekf.onGpsFix(
        const GpsFix(
          lat: 12.0,
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 0.0,
          timestamp: Duration(seconds: 0),
        ),
      );

      // Add IMU sample with forward accel to increase velocity.
      ekf.onImuSample(
        const ImuSample(
          ax: 1.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(milliseconds: 20),
        ),
      );

      final before = ekf.publicState.v;
      ekf.onZuptConfirmed();
      final after = ekf.publicState.v;

      expect(after.abs(), lessThanOrEqualTo(before.abs()));
    });

    test('Station snap moves progress toward station', () {
      final geom = RouteGeometry.fromPoints(
        const [
          LatLng(12.0, 77.0),
          LatLng(12.0, 77.002),
        ],
      );
      final ekf = EkfPipeline(config: const EkfConfig(), route: geom);

      ekf.onGpsFix(
        const GpsFix(
          lat: 12.0,
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 0.0,
          timestamp: Duration(seconds: 0),
        ),
      );

      final s0 = ekf.publicState.s;
      final sStation = (s0 + 50.0).clamp(0.0, geom.totalLengthMeters);

      ekf.onStationCandidates([StationCandidate(sStation)]);

      final s1 = ekf.publicState.s;
      expect(s1, greaterThanOrEqualTo(s0));
      expect(s1, closeTo(sStation, 10.0));
    });
  });
}
