import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/transfer_utils.dart'; // For RouteEventBoundary
import 'package:shared_preferences/shared_preferences.dart';

// --- Mocks and Helpers ---

DateTime _mockTime = DateTime.now();
Position p(double lat, double lng, {double speed = 10.0}) {
  _mockTime = _mockTime.add(const Duration(seconds: 1));
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: _mockTime,
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: speed,
    speedAccuracy: 0,
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/sensors/method'),
          (MethodCall methodCall) async => null,
        );

    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();
    _mockTime = DateTime.now();
  });

  tearDown(() async {
    final svc = TrackingService();
    await svc.stopTracking();
  });

  test('Complex Route Alarm Logic: Switch vs Destination Conflict', () async {
    final svc = TrackingService();
    // USE SINGLE SUBSCRIPTION CONTROLLER FOR IDENTITY STABILITY
    final gps = StreamController<Position>();
    testGpsStream = gps.stream;
    print('DEBUG: Test: Setup testGpsStream Hash=${testGpsStream.hashCode}');

    final points = [
      const LatLng(0.0, 0.0), // Start
      const LatLng(0.01, 0.0), // Switch 1 (Board) ~1111m
      const LatLng(0.04, 0.0), // Switch 2 ~4440m
      const LatLng(0.05, 0.0), // Dest ~5550m
    ];

    final stepBounds = [1100.0, 4400.0, 5500.0];
    final stepStops = [0.0, 6.0, 6.0];

    final routeEvents = [
      RouteEventBoundary(
        meters: 1100.0,
        lat: 0.01,
        lng: 0.0,
        label: 'Metro Stn 1',
        type: 'transfer',
      ),
      RouteEventBoundary(
        meters: 4400.0,
        lat: 0.04,
        lng: 0.0,
        label: 'Metro Stn 2',
        type: 'transfer',
      ),
    ];

    await svc.registerRouteRaw(
      key: 'test_complex',
      points: points,
      stepBounds: stepBounds,
      stepStops: stepStops,
      routeEvents: routeEvents,
      destinationName: 'Home 2',
      transitMode: true,
    );

    await svc.startTracking(
      destination: const LatLng(0.05, 0.0),
      destinationName: 'Home 2',
      alarmMode: 'stops',
      alarmValue: 2.0, // 2 stops OR 1km (hybrid)
    );

    // Wait for GPS subscription
    print('DEBUG: Test: Waiting for GPS listener...');
    while (!gps.hasListener) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    print('DEBUG: Test: GPS hasListener=true');

    // --- EXECUTION ---

    // 1. Approaching Switch 1
    var nextState = svc.activeRouteStateStream.first;
    print('DEBUG: Test: Adding GPS point 1');
    gps.add(p(0.0015, 0.0)); // ~100m from start
    await nextState.timeout(const Duration(seconds: 2));
    print('DEBUG: Test: State received');
    await Future.delayed(const Duration(milliseconds: 250));

    var alarms = NotificationService.testRecordedAlarms;
    expect(
      alarms.any((a) => (a['body'] as String).contains('Metro Stn 1')),
      isTrue,
      reason: 'Failed to trigger Switch 1 alarm at 1km',
    );
    NotificationService.clearTestRecordedAlarms();

    // 2. Approaching Switch 2
    nextState = svc.activeRouteStateStream.first;
    gps.add(p(0.03, 0.0));
    await nextState.timeout(const Duration(seconds: 2));
    await Future.delayed(const Duration(milliseconds: 250));

    alarms = NotificationService.testRecordedAlarms;
    expect(
      alarms.any((a) => (a['body'] as String).contains('Metro Stn 2')),
      isTrue,
      reason: 'Failed to trigger Switch 2 alarm at 2 stops out',
    );
    NotificationService.clearTestRecordedAlarms();

    // 3. CONFLICT TEST
    nextState = svc.activeRouteStateStream.first;
    gps.add(p(0.041, 0.0));
    await nextState.timeout(const Duration(seconds: 2));

    await svc.stopTracking();
    await gps.close();
  });

  test('Conflict Resolution: Destination beats Switch', () async {
    final svc = TrackingService();
    // USE SINGLE SUBSCRIPTION CONTROLLER FOR IDENTITY STABILITY
    final gps = StreamController<Position>();
    testGpsStream = gps.stream;
    print('DEBUG: Test: Setup testGpsStream Hash=${testGpsStream.hashCode}');

    final points = [const LatLng(0, 0), const LatLng(0.011, 0)]; // 0 to ~1200m
    final stepBounds = [1250.0];
    final stepStops = [0.0]; // Walking

    final routeEvents = [
      RouteEventBoundary(
        meters: 1000.0,
        lat: 0.01,
        lng: 0.0,
        label: 'Switch Point',
        type: 'transfer',
      ),
    ];

    await svc.registerRouteRaw(
      key: 'conflict_test',
      points: points,
      stepBounds: stepBounds,
      stepStops: stepStops,
      routeEvents: routeEvents,
      destinationName: 'Final Home',
      transitMode: true,
    );

    await svc.startTracking(
      destination: const LatLng(0.011, 0.0), // 1200m point aprox
      destinationName: 'Final Home',
      alarmMode: 'stops',
      alarmValue: 2.0,
    );

    print('DEBUG: Test: Waiting for GPS listener...');
    while (!gps.hasListener) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    print('DEBUG: Test: GPS hasListener=true');

    var nextState = svc.activeRouteStateStream.first;
    print('DEBUG: Test: Adding GPS point conflict');
    gps.add(p(0.0081, 0.0));
    await nextState.timeout(const Duration(seconds: 2));
    print('DEBUG: Test: State received');
    await Future.delayed(const Duration(milliseconds: 250));

    final alarms = NotificationService.testRecordedAlarms;
    print("Conflict Alarms: $alarms");
    final firedDest = alarms.any(
      (a) => (a['body'] as String).contains('Final Home'),
    );
    final firedSwitch = alarms.any(
      (a) => (a['body'] as String).contains('Switch Point'),
    );

    expect(
      firedDest,
      isTrue,
      reason: 'Should prefer Destination alarm over Switch alarm',
    );
    expect(
      firedSwitch,
      isFalse,
      reason: 'Should IGNORE Switch alarm when Destination alarm coincides',
    );

    await svc.stopTracking();
    await gps.close();
  });
}
