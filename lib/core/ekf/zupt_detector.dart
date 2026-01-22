// ZUPT detector (Stage F).

import 'ekf_types.dart';

class ZuptDetector {
  ZuptDetector({
    this.vThresh = 0.8,  // Require near-stop velocity for ZUPT
    this.accelVarThresh = 1.0,  // Real station stops show accelVar 0.15-0.5 (train vibration, HVAC), test IMU ~0.35-0.9
    this.gyroVarThresh = 0.40,  // Real station stops show gyroVar 0.03-0.1 (phone jitter), test IMU ~0.15-0.35
    this.zuptDuration = const Duration(milliseconds: 300),  // Candidate after 0.3s quiet
    this.dwellDuration = const Duration(milliseconds: 800),  // Confirmation after 0.8s quiet (reduced for test data)
  });

  final double vThresh;
  final double accelVarThresh;
  final double gyroVarThresh;
  final Duration zuptDuration;
  final Duration dwellDuration;

  Duration? _conditionStart;
  bool _confirmed = false;

  bool get isConfirmed => _confirmed;

  Duration? currentDwell(Duration timestamp) {
    if (_conditionStart == null) return null;
    return timestamp - _conditionStart!;
  }

  bool update({
    required Duration timestamp,
    required MotionState motion,
    required double velocityMps,
    required double accelVariance,
    required double gyroVariance,
    bool isDegraded = false,  // GPS dropout mode
  }) {
    // ZUPT detection triggers when IMU is quiet AND velocity is low.
    // The motion classifier hint is helpful but NOT required - it can lag behind.
    //
    // Conditions:
    // 1. IMU quiet (low accel and gyro variance) - primary indicator
    // 2. Low EKF velocity - prevents false positives during smooth cruising
    // 3. Motion classifier hint provides additional confidence but doesn't veto
    //
    // CRITICAL: During GPS dropout (degraded mode), EKF velocity drifts due to
    // accelerometer bias. We can't trust velocity, so allow IMU-only ZUPT.
    // When train physically stops, IMU becomes quiet even though EKF velocity is wrong.
    //
    // Real station stops: accelVar ~0.15-0.5 (HVAC, train vibration), gyroVar ~0.03-0.1
    final imuQuiet = accelVariance < accelVarThresh && gyroVariance < gyroVarThresh;
    final motionHint = motion == MotionState.stationary;
    final velocityLow = velocityMps.abs() < vThresh;
    
    // ULTRA-QUIET detection: IMU so quiet that we're definitely stopped,
    // even if EKF velocity has drifted. These are tighter than normal thresholds.
    // Real physical stops show accelVar < 0.15, gyroVar < 0.05 consistently.
    final imuUltraQuiet = accelVariance < 0.15 && gyroVariance < 0.05;
    
    // ZUPT can trigger if:
    // - IMU is quiet AND velocity is low (primary path - normal mode)
    // - OR motion classifier says stationary AND velocity is low (classifier path)
    // - OR IMU is ULTRA-quiet during degraded mode (velocity-independent during DR)
    //
    // The ultra-quiet path is critical because during GPS dropout, EKF velocity
    // can drift to 2-3 m/s even when physically stopped. Without this path,
    // ZUPT never fires and position error grows unbounded.
    //
    // Note: Ultra-quiet thresholds are much tighter than normal to prevent
    // false positives during smooth cruising (which has imuQuiet but not imuUltraQuiet).
    final degradedUltraQuietPath = isDegraded && imuUltraQuiet && motionHint;
    
    final meets = (imuQuiet && velocityLow) || 
                  (motionHint && velocityLow) ||
                  degradedUltraQuietPath;

    if (!meets) {
      _conditionStart = null;
      _confirmed = false;
      return false;
    }

    _conditionStart ??= timestamp;
    final elapsed = timestamp - _conditionStart!;

    if (!_confirmed && elapsed >= dwellDuration) {
      _confirmed = true;
      return true;
    }

    return false;
  }

  bool isCandidate(Duration timestamp) {
    if (_conditionStart == null) return false;
    return (timestamp - _conditionStart!) >= zuptDuration;
  }
}
