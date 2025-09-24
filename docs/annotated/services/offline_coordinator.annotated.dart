// Annotated copy of lib/services/offline_coordinator.dart
// Purpose: Explain offline/online coordination for directions and cache usage.

import 'dart:async'; // StreamController for offline state broadcasting
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng for origin/destination
import 'package:geowake2/services/direction_service.dart'; // Concrete provider (used by default wrapper)
import 'package:geowake2/services/route_cache.dart'; // Persistent cache API

// Source of the route returned by OfflineCoordinator
enum RouteSource { cache, network }

// Wrapper carrying the directions payload and its source
class OfflineRouteResult {
  final Map<String, dynamic> directions; // Google Directions-like JSON map
  final RouteSource source;               // cache or network
  OfflineRouteResult({required this.directions, required this.source});
}

// Abstraction for fetching directions (default: DirectionService)
abstract class DirectionsProvider {
  Future<Map<String, dynamic>> getDirections(
    double startLat,
    double startLng,
    double endLat,
    double endLng, {
    required bool isDistanceMode, // distance vs time mode for thresholds
    required double threshold,    // server-side threshold param
    required bool transitMode,    // whether to request transit
    bool forceRefresh,            // bypass local cache when true
  });
}

// Default provider delegating to DirectionService
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

// Abstraction over the persistent route cache for testability.
abstract class RouteCachePort {
  Future<RouteCacheEntry?> get({
    required LatLng origin,
    required LatLng destination,
    required String mode,          // 'driving' or 'transit'
    String? transitVariant,        // e.g., 'rail' for sub-mode
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

// Coordinates offline/online behavior for directions fetching and state exposure.
class OfflineCoordinator {
  final DirectionsProvider _directionsProvider; // Online provider
  final RouteCachePort _cache;                  // Persistent cache facade

  bool _isOffline;                              // Current offline flag
  final _offlineCtrl = StreamController<bool>.broadcast(); // Offline state stream

  OfflineCoordinator({
    DirectionsProvider? directionsProvider,
    RouteCachePort? cache,
    bool initialOffline = false, // Bootstrap value for offline state
  })  : _directionsProvider = directionsProvider ?? DefaultDirectionsProvider(),
        _cache = cache ?? DefaultRouteCachePort(),
        _isOffline = initialOffline;

  bool get isOffline => _isOffline;               // Read current offline flag
  Stream<bool> get offlineStream => _offlineCtrl.stream; // Observe changes

  // Update offline status (connectivity callbacks should call this)
  void setOffline(bool value) {
    if (_isOffline != value) {
      _isOffline = value;
      _offlineCtrl.add(_isOffline);
    }
  }

  // Fetch a route honoring offline mode; when offline, only returns cached routes.
  Future<OfflineRouteResult> getRoute({
    required LatLng origin,
    required LatLng destination,
    required bool isDistanceMode,
    required double threshold,
    required bool transitMode,
    bool forceRefresh = false,
  }) async {
    final mode = transitMode ? 'transit' : 'driving';
    final variant = transitMode ? 'rail' : null; // current transit flavor used by cache key

    if (_isOffline) {
      // Strict offline: attempt cache retrieval; error if missing
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

    // Online: delegate to provider (DirectionService implements its own memo/cache)
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
    _offlineCtrl.close(); // Clean up broadcast controller
  }
}
