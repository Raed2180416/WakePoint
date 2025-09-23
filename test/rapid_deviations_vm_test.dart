import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'mock_location_provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();
  });

  tearDown(() async {
    TrackingService.isTestMode = false;
    NotificationService.isTestMode = false;
    NotificationService.clearTestRecordedAlarms();
  });

  test('Rapid many deviations stress route-switch hysteresis', () async {
    final mockProvider = MockLocationProvider();
    final tracking = TrackingService();

  // Register two nearby orthogonal routes so the manager can switch
  // Route A: horizontal corridor (east-west) around lat 12.9600
  final routeA = List.generate(30, (i) => LatLng(12.9600, 77.5850 + i * 0.00005));
  // Route B: vertical corridor (north-south) around lon 77.5865
  final routeB = List.generate(30, (i) => LatLng(12.9595 + i * 0.00005, 77.5865));
    tracking.registerRoute(
      key: 'A',
      mode: 'driving',
      destinationName: 'A',
      points: routeA,
    );
    tracking.registerRoute(
      key: 'B',
      mode: 'driving',
      destinationName: 'B',
      points: routeB,
    );

    // Weave path: start near A, move along A, then drift to B, linger near B, then back
    final route = <LatLng>[];
    // Along A
    for (int i = 0; i < 20; i++) {
      route.add(LatLng(12.9600, 77.5850 + i * 0.00005));
    }
    // Drift towards B
    for (int i = 0; i < 10; i++) {
      route.add(LatLng(12.9600 + i * 0.00003, 77.5860 + i * 0.00005));
    }
    // Linger near B corridor to satisfy sustain
    for (int i = 0; i < 10; i++) {
      route.add(LatLng(12.9610 + i * 0.00001, 77.5865));
    }
    // Return towards A
    for (int i = 0; i < 10; i++) {
      route.add(LatLng(12.9610 - i * 0.00003, 77.5865 - i * 0.00005));
    }

    testGpsStream = mockProvider.positionStream;

    await tracking.startTracking(
      destination: route.last,
      destinationName: 'WeaveDest',
      alarmMode: 'distance',
      alarmValue: 0.5,
    );
    // Listen for switch events before feeding GPS positions
    bool switched = false;
    final sub = tracking.routeSwitchStream.listen((event) {
      switched = true;
    });

    // Feed the route
    await mockProvider.playRoute(route);

    // Wait to let switch decisions settle
    await Future.delayed(const Duration(seconds: 1));

    await sub.cancel();

    expect(switched, isTrue);

    await tracking.stopTracking();
    mockProvider.dispose();
  }, timeout: Timeout(Duration(seconds: 20)));
}
