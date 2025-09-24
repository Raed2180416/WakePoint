// docs/annotated/services/polyline_simplifier.annotated.dart
// Purpose: Line-by-line annotated copy of `lib/services/polyline_simplifier.dart`.
// Scope: Ramer–Douglas–Peucker simplification, meters-based perpendicular distance, gzip/base64 compression helpers.

import 'dart:math'; // Trig and sqrt for haversine and projections.
import 'dart:convert'; // JSON and base64 encoding.
import 'dart:io'; // gzip compression/decompression.
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng container.

/// [PolylineSimplifier] implements the Ramer–Douglas–Peucker algorithm to simplify a polyline. // Class-level summary.
/// It also provides methods to compress and decompress the simplified polyline.                 // Mentions compression helpers.
class PolylineSimplifier { // Names a static-utility style class.
  /// Simplifies a list of [LatLng] points using the RDP algorithm. // Method summary.
  /// [points]: The original polyline points.                       // Param: input polyline in degrees.
  /// [tolerance]: The maximum allowed deviation (in meters) from the original polyline. // Param notes: meters based.
  /// Returns a new, simplified list of [LatLng] points.            // Return contract.
  static List<LatLng> simplifyPolyline(List<LatLng> points, double tolerance) { // Static utility entry.
    if (points.length < 3) return points; // Trivial cases: cannot simplify fewer than 3 points.

    // Find the point with the maximum perpendicular distance from the line. // RDP split selection.
    double maxDistance = 0.0; // Tracks farthest deviation.
    int index = 0;            // Index of the farthest point.
    for (int i = 1; i < points.length - 1; i++) { // Skip endpoints.
      double distance = _perpendicularDistance(points[i], points.first, points.last); // Distance of point from chord.
      if (distance > maxDistance) { // Maintain max.
        maxDistance = distance;     // Update max distance.
        index = i;                  // Update split index.
      }
    }

    // If the maximum distance exceeds the tolerance, recursively simplify. // RDP recursion.
    if (maxDistance > tolerance) {
      List<LatLng> recResults1 = simplifyPolyline(points.sublist(0, index + 1), tolerance); // Left segment (inclusive of split).
      List<LatLng> recResults2 = simplifyPolyline(points.sublist(index), tolerance);        // Right segment (from split).
      // Combine the results while avoiding duplicate at the split point. // Merge halves without double-counting split.
      return recResults1.sublist(0, recResults1.length - 1) + recResults2; // Drop last from left; concat right.
    } else {
      // If the deviation is within tolerance, return only the start and end points. // Whole segment approximated by chord.
      return [points.first, points.last]; // Endpoints preserve geometry under tolerance.
    }
  }

  /// Helper: Calculates the perpendicular distance from point [p] to the SEGMENT defined by [lineStart] and [lineEnd]. // Geometry helper.
  /// Uses a projection method clamped to [0,1] so the closest point lies on the segment, not the infinite line. // Segment distance.
  /// Returns the distance in meters using haversine on radian coordinates. // Uses radian projection and haversine.
  static double _perpendicularDistance(LatLng p, LatLng lineStart, LatLng lineEnd) { // Private static helper.
    // If lineStart and lineEnd are the same point, return the direct distance. // Degenerate line segment.
    if (lineStart.latitude == lineEnd.latitude && lineStart.longitude == lineEnd.longitude) {
      return _distanceBetweenPoints(p, lineStart); // Fall back to point distance.
    }

    // Convert degrees to radians for accurate calculation. // Prepare radian values.
    double lat1 = _toRadians(lineStart.latitude);
    double lng1 = _toRadians(lineStart.longitude);
    double lat2 = _toRadians(lineEnd.latitude);
    double lng2 = _toRadians(lineEnd.longitude);
    double latP = _toRadians(p.latitude);
    double lngP = _toRadians(p.longitude);

    // Calculate the differences. // Vector components of line segment.
    double dLat = lat2 - lat1;
    double dLng = lng2 - lng1;

  // Project point p onto the line and clamp to segment. // Scalar projection along line vector with clamping.
  double u = ((latP - lat1) * dLat + (lngP - lng1) * dLng) / (dLat * dLat + dLng * dLng);
  if (u < 0) u = 0; // Clamp to start of segment
  if (u > 1) u = 1; // Clamp to end of segment

  // Find the closest point on the segment (after clamping). // Parametric point on segment.
    double latClosest = lat1 + u * dLat;
    double lngClosest = lng1 + u * dLng;

    // Return the distance from p to the closest point on the line. // Haversine between p and projection.
    return _distanceBetweenRadians(latP, lngP, latClosest, lngClosest);
  }

  /// Converts degrees to radians. // Simple helper.
  static double _toRadians(double degree) {
    return degree * pi / 180; // Degrees to radians conversion.
  }

  /// Calculates the distance (in meters) between two [LatLng] points using the haversine formula. // Haversine with degree inputs.
  static double _distanceBetweenPoints(LatLng a, LatLng b) {
    const double earthRadius = 6371000; // in meters // Radius of Earth.
    double dLat = _toRadians(b.latitude - a.latitude); // Delta latitude in radians.
    double dLng = _toRadians(b.longitude - a.longitude); // Delta longitude in radians.
    double lat1 = _toRadians(a.latitude); // a latitude in radians.
    double lat2 = _toRadians(b.latitude); // b latitude in radians.

    double aCalc = sin(dLat / 2) * sin(dLat / 2) + // Haversine intermediate.
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    double c = 2 * atan2(sqrt(aCalc), sqrt(1 - aCalc)); // Angular distance.
    return earthRadius * c; // Meters distance.
  }

  /// Calculates the distance between two points provided in radians. // Radian overload avoids recompute.
  static double _distanceBetweenRadians(double lat1, double lng1, double lat2, double lng2) {
    const double earthRadius = 6371000; // meters // Same radius.
    double dLat = lat2 - lat1; // Radian deltas.
    double dLng = lng2 - lng1;
    double aCalc = sin(dLat / 2) * sin(dLat / 2) + // Haversine intermediate.
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    double c = 2 * atan2(sqrt(aCalc), sqrt(1 - aCalc)); // Angular distance.
    return earthRadius * c; // Convert to meters.
  }

  /// Compresses a list of [LatLng] points into a compressed string. // Compression pipeline overview.
  /// The points are first JSON encoded, then compressed using gzip, and finally encoded in base64. // Encoding chain.
  static String compressPolyline(List<LatLng> points) { // Static compressor.
    // Convert the list of LatLng objects to a list of maps. // Serialize as simple numeric lat/lng pairs.
    List<Map<String, double>> pointList =
        points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList();
    String jsonString = jsonEncode(pointList); // JSON stringify.
    // Compress the JSON string using gzip. // Byte-level compression.
    List<int> compressedBytes = gzip.encode(utf8.encode(jsonString)); // UTF-8 then gzip encode.
    // Encode the compressed bytes as a base64 string for safe storage. // Text-safe container for bytes.
    return base64Encode(compressedBytes); // Return portable string.
  }

  /// Decompresses a compressed polyline string back into a list of [LatLng] points. // Decompression path.
  static List<LatLng> decompressPolyline(String compressed) { // Static decompressor.
    // Decode the base64 string back to bytes. // Reverse base64.
    List<int> compressedBytes = base64Decode(compressed);
    // Decompress using gzip. // Reverse gzip.
    List<int> jsonBytes = gzip.decode(compressedBytes);
    String jsonString = utf8.decode(jsonBytes); // Decode UTF-8 bytes to JSON string.
    List<dynamic> jsonData = jsonDecode(jsonString); // Parse JSON array.
    return jsonData.map((item) => LatLng(item['lat'], item['lng'])).toList(); // Map to LatLng list.
  }
}

// Post-block notes:
// - The RDP algorithm keeps endpoints and recursively splits at the worst-offending point until within tolerance.
// - Distances are computed using haversine; perpendicular projection uses radians for stability, clamped to segment.
// - Compression uses JSON+gzip+base64 for simplicity and portability; favoring readability over maximum compactness.
// - This simplifier is deterministic for given inputs and tolerance.

// End-of-file summary:
// - Input: polyline `List<LatLng>` and `tolerance` meters.
// - Output: simplified `List<LatLng>` retaining shape within tolerance; and helpers to compress/decompress.
// - Complexity: O(N log N) worst-case due to recursion; typical near-linear for natural polylines.
// - Edge cases: degenerate segments; <3 points; high tolerance collapses to endpoints.
