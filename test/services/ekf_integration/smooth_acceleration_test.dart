import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_orchestrator.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('EKF - Smooth Acceleration Vulnerability', () {
    late RouteGeometry route;

    setUp(() {
      // 5km straight route
      route = RouteGeometry.fromPoints(const [
        LatLng(12.0, 77.0),
        LatLng(12.0, 77.05),
      ]);
    });

    test('Smooth acceleration (low variance) is masked by tilt filter', () {
      final orchestrator = EkfOrchestrator(route: route);
      // Enable Metro mode to allow extended dead reckoning (DR) without GPS
      orchestrator.setStationContext(stationMeters: [], isMetroLeg: true);

      // 1. Initialize with GPS (Stationary)
      orchestrator.onGpsFixAuto(
        const GpsFix(
          lat: 12.0,
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 0.0,
          timestamp: Duration.zero,
        ),
      );

      // 2. Simulate smooth acceleration: 0.5 m/s² for 10 seconds
      // Ideally, v should reach 5.0 m/s
      // With vulnerable tilt filter, it stays near 0 because a_fwd is interpreted as tilt

      const accelMps2 = 0.5;
      const durationSeconds = 10;
      const freqHz = 50;

      // Warmup: 5s stationary to establish gravity vector and trigger ZUPT
      // (ZUPT requires ~3s of stationary data)
      for (var i = 0; i < 5 * freqHz; i++) {
        final timestamp = Duration(milliseconds: (i * 1000 / freqHz).round());
        orchestrator.onImuSample(
          ImuSample(
            ax: 0.0,
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: timestamp,
          ),
        );
      }

      // Acceleration Phase: 10s of 0.5 m/s²
      for (var i = 0; i < durationSeconds * freqHz; i++) {
        final timestamp = Duration(
          milliseconds: ((i + 5 * freqHz) * 1000 / freqHz).round(),
        );

        // Inject smooth accel (low variance)
        // ax = 0.5, ay=0, az=9.81
        // No vibration noise added -> variance is ZERO
        orchestrator.onImuSample(
          ImuSample(
            ax: accelMps2,
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: timestamp,
          ),
        );
      }

      final v = orchestrator.publicState.v;
      print('Velocity after 10s of 0.5m/s²: $v m/s');

      // PRE-FIX EXPECTATION: Velocity is near 0 because 0.5 accel is filtered out as tilt
      // POST-FIX EXPECTATION: Velocity should be > 4.0 m/s (ideal is 5.0)
      // The fix (Motion Gating) prevents the tilt filter from masking the acceleration.
      expect(
        v,
        greaterThan(4.0),
        reason: 'Motion-gated filter should capture accel',
      );
    });
  });
}
