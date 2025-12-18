# SYMBOL_MAP

- `TrackingService` – lib/services/trackingservice.dart: configures flutter_background_service, ack bridge, heartbeat sender, tracking start/stop, alarm logic, background `_onStart` handlers.
- `_onStart(ServiceInstance)` – trackingservice.dart background entry; registers listeners, starts location stream, heartbeat monitor.
- `_checkAndTriggerAlarm` – trackingservice.dart: evaluates distance/time/stops alarms, triggers notifications, starts alarm stop polling.
- `NotificationService` – lib/services/notification_service.dart: notification init, alarm show/cancel, progress notifications, background action handler `notificationTapBackground`.
- `TrackingStateStore` – lib/services/tracking_state_store.dart: SharedPreferences persistence for active/paused/snapshot/progress/alarm flags.
- `DirectionService` – lib/services/direction_service.dart: API client directions, tiered refresh intervals, cache to RouteCache, simplify polylines.
- `RouteCache` – lib/services/route_cache.dart: Hive-backed caching of directions/simplified polyline.
- `ActiveRouteManager` / `RouteRegistry` – manage active route entry, progress meters, switching (lib/services/active_route_manager.dart, route_registry.dart).
- `DeviationMonitor` / `ReroutePolicy` – deviation detection and reroute cooldown logic (lib/services/deviation_monitor.dart, reroute_policy.dart).
- `OfflineCoordinator` – lib/services/offline_coordinator.dart: online/offline gating for reroute behavior.
- UI entry: `SplashScreen`, `HomeScreen`, `MapTrackingScreen` (lib/screens/*) link to tracking flows.
