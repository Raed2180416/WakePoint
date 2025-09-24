# NotificationService (lib/services/notification_service.dart)

Purpose: Centralizes alarm and journey progress notifications, native alarm UI bridging, and test-mode observability.

## Singleton and Test Mode
- Singleton via factory; `isTestMode` disables platform calls.
- `testRecordedAlarms`: in-memory list to assert alarms in tests.
- Optional `testOnShowWakeUpAlarm` hook for additional test observability.
- `clearTestRecordedAlarms()` utility.

## Native Channels and Plugins
- `MethodChannel('com.example.geowake2/alarm')` used to launch native `AlarmActivity` and stop vibration.
- `FlutterLocalNotificationsPlugin` for showing full-screen alarm and persistent journey progress notifications.
- Notification channel IDs:
  - `geowake_alarm_channel_v3` (high priority, full-screen)
  - `geowake_tracking_channel_v2` (progress)
  - `geowake_tracking_channel` (service)

## Initialization
- `initialize()` sets up plugin, response handlers (STOP_ALARM/END_TRACKING), requests Android 13+ permission, and creates channels.
- `notificationTapBackground` handles background action presses similarly.

## Alarm Flow: showWakeUpAlarm({title, body, allowContinueTracking})
- Records to tests (and optional hook) always when `isTestMode` or a hook is set.
- If `isTestMode`, returns early after recording.
- Otherwise:
  - Persists pending alarm details in SharedPreferences (for recovery/UI on resume).
  - Ensures high-priority alarm channel exists (with vibration pattern).
  - Shows a full-screen notification with actions STOP_ALARM and END_TRACKING.
  - Attempts to launch native `AlarmActivity`; if it fails, falls back to in-app `AlarmFullscreen` route.
  - Starts `AlarmPlayer.playSelected()` to play ringtone.

## Journey Progress
- `showJourneyProgress(title, subtitle, progress0to1)` shows/updates persistent progress notification.
- `cancelJourneyProgress()` clears it (no-op in tests).

## Pending Alarm UI
- `showPendingAlarmScreenIfAny()` checks SharedPreferences for a pending alarm and pushes `AlarmFullscreen` if present, then clears flags.

## Interactions with TrackingService
- STOP_ALARM action relays to background service method `stopAlarm` (stops sound and vibration).
- END_TRACKING action calls `TrackingService().stopTracking()`.

## Nuances
- Uses explicit vibration patterns to emulate native alarm urgency.
- Uses `onlyAlertOnce` for progress updates to avoid repeated sounds.
- Full-screen intent and category=alarm to surface on lockscreen.
