import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/offline_coordinator.dart';
import 'package:geowake2/services/route_cache.dart';
import 'log_helper.dart';

class FakeDirectionsProvider implements DirectionsProvider {
  int calls = 0;
  Map<String, dynamic> payload;
  FakeDirectionsProvider(this.payload);
  @override
  Future<Map<String, dynamic>> getDirections(double a, double b, double c, double d,
      {required bool isDistanceMode,
      required double threshold,
      required bool transitMode,
      bool forceRefresh = false}) async {
    calls++;
    return payload;
  }
}

class FakeCachePort implements RouteCachePort {
  RouteCacheEntry? entry;
  @override
  Future<RouteCacheEntry?> get({required LatLng origin, required LatLng destination, required String mode, String? transitVariant}) async {
    return entry;
  }
}

void main() {
  group('OfflineCoordinator', () {
    final origin = const LatLng(10.0, 10.0);
    final dest = const LatLng(11.0, 11.0);
    final okDirections = {
      'status': 'OK',
      'routes': [
        {
          'overview_polyline': {'points': '}_se}Ff`miO??'},
          'legs': [
            {
              'steps': [],
              'duration': {'value': 600}
            }
          ]
        }
      ]
    };

    test('Online uses network provider and emits network source', () async {
      logSection('OfflineCoordinator: online fetch path');
      final fakeProvider = FakeDirectionsProvider(okDirections);
      final fakeCache = FakeCachePort();
      final oc = OfflineCoordinator(
        directionsProvider: fakeProvider,
        cache: fakeCache,
        initialOffline: false,
      );
      final res = await oc.getRoute(
        origin: origin,
        destination: dest,
        isDistanceMode: true,
        threshold: 1.0,
        transitMode: false,
      );
      expect(fakeProvider.calls, 1);
      expect(res.source, RouteSource.network);
      expect(res.directions['status'], 'OK');
      logPass('Fetched via network and returned OK');
    });

    test('Offline returns cached when available and never calls network', () async {
      logSection('OfflineCoordinator: offline uses cache');
      final fakeProvider = FakeDirectionsProvider(okDirections);
      final fakeCache = FakeCachePort();
      fakeCache.entry = RouteCacheEntry(
        key: 'k',
        directions: okDirections,
        timestamp: DateTime.now(),
        origin: origin,
        destination: dest,
        mode: 'driving',
      );
      final oc = OfflineCoordinator(
        directionsProvider: fakeProvider,
        cache: fakeCache,
        initialOffline: true,
      );
      final res = await oc.getRoute(
        origin: origin,
        destination: dest,
        isDistanceMode: true,
        threshold: 1.0,
        transitMode: false,
      );
      expect(fakeProvider.calls, 0);
      expect(res.source, RouteSource.cache);
      logPass('Served from cache without network');
    });

    test('Offline without cache throws', () async {
      logSection('OfflineCoordinator: offline no cache -> error');
      final oc = OfflineCoordinator(
        directionsProvider: FakeDirectionsProvider(okDirections),
        cache: FakeCachePort(),
        initialOffline: true,
      );
      expect(
        () => oc.getRoute(
          origin: origin,
          destination: dest,
          isDistanceMode: false,
          threshold: 1.0,
          transitMode: false,
        ),
        throwsA(isA<StateError>()),
      );
      logPass('Threw as expected due to no cache while offline');
    });
  });
}
