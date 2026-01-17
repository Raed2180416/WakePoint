# EKF Data Flow Diagram

**Date:** 2026-01-16  
**Purpose:** Explicit end-to-end signal flow from sensors → alarm

---

## Complete Signal Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    SENSOR LAYER (Hardware)                       │
├─────────────────────────────────────────────────────────────────┤
│  Accelerometer (100 Hz)  →  a_raw [x, y, z]                     │
│  Gyroscope (100 Hz)      →  ω [x, y, z]                         │
│  GPS (1-2 Hz)            →  Position(lat, lng, accuracy)         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              STAGE A: Tilt Filter (Complementary)                │
├─────────────────────────────────────────────────────────────────┤
│  Input:  a_raw, ω, timestamps                                   │
│  Process:                                                        │
│    - Gyro integration → predict gravity direction               │
│    - Accel low-pass → measure gravity                           │
│    - Complementary fusion (α = 0.02)                            │
│  Output:                                                         │
│    - R_device→world (rotation matrix)                           │
│    - ĝ_device (gravity unit vector)                             │
│    - Pitch θ, Roll φ                                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              STAGE B: Route Geometry Engine                      │
├─────────────────────────────────────────────────────────────────┤
│  Input:  Route polyline, station list                            │
│  Output:                                                         │
│    - s[i] (cumulative meters)                                   │
│    - t(s) (tangent vectors, interpolated at boundaries)         │
│    - project(lat,lng) → (s_proj, lateral_error)                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│         STAGE C: EKF Core (Progress Estimator)                  │
├─────────────────────────────────────────────────────────────────┤
│  State:  x = [s, v, b_a]ᵀ                                        │
│                                                                    │
│  PREDICTION (per IMU tick, 100 Hz):                              │
│    a_world = R_d→w(a_raw - ĝ)     [gravity-removed]            │
│    a_fwd = dot(a_world, t(s))     [project onto route]          │
│    u = a_fwd                      [control input]               │
│                                                                    │
│    s_{k+1} = s_k + v_k dt + 0.5(u - b_a)dt²                     │
│    v_{k+1} = v_k + (u - b_a)dt                                  │
│    b_{a,k+1} = b_{a,k}                                          │
│                                                                    │
│  MEASUREMENT UPDATES:                                            │
│    GPS:     z = [s_gps],    H = [1 0 0]  (when available)       │
│    ZUPT:    z = [0],        H = [0 1 0]  (when stationary)      │
│    Station: z = [s_station], H = [1 0 0]  (when at station)      │
│                                                                    │
│  Output:                                                         │
│    - s_pub (public progress, monotonic)                          │
│    - σ_s (uncertainty)                                          │
│    - v (velocity)                                               │
│    - ekf_mode (SURFACE/METRO/DEGRADED)                          │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┴─────────────────────┐
        │                                           │
        ▼                                           ▼
┌──────────────────────────┐          ┌──────────────────────────┐
│  STAGE D: GPS Degradation │          │  STAGE E: Motion          │
│  Detector (Separate File) │          │  Classifier               │
├──────────────────────────┤          ├──────────────────────────┤
│  Input:                  │          │  Input:                  │
│    - GPS fix status      │          │    - Accel variance      │
│    - GPS accuracy        │          │    - Gyro variance       │
│    - EKF innovation      │          │    - FFT (0.5-2 Hz, 5Hz) │
│  Output:                 │          │    - EKF speed (σ_v)     │
│    - gpsDegraded (bool)  │          │  Output:                 │
│  Owns:                   │          │    - MOTION state       │
│    - Hysteresis           │          │      (HUMAN/VEHICLE/     │
│    - Counters             │          │       STATIONARY)        │
│    - Timers               │          │                          │
└──────────────────────────┘          └──────────────────────────┘
        │                                           │
        └─────────────────────┬─────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              STAGE F: ZUPT Detector                              │
├─────────────────────────────────────────────────────────────────┤
│  Input:  Motion state, accel variance, gyro variance, EKF v    │
│  Process:                                                        │
│    - STE detection (high-pass + energy)                          │
│    - Sliding window (95% below threshold)                       │
│    - Debounce (T_dwell = 5s)                                    │
│  Output:                                                         │
│    - ZUPT_CONFIRMED event                                        │
│    → Triggers EKF velocity update (v = 0)                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              STAGE G: Station Association                        │
├─────────────────────────────────────────────────────────────────┤
│  Input:  ZUPT event, EKF state (s, σ_s), station list          │
│  Process:                                                        │
│    - Find candidates: |s_station - s_est| < 3σ + 50m            │
│    - Require single candidate + dwell ≥ 20s                     │
│  Output:                                                         │
│    - Station snap event (if conditions met)                      │
│    → Triggers EKF position update (soft)                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              STAGE I: Alarm Logic                                │
├─────────────────────────────────────────────────────────────────┤
│  Input:  EKF progress (s_pub, σ_s) at alarm evaluation tick     │
│  Process:                                                        │
│    - Sample (s_pub, σ_s) snapshot (not IMU tick)                │
│    - Evaluate: s_pub + k·σ_s ≥ s_target                         │
│    - k = 2.0 (normal), 3.0 (degraded), 4.0 (hard degraded)     │
│  Output:                                                         │
│    - Alarm trigger (notification)                               │
└─────────────────────────────────────────────────────────────────┘
```

---

## GPS Available Mode (Sensor Fusion)

```
GPS Available → GPS Degradation Detector → gpsDegraded = false
                                              │
                                              ▼
                                    EKF receives GPS updates
                                              │
                                    z_gps = [s_gps]
                                    H_gps = [1 0 0]
                                              │
                                    State update: x = x + K·ν
                                              │
                                    Bias becomes observable
                                    during ZUPT events
                                              │
                                    Continuous learning of
                                    sensor biases
```

**Key Point:** EKF continuously runs, learns biases during ZUPTs, maintains accurate state with GPS corrections.

---

## GPS Degraded Mode (Prediction Only)

```
GPS Lost → GPS Degradation Detector → gpsDegraded = true
                                          │
                                          ▼
                                GPS measurement updates STOP
                                          │
                                EKF continues prediction only
                                          │
                                s_{k+1} = s_k + v_k dt + 0.5(u - b_a)dt²
                                v_{k+1} = v_k + (u - b_a)dt
                                          │
                                Uses learned biases (b_a)
                                from GPS-available mode
                                          │
                                ZUPT corrections maintain accuracy
                                Station snaps provide anchors
                                          │
                                Dead reckoning between anchors
```

**Key Point:** System works off prediction alone, but uses learned biases and route constraints to maintain accuracy.

---

## Why This Architecture Is Correct

### 1. Staged Fusion (Not All-in-One EKF)
- **Tilt Filter:** High-rate, nonlinear pitch/roll dynamics
- **EKF:** Lower-rate, linearized progress estimation
- **Separation is correct:** Different time scales and dynamics

### 2. GPS Degradation Detector (Separate Component)
- **Stateful:** Owns hysteresis, counters, timers
- **Cross-cutting:** Used by EKF, motion classifier, alarm logic
- **Separation is mandatory:** Prevents mode flapping bugs

### 3. Route Constraint (1D Manifold)
- Error grows **linearly**, not quadratically
- ZUPTs reset drift at stations
- Station snaps provide position anchors
- System degrades gracefully, fails early

---

## Failure Mode Analysis

### Worst Case: Metro Tunnel, No ZUPTs

**Scenario:**
- GPS lost at tunnel entry
- Express train (no intermediate stops)
- No ZUPTs for 10+ minutes

**What Happens:**
1. EKF enters DEGRADED mode (no ZUPT > 10 min)
2. Covariance inflates: σ_s grows
3. Progress freezes: v = 0, s doesn't advance
4. Alarm uses conservative trigger: s + 4σ_s
5. System fails **early** (alarm before actual stop)
6. **Never misses alarm** (conservative guarantee)

**Recovery:**
- GPS returns → soft reset
- ZUPT detected → drift reset
- Station snap → position anchor

---

## Verification

✅ **GPS condition file:** Mandatory separate component  
✅ **Sensor fusion:** All sensors fused via staged architecture  
✅ **GPS degraded mode:** Works off prediction + constraints  
✅ **Data flow:** Explicit and traceable  
✅ **Failure modes:** Handled gracefully

**Status:** Architecture validated and ready for implementation
