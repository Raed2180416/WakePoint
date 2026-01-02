import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/services/navigation_service.dart';
import 'package:geowake2/services/notification_service.dart';
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
    NotificationService.isTestMode = true;
    TrackingService.isTestMode = true;

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

    // Let navigation complete (bounded; avoids hanging if timers keep frames alive).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const Key('mapTracking')), findsOneWidget);

    NotificationService.isTestMode = false;
    TrackingService.isTestMode = false;
  });
}
