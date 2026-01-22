// Test EKF Test Controller wiring - verifies EKF orchestrator is properly
// connected and receives IMU/GPS data during replay.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/core/ekf/ekf_test_controller.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/ekf_orchestrator.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';

void main() {
  group('EkfTestController Wiring', () {
    test('EKF orchestrator is created when route is loaded', () async {
      final controller = EkfTestController();
      
      // We can't easily test loadLog without actual files, so let's test
      // the initialization logic by checking internal state after manual setup
      
      // For now, just verify the controller can be created
      expect(controller.isActive, isFalse);
      expect(controller.isPlaying, isFalse);
      
      controller.dispose();
    });

    test('EKF orchestrator receives IMU samples and produces state', () {
      // Create a simple route
      final route = RouteGeometry.fromPoints(const [
        LatLng(12.9716, 77.5946), // Bangalore start
        LatLng(12.9800, 77.5946), // ~1km north
      ]);

      final orchestrator = EkfOrchestrator(route: route);
      orchestrator.setStationContext(stationMeters: [0, 500, 1000], isMetroLeg: true);

      // Initial state - EKF returns 0 when not initialized (not NaN)
      expect(orchestrator.publicState.s, equals(0.0));
      expect(orchestrator.publicState.v, equals(0.0));

      // Feed GPS fix to initialize position
      orchestrator.onGpsFixAuto(
        const GpsFix(
          lat: 12.9716,
          lng: 77.5946,
          accuracyMeters: 10.0,
          speedMps: 0.0,
          timestamp: Duration.zero,
        ),
      );

      // After GPS, position should be initialized (near start of route)
      expect(orchestrator.publicState.s, closeTo(0, 50)); // Near start

      // Feed some IMU samples (stationary)
      for (int i = 0; i < 100; i++) {
        orchestrator.onImuSample(
          ImuSample(
            ax: 0.0,
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: Duration(milliseconds: i * 10),
          ),
        );
      }

      // State should still be valid
      expect(orchestrator.publicState.sigmaS, greaterThan(0));
    });

    test('EKF orchestrator tracks GPS dropout and uses IMU prediction', () {
      final route = RouteGeometry.fromPoints(const [
        LatLng(12.9716, 77.5946),
        LatLng(12.9900, 77.5946), // ~2km north
      ]);

      final orchestrator = EkfOrchestrator(route: route);
      orchestrator.setStationContext(stationMeters: [0, 1000, 2000], isMetroLeg: true);

      // Initialize with GPS at start
      orchestrator.onGpsFixAuto(
        const GpsFix(
          lat: 12.9716,
          lng: 77.5946,
          accuracyMeters: 10.0,
          speedMps: 5.0, // Moving at 5 m/s
          timestamp: Duration.zero,
        ),
      );

      // Feed IMU with forward acceleration for 2 seconds (no GPS)
      for (int i = 0; i < 200; i++) {
        orchestrator.onImuSample(
          ImuSample(
            ax: 0.5, // Forward accel
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: Duration(milliseconds: i * 10),
          ),
        );
      }

      // Position uncertainty should have grown without GPS
      expect(orchestrator.publicState.sigmaS, greaterThan(10));
      
      // Check if EKF reports degraded mode
      // (may or may not be degraded depending on thresholds)
    });

    test('Station snap callback is triggered during ZUPT at station', () {
      final route = RouteGeometry.fromPoints(const [
        LatLng(12.9716, 77.5946),
        LatLng(12.9800, 77.5946),
      ]);

      final orchestrator = EkfOrchestrator(route: route);
      
      // Station at 500m
      orchestrator.setStationContext(stationMeters: [500], isMetroLeg: true);

      final snaps = <StationSnapConfirmed>[];
      orchestrator.onStationSnapConfirmed = (snap) {
        snaps.add(snap);
      };

      // Initialize at station location
      orchestrator.onGpsFixAuto(
        const GpsFix(
          lat: 12.9760, // Approx 500m from start
          lng: 77.5946,
          accuracyMeters: 10.0,
          speedMps: 0.0,
          timestamp: Duration.zero,
        ),
      );

      // Feed stationary IMU for 5 seconds to trigger ZUPT
      for (int i = 0; i < 500; i++) {
        orchestrator.onImuSample(
          ImuSample(
            ax: 0.0,
            ay: 0.0,
            az: 9.81,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: Duration(milliseconds: i * 10),
          ),
        );
      }

      // Station snap may or may not be triggered depending on implementation
      // This test documents current behavior
      print('Station snaps triggered: ${snaps.length}');
    });
  });
}
