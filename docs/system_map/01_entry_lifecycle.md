## App Entry, Lifecycle & Background Service

**Role in the core promise:** This subsystem is the *ignition and the pilot light* of GeoWake. It decides what runs when the app is opened, what survives when the app is backgrounded, swiped away, or the phone reboots, and it owns the single most safety‑critical handoff in the whole product: getting the **background isolate** (a second, headless Dart process that keeps tracking GPS with the screen off) alive and armed. If any step here fails silently, the rider is never woken — the worst possible outcome. So the entry layer is built defensively: it installs three separate crash nets so a reliability app "never dies silently," it starts an Android *foreground service* with a persistent notification so the OS is far less likely to kill tracking, it can **recover an in‑flight journey from disk** after the OS murders the process, and it uses a heartbeat to notice when the UI has been swiped away. It is also, however, where the two most fragile things live: a **cold‑start arming race** between two independent startup paths, and a time‑abstraction (`AppClock`) that the lifecycle plumbing itself does not actually use.

**Files:**

| Path | What it does |
| --- | --- |
| `lib/main.dart` | Production entry point. Installs 3‑layer error capture, sets edge‑to‑edge system UI (Play/Android‑15 compliance), inits Hive, fire‑and‑forgets monetization, mounts `MyApp`. `MyApp` owns the `MaterialApp`, routing table, dark‑mode persistence, and the app‑lifecycle observer that flushes Hive on pause and forwards lifecycle events to `TrackingService`. |
| `lib/main_unified_dashboard.dart` | A *second, separate* entry point used only for the in‑house end‑to‑end testing dashboard (`flutter run -t lib/main_unified_dashboard.dart`). Bypasses almost all production init. |
| `lib/screens/splash_screen.dart` | First screen the user sees. Runs animations, kicks off service initialization, and — critically — decides where to route: home, an in‑progress journey (restore), or cleanup of a "zombie" firing‑alarm state left by a killed process. |
| `lib/services/navigation_service.dart` | A one‑field holder for a global `navigatorKey`, so non‑widget code (e.g. `TrackingService.completeEndTracking`) can navigate without a `BuildContext`. |
| `lib/services/trackingservice.dart` (arming/lifecycle only: `initializeService`, `startTracking`, `_onStart`, `_handleBackgroundStartTracking`, `handleAppLifecycleChange`, `completeEndTracking`, `_onStop`) | The foreground↔background facade + the background‑isolate entry point. Configures and launches the Android foreground service, sends the "start tracking" command with ACK‑retry, restores a session from disk after process death, and tears everything down. |
| `lib/services/tracking/heartbeat_monitor.dart` | (supporting) In the background isolate, watches for a 1 Hz heartbeat from the UI; after 4 s of silence concludes the UI was swiped away and shows a "tracking paused" notification. |
| `lib/services/tracking/foreground_bridge.dart` | (supporting) Implements the ACK‑retry invoke, the heartbeat sender, and stream piping between isolates. |
| `lib/core/clock/app_clock.dart` | A singleton clock abstraction that returns real time in production and *warped* (accelerated up to 500×) time in simulation, so time‑dependent logic can be tested fast. |

---

### How it works, step by step (the atomic walkthrough)

#### A. Production boot — `main()` (`main.dart:23‑63`)

1. **Before anything else**, two synchronous crash nets are installed (`main.dart:29‑37`):
   - `FlutterError.onError` → still prints the error to console (`presentError`) **and** forwards it to `TelemetryService.instance.recordError(..., fatal:false)` — catches widget‑tree/framework errors.
   - `PlatformDispatcher.instance.onError` → forwards to telemetry with `fatal:true` and **returns `true`** so the platform treats the error as handled and does **not** crash the isolate (`main.dart:34‑37`).
2. The rest of boot runs inside `runZonedGuarded` (`main.dart:39`), the third net, which catches uncaught *async* errors and routes them to telemetry + `dev.log` (`main.dart:59‑62`).
3. Inside the guarded zone, in order (`main.dart:40‑58`):
   - `WidgetsFlutterBinding.ensureInitialized()`.
   - `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)` and transparent status/nav bars — required because targetSdk 35 (Android 15) *enforces* edge‑to‑edge; Scaffolds already use `SafeArea` so content isn't hidden.
   - `await Hive.initFlutter()` — opens the on‑device key/value store used for recent locations.
   - `unawaited(MonetizationService.instance.init())` — monetization (entitlements/store/ads) is started **off the critical path**; gates "default to free" until ready so the alarm never waits on a slow ad SDK.
   - `runApp(const MyApp())`.
   - **Note:** the comment at `main.dart:51` says heavy service init was *moved out of `main` into `SplashScreen`* to speed cold start.

#### B. `MyApp` — the root widget (`main.dart:65‑188`)

1. `initState` (`main.dart:76‑87`): registers `MyAppState` as a `WidgetsBindingObserver` (to receive lifecycle callbacks), calls `_checkNotificationPermission()`, and `_restoreThemePreference()`.
2. `_checkNotificationPermission` (`main.dart:117‑122`): reads `Permission.notification.status`; if `isDenied`, requests it. This is the **only** runtime permission this file touches — location, battery‑optimization exemption, and exact‑alarm permissions are handled elsewhere (preflight/home screens).
3. `build` (`main.dart:154‑187`): a `MaterialApp` with:
   - `navigatorKey: NavigationService.navigatorKey` (the global key),
   - `initialRoute: '/splash'`,
   - an `onGenerateRoute` switch mapping `/splash`, `/preloadMap`, `/mapTracking`, `/` (home) to their screens (`main.dart:161‑185`). `/preloadMap` casts `settings.arguments` to `Map<String,dynamic>` with no null‑guard (`main.dart:169`).
4. **Lifecycle handling** — `didChangeAppLifecycleState` (`main.dart:99‑114`):
   - On `AppLifecycleState.paused` (user pressed home / backgrounded): logs and, if the recents Hive box is open, calls `Hive.box(...).flush()` — a direct disk write so the OS can't kill the app before data is saved (`main.dart:103‑110`).
   - **Always** forwards the raw state to `TrackingService().handleAppLifecycleChange(state)` (`main.dart:113`).
5. `dispose` (`main.dart:89‑96`): removes the observer and calls `Hive.close()`. In practice this rarely runs — app termination usually just kills the process — so the `paused` flush is the real durability guarantee.

#### C. Splash routing — the "where do we go?" decision (`splash_screen.dart`)

`initState` (`splash_screen.dart:28‑52`) starts two independent async flows and does **not** await either:
- `_initFuture = _initializeServices()` (fire‑and‑forget, stored for later).
- `_checkStateAndNavigate()` (fire‑and‑forget).

**`_initializeServices` (`splash_screen.dart:54‑80`)** — sequential, each wrapped in its own try/catch so one failure doesn't block the next:
1. `ApiClient.instance.initialize()` (secures API calls — done *first*).
2. `NotificationService().initialize()`.
3. `TrackingService().initializeService()`.

**`_checkStateAndNavigate` (`splash_screen.dart:82‑147`)** — the router, in strict order:
1. `alarmFired = await TrackingStateStore.isAlarmFired()` (`:84`). If the app was **killed while the alarm was ringing**, this is `true`. Then it calls `TrackingService().completeEndTracking(navigateHome:false)` to kill the zombie service/notifications, and `pushReplacementNamed('/')` → home. This prevents an orphaned, un‑stoppable alarm on relaunch.
2. Otherwise, `await _initFuture!.timeout(8s)` (`:96`) — waits up to 8 s for services, but *continues anyway* on timeout/failure (caught, logged).
3. `restoreSession = await TrackingStateStore.isActive()` (`:105`).
   - If **active**: `loadSnapshot()`. If the snapshot is `null` or has no `directions` (`:112`), treat it as corrupted → `completeEndTracking(navigateHome:false)` → home. Otherwise `pushReplacementNamed('/mapTracking', arguments:{...})` reconstructing lat/lng/destination/directions/metroMode/userLat/userLng/mode/value from the snapshot (`:125‑138`) so the map screen re‑arms with the user's *original* alarm settings.
   - If **not active** (normal cold start): schedule a **3‑second** `_navTimer` → `pushReplacementNamed('/')` (`:141‑145`). The comment (`:143`) explains it goes *straight home* to avoid flashing a map during startup.
4. `dispose` (`:149‑156`) cancels both timers and the animation controllers.

#### D. Foreground‑service configuration — `initializeService()` (`trackingservice.dart:208‑231`)

Called from splash. On non‑test builds it wires the ACK listeners then `_service.configure(...)`:
- **Android** (`:212‑224`): `onStart: _onStart`, `autoStart:false`, **`autoStartOnBoot:true`** (G4 — after a reboot the OS re‑runs `_onStart` so an active session can resume), `isForegroundMode:true`, channel `geowake_tracking_channel_v2`, foreground notification id **888**.
- **iOS** (`:225‑229`): `onForeground: _onStart`, `onBackground: onIosBackground` (which just `ensureInitialized()` + returns `true`, `:616‑619`).

#### E. Arming from the UI — `startTracking(...)` (`trackingservice.dart:234‑329`)

1. `_ensureAckListenersRegistered()` (`:245`) — makes sure the foreground can hear the background's ACK and alarm‑trigger events (`:145‑182`; wires `onAlarmTrigger` → `NotificationService().showWakeUpAlarm`).
2. `unawaited(recordSessionStart(...))` (`:250`) — fire‑and‑forget telemetry funnel (device/OEM/Android + permission states); explicitly fail‑open so it can never delay or break arming.
3. Builds the `params` map (destination lat/lng/name, alarmMode, alarmValue, transitMode, useInjectedPositions, isSimulationMode; optional `routePoints`) (`:252‑271`).
4. **Test mode** (`:272‑286`): directly `await _onStart(TestServiceInstance(), initialData: params)` and return — no real isolate.
5. **Real mode:**
   - If the service isn't running, `await _service.startService()` (`:287‑289`). *(This spawns the background isolate, which begins `_onStart(null)` — see the race in Design Decision #7.)*
   - Best‑effort state init (`:290‑309`, caught): `setNotificationsMuted(false)`, `setActive(true)`, `setPaused(false)`, `setAlarmFired(false)`, and show the initial "Journey to … / Starting…" progress notification.
   - `acked = await _invokeWithAckRetry(method:'startTracking', args:params, ackEvent:'startTrackingAck')` (`:314‑318`).
   - If **not acked**, fallback best‑effort `_service?.invoke('startTracking', params)` (`:319‑326`).
   - `_startForegroundHeartbeat()` (`:328`) — begins the 1 Hz heartbeat.
   - **ACK‑retry mechanics** (`foreground_bridge.dart:265‑311`): up to 5 attempts, per‑attempt 400 ms ACK timeout, escalating back‑off (30/80/150/300/500 ms). Worst case ≈ 3.4 s before giving up and logging `CRITICAL: No ACK received`. It does **not** restart the service on failure.

#### F. Background‑isolate entry — `_onStart(service, {initialData})` (`trackingservice.dart:1875‑2203`)

This runs in the **second isolate**. Two ways in: (a) with `initialData` (test/direct), (b) with `initialData == null` (real `startService()` *and* reboot auto‑start *and* OS‑restart‑after‑death).

1. `ensureInitialized()`, sets `_isBackgroundIsolate = true` (`:1879‑1880`).
2. Bridges `RouteSessionManager` streams → `TrackingService` controllers (route state / route switch / reroute / deviation‑for‑termination / wrong‑direction) (`:1882‑1927`). Route switches migrate alarm‑fired state to the new key so alarms don't re‑fire (`:1891`).
3. `await _etaEngine.loadState()` (`:1930`).
4. Initializes `NotificationService` in this isolate (must be re‑inited per isolate or Android Context is null) (`:1936‑1962`).
5. **Registers all command handlers** via `BackgroundHandlers(...).registerAll()` (`:1966‑2057`): `startTracking`→`_handleBackgroundStartTracking`, `stopTracking`→`_onStop`, `registerRoute`, `registerRouteDirections`, `stopAlarm`, `foregroundHeartbeat`→`_heartbeatMonitor.recordHeartbeat()`, `foregroundResumed`, `setSimulationMode`. **Listeners are registered *before* the branch below** — deliberately, to avoid losing an early command.
6. Re‑inits `NotificationService` again (`:2062`) and sets `LocationManager` alarm‑reset / route‑switch callbacks (`:2071‑2074`).
7. **Branch on `initialData`:**
   - **Non‑null (`:2077‑2119`):** restore destination/name/mode/value from the map, set `_trackingSessionActive = true`, reset alarm + time‑gating state, `startLocationStream(service)`, and start the alarm‑stop poll timer.
   - **Null → RECOVERY (`:2120‑2202`):** read `TrackingStateStore.isActive()`. If **active** and a snapshot exists → restore destination/name/mode/value/**transitMode**, set active, re‑register the route from the snapshot's directions (`SnapshotRouteRestorer`), `startLocationStream`, start poll timer, and show a "Resumed" notification. If **active but snapshot is null** → log "No snapshot found, stopping self" → `service.stopSelf()`. If **not active** → "Session not active, stopping self" → `service.stopSelf()`. Any exception → `stopSelf()`.

#### G. Command‑driven arm — `_handleBackgroundStartTracking(...)` (`trackingservice.dart:1578‑1776`)

Invoked by the `startTracking` command handler. It: resets all stale per‑session state (registry, EtaEngine, location handler, smoothed speed, alarm controller, EKF snapshots) (`:1600‑1624`); sets `_destination/_destinationName/_alarmMode/_alarmValue` and `_trackingSessionActive = true` (`:1626‑1630`); resets the termination policy and sets its destination (`:1633‑1634`); re‑subscribes the RouteSessionManager streams (`:1638‑1682`); persists `setActive(true)/setPaused(false)/setAlarmFired(false)` (`:1685‑1694`); **restores route directions from the store** in case the foreground→background route‑registration invoke was dropped (`:1699‑1721`); resets alarm/time state again (`:1723‑1732`); computes first transit boarding point if needed (`:1733‑1748`); shows the initial journey notification (`:1756‑1768`); and finally `startLocationStream(service)` (`:1775`).

#### H. Lifecycle mirroring — `handleAppLifecycleChange(state)` (`trackingservice.dart:479‑526`)

`void … async` (fire‑and‑forget). No‑op in test mode.
- **`resumed`**: calls `_startForegroundHeartbeat()` **twice in a row** (`:493‑494` — a duplicate; the second is redundant), then, if the service is running, invokes `foregroundResumed` on the background (`:499`), which records a heartbeat, ensures the monitor is started, and if state was `paused` clears it and restores the journey notification (`_handleBackgroundForegroundResumed`, `:1841‑1872`).
- **`paused`**: deliberately does **nothing** to the heartbeat. The long comment (`:510‑517`) explains that when merely backgrounded the Flutter timer keeps running and heartbeats keep flowing; only a real kill (swipe‑away) stops the process and hence the heartbeat. Stopping heartbeats on `paused` previously caused a false "tracking paused" banner.
- **`detached`**: only logs; the comment notes `detached` is rarely delivered reliably on Android, so **the 4 s heartbeat timeout is the primary swipe‑away detector**.

#### I. Swipe‑away detection — `HeartbeatMonitor` (`heartbeat_monitor.dart`)

Runs in the background isolate. `recordHeartbeat()` stamps `DateTime.now()` (`:30‑32`). `start()` (`:40‑99`) polls every **2 s** (`checkInterval`); if `now − lastHeartbeat > 4 s` (`timeout`) it concludes the UI is gone. Then, only if the session is `active` and not already `paused` and not in simulation mode, it `setPaused(true)`, cancels the journey notification, shows the "tracking paused" notification, and `stop()`s itself (`:57‑91`). **It uses raw `DateTime.now()`, not `AppClock` — which is exactly why it must be skipped in simulation mode.**

#### J. Teardown — `completeEndTracking(...)` and `_onStop()`

- `completeEndTracking({navigateHome=true})` (`trackingservice.dart:528‑557`): cancels all notifications; clears the snapshot; sets active/paused/alarmFired/muted flags to their "off" values (all caught) (`:530‑541`); `await stopTracking()` (`:543`); then, if `navigateHome` and not test, uses `NavigationService.navigatorKey.currentState?.pushNamedAndRemoveUntil('/', ...)` to return home (`:546‑556`).
- `stopTracking()` (`:331‑362`) stops the foreground alarm/vibration, and either invokes `stopTracking` on the running background service or calls `_onStop()` directly.
- `_onStop()` (`:877‑946+`): flips `_isBackgroundIsolate`/`_trackingSessionActive` to false, stops the heartbeat monitor, stops the location handler + `LocationManager`, broadcasts `active:false`, cancels timers/sensor fusion, **releases the wake lock** and **cancels the exact‑alarm ETA backstop** (G1/G5), and cancels all the manager subscriptions.

#### K. `AppClock` (`app_clock.dart`)

A singleton (`AppClock()` factory → `_instance`). Config: `_warpFactor` (default 1.0), `_simulationStartReal`, `_simulationStartVirtual`. `now()` (`:116‑130`) fast‑paths to real `DateTime.now()` when not simulating; otherwise `virtual = startVirtual + (realElapsed × warpFactor)`. `setWarpFactor` (`:54‑70`) clamps to **1.0–500.0** and re‑anchors virtual time so a mid‑run change is continuous. `enableSimulation({startAt})`/`disableSimulation()` toggle the mode. Helpers: `since`, `hasElapsed`, `createPeriodicTimer`/`createTimer` (fire on real intervals, deliver warped `now`). `reset()`/`install()` swap the singleton for tests. **Adoption is partial** (see Gaps): it is imported by `eta_engine`, `alarm_controller`, `deviation_monitor`, `tracking_termination_policy`, and the dashboards — but **not** by `trackingservice.dart` (0 `DateTime.now()` calls there) nor by `heartbeat_monitor.dart` (raw `DateTime.now()`).

---

### Key types & functions

- **`MyApp` / `MyAppState`** (`main.dart:65‑188`) — root widget; `WidgetsBindingObserver`; owns routing, theme persistence (`gw_dark_mode` via `SharedPreferences`), and lifecycle forwarding. `didChangeAppLifecycleState(AppLifecycleState) → void`.
- **`SplashScreen` / `_SplashScreenState`** (`splash_screen.dart`) — `Future<void> _initializeServices()`, `Future<void> _checkStateAndNavigate()`. The router that chooses home vs restore vs zombie‑cleanup.
- **`NavigationService`** (`navigation_service.dart`) — `static final GlobalKey<NavigatorState> navigatorKey`. Context‑free navigation for background/service code.
- **`TrackingService`** (singleton; `factory TrackingService() => _instance`, `trackingservice.dart:108‑112`):
  - `Future<void> initializeService()` — configure the platform foreground service.
  - `Future<void> startTracking({required LatLng destination, required String destinationName, required String alarmMode, required double alarmValue, bool transitMode, bool allowNotificationsInTest, bool useInjectedPositions, List<LatLng>? routePoints})` — arm from the UI.
  - `void handleAppLifecycleChange(AppLifecycleState state)` — mirror app lifecycle (async, fire‑and‑forget).
  - `Future<void> completeEndTracking({bool navigateHome})` — full clean shutdown + optional navigate home.
  - `static bool isTestMode`; `bool isSimulationMode` / `setSimulationMode(bool)`.
- **Top‑level isolate functions:** `Future<void> _onStart(ServiceInstance, {Map? initialData})` (background entry), `void _handleBackgroundStartTracking({...})`, `void _onStop()`, `bool onIosBackground(ServiceInstance)`.
- **`HeartbeatMonitor`** (`heartbeat_monitor.dart:14‑106`) — `recordHeartbeat()`, `start()`, `stop()`, `ensureStarted()`; `timeout=4s`, `checkInterval=2s`.
- **`ForegroundBridge.invokeWithAckRetry({method, args, ackEvent}) → Future<bool>`** (`foreground_bridge.dart:265‑311`).
- **`AppClock`** (`app_clock.dart:24‑201`) — `now()`, `setWarpFactor(double)`, `enableSimulation({startAt})`, `disableSimulation()`, `since`, `hasElapsed`, `createPeriodicTimer`, `createTimer`, `static reset()/install()`.

---

### Design decisions (the WHY)

1. **Three independent crash nets in `main()` (`main.dart:29‑62`).**
   *Decided:* capture framework errors (`FlutterError.onError`), platform errors (`PlatformDispatcher.onError`, return `true` = handled), and async‑zone errors (`runZonedGuarded`), all routed to telemetry.
   *Why:* a reliability app "must never die silently" — a crash in the tracking isolate that nobody records is a rider who was never woken *and* a bug you can never diagnose.
   *Trade‑off / rejected:* swallowing platform errors (`return true`) keeps the app alive but can mask a truly corrupt state and keep a broken session limping. Alternative (letting it crash) was rejected because a crash mid‑journey = guaranteed miss.
   *Flaw:* `recordError` runs synchronously inside the error handlers; if telemetry itself throws, there's no guard against re‑entrancy. And a "handled" fatal that leaves the app in a bad state is now invisible to the user.

2. **Two separate entry points; the dashboard bypasses production init (`main_unified_dashboard.dart:12‑15`).**
   *Decided:* the test dashboard's `main()` only does `ensureInitialized()` + `runApp(UnifiedDashboardApp())`.
   *Why:* fast, isolated end‑to‑end testing of the simulation UI without store/ads/Hive/error‑handler weight.
   *Trade‑off:* the dashboard runs in a materially different environment than production — no error nets, no Hive, no monetization, no edge‑to‑edge. Anything "proven" in the dashboard is proven in a *different* runtime than what ships.
   *Flaw:* easy to over‑trust dashboard results; a bug that only appears with the production init order won't show up there.

3. **Heavy service init moved from `main()` into `SplashScreen` (`main.dart:51`, `splash_screen.dart:54‑80`).**
   *Decided:* API/notification/tracking init happens during the splash, behind animations.
   *Why:* faster first‑frame; the user sees a branded splash instead of a white screen while I/O runs.
   *Trade‑off:* the splash's `_checkStateAndNavigate` must now defensively `timeout(8s)` the init (`:96`) and proceed even if it failed — so the app can reach the map with a half‑initialized `ApiClient`/`NotificationService`.
   *Flaw:* each init is independently try/caught and **non‑fatal** (`:54‑80`). If `NotificationService().initialize()` silently fails here, the app still navigates on — and notifications are the delivery mechanism for the wake alarm. There is no user‑visible "setup failed" state.

4. **Splash routes by reading persisted flags, with an explicit zombie‑alarm path (`splash_screen.dart:82‑147`).**
   *Decided:* check `isAlarmFired()` first (kill the orphaned alarm), then `isActive()` (restore or cleanup), else go home after 3 s.
   *Why:* the OS can kill the app *while the alarm is ringing*; on relaunch you must both stop the un‑cancelable notification and not silently resume a finished journey.
   *Trade‑off:* correctness depends entirely on `TrackingStateStore` (SharedPreferences) being consistent with reality. A corrupted/missing snapshot is treated as "clean up and go home" (`:112‑121`) — safe, but it means a real in‑flight journey with a lost snapshot is *silently abandoned*.
   *Flaw:* the normal cold‑start path adds a fixed **3 s** timer *after* waiting up to **8 s** for init (`:96` then `:141`), so worst‑case cold start to home ≈ 11 s. Also `_checkStateAndNavigate` is not awaited and races the animation state; multiple `mounted` guards paper over it but the timing is implicit, not enforced.

5. **Android foreground service with a persistent notification + `autoStartOnBoot:true` (`trackingservice.dart:212‑224`).**
   *Decided:* run tracking as a foreground service (id 888, channel v2) and re‑launch the entry point after reboot.
   *Why:* Android aggressively kills background work; a *foreground* service with an ongoing notification is the sanctioned way to keep GPS + the EKF running with the screen off — essential for "GPS dies underground" survival. Reboot auto‑start lets a journey survive a phone restart (G4).
   *Trade‑off:* a permanent notification the user can't dismiss; on aggressive OEM skins (Xiaomi/Oppo/Vivo — common in India) even foreground services get killed unless the user grants battery‑optimization exemptions, which this file does **not** request.
   *Flaw:* `autoStartOnBoot` re‑runs `_onStart(null)`, which only resumes if `isActive()` + snapshot survive; if either was cleared, a reboot silently ends the journey with no user signal.

6. **ACK‑retry command delivery, but no service‑restart on failure (`trackingservice.dart:314‑326`, `foreground_bridge.dart:265‑311`).**
   *Decided:* deliver `startTracking` with 5 retries / 400 ms ACK timeout / escalating back‑off (~3.4 s max), then a single best‑effort fallback `invoke`.
   *Why:* cross‑isolate `invoke` is fire‑and‑forget and can be dropped before the background registers its listeners; retry‑until‑ACK closes that window.
   *Trade‑off:* worst case ~3.4 s of arming latency before giving up.
   *Flaw:* on total ACK failure it logs `CRITICAL` and returns `false`, but the fallback `invoke` is *also* fire‑and‑forget and the code proceeds to `_startForegroundHeartbeat()` regardless — so the user can see a "Journey… / Starting…" notification (shown at `:297`) with **no background tracking actually running**. There is no retry that restarts the service, and no UI signal that arming failed.

7. **Two independent bring‑up paths (`startService()` → `_onStart(null)` recovery *and* the `startTracking` command → `_handleBackgroundStartTracking`) — the cold‑start arming race.**
   *Decided:* `startTracking` calls `await _service.startService()` (`:288`) *then* `setActive(true)` (`:294`) *then* sends the `startTracking` command. `startService()` triggers `_onStart(null)`, whose recovery branch reads `isActive()` and calls `service.stopSelf()` when it sees the session inactive or snapshot‑less (`:2184‑2196`).
   *Why:* the null‑`initialData` recovery branch is genuinely needed for reboot/after‑death restart; reusing `_onStart` for both keeps one entry point.
   *Trade‑off / FLAW (high severity):* on a **fresh** arm, `_onStart(null)` and the foreground's `setActive(true)` + command send are **not ordered**. If the recovery branch's `await isActive()` observes `false` (or `true` but the UI hasn't persisted the snapshot yet), it calls `stopSelf()` — potentially tearing down the very isolate that the `startTracking` command is trying to arm. The long `await` chain before the branch (etaEngine load, two NotificationService inits) *usually* lets the foreground win, and the command handler is registered before the branch, but nothing *guarantees* the ordering. The design leans on an implicit "UI persists the snapshot before arming" contract (`:293`, `:1698`) that is not enforced here. I could not statically prove this is race‑free; it is the single most fragile point for the core promise (a lost arm = a rider never woken) and deserves a deterministic guard (e.g., have the fresh‑start command path suppress the recovery `stopSelf`, or set active+snapshot *before* `startService()`).

8. **`paused` does not stop the heartbeat; swipe‑away is detected by a 4 s heartbeat timeout, not by `detached` (`trackingservice.dart:510‑525`, `heartbeat_monitor.dart:24‑25`).**
   *Decided:* keep heartbeats flowing while merely backgrounded; treat 4 s of heartbeat silence as "UI killed."
   *Why:* Android rarely delivers `detached` reliably, and stopping heartbeats on `paused` produced a false "tracking paused" banner every time the user backgrounded the app.
   *Trade‑off:* a 4 s window where a genuinely‑killed UI is still considered alive; and the heuristic conflates "process killed" with "Flutter timers throttled." If the OS heavily throttles the foreground timer (Doze) without killing it, a false "paused" could still fire.
   *Flaw:* the pause detection lives in the *background* isolate but depends on the *foreground* timer's health — two things the OS can throttle independently. It is also simulation‑blind (see #10).

9. **Duplicate `_startForegroundHeartbeat()` call on resume (`trackingservice.dart:493‑494`).**
   *Decided (apparently unintentionally):* the method is called twice back‑to‑back on `resumed`.
   *Why:* almost certainly a copy‑paste artifact.
   *Trade‑off:* the underlying `ForegroundBridge.startHeartbeat()` cancels any existing timer first (`foreground_bridge.dart:316`), so it's idempotent and harmless today.
   *Flaw:* dead/confusing code that signals the resume path wasn't carefully reviewed; if `startHeartbeat` ever became non‑idempotent this would double‑fire.

10. **`AppClock` warp‑clock abstraction — but the lifecycle layer opts out.**
    *Decided:* provide a singleton clock (1×–500×) so cooldowns/deviation/termination/ETA run fast in simulation; but `trackingservice.dart` and `heartbeat_monitor.dart` use real time (heartbeat uses raw `DateTime.now()`).
    *Why:* the simulation dashboard needs to compress hours of travel into seconds; alarm/ETA/deviation/termination logic is the part whose *time‑dependent behavior* must be validated, so those adopt `AppClock`. Wall‑clock plumbing (heartbeat cadence, splash timers) is real‑time by nature.
    *Trade‑off:* because the heartbeat isn't warp‑aware, it would false‑trip under warp, so it is explicitly **skipped in simulation mode** (`heartbeat_monitor.dart:69‑76`) — meaning a whole class of lifecycle behavior is simply *not exercised* by the simulator.
    *Flaw:* partial adoption creates a two‑clock world. Anything validated in simulation is validated with the swipe‑away/heartbeat path disabled, and `AppClock.now()` is wall‑clock‑based (not monotonic), so a device clock jump (NTP correction) during a real journey shifts every cooldown/ETA computed on top of it.

11. **Global `navigatorKey` for context‑free navigation (`navigation_service.dart`, used at `trackingservice.dart:548‑549`).**
    *Decided:* one static `GlobalKey<NavigatorState>` so services can `pushNamedAndRemoveUntil('/')`.
    *Why:* teardown/alarm code has no `BuildContext`.
    *Trade‑off:* in the background isolate `navigatorKey.currentState` is `null` (different isolate, no widget tree); the call is null‑safe and try/caught (`:547‑555`), so background teardown simply doesn't navigate — acceptable, but it means "return to a safe screen" only happens when teardown runs in the UI isolate.
    *Flaw:* silent no‑op navigation in the wrong isolate; a maintainer could wrongly assume `completeEndTracking` always lands the user on home.

---

### Invariants (what must always hold)

- Exactly **one** production entry (`main.dart`); `main_unified_dashboard.dart` is dev‑only and must never ship as the launch target.
- `_isBackgroundIsolate` is `true` only inside the background isolate (`_onStart` sets it, `_onStop` clears it); foreground code must not assume it can see background globals directly — it talks over `ForegroundBridge`.
- After a successful arm: `TrackingStateStore.isActive() == true`, `isPaused() == false`, `isAlarmFired() == false`, a snapshot exists, the location stream is running, and the foreground heartbeat is ticking.
- The persistent foreground notification (id 888) exists for the entire lifetime of an active session and is cancelled by `_onStop`/`completeEndTracking`.
- The wake lock (G1) is held for exactly the span between `startLocationStream` and `_onStop`; the ETA exact‑alarm backstop (G5) is cancelled on stop.
- Command handlers in `_onStart` are registered **before** the recovery/`stopSelf` branch runs.
- `AppClock.warpFactor ∈ [1.0, 500.0]`; `isSimulating` ⇔ `_simulationStartReal != null`.

### Interfaces (consumes ↔ exposes)

- **Consumes:** `TrackingStateStore` (SharedPreferences: active/paused/alarmFired/muted flags, snapshot, progress payload) — the shared truth between the UI isolate, the background isolate, and cold‑start recovery. `NotificationService` (journey progress, wake alarm, paused/wrong‑direction banners, ETA backstop). `TelemetryService` (error + session‑start funnel). `MonetizationService` (fire‑and‑forget init). `ApiClient` (init in splash). `Hive` (recents durability). `WakepointNative` (wake lock). `flutter_background_service` (`FlutterBackgroundService`, `ServiceInstance`).
- **Exposes:** `TrackingService.startTracking / completeEndTracking / stopTracking / handleAppLifecycleChange`; the streams `activeRouteStateStream`, `routeSwitchStream`, `rerouteDecisionStream`, `locationStream`, `etaSecondsStream` (bridged from the background isolate); `NavigationService.navigatorKey`; `AppClock` (consumed by ETA/alarm/deviation/termination and the dashboards). The background isolate's `_onStart` is the platform `onStart`/`onForeground`/boot entry point registered in `initializeService`.

### Gaps & flaws vs the core promise (brutally honest)

1. **Cold‑start arming race (Design #7) — the biggest risk.** `startService()` triggers a recovery `_onStart(null)` that can `stopSelf()` based on `isActive()`/snapshot state that the foreground is setting concurrently. Under static reading this is not provably race‑free. If it loses the race, the user sees "Starting…" but nothing tracks, and there is **no restart and no user‑visible failure**. For a "never late" product this is a potential silent no‑arm. *Needs a deterministic guard.*
2. **Silent arming/notification‑init failures.** ACK total failure (`foreground_bridge.dart:306‑310`) and `NotificationService().initialize()` failure in splash (`splash_screen.dart:63‑70`) are both logged and swallowed with no UI. Notifications are the delivery channel for the wake — a failed init there defeats the entire promise silently.
3. **Permissions largely out of scope here.** `main.dart` only requests notification permission (`:117‑122`). Location, background‑location, battery‑optimization exemption (critical on Indian OEM skins), and exact‑alarm are handled elsewhere; this entry layer provides no guarantee they were granted before arming.
4. **OEM/reboot durability is best‑effort.** `autoStartOnBoot` + snapshot recovery help, but aggressive OEM process‑killing (Xiaomi/Vivo/Oppo — a core "cheap Android in India" scenario) can kill the foreground service, and recovery silently ends the journey if `isActive()`/snapshot were cleared. No user‑facing "your journey may have stopped" signal.
5. **Two‑clock simulation blind spot (Design #10).** The heartbeat/swipe‑away path is disabled under simulation, so the simulator never exercises UI‑killed detection; and `AppClock` is wall‑clock‑based, so a real device clock jump perturbs downstream cooldowns/ETA.
6. **Long, implicit cold‑start latency.** Up to ~8 s init wait + a fixed 3 s splash delay before reaching home on a normal launch (`splash_screen.dart:96`,`:141`) — a UX drag and an implicit, timing‑dependent contract rather than an event‑driven one.
7. **`didChangeAppLifecycleState` durability is narrow.** Hive is flushed only on `paused` (`main.dart:103‑110`); `inactive`/`detached` don't flush, and `dispose`'s `Hive.close()` rarely runs on real terminations — so a kill that skips `paused` can lose the most recent recents write (non‑safety, but a correctness gap).
8. **Unguarded route‑argument cast.** `/preloadMap` does `settings.arguments as Map<String,dynamic>` (`main.dart:169`) with no null/type guard — a malformed navigation would throw (caught only by the global zone).
