import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/active_route_manager.dart';
import 'log_helper.dart';

void main() {
  group('ActiveRouteManager switching', () {
    test('Switch from A to B then back to A with hysteresis', () async {
      logSection('ActiveRouteManager: A -> B -> A with hysteresis');
      final reg = RouteRegistry(capacity: 5);
      // Route A: east along equator
      final routeA = RouteEntry(
        key: 'A', mode: 'driving', destinationName: 'A',
        points: const [LatLng(0,0), LatLng(0,0.005), LatLng(0,0.010)],
      );
      // Route B: north from (0.005, 0.005)
      final routeB = RouteEntry(
        key: 'B', mode: 'driving', destinationName: 'B',
        points: const [LatLng(0.0,0.005), LatLng(0.005,0.005), LatLng(0.010,0.005)],
      );
      reg.upsert(routeA);
      reg.upsert(routeB);

      final mgr = ActiveRouteManager(
        registry: reg,
        sustainDuration: const Duration(milliseconds: 300),
        switchMarginMeters: 10,
        postSwitchBlackout: const Duration(milliseconds: 200),
      );
  mgr.setActive('A');
  logStep('Active set to A');
      final switches = <RouteSwitchEvent>[];
      mgr.switchStream.listen(switches.add);

      // Move along A near (0, 0.003)
  logStep('Move along A near (0, 0.003)');
  mgr.ingestPosition(const LatLng(0.0001, 0.003));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      mgr.ingestPosition(const LatLng(0.0001, 0.004));
      await Future<void>.delayed(const Duration(milliseconds: 220));

      // Deviate towards B intersection near (0.005, 0.005) and sustain
  logStep('Deviate towards B corridor and sustain');
  mgr.ingestPosition(const LatLng(0.001, 0.005));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      mgr.ingestPosition(const LatLng(0.003, 0.005));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      mgr.ingestPosition(const LatLng(0.004, 0.005));
  await Future<void>.delayed(const Duration(milliseconds: 300));
  // Trigger evaluation after sustain window
  mgr.ingestPosition(const LatLng(0.0045, 0.005));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  // Expect a switch to B
  expect(switches.any((e) => e.fromKey == 'A' && e.toKey == 'B'), true);
  logPass('Switched from A to B after sustain');

      // After blackout, move back towards A corridor and sustain
      await Future<void>.delayed(const Duration(milliseconds: 250));
  logStep('Move back near A and wait to switch back');
  mgr.ingestPosition(const LatLng(0.0005, 0.006));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      mgr.ingestPosition(const LatLng(0.0002, 0.007));
  await Future<void>.delayed(const Duration(milliseconds: 300));
  // Trigger evaluation after sustain window
  mgr.ingestPosition(const LatLng(0.0002, 0.0075));
  await Future<void>.delayed(const Duration(milliseconds: 50));
  // Expect a switch back to A without any API usage
  expect(switches.any((e) => e.fromKey == 'B' && e.toKey == 'A'), true);
  logPass('Switched from B back to A');
    });
  });
}
