# GeoWake Behavior Checklist (Spec → Implementation)

This is the **authoritative checklist** derived from your requirements.
Each item should be mapped to:
- the implementing code path(s)
- tests that validate it
- open findings when behavior is missing or inconsistent

## A. Exclusions (skip for now)
- EKF
- Dead reckoning
- AI voice integration
- Premium mode
- Ad placement

## B. Notifications

### B0. Implementation pointers (current code paths)
- App routes + initial navigation: [lib/main.dart](lib/main.dart#L1-L200)
- Service init + restore routing: [lib/screens/splash_screen.dart](lib/screens/splash_screen.dart#L1-L170)
- Map warm-up handoff: [lib/screens/otherimpservices/preload_map_screen.dart](lib/screens/otherimpservices/preload_map_screen.dart#L1-L120)
- Destination selection + tracking start + snapshot save: [lib/screens/homescreen.dart](lib/screens/homescreen.dart#L1-L620)
- MapTracking UI + restore + End Tracking button: [lib/screens/maptracking.dart](lib/screens/maptracking.dart#L59-L910)
- Essential permissions flow (dialogs + settings redirect): [lib/services/permission_service.dart](lib/services/permission_service.dart#L1-L180)
- Server-backed Maps API client (auth + requests): [lib/services/api_client.dart](lib/services/api_client.dart#L1-L462)
- Places autocomplete + place details normalization: [lib/services/places_service.dart](lib/services/places_service.dart#L1-L99)
- Metro stop pre-validation helpers: [lib/services/metro_stop_service.dart](lib/services/metro_stop_service.dart#L1-L188)
- Recent destination history persistence (Hive): [lib/screens/otherimpservices/recent_locations_service.dart](lib/screens/otherimpservices/recent_locations_service.dart)
- Notification init + tap/action handlers: [lib/services/notification_service.dart](lib/services/notification_service.dart#L1-L620)
- Alarm audio playback + isPlaying UI latch: [lib/services/alarm_player.dart](lib/services/alarm_player.dart#L1-L98)
- Tracking start/end called by notification actions: [lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1-L260)
- Power policy knobs (accuracy/distanceFilter/dropout/notification tick/reroute cooldown): [lib/config/power_policy.dart](lib/config/power_policy.dart)
- Simulation position source + debug state/route broadcasts: [lib/services/simulation_client.dart](lib/services/simulation_client.dart)
- Optional sensor-fusion position helper (accelerometer-based dead reckoning): [lib/services/sensor_fusion.dart](lib/services/sensor_fusion.dart)
- Playground bridge enablement + relay URL (build flags + FLUTTER_TEST gate): [lib/config/playground_bridge.dart](lib/config/playground_bridge.dart)
- Active route switching + remaining meters state: [lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L1-L231)
- Route registry (cached geometry + session snap/progress): [lib/services/route_registry.dart](lib/services/route_registry.dart#L1-L216)
- Snap-to-route primitive (snapped point + progress meters): [lib/services/snap_to_route.dart](lib/services/snap_to_route.dart#L1-L116)
- ETA-from-steps helper (progress → seconds remaining): [lib/services/eta_utils.dart](lib/services/eta_utils.dart#L1-L34)
- ETA engine (map-match + speed smoothing + sigma): [lib/services/eta_engine.dart](lib/services/eta_engine.dart) (workspace search did not find call sites in `lib/`; tracking loop also maintains its own `_smoothedETA` state)
### B1. Journey progress notification lifecycle
- [ ] B1.1 When “Wake Me” starts tracking and navigation reaches MapTracking, show a persistent journey notification.
- Observed implementation path: progress notification is shown from both foreground start and background `startTracking` listener; MapTracking navigation typically passes through `/preloadMap`.
- [ ] B1.2 If user dismisses the journey notification by swiping it away, it reappears automatically unless Ignore or End Tracking was pressed.
- [ ] B1.3 Ignore stops persistence but tracking continues.
- [ ] B1.4 End Tracking stops all tracking, cancels all notifications (journey + alarms), clears snapshots/state; next app launch is fresh.
- Observed implementation path: `TrackingService.completeEndTracking()` clears SharedPreferences flags and cancels notifications, then navigates to `/` when allowed. See [lib/services/trackingservice.dart](lib/services/trackingservice.dart#L180-L240) and [lib/services/notification_service.dart](lib/services/notification_service.dart#L520-L610).

### B2. Alarm notification behavior
- [ ] B2.1 At each switch point, show an alarm/event notification with Stop Alarm + End Tracking.
- [ ] B2.2 Stop Alarm stops alarm/vibration/sound and auto-dismisses the alarm notification; tracking continues.
- [ ] B2.3 Final destination alarm shows only End Tracking.
- [ ] B2.4 If switch alarm and destination alarm coincide, suppress switch and fire destination.

### B3. Paused-after-swipe behavior
- [ ] B3.1 When user swipes away the app task while tracking is active, journey notification is replaced by a persistent “tracking paused” notification.
- [ ] B3.2 Paused notification provides Resume Tracking + End Tracking.
- [ ] B3.3 Tapping paused notification OR Resume opens app and restores last snapshot and resumes tracking.
- [ ] B3.4 After resuming, paused notification dismisses and journey progress notification returns.
- [ ] B3.5 End Tracking from paused notification performs full cleanup (same as B1.4).

### B4. Notification tap navigation
- [ ] B4.1 Tapping any notification body (not an action button) lands the user where they left off (restores state if needed).
- Observed implementation path: tap (no actionId) currently navigates via global navigator key; background taps suppress navigation. See [lib/services/notification_service.dart](lib/services/notification_service.dart#L60-L120) and [lib/services/notification_service.dart](lib/services/notification_service.dart#L560-L620).
- Observed restore behavior on MapTracking: if `/mapTracking` is pushed without arguments, `MapTrackingScreen` attempts to restore from `TrackingStateStore` snapshot and will return to `/` if restore is not possible. See [lib/screens/maptracking.dart](lib/screens/maptracking.dart#L59-L279).

### B5. Reliability constraints
- [ ] B5.1 Alarm fires reliably when phone is locked.
- [ ] B5.2 Vibration plays in sync with alarm sound and works in silent/vibrate modes.

## C. Tracking behavior
### C1. Modes
- [ ] C1.1 Metro OFF: fetch optimal normal route; alarms based on distance/time.
- [ ] C1.2 Metro ON: fetch optimal route including metro.
- Observed implementation path: HomeScreen computes `alarmMode` as `distance`/`time`, but when metro mode is enabled and the distance-mode UI is selected, it sends `alarmMode='stops'` and `alarmValue=_stopsSliderValue` into `TrackingService.startTracking(...)`. See [lib/screens/homescreen.dart](lib/screens/homescreen.dart#L541-L601).

### C2. Stops mode (metro ON)
- [ ] C2.1 Switch alarms trigger N stops before each switch point.
- [ ] C2.2 For walking/driving legs approaching first boarding, treat ~500m as one stop so “N stops prior” works as distance prior.
- [ ] C2.3 Prevent user from starting if `N >= stopsRemainingToNextSwitch` at start (show error; do not navigate).
- [ ] C2.4 Final destination alarm triggers at N “stops-equivalent” prior.

- Observed implementation artifact: [lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L24) provides `calculateRemainingStops(...)` which selects the next unfired `RouteEventBoundary` (with a 500m overshoot tolerance) and returns both `remainingStops` to that target and `remainingStopsToDestination`.
- Observed implementation artifact: the same helper applies a hybrid “virtual stops” conversion for non-transit legs when the transit-stop delta is near zero: if `remainingStops < 0.1` and the remaining distance is positive, it uses `dist/500.0` (500m = 1 stop) ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L98-L121)).
- Observed implementation artifact: [lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L285) provides `validateThreshold(...)` which computes a `maxStops` cap, optionally limited to the interpolated stop count at the first route event (requires `stepBoundsMeters`), and returns `(isValid, maxStops, errorMessage)`.
- Observed implementation artifact: [lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L99) provides `buildRouteEvents(...)` which emits `RouteEventBoundary` entries (`type: 'transfer' | 'mode_change'`) keyed by cumulative meters, which are then used by tracking/stops logic as the ordered “switch point” list.
- Observed implementation artifact: [lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L313) provides `firstTransitBoardingStops(...)`, which converts non-transit approach distance into “virtual stops” via `distance/500.0` until the first `TRANSIT` step.

### C3. Time mode
- [ ] C3.1 Trigger N minutes before every switch point.

### C4. Deviation/reroute
- [ ] C4.1 Sustained deviation triggers reroute policy.
- [ ] C4.2 Route queue minimizes API calls; switching back to previously known route should reuse cached geometry.

- Observed implementation path: `TrackingService.registerRouteFromDirections(...)` initializes a `DeviationMonitor` and `ReroutePolicy`, then ingests lateral offset values (computed via `SnapToRouteEngine.snap`) into `DeviationMonitor.ingest(...)` via the ActiveRouteManager state stream ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1433-L1476)).
- Observed implementation path: sustained deviation handling in `TrackingService` uses offset bands:
	- `<100m` ignored as noise;
	- `100–150m` attempts a local switch to a better registered route (no network);
	- `>150m` calls `ReroutePolicy.onSustainedDeviation(...)` (subject to policy cooldown/online gating) ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1539-L1579)).
- Observed implementation artifact: [lib/services/deviation_monitor.dart](lib/services/deviation_monitor.dart#L13-L78) uses a speed-based high/low threshold model (hysteresis) and a sustain timer to emit `DeviationState(offroute, sustained, offsetMeters, speedMps, at)`.

- Observed implementation artifact: [lib/services/reroute_policy.dart](lib/services/reroute_policy.dart#L12-L54) gates reroute decisions on `_online` and `_cooldown` and emits `RerouteDecision(shouldReroute, at)` on a broadcast stream.
- Observed implementation artifact: `TrackingService.setOnline(bool)` forwards connectivity into both the reroute policy and the offline coordinator ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1360-L1363)).
- Observed implementation artifact: [lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L83-L151) returns cache-only routes when offline (throws if none) and delegates to a directions provider when online.
- Observed implementation artifact: [lib/services/direction_service.dart](lib/services/direction_service.dart#L36-L171) uses persistent `RouteCache` when not force-refreshing, enforces a tiered refresh interval, persists network responses to `RouteCache`, and retries once with `forceRefresh:true` on failure.

- Observed implementation artifact: [lib/services/route_cache.dart](lib/services/route_cache.dart#L53-L152) defines `RouteCache` with:
	- keying via a JSON-string payload with origin/destination rounded to 5 decimals and optional `transitVariant` ([lib/services/route_cache.dart](lib/services/route_cache.dart#L81-L92));
	- default TTL eviction of 5 minutes ([lib/services/route_cache.dart](lib/services/route_cache.dart#L56-L58), [lib/services/route_cache.dart](lib/services/route_cache.dart#L116-L122));
	- default origin-deviation invalidation at 300m ([lib/services/route_cache.dart](lib/services/route_cache.dart#L59-L60), [lib/services/route_cache.dart](lib/services/route_cache.dart#L124-L134)).
- Observed implementation artifact: [lib/services/route_queue.dart](lib/services/route_queue.dart#L1-L52) defines a singleton in-memory queue for `RouteModel` with `maxSize=8` and an active index; workspace search did not find call sites in `lib/`.

## D. Test coverage expectations
- [ ] D1 Add unit tests for notification action classification (IGNORE/STOP_ALARM/END_TRACKING/RESUME).
- [ ] D2 Add tests for “destination beats switch when coincident”.
- [ ] D3 Add tests for stops constraint at start (N too large blocks start).
- [ ] D4 Add tests for paused-notification state persistence and resume behavior (as much as possible in unit tests).
