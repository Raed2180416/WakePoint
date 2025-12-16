import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() {
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
  });

  test('completeEndTracking should clear active flag and snapshot', () async {
    final svc = TrackingService();

    // Seed a snapshot as if UI saved it.
    await TrackingStateStore.saveSnapshot(
      TrackingSnapshot(
        destinationName: 'Dest',
        destinationLat: 1.0,
        destinationLng: 1.0,
        alarmMode: 'distance',
        alarmValue: 1.0,
        metroMode: false,
        userLat: 0.0,
        userLng: 0.0,
        createdAt: DateTime(2024, 1, 1),
        directions: null,
      ),
    );
    await TrackingStateStore.setActive(true);

    // Start tracking in test mode to ensure foreground loop/session state is primed.
    await svc.startTracking(
      destination: const LatLng(1.0, 1.0),
      destinationName: 'Dest',
      alarmMode: 'distance',
      alarmValue: 1.0,
      allowNotificationsInTest: true,
      useInjectedPositions: true,
    );

    await svc.completeEndTracking(navigateHome: false);

    expect(
      await TrackingStateStore.isActive(),
      isFalse,
      reason: 'Active flag should be cleared after end tracking',
    );
    expect(
      await TrackingStateStore.loadSnapshot(),
      isNull,
      reason: 'Snapshot should be removed after end tracking',
    );
    expect(
      await TrackingStateStore.notificationsMuted(),
      isFalse,
      reason: 'Muted flag should not remain set after end tracking',
    );
  });
}
