// docs/annotated/services/deviation_detection.annotated.dart
// Purpose: Line-by-line annotated copy of `lib/services/deviation_detection.dart`.
// Scope: Closest-point scan across route polyline, haversine distance helper, threshold selection, exceedance check.

// lib/services/deviation_detection.dart // Original file path comment retained.
import 'package:geolocator/geolocator.dart'; // Provides distanceBetween for meter distances.
import 'package:geowake2/models/route_models.dart'; // RouteModel definition with decoded polyline.
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng type for coordinates.

/// A simple data class to store information about the closest point. // Holds nearest point info.
class PointInfo { // Value object for nearest-point analysis.
  final LatLng point; // The closest polyline vertex to current location.
  final int segmentIndex; // Index in decoded polyline list.
  final double distanceFromStart; // Approx cumulative distance from route start to that vertex.

  PointInfo({ // Constructor requires all values.
    required this.point,
    required this.segmentIndex,
    required this.distanceFromStart,
  });
}

/// Calculates the Haversine distance in meters between two [LatLng] points. // Wrapper around Geolocator.
double calculateDistance(LatLng a, LatLng b) { // Convenience function to compute meters.
  return Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude); // Delegate to Geolocator.
}

/// Iterates through the decoded polyline of a [RouteModel] to find the point closest to [currentLocation]. // O(N) scan.
PointInfo findClosestPointOnRoute(LatLng currentLocation, RouteModel route) { // Returns nearest vertex and cumulative distance.
  double minDistance = double.infinity; // Initialize with large value.
  LatLng closestPoint = currentLocation; // Default to current location in case of empty input (though route expected non-empty).
  int closestIndex = 0; // Track index of nearest vertex.
  double cumulativeDistance = 0; // Approximate traveled distance along route to that vertex.

  for (int i = 0; i < route.polylineDecoded.length; i++) { // Iterate all vertices.
    final point = route.polylineDecoded[i]; // Current route vertex.
    final distance = calculateDistance(currentLocation, point); // Meters from current location to vertex.
    if (distance < minDistance) { // Maintain running minimum.
      minDistance = distance; // Update best distance.
      closestPoint = point; // Update closest point.
      closestIndex = i; // Update index.
      // Approximate the distance from the start by summing up distances from the beginning to this point. // Cumulative sum.
      cumulativeDistance = 0; // Reset accumulator.
      for (int j = 0; j < i; j++) { // Sum segment lengths up to i.
        cumulativeDistance += calculateDistance(route.polylineDecoded[j], route.polylineDecoded[j + 1]); // Add segment j->j+1.
      }
    }
  }
  return PointInfo(point: closestPoint, segmentIndex: closestIndex, distanceFromStart: cumulativeDistance); // Package result.
}

/// Determines the deviation threshold based on connectivity and environment. // Policy hook.
/// For now, it returns a fixed base threshold—adapt this as needed. // Simple placeholder policy.
double determineThreshold(bool isOffline, LatLng currentLocation, RouteModel route) { // Returns meters threshold.
  // Base threshold: 600m when online, 1500m when offline. // Tunable constants.
  double baseThreshold = isOffline ? 1500.0 : 600.0; // Offline more tolerant due to less reroute capability.

  // (Optional) Add adjustments based on factors such as urban density, road type, or speed. // Extension ideas.

  return baseThreshold; // Current policy output.
}

/// Checks whether the current location deviates from the [activeRoute] beyond the acceptable threshold. // High-level API.
bool isDeviationExceeded(LatLng currentLocation, RouteModel activeRoute, bool isOffline) { // Returns true when exceeding policy threshold.
  final closest = findClosestPointOnRoute(currentLocation, activeRoute); // Nearest vertex on route.
  final deviationDistance = calculateDistance(currentLocation, closest.point); // Meters off the route vertex.
  final threshold = determineThreshold(isOffline, currentLocation, activeRoute); // Policy threshold.
  
  return deviationDistance > threshold; // Deviated if beyond threshold.
}

// Post-block notes:
// - Nearest-point search operates on polyline vertices only; for higher fidelity, project onto segments.
// - Cumulative distance is approximate and recomputed when a nearer vertex is found; acceptable for coarse ETA/gating.
// - Deviation threshold policy is a placeholder; integrate with Dynamic ReroutePolicy bands for production logic.
// - Distance calculations use Geolocator for consistency with the rest of the app.

// End-of-file summary:
// - Provides building blocks to detect off-route conditions against a decoded route polyline.
// - Key methods: `findClosestPointOnRoute`, `determineThreshold`, and `isDeviationExceeded`.
// - Complexity: O(N) nearest vertex scan; cumulative distance sum O(N) in worst case when nearest vertex moves forward.
// - Extensibility: Replace vertex-only check with point-to-segment projection for precise nearest distance and progress.
