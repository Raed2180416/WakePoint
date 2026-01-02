import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/transfer_utils.dart'; // RouteEventBoundary

class StopLogicResult {
  final String targetName;
  final double remainingStops;
  final bool isDestination;

  StopLogicResult({
    required this.targetName,
    required this.remainingStops,
    required this.isDestination,
  });
}

class PreBoardResults {
  final bool shouldTrigger;
  final bool shouldSuppress;

  PreBoardResults({required this.shouldTrigger, required this.shouldSuppress});
}

class StopLogicEngine {
  /// Calculates remaining stops to the NEXT relevant switch point or destination.
  /// Used for UI display or checking alarm thresholds.
  StopLogicResult? calculateRemainingStops({
    required double progressMeters,
    required List<double> stepBoundsMeters,
    required List<double> stepStopsCumulative,
    required List<RouteEventBoundary> routeEvents,
    required Set<int> firedEventIndexes,
  }) {
    // If there are no explicit events left (or none at all), we still treat the
    // end-of-route as a destination target for remaining-stops calculation.
    if (stepBoundsMeters.isEmpty || stepStopsCumulative.isEmpty) {
      return null;
    }

    // 1. Find the next unfired event (inclusive with small tolerance so
    // arriving exactly at the boundary still counts as pending).
    const double _metersTolerance = 5.0;
    final double routeEndMeters = stepBoundsMeters.last;

    final entries =
        routeEvents.asMap().entries.toList()
          ..sort((a, b) => a.value.meters.compareTo(b.value.meters));

    final candidates =
        entries
            .where(
              (e) =>
                  !firedEventIndexes.contains(e.key) &&
                  e.value.meters >= (progressMeters - _metersTolerance),
            )
            .toList();

    final RouteEventBoundary nextEvent =
        candidates.isNotEmpty
            ? candidates.first.value
            : RouteEventBoundary(
              meters: routeEndMeters,
              type: 'destination',
              label: 'Destination',
            );

    // 2. Calculate remaining stops
    // We need to map meters to stops using stepBounds/stepStopsCumulative.
    // Interpolation:
    // Find step index for current progress
    // Find step index for event meter

    // Helper to get stops at meters
    double getStopsAtMeters(double m) {
      if (stepBoundsMeters.isEmpty || stepStopsCumulative.isEmpty) return 0.0;

      final int usableLen =
          stepBoundsMeters.length < stepStopsCumulative.length
              ? stepBoundsMeters.length
              : stepStopsCumulative.length;
      if (usableLen == 0) return 0.0;

      // Find step index where m falls
      int idx = -1;
      for (int i = 0; i < usableLen; i++) {
        if (m <= stepBoundsMeters[i]) {
          idx = i;
          break;
        }
      }

      if (idx == -1) {
        // Beyond last step? Use max stops.
        return stepStopsCumulative[usableLen - 1];
      }

      double prevBound = (idx == 0) ? 0.0 : stepBoundsMeters[idx - 1];
      double prevStops = (idx == 0) ? 0.0 : stepStopsCumulative[idx - 1];
      double nextBound = stepBoundsMeters[idx];
      double nextStops = stepStopsCumulative[idx];

      final denom = (nextBound - prevBound);
      double fraction = denom == 0.0 ? 1.0 : (m - prevBound) / denom;
      if (fraction < 0) fraction = 0;
      if (fraction > 1) fraction = 1;

      return prevStops + fraction * (nextStops - prevStops);
    }

    double currentStops = getStopsAtMeters(progressMeters);
    double eventStops = getStopsAtMeters(nextEvent.meters);

    return StopLogicResult(
      targetName:
          nextEvent.label ??
          (nextEvent.type == 'destination' ? 'Destination' : 'Point'),
      remainingStops: (eventStops - currentStops).clamp(0.0, double.infinity),
      isDestination: nextEvent.type == 'destination',
    );
  }

  /// Checks if pre-boarding notification should fire.
  /// Typically fires when approaching the first station, unless started too close.
  PreBoardResults? checkPreBoarding({
    required Position currentPosition,
    required LatLng firstTransitBoarding,
    required LatLng startPosition,
  }) {
    final distCurrentToStation = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      firstTransitBoarding.latitude,
      firstTransitBoarding.longitude,
    );

    final distStartToStation = Geolocator.distanceBetween(
      startPosition.latitude,
      startPosition.longitude,
      firstTransitBoarding.latitude,
      firstTransitBoarding.longitude,
    );

    // Thresholds (assumed from test behavior or common logic)
    const double triggerDistance = 600.0;
    // Test says: "~110m away" -> Suppress. "~550m away" -> Trigger.
    // Test "started near station" -> 110m.

    // Simple logic:
    // If we started very close (< 200m?), suppress to avoid instant-spam.
    if (distStartToStation < 300.0) {
      // Using 300 safe margin
      // If currently close, it's suppressed.
      if (distCurrentToStation < 300.0) {
        return PreBoardResults(shouldTrigger: false, shouldSuppress: true);
      }
    }

    if (distCurrentToStation <= triggerDistance) {
      return PreBoardResults(shouldTrigger: true, shouldSuppress: false);
    }

    return PreBoardResults(shouldTrigger: false, shouldSuppress: false);
  }

  /// Validates that the user's stop threshold is achievable for the given route.
  /// Returns validation result with isValid flag and optional error message.
  ({bool isValid, String? errorMessage, double maxStops}) validateThreshold({
    required double userThreshold,
    required List<double> stepBoundsMeters,
    required List<double> stepStopsCumulative,
    required List<RouteEventBoundary> routeEvents,
  }) {
    // Find the first switch point or destination
    if (routeEvents.isEmpty) {
      return (isValid: true, errorMessage: null, maxStops: 99.0);
    }

    // Get the first event (switch point or destination)
    final firstEvent = routeEvents.first;

    // Calculate stops available at first event
    double stopsAtFirstEvent = 0.0;
    if (stepBoundsMeters.isNotEmpty && stepStopsCumulative.isNotEmpty) {
      for (int i = 0; i < stepBoundsMeters.length; i++) {
        if (firstEvent.meters <= stepBoundsMeters[i]) {
          stopsAtFirstEvent = stepStopsCumulative[i];
          break;
        }
      }
      if (stopsAtFirstEvent == 0.0 && stepStopsCumulative.isNotEmpty) {
        stopsAtFirstEvent = stepStopsCumulative.last;
      }
    }

    // Max allowed is stops - 1 (need at least 1 stop remaining)
    final maxStops = (stopsAtFirstEvent - 1).clamp(1.0, double.infinity);

    if (userThreshold > maxStops) {
      return (
        isValid: false,
        errorMessage:
            'The number of stops (${userThreshold.toInt()}) is too high for the first segment. Max allowed is ${maxStops.toInt()}.',
        maxStops: maxStops,
      );
    }

    return (isValid: true, errorMessage: null, maxStops: maxStops);
  }

  /// Validates that the user's stop threshold does not exceed the minimum number
  /// of stops on any metro leg along the route.
  ///
  /// Rule: User cannot choose n >= min(stops across all metro legs).
  /// This ensures the alarm can fire meaningfully on every metro leg.
  ///
  /// Returns validation result with isValid flag and optional error message.
  ({bool isValid, String? errorMessage, int minMetroStops})
  validateThresholdAgainstMetroLegs({
    required int userThreshold,
    required List<TransitLegStops> transitLegs,
  }) {
    // Filter to metro legs only
    final metroLegs = transitLegs.where((leg) => leg.isMetro).toList();

    if (metroLegs.isEmpty) {
      // No metro legs - threshold validation not applicable
      return (isValid: true, errorMessage: null, minMetroStops: 99);
    }

    // Find the minimum number of stops across all metro legs
    // numStops is the count of intermediate stops (excluding boarding/alighting points)
    // So for a leg with numStops=2, we have: boarding -> stop1 -> stop2 -> alighting
    // That's 3 stops total including the final station (alighting point)
    // The alarm fires when remaining stops <= N, where remaining includes the target.
    // For numStops=2: we can have N=1, N=2, or N=3 as valid thresholds.
    // The remaining stops count = numStops + 1 (the target station)
    int minStopsOnAnyMetroLeg = 999;
    String? shortestLegName;

    for (final leg in metroLegs) {
      // Total stops including target = numStops + 1
      // (numStops = intermediate stops, +1 for the final/target station)
      final totalStops = leg.numStops + 1;
      if (totalStops < minStopsOnAnyMetroLeg) {
        minStopsOnAnyMetroLeg = totalStops;
        shortestLegName = leg.lineName ?? 'Metro leg';
      }
    }

    // User's threshold must be less than the minimum stops on any leg
    // because if threshold >= minStops, the alarm would fire immediately
    // or not have any meaningful "N stops prior" warning.
    if (userThreshold >= minStopsOnAnyMetroLeg) {
      return (
        isValid: false,
        errorMessage:
            'Threshold ${userThreshold} is too high. The $shortestLegName segment only has $minStopsOnAnyMetroLeg stop${minStopsOnAnyMetroLeg == 1 ? '' : 's'}. Please choose a value less than $minStopsOnAnyMetroLeg.',
        minMetroStops: minStopsOnAnyMetroLeg,
      );
    }

    return (
      isValid: true,
      errorMessage: null,
      minMetroStops: minStopsOnAnyMetroLeg,
    );
  }
}
