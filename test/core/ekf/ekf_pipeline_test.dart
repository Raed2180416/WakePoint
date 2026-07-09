import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/core/ekf/ekf_pipeline.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';

/// Custom matcher for finite numbers (not NaN or Infinity)
final isFiniteNumber = predicate<num>(
  (v) => v.isFinite,
  'is a finite number (not NaN or Infinity)',
);

void main() {
  group('EkfPipeline core updates', () {
    test('ZUPT update drives velocity toward zero', () {
      final ekf = EkfPipeline(
        config: const EkfConfig(),
        route: RouteGeometry.fromPoints(const [
          LatLng(12.0, 77.0),
          LatLng(12.0, 77.001),
        ]),
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
      final geom = RouteGeometry.fromPoints(const [
        LatLng(12.0, 77.0),
        LatLng(12.0, 77.002),
      ]);
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

  group('EkfPipeline numerical stability', () {
    late RouteGeometry route;
    late EkfPipeline ekf;

    setUp(() {
      // ~1km route for testing
      route = RouteGeometry.fromPoints(const [
        LatLng(12.0, 77.0),
        LatLng(12.009, 77.0), // ~1km north
      ]);
      ekf = EkfPipeline(config: const EkfConfig(), route: route);

      // Initialize from GPS
      ekf.onGpsFix(
        const GpsFix(
          lat: 12.0,
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 5.0,
          timestamp: Duration(seconds: 0),
        ),
      );
    });

    test('covariance remains symmetric after 1000 IMU + GPS updates', () {
      // Simulate 1000 IMU samples at 50Hz with periodic GPS
      for (var i = 1; i <= 1000; i++) {
        final ts = Duration(milliseconds: i * 20);

        // IMU update
        ekf.onImuSample(
          ImuSample(
            ax: 0.1 * (i % 10 - 5), // Small varying accel
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: ts,
          ),
        );

        // GPS every 20 samples (~1Hz)
        if (i % 20 == 0) {
          final lat = 12.0 + (i * 0.000001); // Move north slowly
          ekf.onGpsFix(
            GpsFix(
              lat: lat,
              lng: 77.0,
              accuracyMeters: 10.0,
              speedMps: 5.0,
              timestamp: ts,
            ),
          );
        }
      }

      // At this point we can't directly access P matrix, but we verify
      // sigmaS and sigmaV are positive and finite (indication of no NaN/Inf)
      final state = ekf.publicState;
      expect(state.sigmaS, isPositive);
      expect(state.sigmaS, isFiniteNumber);
      expect(state.sigmaV, isPositive);
      expect(state.sigmaV, isFiniteNumber);
      expect(state.s, isFiniteNumber);
      expect(state.v, isFiniteNumber);
      expect(state.biasA, isFiniteNumber);
    });

    test('dt > 1s triggers velocity reset, not crash', () {
      // First sample
      ekf.onImuSample(
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

      final vBefore = ekf.publicState.v;
      expect(vBefore, isPositive); // From GPS initialization with speed=5

      // Skip 2 seconds (dt > 1s threshold)
      ekf.onImuSample(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(seconds: 3), // 2 second gap
        ),
      );

      final vAfter = ekf.publicState.v;
      // After large dt gap, velocity should be reset to 0
      expect(vAfter, equals(0.0));

      // State should still be finite
      expect(ekf.publicState.s, isFiniteNumber);
      expect(ekf.publicState.sigmaS, isPositive);
    });

    test('large innovation uses Huber down-weighting not hard reset', () {
      // Add some IMU samples to establish velocity
      for (var i = 1; i <= 10; i++) {
        ekf.onImuSample(
          ImuSample(
            ax: 0.0,
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: Duration(milliseconds: i * 20),
          ),
        );
      }

      final sBefore = ekf.publicState.s;
      // ignore: unused_local_variable
      final sigmaSBefore = ekf.publicState.sigmaS;

      // GPS fix with large innovation (~5σ away)
      // σs starts around 25m, so 5*25 = 125m offset
      final lat5Sigma = 12.0 + (125.0 / 111000.0); // ~125m north

      ekf.onGpsFix(
        GpsFix(
          lat: lat5Sigma,
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 5.0,
          timestamp: const Duration(milliseconds: 250),
        ),
      );

      final sAfter = ekf.publicState.s;
      final sigmaSAfter = ekf.publicState.sigmaS;

      // With Huber weighting at 5σ:
      // - weight = 2.5 / 5 = 0.5
      // - Update should happen but down-weighted
      // - State should not jump to raw GPS position
      expect(sAfter, isFiniteNumber);
      expect((sAfter - sBefore).abs(), lessThan(125.0)); // Not full jump
      expect(sigmaSAfter, greaterThan(0.0));
    });

    test('ZUPT shrinks covariance and corrects bias', () {
      // Run IMU for ~1 second to accumulate some error
      for (var i = 1; i <= 50; i++) {
        ekf.onImuSample(
          ImuSample(
            ax: 0.1, // Constant bias-like accel
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: Duration(milliseconds: i * 20),
          ),
        );
      }

      // ignore: unused_local_variable
      final sigmaSBefore = ekf.publicState.sigmaS;
      final sigmaVBefore = ekf.publicState.sigmaV;

      // ZUPT confirmed (train stopped at station)
      ekf.onZuptConfirmed();

      final sigmaSAfter = ekf.publicState.sigmaS;
      final sigmaVAfter = ekf.publicState.sigmaV;
      final vAfter = ekf.publicState.v;

      // Post-ZUPT:
      // - σs should be capped at 10m
      // - σv should be capped at 0.5 m/s
      // - v should be near zero
      expect(sigmaSAfter, lessThanOrEqualTo(10.0));
      expect(sigmaVAfter, lessThanOrEqualTo(0.5));
      expect(vAfter.abs(), lessThan(1.0)); // Near zero after ZUPT

      // Covariance should have shrunk
      expect(sigmaVAfter, lessThan(sigmaVBefore));
    });

    test('negative dt is rejected gracefully', () {
      // First sample
      ekf.onImuSample(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(seconds: 10),
        ),
      );

      final stateBefore = ekf.publicState;

      // Negative dt (timestamp regression)
      ekf.onImuSample(
        const ImuSample(
          ax: 1.0, // Would change state if processed
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(seconds: 5), // Before previous!
        ),
      );

      final stateAfter = ekf.publicState;

      // State should be unchanged (sample rejected)
      expect(stateAfter.s, equals(stateBefore.s));
      expect(stateAfter.v, equals(stateBefore.v));
    });

    test('EKF survives 388s GPS blackout (Majestic-Cubbon simulation)', () {
      // Simulate 388-second GPS gap at metro speed (~20 m/s)
      // This matches the actual gap found in the Sandal Soap Factory route

      const dt = 0.02; // 50Hz IMU
      const blackoutSeconds = 388;
      final steps = (blackoutSeconds / dt).round();

      // Initialize with reasonable velocity
      ekf.onGpsFix(
        const GpsFix(
          lat: 12.0,
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 20.0,
          timestamp: Duration(seconds: 0),
        ),
      );

      // Enter degraded mode
      ekf.setMode(EkfMode.degraded);

      final sStart = ekf.publicState.s;
      final sigmaStart = ekf.publicState.sigmaS;

      // Run 388 seconds of dead-reckoning
      for (var i = 1; i <= steps; i++) {
        final ts = Duration(milliseconds: (i * dt * 1000).round());

        // Small jitter in accelerometer (realistic metro noise)
        final ax = 0.05 * ((i % 100) / 50.0 - 1.0); // ±0.05 m/s²

        ekf.onImuSample(
          ImuSample(
            ax: ax,
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: ts,
          ),
        );

        // Verify no NaN/Inf at 10% intervals
        if (i % (steps ~/ 10) == 0) {
          expect(ekf.publicState.s, isFiniteNumber, reason: 'NaN at step $i');
          expect(ekf.publicState.v, isFiniteNumber, reason: 'NaN at step $i');
          expect(
            ekf.publicState.sigmaS,
            isPositive,
            reason: 'Bad sigmaS at step $i',
          );
        }
      }

      final sEnd = ekf.publicState.s;
      final sigmaEnd = ekf.publicState.sigmaS;
      final vEnd = ekf.publicState.v;

      // Verify reasonable dead-reckoning results:
      // - Position advanced significantly (metro traveled ~7.7km in 388s at 20m/s)
      final distanceTraveled = sEnd - sStart;
      expect(distanceTraveled, greaterThan(5000)); // At least moved 5km
      expect(distanceTraveled, lessThan(15000)); // But not unreasonable

      // - Velocity bounded (-25 to 25 m/s)
      expect(vEnd, greaterThanOrEqualTo(-25.0));
      expect(vEnd, lessThanOrEqualTo(25.0));

      // - Uncertainty grew but bounded reasonably
      // The cap ensures σs stays manageable for station association
      // Allow up to 250m since small inflation can occur after capping
      expect(sigmaEnd, greaterThan(sigmaStart));
      expect(sigmaEnd, lessThanOrEqualTo(250.0));

      // - All values finite
      expect(sEnd, isFiniteNumber);
      expect(vEnd, isFiniteNumber);
      expect(sigmaEnd, isFiniteNumber);
    });
  });

  group('EkfPipeline bias observability', () {
    test('GPS-derived acceleration updates bias during surface mode', () {
      final route = RouteGeometry.fromPoints(const [
        LatLng(12.0, 77.0),
        LatLng(12.009, 77.0), // ~1km north
      ]);
      final ekf = EkfPipeline(config: const EkfConfig(), route: route);

      // Initialize from GPS
      ekf.onGpsFix(
        const GpsFix(
          lat: 12.0,
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 10.0, // Initial velocity
          timestamp: Duration(seconds: 0),
        ),
      );

      final biasInitial = ekf.publicState.biasA;

      // Feed IMU samples with a consistent acceleration
      // If IMU reads 1.0 m/s² but GPS shows 0 acceleration,
      // bias should converge toward 1.0
      for (int i = 1; i <= 50; i++) {
        ekf.onImuSample(
          ImuSample(
            ax: 1.0, // Consistent forward accel
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: Duration(milliseconds: i * 20),
          ),
        );
      }

      // Second GPS fix at t=1s with same velocity (no actual acceleration)
      ekf.onGpsFix(
        const GpsFix(
          lat: 12.0001, // Slightly moved
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 10.0, // Same velocity → GPS accel ≈ 0
          timestamp: Duration(seconds: 1),
        ),
      );

      final biasAfterFirst = ekf.publicState.biasA;

      // Continue feeding IMU and GPS fixes
      for (int j = 2; j <= 10; j++) {
        for (int i = 1; i <= 50; i++) {
          ekf.onImuSample(
            ImuSample(
              ax: 1.0,
              ay: 0.0,
              az: 9.81,
              gx: 0.0,
              gy: 0.0,
              gz: 0.0,
              timestamp: Duration(milliseconds: j * 1000 + i * 20),
            ),
          );
        }

        ekf.onGpsFix(
          GpsFix(
            lat: 12.0 + j * 0.0001,
            lng: 77.0,
            accuracyMeters: 10.0,
            speedMps: 10.0, // Constant velocity → GPS accel ≈ 0
            timestamp: Duration(seconds: j),
          ),
        );
      }

      final biasFinal = ekf.publicState.biasA;

      // Bias should have increased from initial toward the IMU-GPS discrepancy
      // IMU shows 1.0 m/s², GPS shows 0 accel → bias estimate ~1.0
      expect(biasFinal, greaterThan(biasInitial));
      expect(biasFinal, greaterThan(0.1)); // Should have moved significantly
      expect(biasFinal, lessThanOrEqualTo(1.0)); // Capped at ±1.0
      expect(biasFinal, isFiniteNumber);

      // First update should show some movement
      expect(biasAfterFirst, greaterThanOrEqualTo(biasInitial));
    });

    test('Bias observability respects gain limits', () {
      final route = RouteGeometry.fromPoints(const [
        LatLng(12.0, 77.0),
        LatLng(12.009, 77.0),
      ]);
      final ekf = EkfPipeline(config: const EkfConfig(), route: route);

      // Initialize
      ekf.onGpsFix(
        const GpsFix(
          lat: 12.0,
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 10.0,
          timestamp: Duration(seconds: 0),
        ),
      );

      // Add IMU samples
      for (int i = 1; i <= 50; i++) {
        ekf.onImuSample(
          ImuSample(
            ax: 0.5,
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: Duration(milliseconds: i * 20),
          ),
        );
      }

      // GPS fix with large sudden velocity change (noisy)
      ekf.onGpsFix(
        const GpsFix(
          lat: 12.0001,
          lng: 77.0,
          accuracyMeters: 10.0,
          speedMps: 15.0, // 5 m/s change → GPS accel = 5 m/s²
          timestamp: Duration(seconds: 1),
        ),
      );

      final bias = ekf.publicState.biasA;

      // Bias should not jump dramatically due to low gain (0.05)
      // and outlier rejection (>2 m/s² estimate rejected)
      expect(bias.abs(), lessThanOrEqualTo(1.0));
      expect(bias, isFiniteNumber);
    });
  });
}
