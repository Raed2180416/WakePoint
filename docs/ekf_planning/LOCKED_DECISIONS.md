# Locked Decisions - EKF Implementation

**Date:** 2026-01-16  
**Status:** All decisions final, no further changes

---

## Critical Architecture: EKF Usage Model

### Two-Mode Operation (LOCKED)

**Mode 1: Sensor Fusion (GPS Available)**
- EKF continuously runs to **learn sensor biases**
- GPS updates correct EKF state
- Bias estimates improve over time
- State is always synchronized with GPS
- **Purpose:** Calibrate sensors, learn biases, maintain accurate state

**Mode 2: Prediction (GPS Lost)**
- EKF switches to prediction using **learned biases**
- Dead reckoning along route using IMU
- ZUPT corrections maintain accuracy
- Station snaps provide position anchors
- **Purpose:** Continue tracking during GPS outages

**Key Insight:** By learning biases when GPS is available, the EKF has accurate calibration ready when GPS drops. This is the core value proposition.

---

## Factual Corrections

### ✅ IMU Timestamps
- **CORRECT:** `sensors_plus` DOES expose `SensorEvent.timestamp` on Android
- **Value:** Nanoseconds since boot, monotonic
- **Implementation:** Use `SensorEvent.timestamp` as primary timebase
- **Fallback:** Stopwatch only if timestamp is null (rare)
- **Wrapper:** Keep `TimestampedSensorEvent` for abstraction, but source from `SensorEvent.timestamp`

### ✅ Station Snap UI Update
- **CORRECT:** UI/ActiveRouteManager updates remain **gated** per §24.2
- **EKF State:** Always updates internally
- **UI Update:** Only when confidence gates pass (single candidate, σ ≤ 30m, etc.)
- **Rationale:** Prevents false snaps from corrupting route state

---

## All Resolved Ambiguities

### 1. Route Change Handling (LOCKED)
**Decision:** HARD RESET WITH PROJECTION

**Rules:**
- On route change: Discard EKF bias
- Project current GPS (if available) onto new route → `s_new`
- If GPS unavailable: project last known lat/lng from EKF to new route
- Initialize: `s = s_new`, `v = 0`, `σ_s = 50 m`
- Reset: motion classifier, ZUPT timers
- Enter DEGRADED until GPS confirms

**Rationale:** Route changes are semantic resets. Transferring EKF state across routes is unsafe.

---

### 2. Battery Policy Integration (LOCKED)
**Decision:** EKF is battery-agnostic; feature gating only

**Rules:**
- IMU sampling rate: **never modified** (unreliable across OEMs)
- EKF prediction: **always runs** (cheap)
- FFT/Motion classifier: **disabled when battery < 20%**
  - Motion defaults to VEHICLE unless ZUPT detected
- ZUPT: **always active** (cheap)

**Rationale:** Only FFT is expensive. EKF math is cheap. IMU rate control is unreliable.

---

### 3. Simulation/IMU Replay Injection (LOCKED)
**Decision:** Symmetric test streams

**Changes:**
- Add `testGyroscopeStream` to match `testAccelerometerStream`
- `SensorFusionManager` constructor accepts:
  - `Stream<AccelerometerEvent>?`
  - `Stream<GyroscopeEvent>?`
- Simulation mode injects both streams
- No "simulation mode" flag needed; streams define behavior

---

### 4. EKF Initialization Timing (LOCKED)
**Decision:** Two-phase initialization

**Behavior:**
- EKF object created at `LocationStreamHandler.start()`
- Prediction **disabled** until:
  - First GPS fix **OR**
  - First confirmed ZUPT
- Until enabled: EKF holds invalid state, σ inflated, no alarms rely on EKF

**Rationale:** Avoids blind IMU integration at app start.

---

### 5. EKF State Persistence (LOCKED)
**Decision:** MINIMAL PERSISTENCE

**Persist:**
- `s_pub`
- `σ_s`
- `ekf_mode`

**Do NOT persist:**
- bias
- covariance matrix
- velocity

**On resume:**
- Discard IMU backlog
- Reinitialize EKF from GPS
- Treat persisted `s_pub` as hint only

**Rationale:** Bias/velocity are session-specific. Minimal state prevents corruption.

---

### 6. ZUPT on Non-Metro Legs (LOCKED)
**Decision:** Velocity update only

**Rules:**
- On walking/bus/drive legs:
  - ZUPT → `v = 0`, bias update
  - **NO position snap**
  - **NO station association**

**Rationale:** Avoids "bus stop = metro stop" errors.

---

### 7. FFT/Matrix Libraries (LOCKED)
**Decision:** Minimal dependencies

**Choices:**
- **FFT:** Use `fftea` package
- **EKF math:** Custom 3×3 matrices (no external linear algebra dependency in v1)

**Rationale:** Predictability, debuggability, performance.

---

## Implementation Readiness

✅ **All ambiguities resolved**  
✅ **All technical decisions locked**  
✅ **Architecture clarified**  
✅ **Factual corrections applied**

**Status:** READY FOR IMPLEMENTATION
