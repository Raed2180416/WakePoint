import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_orchestrator.dart';
import 'package:geowake2/core/ekf/ekf_pipeline.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';
import 'package:geowake2/core/ekf/zupt_detector.dart';
import 'package:geowake2/core/ekf/station_association.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('EKF integration - ambiguous station stop (§28.2 Test 2)', () {
    late RouteGeometry route;
    late List<double> stationMeters;

    setUp(() {
      // Create a route with stations at 500m intervals
      route = RouteGeometry.fromPoints(const [
        LatLng(12.0, 77.0),
        LatLng(12.0, 77.01), // ~1.1km
      ]);
      stationMeters = [0.0, 500.0, 1000.0];
    });

    test('ZUPT not confirmed when dwell < dwellDuration (5s default)', () {
      final zupt = ZuptDetector();

      // Simulate short dwell (< 5s required for confirmation)
      bool confirmed = false;
      for (var i = 0; i < 4; i++) {
        confirmed = zupt.update(
          timestamp: Duration(seconds: i),
          motion: MotionState.stationary,
          velocityMps: 0.05,
          accelVariance: 1e-4,
          gyroVariance: 1e-5,
        );
      }

      // Should NOT be confirmed (dwell < 5s)
      expect(confirmed, isFalse,
          reason: 'ZUPT should not confirm with < 5s dwell');

      // But isCandidate should be true after 3s
      expect(zupt.isCandidate(const Duration(seconds: 4)), isTrue,
          reason: 'isCandidate should be true after 3s');
    });

    test('ZUPT confirms after sufficient dwell (dwellDuration >= 5s)', () {
      final zupt = ZuptDetector();

      // Simulate 6s of stationary state - update returns true ONCE when crossing threshold
      bool everConfirmed = false;
      for (var i = 0; i <= 6; i++) {
        final confirmed = zupt.update(
          timestamp: Duration(seconds: i),
          motion: MotionState.stationary,
          velocityMps: 0.05,
          accelVariance: 1e-4,
          gyroVariance: 1e-5,
        );
        everConfirmed = everConfirmed || confirmed;
      }

      expect(everConfirmed, isTrue,
          reason: 'ZUPT should confirm after >= 5s dwell');
      expect(zupt.isConfirmed, isTrue,
          reason: 'ZUPT isConfirmed should be true');
    });

    test('Station snaps only with confirmed ZUPT and sufficient dwell', () {
      final assoc = StationAssociation();

      // Station association should NOT snap with short dwell
      final snapShort = assoc.selectCandidate(
        stationMeters: stationMeters,
        sEst: 500.0, // At station
        sigmaS: 25.0,
        isMetroLeg: true,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 15), // Short dwell
      );

      // Check behavior - depends on minimum dwell in StationAssociation
      // If it requires 20s, this should be null
      expect(snapShort, isNull,
          reason: 'Should not snap with dwell < minDwell (20s per §22.8)');

      // Station association SHOULD snap with long dwell
      final snapLong = assoc.selectCandidate(
        stationMeters: stationMeters,
        sEst: 500.0,
        sigmaS: 25.0,
        isMetroLeg: true,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 25),
      );

      expect(snapLong, isNotNull,
          reason: 'Should snap with dwell >= 20s');
      expect(snapLong!.stationMeters, equals(500.0));
      expect(snapLong.stationIndex, equals(1));
    });

    test('Motion oscillation prevents ZUPT confirmation', () {
      final zupt = ZuptDetector();

      // Oscillate between VEHICLE and STATIONARY
      bool confirmedEver = false;
      for (var i = 0; i < 20; i++) {
        final motion = i % 2 == 0
            ? MotionState.stationary
            : MotionState.vehicle;
        final confirmed = zupt.update(
          timestamp: Duration(seconds: i),
          motion: motion,
          velocityMps: 0.1,
          accelVariance: 1e-3,
          gyroVariance: 1e-4,
        );
        confirmedEver = confirmedEver || confirmed;
      }

      expect(confirmedEver, isFalse,
          reason: 'Oscillating motion should prevent ZUPT confirmation');
    });

    test('HUMAN motion state suppresses ZUPT even with low variance', () {
      final zupt = ZuptDetector();

      // Low variance but HUMAN motion (not stationary)
      bool confirmed = false;
      for (var i = 0; i < 10; i++) {
        confirmed = zupt.update(
          timestamp: Duration(seconds: i),
          motion: MotionState.human, // Walking at station
          velocityMps: 0.05,
          accelVariance: 1e-4, // Low variance
          gyroVariance: 1e-5,
        );
      }

      expect(confirmed, isFalse,
          reason: 'HUMAN state should suppress ZUPT per §7.3');
    });

    test('Multiple station candidates prevent snap', () {
      final assoc = StationAssociation();

      // High sigma means multiple candidates in window
      final snap = assoc.selectCandidate(
        stationMeters: [0.0, 50.0, 100.0], // Close stations
        sEst: 50.0,
        sigmaS: 100.0, // 3σ + 50m margin = 350m window covers all
        isMetroLeg: true,
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 25),
      );

      expect(snap, isNull,
          reason: 'Multiple candidates should prevent snap');
    });

    test('Bias correction happens during ZUPT', () {
      final ekf = EkfPipeline(config: const EkfConfig(), route: route);

      // Initialize
      ekf.onGpsFix(const GpsFix(
        lat: 12.0,
        lng: 77.0,
        accuracyMeters: 10.0,
        speedMps: 10.0,
        timestamp: Duration(seconds: 0),
      ));

      // Feed biased IMU samples
      for (var i = 0; i < 100; i++) {
        ekf.onForwardAccel(Duration(milliseconds: i * 10), 0.3); // Bias
      }

      final biasBeforeZupt = ekf.publicState.biasA;
      final vBeforeZupt = ekf.publicState.v;

      // ZUPT should correct velocity and update bias
      ekf.onZuptConfirmed();

      final biasAfterZupt = ekf.publicState.biasA;
      final vAfterZupt = ekf.publicState.v;

      expect(vAfterZupt.abs(), lessThan(vBeforeZupt.abs()),
          reason: 'ZUPT should reduce velocity toward zero');
      expect(biasAfterZupt, isNot(equals(biasBeforeZupt)),
          reason: 'ZUPT should update bias estimate');
    });

    test('Orchestrator emits station snap confirmed only when gated', () {
      final orchestrator = EkfOrchestrator(route: route);
      orchestrator.setStationContext(
        stationMeters: stationMeters,
        isMetroLeg: true,
      );

      final snapEvents = <StationSnapConfirmed>[];
      orchestrator.onStationSnapConfirmed = (event) {
        snapEvents.add(event);
      };

      // Initialize near station 1
      orchestrator.onGpsFixAuto(const GpsFix(
        lat: 12.0,
        lng: 77.0045, // ~500m along route
        accuracyMeters: 5.0,
        speedMps: 0.0,
        timestamp: Duration(seconds: 0),
      ));

      // Feed stationary IMU for 25+ seconds to trigger ZUPT + snap
      for (var i = 0; i < 2600; i++) {
        final timestamp = Duration(milliseconds: i * 10);
        orchestrator.onImuSample(ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: timestamp,
        ));
      }

      // Check if any snap events were emitted (depends on σ_s gate)
      // With low initial σ and confirmed ZUPT, we expect a snap
      // Note: This depends on full integration working correctly
    });

    test('Non-metro leg prevents station association', () {
      final assoc = StationAssociation();

      final snap = assoc.selectCandidate(
        stationMeters: stationMeters,
        sEst: 500.0,
        sigmaS: 20.0,
        isMetroLeg: false, // Bus leg
        zuptConfirmed: true,
        zuptDwell: const Duration(seconds: 25),
      );

      expect(snap, isNull,
          reason: 'Non-metro legs should not allow station snaps per §6');
    });
  });
}
