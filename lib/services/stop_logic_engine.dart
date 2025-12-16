import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/transfer_utils.dart';

/// Stop Logic Engine - Handles stop-based alarm logic with switch point awareness
class StopLogicEngine {
  // Configuration
  static const double preBoardingAlertDistance = 1200.0; // meters
  static const double switchPointProximity = 200.0; // meters
  static const double walkingSpeed = 1.4; // m/s

  /// Calculate remaining stops to next critical point (switch or destination)
  /// Returns null if calculation fails
  ({
    double remainingStops,
    double remainingStopsToDestination,
    int nextSwitchIndex,
    String targetName,
    bool isDestination,
    double? targetLat,
    double? targetLng,
    double targetMeters,
  })?
  calculateRemainingStops({
    required double progressMeters,
    required List<double> stepBoundsMeters,
    required List<double> stepStopsCumulative,
    required List<RouteEventBoundary> routeEvents,
    required Set<int> firedEventIndexes,
  }) {
    if (stepBoundsMeters.isEmpty || stepStopsCumulative.isEmpty) {
      return null;
    }

    // Find the next unfired switch point
    int? nextSwitchIndex;
    double? switchPointMeters;
    String? switchPointName;
    double? switchLat;
    double? switchLng;

    for (int i = 0; i < routeEvents.length; i++) {
      if (firedEventIndexes.contains(i)) continue;

      final event = routeEvents[i];
      final eventMeters = event.meters;

      // Only consider switch points ahead of current progress
      // OR if we are close to it (within 500m) to handle GPS jitter/overshoot
      if (eventMeters > progressMeters ||
          (eventMeters - progressMeters).abs() < 500) {
        nextSwitchIndex = i;
        switchPointMeters = eventMeters;
        switchPointName = event.label ?? 'Transfer';
        switchLat = event.lat;
        switchLng = event.lng;
        break;
      }
    }

    // Determine target: next switch or destination
    final totalRouteMeters =
        stepBoundsMeters.isNotEmpty ? stepBoundsMeters.last : 0.0;
    final isDestination = nextSwitchIndex == null;
    final targetMeters = isDestination ? totalRouteMeters : switchPointMeters!;
    final targetName = isDestination ? 'Destination' : switchPointName!;

    // Interpolate current progress stops
    double progressStops = _interpolateStops(
      progressMeters,
      stepBoundsMeters,
      stepStopsCumulative,
    );

    // Interpolate target stops
    double targetStops = _interpolateStops(
      targetMeters,
      stepBoundsMeters,
      stepStopsCumulative,
    );

    final remainingStops = targetStops - progressStops;

    // --- HYBRID MODE FIX ---
    // If we are in a walking/driving leg (0 transit stops difference),
    // we should convert the remaining distance to "virtual stops" (0.5km = 1 stop).
    // This allows "N stops prior" alerts to work for boarding points.
    double finalRemainingStops = remainingStops;

    if (remainingStops < 0.1) {
      // Check if we are actually moving towards the target
      final dist = targetMeters - progressMeters;
      if (dist > 0) {
        // Convert distance to stops: 500m = 1 stop
        final virtualStops = dist / 500.0;
        finalRemainingStops = virtualStops;
      }
    }

    // Interpolate stops at destination (end of route)
    final endOfRouteMeters = stepBoundsMeters.last;
    final endOfRouteStops = _interpolateStops(
      endOfRouteMeters,
      stepBoundsMeters,
      stepStopsCumulative,
    );

    // Calculate remaining stops to final destination
    double remainToDest = endOfRouteStops - progressStops;

    // Apply hybrid fix to destination calculation as well if needed
    if (remainToDest < 0.1) {
      final dist = endOfRouteMeters - progressMeters;
      if (dist > 0) {
        remainToDest = dist / 500.0;
      }
    }

    return (
      remainingStops: finalRemainingStops.clamp(0.0, double.infinity),
      remainingStopsToDestination: remainToDest.clamp(0.0, double.infinity),
      nextSwitchIndex: nextSwitchIndex ?? -1,
      targetName: targetName,
      isDestination: isDestination,
      targetLat: switchLat,
      targetLng: switchLng,
      targetMeters: targetMeters,
    );
  }

  /// Interpolate stops at a given meter position along the route
  /// Handles mixed modes: Transit uses actual stops, Walking/Driving uses 0.5km = 1 stop
  double _interpolateStops(
    double meters,
    List<double> stepBoundsMeters,
    List<double> stepStopsCumulative,
  ) {
    // Handle overshoot
    if (meters >= stepBoundsMeters.last) {
      return stepStopsCumulative.last;
    }

    // Find the step containing this meter position
    for (int i = 0; i < stepBoundsMeters.length; i++) {
      if (meters <= stepBoundsMeters[i]) {
        final stepEndM = stepBoundsMeters[i];
        final stepEndStops = stepStopsCumulative[i];

        final stepStartM = i == 0 ? 0.0 : stepBoundsMeters[i - 1];
        final stepStartStops = i == 0 ? 0.0 : stepStopsCumulative[i - 1];

        final stepDist = stepEndM - stepStartM;
        final stepStopsDiff = stepEndStops - stepStartStops;

        // If step has stops (Transit), interpolate based on stops
        if (stepStopsDiff > 0) {
          if (stepDist > 0) {
            final fraction = (meters - stepStartM) / stepDist;
            return stepStartStops + (stepStopsDiff * fraction);
          } else {
            return stepEndStops;
          }
        }
        // If step has NO stops (Walking/Driving), use distance-based stops (0.5km = 1 stop)
        else {
          // We need to calculate how many "virtual stops" this walking segment represents
          // But stepStopsCumulative only tracks TRANSIT stops.
          // To support "N stops prior" for boarding, we need to add virtual stops
          // to the calculation relative to the target.

          // However, modifying the cumulative array is complex.
          // Instead, let's look at the problem:
          // We want "remaining stops" to include walking distance.
          // So, if we are in a walking segment, we should add (dist_to_end_of_segment / 500m)
          // to the stops of the *next* transit segment?

          // Actually, the user wants: "Alert 1km before boarding".
          // If N=2 (1km), and we are 1km away from boarding (walking), remainingStops should be 2.

          // Current logic:
          // progressStops = stops at current location (likely 0 if walking start)
          // targetStops = stops at boarding (likely 0 if walking end)
          // Result = 0.

          // FIX: We need a hybrid approach.
          // If the target is a Switch Point (Boarding), and we are in a non-transit leg leading to it:
          // remainingStops = (distance_to_target / 500.0) + (target_stops - current_transit_stops)

          // But _interpolateStops is generic.
          // Let's keep _interpolateStops as is (pure transit stops) and handle the hybrid logic in calculateRemainingStops.
          return stepStartStops; // For walking, return the stops at the start of the segment (constant)
        }
      }
    }

    return 0.0;
  }

  /// Check if pre-boarding alert should trigger
  /// Returns null if no first boarding point exists
  ({bool shouldTrigger, bool shouldSuppress})? checkPreBoarding({
    required Position currentPosition,
    required LatLng? firstTransitBoarding,
    required LatLng? startPosition,
  }) {
    if (firstTransitBoarding == null) {
      return null;
    }

    final distanceToStation = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      firstTransitBoarding.latitude,
      firstTransitBoarding.longitude,
    );

    // Check if start position was already near station (suppress alert)
    bool shouldSuppress = false;
    if (startPosition != null) {
      final startDistance = Geolocator.distanceBetween(
        startPosition.latitude,
        startPosition.longitude,
        firstTransitBoarding.latitude,
        firstTransitBoarding.longitude,
      );
      if (startDistance <= switchPointProximity) {
        shouldSuppress = true;
      }
    }

    final shouldTrigger =
        distanceToStation <= preBoardingAlertDistance && !shouldSuppress;

    return (shouldTrigger: shouldTrigger, shouldSuppress: shouldSuppress);
  }

  /// Detect if a leg transition is occurring
  ({bool autoSwitch, bool missedTransfer, double distanceToSwitch})?
  detectLegTransition({
    required Position currentPosition,
    required List<RouteEventBoundary> routeEvents,
    required int? currentSwitchIndex,
    required double? lastDistanceToSwitch,
    required double currentSpeed,
  }) {
    if (currentSwitchIndex == null ||
        currentSwitchIndex >= routeEvents.length) {
      return null;
    }

    final event = routeEvents[currentSwitchIndex];
    final switchLat = event.lat;
    final switchLng = event.lng;

    if (switchLat == null || switchLng == null) {
      return null;
    }

    final distanceToSwitch = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      switchLat,
      switchLng,
    );

    // Auto-switch: Close proximity + low speed
    final autoSwitch =
        distanceToSwitch < switchPointProximity && currentSpeed < walkingSpeed;

    // Missed transfer: Distance increasing after reaching 0 remaining stops
    final prevDistance = lastDistanceToSwitch ?? double.infinity;
    final missedTransfer =
        distanceToSwitch > prevDistance &&
        distanceToSwitch > switchPointProximity;

    return (
      autoSwitch: autoSwitch,
      missedTransfer: missedTransfer,
      distanceToSwitch: distanceToSwitch,
    );
  }

  /// Validate user threshold against route stops
  /// Returns (isValid, maxStops, errorMessage)
  ({bool isValid, double maxStops, String? errorMessage}) validateThreshold({
    required double userThreshold,
    List<double>? stepBoundsMeters,
    required List<double> stepStopsCumulative,
    required List<RouteEventBoundary> routeEvents,
  }) {
    if (stepStopsCumulative.isEmpty) {
      return (
        isValid: false,
        maxStops: 0.0,
        errorMessage: 'Unable to calculate route stops. Please try again.',
      );
    }

    // Find max stops for the first transit leg
    double maxStops = stepStopsCumulative.last;

    // If there are switch points, use the first one as the limit.
    // NOTE: routeEvents are in meters, so we must use stepBoundsMeters (meters)
    // to interpolate the stop count at the switch.
    if (routeEvents.isNotEmpty &&
        stepBoundsMeters != null &&
        stepBoundsMeters.isNotEmpty) {
      final firstSwitch = routeEvents.first;
      final switchMeters = firstSwitch.meters;
      maxStops = _interpolateStops(
        switchMeters,
        stepBoundsMeters,
        stepStopsCumulative,
      );
    }

    if (userThreshold > maxStops) {
      return (
        isValid: false,
        maxStops: maxStops,
        errorMessage:
            'Please choose < ${maxStops.ceil()} stops (route has ${maxStops.toStringAsFixed(1)} stops)',
      );
    }

    return (isValid: true, maxStops: maxStops, errorMessage: null);
  }

  /// Calculate estimated progress using fallback (distance-based)
  double estimateProgressFallback({
    required double totalRouteMeters,
    required Position currentPosition,
    required LatLng destination,
  }) {
    final distanceToDest = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      destination.latitude,
      destination.longitude,
    );

    final estimatedProgress = totalRouteMeters - distanceToDest;
    return estimatedProgress.clamp(0.0, totalRouteMeters);
  }
}
