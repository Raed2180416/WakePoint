# FINAL IMPLEMENTATION PLAN: EKF-Based 1D Progress Estimation

## 0. Scope (Locked)
**What the system is**:
*   A 1D progress estimator along a known route (distance-along-route).
*   Optimized for metro/rail/tunnel segments.
*   Uses IMU propagation, ZUPT at stops, and opportunistic GPS.
*   Primary objective: reliable alarm timing.

**What the system is not**:
*   Not free underground navigation.
*   Not pedestrian dead-reckoning.
*   Not long open-loop inertial navigation without stops.

## 1. Operating Modes (Explicit)
The system runs a **Continuous EKF** in all modes. The "Mode" merely dictates measurement availability and confidence assumptions.

| Mode | EKF Behavior | GPS | ZUPT |
| :--- | :--- | :--- | :--- |
| **SURFACE** | Active (1D Projection). | Used as Measurement Update. | Ignored (GPS moves user). |
| **METRO** | Active (1D Propagation). | Opportunistic Update. | CRITICAL for drift correction. |
| **DEGRADED** | Active (Inflated Noise). | Unavailable. | Used to re-anchor/freeze drift. |

> [!NOTE]
> **Surface 1D Constraint**: The EKF projects 2D GPS to 1D route progress. If the user deviates significantly (e.g. > 50m), the existing `DeviationMonitor` detects this. The plan adds a **Reset Link** to re-initialize the EKF to the new route geometry once a reroute occurs.

## 2. Core Architecture

### 2.1 New Core Module: `lib/core/progress_estimator.dart`
**Responsibilities**:
*   EKF state $[s, v, b_a]^T$.
*   Prediction (IMU) @ 100Hz (Continuous).
*   Updates (GPS, ZUPT, Step).
*   Mode management (SURFACE/METRO/DEGRADED).
*   Confidence/Uncertainty tracking.

**Non-responsibilities**:
*   No GPS requests (passive consumer).
*   No power policy changes.
*   No UI logic.
*   **GPS Latency**: EKF `updateGPS` will check `position.timestamp`. If lag > 2s, apply update with increased measurement noise $R$ rather than complex back-propagation (MVP decision for stability).

### 2.2 Public Interface (Conceptual)
```dart
class ProgressEstimator {
  EstimatorState get state; // s_est, v_est, sigma_s, mode
  void predictIMU(Vector3 accel, Vector3 gyro, double dt);
  void updateGPS(double lat, double lng, double accuracy);
  void enterMetro();
  void exitMetro(); 
}
```

## 3. EKF Design (METRO Mode)

### 3.1 State Vector
$x = [s, v, b_{accel}]^T$
*   $s$: distance along route (m)
*   $v$: speed along route (m/s)
*   $b_{accel}$: accelerometer bias (1D)

### 3.2 Prediction (50-100Hz)
1.  **Tangent Projection**: Project world-frame acceleration onto route tangent at current $s$.
    *   $a_{proj} = (a_{world} \cdot \hat{t}) - b_{accel}$
2.  **Propagation**:
    *   $s_{k+1} = s_k + v_k \Delta t + 0.5 a_{proj} \Delta t^2$
    *   $v_{k+1} = v_k + a_{proj} \Delta t$
    *   $b_{k+1} = b_k$ (Bias Random Walk)

### 3.3 Measurements
1.  **GPS (Opportunistic)**:
    *   If valid GPS received, project to route $\rightarrow s_{gps}$.
    *   Update EKF with measurement $z = s_{gps}$.
    *   Noise $R$ scales with reported accuracy and battery mode.
2.  **ZUPT (Zero Velocity) - CRITICAL**:
    *   **Detection**: $|accel - g| < \epsilon$ AND $|gyro| < \epsilon_{gyro}$ for $> 1s$.
    *   **Update**: $z_{vel} = 0$.
    *   **Effect**: Zeros speed, calibrates bias, collapses uncertainty.

## 4. Hard ZUPT Boundary (7 Minutes)
**Constraint**: `MAX_ZUPT_GAP = 7 minutes`
*   **Logic**: Track `time_since_last_zupt`.
*   **Trigger**: If gap $\ge$ 7 mins:
    *   Transition to **DEGRADED** mode.
    *   Aggressively inflate covariance $P$.
    *   Freeze or dampen progress integration to avoid runaway drift.
    *   Alarms become conservative (fire based on worst-case forward progress).
*   **Recovery**: On next ZUPT (stop), collapse covariance, return to **METRO** mode.

## 5. Integration Plan (Incremental)

### Step 1: `RouteGeometry` Class
*   **File**: `lib/core/route_geometry.dart`
*   **Goal**: Precompile polyline into segments with pre-calculated tangents/headings for O(1) projection.

### Step 2: `ProgressEstimator` Logic
*   **File**: `lib/core/progress_estimator.dart`
*   **Goal**: Implement the math (EKF, ZUPT detector, State machine). Unit test with CSV logs.

### Step 3: Service Integration
*   **File**: `lib/services/trackingservice.dart`
*   **Logic**:
    *   Instantiate `ProgressEstimator` in background isolate.
    *   Feed `accelerometerEvents` and `positionStream` to estimator.
    *   **Continuous Output**: Replace `_distanceTravelledMeters` usage with `estimator.state.s` in ALL modes.
    *   **Deviation Handling**: Listen to `DeviationMonitor` stream. On `offroute=true` or Reroute event, call `estimator.reset(newRoute, currentGPS)`.

### Step 4: Alarm Logic Update
*   **File**: `lib/services/trackingservice.dart`
*   **Logic**: Update `_checkAndTriggerAlarm` to use uncertainty:
    *   `remaining = target_s - s_est`
    *   `trigger_threshold = alarm_val + k * sigma_s`
    *   Ensures alarms fire *early* if uncertainty is high (Conservative).

## 6. Risks & Mitigations
| Risk | Mitigation |
| :--- | :--- |
| **Long Walking Underground** | **Limit Scope**: Explicitly unsupported. System expects station stops. DEGRADED mode handles violations safely (by not lying). |
| **Orientation Noise** | **Rotation Vector**: Use fused `UserAccelerometer` or Game Rotation Vector. Fallback to magnitude projection if unavailable (with high noise). |
| **Stationary Drift** | **Aggressive ZUPT**: Tuning ZUPT threshold is critical. False moving > False stop. |

## 7. Implementation & Verification Sequence (Atomic)
This sequence guarantees 100% certainty at each step before moving to the next.

### Phase 1: Geometry & Math (No dependencies)
1.  **Implement `RouteGeometry`**:
    *   Logic: Wrap polyline. Pre-calculate bearings for every segment. Implement `project(lat,lng)` and `getTangent(s)`.
    *   **Test Case 1 (Unit)**: `RouteGeometry_Tangent`. Create a simple L-shape route (North 100m, East 100m).
        *   Query s=50m -> Expect Tangent [1, 0] (North).
        *   Query s=150m -> Expect Tangent [0, 1] (East).
    *   **Test Case 2 (Unit)**: `RouteGeometry_Projection`. Point (5m East of start). Expect s=0, lateral=5.

### Phase 2: The Estimator Core (Pure Dart)
2.  **Implement `ProgressEstimator`**:
    *   Logic: 1D EKF equations. ZUPT detector. timestamp handling.
    *   **Timestamp Solution**: Since `sensors_plus` lacks hardware timestamps, use a dedicated `Stopwatch` tied to the estimator lifecycle. `timestamp = stopwatch.elapsed`.
    *   **Test Case 3 (Simulated Tunnel)**:
        *   Init s=0, v=0.
        *   Feed Accel +1m/s² for 1s (dt=0.1s x 10).
        *   **Assert**: `state.v` ≈ 1.0, `state.s` ≈ 0.5.
    *   **Test Case 4 (ZUPT)**:
        *   Feed noise < threshold.
        *   **Assert**: `state.v` decays to 0. `state.b_a` stabilizes.

### Phase 3: Service Integration (The Harness)
3.  **Wire up `TrackingService`**:
    *   Logic: Instantiate Estimator. Listen to streams.
    *   **Test Case 5 (Black Box)**:
        *   Mock `Geolocator`. Feed GPS at t=0. Feed Accel. Feed GPS at t=60s (Outage).
        *   **Verify**: `_distanceTravelled` continues increasing during outage.

## 8. Feasibility & Gap Analysis
**Assessment**:
*   **StopLogicEngine**: Analyzed `stop_logic_engine.dart`. It is stateless and relies purely on `progressMeters`. **Compatible** without modification.
*   **SnapToRouteEngine**: Lacks tangent/heading output. **Solution**: The new `RouteGeometry` class will wrap `SnapToRouteEngine` and add O(1) tangent lookup.
*   **GPS Timestamps**: `TrackingService` currently uses `DateTime.now()`. **Requirement**: The EKF `updateGPS` method will use `position.timestamp`. For IMU, we will use a monotonic `Stopwatch` to synthesize robust timestamps.
*   **Battery**: Passive listening ensures zero regression. 100Hz EKF loop is lightweight (< 1% CPU).

**APPROVED for Implementation.**
*   The **7-minute hard limit** is the key enabler—it bounds the max error drift.
*   **Continuous EKF** simplifies state management (no mode switching artifacts).
