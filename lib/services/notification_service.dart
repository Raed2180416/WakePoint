// lib/services/notification_service.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';  // For MethodChannel
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geowake2/services/navigation_service.dart';
import 'package:geowake2/screens/alarm_fullscreen.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'dart:typed_data';
import 'dart:developer' as dev;

class NotificationService {
  // Singleton pattern to ensure only one instance of this service
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Allows tests to disable platform/plugin calls.
  static bool isTestMode = false;
  // Optional hook for tests to observe alarms without invoking plugins.
  // Signature: (title, body, allowContinueTracking)
  static Future<void> Function(String, String, bool)? testOnShowWakeUpAlarm;
  // Recorded alarm events for assertions in tests (title/body/allow)
  static final List<Map<String, dynamic>> testRecordedAlarms = [];

  static void clearTestRecordedAlarms() => testRecordedAlarms.clear();

  // Method channel to communicate with native Android code
  static const _alarmMethodChannel = MethodChannel('com.example.geowake2/alarm');

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  static const int _alarmNotificationId = 0;
  static const int _progressNotificationId = 888;
  
  // Native method to directly launch the AlarmActivity
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
  
  // Stop native vibration
  Future<void> stopVibration() async {
    try {
      await _alarmMethodChannel.invokeMethod('stopVibration');
    } catch (e) {
      dev.log('Failed to stop vibration: $e', name: 'NotificationService');
    }
  }

  // Public helper to cancel active alarm: stop sound, vibration, and clear notification
  Future<void> cancelAlarm() async {
    try { await AlarmPlayer.stop(); } catch (e) {
      dev.log('AlarmPlayer.stop failed: $e', name: 'NotificationService');
    }
    try { await stopVibration(); } catch (_) {}
    try { await _notificationsPlugin.cancel(_alarmNotificationId); } catch (e) {
      dev.log('Cancel alarm notification failed: $e', name: 'NotificationService');
    }
  }

  // Initialize the notification service
  Future<void> initialize() async {
    dev.log('NotificationService.initialize() start', name: 'NotificationService');
    // Settings for Android initialization
    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    
    // Settings for iOS initialization
    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings();

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

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
          if (parts.length > 1) {
            allow = parts[1] == '1';
          }
          final nav = NavigationService.navigatorKey.currentState;
          if (nav != null) {
            nav.push(MaterialPageRoute(
              builder: (_) => AlarmFullscreen(
                title: 'Wake Up!',
                body: 'Approaching your target',
                allowContinueTracking: allow,
              ),
            ));
          }
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    // Explicitly request Android notification permission (Android 13+)
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();
    } catch (e) {
      dev.log('Android notification permission request failed: $e', name: 'NotificationService');
    }

    // Create/ensure channels exist (alarm + tracking + bg service channel used by flutter_background_service)
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        await androidImpl.createNotificationChannel(const AndroidNotificationChannel(
          'geowake_alarm_channel_v2',
          'GeoWake Alarms',
          description: 'Channel for GeoWake wake-up alarms',
          importance: Importance.max,
        ));
        await androidImpl.createNotificationChannel(const AndroidNotificationChannel(
          'geowake_tracking_channel_v2',
          'GeoWake Tracking',
          description: 'Ongoing tracking status',
          importance: Importance.defaultImportance,
        ));
        // Also ensure legacy/background service channel exists as configured in TrackingService
        await androidImpl.createNotificationChannel(const AndroidNotificationChannel(
          'geowake_tracking_channel',
          'GeoWake Tracking (Service)',
          description: 'Foreground service notifications',
          importance: Importance.defaultImportance,
        ));
      }
    } catch (e) {
      dev.log('Creating notification channels failed: $e', name: 'NotificationService');
    }

    dev.log('NotificationService.initialize() done', name: 'NotificationService');
  }

  // This is the main function to trigger the alarm
  Future<void> showWakeUpAlarm({
    required String title,
    required String body,
    bool allowContinueTracking = true,
  }) async {
    // Test-mode observability: always record, and call optional hook when present
    if (isTestMode || testOnShowWakeUpAlarm != null) {
      if (testOnShowWakeUpAlarm != null) {
        try { await testOnShowWakeUpAlarm!(title, body, allowContinueTracking); } catch (_) {}
      }
      try {
        testRecordedAlarms.add({
          'title': title,
          'body': body,
          'allow': allowContinueTracking,
          'ts': DateTime.now().toIso8601String(),
        });
      } catch (_) {}
    }

    // If tests explicitly disabled platform behavior, skip showing.
    if (isTestMode) {
      return;
    }
    dev.log('ALARM TRIGGER: Showing wake-up alarm with title: "$title", body: "$body"', name: 'NotificationService');
    
    // 1. Store alarm info in SharedPreferences to recover if needed
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pending_alarm_flag', true);
    await prefs.setString('pending_alarm_title', title);
    await prefs.setString('pending_alarm_body', body);
    await prefs.setBool('pending_alarm_allow', allowContinueTracking);

    // 2. Create high-priority alarm notification channel with vibration pattern
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        // A strong vibration pattern for alarm-like feel
        // Format: [delay, vibrate, sleep, vibrate, sleep, ...]
        // Enhanced vibration pattern that more closely matches Android's native alarm pattern
      // This includes varying vibration durations to create a more attention-grabbing pattern
      final vibrationPattern = Int64List.fromList([0, 500, 250, 500, 250, 1000, 500]);
        
        await androidImpl.createNotificationChannel(AndroidNotificationChannel(
          'geowake_alarm_channel_v3',
          'GeoWake Alarms (High Priority)',
          description: 'Channel for urgent GeoWake wake-up alarms',
          importance: Importance.max,
          enableVibration: true,
          vibrationPattern: vibrationPattern,
          playSound: false, // We'll use our AlarmPlayer instead
        ));
        
        // Request permission to show notifications on Android 13+
        try {
          await androidImpl.requestNotificationsPermission();
        } catch (e) {
          dev.log('Failed to request notification permission: $e', name: 'NotificationService');
        }
      }
    } catch (e) {
      dev.log('Failed to create/update alarm channel: $e', name: 'NotificationService');
    }

    // 3. Define the Android notification details, including vibration pattern
    // Enhanced vibration pattern that more closely matches Android's native alarm pattern
    // This includes varying vibration durations to create a more attention-grabbing pattern
    final vibrationPattern = Int64List.fromList([0, 500, 250, 500, 250, 1000, 500]);
    
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'geowake_alarm_channel_v3',
      'GeoWake Alarms (High Priority)',
      channelDescription: 'Channel for GeoWake wake-up alarms',
      importance: Importance.max,
      priority: Priority.max,
      playSound: false, // Use AlarmPlayer for the custom sound
      fullScreenIntent: true,  // This is critical for lockscreen appearance
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.alarm,
      ongoing: true, // Make it ongoing so it can't be dismissed
      autoCancel: false,
      enableVibration: true,
      vibrationPattern: vibrationPattern,
      ticker: 'Destination alarm active',
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction('STOP_ALARM', 'Stop Alarm', showsUserInterface: false),
        AndroidNotificationAction('END_TRACKING', 'End Tracking', showsUserInterface: true),
      ],
    );

    // Define iOS notification details (sound name should be included in the app bundle)
    final DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentSound: false,
    );

    // Full-screen intent to bring app UI to foreground (lockscreen included).
    final details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    // 3. Show the notification and trigger alarm UI, sound, and vibration
    try {
      dev.log('Showing alarm notification with fullScreenIntent: "$title" - "$body"', name: 'NotificationService');
      
      // First show the notification
      await _notificationsPlugin.show(
        _alarmNotificationId,
        title,
        body,
        details,
        payload: 'open_alarm:${allowContinueTracking ? '1' : '0'}',
      );
      
      // Also directly launch the AlarmActivity via our native method channel
      try {
        await _launchNativeAlarmActivity(
          title: title,
          body: body,
          allowContinueTracking: allowContinueTracking,
        );
      } catch (e) {
        dev.log('Failed to launch native AlarmActivity: $e', name: 'NotificationService');
        
        // Fallback: Present the UI directly if we're in the foreground
        final nav = NavigationService.navigatorKey.currentState;
        if (nav != null) {
          dev.log('Fallback: presenting AlarmFullscreen UI directly', name: 'NotificationService');
          nav.push(MaterialPageRoute(
            builder: (_) => AlarmFullscreen(
              title: title,
              body: body,
              allowContinueTracking: allowContinueTracking,
            ),
          ));
        }
      }
      
      // Start playing the ringtone
      try {
        await AlarmPlayer.playSelected();
      } catch (e) {
        dev.log('Failed to play alarm sound: $e', name: 'NotificationService');
      }
      
    } catch (e) {
      dev.log('Failed to show alarm notification: $e', name: 'NotificationService');
    }
  }

  // Ongoing journey progress notification (non-dismissible)
  Future<void> showJourneyProgress({
    required String title,
    required String subtitle,
    required double progress0to1,
  }) async {
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'geowake_tracking_channel_v2',
      'GeoWake Tracking',
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
      dev.log('Updating progress notification: progress=${(progress0to1 * 100).toStringAsFixed(1)}%', name: 'NotificationService');
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

  Future<void> cancelJourneyProgress() async {
    if (isTestMode) return;
    await _notificationsPlugin.cancel(_progressNotificationId);
  }

  // When app comes to foreground via full-screen intent, ensure the alarm screen shows
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
        nav.push(MaterialPageRoute(
          builder: (_) => AlarmFullscreen(title: title, body: body, allowContinueTracking: allow),
        ));
      }
    } catch (e) {
      dev.log('Failed to present pending alarm screen: $e', name: 'NotificationService');
    }
  }
}

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
  } catch (_) {}
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