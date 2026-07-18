## 06 — Tracking Service, Location Stream & State Persistence

**Role in the core promise:** This subsystem is the *engine room* of GeoWake. It is the thing that actually keeps running with the screen off, the app swiped away, and the phone in a pocket underground, and it is the thing that decides "am I still tracking, where am I on the route, and is it time to check the alarm?" Every other subsystem (alarm decision, EKF dead-reckoning, notifications, reroute) is *driven* by the loop that lives here. If this loop stalls, dies silently, or loses the route context, the rider sleeps past their stop — the single failure the whole product exists to prevent. Concretely, this subsystem owns: (1) the **background isolate lifecycle** (`_onStart`, wake-lock, recovery after Android kills the process), (2) the **GPS position pump** (`LocationStreamHandler`) that turns raw fixes into per-tick alarm evaluations and falls back to dead-reckoning when GPS dies, (3) the **foreground↔background IPC** that lets the UI arm/stop tracking and receive alarm triggers reliably, (4) the **persisted session state** (`TrackingStateStore`) that survives process death so a rebooted phone resumes the journey, and (5) the **"is the rider still on this trip?" guards** (`TrackingTerminationPolicy`, `SoftLockManager`, heartbeat monitor).

---

### Files

| Path | What it does |
|---|---|
| `lib/services/trackingservice.dart` (2696 lines) | The orchestrator. Singleton facade (`TrackingService`) used by the UI, PLUS the background-isolate entry point (`_onStart`) and a large block of **module-level global state** that acts as the one-and-only session for that isolate. Wires every other component together. |
| `lib/services/tracking/location_stream_handler.dart` | The GPS pump. Subscribes to `LocationManager`'s position stream, computes ETA, tracks distance, drives the per-fix alarm check, runs the periodic "dropout tick" that dead-reckons through GPS blackouts, and persists snapshots every 30 s. |
| `lib/services/tracking/foreground_bridge.dart` | Foreground side of IPC. ACK-with-retry `invoke`, 1 Hz heartbeat sender, and decoders that turn background event maps (`activeRouteSwitch`, `triggerAlarm`, `updateLocation`, …) into typed Dart streams. |
| `lib/services/tracking/background_handlers.dart` | Background side of IPC. Registers every `service.on(<event>)` listener, parses the argument maps, sends ACKs back, and calls typed callbacks into the orchestrator. |
| `lib/services/tracking/heartbeat_monitor.dart` | Background watchdog that detects when the foreground app has been swiped away (heartbeats stop) and posts a "tracking paused" notification. |
| `lib/services/tracking/snapshot_route_restorer.dart` | Small helper that re-registers a route from a persisted snapshot's `directions` on resume / recovery. |
| `lib/services/tracking/notification_updater.dart` | Builds the ongoing journey notification, broadcasts dashboard/simulation state, and (re)arms the OS exact-alarm ETA backstop (G5). |
| `lib/services/tracking/alarm_context_builder.dart` | Pure function that assembles an `AlarmContext` (route events, step bounds, transit legs, EKF snapshot, speeds) for the alarm decision — the boundary into the Alarm Logic subsystem. |
| `lib/services/tracking/tracking.dart` | Barrel file re-exporting the tracking components. |
| `lib/services/tracking_state_store.dart` | All persisted tracking state in `SharedPreferences`: active/paused/alarm-fired flags, the `TrackingSnapshot`, progress payload, mute/preboarding toggles, and per-route transit-leg-stops. |
| `lib/services/tracking_termination_policy.dart` | Multi-signal decision on when to *give up* tracking (rider abandoned the trip) without false-positives. |
| `lib/services/soft_lock_manager.dart` | "Bus Reality" corridor check — hysteresis-based deviation detection for non-metro legs. |
| `lib/services/pending_ack_manager.dart` | A hardened, timeout-based ACK bookkeeper. **NOTE: not wired into the live IPC path** (see flaws). |

Adjacent files this subsystem leans on but that are documented elsewhere: `alarm_controller.dart` (Alarm Logic subsystem), `location_manager.dart` (GPS source + speed smoothing + accuracy gate), `sensor_fusion.dart`/`core/ekf/*` (EKF), `route_session_manager.dart`, `active_route_manager.dart`, `deviation_monitor.dart`, `eta_engine.dart`.

---

### How it works, step by step (the atomic walkthrough)

#### 0. The two-isolate model (the mental model you MUST hold)

`flutter_background_service` spawns a **second Dart isolate**. Dart isolates share *no* memory, so there are effectively two copies of this code running:

- **Foreground isolate** (the UI): `TrackingService()` is a singleton facade. It talks to the background *only* through `service.invoke('<method>', argsMap)` (send) and `service.on('<event>').listen(...)` (receive). All args are `Map<String, dynamic>` — **string-keyed, untyped, JSON-ish**. There is no compiler check that the two sides agree on shape.
- **Background isolate**: entered at `_onStart` (marked `@pragma('vm:entry-point')` so tree-shaking keeps it). Here the **module-level globals** in `trackingservice.dart` (`_destination`, `_alarmMode`, `_trackingSessionActive`, `_lastProcessedPosition`, `_lastEkfState`, …) hold the entire session. Because one background isolate = one journey, these globals behave like session singletons.

`_isBackgroundIsolate` (global bool, set true at the top of `_onStart`) is how the same code file knows which side it is on.

#### 1. Arming a journey (foreground → background)

`TrackingService.startTracking({destination, destinationName, alarmMode, alarmValue, transitMode, routePoints, …})`:

1. `_ensureAckListenersRegistered()` — wires the `ForegroundBridge` listeners and pipes its streams into the public `TrackingService` streams; also installs the `onAlarmTrigger` callback that shows the wake-up notification when the background fires.
2. `recordSessionStart(...)` — fire-and-forget telemetry (HANDOFF §3 reliability funnel), deliberately `unawaited` so it can never delay arming.
3. Builds `params` map (dest lat/lng, name, mode, value, transit, `isSimulationMode`) and, if `routePoints` given, a serialized point list.
4. **Test mode** short-circuits: calls `_onStart(TestServiceInstance(), initialData: params)` directly in-process.
5. Real mode: `_service.startService()` if not running; sets `TrackingStateStore` flags `active=true, paused=false, alarmFired=false, notificationsMuted=false`; shows the initial "Journey to X … Starting" notification.
6. `_invokeWithAckRetry(method:'startTracking', args:params, ackEvent:'startTrackingAck')` — reliable send (see §7). If it never ACKs, falls back to a plain `_service.invoke('startTracking', params)`.
7. `_startForegroundHeartbeat()` — begins the 1 Hz heartbeat so the background knows the UI is alive.

On the **background** side `BackgroundHandlers._handleStartTracking` parses the map, **immediately sends `startTrackingAck`** (before doing any work, so the ACK is fast), then calls `onStartTracking(...)` → `_handleBackgroundStartTracking(...)`.

#### 2. `_handleBackgroundStartTracking` — session bootstrap (background)

This is the reset-everything-then-start routine. In order it:
1. Clears stale state: `_registry.clear()`, `_etaEngine.reset()`, `_locationStreamHandler.reset()`, nulls `_smoothedSpeed`, resets route/step/transit globals, `_alarmController.resetAlarmState()`, nulls EKF snapshots.
2. Assigns `_destination`, `_destinationName`, `_alarmMode`, `_alarmValue`, sets `_trackingSessionActive = true`.
3. `_terminationPolicy.reset()` + `setDestination(destination)`.
4. **Subscribes to `RouteSessionManager` streams** (this is the nerve wiring):
   - `routeStateStream` → `_routeStateCtrl` (UI progress).
   - `routeSwitchStream` → **migrate alarm state** (`_alarmController.migrateAlarmState(fromKey,toKey)` so alarms don't re-fire on the new route key), update fusion route geometry, forward event.
   - `rerouteStream` → forward + `_handleRerouteDecision(d)` (the actual reroute execution).
   - `deviationStateStream` → drives `TrackingTerminationPolicy.onDeviationStart/onReturnToRoute`.
   - `wrongDirectionStream` (G14/G15) → shows a heads-up "wrong direction" notification.
5. Persists `active/paused/alarmFired` flags.
6. `SnapshotRouteRestorer.restoreFromStoreIfActiveAndNotPaused(...)` — if the UI already persisted `directions` into the store, re-register the route here so stop/time/event alarms have geometry even if the `registerRoute` IPC gets dropped.
7. Resets time-alarm gating (`_distanceTravelledMeters=0`, `_etaSamples=0`, `_timeAlarmEligible=false`).
8. If transit and no boarding point yet, derive `_firstTransitBoarding` from a boarding/transfer event or the 2nd polyline point.
9. `startLocationStream(service)` — starts the pump.

#### 3. `startLocationStream` — starting the pump (background)

1. **G1: `WakepointNative.acquireWakeLock()`** — a `PARTIAL_WAKE_LOCK` held for the whole session so the CPU keeps running with the screen off (essential for the accel/gyro + EKF to keep advancing through a tunnel). Re-taken on the recovery path too.
2. `_heartbeatMonitor.start()`.
3. Reads battery (`Battery().batteryLevel`, default 100 on failure) and selects a `PowerPolicy` via `PowerPolicyManager.forBatteryLevel` (or `PowerPolicy.testing()`).
4. Sets the global `gpsDropoutBuffer` from the policy and pushes the reroute cooldown into `ReroutePolicy`.
5. Wires **all** `LocationStreamHandler` callbacks: `onEkfUpdate` (stores `_lastEkfState`), `onCheckAlarm` (sync globals → `_checkAndTriggerAlarm` → sync globals), `onUpdateNotification`, `onBroadcastState` (packs the big debug map incl. EKF telemetry), `onMaybeBroadcastRoute`, `onEndTrackingRequested`.
6. `_locationStreamHandler.start(LocationStreamContext(...))`.

The **power tiers** (`PowerPolicyManager.forBatteryLevel`) are:

| Battery | Accuracy | distanceFilter | gpsDropoutBuffer | notificationTick | rerouteCooldown |
|---|---|---|---|---|---|
| > 50 % | high | 5 m | 25 s | 1 s | 20 s |
| 21–50 % | medium | 15 m | 30 s | 2 s | 25 s |
| ≤ 20 % | low | 50 m | 40 s | 3 s | 30 s |
| test | high | 5 m | 2 s | 50 ms | 2 s |

Note the `gpsDropoutBuffer` — how long GPS must be *silent* before dead-reckoning kicks in — grows as battery drops (25 → 40 s). And `notificationTick` is the period of the dropout-check timer.

#### 4. Per-fix processing — `LocationStreamHandler._handlePositionUpdate`

Every emitted `Position` (from `LocationManager.positionStream`, which is already speed-normalized and accuracy-gated — see §11) runs this pipeline:
1. Stamp `_lastGpsUpdate = now`, `_lastProcessedPosition`, `_lastSpeedMps`, `_lastPositionTimestamp`.
2. Throttled (≥ 1 s) dashboard broadcast of raw lat/lng/heading/speed.
3. `_ensureFusionManager` + `_sensorFusionManager?.updateGps(position)` — feed the EKF.
4. `_trackMovement` — set `_distanceTravelledMeters` = straight-line distance from the journey start position; also re-ingests into `ActiveRouteManager` with the current `isFinalAlarm` flag.
5. `_computeEta` — `EtaEngine.computeEta(routeCoords, gps, isMetroMode, stepBounds, stepDurations, totalRouteMeters)`; sets `_smoothedETA`, `_smoothedSpeed`. Fallback if no route: `distance / (speed>0.5 ? speed : 2.8 m/s)`. Increments `_etaSamples` only when `speed ≥ 0.5`.
6. `_evaluateTimeAlarmEligibility` — flips `_timeAlarmEligible` true once **distance ≥ 100 m AND etaSamples ≥ 3 AND ≥ 30 s since start** (guards time-mode from firing on a bad first fix).
7. Ingest into `ActiveRouteManager`.
8. **Sequential guard**: if not already checking, set `_isCheckingAlarm = true` and call `onCheckAlarm(position, service)` → `_checkAndTriggerAlarm`; clear the flag on completion. This prevents overlapping async alarm evaluations.
9. `service.invoke("updateLocation", {lat,lng,speed,eta})` — mirror to the UI.
10. `_maybePersistSnapshot` — every 30 s writes a `TrackingSnapshot` (incl. EKF `s/sigmaS/mode`).

#### 5. The dropout tick — `_handleGpsCheckTick` (the underground lifeline)

A `Timer.periodic(policy.notificationTick)` runs independently of GPS. On each tick:
1. `_processNotificationActions` — consume notification-button requests from prefs: **stop-alarm**, **mute-journey**, **end-tracking** (end delegates to `onEndTrackingRequested`).
2. `_ensureCriticalNotificationsVisible` — re-post alarm / paused notifications the OS may have dropped.
3. `_checkGpsDropout` — if `now - _lastGpsUpdate ≥ gpsDropoutBuffer`, ensure a fusion manager exists at the last known position.
4. **G10 dead-reckoned alarm eval — `_maybeEvaluateAlarmDuringDropout`**: this is the whole reason the alarm still fires in a tunnel. When GPS has been silent past the buffer AND a finite `_lastEkfState` exists, it **synthesizes a `Position`** with `accuracy = 9999.0` (a sentinel), `speed = EKF.v`, and lat/lng = last known fix, then drives `onCheckAlarm` with it — rate-limited to once per `dropoutEvalMinInterval` (2 s). Because the `positionStream` is silent underground, this periodic tick is the *only* thing keeping the countdown alive.
5. `onUpdateNotification` (subtitle switches to "No GPS (tunnel) — estimating from motion" when EKF mode is `degraded`).
6. `onBroadcastState`, `onMaybeBroadcastRoute`, re-evaluate time-alarm eligibility.

#### 6. `_checkAndTriggerAlarm` — the alarm gate (background)

1. Early-returns unless `_trackingSessionActive` and `_destination != null` and `_alarmValue != null`.
2. **Dead-reckoned detection**: `isDeadReckoned = !accuracy.isFinite || accuracy ≥ 9000.0`. A synthesized dropout position is thus recognizable.
3. If NOT dead-reckoned: refresh `_lastProcessedPosition`, `_lastSpeedMps`, and `_sessionManager.ingestPosition(currentPosition)`. If dead-reckoned, it deliberately does **not** overwrite the last good fix or feed snap/deviation/session — a frozen fix would poison the registry and soft-lock.
4. Snapshot EKF: `_lastEkfAlarmSnapshot = _lastEkfState` (the exact EKF used for *this* decision).
5. `_resolveAlarmRouteState(currentPosition, deadReckoned)` → `{progressMeters, activeKey}`:
   - **Dead-reckoned** → take arc-progress straight from `EKF.s` (no snap).
   - **Live** → `SnapToRouteEngine.snap(point, polyline, previousResult, heading?, precomputedCumMeters)`; update registry session state; track `_maxProgressMetersSeenByKey`; run `SoftLockManager.checkSoftLock` for non-metro legs; then **prefer EKF progress** (`EKF.s`) when the current leg is metro or EKF mode is `degraded`/`metro`.
6. `AlarmContextBuilder.build(...)` assembles the full context, including `preferEkfSpeed` (true when dead-reckoned, or EKF mode is metro/degraded) and the EKF σ values.
7. `_alarmController.checkAndTriggerAlarm(currentPosition, service, context, onAlarmFired)` — hands off to the Alarm Logic subsystem. `onAlarmFired` marks fired + broadcasts.

#### 7. Reliable IPC — `ForegroundBridge.invokeWithAckRetry`

Because `service.invoke` is best-effort (a message can be silently dropped, especially right after the isolate spawns), critical foreground→background commands use ACK-with-retry:
- Up to **5 attempts** with escalating inter-attempt delays `[30, 80, 150, 300, 500] ms`; each attempt has a **400 ms ACK timeout**.
- Each attempt mints a `requestId = "${millis}_${counter++}"`, stores a `Completer` in `_pendingAcks`, invokes `{...args, requestId}`, and awaits the completer with timeout.
- The background handler echoes `{'requestId': id}` on the `<method>Ack` event; `_handleAck` completes the matching completer.
- Returns `true` on ACK, `false` if all 5 attempts fail (caller then does a plain unacked `invoke` as a last resort).

Events decoded on the foreground side: `startTrackingAck`, `registerRouteAck`, `registerRouteDirectionsAck` (ACKs); `activeRouteSwitch`, `activeRouteUpdate`, `routeSwitch` (route state → typed streams); `triggerAlarm` (→ show wake alarm); `updateLocation` (→ mirror `Position`, **hardcoded `accuracy: 10.0`**).

#### 8. Heartbeat & "paused" detection — `HeartbeatMonitor`

- Foreground `ForegroundBridge.startHeartbeat()` invokes `foregroundHeartbeat` every **1 s**.
- Background `HeartbeatMonitor` (timeout **4 s**, check every **2 s**): if `now - lastHeartbeat > 4 s` AND session `active` AND not already `paused` AND not simulation mode → set `paused=true`, cancel journey progress, show **"tracking paused"** notification, and **stop monitoring**.
- The design intent: when the user swipes the app from recents, the foreground isolate dies, heartbeats stop, and within ~4 s the background posts a tap-to-resume prompt. Resuming goes through `foregroundResumed` / `resumeFromNotification`.
- Important: "paused" is a **UI/notification concept only** — it sets a pref flag and a notification. It does **not** stop the background location stream or gate `_checkAndTriggerAlarm`. So the alarm keeps evaluating even while "paused". (This is good for the core promise but makes the word "paused" misleading.)

#### 9. Recovery after process death — `_onStart(service, initialData: null)`

Android *will* kill the background isolate under memory pressure; `AndroidConfiguration(autoStartOnBoot: true)` also re-runs the entry point after a **reboot** (G4). When `_onStart` is entered with `initialData == null`:
1. Read `TrackingStateStore.isActive()`. If false → `service.stopSelf()`.
2. If active, `loadSnapshot()`. If null → `stopSelf()`.
3. Else restore `_destination/_destinationName/_alarmMode/_alarmValue/_transitMode` from the snapshot, set `_trackingSessionActive = true`, `SnapshotRouteRestorer.restoreFromSnapshotIfDirectionsPresent(...)` (re-registers the route from the persisted, minimized `directions`), `startLocationStream`, start the alarm-stop poll, and show a "Resumed" notification.

#### 10. Persistence — `TrackingStateStore` (`SharedPreferences`)

Keys (all `_v1`/`_v5` suffixed for schema migration): `tracking_active_v1`, `tracking_paused_v1`, `tracking_alarm_fired_v1`, `tracking_snapshot_v1`, `tracking_notifications_muted_v1`, `gw_progress_payload_v1`, `gw_preboarding_enabled_v1`, `gw_destination_only_metro_time_v1`, `tracking_transit_leg_stops_v5`.

`TrackingSnapshot` fields: destination lat/lng/name, `alarmMode`, `alarmValue`, `metroMode`, current `userLat/userLng`, `createdAt`, optional minimized `directions`, and `ekfS/ekfSigmaS/ekfMode`.

`saveSnapshot` details:
- **Directions-preservation merge**: background refreshes the snapshot every 30 s with new user coords but often *without* directions; the code reads the existing snapshot and keeps its `directions` rather than nulling them.
- **Minimization** (`_minimizeDirectionsForSnapshot`): strips the Directions response down to `status` + `routes[0]` with only `legs→steps` (`travel_mode`, `distance.value`, `duration.value`, `polyline.points`, start/end location, a subset of `transit_details`), plus `overview_polyline`/`simplified_polyline`. This is critical because `SharedPreferences` has practical size limits and a raw Directions payload is large.
- Encoding is offloaded to a background isolate via `compute(_encodeSnapshotInBackground, json)` (except under `flutter_test`).
- Throws on failure (payload too large) and `rethrow`s — the caller logs and continues.
- **Cross-isolate freshness**: `notificationsMuted()`, `preboardingEnabled()`, `destinationOnlyMetroTimeEnabled()`, `pendingAlarmAllowContinue()` call `prefs.reload()` before reading, because two isolates + native Android all read/write the same prefs and the in-process cache goes stale.

#### 11. Position source — `LocationManager` (consumed dependency)

`LocationStreamHandler` subscribes to `LocationManager().positionStream`, which:
- Starts real GPS (`Geolocator.getPositionStream`, `LocationAccuracy.high`, `distanceFilter: 0`) and auto-fails-over to the simulation client when the dashboard takes control (`injectPosition` / WebSocket).
- **Normalizes speed** (derives from Δdistance/Δt with jitter + acceleration guards, EMA α=0.2) so real and simulated runs behave identically.
- **G27 accuracy gate**: real fixes worse than `accuracyGateMeters` (default 100 m; "approximate" if > 500 m) are **dropped** — treated as a GPS gap so the dropout tick + EKF take over. Simulated positions bypass the gate.
- **G28**: watches `Geolocator.getServiceStatusStream()` to detect the user disabling Location mid-journey.

---

### Key types & functions

- `TrackingService` (singleton, both isolates) — `startTracking(...)`, `stopTracking({stopServiceInstance})`, `completeEndTracking({navigateHome})`, `resumeFromNotification()`, `muteJourneyNotifications()`, `handleAppLifecycleChange(state)`, `setSimulationMode(bool)`, `registerRoute(...)`, `registerRouteFromDirections(...)`, plus public streams `activeRouteStateStream / routeSwitchStream / rerouteDecisionStream / locationStream / etaSecondsStream`.
- `_onStart(ServiceInstance, {initialData})` — `@vm:entry-point` background entry; two branches: fresh/test start (`initialData != null`) vs recovery (`null`).
- `_handleBackgroundStartTracking({...})` — session bootstrap (reset + subscribe + start pump).
- `_checkAndTriggerAlarm(Position, ServiceInstance)` — the alarm gate; dead-reckon aware.
- `_resolveAlarmRouteState(Position, {deadReckoned}) → _ResolvedAlarmRouteState{progressMeters, activeKey}` — snap-or-EKF progress resolution.
- `_handleRerouteDecision(RerouteDecision)` — fetch new route, validate constraints, register or terminate; guarded against post-alarm resurrection and concurrent runs (`_rerouteInFlight`).
- `LocationStreamHandler.start(LocationStreamContext)` / `_handlePositionUpdate` / `_handleGpsCheckTick` / `_maybeEvaluateAlarmDuringDropout` / `_ensureFusionManagerPosition` — the pump. Exposes getters (`lastGpsUpdate`, `lastProcessedPosition`, `smoothedETA`, `distanceTravelledMeters`, `etaSamples`, `timeAlarmEligible`, `fusionActive`) mirrored into globals via `syncGlobalsFromHandler`.
- `ForegroundBridge.invokeWithAckRetry({method,args,ackEvent}) → Future<bool>` — reliable IPC; `ensureListenersRegistered()`; `startHeartbeat()/stopHeartbeat()`.
- `BackgroundHandlers.registerAll()` — installs `service.on(...)` listeners; `BackgroundHandlerCallbacks` is the typed callback bundle.
- `HeartbeatMonitor(isEnabled, timeout=4s, checkInterval=2s)` — `recordHeartbeat()`, `start()/stop()`, `ensureStarted()`.
- `TrackingStateStore` (all static) — `setActive/isActive`, `setPaused/isPaused`, `setAlarmFired/isAlarmFired`, `saveSnapshot/loadSnapshot/clearSnapshot`, `setNotificationsMuted/notificationsMuted`, `preboardingEnabled(Sync)`, `destinationOnlyMetroTimeEnabled(Sync)`, `save/loadProgressPayload`, `save/load/clearTransitLegStops`.
- `TrackingSnapshot` / `TrackingProgressPayload` — persisted value objects with `toJson/fromJson`.
- `TrackingTerminationPolicy` — `setDestination`, `onDeviationStart/onReturnToRoute/onRerouteFailed/onRerouteSuccess`, `shouldTerminate({currentPosition, speedMps, at}) → TerminationDecision`, `reset()`, getters `isDeviating/failedRerouteAttempts/currentDeviationDuration/getDeviationDistanceKm`.
- `SoftLockManager.checkSoftLock({userLocation, accuracy, routePoints, closestSegmentIndex, projectedPoint, lateralOffsetMeters}) → bool` (true = on route), `reset()`.
- `PendingAckManager` — `waitForAck/receiveAck/cancel/dispose` (see flaw #9).
- `SnapshotRouteRestorer` — `restoreFromStoreIfActiveAndNotPaused(...)`, `restoreFromSnapshotIfDirectionsPresent(...)`.
- `NotificationUpdater` — `updateNotification(...)`, `broadcastSimulationState(...)`, `maybeBroadcastCachedRoute(...)`, `_maybeRearmEtaBackstop(...)` (G5 ETA backstop).
- `AlarmContextBuilder.build(...) → AlarmContext` — pure assembler into the Alarm subsystem.

---

### Design decisions (the WHY)

1. **One giant `trackingservice.dart` with module-level global state, not an injected object graph.**
   *Decision:* The session lives in ~40 top-level mutable globals (`_destination`, `_trackingSessionActive`, `_lastEkfState`, …), and the file's own header defends being 2.7k lines.
   *Why:* The background isolate hosts exactly one journey at a time. Globals are the simplest way to give the `@vm:entry-point` free functions (`_onStart`, `_checkAndTriggerAlarm`) shared session state without threading a context object through every call, and the author judged that splitting the file would "introduce race conditions and complex cross-file state."
   *Trade-off / rejected:* A proper session object (constructed per journey) would be testable, reentrant, and impossible to leave half-reset. It was rejected for expedience.
   *FLAW:* Globals are not reset atomically — `_onStop`, `_handleBackgroundStartTracking`, `resetForTesting`, and `initialData` handling each reset an overlapping-but-different subset by hand. A missed field leaks state into the next journey (e.g. a stale `_maxProgressMetersSeenByKey` or `_lastEkfState`). This is exactly the class of bug the recent EKF "518 km s_est spike" work was chasing.

2. **State is mirrored twice: `LocationStreamHandler` keeps its own `_lastProcessedPosition`, `_smoothedETA`, etc., and `syncGlobalsFromHandler()` copies them into the globals around each alarm check.**
   *Why:* The pump was extracted from the monolith ("Phase 1 refactoring") but the alarm/notification code still reads globals, so a sync shim bridges the two.
   *Trade-off:* Avoided rewriting all consumers.
   *FLAW:* Double bookkeeping with manual sync is fragile. `onCheckAlarm` deliberately syncs **before and after** the check; if any new code reads a global mid-check without syncing, it can see a value one tick stale. Two sources of truth for "where is the rider" is a latent correctness hazard for a never-late alarm.

3. **Dead-reckoning is driven by a *separate periodic timer*, and the dead-reckoned fix is a synthetic `Position` with sentinel `accuracy = 9999.0` and `speed = EKF.v`.**
   *Why:* Underground, `positionStream` emits nothing, so a GPS-driven loop would freeze. The `notificationTick` timer keeps running on the wake-locked CPU and pushes EKF-based evaluations. The sentinel accuracy lets `_checkAndTriggerAlarm` recognize the fix and refuse to snap/ingest it (which would corrupt the registry with a non-moving point).
   *Trade-off:* Two code paths (live vs dead-reckoned) for the same evaluation; the magic-number `9000/9999` coupling between `LocationStreamHandler`, `_checkAndTriggerAlarm`, and `FireDecisionConfig.deadReckonAccuracySentinel` must stay in sync.
   *FLAW:* Dead-reckoning **only** works if `_lastEkfState` exists, which **only** happens if a fusion manager was created with valid `RouteGeometry` (≥ 2 route points). If the route registration was dropped (see flaw #5) there is no EKF → no dead-reckoning → progress freezes in the tunnel → stop/time alarms can fire late or never. This is the single most core-promise-relevant weakness in the subsystem.

4. **Battery-tiered `PowerPolicy` that *relaxes* GPS as battery drops (high→low accuracy, 5→50 m filter, 25→40 s dropout buffer).**
   *Why:* A wake-alarm app that drains the battery to 0 before the stop is worse than useless; on a cheap Indian phone on a long commute, survival to arrival matters.
   *Trade-off:* Lower accuracy + coarser filter + longer dropout buffer at low battery means the alarm-relevant position is less precise and dead-reckoning starts later — a deliberate accuracy-for-endurance trade.
   *FLAW:* The tier is chosen **once** at `startLocationStream` from the battery level at that instant; it is never re-evaluated as the battery drains during a 90-minute journey. A journey started at 55 % never drops to the low-power tier even at 5 %.

5. **Route context can arrive three ways (direct `registerRoute` IPC, `registerRouteDirections` IPC, or restore-from-snapshot) and registration must happen in the background isolate.**
   *Why:* Snapping/progress/stop-counting all run in the background, so the route must live there. The UI persists `directions` into the store as a belt-and-suspenders so a dropped IPC doesn't leave the background route-less.
   *Trade-off:* Complex multi-path registration with ACK-retry + snapshot fallback.
   *FLAW:* Snapshots are only written **every 30 s** and the first one may not include directions until the UI persisted them. If Android kills the isolate in the first ~30 s of a metro/stops journey before directions are persisted, recovery restores the destination but **no route geometry** — the alarm silently degrades to straight-line distance, which is wrong for stops/time modes. `registerRouteFromDirections`'s final fallback is an *unacked* `invoke`, so a genuinely dropped registration is possible.

6. **`SoftLockManager` corridor check (50 m normal / 200 m when accuracy > 20 m, deviation after 3 consecutive out-of-corridor points).**
   *Why:* Buses don't follow the polyline exactly; strict snapping would false-alarm "off route." A corridor with hysteresis tolerates normal bus wander and poor GPS.
   *Trade-off:* Widening to 200 m on bad accuracy means a genuinely-off-route rider in a GPS-poor area is tolerated longer.
   *FLAW (significant):* In `_resolveAlarmRouteState`, when `checkSoftLock` returns `false` (deviation confirmed) the code only **logs a warning with a `TODO: Trigger actual reroute`** — it does nothing else. So `SoftLockManager`'s output is effectively **advisory/dead**; all real reroute triggering depends on the separate `DeviationMonitor`. The 3-consecutive-points hysteresis and 200 m fallback are computed but not acted upon.

7. **`TrackingTerminationPolicy` uses three behavioral rules instead of a single distance cutoff.**
   *Why:* A pure "> X km off route ⇒ stop" rule kills legitimate highway detours and metro-line corrections. The three rules (extreme distance while stopped ≥ 5 km & < 2 m/s; moderate ≥ 2 km & ≥ 10 min & ≥ 2 failed reroutes; consistently moving away ≥ 3 km & +500 m for 5 checks & > 1 m/s) target genuine abandonment.
   *Trade-off:* More state and tuning knobs; harder to reason about.
   *FLAW:* The thresholds are Western-commuter tuned and untested against Indian multimodal reality (a 2 km walk to a different platform, a bus that loops). Rule 2 needs 10 minutes *and* 2 failed reroutes — a long time to keep a doomed session alive, spamming reroute attempts. Because it's bypassed entirely in simulation mode, it gets little exercise in the validation harness.

8. **Heartbeat watchdog with a 4 s timeout posts a "tracking paused" notification when the foreground dies.**
   *Why:* Users swipe apps from recents; the app wants to prompt them to reopen so the map/UI comes back, and to reflect that the (foreground) app is gone.
   *Trade-off:* Aggressive 4 s window vs a 1 s heartbeat.
   *FLAW:* A 4 s window is only 4 missed 1 Hz beats. A brief foreground stall (GC, heavy map render, a slow frame on a cheap phone) can trip a *false* "tracking paused" banner even though nothing is wrong, and once tripped the monitor **stops** — it won't clear itself until a `foregroundResumed` arrives. This erodes trust (the rider sees "paused" and may think the alarm is off, even though the background loop keeps firing). The label "paused" overstates what happened (only the UI process is gone).

9. **`PendingAckManager` exists as a hardened, unit-tested ACK bookkeeper — but `ForegroundBridge` rolls its own `_pendingAcks` map instead.**
   *Why:* `ForegroundBridge` was written with an inline retry loop; `PendingAckManager` was a later, more careful abstraction (timeout cleanup, disposal, `AckTimeoutException`).
   *Trade-off:* None intended — this looks like an incomplete migration.
   *FLAW:* The production IPC path does **not** use `PendingAckManager`; it is effectively dead code relative to the live path. Worse, `ForegroundBridge.invokeWithAckRetry` removes completers from `_pendingAcks` only on the success/timeout branches of the *current* attempt — a late ACK for a prior attempt just no-ops, and there is no periodic sweep, so the map is cleaned adequately but the two implementations can drift. Maintaining two ACK mechanisms is a bug farm.

10. **Directions are aggressively minimized before persisting to `SharedPreferences`, and encoding is offloaded via `compute()`.**
   *Why:* `SharedPreferences` is a small key-value store; a full Google/OSM Directions payload can be hundreds of KB and blow the practical limit, and JSON-encoding it on the UI thread would jank. Minimization keeps only the fields snapping/stop-counting need.
   *Trade-off:* If minimization drops a field a future feature needs, recovery silently loses it; the minimizer falls back to the *original* (huge) payload on any exception, which can then fail to persist.
   *FLAW:* `saveSnapshot` `rethrow`s on write failure; a snapshot that is still too large after minimization (very long multi-leg transit route) means **no snapshot is stored at all**, defeating post-death recovery for exactly the long journeys where recovery matters most.

11. **IPC is untyped `Map<String,dynamic>` over `service.invoke`/`service.on`, with the foreground location mirror hardcoding `accuracy: 10.0`.**
   *Why:* That is the `flutter_background_service` contract; the mirror's accuracy is irrelevant to the UI dot.
   *Trade-off:* No compile-time guarantee the two isolates agree on map keys; a rename on one side fails silently at runtime.
   *FLAW:* Silent shape drift between isolates is undetectable until a field reads `null` in production. The hardcoded 10 m accuracy means any UI-side logic that trusted `locationStream` accuracy would be misled (currently it doesn't, but it's a trap).

12. **Vestigial globals `_positionSubscription`, `_gpsCheckTimer`, `_sensorFusionManager` remain in `trackingservice.dart`.**
   *Decision/observation:* These are declared (lines 627/629/631) and cancelled/disposed in `_onStop` and `startLocationStream`, but **never assigned** — the real subscription/timer/fusion manager now live inside `LocationStreamHandler`.
   *FLAW:* Dead state that looks live. A future maintainer may "fix" a leak by re-subscribing to the global, creating a second GPS subscription or fusion manager. Pure confusion risk; should be deleted.

---

### Invariants (what must always hold)

- **Single active session per background isolate.** All module globals assume exactly one journey; a second `startTracking` without a clean `_onStop`/reset is undefined.
- **`_trackingSessionActive == true` is required for any alarm to fire.** `_checkAndTriggerAlarm` early-returns otherwise. Recovery/test paths set it true explicitly before the first fix.
- **A dead-reckoned `Position` is identified solely by `accuracy ≥ 9000` (sentinel 9999).** No real fix may ever legitimately carry that accuracy, and every consumer of a synthesized position must honor "don't snap/ingest."
- **The wake lock (G1) is held for the entire session** and released exactly once in `_onStop`; the ETA backstop (G5) must be cancelled whenever the session ends or the alarm fires so it can't double-wake.
- **`TrackingStateStore.isActive()` is the source of truth for recovery.** If it's true, a snapshot must be loadable or the isolate stops itself. `active/paused/alarmFired` must be kept consistent with reality across every stop/complete/resume path.
- **Alarm state must migrate on every route switch** (`_alarmController.migrateAlarmState(fromKey,toKey)`) so a reroute doesn't re-fire an already-fired leg or drop a pending one.
- **After the destination alarm fires, no reroute may resurrect the session** — enforced by the `anyDestinationAlarmFired` guards in `_handleRerouteDecision`.
- **`_isCheckingAlarm` serializes alarm evaluations** — no two `onCheckAlarm` calls may overlap.

---

### Interfaces (what it consumes / exposes, by name)

**Consumes:**
- `LocationManager` — position source (`positionStream`, `start/stop`, `injectPosition`, `testModeStream`, `broadcastState/Position/Route`, `onAlarmReset`, `onSwitchRoute`, G27 accuracy gate, G28 service-status).
- `RouteSessionManager` — owns `RouteRegistry`, `ActiveRouteManager`, `DeviationMonitor`, `ReroutePolicy`, `SoftLockManager`, per-key route/step/transit-leg maps, and the route/switch/reroute/deviation/wrong-direction streams; `ingestPosition`, `registerRoute(FromDirections)`, `switchToRoute`.
- `AlarmController` (Alarm Logic subsystem) — `checkAndTriggerAlarm`, `resetAlarmState`, `migrateAlarmState`, `markAlarmFired`, `startAlarmStopPollTimer`, `anyDestinationAlarmFired`, `lastAlarmFiredAt`.
- `SensorFusionManager` / EKF (`EkfPublicState`, `RouteGeometry`) — dead-reckoning + `ekfStateStream`, `onStationSnapConfirmed`.
- `EtaEngine` — `computeEta`, `loadState/saveState/reset`.
- `NotificationService` — journey progress, wake alarm, paused, wrong-direction, ETA backstop, action-request consumption.
- `OfflineCoordinator` — `getRoute(...)` for reroute; `RerouteConstraints` for validation.
- `PowerPolicy` / `PowerPolicyManager`, `FireDecisionConfig`, `DeviationConfig` — tunables.
- `WakepointNative` — `acquireWakeLock/releaseWakeLock`.
- `SharedPreferences` — via `TrackingStateStore`.

**Exposes:**
- To the **UI**: `TrackingService.startTracking/stopTracking/completeEndTracking/resumeFromNotification/muteJourneyNotifications/handleAppLifecycleChange/setSimulationMode` and the streams `activeRouteStateStream / routeSwitchStream / rerouteDecisionStream / locationStream / etaSecondsStream`.
- To the **Alarm subsystem**: `AlarmContext` (built by `AlarmContextBuilder`), and the `onAlarmFired` callback wiring the fired flag + broadcast.
- To the **dashboard/simulation**: `LocationManager.broadcastState/broadcastRoute/broadcastPosition` payloads (via `NotificationUpdater`).
- To **native / recovery**: the persisted `TrackingStateStore` keys and `TrackingSnapshot` (shared with native Android).

---

### Gaps & flaws vs the core promise (brutally honest)

1. **No route geometry ⇒ no EKF ⇒ no dead-reckoning underground.** (Flaws #3, #5.) The single biggest hole. The tunnel lifeline depends on an EKF that only exists when a valid route was registered with ≥ 2 points. A dropped/late registration, or death within the first 30 s before directions are persisted, leaves the rider with straight-line distance only — precisely the case (metro, underground, stop-counting) the product promises to handle. **Severity: high.**

2. **Recovery can silently lose the route.** (Flaw #5, #10.) 30 s snapshot cadence + rethrow-on-too-large means a killed-early or very-long journey may resume with destination but no route, degrading stop/time alarms to distance. No telemetry distinguishes "recovered with route" from "recovered route-less." **Severity: high.**

3. **Soft-lock deviation is computed but never acted on** (`TODO` in `_resolveAlarmRouteState`). Bus-corridor departures rely entirely on `DeviationMonitor`; the second, independent signal is dead. **Severity: medium** (redundancy lost, not primary path).

4. **Power tier is frozen at journey start** and never downgraded as the battery drains. A long commute that starts at 55 % keeps high-accuracy GPS to 0 %, risking the phone dying before the stop — the "never late" promise fails by way of a dead battery. **Severity: medium.**

5. **False "tracking paused" banners** from the 4 s heartbeat window on cheap/stalling phones, and the monitor self-disables once tripped. The rider may believe the alarm is off. Underlying alarm keeps working, so this is a **trust** failure more than a functional one. **Severity: medium.**

6. **Untyped cross-isolate IPC + two ACK implementations** (`ForegroundBridge` vs unused `PendingAckManager`). Shape drift is silent; the hardened manager is dead code. On top of `SharedPreferences` cross-isolate reads papered over with `reload()`, the state-sync story is racy by construction. **Severity: medium.**

7. **Global mutable session state reset by hand in ≥ 4 different places.** Any missed field bleeds into the next journey; this is the same failure mode as the unresolved cold-start / s_est spike work noted in the branch history. **Severity: medium.**

8. **Termination policy thresholds are unvalidated for Indian multimodal trips** and disabled in simulation, so the validation harness barely exercises them. Worst case: it terminates a legitimate long-transfer journey, or keeps a doomed one alive for 10 min. **Severity: low–medium.**

9. **Accuracy gate (default 100 m) may drop many legitimate fixes on cheap phones in dense Indian urban canyons**, forcing more dead-reckoning than intended. Safe *if* the EKF exists (see #1), dangerous if it doesn't. The gate is set from the alarm threshold but its interplay with #1 is untested at scale. **Severity: low–medium.**

10. **Vestigial `_positionSubscription/_gpsCheckTimer/_sensorFusionManager` globals** invite a future double-subscription bug. Cosmetic today, a trap tomorrow. **Severity: low.**

11. **Time-alarm eligibility gate (100 m / 3 samples / 30 s)** can delay a time-mode alarm's arming if the rider boards immediately or GPS is poor at the start; distance mode is not gated, so behavior differs by mode in a way riders won't anticipate. **Severity: low.**
