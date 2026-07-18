import 'dart:async';
import 'package:flutter/foundation.dart';
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
    bool preferMetroEvenIfClosed,
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
    bool preferMetroEvenIfClosed = false,
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
      preferMetroEvenIfClosed: preferMetroEvenIfClosed,
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
    int? departureTime,
    // #23 active-route pin: when true the read bypasses TTL/schema/planned-window
    // staleness and is non-destructive (used by the offline restore/reroute path).
    bool pinned,
  });
}

class DefaultRouteCachePort implements RouteCachePort {
  @override
  Future<RouteCacheEntry?> get({
    required LatLng origin,
    required LatLng destination,
    required String mode,
    String? transitVariant,
    int? departureTime,
    bool pinned = false,
  }) {
    return RouteCache.get(
      origin: origin,
      destination: destination,
      mode: mode,
      transitVariant: transitVariant,
      departureTime: departureTime,
      pinned: pinned,
    );
  }
}

/// Coordinates offline/online behavior for directions fetching and exposure of state.
class OfflineCoordinator {
  /// Singleton instance for shared access across HomeScreen and TrackingService.
  /// This ensures reroute logic has access to the same coordinator that handles
  /// connectivity changes.
  static OfflineCoordinator? _instance;

  /// Returns the singleton instance, creating it if necessary.
  /// The singleton starts in online mode by default.
  static OfflineCoordinator get instance {
    _instance ??= OfflineCoordinator._internal(initialOffline: false);
    return _instance!;
  }

  /// Allows tests to inject a custom instance.
  @visibleForTesting
  static void setInstance(OfflineCoordinator? coordinator) {
    _instance = coordinator;
  }

  /// Resets the singleton (for testing).
  @visibleForTesting
  static void resetInstance() {
    _instance?.dispose();
    _instance = null;
  }

  final DirectionsProvider _directionsProvider;
  final RouteCachePort _cache;

  bool _isOffline;
  final _offlineCtrl = StreamController<bool>.broadcast();

  /// Named constructor for internal singleton creation.
  OfflineCoordinator._internal({
    DirectionsProvider? directionsProvider,
    RouteCachePort? cache,
    bool initialOffline = false,
  }) : _directionsProvider = directionsProvider ?? DefaultDirectionsProvider(),
       _cache = cache ?? DefaultRouteCachePort(),
       _isOffline = initialOffline;

  /// Public constructor for testing or explicit instantiation.
  /// Prefer using [OfflineCoordinator.instance] for production code.
  OfflineCoordinator({
    DirectionsProvider? directionsProvider,
    RouteCachePort? cache,
    bool initialOffline = false,
  }) : _directionsProvider = directionsProvider ?? DefaultDirectionsProvider(),
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
    bool preferMetroEvenIfClosed = false,
    bool forceRefresh = false,
  }) async {
    final mode = transitMode ? 'transit' : 'driving';
    final variant = transitMode ? 'rail' : null;

    if (_isOffline) {
      // #23: pin the active-route read so a route cached before we went offline
      // survives past its TTL and is returned non-destructively — offline
      // reroute/restore after 5 min must not be impossible.
      final cached = await _cache.get(
        origin: origin,
        destination: destination,
        mode: mode,
        transitVariant: variant,
        pinned: true,
      );
      if (cached == null) {
        throw StateError('Offline and no cached route available');
      }
      return OfflineRouteResult(
        directions: cached.directions,
        source: RouteSource.cache,
      );
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
      preferMetroEvenIfClosed: preferMetroEvenIfClosed,
      forceRefresh: forceRefresh,
    );
    return OfflineRouteResult(
      directions: directions,
      source: RouteSource.network,
    );
  }

  void dispose() {
    _offlineCtrl.close();
  }
}
