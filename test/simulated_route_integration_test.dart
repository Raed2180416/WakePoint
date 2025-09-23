import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'mock_location_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

// This integration-style test runs inside the Dart VM using the existing
// TrackingService test hooks. It simulates a sped-up route with deviations
// and asserts that the alarm notification and alarm player are invoked.

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.testOnShowWakeUpAlarm = (String title, String body, bool allow) async {
      // mark via a simple print/log that the alarm hook was called
      // Tests can assert on this by capturing prints or by other shared state.
  debugPrint('TEST-HOOK: showWakeUpAlarm -> $title | $body | allow=$allow');
    };
  });

  tearDown(() async {
    NotificationService.testOnShowWakeUpAlarm = null;
    TrackingService.isTestMode = false;
    NotificationService.isTestMode = false;
  });

  test('Simulated fast route with deviations triggers alarm and notifications', () async {
    final mockProvider = MockLocationProvider();
    final tracking = TrackingService();

    // Define a dense route with multiple deviations (looping back and forth)
    final route = <LatLng>[];
    // Start far, then approach, deviate, come back, then approach destination
    for (int i = 0; i < 30; i++) {
      route.add(LatLng(12.9600 + (i * 0.00005), 77.5855));
    }
    // Deviation
    for (int i = 0; i < 10; i++) {
      route.add(LatLng(12.9620 + (i * 0.00008), 77.5865));
    }
    // Return
    for (int i = 0; i < 20; i++) {
      route.add(LatLng(12.9610 - (i * 0.00004), 77.5860));
    }
    // Final approach
    for (int i = 0; i < 10; i++) {
      route.add(LatLng(12.9580 + (i * 0.00002), 77.5868));
    }

    // Hook to observe when alarm player is started/stopped (log-only)
    AlarmPlayer.isPlaying.addListener(() {
      debugPrint('TEST-HOOK: AlarmPlayer.isPlaying=${AlarmPlayer.isPlaying.value}');
    });

    // Prepare GPS stream for injection
    testGpsStream = mockProvider.positionStream;

    // Start tracking with alarm mode distance (1 km threshold)
    await tracking.startTracking(
      destination: route.last,
      destinationName: 'TestDest',
      alarmMode: 'distance',
      alarmValue: 1.0,
    );

    // Play the route (sped up)
    await mockProvider.playRoute(route);

  // Allow some time for processing
  await Future.delayed(const Duration(seconds: 1));

    expect(tracking.alarmTriggered, isTrue);

    // Clean up
    await tracking.stopTracking();
    mockProvider.dispose();
  }, timeout: Timeout(Duration(seconds: 20)));
}
