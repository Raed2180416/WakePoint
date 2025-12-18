# CERTAINTY_MATRIX

- **Proven**: None (baseline Flutter tooling unavailable; no runtime validation possible).
- **Strongly Supported**:
  - Alarm trigger relay: background `_checkAndTriggerAlarm` calls `_triggerAlarmNotification` → `service.invoke('triggerAlarm')` → foreground listener shows NotificationService alarm (trackingservice.dart).
  - Heartbeat pause detection: foreground `_sendHeartbeat` every second while tracking; background `_startHeartbeatMonitoring` uses 4s timeout to show paused notification (trackingservice.dart).
- **Uncertain**:
  - Reliability of file-flag consumption for STOP_ALARM/END_TRACKING when invoked from background callback before any alarm starts (depends on `_startAlarmStopPollTimer` start conditions).
  - Geolocator stream resilience to permission loss or provider errors; no error handling present in `startLocationStream` subscription.
- **Unverified (needs device/emulator)**:
  - Alarm notification behavior under Doze/Android 13+ exact alarm restrictions.
  - Heartbeat timer behavior on OEMs that throttle timers in background (possible false pause).
  - Route deviation/reroute correctness under intermittent GPS/out-of-order timestamps.
