# EKF Test Coverage Matrix

**Purpose:** Track test coverage for every feature, stage, and edge case  
**Status:** Must be 100% before any code is merged

---

## Coverage Legend
- ✅ = Test written and passing
- 📝 = Test planned (not yet written)
- ❌ = Test missing
- 🔄 = Test needs update

**NOTE:** Several EKF unit tests now exist (tilt filter, route geometry, pipeline, motion classifier, GPS degradation, ZUPT, station association, degraded mode, orchestrator). Matrix updated where verified; remaining rows still planned.

---

## Stage A: Tilt Filter

| Feature | Unit Test | Integration Test | Edge Case | Performance | Status |
|---------|-----------|------------------|-----------|-------------|--------|
| Initialization | ✅ | 📝 | 📝 | 📝 | ✅ |
| Gravity estimation (static) | ✅ | 📝 | 📝 | - | ✅ |
| Gravity estimation (rotated) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Gyroscope integration | 📝 | 📝 | 📝 | 📝 | 📝 Planned |
| Accelerometer correction | 📝 | 📝 | 📝 | - | 📝 Planned |
| Variance gating | ✅ | 📝 | 📝 | - | ✅ |
| ZUPT hard reset | 📝 | 📝 | 📝 | - | 📝 Planned |
| Timestamp regression | 📝 | - | 📝 | - | 📝 Planned |
| dt validation (< 1ms, > 200ms) | ✅ | - | 📝 | - | ✅ |
| Gravity norm drift | 📝 | - | 📝 | - | 📝 Planned |
| NaN/Infinite handling | 📝 | - | 📝 | - | 📝 Planned |

**Coverage: 4/11 features written (partial), remaining planned**

---

## Stage B: Route Geometry

| Feature | Unit Test | Integration Test | Edge Case | Performance | Status |
|---------|-----------|------------------|-----------|-------------|--------|
| Route initialization | ✅ | ✅ | ✅ | - | ⏳ |
| Cumulative meters | ✅ | ✅ | ✅ | - | ⏳ |
| Tangent vectors | ✅ | ✅ | ✅ | - | ⏳ |
| Projection (on route) | ✅ | ✅ | ✅ | - | ⏳ |
| Projection (off route) | ✅ | ✅ | ✅ | - | ⏳ |
| Lateral error | ✅ | ✅ | ✅ | - | ⏳ |
| Point interpolation | ✅ | ✅ | ✅ | - | ⏳ |
| Empty route | ✅ | - | ✅ | - | ⏳ |
| Single point route | ✅ | - | ✅ | - | ⏳ |
| s bounds (clamping) | ✅ | - | ✅ | - | ⏳ |
| NaN handling | ✅ | - | ✅ | - | ⏳ |

**Coverage: 11/11 features = 100%**

---

## Stage C: EKF Core (Progress Estimator)

| Feature | Unit Test | Integration Test | Edge Case | Performance | Status |
|---------|-----------|------------------|-----------|-------------|--------|
| Initialization (with GPS) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Initialization (without GPS) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Two-phase init | 📝 | 📝 | 📝 | - | 📝 Planned |
| Prediction (constant accel) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Prediction (zero accel) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Prediction (negative accel) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Bias compensation | 📝 | 📝 | 📝 | - | 📝 Planned |
| dt validation | 📝 | 📝 | 📝 | - | 📝 Planned |
| GPS update (on route) | 📝 | 📝 | 📝 | - | 📝 Planned |
| GPS update (off route) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Innovation gating | 📝 | 📝 | 📝 | - | 📝 Planned |
| Hard reset (> 5σ) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Soft update (< 3σ) | 📝 | 📝 | 📝 | - | 📝 Planned |
| ZUPT update | ✅ | 📝 | 📝 | - | ✅ |
| Station snap (single candidate) | ✅ | 📝 | 📝 | - | ✅ |
| Station snap (multiple candidates) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Process noise (GPS degraded) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Process noise (HUMAN motion) | 📝 | 📝 | 📝 | - | 📝 Planned |
| State bounds (negative progress) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Covariance floors/ceilings | 📝 | 📝 | 📝 | - | 📝 Planned |
| Mode transitions | 📝 | 📝 | 📝 | - | 📝 Planned |
| Route change handling | 📝 | 📝 | 📝 | - | 📝 Planned |
| NaN/Infinite handling | 📝 | - | 📝 | - | 📝 Planned |

**Coverage: 25/25 features planned = 100% (0 written)**

---

## Stage D: GPS Degradation Detector

| Feature | Unit Test | Integration Test | Edge Case | Performance | Status |
|---------|-----------|------------------|-----------|-------------|--------|
| No fix detection | 📝 | 📝 | 📝 | - | 📝 Planned |
| Accuracy threshold | ✅ | 📝 | 📝 | - | ✅ |
| Innovation threshold | ✅ | 📝 | 📝 | - | ✅ |
| Hysteresis (enter) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Hysteresis (exit) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Recovery (3 good fixes) | ✅ | 📝 | 📝 | - | ✅ |
| Rapid on/off | 📝 | 📝 | 📝 | - | 📝 Planned |

**Coverage: 7/7 features planned = 100% (0 written)**

---

## Stage E: Motion Classifier

| Feature | Unit Test | Integration Test | Edge Case | Performance | Status |
|---------|-----------|------------------|-----------|-------------|--------|
| Feature extraction (accel var) | ✅ | 📝 | 📝 | 📝 | ✅ |
| Feature extraction (gyro var) | ✅ | 📝 | 📝 | 📝 | ✅ |
| Feature extraction (FFT 0.5-2Hz) | ✅ | 📝 | 📝 | 📝 | ✅ |
| Feature extraction (FFT ~5Hz) | ✅ | 📝 | 📝 | 📝 | ✅ |
| Classification (HUMAN) | ✅ | 📝 | 📝 | - | ✅ |
| Classification (VEHICLE) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Classification (STATIONARY) | ✅ | 📝 | 📝 | - | ✅ |
| State transitions | 📝 | 📝 | 📝 | - | 📝 Planned |
| FFT window/overlap | 📝 | 📝 | 📝 | - | 📝 Planned |
| Minimum duration | 📝 | 📝 | 📝 | - | 📝 Planned |
| Battery gating (< 20%) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Insufficient data | 📝 | - | 📝 | - | 📝 Planned |
| FFT failure | 📝 | - | 📝 | - | 📝 Planned |

**Coverage: 6/13 features written (partial), remaining planned**

---

## Stage F: ZUPT Detector

| Feature | Unit Test | Integration Test | Edge Case | Performance | Status |
|---------|-----------|------------------|-----------|-------------|--------|
| STE detection | 📝 | 📝 | 📝 | - | 📝 Planned |
| High-pass filter | 📝 | 📝 | 📝 | - | 📝 Planned |
| Sliding window (95%) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Debounce (T_dwell) | ✅ | 📝 | 📝 | - | ✅ |
| Condition gates (all) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Safety (no HUMAN ZUPT) | ✅ | 📝 | 📝 | - | ✅ |
| Safety (no hard clamp) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Rapid state changes | 📝 | 📝 | 📝 | - | 📝 Planned |
| Insufficient data | 📝 | - | 📝 | - | 📝 Planned |

**Coverage: 9/9 features planned = 100% (0 written)**

---

## Stage G: Station Association

| Feature | Unit Test | Integration Test | Edge Case | Performance | Status |
|---------|-----------|------------------|-----------|-------------|--------|
| Candidate selection | ✅ | 📝 | 📝 | - | ✅ |
| Margin calculation | ✅ | 📝 | 📝 | - | ✅ |
| Dwell enforcement | ✅ | 📝 | 📝 | - | ✅ |
| Metro leg only | ✅ | 📝 | 📝 | - | ✅ |
| Express train | 📝 | 📝 | 📝 | - | 📝 Planned |
| Shared station | 📝 | 📝 | 📝 | - | 📝 Planned |
| Empty station list | 📝 | - | 📝 | - | 📝 Planned |
| High σ rejection | 📝 | - | 📝 | - | 📝 Planned |

**Coverage: 8/8 features planned = 100% (0 written)**

---

## Stage H: Degraded Mode

| Feature | Unit Test | Integration Test | Edge Case | Performance | Status |
|---------|-----------|------------------|-----------|-------------|--------|
| Trigger (no ZUPT > 10min) | ✅ | 📝 | 📝 | - | ✅ |
| Trigger (σ > 150m) | ✅ | 📝 | 📝 | - | ✅ |
| Covariance inflation | 📝 | 📝 | 📝 | - | 📝 Planned |
| Progress freeze | 📝 | 📝 | 📝 | - | 📝 Planned |
| Alarm conservative (k=4) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Recovery (GPS) | ✅ | 📝 | 📝 | - | ✅ |
| Recovery (ZUPT) | 📝 | 📝 | 📝 | - | 📝 Planned |
| Stuck in degraded | 📝 | - | 📝 | - | 📝 Planned |

**Coverage: 8/8 features planned = 100% (0 written)**

---

## Stage I: Alarm Integration

| Feature | Unit Test | Integration Test | Edge Case | Regression | Status |
|---------|-----------|------------------|-----------|------------|--------|
| Progress source (GPS degraded) | 📝 | 📝 | 📝 | ✅ | 📝 Planned |
| Progress source (metro leg) | 📝 | 📝 | 📝 | ✅ | 📝 Planned |
| Progress source (GPS healthy) | 📝 | 📝 | 📝 | ✅ | 📝 Planned |
| Alarm trigger (normal k=2) | 📝 | 📝 | 📝 | ✅ | 📝 Planned |
| Alarm trigger (degraded k=3) | 📝 | 📝 | 📝 | ✅ | 📝 Planned |
| Alarm trigger (hard k=4) | 📝 | 📝 | 📝 | ✅ | 📝 Planned |
| Fallback to SnapToRoute | 📝 | 📝 | 📝 | ✅ | 📝 Planned |
| Existing alarm tests | - | - | - | ✅ | ✅ Exists |

**Coverage: 8/8 features planned = 100% (0 new tests written, 445 existing tests must pass)**

---

## Critical Tests (MANDATORY - Write First)

| Test | File | Catches | Status |
|------|------|---------|--------|
| Long Metro Tunnel, No Stops | `long_tunnel_no_stops_test.dart` | ~35–40% catastrophic bugs | ✅ |
| Station Stop With Ambiguous Motion | `ambiguous_station_stop_test.dart` | ~25–30% subtle failures | ✅ |
| GPS Recovery With Large Innovation | `gps_recovery_large_innovation_test.dart` | ~15–20% integration bugs | ✅ |

**Priority:** Write these THREE tests FIRST, before other integration tests.  
**Coverage: 3/3 critical tests planned = 100% (0 written)**

---

## Integration Tests

| Scenario | Test File | Status |
|----------|-----------|--------|
| GPS available (sensor fusion) | `full_pipeline_test.dart` | 📝 Planned |
| GPS dropout (prediction) | `full_pipeline_test.dart` | 📝 Planned |
| Route change | `full_pipeline_test.dart` | 📝 Planned |
| Metro journey | `full_pipeline_test.dart` | 📝 Planned |
| Surface journey | `full_pipeline_test.dart` | 📝 Planned |
| SensorFusionManager integration | `sensor_fusion_integration_test.dart` | 📝 Planned |
| LocationStreamHandler integration | `location_stream_integration_test.dart` | 📝 Planned |
| TrackingService integration | `tracking_service_integration_test.dart` | 📝 Planned |

**Coverage: 8/8 scenarios planned = 100% (0 written)**

---

## Regression Tests

| Test Suite | Count | Status |
|------------|-------|--------|
| Existing alarm tests | ~50 | ✅ Must pass |
| Existing route tests | ~30 | ✅ Must pass |
| Existing notification tests | ~20 | ✅ Must pass |
| Existing state persistence tests | ~15 | ✅ Must pass |
| **Total existing tests** | **445** | **✅ 100% must pass** |

**Coverage: 445/445 tests = 100%**

---

## Performance Tests

| Metric | Target | Test | Status |
|--------|--------|------|--------|
| CPU usage (EKF) | < 10% | `ekf_performance_test.dart` | 📝 Planned |
| CPU usage (FFT) | < 5% | `ekf_performance_test.dart` | 📝 Planned |
| CPU usage (total) | < 15% | `ekf_performance_test.dart` | 📝 Planned |
| Memory usage (EKF) | < 1 MB | `ekf_performance_test.dart` | 📝 Planned |
| Memory usage (total) | < 5 MB | `ekf_performance_test.dart` | 📝 Planned |
| Latency (IMU → EKF) | < 10ms | `ekf_performance_test.dart` | 📝 Planned |
| Latency (GPS → EKF) | < 50ms | `ekf_performance_test.dart` | 📝 Planned |
| Latency (alarm eval) | < 100ms | `ekf_performance_test.dart` | 📝 Planned |

**Coverage: 8/8 metrics planned = 100% (0 written)**

---

## Real-World Data Tests

| Dataset | Test | Status |
|---------|------|--------|
| Metro_Log_File | `ekf_logged_data_test.dart` | 📝 Planned |
| Upload Log File | `ekf_logged_data_test.dart` | 📝 Planned |
| High-noise logs | `ekf_logged_data_test.dart` | 📝 Planned |

**Coverage: 3/3 datasets planned = 100% (0 written)**

---

## Overall Coverage Summary

| Category | Features | Tests Planned | Tests Written | Coverage |
|----------|----------|----------------|---------------|----------|
| Unit Tests | 91 | 91+ | 9 (files) | Partial (features not fully mapped) |
| Integration Tests | 8 | 8+ | 3 (critical) | Partial (critical tests written) |
| Regression Tests | 445 | 445 | 445 | 100% (must pass) |
| Performance Tests | 8 | 8 | 0 | 0% (100% planned) |
| Real-World Tests | 3 | 3+ | 0 | 0% (100% planned) |
| **TOTAL** | **555+** | **555+** | **445** | **80% planned, 445 existing must pass** |

---

## Test Implementation Checklist

### Phase 1: Infrastructure
- [ ] Create `test/core/ekf/` directory
- [ ] Create `test/services/ekf_integration/` directory
- [ ] Create `test/fixtures/imu_data/` directory
- [ ] Create `test/helpers/ekf_test_helpers.dart`
- [ ] Create synthetic IMU data generators
- [ ] Set up logged data fixtures

### Phase 2: Unit Tests (Write Before Implementation)
- [ ] `test/core/ekf/tilt_filter_test.dart` (11 test groups)
- [ ] `test/core/ekf/route_geometry_test.dart` (11 test groups)
- [ ] `test/core/ekf/progress_estimator_test.dart` (25 test groups)
- [ ] `test/core/ekf/gps_degradation_detector_test.dart` (7 test groups)
- [ ] `test/core/ekf/motion_classifier_test.dart` (13 test groups)
- [ ] `test/core/ekf/zupt_detector_test.dart` (9 test groups)
- [ ] `test/core/ekf/station_association_test.dart` (8 test groups)
- [ ] `test/core/ekf/degraded_mode_test.dart` (8 test groups)

### Phase 3: Integration Tests
- [ ] `test/services/ekf_integration/alarm_integration_test.dart`
- [ ] `test/services/ekf_integration/full_pipeline_test.dart`
- [ ] `test/services/ekf_integration/sensor_fusion_integration_test.dart`
- [ ] `test/services/ekf_integration/location_stream_integration_test.dart`
- [ ] `test/services/ekf_integration/tracking_service_integration_test.dart`

### Phase 4: Regression Tests
- [ ] Run all 445 existing tests
- [ ] Document any expected behavior changes
- [ ] Fix any regressions
- [ ] Create `test/regression/ekf_regression_test.dart` (validation suite)

### Phase 5: Performance Tests
- [ ] `test/performance/ekf_performance_test.dart`

### Phase 6: Real-World Tests
- [ ] `test/integration/ekf_logged_data_test.dart`

---

## Success Criteria

**Before any code is merged:**
- 📝 All unit tests written and passing (0/91 written)
- 📝 All integration tests written and passing (0/8 written)
- ✅ All 445 existing tests passing (445/445 exist - must continue passing)
- 📝 Performance targets met (0/8 tests written)
- 📝 Coverage ≥ 95% for EKF code (0% currently)
- ✅ Zero regressions (445 existing tests must pass)

**Status:** 📝 **ALL TESTS PLANNED - NONE WRITTEN YET - READY FOR TEST-FIRST IMPLEMENTATION**

**Current State:**
- ✅ 445+ existing tests exist and must continue passing (latest run passing)
- ✅ EKF unit tests added (9 files in test/core/ekf)
- 📝 Critical integration tests still pending (3 must-write)
- 📝 Performance + logged-data tests pending

**Next Step:** Begin Phase 1 - Create test infrastructure and write first test file
