import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';

void main() {
  group('RouteGeometry', () {
    test('projects a point on route to correct s', () {
      final pts = [
        const LatLng(12.0, 77.0),
        const LatLng(12.0, 77.001),
      ];
      final geom = RouteGeometry.fromPoints(pts);

      final total = Geolocator.distanceBetween(
        pts[0].latitude,
        pts[0].longitude,
        pts[1].latitude,
        pts[1].longitude,
      );

      final mid = const LatLng(12.0, 77.0005);
      final s = geom.projectLatLng(mid.latitude, mid.longitude);

      expect(s.isNaN, isFalse);
      expect(s, closeTo(total * 0.5, 2.0));
    });

    test('returns NaN for points far from route', () {
      final pts = [
        const LatLng(12.0, 77.0),
        const LatLng(12.0, 77.001),
      ];
      final geom = RouteGeometry.fromPoints(pts, maxLateralErrorMeters: 50);

      final far = const LatLng(12.01, 77.01);
      final s = geom.projectLatLng(far.latitude, far.longitude);

      expect(s.isNaN, isTrue);
    });

    test('tangent continuity interpolates at boundary', () {
      final pts = [
        const LatLng(12.0, 77.0),
        const LatLng(12.0, 77.001),
        const LatLng(12.001, 77.001),
      ];
      final geom = RouteGeometry.fromPoints(pts);

      final boundary = Geolocator.distanceBetween(
        pts[0].latitude,
        pts[0].longitude,
        pts[1].latitude,
        pts[1].longitude,
      );

      final t = geom.tangentAt(boundary + 3.75);
      // Expect a blended vector within the interpolation window.
      expect(t[0], greaterThan(0.2));
      expect(t[1], greaterThan(0.2));
    });
  });
}
