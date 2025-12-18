# DOMAIN_REPORT_UI_SYNC

- **Splash restore**: Checks `TrackingStateStore.isAlarmFired()` for zombie alarms and calls `completeEndTracking` before navigation; routes to `/mapTracking` if `isActive` true else home (splash_screen.dart).
- **Home to MapTracking**: HomeScreen saves snapshot and navigates with args; MapTrackingScreen reads args, validates required fields, else `_restoreState` from snapshot; shows error dialog and pops when args incomplete (maptracking.dart).
- **Streams**: MapTrackingScreen listens to `routeSwitchStream` to show snackbars and update polylines; listens to `activeRouteStateStream` to recompute ETA/distance text; subscribes to Geolocator location updates to move markers. Subscriptions cancelled in `dispose`.
- **Restore gaps**: If snapshot missing directions, `_restoreState` fetches new directions and re-saves snapshot. Background alarm logic may be running before UI fetch completes; progress notification may show with stale progress until routes registered again.
- **Navigation service**: Notification taps with payloads push `/mapTracking`; lifecycle resume triggers heartbeat restart in TrackingService to keep background aware of UI state.
