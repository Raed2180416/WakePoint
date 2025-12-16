# GeoWake System Map (How It All Ties Together)

This is a living architecture map: modules, ownership boundaries, state flows, and timelines.

## 1. Main runtime components
### UI (main isolate)
- Screens: Home → MapTracking
- User initiates tracking from Home.
- UI reads/writes persisted state via TrackingStateStore and other stores.

### Background tracking (background isolate via flutter_background_service)
- Entry: TrackingService._onStart
- Inputs: startTracking/registerRoute/stopTracking events (from UI)
- Loop: position stream → ActiveRouteManager/DeviationMonitor → alarm checks → notification updates

### Persistence
- TrackingStateStore (SharedPreferences): active flag, snapshot, muted flag, progress payload, alarm fired flag.

### Notifications + alarm output
- NotificationService: creates channels; shows journey progress and alarm notifications; handles action responses.
- AlarmPlayer: plays looping sound via audioplayers; attempts to stop vibration via NotificationService.

### Dev / simulation tooling
- Playground relay bridge gating + URL: `PlaygroundBridgeConfig` (disabled under Flutter tests).
- Device-side simulation bridge: `SimulationClient` (WebSocket) can supply synthetic `Position` updates to TrackingService and can broadcast route/state out.
- Web dashboard: `main_dashboard.dart` consumes route/state from the relay and uses `SimulationEngine` to emit ghost positions back to the relay.
	- Receives: `route_update`, `app_state`, `ping` (responds with `pong`).
	- Sends: `simulation_update` (lat/lng/timestamp) when simulation is playing.
- Local demo triggers: `DevServer` exposes `/demo/*` endpoints that call `DemoRouteSimulator` to start tracking and fire demo alarms.

### Config + test gating (selected)
- `AppConfig` hard-disables direct Google Maps API key access (throws) and defines a server base URL constant.
- Flutter test detection (`detectFlutterTest`) has IO + non-IO implementations and is used by `PlaygroundBridgeConfig` to auto-disable the bridge during `flutter test`.

## 2. State ownership rules (to validate)
- TrackingStateStore is the source of truth for “isActive”, “snapshot”, and “notificationsMuted”.
- Background isolate should be the source of truth for “current progress” and “alarm fired in this session”.

## 3. Timelines (to fill in during deep review)
### T0. Cold start → Splash → warm-up map → Home/MapTracking (as implemented)
1) `main()` ensures `WidgetsFlutterBinding.ensureInitialized()` and runs `Hive.initFlutter()`.
2) `MyApp` registers as a lifecycle observer; on `paused` it flushes the Hive box used by `RecentLocationsService` (if open).
3) `MaterialApp` uses `navigatorKey` (global) and `initialRoute: '/splash'` with `onGenerateRoute` handling:
	- `'/splash'` → `SplashScreen`
	- `'/preloadMap'` → `PreloadMapScreen(arguments: settings.arguments as Map<String, dynamic>)`
	- `'/mapTracking'` → `MapTrackingScreen()`
	- `'/'` → `HomeScreen`
4) `SplashScreen.initState()` kicks off `_initializeServices()` and then `_checkStateAndNavigate()`.
5) `_initializeServices()` attempts (in order): `ApiClient.initialize()`, `NotificationService.initialize()`, `TrackingService.initializeService()`.
6) `_checkStateAndNavigate()` behavior:
	- If `TrackingStateStore.isAlarmFired()` is true: calls `TrackingService.completeEndTracking(navigateHome: false)` then navigates to `'/'`.
	- Else waits for `_initializeServices()`.
	- If `TrackingStateStore.isActive()` is true: navigates to `'/preloadMap'` with `{ nextRoute: '/mapTracking' }`.
	- Else after a ~3s splash delay: navigates to `'/preloadMap'` with `{ nextRoute: '/' }`.
7) `PreloadMapScreen` renders a minimal `GoogleMap` and, once created, waits ~700ms then `pushReplacementNamed` to `nextRoute`.
	- Default `nextRoute` is `'/mapTracking'`.
	- If `nextRoute == '/mapTracking'` and `nextArgs` is absent, it passes through the original `arguments`.
	- Otherwise it navigates to `nextRoute` with `nextArgs`.
### T1. Start tracking
1) Home computes directions, starts the background service tracking session, registers route data, and persists a `TrackingSnapshot`.
2) Home navigates to `'/preloadMap'` with a map-args payload (no `nextRoute`, so preload defaults to `'/mapTracking'`).
3) `PreloadMapScreen` warms up the map view and hands off to `'/mapTracking'`.
4) `MapTrackingScreen.didChangeDependencies()`:
	- If it receives args: uses them to render the route and starts UI subscriptions.
	- If args are missing: attempts restore via `TrackingStateStore.isActive()` + `TrackingStateStore.loadSnapshot()`.
5) Foreground `TrackingService.startTracking()` (non-test) sets `tracking_notifications_muted_v1` to false and shows an initial “journey progress” notification.
6) Background isolate `_onStart` receives `startTracking` and (non-test) also calls `NotificationService.showJourneyProgress(...)` immediately.

### T2. Alarm trigger
1) Background computes approaching switch/destination
2) Alarm notification shown + AlarmPlayer starts
3) User action routes to STOP_ALARM or END_TRACKING

### T2a. Notification tap/actions (foreground vs background)
- Foreground callback (`onDidReceiveNotificationResponse`) calls `NotificationService.handleNotificationResponse(..., allowNavigation: true)`.
	- If user tapped the notification body (no actionId): navigates to `'/mapTracking'` via `pushNamedAndRemoveUntil`.
	- If user tapped an action button: routes to one of `muteJourney`, `cancelAlarm`, `resumeTracking`, `endTracking`, `stopAlarm`, `dismissAlarm`.
- Background callback (`notificationTapBackground`) calls `handleNotificationResponse(..., allowNavigation: false)`.
	- Navigation is suppressed; action handlers still run (e.g., `END_TRACKING` calls `TrackingService.completeEndTracking()`).

### T3. App task removed (paused mode)
1) Detect task removal
2) Replace journey notification with paused notification
3) Resume tap restores session + returns to journey notification

## 5. Persisted keys (SharedPreferences)
- `tracking_active_v1` (bool)
- `tracking_snapshot_v1` (json string)
- `tracking_notifications_muted_v1` (bool; removed when false)
- `gw_progress_payload_v1` (json string)
- `tracking_alarm_fired_v1` (bool)

## 4. Cross-link pointers
- Findings log: review/lib_audit.md
- Process: review/review_process.md
- Spec checklist: review/spec_checklist.md
