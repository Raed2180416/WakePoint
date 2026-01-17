# EKF Decisions Log

**Date:** 2026-01-16

Record all finalized numeric values and thresholds here before implementation begins.

## Tilt Filter
- LPF type: 1st-order IIR
- LPF cutoff (Hz): 0.8
- Variance window `Wg` (s): 0.75
- Complementary gain α: 0.02

## EKF Process Noise
- sigma_accel (m/s²): 0.15
- sigma_bias (m/s²): 0.001
- Q scaling (GPS degraded): ×1.5
- Q scaling (HUMAN motion): ×0.1 on Q_v
- Q scaling (ZUPT overdue): ×2.0 on Q_bias

## Measurement Noise
- R_gps floor (m²): 625 (25^2)
- R_zupt (m²): (0.05 m/s)^2
- R_station (m²): (10 m)^2

## Innovation Gates
- soft reject (σ): 3
- hard reset (σ): 5

## GPS Degradation Detector
- T_no_fix (s): 5
- A_bad (m): 50
- I_bad (σ): 4
- N_bad (fixes): 3
- T_hold (s): 10
- N_good (fixes): 3

## Motion Classifier
- FFT window length (s): 2.56
- FFT overlap (%): 50
- Accel variance thresholds: stationary < 4e-4 (m/s^2)^2 (std dev ≈ 0.02 m/s^2)
- Gyro variance thresholds: stationary < 7.62e-5 (rad/s)^2 (equivalent to 0.5 deg/s)
- EKF feedback weight: 0.3

## ZUPT Detector
- V_th (m/s): 0.3
- A_th: 4e-4 (m/s^2)^2 (std dev ≈ 0.02 m/s^2)
- G_th: 7.62e-5 (rad/s)^2 (equivalent to 0.5 deg/s)
- T_zupt (s): 3
- T_dwell (s): 5

## Station Association
- margin (m): 50
- dwell (s): 20

## Alarm Logic
- k normal: 2.0
- k degraded: 3.0
- k hard degraded: 4.0
- ramp schedule (if any): none (v1)

## Logging
- Format: CSV, monotonic timestamps
- Storage limits: 10 MB ring buffer

## Caveats / Unit Notes
- IMU accel units: m/s^2; accel variance units: (m/s^2)^2.
- IMU gyro units: rad/s; gyro variance units: (rad/s)^2.
- Accel variance thresholds should be validated against logged IMU datasets; keep as v1 defaults.
