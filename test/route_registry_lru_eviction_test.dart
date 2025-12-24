import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/route_registry.dart';

void main() {
  test('RouteRegistry evicts least-recently-used when capacity exceeded', () {
    final reg = RouteRegistry(capacity: 3);

    RouteEntry e(String key, DateTime lastUsed) => RouteEntry(
      key: key,
      mode: 'driving',
      destinationName: key,
      points: const [LatLng(0, 0), LatLng(0, 0.01)],
      lastUsed: lastUsed,
    );

    final now = DateTime.now();
    reg.upsert(e('A', now.subtract(const Duration(minutes: 30))));
    reg.upsert(e('B', now.subtract(const Duration(minutes: 20))));
    reg.upsert(e('C', now.subtract(const Duration(minutes: 10))));

    // New entry should push out the least recently used (A).
    reg.upsert(e('D', now));

    final keys = reg.entries.map((x) => x.key).toSet();
    expect(keys.contains('A'), isFalse);
    expect(keys.containsAll(['B', 'C', 'D']), isTrue);

    // Mark B used; then insert E. The least-recently-used should be C.
    reg.markUsed('B');
    reg.upsert(e('E', now.add(const Duration(seconds: 1))));

    final keys2 = reg.entries.map((x) => x.key).toSet();
    expect(keys2.contains('C'), isFalse);
    expect(keys2.containsAll(['B', 'D', 'E']), isTrue);
  });
}
