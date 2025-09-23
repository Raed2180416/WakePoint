import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/api_client.dart';
import 'package:geowake2/services/direction_service.dart';
import 'package:geowake2/services/route_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ApiClient.testMode = true;
    ApiClient.directionsCallCount = 0;
    ApiClient.lastDirectionsBody = null;
    await RouteCache.clear();
  });

  test('Respects forceRefresh vs cached path (call count)', () async {
    final ds = DirectionService();
    // First call fetches
    await ds.getDirections(12, 77, 12.5, 77.5, isDistanceMode: true, threshold: 5, transitMode: false);
    expect(ApiClient.directionsCallCount, 1);
    // Second call reuses cache (no additional fetch)
    await ds.getDirections(12, 77, 12.5, 77.5, isDistanceMode: true, threshold: 5, transitMode: false);
    expect(ApiClient.directionsCallCount, 1);
    // Force refresh triggers fetch
    await ds.getDirections(12, 77, 12.5, 77.5, isDistanceMode: true, threshold: 5, transitMode: false, forceRefresh: true);
    expect(ApiClient.directionsCallCount, 2);
  });

  test('Transit variant included in request and cache key', () async {
  await DirectionService().getDirections(12, 77, 12.5, 77.5, isDistanceMode: false, threshold: 1, transitMode: true);
    expect(ApiClient.lastDirectionsBody?['mode'], 'transit');
    expect(ApiClient.lastDirectionsBody?['transit_mode'], 'rail');
  });

  test('Cache TTL expiration invalidates entry', () async {
    final origin = LatLng(12, 77);
    final dest = LatLng(12.5, 77.5);
    final key = RouteCache.makeKey(origin: origin, destination: dest, mode: 'driving');

    // Seed cache with old timestamp
    await RouteCache.put(RouteCacheEntry(
      key: key,
      directions: {
        'status': 'OK',
        'routes': [
          {'overview_polyline': {'points': '}_se}Ff`miO??'}}
        ]
      },
      timestamp: DateTime.now().subtract(const Duration(minutes: 30)),
      origin: origin,
      destination: dest,
      mode: 'driving',
      simplifiedCompressedPolyline: 'abc',
    ));

    final entry = await RouteCache.get(origin: origin, destination: dest, mode: 'driving', ttl: const Duration(minutes: 5));
    expect(entry, isNull); // expired
  });

  test('Origin deviation invalidates entry', () async {
    final origin = LatLng(12, 77);
    final dest = LatLng(12.5, 77.5);
    final key = RouteCache.makeKey(origin: origin, destination: dest, mode: 'driving');
    await RouteCache.put(RouteCacheEntry(
      key: key,
      directions: {
        'status': 'OK',
        'routes': [
          {'overview_polyline': {'points': '}_se}Ff`miO??'}}
        ]
      },
      timestamp: DateTime.now(),
      origin: origin,
      destination: dest,
      mode: 'driving',
      simplifiedCompressedPolyline: 'abc',
    ));

    final movedOrigin = LatLng(12.01, 77.01); // ~1.5km
    final entry = await RouteCache.get(
      origin: movedOrigin,
      destination: dest,
      mode: 'driving',
      originDeviationMeters: 300,
    );
    expect(entry, isNull);
  });
}
