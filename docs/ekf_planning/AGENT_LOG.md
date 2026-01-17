# Agent Log

Use this file as a rolling scratchpad for decisions, reasoning, and progress checkpoints.

## 2026-01-16
- Created planning artifacts: AGENT_CONTEXT.md, NEXT_STEPS.md, DECISIONS_LOG.md, WIRING_NOTES.md, IMPLEMENTATION_READINESS.md.
- Next action: fill DECISIONS_LOG.md and WIRING_NOTES.md before writing tests.
- Filled WIRING_NOTES.md with current codebase integration points.
- Created test infrastructure directories and helper scaffolding in test/helpers and test/fixtures/imu_data.
- Added EKF API skeleton: lib/core/ekf/ekf_types.dart, ekf_pipeline.dart, route_geometry.dart.
- Unskipped and wired critical integration tests to API skeleton (expected to fail until implemented).
- Implemented RouteGeometry projection + tangent continuity per spec.
- Added unit tests for RouteGeometry (projection, far rejection, tangent interpolation).
- Implemented minimal EKF prediction + GPS update per MATH_SPECIFICATION + DECISIONS_LOG defaults.
- Implemented ZUPT and station snap updates; added EKF pipeline unit tests.
- Added GPS degradation detector + tests and motion classifier scaffold + tests.
- Implemented ZUPT detector + tests (Stage F).
- Added EKF orchestrator scaffold + unit test (not wired into app).
- Implemented station association component + tests (Stage G).
- Implemented degraded mode component + tests (Stage H).
- Wired EKF snapshot telemetry into TrackingService debug info (no alarm logic changes).
- Added minimal EKF snapshot persistence (s, sigma, mode) via TrackingSnapshot.
- Wired EKF progress selection for alarms on metro legs/degraded mode (threshold logic unchanged).
- Implemented tilt filter (Stage A) and added unit tests.
- Expanded motion classifier with FFT feature extraction and added tests.
- Cleared EKF state on session start/stop and test reset to avoid cross-test contamination.
- Adjusted tilt filter test to allow convergence before asserting gravity shift.

## 2026-01-17
- Wired tilt filter output into EKF prediction in EkfOrchestrator (gravity removal → world frame → route tangent projection).
- Added motion feature extraction buffers (2.56s window, 50% overlap) and variance windows (0.75s) to drive motion classification + ZUPT.
- Added EKF pipeline `onForwardAccel()` entry point and motion state update hook.
- Added battery-tier FFT gating hook in LocationStreamHandler → SensorFusionManager → EkfOrchestrator (disable FFT when battery < 20%).
- Updated SensorFusionManager IMU ingestion to use latest gyroscope sample and monotonic stopwatch timestamps for EKF IMU samples.
- Kept EKF fusion running continuously; wired GPS updates into SensorFusionManager and auto-innovation for GPS degradation detector.
- Updated connectivity test to reflect continuous fusion behavior (no stop on GPS resume).
- Fixed recovery test to inject empty IMU streams under test mode to avoid sensors plugin calls.
- Wired route switch handling to refresh EKF route geometry (hard reset via new orchestrator).
- Innovation sigma now computed from EKF internal state (not monotonic public s).
- Wired station association path: transit leg stops passed to SensorFusionManager, station context set on GPS, station snap applied on ZUPT.
- Integrated degraded mode into EKF: mode set from DegradedMode and progress freezes while sigma grows.
- Reset tilt filter on confirmed ZUPT to hard realign gravity.
- Added two-phase prediction gate: IMU prediction only after GPS fix or confirmed ZUPT.
- Enforced soft innovation reject (>3σ) and disabled bias updates on GPS/station measurements (bias only via ZUPT).
- Added motion state minimum-duration gate (2 consecutive windows, 50% overlap) before switching motion class.
- Set EKF mode to degraded until first GPS fix after reset/route change (per spec).
- Added EKF motion state to debug telemetry broadcast.

## 2026-01-18
- Expanded critical integration tests per §28.2 of the EKF plan:
  - **long_tunnel_no_stops_test.dart**: Now 5 comprehensive tests covering 120s GPS blackout, IMU-only progress, no station proximity, covariance growth, and degraded mode fallback.
  - **ambiguous_station_stop_test.dart**: Expanded from 1 to 9 tests covering ZUPT dwell enforcement (dwellDuration=5s), station snap with sufficient dwell (20s per §22.8), motion oscillation prevention, HUMAN state suppression, multiple candidate rejection, bias correction during ZUPT, and non-metro leg rejection.
  - **gps_recovery_large_innovation_test.dart**: Expanded from 1 to 10 tests covering GPS update state changes, medium innovation soft reject (3-5σ), large innovation hard reset (>5σ), s_pub monotonicity, orchestrator monotonicity, degraded mode covariance growth, GPS recovery uncertainty reduction, and GPS outlier handling.
- Fixed test assumptions to match actual implementation behavior:
  - ZuptDetector: `dwellDuration=5s` (confirmation), `zuptDuration=3s` (candidate), `update()` returns true once when crossing dwellDuration
  - EkfOrchestrator: Uses `gpsDegraded` getter (not `isDegraded`)
  - GPS innovation gating: >5σ triggers hard reset, 3-5σ triggers soft reject, <3σ normal Kalman update
- All 506 tests passing (3 skipped), no regressions introduced.
- Implemented EKF logging ring buffer infrastructure per §12 and §22.12:
  - Created `lib/core/ekf/ekf_logger.dart` with `EkfLogEntry` and `EkfLogger` classes
  - Ring buffer limited to 10 MB per session; oldest entries dropped when limit exceeded
  - CSV format with monotonic timestamps compatible with simulation playground
  - Log streams: Raw/filtered IMU, gravity estimate, EKF state + covariance, motion class, ZUPT events, GPS innovations
  - 19 unit tests for logger in `test/core/ekf/ekf_logger_test.dart`
- All 525 tests passing (3 skipped) including new logger tests.

## Plan Adherence Checklist (Live)
- [x] Follow test-first approach (critical tests scaffolded before full implementation)
- [x] Route geometry implemented before EKF core per NEXT_STEPS order
- [x] EKF numerics taken from DECISIONS_LOG (no ad-hoc values)
- [x] ZUPT update implemented (Stage F)
- [x] Station snap update implemented (Stage G)
- [x] GPS degradation detector implemented (Stage D)
- [x] Motion classifier implemented (Stage E)
- [x] EKF integration wiring into SensorFusionManager
- [x] Alarm timing snapshot integration
- [x] Critical integration tests expanded per §28.2 (long tunnel, ambiguous station, GPS recovery)
- [x] Logging ring buffer infrastructure implemented per §12 and §22.12
