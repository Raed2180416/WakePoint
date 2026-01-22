# WakePoint Tracking & EKF Reference Guide (Exhaustive)

> **Purpose**: This document is the final, exhaustive technical reference for WakePoint’s tracking, ETA, map‑matching, deviation, rerouting, alarm, and EKF subsystems. It is intended for deep engineering understanding and should be treated as the canonical guide to the runtime behavior. Every notable constant, heuristic, and decision point is described along with the rationale behind it.

---

## Table of Contents
1. [System Overview](#1-system-overview)
2. [Data & Terminology](#2-data--terminology)
3. [Routes, Polylines, and Step Geometry](#3-routes-polylines-and-step-geometry)
4. [ETA Engine (Primary ETA)](#4-eta-engine-primary-eta)
5. [ETA Utilities (Step‑based Helpers)](#5-eta-utilities-step-based-helpers)
6. [Snap‑to‑Route Engine (Map Matching)](#6-snap-to-route-engine-map-matching)
7. [Alarm Evaluation & Triggering](#7-alarm-evaluation--triggering)
8. [Route Queue (UI‑level)](#8-route-queue-ui-level)
9. [Route Session Manager (Registration + Lifecycle)](#9-route-session-manager-registration--lifecycle)
10. [Active Route Manager (Auto‑switching)](#10-active-route-manager-auto-switching)
11. [Deviation Monitor (Off‑route Detection)](#11-deviation-monitor-off-route-detection)
12. [Reroute Policy & Execution](#12-reroute-policy--execution)
13. [Tracking Termination Policy](#13-tracking-termination-policy)
14. [Sensor Fusion + EKF Orchestration](#14-sensor-fusion--ekf-orchestration)
15. [EKF Pipeline (State + Filters)](#15-ekf-pipeline-state--filters)
16. [Station Association](#16-station-association)
17. [ZUPT (Zero‑Velocity Update)](#17-zupt-zero-velocity-update)
18. [Motion Classification](#18-motion-classification)
19. [GPS Degradation Detector](#19-gps-degradation-detector)
20. [Degraded Mode Policy](#20-degraded-mode-policy)
21. [Tilt Filter (Gravity Estimation)](#21-tilt-filter-gravity-estimation)
22. [Failure Handling, Resets, and Edge Cases](#22-failure-handling-resets-and-edge-cases)
23. [Configuration, Hardcoded Values, and Rationale](#23-configuration-hardcoded-values-and-rationale)
24. [Operational Guidance & Debugging](#24-operational-guidance--debugging)

---

## 1) System Overview
WakePoint tracking is a **multi‑sensor, route‑aware estimation pipeline**. It takes:
- **GPS** position + accuracy + optional speed
- **IMU** sensor data (accelerometer, gyroscope)
- **A route polyline** (expected travel path)

…and produces:
- **Progress along route** (meters traveled along polyline)
- **Remaining distance** and **ETA**
- **Alarms** when thresholds are crossed
- **Deviation detection** (off‑route vs on‑route)
- **Reroute decisions** and **termination events**

There are two parallel “location alignment” paths:
1) **Snap‑to‑Route Engine** (map matching for tracking/alarm logic)
2) **EKF** (sensor fusion that estimates progress even with poor GPS)

These are fused by higher‑level orchestration (tracking service + alarm controller) to select the best progress source depending on mode (e.g., metro, degraded). 

---

## 2) Data & Terminology
**Route**: A polyline representing the expected path; typically from directions API. 

**Polyline**: An ordered list of coordinate points (lat/lon). The system breaks it into line segments to compute distances and snapped positions.

**Progress meters (s)**: The scalar distance along the polyline from the start.

**Remaining meters**: `totalRouteMeters - progressMeters`.

**ETA**: Estimated time to destination in seconds.

**Step**: A logical segment of a route (e.g., “walk 120m”, “ride 2km”). Steps have boundaries in meters and durations in seconds.

**Lateral offset**: The perpendicular distance from the GPS point to the closest polyline segment.

**EKF**: Extended Kalman Filter. It estimates a continuous state (progress, velocity, bias) using motion sensor data + GPS constraints.

**ZUPT**: Zero‑Velocity Update. When the system detects the user is stationary, it resets velocity to reduce drift.

**Degraded mode**: A runtime mode used when GPS is unreliable (low accuracy, missing fixes, or high innovation).

---

## 3) Routes, Polylines, and Step Geometry
Routes can be built from multiple sources, in priority order:
1) **Step polylines** (highest quality)
2) **Overview polyline**
3) **Simplified polyline**
4) **Fallback from step start/end points**

This ensures the route is usable even if detailed step geometry is missing.

### Step boundaries and scaling
- Steps are expressed as **meter boundaries** along the polyline.
- If step meter totals do not match polyline length, the system **scales** step boundaries to fit.
- This preserves proportional step placement and keeps ETA step math consistent.

### Stops and transit legs
- Transit legs define **stops** (stations) and are cached per route.
- The EKF uses these stops for **station association** (snap to station when stationary).

---

## 4) ETA Engine (Primary ETA)
This engine computes ETA with a hybrid strategy:
- **Speed‑based** estimation (core)
- **Step‑based** fallback/augmentation when available
- **Dwell time** injection when stopped

### 4.1 Constants and internal state
**Key tunables (hardcoded)**
- `vMin`: minimum speed in m/s (prevents divide‑by‑zero and unrealistic ETAs when nearly stationary).
- `speedAlpha`: smoothing factor for EMA.
- `gpsAccuracyThreshold`: threshold for deciding if GPS is “good enough”.
- `stopSpeedThreshold`: below this speed you are considered stopped.
- `stopTimeThresholdMs`: how long you must be stopped before dwell is added.
- `defaultDwellSeconds`: dwell added when stopped.
- `uncertaintyMinPos`: minimum positional uncertainty.
- `sigmaVDefault`: default speed uncertainty.
- `largeSigmaEta`: large uncertainty used when stationary.
- `speedWindowMax`: maximum samples kept for speed variance.
- `maxSnapDistance`: if snap distance exceeds this, fallback to full‑route search.
- **Metro mode constants**:
  - `metroScheduledSpeedMps = 9.2`
  - `metroDwellTimePerStopSec = 25.0`

**Persistent state** (stored via SharedPreferences):
- `smoothedSpeed`
- `lastGps`
- `stoppedSince`
- `speedWindow`
- `lastSnappedPoint`
- `lastSegmentIndex`
- `lastSigma`

### 4.2 Map matching inside ETA engine
A **fast, windowed snap** is used for performance:
- Searches segments around `lastSegmentIndex` (±50).
- If distance to last snapped point > 2km, it does **full search**.
- If the windowed result is too far (greater than `maxSnapDistance`), it **fallbacks** to full search.

**Remaining distance** is computed as:
1) Remaining portion of current segment.
2) Sum of all subsequent segments.

### 4.3 Speed estimation
- If GPS speed is valid and > 0, use it.
- Otherwise use **distance/time** between last and current GPS fixes.
- Apply EMA smoothing to stabilize short‑term noise.
- Maintain a window of recent speeds for sigma‑v estimation.

### 4.4 Dwell detection
- If speed < `stopSpeedThreshold`, `stoppedSince` is set.
- If stopped for ≥ `stopTimeThresholdMs`, add `defaultDwellSeconds` to ETA.
- This is **disabled** in metro mode because metro dwell is already modeled.

### 4.5 Base ETA formula
**Non‑metro**:
- $ETA = \frac{d_{rem}}{v_{eff}} + dwell$
- `v_eff = max(smoothedSpeed, vMin)`

**Metro**:
- If remaining stops exist:
  - Travel time = $d_{rem}/9.2$
  - Dwell time = `remainingStops * 25`
- If no stops:
  - Use speed‑based ETA but clamp to at least walking speed.

### 4.6 Step‑based hybrid ETA
If step boundaries and durations are valid:
1) Compute progress = `totalMeters - remainingMeters`.
2) Find which step the user is currently in.
3) Compute remaining time inside current step.
4) Compute time for all future steps (full durations).
5) Apply a **floor factor** so ETA cannot become too optimistic.

**Floor factor logic**:
- If GPS accuracy is good and speed variance is low, ETA can be faster than plan.
- If GPS is poor or speed variance high, ETA must be closer to plan.
- `floorFactor` ranges roughly 0.60–0.90 depending on reliability.

### 4.7 Uncertainty
Uncertainty is computed as:
$$\sigma_\eta = \sqrt{(\sigma_p / v)^2 + (d \cdot \sigma_v / v^2)^2}$$
- $
  \sigma_p = \max(accuracy, 8)
$
- If speed is near 0, uncertainty becomes large to avoid false precision.

### 4.8 Output
The ETA engine returns:
- ETA seconds
- Remaining meters
- Estimated speed
- ETA uncertainty
- Dwell seconds added
- Snapped point (for debugging/visualization)

---

## 5) ETA Utilities (Step‑based Helpers)
Two functions provide deterministic step‑based times:

### 5.1 `etaRemainingSeconds`
- Validates steps.
- Finds current step for the given progress.
- Computes remaining time = current step partial + future steps full.

### 5.2 `etaToTargetSeconds`
- Computes ETA from current progress to any target point on the route.
- Supports targets in the same step or later steps.

---

## 6) Snap‑to‑Route Engine (Map Matching)
This is the **primary map matching engine** for tracking and alarms.

### 6.1 Core algorithm
1) Compute cumulative distance along route.
2) Search a window around the last snapped index.
3) For each candidate segment:
   - Project GPS point onto segment.
   - Compute lateral offset.
   - Compute heading alignment.
4) Apply scoring:
   - Lower lateral offset = better.
   - Bonus for staying on same or adjacent segments.
   - Penalty for large index jumps (prevents teleporting).
   - Penalty if heading is opposite the segment direction.

### 6.2 Fallback path
If the windowed snap is too far (> 500m offset) and a previous result exists:
- Run a **full route search**.
- Use the new snap if it is significantly better.

### 6.3 Why two matchers exist
- **ETA engine** uses a simpler matcher for speed.
- **SnapToRoute** uses a richer heuristic for accuracy and continuity.

---

## 7) Alarm Evaluation & Triggering
Alarms fire when specific conditions are met.

### 7.1 Alarm inputs
- Alarm mode (distance/time/stops)
- Destination
- Current progress on route
- ETA engine output

### 7.2 Progress resolution
- Snap GPS to route to get `progressMeters`.
- If in metro or degraded mode, EKF progress can override snap.

### 7.3 Alarm evaluation flow
- Distance mode: check remaining distance.
- Time mode: use ETA.
- Stops mode: use remaining stops.

### 7.4 Metro time‑mode behavior
- If on a non‑metro leg before a metro segment, compute ETA to the next boarding point.
- Interchange walks can be ignored for time‑mode alarms.

---

## 8) Route Queue (UI‑level)
The route queue is only for UI selection:
- Max size 8
- New routes push out oldest
- `activeRouteIndex` exists for UI only
- **Does not drive tracking logic**

---

## 9) Route Session Manager (Registration + Lifecycle)
This component registers routes and builds all per‑route metadata:
- Polyline source selection
- Step boundaries + durations
- Stops for transit legs
- Initializes ActiveRouteManager + DeviationMonitor

It stores per‑route arrays like:
- `stepBoundsMetersByKey`
- `stepDurationsSecondsByKey`
- `routeMetersByKey`

---

## 10) Active Route Manager (Auto‑switching)
Purpose: if multiple routes exist, pick the best matching one.

### 10.1 Decision flow
1) Snap to current active route.
2) Snap to nearby candidate routes.
3) Compute lateral offset difference.
4) If another route is better by `switchMarginMeters`:
   - Start a timer.
   - Only switch if the new route remains better for `sustainDuration`.
5) After switch, block changes for `postSwitchBlackout`.

### 10.2 Rationale
- Prevent oscillation between similar routes.
- Require sustained evidence to switch.

---

## 11) Deviation Monitor (Off‑route Detection)
### 11.1 Threshold logic
Deviation threshold is **speed adaptive**:
- $T_{high} = base + k \cdot v$
- $T_{low} = hysteresisRatio \cdot T_{high}$

This prevents false positives at high speed while still being strict at low speed.

### 11.2 State machine
- If offset > high → `offroute = true`
- If offset < low → `offroute = false`
- If offroute for `sustainDuration` → `sustained = true`

---

## 12) Reroute Policy & Execution
### 12.1 Policy gates
- Must be online.
- Must satisfy cooldown (default 20s).

### 12.2 Execution flow
1) Validate that destination/alarm settings exist.
2) Check termination policy first.
3) Request new route.
4) Validate new route constraints.
5) Register new route and activate.

### 12.3 Failure handling
- Track failed reroutes.
- If too many failures, consider termination.

---

## 13) Tracking Termination Policy
Tracking can be terminated if:
- Deviation is extreme (>= 5km) and stopped/slow
- Deviation >= 2km for >= 10 minutes with repeated reroute failures
- Moving away from destination for multiple checks

---

## 14) Sensor Fusion + EKF Orchestration
The EKF is created when:
- `enableEkf == true`
- A valid RouteGeometry exists

It receives:
- **IMU samples** for prediction
- **GPS fixes** for correction

It emits:
- `EkfPublicState` containing progress, velocity, mode flags

---

## 15) EKF Pipeline (State + Filters)
### 15.1 State
- $s$ = progress meters
- $v$ = velocity
- $b$ = acceleration bias

### 15.2 Prediction step
- $s \leftarrow s + v dt + 0.5(a-b) dt^2$
- $v \leftarrow (v + (a-b) dt) \cdot damping$

### 15.3 GPS update
- Innovation gating:
  - $|\nu| > 5\sigma$ → hard reset
  - $3\sigma < |\nu| \le 5\sigma$ → soft reject (inflate P)
  - otherwise normal update
- GPS speed is fused into velocity

### 15.4 ZUPT update
Forces velocity toward 0 and adjusts bias.

### 15.5 Station snap update
Softly pulls $s$ and $v$ toward station meter when station is confirmed.

### 15.6 Public progress
- Normal mode: monotonic `s` to avoid backward jumps.
- Degraded mode: raw `s` to avoid freezing dead‑reckoning.

---

## 16) Station Association
Used in metro mode when stationary:
- Requires ZUPT confirmation + dwell time
- Uses adaptive window based on $\sigma_s$
- If one candidate, snap to that station
- If multiple candidates and not degraded, reject

---

## 17) ZUPT (Zero‑Velocity Update)
Detects stationary periods using:
- IMU variance
- Low velocity thresholds

In degraded mode, it can confirm ZUPT even if velocity drifted.

---

## 18) Motion Classification
Determines motion state:
- Hard gate: if |v| > 1.0 m/s, classify as vehicle (normal mode)
- Degraded mode: rely on IMU statistics instead of velocity

---

## 19) GPS Degradation Detector
Tracks:
- Missing GPS fixes
- Poor accuracy
- Large innovations

Enters degraded mode after consecutive bads; exits after sustained good fixes.

---

## 20) Degraded Mode Policy
Used when:
- GPS is unreliable
- $\sigma_s$ too large
- ZUPT missing for too long

Recovery occurs when:
- GPS quality improves
- ZUPT resumes

---

## 21) Tilt Filter (Gravity Estimation)
A complementary filter to isolate gravity:
- Integrates gyroscope over time
- Uses accelerometer to correct drift when stable
- Adjusts blend aggressiveness based on motion state

This provides **linear acceleration** used by EKF prediction.

---

## 22) Failure Handling, Resets, and Edge Cases
- Hard reset on large GPS innovation errors
- Full‑route snap fallback when local window fails
- ETA uncertainty inflates when speed → 0
- Degraded mode prevents EKF stalling when GPS is absent

---

## 23) Configuration, Hardcoded Values, and Rationale
The following constants are hardcoded for stability and user experience:
- **`metroScheduledSpeedMps = 9.2`**: approximates metro average including stop spacing.
- **`metroDwellTimePerStopSec = 25`**: typical station dwell in metro systems.
- **`stopSpeedThreshold` / `stopTimeThresholdMs`**: avoid flickering “stopped” detection.
- **`switchMarginMeters`**: prevents route flipping on minor differences.
- **`sustainDuration`**: ensures deviations or switches are real, not transient GPS error.
- **`postSwitchBlackout`**: prevents rapid oscillation.

These values balance:
- Responsiveness vs. stability
- ETA realism vs. optimism
- Route adherence vs. tolerance of GPS noise

---

## 24) Operational Guidance & Debugging
- Use ETA engine output to verify remaining distance and dwell effect.
- Use SnapToRoute output to debug offsets and segment index.
- Use EKF public state to verify degraded mode and progress monotonicity.
- If alarms fire early/late, compare ETA engine vs EKF progress inputs.

---

# End of Reference
This document is the authoritative reference for the current behavior. If you add new heuristics or constants, update this file to preserve correctness.
