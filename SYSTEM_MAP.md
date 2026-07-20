# GeoWake — Master System Map

_Chief-engineer end-to-end map. Atomic detail lives in `docs/system_map/01..18_*.md`; this document is the index, the data-flow, the call graph, and the load-bearing invariants. App name is **GeoWake** (never "geowake2"/"WakePoint" in user-facing strings). Flutter, Android-first, India-first. Branch `sim-validation`; main `stable-release-1`._

> **Regenerated 2026-07-20 @ commit `8b9295a`** (from a map last written 2026-07-15). The subsystem docs `docs/system_map/*.md` are still 2026-07-15 vintage; the ones whose code materially changed carry a **STALE — needs regen** banner (§0 below lists them). See **§0 Delta since 2026-07-15** for exactly what moved.

---

## 0. Delta since 2026-07-15 (what changed under this map)

Two commits landed after the 2026-07-15 subsystem docs were written: `9947358` (*checkpoint(testing): multi-session never-late hardening + full E2E coverage audit*) and `8b9295a` (*feat(testing §7): close build mandates — loadFromPolyline, harness_runner, Semantics, driver gate*), the current HEAD. The changes are concentrated in the **never-late engine** and a **new §7 headless harness surface**. Nothing below altered the arm→track→alarm spine's shape — every change either tightens the physics bound (monotone-safe, can only fire *earlier*) or adds a validation-only driver.

### Never-late engine additions (`9947358`)

| Change | Where | What it does | Never-late argument |
| --- | --- | --- | --- |
| **Vehicle-type V_LINE floor** (GW-0076) | `reachability.dart` `VLineTable._vehicleCeiling` + `forLine(vehicleType:)`; threaded from `ReachabilityTracker.boundNow(vehicleType:)` and wired in production at `alarm_controller.dart:361/518/1038/1523/1528` | Closes the "fast line reported with a slow/generic name" hole. Google Directions `transit_details.line.vehicle.type` (name-free) lifts the ceiling: `HEAVY_RAIL`/`RAIL`/`COMMUTER_TRAIN` → RRTS ceiling (53 m/s), `HIGH_SPEED_TRAIN`/`LONG_DISTANCE_TRAIN` → 56 m/s. A genuine `SUBWAY`/`METRO_RAIL` gets **no** lift (Nagpur's "Orange Line" 90 km/h metro stays at 28 m/s). | `forLine` returns `max(keyword-tier, vehicle-floor)`. Both are over-bound claims on true max speed, so taking the larger only raises the ceiling → fires earlier. Residual fast-`SUBWAY`-with-generic-name (Airport Express as literal `SUBWAY`) still needs a `(city,line)` override pin. |
| **Piecewise multi-leg V_LINE** | `reachability.dart` `VLineSegment` + `Reachability._piecewiseFreeRun`; `bound(vLineSegments:)`; production builds the segment list at `alarm_controller.dart:1518-1556` | Replaces the old flat-`max(V_LINE over forward legs)` free-run with a per-leg piecewise march. A slow metro leg feeding a fast RRTS leg no longer inflates the current leg's blackout bound to the RRTS ceiling (which fired ~2× early). | Each segment's `vLineMps` still over-bounds *that arc span's* true speed, and the rider must traverse the slower arc before reaching the faster leg, so `P(t) ≥ S(t)` holds at every arc position and the result is `≤` the flat-max free-run (strictly tighter, never looser). |
| **Physics process-death backstop** (GW-0080 / "P0-00") | `alarm_controller.dart` `backstopPhysicsFireInSeconds(...)` + `_refreshBackstopPhysicsFireAt` + `backstopPhysicsFireAt` getter → threaded via `BroadcastContext.backstopPhysicsFireAt` into `notification_updater.dart` `_maybeRearmEtaBackstop` | The OS exact-alarm backstop (id 991) is now armed at **min(ETA-derived fire, physics free-run reach instant)**, not ETA alone. If the process dies mid-blackout, the pre-scheduled `setAlarmClock` still fires on the physics never-late instant. | The physics instant is the free-run `s_max`-reaches-target time from the current anchor + V_LINE — an early-biased upper bound, so `min(eta, physics)` can only move the backstop *earlier*. |

### §7 headless harness surface (`8b9295a`)

| Change | Where | Role |
| --- | --- | --- |
| **`ImuReplayEngineV2.loadFromPolyline`** | `lib/core/ekf/imu_replay_engine_v2.dart:758` (now 2888 lines) | Synthesizes a full EKF/IMU/GPS timeline from an *arbitrary* polyline (not just canned Bengaluru routes), with `stops` → ZUPT dwell points and `blackoutWindows` → tunnel/no-signal stretches. |
| **`GpsBlackoutWindow`** | `imu_replay_engine_v2.dart:108` | `[startSeconds, endSeconds)` simulation-time window that suppresses the synthesized GPS fix (models a tunnel) independent of `GpsDropoutMode`. |
| **`EkfTestController.loadRouteFromPolyline`** | `lib/core/ekf/ekf_test_controller.dart:554` (now 1575 lines) | Drives the same real EKF + AlarmEvaluator + reachability pipeline as `loadRoute`, but from any polyline via `loadFromPolyline`, so arbitrary recorded trips exercise the never-late engine. |
| **`lib/testing/harness_runner.dart`** (763 lines, **NEW**) | charter §7.3 | Pure `runScenario(spec) → metrics` + `sweep([...])` + a CLI `main`. Maps a JSON scenario spec → `EkfTestController` → JSON metrics (reachability cone fire, EKF alarm fire, EKF drift) + a tolerance verdict; **exit 1** on any late-fire/never-fire/tolerance breach so CI can gate. No `system_map/*.md` doc exists for this file yet. |
| **Flutter Driver gate** | `main.dart:142` | `enableFlutterDriverExtension()` guarded behind `--dart-define=ENABLE_FLUTTER_DRIVER=true` (default false → production no-op) for §7.1 black-box drivability. |

Also merged in this window (product surface, walled off from the alarm): journey-share + Guardian mode, opt-in mobility-data pipeline (egress-OFF), trip stats, home-widget scaffold, arrival hooks/post-arrival UX, and a Pro-tier trim. These live under `lib/services/share/*`, `lib/services/data_asset/*`, `lib/services/monetization/*`, `lib/services/widget/*` and are covered by `13_monetization.md` (now broader than that doc describes).

---

## 1. Executive architecture overview

GeoWake has exactly one job: **wake a transit rider before their stop — never late, never at the wrong place — even when GPS dies underground, on a cheap Android phone, in India.** Everything below is graded against that promise.

The product is a Flutter app plus a thin Node/Railway Maps proxy plus a small Android-native plugin. The core is a **background isolate** (`flutter_background_service`) that holds a partial wake lock for the whole trip, streams GPS, fuses it with an EKF, decides when to fire, and raises the alarm through the OS notification/audio stack — with a pre-scheduled OS exact-alarm as a process-death backstop.

The central engineering truth (measured, not assumed — see `HANDOFF.md §0`): **IMU dead-reckoning does not work on a consumer phone.** Handheld accelerometer has ~0 correlation with train acceleration; ZUPT/station detection fails; open-loop dead-reckoning drifts kilometres in minutes and fires late 30–55% of the time on real rides; "never late" is statistically unprovable with collectable data. So the never-late guarantee does **not** rest on the Kalman filter. It rests on a **reachability Protection Level** (`docs/system_map/02_reachability.md`): after GPS is lost, the train cannot be further along the route than

```
s_max(t) = last_true_anchor_hi + V_LINE · (wall-clock time since last real fix)
```

Fire when `s_max` reaches the target → **late-proof by physics, no sensors required.** The EKF (`03_ekf_core.md`) is demoted to three real jobs: GPS-present tracking (~90% of a trip), protecting the reachability anchor via phantom-fix rejection, and fire-decision plumbing. It is not trusted for the tunnel fire.

### The never-late 3-layer stack

The promise is held by three independent nets, each an *upper bound* on progress (or *lower bound* on ETA) that can only fire the alarm early:

1. **Statistical layer** — EKF dead-reckoned progress `+ k·σ` (`k=2`). Dominant when GPS is healthy or the blackout is short. Runs in the live wake-locked isolate. Not trusted alone through a long tunnel.
2. **Physics reachability cone** — `Reachability.bound` → `s_max` (`reachability.dart`, 964 lines). The load-bearing late-proof bound. Now tightened by the **vehicle-type V_LINE floor**, the **piecewise multi-leg V_LINE march**, and (inert-by-default) the fastest-feasible-train sweep (accel + terminal-braking + curve ceiling + dwell). Fires the moment the worst-case reachable position passes the target. Also runs in the live isolate; also seeds a cold-start anchor at trip origin so it works even if GPS never yields one underground fix.
3. **OS exact-alarm process-death backstop** — `setAlarmClock` id 991, re-armed ~1 Hz. As of GW-0080 it is armed at **min(ETA-derived fire, physics free-run reach instant)**, so it survives process death / Doze / OEM-kill and still fires on the physics never-late instant, not a stale ETA. Mutually exclusive in time with the live alarm (cancelled the instant `alarmFired`).

The `fire decision = max(statistical, physics)` folds layers 1+2 (`Reachability.effectiveProgress`); layer 3 is the out-of-process net for when the live chain is dead.

Layer stack (by delivery role):

- **Delivery / OS**: `12_notifications_native.md` (channels, backstop id 991, wake lock), `packages/wakepoint_native` (partial wake lock, full-screen-intent capability), Android manifest + FGS.
- **Decision**: `05_alarm_decision.md` (fire), `02_reachability.md` (never-late bound), `11_eta.md` (ETA + σ cushion).
- **State estimation**: `03_ekf_core.md` (EKF), `07_location_position.md` (GPS gate + fusion handoff).
- **Route knowledge**: `08_route_directions.md` (fetch/cache/snap), `10_metro_data_stops.md` (station inventory, N-stops), `09_deviation_reroute.md` (off-route).
- **Session/runtime**: `01_entry_lifecycle.md`, `06_tracking.md` (background loop + persistence).
- **Trust/telemetry/UI**: `14_reliability_telemetry.md` (preflight + funnel), `15_ui_screens.md` (arming flow).
- **Infra/build/revenue/dev**: `16_server_railway.md`, `17_config_build_ios.md`, `13_monetization.md`, `04_ekf_replay.md` + `18_sim_dashboards.md` (validation) + `lib/testing/harness_runner.dart` (§7 headless harness, no doc yet).

---

## 2. Key files (with role + size)

Sizes are current line counts at HEAD; roles are the load-bearing responsibility.

### Never-late core

| Path | Lines | Role |
| --- | --- | --- |
| `lib/core/reachability/reachability.dart` | 964 | The entire Protection Level. Pure math (`Reachability.bound`, `effectiveProgress`, `_piecewiseFreeRun`, `_topologyCappedProgress`, `_fastestFeasibleProgress`) + data holders (`ReachabilityAnchor`, `RouteTopology`, `RouteProfile`, `ReachabilityConfig`, `ReachabilityBound`, **`VLineSegment`**) + the per-line speed table `VLineTable` (now with the **name-free `_vehicleCeiling` floor**) + the stateful `ReachabilityTracker`. Time is passed in explicitly → deterministically testable. |
| `lib/services/tracking/alarm_controller.dart` | 2032 | Owns the single `ReachabilityTracker _reach`. Per tick: seeds/re-anchors from the `Position`, resolves V_LINE via `forLine(city:,lineName:,vehicleType:)`, builds the **`vLineSegments` list over forward legs** (`:1518-1556`), computes the reach bound, folds it into `AlarmEvaluator`, and refreshes the **physics backstop instant** `_backstopPhysicsFireAt` (`:1586-1589`). Also fires the cold-start-underground reach backstop (`_maybeFireColdStartReachBackstop`). |
| `lib/services/alarm_evaluator.dart` | 1564 | Consumes `reachableProgressBoundMeters`; folds it via `Reachability.effectiveProgress` for metro stop-count / 60%-rule paths and a direct `reachBound ≥ target` short-circuit on the time-mode ETA paths. |
| `lib/config/fire_decision_config.dart` | 60 | Shared constants: `fractileK = 2.0`, `maxFractileSigmaMeters = 300`, `deadReckonAccuracySentinel = 9999`. |
| `lib/services/tracking/notification_updater.dart` | 500 | Re-arms the OS backstop id 991 ~1 Hz at **min(ETA lead, `backstopPhysicsFireAt`)** (`_maybeRearmEtaBackstop`); cancels it once `alarmFired`. |
| `lib/services/ios/ios_backstop_planner.dart` | 267 | Second consumer of `VLineTable` (earliest-arrival iOS scheduling). Not on the live fire loop. |

### EKF core + replay/harness

| Path | Lines | Role |
| --- | --- | --- |
| `lib/core/ekf/ekf_pipeline.dart` | 819 | The Kalman filter proper: state `[s, v, b]`, 3×3 `P`, predict/GPS-update/ZUPT/station-snap + numerical safety rails. |
| `lib/core/ekf/ekf_orchestrator.dart` | 887 | The conductor: owns the pipeline + detectors, decides when to predict/update, runs frozen-phantom rejection, gates station snaps. App-facing integration surface. |
| `lib/core/ekf/imu_replay_engine_v2.dart` | 2888 | Dashboard/replay **data source**: synthesizes or replays IMU+GPS at fixed tick; six GPS-dropout modes. **NEW `loadFromPolyline` + `GpsBlackoutWindow`** synthesize a timeline from any polyline with explicit tunnel windows. No EKF or pass/fail logic. |
| `lib/core/ekf/ekf_test_controller.dart` | 1575 | Replay **wiring**: drives the real orchestrator + `RouteGeometry` + `AlarmEvaluator` + reachability. **NEW `loadRouteFromPolyline`** runs the real never-late engine over arbitrary polylines. Illustrative metrics; asserts no gate itself. |
| `lib/testing/harness_runner.dart` | 763 | **NEW** charter §7.3 headless harness. `runScenario`/`sweep` + CLI; JSON spec → `EkfTestController` → JSON metrics + tolerance verdict; exit 1 on late-fire/never-fire. |
| `test/ekf/replay_harness_test.dart` | ~1175 | **THE offline never-late gate** (`flutter test`); globs recorded fixtures at `/home/raed/geowake_imu_analysis/fixtures`, replays through the real engine, `expect`s no late/never-fire + a reachability-monotonicity proof. |

### Session / tracking / delivery

| Path | Lines | Role |
| --- | --- | --- |
| `lib/main.dart` | 392 | App entry. `runZonedGuarded` + `FlutterError.onError` + `PlatformDispatcher.onError` → telemetry + crash flag; edge-to-edge; Hive init; fire-and-forget init of monetization / Guardian / mobility-data / home-widget / journey-share; share deep-links; **driver-extension gate**; `MyApp` routes (`/splash`, `/mapTracking`, `/paywall`, `/guardian`, `/postArrival`, `/dataConsent`, …). |
| `lib/services/trackingservice.dart` | 2758 | Background-isolate host: `_onStart`, wake-lock acquire/release, location stream, snapshot persistence, dropout `Timer.periodic` tick, recovery. |
| `lib/services/tracking/location_stream_handler.dart` | 773 | Produces the dead-reckoned dropout `Position` (`accuracy = 9999` sentinel that must **not** re-anchor reachability); `onCheckAlarm` → `AlarmController`. |
| `lib/services/location_manager.dart` | 457 | GPS gate (drop `acc > 100 m`), speed pipeline, EKF/sensor-fusion handoff. |
| `lib/services/notification_service.dart` | 1758 | Notification channels + `showWakeUpAlarm` (id 0, silent channel + `AlarmPlayer`) + `scheduleEtaBackstop`/`cancelEtaBackstop` (id 991). |
| `lib/services/transfer_utils.dart` | 1857 | Metro leg stops, `nStopsPriorTarget`, `stopsPassed` — the "N stops before" correctness. |

### Product surface (walled off from the alarm)

| Path | Lines | Role |
| --- | --- | --- |
| `lib/services/share/journey_share_service.dart` | 366 | Free viral journey share; `bindTracking` relays live position, self-gated on an active share (inert otherwise). |
| `lib/services/share/guardian_service.dart` | 365 | Guardian mode (Pro); POST-ALARM "arrived safely" observer hung off `PostAlarmMulticast` — never touches the spine. |
| `lib/services/monetization/premium_service.dart` | 246 | Reactive entitlement; gates default to "free" until ready. |
| `lib/services/telemetry/telemetry_service.dart` | 335 | Error/funnel telemetry; durable JSONL sink; optional network egress INERT unless `GEOWAKE_TELEMETRY_URL` is dart-defined. |

---

## 3. End-to-end data-flow (arm → route fetch → track → GPS-loss → fire → notify → backstop → wake → arrive)

```
                          ┌──────────────────────────── FOREGROUND (UI isolate) ────────────────────────────┐
   rider picks dest       │                                                                                  │
        │                 │  homescreen: search → select dest                                                │
        ▼                 │        │                                                                         │
 ┌──────────────┐         │        ▼  _validateSameState  ── (G2: cross-state HARD BLOCK, refuses sleeper)   │
 │ Places/Auto  │◀────────┤   Wake Me!                                                                       │
 │ complete     │  proxy  │        │                                                                         │
 └──────────────┘         │        ▼  ReliabilityPreflight.run()  ── (G1: block verdict NOT enforced) ───────┼──┐
        │                 │        │   (notifications/DND/exact-alarm/battery/OEM checks → advisory dialog)  │  │ warns
        ▼                 │        ▼                                                                         │  │ only
 ┌──────────────┐  HTTPS  │   DirectionService.getRoute ──▶ RouteCache (Hive, 5-min TTL) ──▶ RouteRegistry   │  │
 │ Railway proxy│◀────────┤        │  decode polyline, build legs (cityKey/lineName/vehicleType), stopMeters │  │
 │ (16_server)  │  Google │        ▼                                                                         │  │
 └──────────────┘  Maps   │   setActive(true) + saveSnapshot(directions)  ── persisted BEFORE start ─────────┼─┐│
        ▲                 │        ▼                                                                         │ ││
        │ single point    │   TrackingService.startTracking ──▶ startService()  ── (G33: race vs setActive) │ ││
        │ of failure(G28) └────────┼─────────────────────────────────────────────────────────────────────────┘ ││
        │                          ▼                                                                             ││
        │       ┌──────────────────────────── BACKGROUND isolate (_onStart) ───────────────────────────────┐   ││
        │       │  acquire G1 PARTIAL_WAKE_LOCK ── held whole session ── release only in _onStop            │   ││
        │       │        │                                                                                  │   ││
        │       │        ▼  startLocationStream(PowerPolicy tier @arm, never re-evaluated  G32)             │   ││
        │       │  LocationManager.positionStream (07) ──gate: drop acc>100m, sim takeover──▶               │   ││
        │       │        │                                                                                  │   ││
        │       │  ┌─────┴─────────── GPS PRESENT ───────────┐   ┌────────── GPS LOST (tunnel) ──────────┐  │   ││
        │       │  │ SensorFusionManager/EKF.ingest (03)     │   │ dropout Timer.periodic on wake-locked │  │   ││
        │       │  │  needs RouteGeometry ≥2 pts (G10)       │   │ CPU tick → _maybeEvaluateAlarm...      │  │   ││
        │       │  │ snap-to-route → progressMeters          │   │ EKF coasts on last v; reach: s_max +=  │  │   ││
        │       │  │ Reachability.onAcceptedFix (real only)  │   │  V_LINE·Δt (accuracy=9999 sentinel)   │  │   ││
        │       │  └─────┬──────────────────────────────────┘   └──────────────┬───────────────────────┘  │   ││
        │       │        ▼                                                      │                          │   ││
        │       │  AlarmController.checkAndTriggerAlarm (05)  ◀──────────────────┘                          │   ││
        │       │        │  V_LINE = forLine(city,line,vehicleType)  ── vehicle-type FLOOR (GW-0076)        │   ││
        │       │        │  reach = bound(anchor, vLineSegments[forward legs])  ── PIECEWISE multi-leg      │   ││
        │       │        │  effectiveProgress = max(deadReckoned+kσ, reachBound)                            │   ││
        │       │        │  ETA path: fire if (median-ETA − k·σ_eta) ≤ threshold                            │   ││
        │       │        │  _refreshBackstopPhysicsFireAt → _backstopPhysicsFireAt (GW-0080)  ──────────────┼─┐ ││
        │       │        ▼  shouldFire?  ──── one-alarm-per-leg (firedLegIds) ────                          │ │ ││
        │       │   ┌────┴─── FIRE ───────────────────────────────────────────────┐                        │ │ ││
        │       │   │ NotificationService.showWakeUpAlarm                          │                        │ │ ││
        │       │   │   • id 0 live alarm (SILENT channel) + fullScreenIntent?     │  ── (G16 false on 14+) │ │ ││
        │       │   │   • AlarmPlayer: loud ALARM tone + escalating haptics        │                        │ │ ││
        │       │   │   • cancelEtaBackstop(991)  (mutually exclusive w/ backstop) │                        │ │ ││
        │       │   └─────────────────────────────────────────────────────────────┘                        │ │ ││
        │       │                                                                                           │ │ ││
        │       │  every ~1 Hz: NotificationUpdater re-arms OS backstop id 991                               │ │ ││
        │       │     setAlarmClock(fireAt = MIN(smoothedETA−lead, backstopPhysicsFireAt))  ◀────────────────┘ │ ││
        │       └───────────────────────────────────────────────────────────────────────────────────────────┘ │ ││
        │                                                                                                       │ ││
        │   PROCESS-DEATH / Doze / OEM-kill / reboot ──▶ live chain dies. Only surviving net = OS backstop 991  │ ││
        │      • now armed at the PHYSICS never-late instant, not a stale ETA (GW-0080)  ◀─────────────────────┘ ││
        │      • Boot/watchdog resume BROKEN on Android 14+ (G9)   • Backstop may be left armed after End (G22)   │
        │      • recovery: SplashScreen reads snapshot → resume  (G10: may resume route-less)  ◀─────────────────┘
        ▼
   BACKSTOP (or live alarm) RINGS ──▶ rider wakes ──▶ END TRACKING ──▶ _onStop: release wake lock, cancel 0/888/889 (+991)
```

Legend: `(Gn)` markers point to ranked gaps in `GAP_ANALYSIS.md`. Notification IDs are fixed and globally unique: **alarm=0, progress=888, paused=889, wrong-direction=890, backstop=991** (legacy 8888 swept).

---

## 4. Subsystem index

| # | Section file | One-line role | Freshness |
|---|---|---|---|
| 01 | `docs/system_map/01_entry_lifecycle.md` | App entry (`main.dart`), splash, background-isolate lifecycle, arm/recovery, `AppClock` | current-ish (main.dart grew share/widget/data init + driver gate) |
| 02 | `docs/system_map/02_reachability.md` | **The never-late physics core**: `s_max = anchor + V_LINE·t`; the only true late-proof lever | **STALE** — vehicle-type floor, piecewise `VLineSegment`, physics backstop |
| 03 | `docs/system_map/03_ekf_core.md` | EKF for GPS-present tracking + dead-reckoning + station snap (demoted from tunnel fire) | **STALE** — replay entry points (`loadFromPolyline`) added |
| 04 | `docs/system_map/04_ekf_replay.md` | Offline replay harness + the never-late build gate over real-ride fixtures | **STALE** — `loadFromPolyline`/`loadRouteFromPolyline`/`GpsBlackoutWindow`; new `harness_runner.dart` has no doc |
| 05 | `docs/system_map/05_alarm_decision.md` | The fire decision: modes (stops/time/distance), `effectiveProgress`, one-alarm-per-leg | mostly current (folds new reach bound transparently) |
| 06 | `docs/system_map/06_tracking.md` | `trackingservice.dart` background loop, location stream, snapshot persistence, dropout tick | current |
| 07 | `docs/system_map/07_location_position.md` | `LocationManager` GPS gate, speed pipeline, EKF/sensor-fusion handoff | current |
| 08 | `docs/system_map/08_route_directions.md` | Directions fetch via proxy, `RouteCache`/`RouteRegistry`, snap-to-route | current |
| 09 | `docs/system_map/09_deviation_reroute.md` | Off-route detection, reroute policy + constraints, termination | current |
| 10 | `docs/system_map/10_metro_data_stops.md` | Metro station inventory + stop matching (the "N stops before" correctness) | current |
| 11 | `docs/system_map/11_eta.md` | ETA estimation + σ cushion (the statistical never-late lever) | current |
| 12 | `docs/system_map/12_notifications_native.md` | Notification channels, OS exact-alarm backstop, Android-native reliability | mostly current (backstop now min(eta,physics)) |
| 13 | `docs/system_map/13_monetization.md` | Ads, premium, share/Guardian, data, widget, post-arrival — walled off from the alarm | **broadened** — Waves 4–7 + arrival + Pro trim landed after this doc |
| 14 | `docs/system_map/14_reliability_telemetry.md` | Reliability preflight verdict + telemetry funnel (durable JSONL + optional egress) | current |
| 15 | `docs/system_map/15_ui_screens.md` | Screens/widgets/theme, arming flow, live tracking UI | current-ish (new share/guardian/report/post-arrival screens) |
| 16 | `docs/system_map/16_server_railway.md` | Railway Maps proxy: API-key protection, device auth, caching | current (+ `backend/share` journey-share service) |
| 17 | `docs/system_map/17_config_build_ios.md` | Build config, versioning, `VLineTable`, iOS backstop, platform | current |
| 18 | `docs/system_map/18_sim_dashboards.md` | Simulation, dev dashboards, test infrastructure | current-ish (see §7 harness below) |
| — | `lib/testing/harness_runner.dart` | **§7 headless scenario harness** (JSON spec → metrics → CI gate). **No `system_map` doc yet.** | **NO DOC** |

---

## 5. Cross-subsystem call graph (prose)

**Arm.** `15_ui` (`homescreen.dart`) validates the destination (`_validateSameState`, the cross-state block), runs `14` `ReliabilityPreflight` (advisory only), fetches a route through `08` `DirectionService` → `16` Railway proxy → Google, caches in `08` `RouteCache`/`RouteRegistry`, enhances metro legs with `10` station sequences **and per-leg `cityKey`/`lineName`/`vehicleType`**, persists an `06` `TrackingStateStore` snapshot **before** invoking `06` `TrackingService.startTracking`. `startTracking` calls `startService()`, spinning up the `01`/`06` background isolate (`_onStart`).

**Track.** `_onStart` acquires the G1 wake lock and calls `startLocationStream`, subscribing to `07` `LocationManager.positionStream`. Each accepted fix flows into `07`→`03` `SensorFusionManager`/EKF (which exists only if `08` registered a `RouteGeometry` with ≥2 points), then to `08` snap-to-route for `progressMeters`. `06` `LocationStreamHandler.onCheckAlarm` invokes `05` `AlarmController.checkAndTriggerAlarm`, which seeds/advances the `02` `ReachabilityTracker` anchor (real fixes only), resolves `V_LINE` via `VLineTable.forLine(city,line,vehicleType)` (**vehicle-type floor**), builds the forward-leg **`vLineSegments`** list (**piecewise multi-leg**), computes the reach bound, and calls `05` `AlarmEvaluator`. The evaluator combines `03` dead-reckoned progress, `11` `EtaEngine` ETA + σ, and the `02` reach bound into `effectiveProgress`, then decides `shouldFire`. Each tick it also refreshes `_backstopPhysicsFireAt` for the OS backstop.

**GPS-loss.** When the position stream goes silent, `06`'s wake-locked `Timer.periodic` dropout tick calls `_maybeEvaluateAlarmDuringDropout` → the same `05` `checkAndTriggerAlarm` with a dead-reckon sentinel (`accuracy == 9999`). `02` keeps growing `s_max` on wall-clock; `03` coasts on last velocity. `AlarmController._maybeFireColdStartReachBackstop` covers the cold-start-underground case where the EKF never initialised.

**Fire → notify → backstop.** On fire, `05` calls `12` `NotificationService.showWakeUpAlarm` (silent alarm id 0 + `AlarmPlayer` loud tone/haptics), and cancels the OS backstop (id 991). Independently, every ~1 Hz `12` `NotificationUpdater._maybeRearmEtaBackstop` re-arms the exact alarm (id 991) at **`min(smoothedETA − lead, backstopPhysicsFireAt)`** — the process-death net, now physics-anchored (GW-0080).

**Deviation/reroute.** `06`→`09` `RouteSessionManager`/`DeviationMonitor` watch offset; on sustained deviation `09` `ReroutePolicy`/`RerouteConstraints` validate a replacement from `08`, and `05` `migrateAlarmState` moves fired/pending markers across route keys.

**Recovery.** After an OS kill, `15` `SplashScreen` reads the `06` snapshot; if `isActive()`, it resumes into `06`/`15` tracking (possibly route-less). `12` native + the FLN boot receiver re-arm scheduled notifications, but no receiver restarts the foreground service.

**Validation.** `04`/`18` + `lib/testing/harness_runner.dart` are validation-only, never on the release alarm path. `harness_runner` maps a JSON scenario → `EkfTestController` (`loadRouteFromPolyline` / named route) → the real EKF + `AlarmEvaluator` + reachability → JSON metrics + a tolerance verdict; `test/ekf/replay_harness_test.dart` is the blocking `flutter test` gate.

**Cross-cutting.** `14` telemetry/preflight observe but never gate; `13` monetization + share/Guardian/data/widget are structurally forbidden from touching the alarm/lock-screen (Guardian is POST-ALARM only); `17` supplies `VLineTable` speeds and the (unwired) iOS backstop.

---

## 6. Top invariants the whole system rests on

1. **Never fire late (the promise).** Every mode compares an **upper bound** on true progress (`effectiveProgress = max(deadReckoned + k·σ, reachBound)`) or a **lower bound** on ETA (`median − k·σ_eta`, `k=2`) against the threshold. _Caveat (G5): the `reachBound` term is wired to the metro-stops/time paths; the app-wide guarantee is still not universal on every distance path._
2. **Reachability is monotone-safe.** It can only make an alarm fire **earlier**, never later (`fireTs(reach on) ≤ fireTs(reach off)`), and is late-proof only while its three preconditions hold: (i) the anchor is a **real** fix, not a phantom; (ii) `V_LINE ≥ true max line speed`; (iii) `t` is wall-clock since the last **true** fix. **The new tighteners preserve this**: the vehicle-type floor returns `max(keyword-tier, vehicle-floor)` (a raise never lowers the ceiling); the piecewise march integrates per-leg ceilings each of which over-bounds its own span and is `≤` the flat max.
3. **The anchor advances only on real accepted fixes.** A dead-reckon sentinel (`accuracy ≥ 9999`) never re-anchors and never resets `t`; `t` grows monotonically through a blackout. `onAcceptedFix` also guards against a backward-in-time anchor.
4. **One alarm per leg; destination is terminal.** A `legId` fires at most once per session (`firedLegIds`); after the destination alarm fires for a route key, nothing else fires for it.
5. **Fired markers are committed only after a successful notification.** Failure rolls back so the alarm retries — a fire is never "lost" by marking-then-failing.
6. **Exactly one active session per background isolate.** Module-level globals assume a single journey; a second arm without a clean `_onStop` is undefined.
7. **The wake lock (G1) is held for the entire session** (`startLocationStream` → `_onStop`), and the OS backstop (id 991) is **mutually exclusive in time** with the live alarm — cancelled the moment `alarmFired` becomes true. The backstop's fire instant is `min(ETA-derived, physics free-run)` so it is always early-biased (GW-0080).
8. **Notification channels are created natively (MainActivity) before any Dart post**, because importance/DND/sound freeze on first creation. The live alarm channel is always **silent**; the backstop channel always **self-sounds** the system ALARM tone.
9. **Identity is stable end-to-end.** `applicationId == com.geowake.app` across app, server `APP_BUNDLE_ID`, and AdMob/IAP; a route key is a pure function of `(origin, dest, mode, variant, departureTime)` at 5-decimal rounding; meters live in the decoded-polyline domain across all subsystems.
10. **Every `VLineTable` value ≥ the line's true max speed.** Both never-late nets (reachability and the iOS backstop) rest on this — a too-low `V_LINE` is a direct late-fire (see G11). The vehicle-type floor exists precisely to prevent a fast line reported with a slow/generic name from under-bounding.
11. **Fail-safe toward firing on corrupt input.** A non-finite anchor position/time or clock forces `s_max = +∞` (fires), and `effectiveProgress` returns `+∞` for a fire-forcing reach bound — never-firing is the cardinal sin, so every corrupt-input branch biases toward an early wake.

_For the honest accounting of where these invariants are violated or unenforced, read `GAP_ANALYSIS.md`. For what is *proven* vs physical-only, read `VALIDATION_REPORT.md`._
