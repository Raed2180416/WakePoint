import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/main.dart' as app;
import 'package:geolocator/geolocator.dart';

// Device integration test: Use foreground test mode (TrackingService.isTestMode=true)
// but keep platform notifications enabled. Inject GPS via testGpsStream so that
// full-screen notifications, vibration, and AlarmActivity still execute on-device.

class SimpleLocationInjector {
  final _ctrl = StreamController<Position>();
  Stream<Position> get stream => _ctrl.stream;
  Future<void> playRoute(List<LatLng> route, {Duration step = const Duration(milliseconds: 350)}) async {
    for (final p in route) {
      _ctrl.add(Position(
        latitude: p.latitude,
        longitude: p.longitude,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: 0.0,
        headingAccuracy: 0.0,
        speed: 12.0,
        speedAccuracy: 1.0,
      ));
      await Future.delayed(step);
    }
  }
  Future<void> close() async { await _ctrl.close(); }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Device: end-to-end alarm flow via injected positions', (WidgetTester tester) async {
    // Launch the real app
    app.main();
    await tester.pumpAndSettle();

  // Foreground test mode: run pipelines in UI isolate but allow real notifications
  TrackingService.isTestMode = true;
  NotificationService.isTestMode = false;
    NotificationService.clearTestRecordedAlarms();
  // Record alarms for assertion; platform behavior remains active
  NotificationService.testOnShowWakeUpAlarm = (String t, String b, bool a) async {};

  // Provide injected GPS via testGpsStream
  final injector = SimpleLocationInjector();
  testGpsStream = injector.stream;

    // Start tracking using the public API (destination ~1km away)
    final destination = const LatLng(12.9585, 77.5868);
    await TrackingService().startTracking(
      destination: destination,
      destinationName: 'DeviceDest',
      alarmMode: 'distance',
      alarmValue: 1.0,
      allowNotificationsInTest: true,
    );

    // Feed a short route that approaches the destination
    final route = <LatLng>[
      const LatLng(12.9630, 77.5850),
      const LatLng(12.9615, 77.5858),
      const LatLng(12.9600, 77.5862),
      const LatLng(12.9590, 77.5865),
      destination,
    ];

    await injector.playRoute(route);
    for (int i = 0; i < 5; i++) { await injector.playRoute([destination], step: const Duration(milliseconds: 500)); }

    // Wait for alarm logic + notification + AlarmActivity
    // Poll up to 25s for the alarm to be recorded
    final startWait = DateTime.now();
    while (NotificationService.testRecordedAlarms.isEmpty &&
        DateTime.now().difference(startWait) < const Duration(seconds: 25)) {
      await Future.delayed(const Duration(seconds: 1));
    }

    // Verify our test hook recorded an alarm (and device should show full-screen)
    expect(NotificationService.testRecordedAlarms.isNotEmpty, true);

    // Clean up
    await TrackingService().stopTracking();
    await injector.close();
  }, timeout: Timeout(Duration(minutes: 5)));
}
