import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/snap_to_route.dart';

void main() {
  group('SnapToRouteEngine "Scientific Snapping" Tests', () {
    // A simple straight line: (0,0) -> (0, 0.001) -> (0, 0.002) ...
    // Approx 111m per 0.001 degrees latitude.
    final List<LatLng> straightLine = [
      LatLng(0.000, 0.0),
      LatLng(0.001, 0.0), // ~111m
      LatLng(0.002, 0.0), // ~222m
      LatLng(0.003, 0.0), // ~333m
    ];

    // A route with a parallel service road
    // Main road: (0,0) -> (0, 0.01)
    // Parallel road: (0.0005, 0) -> (0.0005, 0.01) (Parallel at ~55m offset)

    test('Basic Geometric Snap (No History)', () {
      final userPos = LatLng(0.0005, 0.0001); // 50m along, 11m offset
      final result = SnapToRouteEngine.snap(
        point: userPos,
        polyline: straightLine,
      );

      expect(result.segmentIndex, 0);
      expect(result.progressMeters, closeTo(55.6, 1.0)); // 0.0005 deg * 111320
    });

    test('Heading Alignment: Prefer correct direction', () {
      // Create a "U-Turn" shape or parallel roads with opposite directions?
      // Actually, simple constraint:
      // Route A->B (Heading 0/North)

      // User is moving South (180).
      // If we had two segments, one going North, one South, it should pick South.

      final List<LatLng> loopRoute = [
        LatLng(0.0, 0.0), LatLng(0.001, 0.0), // North
        LatLng(0.001, 0.001), // East
        LatLng(0.0, 0.001), LatLng(0.0, 0.0), // South then West
      ];
      // Segment 0: North
      // Segment 2: South (0.001, 0.001) -> (0.0, 0.001)

      // User is at (0.0005, 0.0005) - middle of the loop square
      // Heading is 180 (South).
      // Should snap to Segment 2 (Southbound), not Segment 0 (Northbound).

      final userPos = LatLng(0.0005, 0.0005);

      final result = SnapToRouteEngine.snap(
        point: userPos,
        polyline: loopRoute,
        heading: 180.0, // South
      );

      expect(
        result.segmentIndex,
        2,
        reason: "Should pick southbound segment due to heading alignment",
      );
    });

    test('Connectivity Stickiness: Prefer current segment', () {
      // Jumping scenario.
      // 0->1 is Main Road.
      // 10->11 is Parallel Road (far away index, but spatially close? loop back?)

      // Let's model a "Lollipop" or tight spiral where index 0 and index 100 are close.
      final List<LatLng> spiral = [
        LatLng(0, 0), LatLng(0.001, 0), // Seg 0
        // ... wandering ...
        LatLng(0.0001, 0.0002),
        LatLng(0.0011, 0.0002), // Seg 10 (parallel, slightly offset)
      ];
      // Fake fill in between
      for (int i = 2; i < 10; i++) {
        spiral.insert(i, LatLng(10.0, 10.0)); // Far away
      }

      final userPosEqui = LatLng(0.0005, 0.0001);

      // Case 1: No History -> Picks closest (Seg 0)
      final res1 = SnapToRouteEngine.snap(point: userPosEqui, polyline: spiral);
      expect(res1.segmentIndex, 0);

      // Case 2: History says we were on Seg 10 -> Should stick to Seg 10 despite Seg 0 being close/closer
      final history = SnapResult(
        snappedPoint: LatLng(0, 0),
        lateralOffsetMeters: 0,
        progressMeters: 0,
        segmentIndex: 10,
      );

      final res2 = SnapToRouteEngine.snap(
        point: userPosEqui,
        polyline: spiral,
        previousResult: history,
      );

      expect(
        res2.segmentIndex,
        10,
        reason: "Should stick to segment 10 due to connectivity",
      );
    });

    test('Parallel Road Rejection via History', () {
      // Two parallel lines very close.
      // Seg 0: (0,0) -> (0, 1)
      // Seg 5: (0.00005, 0) -> (0.00005, 1) (5 meters away)

      final List<LatLng> parallel = [
        LatLng(0, 0), LatLng(0, 0.01), // Seg 0
        LatLng(10, 10), LatLng(10, 11), // Seg 1..4 (far)
        LatLng(10, 12), LatLng(10, 13),
        LatLng(10, 14),
        LatLng(0.00005, 0), LatLng(0.00005, 0.01), // Seg 5
      ];

      // User is exactly on Seg 5 (Parallel).
      final userPos = LatLng(0.00005, 0.005);

      // History says we are on Seg 0.
      // The jump from 0 to 5 is 5 indices.
      // Penalty = 5 * 5 = 25 score.
      // Distance difference = 0 (on Seg 5) vs 5m (on Seg 0).
      // Cost Seg 5 = 0 (dist) + 25 (jump) = 25.
      // Cost Seg 0 = 5 (dist) + 0 (jump) = 5.
      // Should stick to Seg 0 (projected) even though user is physically on Seg 5.

      final history = SnapResult(
        snappedPoint: LatLng(0, 0),
        lateralOffsetMeters: 0,
        progressMeters: 0,
        segmentIndex: 0,
      );

      final res = SnapToRouteEngine.snap(
        point: userPos,
        polyline: parallel,
        previousResult: history,
      );

      expect(
        res.segmentIndex,
        0,
        reason:
            "Should resist jumping to parallel road due to index distance penalty",
      );
    });
  });
}
