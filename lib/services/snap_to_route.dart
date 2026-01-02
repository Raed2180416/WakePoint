import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';

class SnapResult {
  final LatLng snappedPoint;
  final double lateralOffsetMeters;
  final double progressMeters;
  final int segmentIndex;

  /// The cost/score of this match (lower is better). Useful for debugging.
  final double matchScore;

  const SnapResult({
    required this.snappedPoint,
    required this.lateralOffsetMeters,
    required this.progressMeters,
    required this.segmentIndex,
    this.matchScore = 0.0,
  });
}

class SnapToRouteEngine {
  // --- Tunable Parameters ---
  static const double _kHeadingPenaltyMultiplier =
      20.0; // Penalty multiplier for heading mismatch
  static const double _kConnectivityBonus =
      10.0; // Bonus (meters saved) for staying on same/next segment
  static const double _kJumpPenaltyPerIndex = 5.0; // Penalty per index jumped

  /// Snap a point to a polyline using a "Scientific" weighted approach.
  ///
  /// [point]: The user's current raw GPS location.
  /// [polyline]: The ordered list of route points.
  /// [heading]: User's current bearing (0-360). If null, heading logic is disabled.
  /// [previousResult]: The previous snap result, used for connectivity/history.
  /// [precomputedCumMeters]: Cumulative distance array for O(1) progress lookup.
  /// [searchWindow]: How many segments to check around the hint (if available).
  static SnapResult snap({
    required LatLng point,
    required List<LatLng> polyline,
    double? heading,
    SnapResult? previousResult,
    List<double>? precomputedCumMeters,
    int? hintIndex,
    int searchWindow = 25,
  }) {
    if (polyline.length < 2) {
      return SnapResult(
        snappedPoint: point,
        lateralOffsetMeters: double.infinity,
        progressMeters: 0,
        segmentIndex: 0,
      );
    }

    // 1. Determine Search Bounds
    int start = 0;
    int end = polyline.length - 2;

    // effectiveHint: Use previous result's index if available
    int? effectiveHint = previousResult?.segmentIndex;

    if (effectiveHint != null) {
      // Dynamic window: if we are moving fast, look further ahead?
      // For now, fixed window around last known pos.
      start = (effectiveHint - 5).clamp(
        0,
        end,
      ); // Look slightly back (drift/loops)
      end = (effectiveHint + searchWindow).clamp(0, end); // Look mostly forward
    }

    // 2. Precompute Cumulative Meters if needed
    final cum =
        precomputedCumMeters ??
        (() {
          final c = List<double>.filled(polyline.length, 0.0);
          for (int i = 1; i < polyline.length; i++) {
            c[i] = c[i - 1] + _dist(polyline[i - 1], polyline[i]);
          }
          return c;
        })();

    double bestScore = double.infinity;
    LatLng bestPoint = polyline[0];
    double bestDist = double.infinity;
    int bestIdx = 0;
    double bestProgress = 0.0;

    // 3. Iterate Candidates
    for (int i = start; i <= end; i++) {
      final A = polyline[i];
      final B = polyline[i + 1];

      // Geometric Snap
      final proj = _projectPointOnSegment(point, A, B);
      final distMeters = _dist(point, proj);

      // --- Weighted Scoring ---
      double score = distMeters;

      // A. Connectivity / Continuity (History)
      if (previousResult != null) {
        final int prevIdx = previousResult.segmentIndex;
        final int jump = (i - prevIdx).abs();

        // Bonus for being "sticky" (same or next segment)
        if (jump == 0 || jump == 1) {
          score -= _kConnectivityBonus;
        } else {
          // Penalty for jumping far
          score += (jump * _kJumpPenaltyPerIndex);
        }

        // Massive penalty for going WAY back (unless loop? assuming simple routes for now)
        if (i < prevIdx - 3) {
          score += 100.0; // Hard resistance to backward movement
        }
      }

      // B. Heading Alignment
      // Only apply if we have a valid heading and are moving (dist > 0)
      if (heading != null && heading >= 0) {
        // Segment Heading
        final segHeading = Geolocator.bearingBetween(
          A.latitude,
          A.longitude,
          B.latitude,
          B.longitude,
        );

        // Difference (0 to 180)
        double diff = (heading - segHeading).abs();
        if (diff > 180) diff = 360 - diff;

        // Penalty Logic:
        // 0 deg diff -> 0 penalty
        // 90 deg diff -> moderate
        // 180 deg diff -> MAX penalty
        // We use cosine similarityish approach:
        // Penalize significantly if opposing (> 90 deg).
        if (diff > 45) {
          // Add penalty proportional to misalignment
          score += (diff / 180.0) * _kHeadingPenaltyMultiplier;
        }

        // Strict Reverse Lane Check: if > 135 degrees (opposing), huge penalty
        if (diff > 120) {
          score += 50.0; // Assume parallel road is better than reverse lane
        }
      }

      // Track Best
      if (score < bestScore) {
        bestScore = score;
        bestPoint = proj;
        bestDist = distMeters;
        bestIdx = i;
        bestProgress = cum[i] + _dist(A, proj);
      }
    }

    return SnapResult(
      snappedPoint: bestPoint,
      lateralOffsetMeters: bestDist, // Return actual physics dist, not score
      progressMeters: bestProgress,
      segmentIndex: bestIdx,
      matchScore: bestScore,
    );
  }

  static double _dist(LatLng a, LatLng b) => Geolocator.distanceBetween(
    a.latitude,
    a.longitude,
    b.latitude,
    b.longitude,
  );

  /// Project point P onto segment AB, clamped to the segment endpoints.
  static LatLng _projectPointOnSegment(LatLng p, LatLng a, LatLng b) {
    // Equirectangular approximation for performance (valid for short segments)
    final latRad = ((a.latitude + b.latitude) * 0.5) * (pi / 180.0);
    final kx = 111320.0 * cos(latRad);
    const ky = 110540.0;

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

    // t is the projection factor (0.0 to 1.0)
    double t = vv > 0 ? (wx * vx + wy * vy) / vv : 0.0;
    if (t < 0) {
      t = 0;
    } else if (t > 1) {
      t = 1;
    }

    final sx = ax + t * vx;
    final sy = ay + t * vy;
    final slon = sx / kx;
    final slat = sy / ky;
    return LatLng(slat, slon);
  }
}
