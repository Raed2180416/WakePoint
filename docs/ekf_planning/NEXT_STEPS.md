# EKF Implementation Next Steps (Extreme Detail)

**Date:** 2026-01-16
**Mode:** Test-First (MANDATORY)

---

## Phase 0 — Readiness & Decisions (No Code Yet)

### 0.1 Resolve Open Questions (spec lock-in)
**Owner action:** decide or confirm values; record in this file.
- Tilt filter LPF type and cutoff (default 0.8 Hz per plan). Choose IIR vs FIR; document coefficients.
- Variance window size `Wg` (default 0.75 s). Confirm and document.
- EKF process noise defaults: `sigma_accel`, `sigma_bias`, and scaling factors per mode.
- Measurement noise defaults: `R_gps`, `R_zupt`, `R_station` (locked values exist for ZUPT and station; GPS uses max(accuracy^2, 25^2)).
- Innovation gates: soft reject at 3σ, hard reset at 5σ (locked) — confirm numeric σ usage.
- GPS degradation thresholds: `T_no_fix`, `A_bad`, `I_bad`, `N_bad`, `T_hold`, `N_good`.
- Motion classifier thresholds: variance cutoffs, FFT bands, window length (2.56 s) and overlap (50%).
- ZUPT thresholds: `V_th`, `A_th`, `G_th`, `T_zupt`, dwell `T_dwell` (5 s).
- Station snap margin and dwell (margin = 50 m; dwell = 20 s, per spec).
- Alarm `k` values: normal=2, degraded=3, hard=4 (locked). Decide if any ramp.
- Logging format and storage limits.

**Deliverable:** Update `docs/ekf_planning/DECISIONS_LOG.md` with numeric values.

### 0.2 Codebase Wiring Validation (read-only)
- Identify existing IMU ingestion code and timestamp usage.
- Confirm `SensorFusionManager` and `LocationStreamHandler` integration points per implementation plan.
- Confirm any existing route geometry helpers to reuse.

**Deliverable:** Update `docs/ekf_planning/WIRING_NOTES.md` with file paths and notes.

---

## Phase 1 — Test Infrastructure (Create Files & Helpers)

### 1.1 Create directories
- test/core/ekf/
- test/services/ekf_integration/
- test/fixtures/imu_data/
- test/helpers/

### 1.2 Create test helpers
- `test/helpers/ekf_test_helpers.dart`
  - Deterministic IMU stream generators (accel + gyro).
  - Synthetic GPS projection helpers.
  - Route geometry fixtures (short straight, L-shape, curved).
  - Timebase utilities (monotonic timestamps).

### 1.3 Fixtures
- `test/fixtures/imu_data/` contains small synthetic datasets for repeatable unit tests.

**Exit Criteria:** Helpers compile, tests can import them.

---

## Phase 2 — Mandatory Critical Integration Tests (Write First)

### 2.1 `long_tunnel_no_stops_test.dart`
**Goal:** Validate degraded mode behavior under GPS loss + no ZUPTs.
**Steps:**
1. Start EKF with GPS fix (valid init).
2. Simulate GPS loss for 10–15 minutes.
3. Feed IMU with train-like vibration, no ZUPT.
4. Assert σ_s grows > 150 m; progress freezes; alarm uses k=4 path.

### 2.2 `ambiguous_station_stop_test.dart`
**Goal:** Validate ZUPT confirmation + station snap gating under motion oscillation.
**Steps:**
1. Oscillate motion state; feed partial GPS.
2. Ensure ZUPT confirms only after dwell.
3. Validate single-candidate snap only after ZUPT.

### 2.3 `gps_recovery_large_innovation_test.dart`
**Goal:** Validate soft update for 3–5σ innovation and update ordering.
**Steps:**
1. Drift EKF to σ_s ~ 100 m.
2. Inject GPS offset ~ 3.2σ.
3. Assert soft update, not hard reset; monotonic `s_pub`.
4. Evaluate station snap after GPS update.

**Exit Criteria:** These three tests compile and fail (expected) prior to implementation.

---

## Phase 3 — Unit Tests by Stage (Write Before Implementation)

### 3A Tilt Filter
- test/core/ekf/tilt_filter_test.dart
- Cover initialization, gravity estimation, gyro integration, variance gating, ZUPT reset, edge cases, performance.

### 3B Route Geometry
- test/core/ekf/route_geometry_test.dart
- Focus on projection, tangent continuity, interpolation, edge cases.

### 3C Progress Estimator (EKF Core)
- test/core/ekf/progress_estimator_test.dart
- Prediction dynamics, measurement updates, bounds, covariance, mode transitions.

### 3D GPS Degradation Detector
- test/core/ekf/gps_degradation_detector_test.dart
- Hysteresis, thresholds, recovery.

### 3E Motion Classifier
- test/core/ekf/motion_classifier_test.dart
- Feature extraction + EKF feedback bias.

### 3F ZUPT Detector
- test/core/ekf/zupt_detector_test.dart
- STE + dwell + gating + safety.

### 3G Station Association
- test/core/ekf/station_association_test.dart

### 3H Degraded Mode
- test/core/ekf/degraded_mode_test.dart

**Exit Criteria:** All unit tests compile and fail (expected) before any implementation.

---

## Phase 4 — Implementation (Only After Tests Exist)

### 4.1 Core files (new)
- lib/core/ekf/tilt_filter.dart
- lib/core/ekf/route_geometry.dart
- lib/core/ekf/gps_degradation_detector.dart
- lib/core/ekf/motion_classifier.dart
- lib/core/ekf/zupt_detector.dart
- lib/core/ekf/progress_estimator.dart

### 4.2 Integration wiring
- lib/services/sensor_fusion.dart (replace placeholder)
- lib/services/tracking/location_stream_handler.dart
- lib/services/stop_logic_engine.dart
- lib/services/tracking_state_store.dart

**Implementation order (minimize dependency churn):**
1. route_geometry → tilt_filter → progress_estimator
2. gps_degradation_detector
3. motion_classifier → zupt_detector → station_association
4. sensor_fusion manager orchestration
5. alarm integration wiring

---

## Phase 5 — Regression, Performance, Real Data
- Run all existing tests; fix regressions immediately.
- Implement and run `test/performance/ekf_performance_test.dart`.
- Implement and run `test/integration/ekf_logged_data_test.dart`.

---

## Phase 6 — Acceptance & Freeze
**Must be true:**
- All new unit/integration tests pass.
- All 445 existing tests pass.
- Performance targets met.
- No regressions in alarms.

---

## Decision Log (Fill In)
Create/Update `docs/ekf_planning/DECISIONS_LOG.md` with all final numeric values.

## Wiring Notes (Fill In)
Create/Update `docs/ekf_planning/WIRING_NOTES.md` with exact integration points.
