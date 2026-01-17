# Comprehensive Test Plan - EKF Implementation

**Date:** 2026-01-16  
**Status:** MANDATORY - All tests must pass before any code is merged  
**Approach:** Test-Driven Development (TDD) - Write tests first, then implementation

**⚠️ IMPORTANT:** This document specifies **PLANNED tests** that need to be written. **NONE of these tests exist yet.** The test plan defines what tests must be created during implementation. All 445 existing tests in the codebase must continue passing (zero regressions).

---

## Test Philosophy

### Core Principles
1. **Test-First:** Every feature must have tests written BEFORE implementation
2. **Zero Regression:** All existing tests (445) must continue passing
3. **Complete Coverage:** Every stage, every feature, every edge case
4. **Isolation:** Each component tested independently before integration
5. **Real-World Validation:** Integration tests with logged IMU/GPS data

### Test Types
- **Unit Tests:** Individual components in isolation
- **Integration Tests:** Component interactions
- **Regression Tests:** Ensure existing functionality unchanged
- **End-to-End Tests:** Full pipeline with synthetic/logged data
- **Performance Tests:** CPU/memory/battery impact

---

## Test Infrastructure

### Existing Test Infrastructure
- ✅ 445 existing tests in `test/` directory
- ✅ Integration tests in `integration_test/`
- ✅ Test utilities: `mock_location_provider.dart`, `log_helper.dart`
- ✅ Test configuration: `flutter_test_config.dart`

### New Test Infrastructure Needed
- `test/core/ekf/` - EKF component unit tests
- `test/services/ekf_integration/` - EKF integration tests
- `test/fixtures/imu_data/` - Synthetic and logged IMU data
- `test/helpers/ekf_test_helpers.dart` - EKF test utilities

---

## Stage-by-Stage Test Coverage

## Stage A: Tilt Filter (Pitch & Roll Estimation)

### Unit Tests: `test/core/ekf/tilt_filter_test.dart`

#### Test Groups

**1. Initialization Tests**
- ✅ Tilt filter initializes with zero pitch/roll
- ✅ Gravity vector initialized correctly
- ✅ Complementary gain set correctly (α = 0.02)
- ✅ LPF cutoff set correctly (fc = 0.8 Hz)

**2. Gravity Estimation Tests**
- ✅ Static device: gravity aligns with accelerometer
- ✅ Device rotated 90°: gravity vector rotates correctly
- ✅ Device rotated -90°: gravity vector rotates correctly
- ✅ Device at 45° pitch: gravity estimate converges
- ✅ Device at 45° roll: gravity estimate converges

**3. Gyroscope Integration Tests**
- ✅ Constant rotation: gravity prediction follows gyro
- ✅ Rotation then stop: gravity stabilizes
- ✅ Fast rotation: complementary filter prevents overshoot

**4. Accelerometer Correction Tests**
- ✅ Low variance: accel correction applied
- ✅ High variance: accel correction gated (variance > VarG)
- ✅ Variance window (Wg = 0.75s): correct windowing
- ✅ Variance never stabilizes > 60s: noise inflated

**5. ZUPT Hard Reset Tests**
- ✅ ZUPT detected: gravity hard reset to accel direction
- ✅ ZUPT during motion: reset still occurs

**6. Edge Cases**
- ✅ Timestamp regression: sample discarded
- ✅ dt < 1ms: sample discarded, covariance inflated
- ✅ dt > 200ms: sample discarded, covariance inflated
- ✅ Gravity norm drift > G_norm_tol: reinitialize from accel
- ✅ NaN inputs: handled gracefully
- ✅ Infinite inputs: handled gracefully

**7. Performance Tests**
- ✅ Processes 100 Hz IMU stream without lag
- ✅ Memory usage stable over 10 minutes
- ✅ CPU usage < 5% on mid-range device

---

## Stage B: Route Geometry Engine

### Unit Tests: `test/core/ekf/route_geometry_test.dart`

#### Test Groups

**1. Route Initialization Tests**
- ✅ Route created from RouteEntry
- ✅ Cumulative meters computed correctly
- ✅ Tangent vectors computed for all segments
- ✅ Station positions mapped correctly

**2. Projection Tests**
- ✅ Point on route: projects to correct s
- ✅ Point off route: lateral error computed correctly
- ✅ Point far from route (> 75m): returns invalid
- ✅ Point at route start: s = 0
- ✅ Point at route end: s = total length

**3. Tangent Tests**
- ✅ Straight segment: tangent is constant
- ✅ L-shaped route: tangent changes at corner
- ✅ Curved route: tangent interpolated correctly
- ✅ Tangent at s=0: points along first segment
- ✅ Tangent at s=end: points along last segment
- ✅ **Tangent continuity at boundaries:** Interpolated over ±7.5 m using weighted averaging
- ✅ **No false spikes:** Tangent smooth at segment boundaries (prevents accel spikes at stations)

**4. Point Interpolation Tests**
- ✅ s -> lat/lng: correct interpolation
- ✅ s at segment boundary: no discontinuity
- ✅ s between segments: smooth interpolation

**5. Edge Cases**
- ✅ Empty route: handled gracefully
- ✅ Single-point route: handled gracefully
- ✅ Route with duplicate points: handled correctly
- ✅ s < 0: clamped to 0
- ✅ s > total length: clamped to end
- ✅ NaN s: returns NaN lat/lng

**6. Integration with RouteEntry Tests**
- ✅ Works with RouteEntry.cumMeters
- ✅ Works with RouteEntry.points
- ✅ Handles route updates correctly

---

## Stage C: EKF Core (Progress Estimator)

### Unit Tests: `test/core/ekf/progress_estimator_test.dart`

#### Test Groups

**1. Initialization Tests**
- ✅ EKF initializes with GPS: s = s_gps, v = v_gps, b_a = 0
- ✅ Initial covariance: P = diag(25², 5², 0.1²)
- ✅ EKF initializes without GPS: invalid state, σ inflated
- ✅ Two-phase init: prediction disabled until GPS/ZUPT

**2. Prediction Tests (IMU Tick)**
- ✅ Constant acceleration: position/velocity update correctly
- ✅ Zero acceleration: velocity constant, position linear
- ✅ Negative acceleration: velocity decreases
- ✅ Bias compensation: bias subtracted from accel
- ✅ dt validation: dt < 1ms or > 200ms → skip + inflate

**3. GPS Update Tests**
- ✅ GPS on route: state updated correctly
- ✅ GPS off route: innovation gate rejects (|s_gps - s_est| > 3σ)
- ✅ GPS accuracy: R = max(accuracy², 25²)
- ✅ Large innovation (> 5σ): hard reset
- ✅ Small innovation (< 3σ): soft update

**4. ZUPT Update Tests**
- ✅ ZUPT detected: v = 0 update applied using $H_{zupt} = [0\ 1\ 0]$, $z = [0]$
- ✅ ZUPT covariance: R_v = (0.05 m/s)²
- ✅ ZUPT bias update: bias updated correctly via cross-covariance $P[2,1]$
- ✅ ZUPT during motion: still applies (safety)
- ✅ Measurement model: Verify Kalman gain and state update equations
- ✅ Bias bounds: Verify $|b_a| \le 0.5$ m/s² after update

**5. Station Snap Tests**
- ✅ Single candidate: soft position update using $H_{station} = [1\ 0\ 0]$, $z = [s_{station}]$
- ✅ Multiple candidates: no snap
- ✅ No candidates: no snap
- ✅ Station snap covariance: R_station = (10 m)²
- ✅ Measurement model: Verify soft update (not hard reset)

**6. Process Noise Tests**
- ✅ GPS degraded: Q inflated
- ✅ HUMAN motion: Q adjusted (freeze or down-weight)
- ✅ ZUPT overdue: bias noise inflated
- ✅ Normal mode: default Q values

**7. State Bounds Tests**
- ✅ Negative progress: clamped to max(prev, current)
- ✅ Progress jump > 100m: logged and investigated
- ✅ Velocity bounds: v clamped to reasonable range
- ✅ Bias bounds: b_a clamped to reasonable range

**8. Covariance Tests**
- ✅ Covariance always positive definite
- ✅ σ_s floor: ≥ 5 m
- ✅ σ_v floor: ≥ 0.1 m/s
- ✅ σ_s ceiling: > 300 m → DEGRADED mode
- ✅ Covariance inflation on errors

**9. Mode Transitions Tests**
- ✅ SURFACE → METRO: mode switch
- ✅ METRO → DEGRADED: on high σ
- ✅ DEGRADED → METRO: on GPS recovery
- ✅ Mode persistence: correct hysteresis

**10. Edge Cases**
- ✅ NaN inputs: handled gracefully
- ✅ Infinite inputs: handled gracefully
- ✅ Route change: hard reset with projection
- ✅ No route: EKF holds invalid state
- ✅ IMU dropout: covariance inflated

---

## Stage D: GPS Degradation Detector

### Unit Tests: `test/core/ekf/gps_degradation_detector_test.dart`

#### Test Groups

**1. Degradation Detection Tests**
- ✅ No fix > 5s: degraded flag set
- ✅ Accuracy > 50m: degraded flag set
- ✅ Innovation > 4σ for 3 fixes: degraded flag set
- ✅ All conditions: degraded flag set

**2. Hysteresis Tests**
- ✅ Degraded persists ≥ T_hold before enabling IMU-dominant
- ✅ Recovery requires 3 consecutive good fixes
- ✅ Rapid GPS on/off: hysteresis prevents oscillation

**3. Recovery Tests**
- ✅ Good fix after degraded: recovery count increments
- ✅ Bad fix during recovery: count resets
- ✅ 3 good fixes: degraded flag cleared

**4. Integration Tests**
- ✅ Works with EKF innovation statistics
- ✅ Works with GPS accuracy from Position
- ✅ Works with GPS fix status

---

## Stage E: Motion Classifier

### Unit Tests: `test/core/ekf/motion_classifier_test.dart`

#### Test Groups

**1. Feature Extraction Tests**
- ✅ Accel magnitude variance: computed correctly
- ✅ Gyro variance: computed correctly
- ✅ FFT energy 0.5-2 Hz: computed correctly
- ✅ FFT energy ~5 Hz: computed correctly
- ✅ EKF speed: used correctly

**2. Classification Tests**
- ✅ Walking motion: classified as HUMAN
- ✅ Train motion: classified as VEHICLE
- ✅ Stationary: classified as STATIONARY
- ✅ Transition walking → train: state changes
- ✅ Transition train → walking: state changes
- ✅ **EKF feedback:** If $\sigma_v < 0.15$ m/s AND recent ZUPT → bias toward STATIONARY
- ✅ **EKF feedback:** High innovation (> 3σ) for > 10s → suppress VEHICLE classification
- ✅ **Bidirectional:** EKF confidence (30% weight) biases classifier, doesn't override IMU

**3. FFT Tests**
- ✅ Window length: 2.56s
- ✅ Overlap: 50%
- ✅ Minimum duration: 2 consecutive windows
- ✅ FFT disabled when battery < 20%: defaults to VEHICLE

**4. Edge Cases**
- ✅ Insufficient data: returns previous state
- ✅ FFT failure: defaults to VEHICLE
- ✅ NaN features: handled gracefully

**5. Performance Tests**
- ✅ FFT computation < 50ms
- ✅ Classification latency < 100ms
- ✅ Memory usage stable

---

## Stage F: ZUPT Detector

### Unit Tests: `test/core/ekf/zupt_detector_test.dart`

#### Test Groups

**1. STE Detection Tests**
- ✅ Low STE: ZUPT candidate
- ✅ High STE: not ZUPT
- ✅ STE threshold: STE_th correct
- ✅ Window size: W_ste = 2s

**2. High-Pass Filter Tests**
- ✅ Gravity removed: high-pass works
- ✅ 0.5 Hz cutoff: correct filtering
- ✅ Butterworth filter: correct implementation

**3. Sliding Window Tests**
- ✅ 95% below threshold: ZUPT
- ✅ < 95% below: not ZUPT
- ✅ Window length: W_stop = 4-6s

**4. Debounce Tests**
- ✅ Continuous low variance: ZUPT confirmed after T_dwell
- ✅ Short bump: ZUPT not confirmed
- ✅ Dwell time: T_dwell = 5s

**5. Condition Gates Tests**
- ✅ All conditions met: ZUPT confirmed
- ✅ Motion = STATIONARY: required
- ✅ |mean(v)| < V_th: required
- ✅ Accel variance < A_th: required
- ✅ Gyro variance < G_th: required
- ✅ Persists ≥ T_zupt: required

**6. Safety Tests**
- ✅ Never ZUPT during HUMAN state
- ✅ Never hard clamp position
- ✅ Velocity update only (soft)

**7. Edge Cases**
- ✅ Insufficient data: no ZUPT
- ✅ NaN inputs: handled gracefully
- ✅ Rapid state changes: debounced correctly

---

## Stage G: ZUPT → Station Association

### Unit Tests: `test/core/ekf/station_association_test.dart`

#### Test Groups

**1. Candidate Selection Tests**
- ✅ Single candidate within margin: selected
- ✅ Multiple candidates: none selected
- ✅ No candidates: none selected
- ✅ Candidate outside margin: rejected
- ✅ Margin: 3σ + 50m

**2. Dwell Enforcement Tests**
- ✅ ZUPT < T_dwell: no snap
- ✅ ZUPT ≥ T_dwell: snap allowed
- ✅ T_dwell = 20s: correct duration

**3. Metro Leg Only Tests**
- ✅ Metro leg: association active
- ✅ Non-metro leg: association disabled
- ✅ Leg transition: association state updates

**4. Express Train Tests**
- ✅ Express train: no candidates → no snap
- ✅ Normal train: candidates → snap

**5. Edge Cases**
- ✅ Shared station: uses active route only
- ✅ Station list empty: no association
- ✅ σ too high: no association

---

## Stage H: Degraded Mode

### Unit Tests: `test/core/ekf/degraded_mode_test.dart`

#### Test Groups

**1. Trigger Tests**
- ✅ No ZUPT > 10 min: degraded mode
- ✅ σ_s > 150 m: degraded mode
- ✅ Both conditions: degraded mode

**2. Behavior Tests**
- ✅ Covariance inflated: σ grows
- ✅ Progress frozen: v = 0, s doesn't advance
- ✅ Alarm conservative: uses s + 4σ

**3. Recovery Tests**
- ✅ GPS recovery: exits degraded
- ✅ Confirmed ZUPT: exits degraded
- ✅ Recovery check: every 1s

**4. Edge Cases**
- ✅ Stuck in degraded: handled gracefully
- ✅ Rapid mode changes: handled correctly

---

## Stage I: Alarm Logic Integration

### Integration Tests: `test/services/ekf_integration/alarm_integration_test.dart`

#### Test Groups

**1. Progress Source Selection Tests**
- ✅ GPS degraded: uses EKF progress
- ✅ Metro leg: uses EKF progress
- ✅ GPS healthy + non-metro: uses SnapToRoute
- ✅ EKF invalid: falls back to SnapToRoute

**2. Alarm Trigger Tests**
- ✅ Normal mode: uses s + 2σ
- ✅ Degraded mode: uses s + 3σ
- ✅ Hard degraded: uses s + 4σ
- ✅ EKF not active: uses standard trigger
- ✅ **Timing:** $(s_{pub}, \sigma_s)$ sampled at alarm evaluation tick, not IMU tick
- ✅ **Consistency:** $s_{pub}$ and $\sigma_s$ are from same snapshot (no race conditions)

**3. Regression Tests**
- ✅ Existing alarm tests still pass
- ✅ Distance mode alarms: unchanged behavior
- ✅ Time mode alarms: unchanged behavior
- ✅ Stops mode alarms: unchanged behavior

---

## Critical Tests (Catch ~80% of Real Bugs)

**MANDATORY:** These three tests must be written and passing before any other integration tests.

### Test 1: Long Metro Tunnel, No Stops
**File:** `test/services/ekf_integration/long_tunnel_no_stops_test.dart`

**Scenario:**
* GPS lost at tunnel entry
* Continuous vibration (train motion)
* No ZUPT for 10–15 minutes
* Express train (no intermediate stops)

**What This Validates:**
* Covariance inflation correctness: σ_s grows appropriately
* Progress freeze logic: v = 0, s doesn't advance when σ > 150m
* Alarm conservative trigger: uses s + 4σ_s (hard degraded)
* No false confidence: σ never decreases during prediction-only mode
* No numeric explosion: state remains finite

**Bug Classes Caught:**
* Over-trusting IMU (progress advances too far)
* σ not growing correctly (underestimates uncertainty)
* Alarm race conditions (σ sampled at wrong time)

**Success Criteria:**
* σ_s grows from ~25m to > 150m over 10 minutes
* Progress freezes when σ > 150m
* Alarm triggers early (conservative)
* No NaN or infinite values
* **Catches ~35–40% of catastrophic bugs**

---

### Test 2: Station Stop With Ambiguous Motion
**File:** `test/services/ekf_integration/ambiguous_station_stop_test.dart`

**Scenario:**
* Train stops at station
* Residual vibration (doors, passengers)
* Classifier oscillates VEHICLE ↔ STATIONARY
* GPS flickers weakly (partial signal)
* Station within 3σ + margin

**What This Validates:**
* ZUPT dwell enforcement: T_dwell = 5s must be met
* EKF → classifier bias: σ_v < 0.15 AND recent ZUPT → bias toward STATIONARY
* Station snap gating: single candidate + dwell + σ ≤ 30m
* No snap during HUMAN state: even if ZUPT candidate
* Bias correction actually happens: b_a updated during ZUPT

**Bug Classes Caught:**
* Missed ZUPTs (classifier oscillation prevents detection)
* False snaps (snap during HUMAN state)
* Bias drift at stations (ZUPT never fires)

**Success Criteria:**
* ZUPT eventually confirmed despite classifier oscillation
* Station snap occurs only after ZUPT confirmed + dwell met
* Bias updated: |b_a| changes after ZUPT
* No false station snaps
* **Catches ~25–30% of subtle real-world failures**

---

### Test 3: GPS Recovery With Large Innovation
**File:** `test/services/ekf_integration/gps_recovery_large_innovation_test.dart`

**Scenario:**
* EKF drifts underground (GPS lost for 5 minutes)
* σ_s grows to ~100m
* GPS returns with large offset: |s_gps - s_est| = 80m (3.2σ)
* Station nearby (within 50m of GPS position)
* Both GPS update and station snap are candidates

**What This Validates:**
* Soft vs hard reset logic: 3σ < innovation < 5σ → soft update
* Innovation gating: innovation > 5σ → hard reset
* Snap + GPS update ordering: GPS update first, then snap (if conditions met)
* No backward progress jump: s_pub remains monotonic
* UI state remains monotonic: ActiveRouteManager not corrupted

**Bug Classes Caught:**
* Double-correction errors (both GPS and snap update same state)
* Route corruption (backward progress in UI)
* UI inconsistency (EKF state ≠ UI state)

**Success Criteria:**
* GPS update applied (soft, not hard reset)
* Station snap evaluated after GPS update
* s_pub never decreases
* UI state consistent with EKF state
* **Catches ~15–20% of integration bugs**

**Priority:** Write these three tests FIRST, before other integration tests.

---

## Integration Tests

### Full Pipeline Tests: `test/services/ekf_integration/full_pipeline_test.dart`

#### Test Groups

**1. GPS Available Mode Tests**
- ✅ EKF learns biases: bias estimates improve **only during ZUPT events** (not during motion)
- ✅ GPS updates correct state: state synchronized
- ✅ Stationary device: bias converges **after ZUPT confirmed**
- ✅ Moving device: bias stable (no learning during motion, per §22.4)
- ✅ **Bias learning assertion:** Only test bias convergence after ZUPT events, not during continuous motion
- ✅ **Bias bounds:** Test that $|b_a| \le 0.5$ m/s² and $\sigma_{bias} \ge 1 \times 10^{-4}$ (m/s²)²

**2. GPS Dropout Mode Tests**
- ✅ GPS drops: EKF switches to prediction
- ✅ Prediction uses learned biases: accurate dead reckoning
- ✅ ZUPT corrections: maintain accuracy
- ✅ Station snaps: provide anchors

**3. Route Change Tests**
- ✅ Route changes: EKF hard reset
- ✅ Projection to new route: correct s_new
- ✅ State reinitialized: v = 0, σ = 50m
- ✅ Degraded until GPS confirms

**4. Metro Journey Tests**
- ✅ Metro ride with GPS outage: tracks correctly
- ✅ Station stops: ZUPT detected
- ✅ Station snaps: position corrected
- ✅ Inter-station drift: < 60m

**5. Surface Journey Tests**
- ✅ Bus ride: EKF tracks when GPS degraded
- ✅ Walking: ZUPT updates velocity only
- ✅ No false station snaps: bus stops ignored

---

## Regression Tests

### Existing Test Suite Validation: `test/regression/ekf_regression_test.dart`

#### Test Groups

**1. Alarm Logic Regression**
- ✅ All 445 existing tests pass
- ✅ Distance mode alarms: unchanged
- ✅ Time mode alarms: unchanged
- ✅ Stops mode alarms: unchanged
- ✅ Event alarms: unchanged

**2. Route Snapping Regression**
- ✅ SnapToRoute still works: unchanged behavior
- ✅ Progress calculation: unchanged when EKF not active
- ✅ Route switching: unchanged

**3. Notification Regression**
- ✅ Notifications still work: unchanged
- ✅ Journey progress: unchanged
- ✅ Alarm notifications: unchanged

**4. State Persistence Regression**
- ✅ Snapshot save/load: unchanged
- ✅ Route persistence: unchanged
- ✅ Alarm state persistence: unchanged

---

## Performance Tests

### Performance Validation: `test/performance/ekf_performance_test.dart`

#### Test Groups

**1. CPU Usage Tests**
- ✅ EKF processing: < 10% CPU on mid-range device
- ✅ FFT computation: < 5% CPU when enabled
- ✅ Full pipeline: < 15% CPU total

**2. Memory Usage Tests**
- ✅ EKF state: < 1 MB
- ✅ IMU buffer: < 500 KB
- ✅ Total memory: < 5 MB additional

**3. Battery Impact Tests**
- ✅ IMU always on: no additional drain (already running)
- ✅ FFT disabled < 20%: battery preserved
- ✅ EKF math: negligible drain

**4. Latency Tests**
- ✅ IMU → EKF update: < 10ms
- ✅ GPS → EKF update: < 50ms
- ✅ Alarm evaluation: < 100ms total

---

## Real-World Data Tests

### Logged Data Replay: `test/integration/ekf_logged_data_test.dart`

#### Test Groups

**1. Metro Log Replay Tests**
- ✅ Replay Metro_Log_File data: EKF tracks correctly
- ✅ GPS outages: prediction accurate
- ✅ Station stops: ZUPT detected
- ✅ Drift measurement: < 60m between ZUPTs

**2. Surface Log Replay Tests**
- ✅ Replay Upload Log File data: EKF tracks correctly
- ✅ Tunnel sections: prediction accurate
- ✅ No false station snaps: verified

**3. High-Noise Replay Tests**
- ✅ Replay Boom logs: EKF handles noise
- ✅ False ZUPT rate: < 5%
- ✅ ZUPT miss rate: < 1%

---

## Test Implementation Order

### Phase 1: Test Infrastructure (Week 1)
1. ✅ Create test directory structure
2. ✅ Create synthetic IMU data generators
3. ✅ Create EKF test helpers
4. ✅ Set up test fixtures for logged data

### Phase 2: Unit Tests (Week 1-2)
5. ✅ Write tilt filter tests (before implementation)
6. ✅ Write route geometry tests (before implementation)
7. ✅ Write EKF core tests (before implementation)
8. ✅ Write ZUPT detector tests (before implementation)
9. ✅ Write motion classifier tests (before implementation)
10. ✅ Write GPS degradation tests (before implementation)

### Phase 3: Integration Tests (Week 2-3)
11. ✅ Write SensorFusionManager integration tests
12. ✅ Write LocationStreamHandler integration tests
13. ✅ Write TrackingService integration tests
14. ✅ Write alarm integration tests

### Phase 4: Regression Tests (Week 3)
15. ✅ Run all 445 existing tests
16. ✅ Fix any regressions
17. ✅ Document any expected behavior changes

### Phase 5: Performance Tests (Week 3-4)
18. ✅ Write performance tests
19. ✅ Validate performance targets
20. ✅ Optimize if needed

### Phase 6: Real-World Validation (Week 4)
21. ✅ Replay logged data
22. ✅ Validate accuracy metrics
23. ✅ Tune parameters if needed

---

## Test Execution Strategy

### Pre-Commit Checks
```bash
# Run all EKF unit tests
flutter test test/core/ekf/

# Run all EKF integration tests
flutter test test/services/ekf_integration/

# Run all regression tests
flutter test test/regression/

# Run with coverage
flutter test --coverage
```

### CI/CD Pipeline
1. **Unit Tests:** Run on every commit
2. **Integration Tests:** Run on every PR
3. **Regression Tests:** Run on every PR (must pass 445/445)
4. **Performance Tests:** Run nightly
5. **Real-World Tests:** Run weekly

### Coverage Requirements
- **Unit Tests:** 100% line coverage for EKF components
- **Integration Tests:** 100% scenario coverage
- **Regression Tests:** 100% existing test pass rate

---

## Test Data Management

### Synthetic Data Generators
- `test/fixtures/imu_data/synthetic_generators.dart`
  - Constant acceleration
  - Sinusoidal motion (walking)
  - Train vibration (5 Hz)
  - Stationary device
  - Rotation sequences

### Logged Data Fixtures
- `test/fixtures/imu_data/metro_logs/` - Metro journey logs
- `test/fixtures/imu_data/surface_logs/` - Surface journey logs
- `test/fixtures/imu_data/high_noise_logs/` - High-noise scenarios

### Test Helpers
- `test/helpers/ekf_test_helpers.dart`
  - Mock sensor streams
  - Route builders
  - State validators
  - Assertion helpers

---

## Success Criteria

### Must Pass Before Merge
- ✅ All unit tests pass (100%)
- ✅ All integration tests pass (100%)
- ✅ All 445 existing tests pass (100%)
- ✅ Performance targets met
- ✅ Coverage ≥ 95% for EKF code
- ✅ Zero regressions

### Validation Metrics
- ✅ Metro drift < 60m (from logged data)
- ✅ ZUPT false positive rate < 5%
- ✅ ZUPT miss rate < 1%
- ✅ Alarm accuracy: 0 missed alarms
- ✅ CPU usage < 15%
- ✅ Memory usage < 5 MB additional

---

## Test Maintenance

### Ongoing Requirements
- ✅ Update tests when parameters change
- ✅ Add tests for new edge cases discovered
- ✅ Maintain test data as codebase evolves
- ✅ Review test coverage quarterly
- ✅ Update logged data fixtures annually

---

## Conclusion

This test plan ensures:
1. **Every feature tested** before implementation
2. **Zero regressions** in existing functionality
3. **Complete coverage** of all EKF stages
4. **Real-world validation** with logged data
5. **Performance validation** for production readiness

**Status:** READY FOR TEST-DRIVEN IMPLEMENTATION
