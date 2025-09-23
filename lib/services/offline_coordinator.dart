import 'dart:async';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/direction_service.dart';
import 'package:geowake2/services/route_cache.dart';

/// Source of the route returned by [OfflineCoordinator]
enum RouteSource { cache, network }

class OfflineRouteResult {
  final Map<String, dynamic> directions;
  final RouteSource source;
  OfflineRouteResult({required this.directions, required this.source});
}

/// Thin abstraction for a directions provider (default: [DirectionService]).
abstract class DirectionsProvider {
  Future<Map<String, dynamic>> getDirections(
    double startLat,
    double startLng,
    double endLat,
    double endLng, {
    required bool isDistanceMode,
    required double threshold,
    required bool transitMode,
    bool forceRefresh,
  });
}

class DefaultDirectionsProvider implements DirectionsProvider {
  final DirectionService _service = DirectionService();
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
  }) {
    return _service.getDirections(
      startLat,
      startLng,
      endLat,
      endLng,
      isDistanceMode: isDistanceMode,
      threshold: threshold,
      transitMode: transitMode,
      forceRefresh: forceRefresh,
    );
  }
}

/// Abstraction over the persistent route cache for testability.
abstract class RouteCachePort {
  Future<RouteCacheEntry?> get({
    required LatLng origin,
    required LatLng destination,
    required String mode,
    String? transitVariant,
  });
}

class DefaultRouteCachePort implements RouteCachePort {
  @override
  Future<RouteCacheEntry?> get({
    required LatLng origin,
    required LatLng destination,
    required String mode,
    String? transitVariant,
  }) {
    return RouteCache.get(
      origin: origin,
      destination: destination,
      mode: mode,
      transitVariant: transitVariant,
    );
  }
}

/// Coordinates offline/online behavior for directions fetching and exposure of state.
class OfflineCoordinator {
  final DirectionsProvider _directionsProvider;
  final RouteCachePort _cache;

  bool _isOffline;
  final _offlineCtrl = StreamController<bool>.broadcast();

  OfflineCoordinator({
    DirectionsProvider? directionsProvider,
    RouteCachePort? cache,
    bool initialOffline = false,
  })  : _directionsProvider = directionsProvider ?? DefaultDirectionsProvider(),
        _cache = cache ?? DefaultRouteCachePort(),
        _isOffline = initialOffline;

  bool get isOffline => _isOffline;
  Stream<bool> get offlineStream => _offlineCtrl.stream;

  /// Update offline status (wire this to connectivity callbacks in the app layer).
  void setOffline(bool value) {
    if (_isOffline != value) {
      _isOffline = value;
      _offlineCtrl.add(_isOffline);
    }
  }

  /// Fetch a route honoring offline mode. When offline, only returns cached routes.
  Future<OfflineRouteResult> getRoute({
    required LatLng origin,
    required LatLng destination,
    required bool isDistanceMode,
    required double threshold,
    required bool transitMode,
    bool forceRefresh = false,
  }) async {
    final mode = transitMode ? 'transit' : 'driving';
    final variant = transitMode ? 'rail' : null;

    if (_isOffline) {
      final cached = await _cache.get(
        origin: origin,
        destination: destination,
        mode: mode,
        transitVariant: variant,
      );
      if (cached == null) {
        throw StateError('Offline and no cached route available');
      }
      return OfflineRouteResult(directions: cached.directions, source: RouteSource.cache);
    }

    // Online: delegate to provider (DirectionService handles its own caching)
    final directions = await _directionsProvider.getDirections(
      origin.latitude,
      origin.longitude,
      destination.latitude,
      destination.longitude,
      isDistanceMode: isDistanceMode,
      threshold: threshold,
      transitMode: transitMode,
      forceRefresh: forceRefresh,
    );
    return OfflineRouteResult(directions: directions, source: RouteSource.network);
  }

  void dispose() {
    _offlineCtrl.close();
  }
}
