# CALL_FLOWS (Android)

## Startup
1. `main()` (lib/main.dart) initializes Hive and runs `MyApp`; lifecycle observer forwards `didChangeAppLifecycleState` to `TrackingService().handleAppLifecycleChange`.
2. Initial route `/splash` -> `SplashScreen` (lib/screens/splash_screen.dart) `initState` kicks `_initializeServices`: ApiClient.initialize, `NotificationService.initialize`, `TrackingService.initializeService` (configures flutter_background_service with `_onStart`).
3. `_checkStateAndNavigate` reads `TrackingStateStore.isAlarmFired()`; if true invokes `TrackingService.completeEndTracking(navigateHome:false)` to clear zombie alarm then navigates home. Otherwise waits for `_initFuture` (timeout 8s) then routes to `/mapTracking` when `TrackingStateStore.isActive()` else `/`.

## Start tracking (UI isolate -> background)
1. HomeScreen user selects destination; before navigation it persists snapshot via `TrackingStateStore.saveSnapshot` (homescreen.dart) and sets active flags.
2. UI calls `TrackingService.startTracking(destination,...,alarmMode,value)` (trackingservice.dart). Method ensures ack listeners, starts background service if needed, marks `TrackingStateStore` active/paused false/alarmFired false, shows journey progress notification, and invokes `_invokeWithAckRetry` for `startTracking` (payload: destinationLat/lng/name, alarmMode/value, useInjectedPositions, optional routePoints) expecting `startTrackingAck`.
3. Background `_onStart` (trackingservice.dart) receives `startTracking` event, acks, resets route state, sets `_trackingSessionActive=true`, persists active flags, optionally restores directions from snapshot, connects SimulationClient, and calls `startLocationStream(service)`.
4. `startLocationStream` chooses simulation/injected/geolocator stream based on flags, starts heartbeat monitor, and listens for positions. Each GPS update feeds ActiveRouteManager/deviation/reroute, invokes `_checkAndTriggerAlarm`, updates notifications, broadcasts simulation state, and invokes `updateLocation` on service.

## Stop tracking
- Foreground stop: `TrackingService.stopTracking(stopServiceInstance)` stops heartbeats, stops alarm locally, invokes background `stopTracking` (with stopSelf flag) if service running, else `_onStop` cleanup.
- Background listener `service.on("stopTracking")` runs `_onStop()` (cancels streams, managers, alarms, clears registry) and `service.stopSelf()` when requested.
- `completeEndTracking` (foreground) additionally clears snapshot/flags and cancels all notifications via NotificationService then optional navigation home.
- Notification actions: foreground END_TRACKING directly invokes `FlutterBackgroundService().invoke('stopTracking', {'stopSelf': true})` and `TrackingService.completeEndTracking`; background callback `notificationTapBackground` persists end-tracking request (file flag + prefs) and best-effort invokes `stopTracking`.

## Alarm trigger
1. `_checkAndTriggerAlarm` (trackingservice.dart) runs on every position: computes distance/time/stops thresholds using `_routeEvents`/snap progress. When alarm condition met it calls `_triggerAlarmNotification`.
2. Foreground branch calls `NotificationService.showWakeUpAlarm` directly. Background branch sends `triggerAlarm` invoke to foreground; `_ensureAckListenersRegistered` listener invokes NotificationService.showWakeUpAlarm.
3. NotificationService.showWakeUpAlarm stores pending alarm prefs, shows full-screen notification with STOP_ALARM/END_TRACKING actions, starts AlarmPlayer + vibration, sets `TrackingStateStore.setAlarmFired(true)`.
4. `_startAlarmStopPollTimer` begins 200ms polling in background isolate to consume file-flag requests for STOP_ALARM/MUTE/END_TRACKING via NotificationService.consume*; stops alarm/notifications and can stop service when end requested.

## Offline/online & reroute
- HomeScreen subscribes to Connectivity; sets `_offline` and calls `TrackingService().setOnline(!_noConnectivity)` (homescreen.dart).
- Reroute/deviation handling inside trackingservice via `OfflineCoordinator`, `DeviationMonitor`, `ReroutePolicy`, and `ActiveRouteManager`; route switches broadcast through `_routeSwitchCtrl` to UI (maptracking listens to `routeSwitchStream`).
