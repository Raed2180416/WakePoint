import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/offline_coordinator.dart';
import 'package:geowake2/services/route_cache.dart';

// #23 Offline route pinning.
//
// RouteCache.get() used to be a DESTRUCTIVE read: a route older than the 5-min
// TTL was DELETED on read, so an offline reroute/restore after 5 min was
// impossible (the read itself evicted the last-good route). The fix adds an
// active-route PIN: get(pinned: true) bypasses the TTL / schema / planned-window
// staleness guards AND never deletes. These tests fast-forward past the TTL by
// injecting an old stored timestamp (no wall-clock wait, fully deterministic).

const _origin = LatLng(12.9716, 77.5946); // Bangalore-ish
const _dest = LatLng(13.0359, 77.5970);
const _mode = 'driving';

/// Seed the real Hive-backed cache with an entry whose stored timestamp is
/// [minutesAgo] in the past (so unpinned reads see it as TTL-stale).
Future<void> _seedAged({
  int minutesAgo = 10,
  int schemaVersion = RouteCache.schemaVersion,
}) async {
  final key = RouteCache.makeKey(
    origin: _origin,
    destination: _dest,
    mode: _mode,
  );
  await RouteCache.put(
    RouteCacheEntry(
      key: key,
      directions: {
        'status': 'OK',
        'routes': [
          {'summary': 'pinned-route'},
        ],
      },
      timestamp: DateTime.now().subtract(Duration(minutes: minutesAgo)),
      origin: _origin,
      destination: _dest,
      mode: _mode,
      schemaVersion: schemaVersion,
    ),
  );
}

Future<RouteCacheEntry?> _get({required bool pinned}) => RouteCache.get(
      origin: _origin,
      destination: _dest,
      mode: _mode,
      pinned: pinned,
    );

class _ThrowingProvider implements DirectionsProvider {
  int calls = 0;
  @override
  Future<Map<String, dynamic>> getDirections(
    double a,
    double b,
    double c,
    double d, {
    required bool isDistanceMode,
    required double threshold,
    required bool transitMode,
    bool preferMetroEvenIfClosed = false,
    bool forceRefresh = false,
  }) async {
    calls++;
    throw StateError('network must not be hit while offline');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // RouteCache._box is a static Hive box that persists across a file run; the
  // global test config (test/flutter_test_config.dart) has already Hive.init'd a
  // temp dir. Isolate every test.
  setUp(() async {
    await RouteCache.clear();
  });

  group('RouteCache TTL: unpinned vs pinned', () {
    test('unpinned get past TTL evicts destructively (miss, then gone)',
        () async {
      await _seedAged(minutesAgo: 10);

      // Unpinned read past the 5-min TTL -> miss.
      expect(await _get(pinned: false), isNull);

      // The unpinned read DELETED the entry: even a pinned read now misses,
      // proving the read was destructive.
      expect(await _get(pinned: true), isNull);
    });

    test('pinned get past TTL returns the route and is non-destructive',
        () async {
      await _seedAged(minutesAgo: 10);

      // Pinned read ignores the TTL and returns the last-good route.
      final first = await _get(pinned: true);
      expect(first, isNotNull);
      expect(
        (first!.directions['routes'] as List).first['summary'],
        'pinned-route',
      );

      // Still there on a second pinned read (never deleted).
      final second = await _get(pinned: true);
      expect(second, isNotNull);

      // An unpinned read still enforces + evicts the TTL (normal path intact).
      expect(await _get(pinned: false), isNull);
    });

    test('pinned get bypasses schema-version staleness non-destructively',
        () async {
      // Fresh timestamp but a legacy schemaVersion (0 != current) => unpinned is
      // stale-by-schema. Pinned must still return it.
      await _seedAged(minutesAgo: 0, schemaVersion: 0);
      final pinnedHit = await _get(pinned: true);
      expect(pinnedHit, isNotNull);
      expect(pinnedHit!.schemaVersion, 0);

      // Re-seed (previous line's pinned read left it in place; re-seed to be
      // explicit) and confirm the unpinned path still evicts a schema-stale row.
      await _seedAged(minutesAgo: 0, schemaVersion: 0);
      expect(await _get(pinned: false), isNull);
    });
  });

  group('OfflineCoordinator pins the active-route read (#23)', () {
    test('offline getRoute returns a >5min-old cached route without throwing',
        () async {
      await _seedAged(minutesAgo: 6);

      final provider = _ThrowingProvider();
      final oc = OfflineCoordinator(
        directionsProvider: provider,
        initialOffline: true,
      );
      addTearDown(oc.dispose);

      final res = await oc.getRoute(
        origin: _origin,
        destination: _dest,
        isDistanceMode: true,
        threshold: 1.0,
        transitMode: false,
      );
      expect(res.source, RouteSource.cache);
      expect(provider.calls, 0);

      // Non-destructive: a second offline read still hits the pinned route,
      // proving the first read did not evict it.
      final res2 = await oc.getRoute(
        origin: _origin,
        destination: _dest,
        isDistanceMode: true,
        threshold: 1.0,
        transitMode: false,
      );
      expect(res2.source, RouteSource.cache);
    });
  });
}
