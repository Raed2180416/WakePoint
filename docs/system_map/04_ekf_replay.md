> **⚠ STALE — needs regen (as of 2026-07-20 @ `8b9295a`).** This doc is 2026-07-15 vintage and predates the §7 harness surface: `ImuReplayEngineV2.loadFromPolyline` + `GpsBlackoutWindow` (`imu_replay_engine_v2.dart`, now 2888 lines), `EkfTestController.loadRouteFromPolyline` (now 1575 lines) — both run the **real** never-late engine over *arbitrary* polylines (not just canned Bengaluru routes) — and a brand-new headless CLI harness **`lib/testing/harness_runner.dart`** (763 lines: JSON scenario spec → `EkfTestController` → JSON metrics + tolerance verdict, exit 1 on late/never-fire) that **has no `system_map` doc of its own yet**. See `SYSTEM_MAP.md §0`.

## EKF Replay & Test Harness Engine

**Role in the core promise:** This subsystem is how GeoWake *proves* it will wake the rider on time. The core promise — "never late, never at the wrong place, even when GPS dies underground" — is a claim about the EKF's dead-reckoned progress estimate and the alarm-fire decision built on top of it. You cannot verify that claim on a live train ride every time you change code. So this subsystem replays *recorded* and *synthetic* metro rides through the **real** production EKF, the **real** alarm evaluator, and the **real** reachability safety-net, and then grades the fire decision against known ground truth. It has two distinct halves that share almost no code: (1) an *interactive dashboard* path (`imu_replay_engine_v2.dart` + `ekf_test_controller.dart`) that streams simulated/replayed sensor data into the live EKF for on-screen visual debugging, and (2) an *offline gate* (`test/ekf/replay_harness_test.dart`) that is the actual pass/fail "never-late" enforcement run as a `flutter test`. Only the second one blocks anything. The first one shows you *why* on a map.

---

### Files

| Path | What it does |
| --- | --- |
| `lib/core/ekf/imu_replay_engine_v2.dart` (2721 lines) | The dashboard-facing **data source**. Generates synthetic IMU+GPS for hand-built Bengaluru routes, or replays recorded CSV/JSON sensor logs, at a fixed 100 Hz tick. Emits `accelerometerStream`, `gyroscopeStream`, `gpsStream`, `imuSampleStream`, `gravityStream`, `orientationStream`, plus a rich per-tick `tickStream` and a `logStream`. Simulates six GPS-dropout modes. Does **not** contain any EKF or any pass/fail logic. |
| `lib/core/ekf/ekf_test_controller.dart` (1316 lines) | The dashboard **wiring**. Takes the engine's streams and drives the *real* `EkfOrchestrator` + `RouteGeometry` + `AlarmEvaluator` + `EkfMetrics`, projects EKF state back to map positions, evaluates a (simplified) alarm against EKF progress, and pushes `EkfTestVisualization` frames to the UI. Illustrative only — it computes metrics and logs but never asserts a gate. |
| `test/ekf/replay_harness_test.dart` (1175 lines) | **THE never-late gate.** A standalone offline harness (never touches `lib/`) that globs recorded fixtures, replays them through the real orchestrator+evaluator+reachability with its own deterministic driver loop, and `expect(...)`s that no ride fires late or never-fires. Contains four tests: the baseline never-late gate, three synthetic-scenario probes (phantom / gap / cold-start), and a reachability-monotonicity proof. |

> **Fixtures live outside the repo** at the hardcoded absolute path `/home/raed/geowake_imu_analysis/fixtures` (`replay_harness_test.dart:38`). Each ride is a triple: `fixture_<ride>.json` (metadata + polyline + station anchors + blind windows), `fixture_<ride>_imu.csv`, `fixture_<ride>_gps.csv`. Verified present on this machine (e.g. `fixture_short_2stop`, `fixture_Nallur_to_Vijaynagar`, `fixture_allunderground_20min`, `fixture_long_fullline`, `fixture_express_skip`).

---

### How it works, step by step

There are **three** replay paths. They are genuinely different pieces of software, so I walk each atomically.

#### Path A — Dashboard synthetic route (engine + controller, live)

1. **Route load.** `EkfTestController.initialize(scenario)` (`ekf_test_controller.dart:402`) builds a fresh `ImuReplayEngineV2`, calls `_configureForScenario` (`:720`) to pick a GPS-dropout mode + warp factor, maps the scenario to a `TestRouteId` (`:411`), and `await _engine!.loadTestRoute(routeId)` (`:423`).
2. **Route construction.** For a metro route, `_loadMetroRoute` (`imu_replay_engine_v2.dart:1104`) reads `assets/ekf_test_routes/bengaluru_metro_routes.json`, parses stations + `polyline_points` + `cumulative_meters`, and densifies the polyline with `_interpolatePolyline(..., 10.0)` (`:1143`) so no segment exceeds 10 m. The whole ride is a single `TestRouteLeg` with `averageSpeedMps = totalMeters / duration` (`:1162`). Non-metro (`_loadNonMetroRoute :1375`) and multi-modal (`_loadMultiModalRoute :1432`) build synthetic straight-line paths with `_generateSmoothPath` (pure linear interpolation, `:2171`).
3. **EKF wiring.** `_initializeEkf` (`:555`) creates `RouteGeometry.fromPoints(route.fullPolyline)` (`:563`), constructs the real `EkfOrchestrator` (`:566`), and calls `setStationContext(stationMeters, isMetroLeg: true)` (`:578`) — station arc-lengths come from `route.allStations.map((s) => s.cumulativeMeters)`. `_subscribeToEngineImu` (`:597`) pipes `engine.imuSampleStream` → `orchestrator.onImuSample`, deliberately bypassing the sparse tick stream so IMU arrives at the full 100 Hz.
4. **Playback tick.** `play()` starts `Timer.periodic(Duration(milliseconds: 10), (_) => _tick())` (`:1577`) — a fixed 100 Hz wall-clock timer. Each `_tick()` (`:1668`) advances `_elapsedSeconds` by `_fixedTickSeconds (0.01) * warpFactor` when `deterministicReplay` is true (`:1683`), builds a synthetic `simTime` from elapsed seconds, computes ground-truth `position = _positionAtTime(elapsed)` (`:1819`), a bearing, the active leg, and last/next station.
5. **Synthetic sensor generation.** `_updateMotionState` (`:1897`) picks a target speed (0 at a station dwell; a 200 m linear braking ramp before a station `:1923`; else `averageSpeedMps`) and eases `_currentSpeed` toward it at ±1.2/2.0 m/s². `_generateAccelerometer` (`:2070`) emits `z ≈ 9.81` gravity plus tiny motion terms (+0.5–0.8 m/s² forward/braking) and noise; `_generateGyroscope` (`:2110`) emits essentially only noise. These are pushed onto `_accelController`, `_gyroController`, and the combined `_imuSampleController`.
6. **GPS simulation.** `_computeGpsState(position, leg)` (`:1967`) switches on `gpsDropoutMode`: `normal` → true position, 10 m accuracy; `completeDropout` → one initial fix then nothing (`:1988`); `tunnelSimulation` → for metro legs, GPS only within ~50 m of a station else nothing (`:1995`); `intermittent` → random 5–15 s blackouts scheduled from the seeded RNG (`:2011`); `accuracyDegraded`/`urbanCanyon` → jittered position with 50–200 m / 15–100 m accuracy.
7. **Tick emission.** A fully-populated `ReplayTickResultV2` (`:1777`) is pushed on `tickStream`.
8. **Controller consumes the tick.** `_onTick` (`ekf_test_controller.dart:833`) feeds GPS to the EKF via `onGpsFixAuto(GpsFix(...))` when available or `onGpsUnavailable(tickDuration)` when not (`:856`/`:860`); reads `orchestrator.publicState`; projects EKF progress `ekfState.s` back to a `LatLng` via `RouteGeometry.positionAt` (`:878`); updates `EkfMetrics` with (EKF progress vs `tick.progressMeters`) (`:886`); runs `_evaluateAlarm` (`:897`); forces a ZUPT on a station dwell during GPS loss (`:1035`); builds the `EkfTestVisualization` (`:1092`) and calls `onVisualizationUpdate`.
9. **In-sim alarm (dashboard).** `_evaluateAlarm` (`:655`) constructs a single `RouteEventBoundary(meters: totalMeters, type: finalDestination)` and calls the **real** `AlarmEvaluator.evaluateCoinciding(mode: distance, userValue: 0, ..., transitLegs: const [], positionSigmaMeters: ekfState.sigmaS, ...)`. With empty transit legs it deliberately selects the evaluator's fallback "direct-fire < 200 m" destination rule. On fire it records an `EkfAlarmResult` whose `leadErrorMeters = ekfProgressMeters - trueProgressMeters` (`:238`) and `leadSeconds = routeDurationSeconds - fireElapsedSeconds` (`:242`).

#### Path B — Dashboard log replay (engine + controller, recorded)

Same controller wiring, but the engine is fed by CSV/JSON instead of a synthetic model. `loadFromLog` (`:997`) / `loadCapturedRouteReplay` (`:709`) / `loadUnifiedRouteLog` (`:891`) parse the logs via `LogParser` and reconstruct a route. In `_tickLogReplay` (`:2248`) the engine walks `logTime = _logStartTimeSeconds + _elapsedSeconds`, drains all accel/gyro/gravity/orientation samples with `secondsElapsed <= logTime`, and — critically — emits a combined `ImuSample` only when a **gyro** sample arrives, pairing it with the last-seen accel (`_lastLogAccel`, `:2289`). Locations are snapped to the route polyline via `_findClosestPointOnPolyline` (`:2356`) to derive `progressMeters`. This path is what the "sim-validation" work primarily exercises through the UI (the Nallur→Vijayanagar spike and cold-start bootstrap in the recent commits were debugged here).

#### Path C — Offline never-late gate (`replay_harness_test.dart`) — the one that matters

This does **not** use `ImuReplayEngineV2` at all. It reimplements a leaner, fully-deterministic driver.

1. **Discovery.** `discoverFixtures()` (`:133`) globs every `fixture_*.json` basename in `kFixturesDir`; nothing is hardcoded so new fixtures are picked up automatically.
2. **Load.** `_loadFixture(basename)` (`:178`) parses the JSON into a `_Fixture`: `oriented_polyline` → `List<LatLng>`; each station → `_StationAnchor(name, lat, lng, arrival_t_s, s_travel)`; the `alarm_target`; `gps_blind_windows_s`; and the two CSVs into `_ImuRow`/`_GpsRow` lists.
3. **Geometry + ground truth.** `runReplay` (`:442`) builds `RouteGeometry.fromPoints(fx.polyline)`, then projects each station and the alarm target onto arc-length: `s.sProj = route.projectLatLng(s.lat, s.lng)` (`:452`). Ground truth is a piecewise-linear map from time→arc-length over `(arrival_t_s, sProj)` anchors: `_GroundTruth.at(t)` (`:275`) linearly interpolates between the two bracketing station arrivals.
4. **Alarm topology.** A single final metro leg `TransitLegStops` is built from the *intermediate* stations (`:479`), with `stepBounds = [0, totalLen]` and `stepStops = [0, numIntermediate]`. This is what makes the gate test the realistic "N stops before destination" alarm rather than a toy.
5. **Reachability net.** A `ReachabilityTracker` with `ReachabilityConfig(dwellMinSeconds: 0.0)` and a `RouteTopology(stationMeters, dwellMinSeconds: 0)` is created (`:506`), then **seeded at the trip origin**: `reach.seedColdStart(tSeconds: reachT0, sMeters: 0.0)` (`:517`) where `reachT0` is the first IMU (or GPS) timestamp. This is the safety net that lets a fire happen even if the EKF never initializes.
6. **The driver loop** `body()` (`:676`): merges IMU and GPS rows by timestamp (`imuT <= gpsT` decides which advances).
   - **IMU event:** optionally dropped inside a `gapInject` window (`:690`); after 100 all-zero-gyro accel samples it declares `orch.setNoGyro(true)` (`:704`); if it has been >3 s since the last GPS fix it calls `orch.onGpsUnavailable(ts)` at most every 0.5 s (`:708`); then `orch.onImuSample(ImuSample(...))`; then records `publicState.s`, feeds metrics, counts degraded ticks, and detects **backward steps** (`st.s < lastS - 0.5` ⇒ `backwardEvents++`, `:734`).
   - **GPS event:** dropped entirely for `coldStart` (`:778`); dropped inside a `gapInject`/`phantomInject` window; **skipped if inside a blind window** — this blanking *is* the dead-reckoning mechanism (`:794`); otherwise passed through `_locationReplicaProcess` (`:406`) which enforces the production 100 m accuracy gate (`FireDecisionConfig.defaultAccuracyGateMeters`) and rewrites a missing/negative speed sentinel to a haversine-derived speed. Accepted fixes go to `orch.onGpsFixAuto(...)` via `acceptGps` (`:633`) and, for real fixes only, re-anchor reachability with `reach.onAcceptedFix(...)` (`:806`).
7. **Fire evaluation** `maybeEvaluateFire(t)` (`:594`): reads `orch.publicState`, optionally computes `reachBound = reach.boundNow(...).sMaxMeters`, and calls the **real** `AlarmEvaluator.evaluateCoinciding(mode: stops, userValue: 2, progressMeters: st.s, transitLegs: [leg], ..., positionSigmaMeters: st.sigmaS, velocitySigmaMps: st.sigmaV, fractileK: FireDecisionConfig.fractileK (2.0), reachableProgressBoundMeters: reachBound)`. If it returns a `finalDestination` trigger, it latches `fired = true`, `fireTs = t`, `fireS = st.s`, `fireSigma`, and the reason. Fire is evaluated on every accepted fix (after init), every ≥1 s while degraded, and — for cold start — every ≥1 s via reachability *even before EKF init* (`:767`). That pre-init reachability path is exactly what closes GLMT-03 ("EKF never inits → never fires").
8. **Scoring.** After the run, `sEstAt(t)` (`:822`) binary-searches the recorded `(recT, recS)` trace to interpolate the EKF estimate at each station's `arrival_t_s`, producing `_StationScore`s. The headline numbers:
   - `secondsMargin = fx.alarmTarget.arrivalTs - fireTs` (`:847`) — **positive ⇒ fired before true arrival ⇒ on time.**
   - `metersEarly = fx.alarmTarget.sProj - fireTrueS` (`:848`).
   - `ekfArcErrAtFire = |fireS - fireTrueS|` (`:849`).
   - `isLate = !fired || (secondsMargin.isFinite && secondsMargin < 0)` (`:390`).

##### The four tests (the actual gates)

- **TASK 1 — `NEVER-LATE GATE — all fixtures` (`:992`).** Runs `runReplay(b)` (primary scenario) over *every* discovered fixture, prints a combined scorecard, and hard-asserts `expect(late, isEmpty)` where `late = results.where((r) => r.isLate)`. **A ride fails the build if its destination alarm (mode=stops, N=2) ever fires after the true arrival time, or never fires at all.** 15-minute timeout.
- **TASK 2 — synthetic scenarios (`:1023`, `:1065`).** `PHANTOM_INJECT` freezes the last pre-window real fix and re-injects it every 2 s with an exponentially-decaying speed (`tau = 40 s`, `:754`) over a ~120 s mid-route window, then checks whether `s_est` kept advancing. `GAP_INJECT` drops *all* IMU+GPS for 60 s and 300 s to probe the `dt>1 s` reset. **Both are report-only** (`expect(r.window, isNotNull)` is the only assertion) — the code itself annotates the phantom baseline as *"expectation: FAIL — no phantom defense in current lib/"* (`:1058`).
- **TASK 3 — `COLD_START` (`:1099`).** Withholds *all* GPS. **Hard-gated:** `expect(r.fired, isTrue)` and `expect(r.isLate, isFalse)` — reachability must fire (early) from the seeded origin anchor even with zero GPS. Then a cross-check runs the same fixture with `useReachability: false` and asserts `expect(rNoReach.fired, isFalse)` — proving the fire genuinely came from the reachability layer and not the EKF.
- **TASK 4 — `REACHABILITY IS A MONOTONE SAFETY NET` (`:1144`).** For every fixture, runs reachability on and off and asserts `onT <= offT + 1e-6` (`:1160`). This empirically proves the integration's core safety property: because effective progress = `max(statistical, reachability)`, turning reachability *on* can only make the alarm fire **earlier**, never later. `expect(violations, 0)`.

---

### Key types & functions

**Engine (`imu_replay_engine_v2.dart`)**
- `ImuReplayEngineV2` — the simulator/replayer. Config fields: `gpsDropoutMode`, `warpFactor`, `deterministicReplay = true`, `enableImuNoise`, `logVerbosity`. Seeded `math.Random(42)` (`:594`) and `_fixedTickSeconds = 0.01` (`:595`).
- `TestRoute` / `TestRouteLeg` / `TestRouteStation` — route data model; `cumulativeMeters` gives arc-length; `TestRoute.legAtTime` / `allStations`.
- `ReplayTickResultV2` — the per-tick payload (position, bearing, speed, motion state, GPS position+accuracy+availability, raw accel/gyro, last/next station, `isZuptCandidate`, `isAtStation`).
- `LogParser` — static `parseLocationLog` / `parseImuLog` / `parseGravityLog` / `parseOrientationLog`; loads CSV from `rootBundle` assets.
- `_positionAtTime(elapsed)` (`:1819`) — ground-truth position by **linear-in-time** progress (`progress = elapsed / totalDurationSeconds`).
- `_computeGpsState(...)` (`:1967`) — the six-mode dropout simulator.
- `_tickLogReplay` (`:2248`) / `_tickUnifiedLogReplay` (`:2596`) — the recorded-data tick loops.
- `_finish()` (`:1603`) — idempotent end-of-run, fires `onFinished` once.

**Controller (`ekf_test_controller.dart`)**
- `EkfTestController` — dashboard glue. Holds `_engine`, `_ekfOrchestrator`, `_routeGeometry`, `_metrics`.
- `TestScenario` enum (`:30`) — 9 presets mapping to dropout-mode + warp + route.
- `EkfTestVisualization` (`:99`) — the per-frame map payload (true/gps/ekf positions, sigmas, trails, snapped stations, degraded flag).
- `EkfAlarmResult` (`:204`) — fire outcome with `leadErrorMeters` / `leadSeconds`.
- `_onTick` (`:833`) — the per-tick EKF-drive-and-visualize pipeline.
- `_evaluateAlarm(...)` (`:655`) — single-destination fallback alarm on EKF progress (visual only).

**Offline harness (`replay_harness_test.dart`)**
- `ScenarioConfig` / `ScenarioKind` (`:44`) — `primary` / `phantomInject` / `gapInject` / `coldStart`.
- `_Fixture`, `_StationAnchor`, `_ImuRow`, `_GpsRow` — parsed fixture model.
- `_GroundTruth.at(t)` (`:275`) — piecewise-linear time→arc-length truth.
- `RunResult` (`:314`) with `isLate` (`:390`) — the scored outcome.
- `_locationReplicaProcess(r, prev)` (`:406`) — hand-copied replica of `LocationManager.process` (100 m gate + speed sentinel).
- `runReplay(basename, {config, useReachability})` (`:442`) — the deterministic driver.
- `maybeEvaluateFire(t)` (`:594`) — real-evaluator fire probe with reachability bound.

---

### Design decisions (the WHY)

1. **The real gate reimplements its own driver instead of reusing `ImuReplayEngineV2`.** *What:* `replay_harness_test.dart` re-derives its own merge-sorted IMU/GPS loop, its own GPS-unavailable timeout, its own `noGyro` detection, and a hand-copied `_locationReplicaProcess`. *Why:* the dashboard engine carries UI baggage (Timers, stream controllers, wall-clock ticks, visualization payloads) that make it non-deterministic and slow; a test gate must be pure, fast, and reproducible, replaying recorded rows at their *own* timestamps with no clock. *Trade-off / FLAW:* the harness is a **replica** of production glue, not production glue. It cites exact production line numbers in comments (`location_manager.dart:305-344`, `sensor_fusion:140`) but those are copied by hand — if `LocationManager` or `SensorFusionManager` changes, the gate silently validates *stale* behavior. The one thing it does drive for real is the `EkfOrchestrator` + `AlarmEvaluator` + `ReachabilityTracker`, which is the load-bearing part.

2. **"Never-late" is measured in *time* against a recorded arrival, not in meters against an interpolated truth.** *What:* the gate's verdict is `secondsMargin = alarmTarget.arrivalTs - fireTs` (`:847`). *Why:* `arrival_t_s` is a real, recorded wall-time when the train reached the destination anchor; `fireTs` is in the same replayed clock. Comparing two real timestamps is airtight and immune to arc-length projection error. *Trade-off:* the *per-station* diagnostics (`s_err`, `metersEarly`) do rely on `_GroundTruth`, which is only piecewise-linear between station arrivals (§ decision 3) — but those are report-only, not the gate.

3. **Ground truth between stations is piecewise-linear (constant speed).** *What:* `_GroundTruth.at(t)` linearly interpolates arc-length between consecutive station arrivals. *Why:* station anchors (name, lat/lng, arrival time) are the only high-confidence truth you can extract from a recorded ride without a survey-grade reference; assuming constant speed between them is the simplest defensible fill. *Trade-off / FLAW:* real metro speed is not constant — it accelerates out of and brakes into every station — so mid-segment `s_true` can be off by tens of meters. This *understates* drift near stations and *overstates* it mid-run. It does not affect the time-based gate, but it makes the drift/RMSE numbers softer than reality.

4. **The gate tests exactly one alarm configuration: `mode: stops, userValue: 2`.** *What:* `maybeEvaluateFire` (`:607`) hardcodes a "fire 2 stops before the destination" stops-mode alarm. *Why:* it is the highest-stakes real configuration (metro rider counting stations) and it stresses the dangerous direction — if the EKF *under-estimates* progress, the fire is delayed and can go late, which the gate catches. *Trade-off / FLAW:* distance-mode and time-mode alarms, and other `userValue`s, are **not** gated by this file. A regression that only breaks never-lateness for `mode: distance` would pass here.

5. **Reachability is seeded at the origin with the loosest possible bound (`dwellMinSeconds: 0`).** *What:* `seedColdStart(sMeters: 0.0)` plus `ReachabilityConfig(dwellMinSeconds: 0.0)` and an inert topology cap. *Why:* the reachability net must be *unconditionally safe* — a lower bound on how far the train *could* have travelled given elapsed time and the line's max speed. `dwellMinSeconds: 0` (assume zero dwell) is the fastest-possible-train assumption, which makes the bound an over-estimate of progress that can only fire the alarm *early*. This is what mathematically guarantees the monotone-safety-net property (decision proven empirically in TASK 4) and closes GLMT-03 (cold-start never-fire). *Trade-off / FLAW:* the loosest bound is also the *most aggressive* — in a genuine cold start with zero GPS it can fire the alarm very early, potentially far from the actual stop. **The gate only checks never-*late*; it does not check never-*early* or never-at-the-wrong-place.** An over-eager cold-start reachability fire that wakes the rider two stations too soon would still PASS every test in this file. That is a real gap against the *full* core promise (see Gaps).

6. **Phantom-injection and gap-injection are report-only, not gated.** *What:* TASK 2's phantom and gap tests only `expect(r.window, isNotNull)`; the phantom test literally documents *"baseline expectation: FAIL — no phantom defense in current lib/"* (`:1058`). *Why:* these probe a *known-unresolved* failure mode (a frozen "confident" GPS fix that stalls EKF progress) that the team wanted visibility into without red-flagging the whole build while the fix is in flight. *Trade-off / FLAW:* a stuck/frozen fix that drags EKF progress backward or freezes it is one of the most direct never-late threats (the rider sails past the stop while the estimate sits still), and right now nothing in the gate *fails* on it. It is measured, not enforced.

7. **Determinism everywhere, achieved two different ways.** *What:* the engine uses `deterministicReplay = true` (fixed 0.01 s step, seeded `Random(42)`); the offline harness uses no RNG at all and replays recorded rows at their own timestamps inside a print-swallowing `runZoned` (`:819`). *Why:* a validation harness whose numbers wander run-to-run is worthless — you cannot tell a real regression from noise. *Trade-off:* the engine's determinism is *wall-clock-decoupled* but the playback `Timer` still fires on the real 10 ms clock, so on a slow machine the dashboard path can visually stutter (it does not affect the math, since dt is fixed). The offline harness is fully time-independent and is the trustworthy one.

8. **IMU is fed to the EKF from a dedicated high-rate stream, not the tick stream.** *What:* `_subscribeToEngineImu` (`:597`) wires `imuSampleStream` straight into `orchestrator.onImuSample`, bypassing `_onTick`. *Why:* dead reckoning integrates acceleration; starving the EKF of IMU (feeding it only at the sparse visualization tick rate) would cripple the very thing being validated. *Trade-off / FLAW (log path):* in `_tickLogReplay`, a combined `ImuSample` is only emitted when a *gyro* row arrives, pairing it with the last-held accel (`:2289`). If the recording's gyro rate differs from its accel rate, or gyro is absent, accel samples are dropped or time-mismatched with gyro — the fused sample's two halves come from different instants.

9. **Synthetic-route position is decoupled from synthetic-route IMU.** *What:* `_positionAtTime` is pure linear-in-time interpolation (`:1825`), while `_generateAccelerometer` emits only ±0.5–0.8 m/s² motion terms plus noise and `_generateGyroscope` emits **only noise** (with a `TODO: Calculate actual angular velocity from bearing changes`, `:2119`). *Why:* the synthetic routes were built for quick visual smoke-testing of GPS-dropout handling and station snapping, not for physically-faithful dead-reckoning validation. *Trade-off / FLAW:* on synthetic routes the emitted IMU does **not** integrate to the ground-truth trajectory — the accelerations are far too small to produce the implied speed changes, and there is no turn signal at all. So any EKF drift measured on a *synthetic* route is meaningless for dead reckoning. Only the **recorded-fixture** path (real IMU) validates dead reckoning honestly. This is the single most important caveat about the dashboard half of the subsystem.

10. **Bengaluru-only hard bounds in polyline decoding.** *What:* `_decodePolyline` (`:803`) silently drops any decoded point outside lat 12–14, lng 77–78 (`:843`). *Why:* to strip garbage points from occasional Google-polyline decode corruption in the captured routes. *Trade-off / FLAW:* it is hardcoded to Bengaluru. Feed this engine a Delhi or Mumbai captured route and it will silently delete the entire polyline, producing an empty route. Acceptable for a Bengaluru-fixtures test harness, but a latent trap if the fixtures ever expand to other cities.

11. **`tunnelSimulation` near-station GPS condition looks buggy.** *What:* `_computeGpsState` (`:2001`) gates GPS on `metersToNext < 50 || metersToNext > (next.cumulativeMeters - 50)`. *Why (intended):* emit GPS only in a ~50 m bubble around each station. *FLAW:* the second clause compares a *remaining-distance* (`metersToNext`) against an *absolute cumulative arc-length minus 50* — dimensionally inconsistent. For any station past ~50 m into the route this clause is almost always true, so GPS is emitted far more than "only near stations." This is a dashboard-only cosmetic bug (it does not touch the offline gate), but it means the tunnel visualization does not faithfully model an underground blackout.

---

### Invariants

- **Offline gate:** for every fixture in the primary scenario, `fired == true` and `secondsMargin >= 0` (i.e. `isLate == false`). This is the hard build gate (TASK 1).
- **Cold start:** with zero GPS, reachability alone must produce `fired == true` and `isLate == false`; and with reachability disabled the same run must produce `fired == false` (TASK 3).
- **Monotonicity:** `fireTs(reachability=on) <= fireTs(reachability=off) + 1e-6` on every fixture (TASK 4). Reachability may only advance a fire.
- **Determinism:** identical fixtures ⇒ identical `RunResult` across runs (no RNG in the harness driver; engine uses seed 42).
- **Read-only:** the harness never mutates anything under `lib/` and never writes fixtures; `_readHeader` even tolerates a fixture being mid-write by the coordinator (`:156`).
- **`_finish()` fires `onFinished` at most once** (engine, `:1604`).
- **Reachability re-anchors only on *real* accepted fixes**, never on phantom-injected ones (`:800`) — otherwise a phantom would poison the safety net.

---

### Interfaces

**Consumes (drives the real production code):**
- `EkfOrchestrator` (`lib/core/ekf/ekf_orchestrator.dart`) — `onImuSample`, `onGpsFixAuto`, `onGpsUnavailable`, `setStationContext`, `setNoGyro`, `forceZupt`, `reset`, `publicState`, `onStationSnapConfirmed`, and the diagnostics `gpsDegraded` / `predictionEnabled` / `currentMotionState` / `currentAccelVariance` / `currentGyroVariance`.
- `AlarmEvaluator.evaluateCoinciding` (`lib/services/alarm_evaluator.dart:50`) — the real fire decision, including `reachableProgressBoundMeters`, `fractileK`, and the sigma cushion inputs.
- `RouteGeometry` (`lib/core/ekf/route_geometry.dart`) — `fromPoints`, `projectLatLng`, `positionAt`, `totalLengthMeters`.
- `ReachabilityTracker` / `ReachabilityConfig` / `RouteTopology` / `VLineTable` (`lib/core/reachability/reachability.dart`) — `seedColdStart`, `onAcceptedFix`, `boundNow` → `ReachabilityBound.sMaxMeters`.
- `EkfMetrics` (`lib/core/ekf/ekf_metrics.dart`) — `update`, `reset`, `currentError`, `maxDrift`, `rmse`, `maxBlackoutError`.
- `FireDecisionConfig` (`lib/config/fire_decision_config.dart`) — `defaultAccuracyGateMeters = 100.0`, `fractileK = 2.0`.
- `TransitLegStops` / `RouteEventBoundary` / `AlarmMode` / `AlarmEventType` / `AlarmTrigger` (`lib/services/transfer_utils.dart`, `alarm_evaluator.dart`).
- `ekf_types.dart` — `ImuSample`, `GpsFix`, `GravitySample`, `OrientationSample`, `EkfPublicState`, `EkfMode`, `MotionState`.
- Assets: `assets/ekf_test_routes/bengaluru_metro_routes.json`, `assets/ekf_test_routes/captured_route.json`, `assets/logs/...`, `lib/all_india_stops.dart` (for `_findAndSnapStations`).
- External fixtures: `/home/raed/geowake_imu_analysis/fixtures/*` (offline gate only).

**Exposes:**
- Engine → streams (`accelerometerStream`, `gyroscopeStream`, `gpsStream`, `imuSampleStream`, `gravityStream`, `orientationStream`, `tickStream`, `logStream`) and `onFinished`.
- Controller → `EkfTestVisualization` (to the dashboard UI), `EkfTestLogEntry`, `EkfStateSnapshot`, `EkfAlarmResult`, plus injectable `gpsStream`/`accelerometerStream`/`gyroscopeStream` for a legacy `TrackingService` path, and metrics getters (`ekfRmse`, `ekfMaxDrift`, `ekfMaxBlackoutError`, `alarmFired`).
- Offline harness → `RunResult` scorecards on stdout and `flutter test` pass/fail.

---

### Gaps & flaws vs the core promise

1. **The gate cannot run anywhere but this one machine.** The fixtures directory is a hardcoded absolute path outside the repo (`replay_harness_test.dart:38`) holding large binaries that are not version-controlled. On CI or any other developer's machine `discoverFixtures()` returns `[]`, TASK 1 fails on `expect(fixtures, isNotEmpty)`, and TASKS 2–3 *silently skip*. The single most important safety gate GeoWake has is **not reproducible and not in CI** — it is a manual, local ritual. This is a blocker for trusting "never-late" as an ongoing guarantee rather than a one-time observation.

2. **"Never-early / never-at-the-wrong-place" is completely unenforced.** Every test here checks only that the alarm is not *late*. Nothing fails when it fires absurdly *early* — and the reachability net is deliberately tuned to the loosest (earliest-firing) bound (decision 5). Half of the core promise ("never at the wrong place") has no gate in this subsystem. An aggressive cold-start fire that wakes the rider stations too soon is invisible to the harness.

3. **Phantom-fix defense is a known hole, measured but not gated.** The code openly expects the phantom scenario to FAIL in current `lib/` (`:1058`). A frozen "confident" GPS fix (common in urban canyons / tunnel mouths on cheap Android GPS chips — exactly the target hardware) can stall or drag EKF progress; the rider then overshoots the stop. This is a direct never-late threat that the gate reports on but does not block. The HANDOFF/commit history ("Nallur spike + cold-start unresolved") corroborates that this class of bug is still open.

4. **Synthetic routes do not validate dead reckoning.** On the dashboard's synthetic path, the emitted IMU is decoupled from the emitted trajectory (decision 9), and the gyro is pure noise. Any confidence drawn from "the EKF tracked well on the synthetic metro route" is false confidence for the underground-GPS-dead scenario. Only the recorded-fixture path (real IMU) is trustworthy for the core promise, and there are a finite, Bengaluru-only set of those fixtures.

5. **The harness validates a *replica* of the ingest path, not the real one.** `_locationReplicaProcess`, the GPS-unavailable timeout, and `noGyro` detection are hand-copied from production with line-number comments. There is no compile-time link, so production can drift from the replica and the gate would keep passing against outdated logic. The EKF/evaluator/reachability core *is* real, but the sensor front-end around it is a stand-in.

6. **Only one alarm mode and a fixed device/line set are gated.** `mode: stops, N=2` on a handful of Bengaluru Purple/Green-line rides. The promise is "a transit rider in India" broadly; distance/time alarms, other cities, non-metro legs, and other phones are not represented in the gate. Coverage breadth is a medium gap: the mechanism is sound but the empirical evidence is narrow.

7. **Metric ground truth is soft near stations.** Because truth is piecewise-linear between station arrivals (decision 3), the drift/RMSE/`maxBlackoutError` numbers — the very numbers a reviewer would cite as "the EKF is accurate underground" — are systematically optimistic through the acceleration/braking zones around each stop, which is precisely where the alarm fires. The time-based gate is unaffected, but the reassurance numbers are softer than they look.

8. **Dashboard tunnel simulation is dimensionally buggy (decision 11)** so the on-screen "underground blackout" demo emits far more GPS than a real tunnel would — a reviewer eyeballing the dashboard could conclude dead reckoning is healthier than the offline gate proves.
