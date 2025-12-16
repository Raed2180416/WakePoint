import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/route_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LatLng pt(double lat, double lng) => LatLng(lat, lng);

  List<LatLng> line(LatLng a, LatLng b) => [a, b];

  test('upsert should replace geometry/metrics when key is reused', () {
    final registry = RouteRegistry(capacity: 4);

    final first = RouteEntry(
      key: 'active_route',
      mode: 'driving',
      destinationName: 'A',
      points: line(pt(0, 0), pt(0, 1)), // ~111km
    );
    registry.upsert(first);

    final second = RouteEntry(
      key: 'active_route',
      mode: 'driving',
      destinationName: 'A',
      points: line(pt(0, 0), pt(0, 0.1)), // ~11km, different bbox/length
    );
    registry.upsert(second);

    final stored = registry.entries.firstWhere((e) => e.key == 'active_route');

    // Expect the latest geometry to be stored, not just timestamps bumped.
    expect(stored.points.length, second.points.length);
    expect(stored.points.first, second.points.first);
    expect(stored.points.last, second.points.last);
    expect(stored.lengthMeters, lessThan(first.lengthMeters));
    expect(stored.bbox.northeast.longitude, closeTo(0.1, 1e-6));
  });
}
