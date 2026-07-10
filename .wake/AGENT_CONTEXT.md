Wrote `/home/raed/Projects/WakePoint/.wake/AGENT_CONTEXT.md`. Content:

# WakePoint — AGENT_CONTEXT (READ THIS FIRST)

> Orientation packet for the next agent. Read this, not the tree. Query with the RAG index + symbol graph (§5) before opening files. Generated against git `bf09030` (branch `stable-release-1`).

## 1. What is WakePoint
A metro/transit **wake-up alarm** for India (Flutter package `geowake2` + a thin Node/Express backend `geowake-server`). The user picks a destination and an alarm rule (**distance / time / stops**, optionally metro mode); the app tracks GPS in a background isolate, snaps position to the route, computes ETA/progress, and **fires a full-screen alarm** at the right leg/station — surviving app-swipe, backgrounding, and process death. **North star: the alarm fires at the correct station every time, even with no GPS** (tunnels, deep metro) — which is why the route-constrained EKF dead-reckoning subsystem exists.

## 2. Entry points
- **App:** `lib/main.dart` → `main()` → Hive init → `runApp(MyApp)`. Routes via `onGenerateRoute`: `/splash`→`/`(home)→`/preloadMap`→`/mapTracking`. Heavy service init is deferred to SplashScreen, NOT main.
- **Background isolate:** `lib/services/trackingservice.dart` module-level `_onStart(ServiceInstance)` (Android onStart / iOS onForeground); `startLocationStream()` begins the GPS loop.
- **Backend:** `geowake-server/src/server.js` → mounts `/api/auth` (open) + `/api/maps` (JWT-gated), `app.listen`. Canonical entry list: `.wake/map/entry-points.json`.
- **Dev/QA dashboards (web-only):** `lib/main_unified_dashboard.dart` (`flutter run -d chrome -t lib/main_unified_dashboard.dart`).

## 3. Subsystem / feature map (feature → key dirs → purpose)
| Feature | Key dirs/files | Purpose |
|---|---|---|
| Bootstrap + shared primitives | `lib/main.dart`, `lib/core/clock/app_clock.dart`, `lib/models/route_models.dart`, `lib/all_india_stops.dart` (generated, 875 stops), `lib/metro_color_map.dart`, `lib/themes/` | App boot, route table, `AppClock` (real vs warped virtual time), shared value types + static datasets. |
| Live tracking runtime | `lib/services/trackingservice.dart` + `lib/services/tracking/*` (barrel `tracking.dart`) | Background GPS loop → ETA/progress → alarm check; cross-isolate bridge, persistence, notifications. **#1 load-bearing file.** |
| Alarm engine | `lib/services/alarm_evaluator.dart` (WHEN to fire), `lib/services/tracking/alarm_controller.dart` (orchestrator + dedup), `lib/services/notification_service.dart` (present/deliver), `lib/services/stop_logic_engine.dart` (pre-trip validation only) | Geometric per-leg fire decision + cross-isolate notification actions. |
| Routing | `lib/services/route_session_manager.dart` (orchestrator, owned by TrackingService), `lib/services/transfer_utils.dart`, `lib/services/direction_service.dart`, `lib/services/active_route_manager.dart`, `eta_utils.dart`, `polyline_simplifier.dart`, `route_cache.dart`, `route_registry.dart`, `snap_to_route.dart` | Directions JSON → canonical route model (leg stops, transfer/mode-change boundaries, step ETA), live "which route am I on" + auto-switch. |
| EKF sensor fusion | `lib/core/ekf/*` (orchestrator, pipeline, route_geometry, tilt_filter, motion_classifier, zupt_detector, gps_degradation_detector, station_association, degraded_mode) + `lib/services/sensor_fusion.dart` bridge | 1-D route-arclength EKF `[s,v,bias]` for dead-reckoning + station-snap when GPS degrades. |
| Platform/edge services | `lib/services/api_client.dart` (sole HTTP gateway), `places_service.dart`, `metro_stop_service.dart`, `permission_service.dart`, `simulation_client.dart`, `location_manager.dart`, `lib/services/testing/*` (OSM graph + A* pathfinder, dashboards-only) | Network, OS, sensors, simulation feed. |
| UI screens | `lib/screens/*` (splash, homescreen, maptracking, settingsdrawer, ringtones, preload) | Presentation + wiring only; no domain logic. |
| Dev dashboards (web-only, `dart:html`) | `lib/dashboard/*` (`unified_dashboard`, `deviation_simulation_controller`, `constraint_logger`, `ekf_test_panel`) | GPS/deviation simulation, time-warp, EKF replay. **NOT shipped**, but `constraint_logger.dart` is imported by production reroute/deviation code. |
| Config / tuning | `lib/config/*` (`deviation_config`, `power_policy`, `playground_bridge`, `app_config`) | Static consts + feature flags (leaf unit). |
| Backend | `geowake-server/src/*` (config, controllers, middleware, routes, utils/cache) | Stateless proxy keeping the Google Maps key server-side; mints device JWTs, caches, rate-limits. |
| Tests | `test/`, `integration_test/`, `test_driver/` (138 files) | **No mock frameworks** — real objects driven through static test seams. |

## 4. Load-bearing hub files (from change-impact — touch with care)
- **`lib/services/transfer_utils.dart`** — **#1 fan-in (~49 importers), riskLevel critical.** 1516-line pure-static toolbox: `TransitLegStops` + `RouteEventBoundary` models and all directions-JSON→stops/legs/events/boundaries geometry. Its output *gates alarm trigger points*; `toJson/fromJson` is a persistence contract used by snapshots + dozens of tests. A subtle geometry change silently moves where alarms fire. Signature changes ripple everywhere.
- **`lib/services/trackingservice.dart`** — **fan-in 43, the single most load-bearing file.** ~2582-line singleton facade spanning foreground + background isolates. Note `_onStart/startLocationStream/_onStop/_handleReroute*` are **module-level functions, not methods**, mutating top-level globals. Handler state is source of truth; globals are a mirror kept coherent only by `syncGlobalsFromHandler()`.
- **`lib/core/ekf/ekf_types.dart`** — **fan-in 25, critical shared model.** `EkfPublicState`, `ImuSample`, `GpsFix`, `StationSnapConfirmed`, `EkfConfig`, enums `EkfMode`/`MotionState`. The data contract crossing from `core/ekf/` into `services/`. Its `MotionState{human,vehicle,stationary}` is EKF-internal — do not confuse with app-level transit-mode enums.
- Runners-up worth knowing: `notification_service.dart` (fan-in 34), `api_client.dart` (14), `app_clock.dart` (12 — warp semantics ripple into ETA/alarm/termination timing), `alarm_evaluator.dart` (13), `route_geometry.dart` (15).

## 5. HOW TO QUERY without burning tokens
Prefer these over grepping or reading the tree. All artifacts live under `.wake/` (manifest: `.wake/MANIFEST.json`).

**(a) RAG lexical index → file:line spans.** BM25 over `.wake/rag/codebase-index.json` (~10 MB, prebuilt).
```js
import { CodebaseRAG } from '/home/raed/.agentic-os/scripts/codebase-rag.mjs';
const rag = new CodebaseRAG('/home/raed/Projects/WakePoint');
const hits = await rag.search('station snap confidence gate', { limit: 8 });
// each hit: { relativePath, lines:"start-end", lineStart, lineEnd, symbol, symbolType, score, snippet }
```
Filters: `{ filters: { fileType:'.dart', pathIncludes:'lib/core/ekf', symbolType:'class' } }`. The index is prebuilt — don't re-index. Also `tools/wakepoint-rag.mjs` wraps this as a CLI.

**(b) Symbol graph → callers/callees.** `.wake/graph/dart-symbol-graph.json` (SCIP-derived). Shape:
- `definitions[]` = `{ symbol, file }` (12283 defs) — where a symbol is defined.
- `referenceEdges[]` = `{ fromFile, toFile, symbol }` (4980 edges) — `fromFile` references `symbol` defined in `toFile`. **Callers of X** = edges where `symbol` is X's def; **callees/deps of a file** = edges where `fromFile` is that file. `fileDependencies` gives file→file import edges.
```bash
node -e "const g=require('./.wake/graph/dart-symbol-graph.json'); \
  console.log(g.referenceEdges.filter(e=>e.symbol.includes('evaluateCoinciding')).map(e=>e.fromFile))"
```
Backend equivalent: `.wake/graph/backend-call-graph.json`. Raw SCIP: `.wake/graph/scip-dart.scip`.

**(c) Other prebuilt maps** (`.wake/map/`): `change-impact.json` (fan-in/risk), `knowledge-graph.json`, `module-interfaces.jsonl`, `public-api-surface.json`, `type-signatures.jsonl`, `entry-points.json`, `LLM_NAVIGATION_GUIDE.md`. Intent graph: `.wake/intent/intent-graph.json`.

## 6. Key invariants & gotchas (aggregated)
**Cross-cutting**
- **`transfer_utils` meters are cumulative-from-route-start**; `TransitLegStops.stopMeters/stopPositions` length == `numStops` and must be ascending. `legId` must stay stable across reroutes (drives one-alarm-per-leg dedup). Any new field goes in 3 places (fields, `toJson`, `fromJson`).
- **Route identity is `RouteCache.makeKey(origin,dest,mode,transitVariant[,departureTime])`** everywhere. Gotcha: `RouteSessionManager` builds the key with `transitVariant='rail'` for transit, so the session key can differ from DirectionService's cache key.
- **`AppClock` is a process-wide singleton;** once `enableSimulation()` is on, `now()` is virtual time (even at warp 1.0). Tests MUST `AppClock.reset()` in teardown.
- **`isTestMode` is process-global static state** on TrackingService / NotificationService / LocationManager / ApiClient — three flags must agree; leaks across tests without teardown. `isTestMode` bypasses alarm cooldown → alarm tests assert bounded (`<=`) counts, and short-circuits the isolate hop.

**Alarm**
- **One-alarm-per-leg:** `AlarmEvaluator.evaluateCoinciding` returns null if `firedLegIds` contains the leg; the **caller (AlarmController) must add `trigger.legId` after firing** — the evaluator never mutates the set. Firing is **purely geometric** (progress vs bounds); `allEvents` only enrich message text.
- AlarmController keeps **two dedup layers** (`_firedLegIds` legacy + `_firedLegIdsByKey`); wrong set → dup/missing alarms. On any route switch, `migrateAlarmState(from,to)` MUST run before emitting the switch (in both listener paths) or fired alarms re-fire.
- preBoarding uses **synthetic legIds**; "60% rule" naming is inverted — fires at **40% progress / 60% remaining**.
- Notification IDs fixed (alarm=0, progress=888, paused=889); alarm channel `geowake_alarm_channel_v4` is **deliberately silent** (AlarmPlayer + Vibration own sound/haptics). `notificationTapBackground` must stay `@pragma('vm:entry-point')`; cross-isolate actions persist via file flag + SharedPreferences backup.

**EKF**
- Filter is **1-D arc-length `s` (meters), NOT lat/lng.** A route MUST be set or the whole EKF is disabled (`enableEkf = geometry != null`). GPS enters via `RouteGeometry.projectLatLng` (returns **NaN when lateral error > max**, 75m surface/50m transit → fix silently dropped, looks like a stuck filter).
- `publicState.s` is **monotonic non-decreasing** in surface/metro; only degraded mode exposes raw `_s`. Pipeline is **uninitialized until first GPS fix**. `onStationCandidates` updates only for **exactly one** candidate. `sigmaS` clamped to **200m ceiling**. Station snap only through the **§24.2 gate** (σ≤30m, ≤60m degraded, station index strictly increasing).
- Degraded covariance inflation is `1.0002`/tick — do not change it or the 200m clamp casually (old 1.02/10km values broke snaps).

**Tracking / routing**
- Sequential alarm guard: `LocationStreamHandler._isCheckingAlarm` — evaluation must be re-entrancy-safe. `ActiveRouteManager.ingestPosition` is called **twice per update** (direct + inside `_trackMovement` with final flag).
- Time-alarm eligibility: `distanceTravelled>=100m AND etaSamples>=3 AND >=30s since start`.
- Snapshot persistence throttled 30s, dashboard broadcast 1s; `saveSnapshot` must not overwrite existing directions with null. `_transitLegStopsKey` is version-bumped (v5); old keys silently ignored. `TrackingStateStore` caches prefs statically — tests call `resetCacheForTests()`; `*Sync` getters may be stale (non-sync call `prefs.reload()`).
- `ActiveRouteManager` uses **monotonic Stopwatch** (not DateTime) for sustain/blackout; `_headingAgreement` is a stub (~0.5).

**Backend**
- `config.js` `process.exit(1)` at require time if `GOOGLE_MAPS_API_KEY` unset or `JWT_SECRET < 32` chars (fires for Jest too). **bundleId is the sole identity** — must match at mint + verify. **3 different bundle IDs across the repo**: `com.geowake.app` (client + config default) vs `com.yourcompany.geowake2` (auth test expects via `APP_BUNDLE_ID` env). Successful proxy responses are Google's **raw JSON** (no `{success:true}` wrapper); only errors are wrapped. CORS defaults to `*` — JWT+bundleId is the only gate. `cacheTimeouts` missing keys for `place-details`/`nearby-search` → silent 300s default.

**Known dead/orphan code (don't wire new work to these):** `lib/simulation_engine.dart`, `lib/config/test_mode_flag.dart`, `lib/services/test_service_instance.dart` (TrackingService has its own inline one), the `position/` provider abstraction, `SensorFusionManager.fusedPositionStream`, `GpsHealthMonitor` (no prod consumer), `test/helpers/ekf_test_helpers.dart` (0 importers). Two replay engines: `imu_replay_engine_v2.dart` (v2 — target this) vs `imu_replay_engine.dart` (v1, dashboard only). `AppConfig` is documentation-only (values duplicated in `api_client`). The EKF orchestrator header comment "not yet integrated" is **STALE** — it is live-wired.

## 7. Regenerate / verify the map
- **Regenerate the full map:** `node tools/wakepoint-indexer.mjs` (defaults to repo root). Sub-generators: `wakepoint-decode-scip.mjs`, `wakepoint-build-intent-graph.mjs`, `wakepoint-rag.mjs`, `wake-manifest.mjs`.
- **Verify (CI/hook gate):** `node tools/wake-manifest.mjs --check` — recomputes deterministic layers and asserts byte-equality against `.wake/MANIFEST.json`; **exit 1 on drift**. Run without `--check` to rewrite the manifest.
- After any `lib/` change that shifts symbols/imports, regenerate so the RAG index and symbol graph stay honest (the checked-in artifacts pin to git `bf09030`).
