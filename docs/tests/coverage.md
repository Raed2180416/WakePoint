# Tests Coverage Map

This document maps each test file to the feature area(s), thresholds, and behaviors it validates. Use it to navigate verification for alarms, deviations, routing, and power policy.

- `active_route_manager_test.dart`: Active route selection, sustain timer, blackout handling, switch margin behavior.
- `active_route_manager_complex_test.dart`: Multi-route scenarios, candidate selection stability under noisy positions.
- `deviation_detection_integration_test.dart`: Deviation sustain logic end-to-end through manager + monitor.
- `deviation_decision_tree_test.dart`: Thresholds: <100 m ignore; 100–150 m local switch preference; >150 m reroute policy.
- `direction_service_behavior_test.dart`: Segmented polylines correctness; metro vs driving styling; bounds.
- `direction_service_caching_test.dart`: OfflineCoordinator/RouteCache behavior; cache hits/misses semantics.
- `eta_utils_test.dart`: Step-boundary ETA calculation fallback and formatting.
- `maptracking_eta_distance_test.dart`: Foreground ETA and remaining distance display based on snap progress.
- `metro_stops_prior_test.dart`: Stops-mode destination alarm; pre-boarding alert at <=1 km to first transit boarding; event alarms mapping to stops.
- `offline_coordinator_test.dart`: Network/cache decisioning, refresh behavior, and failure handling.
- `places_session_token_test.dart`: Proper session token handling across Places calls.
- `polyline_simplifier_test.dart`: Simplification and decompression of overview/simplified polylines.
- `power_policy_tracking_test.dart`: Battery-tiered accuracy, distanceFilter, dropout buffer, notification tick, reroute cooldown.
- `rapid_deviations_vm_test.dart`: Robustness against quick zig-zag deviations; sustain gating prevents churn.
- `route_cache_integration_test.dart`: RouteCache + read/write correctness; eviction and transit variant keys.
- `route_cache_policy_test.dart`: Cache TTL and policy rules under different modes.
- `route_cache_transit_variant_test.dart`: Transit variant (`rail`) isolation in keys and lookups.
- `route_events_test.dart`: Transfer and mode-change event extraction and threshold matching.
- `route_registry_test.dart`: Bounds safety, SW/NE ordering, proximity candidates, progress updates.
- `sensor_fusion_test.dart`: GPS dropout buffer enabling fusion; basic prediction continuity.
- `simplified_polyline_present_test.dart`: Ensures simplified polyline usage when present.
- `simulated_route_integration_test.dart`: Full-flow tracking with injected positions; alarms and notifications observable in test mode.
- `snap_to_route_test.dart`: Snapping correctness, lateral offset, progress computation and hint index.
- `stop_end_tracking_vm_test.dart`: STOP_ALARM and END_TRACKING actions wiring from notifications.
- `time_alarm_vm_test.dart`: Time-mode gating and triggers once eligible; ETA threshold mapping.
- `tracking_alarm_test.dart`: Distance-mode alarms and notification recording.
- `tracking_service_connectivity_test.dart`: Online/offline gating into reroute policy.
- `tracking_service_reroute_integration_test.dart`: Cooldown-driven reroute, cache/network fetch via OfflineCoordinator.
- `transfer_utils_test.dart`: Step boundary and stops calculations; event boundaries mapping.
- `widget_test.dart`: Basic widget tree smoke tests.
