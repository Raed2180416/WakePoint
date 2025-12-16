# GeoWake Test Suite Plan (Android focus)

## Objectives
- Ensure critical user journeys (Home → Preload → MapTracking → Alarm/Stop) are regression-proof.
- Verify reroute, deviation, offline/cache, metro/stops mode, and alarm behaviors in both service and UI layers.
- Cover startup/permissions, configuration flags, and background service lifecycle.
- Keep existing unit/logic tests as fast guards; add widget/device tests for UI/state coupling.

## Current Coverage Snapshot (adequate areas)
- **Routing/Cache/Deviation Logic**: route cache policy/integration, deviation detection, snap-to-route, transfer utils, ETA utils, polyline simplifier/projection, power policy, rapid deviations, hybrid ETA/time, mixed-mode alarms, reroute policy continuity, route registry basics.
- **Alarms/Notifications (logic)**: alarm logic, event alarm overlap/progress, stop logic engine, notification action classification/service (test-mode hooks), tracking alarm/time alarm VM, stop_end_tracking VM, mixed-mode regression.
- **Direction service**: caching and behavior.
- **Sensor fusion**: basic fusion test.
- **Device alarm integration**: single on-device path (injected GPS) verifying alarm fires.

## Key Gaps/Risks
- **UI flows**: No widget tests for HomeScreen or MapTracking (destination selection, sliders, metro toggle, map tap, reroute UI refresh, end-tracking navigation, banners for offline/low battery).
- **Reroute UI sync**: No test that MapTracking refreshes polylines/ETA on route switches; current reroute tests only check service streams.
- **End tracking UX**: No test that END TRACKING navigates away/clears snapshot/markers; PopScope can strand users.
- **Startup/permissions**: No coverage ensuring WidgetsFlutterBinding.ensureInitialized before plugins; notification permission path untested on Android (and iOS later).
- **Config flags**: Playground bridge default enable not gated; AppConfig URL mismatch unused—no tests to prevent accidental production misuse.
- **Offline/metro UX**: No UI coverage that offline banner gates routing or metro validation errors block Wake Me.
- **Stops-mode/stale geometry**: No UI test for stops-based alarms or for reroute replacing geometry when using constant key active_route.
- **Background lifecycle**: No device test for stop/end flows, reroute mid-run, or alarm restart after app kill.

## Additions Required (proposed files/tests)
- **Widget/Golden**
  - `test/ui/homescreen_flow_test.dart`: destination entry + suggestion select + map tap drop pin; metro toggle + slider thresholds; offline/low-battery banners and Wake Me disabled states; navigation to preload with correct arguments.
  - `test/ui/maptracking_reroute_refresh_test.dart`: start with route A, emit routeSwitch event → expect polylines/_routePoints updated, ETA/distance text changes, markers snap to new geometry.
  - `test/ui/maptracking_end_tracking_navigation_test.dart`: tap END TRACKING → completeEndTracking called, snapshot cleared, Navigator returns to home/preload; PopScope allows exit.
  - `test/ui/stops_mode_ui_test.dart`: metro + stops mode shows stops label, slider integer clamping, args carry alarmMode='stops'.

- **Service/Integration (hosted)**
  - Extend `tracking_service_reroute_integration_test.dart`: assert ActiveRouteManager exposes new geometry and emits to UI hook; ensure routeRegistry upsert replaces geometry when key reused.
  - Add `tracking_service_stop_flow_integration_test.dart`: start → stop/end; verify snapshot removed, route registry cleared, notification canceled, background service halted.
  - Add `offline_routing_guard_test.dart`: offline banner forces cached route usage and fails when no cache; Wake Me button disabled when offline and no cache.

- **Startup/Permissions**
  - `main_startup_init_test.dart`: ensure WidgetsFlutterBinding.ensureInitialized invoked before Hive/plugins; verify no plugin calls before binding.
  - `notification_permission_android_test.dart`: PermissionService requests POST_NOTIFICATIONS on Android and handles denial; (note: iOS path later).

- **Config Flags**
  - `playground_bridge_flag_test.dart`: default disabled on non-debug; enabling requires explicit dart-define; no WS attempt when disabled.
  - `app_config_url_alignment_test.dart`: assert AppConfig.serverBaseUrl matches ApiClient base or is unused (fail on localhost in release builds).

- **Device/Integration (instrumented)**
  - Extend `integration_test/device_alarm_integration_test.dart`: scenarios for reroute mid-run (new directions injected) and end-tracking cleanup; verify UI navigates home and notifications cleared.
  - Add `integration_test/device_offline_recovery_test.dart`: start offline with cached route, regain connectivity, and reroute; ensure alarm still fires.

## Data/Scaffolding Needs
- Test factories for directions/routes to avoid boilerplate; reuse `test/test_routes.dart` or add helpers under `test/support/` for encoded polylines and snapshots.
- Mock Navigator wrapper for widget tests to assert route pushes/pops.
- Hooks to inject route switch events into MapTracking (e.g., expose test stream setter or use TrackingService.testMode with fake registry).

## Prioritized Order (Android focus)
1) UI widget tests: HomeScreen flow, MapTracking reroute refresh, end-tracking navigation, stops mode.
2) Service/integration: reroute replacement geometry, stop flow cleanup, offline gating.
3) Startup/permissions and config flag tests.
4) Device integration variants (reroute mid-run, stop/end, offline recovery).

## Adequacy Check After Additions
- Ensure each user journey is covered by at least one widget or device test and critical logic by a unit/integration test.
- Maintain fast unit suite; keep slow device/integration tests tagged or separated.
- Re-run `flutter test --disable-dds` for unit/widget; `flutter test integration_test` for device flows.

## Maintenance Notes
- Keep TrackingService.isTestMode, NotificationService hooks, and testGpsStream stable; avoid regressions in test-only APIs.
- Gate playground bridge by build mode; add asserts in tests to prevent accidental enablement.
- When EKF/dead-reckoning lands, add fusion consistency tests using recorded traces.
