// Annotated copy of lib/services/notification_service.dart
// Purpose: Explain alarm and progress notifications, test-mode hooks, and full-screen intents.

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geowake2/services/navigation_service.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:meta/meta.dart';
import 'dart:typed_data';
import 'dart:developer' as dev;

enum NotificationActionOutcome {
  muteJourney,
  cancelAlarm,
  resumeTracking,
  endTracking,
  stopAlarm,
  dismissAlarm,
  none,
}

class NotificationService {
  @visibleForTesting
  static NotificationActionOutcome classifyAction(
    String? actionId,
    String? payload,
  ) {
    if (actionId == null || actionId.isEmpty) {
      return NotificationActionOutcome.none;
    }

    switch (actionId) {
      case 'IGNORE':
        if (payload != null && payload.startsWith('journey')) {
          return NotificationActionOutcome.muteJourney;
        }
        return NotificationActionOutcome.cancelAlarm;
      case 'RESUME_TRACKING':
        return NotificationActionOutcome.resumeTracking;
      case 'END_TRACKING':
        return NotificationActionOutcome.endTracking;
      case 'STOP_ALARM':
        return NotificationActionOutcome.stopAlarm;
      case 'DISMISS_ALARM':
        return NotificationActionOutcome.dismissAlarm;
      default:
        return NotificationActionOutcome.none;
    }
  }

  Future<void> handleNotificationResponse(
    NotificationResponse response, {
    bool allowNavigation = true,
  }) async {
    // If user tapped the notification itself (no action ID)
    if (response.actionId == null && allowNavigation) {
      // Navigate to MapTrackingScreen
      final nav = NavigationService.navigatorKey.currentState;
      if (nav != null) {
        nav.pushNamedAndRemoveUntil('/mapTracking', (route) => false);
      }
      return;
    }

    await _handleNotificationAction(
      actionId: response.actionId,
      payload: response.payload,
      allowNavigation: allowNavigation,
    );
  }

  Future<void> _handleNotificationAction({
    required String? actionId,
    required String? payload,
    required bool allowNavigation,
  }) async {
    final outcome = NotificationService.classifyAction(actionId, payload);
    switch (outcome) {
      case NotificationActionOutcome.muteJourney:
        dev.log(
          'GW_NOTIF_ACTION_IGNORE_JOURNEY: user muted journey notification',
          name: 'NotificationService',
        );
        await TrackingService().muteJourneyNotifications();
        return;
      case NotificationActionOutcome.cancelAlarm:
        dev.log(
          'GW_NOTIF_ACTION_IGNORE_ALARM: user silenced alarm without ending tracking',
          name: 'NotificationService',
        );
        await cancelAlarm();
        return;
      case NotificationActionOutcome.resumeTracking:
        dev.log(
          'GW_NOTIF_ACTION_RESUME: User tapped Resume Tracking',
          name: 'NotificationService',
        );
        await TrackingService().resumeFromNotification();
        return;
      case NotificationActionOutcome.endTracking:
        dev.log(
          'GW_NOTIF_ACTION_END: User tapped End Tracking',
          name: 'NotificationService',
        );
        // This stops everything
        await TrackingService().completeEndTracking();
        return;
      case NotificationActionOutcome.stopAlarm:
        dev.log(
          'GW_NOTIF_ACTION_STOP_ALARM: User tapped Stop Alarm button',
          name: 'NotificationService',
        );
        // This stops only the alarm, tracking continues
        await cancelAlarm();
        return;
      case NotificationActionOutcome.dismissAlarm:
        dev.log(
          'GW_NOTIF_ACTION_DISMISS: User dismissed final alarm',
          name: 'NotificationService',
        );
        await cancelAlarm();
        return;
      case NotificationActionOutcome.none:
        dev.log(
          'GW_NOTIF_ACTION_NOOP: No handler for action=$actionId payload=$payload',
          name: 'NotificationService',
        );
        return;
    }
  }

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

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  static const int _alarmNotificationId = 0;
  static const int _progressNotificationId = 888;

  // Flag to prevent duplicate alarm overlays
  bool _alarmCurrentlyShowing = false;

  // Stop native vibration (No-op now as we rely on notification cancellation)
  Future<void> stopVibration() async {
    // Intentionally empty as we rely on cancelling the notification to stop vibration
  }

  // Public helper to cancel active alarm: stop sound, vibration, and clear notification
  Future<void> cancelAlarm() async {
    _alarmCurrentlyShowing = false;
    try {
      await AlarmPlayer.stop();
    } catch (e) {
      dev.log('AlarmPlayer.stop failed: $e', name: 'NotificationService');
    }

    try {
      await _notificationsPlugin.cancel(_alarmNotificationId);
    } catch (e) {
      dev.log(
        'Cancel alarm notification failed: $e',
        name: 'NotificationService',
      );
    }
  }

  // Initialize the notification service
  Future<void> initialize() async {
    dev.log(
      'NotificationService.initialize() start',
      name: 'NotificationService',
    );
    // Settings for Android initialization
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // Settings for iOS initialization
    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings();

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notificationsPlugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) async {
        dev.log(
          'Notification response: actionId=${response.actionId}, payload=${response.payload}',
          name: 'NotificationService',
        );

        await handleNotificationResponse(response);
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    // Explicitly request Android notification permission (Android 13+)
    try {
      final androidImpl =
          _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();
      await androidImpl?.requestNotificationsPermission();
    } catch (e) {
      dev.log(
        'Android notification permission request failed: $e',
        name: 'NotificationService',
      );
    }

    // Create/ensure channels exist (alarm + tracking + bg service channel used by flutter_background_service)
    try {
      final androidImpl =
          _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();
      if (androidImpl != null) {
        // Enhanced vibration pattern
        final vibrationPattern = Int64List.fromList([
          0,
          500,
          250,
          500,
          250,
          1000,
          500,
        ]);

        await androidImpl.createNotificationChannel(
          AndroidNotificationChannel(
            'geowake_alarm_channel_v3',
            'GeoWake Alarms (High Priority)',
            description: 'Channel for urgent GeoWake wake-up alarms',
            importance: Importance.max,
            enableVibration: true,
            vibrationPattern: vibrationPattern,
            playSound: false, // We'll use our AlarmPlayer instead
          ),
        );
        await androidImpl.createNotificationChannel(
          const AndroidNotificationChannel(
            'geowake_tracking_channel_v2',
            'GeoWake Tracking',
            description: 'Ongoing tracking status',
            importance: Importance.defaultImportance,
          ),
        );
        // Also ensure legacy/background service channel exists as configured in TrackingService
        await androidImpl.createNotificationChannel(
          const AndroidNotificationChannel(
            'geowake_tracking_channel',
            'GeoWake Tracking (Service)',
            description: 'Foreground service notifications',
            importance: Importance.defaultImportance,
          ),
        );
      }
    } catch (e) {
      dev.log(
        'Creating notification channels failed: $e',
        name: 'NotificationService',
      );
    }

    dev.log(
      'NotificationService.initialize() done',
      name: 'NotificationService',
    );
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
        try {
          await testOnShowWakeUpAlarm!(title, body, allowContinueTracking);
        } catch (_) {}
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
    dev.log(
      'ALARM TRIGGER: Showing wake-up alarm with title: "$title", body: "$body"',
      name: 'NotificationService',
    );

    // Prevent duplicate overlays
    if (_alarmCurrentlyShowing) {
      dev.log(
        'Alarm already showing, skipping duplicate trigger',
        name: 'NotificationService',
      );
      return;
    }
    _alarmCurrentlyShowing = true;

    // 1. Store alarm info in SharedPreferences to recover if needed
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pending_alarm_flag', true);
    await prefs.setString('pending_alarm_title', title);
    await prefs.setString('pending_alarm_body', body);
    await prefs.setBool('pending_alarm_allow', allowContinueTracking);

    // 2. Define the Android notification details
    final vibrationPattern = Int64List.fromList([
      0,
      500,
      250,
      500,
      250,
      1000,
      500,
    ]);

    final AndroidNotificationDetails
    androidDetails = AndroidNotificationDetails(
      'geowake_alarm_channel_v3',
      'GeoWake Alarms (High Priority)',
      channelDescription: 'Channel for GeoWake wake-up alarms',
      importance: Importance.max,
      priority: Priority.max,
      playSound: false, // Use AlarmPlayer for the custom sound
      fullScreenIntent: true, // This is critical for lockscreen appearance
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.alarm,
      ongoing: true, // Make it ongoing so it can't be dismissed
      autoCancel: false,
      enableVibration: true,
      vibrationPattern: vibrationPattern,
      // FLAG_INSISTENT = 4. Makes the notification audio/vibration loop until cancelled.
      additionalFlags: Int32List.fromList([4]),
      ticker: 'Destination alarm active',
      actions:
          allowContinueTracking
              ? <AndroidNotificationAction>[
                AndroidNotificationAction(
                  'STOP_ALARM',
                  'Stop Alarm',
                  showsUserInterface: false,
                ),
                AndroidNotificationAction(
                  'END_TRACKING',
                  'End Tracking',
                  showsUserInterface: true,
                ),
              ]
              : <AndroidNotificationAction>[
                AndroidNotificationAction(
                  'END_TRACKING',
                  'End Tracking',
                  showsUserInterface: true,
                ),
              ],
    );

    // Define iOS notification details (sound name should be included in the app bundle)
    final DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentSound: false,
    );

    // Full-screen intent to bring app UI to foreground (lockscreen included).
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // 3. Show the notification and trigger alarm sound
    try {
      dev.log(
        'Showing alarm notification with fullScreenIntent: "$title" - "$body"',
        name: 'NotificationService',
      );

      // First show the notification
      await _notificationsPlugin.show(
        _alarmNotificationId,
        title,
        body,
        details,
        payload: 'open_alarm:${allowContinueTracking ? '1' : '0'}',
      );

      // Start playing the ringtone
      try {
        await AlarmPlayer.playSelected();
      } catch (e) {
        dev.log('Failed to play alarm sound: $e', name: 'NotificationService');
      }
    } catch (e) {
      dev.log(
        'Failed to show alarm notification: $e',
        name: 'NotificationService',
      );
    }
  }

  // Ongoing journey progress notification with dynamic buttons
  Future<void> showJourneyProgress({
    required String title,
    required String subtitle,
    required double progress0to1,
    bool isTracking = true,
  }) async {
    if (isTracking) {
      final muted = await TrackingStateStore.notificationsMuted();
      if (muted) {
        dev.log(
          'Journey notification muted by user; skipping update.',
          name: 'NotificationService',
        );
        return;
      }
    }

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'geowake_tracking_channel_v2',
          'GeoWake Tracking',
          channelDescription: 'Ongoing tracking status',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ongoing: isTracking,
          autoCancel: false,
          showProgress: true,
          maxProgress: 1000,
          progress: (progress0to1.clamp(0.0, 1.0) * 1000).round(),
          onlyAlertOnce: true,
          visibility: NotificationVisibility.public,
          actions:
              isTracking
                  ? <AndroidNotificationAction>[
                    AndroidNotificationAction(
                      'IGNORE',
                      'Ignore',
                      showsUserInterface: false,
                    ),
                    AndroidNotificationAction(
                      'END_TRACKING',
                      'End Tracking',
                      showsUserInterface: true,
                    ),
                  ]
                  : <AndroidNotificationAction>[
                    AndroidNotificationAction(
                      'IGNORE',
                      'Ignore',
                      showsUserInterface: false,
                    ),
                    AndroidNotificationAction(
                      'RESUME_TRACKING',
                      'Resume Tracking',
                      showsUserInterface: true,
                    ),
                  ],
        );
    final NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );
    try {
      dev.log(
        'Updating progress notification: progress=${(progress0to1 * 100).toStringAsFixed(1)}%, isTracking=$isTracking',
        name: 'NotificationService',
      );
      await _notificationsPlugin.show(
        _progressNotificationId,
        title,
        subtitle,
        details,
        payload: isTracking ? 'journey_active' : 'journey_paused',
      );
      await TrackingStateStore.saveProgressPayload(
        TrackingProgressPayload(
          title: title,
          subtitle: subtitle,
          progress: progress0to1,
          isTracking: isTracking,
        ),
      );
    } catch (e) {
      dev.log(
        'Failed to show progress notification: $e',
        name: 'NotificationService',
      );
    }
  }

  Future<void> cancelJourneyProgress() async {
    if (isTestMode) return;
    await _notificationsPlugin.cancel(_progressNotificationId);
    await TrackingStateStore.clearProgressPayload();
  }

  /// Cancel all notifications (journey progress + alarm)
  Future<void> cancelAllNotifications() async {
    if (isTestMode) return;
    _alarmCurrentlyShowing = false;

    try {
      await _notificationsPlugin.cancel(_alarmNotificationId);
      await _notificationsPlugin.cancel(_progressNotificationId);
      await TrackingStateStore.clearProgressPayload();
      dev.log('All notifications cancelled', name: 'NotificationService');
    } catch (e) {
      dev.log(
        'Error cancelling all notifications: $e',
        name: 'NotificationService',
      );
    }
  }
}

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
  } catch (_) {}
  dev.log(
    'BG notification response: actionId=${response.actionId}, payload=${response.payload}',
    name: 'NotificationService',
  );

  await NotificationService().handleNotificationResponse(
    response,
    allowNavigation: false,
  );
}
