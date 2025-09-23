import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/snap_to_route.dart';
import 'log_helper.dart';

void main() {
  group('SnapToRouteEngine', () {
    // Construct a simple polyline: a right-angle L shape
    final poly = <LatLng>[
      const LatLng(0.0, 0.0),
      const LatLng(0.0, 0.01), // ~1.1km east
      const LatLng(0.01, 0.01), // then ~1.1km north
    ];

    test('Snaps near first segment with small lateral offset', () {
      logSection('SnapToRoute: basic projection');
      final p = const LatLng(0.0005, 0.005); // ~55m north of first segment center
      final r = SnapToRouteEngine.snap(point: p, polyline: poly);
      logInfo('Segment index=${r.segmentIndex}, offset≈${r.lateralOffsetMeters.toStringAsFixed(1)} m, progress≈${r.progressMeters.toStringAsFixed(1)} m');
      expect(r.segmentIndex, 0);
      expect(r.lateralOffsetMeters, greaterThan(40));
      expect(r.lateralOffsetMeters, lessThan(80));
      expect(r.progressMeters, greaterThan(400));
      expect(r.progressMeters, lessThan(700));
    });

    test('Respects hintIndex to keep continuity', () {
      final p1 = const LatLng(0.0005, 0.005);
      final r1 = SnapToRouteEngine.snap(point: p1, polyline: poly);
      final p2 = const LatLng(0.0006, 0.006); // move a bit east
      final r2 = SnapToRouteEngine.snap(point: p2, polyline: poly, hintIndex: r1.segmentIndex);
      logInfo('r1.progress≈${r1.progressMeters.toStringAsFixed(1)} m -> r2.progress≈${r2.progressMeters.toStringAsFixed(1)} m');
      expect(r2.segmentIndex, anyOf(0, 1)); // could move to the corner
      // progress should be non-decreasing with motion forward along route
      expect(r2.progressMeters, greaterThanOrEqualTo(r1.progressMeters));
    });

    test('Snaps to second segment once past the corner', () {
      final p = const LatLng(0.008, 0.0102); // near vertical segment
      final r = SnapToRouteEngine.snap(point: p, polyline: poly, hintIndex: 1);
      logInfo('Segment index=${r.segmentIndex}, offset≈${r.lateralOffsetMeters.toStringAsFixed(1)} m');
      expect(r.segmentIndex, 1);
      expect(r.lateralOffsetMeters, lessThan(60));
    });
  });
}
