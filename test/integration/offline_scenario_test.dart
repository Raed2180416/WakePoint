// Integration / end-to-end scenarios for offline / degraded-network reliability.
//
// Unlike the unit tests in test/offline_coordinator_test.dart and
// test/offline_routing_guard_test.dart (which inject *fake* RouteCachePorts),
// these tests drive the REAL Hive-backed RouteCache through the coordinator's
// default DefaultRouteCachePort, and exercise the offlineStream/isOffline
// connectivity surface that the unit tests never touch.
//
// Headless setup: Hive is initialized/torn down by test/flutter_test_config.dart
// (which applies to this subdirectory too). RouteCache is a pure-Dart + Hive
// seam with no platform channels; Geolocator.distanceBetween (used by the cache
// origin-deviation guard) is a pure computation, so the whole cache path runs
// headlessly. The live-network branch is never taken: offline reads only from
// cache, and the online branch is fed by an in-memory fake DirectionsProvider.
//
// Cardinal-sin coverage for a wake alarm: offline must never silently fabricate
// a route (it throws instead), must not crash or lose connectivity state across
// a trip that flaps between offline/online, and must never call the network on
// the offline path.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/offline_coordinator.dart';
import 'package:geowake2/services/route_cache.dart';

/// A directions provider that fails loudly if the offline path ever reaches the
/// network. Throws [UnsupportedError] (NOT StateError) so that an accidental
/// network call is never mistaken for the offline guard's own StateError.
class _ThrowingProvider implements DirectionsProvider {
  int calls = 0;
  @override
  Future<Map<String, dynamic>> getDirections(
    double startLat,
    double startLng,
    double endLat,
    double endLng, {
    required bool isDistanceMode,
    required double threshold,
    required bool transitMode,
    bool preferMetroEvenIfClosed = false,
    bool forceRefresh = false,
  }) async {
    calls++;
    throw UnsupportedError('offline path must not hit the network');
  }
}

/// A network stand-in for the ONLINE legs of a trip: returns a canned payload
/// without touching real HTTP. It does NOT write to RouteCache (only the real
/// DirectionService does), so offline legs must rely on pre-seeded cache.
class _FakeNetworkProvider implements DirectionsProvider {
  int calls = 0;
  final Map<String, dynamic> payload;
  _FakeNetworkProvider(this.payload);
  @override
  Future<Map<String, dynamic>> getDirections(
    double startLat,
    double startLng,
    double endLat,
    double endLng, {
    required bool isDistanceMode,
    required double threshold,
    required bool transitMode,
    bool preferMetroEvenIfClosed = false,
    bool forceRefresh = false,
  }) async {
    calls++;
    return payload;
  }
}

Map<String, dynamic> _okDirections() => {
  'status': 'OK',
  'routes': [
    {
      'overview_polyline': {'points': '}_se}Ff`miO??'},
      'legs': [
        {
          'steps': [],
          'duration': {'value': 600},
        },
      ],
    },
  ],
};

/// Seed the REAL Hive-backed RouteCache the way production
/// DirectionService.getDirections does: key via RouteCache.makeKey and
/// schemaVersion == RouteCache.schemaVersion. Both are required for a real hit
/// (the entry default schemaVersion of 0 is treated as stale on read).
Future<void> _seedRealCache({
  required LatLng origin,
  required LatLng destination,
  required String mode,
  String? transitVariant,
  required Map<String, dynamic> directions,
  DateTime? timestamp,
}) async {
  final key = RouteCache.makeKey(
    origin: origin,
    destination: destination,
    mode: mode,
    transitVariant: transitVariant,
  );
  await RouteCache.put(
    RouteCacheEntry(
      key: key,
      directions: directions,
      timestamp: timestamp ?? DateTime.now(),
      origin: origin,
      destination: destination,
      mode: mode,
      schemaVersion: RouteCache.schemaVersion,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Keep the real cache isolated between tests (RouteCache._box is static and
  // persists within a test file run).
  setUp(() async {
    await RouteCache.clear();
  });

  final origin = const LatLng(12.9716, 77.5946); // Bangalore-ish
  final dest = const LatLng(13.0359, 77.5970);

  group('(1) connectivity stream: offline<->online events and isOffline', () {
    test(
      'setOffline emits on real change, dedups repeats, and flips isOffline',
      () async {
        final oc = OfflineCoordinator(
          directionsProvider: _ThrowingProvider(),
          initialOffline: false,
        );
        addTearDown(oc.dispose);

        // Broadcast stream: subscribe BEFORE mutating so no events are lost.
        final events = <bool>[];
        final sub = oc.offlineStream.listen(events.add);

        expect(oc.isOffline, isFalse, reason: 'fresh coordinator is online');

        oc.setOffline(true); // false -> true : emit
        oc.setOffline(true); // no change     : dedup (no emit)
        oc.setOffline(false); // true -> false : emit
        oc.setOffline(false); // no change     : dedup (no emit)
        oc.setOffline(true); // false -> true : emit

        await pumpEventQueue();
        await sub.cancel();

        expect(
          events,
          equals(<bool>[true, false, true]),
          reason:
              'stream must emit exactly one event per real transition and '
              'suppress no-op repeats',
        );
        expect(oc.isOffline, isTrue, reason: 'isOffline reflects last value');
      },
    );

    test('offlineStream is broadcast: supports multiple listeners', () async {
      final oc = OfflineCoordinator(
        directionsProvider: _ThrowingProvider(),
        initialOffline: false,
      );
      addTearDown(oc.dispose);

      final a = <bool>[];
      final b = <bool>[];
      final subA = oc.offlineStream.listen(a.add);
      final subB = oc.offlineStream.listen(b.add);

      oc.setOffline(true);
      oc.setOffline(false);

      await pumpEventQueue();
      await subA.cancel();
      await subB.cancel();

      expect(a, equals(<bool>[true, false]));
      expect(b, equals(<bool>[true, false]),
          reason: 'a second listener (e.g. TrackingService + HomeScreen) must '
              'receive the same connectivity events');
    });
  });

  group('(2) route cache: hit returns route, miss is handled without throwing',
      () {
    test(
      'offline hit flows through REAL RouteCache -> DefaultRouteCachePort '
      'and never calls network (driving)',
      () async {
        await _seedRealCache(
          origin: origin,
          destination: dest,
          mode: 'driving',
          directions: _okDirections(),
        );

        final provider = _ThrowingProvider();
        // No cache injected -> coordinator uses the real DefaultRouteCachePort.
        final oc = OfflineCoordinator(
          directionsProvider: provider,
          initialOffline: true,
        );
        addTearDown(oc.dispose);

        final res = await oc.getRoute(
          origin: origin,
          destination: dest,
          isDistanceMode: true,
          threshold: 1.0,
          transitMode: false,
        );

        expect(res.source, RouteSource.cache);
        expect(res.directions['status'], 'OK');
        expect(provider.calls, 0,
            reason: 'offline must be served purely from cache');
      },
    );

    test(
      'offline hit through REAL RouteCache respects transit variant keying',
      () async {
        await _seedRealCache(
          origin: origin,
          destination: dest,
          mode: 'transit',
          transitVariant: 'rail',
          directions: _okDirections(),
        );

        final provider = _ThrowingProvider();
        final oc = OfflineCoordinator(
          directionsProvider: provider,
          initialOffline: true,
        );
        addTearDown(oc.dispose);

        final res = await oc.getRoute(
          origin: origin,
          destination: dest,
          isDistanceMode: false,
          threshold: 500.0,
          transitMode: true, // -> mode 'transit', variant 'rail'
        );

        expect(res.source, RouteSource.cache);
        expect(res.directions['status'], 'OK');
        expect(provider.calls, 0);
      },
    );

    test('REAL RouteCache.get returns null on a miss without throwing',
        () async {
      // Nothing seeded for this origin/destination.
      final miss = await RouteCache.get(
        origin: const LatLng(1.0, 1.0),
        destination: const LatLng(2.0, 2.0),
        mode: 'driving',
      );
      expect(miss, isNull);
    });

    test(
      'offline + real-cache MISS throws StateError (never fabricates a route)',
      () async {
        final provider = _ThrowingProvider();
        final oc = OfflineCoordinator(
          directionsProvider: provider,
          initialOffline: true,
        );
        addTearDown(oc.dispose);

        // Distinct StateError from the offline guard; a stray network call would
        // instead surface as UnsupportedError, so throwsStateError is precise.
        await expectLater(
          oc.getRoute(
            origin: const LatLng(40.0, -74.0),
            destination: const LatLng(41.0, -73.0),
            isDistanceMode: true,
            threshold: 1.0,
            transitMode: false,
          ),
          throwsStateError,
        );
        expect(provider.calls, 0,
            reason: 'offline guard must short-circuit before the network');
      },
    );

    test(
      'transit variant is NOT served from a driving-mode cache entry '
      '(no wrong-mode route)',
      () async {
        // Seed only a DRIVING entry for this pair.
        await _seedRealCache(
          origin: origin,
          destination: dest,
          mode: 'driving',
          directions: _okDirections(),
        );

        final oc = OfflineCoordinator(
          directionsProvider: _ThrowingProvider(),
          initialOffline: true,
        );
        addTearDown(oc.dispose);

        // A transit request keys on mode 'transit'/variant 'rail' -> miss ->
        // must throw rather than serve the driving route.
        await expectLater(
          oc.getRoute(
            origin: origin,
            destination: dest,
            isDistanceMode: false,
            threshold: 500.0,
            transitMode: true,
          ),
          throwsStateError,
        );
      },
    );
  });

  group('(3) offline during a trip: no crash, no lost state', () {
    test(
      'a trip that flaps online->offline->online serves the right source '
      'each leg and preserves connectivity state',
      () async {
        // Pre-seed the cache so the offline leg has a route to serve. (The fake
        // network provider does not populate RouteCache; only the real
        // DirectionService does in production.)
        await _seedRealCache(
          origin: origin,
          destination: dest,
          mode: 'driving',
          directions: _okDirections(),
        );

        final provider = _FakeNetworkProvider(_okDirections());
        final oc = OfflineCoordinator(
          directionsProvider: provider,
          initialOffline: false,
        );
        addTearDown(oc.dispose);

        final events = <bool>[];
        final sub = oc.offlineStream.listen(events.add);

        // Leg 1: online -> network.
        final r1 = await oc.getRoute(
          origin: origin,
          destination: dest,
          isDistanceMode: true,
          threshold: 1.0,
          transitMode: false,
        );
        expect(r1.source, RouteSource.network);

        // Signal loss mid-trip.
        oc.setOffline(true);
        expect(oc.isOffline, isTrue);

        // Leg 2: offline -> served from real cache, network untouched.
        final networkCallsBeforeOffline = provider.calls;
        final r2 = await oc.getRoute(
          origin: origin,
          destination: dest,
          isDistanceMode: true,
          threshold: 1.0,
          transitMode: false,
        );
        expect(r2.source, RouteSource.cache);
        expect(provider.calls, networkCallsBeforeOffline,
            reason: 'no network calls while offline');

        // Signal recovery.
        oc.setOffline(false);
        expect(oc.isOffline, isFalse);

        // Leg 3: back online -> network again.
        final r3 = await oc.getRoute(
          origin: origin,
          destination: dest,
          isDistanceMode: true,
          threshold: 1.0,
          transitMode: false,
        );
        expect(r3.source, RouteSource.network);

        await pumpEventQueue();
        await sub.cancel();

        // State was never lost or corrupted across the flap.
        expect(events, equals(<bool>[true, false]));
        expect(oc.isOffline, isFalse);
      },
    );

    test(
      'rapid connectivity flapping during a trip does not crash and keeps '
      'isOffline consistent with the last transition',
      () async {
        await _seedRealCache(
          origin: origin,
          destination: dest,
          mode: 'driving',
          directions: _okDirections(),
        );

        final oc = OfflineCoordinator(
          directionsProvider: _FakeNetworkProvider(_okDirections()),
          initialOffline: false,
        );
        addTearDown(oc.dispose);

        final events = <bool>[];
        final sub = oc.offlineStream.listen(events.add);

        // Interleave route fetches with rapid connectivity toggles.
        for (var i = 0; i < 5; i++) {
          oc.setOffline(true);
          final offRes = await oc.getRoute(
            origin: origin,
            destination: dest,
            isDistanceMode: true,
            threshold: 1.0,
            transitMode: false,
          );
          expect(offRes.source, RouteSource.cache);

          oc.setOffline(false);
          final onRes = await oc.getRoute(
            origin: origin,
            destination: dest,
            isDistanceMode: true,
            threshold: 1.0,
            transitMode: false,
          );
          expect(onRes.source, RouteSource.network);
        }

        await pumpEventQueue();
        await sub.cancel();

        // 5 real true->false round trips == 10 emitted transitions, alternating.
        expect(events.length, 10);
        expect(events.first, isTrue);
        expect(events.last, isFalse);
        expect(oc.isOffline, isFalse);
      },
    );
  });

  group('#23 offline active-route pin: cached route survives past TTL', () {
    // The offline branch reads the cache via DefaultRouteCachePort.get(), which
    // now PINS the active-route read (RouteCache.get called with pinned:true).
    // A cached route older than the 5-minute TTL is returned non-destructively,
    // so an offline trip that outlasts the TTL is still served its own route
    // instead of throwing. This makes offline reroute/restore after 5 min work.
    test(
      'a >5min-old cached route is returned (not evicted) on the offline read',
      () async {
        await _seedRealCache(
          origin: origin,
          destination: dest,
          mode: 'driving',
          directions: _okDirections(),
          timestamp: DateTime.now().subtract(const Duration(minutes: 6)),
        );

        final provider = _ThrowingProvider();
        final oc = OfflineCoordinator(
          directionsProvider: provider,
          initialOffline: true,
        );
        addTearDown(oc.dispose);

        final res = await oc.getRoute(
          origin: origin,
          destination: dest,
          isDistanceMode: true,
          threshold: 1.0,
          transitMode: false,
        );
        expect(res.source, RouteSource.cache);
        expect(provider.calls, 0);

        // Non-destructive: a second offline read still returns the pinned route.
        final res2 = await oc.getRoute(
          origin: origin,
          destination: dest,
          isDistanceMode: true,
          threshold: 1.0,
          transitMode: false,
        );
        expect(res2.source, RouteSource.cache);
      },
    );
  });

  group('singleton default state (shared coordinator)', () {
    test('a fresh singleton defaults to ONLINE (does not block network)',
        () async {
      OfflineCoordinator.resetInstance();
      final inst = OfflineCoordinator.instance;
      expect(inst.isOffline, isFalse,
          reason:
              'the shared coordinator must start online so a healthy network '
              'is not wrongly treated as offline at app start');
      OfflineCoordinator.resetInstance();
    });
  });
}
