import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/logging/app_logger.dart';

/// Manages the "Soft Lock" logic for non-metro transit (Bus Reality).
///
/// Instead of strictly snapping to the polyline, this manager checks if the user
/// is within a "corridor" of the route. If they exit the corridor for a sustained
/// period/distance, a deviation is triggered.
///
/// Rules:
/// - Success: GPS is within X meters of the route projection.
/// - Failure: GPS is > X meters from route for N consecutive updates.
/// - Corridor Width: 50m (configurable).
/// - Low Accuracy Fallback: Expand corridor to 200m if GPS accuracy > 20m.
class SoftLockManager {
  static final _log = AppLogger('SoftLockManager');

  // Config
  static const double kDefaultCorridorRadiusMeters = 50.0;
  static const double kLowAccuracyCorridorRadiusMeters = 200.0;
  static const int kConsecutivePointsForDeviation = 3;

  // State
  int _consecutiveOut = 0;

  /// Evaluates whether the user is "locked" to the route (within corridor).
  /// Returns [true] if locked (on route), [false] if deviated.
  bool checkSoftLock({
    required LatLng userLocation,
    required double accuracy,
    required List<LatLng> routePoints,
    required int closestSegmentIndex,
    required LatLng projectedPoint,
    required double lateralOffsetMeters, // Distance from route
  }) {
    // 1. Determine Corridor Width based on signal quality
    // If accuracy is bad (>20m), be more lenient.
    final double threshold =
        accuracy > 20.0
            ? kLowAccuracyCorridorRadiusMeters
            : kDefaultCorridorRadiusMeters;

    // 2. Check Lateral Distance
    // Use the pre-computed offset from SnapToRoute if reliable, or recompute?
    // We assume lateralOffsetMeters comes from SnapToRoute which is geometrically accurate.
    final bool isWithinCorridor = lateralOffsetMeters <= threshold;

    if (isWithinCorridor) {
      if (_consecutiveOut > 0) {
        _log.debug('SoftLock recovered (was out $_consecutiveOut times)');
      }
      _consecutiveOut = 0;
      return true;
    } else {
      _consecutiveOut++;
      _log.info(
        'SoftLock OUT: dist=${lateralOffsetMeters.toStringAsFixed(1)}m > limit=${threshold.toStringAsFixed(0)}m (count=$_consecutiveOut)',
      );

      // 3. Deviation Trigger
      if (_consecutiveOut >= kConsecutivePointsForDeviation) {
        _log.warn(
          'SoftLock DEVIATION CONFIRMED ($_consecutiveOut consecutive points out)',
        );
        // Reset count to avoid spamming? Or keep reporting deviation until recovered/rerouted?
        // Typically deviation triggers a reroute which generates a NEW route.
        // The calling service should handle the reroute.
        return false;
      }

      // Still effectively "locked" until we hit the threshold count (hysteresis)
      return true;
    }
  }

  /// Resets internal state (e.g. on new route or manual reset).
  void reset() {
    _consecutiveOut = 0;
  }
}
