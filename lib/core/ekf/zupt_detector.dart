// ZUPT detector (Stage F).

import 'ekf_types.dart';

class ZuptDetector {
  ZuptDetector({
    this.vThresh = 0.3,
    this.accelVarThresh = 4e-4,
    this.gyroVarThresh = 7.62e-5,
    this.zuptDuration = const Duration(seconds: 3),
    this.dwellDuration = const Duration(seconds: 5),
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
  }) {
    final meets =
        motion == MotionState.stationary &&
        velocityMps.abs() < vThresh &&
        accelVariance < accelVarThresh &&
        gyroVariance < gyroVarThresh;

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
