import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/soft_lock_manager.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('SoftLockManager', () {
    late SoftLockManager manager;

    setUp(() {
      manager = SoftLockManager();
    });

    final dummyRoute = [const LatLng(0, 0), const LatLng(0, 1)];

    test('should return true when within 50m corridor (high accuracy)', () {
      final result = manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 10.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 40.0, // Within 50
      );
      expect(result, isTrue);
    });

    test('should return true initially even if outside 50m (hysteresis)', () {
      final result = manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 10.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 60.0, // Outside 50
      );
      // First strike is forgiven/counted but returns true 'locked' state until threshold
      expect(result, isTrue);
    });

    test(
      'should return false after 3 consecutive failures (high accuracy)',
      () {
        // 1
        manager.checkSoftLock(
          userLocation: const LatLng(0, 0),
          accuracy: 10.0,
          routePoints: dummyRoute,
          closestSegmentIndex: 0,
          projectedPoint: const LatLng(0, 0),
          lateralOffsetMeters: 60.0,
        );
        // 2
        manager.checkSoftLock(
          userLocation: const LatLng(0, 0),
          accuracy: 10.0,
          routePoints: dummyRoute,
          closestSegmentIndex: 0,
          projectedPoint: const LatLng(0, 0),
          lateralOffsetMeters: 60.0,
        );
        // 3rd strike
        final result = manager.checkSoftLock(
          userLocation: const LatLng(0, 0),
          accuracy: 10.0,
          routePoints: dummyRoute,
          closestSegmentIndex: 0,
          projectedPoint: const LatLng(0, 0),
          lateralOffsetMeters: 60.0,
        );
        expect(result, isFalse, reason: "Should be false on 3rd strike");
      },
    );

    test('should reset counters on recovery', () {
      // 2 strikes
      manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 10.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 60.0,
      );
      manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 10.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 60.0,
      );

      // Recovery
      final result = manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 10.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 10.0, // Safe
      );
      expect(result, isTrue);

      // Next bad check should be strike 1 (return true)
      final afterRecovery = manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 10.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 60.0,
      );
      expect(afterRecovery, isTrue, reason: "Counter should have reset");
    });

    test('should expand corridor to 200m when accuracy is low (>20m)', () {
      // 25m accuracy -> 200m corridor
      // So 100m offset IS valid
      final result = manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 25.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 100.0, // > 50 but < 200
      );
      expect(result, isTrue);

      // But 250m is invalid
      // 3 strikes
      manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 25.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 250.0,
      );
      manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 25.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 250.0,
      );
      final strike3 = manager.checkSoftLock(
        userLocation: const LatLng(0, 0),
        accuracy: 25.0,
        routePoints: dummyRoute,
        closestSegmentIndex: 0,
        projectedPoint: const LatLng(0, 0),
        lateralOffsetMeters: 250.0,
      );
      expect(strike3, isFalse);
    });
  });
}
