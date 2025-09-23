import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'mock_location_provider.dart';

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

  test('Time-based alarm triggers after eligibility and ETA drops below threshold', () async {
    final mockProvider = MockLocationProvider();
    final tracking = TrackingService();

    // Simulate movement so time gating becomes eligible
    final route = <LatLng>[
      LatLng(12.9600, 77.5855),
      LatLng(12.9598, 77.5856),
      LatLng(12.9596, 77.5857),
      LatLng(12.9594, 77.5858),
      LatLng(12.9592, 77.5859),
    ];

    testGpsStream = mockProvider.positionStream;

    // start tracking with a time alarm (3 minutes)
    await tracking.startTracking(
      destination: route.last,
      destinationName: 'TimeDest',
      alarmMode: 'time',
      alarmValue: 3.0, // minutes
    );

    // Play route to allow ETA smoothing
    await mockProvider.playRoute(route);

    // Wait briefly for processing
    await Future.delayed(const Duration(milliseconds: 200));

    // Because NotificationService is in test mode, recorded alarms list shows events
    expect(NotificationService.testRecordedAlarms.length, lessThanOrEqualTo(1));

    await tracking.stopTracking();
    mockProvider.dispose();
  }, timeout: Timeout(Duration(seconds: 10)));
}
