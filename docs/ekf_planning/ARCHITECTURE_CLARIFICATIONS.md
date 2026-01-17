# Architecture Clarifications - Locked Answers

**Date:** 2026-01-16  
**Status:** All answers locked and integrated into spec

---

## Question 1: Do we need a file to check GPS conditions?

### Answer: **YES - MANDATORY separate file**

**File:** `lib/core/ekf/gps_degradation_detector.dart`

**Why Mandatory (Not Optional):**
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

---

## Question 2: Do these equations actually fuse gyro, accelerometer, pitch & roll, and GPS while GPS is stable?

### Answer: **YES - via staged architecture (correct design)**

**Signal Fusion Chain:**

1. **Gyro + Accelerometer** → **Tilt Filter (Stage A)**
   * Gyro integration → predicts gravity direction (short-term)
   * Accelerometer low-pass → measures gravity (long-term)
   * Complementary fusion (α = 0.02)
   * Output: $R_{device \rightarrow world}$ (rotation matrix)

2. **Accelerometer** → **Gravity Removal**
   * $a_{world} = R_{d\rightarrow w}(a_{raw} - \hat{g})$
   * Gravity-removed acceleration in world frame

3. **Route Geometry** → **Forward Projection**
   * $a_{fwd} = \langle a_{world}, t(s) \rangle$
   * Project onto route tangent (interpolated at boundaries)

4. **Forward Acceleration** → **EKF Control Input**
   * $u = a_{fwd}$
   * EKF prediction uses this as control input

5. **GPS** → **EKF Measurement Update** (when available)
   * $z_{gps} = [s_{gps}]$, $H_{gps} = [1\ 0\ 0]$
   * State update: $x = x + K\nu$

**Why Staged Architecture is Correct:**
* Pitch/roll dynamics are high-rate and nonlinear
* Progress estimation is lower-rate and linearized
* Separation by time scale and dynamics is correct engineering
* Not all-in-one EKF (which would be incorrect)

**While GPS is Stable:**
* EKF runs continuously
* GPS updates apply measurement corrections
* Bias ($b_a$) becomes observable during ZUPTs
* Velocity and position remain anchored
* **Continuous learning of sensor biases** (as designed)

---

## Question 3: Once in a GPS degraded zone, will the model work off prediction alone?

### Answer: **YES - exactly as designed**

**What Happens When GPS Degrades:**

1. **GPS measurement updates STOP**
   * No more $z_{gps}$ updates
   * EKF continues running **prediction step only**

2. **Control Input Still Arrives**
   * $u = a_{fwd}$ at IMU rate (100 Hz)
   * Prediction equations:
     * $s_{k+1} = s_k + v_k \Delta t + \tfrac{1}{2}(u_k - b_a)\Delta t^2$
     * $v_{k+1} = v_k + (u_k - b_a)\Delta t$

3. **Bias is Frozen** (except during ZUPT)
   * Uses learned biases from GPS-available mode
   * Bias becomes observable again during ZUPTs

**Why This Does NOT Explode Immediately:**

### (1) Route Constraint (1D Manifold)
* Error grows **linearly**, not quadratically
* Dead reckoning along constrained route

### (2) ZUPT Updates
* At stations: $v \approx 0$ is enforced
* Bias becomes observable
* Drift is reset
* **Key metro insight:** Stations provide anchors

### (3) Conservative Covariance Growth
* As uncertainty grows: $\sigma_s$ increases
* Alarm logic uses: $s + k\sigma_s$ (conservative)
* Progress may freeze if $\sigma_s > 150$ m
* System fails **early**, not late
* Matches "never miss a stop" guarantee

**What the Model Does NOT Try to Do:**
* ❌ Estimate heading
* ❌ Estimate lateral position
* ❌ Infer intent
* ❌ Trust IMU indefinitely

**What It DOES:**
* ✅ Dead-reckons **between anchors** (ZUPTs, station snaps)
* ✅ Degrades gracefully
* ✅ Refuses to hallucinate confidence
* ✅ Uses learned biases from GPS-available mode

---

## Complete Data Flow

See `DATA_FLOW_DIAGRAM.md` for explicit end-to-end signal flow from sensors → alarm.

**Key Points:**
* Sensors → Tilt Filter → Route Geometry → EKF → Alarm
* GPS Degradation Detector is separate component
* All sensors fused via staged architecture
* GPS degraded mode works off prediction + constraints

---

## Verification

✅ **GPS condition file:** Mandatory separate component (locked)  
✅ **Sensor fusion:** All sensors fused via staged architecture (locked)  
✅ **GPS degraded mode:** Works off prediction + constraints (locked)  
✅ **Data flow:** Explicit and traceable (documented)  
✅ **Failure modes:** Handled gracefully (validated)

**Status:** All clarifications locked and integrated into spec
