# 07 — Location Acquisition, GPS Gate & Sensor Fusion

**Role in the core promise:** This subsystem is the *front door* through which every GPS fix enters GeoWake. Before any alarm logic, ETA, snap-to-route, or EKF can run, a position must be acquired from the phone, sanity-checked, speed-normalized, and either accepted or rejected. It also feeds the raw accelerometer/gyroscope stream that keeps the Extended Kalman Filter (EKF) dead-reckoning alive when GPS dies underground. In plain terms: **if this layer lets a garbage fix through, the rider gets woken at the wrong place; if it wrongly rejects good fixes or drops the sensor feed, the rider gets woken late or not at all.** Everything downstream trusts the `Position` objects that come out of here, so the correctness of the whole "never late, never wrong place" guarantee starts at this gate.

---

## Files

| Path | What it does |
|---|---|
| `lib/services/location_manager.dart` | **The live production location source.** Singleton that owns the real GPS stream *and* the simulation stream, merges them into one `positionStream`, derives/smooths speed, and enforces the G27 accuracy gate + G28 OS-location-service watchdog. This is what `LocationStreamHandler` actually listens to. |
| `lib/services/sensor_fusion.dart` | `SensorFusionManager` — bridges raw IMU (accelerometer + gyroscope via `sensors_plus`) and GPS fixes into the EKF (`EkfOrchestrator`). Exposes `ekfStateStream` (the progress estimate used during blackouts). Also contains a **legacy dead-reckoning integrator** that feeds `fusedPositionStream` (see flaws — this path is vestigial). |
| `lib/services/gps_health_monitor.dart` | `GpsHealthMonitor` — a 3-state (healthy/degraded/unavailable) GPS-health classifier with hysteresis. **Not wired into production** (only exercised by its unit test). Documented here because it is assigned and because its *absence* from the live path is itself a finding. |
| `lib/services/position/position_provider.dart` | Abstract `PositionProvider` interface (start/stop/reset/positionStream/uncertainty/isEstimated) + `PositionProviderType` enum. Intended to let GPS/EKF/simulated sources be swapped uniformly. **Not used by the live tracking path.** |
| `lib/services/position/gps_position_provider.dart` | `GpsPositionProvider` — a clean `PositionProvider` implementation over `geolocator`, including the **correct iOS background-location settings** (`AppleSettings.allowBackgroundLocationUpdates`). **Never instantiated in production** — dead code. |
| `lib/services/position/position_providers.dart` | Barrel export for the `position/` package. Notes that `EkfPositionProvider` (Phase 6) was never implemented. |

> **Headline for the founder:** two of the six files (`gps_health_monitor.dart`, the entire `position/` package) are **not on the live code path**. The real production chain is `LocationManager → LocationStreamHandler → SensorFusionManager → EkfOrchestrator`. The nice abstractions were built and then bypassed. Details in *Gaps & flaws*.

---

## How it works, step by step (the atomic walkthrough)

### A. Acquisition — `LocationManager.start()` (`location_manager.dart:70`)

`LocationManager` is a **singleton** (`_instance`, factory at line 14-16). `LocationStreamHandler.start()` calls `LocationManager().start()` (`location_stream_handler.dart:212`) and then subscribes to `LocationManager().positionStream` (line 214).

`start()` does three things:

1. **`stop()` first** (line 74) — cancels any existing subscriptions and resets all speed state to null (lines 116-120). Idempotent restart.
2. **`_startRealGps()`** (line 77 → 126) — opens `Geolocator.getPositionStream(locationSettings: _locationSettings)`. The settings are a hard-coded `const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0)` (lines 62-65). `distanceFilter: 0` means *every* fix is delivered (needed so the speed smoother sees a continuous signal). Each fix lands in `_onRealPosition` (line 209).
3. **G28 service watchdog** (lines 82-96) — subscribes to `Geolocator.getServiceStatusStream()`. When the user toggles the OS Location switch mid-journey, it fires `onServiceStatusChanged(enabled)`. Skipped when `isTestMode` to avoid platform channels.
4. **`_connectSimulation()`** (line 99 → 143) — subscribes to `SimulationClient.positionStream`. The *first* simulated position auto-flips the manager into `_isSimulationMode = true` (line 148-160), calls `onAlarmReset` so a previous session's fired-leg IDs don't carry over, and thereafter **real GPS is ignored** (`_onRealPosition` early-returns at line 211-213). Disconnect resets back to real GPS (lines 189-196).

So there is exactly **one output stream** (`_positionController`, a broadcast controller, line 24) carrying whichever source is active. Consumers can't tell real vs. simulated apart except via the value stream — which is the whole point (deterministic replay/dev dashboard drives the *same* pipeline as real GPS).

### B. The processing pipeline — `_processPosition(pos, isSimulated)` (`location_manager.dart:217`)

Every fix (real or simulated) flows through four numbered stages:

**Stage 1 — Speed derivation (lines 221-255).** Computes `dtSeconds` = time since last kept fix and `dMeters` = `Geolocator.distanceBetween(...)` (great-circle). Then:
- **Jitter floor:** treats movement smaller than the accuracy radius as noise. `jitterMeters = isSimulated ? 0.0 : (acc * 0.6).clamp(3.0, 30.0)` (line 239-240). If `acc` isn't finite it defaults to 25 m.
- **Minimum dt:** `minDt = isSimulated ? 0.05 : 0.8` seconds (line 242) — real GPS needs 0.8 s between samples before it trusts a speed, sim needs only 0.05 s.
- Only if `dtSeconds >= minDt && dMeters >= jitterMeters` does it compute `raw = dMeters/dtSeconds` and **clamp to `[0, 40] m/s`** (line 246). 40 m/s = 144 km/h, the sane upper bound so a GPS teleport can't make ETA collapse to zero.

**Stage 2 — Choosing between platform speed and derived speed (lines 260-291).** The platform (`pos.speed`) is preferred but distrusted:
- If both platform and derived exist: use `min(platform, derived)` (conservative) **unless** platform looks stuck (`< 0.5 m/s`) while derived says real motion (`> 1.5 m/s`) — then use derived (lines 271-276). This catches the common Android bug where `pos.speed` reports 0 on a moving vehicle.
- **Acceleration spike guard (lines 283-291):** caps the new speed at `_speedEmaMps + (3.0 m/s² × dt) + 1.0`, clamped to `[0,40]`. A jump implying > 3 m/s² acceleration is rejected as noise.

**Stage 3 — EMA smoothing (lines 293-303).** `_speedEmaMps = 0.8·old + 0.2·new` (alpha = 0.2). First sample seeds the EMA directly. `currentSpeedMps` getter (line 43) exposes the smoothed value.

**Stage 4 — G27 accuracy gate (lines 311-327).** *This is the safety-critical filter.* For **real** fixes only (sim bypasses):
- `approximate = acc > FireDecisionConfig.approximateLocationAccuracyMeters` (500 m, `fire_decision_config.dart:26`) — flags coarse Android "approximate location".
- `gate = accuracyGateMeters ?? FireDecisionConfig.defaultAccuracyGateMeters` (100 m, `fire_decision_config.dart:30`). `accuracyGateMeters` is set by `TrackingService` from the active alarm threshold.
- If `!acc.isFinite || acc > gate`: **the fix is dropped** (`return` at line 326) after firing `onGpsAccuracyRejected(acc, approximate)`. It is *not* emitted, so downstream sees a GPS gap and the EKF/dropout logic takes over.

**Emit (lines 331-344):** builds a new `Position` copying all fields but replacing `speed` with `normalizedSpeedMps`, and adds it to `_positionController`. Downstream now sees a consistent speed signal for both real and simulated runs.

### C. Downstream fan-out (in `LocationStreamHandler`, the consumer)

`_handlePositionUpdate` (`location_stream_handler.dart:224`) on each emitted `Position`:
1. Records `_lastGpsUpdate = now` (line 232) — the freshness clock used by the dropout timer.
2. Throttled `LocationManager().broadcastPosition(...)` to the dev dashboard (≤1/sec).
3. `_ensureFusionManager(position, ctx)` then `_sensorFusionManager?.updateGps(position)` (lines 251-252) — pushes the fix into the EKF.

**GPS dropout detection is done by `LocationStreamHandler`, not `GpsHealthMonitor`.** `_startGpsCheckTimer` runs a periodic tick → `_checkGpsDropout` (line 531): if `now - _lastGpsUpdate >= gpsDropoutBuffer`, it calls `_ensureFusionManagerPosition(...)` to keep dead-reckoning warm. `gpsDropoutBuffer` comes from the battery power policy (default 5 s, up to ~25 s), set at line 204.

### D. Sensor fusion — `SensorFusionManager` (`sensor_fusion.dart`)

Constructed by `LocationStreamHandler._ensureFusionManager` (`location_stream_handler.dart:614`) with `enableEkf: geometry != null` — i.e. the EKF only runs once a route geometry exists. Two data paths live inside:

**Path 1 — IMU → EKF (the live one).** `startFusion()` (line 193):
- Starts an `_imuClock` (`Stopwatch`) as the monotonic time base for all EKF timestamps (line 195). Using a stopwatch instead of wall-clock avoids NTP/clock-skew jumps corrupting dt.
- Subscribes to `accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)` (~50 Hz) and `gyroscopeEventStream` (lines 204-319). Both `.handleError((_){})` and `cancelOnError: true` so a missing sensor plugin (unit tests, exotic phones) degrades to "no fusion" rather than crashing.
- **G21 no-gyro detection (lines 254-262):** counts accel samples; if 100 arrive (~2 s) with no gyro sample ever seen, it declares `ekf.setNoGyro(true)`. Why: a phone with no gyroscope looks "perfectly still" to a ZUPT (zero-velocity) detector and would wrongly freeze progress. Telling the EKF keeps its σ floor honest (wider → fires the alarm *earlier*, which is the safe direction).
- **E1 GPS-silence → EKF degrade (lines 274-281):** on each IMU sample, if `(now - _lastGpsFixTs) > 3 s` (`_noFixDegradeThreshold`, line 189), throttled to every 500 ms, it calls `ekf.onGpsUnavailable(timestamp)` so the filter enters DEGRADED dead-reckoning with honest covariance growth. `_lastGpsFixTs` is only refreshed by a **valid on-route** GPS fix (see `updateGps` below).
- Feeds each sample via `ekf.onImuSample(ImuSample(ax..az, gx..gz, timestamp))`, then republishes `ekf.publicState` on `_ekfStateController` (lines 282-294). That `EkfPublicState` (progress `s`, velocity `v`, `sigmaS`, `mode`, ...) is what the alarm evaluator uses during blackouts.

**`updateGps(position)` (line 132):** projects the lat/lng onto the route (`_routeGeometry.projectLatLng`). Only if the projection `sGps` is **finite** does it refresh `_lastGpsFixTs` (line 151) — an off-route/phantom fix that projects to NaN must *not* count as "GPS alive" (comment E1, lines 145-150). It sets station context for the current leg, then calls `ekf.onGpsFixAuto(GpsFix(...))` which internally does frozen-phantom + off-route rejection.

**Path 2 — legacy strap-down integrator (lines 228-245).** Inside the same accel callback it also maintains `_velX/_velY/_posX/_posY` by damped double-integration of raw accelerometer, converts to a lat/lng delta, and emits on `fusedPositionStream`. It resets every `maxFusionDuration = 10 s` (lines 218-226) to bound drift. **This path is vestigial** (see flaws): nobody in `lib/` consumes `fusedPositionStream`, and the math is physically unsound.

### E. `GpsHealthMonitor` (`gps_health_monitor.dart`) — the road not taken

A clean state machine: `ingestGpsUpdate(position)` stamps `_lastGpsUpdate`/`_lastAccuracy` and `_evaluateState`; `tick()` re-evaluates on a timer for silence detection. Thresholds: `degradedThreshold = 10 s`, `unavailableThreshold = 25 s`, `poorAccuracyMeters = 50 m`, plus `sustainedDegradationRequired = 5 s` hysteresis so a single bad fix doesn't flip the state. It publishes on `stateStream`. **It is never instantiated in `lib/`** — the production dropout logic instead lives in `LocationStreamHandler` (5–25 s buffer) and `SensorFusionManager` (3 s E1 threshold), using *different* numbers.

---

## Key types & functions

| Type / function | Signature | Responsibility |
|---|---|---|
| `LocationManager` (singleton) | `factory LocationManager()` | Owns the merged real+sim position stream; the live source of truth. |
| `LocationManager.positionStream` | `Stream<Position> get` | The one output every consumer subscribes to. |
| `LocationManager.start/stop` | `Future<void>` | Open/close GPS + sim + service-status subscriptions; reset speed state. |
| `LocationManager._processPosition` | `void (_, {required bool isSimulated})` | The 4-stage pipeline: speed derive → source select → EMA → accuracy gate → emit. |
| `LocationManager.injectPosition` | `void (Position)` | Test/internal hook; forces sim mode and pushes a fix through the pipeline. |
| `LocationManager.currentSpeedMps` | `double get` | Smoothed EMA speed for ETA/UI. |
| `LocationManager.accuracyGateMeters` | `double? field` | G27 gate override, set by `TrackingService`. |
| `LocationManager.onGpsAccuracyRejected` | `void Function(double acc, bool approximate)?` | Callback when a fix is dropped by the gate. |
| `LocationManager.onServiceStatusChanged` | `void Function(bool enabled)?` | G28 OS location toggle callback. |
| `SensorFusionManager` | ctor `{required LatLng initialPosition, streams?, RouteGeometry?, bool enableEkf}` | IMU↔GPS↔EKF bridge. |
| `SensorFusionManager.updateGps` | `void (Position)` | Project fix, gate GPS-alive clock, feed `onGpsFixAuto`. |
| `SensorFusionManager.startFusion` | `void ()` | Subscribe IMU streams; drive EKF; G21 no-gyro + E1 degrade logic. |
| `SensorFusionManager.ekfStateStream` | `Stream<EkfPublicState> get` | Progress estimate used during blackouts. |
| `SensorFusionManager.updateRouteGeometry` | `void (RouteGeometry?)` | Rebuild orchestrator on route change; null disables EKF. |
| `SensorFusionManager.fusedPositionStream` | `Stream<LatLng> get` | **Vestigial** legacy DR output; no live consumer. |
| `GpsHealthMonitor.ingestGpsUpdate / tick` | `void (Position)` / `void ()` | Classify health; **unused in prod**. |
| `GpsHealthMonitor.stateStream` | `Stream<GpsHealthState> get` | healthy/degraded/unavailable transitions. |
| `PositionProvider` (abstract) | interface | Uniform start/stop/reset/uncertainty/isEstimated contract; **unused in prod**. |
| `GpsPositionProvider` | `implements PositionProvider` | Clean geolocator wrapper w/ correct iOS background settings; **never instantiated**. |

---

## Design decisions (the WHY)

1. **`LocationManager` is a global singleton merging real GPS and simulation into one stream.**
   *Why:* the dev dashboard / replay harness must drive the *exact same* pipeline as real GPS so a bug reproduced in replay is the real bug. One stream, one code path.
   *Trade-off:* global mutable singleton state is hard to test in isolation and impossible to run two independent trackers. The `isTestMode` static flag (line 19) is a smell that leaks test concerns into production code.
   *Flaw:* the "first sim position silently takes over and ignores real GPS" behavior (lines 211-213) is a hidden mode switch. If a stray `SimulationClient` connection appears in the field, real GPS is silently muted for the rest of the session — a foot-gun for the core promise.

2. **`distanceFilter: 0` on the real GPS stream (accept every fix).**
   *Why:* the EMA speed smoother and the EKF both want a dense, regular signal; filtering by distance would starve them when the vehicle is slow or stopped.
   *Trade-off:* higher battery drain and more noise to filter. On a cheap Android phone with a weak GPS chip this produces more jitter, which is exactly why Stages 1-3 exist.

3. **Speed is *re-derived* from position deltas rather than trusting `pos.speed`.**
   *Why:* Android's platform speed is notoriously unreliable — often stuck at 0 on moving vehicles or spiking on multipath. Deriving `distance/dt` and taking `min(platform, derived)` (with the stuck-at-zero override) is more robust.
   *Trade-off:* derived speed is noisier at low dt and depends on position accuracy; the jitter floor and clamps are heuristics tuned by feel, not proven.
   *Flaw:* the constants (0.8 s minDt, 40 m/s cap, `acc*0.6` jitter, 3 m/s² accel cap, alpha 0.2) are magic numbers with no test coverage that pins them. A fast train (>144 km/h) would have its speed silently capped at 40 m/s, making ETA pessimistic (arguably safe, but wrong).

4. **G27 accuracy gate drops fixes worse than 100 m (default) / alarm-derived threshold.**
   *Why:* an Android "approximate location" fix can be 1–3 km off. Snapping/alarm on such a fix would place the rider wildly off-route and fire at the wrong place. Better to treat a bad fix as *no fix* and let EKF dead-reckon.
   *Trade-off:* in a genuinely bad-GPS city core, *most* fixes may exceed the gate, so the app leans hard on EKF dead-reckoning for long stretches — pushing risk onto the EKF's drift.
   *Flaw:* the gate is applied **only in `LocationManager`**, but a copy of the raw fix still reaches the EKF via a different path? No — the EKF is fed from the *gated* `positionStream`, so this is consistent. However, `approximate` is computed against 500 m while the gate is 100 m; a fix at 200 m is dropped but not flagged "approximate", so the UI/telemetry distinction is coarse.

5. **G28 OS-location-service watchdog.**
   *Why:* if the user disables Location mid-journey, `getPositionStream` goes permanently silent with no error. The watchdog surfaces this so the app can warn the rider instead of failing silently — directly protecting "never late."
   *Trade-off:* none significant; it's a pure observation callback. It is skipped in test mode.

6. **IMU timestamps come from a `Stopwatch` (`_imuClock`), not wall-clock.**
   *Why:* the EKF integrates over dt; a wall-clock jump (NTP sync, timezone, user clock change) would inject a huge phantom dt and blow up the filter. A monotonic stopwatch is immune.
   *Trade-off:* stopwatch time and GPS timestamp time live in different clocks; reconciling them relies on the orchestrator, not this layer.

7. **G21: declare "no gyroscope" after 100 accel samples with no gyro.**
   *Why:* budget Indian phones often ship without a gyro. Missing gyro reads as "perfectly quiet," which would over-trigger ZUPT and freeze progress → rider never woken. Telling the EKF widens its σ floor so the critical-fractile fires *earlier* (safe direction).
   *Trade-off:* the 100-sample (~2 s) window is a guess; a gyro that's merely slow to start could be misclassified once. It's a one-way latch per session (`_noGyroDeclared`).

8. **E1: refresh the "GPS alive" clock only on a valid *on-route* fix.**
   *Why:* a burst of off-route/phantom fixes (projection → NaN) would otherwise keep resetting the clock and stop the EKF from ever entering degraded dead-reckoning — even though none of those fixes actually update the filter. Gating on a finite projection fixes that.
   *Trade-off:* a rider legitimately off the modeled route (reroute not yet applied) will be treated as "GPS silent" and dead-reckoned along the *old* route — which can be wrong until the reroute lands.

9. **EKF is only enabled when a `RouteGeometry` exists (`enableEkf: geometry != null`).**
   *Why:* the EKF here tracks **1-D progress along a known route**, not free 2-D position. With no route there's nothing to project onto.
   *Trade-off:* before a route is chosen, or if geometry fails to build, there is **no dead-reckoning at all** — a GPS blackout in that window means total blindness. The legacy strap-down path (which *could* give a crude 2-D estimate) is not used as a fallback.

10. **Keep sensor fusion running continuously (no stop when GPS returns).**
    *Why (per comment `location_stream_handler.dart` around fusion):* restarting fusion on every GPS recovery causes "cold starts" where the filter re-converges from scratch, briefly producing bad estimates. Keeping it warm avoids that.
    *Trade-off:* continuous IMU sampling at ~50 Hz drains battery — mitigated only indirectly via the `_fftEnabled = batteryLevel >= 20` toggle.

---

## Invariants

- **Single output stream:** all consumers see positions only via `LocationManager().positionStream`; no consumer reads `Geolocator` directly on the live path.
- **Speed monotonic-ish:** emitted `Position.speed` is always finite, in `[0, 40] m/s`, and cannot jump by more than `3·dt + 1` m/s per fix relative to the prior EMA.
- **Gate is one-directional:** a real fix with `accuracy > gate` (or non-finite) is *never* emitted; simulated fixes are *never* gated.
- **Sim overrides real:** once `_isSimulationMode && _simulationPositionsReceived`, real GPS is dropped until disconnect.
- **EKF time base is monotonic:** every `ImuSample`/`GpsFix` timestamp derives from `_imuClock.elapsedMicroseconds`; wall-clock is only a fallback when the stopwatch is null.
- **`_lastGpsFixTs` reflects only on-route validity:** it advances solely on a finite route projection.
- **EKF existence ⇔ route geometry:** `_ekfOrchestrator != null` iff `_enableEkf && _routeGeometry != null` (enforced in ctor and `updateRouteGeometry`).

---

## Interfaces

**Consumes:**
- `geolocator` — `Geolocator.getPositionStream`, `getServiceStatusStream`, `distanceBetween`, `Position`, `LocationSettings`.
- `sensors_plus` — `accelerometerEventStream`, `gyroscopeEventStream`.
- `SimulationClient` (`simulation_client.dart`) — sim position stream + broadcast delegation + `onFirstPositionReceived`/`onDisconnected`/`onAlarmReset` callbacks.
- `FireDecisionConfig` (`config/fire_decision_config.dart`) — `approximateLocationAccuracyMeters` (500), `defaultAccuracyGateMeters` (100).
- `EkfOrchestrator` + `ekf_types` + `route_geometry` (`core/ekf/*`) — `onGpsFixAuto`, `onImuSample`, `onGpsUnavailable`, `setStationContext`, `setNoGyro`, `setFftEnabled`, `publicState`, `EkfPublicState`, `GpsFix`, `ImuSample`, `StationSnapConfirmed`, `RouteGeometry.projectLatLng`.
- `TransitLegStops` (`services/transfer_utils.dart`) — per-leg station meters / metro flag.

**Exposes / exposed-to:**
- `LocationStreamHandler` (`services/tracking/location_stream_handler.dart`) — the primary consumer: subscribes to `positionStream`, owns `SensorFusionManager`, runs the real dropout timer, and forwards `ekfStateStream` via `onEkfUpdate`.
- `TrackingService` — sets `accuracyGateMeters`, handles `onGpsAccuracyRejected` / `onServiceStatusChanged`, and consumes `EkfPublicState` for alarm evaluation.
- Dev dashboard — via `broadcastPosition/broadcastState/broadcastRoute` delegation to `SimulationClient`.

---

## Gaps & flaws vs the core promise

1. **`GpsHealthMonitor` is dead code; dropout detection is duplicated and inconsistent.** The well-designed 3-state monitor with 10 s/25 s/50 m thresholds and 5 s hysteresis is only touched by its own test. Production instead uses (a) `LocationStreamHandler`'s 5–25 s `gpsDropoutBuffer` and (b) `SensorFusionManager`'s 3 s E1 threshold — two different clocks with two different numbers, neither with hysteresis. **Risk:** the "when do we stop trusting GPS?" decision is scattered, undocumented as a single source of truth, and the numbers can drift apart. This is a correctness-of-timing risk for "never late."

2. **The entire `position/` package (`PositionProvider` / `GpsPositionProvider`) is unused, and it holds the *correct iOS background settings that the live path lacks*.** `GpsPositionProvider` sets `AppleSettings(allowBackgroundLocationUpdates: true, pauseLocationUpdatesAutomatically: false, ...)` and its own docstring calls this "load-bearing, not cosmetic" for tracking through a locked-phone blackout. But production uses `LocationManager`, whose settings are a plain `const LocationSettings(accuracy: high, distanceFilter: 0)` with **no iOS background flags**. **On iOS the live location stream can silently stop delivering the moment the app is backgrounded** — a direct defeat of the core promise. (The stated target is cheap Android, so this may be out-of-scope today, but it's a latent trap the moment iOS ships.) Also note the filter mismatch: dead code uses `distanceFilter: 5`, live uses `0`.

3. **`SensorFusionManager`'s legacy strap-down integrator is physically unsound and pointless.** Lines 228-245 double-integrate **raw device-frame accelerometer** (`event.x`, `event.y`) directly into an ENU lat/lng displacement — with **no gravity removal and no rotation from device frame to world frame**. That means a phone lying flat integrates ~9.8 m/s² of gravity as horizontal motion; a tilt re-projects gravity arbitrarily. The result on `fusedPositionStream` is noise. It's harmless *only because nothing in `lib/` consumes that stream* — but it still burns CPU every ~50 Hz sample and is a trap for a future dev who wires it up thinking it's a real fallback.

4. **No 2-D dead-reckoning fallback before a route exists.** EKF progress tracking requires a `RouteGeometry`. In the window between "tracking started" and "route geometry built," or if geometry fails, a GPS blackout leaves the app with *zero* position estimate. For a rider who starts the app already inside a tunnel-adjacent station, this is a blind spot.

5. **Magic-number heuristics with no pinning tests.** The speed pipeline (0.8 s minDt, 40 m/s cap, `acc*0.6` jitter clamp `[3,30]`, 3 m/s² accel guard, alpha 0.2) and the fusion thresholds (10 s max-fusion reset, 3 s E1, 100-sample no-gyro, 500 ms E1 throttle) are all hand-tuned constants. There is no test that fails if someone changes them, so silent regressions in "how fast we detect motion / dropout" are possible — and those directly affect wake timing.

6. **Hidden sim takeover mutes real GPS for the session.** Any `SimulationClient` position flips `_isSimulationMode` on and real GPS is ignored until disconnect (`location_manager.dart:211-213`). In production this should never trigger, but there's no guard preventing a rogue/stale WebSocket from hijacking a real rider's session and silently replacing real fixes.

7. **`approximate` vs gate threshold gap.** A fix at 100–500 m accuracy is dropped by the gate but not labeled `approximate`, so downstream telemetry/UI can't distinguish "moderately bad urban GPS" from "coarse approximate location." Minor, but it muddies diagnostics when investigating a wrong-place wake.

8. **`isTestMode` static leaks into production.** The `static bool isTestMode` branch in `_startRealGps` and the G28 watchdog means test configuration is baked into the shipping singleton; a mistaken set could disable the real GPS start path in production.
