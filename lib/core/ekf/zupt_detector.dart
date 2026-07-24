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
    
    // ZUPT trigger paths differ by GPS state, because EKF velocity is only
    // trustworthy when GPS has recently corroborated it:
    //
    // NORMAL mode (GPS present):
    // - IMU quiet AND velocity low (primary), OR
    // - motion classifier says stationary AND velocity low.
    //
    // DEGRADED mode (GPS dropout): velocity is untrustworthy in BOTH
    // directions — it can drift UP (bias) even when stopped, and it can be
    // pinned LOW when never learned. The pinned-low case is the proven
    // real-ride failure (Majestic 2025-12-21 fixture): GPS lost ~25s after
    // boarding, before cruise speed was learned, so `velocityLow` stayed true
    // and smooth in-tunnel cruising passed `imuQuiet` — ZUPT confirmed at
    // t=44/51/77/78/104s while the train was PROVABLY moving between stations,
    // pinning v to 0 and freezing the estimate ~1.3 km behind truth
    // (see docs/business_os/research/underground_validation_execution.md).
    // So in degraded mode the velocity-gated paths are INVALID: only the
    // ULTRA-quiet signature corroborated by the motion classifier may confirm.
    // The same real ride shows cruise segments passing ultra-quiet thresholds
    // alone (accelVar ~0.07, gyroVar ~0.025) but with motion=vehicle — the
    // motionHint requirement is what rejects them. Missing a real dwell this
    // way only loses a tightening anchor (σ grows honestly, the association
    // window widens, GPS re-anchors on tunnel exit); a FALSE anchor corrupts
    // the estimate with false confidence. Never-late is independent
    // (reachability bounds progress regardless).
    final degradedUltraQuietPath = isDegraded && imuUltraQuiet && motionHint;

    final meets = isDegraded
        ? degradedUltraQuietPath
        : (imuQuiet && velocityLow) || (motionHint && velocityLow);

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
