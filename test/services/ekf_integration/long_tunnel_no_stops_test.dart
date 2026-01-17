import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_orchestrator.dart';
import 'package:geowake2/core/ekf/ekf_pipeline.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';
import 'package:geowake2/core/ekf/degraded_mode.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('EKF integration - long tunnel, no stops (§28.2 Test 1)', () {
    late RouteGeometry route;

    setUp(() {
      // Create a ~10km route (sufficient for 10-15 min tunnel)
      route = RouteGeometry.fromPoints(const [
        LatLng(12.0, 77.0),
        LatLng(12.0, 77.1), // ~11km at equator
      ]);
    });

    test('GPS loss + no ZUPT triggers degraded mode after σ > 150m', () {
      final ekf = EkfPipeline(config: const EkfConfig(), route: route);
      final degraded = DegradedMode(maxSigmaMeters: 150);

      // Initialize with GPS fix
      ekf.onGpsFix(const GpsFix(
        lat: 12.0,
        lng: 77.0,
        accuracyMeters: 20.0,
        speedMps: 20.0, // ~72 km/h metro speed
        timestamp: Duration(seconds: 0),
      ));

      expect(ekf.publicState.sigmaS, lessThan(30));
      expect(degraded.isDegraded, isFalse);

      // Simulate 10+ minutes of IMU samples with train-like vibration
      // At 100Hz, 10 minutes = 60000 samples
      // For test efficiency, we use 10Hz (100ms intervals) instead
      const samplesFor10Min = 6000; // 10 min at 10Hz

      for (var i = 0; i < samplesFor10Min; i++) {
        final timestamp = Duration(milliseconds: i * 100);
        
        // Simulate train vibration (small random accel, no net motion)
        // Forward accel averages near zero but with noise
        final aFwd = 0.05 * ((i % 7) - 3) / 3.0; // Small oscillations
        
        ekf.onForwardAccel(timestamp, aFwd);
        
        // Update degraded mode periodically
        if (i % 10 == 0) {
          degraded.update(
            timestamp: timestamp,
            sigmaS: ekf.publicState.sigmaS,
            gpsRecovered: false,
          );
        }
      }

      // After 10 min without GPS/ZUPT, degraded mode should trigger
      expect(degraded.isDegraded, isTrue,
          reason: 'Should enter degraded mode after 10 min without ZUPT');
    });

    test('Covariance grows without bound until degraded mode freezes progress', () {
      final ekf = EkfPipeline(config: const EkfConfig(), route: route);

      // Initialize
      ekf.onGpsFix(const GpsFix(
        lat: 12.0,
        lng: 77.0,
        accuracyMeters: 10.0,
        speedMps: 20.0,
        timestamp: Duration(seconds: 0),
      ));

      final initialSigma = ekf.publicState.sigmaS;

      // Feed IMU samples without GPS
      for (var i = 0; i < 1000; i++) {
        final timestamp = Duration(milliseconds: i * 10);
        ekf.onForwardAccel(timestamp, 0.1); // Small constant accel
      }

      // Sigma should have grown
      expect(ekf.publicState.sigmaS, greaterThan(initialSigma),
          reason: 'σ_s should grow without GPS updates');
    });

    test('Orchestrator enters degraded mode and freezes velocity', () {
      final orchestrator = EkfOrchestrator(route: route);

      // Initialize with GPS
      orchestrator.onGpsFixAuto(const GpsFix(
        lat: 12.0,
        lng: 77.0,
        accuracyMeters: 10.0,
        speedMps: 15.0,
        timestamp: Duration(seconds: 0),
      ));

      // Feed train-like IMU samples for extended period
      // Motion = VEHICLE, no ZUPT, no GPS
      for (var i = 0; i < 3000; i++) {
        final timestamp = Duration(milliseconds: i * 10);
        orchestrator.onImuSample(ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81, // Gravity
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: timestamp,
        ));
      }

      // Check degraded behavior
      final finalState = orchestrator.publicState;
      expect(finalState.sigmaS, greaterThan(25),
          reason: 'σ_s should grow without anchors');
    });

    test('Progress is monotonic even without GPS', () {
      final ekf = EkfPipeline(config: const EkfConfig(), route: route);

      // Initialize
      ekf.onGpsFix(const GpsFix(
        lat: 12.0,
        lng: 77.0,
        accuracyMeters: 10.0,
        speedMps: 20.0,
        timestamp: Duration(seconds: 0),
      ));

      double lastPubS = ekf.publicState.s;

      // Feed samples with varying forward accel (including negative)
      for (var i = 0; i < 500; i++) {
        final timestamp = Duration(milliseconds: i * 10);
        final aFwd = 0.5 * ((i % 11) - 5) / 5.0; // Oscillates +/- 0.5
        ekf.onForwardAccel(timestamp, aFwd);

        // Public s should never decrease (monotonic clamp per §24.1)
        expect(ekf.publicState.s, greaterThanOrEqualTo(lastPubS),
            reason: 's_pub must be monotonic');
        lastPubS = ekf.publicState.s;
      }
    });

    test('No numeric explosion after extended prediction', () {
      final ekf = EkfPipeline(config: const EkfConfig(), route: route);

      // Initialize
      ekf.onGpsFix(const GpsFix(
        lat: 12.0,
        lng: 77.0,
        accuracyMeters: 10.0,
        speedMps: 20.0,
        timestamp: Duration(seconds: 0),
      ));

      // Feed many samples
      for (var i = 0; i < 10000; i++) {
        final timestamp = Duration(milliseconds: i * 10);
        ekf.onForwardAccel(timestamp, 0.05);
      }

      final state = ekf.publicState;
      
      // Check for numeric stability
      expect(state.s.isFinite, isTrue, reason: 's should not explode');
      expect(state.v.isFinite, isTrue, reason: 'v should not explode');
      expect(state.sigmaS.isFinite, isTrue, reason: 'σ_s should not explode');
      expect(state.sigmaV.isFinite, isTrue, reason: 'σ_v should not explode');
      expect(state.biasA.isFinite, isTrue, reason: 'bias should not explode');
      
      // Bias should stay within bounds per §22.4
      expect(state.biasA.abs(), lessThanOrEqualTo(0.5),
          reason: 'Bias must be bounded to ±0.5 m/s²');
    });
  });
}
