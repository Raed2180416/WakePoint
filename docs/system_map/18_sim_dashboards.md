## Simulation, Dev Dashboards & Testing Infrastructure

**Role in the core promise:** This is GeoWake's *validation lab*, not the product. The core promise — wake a rider before their stop, never late, never at the wrong place, even when GPS dies underground on a cheap Android phone in India — is a claim that can only be *trusted* if it has been exercised against realistic, hostile scenarios before shipping: multi-hour metro rides compressed into minutes via time-warp, GPS-dropout tunnels, off-route deviations and reroutes, and real recorded IMU rides replayed through the *actual* production alarm engine. This subsystem provides all of that: (1) a **web dashboard** (runs in Chrome, not on the phone) that drives a "virtual rider" along a route and can push those positions into a real device; (2) a **WebSocket bridge** that mirrors device↔dashboard state; (3) an **OSM road-graph + A\* pathfinder** so simulated deviations follow real streets; (4) an **EKF replay panel** that scores the real `AlarmEvaluator` against ground truth; and (5) a **162-file automated test suite**. Critically, *almost none of this code ships in the alarm-firing path* — the sole on-device exception is `SimulationClient` (gated to debug/profile builds). So its failure mode is not "rider misses stop" directly; it is the more insidious "a defect ships because the lab never caught it," or "the lab shows green while feeding the real ETA logic distorted inputs." Several such integrity gaps exist and are called out below.

---

### Files

| Path | What it does |
| --- | --- |
| `lib/main_unified_dashboard.dart` | Web entry point. `flutter run -d chrome -t lib/main_unified_dashboard.dart` boots the current dashboard. |
| `lib/dashboard/unified_dashboard.dart` | **The canonical dashboard** (~1980 lines). Combines simulate-send + monitor-receive + EKF replay + map rendering + WebSocket. |
| `lib/dashboard/deviation_dashboard.dart` | **Orphaned earlier variant** (`DeviationDashboardApp`). Superseded by `unified_dashboard`; no entry point references it. |
| `lib/dashboard/deviation_simulation_controller.dart` | The "virtual rider" engine: walks a route, computes deviations/returns via pathfinder, emits ticks, supports time-warp. |
| `lib/dashboard/simulation_state.dart` | `SimulationStateMachine` — 5-state FSM (idle/onRoute/deviating/returning/paused) with legal-transition guards. |
| `lib/dashboard/constraint_logger.dart` | Singleton event log (`ConstraintLogger`) + typed `ConstraintEvent` factories (deviation, reroute, alarm, warp…). |
| `lib/dashboard/constraint_drawer.dart` | Slide-out UI panel that renders the constraint event log with color/icon per type + JSON/CSV export. |
| `lib/dashboard/simulation_controls.dart` | Stateless button panel (Start/Stop/Deviate/Return/Pause/Resume/Revert) driven by `SimulationState`. |
| `lib/dashboard/speed_slider.dart` | 1–160 km/h speed control + presets; km/h↔m/s helpers. |
| `lib/dashboard/time_warp_slider.dart` | 1×–200× time-warp control + presets. |
| `lib/dashboard/osm_overlay_manager.dart` | Draws OSM road polylines on the Google Map (styled by road class). |
| `lib/dashboard/ekf_test_panel.dart` | UI to replay curated/real recorded rides through the EKF; shows σ, ZUPT, drift, RMSE, in-sim alarm result. |
| `lib/dashboard/alarm_debouncer.dart` | Rising-edge + hold debouncer for alarm state. **Only referenced by a test** — not wired into any dashboard. |
| `lib/services/simulation_client.dart` | **The only on-device piece.** WebSocket client that injects simulated GPS into `LocationManager` (debug/profile only). |
| `lib/services/testing/osm_graph.dart` | In-memory road graph (`OsmGraph`, `OsmNode`, `OsmEdge`) + 100×100 spatial grid for nearest-node lookup. |
| `lib/services/testing/osm_loader.dart` | Parses the binary `.wkp` road file (magic `WKP1`), full + windowed loads; synthetic grid fallback. |
| `lib/services/testing/pathfinder.dart` | `Pathfinder` (A\*) + `DeviationPathfinder` (route-avoidance / return / continued-deviation). |
| `lib/simulation_engine.dart` | `SimulationEngine` — **dead code / orphaned.** Simpler route-walker referenced nowhere. |
| `lib/debug/demo_tools.dart` | `DemoRouteSimulator` — **orphaned** on-device demo that would fire *real* alarms/notifications if resurrected. |
| `lib/debug/dev_server.dart` | `DevServer` — **orphaned** localhost HTTP trigger server (debug-only, loopback-bound). |
| `lib/config/playground_bridge.dart` | `PlaygroundBridgeConfig` — feature flag + relay URL; disables the bridge in tests and (by default) release. |
| `lib/core/clock/app_clock.dart` | `AppClock` singleton — real-time or warped virtual time. Shared with production, central to time-warp. |
| `tools/relay_server.dart` | Standalone Dart CLI. Dumb WebSocket broadcast hub on `0.0.0.0:8081` with ping/pong heartbeat. |
| `test/` (162 files) | Automated suite: 145 `*_test.dart` + 17 helpers/manual scratch scripts. Categorized below. |

---

### How it works, step by step

There are **five independent flows**. They share the map and the constraint log but are otherwise separable.

#### Flow 1 — Time-warped deviation simulation (entirely inside the dashboard)

This is the "virtual rider." No device required.

1. **Boot.** `main_unified_dashboard.dart` → `UnifiedDashboardApp` → `UnifiedDashboard`. `initState()` sets `TrackingService.isTestMode = true`, `setSimulationMode(true)`, then `_initializeSimulation()`, `_connectToRelay()`, `_subscribeToConstraints()`, `_startHealthMonitor()`.
2. **Controller creation.** `_initializeSimulation()` builds a `DeviationSimulationController` with `graph: null` (the 20 MB OSM graph is *deliberately not* loaded at startup for performance) and config `deviationDistanceM: 300, routeAvoidanceRadiusM: 50, returnThresholdM: 25`. It subscribes `_onSimulationTick` to `positionStream` and `setState` to `stateStream`, then `loadRoute(_demoRoute, routeId:'demo_bengaluru')` (a hard-coded 5-point Bengaluru MG-Road→Airport-Road path).
3. **Start.** User presses Start → `controller.start()`: `AppClock().enableSimulation()`, FSM `idle→onRoute`, and a **`Timer.periodic(33 ms)`** loop begins (`_startSimulationLoop`, "30 FPS").
4. **Each tick (`_tick`).** Reads `AppClock().now()` (which may be warped), computes `realDt = now − lastTickTime` in seconds, then `_moveAlongPath(realDt)`:
   - `moveDistance = speedMps × dtSeconds` (default `speedMps = 11.1` = 40 km/h; settable 0.3–44.4 m/s = 1–160 km/h).
   - It advances `_progressInSegment` along the current polyline segment (`moveDistance / segmentLength`), rolling over vertices with a `while` loop, interpolating `LatLng` linearly and computing heading via `atan2(dLon, dLat)`.
   - When it runs off the end it calls `_handlePathComplete()` (see step 6).
5. **State + emit.** `_checkStateTransitions()` (if returning and within `returnThresholdM=25 m` of the route → snap back onto original route at nearest segment), then `_emitPositionUpdate()` pushes a `SimulationTickResult{position, heading, speedMps, virtualTime = AppClock().now(), distanceFromRoute}`.
6. **Deviation.** User presses "Start Deviation" → `_startDeviationOptimized()`:
   - `_ensureLocalGraphLoaded()` lazily loads a **3 km window** of `assets/osm/bengaluru.wkp` centered on the sim position + nearest route point (`OsmLoader.loadAssetWindowed`), or a synthetic grid on failure. It caches the window bounds and skips reloading while the rider stays inside.
   - `DeviationSimulationController.startDeviation()` requires FSM state `onRoute`, a current position, and a graph. It finds the nearest OSM node (≤ 2 km), then `DeviationPathfinder.findDeviationPath()` computes a perpendicular escape target ~300 m away and runs A\* with a *route-avoidance cost penalty* (nodes within `routeAvoidanceRadiusM` of the route cost up to `+routeAvoidancePenalty`). The returned path becomes `_currentPath`; FSM `onRoute→deviating`.
   - While deviating, `_handlePathComplete()` calls `findContinuedDeviationPath()` to keep fleeing in the same direction, so the rider doesn't stop at the end of the first escape path.
7. **Return.** "Go Back to Route" → `findReturnPath()` (A\* to nearest route point), FSM `deviating→returning`. When within 25 m, snap onto the original route (`onReachedRoute`, FSM→`onRoute`).
8. **Scrubbing.** The Progress slider calls `controller.seek(t)` (t∈[0,1] on the *original* route). If dragged backward >0.05, `_broadcastAlarmReset()` tells the device to clear fired-leg IDs. On drag-start it pauses; on drag-end it resumes if it was playing.
9. **Time-warp.** The Time-Warp slider → `setWarpFactor(f)` → `AppClock().setWarpFactor(f)`. `AppClock.now()` returns `simulationStartVirtual + (realElapsed × warp)`. Changing warp mid-run *rebases* the virtual clock so time is continuous. Every logged event timestamps with `AppClock().now()`, so the constraint log is in virtual time.

Every meaningful action funnels a typed `ConstraintEvent` into the singleton `ConstraintLogger`, which fans out to (a) the in-panel `ConstraintDrawer` (last 200 kept) and (b) the WebSocket as a `constraint_event`.

#### Flow 2 — The WebSocket bridge (dashboard ↔ relay ↔ device)

The dashboard runs in Chrome; the app runs on a phone. They never talk directly — a **relay** sits between them.

1. **Relay** (`tools/relay_server.dart`): binds `0.0.0.0:8081`, keeps a client list, **re-broadcasts every message to all *other* clients**, and pings every 30 s (drops a client after 60 s of no pong). It has zero knowledge of message semantics — a pure hub.
2. **Config** (`PlaygroundBridgeConfig`): `relayUrl` defaults to `ws://127.0.0.1:8081`. `enabled` = `false` under `flutter test`, `false` if `PLAYGROUND_BRIDGE_DISABLED`, else `true` in debug/profile (or if `PLAYGROUND_BRIDGE_ENABLED`). So a stock **release build does not connect**.
3. **Device side** (`SimulationClient`, instantiated by `LocationManager`): connects with exponential-backoff reconnect (`1<<attempts` clamped 1–30 s), monitors health (reconnect if no ping for 90 s), and carefully handles the `ready` Future so an unhandled WebSocket handshake error can't kill the isolate and silence alarms (an explicitly documented hazard).
   - **Device → dashboard** it *sends*: `route_update` (`broadcastRoute`), `app_state` (`broadcastState`: eta, distance, alarm mode/value/fired, remaining_stops, debug_info), `device_position` (`broadcastPosition`), and `pong`.
   - **Dashboard → device** it *handles*: `simulation_update` (inject a sim GPS fix), `reset_alarm_state`, `switch_route`, and `ping`.
4. **Injection.** On a `simulation_update`, `SimulationClient._handleMessage` builds a `geolocator.Position`. It **prefers the dashboard's `virtualTime`** for the timestamp and the dashboard's `speedMps` for speed — because under time-warp, stamping with `DateTime.now()` or deriving speed from `Δdistance/Δt` inflates speed by the warp factor and *collapses ETA to near-zero* (heavily commented). Only if `speedMps` is absent does it fall back to derived speed (clamped 0–60 m/s). The `Position` is pushed onto `positionStream`.
5. **`LocationManager`** listens to that stream. The first simulated position flips `_isSimulationMode=true` and triggers `onAlarmReset` (so stale `firedLegIds` from prior sessions don't suppress a fresh alarm). While in sim mode, real GPS (`_onRealPosition`) is **ignored**. `onDisconnected` clears sim mode so real GPS resumes. From here the position flows into the *real* tracking/ETA/alarm pipeline — this is what makes the simulation a genuine end-to-end test.
6. **Dashboard side** (`html.WebSocket` in `unified_dashboard`): handles `ping`, `route_update` (mirror the app's real route + colored segments onto the map, compute a route signature to dedupe), `app_state` (update Device-Metrics panel; if `alarm_fired` log an `ALARM FIRED` event; if `active:false` clear the map), `device_position` (draw the device marker), and `simulation_control` (a *third-party controller* can remote-drive the dashboard). Outbound it broadcasts `simulation_update`, `constraint_event`, `reset_alarm_state`, `switch_route`, and `ekf_test_position`.

#### Flow 3 — OSM graph + A\* pathfinding (makes deviations follow real roads)

1. **Binary format** (`OsmLoader`): `.wkp` = 16-byte header (`'WKP1'` magic, uint16 version=1, uint32 nodeCount, uint32 edgeCount, 2 reserved), then `nodeCount` × 16-byte node records (float32 lat, float32 lon, uint64 osmId), then `edgeCount` × 16-byte edge records (uint32 from, uint32 to, float32 distance, uint8 roadType, uint8 oneway, 2 pad). Size is validated against the header before parsing.
2. **Windowed load** (`loadBytesWindowed`): derives a bounding box from `centers ± radiusM`, then materializes *only* nodes/edges inside it, remapping indices (`oldToNew`) and yielding to the event loop every 50 k nodes / 100 k edges to avoid jank. This is what keeps the 20 MB Bengaluru graph usable on a web page.
3. **Graph** (`OsmGraph`): stores nodes, edges, an adjacency list, bounds, and a lazily-built `_SpatialGrid` (100×100 cells) for `nearestNode(point, maxDistanceM)` (expanding-ring search with an early-exit heuristic) and `nodesWithinRadius`.
4. **A\*** (`Pathfinder.findPathBetweenNodes`): standard open/closed sets, admissible straight-line (haversine) heuristic, a `costModifier` hook, `maxIterations = 100000` safety cap. The open set is a `_PriorityQueue` backed by a **sorted `List`** with binary-search insert and `removeAt(0)` pop.
5. **DeviationPathfinder**: `findDeviationPath` picks a perpendicular target and penalizes near-route nodes; `findReturnPath` targets the nearest route point; `findContinuedDeviationPath` extends the escape in the same heading.

#### Flow 4 — EKF replay panel (validates the real alarm engine against ground truth)

1. `EkfTestPanel` owns an `EkfTestController` (from the EKF subsystem). Four curated routes: Purple/Green metro lines, a non-metro auto/cab route, and **Log Replay** (a real recorded Sandal-Soap→Whitefield ride at `docs/Sandalsoap-whitefield/unified_route_log.json`, fusing GPS+IMU+ground truth).
2. For non-log routes the user picks a **GPS-dropout scenario** (normal / tunnel / intermittent / complete). For Log Replay, dropout is baked into the log.
3. On Start, the panel wires `EkfTestController.accelerometerStream`/`gyroscopeStream` into `TrackingService.testAccelerometerStream`/`testGyroscopeStream` (the `@visibleForTesting` injection hooks) and plays the recording.
4. Each `EkfTestVisualization` tick updates live metrics: EKF speed, EKF distance, σ_pos / σ_vel (covariance), GPS active/dropout, EKF normal/degraded, ground-truth error-now / max-drift / RMSE / blackout-max, and current/next station. When the real `AlarmEvaluator` fires, an `EkfAlarmResult` renders a banner with fire time, lead seconds, and **lead error** ("Xm ahead/behind truth (fired early/late)") — the direct never-late scorecard.
5. The panel *also* calls `onInjectGps` → `_broadcastEkfTestPosition` (`ekf_test_position` over the WebSocket). **This message has no consumer on the device** (see Gaps): the EKF replay validation happens entirely inside the dashboard against the *replayed* orchestrator, not against a live phone.

#### Flow 5 — Orphaned on-device debug tools (present but unwired)

- `SimulationEngine` (`lib/simulation_engine.dart`): a simpler route-walker (1.4 m/s base, optional positional noise). Referenced **nowhere**.
- `DemoRouteSimulator` (`lib/debug/demo_tools.dart`): would register a demo route and inject 60 positions over ~18 s into the background service, firing a real distance alarm. It sets `NotificationService.isTestMode = false` and `TrackingService.isTestMode = false` (real alarms). Called only by `DevServer`.
- `DevServer` (`lib/debug/dev_server.dart`): debug-only, loopback-bound HTTP server (`/demo/journey`, `/demo/transfer`, `/demo/destination`). Nothing calls `DevServer.start()`, so the whole demo path is dormant.

---

### Key types & functions

- **`DeviationSimulationController`** (`deviation_simulation_controller.dart`) — the virtual rider. `loadRoute`, `start/stop/pause/resume`, `startDeviation/goBackToRoute/stopDeviation`, `seek(t)`, `positionStream`, `progressOnOriginalRoute`. Owns the 33 ms tick loop and the FSM. Speed setter clamps 0.3–44.4 m/s. `setWarpFactor` delegates to `AppClock`.
- **`SimulationStateMachine`** (`simulation_state.dart`) — `enum SimulationState{idle,onRoute,deviating,returning,paused}` + `_isValidTransition` table; throws `StateError` on illegal transitions. Exposes `isActive/isOnRoute/isDeviating/isReturning/isPaused` and a `stateStream`.
- **`AppClock`** (`core/clock/app_clock.dart`) — singleton. `now()`, `setWarpFactor(1.0–500.0)` (throws outside), `enableSimulation/disableSimulation`, `createPeriodicTimer/createTimer`, `reset()/install()` for tests. Formula: `virtual = startVirtual + realElapsed×warp`.
- **`ConstraintLogger` / `ConstraintEvent`** (`constraint_logger.dart`) — singleton event bus + typed factories (`deviationDetected`, `rerouteTriggered/Success/Failed/Skipped`, `terminationCheck`, `warpFactorChange`, `info`…). `log`, `events`, `eventStream`, `clear`, `resetForTesting`.
- **`SimulationClient`** (`services/simulation_client.dart`) — on-device WebSocket. `connect/disconnect`, `positionStream`, `broadcastRoute/broadcastState/broadcastPosition`, callbacks `onFirstPositionReceived/onDisconnected/onAlarmReset/onSwitchRoute`. Reconnect backoff, 90 s ping-timeout, speed clamp 0–60 m/s.
- **`OsmGraph` / `OsmLoader` / `Pathfinder` / `DeviationPathfinder`** — road graph, `.wkp` parser (`loadAsset`, `loadAssetWindowed`, `loadBytes`, `createTestGraph`), and A\*/deviation search. `PathResult{path, nodes, totalDistanceM, nodesExplored, found}`.
- **`EkfTestPanel`** — `StatefulWidget` with callbacks `onInjectGps`, `onRouteChanged`, `onVisualizationUpdate`, and `externalWarpFactor`. Curated-route enum → `TestRouteId`.
- **UI leaves** — `SimulationControls`, `SpeedSlider` (`kmhToMps`/`mpsToKmh`), `TimeWarpSlider`, `ConstraintDrawer` (+`LogExportFormat`), `OsmOverlayManager`, `AlarmDebouncer` (`update(serverFired, now)` rising-edge/hold).

---

### Design decisions (the WHY)

1. **The dashboard is a separate Chrome web app, not an in-app screen.** *Why:* keeping a heavyweight Google-Maps testing console (deviation pathfinding, OSM overlays, warp sliders, log export) out of the shipped app avoids bloating the APK and lets a developer watch the *real phone* on a big screen while driving it remotely. *Trade-off / flaw:* it hard-imports `dart:html` (`unified_dashboard`, `deviation_dashboard`, `ekf_test_panel`), so the tooling is **locked to web** — it cannot run on desktop/mobile, and those three files won't even compile for a non-web target. The whole subsystem is therefore invisible to `flutter analyze` on mobile builds.

2. **`AppClock` abstraction over `DateTime.now()`.** *Why:* to compress a 45-minute ride into ~30 s at 100× so cooldowns, deviation timers, and termination policy can be watched quickly, *and* so tests can install a fake clock. *Trade-off:* every piece of production time logic must route through `AppClock` or it silently ignores warp. *Flaw:* the slider caps warp at 200× while `AppClock` allows 500× and throws outside 1–500 — an inconsistent, undocumented ceiling. At very high warp the 33 ms real tick advances the rider by huge spatial jumps, which can skip past narrow geofences.

3. **Prefer dashboard-provided `virtualTime` + `speedMps` on the wire instead of deriving them on the device.** *Why:* under time-warp the *rate* of position messages changes wildly; deriving speed from `Δd/Δt` or stamping `DateTime.now()` makes the app infer 100× speed and collapse ETA to ~0 — the app would fire absurdly early. Sending explicit fields fixes it. *Trade-off / flaw:* this is a **fragile hidden contract** across three programs (dashboard, relay, device). `_broadcastSimulationPosition` sends *both* a real `timestamp` and a `virtualTime` and a `speedMps`; if any field is dropped or the two sides drift, ETA silently corrupts and **the tool can show plausible-but-wrong numbers** — the worst outcome for a validation tool. There is no assertion that the injected speed matches the spatial delta.

4. **Lazy 3 km windowed OSM load, not the full graph.** *Why:* the Bengaluru `.wkp` is 20 MB; parsing it whole would freeze the web page. Loading only a 3 km window around the rider keeps pathfinding responsive and caches the window until the rider leaves it. *Trade-off:* the first "Start Deviation" incurs a load stall; a rider who deviates >3 km triggers a reload. *Flaw:* the OSM graph is **Bengaluru-only** — deviation simulation is meaningless anywhere else, so this validation path does not cover the "India-wide" breadth the promise implies.

5. **A\* open set is a sorted-`List` priority queue.** *Why:* trivially correct and adequate for the small windowed graphs. *Trade-off / flaw:* `add` is O(log n) search but O(n) insert, and `removeFirst` is O(n) `removeAt(0)`; on a dense window this is effectively O(n²), guarded only by the `maxIterations = 100000` cap. Also `totalDistanceM` in `PathResult` is taken from `gScore`, which **includes the route-avoidance penalty**, so the reported deviation distance is inflated, not true meters. `_reconstructPath` contains a dead `nodes.reversed;` statement (a no-op; the value is discarded).

6. **Simulation tick uses real wall-clock `dt`, not a fixed step.** *Why:* it produces smooth on-screen motion regardless of frame jitter. *Trade-off / flaw:* the dashboard simulation is **not deterministic** — two runs of the same route yield different position streams because they depend on timer jitter × warp. That is fine for a demo but means the dashboard is *not* the reproducible-validation path. Reproducibility lives only in the offline replay harness (Flow 4 / `test/ekf/replay_harness_test.dart`).

7. **The relay is a dumb, auth-less broadcast hub on `0.0.0.0:8081`.** *Why:* the simplest thing that connects a browser to a phone on the same LAN. *Trade-off / flaw:* binding to all interfaces with no auth means anyone on the network can inject `simulation_control`/`simulation_update` into a connected debug device. Low real-world risk (dev-only, needs an active debug build), but it is a foot-gun on shared Wi-Fi. `DevServer`, by contrast, correctly binds loopback-only and is `kDebugMode`-gated — a good pattern the relay does not follow.

8. **Bridge disabled by default in release; opt-in via dart-define.** *Why:* a release build must never stall startup trying to reach a localhost relay, and must never accept spoofed positions. `PlaygroundBridgeConfig.enabled` returns false in tests and defaults off in release. *Flaw:* if someone ships with `--dart-define=PLAYGROUND_BRIDGE_ENABLED=true`, a *release* device would connect to `ws://127.0.0.1:8081` and accept injected GPS — a position-spoofing path. It is opt-in and localhost-only, so risk is low, but the safety rests on a build flag, not a hard release guard.

9. **`SimulationClient` guards the WebSocket `ready` Future and all `sink.close()` calls with `unawaited(...catchError)`.** *Why:* an unhandled async error from the socket can crash the Dart isolate — and on the background isolate that would **stop all alarms**. This is defensive code directly protecting the core promise. *Good decision, no flaw.* It is the single most safety-relevant line in the subsystem.

10. **Constraint events timestamped in virtual time and capped at 200.** *Why:* the log should read in the same (warped) time domain the user is watching, and an unbounded list would leak memory over a long session. *Trade-off:* older events scroll off; there is no persistence, so a crash loses the log unless the user exported JSON/CSV first.

11. **EKF replay drives the *real* orchestrator + real `AlarmEvaluator` and scores lead-error against station-anchor truth.** *Why:* this is the only honest way to test "never late" — replay a real underground ride and check the real fire decision. *Trade-off / flaw:* the fixtures for the replay *harness test* live **outside the repo** (`/home/raed/geowake_imu_analysis/fixtures`), and the panel's Log Replay reads a 39 MB+ raw-CSV directory under `docs/`. So the highest-value validation is **non-portable**: it will not run in CI or on any machine but the founder's. `ekf_test_helpers.dart` is explicitly labeled "placeholder scaffolding," and `test/fixtures/imu_data/` contains only a README — the promised deterministic IMU generators were never built.

12. **Hand-rolled Taylor-series trig in `deviation_dashboard.dart`** (`_sinImpl`, `_sqrtImpl`, `_atan2Impl`) "for web compatibility." *Why:* an apparent (mistaken) belief that `dart:math` is unavailable on web. *Flaw:* `dart:math` works fine on web; these approximations are slower and less accurate, and the whole file is an orphaned earlier dashboard variant that duplicates `unified_dashboard` logic. It should be deleted, not maintained.

13. **`DemoRouteSimulator` flips test-mode off to fire real alarms.** *Why:* the demo's purpose was a live, buzzing end-to-end walkthrough. *Flaw:* it is orphaned but still compiled; if anyone re-wires `DevServer`, hitting `/demo/journey` would fire real wake-up alarms and notifications on the device — a surprising side effect for a "demo" endpoint. Dead code with a live detonator.

---

### Invariants

- **The alarm path never depends on this subsystem in release.** Only `SimulationClient` is on-device, and only when `PlaygroundBridgeConfig.enabled` (off by default in release; always off under `flutter test`).
- **In simulation mode, real GPS is ignored** (`LocationManager._onRealPosition` early-returns) so the two sources never fight; on disconnect, real GPS resumes.
- **Entering simulation mode resets alarm state** (`onFirstPositionReceived` → `onAlarmReset`) so prior `firedLegIds` cannot suppress a fresh alarm.
- **`SimulationStateMachine` only permits legal transitions**; any illegal transition throws rather than silently corrupting state. `idle` and "stop" are always reachable.
- **FSM `startDeviation` requires state `onRoute` + a loaded graph + a current position**; otherwise it logs a failure event and no-ops (never crashes).
- **Warp changes preserve virtual-time continuity** (`AppClock` rebases start points) and every event carries an `AppClock().now()` timestamp.
- **`.wkp` parsing validates magic, version, and file size** before reading; a truncated/foreign file throws `OsmLoadException` rather than reading garbage.
- **A\* is bounded** by `maxIterations = 100000` and always returns `null` (never hangs) when no path exists.
- **Injected simulated positions carry `speedMps` and `virtualTime`** so the device does not derive warp-inflated speed.

---

### Interfaces

**Consumes from other subsystems:**
- **Clock:** `core/clock/app_clock.dart` (`AppClock`) — the shared time source for warp.
- **EKF subsystem:** `core/ekf/ekf_test_controller.dart` (`EkfTestController`, `EkfTestVisualization`, `EkfAlarmResult`, log types) and `core/ekf/imu_replay_engine_v2.dart` (`TestRouteId`, `GpsDropoutMode`). `EkfTestPanel` is a thin UI over these.
- **Tracking/Location:** `services/trackingservice.dart` — `isTestMode`, `setSimulationMode`, and the `@visibleForTesting` `testAccelerometerStream`/`testGyroscopeStream`/`testGpsStream` injection hooks; `registerRoute`, `startTracking` (used by the orphaned demo). `services/location_manager.dart` owns the on-device `SimulationClient` and consumes its `positionStream`.
- **Routing/Map:** `services/direction_service.dart` (`buildSegmentedPolylinesFromRawSegments` for colored route rendering); `all_india_stops.dart` (metro-stop overlay); the real `AlarmEvaluator` (scored inside EKF replay).
- **Config:** `config/playground_bridge.dart` (flag + relay URL); assets `assets/osm/bengaluru.wkp`, `docs/Sandalsoap-whitefield/unified_route_log.json`.

**Exposes to other subsystems / external actors:**
- **On the wire (via relay):** to the device — `simulation_update`, `reset_alarm_state`, `switch_route`; from the device — `route_update`, `app_state`, `device_position`. A third-party controller may send `simulation_control` to remote-drive the dashboard.
- **`ConstraintLogger.instance`** — a global event bus any subsystem could log into (currently only dashboard/controller write to it).
- **`SimulationClient`** — the injection surface `LocationManager` uses to override real GPS.

---

### Gaps & flaws vs the core promise

Brutally honest, roughly worst-first:

1. **The 20 MB Bengaluru OSM graph ships in the APK.** `pubspec.yaml` bundles `assets/osm/` (line 91) and `assets/osm/bengaluru.wkp` is 20 MB — yet the graph is used **only** by the testing dashboard's deviation pathfinder, which cannot even run on the phone (web-only). This is dead weight in the download that directly harms the "cheap Android phone in India" promise (data cost, install size, low-end storage). This is almost certainly the biggest concrete regression in this subsystem and should be excluded from release bundles.
2. **The EKF replay panel's on-device injection is a dead path.** The panel emits `ekf_test_position`, but **no device code handles it** (`SimulationClient` only handles `simulation_update`/`reset_alarm_state`/`switch_route`/`ping`). So the panel's "inject GPS into the real phone" wiring is a no-op; EKF replay validates only the in-dashboard replayed orchestrator. Anyone reading the code could wrongly believe the replay is exercising a live device.
3. **The highest-value validation is non-reproducible.** The never-late replay harness reads fixtures from `/home/raed/geowake_imu_analysis/fixtures` (outside the repo) and the panel reads a 39 MB+ CSV under `docs/`. Neither runs in CI or on another developer's machine. The proof that "we never fire late on a real underground ride" is therefore not portable, not gated, and not re-runnable by a new maintainer.
4. **The bridge is a fragile, unverified numeric contract.** ETA correctness depends on the dashboard and device agreeing on `virtualTime` + `speedMps` semantics with no cross-check. A silent field mismatch makes the tool *display green while feeding the real ETA engine distorted speed* — exactly the failure a validation tool must not have. There is no assertion that injected speed ≈ spatial delta.
5. **Dashboard simulation is non-deterministic** (wall-clock `dt` × warp), so it cannot be used for regression-grade reproducibility; it is a demo, not a proof. Reproducibility exists only in the offline harness, which (per #3) is non-portable.
6. **Significant dead/orphaned code with live hazards.** `SimulationEngine` (unreferenced), `deviation_dashboard.dart` (superseded variant with unnecessary Taylor-series trig), `DevServer` + `DemoRouteSimulator` (dormant but would fire *real* alarms if re-wired, because they force `isTestMode=false`), and `AlarmDebouncer` (only referenced by a test). This is maintenance drag and a resurrection risk directly adjacent to the alarm path.
7. **`SimulationEngine` also has a correctness bug** (even though unused): in `update()`, when a segment completes it snaps `currentPosition` to the vertex and *discards the overflow distance* (the code comment admits "simple version: just clamp"), so the rider under-integrates distance at every vertex and moves slightly slower than the requested speed; noise is applied only on the interpolate branch, not the vertex-snap branch. If it is ever resurrected as a "simple" simulator, it will misreport speed/ETA.
8. **Coverage is Bengaluru-shaped.** Deviation pathfinding, the demo route, and the OSM overlay are all Bengaluru; the replay ride is one Whitefield corridor. The promise is India-wide and underground-heavy, but the *simulation* breadth (as opposed to the unit tests) is narrow — many Indian metro/rail geometries, GPS-canyon patterns, and cheap-sensor IMU profiles are unexercised in the interactive tooling.
9. **Release safety rests on a build flag.** If `PLAYGROUND_BRIDGE_ENABLED` is ever set for a release build, that device will accept injected positions from `ws://127.0.0.1:8081`. Localhost + opt-in keeps risk low, but there is no hard "never in release" guard.
10. **Test-directory hygiene.** Of 162 files, 17 are non-`_test` scratch/manual scripts (`alarm_repro.dart`, `compare_routes.dart`, `debug_*`, `reproduce_*`, `tool_fetch_route.dart`, …) that `flutter test` does not run. They inflate the apparent test count and blur the line between "automated gates" and "one-off debugging scripts." The IMU-fixture scaffolding (`test/helpers/ekf_test_helpers.dart`, `test/fixtures/imu_data/`) is a stub with a TODO, so some intended deterministic sensor tests do not exist.

**Net:** the *automated unit/integration suite* (145 `_test.dart` files spanning EKF, clock, dashboard, alarm logic, metro/stops, routing/reroute, reachability, reliability/preflight, monetization, iOS backstop, telemetry, notifications, lifecycle, ETA) is broad and is the real safety net. The *interactive simulation tooling* is a useful demo and integration harness but is web-only, Bengaluru-only, non-deterministic, partly dead-wired (EKF injection), and — via the bundled 20 MB graph — actively costs the very users the promise is about. The lab is good at breadth-of-logic and weak at portable, reproducible, India-wide field-condition proof.
