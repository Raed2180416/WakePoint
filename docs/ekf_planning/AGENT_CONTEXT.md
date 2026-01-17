# Agent Context (EKF Implementation)

**Date:** 2026-01-16

## Sources of Truth (Locked)
- MATH_SPECIFICATION.md
- implementation_plan.md
- LOCKED_DECISIONS.md
- SPECIFICATION_FIXES.md
- DATA_FLOW_DIAGRAM.md
- TEST_PLAN.md
- TEST_COVERAGE_MATRIX.md

## IMU/GPS Logged Datasets (Local)
- Root: GeoWake IMU  (File responses)/
	- Metro_Log_File/**/Accelerometer.csv, Gyroscope.csv, Location.csv, Annotation.csv, Metadata.csv
	- Upload Log File (Zipped CSV) (File responses)/**/Accelerometer.csv, Gyroscope.csv, Location.csv, Annotation.csv, Metadata.csv

## Planned Use of Logged Data (Later Phase)
- Use for `test/integration/ekf_logged_data_test.dart` and regression validation.
- Parse sensor CSVs to monotonic timestamps and feed both accel+gyro streams.
- Use Location.csv for GPS updates (accuracy if present).

## Readiness Check (Summary)
- Specs complete and locked.
- Test-first mandate active; EKF unit tests now exist for route geometry, pipeline, detectors, motion classifier, and tilt filter.
- Separate GPS degradation detector required (implemented).
- Two-phase EKF initialization required.

## Open Questions (Must Resolve Before Coding)
1. LPF type + coefficients and accel variance window size `Wg`.
2. Default Q/R values per mode and innovation gate thresholds.
3. GPS degrade thresholds (`T_no_fix`, `A_bad`, `I_bad`, `N_bad`, `T_hold`, `N_good`).
4. Motion classifier thresholds + FFT window/overlap.
5. ZUPT thresholds (`V_th`, `A_th`, `G_th`, `T_zupt`) and dwell (`T_dwell`).
6. Station snap margin and express train handling.
7. Alarm `k` values per mode and any ramp schedule.
8. Logging format + storage limits.
9. Simulation/IMU replay injection points (already locked for gyro stream parity, but wiring details need verification in code).

## Definition of Ready
- Answers recorded for all open questions above.
- Test infrastructure created.
- Three critical integration tests authored (long tunnel, ambiguous station, GPS recovery large innovation).
- Baseline test run completed and passing (445 existing tests).
