# DOMAIN_REPORT_ALARMS_NOTIFS

- **Alarm trigger path**: `_checkAndTriggerAlarm` evaluates distance/time/stops thresholds; uses SnapToRoute progress for events and triggers `_triggerAlarmNotification` with debug info (trackingservice.dart).
- **Foreground vs background**: Background isolate cannot show notifications, so it invokes `triggerAlarm` to foreground; foreground listener shows wake-up alarm via NotificationService (trackingservice.dart, notification_service.dart).
- **Notification content**: Full-screen alarm notification uses STOP_ALARM/END_TRACKING actions; pending alarm data stored in SharedPreferences to allow `ensureAlarmNotificationVisible` resurrection (notification_service.dart).
- **Action handling**: Foreground responses handled via `_handleNotificationAction`; background responses via `notificationTapBackground` persist file flags and attempt best-effort player stop/stopTracking.
- **Stop loop**: Alarm stop uses AlarmPlayer.stop and `_cancelAlarmNotificationOnly`; vibration loop restarted periodically. `_alarmCurrentlyShowing` guards duplicates.
- **Reliability gap**: Background STOP_ALARM/END_TRACKING rely on file flags consumed by `_startAlarmStopPollTimer`; poll timer not started until an alarm triggers (or test initialData), so if invoke channel fails before poll starts, persisted requests may sit until an alarm eventually fires (see GW-AUDIT-002).
- **Platform constraints**: No explicit handling for notification permission denial beyond initial request in main; Doze/ExactAlarm restrictions unverified (baseline tests blocked).
