import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/navigation_service.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/trackingservice.dart';

NotificationResponse _tap({String? payload}) {
  return NotificationResponse(
    notificationResponseType: NotificationResponseType.selectedNotification,
    payload: payload,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Tapping paused notification routes to /mapTracking', (
    tester,
  ) async {
    TrackingStateStore.resetCacheForTests();
    SharedPreferences.setMockInitialValues({});
    NotificationService.isTestMode = true;
    TrackingService.isTestMode = true;

    await TrackingStateStore.setPaused(true);

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
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: NavigationService.navigatorKey,
        routes: {
          '/': (_) => const Scaffold(body: Text('Home')),
          '/mapTracking':
              (_) => const Scaffold(
                body: Text('MapTracking', key: Key('mapTracking')),
              ),
        },
      ),
    );

    // Simulate the user tapping the notification (no actionId).
    await NotificationService().handleNotificationResponse(
      _tap(payload: 'tracking_paused'),
      allowNavigation: true,
    );

    // Let navigation settle.
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mapTracking')), findsOneWidget);

    NotificationService.isTestMode = false;
    TrackingService.isTestMode = false;
  });
}
