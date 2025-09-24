import 'dart:math';
import 'dart:convert';
import 'dart:io'; // For gzip compression/decompression.
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// [PolylineSimplifier] implements the Ramer–Douglas–Peucker algorithm to simplify a polyline.
/// It also provides methods to compress and decompress the simplified polyline.
class PolylineSimplifier {
  /// Simplifies a list of [LatLng] points using the RDP algorithm.
  /// [points]: The original polyline points.
  /// [tolerance]: The maximum allowed deviation (in meters) from the original polyline.
  /// Returns a new, simplified list of [LatLng] points.
  static List<LatLng> simplifyPolyline(List<LatLng> points, double tolerance) {
    if (points.length < 3) return points;

    // Find the point with the maximum perpendicular distance from the line.
    double maxDistance = 0.0;
    int index = 0;
    for (int i = 1; i < points.length - 1; i++) {
      double distance = _perpendicularDistance(points[i], points.first, points.last);
      if (distance > maxDistance) {
        maxDistance = distance;
        index = i;
      }
    }

    // If the maximum distance exceeds the tolerance, recursively simplify.
    if (maxDistance > tolerance) {
      List<LatLng> recResults1 = simplifyPolyline(points.sublist(0, index + 1), tolerance);
      List<LatLng> recResults2 = simplifyPolyline(points.sublist(index), tolerance);
      // Combine the results while avoiding duplicate at the split point.
      return recResults1.sublist(0, recResults1.length - 1) + recResults2;
    } else {
      // If the deviation is within tolerance, return only the start and end points.
      return [points.first, points.last];
    }
  }

  /// Helper: Calculates the perpendicular distance from point [p] to the line defined by [lineStart] and [lineEnd].
  /// Uses a projection method and returns the distance in meters.
  static double _perpendicularDistance(LatLng p, LatLng lineStart, LatLng lineEnd) {
    // If lineStart and lineEnd are the same point, return the direct distance.
    if (lineStart.latitude == lineEnd.latitude && lineStart.longitude == lineEnd.longitude) {
      return _distanceBetweenPoints(p, lineStart);
    }

    // Convert degrees to radians for accurate calculation.
    double lat1 = _toRadians(lineStart.latitude);
    double lng1 = _toRadians(lineStart.longitude);
    double lat2 = _toRadians(lineEnd.latitude);
    double lng2 = _toRadians(lineEnd.longitude);
    double latP = _toRadians(p.latitude);
    double lngP = _toRadians(p.longitude);

    // Calculate the differences.
    double dLat = lat2 - lat1;
    double dLng = lng2 - lng1;

  // Project point p onto the line and clamp to segment [0,1].
  double u = ((latP - lat1) * dLat + (lngP - lng1) * dLng) / (dLat * dLat + dLng * dLng);
  if (u < 0.0) u = 0.0; else if (u > 1.0) u = 1.0;

  // Find the closest point on the segment.
  double latClosest = lat1 + u * dLat;
  double lngClosest = lng1 + u * dLng;

    // Return the distance from p to the closest point on the line.
    return _distanceBetweenRadians(latP, lngP, latClosest, lngClosest);
  }

  /// Converts degrees to radians.
  static double _toRadians(double degree) {
    return degree * pi / 180;
  }

  /// Calculates the distance (in meters) between two [LatLng] points using the haversine formula.
  static double _distanceBetweenPoints(LatLng a, LatLng b) {
    const double earthRadius = 6371000; // in meters
    double dLat = _toRadians(b.latitude - a.latitude);
    double dLng = _toRadians(b.longitude - a.longitude);
    double lat1 = _toRadians(a.latitude);
    double lat2 = _toRadians(b.latitude);

    double aCalc = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    double c = 2 * atan2(sqrt(aCalc), sqrt(1 - aCalc));
    return earthRadius * c;
  }

  /// Calculates the distance between two points provided in radians.
  static double _distanceBetweenRadians(double lat1, double lng1, double lat2, double lng2) {
    const double earthRadius = 6371000;
    double dLat = lat2 - lat1;
    double dLng = lng2 - lng1;
    double aCalc = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    double c = 2 * atan2(sqrt(aCalc), sqrt(1 - aCalc));
    return earthRadius * c;
  }

  /// Compresses a list of [LatLng] points into a compressed string.
  /// The points are first JSON encoded, then compressed using gzip, and finally encoded in base64.
  static String compressPolyline(List<LatLng> points) {
    // Convert the list of LatLng objects to a list of maps.
    List<Map<String, double>> pointList =
        points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList();
    String jsonString = jsonEncode(pointList);
    // Compress the JSON string using gzip.
    List<int> compressedBytes = gzip.encode(utf8.encode(jsonString));
    // Encode the compressed bytes as a base64 string for safe storage.
    return base64Encode(compressedBytes);
  }

  /// Decompresses a compressed polyline string back into a list of [LatLng] points.
  static List<LatLng> decompressPolyline(String compressed) {
    // Decode the base64 string back to bytes.
    List<int> compressedBytes = base64Decode(compressed);
    // Decompress using gzip.
    List<int> jsonBytes = gzip.decode(compressedBytes);
    String jsonString = utf8.decode(jsonBytes);
    List<dynamic> jsonData = jsonDecode(jsonString);
    return jsonData.map((item) => LatLng(item['lat'], item['lng'])).toList();
  }
}
