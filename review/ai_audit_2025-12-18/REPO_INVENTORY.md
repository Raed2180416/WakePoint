# REPO_INVENTORY (Android scope)

- `lib/main.dart` – app entry; registers lifecycle observer, routes to Splash/Home/MapTracking.
- `lib/screens/splash_screen.dart` – startup init (ApiClient, NotificationService, TrackingService), restore/zombie alarm cleanup.
- `lib/screens/homescreen.dart` – destination search, start tracking, connectivity/battery monitoring, offline coordinator wiring.
- `lib/screens/maptracking.dart` – live tracking UI, restore from snapshot, listens to TrackingService streams.
- `lib/services/trackingservice.dart` – foreground↔background bridge, alarm logic, GPS ingest, route management, ack reliability.
- `lib/services/notification_service.dart` – notifications, alarm audio/vibration, notification action handling, file-flag requests.
- `lib/services/tracking_state_store.dart` – SharedPreferences-backed tracking state/snapshot/progress.
- Routing stack: `direction_service.dart`, `route_cache.dart`, `offline_coordinator.dart`, `active_route_manager.dart`, `route_registry.dart`, `deviation_monitor.dart`, `snap_to_route.dart`, `reroute_policy.dart`, `eta_engine.dart`.
- Other services: `permission_service.dart`, `navigation_service.dart`, `alarm_player.dart`, `alarm_haptics.dart`, `sensor_fusion.dart`, `simulation_client.dart`, etc.
- Platform: `android/` (foreground service declaration, permissions). Non-Android platforms ignored per scope.
- Tests: `test/` and `integration_test/` exist but baseline execution blocked due to missing Flutter toolchain in runner.
- Existing review artifacts: `review/` (legacy docs); new audit under `review/ai_audit_2025-12-18/`.
