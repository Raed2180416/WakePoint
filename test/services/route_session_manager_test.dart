// Regression test: RouteSessionManager's per-route-key auxiliary maps
// (routeEventsByKey, stepBoundsMetersByKey, stepStopsCumulativeByKey,
// stepDurationsSecondsByKey, firstTransitBoardingByKey, transitModeByKey,
// transitLegStopsByKey, and the internal route-payload cache) must be
// evicted in lockstep with RouteRegistry's own capacity-bounded LRU —
// otherwise a long session with many reroutes/alternates leaves orphaned
// entries in every auxiliary map for keys the registry itself has already
// dropped.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/services/route_session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RouteSessionManager mgr() => RouteSessionManager(isTestMode: true);

  /// Registers a fully-populated route under [key] and seeds EVERY
  /// auxiliary map for it — including the ones registerRoute() itself
  /// doesn't touch (stepBoundsMetersByKey etc., normally populated by
  /// registerRouteFromDirections) — so the prune logic is exercised against
  /// all eight maps, not just the ones the public API path happens to fill.
  void registerFullyPopulated(RouteSessionManager m, String key) {
    m.stepBoundsMetersByKey[key] = [100.0, 200.0];
    m.stepStopsCumulativeByKey[key] = [50.0];
    m.stepDurationsSecondsByKey[key] = [60, 120];
    m.firstTransitBoardingByKey[key] = const LatLng(12.9, 77.6);
    m.transitModeByKey[key] = false;

    m.registerRoute(
      key: key,
      mode: 'driving',
      destinationName: key,
      points: const [LatLng(12.90, 77.60), LatLng(12.91, 77.61)],
      events: const [
        {'meters': 100.0, 'type': 'destination', 'label': 'Destination'},
      ],
      transitLegsJson: const [],
    );
  }

  test(
      'registering more routes than RouteRegistry.capacity evicts the '
      'oldest key from every auxiliary map, not just the registry',
      () {
    final m = mgr();
    expect(m.registry.capacity, 8,
        reason: 'this test assumes the default capacity; update the loop '
            'bound below if RouteRegistry\'s default ever changes');

    // Register capacity+1 distinct routes, one at a time, each strictly
    // more recently used than the last.
    for (var i = 0; i < m.registry.capacity + 1; i++) {
      registerFullyPopulated(m, 'route_$i');
    }

    final liveKeys = m.registry.entries.map((e) => e.key).toSet();
    expect(liveKeys.length, m.registry.capacity);
    expect(liveKeys.contains('route_0'), isFalse,
        reason: 'route_0 is the least-recently-used and must be evicted '
            'from the registry');

    // Every auxiliary map must mirror the registry's live key set exactly —
    // no orphaned entry for the evicted 'route_0', and nothing evicted that
    // is still live in the registry.
    void assertMirrorsRegistry(Map<String, dynamic> auxMap, String name) {
      expect(auxMap.keys.toSet(), liveKeys,
          reason: '$name must be evicted in lockstep with RouteRegistry');
    }

    assertMirrorsRegistry(m.stepBoundsMetersByKey, 'stepBoundsMetersByKey');
    assertMirrorsRegistry(
        m.stepStopsCumulativeByKey, 'stepStopsCumulativeByKey');
    assertMirrorsRegistry(
        m.stepDurationsSecondsByKey, 'stepDurationsSecondsByKey');
    assertMirrorsRegistry(
        m.firstTransitBoardingByKey, 'firstTransitBoardingByKey');
    assertMirrorsRegistry(m.transitModeByKey, 'transitModeByKey');
    assertMirrorsRegistry(m.transitLegStopsByKey, 'transitLegStopsByKey');
    assertMirrorsRegistry(m.routeEventsByKey, 'routeEventsByKey');
  });

  test(
      'registering fewer routes than capacity never evicts anything (no '
      'accidental over-pruning)', () {
    final m = mgr();
    for (var i = 0; i < 4; i++) {
      registerFullyPopulated(m, 'route_$i');
    }

    final liveKeys = m.registry.entries.map((e) => e.key).toSet();
    expect(liveKeys.length, 4);
    expect(m.stepBoundsMetersByKey.keys.toSet(), liveKeys);
    expect(m.routeEventsByKey.keys.toSet(), liveKeys);
    expect(m.transitLegStopsByKey.keys.toSet(), liveKeys);
  });

  test('re-registering an EXISTING key (no growth) never triggers eviction',
      () {
    final m = mgr();
    for (var i = 0; i < m.registry.capacity; i++) {
      registerFullyPopulated(m, 'route_$i');
    }
    // Re-register an already-known key — RouteRegistry.upsert() replaces in
    // place rather than growing, so nothing should be evicted.
    registerFullyPopulated(m, 'route_0');

    final liveKeys = m.registry.entries.map((e) => e.key).toSet();
    expect(liveKeys.length, m.registry.capacity);
    expect(m.stepBoundsMetersByKey.keys.toSet(), liveKeys);
  });

  test('clearSession() still wipes every auxiliary map completely', () {
    final m = mgr();
    for (var i = 0; i < 3; i++) {
      registerFullyPopulated(m, 'route_$i');
    }
    m.clearSession();

    expect(m.registry.entries, isEmpty);
    expect(m.stepBoundsMetersByKey, isEmpty);
    expect(m.stepStopsCumulativeByKey, isEmpty);
    expect(m.stepDurationsSecondsByKey, isEmpty);
    expect(m.firstTransitBoardingByKey, isEmpty);
    expect(m.transitModeByKey, isEmpty);
    expect(m.transitLegStopsByKey, isEmpty);
    expect(m.routeEventsByKey, isEmpty);
  });
}
