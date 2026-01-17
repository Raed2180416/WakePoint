# Critical Analysis of EKF Implementation Plan

**Date:** 2026-01-16  
**Analyst:** AI Code Assistant  
**Plan Version:** Full Implementation Specification (Locked)

---

## Executive Summary

The EKF implementation plan is **comprehensive and fully implementation-ready**. All ambiguities have been resolved with locked decisions.

### ✅ Critical Architecture Clarification
**EKF Usage Model (Locked):**
- **GPS Available:** EKF runs in **sensor fusion mode** - continuously learns sensor biases, calibrates, updates state with GPS corrections
- **GPS Lost:** EKF switches to **prediction mode** - uses learned biases for dead reckoning along route
- This ensures accurate bias estimates are ready when GPS drops, enabling reliable prediction during outages

**Status:** Plan is **fully implementation-ready** with all decisions locked.

---

## 1. Project Understanding

### 1.1 What GeoWake Is
- **Purpose:** Transit alarm app that wakes users before their stop
- **Key Challenge:** GPS dropout in metro tunnels/underground
- **Current Solution:** Placeholder sensor fusion (deprecated, not used)
- **Target Solution:** Full EKF with IMU-based dead reckoning

### 1.2 Current Architecture
```
Foreground (UI)
  └─> TrackingService (singleton facade)
       └─> Background Isolate
            └─> LocationStreamHandler
                 ├─> LocationManager (GPS stream)
                 ├─> SensorFusionManager (DEPRECATED, not wired)
                 └─> EtaEngine, AlarmController, etc.
```

### 1.3 Key Files (Current State)
- `lib/services/sensor_fusion.dart` - **DEPRECATED placeholder** (will be replaced)
- `lib/services/tracking/location_stream_handler.dart` - GPS stream handler
- `lib/services/trackingservice.dart` - Main orchestrator (4400+ lines)
- `lib/services/snap_to_route.dart` - Route snapping engine
- `lib/services/route_registry.dart` - Route storage (has `cumMeters`, `points`)
- `lib/services/transfer_utils.dart` - Transit leg stops (`TransitLegStops.stopMeters`)
- `lib/services/tracking/alarm_controller.dart` - Alarm evaluation (uses `progressMeters`)

---

## 2. Plan Strengths

### 2.1 Comprehensive Coverage
- ✅ All stages defined (Tilt Filter → Route Geometry → EKF → ZUPT → Station Snap)
- ✅ Parameter values locked (section 22)
- ✅ Edge cases documented (section 24)
- ✅ Integration points mapped (section 16, 27)

### 2.2 Real-World Robustness
- ✅ GPS degradation detection with hysteresis
- ✅ Motion classification (HUMAN/VEHICLE/STATIONARY)
- ✅ ZUPT with multiple detection methods
- ✅ Station snapping with confidence gates
- ✅ Degraded mode fail-safes

### 2.3 Codebase Integration Awareness
- ✅ Identifies exact files to modify
- ✅ Preserves existing class names (`SensorFusionManager`)
- ✅ Maps to existing route/alarm infrastructure

---

## 3. Critical Gaps & Ambiguities

### 3.1 RESOLVED: EKF Scope (CLARIFIED)
**Question:** Should EKF run for all sessions or only transit?
**Answer:** ✅ **EKF runs continuously but in two modes:**
- **GPS Available:** Sensor fusion mode - learn biases, calibrate, update state with GPS
- **GPS Lost:** Prediction mode - use learned biases for dead reckoning
**Impact:** EKF is always "running" to learn biases when GPS available, but prediction only activates on GPS dropout. This ensures accurate biases are ready when needed.

### 3.2 RESOLVED: Progress Source Selection (User Answered)
**Question:** When to prefer EKF progress over SnapToRoute?
**Answer:** ✅ **Only when GPS degraded OR on metro leg**
**Impact:** Clear logic: `if (gpsDegraded || isMetroLeg) useEKF() else useSnapToRoute()`

### 3.3 RESOLVED: Station Snap UI Update (CORRECTED)
**Question:** When should station snap update UI?
**Answer:** ✅ **UI/ActiveRouteManager update remains GATED (per §24.2)** - EKF internal state updates always, but UI only updates under confidence gates
**Impact:** Prevents false snaps from corrupting route state; EKF confidence gates are separate from UI update gates

### 3.4 RESOLVED: IMU Timestamps (CORRECTED)
**Question:** How to handle monotonic timestamps?
**Answer:** ✅ **Use SensorEvent.timestamp (nanoseconds since boot) on Android - this IS available in sensors_plus**
**Fallback:** Stopwatch only if timestamp is null (rare)
**Impact:** Keep `TimestampedSensorEvent` wrapper but source from `SensorEvent.timestamp` when present

### 3.5 RESOLVED: Background Isolate (User Answered)
**Question:** Where should EKF components run?
**Answer:** ✅ **All EKF components in background isolate**
**Impact:** Consistent with current architecture; all processing in background

### 3.6 RESOLVED: Route Geometry Helper (User Answered)
**Question:** Where to implement `tangentAt(s)`?
**Answer:** ✅ **New file `lib/core/ekf/route_geometry.dart`**
**Impact:** Clean separation; can wrap `RouteEntry.cumMeters` and `RouteEntry.points`

---

## 4. UNRESOLVED Critical Questions

### 4.1 Sensor Timestamp Implementation Details
**Issue:** Plan requires monotonic timestamps, but `sensors_plus` doesn't expose `SensorEvent.timestamp`.

**Required Clarification:**
- Should we use `Stopwatch` started at EKF initialization?
- How to handle app backgrounding/foregrounding (Stopwatch continues)?
- Should we log timestamp source (hardware vs software) for diagnostics?

**Recommendation:** Implement `TimestampedSensorEvent` wrapper:
```dart
class TimestampedSensorEvent<T> {
  final T event; // AccelerometerEvent or GyroscopeEvent
  final int timestampMicroseconds; // From Stopwatch
  final DateTime wallClockTime; // For logging
}
```

### 4.2 EKF Initialization Timing
**Issue:** Plan says "always running" but doesn't specify when to initialize.

**Questions:**
- Initialize EKF at `LocationStreamHandler.start()` or wait for first GPS?
- What if first GPS arrives after 30 seconds? Should EKF wait or use IMU-only?
- How to handle route changes mid-journey (reroute)?

**Current Code Behavior:**
- `LocationStreamHandler.start()` is called from `TrackingService.startLocationStream()`
- First GPS arrives via `LocationManager().positionStream`
- Route can change via `registerRouteFromDirections()`

**Recommendation:** Initialize EKF at `start()` with route geometry, but don't start prediction until first GPS or confirmed ZUPT.

### 4.3 Route Geometry Update on Route Change
**Issue:** Plan says "update `fusion.setRoute(active route)` when route changes" but doesn't specify how.

**Questions:**
- How does EKF detect route changes? Via callback from `RouteSessionManager`?
- Should EKF reset state on route change, or try to project current `s` to new route?
- What if route change happens during GPS dropout (EKF is primary source)?

**Current Code:**
- Route changes trigger `RouteSwitchEvent` from `RouteSessionManager`
- `TrackingService` listens to `routeSwitchStream`
- `ActiveRouteManager` manages active route key

**Recommendation:** Add `SensorFusionManager.onRouteChanged(String newKey, RouteEntry route)` callback, reset EKF state, project current GPS to new route for initialization.

### 4.4 Battery Policy Integration
**Issue:** Plan mentions "EKF runs even when GPS throttled" but doesn't specify how EKF respects power policy.

**Questions:**
- Should EKF reduce IMU sampling rate when battery is low?
- Should FFT (motion classifier) be disabled in low-power mode?
- How does EKF interact with `PowerPolicyManager`?

**Current Code:**
- `PowerPolicyManager.forBatteryLevel()` returns policy with `gpsDropoutBuffer`
- `LocationStreamHandler` uses policy to set GPS dropout threshold
- No current IMU rate control

**Recommendation:** EKF should NOT change IMU sampling rate (sensors_plus controls that). FFT should be disabled in low-power mode (section 27.2 already mentions this).

### 4.5 Station Snap vs ActiveRouteManager Integration
**Issue:** Plan says station snap updates EKF always, but UI update is gated. User answered "always update UI" but plan has confidence gates.

**Clarification Needed:**
- If user wants "always update UI", should we remove confidence gates?
- Or keep gates but update UI whenever EKF snaps (gates prevent false snaps)?

**Recommendation:** Keep confidence gates in EKF (prevent false snaps), but if EKF decides to snap, always update UI. This matches user's answer.

### 4.6 ZUPT Association with TransitLegStops
**Issue:** Plan uses `TransitLegStops.stopMeters` for station snapping, but doesn't specify how to handle:
- Express trains (skip stops)
- Shared stations (multiple lines)
- Non-metro legs (walking between stations)

**Questions:**
- Should ZUPT association only run on metro legs (`isMetro == true`)?
- How to handle ZUPTs during walking legs (should they be ignored)?
- What if user is stationary at a bus stop (not a metro station)?

**Current Code:**
- `TransitLegStops` has `isMetro` flag
- `stopMeters` is list of cumulative meters for each stop
- Plan section 8.1 says "Metro leg active" precondition

**Recommendation:** Only associate ZUPTs with stations on metro legs. Walking/bus ZUPTs should still trigger velocity update but not position snap.

### 4.7 EKF State Persistence
**Issue:** Plan section 27.9 mentions persisting "EKF mode + last `s_pub`" but doesn't specify format.

**Questions:**
- Should EKF state be in `TrackingStateStore` snapshot?
- What happens on app resume - should EKF restore state or reinitialize?
- How to handle IMU backlog after resume (plan says "discard IMU backlog")?

**Current Code:**
- `TrackingStateStore.loadSnapshot()` restores route, destination, alarm settings
- `LocationStreamHandler` doesn't currently persist EKF state

**Recommendation:** Persist minimal state (`s_pub`, `sigma_s`, `ekf_mode`) in snapshot. On resume, reinitialize EKF from latest GPS (discard IMU backlog as plan states).

### 4.8 Simulation/Testing Integration
**Issue:** Plan mentions "simulation injection via LocationStreamHandler" but doesn't specify how to inject IMU data.

**Questions:**
- Should test IMU streams be injected via `LocationStreamContext`?
- How to replay logged IMU data (section 25 mentions test database)?
- Should EKF have a "simulation mode" that accepts pre-recorded IMU?

**Current Code:**
- `testAccelerometerStream` exists in `TrackingService` and `LocationStreamHandler`
- No `testGyroscopeStream` currently
- Simulation uses `LocationManager().injectPosition()`

**Recommendation:** Add `testGyroscopeStream` to match accelerometer pattern. EKF should accept test streams via constructor (already in plan section 16.3).

---

## 5. Codebase Integration Analysis

### 5.1 File Modification Plan (Verified Against Codebase)

#### ✅ **lib/services/sensor_fusion.dart** - REPLACE ENTIRELY
- **Current:** 167 lines, deprecated placeholder
- **Action:** Complete rewrite with EKF pipeline
- **Keep:** Class name `SensorFusionManager` (minimizes refactors)
- **New Dependencies:** Will need `lib/core/ekf/*` modules

#### ✅ **lib/services/tracking/location_stream_handler.dart** - MODIFY
- **Current:** Lines 483-504 handle GPS dropout, create fusion manager
- **Action:** 
  - Always create `SensorFusionManager` at `start()` (line ~187)
  - Call `fusion.updateGPS()` on every position (line ~200)
  - Call `fusion.setGpsDegraded()` instead of creating new manager (line ~489)
  - Expose EKF progress via getter/callback
- **Risk:** Low - well-isolated changes

#### ✅ **lib/services/trackingservice.dart** - MODIFY
- **Current:** `_resolveAlarmRouteState()` uses SnapToRoute (line ~1023)
- **Action:**
  - Add `_ekfProgressMeters`, `_ekfSigmaMeters` fields
  - Wire EKF callbacks from `LocationStreamHandler`
  - Modify `_resolveAlarmRouteState()` to prefer EKF when degraded/metro
  - Add EKF telemetry to `_broadcastSimulationState()` (line ~638)
- **Risk:** Medium - large file, need careful integration

#### ✅ **lib/core/ekf/route_geometry.dart** - CREATE NEW
- **Purpose:** Provide `tangentAt(s)` and `pointAt(s)` for route
- **Dependencies:** `RouteEntry` from `route_registry.dart`
- **Implementation:** Wrap `RouteEntry.points` and `RouteEntry.cumMeters`

#### ✅ **lib/core/ekf/tilt_filter.dart** - CREATE NEW
- **Purpose:** Stage A - Pitch & Roll estimation
- **Dependencies:** `sensors_plus` (accelerometer, gyroscope)
- **Output:** Gravity-aligned acceleration

#### ✅ **lib/core/ekf/motion_classifier.dart** - CREATE NEW
- **Purpose:** Stage E - Motion classification (HUMAN/VEHICLE/STATIONARY)
- **Dependencies:** FFT (need to add FFT library or implement)
- **Note:** Only runs when GPS degraded (power guard)

#### ✅ **lib/core/ekf/zupt_detector.dart** - CREATE NEW
- **Purpose:** Stage F - ZUPT detection
- **Dependencies:** Tilt filter output, motion classifier
- **Output:** ZUPT events

#### ✅ **lib/core/ekf/progress_estimator.dart** - CREATE NEW
- **Purpose:** Stage C - EKF core (state: s, v, b_a)
- **Dependencies:** Tilt filter, route geometry, ZUPT detector
- **Output:** `EstimatedProgress(s, v, sigma_s)`

#### ✅ **lib/dashboard/unified_dashboard.dart** - MODIFY
- **Current:** Receives `debug_info` via WebSocket (line ~1200+)
- **Action:** 
  - Parse EKF telemetry from `debug_info`
  - Render EKF progress, sigma, motion state in debug panel
  - Add ZUPT markers (red) and station snap markers (cyan)
- **Risk:** Low - additive changes

### 5.2 Integration Risks

#### 🔴 **HIGH RISK: Progress Source Switching**
**Issue:** Switching between EKF and SnapToRoute progress could cause jumps.

**Mitigation:**
- Use hysteresis: once EKF is active, keep using it until GPS recovers AND sigma is low
- Smooth transition: blend EKF and SnapToRoute for 5 seconds during switch
- Log all progress source switches for debugging

#### 🟡 **MEDIUM RISK: Route Change During GPS Dropout**
**Issue:** If route changes while EKF is primary source, how to reinitialize?

**Mitigation:**
- Project current EKF `s` to new route (find closest point)
- Inflate covariance on route change
- Require GPS confirmation before trusting new route

#### 🟡 **MEDIUM RISK: Battery Impact**
**Issue:** Continuous IMU + EKF processing could drain battery.

**Mitigation:**
- FFT only when GPS degraded (already in plan)
- Use efficient EKF implementation (sparse matrices if possible)
- Monitor battery level and log warnings if drain is high

#### 🟢 **LOW RISK: Test Coverage**
**Issue:** Large codebase, need comprehensive tests.

**Mitigation:**
- Unit tests for each EKF stage (tilt filter, ZUPT, etc.)
- Integration test with logged IMU data (section 25)
- Dashboard visualization for manual verification

---

## 6. Technical Implementation Questions

### 6.1 FFT Library Dependency
**Question:** Plan requires FFT for motion classification. What library should we use?

**Options:**
- `fftea` (Dart FFT library)
- `dart:ffi` with native FFT (more complex)
- Custom FFT implementation (not recommended)

**Recommendation:** Use `fftea` package. Add to `pubspec.yaml`.

### 6.2 Matrix Operations
**Question:** EKF requires matrix operations (covariance, Kalman gain). What library?

**Options:**
- `ml_linalg` (Dart linear algebra)
- Custom 3x3 matrix class (EKF state is only 3D: s, v, b_a)
- `dart:math` with manual matrix math

**Recommendation:** For 3D state, custom matrix class is sufficient. Use `ml_linalg` if we need larger matrices later.

### 6.3 Logging Format
**Question:** Plan requires CSV logging. Where should logs be stored?

**Current Code:**
- `AppLogger` exists in `lib/core/logging/app_logger.dart`
- No current CSV logging infrastructure

**Recommendation:** Create `lib/core/ekf/ekf_logger.dart` that writes CSV to app documents directory. Ring buffer (10 MB max) as plan specifies.

### 6.4 Unit Test Data
**Question:** How to test EKF components without real IMU data?

**Recommendation:** 
- Create synthetic IMU data generators (constant acceleration, sinusoidal motion, etc.)
- Use logged data from section 25 test database
- Mock sensor streams in unit tests

---

## 7. Implementation Order Recommendation (TEST-FIRST)

### Phase 1: Test Infrastructure (Week 1)
1. ✅ Create test directory structure (`test/core/ekf/`, `test/services/ekf_integration/`)
2. ✅ Create synthetic IMU data generators
3. ✅ Create EKF test helpers (`test/helpers/ekf_test_helpers.dart`)
4. ✅ Set up logged data fixtures
5. ✅ Add FFT library to `pubspec.yaml`

### Phase 2: Unit Tests + Core Infrastructure (Week 1-2)
6. ✅ **Write tests** for `route_geometry.dart` (11 test groups)
7. ✅ **Implement** `lib/core/ekf/route_geometry.dart` (make tests pass)
8. ✅ **Write tests** for `tilt_filter.dart` (11 test groups)
9. ✅ **Implement** `lib/core/ekf/tilt_filter.dart` (make tests pass)
10. ✅ Create timestamp wrapper for sensor events
11. ✅ **Verify** all existing tests still pass

### Phase 3: Unit Tests + EKF Core (Week 2-3)
12. ✅ **Write tests** for `progress_estimator.dart` (25 test groups)
13. ✅ **Implement** `lib/core/ekf/progress_estimator.dart` (make tests pass)
14. ✅ **Write tests** for `zupt_detector.dart` (9 test groups)
15. ✅ **Implement** `lib/core/ekf/zupt_detector.dart` (make tests pass)
16. ✅ **Write tests** for `motion_classifier.dart` (13 test groups)
17. ✅ **Implement** `lib/core/ekf/motion_classifier.dart` (make tests pass)
18. ✅ **Write tests** for remaining components (GPS degradation, station association, degraded mode)
19. ✅ **Implement** remaining components (make tests pass)
20. ✅ **Verify** all existing tests still pass

### Phase 4: Integration Tests + Integration (Week 3-4)
21. ✅ **Write integration tests** for SensorFusionManager
22. ✅ **Write integration tests** for LocationStreamHandler
23. ✅ **Write integration tests** for TrackingService
24. ✅ **Implement** replacement of `lib/services/sensor_fusion.dart`
25. ✅ **Implement** modifications to `LocationStreamHandler`
26. ✅ **Implement** modifications to `TrackingService`
27. ✅ **Run all 445 existing tests** - fix any regressions
28. ✅ **Verify** all integration tests pass

### Phase 5: Performance & Real-World Tests (Week 4)
29. ✅ **Write performance tests**
30. ✅ **Validate** performance targets
31. ✅ **Write real-world data tests**
32. ✅ **Replay logged data** and validate accuracy
33. ✅ **Tune parameters** if needed
34. ✅ **Final verification** - all 555+ tests passing

---

## 8. Critical Pre-Implementation Checklist

Before writing any code, confirm:

- [x] **IMU timestamp strategy** - Use `SensorEvent.timestamp` (available on Android), fallback Stopwatch (✅ LOCKED)
- [x] **EKF scope** - Always run: sensor fusion when GPS available, prediction when GPS lost (✅ LOCKED)
- [x] **Progress source logic** - EKF only when degraded/metro (✅ LOCKED)
- [x] **Station snap UI policy** - Gated per §24.2, EKF state always updates (✅ LOCKED)
- [x] **Route geometry location** - New file `lib/core/ekf/route_geometry.dart` (✅ LOCKED)
- [x] **Background isolate** - All EKF in background (✅ LOCKED)
- [x] **FFT library choice** - Use `fftea` package (✅ LOCKED)
- [x] **Matrix library choice** - Custom 3×3 matrices (✅ LOCKED)
- [x] **Route change handling** - Hard reset with projection (✅ LOCKED)
- [x] **Battery policy** - EKF battery-agnostic, only FFT gated < 20% (✅ LOCKED)
- [x] **Simulation mode** - Symmetric test streams (✅ LOCKED)
- [x] **Initialization timing** - Two-phase (create at start, enable on GPS/ZUPT) (✅ LOCKED)
- [x] **State persistence** - Minimal (s_pub, σ_s, ekf_mode) (✅ LOCKED)
- [x] **ZUPT non-metro** - Velocity update only, no position snap (✅ LOCKED)

---

## 9. Remaining Ambiguities (ALL RESOLVED - LOCKED DECISIONS)

### 9.1 ✅ Route Change Handling (LOCKED)
**Decision:** HARD RESET WITH PROJECTION
- On route change: Discard EKF bias, project current GPS (or last EKF lat/lng) to new route → `s_new`
- Initialize: `s = s_new`, `v = 0`, `σ_s = 50 m`
- Reset: motion classifier, ZUPT timers
- Enter DEGRADED until GPS confirms
- **Rationale:** Route changes are semantic resets; transferring EKF state is unsafe

### 9.2 ✅ Battery Policy Integration (LOCKED)
**Decision:** EKF is battery-agnostic; feature gating only
- IMU sampling rate: **never modified** (unreliable across OEMs)
- EKF prediction: **always runs** (cheap)
- FFT/Motion classifier: **disabled when battery < 20%** (only meaningful CPU cost)
- Motion defaults to VEHICLE unless ZUPT detected when FFT disabled
- ZUPT: **always active** (cheap)
- **Rationale:** Aligns with §27 safeguards; only FFT is expensive

### 9.3 ✅ Simulation/IMU Replay Injection (LOCKED)
**Decision:** Symmetric test streams
- Add `testGyroscopeStream` to match `testAccelerometerStream`
- `SensorFusionManager` constructor accepts both:
  - `Stream<AccelerometerEvent>?`
  - `Stream<GyroscopeEvent>?`
- Simulation mode injects both streams
- No "simulation mode" flag needed; streams define behavior

### 9.4 ✅ EKF Initialization Timing (LOCKED)
**Decision:** Two-phase initialization
- EKF object created at `LocationStreamHandler.start()`
- Prediction **disabled** until:
  - First GPS fix **OR**
  - First confirmed ZUPT
- Until enabled: EKF holds invalid state, σ inflated, no alarms rely on EKF
- **Rationale:** Avoids blind IMU integration at app start

### 9.5 ✅ EKF State Persistence (LOCKED)
**Decision:** MINIMAL PERSISTENCE
- **Persist:** `s_pub`, `σ_s`, `ekf_mode`
- **Do NOT persist:** bias, covariance matrix, velocity
- **On resume:** Discard IMU backlog, reinitialize EKF from GPS, treat persisted `s_pub` as hint only
- **Rationale:** Aligned with §27.9; bias/velocity are session-specific

### 9.6 ✅ ZUPT on Non-Metro Legs (LOCKED)
**Decision:** Velocity update only
- On walking/bus/drive legs: ZUPT → `v = 0`, bias update
- **NO position snap**
- **NO station association**
- **Rationale:** Avoids "bus stop = metro stop" errors

### 9.7 ✅ FFT/Matrix Libraries (LOCKED)
**Decision:** Minimal dependencies
- **FFT:** Use `fftea` package
- **EKF math:** Custom 3×3 matrices (no external linear algebra dependency in v1)
- **Rationale:** Predictability, debuggability, performance

---

## 10. Conclusion

The plan is **fully implementation-ready**. All ambiguities have been resolved with locked decisions.

### ✅ All Questions Resolved
- Route change handling: Hard reset with projection
- Battery policy: EKF battery-agnostic, only FFT gated
- Simulation: Symmetric test streams
- Initialization: Two-phase (create at start, enable on GPS/ZUPT)
- State persistence: Minimal (s_pub, σ_s, ekf_mode)
- ZUPT non-metro: Velocity update only
- Libraries: fftea + custom 3×3 matrices

### ✅ Factual Corrections Applied
- IMU timestamps: Use `SensorEvent.timestamp` (available on Android)
- Station snap UI: Remains gated per §24.2 (not always update)

### ✅ EKF Usage Model Clarified
**Critical Architecture Understanding:**
- **GPS Available:** EKF runs in **sensor fusion mode** - continuously learns biases, calibrates sensors, updates state with GPS corrections
- **GPS Lost:** EKF switches to **prediction mode** - uses learned biases for dead reckoning along route
- This ensures accurate bias estimates are ready when GPS drops

**Risk Level:** 🟢 **LOW** - Plan is complete, all decisions locked, ready for implementation.

---

**Next Steps:**
1. ✅ All ambiguities resolved
2. Create detailed implementation plan with specific file changes
3. Begin Phase 1 (core infrastructure)
4. Iterate based on testing results
