# OfflineCoordinator (lib/services/offline_coordinator.dart)
Coordinates network vs cache for directions fetching with an offline-first policy.

- Types: lines 8–20 — `RouteSource` enum, `OfflineRouteResult` wrapper, `DirectionsProvider`/`DefaultDirectionsProvider` abstraction, `RouteCachePort`.
- Class: line 83 — holds provider, cache port, and offline state with broadcast stream.
- `setOffline(value)`: line 102 — toggles `_isOffline` and emits.
- `getRoute({...})`: lines 110–141 —
	- If offline: attempt `RouteCachePort.get(...)` using mode/variant; throw if missing.
	- If online: delegate to provider (`DirectionService`) which manages its own caching; returns `RouteSource.network`.
- `dispose()`: line 143 — close stream.

Used by: `TrackingService` to fetch routes respecting connectivity; tests stub provider/cache.

Tests: `offline_coordinator_test.dart`, `tracking_service_reroute_integration_test.dart`.
