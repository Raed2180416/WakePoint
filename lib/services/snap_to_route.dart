import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math' show cos;

class SnapResult {
  final LatLng snappedPoint;
  final double lateralOffsetMeters;
  final double progressMeters;
  final int segmentIndex;
  const SnapResult({
    required this.snappedPoint,
    required this.lateralOffsetMeters,
    required this.progressMeters,
    required this.segmentIndex,
  });
}

class SnapToRouteEngine {
  /// Snap a point to a polyline. Optionally provide a hint segment index to reduce search.
  static SnapResult snap({
    required LatLng point,
    required List<LatLng> polyline,
    int? hintIndex,
    int searchWindow = 20,
  }) {
    if (polyline.length < 2) {
      return SnapResult(
        snappedPoint: point,
        lateralOffsetMeters: double.infinity,
        progressMeters: 0,
        segmentIndex: 0,
      );
    }

    int start = 0;
    int end = polyline.length - 2;
    if (hintIndex != null) {
      start = (hintIndex - searchWindow).clamp(0, end);
      end = (hintIndex + searchWindow).clamp(0, end);
    }

    double bestDist = double.infinity;
    LatLng bestPoint = polyline[0];
    int bestIdx = 0;
    double bestProgress = 0.0;

    // Precompute cumulative distances for progress
    final cum = List<double>.filled(polyline.length, 0.0);
    for (int i = 1; i < polyline.length; i++) {
      cum[i] = cum[i - 1] + _dist(polyline[i - 1], polyline[i]);
    }

    for (int i = start; i <= end; i++) {
      final A = polyline[i];
      final B = polyline[i + 1];
      final proj = _projectPointOnSegment(point, A, B);
      final d = _dist(point, proj);
      if (d < bestDist) {
        bestDist = d;
        bestPoint = proj;
        bestIdx = i;
        bestProgress = cum[i] + _dist(A, proj);
      }
    }

    return SnapResult(
      snappedPoint: bestPoint,
      lateralOffsetMeters: bestDist,
      progressMeters: bestProgress,
      segmentIndex: bestIdx,
    );
  }

  static double _dist(LatLng a, LatLng b) =>
      Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

  /// Project point P onto segment AB, clamped to the segment endpoints.
  static LatLng _projectPointOnSegment(LatLng p, LatLng a, LatLng b) {
    // Convert to approximate meters using simple equirectangular projection around segment latitude.
    final latRad = ((a.latitude + b.latitude) * 0.5) * (3.141592653589793 / 180.0);
    final kx = 111320.0 * cos(latRad);
    const ky = 110540.0; // average meters per degree latitude

    final ax = a.longitude * kx;
    final ay = a.latitude * ky;
    final bx = b.longitude * kx;
    final by = b.latitude * ky;
    final px = p.longitude * kx;
    final py = p.latitude * ky;

    final vx = bx - ax;
    final vy = by - ay;
    final wx = px - ax;
    final wy = py - ay;
    final vv = vx * vx + vy * vy;
    double t = vv > 0 ? (wx * vx + wy * vy) / vv : 0.0;
    if (t < 0) t = 0; else if (t > 1) t = 1;

    final sx = ax + t * vx;
    final sy = ay + t * vy;
    final slon = sx / kx;
    final slat = sy / ky;
    return LatLng(slat, slon);
  }
}
