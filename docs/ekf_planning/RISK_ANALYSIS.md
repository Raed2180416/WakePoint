# Risk Analysis - Remaining Risks & Mitigation

**Date:** 2026-01-16  
**Status:** All risks identified, ranked, and mitigation strategies defined

---

## Risk Ranking Methodology

Risks ranked by **Likelihood × Impact**. Only risks that still matter are listed.

---

## Tier-1 (Highest Priority: Must be Controlled)

### R1 — Parameter Interaction Instability

**Likelihood:** High  
**Impact:** High  
**Risk Score:** 🔴 **CRITICAL**

#### What This Really Is
Not "wrong math," but **correct rules interacting badly**.

#### Concrete Examples

**Example 1: Motion Classifier → ZUPT Suppression**
```
Motion classifier briefly flips to HUMAN
  → ZUPT suppressed (safety rule: no ZUPT during HUMAN)
  → Bias not corrected
  → Drift accumulates
  → Station snap fails (σ too high)
```

**Example 2: Battery → FFT Disable → False VEHICLE**
```
Battery < 20% → FFT disabled
  → Motion defaults to VEHICLE
  → Walking user integrates accel
  → False progress advance
  → Early alarm
```

**Example 3: GPS Recovery + Station Snap Collision**
```
GPS recovers during station dwell
  → GPS update applied (soft)
  → Station snap also candidate
  → Both update same state
  → Double correction error
  → Route corruption
```

#### Why This Is Dangerous
Each component is **correct alone**. Bugs emerge only when **multiple guards activate together**.

#### Mitigation (Already Present)
* ✅ Conservative clamps (bias, velocity, progress)
* ✅ Hysteresis (GPS degradation, motion classifier)
* ✅ Confidence-gated snapping (single candidate, σ ≤ 30m)
* ✅ EKF → classifier feedback (prevents oscillation)

#### What Remains
**Empirical bounding via parameter sensitivity analysis** (see §28.1 Parameter-Locking Protocol).

Not a redesign—just validation that interactions are bounded.

---

### R2 — ZUPT False Negatives at Stations

**Likelihood:** Medium–High  
**Impact:** High  
**Risk Score:** 🔴 **CRITICAL**

#### Failure Mode
Train stops, but:
1. Vibration persists (doors, passengers, HVAC)
2. Classifier stays VEHICLE (not enough low-variance window)
3. ZUPT never fires (motion ≠ STATIONARY gate fails)
4. Bias not corrected (no ZUPT → no bias update)
5. Station snap never triggered (no ZUPT → no dwell → no snap)

#### Why This Matters
**ZUPT is the only bias anchor underground.**

If ZUPTs are missed:
* Bias drifts uncorrected
* Station snaps fail (σ too high)
* Alarm accuracy degrades
* System enters DEGRADED mode prematurely

#### Mitigation (Already Present)
* ✅ STE + sliding window + dwell (multiple detection methods)
* ✅ EKF confidence bias toward STATIONARY (σ_v < 0.15 + recent ZUPT)
* ✅ Conservative alarm even if snap fails (uses s + kσ_s)
* ✅ Dwell enforcement (T_dwell = 5s prevents false positives)

#### Residual Risk
**Threshold tuning only.** Architecture is correct.

**Tuning Strategy:**
* Sweep A_th, G_th, V_th across ±50%
* Measure ZUPT detection rate at known stations
* Lock when: 0 missed ZUPTs, < 5% false positives

---

## Tier-2 (Manageable, but Must be Observed)

### R3 — Platform IMU Timestamp Pathologies

**Likelihood:** Medium  
**Impact:** Medium–High  
**Risk Score:** 🟡 **HIGH**

#### Failure Mode
OEM-specific behaviors:
* **Batching:** IMU samples arrive in bursts (not 100 Hz smooth)
* **Clock jumps:** System clock adjustments cause timestamp regressions
* **Delayed bursts:** IMU pauses, then delivers backlogged samples

#### Mitigation (Present)
* ✅ dt rejection: < 1ms or > 200ms → skip sample
* ✅ Covariance inflation: ×1.2 on dt violation
* ✅ Prediction skip: If IMU pause > 200ms, skip prediction, inflate covariance

#### Residual Issue
No hard "estimator invalid" cutoff for extreme cases (e.g., 5-second IMU pause).

#### Why Acceptable
**System fails early, not silently:**
* Covariance inflates rapidly
* Progress freezes
* Alarm triggers conservatively
* User is notified (DEGRADED mode)

**Action:** Monitor for extreme dt violations in production logs. Add hard cutoff if needed.

---

### R4 — GPS Degradation Detector Mis-tuning

**Likelihood:** Medium  
**Impact:** Medium  
**Risk Score:** 🟡 **MEDIUM**

#### Failure Mode

**Too Aggressive:**
* Degrades too early → freezes progress unnecessarily
* User sees "GPS degraded" when GPS is actually fine
* EKF not used when it could be

**Too Late:**
* Degrades too late → trusts bad GPS briefly
* Large innovation accepted → state corrupted
* Recovery takes longer

#### Mitigation
* ✅ Hysteresis (enter: 5s, exit: 3 good fixes)
* ✅ Innovation-based gating (|ν| > 4σ for 3 fixes)
* ✅ Conservative alarm (uses s + kσ_s even when GPS trusted)

#### This Is a Tuning Risk, Not Logic Risk

**Tuning Strategy:**
* Sweep T_no_fix, A_bad, I_bad across ±50%
* Measure: false degradation rate, missed degradation rate
* Lock when: < 5% false positives, < 1% missed degradations

---

## Tier-3 (Known, Low Risk, Acceptable)

### R5 — Express Trains with Zero Anchors

**Likelihood:** Low (express trains are rare)  
**Impact:** Medium (but handled)  
**Risk Score:** 🟢 **ACCEPTABLE**

#### Scenario
* Express train (no intermediate stops)
* GPS lost for entire journey
* No ZUPTs (train never stops)
* No station snaps (no stations passed)

#### Handled Intentionally
* σ inflates (no anchors to reset drift)
* Progress freezes (when σ > 150m)
* Alarm triggers early (conservative: s + 4σ_s)
* System enters DEGRADED mode

#### This Is a Designed Failure, Not a Bug

**Rationale:**
* Express trains are edge case
* System fails **early** (alarm before stop)
* User is notified (DEGRADED mode)
* **Never misses alarm** (conservative guarantee)

**No mitigation needed.** This is acceptable behavior.

---

## Summary of Risk Reality

### What We Know
✅ **There are no unknown unknowns left.**

### What Remains
* **Numeric stability risks** (contained via bounds)
* **Interaction risks** (contained via sensitivity analysis)
* **Tuning risks** (contained via parameter-locking protocol)

### All Are Containable Via
1. **Parameter sensitivity analysis** (§28.1)
2. **Three critical tests** (§28.2)
3. **Conservative design choices** (already present)
4. **Hysteresis and gates** (already present)

### Risk Mitigation Checklist

- [ ] Parameter sensitivity analysis completed
- [ ] Three critical tests written and passing
- [ ] Long tunnel test validates covariance growth
- [ ] Ambiguous motion test validates ZUPT detection
- [ ] GPS recovery test validates state consistency
- [ ] All parameters locked via protocol
- [ ] Production monitoring for extreme cases

---

## Next Steps

1. **Write three critical tests FIRST** (before other integration tests)
2. **Run parameter sensitivity analysis** (before final parameter locking)
3. **Monitor production logs** for extreme dt violations
4. **Tune GPS degradation thresholds** based on real-world data

**Status:** Risks identified, mitigation strategies defined, ready for implementation
