# Tests-to-Code Traceability

Map each test to concrete functions and line ranges in services/core for fast diagnosis.

- direction_service_behavior_test.dart
  - `DirectionService.buildSegmentedPolylines` — lib/services/direction_service.dart: 140–EOF
  - `PolylineSimplifier.simplifyPolyline` — lib/services/polyline_simplifier.dart: 13–41
- direction_service_caching_test.dart
  - `RouteCache.get` — lib/services/route_cache.dart: 94–141
  - `RouteCache.makeKey` — lib/services/route_cache.dart: 77–92
  - `OfflineCoordinator.getRoute` — lib/services/offline_coordinator.dart: 110–141
- simplified_polyline_present_test.dart
  - `DirectionService.getDirections` simplify/compress branch — lib/services/direction_service.dart: 99–138
- transfer_utils_test.dart
  - `TransferUtils.buildStepBoundariesAndStops` — lib/services/transfer_utils.dart: 134–178
  - `TransferUtils.buildRouteEvents` — lib/services/transfer_utils.dart: 67–132
- eta_utils_test.dart
  - `EtaUtils.etaRemainingSeconds` — lib/services/eta_utils.dart: 1–21
- snap_to_route_test.dart
  - `SnapToRouteEngine.snap` — lib/services/snap_to_route.dart: 20–73
  - Projection — lib/services/snap_to_route.dart: 82–114
- deviation_detection_integration_test.dart, rapid_deviations_vm_test.dart
  - `DeviationMonitor.ingest` — lib/services/deviation_monitor.dart: 45–79
  - `ReroutePolicy.onSustainedDeviation` — lib/services/reroute_policy.dart: 28–45
- route_cache_* tests
  - `RouteCacheEntry` — lib/services/route_cache.dart: 9–51
  - `RouteCache.get/put/clear` — lib/services/route_cache.dart: 94–156
- sensor_fusion_test.dart
  - `SensorFusionManager.startFusion` — lib/services/sensor_fusion.dart: 49–79
- places_session_token_test.dart
  - `PlacesService._ensureSessionToken` — lib/services/places_service.dart: 9–22
  - `ApiClient.getAutocompleteSuggestions` — lib/services/api_client.dart: 300–320
  - `ApiClient.getPlaceDetails` — lib/services/api_client.dart: 327–343
- tracking_service_reroute_integration_test.dart
  - `OfflineCoordinator.getRoute` — lib/services/offline_coordinator.dart: 110–141
  - `ReroutePolicy.onSustainedDeviation` — lib/services/reroute_policy.dart: 28–45
- metro_stops_prior_test.dart
  - `TransferUtils.buildRouteEvents` — lib/services/transfer_utils.dart: 67–132
  - `TransferUtils.buildStepBoundariesAndStops` — lib/services/transfer_utils.dart: 134–178
  - `MetroStopService.validateDestination/validateMetroRoute` — lib/services/metro_stop_service.dart: 37–84, 86–126
- stop_end_tracking_vm_test.dart
  - `AlarmPlayer.playSelected/stop` — lib/services/alarm_player.dart: 31–58, 60–79
- direction_service_behavior_test.dart (colors/patterns)
  - `DirectionService.buildSegmentedPolylines` styling — lib/services/direction_service.dart: 140–EOF

Note: Line ranges reflect current workspace revision; update if files change.
