# GeoWake lib/ Deep Dive Audit

This file will capture issues and observations as the deep review proceeds. Each entry:
- Module / File
- Finding (severity/risk)
- Details / rationale
- Suggested action
- Cross-links (tests/other modules)

## Inventory
- services: active_route_manager.dart, alarm_player.dart, api_client.dart, deviation_detection.dart, deviation_monitor.dart, direction_service.dart, eta_engine.dart, eta_utils.dart, metro_stop_service.dart, navigation_service.dart, notification_service.dart, offline_coordinator.dart, permission_service.dart, places_service.dart, polyline_decoder.dart, polyline_simplifier.dart, reroute_policy.dart, route_cache.dart, route_queue.dart, route_registry.dart, sensor_fusion.dart, simulation_client.dart, snap_to_route.dart, stop_logic_engine.dart, test_service_instance.dart, trackingservice.dart, tracking_state_store.dart, transfer_utils.dart
- models: route_models.dart
- screens: homescreen.dart, maptracking.dart, ringtones_screen.dart, settingsdrawer.dart, splash_screen.dart (+ otherimpservices/)
- widgets: pulsing_dots.dart
- config: app_config.dart, platform_test_flag_io.dart, platform_test_flag_stub.dart, playground_bridge.dart, power_policy.dart
- debug: demo_tools.dart, dev_server.dart
- themes: appthemes.dart
- simulation_engine.dart, main.dart, main_dashboard.dart

## Review Workflow
- Process: [review/review_process.md](review/review_process.md)
- Spec checklist: [review/spec_checklist.md](review/spec_checklist.md)
- System map: [review/architecture_map.md](review/architecture_map.md)
- File-by-file index: [review/file_review_index.md](review/file_review_index.md)

## Behavior Reference (Product Spec)

This section captures the intended behavior (per user spec, Dec 2025). The audit
below will be updated to reflect mismatches, logical gaps, and redundancies.

### Tracking Modes
- **Normal mode (metro OFF)**: fetch optimal non-metro route; alarms based on **distance** or **time**.
- **Metro mode (metro ON)**:
	- **Time mode**: alert user N minutes before every switch point.
	- **Stops mode**: alert N stops before every switch point; for walking/driving legs treat ~500m ≈ 1 stop so pre-boarding alerts work.
- **Precondition** (stops mode): user cannot set `N >= stopsRemainingToNextSwitch` at the time of starting. If violated, do not navigate to tracking; show an error like “choose < n stops”.
- **Precedence**: if a switch alarm and destination alarm coincide, suppress switch and fire destination alarm only.
- **Reroute**: sustained deviation triggers reroute; route queue/cache should minimize redundant API calls and allow switching back to known routes.

### Notification Lifecycle
- **Journey progress notification** (persistent): appears immediately after tracking starts; reappears if dismissed unless **Ignore** or **End Tracking** pressed.
- **Ignore**: stops persistence but tracking continues in background.
- **End Tracking**: stops tracking fully (service + state), cancels **all notifications**, clears snapshots/state; next app launch behaves like fresh start.
- **Alarm event notification** (switch points): actions are **Stop Alarm** (stop alarm only, auto-dismiss alarm notif) and **End Tracking**.
- **Final destination alarm notification**: only action is **End Tracking**.
- **App swiped away**: journey notif is replaced by a persistent “tracking paused” notif with **Resume Tracking** and **End Tracking**.
	- Tap notif or Resume → open app, restore snapshot, continue tracking, dismiss paused notif, show journey notif again.
	- End → full cleanup, no persistence.
- **Tap behavior**: tapping a notification (not an action button) should land the user back where they left off (restoring snapshot/app state as needed).
- **Reliability**: alarm must fire reliably even when phone is locked; vibration should be in sync with alarm and effective even in silent/vibrate modes.

## Findings

- ✅ FIXED — [lib/services/transfer_utils.dart](lib/services/transfer_utils.dart) — `firstTransitBoardingStops` had a duplicate TRANSIT check and effectively never advanced. It now accumulates non-transit distance as “virtual stops” (~500m = 1) before first boarding.

- ✅ FIXED — [lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart) — `validateThreshold` now interpolates stops at the switch using `stepBoundsMeters` when provided (avoids meters-vs-stops mismatch).

- ✅ FIXED — [lib/services/active_route_manager.dart](lib/services/active_route_manager.dart) — Removed duplicate debug prints.

- ✅ FIXED — [lib/services/active_route_manager.dart](lib/services/active_route_manager.dart) — State emission no longer mixes candidate snap/progress with active route length; candidate values are only used after an actual switch.

- [lib/services/direction_service.dart#L14-L124](lib/services/direction_service.dart#L14-L124) — In-memory directions cache is global and not keyed by origin/destination. Within the freshness window, subsequent calls for a different trip will return the previous route without hitting the API or RouteCache.

- [lib/services/eta_engine.dart#L93-L150](lib/services/eta_engine.dart#L93-L150) — Map-matching skips any segment whose *start* is farther than `2 * maxSnapDistance` from the last snapped point. On routes with long segments or when GPS jumps forward (e.g., after tunnel), the actual nearby segment can be ignored, forcing fallback to the nearest vertex and causing large progress jumps or regressions.

- [lib/services/eta_engine.dart#L278-L305](lib/services/eta_engine.dart#L278-L305) — `computeEta` calls `saveState()` on every GPS update, synchronously writing to SharedPreferences. At 1 Hz this forces constant disk I/O on the main isolate and risks jank.

- ✅ FIXED / NO LONGER OBSERVED — [lib/services/trackingservice.dart](lib/services/trackingservice.dart) — `_onStart` listener setup appears deduplicated (single `startTracking` and `registerRoute` handlers). Keep an eye on regressions here because duplicate listeners are high-impact.

- ✅ FIXED — [lib/services/route_registry.dart](lib/services/route_registry.dart) — `upsert` replaces geometry + derived fields when reusing a key, preventing stale-route snapping after reroutes.

- [lib/services/permission_service.dart#L52-L91](lib/services/permission_service.dart#L52-L91) — Notification permission is short-circuited on iOS (`if (!Platform.isAndroid) return true`), so iOS never requests notification permission and alarms/foreground notifications can be blocked silently.

- [lib/config/playground_bridge.dart#L7-L41](lib/config/playground_bridge.dart#L7-L41) — Playground bridge is enabled by default in all builds unless explicitly disabled with a dart-define. Release/profile devices will attempt to connect to the relay URL (`ws://127.0.0.1:8081`), causing wasted sockets/errors and potential privacy concerns.

- ✅ FIXED — [lib/main.dart](lib/main.dart) — Added `WidgetsFlutterBinding.ensureInitialized()` before `Hive.initFlutter()`.

- [lib/config/app_config.dart#L11-L18](lib/config/app_config.dart#L11-L18) — Server base URL is hardcoded to `http://localhost:3000/api` while ApiClient uses `https://geowake-production.up.railway.app/api`. This dead config can mislead developers and any code that still references `AppConfig.serverBaseUrl` will point to localhost in release builds.

- [lib/screens/maptracking.dart#L139-L211](lib/screens/maptracking.dart#L139-L211) — Route switches are only surfaced as SnackBars; the screen never reloads directions/polylines when `TrackingService` reroutes. `_processDirections` runs once on entry/restore ([lib/screens/maptracking.dart#L280-L374](lib/screens/maptracking.dart#L280-L374)) and `_startLocationUpdates` keeps snapping against the initial `_routePoints` ([lib/screens/maptracking.dart#L403-L470](lib/screens/maptracking.dart#L403-L470)). After a reroute, progress/ETA/switch notices may remain bound to the original geometry while background tracking uses the new route.

- [lib/screens/maptracking.dart#L826-L884](lib/screens/maptracking.dart#L826-L884) — “END TRACKING” calls `TrackingService().completeEndTracking()` and then triggers a local navigation to `/`, while the screen also disables back navigation via `PopScope(canPop: false)`.

### Notifications / UX (Spec Alignment)
- ⚠️ OPEN — [lib/services/notification_service.dart](lib/services/notification_service.dart) — Notification “tap” behavior always navigates to `/mapTracking`. Spec requires “tap returns user to where they left off” (and paused notif tap should restore + resume).
- ⚠️ OPEN — Paused-after-swipe behavior (journey notif replaced by paused notif with Resume/End) is not fully implemented end-to-end. Requires a reliable signal when the app task is removed/backgrounded while service remains.
- ⚠️ OPEN — Background action reliability: action handlers executed from `notificationTapBackground` cannot navigate. Spec requires Resume tap to bring user back and restore session; needs “pending navigation” persistence and handling on next app launch.

- ✅ FIXED — [lib/screens/homescreen.dart](lib/screens/homescreen.dart) + [lib/services/tracking_state_store.dart](lib/services/tracking_state_store.dart) — Tracking sessions now persist `tracking_active_v1` and a full `TrackingSnapshot` (destination/alarm params/metroMode/user location/directions) when tracking starts. This enables restore/resume flows to be grounded in real persisted state.

- ✅ FIXED — [lib/services/notification_service.dart](lib/services/notification_service.dart) — Added a dedicated “Tracking paused” notification (ID 889) with Resume/End Tracking and updated tap handling so paused-notif tap triggers resume behavior.

- ✅ FIXED — [lib/services/notification_service.dart](lib/services/notification_service.dart) — Alarm stop/end paths now clear persisted alarm flags and pending-alarm SharedPreferences keys, and also send a `stopAlarm` message to the background service to ensure alarms stop even if the alarm was started in the background isolate.

- ✅ FIXED — [lib/services/trackingservice.dart](lib/services/trackingservice.dart) — Foreground startTracking now sets `tracking_active_v1=true` and clears alarm-fired state; background startTracking mirrors the active flag and fixes the initial notification subtitle encoding.
