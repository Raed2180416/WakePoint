// EKF Ground-Truth Metrics
//
// Compares the EKF's estimated progress-along-route against the simulator's
// ground-truth progress on every tick and maintains running accuracy metrics:
//
// - currentError   : signed (ekf - true) meters for the latest tick
// - maxDrift       : max absolute error observed over the whole run
// - rmse           : running root-mean-square error over all ticks
// - maxBlackoutError: max absolute error observed while GPS was unavailable
//
// This is a pure, dependency-free helper used by the in-app EKF test panel to
// score dead-reckoning quality across GPS-out scenarios.

import 'dart:math' as math;

/// Running ground-truth accuracy metrics for the EKF replay/test harness.
class EkfMetrics {
  int _sampleCount = 0;
  double _sumSquaredError = 0.0;
  double _maxAbsError = 0.0;
  double _currentError = 0.0;

  // Blackout (GPS-out) window tracking.
  bool _inBlackout = false;
  int _blackoutWindows = 0;
  double _maxBlackoutAbsError = 0.0;
  double _currentBlackoutMaxAbsError = 0.0;

  /// Number of ground-truth comparisons folded in so far.
  int get sampleCount => _sampleCount;

  /// Signed error (ekf - true) in meters for the most recent tick.
  double get currentError => _currentError;

  /// Absolute error for the most recent tick.
  double get currentAbsError => _currentError.abs();

  /// Maximum absolute error (drift) observed over the entire run, in meters.
  double get maxDrift => _maxAbsError;

  /// Running root-mean-square error over all ticks, in meters.
  double get rmse =>
      _sampleCount == 0 ? 0.0 : math.sqrt(_sumSquaredError / _sampleCount);

  /// Maximum absolute error observed during any GPS-out (blackout) window.
  double get maxBlackoutError => _maxBlackoutAbsError;

  /// Number of distinct GPS-out windows encountered.
  int get blackoutWindows => _blackoutWindows;

  /// Whether the most recent tick was inside a GPS-out window.
  bool get inBlackout => _inBlackout;

  /// Fold a single tick's ground-truth comparison into the running metrics.
  ///
  /// [ekfProgressMeters] is the EKF's estimated distance along the route.
  /// [trueProgressMeters] is the simulator's ground-truth distance along the
  /// route. [gpsAvailable] marks whether GPS was present this tick (used to
  /// scope blackout-window error).
  ///
  /// Ticks where the EKF estimate is NaN/infinite are ignored so a transient
  /// bad estimate does not poison the RMSE.
  void update({
    required double ekfProgressMeters,
    required double trueProgressMeters,
    required bool gpsAvailable,
  }) {
    // Track blackout window transitions regardless of estimate validity so the
    // window count stays accurate even if the EKF briefly reports NaN.
    if (!gpsAvailable && !_inBlackout) {
      _inBlackout = true;
      _blackoutWindows++;
      _currentBlackoutMaxAbsError = 0.0;
    } else if (gpsAvailable && _inBlackout) {
      _inBlackout = false;
    }

    if (!ekfProgressMeters.isFinite || !trueProgressMeters.isFinite) {
      return;
    }

    final error = ekfProgressMeters - trueProgressMeters;
    final absError = error.abs();

    _currentError = error;
    _sampleCount++;
    _sumSquaredError += error * error;

    if (absError > _maxAbsError) {
      _maxAbsError = absError;
    }

    if (_inBlackout) {
      if (absError > _currentBlackoutMaxAbsError) {
        _currentBlackoutMaxAbsError = absError;
      }
      if (absError > _maxBlackoutAbsError) {
        _maxBlackoutAbsError = absError;
      }
    }
  }

  /// Reset all metrics to their initial state (called on run reset).
  void reset() {
    _sampleCount = 0;
    _sumSquaredError = 0.0;
    _maxAbsError = 0.0;
    _currentError = 0.0;
    _inBlackout = false;
    _blackoutWindows = 0;
    _maxBlackoutAbsError = 0.0;
    _currentBlackoutMaxAbsError = 0.0;
  }

  /// Snapshot of the current metrics for logging/export.
  Map<String, dynamic> toJson() => {
    'samples': _sampleCount,
    'currentError': _currentError,
    'maxDrift': _maxAbsError,
    'rmse': rmse,
    'maxBlackoutError': _maxBlackoutAbsError,
    'blackoutWindows': _blackoutWindows,
  };
}
