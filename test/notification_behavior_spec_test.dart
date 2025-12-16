import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/trackingservice.dart';

NotificationResponse _resp({String? actionId, String? payload}) {
  return NotificationResponse(
    notificationResponseType: NotificationResponseType.selectedNotification,
    actionId: actionId,
    payload: payload,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Notification spec behaviors (unit)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      TrackingStateStore.resetCacheForTests();
      NotificationService.isTestMode = true;
      TrackingService.isTestMode = true;
      NotificationService.clearTestRecordedAlarms();
      NotificationService.clearTestRecordedNotifications();

      await TrackingStateStore.setActive(false);
      await TrackingStateStore.setNotificationsMuted(false);
      await TrackingStateStore.setAlarmFired(false);
      await TrackingStateStore.clearProgressPayload();
      await TrackingStateStore.clearSnapshot();
    });

    tearDown(() {
      NotificationService.isTestMode = false;
      TrackingService.isTestMode = false;
      NotificationService.testOnShowWakeUpAlarm = null;
      NotificationService.testOnShowNotification = null;
      NotificationService.testOnCancelNotification = null;
    });

    test('Journey progress persists payload in test mode', () async {
      await NotificationService().showJourneyProgress(
        title: 'Journey to A',
        subtitle: 'Starting…',
        progress0to1: 0.1,
        isTracking: true,
      );

      final payload = await TrackingStateStore.loadProgressPayload();
      expect(payload, isNotNull);
      expect(payload!.title, 'Journey to A');
      expect(payload.isTracking, isTrue);

      expect(NotificationService.testRecordedNotifications, isNotEmpty);
      expect(
        NotificationService.testRecordedNotifications.last['payload'],
        'journey_active',
      );
    });

    test('Ignore on journey mutes and clears payload', () async {
      await NotificationService().showJourneyProgress(
        title: 'Journey to A',
        subtitle: 'Remaining: 1.2 km',
        progress0to1: 0.3,
        isTracking: true,
      );

      await NotificationService().handleNotificationResponse(
        _resp(actionId: 'IGNORE', payload: 'journey_active'),
        allowNavigation: false,
      );

      expect(await TrackingStateStore.notificationsMuted(), isTrue);
      expect(await TrackingStateStore.loadProgressPayload(), isNull);
    });

    test('Muted journey prevents further journey updates', () async {
      await TrackingStateStore.setNotificationsMuted(true);

      await NotificationService().showJourneyProgress(
        title: 'Journey to A',
        subtitle: 'Should not show',
        progress0to1: 0.9,
        isTracking: true,
      );

      expect(NotificationService.testRecordedNotifications, isEmpty);
      expect(await TrackingStateStore.loadProgressPayload(), isNull);
    });

    test(
      'Ignore on alarm cancels alarm and clears pending alarm prefs',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('pending_alarm_flag', true);
        await prefs.setString('pending_alarm_title', 'T');
        await prefs.setString('pending_alarm_body', 'B');
        await prefs.setBool('pending_alarm_allow', true);

        await TrackingStateStore.setActive(true);
        await TrackingStateStore.setAlarmFired(true);

        await NotificationService().handleNotificationResponse(
          _resp(actionId: 'IGNORE', payload: 'open_alarm:1'),
          allowNavigation: false,
        );

        expect(
          await TrackingStateStore.isActive(),
          isTrue,
          reason: 'Stop alarm should not end tracking',
        );
        expect(await TrackingStateStore.isAlarmFired(), isFalse);
        expect(prefs.getBool('pending_alarm_flag'), isNull);
        expect(prefs.getString('pending_alarm_title'), isNull);
        expect(prefs.getString('pending_alarm_body'), isNull);
        expect(prefs.getBool('pending_alarm_allow'), isNull);
      },
    );

    test('STOP_ALARM cancels alarm but keeps session active', () async {
      await TrackingStateStore.setActive(true);
      await TrackingStateStore.setAlarmFired(true);

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

      await NotificationService().handleNotificationResponse(
        _resp(actionId: 'STOP_ALARM', payload: 'open_alarm:1'),
        allowNavigation: false,
      );

      expect(await TrackingStateStore.isActive(), isTrue);
      expect(await TrackingStateStore.loadSnapshot(), isNotNull);
      expect(await TrackingStateStore.isAlarmFired(), isFalse);
    });

    test('END_TRACKING clears session state and notifications state', () async {
      await TrackingStateStore.setActive(true);
      await TrackingStateStore.setNotificationsMuted(true);
      await TrackingStateStore.setAlarmFired(true);

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

      await NotificationService().showJourneyProgress(
        title: 'Journey to Dest',
        subtitle: 'Remaining: 1.0 km',
        progress0to1: 0.2,
        isTracking: true,
      );

      await NotificationService().handleNotificationResponse(
        _resp(actionId: 'END_TRACKING', payload: 'journey_active'),
        allowNavigation: false,
      );

      expect(await TrackingStateStore.isActive(), isFalse);
      expect(await TrackingStateStore.loadSnapshot(), isNull);
      expect(await TrackingStateStore.notificationsMuted(), isFalse);
      expect(await TrackingStateStore.isAlarmFired(), isFalse);
      expect(
        await TrackingStateStore.loadProgressPayload(),
        isNull,
        reason: 'End tracking should clear persisted progress payload',
      );
    });

    test('Paused notification persists payload in test mode', () async {
      await NotificationService().showTrackingPaused(destinationName: 'Dest');

      final payload = await TrackingStateStore.loadProgressPayload();
      expect(payload, isNotNull);
      expect(payload!.title, 'Tracking paused');
      expect(payload.isTracking, isFalse);

      expect(NotificationService.testRecordedNotifications, isNotEmpty);
      expect(
        NotificationService.testRecordedNotifications.last['payload'],
        'tracking_paused',
      );
    });

    test(
      'resumeFromNotification restores from snapshot and reissues journey',
      () async {
        await TrackingStateStore.setNotificationsMuted(true);
        await TrackingStateStore.setActive(false);
        await TrackingStateStore.setAlarmFired(true);
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

        NotificationService.clearTestRecordedNotifications();
        await TrackingService().resumeFromNotification();

        expect(await TrackingStateStore.notificationsMuted(), isFalse);
        expect(await TrackingStateStore.isActive(), isTrue);
        expect(await TrackingStateStore.isPaused(), isFalse);
        expect(await TrackingStateStore.isAlarmFired(), isFalse);

        final last = NotificationService.testRecordedNotifications.last;
        expect(last['payload'], 'journey_active');
        expect((last['title'] as String).contains('Dest'), isTrue);

        final progress = await TrackingStateStore.loadProgressPayload();
        expect(progress, isNotNull);
        expect(progress!.isTracking, isTrue);
      },
    );

    test(
      'cancelAllNotifications clears alarm + progress persistent state',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('pending_alarm_flag', true);
        await prefs.setString('pending_alarm_title', 'T');

        await TrackingStateStore.setAlarmFired(true);
        await NotificationService().showJourneyProgress(
          title: 'Journey to A',
          subtitle: 'Remaining',
          progress0to1: 0.2,
          isTracking: true,
        );

        await NotificationService().cancelAllNotifications();

        expect(await TrackingStateStore.isAlarmFired(), isFalse);
        expect(await TrackingStateStore.loadProgressPayload(), isNull);
        expect(prefs.getBool('pending_alarm_flag'), isNull);
        expect(prefs.getString('pending_alarm_title'), isNull);
      },
    );
  });
}
