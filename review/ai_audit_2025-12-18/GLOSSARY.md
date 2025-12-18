# GLOSSARY

- Background isolate: flutter_background_service worker started by TrackingService `_onStart`, handles GPS, alarms, route logic.
- Foreground/UI isolate: main Flutter app handling UI, NotificationService plugin calls, and routing screens.
- Tracking session: active journey from `startTracking` until `stopTracking/completeEndTracking`; persisted via `TrackingStateStore` keys `_activeKey`, `_pausedKey`, `_snapshotKey`.
- Snapshot: serialized `TrackingSnapshot` (destination/alarm/user coords/directions) stored in SharedPreferences for restore.
- Alarm modes: `distance` (km to destination), `time` (ETA minutes), `stops` (transit stops/events) handled in `_checkAndTriggerAlarm`.
- Route events: boundaries (transfer/mode_change/boarding/destination) from Directions fed into `_routeEvents` for stop alarms.
- Heartbeat: foreground invokes `foregroundHeartbeat` every second; background monitors for 4s timeout to detect killed UI.
- File flags: dotfiles `.gw_stop_alarm_flag`, `.gw_end_tracking_flag`, `.gw_mute_journey_flag` in app docs dir for cross-isolate notification actions.
