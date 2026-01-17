import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/core/ekf/ekf_orchestrator.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';

void main() {
  group('EkfOrchestrator', () {
    test('GPS fix updates pipeline and detector', () {
      final orch = EkfOrchestrator(
        route: RouteGeometry.fromPoints(
          const [
            LatLng(12.0, 77.0),
            LatLng(12.0, 77.001),
          ],
        ),
      );

      orch.onGpsFix(
        const GpsFix(
          lat: 12.0,
          lng: 77.0,
          accuracyMeters: 10,
          speedMps: 0.0,
          timestamp: Duration(seconds: 1),
        ),
        innovationSigma: 1.0,
      );

      expect(orch.publicState.sigmaS, greaterThan(0));
      expect(orch.gpsDegraded, isFalse);
    });
  });
}
