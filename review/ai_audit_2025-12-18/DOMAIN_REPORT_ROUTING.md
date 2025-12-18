# DOMAIN_REPORT_ROUTING

- **Directions refresh**: `DirectionService.getDirections` uses tiered intervals (15/7/3 min) based on straight-line distance and alarm threshold; caches in-memory `_cachedDirections` and Hive `RouteCache` (direction_service.dart).
- **Polyline handling**: Decodes overview polyline, simplifies with tolerance 10, compresses, and persists simplified polyline; `_polylineSimplifyCache` keyed by hash prevents recompute.
- **Offline behavior**: HomeScreen monitors connectivity via ConnectivityPlus, toggles OfflineCoordinator and calls `TrackingService.setOnline`; background reroute gating uses OfflineCoordinator/ReroutePolicy but relies on upstream notification of connectivity (homescreen.dart, trackingservice.dart).
- **Route registry**: Background `registerRoute`/`registerRouteDirections` populate RouteRegistry and ActiveRouteManager; `_maybeBroadcastCachedRoute` resends to simulation dashboard periodically. `_onStop` clears registry to avoid stale events.
- **Deviation/reroute**: DeviationMonitor and ReroutePolicy set up during tracking (not fully reviewed due to scope/time); reroute cooldown adjustable via power policy.
- **Risk**: No guard against missing Directions when restore fails; `_restoreState` in MapTracking fetches fresh directions but background alarm logic may run before route events arrive (falling back to distance-based stops, trackingservice.dart fallback paths).
