import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/route_registry.dart';
import 'log_helper.dart';

void main() {
  test('RouteRegistry candidate filtering by proximity and recency', () {
    logSection('RouteRegistry candidate filtering');
    final reg = RouteRegistry(capacity: 3);
    final a = RouteEntry(
      key: 'A', mode: 'driving', destinationName: 'A',
      points: const [LatLng(0,0), LatLng(0,0.01)],
    );
    final b = RouteEntry(
      key: 'B', mode: 'driving', destinationName: 'B',
      points: const [LatLng(1,1), LatLng(1,1.01)],
    );
    final c = RouteEntry(
      key: 'C', mode: 'driving', destinationName: 'C',
      points: const [LatLng(0.005,0.005), LatLng(0.006,0.006)],
    );
    reg.upsert(a);
    reg.upsert(b);
    reg.upsert(c);
    final near = reg.candidatesNear(const LatLng(0.001, 0.002), radiusMeters: 1200, maxCandidates: 3);
    logInfo('Candidates near approximate origin: ${near.map((e)=>e.key).toList()}');
    expect(near.any((e) => e.key == 'A'), true);
    expect(near.any((e) => e.key == 'C'), true);
    expect(near.any((e) => e.key == 'B'), false);
    logPass('Near list contains A and C, excludes distant B');
  });
}
