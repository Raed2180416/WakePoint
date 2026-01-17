# Specification Fixes - Critical Gaps Resolved

**Date:** 2026-01-16  
**Status:** All 6 critical gaps fixed and locked

---

## Summary

Six critical mathematical and logical gaps were identified and fixed. All fixes are minimal (no redesign) and formalize existing procedural descriptions.

---

## Fix 1: EKF Measurement Model Formalization

### Problem
Measurement equations were implicit (procedural), not explicit (mathematical).

### Solution
Added **§4.6 Measurement Models (Locked)** with explicit:
- GPS: $z = [s_{gps}]$, $H = [1\ 0\ 0]$
- ZUPT: $z = [0]$, $H = [0\ 1\ 0]$
- Station snap: $z = [s_{station}]$, $H = [1\ 0\ 0]$

All with standard EKF update equations: $K = P H^T S^{-1}$, $x = x + K\nu$, $P = (I - KH)P$

### Files Updated
- `implementation_plan.md` §4.6
- `MATH_SPECIFICATION.md` (new file with complete math)

### Impact
- Eliminates coding hesitation on measurement dimensions
- Clarifies bias update during ZUPT (via cross-covariance)
- Makes station snap soft update explicit

---

## Fix 2: Route Tangent Continuity

### Problem
Tangent discontinuity at polyline vertices causes false accel spikes at station boundaries (where ZUPT occurs).

### Solution
Added **§3.4 Tangent Continuity Rule (Locked)**:
- Interpolate tangents over ±Δs = 7.5 m at segment boundaries
- Weighted averaging: $t(s) = w_1 t_{left} + w_2 t_{right}$
- Prevents false spikes in $a_{fwd} = \text{dot}(a_{world}, t(s))$

### Files Updated
- `implementation_plan.md` §3.4
- `MATH_SPECIFICATION.md` (route tangent interpolation section)

### Impact
- Prevents motion classifier errors at stations
- Prevents bias pollution from false accel spikes
- Critical for numerical stability

---

## Fix 3: Bidirectional EKF ↔ Motion Classifier Feedback

### Problem
One-way feedback (Motion → EKF) causes unnecessary oscillation. EKF confidence not used to stabilize classifier.

### Solution
Added **§6.5 EKF → Motion Classifier Feedback (Locked)**:
- If $\sigma_v < 0.15$ m/s AND recent ZUPT → bias toward STATIONARY (30% weight)
- If innovation consistently high (> 3σ) for > 10s → suppress VEHICLE
- EKF confidence biases classifier, doesn't override IMU (70% IMU, 30% EKF)

### Files Updated
- `implementation_plan.md` §6.5
- `MATH_SPECIFICATION.md` (motion classifier feedback section)
- `TEST_PLAN.md` (added EKF feedback tests)

### Impact
- Stabilizes classifier in underground metro (where EKF > IMU confidence)
- Prevents oscillation
- Maintains IMU as primary signal

---

## Fix 4: Bias Observability Bounds

### Problem
Bias had no magnitude or covariance bounds, allowing over-fitting and silent divergence.

### Solution
Added to **§22.4 EKF Defaults** and **§29.4 Covariance Floors & Ceilings**:
- Bias magnitude: $|b_a| \le 0.5$ m/s² (hard saturation)
- Bias covariance floor: $\sigma_{bias} \ge 1 \times 10^{-4}$ (m/s²)²

### Files Updated
- `implementation_plan.md` §22.4, §29.4
- `MATH_SPECIFICATION.md` (bias bounds section)
- `TEST_PLAN.md` (added bias bounds tests)

### Impact
- Prevents over-fitting from noisy ZUPTs
- Prevents silent divergence during GPS loss
- Aligns with safety philosophy (floors/ceilings for all state variables)

---

## Fix 5: Alarm Logic σ_s Update Rate

### Problem
Alarm uses $s_{est} + k\sigma_s$ but timing of $(s_{pub}, \sigma_s)$ sampling was undefined.

### Solution
Added **§10.2 Timing Specification (Locked)**:
- Alarm logic samples $(s_{pub}, \sigma_s)$ at **alarm evaluation tick**, not IMU tick
- EKF maintains public state updated at IMU rate
- Alarm reads snapshot at evaluation time (ensures consistency)

### Files Updated
- `implementation_plan.md` §10.2
- `MATH_SPECIFICATION.md` (alarm logic timing section)
- `TEST_PLAN.md` (added timing tests)

### Impact
- Prevents race conditions
- Ensures consistent behavior across devices
- Clarifies that $s_{pub}$ and $\sigma_s$ are from same snapshot

---

## Fix 6: Test Plan Bias Learning Clarification

### Problem
Tests implied continuous bias improvement, but spec says bias only observable during ZUPT.

### Solution
Updated **TEST_PLAN.md** integration tests:
- Clarified: "bias estimates improve **only during ZUPT events** (not during motion)"
- Added: "Bias learning assertion: Only test bias convergence after ZUPT events, not during continuous motion"
- Added bias bounds tests

### Files Updated
- `TEST_PLAN.md` (GPS Available Mode Tests section)

### Impact
- Prevents future test authors from expecting bias learning during motion
- Aligns tests with spec (§22.4: "Bias observable only during ZUPT")
- Clarifies test expectations

---

## New Document Created

### MATH_SPECIFICATION.md
Complete mathematical formalization including:
- State vector and process model
- All measurement models (GPS, ZUPT, station snap)
- Route tangent interpolation
- State and covariance bounds
- Motion classifier feedback
- Alarm logic timing

**Purpose:** Reference document for implementation. All math is explicit and locked.

---

## Verification Checklist

- [x] Fix 1: Measurement models explicit (GPS, ZUPT, station snap)
- [x] Fix 2: Tangent continuity rule specified
- [x] Fix 3: Bidirectional EKF ↔ Motion classifier feedback
- [x] Fix 4: Bias bounds (magnitude and covariance floor)
- [x] Fix 5: Alarm logic timing specification
- [x] Fix 6: Test plan bias learning clarified
- [x] Math specification document created
- [x] All fixes integrated into implementation plan
- [x] Test plan updated with new test requirements

---

## Status

✅ **All 6 critical gaps resolved**  
✅ **All fixes are minimal (no redesign)**  
✅ **All fixes are locked and ready for implementation**  
✅ **Mathematical specification complete**

**No fundamental gaps remain.**
