import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:sensors_plus/sensors_plus.dart';

// Mock ServiceInstance without Mockito
class MockServiceInstance implements ServiceInstance {
  @override
  Future<void> stopSelf() async {}

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {}

  // Implements Observable.on
  @override
  Stream<Map<String, dynamic>?> on(String event) => Stream.empty();
}

// Mock Geolocator without Mockito
class MockGeolocatorPlatform extends GeolocatorPlatform {
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.always;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.always;

  @override
  Stream<ServiceStatus> getServiceStatusStream() =>
      Stream.value(ServiceStatus.enabled);

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    return Stream.value(
      Position(
        longitude: 0,
        latitude: 0,
        timestamp: DateTime.now(),
        accuracy: 10,
        altitude: 0,
        heading: 0,
        speed: 5,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
        isMocked: true,
      ),
    );
  }

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => null;

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    return Position(
      longitude: 0,
      latitude: 0,
      timestamp: DateTime.now(),
      accuracy: 10,
      altitude: 0,
      heading: 0,
      speed: 0,
      speedAccuracy: 0,
      altitudeAccuracy: 0,
      headingAccuracy: 0,
      isMocked: true,
    );
  }

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;

  @override
  double distanceBetween(
    double startLatitude,
    double startLongitude,
    double endLatitude,
    double endLongitude,
  ) => 0.0;

  @override
  double bearingBetween(
    double startLatitude,
    double startLongitude,
    double endLatitude,
    double endLongitude,
  ) => 0.0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GeolocatorPlatform.instance = MockGeolocatorPlatform();
    SharedPreferences.setMockInitialValues({});
    TrackingService.isTestMode = true;
    testAccelerometerStream = const Stream<AccelerometerEvent>.empty();
    testGyroscopeStream = const Stream<GyroscopeEvent>.empty();
  });

  tearDown(() {
    testAccelerometerStream = null;
    testGyroscopeStream = null;
  });

  test(
    'Process Death Recovery: Restores state from snapshot in onStart',
    () async {
      // 1. Setup: Create a persisted snapshot simulating a killed process
      final snapshot = TrackingSnapshot(
        destinationName: 'Recovery Dest',
        destinationLat: 40.7128,
        destinationLng: -74.0060,
        alarmMode: 'time',
        alarmValue: 5.0,
        metroMode: false,
        userLat: 40.7000,
        userLng: -74.0000,
        createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
        directions: {'routes': []}, // Minimal mock
      );

      await TrackingStateStore.saveSnapshot(snapshot);
      await TrackingStateStore.setActive(
        true,
      ); // Must be active to trigger recovery

      // 2. Execution: Run onStart with NO initial data (simulating OS restart)
      final mockService = MockServiceInstance();

      // We import the public exposed wrapper for testing
      await triggerOnStartForRecoveryTest(mockService);

      // Give it a moment to restore
      await Future.delayed(const Duration(milliseconds: 100));

      // 3. Verification: Check singleton state
      final service = TrackingService();

      expect(
        service.destination,
        isNotNull,
        reason: "Destination should be restored",
      );
      expect(service.destination!.latitude, 40.7128);
      expect(service.alarmMode, 'time');
      expect(service.alarmValue, 5.0);

      // Check if tracking is active
      expect(service.trackingActive, isTrue);
    },
  );
}
