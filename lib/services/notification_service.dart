// lib/services/notification_service.dart

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geowake2/services/navigation_service.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/alarm_haptics.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:vibration/vibration.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:wakepoint_native/wakepoint_native.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:developer' as dev;
import 'dart:io';

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
  static const String _stopAlarmRequestKey = 'gw_stop_alarm_request_v1';
  static const String _endTrackingRequestKey = 'gw_end_tracking_request_v1';
  static const String _muteJourneyRequestKey = 'gw_mute_journey_request_v1';

  // File-based flags for reliable cross-isolate communication
  static const String _stopAlarmFileName = '.gw_stop_alarm_flag';
  static const String _endTrackingFileName = '.gw_end_tracking_flag';
  static const String _muteJourneyFileName = '.gw_mute_journey_flag';

  static Future<String?> _getFlagDir() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    } catch (_) {
      return null;
    }
  }

  // File-based flag write - more reliable across isolates than SharedPreferences
  static Future<void> _writeFlag(String fileName) async {
    try {
      final dirPath = await _getFlagDir();
      if (dirPath == null) return;
      final file = File('$dirPath/$fileName');
      await file.writeAsString(DateTime.now().toIso8601String());
    } catch (e) {
      dev.log(
        'Failed to write flag $fileName: $e',
        name: 'NotificationService',
      );
    }
  }

  // File-based flag read and delete - atomic check-and-consume
  static Future<bool> _consumeFlag(String fileName) async {
    try {
      final dirPath = await _getFlagDir();
      if (dirPath == null) return false;
      final file = File('$dirPath/$fileName');
      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      dev.log(
        'Failed to consume flag $fileName: $e',
        name: 'NotificationService',
      );
      return false;
    }
  }

  static Future<void> requestStopAlarmForService() async {
    // Write file-based flag first (most reliable)
    await _writeFlag(_stopAlarmFileName);
    // Also set SharedPreferences as backup
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_stopAlarmRequestKey, true);
      await prefs.setInt(
        '${_stopAlarmRequestKey}_ts',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  static Future<void> requestEndTrackingForService() async {
    // Write file-based flag first (most reliable)
    await _writeFlag(_endTrackingFileName);
    // Also set SharedPreferences as backup
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_endTrackingRequestKey, true);
      await prefs.setInt(
        '${_endTrackingRequestKey}_ts',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  static Future<void> requestMuteJourneyForService() async {
    // Write file-based flag first (most reliable)
    await _writeFlag(_muteJourneyFileName);
    // Also set SharedPreferences as backup
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_muteJourneyRequestKey, true);
      await prefs.setInt(
        '${_muteJourneyRequestKey}_ts',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  static Future<bool> consumeStopAlarmRequest() async {
    // Check file-based flag first (most reliable)
    final fileFlag = await _consumeFlag(_stopAlarmFileName);
    if (fileFlag) return true;
    // Fallback to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // Ensure freshness across isolates
      final v = prefs.getBool(_stopAlarmRequestKey) ?? false;
      if (!v) return false;
      await prefs.remove(_stopAlarmRequestKey);
      await prefs.remove('${_stopAlarmRequestKey}_ts');
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> consumeEndTrackingRequest() async {
    // Check file-based flag first (most reliable)
    final fileFlag = await _consumeFlag(_endTrackingFileName);
    if (fileFlag) return true;
    // Fallback to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // Ensure freshness across isolates
      final v = prefs.getBool(_endTrackingRequestKey) ?? false;
      if (!v) return false;
      await prefs.remove(_endTrackingRequestKey);
      await prefs.remove('${_endTrackingRequestKey}_ts');
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> consumeMuteJourneyRequest() async {
    // Check file-based flag first (most reliable)
    final fileFlag = await _consumeFlag(_muteJourneyFileName);
    if (fileFlag) return true;
    // Fallback to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // Ensure freshness across isolates
      final v = prefs.getBool(_muteJourneyRequestKey) ?? false;
      if (!v) return false;
      await prefs.remove(_muteJourneyRequestKey);
      await prefs.remove('${_muteJourneyRequestKey}_ts');
      return true;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static NotificationActionOutcome classifyAction(
    String? actionId,
    String? payload,
  ) {
    if (actionId == null || actionId.isEmpty) {
      return NotificationActionOutcome.none;
    }

    dev.log(
      'Classifying action: $actionId, payload: $payload',
      name: 'NotificationService',
    );

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
    if ((response.actionId == null || response.actionId!.isEmpty) &&
        allowNavigation) {
      // If tracking is paused, tapping the notification should resume.
      if (response.payload == 'tracking_paused' ||
          response.payload == 'journey_paused') {
        try {
          if (!TrackingService.isTestMode) {
            await TrackingService().resumeFromNotification();
          }
        } catch (_) {}
      }

      final nav = NavigationService.navigatorKey.currentState;
      if (nav != null) {
        await _navigateToMapTrackingWithArgs(nav);
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
        await cancelJourneyProgress();
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
        if (allowNavigation) {
          try {
            final nav = NavigationService.navigatorKey.currentState;
            if (nav != null) {
              await _navigateToMapTrackingWithArgs(nav);
            }
          } catch (_) {}
        }
        return;
      case NotificationActionOutcome.endTracking:
        dev.log(
          'GW_NOTIF_ACTION_END: User tapped End Tracking',
          name: 'NotificationService',
        );
        // Ensure the running background service isolate receives the stop.
        try {
          FlutterBackgroundService().invoke('stopTracking', {'stopSelf': true});
        } catch (_) {}

        await cancelTrackingPaused();
        await TrackingService().completeEndTracking();
        return;
      case NotificationActionOutcome.stopAlarm:
        dev.log(
          'GW_NOTIF_ACTION_STOP_ALARM: User tapped Stop Alarm button',
          name: 'NotificationService',
        );
        // Stops only the alarm, tracking continues
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

  Future<void> _navigateToMapTrackingWithArgs(NavigatorState nav) async {
    try {
      // In test mode, skip the platform-channel snapshot load (path_provider /
      // SharedPreferences) — with no mock its Future never resolves and would
      // hang the caller (this method is awaited by handleNotificationResponse).
      // Navigation itself is fire-and-forget (pushNamedAndRemoveUntil is not
      // awaited), so tests still land on /mapTracking deterministically.
      final snapshot = NotificationService.isTestMode
          ? null
          : await TrackingStateStore.loadSnapshot();
      if (snapshot != null) {
        nav.pushNamedAndRemoveUntil(
          '/mapTracking',
          (route) => false,
          arguments: {
            'lat': snapshot.destinationLat,
            'lng': snapshot.destinationLng,
            'destination': snapshot.destinationName,
            'directions': snapshot.directions,
            'metroMode': snapshot.metroMode,
            'mode': snapshot.alarmMode,
            'userLat': snapshot.userLat,
            'userLng': snapshot.userLng,
          },
        );
      } else {
        // Fallback if no snapshot
        nav.pushNamedAndRemoveUntil('/mapTracking', (route) => false);
      }
    } catch (e) {
      dev.log(
        'Error navigating to map tracking: $e',
        name: 'NotificationService',
      );
      // Fallback on error
      nav.pushNamedAndRemoveUntil('/mapTracking', (route) => false);
    }
  }

  // Singleton pattern to ensure only one instance of this service
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Android 16+ can still allow dismissal of some ongoing notifications.
  // To enforce "persist until a button is clicked", we periodically re-post
  // critical notifications (alarm / paused) while the underlying state says
  // they should be visible.
  static DateTime? _lastEnsureAlarmNotifAt;
  static DateTime? _lastEnsurePausedNotifAt;

  // Allows tests to disable platform/plugin calls.
  static bool isTestMode = false;
  // Optional hook for tests to observe alarms without invoking plugins.
  // Signature: (title, body, allowContinueTracking)
  static Future<void> Function(String, String, bool)? testOnShowWakeUpAlarm;
  // Recorded alarm events for assertions in tests (title/body/allow)
  static final List<Map<String, dynamic>> testRecordedAlarms = [];

  // Optional hooks for unit tests to observe notification behavior without
  // requiring platform channels.
  @visibleForTesting
  static Future<void> Function(
    int id,
    String? title,
    String? body,
    String? payload,
  )?
  testOnShowNotification;

  @visibleForTesting
  static Future<void> Function(int id)? testOnCancelNotification;

  @visibleForTesting
  static final List<Map<String, dynamic>> testRecordedNotifications = [];

  @visibleForTesting
  static final List<int> testRecordedCancels = [];

  static void clearTestRecordedAlarms() => testRecordedAlarms.clear();

  static void clearTestRecordedNotifications() {
    testRecordedNotifications.clear();
    testRecordedCancels.clear();
  }

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  static const int _alarmNotificationId = 0;
  static const int _progressNotificationId = 888;
  static const int _pausedNotificationId = 889;

  // Flag to prevent duplicate alarm overlays
  bool _alarmCurrentlyShowing = false;

  bool _alarmVibrationLoopActive = false;
  Timer? _alarmVibrationResyncTimer;

  // G25: escalating (increasing on-duration) waveform for the vibration-plugin
  // FALLBACK path. The native path (AlarmHaptics -> MainActivity) drives its own
  // amplitude-escalating alarm waveform; this list only shapes the fallback used
  // when the native channel is unavailable. Timings only (no amplitudes) here.
  static const List<int> _alarmVibrationPattern = <int>[
    0,
    400,
    200,
    700,
    200,
    1000,
    300,
    1400,
    400,
  ];

  // Pattern duration = 4.6s (excluding the leading 0 delay). Keep in sync with
  // the pattern above so the fallback resync timer re-arms on each cycle.
  static const Duration _alarmVibrationPatternPeriod = Duration(
    milliseconds: 4600,
  );

  Future<void> _clearPendingAlarmPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pending_alarm_flag');
      await prefs.remove('pending_alarm_title');
      await prefs.remove('pending_alarm_body');
      await prefs.remove('pending_alarm_allow');
    } catch (_) {}
  }

  Future<void> _startAlarmVibrationLoop() async {
    if (_alarmVibrationLoopActive) return;
    _alarmVibrationLoopActive = true;

    try {
      // Prefer AlarmHaptics (native Android vibration attributes) for consistent
      // alarm-like vibration behavior across Android versions.
      await AlarmHaptics.start(pattern: _alarmVibrationPattern);

      // Only enable the periodic resync when we are *not* using the native
      // Android implementation. The native path uses a repeating waveform
      // (repeatIndex=0) and should run continuously until cancelled.
      if (!AlarmHaptics.isUsingNativeForAndroid) {
        _alarmVibrationResyncTimer?.cancel();
        _alarmVibrationResyncTimer = Timer.periodic(
          _alarmVibrationPatternPeriod,
          (_) {
            if (!_alarmVibrationLoopActive) return;
            // Fire-and-forget; best effort.
            () async {
              try {
                await AlarmHaptics.start(pattern: _alarmVibrationPattern);
              } catch (_) {}
            }();
          },
        );
      }
    } catch (e) {
      // MissingPluginException / platform limitations.
      _alarmVibrationLoopActive = false;
      dev.log(
        'Alarm vibration loop failed to start: $e',
        name: 'NotificationService',
      );
    }
  }

  Future<void> _stopAlarmVibrationLoop() async {
    _alarmVibrationLoopActive = false;
    _alarmVibrationResyncTimer?.cancel();
    _alarmVibrationResyncTimer = null;
    try {
      await AlarmHaptics.stop();
    } catch (_) {
      // Ignore: plugin might not be available in unit tests.
    }
  }

  Future<void> stopVibration() async {
    await _stopAlarmVibrationLoop();
    // Break the loop: specific method for stopping vibration/notification only
    await _cancelAlarmNotificationOnly();
    try {
      await TrackingStateStore.setAlarmFired(false);
    } catch (_) {}
    await _clearPendingAlarmPrefs();
    await restoreJourneyProgressIfActive();
  }

  Future<void> restoreJourneyProgressIfActive() async {
    try {
      final active = await TrackingStateStore.isActive();
      if (!active) return;
      final paused = await TrackingStateStore.isPaused();
      if (paused) return;
      if (await TrackingStateStore.notificationsMuted()) return;

      final payload = await TrackingStateStore.loadProgressPayload();
      if (payload != null && payload.isTracking) {
        await showJourneyProgress(
          title: payload.title,
          subtitle: payload.subtitle,
          progress0to1: payload.progress,
          isTracking: true,
        );
      }
    } catch (_) {}
  }

  // Internal helper to just kill the notification overlay
  Future<void> _cancelAlarmNotificationOnly() async {
    _alarmCurrentlyShowing = false;
    try {
      await _notificationsPlugin.cancel(_alarmNotificationId);
    } catch (e) {
      dev.log(
        'Cancel alarm notification failed: $e',
        name: 'NotificationService',
      );
    }
  }

  // Public helper to cancel active alarm: stop sound, vibration, and clear notification
  Future<void> cancelAlarm({bool restoreJourney = true}) async {
    await _stopAlarmVibrationLoop();

    // NOTE: Removed FlutterBackgroundService().invoke('stopAlarm') here because:
    // 1. cancelAlarm() is called FROM the stopAlarm service handler - circular call
    // 2. cancelAlarm() is called FROM the poll timer - no need to re-invoke
    // The background notification callback already invokes stopAlarm if needed.

    // 1. Stop audio (this internally calls stopVibration -> _cancelAlarmNotificationOnly)
    try {
      await AlarmPlayer.stop();
    } catch (e) {
      dev.log('AlarmPlayer.stop failed: $e', name: 'NotificationService');
    }
    // 2. Ensure notification is gone (redundant safety)
    await _cancelAlarmNotificationOnly();
    // Also clear the OS backstop (id 991): after a process-death cold start it
    // is the thing ringing (FLAG_INSISTENT), and it is NOT covered by
    // _alarmNotificationId — without this, dismissing the alarm leaves the
    // backstop looping with no way to silence it (ongoing + no-clear).
    await cancelEtaBackstop();

    try {
      await TrackingStateStore.setAlarmFired(false);
    } catch (_) {}
    await _clearPendingAlarmPrefs();
    if (restoreJourney) {
      await restoreJourneyProgressIfActive();
    }
  }

  // Initialize the notification service
  Future<void> initialize() async {
    dev.log(
      'NotificationService.initialize() start',
      name: 'NotificationService',
    );
    // G5: initialise the timezone database so zonedSchedule() can compute the
    // absolute firing instant for the exact-alarm ETA backstop. We only ever
    // build TZDateTime values from tz.UTC + a Duration, so we do not need the
    // device's local zone name (avoids a flutter_timezone dependency).
    try {
      tzdata.initializeTimeZones();
    } catch (e) {
      dev.log('tz.initializeTimeZones failed: $e', name: 'NotificationService');
    }
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

    // Process-death recovery: when the OS backstop (or any alarm notification)
    // LAUNCHED the app, the tap is NOT delivered to
    // onDidReceiveNotificationResponse — it is only available here. Without
    // this, a rider woken by the backstop after an OEM kill opens the app to a
    // normal home screen with the backstop still ringing and no way to stop
    // it. Route the launch response through the exact same handler as a warm
    // tap, after the first frame so the navigator exists.
    try {
      final launch = await _notificationsPlugin
          .getNotificationAppLaunchDetails();
      final resp = launch?.notificationResponse;
      if ((launch?.didNotificationLaunchApp ?? false) && resp != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(handleNotificationResponse(resp));
        });
      }
    } catch (e) {
      dev.log(
        'Notification launch-details check failed: $e',
        name: 'NotificationService',
      );
    }

    // Explicitly request Android notification permission (Android 13+)
    try {
      final androidImpl =
          _notificationsPlugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();
      await androidImpl?.requestNotificationsPermission();
      // G5: exact-alarm permission (Android 12+). Auto-granted when USE_EXACT_ALARM
      // is declared; on 12/12L it may need the user, so request best-effort.
      try {
        await androidImpl?.requestExactAlarmsPermission();
      } catch (_) {}
      // G7: full-screen-intent permission (Android 14+).
      try {
        await androidImpl?.requestFullScreenIntentPermission();
      } catch (_) {}
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
        // Note: We disable notification channel vibration because we use manual
        // Vibration.vibrate() for better sync with the alarm sound.
        await androidImpl.createNotificationChannel(
          const AndroidNotificationChannel(
            'geowake_alarm_channel_v4',
            'GeoWake Alarms (High Priority)',
            description: 'Channel for urgent GeoWake wake-up alarms',
            importance: Importance.max,
            enableVibration:
                false, // Vibration handled via Vibration plugin for sync
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

  /// Invariant #4 decision (pure, unit-testable): an auxiliary (non-core)
  /// alarm — e.g. anti-theft — must never cancel/override or fire alongside the
  /// core destination wake alarm. Suppress it whenever an alarm is already
  /// presenting or the destination alarm has already fired this session. The
  /// core alarm is never suppressed by this rule.
  static bool shouldSuppressAuxiliaryAlarm({
    required bool isCoreAlarm,
    required bool alarmCurrentlyShowing,
    required bool destinationAlarmFired,
  }) {
    if (isCoreAlarm) return false;
    return alarmCurrentlyShowing || destinationAlarmFired;
  }

  // This is the main function to trigger the alarm
  Future<void> showWakeUpAlarm({
    required String title,
    required String body,
    bool allowContinueTracking = true,
    bool playSound = true, // Default to true for backward compatibility
    // Distinguishes the core destination wake alarm from auxiliary (Pro) alarms
    // like anti-theft. Invariant #4: a Pro feature must never affect the core
    // alarm — so an auxiliary alarm may NOT cancel/override a destination alarm
    // that is already presenting, and the core alarm always wins a collision.
    bool isCoreAlarm = true,
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
          'playSound': playSound,
          'ts': DateTime.now().toIso8601String(),
        });
      } catch (_) {}
    }

    // If tests explicitly disabled platform behavior, skip showing.
    if (isTestMode) {
      return;
    }
    dev.log(
      'DEBUG: ALARM TRIGGER: Showing wake-up alarm with title: "$title", body: "$body", sound: $playSound',
      name: 'NotificationService',
    );

    // An auxiliary (non-core) alarm must never override a presenting alarm:
    // if the core destination wake alarm is already sounding, the rider is
    // already being woken and the core alarm must not be cancelled/replaced by
    // e.g. anti-theft (invariant #4). Auxiliary alarms also never fire once the
    // destination alarm has fired for this session.
    if (!isCoreAlarm) {
      bool destFired = false;
      try {
        destFired = await TrackingStateStore.isAlarmFired();
      } catch (_) {}
      if (shouldSuppressAuxiliaryAlarm(
        isCoreAlarm: isCoreAlarm,
        alarmCurrentlyShowing: _alarmCurrentlyShowing,
        destinationAlarmFired: destFired,
      )) {
        dev.log(
          'Auxiliary alarm suppressed — core alarm already active/fired.',
          name: 'NotificationService',
        );
        return;
      }
    }

    // Prevent duplicate overlays
    if (_alarmCurrentlyShowing) {
      if (allowContinueTracking) {
        dev.log(
          'Alarm already showing, skipping duplicate trigger',
          name: 'NotificationService',
        );
        return;
      } else {
        dev.log(
          'Alarm already showing, but Destination alarm takes priority. Overriding.',
          name: 'NotificationService',
        );
        // Force cancel existing alarm to make way for this one
        await cancelAlarm(restoreJourney: false);
        // Fall through...
      }
    }
    _alarmCurrentlyShowing = true;

    try {
      await TrackingStateStore.setAlarmFired(true);
    } catch (_) {}

    // 1. Store alarm info in SharedPreferences to recover if needed
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pending_alarm_flag', true);
    await prefs.setString('pending_alarm_title', title);
    await prefs.setString('pending_alarm_body', body);
    await prefs.setBool('pending_alarm_allow', allowContinueTracking);

    // 2. Define the Android notification details
    // Note: Vibration is handled manually via Vibration.vibrate() for better sync with audio.

    final AndroidNotificationDetails
    androidDetails = AndroidNotificationDetails(
      'geowake_alarm_channel_v4',
      'GeoWake Alarms (High Priority)',
      channelDescription: 'Channel for GeoWake wake-up alarms',
      importance: Importance.max,
      priority: Priority.max,
      playSound: false, // Use AlarmPlayer for the custom sound
      // G7: only request a full-screen intent when the OS will actually honor it
      // (Android 14+ auto-grants USE_FULL_SCREEN_INTENT only to alarm/calendar
      // apps). When it won't, we keep max importance + insistent flag so the
      // alarm still surfaces as a heads-up banner instead of being suppressed.
      fullScreenIntent: await WakepointNative.canUseFullScreenIntent(),
      visibility: NotificationVisibility.public,
      category: AndroidNotificationCategory.alarm,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      ongoing: true, // Make it ongoing so it can't be dismissed
      autoCancel: false,
      // IMPORTANT: Disable notification vibration - we use manual Vibration.vibrate() loop
      // for better sync with audio. Double vibration (notification + manual) causes
      // desync issues where vibration doesn't match alarm sound timing.
      enableVibration: false,
      // FLAG_INSISTENT = 4: Makes any notification sound/vibration loop until cancelled
      // FLAG_NO_CLEAR = 32: Prevents notification from being cleared by "Clear All"
      // Combined with ongoing:true and autoCancel:false, this ensures the notification
      // persists until explicitly dismissed via Stop Alarm or End Tracking buttons.
      additionalFlags: Int32List.fromList([4, 32]),
      ticker: 'Destination alarm active',
      actions:
          allowContinueTracking
              ? <AndroidNotificationAction>[
                AndroidNotificationAction(
                  'STOP_ALARM',
                  'Stop Alarm',
                  // Must be true so the action is handled by the foreground isolate.
                  // Alarm audio is started from the foreground via the 'triggerAlarm'
                  // bridge; stopping it requires the same isolate.
                  showsUserInterface: true,
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

    // 3. Show the notification, trigger alarm sound, and start vibration all at once for sync
    try {
      dev.log(
        'Showing alarm notification with fullScreenIntent: "$title" - "$body"',
        name: 'NotificationService',
      );

      // Start sound, vibration, and notification in parallel for better sync
      dev.log(
        'DEBUG: Starting alarm sound, vibration, and notification in parallel',
        name: 'NotificationService',
      );
      final soundFuture =
          playSound
              ? AlarmPlayer.playSelected().catchError((e) {
                dev.log(
                  'DEBUG: Failed to play alarm sound: $e',
                  name: 'NotificationService',
                );
              })
              : Future.value();

      if (!playSound) {
        dev.log(
          'DEBUG: Skipping sound playback (handled by background isolate)',
          name: 'NotificationService',
        );
        // Mark alarm as playing in foreground so UI (Stop Alarm button) is enabled.
        // The actual audio is playing in background isolate, but UI needs to know.
        AlarmPlayer.markAsPlaying();
      }

      // Start vibration loop in sync with sound
      dev.log('DEBUG: Starting vibration loop', name: 'NotificationService');
      final vibrationFuture = _startAlarmVibrationLoop();

      final notifFuture = _notificationsPlugin.show(
        _alarmNotificationId,
        title,
        body,
        details,
        payload: 'open_alarm:${allowContinueTracking ? '1' : '0'}',
      );

      await Future.wait([soundFuture, vibrationFuture, notifFuture]);
    } catch (e) {
      dev.log(
        'Failed to show alarm notification: $e',
        name: 'NotificationService',
      );
      // If platform notification/vibration/audio fails (common on web/desktop or
      // if plugins aren't initialized), don't permanently block future alarms.
      _alarmCurrentlyShowing = false;
    }
  }

  // G5: distinct id for the OS-scheduled exact-alarm ETA backstop so it never
  // collides with the in-process alarm (0), progress (888) or paused (889).
  static const int _etaBackstopNotificationId = 991;

  /// G5: schedule (or replace) an OS-owned exact alarm that fires at [fireAt] as
  /// a safety net for TOTAL process death. Uses AlarmManager.setAlarmClock via
  /// flutter_local_notifications (AndroidScheduleMode.alarmClock) so it survives
  /// Doze. Cancelled by [cancelEtaBackstop] once the real alarm fires. Idempotent
  /// per id — re-scheduling the same id replaces the pending alarm.
  Future<void> scheduleEtaBackstop({
    required DateTime fireAt,
    required String title,
    required String body,
  }) async {
    if (isTestMode) return;
    if (!Platform.isAndroid) return;
    try {
      // Build the absolute firing instant in UTC (no local-zone lookup needed).
      final tz.TZDateTime scheduled = tz.TZDateTime.from(fireAt.toUtc(), tz.UTC);
      final bool fsi = await WakepointNative.canUseFullScreenIntent();
      // Post on the dedicated BACKSTOP channel, which carries the system alarm
      // tone + vibration at the OS level. The live alarm channel is silent (the
      // AlarmPlayer isolate drives its audio) — useless for TOTAL process death,
      // which is exactly when this backstop must sound. playSound:true so the OS
      // sounds it even with no live isolate. See MainActivity.createNotificationChannel.
      final AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
            'geowake_backstop_channel_v1',
            'GeoWake Backstop Alarm',
            channelDescription:
                'Last-resort wake alarm that sounds even if the app was killed',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            fullScreenIntent: fsi,
            visibility: NotificationVisibility.public,
            category: AndroidNotificationCategory.alarm,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            // This fires precisely when NO app process exists to loop audio, so
            // the notification itself must do the waking: FLAG_INSISTENT (4)
            // loops the channel's system alarm tone until the rider dismisses
            // it, FLAG_NO_CLEAR (32) survives "Clear all". A once-only chime
            // cannot wake a sleeping rider — parity with the primary alarm.
            ongoing: true,
            autoCancel: false,
            additionalFlags: Int32List.fromList([4, 32]),
          );
      final NotificationDetails details = NotificationDetails(
        android: androidDetails,
      );
      await _notificationsPlugin.zonedSchedule(
        _etaBackstopNotificationId,
        title,
        body,
        scheduled,
        details,
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        payload: 'open_alarm:1',
      );
    } catch (e) {
      dev.log('scheduleEtaBackstop failed: $e', name: 'NotificationService');
    }
  }

  /// G5: cancel the pending OS exact-alarm ETA backstop (if any). Called once the
  /// real alarm has fired so the backstop cannot double-fire.
  Future<void> cancelEtaBackstop() async {
    if (isTestMode) return;
    try {
      await _notificationsPlugin.cancel(_etaBackstopNotificationId);
    } catch (e) {
      dev.log('cancelEtaBackstop failed: $e', name: 'NotificationService');
    }
  }

  // Wrong-direction / wrong-train detection is a BACKGROUND signal only — there
  // is deliberately no user-facing alert. The detection (ActiveRouteManager ->
  // wrongDirectionStream) keeps running for core logic to consume and adjust as
  // needed, but it must never notify/wake the rider: it can false-positive on
  // brief GPS noise, and a false wake would erode trust in the real alarm. The
  // former showWrongDirectionAlert() and its dedicated channel were removed.

  /// Re-post the alarm notification without re-triggering sound/vibration/fullscreen.
  /// This is used to make the alarm effectively non-dismissible on newer Android
  /// versions that may allow dismissing ongoing notifications.
  Future<void> ensureAlarmNotificationVisible() async {
    if (isTestMode) return;

    // Rate-limit to avoid spamming NotificationManager.
    final now = DateTime.now();
    final last = _lastEnsureAlarmNotifAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _lastEnsureAlarmNotifAt = now;

    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getBool('pending_alarm_flag') ?? false;
      if (!pending) return;

      final title =
          prefs.getString('pending_alarm_title') ?? 'Time to Wake Up!';
      final body =
          prefs.getString('pending_alarm_body') ?? 'Approaching destination';
      final allowContinue = prefs.getBool('pending_alarm_allow') ?? false;

      final androidDetails = AndroidNotificationDetails(
        'geowake_alarm_channel_v4',
        'GeoWake Alarms (High Priority)',
        channelDescription: 'Channel for GeoWake wake-up alarms',
        importance: Importance.max,
        priority: Priority.max,
        playSound: false,
        // Critical: do NOT re-fire full-screen intent during resurrection.
        fullScreenIntent: false,
        visibility: NotificationVisibility.public,
        category: AndroidNotificationCategory.alarm,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        ongoing: true,
        autoCancel: false,
        enableVibration: false,
        // Avoid re-alerting; we only want to keep it present.
        onlyAlertOnce: true,
        // Keep NO_CLEAR; omit INSISTENT so we don't re-loop notification effects.
        additionalFlags: Int32List.fromList([32]),
        actions:
            allowContinue
                ? <AndroidNotificationAction>[
                  AndroidNotificationAction(
                    'STOP_ALARM',
                    'Stop Alarm',
                    showsUserInterface: true,
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

      final details = NotificationDetails(android: androidDetails);
      await _notificationsPlugin.show(
        _alarmNotificationId,
        title,
        body,
        details,
        payload: 'open_alarm:${allowContinue ? '1' : '0'}',
      );
    } catch (e) {
      dev.log(
        'ensureAlarmNotificationVisible failed: $e',
        name: 'NotificationService',
      );
    }
  }

  /// Re-post the paused notification while the app is in paused state.
  /// This makes the Resume/End notification effectively non-dismissible.
  Future<void> ensureTrackingPausedNotificationVisible() async {
    if (isTestMode) return;

    // Rate-limit; paused state can last a while.
    final now = DateTime.now();
    final last = _lastEnsurePausedNotifAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastEnsurePausedNotifAt = now;

    try {
      final paused = await TrackingStateStore.isPaused();
      if (!paused) return;

      // Re-use the last saved payload if available.
      // G3: fall back to the softened "running in background" copy so the
      // resurrected notification never falsely implies tracking stopped.
      final payload = await TrackingStateStore.loadProgressPayload();
      final title = payload?.title ?? 'Running in background';
      final subtitle = payload?.subtitle ?? 'Still watching your trip. Tap to open.';

      final androidDetails = AndroidNotificationDetails(
        'geowake_tracking_channel_v2',
        'GeoWake Tracking',
        channelDescription: 'Tracking paused (requires foreground)',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: true,
        autoCancel: false,
        onlyAlertOnce: true,
        visibility: NotificationVisibility.public,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            'RESUME_TRACKING',
            'Resume Tracking',
            showsUserInterface: true,
          ),
          AndroidNotificationAction(
            'END_TRACKING',
            'End Tracking',
            showsUserInterface: true,
          ),
        ],
      );

      final details = NotificationDetails(android: androidDetails);
      await _notificationsPlugin.show(
        _pausedNotificationId,
        title,
        subtitle,
        details,
        payload: 'tracking_paused',
      );
    } catch (e) {
      dev.log(
        'ensureTrackingPausedNotificationVisible failed: $e',
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
      // If the app is in a paused-after-swipe state, the paused notification is
      // the single source of truth. Avoid re-showing journey progress.
      try {
        final paused = await TrackingStateStore.isPaused();
        if (paused) {
          dev.log(
            'Tracking is paused; suppressing journey notification update.',
            name: 'NotificationService',
          );
          return;
        }
      } catch (_) {}

      final muted = await TrackingStateStore.notificationsMuted();
      if (muted) {
        dev.log(
          'Journey notification muted by user; skipping update.',
          name: 'NotificationService',
        );
        return;
      }
    }

    // In unit tests, avoid plugin calls but still persist payload.
    if (isTestMode) {
      try {
        testRecordedNotifications.add({
          'id': _progressNotificationId,
          'title': title,
          'body': subtitle,
          'payload': isTracking ? 'journey_active' : 'journey_paused',
          'ts': DateTime.now().toIso8601String(),
        });
      } catch (_) {}
      if (testOnShowNotification != null) {
        try {
          await testOnShowNotification!(
            _progressNotificationId,
            title,
            subtitle,
            isTracking ? 'journey_active' : 'journey_paused',
          );
        } catch (_) {}
      }
      try {
        await TrackingStateStore.saveProgressPayload(
          TrackingProgressPayload(
            title: title,
            subtitle: subtitle,
            progress: progress0to1,
            isTracking: isTracking,
          ),
        );
      } catch (_) {}
      return;
    }

    final AndroidNotificationDetails
    androidDetails = AndroidNotificationDetails(
      'geowake_tracking_channel_v2',
      'GeoWake Tracking',
      channelDescription: 'Ongoing tracking status',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,

      // Let user swipe; resurrection handled by restoreJourneyProgressIfActive unless muted/end.
      ongoing: false,
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
                  // Must be true so the mute takes effect immediately and reliably.
                  showsUserInterface: true,
                ),
                AndroidNotificationAction(
                  'END_TRACKING',
                  'End Tracking',
                  showsUserInterface: true,
                ),
              ]
              : <AndroidNotificationAction>[
                AndroidNotificationAction(
                  'RESUME_TRACKING',
                  'Resume Tracking',
                  showsUserInterface: true,
                ),
                AndroidNotificationAction(
                  'END_TRACKING',
                  'End Tracking',
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

  Future<void> showTrackingPaused({String? destinationName}) async {
    // Mark state paused so other subsystems (e.g., progress updates) don't
    // fight this notification.
    try {
      await TrackingStateStore.setPaused(true);
    } catch (_) {}

    // Ensure the journey progress notification is not visible while paused.
    try {
      await cancelJourneyProgress();
    } catch (_) {}

    // G3: the foreground process was swiped away/killed, but alarm evaluation
    // CONTINUES in the background isolate. The old "Tracking paused — Resume to
    // continue" copy falsely implied the wake-up alarm had stopped, which is
    // alarming for a sleeping rider. Reword so it does NOT imply tracking
    // stopped. NOTE: the underlying paused STATE (set below/above) is unchanged;
    // only the user-facing message is softened.
    final title = 'Running in background';
    final subtitle =
        destinationName != null && destinationName.trim().isNotEmpty
            ? 'Still watching your trip to $destinationName. Tap to open.'
            : 'Still watching your trip. Tap to open.';

    // In unit tests, avoid plugin calls but still persist payload.
    if (isTestMode) {
      try {
        testRecordedNotifications.add({
          'id': _pausedNotificationId,
          'title': title,
          'body': subtitle,
          'payload': 'tracking_paused',
          'ts': DateTime.now().toIso8601String(),
        });
      } catch (_) {}
      if (testOnShowNotification != null) {
        try {
          await testOnShowNotification!(
            _pausedNotificationId,
            title,
            subtitle,
            'tracking_paused',
          );
        } catch (_) {}
      }
      try {
        await TrackingStateStore.saveProgressPayload(
          TrackingProgressPayload(
            title: title,
            subtitle: subtitle,
            progress: 0,
            isTracking: false,
          ),
        );
      } catch (_) {}
      return;
    }

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'geowake_tracking_channel_v2',
          'GeoWake Tracking',
          channelDescription: 'Tracking paused (requires foreground)',
          importance: Importance.high,
          priority: Priority.high,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          visibility: NotificationVisibility.public,
          actions: <AndroidNotificationAction>[
            AndroidNotificationAction(
              'RESUME_TRACKING',
              'Resume Tracking',
              showsUserInterface: true,
            ),
            AndroidNotificationAction(
              'END_TRACKING',
              'End Tracking',
              showsUserInterface: true,
            ),
          ],
        );

    final details = NotificationDetails(android: androidDetails);
    try {
      await _notificationsPlugin.show(
        _pausedNotificationId,
        title,
        subtitle,
        details,
        payload: 'tracking_paused',
      );
      await TrackingStateStore.saveProgressPayload(
        TrackingProgressPayload(
          title: title,
          subtitle: subtitle,
          progress: 0,
          isTracking: false,
        ),
      );
    } catch (e) {
      dev.log(
        'Failed to show paused notification: $e',
        name: 'NotificationService',
      );
    }
  }

  Future<void> cancelTrackingPaused() async {
    if (isTestMode) {
      try {
        testRecordedCancels.add(_pausedNotificationId);
      } catch (_) {}
      if (testOnCancelNotification != null) {
        try {
          await testOnCancelNotification!(_pausedNotificationId);
        } catch (_) {}
      }
      return;
    }
    try {
      await _notificationsPlugin.cancel(_pausedNotificationId);
    } catch (_) {}
  }

  Future<void> cancelJourneyProgress() async {
    // Clear payload regardless so end/ignore flows don't leave stale state.
    try {
      await TrackingStateStore.clearProgressPayload();
    } catch (_) {}

    if (isTestMode) {
      try {
        testRecordedCancels.add(_progressNotificationId);
      } catch (_) {}
      if (testOnCancelNotification != null) {
        try {
          await testOnCancelNotification!(_progressNotificationId);
        } catch (_) {}
      }
      return;
    }

    await _notificationsPlugin.cancel(_progressNotificationId);
  }

  /// Cancel all notifications (journey progress + alarm)
  Future<void> cancelAllNotifications() async {
    _alarmCurrentlyShowing = false;

    // Always clear persisted state, even in tests.
    try {
      await TrackingStateStore.clearProgressPayload();
      await TrackingStateStore.setAlarmFired(false);
    } catch (_) {}
    await _clearPendingAlarmPrefs();

    if (isTestMode) {
      // Best-effort: record cancels for assertions.
      try {
        testRecordedCancels.addAll([
          _alarmNotificationId,
          _progressNotificationId,
          _pausedNotificationId,
          _etaBackstopNotificationId,
        ]);
      } catch (_) {}
      return;
    }

    try {
      // Stop alarm side-effects first (audio/vibration) even if notification IDs drift.
      await cancelAlarm(restoreJourney: false);

      await _notificationsPlugin.cancel(_alarmNotificationId);
      await _notificationsPlugin.cancel(_progressNotificationId);
      await _notificationsPlugin.cancel(_pausedNotificationId);
      // #11: also sweep the OS-scheduled ETA backstop (id 991); otherwise it
      // stays armed after End Tracking and fires a spurious wake once the trip
      // is over (cancelEtaBackstop only runs on the live isolate's _onStop).
      await _notificationsPlugin.cancel(_etaBackstopNotificationId);
      // Cancel any other potential IDs just in case
      await _notificationsPlugin.cancel(8888);
      dev.log(
        'All notifications cancelled (ID: 0, 888, 889, 991, 8888)',
        name: 'NotificationService',
      );
    } catch (e) {
      dev.log(
        'Error cancelling all notifications: $e',
        name: 'NotificationService',
      );
    }
  }

  /// Cancel the journey progress notification
  Future<void> cancelNotification() async {
    try {
      await TrackingStateStore.clearProgressPayload();
    } catch (_) {}

    if (isTestMode) {
      try {
        testRecordedCancels.add(_progressNotificationId);
      } catch (_) {}
      if (testOnCancelNotification != null) {
        try {
          await testOnCancelNotification!(_progressNotificationId);
        } catch (_) {}
      }
      return;
    }

    await _notificationsPlugin.cancel(_progressNotificationId);
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

  // Critical reliability: when invoked from the plugin background isolate,
  // FlutterBackgroundService.invoke() is not guaranteed to be available.
  // Persist requests so the running tracking service isolate can consume them.
  final actionId = response.actionId;
  final payload = response.payload;

  if (actionId == 'STOP_ALARM') {
    dev.log(
      'BG_STOP_ALARM: Stopping alarm from background callback',
      name: 'NotificationService',
    );
    // Persist first so the tracking isolate can consume even if immediate stops fail.
    await NotificationService.requestStopAlarmForService();

    // Cancel the alarm notification immediately - this should always work.
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.cancel(0);
      dev.log(
        'BG_STOP_ALARM: Cancelled notification ID 0',
        name: 'NotificationService',
      );
    } catch (e) {
      dev.log(
        'BG_STOP_ALARM: Failed to cancel notification: $e',
        name: 'NotificationService',
      );
    }

    // Try to stop vibration - platform call should work from bg isolate.
    try {
      await Vibration.cancel();
      // Call cancel multiple times for reliability on some devices
      await Future.delayed(const Duration(milliseconds: 50));
      await Vibration.cancel();
      dev.log(
        'BG_STOP_ALARM: Cancelled vibration',
        name: 'NotificationService',
      );
    } catch (e) {
      dev.log(
        'BG_STOP_ALARM: Failed to cancel vibration: $e',
        name: 'NotificationService',
      );
    }

    // Best-effort: invoke stopAlarm on the background service.
    // This tells the tracking isolate to call AlarmPlayer.stop() which actually stops the sound.
    try {
      FlutterBackgroundService().invoke('stopAlarm');
      dev.log(
        'BG_STOP_ALARM: Invoked stopAlarm on service',
        name: 'NotificationService',
      );
    } catch (e) {
      dev.log(
        'BG_STOP_ALARM: Failed to invoke stopAlarm: $e',
        name: 'NotificationService',
      );
    }

    // Best-effort: try stopping audio directly (may fail in bg isolate).
    try {
      await AlarmPlayer.stop();
      dev.log(
        'BG_STOP_ALARM: Stopped AlarmPlayer',
        name: 'NotificationService',
      );
    } catch (e) {
      dev.log(
        'BG_STOP_ALARM: AlarmPlayer.stop failed (expected in bg isolate): $e',
        name: 'NotificationService',
      );
    }
    return;
  }

  if (actionId == 'IGNORE') {
    dev.log(
      'BG_IGNORE: Ignoring notification from background callback, payload=$payload',
      name: 'NotificationService',
    );
    // For journey notifications, mute persistence.
    if (payload != null && payload.startsWith('journey')) {
      await NotificationService.requestMuteJourneyForService();
      // CRITICAL FIX: Also set the mute flag IMMEDIATELY in TrackingStateStore
      // so that showJourneyProgress() respects it right away, without waiting
      // for the poll timer to consume the request flag.
      try {
        await TrackingStateStore.setNotificationsMuted(true);
        dev.log(
          'BG_IGNORE: Set notifications muted immediately',
          name: 'NotificationService',
        );
      } catch (e) {
        dev.log(
          'BG_IGNORE: Failed to set notifications muted: $e',
          name: 'NotificationService',
        );
      }
      // Cancel the journey notification (ID 888) immediately.
      try {
        final plugin = FlutterLocalNotificationsPlugin();
        await plugin.cancel(888);
      } catch (_) {}
    } else {
      // Ignore on alarm: just stop the alarm.
      await NotificationService.requestStopAlarmForService();
      try {
        await AlarmPlayer.stop();
      } catch (_) {}
      try {
        await Vibration.cancel();
      } catch (_) {}
      try {
        final plugin = FlutterLocalNotificationsPlugin();
        await plugin.cancel(0);
      } catch (_) {}
    }
    return;
  }

  if (actionId == 'END_TRACKING') {
    dev.log(
      'BG_END_TRACKING: Ending tracking from background callback',
      name: 'NotificationService',
    );
    await NotificationService.requestEndTrackingForService();
    // Best-effort immediate stop to reduce "button does nothing" perception.
    // Full cleanup is performed by the tracking isolate when it consumes the request.
    try {
      FlutterBackgroundService().invoke('stopTracking', {'stopSelf': true});
    } catch (_) {}
    // Cancel all notifications immediately.
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.cancel(0);
      await plugin.cancel(888);
      await plugin.cancel(889);
      // #11: the tracking isolate that would normally call cancelEtaBackstop()
      // is dead on this background path, so cancel the OS ETA backstop (id 991)
      // here — otherwise it stays armed and wakes the rider after the trip.
      await plugin.cancel(NotificationService._etaBackstopNotificationId);
    } catch (_) {}
    return;
  }

  if (actionId == 'RESUME_TRACKING') {
    dev.log(
      'DEBUG: BG_RESUME_TRACKING: Resuming tracking from background callback',
      name: 'NotificationService',
    );
    // Mark tracking as no longer paused
    try {
      await TrackingStateStore.setPaused(false);
      dev.log(
        'DEBUG: BG_RESUME_TRACKING: Set paused to false',
        name: 'NotificationService',
      );
    } catch (e) {
      dev.log(
        'DEBUG: BG_RESUME_TRACKING: Failed to set paused: $e',
        name: 'NotificationService',
      );
    }
    // Cancel the paused notification
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.cancel(889); // Paused notification ID
      dev.log(
        'DEBUG: BG_RESUME_TRACKING: Cancelled paused notification',
        name: 'NotificationService',
      );
    } catch (e) {
      dev.log(
        'DEBUG: BG_RESUME_TRACKING: Failed to cancel notification: $e',
        name: 'NotificationService',
      );
    }
    // Invoke startTracking to resume the background service with stored snapshot
    try {
      final snapshot = await TrackingStateStore.loadSnapshot();
      dev.log(
        'DEBUG: BG_RESUME_TRACKING: Loaded snapshot: ${snapshot != null}',
        name: 'NotificationService',
      );
      if (snapshot != null) {
        FlutterBackgroundService().invoke('startTracking', {
          'destinationLat': snapshot.destinationLat,
          'destinationLng': snapshot.destinationLng,
          'destinationName': snapshot.destinationName,
          'alarmMode': snapshot.alarmMode,
          'alarmValue': snapshot.alarmValue,
        });
        dev.log(
          'DEBUG: BG_RESUME_TRACKING: Invoked startTracking',
          name: 'NotificationService',
        );
      }
    } catch (e) {
      dev.log(
        'DEBUG: BG_RESUME_TRACKING: Failed to invoke startTracking: $e',
        name: 'NotificationService',
      );
    }
    return;
  }

  await NotificationService().handleNotificationResponse(
    response,
    allowNavigation: false,
  );
}
