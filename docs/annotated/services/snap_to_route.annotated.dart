// Annotated copy of lib/services/snap_to_route.dart
// Purpose: Explain every line, each block, and how this file ties into the system.

import 'package:google_maps_flutter/google_maps_flutter.dart'; // Imports LatLng for geographic coordinates (lat, lng in degrees)
import 'package:geolocator/geolocator.dart'; // Imports geodesic distance helper used to compute meters between two LatLngs (haversine)
import 'dart:math' show cos; // Imports cosine used to compute meters-per-degree scaling for longitude at a given latitude

class SnapResult { // Immutable result of snapping a point onto a route polyline
  final LatLng snappedPoint; // The point on the polyline (in LatLng) that is closest to the input point after projection
  final double lateralOffsetMeters; // Perpendicular distance from the input point to the polyline in meters
  final double progressMeters; // Cumulative distance from the start of the polyline to the snappedPoint, in meters
  final int segmentIndex; // Index of the polyline segment (between point i and i+1) where the snap occurred
  const SnapResult({ // Const constructor ensures instances are immutable and compile-time constant when arguments are
    required this.snappedPoint, // Provide the snapped LatLng
    required this.lateralOffsetMeters, // Provide the lateral offset in meters
    required this.progressMeters, // Provide the cumulative progress along the polyline in meters
    required this.segmentIndex, // Provide the index of the segment used for the projection
  }); // End of constructor
} // End of class SnapResult

/* Block summary: SnapResult is a simple data container describing where along the route the user is (progressMeters),
   how far away from the route they are (lateralOffsetMeters), and which segment was used (segmentIndex), plus the exact
   LatLng of the snapped position (snappedPoint). This is consumed by ActiveRouteManager, DeviationMonitor, and ETA logic. */

class SnapToRouteEngine { // Provides snapping utilities for projecting a point onto a polyline route
  /// Snap a point to a polyline. Optionally provide a hint segment index to reduce search.
  static SnapResult snap({ // Static method so callers can use without instantiating the class
    required LatLng point, // Input GPS/location sample to snap
    required List<LatLng> polyline, // The polyline representing the route (ordered list of vertices)
    int? hintIndex, // Optional previous segment index to narrow the search window for efficiency and continuity
    int searchWindow = 20, // Number of segments on either side of hintIndex to consider (caps work to a small neighborhood)
  }) { // Start snap()
    if (polyline.length < 2) { // If fewer than 2 points, there is no segment to project onto
      return SnapResult( // Return a sentinel result indicating we cannot snap meaningfully
        snappedPoint: point, // Fallback to the original point
        lateralOffsetMeters: double.infinity, // Infinite offset signals “no valid snap”
        progressMeters: 0, // No progress can be computed
        segmentIndex: 0, // Default segment index
      ); // End return
    } // End guard for short polyline

    int start = 0; // Default start index: beginning of the polyline
    int end = polyline.length - 2; // Default end index: last segment begins at length-2 (since segment uses i and i+1)
    if (hintIndex != null) { // If caller provides a hint index
      start = (hintIndex - searchWindow).clamp(0, end); // Clamp start to [0, end] around hintIndex - window
      end = (hintIndex + searchWindow).clamp(0, end); // Clamp end to [0, end] around hintIndex + window
    } // End hint window adjustment

    double bestDist = double.infinity; // Track the smallest perpendicular distance found so far
    LatLng bestPoint = polyline[0]; // Track the best projected point found so far (initialize with first vertex)
    int bestIdx = 0; // Track the best segment index
    double bestProgress = 0.0; // Track the best cumulative progress in meters

    // Precompute cumulative distances for progress
    final cum = List<double>.filled(polyline.length, 0.0); // cum[i] = distance from start to vertex i
    for (int i = 1; i < polyline.length; i++) { // Iterate vertices to accumulate distances
      cum[i] = cum[i - 1] + _dist(polyline[i - 1], polyline[i]); // cum[i] = cum[i-1] + distance between consecutive vertices
    } // End cumulative precomputation

    for (int i = start; i <= end; i++) { // Iterate through candidate segments [start..end]
      final A = polyline[i]; // Segment start vertex
      final B = polyline[i + 1]; // Segment end vertex
      final proj = _projectPointOnSegment(point, A, B); // Project input point onto segment AB (clamped to stay on the segment)
      final d = _dist(point, proj); // Compute perpendicular distance from original point to projected point in meters
      if (d < bestDist) { // If this segment yields a closer projection than any seen so far
        bestDist = d; // Update best distance
        bestPoint = proj; // Update best projected point
        bestIdx = i; // Update best segment index
        bestProgress = cum[i] + _dist(A, proj); // Progress = distance to A plus distance along segment from A to projection
      } // End improvement check
    } // End segment search

    return SnapResult( // Return the best projection found
      snappedPoint: bestPoint, // Closest point on the route
      lateralOffsetMeters: bestDist, // Perpendicular distance to the route
      progressMeters: bestProgress, // Cumulative distance traversed along route to the snap point
      segmentIndex: bestIdx, // Segment index used for snap
    ); // End return
  } // End snap()

  static double _dist(LatLng a, LatLng b) => // Helper: geodesic distance (meters) between two LatLngs using Geolocator (haversine)
      Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude); // Calls platform-optimized distance function

  /// Project point P onto segment AB, clamped to the segment endpoints.
  static LatLng _projectPointOnSegment(LatLng p, LatLng a, LatLng b) { // Compute projection using a local equirectangular approximation
    // Convert to approximate meters using simple equirectangular projection around segment latitude.
    final latRad = ((a.latitude + b.latitude) * 0.5) * (3.141592653589793 / 180.0); // Average latitude in radians for scaling
    final kx = 111320.0 * cos(latRad); // Meters per degree of longitude at this latitude (~111.32 km * cos(lat))
    const ky = 110540.0; // Average meters per degree of latitude (slightly varies; 110.54 km is a common mean)

    final ax = a.longitude * kx; // Convert A.lon to local meters (x)
    final ay = a.latitude * ky; // Convert A.lat to local meters (y)
    final bx = b.longitude * kx; // Convert B.lon to local meters (x)
    final by = b.latitude * ky; // Convert B.lat to local meters (y)
    final px = p.longitude * kx; // Convert P.lon to local meters (x)
    final py = p.latitude * ky; // Convert P.lat to local meters (y)

    final vx = bx - ax; // Vector AB x-component (meters)
    final vy = by - ay; // Vector AB y-component (meters)
    final wx = px - ax; // Vector AP x-component (meters)
    final wy = py - ay; // Vector AP y-component (meters)
    final vv = vx * vx + vy * vy; // Squared length of AB (|AB|^2) in meters^2
    double t = vv > 0 ? (wx * vx + wy * vy) / vv : 0.0; // Parametric projection t = (AP·AB)/|AB|^2, or 0 if degenerate
    if (t < 0) t = 0; else if (t > 1) t = 1; // Clamp t to [0,1] so projection stays on the segment

    final sx = ax + t * vx; // Projected point X (meters): A.x + t*AB.x
    final sy = ay + t * vy; // Projected point Y (meters): A.y + t*AB.y
    final slon = sx / kx; // Convert back to degrees longitude
    final slat = sy / ky; // Convert back to degrees latitude
    return LatLng(slat, slon); // Return projected point as LatLng
  } // End _projectPointOnSegment
} // End class SnapToRouteEngine

/* Block summary: snap() iterates candidate segments (all, or a hint-centered window) and finds the projection with the
   smallest perpendicular distance to the input point, then computes progress as cumulative length to the segment plus
   the partial segment length to the projection. The projection uses a locally flat (equirectangular) approximation,
   which is numerically stable and efficient for short segments and typical GPS scales. */

/* File summary: SnapToRoute underpins the entire tracking pipeline:
   - ActiveRouteManager uses it to report snapped position and progress along the active route.
   - DeviationMonitor uses the lateral offset to determine offroute/deviation states with hysteresis.
   - TrackingService consumes both to drive alarms (distance/time/stops), switching, reroute decisions, and UI updates.
   - The approach pairs geodesic distances (for lengths) with equirectangular projection (for projection maths), giving a
     good balance of accuracy and performance for mobile navigation use cases. */
