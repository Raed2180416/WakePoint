import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/active_route_manager.dart';

void main() {
  group('ActiveRouteManager complex deviations and merge', () {
    test('Five deviations, merge back to route1, then deviate again to route2', () async {
      final reg = RouteRegistry(capacity: 5);
      // Route 1 (A): East along equator from lon 0 to 0.010
      final a = RouteEntry(
        key: 'R1', mode: 'driving', destinationName: 'R1',
        points: const [LatLng(0,0), LatLng(0,0.003), LatLng(0,0.006), LatLng(0,0.010)],
      );
      // Route 2 (B): Parallel north (lat +0.002) then merges down to A near lon 0.008
      final b = RouteEntry(
        key: 'R2', mode: 'driving', destinationName: 'R2',
        points: const [
          LatLng(0.002, 0.0005), LatLng(0.002, 0.0035), LatLng(0.002, 0.0065),
          LatLng(0.001, 0.0080), LatLng(0.0005, 0.0090), LatLng(0.0000, 0.0100)
        ],
      );
      reg.upsert(a);
      reg.upsert(b);

      final mgr = ActiveRouteManager(
        registry: reg,
        sustainDuration: const Duration(milliseconds: 200),
        switchMarginMeters: 10,
        postSwitchBlackout: const Duration(milliseconds: 100),
      );
      mgr.setActive('R1');
      final switches = <RouteSwitchEvent>[];
      mgr.switchStream.listen(switches.add);

      // Helper to feed a point and wait small time
      Future<void> feed(LatLng p, [int ms = 120]) async { mgr.ingestPosition(p); await Future<void>.delayed(Duration(milliseconds: ms)); }
      Future<void> sustainAt(LatLng p, int ms) async { final steps = (ms/80).ceil(); for (int i=0; i<steps; i++){ await feed(p, 80);} }

      // Start on R1
      await feed(const LatLng(0.0000, 0.0010));

      // Perform up to five deviations to R2 corridor and back near R1
      for (int i=0; i<5; i++) {
        // Deviate to R2: go north near same longitude corridor
  await sustainAt(LatLng(0.0020, 0.002 + i*0.001), 260); // sustain > 200ms
        // Nudge to force evaluation
  await feed(LatLng(0.0020, 0.002 + i*0.001 + 0.0001), 60);
        // Back towards R1 (but not always switching back immediately; hysteresis applies)
  await sustainAt(LatLng(0.0002, 0.0022 + i*0.001), 220);
  await feed(LatLng(0.0002, 0.0022 + i*0.001 + 0.0001), 60);
      }

      // Move along where R2 merges into R1 near lon ~0.008 - should favor R1
      await sustainAt(const LatLng(0.0002, 0.0080), 240);
      await feed(const LatLng(0.0001, 0.0085), 80);

      // Expect at least one switch back to R1 due to merge
      expect(switches.any((e) => e.fromKey == 'R2' && e.toKey == 'R1'), true,
        reason: 'Should switch back to R1 when routes merge');

      // Then deviate again to R2 and continue near its end
      await sustainAt(const LatLng(0.0010, 0.0090), 260);
      await feed(const LatLng(0.0020, 0.0095), 100);
      await feed(const LatLng(0.0020, 0.0100), 120);

      // Expect a subsequent switch back to R2 at some point after merge
      expect(switches.any((e) => e.fromKey == 'R1' && e.toKey == 'R2'), true,
        reason: 'Should be able to switch back to R2 after merge when deviating again');

      // Sanity: ensure at least 3 switches occurred across the scenario
      expect(switches.length >= 3, true);
    });
  });
}
