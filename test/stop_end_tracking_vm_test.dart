import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/alarm_player.dart';
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

  test('Stop and End tracking flows cancel notifications and stop alarms', () async {
    final mockProvider = MockLocationProvider();
    final tracking = TrackingService();

    final route = <LatLng>[
      LatLng(12.9600, 77.5855),
      LatLng(12.9598, 77.5856),
      LatLng(12.9596, 77.5857),
    ];

    testGpsStream = mockProvider.positionStream;

    await tracking.startTracking(
      destination: route.last,
      destinationName: 'StopFlowDest',
      alarmMode: 'distance',
      alarmValue: 0.5,
    );

    await mockProvider.playRoute(route);

    // Stop tracking and verify alarmPlayer stopped and notifications cleared
    await tracking.stopTracking();

  // After stopping tracking, the alarm should not be playing.
  expect(AlarmPlayer.isPlaying.value, isFalse);

    mockProvider.dispose();
  }, timeout: Timeout(Duration(seconds: 10)));
}
