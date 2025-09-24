// Annotated copy of lib/services/notification_service.dart
// Purpose: Explain alarm and progress notifications, test-mode hooks, and full-screen intents.

import 'package:flutter/material.dart'; // Widgets for routing to full-screen UI
import 'package:flutter/services.dart';  // MethodChannel for native Android interop
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // Notifications plugin
import 'package:shared_preferences/shared_preferences.dart'; // Persist pending alarm state
import 'package:geowake2/services/navigation_service.dart'; // Global navigator access
import 'package:geowake2/screens/alarm_fullscreen.dart'; // Full-screen alarm UI widget
import 'package:geowake2/services/alarm_player.dart'; // Sound playback abstraction
import 'package:geowake2/services/trackingservice.dart'; // To stop tracking from actions
import 'package:flutter_background_service/flutter_background_service.dart'; // To signal bg isolate
import 'dart:typed_data'; // Vibration pattern arrays
import 'dart:developer' as dev; // Logging

class NotificationService {
  static final NotificationService _instance = NotificationService._internal(); // Singleton
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Test-mode switch to bypass platform calls while preserving observability
  static bool isTestMode = false;
  // Optional test hook invoked on showWakeUpAlarm; allows assertions without plugins
  static Future<void> Function(String, String, bool)? testOnShowWakeUpAlarm;
  // In-memory record of alarms for tests
  static final List<Map<String, dynamic>> testRecordedAlarms = [];
  static void clearTestRecordedAlarms() => testRecordedAlarms.clear();

  // Native Android channel for launching dedicated AlarmActivity and vibration control
  static const _alarmMethodChannel = MethodChannel('com.example.geowake2/alarm');

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  static const int _alarmNotificationId = 0;   // Stable ID for alarm
  static const int _progressNotificationId = 888; // Stable ID for ongoing progress

  // Fire native AlarmActivity for reliable lockscreen presentation and vibration
  Future<void> _launchNativeAlarmActivity({
    required String title,
    required String body,
    required bool allowContinueTracking,
  }) async {
    try {
      await _alarmMethodChannel.invokeMethod('launchAlarmActivity', {
        'title': title,
        'body': body,
        'allowContinue': allowContinueTracking,
      });
    } catch (e) {
      dev.log('Failed to launch native alarm activity: $e', name: 'NotificationService');
      throw e;
    }
  }

  Future<void> stopVibration() async {
    try { await _alarmMethodChannel.invokeMethod('stopVibration'); } catch (e) {
      dev.log('Failed to stop vibration: $e', name: 'NotificationService');
    }
  }

  // Stop sound/vibration and clear alarm notification
  Future<void> cancelAlarm() async {
    try { await AlarmPlayer.stop(); } catch (e) { dev.log('AlarmPlayer.stop failed: $e', name: 'NotificationService'); }
    try { await stopVibration(); } catch (_) {}
    try { await _notificationsPlugin.cancel(_alarmNotificationId); } catch (e) { dev.log('Cancel alarm notification failed: $e', name: 'NotificationService'); }
  }

  Future<void> initialize() async {
    dev.log('NotificationService.initialize() start', name: 'NotificationService');
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();
    const InitializationSettings settings = InitializationSettings(android: androidSettings, iOS: iosSettings);

    await _notificationsPlugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) async {
        dev.log('Notification response: actionId=${response.actionId}, payload=${response.payload}', name: 'NotificationService');
        if (response.actionId == 'STOP_ALARM') {
          try { await AlarmPlayer.stop(); } catch (_) {}
          try { FlutterBackgroundService().invoke('stopAlarm'); } catch (_) {}
          return;
        }
        if (response.actionId == 'END_TRACKING') {
          try { await AlarmPlayer.stop(); } catch (_) {}
          try { await TrackingService().stopTracking(); } catch (_) {}
          return;
        }
        if (response.payload != null && response.payload!.startsWith('open_alarm')) {
          bool allow = true;
          final parts = response.payload!.split(':');
          if (parts.length > 1) allow = parts[1] == '1';
          final nav = NavigationService.navigatorKey.currentState;
          if (nav != null) {
            nav.push(MaterialPageRoute(
              builder: (_) => AlarmFullscreen(title: 'Wake Up!', body: 'Approaching your target', allowContinueTracking: allow),
            ));
          }
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    // Android 13+ runtime permission
    try { await _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission(); } catch (e) { dev.log('Permission request failed: $e', name: 'NotificationService'); }

    // Ensure channels exist (alarm + tracking + bg service)
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        await androidImpl.createNotificationChannel(const AndroidNotificationChannel(
          'geowake_alarm_channel_v2', 'GeoWake Alarms', description: 'Channel for GeoWake wake-up alarms', importance: Importance.max,
        ));
        await androidImpl.createNotificationChannel(const AndroidNotificationChannel(
          'geowake_tracking_channel_v2', 'GeoWake Tracking', description: 'Ongoing tracking status', importance: Importance.defaultImportance,
        ));
        await androidImpl.createNotificationChannel(const AndroidNotificationChannel(
          'geowake_tracking_channel', 'GeoWake Tracking (Service)', description: 'Foreground service notifications', importance: Importance.defaultImportance,
        ));
      }
    } catch (e) {
      dev.log('Creating notification channels failed: $e', name: 'NotificationService');
    }

    dev.log('NotificationService.initialize() done', name: 'NotificationService');
  }

  // High-priority alarm with full-screen intent and native activity launch
  Future<void> showWakeUpAlarm({
    required String title,
    required String body,
    bool allowContinueTracking = true,
  }) async {
    // Test-mode observability first
    if (isTestMode || testOnShowWakeUpAlarm != null) {
      if (testOnShowWakeUpAlarm != null) { try { await testOnShowWakeUpAlarm!(title, body, allowContinueTracking); } catch (_) {} }
      try { testRecordedAlarms.add({'title': title, 'body': body, 'allow': allowContinueTracking, 'ts': DateTime.now().toIso8601String()}); } catch (_) {}
    }
    if (isTestMode) return; // Skip platform behavior in tests unless explicitly allowed by caller

    dev.log('ALARM TRIGGER: "$title" - "$body"', name: 'NotificationService');

    // Persist a pending flag so UI can restore if app process restarted
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pending_alarm_flag', true);
    await prefs.setString('pending_alarm_title', title);
    await prefs.setString('pending_alarm_body', body);
    await prefs.setBool('pending_alarm_allow', allowContinueTracking);

    // Ensure a high-priority alarm channel with vibration exists
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        final vibrationPattern = Int64List.fromList([0, 500, 250, 500, 250, 1000, 500]);
        await androidImpl.createNotificationChannel(AndroidNotificationChannel(
          'geowake_alarm_channel_v3', 'GeoWake Alarms (High Priority)',
          description: 'Channel for urgent GeoWake wake-up alarms', importance: Importance.max,
          enableVibration: true, vibrationPattern: vibrationPattern, playSound: false,
        ));
        try { await androidImpl.requestNotificationsPermission(); } catch (e) { dev.log('Permission request failed: $e', name: 'NotificationService'); }
      }
    } catch (e) { dev.log('Failed to create/update alarm channel: $e', name: 'NotificationService'); }

    // Compose platform details for the full-screen alarm notification
    final vibrationPattern = Int64List.fromList([0, 500, 250, 500, 250, 1000, 500]);
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'geowake_alarm_channel_v3', 'GeoWake Alarms (High Priority)',
      channelDescription: 'Channel for GeoWake wake-up alarms', importance: Importance.max, priority: Priority.max,
      playSound: false, fullScreenIntent: true, visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.alarm, ongoing: true, autoCancel: false,
      enableVibration: true, vibrationPattern: vibrationPattern, ticker: 'Destination alarm active',
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction('STOP_ALARM', 'Stop Alarm', showsUserInterface: false),
        AndroidNotificationAction('END_TRACKING', 'End Tracking', showsUserInterface: true),
      ],
    );
    final DarwinNotificationDetails iosDetails = const DarwinNotificationDetails(presentSound: false);
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    try {
      // Show the notification with full-screen intent
      await _notificationsPlugin.show(
        _alarmNotificationId, title, body, details,
        payload: 'open_alarm:${allowContinueTracking ? '1' : '0'}',
      );

      // Also directly launch native AlarmActivity for reliability
      try { await _launchNativeAlarmActivity(title: title, body: body, allowContinueTracking: allowContinueTracking); }
      catch (e) {
        dev.log('Native alarm launch failed: $e', name: 'NotificationService');
        final nav = NavigationService.navigatorKey.currentState;
        if (nav != null) {
          nav.push(MaterialPageRoute(builder: (_) => AlarmFullscreen(title: title, body: body, allowContinueTracking: allowContinueTracking)));
        }
      }

      // Start ringtone playback via AlarmPlayer
      try { await AlarmPlayer.playSelected(); } catch (e) { dev.log('Failed to play alarm sound: $e', name: 'NotificationService'); }

    } catch (e) {
      dev.log('Failed to show alarm notification: $e', name: 'NotificationService');
    }
  }

  // Ongoing journey progress notification (non-dismissible)
  Future<void> showJourneyProgress({ required String title, required String subtitle, required double progress0to1 }) async {
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'geowake_tracking_channel_v2', 'GeoWake Tracking',
      channelDescription: 'Ongoing tracking status',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: 1000,
      progress: (progress0to1.clamp(0.0, 1.0) * 1000).round(),
      onlyAlertOnce: true,
      visibility: NotificationVisibility.public,
    );
    final NotificationDetails details = NotificationDetails(android: androidDetails);
    try {
      dev.log('Updating progress notification', name: 'NotificationService');
      await _notificationsPlugin.show(
        _progressNotificationId,
        title,
        subtitle,
        details,
      );
    } catch (e) {
      dev.log('Failed to show progress notification: $e', name: 'NotificationService');
    }
  }

  Future<void> cancelJourneyProgress() async { if (isTestMode) return; await _notificationsPlugin.cancel(_progressNotificationId); }

  // Bring back the alarm UI if app is opened/resumed after an alarm was shown
  Future<void> showPendingAlarmScreenIfAny() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final has = prefs.getBool('pending_alarm_flag') ?? false;
      if (!has) return;
      final title = prefs.getString('pending_alarm_title') ?? 'Wake Up!';
      final body = prefs.getString('pending_alarm_body') ?? 'Approaching your target';
      final allow = prefs.getBool('pending_alarm_allow') ?? true;
      await prefs.remove('pending_alarm_flag');
      await prefs.remove('pending_alarm_title');
      await prefs.remove('pending_alarm_body');
      await prefs.remove('pending_alarm_allow');
      final nav = NavigationService.navigatorKey.currentState;
      if (nav != null) {
        nav.push(MaterialPageRoute(builder: (_) => AlarmFullscreen(title: title, body: body, allowContinueTracking: allow)));
      }
    } catch (e) {
      dev.log('Failed to present pending alarm screen: $e', name: 'NotificationService');
    }
  }
}

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  try { WidgetsFlutterBinding.ensureInitialized(); } catch (_) {}
  dev.log('BG notification response: actionId=${response.actionId}, payload=${response.payload}', name: 'NotificationService');
  if (response.actionId == 'STOP_ALARM') {
    try { await AlarmPlayer.stop(); } catch (_) {}
    try { FlutterBackgroundService().invoke('stopAlarm'); } catch (_) {}
    return;
  }
  if (response.actionId == 'END_TRACKING') {
    try { await AlarmPlayer.stop(); } catch (_) {}
    try { await TrackingService().stopTracking(); } catch (_) {}
    return;
  }
}
