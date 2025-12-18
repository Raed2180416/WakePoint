# MESSAGE_SCHEMAS

## FlutterBackgroundService invoke/on
- `startTracking` (foreground→background, trackingservice.dart startTracking): payload `{destinationLat: double, destinationLng: double, destinationName: String, alarmMode: String, alarmValue: double, useInjectedPositions: bool, routePoints?: [{lat, lng}], requestId}`; ack event `startTrackingAck` returns `{requestId}`.
- `registerRoute` (foreground→background): `{key: String, mode: String, destinationName: String, points: [{lat,double,lng,double}], segments?: List<Map>, switch_points?: List<Map>, events?: List<Map>, requestId}`; ack `registerRouteAck` `{requestId}`.
- `registerRouteDirections` (foreground→background): `{directions: Map, origin: {lat,lng}, destination: {lat,lng}, transitMode: bool, destinationName: String?, requestId}`; ack `registerRouteDirectionsAck` `{requestId}`.
- `foregroundHeartbeat` (foreground→background every 1s): `{timestamp: int millis}` to update `_lastForegroundHeartbeat`.
- `foregroundResumed` (foreground→background on lifecycle resume): `{}` to reset pause and restore notifications.
- `stopTracking` (foreground or background notification action→background): `{stopSelf: bool}` triggers `_onStop` and optional `service.stopSelf()`.
- `stopAlarm` (foreground MapTracking/NotificationService→background): `{}` cancels alarm notification/audio and stops polling.
- `triggerAlarm` (background→foreground): `{title: String, body: String, allowContinue: bool}` handled by foreground listener calling NotificationService.showWakeUpAlarm.
- `routeSwitch` (background→foreground): `{fromKey: String, toKey: String, timestamp: String?, points?: [{lat,lng}]}` parsed into `RouteSwitchEvent` and sent on `routeSwitchStream`.
- `activeRouteUpdate` (background→foreground): payload of `ActiveRouteState.toJson()` consumed by `_routeStateCtrl` stream.
- `updateLocation` (background invoke to service itself; no foreground listener) carries `{latitude, longitude, heading, speed, timestamp}` for potential extensions.
- Demo/testing: `useInjectedPositions` (foreground→background) no payload to enable injected stream; `injectPosition` with `{latitude, longitude, accuracy?, altitude?, heading?, speed?, ...}` to push synthetic GPS.

## Notification action IDs
- `STOP_ALARM`, `END_TRACKING`, `IGNORE` (mute journey or stop alarm depending payload), `RESUME_TRACKING`, `DISMISS_ALARM` (notification_service.dart classifyAction / notificationTapBackground).

## File-flag + SharedPreferences persistence keys
- Files in app documents dir: `.gw_stop_alarm_flag`, `.gw_end_tracking_flag`, `.gw_mute_journey_flag` (written by `request*ForService`, consumed by TrackingService `_startAlarmStopPollTimer`).
- SharedPreferences fallbacks: `gw_stop_alarm_request_v1`, `gw_end_tracking_request_v1`, `gw_mute_journey_request_v1` (+ `_ts` timestamp suffix) (notification_service.dart).
- Tracking state keys (TrackingStateStore): `tracking_active_v1`, `tracking_snapshot_v1`, `tracking_notifications_muted_v1`, `gw_progress_payload_v1`, `tracking_paused_v1`, `tracking_alarm_fired_v1`.
- Pending alarm prefs for resurrection: `pending_alarm_flag`, `pending_alarm_title`, `pending_alarm_body`, `pending_alarm_allow` (notification_service.dart).
