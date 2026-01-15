# Critical User Flows — End-to-End Traces

## Required flows

1) New user sets destination → starts tracking
2) App backgrounded → continues tracking → triggers alarm
3) App killed/process death → restore state → user safety preserved
4) Network loss/offline behavior
5) GPS degradation behavior
6) Metro/stops mode behavior (if present)

## Trace format

For each flow:
- **Preconditions** (permissions, settings, state)
- **Step-by-step trace** (who calls what)
- **State transitions** (in-memory and persisted)
- **Failure branches** (what breaks, what user sees)
- **Expected vs actual** (from runtime logs/tests where possible)
- **Findings** (each with Evidence/Impact/Repro/Fix/Severity/Confidence)

## Flow 1 — Start tracking (primary)

### Preconditions

- User has selected a destination in `HomeScreen` (`_selectedLocation != null`).
- Permissions granted via `PermissionService.requestEssentialPermissions()`.

### Step-by-step trace (confirmed code path)

1. **User taps “Wake Me!”**
	- **Entry**: `HomeScreen._onWakeMePressed()`
	- **Evidence**: `lib/screens/homescreen.dart` [L447-L505]

2. **Permission gating**
	- Calls `PermissionService(context).requestEssentialPermissions()`.
	- If denied: `_isLoading=false`, tracking does not start.
	- **Evidence**: `lib/screens/homescreen.dart` [L473-L505]

3. **Acquire current location**
	- Uses cached location if <30s old; else calls `_getCurrentLocation()`.
	- If null: shows “Location Error” dialog and aborts.
	- **Evidence**: `lib/screens/homescreen.dart` [L518-L590]

4. **Validate route constraints (state boundary + metro mode)**
	- Runs `_validateSameState(...)` in parallel with directions fetch.
	- Optional metro validation: `MetroStopService.validateMetroRoute(...)`.
	- Failures show dialogs and abort.
	- **Evidence**: `lib/screens/homescreen.dart` [L606-L650]

5. **Fetch directions (offline-aware)**
	- Uses `_offline.getRoute(...)` inside `_fetchDirections(...)`.
	- If offline with no cache: throws “Offline with no cached route available.”
	- **Evidence**: `lib/screens/homescreen.dart` [L845-L896]

6. **Compute alarm mode/value and validate stops thresholds (metro/stops)**
	- For metro + “stops”: uses `StopLogicEngine.validateThreshold(...)` and `validateThresholdAgainstMetroLegs(...)`.
	- Invalid thresholds show dialogs and abort.
	- **Evidence**: `lib/screens/homescreen.dart` [L650-L705]

7. **Persist session snapshot + flags**
	- Writes:
	  - `TrackingStateStore.setActive(true)`
	  - `TrackingStateStore.setAlarmFired(false)`
	  - `TrackingStateStore.setNotificationsMuted(false)`
	  - `TrackingStateStore.saveSnapshot(TrackingSnapshot(..., directions: directions))`
	- **Evidence**: `lib/screens/homescreen.dart` [L706-L736]

8. **Start background tracking**
	- Calls `TrackingService().startTracking(destination, destinationName, alarmMode, alarmValue, transitMode)`.
	- Inside `TrackingService.startTracking()`:
	  - Ensures foreground listeners are registered (ACK + triggerAlarm listener).
	  - Starts background service if not running.
	  - Sets TrackingStateStore flags and shows initial journey notification.
	  - Invokes background `startTracking` with ACK-retry; fallback invoke if no ACK.
	- **Evidence**:
	  - UI call: `lib/screens/homescreen.dart` [L742-L752]
	  - Service start: `lib/services/trackingservice.dart` [L202-L314]

9. **Register route with the background isolate (fire-and-forget)**
	- Calls `TrackingService.registerRouteFromDirections(... activateRoute: true)` unawaited.
	- Intended to allow background alarm evaluation to become route-aware.
	- **Evidence**: `lib/screens/homescreen.dart` [L759-L791]

10. **Navigate to tracking UI**
	- Pushes `'/preloadMap'` then eventually tracking map UI.
	- **Evidence**: `lib/screens/homescreen.dart` [L817-L835]

### Failure branches (confirmed)

- Destination missing → dialog → no tracking start. (`HomeScreen._onWakeMePressed`)
- Permission denied → no tracking start. (`PermissionService.requestEssentialPermissions`)
- Current location unavailable → dialog → abort. (`_getCurrentLocation`)
- State boundary validation fails → dialog → abort.
- Metro validation fails → dialog → abort.
- Directions fetch fails (offline/no cache) → abort.
- Stops-mode threshold invalid → dialog → abort.

### Findings

- **Severity**: MEDIUM
  - **Evidence**: `lib/screens/homescreen.dart` [L759-L791]; `lib/services/trackingservice.dart` [L1496-L1545]
  - **Impact**: If route registration invoke is dropped/delayed, alarm evaluation may start with incomplete route context (depends on restore path correctness).
  - **Repro/Trigger**: Start tracking under heavy load / service startup delays where foreground→background invoke ACK fails.
  - **Fix**: Treat route snapshot restore as authoritative and verify it runs before enabling alarm checks; add explicit “route ready” gating or buffering.
  - **Confidence**: MEDIUM (needs confirm of ordering in background loop)

## Flow 2 — Background tracking → alarm

### Background isolate start

1. Background service entrypoint runs: `_onStart(...)`.
	- Initializes notification plugin in background isolate.
	- Registers BackgroundHandlers listeners (`startTracking`, `stopAlarm`, `registerRouteDirections`, etc.).
	- **Evidence**: `lib/services/trackingservice.dart` [L1718-L1860]; `lib/services/tracking/background_handlers.dart` [L1-L120]

2. Foreground invokes `startTracking` → background handler receives → `_handleBackgroundStartTracking(...)`.
	- Resets prior-session state.
	- Persists `TrackingStateStore` active/paused/alarmFired.
	- Kicks off snapshot restore: `SnapshotRouteRestorer.restoreFromStoreIfActiveAndNotPaused(...)`.
	- Starts location stream via `startLocationStream(service)`.
	- **Evidence**: `lib/services/trackingservice.dart` [L1442-L1608]

### Location updates → alarm evaluation

3. `LocationStreamHandler` subscribes to `LocationManager().positionStream` and on each update:
	- Updates travel/ETA state.
	- Calls `onCheckAlarm(position, service)` with a sequential guard.
	- **Evidence**: `lib/services/tracking/location_stream_handler.dart` [L118-L205]

4. Alarm check entrypoint `_checkAndTriggerAlarm(position, service)` builds `AlarmContext` and delegates to `AlarmController.checkAndTriggerAlarm(...)`.
	- **Evidence**: `lib/services/trackingservice.dart` [L1124-L1252]

5. `AlarmController.checkAndTriggerAlarm(...)` evaluates triggers and, when firing:
	- Calls `triggerAlarmNotification(...)`.
	- Starts a fast poll timer (200ms) to consume Stop/Mute/End requests.
	- **Evidence**: `lib/services/tracking/alarm_controller.dart` [L309-L360] and [L980-L1110]

### Alarm delivery (foreground vs background branch)

6A. **Background isolate branch**: `AlarmController.triggerAlarmNotification(...)` invokes `service.invoke('triggerAlarm', {..., playSound:true})`.
	- **Evidence**: `lib/services/tracking/alarm_controller.dart` [L262-L308]

6B. **Foreground isolate branch**: `ForegroundBridge` listens to `triggerAlarm` and calls `NotificationService.showWakeUpAlarm(...)`.
	- **Evidence**: `lib/services/tracking/foreground_bridge.dart` [L67-L218]

7. `NotificationService.showWakeUpAlarm(...)` posts a full-screen alarm notification and starts sound/vibration (parallel).
	- Persists “pending_alarm_*” in SharedPreferences.
	- **Evidence**: `lib/services/notification_service.dart` [L600-L779]

### Failure branches / unknowns

- UNKNOWN: Whether Android OEM/background restrictions allow the foreground service + notification + audio/vibration to remain reliable when the OS kills the app process.
- UNKNOWN: Whether the app handles notification actions when *no* tracking isolate is running.


## Flow 3 — Process death → restore safety

### Preconditions

- App process starts and shows `SplashScreen`.
- `TrackingStateStore` persisted flags represent prior session state.

### Step-by-step trace (confirmed code path)

1. `SplashScreen.initState()` starts `_initializeServices()` and then `_checkStateAndNavigate()`.
	- `_initializeServices()` initializes `ApiClient`, `NotificationService`, `TrackingService`.
	- **Evidence**: `lib/screens/splash_screen.dart` `_initializeServices()`

2. Zombie-alarm cleanup path:
	- Reads `TrackingStateStore.isAlarmFired()`.
	- If true: calls `TrackingService().completeEndTracking(navigateHome:false)` and navigates to `/`.
	- **Interpretation**: on restart after a firing alarm, it attempts to prevent “stuck alarm/tracking” state.
	- **Evidence**: `lib/screens/splash_screen.dart` `_checkStateAndNavigate()`

3. Restore-session path:
	- Waits for `_initFuture` up to 8 seconds (timeout swallowed).
	- Reads `TrackingStateStore.isActive()`.
	- If active: loads snapshot via `TrackingStateStore.loadSnapshot()`.
	- If snapshot or `snapshot.directions` is null: calls `completeEndTracking(...)` and navigates home.
	- Else: navigates to `/mapTracking` with snapshot fields (destination, directions, metroMode, userLat/userLng, alarm mode/value).
	- **Evidence**: `lib/screens/splash_screen.dart` `_checkStateAndNavigate()`

4. Non-restore path:
	- If not active: waits ~3s then navigates to `/`.
	- **Evidence**: `lib/screens/splash_screen.dart` `_checkStateAndNavigate()`

### Failure branches (confirmed)

- If the persisted snapshot is missing/corrupt (null directions), the app explicitly cleans up state and refuses to restore tracking.
- If init takes too long (>8s), restore decision continues anyway (risk: some services may not be ready when the mapTracking route loads).

### Findings

- **Severity**: HIGH
  - **Evidence**: `lib/screens/splash_screen.dart` `_checkStateAndNavigate()` (restore is gated on `snapshot.directions != null`)
  - **Impact**: If tracking is active but snapshot directions are missing/corrupt, the restore path force-ends tracking. This is safer than running blind, but can cause a silent “tracking stopped” after OS kill if snapshot persistence fails.
  - **Repro/Trigger**: Persisted snapshot write fails, is truncated, or migration breaks; app restarts with `isActive=true`.
  - **Fix**: Make snapshot persistence atomic and verifiable (checksum/version), and surface a user-visible recovery prompt explaining that tracking could not be safely restored.
  - **Confidence**: HIGH

### What runtime evidence is still required

- Device run: start tracking → swipe away / force-stop (as applicable) → relaunch → verify whether tracking safely restores or safely terminates with clear user feedback.

### Related behavior: “swiped away” detection via heartbeat timeout (not a true process-death restore)

- **Intent**: When the foreground Flutter process is swiped away/killed but the background service isolate remains, detect loss of foreground heartbeats and mark tracking “paused”, then present a “tracking paused” notification.
- **Mechanism**:
	- Foreground sends periodic heartbeats (see `ForegroundBridge.startHeartbeat()`; currently 1s cadence).
	- Background `HeartbeatMonitor` runs a periodic check (`checkInterval=2s`, `timeout=4s`).
	- On timeout and if `TrackingStateStore.isActive()==true` and not already paused:
		- Sets `TrackingStateStore.setPaused(true)`
		- Cancels journey progress notification
		- Shows “tracking paused” notification with destination name (if snapshot exists)
		- Stops monitoring while paused
- **Evidence**: `lib/services/tracking/heartbeat_monitor.dart` `HeartbeatMonitor.start()`
- **Safety note**: This is a “foreground gone” detector, not proof of full OS process death. It still affects restore semantics because it flips `tracking_paused_v1`.

## Flow 4 — Offline

### Preconditions

- Connectivity callbacks must be active (HomeScreen subscription to `connectivity_plus`).

### Step-by-step trace (confirmed)

1. HomeScreen listens to connectivity changes (`Connectivity().onConnectivityChanged`).
	- Sets `_noConnectivity = results.contains(ConnectivityResult.none)`.
	- Propagates offline status to:
		- `OfflineCoordinator.instance.setOffline(_noConnectivity)` (directions fetch path)
		- `TrackingService().setOnline(!_noConnectivity)` (reroute gating)
	- **Evidence**: `lib/screens/homescreen.dart` `initState()` connectivity subscription

2. Directions fetching uses `OfflineCoordinator.getRoute(...)`.
	- If `_isOffline == true`:
		- Reads from `RouteCache.get(...)` using mode (`driving` or `transit`) and transitVariant (`rail` for transit).
		- If no cached entry: throws `StateError('Offline and no cached route available')`.
		- If cached entry exists: returns cached directions with `RouteSource.cache`.
	- If `_isOffline == false`: fetches via `DirectionService.getDirections(...)` and returns `RouteSource.network`.
	- **Evidence**: `lib/services/offline_coordinator.dart` `OfflineCoordinator.getRoute()`

3. RouteCache constraints (affect “offline works” claim):
	- Default TTL is 5 minutes; stale entries are evicted on read.
	- Cache is invalidated if origin deviates >= 300m from cached origin.
	- Box open failures delete/recreate the box (data loss).
	- **Evidence**: `lib/services/route_cache.dart` `RouteCache.get()` / `_ensureOpen()`

### Failure branches / safety impact

- Offline during **initial route fetch**:
	- If no cache hit (or TTL/origin-deviation invalidation), the UI will fail route acquisition (exception path). Safety outcome depends on UX handling (must not “start tracking blind”).

- Offline during **reroute**:
	- `_handleRerouteDecision()` refuses reroute when offline (`offlineCoord == null || offlineCoord.isOffline`) and records reroute failure.
	- **Evidence**: `lib/services/trackingservice.dart` `_handleRerouteDecision()`

### Findings

- **Severity**: MEDIUM
	- **Impact**: “Offline mode” is effectively “use cache if still fresh and origin hasn’t drifted too much.” It is not a robust offline plan for longer durations.
	- **Fix**: Consider a longer offline TTL, offline-specific cache policy, and clearer user messaging (“offline route unavailable; tracking not started”).
	- **Confidence**: HIGH

## Flow 5 — GPS degradation

- Background location handler includes dropout detection and starts `SensorFusionManager` after `gpsDropoutBuffer`.
- **Evidence**: `lib/services/tracking/location_stream_handler.dart` [L360-L456]
- **Confidence**: MEDIUM (sensor fusion is explicitly deprecated and EKF not implemented; needs runtime verification)

## Flow 6 — Metro/stops mode

- Stops-mode thresholds are validated against step bounds and minimum metro leg stops before tracking starts.
- Alarm controller enforces one-alarm-per-leg semantics and includes suppression rules for metro time mode.
- **Evidence**: `lib/screens/homescreen.dart` [L650-L705]; `lib/services/tracking/alarm_controller.dart` [L980-L1085]
- **Confidence**: HIGH (needs end-to-end runtime trace)

## Flow 7 — Deviation → reroute → termination policy

### Preconditions

- Tracking is active; destination is set.
- Deviation monitoring is producing `DeviationState` events.

### Step-by-step trace (confirmed)

1. When background startTracking runs, it initializes termination policy and wires deviation events:
	- `TrackingTerminationPolicy.reset()` and `setDestination(destination)`.
	- Subscribes to `RouteSessionManager.deviationStateStream`:
		- On offroute start: `onDeviationStart(position, at)`
		- On return to route: `onReturnToRoute()`
	- **Evidence**: `lib/services/trackingservice.dart` `_handleBackgroundStartTracking()`

2. Reroute decisions arrive from `RouteSessionManager.rerouteStream`.
	- `_handleRerouteDecision(decision)` is called.
	- **Evidence**: `lib/services/trackingservice.dart` `_handleBackgroundStartTracking()` wiring

3. Before attempting reroute, termination policy is evaluated.
	- `shouldTerminate(currentPosition, speedMps)` can return a terminate decision based on:
		- Extreme deviation while stopped/slow
		- Sustained deviation + failed reroutes
		- Consistent movement away from destination (consecutive checks)
	- If terminate: `_terminateTrackingWithMessage(...)` posts a “Tracking Ended” alarm-style notification and stops tracking.
	- **Evidence**: `lib/services/tracking_termination_policy.dart` `shouldTerminate()`; `lib/services/trackingservice.dart` `_handleRerouteDecision()`

4. If not terminating, reroute attempts require online mode.
	- If offline: reroute is skipped and `onRerouteFailed()` increments the failure counter.
	- If online: new directions are fetched via `OfflineCoordinator.getRoute(... forceRefresh:true ...)` and validated against `RerouteConstraints`.
	- If constraints fail: `onRerouteFailed()` increments; after 3 failures, tracking is terminated.
	- If constraints pass: new route is registered and `onRerouteSuccess()` resets deviation state.
	- **Evidence**: `lib/services/trackingservice.dart` `_handleRerouteDecision()`

### Findings

- **Severity**: MEDIUM
	- **Impact**: Termination is only evaluated on reroute attempts; if deviation monitoring fails to emit reroute decisions, termination may not trigger even during extended deviation.
	- **Fix**: Consider evaluating termination policy on a timer or on each deviation-state update (bounded rate), independent of reroute triggers.
	- **Confidence**: MEDIUM (needs confirm reroute decision emission guarantees)
