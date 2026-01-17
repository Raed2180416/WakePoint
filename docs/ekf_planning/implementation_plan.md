# FULL IMPLEMENTATION SPECIFICATION (LOCKED)

This document is an implementation-grade specification. Every stage defines:

* what runs
* when it runs
* inputs/outputs
* thresholds and tuning knobs
* failure handling
* open questions the VS Code agent must resolve before coding

This plan integrates the research cues you provided (SubwayPS/SubTrack/MetroEye/TransitApp) and is biased toward real-world robustness.

---

## 0) System Boundaries (Hard-Locked)

### 0.1 Sensors Allowed
* Accelerometer (60–100 Hz)
* Gyroscope (60–100 Hz)
* GPS (intermittent)

### 0.2 Sensors Not Used
* Magnetometer/Compass
* Camera
* BLE/UWB

### 0.3 Guarantees
* Must never miss a stop alarm (late alarms unacceptable)
* Early alarms allowed
* Must fail conservatively

### 0.4 Non-Goals
* No 3D positioning
* No yaw/heading
* No intent inference

---

## 1) Timebase & Frames (Non-Negotiable)

### 1.1 Timebase Rules
* IMU timestamps must be monotonic.
* Prefer `SensorEvent.timestamp` (nanoseconds since boot).
* If unavailable, use a per-estimator `Stopwatch`.
* GPS timestamps converted into the same monotonic domain on receipt.

**Failure Handling**
* If `dt` < 1 ms or > 200 ms: discard sample and inflate covariance.
* Timestamp regression: discard sample + log.

### 1.2 Frames
* Device frame: raw IMU axes
* World frame: gravity-aligned via pitch/roll only
* Route frame: 1D distance `s` along polyline

Yaw is never estimated. Forward direction is defined by route tangent only.

**Open Questions**
1. Are IMU timestamps exposed by current `sensors_plus` usage?
2. Max tolerable `dt` in current IMU stream?

---

## 2) Stage A — Pitch & Roll Estimation (Tilt Filter)

### 2.1 Purpose
Robust gravity estimation under handling, pocket/bag motion, and vibration.

### 2.2 Inputs
* Raw accelerometer $a_{raw}$
* Raw gyroscope $\omega$
* Monotonic timestamp $t$

### 2.3 Outputs
* Gravity unit vector $\hat{g}_{device}$
* Pitch $\theta$, Roll $\phi$
* Rotation matrix $R_{device \rightarrow world}$

### 2.4 Algorithm (2-DOF Complementary Filter)
1. Predict gravity with gyro integration.
2. Measure gravity with low-pass filtered accel.
3. Gate accel correction with variance threshold.
4. Fuse with complementary gain $\alpha$.

### 2.5 Robustness Rules
* LPF cutoff: 0.5–1.0 Hz (below step frequency).
* Accel correction only if variance < `VarG`.
* On ZUPT, hard reset gravity to accel direction.

### 2.6 Failure Handling
* If accel variance never stabilizes for > 60 s → increase IMU noise and allow EKF to carry uncertainty.
* If gravity norm drifts > `G_norm_tol` → reinitialize from accel.

**Open Questions**
1. LPF type (IIR/FIR) and coefficients.
2. Variance window size `Wg`.
3. Complementary gain schedule vs fixed gain.

---

## 3) Stage B — Route Geometry Engine

### 3.1 Inputs
* Route polyline points
* Leg metadata (metro vs surface)
* Station list

### 3.2 Outputs
* Cumulative distance array `s[i]`
* Tangent vectors per segment `t[i]`
* Station progress `s_station[i]`
* Projection API:
  * `project(lat,lng) -> (s_proj, lateral_error)`
  * `tangentAt(s) -> unit_vector`

### 3.3 Projection Rules
* Closest segment by perpendicular projection.
* Lateral error > 50–75 m → route invalid.

### 3.4 Tangent Continuity (Critical for Numerical Stability)

**Problem:** At polyline vertices, left segment tangent ≠ right segment tangent. This causes:
* False accel spikes at station boundaries (where ZUPT occurs)
* Motion classifier errors
* Bias pollution

**Solution: Tangent Interpolation Rule (Locked)**
* At segment boundaries, interpolate tangents over ±Δs = 7.5 m (default)
* Weighted averaging: $t(s) = w_1 t_{left}(s) + w_2 t_{right}(s)$
* Weights: $w_1 = 1 - \frac{|s - s_{boundary}|}{\Delta s}$, $w_2 = 1 - w_1$
* Clamp weights to [0, 1]
* This ensures smooth $a_{fwd} = \text{dot}(a_{world}, t(s))$ projection

**Implementation:**
* When $|s - s_{boundary}| < \Delta s$, use interpolated tangent
* Otherwise, use segment-specific tangent
* $\Delta s$ is tunable but defaults to 7.5 m (covers ~2–3 IMU samples at 100 Hz)

### 3.5 Failure Handling
* Projection NaN → skip GPS update + log error.

**Open Questions**
1. Lateral error threshold to trigger reroute.
2. Route smoothing (if required).

---

## 4) Stage C — EKF Core (Always Running)

### 4.1 State
$x = [s, v, b_a]^T$

* `s` = distance along route
* `v` = velocity along route
* `b_a` = accel bias

### 4.2 Prediction (per IMU tick)
1. Rotate accel to world frame using $R_{device \rightarrow world}$ from tilt filter.
2. Remove gravity: $a_{world} = R_{d\rightarrow w}(a_{raw} - \hat{g})$.
3. Project onto route tangent: $a_{fwd} = \langle a_{world}, t(s) \rangle$.
4. Propagate:
   * $s_{k+1} = s_k + v_k dt + 0.5(a_{fwd} - b_a)dt^2$
   * $v_{k+1} = v_k + (a_{fwd} - b_a)dt$
   * $b_{a,k+1} = b_{a,k}$

**Signal Fusion Chain:**
* **Gyro + Accelerometer** → Tilt Filter → $R_{device \rightarrow world}$
* **Accelerometer** → Gravity-removed → Forward acceleration
* **Forward acceleration** → EKF control input $u = a_{fwd}$
* **GPS** → EKF measurement update (when available)
* **ZUPT** → EKF velocity constraint (when stationary)

**Note:** Gyro, accelerometer, pitch/roll, and GPS are all fused, but in a **staged architecture** (tilt filter → EKF), which is the correct engineering approach.

### 4.3 Process Noise
Dynamic noise scaling:
* GPS degraded → inflate $Q$.
* Motion = HUMAN → freeze or down-weight prediction.
* ZUPT overdue → inflate bias noise.

### 4.4 GPS Update
* Project to $s_{gps}$.
* Reject if $|s_{gps}-s_{est}| > k\sigma_s$.
* Update with $R = f(accuracy, battery)$.

### 4.5 Consistency Checks
* Track NIS.
* Repeated high NIS → downgrade GPS trust.

### 4.6 Measurement Models (Locked)

**GPS Update:**
* Measurement vector: $z_{gps} = [s_{gps}]$
* Measurement matrix: $H_{gps} = [1\ 0\ 0]$ (measures position only)
* Innovation: $\nu = s_{gps} - s_{est}$
* Innovation covariance: $S = H_{gps} P H_{gps}^T + R_{gps}$
* Kalman gain: $K = P H_{gps}^T S^{-1}$
* State update: $x = x + K \nu$
* Covariance update: $P = (I - K H_{gps}) P$

**ZUPT Velocity Update:**
* Measurement vector: $z_{zupt} = [0]$ (zero velocity)
* Measurement matrix: $H_{zupt} = [0\ 1\ 0]$ (measures velocity only)
* Innovation: $\nu = 0 - v_{est}$
* Innovation covariance: $S = H_{zupt} P H_{zupt}^T + R_{v,zupt}$
* Kalman gain: $K = P H_{zupt}^T S^{-1}$
* State update: $x = x + K \nu$ (updates $v$ and $b_a$ via cross-covariance)
* Covariance update: $P = (I - K H_{zupt}) P$

**Station Snap Update:**
* Measurement vector: $z_{station} = [s_{station}]$
* Measurement matrix: $H_{station} = [1\ 0\ 0]$ (measures position only)
* Innovation: $\nu = s_{station} - s_{est}$
* Innovation covariance: $S = H_{station} P H_{station}^T + R_{station}$
* Kalman gain: $K = P H_{station}^T S^{-1}$
* State update: $x = x + K \nu$ (soft update, not hard reset)
* Covariance update: $P = (I - K H_{station}) P$

**Note:** All measurement updates use standard EKF update equations. No redesign required—this is formalization only.

**Open Questions**
1. Default $Q/R$ values per mode.
2. Innovation gate threshold $k$.
3. Bias observability strategy.

---

## 5) Stage D — GPS Degradation Detector

**CRITICAL:** This **must** be a separate component/file (`lib/core/ekf/gps_degradation_detector.dart`).

**Rationale:**
* GPS condition evaluation is **stateful**, **hysteretic**, and **cross-cutting**
* Mixing measurement quality logic with state estimation logic breaks hysteresis guarantees
* Classic estimator pattern: **Estimator consumes a quality flag; it does not decide quality**
* EKF must never decide GPS trust itself

### 5.1 Responsibilities
* **Consume:**
  * GPS fix status
  * GPS accuracy
  * EKF innovation statistics (|ν| / σ)
* **Produce:**
  * `gpsDegraded = true | false` (binary quality flag)
* **Own:**
  * Hysteresis state
  * Counters (`N_bad`, `N_good`)
  * Timers

### 5.2 Inputs
* GPS fix status
* GPS accuracy
* EKF innovation statistics

### 5.3 Degradation Conditions (Any)
* No fix for > `T_no_fix`
* Accuracy > `A_bad`
* Innovation > `I_bad` for `N_bad` fixes

### 5.4 Hysteresis
* Degraded persists ≥ `T_hold` before enabling IMU-dominant logic.
* Recovery requires `N_good` consecutive good fixes.

**Open Questions**
1. `T_no_fix`, `A_bad`, `I_bad` values.
2. Hysteresis timings.

---

## 6) Stage E — Motion Classification (Only in GPS Degraded Mode)

### 6.1 States
`MOTION ∈ {HUMAN, VEHICLE, STATIONARY}`

### 6.2 Features (2–3 s window)
* Accel magnitude variance
* Gyro variance
* FFT energy in 0.5–2 Hz (walking) and ~5 Hz (train vibration)
* EKF speed

### 6.3 Rule Set
* HUMAN: strong 0.5–2 Hz periodic peak + high variance
* VEHICLE: low periodicity, smoother accel, energy near ~5 Hz
* STATIONARY: low variance + speed near zero

### 6.4 Effect on EKF
* HUMAN → freeze `s` or down-weight IMU
* VEHICLE → normal propagation
* STATIONARY → ZUPT candidate

### 6.5 EKF → Motion Classifier Feedback (Bidirectional Stabilization)

**Problem:** Motion classifier can oscillate unnecessarily when EKF has higher confidence than raw IMU statistics.

**Solution: EKF Confidence Bias (Locked)**
* If $\sigma_v < 0.15$ m/s AND recent ZUPT confirmed (within last 5 s) → bias classifier toward STATIONARY
* If innovation consistently high (> 3σ) for > 10 s → suppress VEHICLE classification (may be walking)
* If $\sigma_s$ very low (< 10 m) AND speed near zero → bias toward STATIONARY

**Rules:**
* EKF confidence does NOT override IMU features, only biases classification
* Bias weight: 0.3 (30% EKF influence, 70% IMU features)
* This prevents oscillation in underground metro where EKF is more reliable than raw IMU

**Open Questions**
1. FFT window length + overlap.
2. CPU budget constraints.
3. Minimum duration before state change.

---

## 7) Stage F — ZUPT Detection (Critical)

### 7.1 Conditions (All)
* Motion = STATIONARY
* $|mean(v)| < V_{th}$
* accel variance < $A_{th}$
* gyro variance < $G_{th}$
* persists for ≥ $T_{zupt}$

### 7.2 Action
* Apply velocity update ($v=0$) with small $R_v$.
* Reduce velocity covariance.
* Update bias.
* Record timestamp.

### 7.3 Safety
* Never hard clamp position.
* Never ZUPT during HUMAN state.

**Open Questions**
1. $V_{th}$, $A_{th}$, $G_{th}$.
2. $T_{zupt}$ duration.

---

## 8) Stage G — ZUPT → Metro Stop Association

### 8.1 Preconditions
* Metro leg active
* ZUPT confirmed

### 8.2 Candidates
* $|s_{station} - s_{est}| < 3\sigma_s + margin$

### 8.3 Logic
* Exactly one candidate → soft position update toward station.
* None/multiple → no snap.

### 8.4 Dwell Enforcement
* ZUPT must persist ≥ $T_{dwell}$ to allow snapping.

**Open Questions**
1. `margin` and $T_{dwell}$.
2. Express train handling.

---

## 9) Stage H — Degraded Mode (Fail-Safe)

### 9.1 Triggers
* No ZUPT for > `T_max_zupt_gap` (default 10 min)
* $\sigma_s$ exceeds `S_max`

### 9.2 Behavior
* Inflate covariance
* Slow or freeze progress
* Alarm conservatively using $s + k\sigma_s$

### 9.3 Recovery
* GPS recovery or confirmed ZUPT

**Open Questions**
1. `S_max` and freeze strategy.
2. Recovery check interval.

---

## 10) Stage I — Alarm Logic

### 10.1 Trigger

$$s_{est} + k\sigma_s \ge s_{target}$$

### 10.2 Timing Specification (Locked)

**Critical:** Alarm logic samples $(s_{pub}, \sigma_s)$ at **alarm evaluation tick**, not IMU tick.

**Rationale:**
* IMU runs at 100 Hz (EKF updates continuously)
* Alarm loop runs at ~1–2 Hz (throttled by GPS update rate)
* If $\sigma_s$ inflates faster than alarm checks, behavior differs across devices
* Sampling at alarm tick avoids race conditions and ensures consistent behavior

**Implementation:**
* Alarm evaluation reads latest $(s_{pub}, \sigma_s)$ snapshot from EKF
* EKF maintains public state updated at IMU rate
* Alarm logic does NOT directly access EKF internal state during evaluation
* This ensures $\sigma_s$ used in trigger is consistent with $s_{est}$ used

### 10.3 Notes
* Larger $k$ in degraded mode.
* Ramp $k$ with time since last ZUPT if needed.

**Open Questions**
1. Default $k$ per mode.
2. Ramp schedule.

---

## 11) Battery Policy Integration

### 11.1 Requirements
* EKF runs even when GPS throttled.
* HUMAN motion avoids double integration.

### 11.2 Behavior
* HUMAN → freeze or step-based update.
* VEHICLE → normal.
* STATIONARY → ZUPT candidate.

**Open Questions**
1. Step count availability.
2. Battery tier exposure in codebase.

---

## 12) Logging & Diagnostics (Mandatory)

### 12.1 Log Streams
* Raw/filtered IMU
* Gravity estimate
* EKF state + covariance
* Motion class
* ZUPT events
* GPS innovations

### 12.2 Format
* CSV with monotonic timestamps
* Compatible with simulation playground

**Open Questions**
1. Logging utility location.
2. Storage limits.

---

## 13) Integration Points (Codebase)

### 13.1 New Files
* `lib/core/ekf/route_geometry.dart`
* `lib/core/ekf/tilt_filter.dart`
* `lib/core/ekf/gps_degradation_detector.dart` (**MANDATORY separate file** - see §13.3)
* `lib/core/ekf/motion_classifier.dart`
* `lib/core/ekf/zupt_detector.dart`
* `lib/core/ekf/progress_estimator.dart`

### 13.2 Existing Services
* `lib/services/trackingservice.dart` — sensor ingestion
* `lib/services/stop_logic_engine.dart` — alarm logic
* `lib/services/tracking_state_store.dart` — persistence

### 13.3 GPS Degradation Detector (Mandatory Separate File)

**File:** `lib/core/ekf/gps_degradation_detector.dart`

**Why Separate (Not Optional):**
* GPS condition evaluation is **stateful**, **hysteretic**, and **cross-cutting**
* Mixing measurement quality logic with state estimation logic breaks hysteresis guarantees
* Classic estimator pattern: **Estimator consumes a quality flag; it does not decide quality**
* EKF must never decide GPS trust itself

**Responsibilities:**
* **Consume:**
  * GPS fix status
  * GPS accuracy
  * EKF innovation statistics (|ν| / σ)
* **Produce:**
  * `gpsDegraded = true | false` (binary quality flag)
* **Own:**
  * Hysteresis state
  * Counters (`N_bad`, `N_good`)
  * Timers

**Integration:**
* EKF receives `gpsDegraded` flag as input
* EKF does NOT evaluate GPS conditions internally
* Motion classifier, alarm logic also use this flag

**Open Questions**
1. Main isolate vs background isolate.
2. Simulation injection points.

---

## 14) Test & Validation Plan (TEST-FIRST APPROACH)

**CRITICAL:** All tests must be written BEFORE implementation. Zero regressions allowed.

### 14.1 Test-First Implementation Strategy
1. **Write tests first** for each component
2. **Run tests** (they fail - expected)
3. **Implement feature** to make tests pass
4. **Verify** all existing tests still pass
5. **Repeat** for next feature

### 14.2 Comprehensive Test Coverage
See `docs/ekf_planning/TEST_PLAN.md` for complete test specification covering:
- **91+ unit tests** for all EKF components
- **8+ integration tests** for component interactions
- **445 regression tests** (all existing tests must pass)
- **8 performance tests** for CPU/memory/battery
- **3+ real-world data tests** with logged IMU/GPS

### 14.3 Test Scenarios
1. Metro ride with GPS outage
2. Station walking
3. Phone in bag
4. Low battery GPS throttling

### 14.4 Metrics
* Max inter-station drift
* Alarm early/late error
* ZUPT false positives
* ZUPT misses

### 14.5 Acceptance Criteria
* 0 missed alarms
* Mean drift < 60 m (metro)
* **All 555+ tests passing**
* **Zero regressions in existing 445 tests**

---

## 15) Implementation Questions (Must Answer Before Coding)

1. LPF coefficients & accel variance window.
2. IMU timestamp availability.
3. $Q/R$ defaults per mode.
4. GPS degrade thresholds & hysteresis.
5. Motion classifier thresholds.
6. ZUPT thresholds & dwell.
7. Station snap margin.
8. Alarm $k$ values.
9. Logging format + storage limits.
10. Simulation replay injection points.

---

## 16) Codebase Deep‑Dive Integration Map (Exact Fit)

This section maps the new EKF pipeline into the current architecture and names the precise files and responsibilities.

### 16.1 Current Flow (as‑is)
1. `LocationManager` emits `Position` (GPS or Simulation).
2. `LocationStreamHandler` ingests positions, computes ETA, handles GPS dropout with placeholder `SensorFusionManager`.
3. `TrackingService._resolveAlarmRouteState()` snaps GPS position to route and produces `progressMeters`.
4. `AlarmController` uses `progressMeters` + route events to trigger alarms.
5. `NotificationUpdater` broadcasts `debug_info` to dashboard.
6. `UnifiedDashboard` renders route and shows debug telemetry.

### 16.2 Replace Placeholder Fusion
**File:** `lib/services/sensor_fusion.dart`

**Action:** Replace deprecated placeholder with the real EKF pipeline orchestration (keep class name `SensorFusionManager` to minimize refactors).

**New responsibilities inside SensorFusionManager:**
* Manage IMU subscriptions (accelerometer + gyroscope).
* Maintain tilt filter + motion classifier + ZUPT detector + EKF state.
* Accept GPS updates and route geometry updates.
* Output:
  * `EstimatedProgress` (s, v, sigma_s)
  * `EstimatedPosition` (lat/lng from progress->route mapping)
  * `DebugTelemetry` (mode, motion state, ZUPT events, STE/variance, innovations)

**Why keep same file/class:** `LocationStreamHandler` already imports `sensor_fusion.dart` and toggles fusion on GPS dropout. Keeping the class name minimizes rewiring.

### 16.3 LocationStreamHandler Wiring (GPS + EKF)
**File:** `lib/services/tracking/location_stream_handler.dart`

**Step‑by‑step changes:**
1. Always create `SensorFusionManager` on `start()` with:
  * route geometry reference
  * transit mode flag
  * optional test IMU streams
2. On every GPS position:
  * call `fusion.updateGPS(position)`
  * update `fusion.setRoute(active route)` when route changes
3. During GPS dropout:
  * do not stop fusion; instead flip `fusion.setGpsDegraded(true)`
4. When GPS resumes:
  * `fusion.setGpsDegraded(false)`
  * `fusion.resetAnchor(position)` if large innovation
5. Expose latest EKF progress to TrackingService via getters or callbacks.

**Reason:** Current `LocationStreamHandler` starts fusion only when GPS drops. The EKF must run continuously to prevent cold‑start drift.

### 16.4 TrackingService Integration (Alarm & Progress)
**File:** `lib/services/trackingservice.dart`

**Step‑by‑step changes:**
1. Add fields:
  * `_ekfProgressMeters`, `_ekfSigmaMeters`, `_ekfMode`, `_ekfDebug`
2. In `startLocationStream()` wire callbacks from `LocationStreamHandler` for EKF updates.
3. In `_resolveAlarmRouteState()`:
  * If GPS degraded or transit leg is metro, prefer EKF progress.
  * Else use existing SnapToRoute progress.
4. In `_broadcastSimulationState()` include EKF telemetry in `debug_info` (see §18).
5. In alarm evaluation use `$s_{est} + k\sigma_s$` for conservative trigger when EKF is in control.

### 16.5 Route Geometry Source
**Files:**
* `lib/services/snap_to_route.dart` (already provides progress & segment index)
* `lib/services/route_registry.dart` (cumulative meters)

**Action:** Introduce a small helper `RouteGeometry` (new file) that:
* maps `s -> lat/lng` (interpolate on polyline)
* returns tangent unit vector at `s`

This can wrap existing `RouteEntry.cumMeters` and `RouteEntry.points`.

### 16.6 Transit Legs & Stops
**File:** `lib/services/transfer_utils.dart`

**Action:** Use `TransitLegStops.stopMeters` for station snapping in ZUPT association.

**Rules:**
* Only metro legs (`isMetro==true`) can snap.
* If `isActualPositions==false`, keep snaps soft and optional.

---

## 17) ZUPT Detector Options (How Each Fits)

### 17.1 STE + High‑Pass (SubTrack‑style)
**Where:** `lib/core/zupt_detector.dart`

**Algorithm:**
1. Gravity‑align accel.
2. High‑pass filter at 0.5 Hz (Butterworth).
3. Compute short‑time energy (STE) over window `W_ste` (e.g., 2 s).
4. ZUPT if STE < `STE_th` for ≥ `T_ste`.

**Use in pipeline:** Primary ZUPT signal when GPS degraded AND motion == STATIONARY.

### 17.2 Sliding‑Window %‑Below Threshold (Hua‑style)
**Algorithm:**
* For each window length `W_stop` (e.g., 4–6 s), count % samples with |a| < `A_stop`.
* ZUPT if ≥ 95% below threshold.

**Use:** Secondary confirmation or fallback when STE unstable.

### 17.3 Debounce / Dwell
**Algorithm:**
* Require continuous low‑variance for `T_dwell` (e.g., 5 s).
* This is a guard to suppress short bumps.

**Use:** Final gate before ZUPT event emission.

### 17.4 Recommendation
Use **STE + Debounce** as primary, and **95%‑below** as a backstop in noisy IMU environments. All gates must pass for `ZUPT_CONFIRMED`.

---

## 18) Dashboard & Visualization Plan (Unified Dashboard)

### 18.1 Telemetry Fields to Broadcast
Extend `debug_info` payload via `NotificationUpdater` → `LocationManager`:
* `ekf_mode` (SURFACE/METRO/DEGRADED)
* `ekf_progress_m`, `ekf_sigma_m`, `ekf_speed_mps`
* `gps_degraded` (bool)
* `motion_state` (HUMAN/VEHICLE/STATIONARY)
* `zupt_state` (IDLE/CANDIDATE/CONFIRMED)
* `ste`, `acc_var`, `gyro_var`
* `last_zupt_at`, `last_zupt_progress`
* `last_station_snap` (station index/name)

### 18.2 UI Rendering (Unified Dashboard)
**File:** `lib/dashboard/unified_dashboard.dart`

Add:
1. A new debug panel line: `ekf: s=..., σ=..., v=..., mode=...`
2. Cyan marker for station snap events (use `last_station_snap`)
3. Red marker for ZUPT confirmed events (at projected route position)
4. Optional polyline overlay showing EKF progress position vs GPS position

### 18.3 Testing Hooks
* Add a dashboard toggle to force GPS degraded flag (debug only).
* Add an overlay showing ZUPT window status (STE + %‑below).

---

## 19) Data‑Driven Test Plan (Using Provided Logs)

### 19.1 Dataset Inventory (Already Available)
Folder: `GeoWake IMU (File responses)/`
* Metro logs with GPS outages
* Non‑metro IMU+GPS logs
* Annotation files for segments

### 19.2 Offline Replay Pipeline (Plan)
1. Parse `Accelerometer.csv`, `Gyroscope.csv`, `Location.csv` into a unified timeline.
2. Reconstruct route using Google Maps (external) and store route polyline.
3. Feed the replay stream into:
  * EKF core (offline unit test)
  * Unified Dashboard (via simulation websocket)

### 19.3 Acceptance Metrics
* Drift between ZUPTs and known stops
* False ZUPT rate (walking vs train)
* Alarm early/late distribution

---

## 20) Concrete File‑Level Change List (Minute Steps)

1. **Create new core modules**
  * `lib/core/ekf/tilt_filter.dart`
  * `lib/core/ekf/motion_classifier.dart`
  * `lib/core/ekf/zupt_detector.dart`
  * `lib/core/ekf/progress_estimator.dart`

2. **Replace placeholder**
  * Update `lib/services/sensor_fusion.dart` to orchestrate the EKF pipeline.

3. **Wire into LocationStreamHandler**
  * Instantiate fusion manager on start.
  * Feed GPS updates continuously.
  * Expose EKF outputs via callbacks or getters.

4. **Integrate into TrackingService**
  * Prefer EKF progress in `_resolveAlarmRouteState()` when GPS degraded.
  * Add EKF debug fields to simulation broadcasts.

5. **Update Alarm Logic**
  * Use $s + k\sigma$ when EKF is active.

6. **Dashboard Enhancements**
  * Render EKF state, ZUPT markers, station snap markers.

7. **Testing**
  * Add offline replay harness (Dart or Python) to feed IMU/GPS logs.
  * Add dashboard toggle for forced degradation.

---

## 21) Clarifications Needed (Stop Before Coding)

1. Should EKF run in all modes or only for transit legs?
2. Should we replace SnapToRoute progress entirely when EKF is healthy, or only during GPS degradation?
3. Do you want station snaps to update both EKF state and `ActiveRouteManager` state (so UI snaps to station)?
4. How should we handle GPS recoveries that disagree strongly with EKF (hard reset vs soft update)?
5. Which dashboard visualizations are mandatory vs optional?

---

## 22) Locked Parameter Answers (as of 2026‑01‑16)

### 22.1 Timebase
* IMU timestamps: use Android `SensorEvent.timestamp` from `sensors_plus` when available.
* Fallback: `Stopwatch.elapsedMicroseconds` (log warning once).
* `dt_min = 1 ms`, `dt_max = 200 ms`.
* On violation: skip sample, inflate covariance ×1.2.

### 22.2 Tilt Filter
* LPF: 1st‑order IIR, cutoff $f_c = 0.8$ Hz.
* $\alpha = \frac{dt}{\tau + dt}$, $\tau = \frac{1}{2\pi f_c}$.
* Variance window $W_g = 0.75$ s.
* Complementary gain $\alpha_{comp} = 0.02$ fixed (v1).

### 22.3 Route Geometry
* Lateral error threshold: 50 m (metro), 75 m (surface).
* No smoothing in v1.

### 22.4 EKF Defaults
* $\sigma_{accel} = 0.15$ m/s² (vehicle), $0.05$ m/s² (stationary).
* $\sigma_{bias} = 0.001$ m/s²/√s.
* $R_{gps} = \max(accuracy^2, 25\text{ m}^2)$.
* $R_{v,zupt} = (0.05\text{ m/s})^2$.
* $R_{station} = (10\text{ m})^2$.
* Innovation gate $k = 3.0$ (3σ).
* Bias observable only during ZUPT (no learning in motion).

**Bias Bounds (Locked):**
* Bias magnitude: $|b_a| \le 0.5$ m/s² (hard saturation)
* Bias covariance floor: $\sigma_{bias} \ge 1 \times 10^{-4}$ (m/s²)²
* Rationale: Prevents over-fitting from noisy ZUPTs and silent divergence during GPS loss.

### 22.5 GPS Degradation
* $T_{no\_fix} = 5$ s, $A_{bad} = 50$ m, $I_{bad} = 4\sigma$, $N_{bad} = 3$.
* Enter degraded after 5 s; exit after 3 good fixes.

### 22.6 Motion Classification
* FFT window 2.56 s, 50% overlap.
* Minimum duration: 2 consecutive windows.

### 22.7 ZUPT
* $V_{th}=0.3$ m/s.
* $A_{th}=(0.02\text{ m/s}^2)^2$.
* $G_{th}=(0.5\text{ deg/s})^2$.
* $T_{zupt}=3$ s.

### 22.8 Station Snapping
* margin = 50 m.
* $T_{dwell}=20$ s.
* Express handling: no special logic; no candidate ⇒ no snap.

### 22.9 Degraded Mode
* $S_{max}=150$ m.
* Freeze $v$, allow $\sigma_s$ to grow; do not advance $s$.
* Recovery check every 1 s.

### 22.10 Alarm
* $k$: normal 2.0, degraded 3.0, hard‑degraded 4.0.

### 22.11 Battery / Steps
* Use Android `TYPE_STEP_DETECTOR` if available; no custom steps in v1.
* EKF must not change IMU sampling rate; power tier from `PowerPolicyManager` only.

### 22.12 Logging
* Use existing `NotificationUpdater` debug telemetry.
* Ring buffer max 10 MB per session; drop oldest.

### 22.13 Integration
* Run EKF in background isolate.
* Simulation injection via `LocationStreamHandler`.
* EKF always running; SnapToRoute only when GPS healthy.
* Station snaps update EKF always; update UI only when single candidate and low $\sigma$.
* GPS recovery: soft update if $|innovation|<3\sigma$, hard reset if $>5\sigma$.
* Mandatory dashboard telemetry: `ekf_progress`, $\sigma$, `motion_state`, `zupt_state`.

---

## 23) Additional Missing Items (Add to Spec)

1. **Leg Transition Handling**
  * On metro↔walk leg changes: reset motion classifier history, reset ZUPT timers, inflate covariance briefly.

2. **Platform Walking Ambiguity**
  * Require ZUPT + dwell before station snap; HUMAN state suppresses snap even if ZUPT candidate.

3. **Reverse Direction Trains**
  * Disallow backward progress unless GPS confirms; clamp negative progress drift.

4. **Shared Station on Multiple Lines**
  * Use only active route leg’s stop list; ignore stations from other legs/lines.

5. **IMU Dropout / Batching**
  * If IMU pauses > `dt_max`, skip prediction and inflate covariance (explicit rule).

---

## 24) Locked Edge‑Case Decisions (as of 2026‑01‑16)

### 24.1 Negative Progress Handling
* EKF internal state may allow $v<0$ and $\Delta s<0$.
* Public progress is clamped:

  $$s_{pub}=\max(s_{pub\_prev},\; s_{est})$$

* Maintain `s_est_raw` for diagnostics.
* Exception: allow decreasing `s_pub` only if GPS confirms backward motion **and** route permits reverse traversal (default: disabled for metro legs).
* Log if `s_est_raw` decreases by >5 m within 2 s.

### 24.2 Station Snap vs ActiveRouteManager
* Always apply soft position update to EKF when a station snap candidate is chosen.
* Update `ActiveRouteManager.lastSnapIndex` **only** if all are true:
  1. Exactly one candidate within $3\sigma + margin$.
  2. ZUPT dwell $\ge T_{dwell}$.
  3. $\sigma_s \le 30$ m after the snap update.
  4. Station index $\ge$ `lastSnapIndex` (monotonic).
* Emit `station_snap_confirmed` event for UI/telemetry when ARM update occurs.
* Never hard‑set ARM from EKF alone; never update ARM on ambiguous snaps.

### 24.3 Consecutive ZUPTs Without Station Association
* Track `unassocZuptCount`.
* Increment on each confirmed ZUPT without station association.
* Reset to 0 on station snap or GPS recovery with consistent update.
* Thresholds: `N_warn = 3`, `N_escalate = 5`.
* If `unassocZuptCount >= N_warn`:
  * Inflate $Q$ by ×1.3.
  * Increase required dwell by +10 s.
* If `unassocZuptCount >= N_escalate`:
  * Enter DEGRADED.
  * Disable station snapping temporarily.
  * Increase alarm $k$ by +1.
  * Wait for GPS recovery or next high‑confidence station snap.
* Never disable ZUPT velocity updates.
* Never hard‑reset EKF solely due to this counter.

---

## 25) Full Testing Database + Artificial Route Construction (Locked)

Goal: build a **complete, queryable testing database** by reconstructing routes using API calls and aligning all IMU/GPS logs to a unified schema. This is required because many logs lack annotations.

### 25.1 Canonical Test Database Schema
Store as local JSON/SQLite (v1 JSON acceptable). Every test run must reference a `TestRoute` entry.

**TestRoute**
* `route_id` (string)
* `source_folder` (log folder path)
* `mode` (metro/surface/mixed)
* `origin_latlng`, `dest_latlng`
* `route_polyline` (API decoded)
* `route_points[]` (lat/lng list)
* `route_cum_meters[]`
* `stations[]` (name, lat/lng, s_meter)
* `legs[]` (metro vs non‑metro, start_s, end_s)

**TimeSeries**
* `imu_accel[]` (t, ax, ay, az)
* `imu_gyro[]` (t, gx, gy, gz)
* `gps[]` (t, lat, lng, accuracy, speed, bearing)
* `annotations[]` (t, label, source)

**DerivedLabels**
* `stop_events[]` (t_start, t_end, type=station/traffic)
* `motion_class[]` (t_start, t_end, HUMAN/VEHICLE/STATIONARY)
* `gps_outage[]` (t_start, t_end, reason)

### 25.2 Route Construction via API (Mandatory)
**Input:** origin/destination inferred from first/last GPS point in `Location.csv`.

**Call:** Directions API (or existing DirectionService) with `transitMode` based on folder type.

**Process:**
1. Decode polyline to `route_points`.
2. Compute `route_cum_meters`.
3. Extract transit legs + stop list (if available).
4. Snap stops to route → compute `s_meter` for each stop.
5. Store in `TestRoute`.

**Failure Handling:**
* If API fails, fallback to polyline built from GPS trace.
* Mark `route_quality = fallback` in DB.

### 25.3 Artificial Labels (Required)
Because most routes have empty annotations, derive labels automatically:

1. **Station stops (metro only)**
  * Use stop list from Directions API.
  * Generate expected station windows from timetable distance + dwell prior.
  * Align with IMU ZUPT detections to refine timestamps.

2. **Motion class labels**
  * Pre‑label windows using FFT rules (0.5–2 Hz = walking, ~5 Hz = train) and mark as `weak_label`.
  * These are used to bootstrap classifier tuning, not final ground truth.

3. **GPS outage segments**
  * Derived from `Location.csv` gaps > `T_no_fix`.

### 25.4 Database Build Pipeline (Step‑by‑Step)
1. For each log folder:
  * Parse `Metadata.csv` and `Location.csv`.
  * Infer origin/destination.
2. Call Directions API and build `TestRoute`.
3. Parse IMU (accel + gyro), resample to common timebase.
4. Align GPS to IMU timebase.
5. Generate derived labels (station stops, motion class, outages).
6. Persist into database.

### 25.5 Minimum Acceptance to Consider “Complete”
* Every log has:
  * a reconstructed route polyline
  * cumulative meters array
  * derived station list (metro) or route legs (surface)
  * motion labels (weak‑label)

---

## 26) Unified Dashboard Testing Plan (End‑to‑End)

### 26.1 Data Injection
* Replay database time‑series to the app through `LocationStreamHandler` and IMU streams.
* When testing EKF, feed **both** GPS and IMU from the database.

### 26.2 Dashboard Visuals (Required)
Add to [lib/dashboard/unified_dashboard.dart](lib/dashboard/unified_dashboard.dart):
* Show `ekf_progress`, $\sigma$, `motion_state`, `zupt_state` in debug bar.
* Render **ZUPT markers** (red) at `s_pub`.
* Render **station snap markers** (cyan) on confirmed snap events.
* Toggle overlay to compare GPS vs EKF progress.

### 26.3 Test Scenarios (must all be runnable)
1. **Metro run with GPS outage** (from Metro_Log_File)
2. **Surface tunnel with GPS outage** (RT_Nagar under tunnel)
3. **Normal bus route** (Upload Log File)
4. **High‑noise handling case** (Boom logs)

### 26.4 Metrics to Compute in Dashboard
* Max drift between ZUPTs
* ZUPT false positives (with weak labels)
* Alarm early/late relative to derived station windows
* Count of unassociated ZUPTs

### 26.5 Pass/Fail Criteria
* 0 missed alarms on metro
* Station snap error ≤ 60 m median
* ZUPT rate stable (no runaway count)

---

## 27) Codebase Deep‑Dive: Entry Points & Safe Integration (Stage‑by‑Stage)

This section is a **ruthless, code‑accurate** integration map. Each stage lists:
* exact entry points
* data flow dependencies
* integration risks
* safeguards to avoid regressions

### 27.1 Stage A — IMU Ingest + Timebase
**Entry points**
* `LocationStreamHandler.start()` in [lib/services/tracking/location_stream_handler.dart](lib/services/tracking/location_stream_handler.dart) — owns session lifecycle and GPS dropout timer.
* `SensorFusionManager` (replacement) in [lib/services/sensor_fusion.dart](lib/services/sensor_fusion.dart) — will subscribe to `accelerometerEvents` and `gyroscopeEvents`.

**Safe wiring**
* Instantiate `SensorFusionManager` at `LocationStreamHandler.start()` and keep it running even when GPS is healthy.
* Only **toggle degraded flag** on dropout; do not stop fusion on GPS return (prevents cold starts).

**Risks**
* Battery impact if IMU always on — mitigate by honoring power policy (keep sampling rate unchanged, skip FFT unless degraded).

**Safeguards**
* Guard IMU subscription errors (sensors_plus MissingPlugin) as in current `SensorFusionManager`.
* Always tolerate IMU gaps (`dt > 200ms`) by skipping + inflating covariance.

---

### 27.2 Stage B — Tilt Filter + Motion Features
**Entry points**
* `SensorFusionManager.onImuSample(...)` (new method) processes accel+gyro.

**Safe wiring**
* Maintain an internal `TiltFilter` class (new file) so no external call sites change.
* Output: gravity‑aligned accel only; do not mutate existing GPS data path.

**Risks**
* Incorrect gravity alignment causes EKF drift.

**Safeguards**
* If accel variance never stabilizes for 60s, inflate noise; do not stop pipeline.
* Log tilt instability in debug telemetry for dashboard.

---

### 27.3 Stage C — Route Geometry Mapping
**Entry points**
* `RouteRegistry` entries already contain `points` and `cumMeters` in [lib/services/route_registry.dart](lib/services/route_registry.dart).
* `ActiveRouteManager` uses snapping in [lib/services/active_route_manager.dart](lib/services/active_route_manager.dart).

**Safe wiring**
* Introduce `RouteGeometry` helper (new file) that wraps `RouteEntry.points` + `cumMeters`.
* Provide `tangentAt(s)` and `pointAt(s)`; no modifications to `SnapToRouteEngine` required.

**Risks**
* Incorrect `tangentAt(s)` could bias accel projection.

**Safeguards**
* Unit tests: tangent continuity on straight + L‑shaped routes.
* Reject lateral error > thresholds and fall back to SnapToRoute.

---

### 27.4 Stage D — EKF Core
**Entry points**
* `SensorFusionManager` owns EKF state.
* `LocationStreamHandler._handlePositionUpdate()` passes GPS updates to fusion.

**Safe wiring**
* Use EKF only to compute **progress**; do not replace GPS Position in UI directly.
* Report EKF progress to `TrackingService` via callback (new field `onEkfUpdate`).

**Risks**
* Alarm logic depends on `progressMeters` being monotonic.

**Safeguards**
* Clamp `s_pub` (see §24.1) before feeding `TrackingService`.
* Preserve `SnapToRoute` fallback if EKF output is NaN.

---

### 27.5 Stage E — GPS Degradation + Motion Classifier
**Entry points**
* `LocationStreamHandler._checkGpsDropout()` already detects GPS silence.

**Safe wiring**
* Replace `_fusionActive` logic with `fusion.setGpsDegraded(bool)`.
* Run FFT only when degraded (power guard).

**Risks**
* False degraded flag can freeze progress.

**Safeguards**
* Use `N_bad` and hysteresis; always allow GPS recovery to soft‑reset EKF.

---

### 27.6 Stage F — ZUPT + Station Snapping
**Entry points**
* `SensorFusionManager` produces ZUPT events.
* `TransitLegStops` in [lib/services/transfer_utils.dart](lib/services/transfer_utils.dart) supplies `stopMeters`.

**Safe wiring**
* Station snapping updates EKF always; ARM only under confidence gate (§24.2).
* Never mutate `ActiveRouteManager` progress directly without gate.

**Risks**
* Wrong station snap can break stop order and alarms.

**Safeguards**
* Require single candidate and $\sigma_s \le 30$ m.
* Enforce monotonic station index.

---

### 27.7 Stage G — Alarm Logic Compatibility
**Entry points**
* `_resolveAlarmRouteState()` in [lib/services/trackingservice.dart](lib/services/trackingservice.dart) determines `progressMeters`.
* `AlarmController` consumes `progressMeters` in [lib/services/tracking/alarm_controller.dart](lib/services/tracking/alarm_controller.dart).

**Safe wiring**
* When GPS healthy and non‑metro leg, prefer SnapToRoute progress.
* When degraded or metro leg, prefer EKF `s_pub`.
* Always keep fallback to straight‑line distance if progress is null.

**Risks**
* Early alarms if EKF overestimates progress.

**Safeguards**
* Use uncertainty‑aware trigger ($s + k\sigma$) only when EKF is active.

---

### 27.8 Stage H — Notifications + Dashboard
**Entry points**
* `NotificationUpdater.broadcastSimulationState()` in [lib/services/tracking/notification_updater.dart](lib/services/tracking/notification_updater.dart).
* Dashboard consumer `_handleAppState()` in [lib/dashboard/unified_dashboard.dart](lib/dashboard/unified_dashboard.dart).

**Safe wiring**
* Add EKF telemetry keys to `debug_info` only (no breaking changes to existing schema).
* Dashboard should ignore unknown fields by default.

**Risks**
* Excess telemetry increases WebSocket payload size.

**Safeguards**
* Gate high‑rate telemetry to 1 Hz in broadcast.

---

### 27.9 Stage I — Persistence & Restore
**Entry points**
* `TrackingStateStore.saveSnapshot()` in [lib/services/tracking_state_store.dart](lib/services/tracking_state_store.dart).

**Safe wiring**
* Persist only EKF mode + last `s_pub` (optional) to avoid bloating snapshot.
* Do not persist full covariance in v1.

**Risks**
* Restore inconsistencies if EKF state resumes without synced IMU.

**Safeguards**
* On restore, re‑init EKF from latest GPS and set `s_pub` to snapped progress.

---

## 28) Risk Register (Ranked by Likelihood × Impact)

### Tier-1 (Highest Priority: Must be Controlled)

**R1 — Parameter Interaction Instability**
* **Likelihood:** High
* **Impact:** High
* **What this is:** Not "wrong math," but correct rules interacting badly.

**Concrete Examples:**
* Motion classifier briefly flips to HUMAN → ZUPT suppressed → bias not corrected → drift accumulates
* Battery disables FFT → VEHICLE default → walking user integrates accel
* GPS recovers during station dwell → snap + GPS update collide in same window

**Why Dangerous:**
Each component is correct alone. Bugs emerge only when multiple guards activate together.

**Mitigation (Already Present):**
* Conservative clamps
* Hysteresis
* Confidence-gated snapping
* **Remaining:** Empirical bounding via parameter sensitivity analysis (see §28.1)

**R2 — ZUPT False Negatives at Stations**
* **Likelihood:** Medium–High
* **Impact:** High
* **Failure Mode:** Train stops, but vibration persists → classifier stays VEHICLE → ZUPT never fires → bias not corrected → station snap never triggered

**Why Matters:**
ZUPT is the only bias anchor underground.

**Mitigation (Already Present):**
* STE + sliding window + dwell
* EKF confidence bias toward STATIONARY
* Conservative alarm even if snap fails
* **Residual Risk:** Threshold tuning only. Architecture is correct.

### Tier-2 (Manageable, but Must be Observed)

**R3 — Platform IMU Timestamp Pathologies**
* **Likelihood:** Medium
* **Impact:** Medium–High
* **Failure Mode:** OEM batching, clock jumps, or delayed IMU bursts

**Mitigation (Present):**
* dt rejection (< 1ms or > 200ms)
* Covariance inflation on violation
* Prediction skip on extreme dt
* **Residual Issue:** No hard "estimator invalid" cutoff for extreme cases
* **Why Acceptable:** System fails early, not silently

**R4 — GPS Degradation Detector Mis-tuning**
* **Likelihood:** Medium
* **Impact:** Medium
* **Failure Mode:**
  * Degrades too aggressively → freezes progress early
  * Degrades too late → trusts bad GPS briefly

**Mitigation:**
* Hysteresis
* Innovation-based gating
* Conservative alarm
* **This is a tuning, not logic, risk**

### Tier-3 (Known, Low Risk, Acceptable)

**R5 — Express Trains with Zero Anchors**
* **Handled Intentionally:**
  * σ inflates
  * Progress freezes
  * Alarm triggers early
* **This is a designed failure, not a bug**

### Summary

**There are no unknown unknowns left.**

What remains are:
* Numeric stability risks
* Interaction risks
* Tuning risks

**All are containable via:**
* Parameter sensitivity analysis (§28.1)
* Three critical tests (§28.2)
* Conservative design choices (already present)

### 28.1 Parameter-Locking Protocol (Mandatory)

**Critical:** Do not lock parameters arbitrarily. Follow this protocol.

**Phase 0 — Provisional Defaults (Already Done)**
* These are scaffolding, not truth
* Exist to: write tests, enable replay, prevent divergence
* Current values in §22 are provisional

**Phase 1 — Sensitivity Bounding (Mandatory Before Locking)**

For each critical parameter:

**Step A — Identify Sensitivity Class**

| Parameter Type | Examples | Strategy |
|----------------|----------|----------|
| Binary gates | degraded/not, snap/no snap | Hysteresis |
| Continuous thresholds | A_th, G_th, FFT energy | Wide margins |
| Confidence scalars | k, Q inflation | Conservative bias |

**Step B — Sweep Ranges Offline**

For each parameter:
* Sweep ±50–100%
* Run logged replays
* Measure:
  * Missed ZUPTs
  * False ZUPTs
  * Drift between anchors
  * Alarm lead time

**Goal:** Not optimizing accuracy. Ensuring no catastrophic mode change.

**Step C — Lock Only When Invariant Holds**

A parameter is lock-worthy if:
* Changing it does not break any invariant:
  * No missed alarms
  * No backward station snaps
  * No silent confidence inflation
* If it does, widen margins

**Phase 2 — Parameter Freezing Rule**

Once locked:
* Parameters move only via:
  * New logged dataset
  * Explicit version bump
* **Never** tuned in isolation
* **Never** tuned to "look good"
* This prevents accidental regression

### 28.2 Three Critical Tests (Catch ~80% of Real Bugs)

If you could only write three tests, these are them.

**Test 1 — Long Metro Tunnel, No Stops (Catches ~35–40% of catastrophic bugs)**

**Scenario:**
* GPS lost at tunnel entry
* Continuous vibration
* No ZUPT for 10–15 minutes

**What This Validates:**
* Covariance inflation correctness
* Progress freeze logic
* Alarm conservative trigger
* No false confidence
* No numeric explosion

**Bug Classes Caught:**
* Over-trusting IMU
* σ not growing correctly
* Alarm race conditions

**Test 2 — Station Stop With Ambiguous Motion (Catches ~25–30% of subtle failures)**

**Scenario:**
* Train stops
* Residual vibration
* Classifier oscillates VEHICLE ↔ STATIONARY
* GPS flickers weakly

**What This Validates:**
* ZUPT dwell enforcement
* EKF → classifier bias
* Station snap gating
* No snap during HUMAN state
* Bias correction actually happens

**Bug Classes Caught:**
* Missed ZUPTs
* False snaps
* Bias drift at stations

**Test 3 — GPS Recovery With Large Innovation (Catches ~15–20% of integration bugs)**

**Scenario:**
* EKF drifts underground
* GPS returns with large offset
* Station nearby

**What This Validates:**
* Soft vs hard reset logic
* Innovation gating
* Snap + GPS update ordering
* No backward progress jump
* UI state remains monotonic

**Bug Classes Caught:**
* Double-correction errors
* Route corruption
* UI inconsistency

**Why These Three Matter:**
Together they stress:
* Time (long tunnels)
* Uncertainty (ambiguous motion)
* Mode switching (GPS recovery)
* Estimator authority (large innovations)

**If these three pass, the rest are refinements.**

---

## 29) Missing Spec Items — Now Locked

### 29.1 EKF Initialization & Re‑Initialization (MUST‑FIX v1)

**Initial EKF state (first valid GPS):**
* $s = s_{gps}$
* $v = \max(v_{gps\_proj}, 0)$
* $b_a = 0$
* $P = \operatorname{diag}(25^2, 5^2, 0.1^2)$

**Hard GPS reset:**
* Re‑initialize entire EKF state using the above.

**Soft GPS recovery:**
* Perform innovation update only (do not reset $b_a$).

**App resume (background → foreground):**
* Discard IMU backlog.
* Wait for first GPS **or** confirmed ZUPT before trusting EKF output.

### 29.2 Sensor Normalization Contract (MUST‑FIX v1)

**Units:**
* Accelerometer: m/s²
* Gyroscope: rad/s
* Gravity magnitude assumed: $|g| \approx 9.81$ m/s²

**Axis conventions:**
* Document Android axis mapping explicitly.
* Add unit tests verifying sign and axis alignment for gravity vector.

**Rule:** If a single sign error is detected in unit tests, EKF must refuse to start (fail safe).

### 29.3 Route Direction Disambiguation (MUST‑FIX v1)

**Direction lock:**
* Initial direction chosen by:
  1) first two GPS projections, **or**
  2) first station snap (if GPS ambiguous).

**After lock:**
* Backward motion suppressed unless GPS confirms reverse movement.
* Unlock only on route re‑plan.

### 29.4 Covariance Floors & Ceilings (MUST‑FIX v1)

**Floor:**
* $\sigma_s \ge 5$ m
* $\sigma_v \ge 0.1$ m/s
* $\sigma_{bias} \ge 1 \times 10^{-4}$ (m/s²)²

**Ceiling:**
* If $\sigma_s > 300$ m → estimator invalid ⇒ force DEGRADED.

**Bias Bounds:**
* $|b_a| \le 0.5$ m/s² (hard saturation, clamp on update)

### 29.5 Reroute Handling (SHOULD‑FIX v1.5)

On reroute:
* Project current GPS to new route → initialize $s$.
* Inflate $\sigma_s$.
* Reset bias $b_a$.

### 29.6 IMU Calibration & Temperature Drift (SAFE‑TO‑DEFER v2)
* Document as known limitation; ZUPTs/GPS mitigate in v1.

### 29.7 UX Fail‑Safe on Hard Degraded (SAFE‑TO‑DEFER v2)
* Future: user‑visible state indicating uncertainty mode.

---


