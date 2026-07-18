# GeoWake — Master System Map

_Chief-engineer end-to-end map. Atomic detail lives in `docs/system_map/01..18_*.md`; this document is the index, the data-flow, the call graph, and the load-bearing invariants. App name is **GeoWake** (never "geowake2"/"WakePoint" in user-facing strings). Flutter, Android-first, India-first. Branch `sim-validation`; main `stable-release-1`._

---

## 1. Executive architecture overview

GeoWake has exactly one job: **wake a transit rider before their stop — never late, never at the wrong place — even when GPS dies underground, on a cheap Android phone, in India.** Everything below is graded against that promise.

The product is a Flutter app plus a thin Node/Railway Maps proxy plus a small Android-native plugin. The core is a **background isolate** (`flutter_background_service`) that holds a partial wake lock for the whole trip, streams GPS, fuses it with an EKF, decides when to fire, and raises the alarm through the OS notification/audio stack — with a pre-scheduled OS exact-alarm as a process-death backstop.

The central engineering truth (measured, not assumed — see `HANDOFF.md §0`): **IMU dead-reckoning does not work on a consumer phone.** Handheld accelerometer has ~0 correlation with train acceleration; ZUPT/station detection fails; open-loop dead-reckoning drifts kilometres in minutes and fires late 30–55% of the time on real rides; "never late" is statistically unprovable with collectable data. So the never-late guarantee does **not** rest on the Kalman filter. It rests on a **reachability Protection Level** (`docs/system_map/02_reachability.md`): after GPS is lost, the train cannot be further along the route than

```
s_max(t) = last_true_anchor + V_LINE · (wall-clock time since last real fix)
```

Fire when `s_max` reaches the target → **late-proof by physics, no sensors required.** The EKF (`03_ekf_core.md`) is demoted to three real jobs: GPS-present tracking (~90% of a trip), protecting the reachability anchor via phantom-fix rejection, and fire-decision plumbing. It is not trusted for the tunnel fire.

Two independent "ropes" are supposed to hold the promise: the **live Dart chain** (EKF + reachability + ETA, running in the wake-locked isolate) and the **OS exact-alarm backstop** (survives process death). The consolidated gap analysis (`GAP_ANALYSIS.md`) shows both ropes are thinner than the docs imply, and that the reachability rope is wired to only one of four alarm modes today.

Layer stack:

- **Delivery / OS**: `12_notifications_native.md` (channels, backstop id 991, wake lock), `packages/wakepoint_native` (partial wake lock, full-screen-intent capability), Android manifest + FGS.
- **Decision**: `05_alarm_decision.md` (fire), `02_reachability.md` (never-late bound), `11_eta.md` (ETA + σ cushion).
- **State estimation**: `03_ekf_core.md` (EKF), `07_location_position.md` (GPS gate + fusion handoff).
- **Route knowledge**: `08_route_directions.md` (fetch/cache/snap), `10_metro_data_stops.md` (station inventory, N-stops), `09_deviation_reroute.md` (off-route).
- **Session/runtime**: `01_entry_lifecycle.md`, `06_tracking.md` (background loop + persistence).
- **Trust/telemetry/UI**: `14_reliability_telemetry.md` (preflight + funnel), `15_ui_screens.md` (arming flow).
- **Infra/build/revenue/dev**: `16_server_railway.md`, `17_config_build_ios.md`, `13_monetization.md`, `04_ekf_replay.md` + `18_sim_dashboards.md` (validation).

---

## 2. End-to-end data-flow (arm → route fetch → track → GPS-loss → fire → notify → backstop → wake → arrive)

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
 │ Railway proxy│◀────────┤        │  decode polyline, build legs, stopMeters, enhance w/ OSM metro seq      │  │
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
        │       │  │ snap-to-route → progressMeters          │   │  ── (G3: BAILS if no prior fix/EKF) ── │  │   ││
        │       │  │ Reachability.onAcceptedFix (real only)  │   │ EKF coasts on last v; reach: s_max +=  │  │   ││
        │       │  └─────┬──────────────────────────────────┘   │  V_LINE·Δt (accuracy=9999 sentinel)   │  │   ││
        │       │        ▼                                       └──────────────┬───────────────────────┘  │   ││
        │       │  AlarmController.checkAndTriggerAlarm (05)  ◀──────────────────┘                          │   ││
        │       │        │  effectiveProgress = max(deadReckoned+kσ, reachBound)   (reachBound: METRO only  │   ││
        │       │        │  ETA path: fire if (median-ETA − k·σ_eta) ≤ threshold    G5/G13)                 │   ││
        │       │        ▼  shouldFire?  ──── one-alarm-per-leg (firedLegIds) ────                          │   ││
        │       │   ┌────┴─── FIRE ───────────────────────────────────────────────┐                        │   ││
        │       │   │ NotificationService.showWakeUpAlarm                          │                        │   ││
        │       │   │   • id 0 live alarm (SILENT channel) + fullScreenIntent?     │  ── (G16 false on 14+) │   ││
        │       │   │   • AlarmPlayer: loud ALARM tone + escalating haptics        │                        │   ││
        │       │   │   • cancelEtaBackstop(991)  (mutually exclusive w/ backstop) │                        │   ││
        │       │   │   (G14 on throw → playSound:false on dead UI isolate)        │                        │   ││
        │       │   └─────────────────────────────────────────────────────────────┘                        │   ││
        │       │                                                                                           │   ││
        │       │  every ~1 Hz: NotificationUpdater re-arms OS backstop id 991                               │   ││
        │       │     setAlarmClock(fireAt = smoothedETA − lead)  lead=60s for stops/dist (G14)  ◀───────────┼───┘│
        │       └───────────────────────────────────────────────────────────────────────────────────────────┘   │
        │                                                                                                         │
        │   PROCESS-DEATH / Doze / OEM-kill / reboot ──▶ live chain dies. Only surviving net = OS backstop 991    │
        │      • Boot/watchdog resume BROKEN on Android 14+ (G9)   • Backstop may be left armed after End (G22)   │
        │      • recovery: SplashScreen reads snapshot → resume  (G10: may resume route-less)  ◀─────────────────┘
        ▼
   BACKSTOP (or live alarm) RINGS ──▶ rider wakes ──▶ END TRACKING ──▶ _onStop: release wake lock, cancel 0/888/889 (+991)
```

Legend: `(Gn)` markers point to ranked gaps in `GAP_ANALYSIS.md`. Notification IDs are fixed and globally unique: **alarm=0, progress=888, paused=889, wrong-direction=890, backstop=991** (legacy 8888 swept).

---

## 3. Subsystem index

| # | Section file | One-line role |
|---|---|---|
| 01 | `docs/system_map/01_entry_lifecycle.md` | App entry (`main.dart`), splash, background-isolate lifecycle, arm/recovery, `AppClock` |
| 02 | `docs/system_map/02_reachability.md` | **The never-late physics core**: `s_max = anchor + V_LINE·t`; the only true late-proof lever |
| 03 | `docs/system_map/03_ekf_core.md` | EKF for GPS-present tracking + dead-reckoning + station snap (demoted from tunnel fire) |
| 04 | `docs/system_map/04_ekf_replay.md` | Offline replay harness + the never-late build gate (TASK 1/3/4) over real-ride fixtures |
| 05 | `docs/system_map/05_alarm_decision.md` | The fire decision: modes (stops/time/distance), `effectiveProgress`, one-alarm-per-leg |
| 06 | `docs/system_map/06_tracking.md` | `trackingservice.dart` background loop, location stream, snapshot persistence, dropout tick |
| 07 | `docs/system_map/07_location_position.md` | `LocationManager` GPS gate, speed pipeline, EKF/sensor-fusion handoff |
| 08 | `docs/system_map/08_route_directions.md` | Directions fetch via proxy, `RouteCache`/`RouteRegistry`, snap-to-route |
| 09 | `docs/system_map/09_deviation_reroute.md` | Off-route detection, reroute policy + constraints, termination |
| 10 | `docs/system_map/10_metro_data_stops.md` | Metro station inventory + stop matching (the "N stops before" correctness) |
| 11 | `docs/system_map/11_eta.md` | ETA estimation + σ cushion (the second, statistical never-late lever) |
| 12 | `docs/system_map/12_notifications_native.md` | Notification channels, OS exact-alarm backstop, Android-native reliability |
| 13 | `docs/system_map/13_monetization.md` | Ads, premium, payment, post-arrival card, route memory — walled off from the alarm |
| 14 | `docs/system_map/14_reliability_telemetry.md` | Reliability preflight verdict + telemetry funnel (persistence currently missing) |
| 15 | `docs/system_map/15_ui_screens.md` | Screens/widgets/theme, arming flow, live tracking UI |
| 16 | `docs/system_map/16_server_railway.md` | Railway Maps proxy: API-key protection, device auth, caching |
| 17 | `docs/system_map/17_config_build_ios.md` | Build config, versioning, `VLineTable`, iOS backstop, platform |
| 18 | `docs/system_map/18_sim_dashboards.md` | Simulation, dev dashboards, test infrastructure |

---

## 4. Cross-subsystem call graph (prose)

**Arm.** `15_ui` (`homescreen.dart`) validates the destination (`_validateSameState`, the cross-state block), runs `14` `ReliabilityPreflight` (advisory only), fetches a route through `08` `DirectionService` → `16` Railway proxy → Google, caches in `08` `RouteCache`/`RouteRegistry`, enhances metro legs with `10` station sequences, persists an `06` `TrackingStateStore` snapshot **before** invoking `06` `TrackingService.startTracking`. `startTracking` calls `startService()`, spinning up the `01`/`06` background isolate (`_onStart`).

**Track.** `_onStart` acquires the G1 wake lock and calls `startLocationStream`, subscribing to `07` `LocationManager.positionStream`. Each accepted fix flows into `07`→`03` `SensorFusionManager`/EKF (which exists only if `08` registered a `RouteGeometry` with ≥2 points), then to `08` snap-to-route for `progressMeters`. `06` `LocationStreamHandler.onCheckAlarm` invokes `05` `AlarmController.checkAndTriggerAlarm`, which seeds/advances the `02` `Reachability` anchor (real fixes only) and calls `05` `AlarmEvaluator`. The evaluator combines `03` dead-reckoned progress, `11` `EtaEngine` ETA + σ, and (metro paths only) the `02` reach bound into `effectiveProgress`, then decides `shouldFire`.

**GPS-loss.** When the position stream goes silent, `06`'s wake-locked `Timer.periodic` dropout tick calls `_maybeEvaluateAlarmDuringDropout` → the same `05` `checkAndTriggerAlarm` with a dead-reckon sentinel (`accuracy == 9999`). `02` keeps growing `s_max` on wall-clock; `03` coasts on last velocity. This is the countdown-keeping path underground.

**Fire → notify → backstop.** On fire, `05` calls `12` `NotificationService.showWakeUpAlarm` (silent alarm id 0 + `AlarmPlayer` loud tone/haptics), and cancels the OS backstop (id 991). Independently, every ~1 Hz `12` `NotificationUpdater` re-arms the `12` `NotificationService.scheduleEtaBackstop` exact alarm (id 991) from `11` ETA — the process-death net.

**Deviation/reroute.** `06`→`09` `RouteSessionManager`/`DeviationMonitor` watch offset; on sustained deviation `09` `ReroutePolicy`/`RerouteConstraints` validate a replacement from `08`, and `05` `migrateAlarmState` moves fired/pending markers across route keys.

**Recovery.** After an OS kill, `15` `SplashScreen` reads the `06` snapshot; if `isActive()`, it resumes into `06`/`15` tracking (possibly route-less). `12` native + the FLN boot receiver re-arm scheduled notifications, but no receiver restarts the foreground service.

**Cross-cutting.** `14` telemetry/preflight observe but never gate; `13` monetization is structurally forbidden from touching the alarm/lock-screen; `04`/`18` are validation-only and never on the release alarm path; `17` supplies `VLineTable` speeds and the (unwired) iOS backstop.

---

## 5. Top invariants the whole system rests on

1. **Never fire late (the promise).** Every mode compares an **upper bound** on true progress (`effectiveProgress = max(deadReckoned + k·σ, reachBound)`) or a **lower bound** on ETA (`median − k·σ_eta`, `k=2`) against the threshold. _Caveat (G5): the `reachBound` term is wired only to the metro-stops/time paths today — the guarantee is not yet app-wide._
2. **Reachability is monotone-safe.** It can only make an alarm fire **earlier**, never later (`fireTs(reach on) ≤ fireTs(reach off)`), and is late-proof only while its three preconditions hold: (i) the anchor is a **real** fix, not a phantom; (ii) `V_LINE ≥ true max line speed`; (iii) `t` is wall-clock since the last **true** fix.
3. **The anchor advances only on real accepted fixes.** A dead-reckon sentinel (`accuracy ≥ 9999`) never re-anchors and never resets `t`; `t` grows monotonically through a blackout.
4. **One alarm per leg; destination is terminal.** A `legId` fires at most once per session (`firedLegIds`); after the destination alarm fires for a route key, nothing else fires for it.
5. **Fired markers are committed only after a successful notification.** Failure rolls back so the alarm retries — a fire is never "lost" by marking-then-failing.
6. **Exactly one active session per background isolate.** ~40 module-level globals assume a single journey; a second arm without a clean `_onStop` is undefined.
7. **The wake lock (G1) is held for the entire session** (`startLocationStream` → `_onStop`), and the OS backstop (id 991) is **mutually exclusive in time** with the live alarm — cancelled the moment `alarmFired` becomes true.
8. **Notification channels are created natively (MainActivity) before any Dart post**, because importance/DND/sound freeze on first creation. The live alarm channel is always **silent**; the backstop channel always **self-sounds** the system ALARM tone.
9. **Identity is stable end-to-end.** `applicationId == com.geowake.app` across app, server `APP_BUNDLE_ID`, and AdMob/IAP; a route key is a pure function of `(origin, dest, mode, variant, departureTime)` at 5-decimal rounding; meters live in the decoded-polyline domain across all subsystems.
10. **Every `VLineTable` value ≥ the line's true max speed.** Both never-late nets (reachability and the iOS backstop) rest on this — a too-low `V_LINE` is a direct late-fire (see G11).

_For the honest accounting of where these invariants are violated or unenforced, read `GAP_ANALYSIS.md`._
