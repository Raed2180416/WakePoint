// ignore_for_file: avoid_print
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TrackingService.isTestMode = true;
    await TrackingStateStore.setAlarmFired(false);
  });

  tearDown(() {
    testGpsStream = null;
  });

  test(
    'Reproduce Missing Bounds Bug: Verify Alarm Triggers with Correct Data',
    () async {
      final service = TrackingService();
      final streamController = StreamController<Position>.broadcast();
      testGpsStream = streamController.stream;

      // 1. Setup a mock route with stops

      // 2. Register Route directly to bypass polyline decoding issues
      print('Registering route...');
      await service.registerRouteRaw(
        key: 'test_route',
        transitMode: true,
        destinationName: "Test Dest",
        points: [LatLng(0, 0), LatLng(0.01, 0)], // Straight line along X axis
        stepBounds: [100.0, 1100.0],
        stepStops: [0.0, 10.0],
        routeEvents: const <RouteEventBoundary>[],
        firstTransitBoarding: LatLng(0.001, 0.001),
      );

      // 3. Start Tracking
      print('Starting tracking...');
      await service.startTracking(
        destination: LatLng(0.01, 0.01),
        destinationName: "Test Dest",
        alarmMode: 'stops',
        alarmValue: 2.0, // Alarm when <= 2 stops remaining
        useInjectedPositions: false, // Use testGpsStream
      );

      // 4. Inject Position: Just boarded bus (150m total)
      // Progress stops = 0.5. Remaining = 9.5. Should NOT trigger.
      print('Injecting position 1 (150m)...');
      streamController.add(
        Position(
          latitude: 0.001, // Approx 111m
          longitude: 0,
          timestamp: DateTime.now(),
          accuracy: 10,
          altitude: 0,
          heading: 0,
          speed: 10,
          speedAccuracy: 0,
          altitudeAccuracy: 0,
          headingAccuracy: 0,
        ),
      );

      // Wait for processing
      await Future.delayed(const Duration(milliseconds: 500));

      // Check alarm
      bool fired = await TrackingStateStore.isAlarmFired();
      print('Alarm Fired (Expect False): $fired');
      expect(fired, false, reason: "Should not fire yet");

      // 5. Inject Positions: Walk from 150m to 1050m
      // We need to simulate movement so SnapToRoute doesn't get lost.
      print('Injecting intermediate positions...');
      for (double lat = 0.002; lat <= 0.012; lat += 0.001) {
        print('Injecting lat: $lat');
        streamController.add(
          Position(
            latitude: lat,
            longitude: 0,
            timestamp: DateTime.now(),
            accuracy: 10,
            altitude: 0,
            heading: 0,
            speed: 10,
            speedAccuracy: 0,
            altitudeAccuracy: 0,
            headingAccuracy: 0,
          ),
        );
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Wait for processing
      await Future.delayed(const Duration(seconds: 3));

      // Check alarm
      fired = await TrackingStateStore.isAlarmFired();
      print('Alarm Fired (Expect True): $fired');

      expect(
        fired,
        true,
        reason: "Alarm should fire if data is correctly propagated",
      );

      await service.stopTracking();
      streamController.close();
    },
  );
}
