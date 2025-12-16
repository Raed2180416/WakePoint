import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/offline_coordinator.dart';
import 'package:geowake2/services/route_cache.dart';

class _FakeCache implements RouteCachePort {
  _FakeCache(this.entry);
  final RouteCacheEntry? entry;
  @override
  Future<RouteCacheEntry?> get({
    required LatLng origin,
    required LatLng destination,
    required String mode,
    String? transitVariant,
  }) async {
    return entry;
  }
}

class _NeverDirections implements DirectionsProvider {
  @override
  Future<Map<String, dynamic>> getDirections(
    double startLat,
    double startLng,
    double endLat,
    double endLng, {
    required bool isDistanceMode,
    required double threshold,
    required bool transitMode,
    bool forceRefresh = false,
  }) async {
    throw StateError('Should not hit network when offline');
  }
}

RouteCacheEntry _entry(LatLng o, LatLng d) => RouteCacheEntry(
  key: 'k',
  directions: {'routes': []},
  timestamp: DateTime.now(),
  origin: o,
  destination: d,
  mode: 'driving',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final o = const LatLng(0, 0);
  final d = const LatLng(1, 1);

  test('Offline with no cache throws and never calls network', () async {
    final oc = OfflineCoordinator(
      initialOffline: true,
      cache: _FakeCache(null),
      directionsProvider: _NeverDirections(),
    );

    expect(
      () => oc.getRoute(
        origin: o,
        destination: d,
        isDistanceMode: true,
        threshold: 1.0,
        transitMode: false,
      ),
      throwsStateError,
    );
  });

  test('Offline uses cached route and reports cache source', () async {
    final cached = _entry(o, d);
    final oc = OfflineCoordinator(
      initialOffline: true,
      cache: _FakeCache(cached),
      directionsProvider: _NeverDirections(),
    );

    final res = await oc.getRoute(
      origin: o,
      destination: d,
      isDistanceMode: true,
      threshold: 1.0,
      transitMode: false,
    );

    expect(res.source, RouteSource.cache);
    expect(res.directions, cached.directions);
  });
}
