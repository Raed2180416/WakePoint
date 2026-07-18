import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Decodes an encoded polyline string into a list of [LatLng] coordinates.
/// Returns an empty list if the input is empty or an error occurs.
List<LatLng> decodePolyline(String encoded) {
  if (encoded.isEmpty) {
    return [];
  }
  List<LatLng> polyline = [];
  int index = 0;
  int len = encoded.length;
  int lat = 0;
  int lng = 0;

  try {
    while (index < len) {
      int shift = 0;
      int result = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      polyline.add(LatLng(lat / 1E5, lng / 1E5));
    }
  } catch (e) {
    // Return the decoded points so far if an error occurs.
    return polyline;
  }
  return polyline;
}

/// Calculate distance between two LatLng points using Haversine formula.
/// Returns distance in meters.
double haversineDistance(LatLng a, LatLng b) {
  const double earthRadius = 6371000; // meters
  final double dLat = _toRadians(b.latitude - a.latitude);
  final double dLng = _toRadians(b.longitude - a.longitude);
  final double lat1 = _toRadians(a.latitude);
  final double lat2 = _toRadians(b.latitude);

  final double hav =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
  final double c = 2 * atan2(sqrt(hav), sqrt(1 - hav));
  return earthRadius * c;
}

double _toRadians(double deg) => deg * pi / 180.0;

/// Calculate total length of a polyline in meters.
double polylineLength(List<LatLng> points) {
  if (points.length < 2) return 0.0;
  double total = 0.0;
  for (int i = 0; i < points.length - 1; i++) {
    total += haversineDistance(points[i], points[i + 1]);
  }
  return total;
}

/// Find the point along a polyline at a specific distance from the start.
/// Returns null if distance exceeds polyline length.
LatLng? pointAlongPolyline(List<LatLng> points, double targetDistance) {
  if (points.isEmpty) return null;
  if (targetDistance <= 0) return points.first;

  double accumulated = 0.0;
  for (int i = 0; i < points.length - 1; i++) {
    final segmentLength = haversineDistance(points[i], points[i + 1]);
    if (accumulated + segmentLength >= targetDistance) {
      // Target is within this segment - interpolate
      final remaining = targetDistance - accumulated;
      final ratio = remaining / segmentLength;
      final lat =
          points[i].latitude +
          ratio * (points[i + 1].latitude - points[i].latitude);
      final lng =
          points[i].longitude +
          ratio * (points[i + 1].longitude - points[i].longitude);
      return LatLng(lat, lng);
    }
    accumulated += segmentLength;
  }
  // Target distance exceeds polyline length - return last point
  return points.last;
}

/// Subdivide a polyline into N equal segments, returning the division points.
/// For a transit leg with `numStops` intermediate stops, use numStops + 1 segments.
/// Returns [numStops] estimated stop positions (excluding departure and arrival).
///
/// Example: 5 stops means 6 segments. Points at 1/6, 2/6, 3/6, 4/6, 5/6 of polyline.
List<LatLng> estimateStopPositions(List<LatLng> polyline, int numStops) {
  if (numStops <= 0 || polyline.length < 2) return const [];

  final totalLength = polylineLength(polyline);
  if (totalLength <= 0) return const [];

  final positions = <LatLng>[];
  for (int i = 1; i <= numStops; i++) {
    // Google Directions `num_stops` is the number of intermediate stops
    // (excluding departure and arrival). So stops lie at 1/(n+1)..n/(n+1).
    final targetDistance = (i / (numStops + 1)) * totalLength;
    final point = pointAlongPolyline(polyline, targetDistance);
    if (point != null) {
      positions.add(point);
    }
  }

  return positions;
}

/// Calculate the cumulative distances along a polyline for a list of stop positions.
/// Returns a list of distances in meters from the start of the polyline.
List<double> stopDistancesAlongPolyline(
  List<LatLng> polyline,
  List<LatLng> stopPositions,
) {
  if (polyline.isEmpty || stopPositions.isEmpty) return const [];

  // Build cumulative distances for polyline vertices
  final cumulativeDistances = <double>[0.0];
  for (int i = 0; i < polyline.length - 1; i++) {
    final d = haversineDistance(polyline[i], polyline[i + 1]);
    cumulativeDistances.add(cumulativeDistances.last + d);
  }

  // For each stop, find closest point on polyline and its distance
  final result = <double>[];
  for (final stop in stopPositions) {
    double minDist = double.infinity;
    double stopDistanceAlongRoute = 0.0;

    for (int i = 0; i < polyline.length - 1; i++) {
      // Project stop onto segment [i, i+1]
      final projected = projectPointOnSegment(
        polyline[i],
        polyline[i + 1],
        stop,
      );
      final distToProjected = haversineDistance(stop, projected.point);

      if (distToProjected < minDist) {
        minDist = distToProjected;
        // Distance along route = cumulative to segment start + distance to projected point
        stopDistanceAlongRoute =
            cumulativeDistances[i] +
            haversineDistance(polyline[i], projected.point);
      }
    }

    result.add(stopDistanceAlongRoute);
  }

  return result;
}

/// Snap a point to the closest position on a polyline.
///
/// Returns null if the polyline is empty.
/// - snapped: closest point on the polyline
/// - metersAlong: cumulative meters from start to snapped
/// - distanceMeters: haversine distance from input point to snapped
({LatLng snapped, double metersAlong, double distanceMeters})?
snapPointToPolyline(List<LatLng> polyline, LatLng point) {
  if (polyline.isEmpty) return null;
  if (polyline.length == 1) {
    return (
      snapped: polyline.first,
      metersAlong: 0.0,
      distanceMeters: haversineDistance(point, polyline.first),
    );
  }

  // Build cumulative distances for polyline vertices
  final cumulativeDistances = <double>[0.0];
  for (int i = 0; i < polyline.length - 1; i++) {
    final d = haversineDistance(polyline[i], polyline[i + 1]);
    cumulativeDistances.add(cumulativeDistances.last + d);
  }

  double bestDist = double.infinity;
  LatLng bestPoint = polyline.first;
  double bestMetersAlong = 0.0;

  for (int i = 0; i < polyline.length - 1; i++) {
    final projected = projectPointOnSegment(
      polyline[i],
      polyline[i + 1],
      point,
    );
    final snapped = projected.point;
    final dist = haversineDistance(point, snapped);

    if (dist < bestDist) {
      bestDist = dist;
      bestPoint = snapped;
      bestMetersAlong =
          cumulativeDistances[i] + haversineDistance(polyline[i], snapped);
    }
  }

  return (
    snapped: bestPoint,
    metersAlong: bestMetersAlong,
    distanceMeters: bestDist,
  );
}

/// Project a point onto a line segment, returning the closest point on the
/// segment and the clamped parameter `t` in [0, 1].
///
/// Uses an equirectangular (cos-latitude) correction so longitude and latitude
/// deltas are compared in a common metric, matching [SnapToRouteEngine]. Without
/// it, projections onto east-west-leaning segments are skewed because one degree
/// of longitude spans fewer meters than one degree of latitude away from the
/// equator. This is the single shared projector for every stop snapper so their
/// geometry cannot diverge. Behaviour is unchanged for purely north-south
/// segments (where the longitude delta, and thus the correction, is zero).
({LatLng point, double t}) projectPointOnSegment(
  LatLng a,
  LatLng b,
  LatLng p,
) {
  // Scale longitude deltas by cos(reference latitude) so they are metric-
  // consistent with latitude deltas. Use the segment midpoint latitude.
  final double cosLat = cos(_toRadians((a.latitude + b.latitude) * 0.5));

  final dx = (b.longitude - a.longitude) * cosLat;
  final dy = b.latitude - a.latitude;
  final lenSq = dx * dx + dy * dy;

  if (lenSq < 1e-12) {
    // Segment is essentially a point
    return (point: a, t: 0.0);
  }

  // Calculate projection parameter t in the cos-lat-corrected space.
  double t =
      ((p.longitude - a.longitude) * cosLat * dx +
              (p.latitude - a.latitude) * dy) /
          lenSq;
  t = t.clamp(0.0, 1.0);

  // Reconstruct the snapped coordinate. The longitude scaling cancels, so we
  // interpolate the raw longitude delta directly (no divide-by-cos).
  final snappedLat = a.latitude + t * dy;
  final snappedLng = a.longitude + t * (b.longitude - a.longitude);
  return (point: LatLng(snappedLat, snappedLng), t: t);
}
