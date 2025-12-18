# STATE_MACHINES

## Tracking session
- States: `inactive` (TrackingStateStore.active=false) → `starting` (startTracking invoked, progress notification shown) → `active` (background `_trackingSessionActive=true`, GPS stream running) → `paused` (heartbeat timeout sets TrackingStateStore.paused=true and shows paused notification) → `ending` (stopTracking/endTracking action) → `ended` (completeEndTracking clears prefs/notifications).
- Zombie recovery: Splash checks `TrackingStateStore.isAlarmFired()` and `isActive()`, calls `completeEndTracking` then navigates home to avoid stuck alarm state.

## Alarm state
- `armed` (tracking active, `_destinationAlarmFired=false`)
- `firing` (NotificationService.showWakeUpAlarm running; AlarmPlayer + vibration; pending_alarm_flag persisted)
- `stop requested` (STOP_ALARM/IGNORE actions -> requestStopAlarmForService or cancelAlarm)
- `stopped` (AlarmPlayer.stop + cancel notification; `_alarmCurrentlyShowing=false`; TrackingStateStore.setAlarmFired(false))

## Route/active key
- `uninitialized` → `registered` (registerRoute/registerRouteDirections) → `active` (ActiveRouteManager ingesting positions) → `switching` (routeSwitch events) → `switched` (routeSwitchStream to UI) → `cleared` (_onStop clears registry).

## UI sync
- `UI alive` (MapTrackingScreen listening to streams) vs `UI dead` (foreground killed). Heartbeat timeout moves background to paused notification; RESUME_TRACKING action resumes via TrackingService.resumeFromNotification and shows mapTracking route again.
