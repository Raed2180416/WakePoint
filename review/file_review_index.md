# File-by-File Review Index

This is the tracking sheet for the comprehensive review.

Legend:
- Status: Not started / In progress / Reviewed / Needs follow-up

## lib/

| File | Status | Purpose summary | Key invariants | Linked findings |
|---|---|---|---|---|
| lib/main.dart | Reviewed | App entry + routing setup | Binding initialized before plugins | |
| lib/main_dashboard.dart | Reviewed | Alternate app entry / dashboard | Uses same state ownership rules as main | |
| lib/simulation_engine.dart | Reviewed | Simulation glue (dev/test) | Never mutates prod state unintentionally | |
| lib/config/app_config.dart | Reviewed | Config/constants | No secrets committed; defaults safe | |
| lib/config/platform_test_flag_io.dart | Reviewed | Platform test flag (IO) | Behavior stable across platforms | |
| lib/config/platform_test_flag_stub.dart | Reviewed | Platform test flag (stub) | Stub matches IO API surface | |
| lib/config/playground_bridge.dart | Reviewed | Dev playground wiring | Must not affect release behavior | |
| lib/config/power_policy.dart | Reviewed | Battery/power policy knobs | Never disables critical alarms | |
| lib/debug/demo_tools.dart | Reviewed | Debug/demo helpers | Guarded by debug flags | |
| lib/debug/dev_server.dart | Reviewed | Dev server integration | Disabled/isolated in release | |
| lib/models/route_models.dart | Reviewed | Route/directions models | JSON parsing tolerant but correct | |
| lib/screens/homescreen.dart | Reviewed | Destination selection + route fetch + start tracking | Snapshot saved before navigation | |
| lib/screens/maptracking.dart | Reviewed | Live map + session UI | Restores from snapshot when args missing | |
| lib/screens/ringtones_screen.dart | Reviewed | Ringtone selection UI | Selected ringtone persists correctly | |
| lib/screens/settingsdrawer.dart | Reviewed | Settings drawer UI | Toggles reflect persisted settings | |
| lib/screens/splash_screen.dart | Reviewed | Service init + routing decisions | Init runs before restore navigation | |
| lib/screens/otherimpservices/preload_map_screen.dart | Reviewed | Map platform-view warm-up | Handoff always occurs once map ready | |
| lib/screens/otherimpservices/recent_locations_service.dart | Reviewed | Recent locations persistence | Hive box name consistent + flushed on pause | |
| lib/services/active_route_manager.dart | Reviewed | Active route selection/switching | State metrics match active route | |
| lib/services/alarm_player.dart | Reviewed | Alarm audio playback | Gracefully degrades when plugins unavailable; isPlaying is the UI latch | |
| lib/services/api_client.dart | Reviewed | API client init/auth | Token stored in SharedPreferences; testMode returns canned responses | |
| lib/services/deviation_detection.dart | Reviewed | Deviation math/thresholds | Uses nearest-vertex distance and fixed online/offline thresholds | |
| lib/services/deviation_monitor.dart | Reviewed | Deviation monitoring loop | Speed-based hysteresis + sustain timer emits DeviationState | |
| lib/services/direction_service.dart | Reviewed | Directions fetch/parse | Tiered refresh intervals + RouteCache persistence + simplified polyline | |
| lib/services/eta_engine.dart | Reviewed | ETA computation | Map-matching + speed smoothing; persists speed window in SharedPreferences | |
| lib/services/eta_utils.dart | Reviewed | ETA formatting/helpers | ETA derived from step durations + progress | |
| lib/services/metro_stop_service.dart | Reviewed | Metro stop lookup | Server-backed nearby transit stop fetch + metro-route validation | |
| lib/services/navigation_service.dart | Reviewed | Global navigator key | Central key for non-context navigation | |
| lib/services/notification_service.dart | Reviewed | Notifications + actions | Foreground vs background handling defined | |
| lib/services/offline_coordinator.dart | Reviewed | Offline route/cache coordinator | Offline mode forces cached-only routes; exposes offline stream | |
| lib/services/permission_service.dart | Reviewed | Permission helpers | Location+background+notifications flow; settings redirect when permanently denied | |
| lib/services/places_service.dart | Reviewed | Places/autocomplete | Session token rotates ~3 min; returns normalized suggestion/detail maps | |
| lib/services/polyline_decoder.dart | Reviewed | Polyline decoding | Best-effort decode returns partial points on error | |
| lib/services/polyline_simplifier.dart | Reviewed | Polyline simplification | RDP simplification + gzip+base64 compression/decompression | |
| lib/services/reroute_policy.dart | Reviewed | Reroute decisions | Online + cooldown gating emits reroute decisions via stream | |
| lib/services/route_cache.dart | Reviewed | Route caching | Hive JSON cache enforces TTL and origin deviation | |
| lib/services/route_queue.dart | Reviewed | Candidate route queue | In-memory ring with active index; sets isActive flags | |
| lib/services/route_registry.dart | Reviewed | Route store/registry | Geometry + derived metrics replaced on key reuse | |
| lib/services/sensor_fusion.dart | Reviewed | Sensor fusion manager | Subscriptions disposed correctly | |
| lib/services/simulation_client.dart | Reviewed | Simulation websocket client | Failures don’t break tracking | |
| lib/services/snap_to_route.dart | Reviewed | Map-match / snap logic | progressMeters derived from cumMeters + projection | |
| lib/services/stop_logic_engine.dart | Reviewed | Stops-mode computations | Transit stops interpolated; walking/driving distance converted to “virtual stops” when needed | |
| lib/services/test_service_instance.dart | Reviewed | Test helpers for service | Never used in production path | |
| lib/services/tracking_state_store.dart | Reviewed | Persisted flags + snapshot | Keys consistent across isolates | |
| lib/services/trackingservice.dart | Reviewed | Background service orchestration | Listener registration precedes events | |
| lib/services/transfer_utils.dart | Reviewed | Transfer/boarding extraction | Events use cumulative meters; step stops are transit-only; virtual-stop conversion uses 500m per stop | |
| lib/themes/appthemes.dart | Reviewed | Theme definitions | No hardcoded colors outside theme | |
| lib/widgets/pulsing_dots.dart | Reviewed | UI widget | Pure widget; no side effects | |

(The lib/ inventory above is complete; next sections cover non-lib parts of the repo.)

## repo manifests / build config

| File | Status | Purpose summary | Key invariants | Linked findings |
|---|---|---|---|---|
| pubspec.yaml | Reviewed | Flutter package metadata + dependencies + assets | Declared deps match platform permissions/usage; assets referenced in UI exist | |
| analysis_options.yaml | Reviewed | Dart analyzer + lint configuration | Lints are consistent with repo conventions | |
| android/build.gradle | Reviewed | Android project-level Gradle config | Repos defined (google/mavenCentral); build output paths stable | |
| android/gradle.properties | Reviewed | Android Gradle properties | AndroidX enabled; Jetifier enabled | |
| android/app/build.gradle | Reviewed | Android app build config | minSdk/targetSdk/compileSdk align with plugin requirements; manifest placeholders resolve | |
| android/app/proguard-rules.pro | Reviewed | Android Proguard/R8 rules | Rules match release minify/shrink config | |
| android/app/src/main/AndroidManifest.xml | Reviewed | Android app manifest (permissions + components) | Permissions align with runtime behavior; background service type declared | |
| android/app/src/debug/AndroidManifest.xml | Reviewed | Debug manifest overlay | Dev overlay does not weaken release invariants | |
| android/app/src/profile/AndroidManifest.xml | Reviewed | Profile manifest overlay | Profile overlay matches debug overlay scope | |
| ios/Runner/Info.plist | Reviewed | iOS app Info.plist | Usage description strings exist for requested permissions | |
| ios/Runner.xcodeproj/project.pbxproj | Reviewed | iOS Xcode project config | Targets + build scripts + signing settings reflect intended permissions | |
| macos/Runner/Info.plist | Reviewed | macOS app Info.plist | Bundle metadata driven by build settings | |
| macos/Runner/DebugProfile.entitlements | Reviewed | macOS sandbox entitlements (debug/profile) | Sandbox enabled; debug-only capabilities explicit | |
| macos/Runner/Release.entitlements | Reviewed | macOS sandbox entitlements (release) | Sandbox enabled in release | |
| macos/Runner.xcodeproj/project.pbxproj | Reviewed | macOS Xcode project config | Entitlements + sandbox wiring is consistent across configs | |
| web/manifest.json | Reviewed | Web app manifest | App name/icons/orientation defined; matches web entrypoint | |
| web/index.html | Reviewed | Web entrypoint HTML | Loads Flutter bootstrap; includes Maps JS script tag when present | |
| windows/runner/CMakeLists.txt | Reviewed | Windows runner build config | Runner includes resources + manifest | |
| windows/runner/Runner.rc | Reviewed | Windows icon + version resources | Version macros tie to FLUTTER_VERSION defines | |
| windows/runner/runner.exe.manifest | Reviewed | Windows app manifest | DPI awareness + supported OS declared | |
| linux/CMakeLists.txt | Reviewed | Linux project-level build config | Application ID and bundle install layout set | |
| linux/runner/CMakeLists.txt | Reviewed | Linux runner build config | Runner builds executable + registers plugins | |
| linux/flutter/CMakeLists.txt | Reviewed | Linux Flutter tool build glue | Controlled by Flutter tool + ephemeral config | |

## test/

| File | Status | Purpose summary | Key invariants | Linked findings |
|---|---|---|---|---|
| test/flutter_test_config.dart | Reviewed | Global test bootstrapping (Hive temp dir) | Hive is initialized before any box opens; Hive is closed after tests | |
| test/log_helper.dart | Reviewed | Test logging helpers | Only writes to stdout; no global state | |
| test/mock_location_provider.dart | Reviewed | Fake GPS stream for tests | Stream emits Positions in route order; stream closes at end | |
| test/test_routes.dart | Reviewed | Predefined LatLng routes for tests | Route lists are static const and deterministic | |
| test/minimal_test.dart | Reviewed | Minimal compilation/smoke test | TrackingService can be constructed in test context | |
| test/widget_test.dart | Reviewed | Placeholder widget test template | Marked skipped; does not execute assertions | |
| test/app_config_url_alignment_test.dart | Reviewed | AppConfig/ApiClient URL invariants | Release/server URL must not be localhost; host aligns with ApiClient | |
| test/playground_bridge_flag_test.dart | Reviewed | Playground bridge gating under tests | Playground bridge disabled when running under flutter test | |
| test/places_session_token_test.dart | Reviewed | Places session token reuse across calls | Autocomplete + place details share the same session token | |
| test/alarm_logic_test.dart | Reviewed | StopLogicEngine remaining-stops calculations | Remaining stops computed against destination vs switch-point targets | |
| test/notification_action_classification_test.dart | Reviewed | Notification action outcome classification | ActionId+payload maps to NotificationActionOutcome | |
| test/notification_service_test.dart | Reviewed | NotificationService test hooks | Test mode records alarm calls and captures allowContinueTracking | |
| test/simplified_polyline_present_test.dart | Reviewed | Directions response invariant | DirectionService injects simplified_polyline into routes[0] | |
| test/power_policy_tracking_test.dart | Reviewed | TrackingService timer cadence smoke test in test mode | Sets TrackingService.isTestMode and feeds GPS points without exceptions | |
| test/sensor_fusion_test.dart | Reviewed | SensorFusionManager definition (not a real test) | Exposes fusedPositionStream; main() is empty to satisfy runner | |
| test/snap_to_route_test.dart | Reviewed | SnapToRouteEngine snapping behavior | Asserts segmentIndex/lateralOffset/progress bounds across cases | |
| test/polyline_projection_clamp_test.dart | Reviewed | PolylineSimplifier projection-clamp behavior (indirect) | Asserts endpoint closeness and simplifyPolyline reduces to endpoints under high tolerance | |
| test/polyline_simplifier_test.dart | Reviewed | PolylineSimplifier simplify + compress/decompress | Decompressed points match simplified within tolerance | |
| test/reproduce_missing_bounds.dart | Reviewed | Regression reproduction: alarm fired when bounds/stops present | Uses registerRouteRaw + injected GPS stream; asserts TrackingStateStore.isAlarmFired transitions | |
| test/reproduce_polyline_color_test.dart | Reviewed | TransferUtils.buildRouteSegments mode labeling | Asserts segment modes across walking/transit/walking/transit/walking; second test is empty | |
| test/reproduce_stop_alarm.dart | Reviewed | Regression reproduction: stop interpolation and overshoot clamp | Manually computes progressStops from step bounds/stops and asserts expected remaining stops | |
| test/reproduce_stop_alarm_overshoot_test.dart | Reviewed | Regression reproduction: transfer-point alarm when arriving exactly at switch point | Synthetic directions with two transit legs; asserts recorded notification includes transfer label | |
| test/reproduce_stop_logic.dart | Reviewed | Regression reproduction: step boundaries/events + remaining stops | Asserts expected bounds/stops; checks events non-empty; validates remaining stops at two progress points | |
| test/active_route_manager_test.dart | Reviewed | ActiveRouteManager switching + hysteresis | Switch requires sustained proximity advantage; blackout applied after switching | |
| test/active_route_manager_complex_test.dart | Reviewed | ActiveRouteManager multi-deviation scenario | Expects multiple switches across deviations + merge region | |
| test/deviation_decision_tree_test.dart | Reviewed | Deviation thresholds integration via TrackingService | Asserts below-100m no switch; ~100–150m triggers routeSwitchStream | |
| test/deviation_detection_integration_test.dart | Reviewed | isDeviationExceeded behavior on/off route | Uses RouteModel polylineDecoded; asserts false on-route and true off-route | |
| test/rapid_deviations_vm_test.dart | Reviewed | Stress route switching with many deviations | Registers two routes; plays weave; asserts at least one routeSwitchStream event | |
| test/reroute_policy_continuity_test.dart | Reviewed | ReroutePolicy stream continuity when cooldown changes | Emits decisions across deviations and setCooldown; asserts true/false/true sequence | |
| test/direction_service_behavior_test.dart | Reviewed | DirectionService + RouteCache behavior tests | Verifies forceRefresh vs cached call count; transit variant request fields; TTL and origin deviation invalidation | |
| test/direction_service_caching_test.dart | Reviewed | Placeholder test file | Contains a single always-true test | |
| test/offline_coordinator_test.dart | Reviewed | OfflineCoordinator route-source selection | Online uses provider; offline uses cache; offline without cache throws StateError | |
| test/offline_routing_guard_test.dart | Reviewed | OfflineCoordinator offline guard behavior | When offline, network provider is not called; cache hit returns RouteSource.cache | |
| test/route_cache_policy_test.dart | Reviewed | Placeholder test file | Contains a single always-true test | |
| test/route_cache_transit_variant_test.dart | Reviewed | Placeholder test file | Contains a single always-true test | |
| test/route_cache_integration_test.dart | Reviewed | DirectionService caching behavior (testMode) | Calls getDirections twice and asserts second call is fast (heuristic) | |
| test/route_events_test.dart | Reviewed | TransferUtils.buildRouteEvents emissions | Asserts transfer/mode_change boundaries and cumulative meters | |
| test/route_registry_test.dart | Reviewed | RouteRegistry candidate filtering | candidatesNear returns nearby routes and excludes distant ones | |
| test/route_registry_upsert_replace_test.dart | Reviewed | RouteRegistry upsert replacement behavior | Reused key replaces geometry/metrics (length/bbox) not just timestamps | |
| test/eta_engine_test.dart | Reviewed | EtaEngine computeEta scenarios | On-route and mid-route ETA checks; dwell/stationary behavior; off-route snap behavior | |
| test/eta_utils_test.dart | Reviewed | EtaUtils.etaRemainingSeconds math | Computes remaining seconds from progress and step boundaries/durations | |
| test/hybrid_eta_time_test.dart | Reviewed | Time-mode metro alarms and API refresh throttling | Uses registerRouteRaw + route event; asserts alarms for switch and destination; asserts directionsCallCount <= 2 | |
| test/maptracking_eta_distance_test.dart | Reviewed | ETA/time-to-switch computations using snap + directions-derived boundaries | Uses SnapToRouteEngine + EtaUtils and TransferUtils.buildTransferBoundariesMeters | |
| test/stop_logic_engine_test.dart | Reviewed | StopLogicEngine remaining stops + pre-boarding checks | Validates remaining stops before/after switch and pre-boarding trigger/suppress cases | |
| test/metro_stops_prior_test.dart | Reviewed | Metro pre-boarding alert and stops-prior transfer alert | Synthetic metro directions; asserts notification bodies contain expected phrases | |
| test/transfer_utils_test.dart | Reviewed | TransferUtils transfer detection between consecutive transit legs | Asserts board/transfer/alight events and cumulative meters when IDs missing | |
| test/complex_route_alarm_test.dart | Reviewed | Complex stop-alarm behavior across multiple transfers and conflict scenario | Asserts switch alarms fire; asserts destination alarm preferred over switch when coincident | |
| test/mixed_mode_alarm_test.dart | Reviewed | Mixed-mode stops alarm near boarding while walking | Synthetic walk->transit directions; asserts recorded alarm contains Board/Approaching | |
| test/mixed_mode_regression_test.dart | Reviewed | Mixed-mode regression: walking threshold then transit stops threshold | Uses registerRouteRaw + checkAlarmForTest via extension; asserts alarm fires/doesn’t fire at specific progress points | |
| test/event_alarm_overlap_test.dart | Reviewed | Placeholder/incomplete overlap scenario test | Builds directions/events and starts tracking, but only asserts true (no alarm assertions) | |
| test/event_alarm_progress_source_test.dart | Reviewed | Event alarm trigger near transfer point using snapped progress | Synthetic directions with transfer stop; injects positions and asserts recorded alarm contains Approaching/Board | |
| test/time_alarm_vm_test.dart | Reviewed | Time-based alarm smoke test on moving route | Plays short route; asserts recorded alarms count <= 2 in test mode | |
| test/tracking_alarm_test.dart | Reviewed | Distance alarm triggers when injected GPS enters threshold | Uses global injected GPS stream; expects NotificationService records wake-up alarm | |
| test/tracking_service_connectivity_test.dart | Reviewed | GPS dropout simulation toggles sensor fusion on/off | fusionActive becomes true after dropout buffer; returns false on GPS resume | |
| test/tracking_service_reroute_integration_test.dart | Reviewed | Deviation/reroute + cached-route manager integration scenario | Either routeSwitchStream emits r1->r2 or rerouteDecisionStream yields shouldReroute true | |
| test/tracking_service_stop_flow_integration_test.dart | Reviewed | End-tracking flow clears persisted active state and snapshot | completeEndTracking clears TrackingStateStore active flag, snapshot, and muted flag | |
| test/simulated_route_integration_test.dart | Reviewed | Simulated route playback triggers alarm in test hooks | Expects TrackingService.alarmTriggered after playing injected route | |
| test/stop_end_tracking_vm_test.dart | Reviewed | Stop tracking stops alarm playback (VM test) | After stopTracking(), AlarmPlayer.isPlaying is false | |
| test/ui/maptracking_end_tracking_navigation_test.dart | Reviewed | Placeholder MapTracking end-tracking navigation test | Marked skipped; no assertions executed | |
| test/ui/maptracking_reroute_refresh_test.dart | Reviewed | Placeholder MapTracking reroute/refresh UI test | Marked skipped; no assertions executed | |

## integration_test/

| File | Status | Purpose summary | Key invariants | Linked findings |
|---|---|---|---|---|
| integration_test/device_alarm_integration_test.dart | Reviewed | On-device alarm flow using injected positions | TrackingService runs in test mode while platform notifications remain enabled | |

## test_driver/

| File | Status | Purpose summary | Key invariants | Linked findings |
|---|---|---|---|---|
| test_driver/integration_test.dart | Reviewed | Integration test driver entrypoint | Runs integration_test driver via integrationDriver() | |

## tools/

| File | Status | Purpose summary | Key invariants | Linked findings |
|---|---|---|---|---|
| tools/relay_server.dart | Reviewed | Simple WS relay server with heartbeat | Broadcasts messages to other clients; ping/pong used for liveness | |
| tools/test_relay.dart | Reviewed | Small WS relay sanity test client | Connects two clients, sends message A->B, exits 0/1 by result | |

## geowake-server/

Note: `geowake-server/node_modules/` is vendored dependencies and is excluded from review.

| File | Status | Purpose summary | Key invariants | Linked findings |
|---|---|---|---|---|
| geowake-server/src/server.js | Reviewed | Express API server wiring and middleware | /api/maps routes require authenticateDevice; CORS origin gate applied | |
| geowake-server/src/config/config.js | Reviewed | Env-based configuration + validation | Exits process if GOOGLE_MAPS_API_KEY missing or JWT_SECRET < 32 chars | |
| geowake-server/src/middleware/security.js | Reviewed | Rate limiting + slowdown policy | Uses IP from x-forwarded-for or req.ip; exports slowDownRules/rateLimitRules | |
| geowake-server/src/middleware/auth.js | Reviewed | JWT auth for device requests | Requires Authorization: Bearer; decoded.bundleId must match config.appBundleId | |
| geowake-server/src/utils/cache.js | Reviewed | NodeCache wrapper for caching Google API responses | Key generation depends on request type + params; TTL derived from config.cacheTimeouts | |
| geowake-server/src/controllers/authController.js | Reviewed | Auth controller for issuing app JWT tokens | Token payload includes bundleId and iss; expiration from config.jwtExpiration | |
| geowake-server/src/controllers/mapsController.js | Reviewed | Google Maps API proxy endpoints with caching | Adds API key server-side; caches successful responses and returns cached hits | |
| geowake-server/src/routes/auth.js | Reviewed | Auth route bindings | POST /token uses rateLimitRules.auth and generateToken controller | |
| geowake-server/src/routes/maps.js | Reviewed | Maps route bindings | Applies rateLimitRules.maps; exposes directions/autocomplete/place-details/geocode/nearby-search | |
| geowake-server/test/README.md | Reviewed | Backend test-suite documentation | Documents env vars and how to run Jest/Supertest tests | |
| geowake-server/test/auth.test.js | Reviewed | Jest/Supertest tests for auth + health + 404 | Uses POST /api/auth/token and asserts response shapes/status codes | |
| geowake-server/test/maps.test.js | Reviewed | Jest/Supertest tests for maps endpoints + caching | Asserts auth required; accepts various request shapes; compares responses for caching when 200 | |

## Reviewed notes (facts-only)

### lib/main.dart
- Purpose/role: App entrypoint, global navigation wiring, theme persistence, and lifecycle observer.
- Routes: `initialRoute` is `/splash` and navigation uses `onGenerateRoute` (no static `routes:` map).
- Global navigation: `navigatorKey` is provided via `NavigationService.navigatorKey`.
- Lifecycle handling: on app `paused`, flushes the Hive box used by `RecentLocationsService` if open; also forwards lifecycle events to `TrackingService.handleAppLifecycleChange`.

### test/widget_test.dart
- Purpose/role: Placeholder widget-test file.
- Test content: Declares a single `testWidgets` named "Counter increments smoke test" with an empty body.
- Execution: The test is marked `skip: true`.

### test/alarm_logic_test.dart
- Purpose/role: Unit/integration-style tests for `StopLogicEngine.calculateRemainingStops`.
- Setup: Creates a `StopLogicEngine` instance in `setUp`.
- Test: "calculateRemainingStops returns correct values"
	- Inputs: `stepBoundsMeters = [1000.0, 2000.0]`, `stepStopsCumulative = [2.0, 5.0]`, `routeEvents = []`, `progressMeters = 500.0`, `firedEventIndexes = {}`.
	- Assertions: `remainingStops` is approximately `4.0` and `isDestination` is `true`.
- Test: "calculateRemainingStops handles switch points"
	- Inputs: same bounds/stops, with `routeEvents` containing `RouteEventBoundary(meters: 1500.0, label: 'Switch', type: 'transfer')`.
	- Assertions: `remainingStops` is approximately `2.5`, `targetName` equals `'Switch'`, and `isDestination` is `false`.

### test/power_policy_tracking_test.dart
- Purpose/role: Smoke test for `TrackingService.startTracking` execution under test-mode power policy.
- Setup: Initializes `TestWidgetsFlutterBinding`, mock `SharedPreferences`, sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`.
- Test: Starts tracking with a destination and distance alarm, assigns a `StreamController<Position>` stream to the global `testGpsStream`, feeds a few `Position` updates with delays, asserts `true` (i.e., no exceptions), then calls `stopTracking` and closes the stream.

### test/sensor_fusion_test.dart
- Purpose/role: Contains an implementation of `SensorFusionManager` (accelerometer-based dead-reckoning) rather than unit assertions.
- API shape:
	- Constructor takes `initialPosition` and an optional injected `accelerometerStream` (defaults to `accelerometerEvents`).
	- Exposes `fusedPositionStream` (`Stream<LatLng>`) from a broadcast `StreamController`.
	- Methods: `startFusion()` subscribes to accelerometer and integrates velocity/position; `stopFusion()` cancels subscription; `reset()` reinitializes; `dispose()` closes controller.
- Test runner: Declares an empty `main()` with a comment noting it is not a real test.

### test/snap_to_route_test.dart
- Purpose/role: Unit tests for `SnapToRouteEngine.snap` behavior.
- Test data: Uses a 3-point polyline forming an L shape: (0,0) -> (0,0.01) -> (0.01,0.01).
- Tests:
	- "Snaps near first segment with small lateral offset": asserts `segmentIndex == 0`, lateral offset between ~40–80m, and progress between ~400–700m for a point slightly north of the first segment.
	- "Respects hintIndex to keep continuity": calls `snap` twice (second call includes `hintIndex`) and asserts `segmentIndex` is 0 or 1 and progress is non-decreasing.
	- "Snaps to second segment once past the corner": asserts `segmentIndex == 1` and lateral offset < 60m for a point near the vertical segment.

### test/polyline_projection_clamp_test.dart
- Purpose/role: Validates assumptions about projection clamping behavior used by polyline simplification (indirectly).
- Content:
	- Defines local `_haversine` and `_toRad` helpers.
	- Asserts a point beyond segment endpoint B is closer to B than A, and a point before A is closer to A than B.
	- Calls `PolylineSimplifier.simplifyPolyline([A, P, B], 5000.0)` for two cases and asserts first/last points are A/B and length >= 2.

### test/polyline_simplifier_test.dart
- Purpose/role: Unit tests for `PolylineSimplifier` simplify and compression round-trip.
- Tests:
	- Low tolerance: asserts first/last preserved and length >= 2.
	- Higher tolerance (10): asserts result length equals 2 and endpoints preserved.
	- Compress/decompress: compresses a simplified polyline and asserts decompressed lat/lng match within `1e-6`.

### test/reproduce_missing_bounds.dart
- Purpose/role: Regression reproduction test that exercises tracking/stop-alarm firing with explicit step bounds/stops.
- Setup: Ensures binding initialized; mocks `SharedPreferences`; sets `TrackingService.isTestMode = true`; sets `TrackingStateStore.setAlarmFired(false)`; resets `testGpsStream` in `tearDown`.
- Test flow:
	- Calls `TrackingService.registerRouteRaw` with:
		- `points: [LatLng(0,0), LatLng(0.01,0)]`, `stepBounds: [100.0, 1100.0]`, `stepStops: [0.0, 10.0]`, `routeEvents: []`, `firstTransitBoarding: LatLng(0.001, 0.001)`.
	- Starts tracking with `alarmMode: 'stops'`, `alarmValue: 2.0`, and `useInjectedPositions: false` (uses `testGpsStream`).
	- Injects one position at ~150m progress and asserts `TrackingStateStore.isAlarmFired()` is `false`.
	- Injects a series of positions (latitude 0.002..0.012 step 0.001) with short delays, then after an additional delay asserts `TrackingStateStore.isAlarmFired()` is `true`.
	- Stops tracking and closes the stream.

### test/reproduce_polyline_color_test.dart
- Purpose/role: Unit test for `TransferUtils.buildRouteSegments` mode classification.
- Test: Builds a synthetic `directions` map with one leg containing five steps: WALKING, TRANSIT (line M1), WALKING, TRANSIT (line M2), WALKING; each includes `polyline.points`.
- Assertions: `segments.length == 5` and `segments[i]['mode']` equals `walking/transit/walking/transit/walking` in order.
- Additional test: Declares a second `test(...)` with an empty body containing only comments about nested steps.

### test/reproduce_stop_alarm.dart
- Purpose/role: Regression reproduction focused on stop interpolation and overshoot behavior.
- Setup: Initializes binding; mocks `SharedPreferences`; sets `TrackingService.isTestMode = true`.
- Test flow:
	- Builds a `mockDirections` with two steps: WALKING distance 100, TRANSIT distance 1000 with `num_stops: 10`.
	- Calls `registerRouteFromDirections(...)` and starts tracking in `alarmMode: 'stops'` with threshold `2.0`.
	- Computes `boundsAndStops = TransferUtils.buildStepBoundariesAndStops(mockDirections)` and prints bounds/stops.
	- Performs manual interpolation for `progressMeters = 150.0` and asserts `progressStops` is ~0.5 and remaining is ~9.5.
	- Performs an overshoot scenario `progressMeters = 1101.0` and asserts `progressStops == 10.0` and remaining == 0.0.

### test/reproduce_stop_alarm_overshoot_test.dart
- Purpose/role: Regression reproduction asserting an alarm is not skipped when arriving exactly at a transfer/switch point.
- Setup: Initializes binding; mocks `SharedPreferences`; mocks sensors method channel `dev.fluttercommunity.plus/sensors/method` to return null; sets `TrackingService.isTestMode = true`; sets `NotificationService.isTestMode = true`; clears `NotificationService.testRecordedAlarms`; resets a local `_mockTime`.
- Helpers: Implements `encodePolyline` and `_encode` to generate an encoded polyline from `LatLng` points; uses `pWithTime(...)` helper to generate `Position` with advancing timestamps.
- Test flow:
	- Builds `syntheticOvershootDirections()` with steps: WALKING, TRANSIT (L1) with arrival at Station B (Transfer), TRANSIT (L2) departing from Station B.
	- Registers route from directions and starts tracking with `alarmMode: 'stops'`, `alarmValue: 1.0`.
	- Feeds three positions: origin, Station A, then exactly Station B with `speed: 1.0`.
	- Filters `NotificationService.testRecordedAlarms` for bodies containing 'Station B' or 'Transfer' and asserts the filtered list is not empty.
	- Test has a 10-second timeout.

### test/reproduce_stop_logic.dart
- Purpose/role: Regression reproduction around step boundary/stop derivation and remaining-stops calculations.
- Test data: Builds a synthetic directions response with five steps: WALKING (500m), TRANSIT (2000m, 5 stops, arrival_stop 'Transfer Station'), WALKING (100m), TRANSIT (3000m, 3 stops, arrival_stop 'Final Station'), WALKING (200m).
- Test: "TransferUtils builds correct structures"
	- Calls `TransferUtils.buildStepBoundariesAndStops` and asserts `bounds == [500, 2500, 2600, 5600, 5800]` and `stops == [0, 5, 5, 8, 8]`.
	- Calls `TransferUtils.buildRouteEvents` and asserts the events list is non-empty.
- Test: "StopLogicEngine calculates remaining stops correctly"
	- Uses the same step data/events and calls `StopLogicEngine.calculateRemainingStops`:
		- At `progressMeters: 1500.0` asserts remaining stops ~2.5.
		- At `progressMeters: 2900.0` asserts remaining stops ~2.7, `isDestination == false`, and `targetName` contains 'Start walking'.

### test/active_route_manager_test.dart
- Purpose/role: Unit test for `ActiveRouteManager` route switching behavior including sustain window and blackout.
- Setup:
	- Creates a `RouteRegistry(capacity: 5)` and inserts two `RouteEntry` routes (A: east along equator; B: northward line intersecting near longitude 0.005).
	- Creates `ActiveRouteManager` with `sustainDuration: 300ms`, `switchMarginMeters: 10`, and `postSwitchBlackout: 200ms`; sets active key to 'A'.
	- Subscribes to `switchStream` and collects `RouteSwitchEvent`s.
- Flow/assertions:
	- Feeds several positions near route A, then feeds positions along the corridor for B and waits long enough to exceed sustain duration.
	- Asserts at least one switch event from A to B.
	- After waiting past blackout, feeds positions back near A and again waits long enough for sustain.
	- Asserts at least one switch event from B back to A.

### test/active_route_manager_complex_test.dart
- Purpose/role: Scenario test for `ActiveRouteManager` behavior across repeated deviations and a merge region.
- Setup:
	- Creates `RouteRegistry(capacity: 5)` and inserts routes R1 (east along equator) and R2 (parallel north, then merging back to R1 near the end).
	- Creates `ActiveRouteManager` with `sustainDuration: 200ms`, `switchMarginMeters: 10`, `postSwitchBlackout: 100ms`; sets active to 'R1'.
	- Collects switch events from `switchStream`.
- Flow/assertions:
	- Runs a loop of 5 deviation cycles feeding positions that sustain near R2 then back near R1.
	- Feeds positions near the merge area and asserts at least one switch from R2 back to R1.
	- Deviates again and asserts a subsequent switch from R1 to R2 occurs.
	- Asserts total switches length is at least 3.

### test/route_registry_test.dart
- Purpose/role: Unit test for `RouteRegistry.candidatesNear` filtering by distance.
- Setup: Creates `RouteRegistry(capacity: 3)` and upserts three routes: A near origin, B far away (near lat/lng 1,1), C near origin.
- Assertion: Calls `candidatesNear(LatLng(0.001, 0.002), radiusMeters: 1200, maxCandidates: 3)` and asserts the returned list includes keys A and C but not B.

### test/route_registry_upsert_replace_test.dart
- Purpose/role: Unit test verifying `RouteRegistry.upsert` replaces stored geometry/metrics when the same key is reused.
- Setup: Creates `RouteRegistry(capacity: 4)` and upserts two `RouteEntry`s with the same key 'active_route' but different endpoint distances (0->1 vs 0->0.1 longitude).
- Assertions: The stored entry has the second entry’s points and its `lengthMeters` is less than the first’s; `bbox.northeast.longitude` is close to 0.1.

### test/route_events_test.dart
- Purpose/role: Unit test for `TransferUtils.buildRouteEvents` boundary extraction.
- Test data: Constructs a directions response with steps: WALKING (300m), TRANSIT A (800m, arrival_stop Majestic), TRANSIT B (1200m, arrival_stop Central), DRIVING (500m).
- Assertions:
	- `events.length == 3`.
	- `events[0]` is a `mode_change` at 300m.
	- `events[1]` is a `transfer` at 1100m and label equals 'Majestic'.
	- `events[2]` is a `mode_change` at 2300m.

### test/deviation_decision_tree_test.dart
- Purpose/role: Integration-style test exercising deviation thresholds through `TrackingService` route switching.
- Setup: Initializes binding; mocks `SharedPreferences`; sets `TrackingService.isTestMode = true`; assigns a `StreamController<Position>` to `testGpsStream`.
- Route setup: Registers two routes (`r1` and `r2`) as parallel lines separated by ~0.001 latitude (~111m).
- Flow/assertions:
	- Starts tracking (distance alarm mode).
	- Subscribes to `routeSwitchStream` and toggles a `switched` flag.
	- Injects a position with latitude 0.0008 and asserts `switched == false` after delay.
	- Injects two positions with latitude 0.0011 and asserts `switched == true` after delays.
- Timeout: 15 seconds.

### test/deviation_detection_integration_test.dart
- Purpose/role: Unit tests for `isDeviationExceeded` using a concrete `RouteModel`.
- Test data: Constructs a `RouteModel` with `polylineDecoded` containing two `LatLng` points, `distance: 500.0`, `travelMode: 'METRO'`, and other required fields.
- Tests:
	- On-route point: calls `isDeviationExceeded(currentLocation, dummyRoute, false)` with a point near the segment and expects `false`.
	- Off-route point: calls the same function with a distant point and expects `true`.

### test/rapid_deviations_vm_test.dart
- Purpose/role: Stress test for route switching behavior under frequent deviations.
- Setup: Initializes binding; mocks `SharedPreferences`; sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`; clears `NotificationService.testRecordedAlarms`.
- Route setup: Registers two orthogonal routes (A east-west, B north-south) as lists of 30 points.
- Flow/assertions:
	- Builds a "weave" route list: along A, drift toward B, linger near B, then return.
	- Sets `testGpsStream` to `MockLocationProvider.positionStream` and calls `startTracking`.
	- Subscribes to `routeSwitchStream` and asserts at least one event occurred after playing the route.
- Timeout: 20 seconds.

### test/reroute_policy_continuity_test.dart
- Purpose/role: Unit test for `ReroutePolicy` decision stream behavior across cooldown changes.
- Setup: Ensures binding initialized; sets `TrackingService.isTestMode = true`.
- Flow/assertions:
	- Creates `ReroutePolicy(cooldown: 200ms, initialOnline: true)`.
	- Subscribes to `policy.stream` and collects `RerouteDecision` values.
	- Calls `onSustainedDeviation` at t0 and again at t0+50ms.
	- Calls `setCooldown(50ms)`, waits 80ms, then calls `onSustainedDeviation` again.
	- Asserts at least 3 decisions and checks the first is `shouldReroute == true`, second is `false`, and last is `true`.

### test/offline_coordinator_test.dart
- Purpose/role: Unit tests for `OfflineCoordinator.getRoute` selecting network vs cache sources.
- Fakes:
	- `FakeDirectionsProvider` counts calls and returns a preset payload.
	- `FakeCachePort` returns a preset `RouteCacheEntry?`.
- Test data: Uses an `okDirections` map with `status: 'OK'` and a single route containing `overview_polyline` and a leg duration.
- Tests:
	- Online path (`initialOffline: false`): expects provider calls == 1, result source `RouteSource.network`, and directions status 'OK'.
	- Offline with cache (`initialOffline: true` + cache entry): expects provider calls == 0 and result source `RouteSource.cache`.
	- Offline without cache: expects `getRoute(...)` throws `StateError`.

### test/offline_routing_guard_test.dart
- Purpose/role: Unit tests ensuring offline mode does not call network and either throws or serves cache.
- Fakes:
	- `_FakeCache` returns a preset `RouteCacheEntry?`.
	- `_NeverDirections` throws `StateError('Should not hit network when offline')` for any `getDirections` call.
- Tests:
	- Offline with no cache: constructs `OfflineCoordinator(initialOffline: true, cache: _FakeCache(null), directionsProvider: _NeverDirections())` and expects `getRoute(...)` throws `StateError`.
	- Offline with cache: provides a `RouteCacheEntry` and expects result `source == RouteSource.cache` and returned directions equal the cached entry directions.

### test/route_cache_policy_test.dart
- Purpose/role: Placeholder test.
- Content: Single `test('placeholder - route_cache_policy_test', ...)` asserting `true`.

### test/route_cache_transit_variant_test.dart
- Purpose/role: Placeholder test.
- Content: Single `test('placeholder - route_cache_transit_variant_test', ...)` asserting `true`.

### test/route_cache_integration_test.dart
- Purpose/role: Integration-style test for `DirectionService` caching behavior under `ApiClient.testMode`.
- Setup: Initializes binding; sets `ApiClient.testMode = true`; constructs `DirectionService`.
- Flow/assertions:
	- Calls `ds.getDirections(...)` once and expects status 'OK' (defaulting to 'OK' if missing).
	- Calls `ds.getDirections(...)` again with identical parameters, measures elapsed time in ms, expects status 'OK', and asserts `elapsedMs < 50` as a heuristic for cached/fast path.

### test/direction_service_behavior_test.dart
- Purpose/role: Unit tests covering `DirectionService.getDirections` behavior and `RouteCache` invalidation rules.
- Setup: Initializes binding; in `setUp` sets `ApiClient.testMode = true`, resets `ApiClient.directionsCallCount` and `ApiClient.lastDirectionsBody`, and calls `RouteCache.clear()`.
- Tests:
	- "Respects forceRefresh vs cached path (call count)": calls `getDirections` twice with the same params and asserts directions call count stays at 1; then calls again with `forceRefresh: true` and expects call count becomes 2.
	- "Transit variant included in request and cache key": calls `getDirections` with `transitMode: true` and asserts `ApiClient.lastDirectionsBody['mode'] == 'transit'` and `['transit_mode'] == 'rail'`.
	- "Cache TTL expiration invalidates entry": seeds `RouteCache` with an entry timestamp 30 minutes in the past and asserts `RouteCache.get(..., ttl: 5 minutes)` returns null.
	- "Origin deviation invalidates entry": seeds cache with a current timestamp entry and asserts `RouteCache.get` returns null when origin differs and `originDeviationMeters: 300`.

### test/direction_service_caching_test.dart
- Purpose/role: Placeholder test.
- Content: Single `test('placeholder - direction_service_caching_test', ...)` asserting `true`.

### test/eta_engine_test.dart
- Purpose/role: Unit tests for `EtaEngine.computeEta`.
- Test data: Defines a simple 3-point route along longitude 0.0 -> 0.02 (approx ~2.2km).
- Tests:
	- On-route, constant speed (10 m/s at start): asserts `etaSeconds` ~222 (±20), `remainingMeters` ~2220 (±50), and `sigmaEta > 0`.
	- Mid-route, higher speed (20 m/s at middle): asserts `etaSeconds` ~55 (±10) and `remainingMeters` ~1110 (±50).
	- Dwell detection: with near-zero speed, asserts `etaSeconds > 1000`.
	- Off-route snapping: with a position ~0.0001 latitude off the start, asserts `remainingMeters` close to full route distance.

### test/eta_utils_test.dart
- Purpose/role: Unit tests for `EtaUtils.etaRemainingSeconds`.
- Test: With `boundaries=[1000,2000,3500]` and `durations=[600,900,1200]`, calls `etaRemainingSeconds(progressMeters: 1500)` and expects ~1650.
- Test: With progress at or beyond end (`progressMeters: 2500` for boundaries ending at 2000), expects returned ETA is 0.

### test/hybrid_eta_time_test.dart
- Purpose/role: Integration-style test for time-mode alarms using route-event ETA targets and throttled API refresh.
- Setup: Initializes binding; mocks sensors method channel; sets `TrackingService.isTestMode = true`, `NotificationService.isTestMode = true`, and `ApiClient.testMode = true`; clears recorded alarms; resets a local `_mockTime`.
- Route setup: Calls `registerRouteRaw` with three points, `stepBounds=[560,1120]`, `stepStops=[0,6]`, and a single transfer `RouteEventBoundary` labeled 'Switch A' at 560m.
- Flow/assertions:
	- Starts tracking with `alarmMode: 'time'` and `alarmValue: 0.4` (24s).
	- Injects a position near the transfer and asserts a recorded alarm body contains 'Switch A'.
	- Injects a position near the destination and asserts a recorded alarm body contains 'Final Stop'.
	- Asserts `ApiClient.directionsCallCount <= 2` as a throttle check.

### test/maptracking_eta_distance_test.dart
- Purpose/role: Unit tests that combine route snapping with ETA/time-to-switch calculations.
- Test: "Computes ETA from directions step durations given snapped progress"
	- Builds a 3-point route polyline and stores `simplified_polyline` using `PolylineSimplifier.compressPolyline`.
	- Builds a directions map with two DRIVING steps (distance 1000/2000 and duration 600/1800).
	- Calls `SnapToRouteEngine.snap(...)` for a point halfway into the first segment and manually derives cumulative step boundaries/durations.
	- Calls `EtaUtils.etaRemainingSeconds(...)` and asserts the result is close to ~2100 seconds (±120).
- Test: "Detects transfer boundary and computes time-to-switch with simple speed"
	- Builds a directions map with two TRANSIT steps (line A then line B) and calls `TransferUtils.buildTransferBoundariesMeters(..., metroMode: true)`.
	- Snaps a point ~200m into the route, picks the next transfer boundary greater than current progress, computes time-to-switch at 10 m/s, and asserts it is between 60 and 120 seconds.

### test/stop_logic_engine_test.dart
- Purpose/role: Unit tests for `StopLogicEngine.calculateRemainingStops` and `StopLogicEngine.checkPreBoarding`.
- Test data: `stepBoundsMeters = [1000,2000,3000]`, `stepStopsCumulative = [2,5,8]`, and one transfer `RouteEventBoundary(meters: 1500, label: 'Switch Train')`.
- Remaining-stops tests:
	- Before switch (`progressMeters: 500`, `firedEventIndexes: {}`): asserts `targetName` contains 'Switch Train' and remaining stops ~2.5.
	- After switch (`progressMeters: 1800`, `firedEventIndexes: {0}`): asserts `targetName` contains 'Destination' and remaining stops ~3.6.
- Pre-boarding tests:
	- Approaching station: current position ~0.005 longitude from station and a far start position; asserts `shouldTrigger == true` and `shouldSuppress == false`.
	- Suppress if started near station: both current and start near station; asserts `shouldTrigger == false` and `shouldSuppress == true`.
	- Far from station: asserts `shouldTrigger == false`.

### test/metro_stops_prior_test.dart
- Purpose/role: Integration-style test for metro pre-boarding alert and stops-prior transfer alert in stop-alarm mode.
- Setup: Initializes binding; mocks `SharedPreferences`; mocks sensors method channel; sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`; clears recorded alarms; uses a `_mockTime` Position helper.
- Route setup: Builds `syntheticMetroDirections()` with one WALKING step then two TRANSIT steps (line A then line B) and registers via `registerRouteFromDirections`.
- Flow/assertions:
	- Starts tracking with `alarmMode: 'stops'`, `alarmValue: 2.0`.
	- Feeds multiple walking positions approaching the boarding station and waits/polls until a recorded alarm body contains 'Approaching metro station'.
	- Feeds positions at/near the station and then near the transfer, waits/polls until a recorded alarm body contains 'Upcoming transfer' or 'Station3' or 'Board transit'.
- Timeout: 20 seconds.

### test/transfer_utils_test.dart
- Purpose/role: Unit test for transfer detection when two TRANSIT steps occur consecutively and line IDs may be missing.
- Test data: Directions response steps: WALKING (1000m), TRANSIT (5000m, line name 'Green Line', arrival stop Majestic), TRANSIT (5000m, line name 'Purple Line'), WALKING (1000m).
- Assertions on `TransferUtils.buildRouteEvents(...)`:
	- Finds a 'Board transit' mode-change event at 1000m.
	- Finds a `transfer` event labeled 'Majestic' at 6000m.
	- Finds a 'Start walking' mode-change event at 11000m.

### test/complex_route_alarm_test.dart
- Purpose/role: Integration-style tests around stop-based alarms across multiple switch points and a destination/switch conflict case.
- Setup: Initializes binding; mocks `SharedPreferences`; mocks sensors method channel; sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`; clears recorded alarms; uses a `_mockTime` Position helper; `tearDown` calls `stopTracking` on a new `TrackingService` instance.
- Test: "Complex Route Alarm Logic: Switch vs Destination Conflict"
	- Registers a route via `registerRouteRaw` with 4 points, `stepBounds=[1100,4400,5500]`, `stepStops=[0,6,6]`, and two transfer `RouteEventBoundary`s labeled 'Metro Stn 1' and 'Metro Stn 2'.
	- Starts tracking with `alarmMode: 'stops'`, `alarmValue: 2.0`.
	- Injects a position near start and asserts a recorded alarm body contains 'Metro Stn 1'.
	- Injects a position near the second switch and asserts a recorded alarm body contains 'Metro Stn 2'.
	- Injects an additional position near the second switch/destination area and then stops tracking; this test does not include further expectations after the final position.
- Test: "Conflict Resolution: Destination beats Switch"
	- Registers a shorter route via `registerRouteRaw` with one transfer event at 1000m ('Switch Point') and destination 'Final Home'.
	- Starts tracking and injects a position near the end; inspects `NotificationService.testRecordedAlarms`.
	- Asserts an alarm for 'Final Home' is present and an alarm for 'Switch Point' is absent.

### test/mixed_mode_alarm_test.dart
- Purpose/role: Integration-style test for stop-based alarm behavior during a mixed walking + transit route.
- Setup: Initializes binding; mocks `SharedPreferences`; mocks sensors method channel; sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`; clears recorded alarms; uses a `_mockTime` Position helper.
- Route setup: `mixedModeDirections()` returns directions with WALKING step (~1571m) followed by TRANSIT step (~1571m) with departure at Station A and arrival at Station B.
- Flow/assertions:
	- Registers route via `registerRouteFromDirections` and starts tracking with `alarmMode: 'stops'`, `alarmValue: 2.0`.
	- Injects origin, then injects a position at (0.006,0.006) and waits.
	- Filters `NotificationService.testRecordedAlarms` for bodies containing 'Board' or 'Approaching' and asserts the filtered list is non-empty.
- Timeout: 10 seconds.

### test/mixed_mode_regression_test.dart
- Purpose/role: Regression test for mixed-mode stop alarms across a walking leg and a subsequent transit leg.
- Test scaffolding:
	- Defines `MockServiceInstance` implementing `ServiceInstance` with `invoke` capturing `triggerAlarm` calls and an `on(event)` stream map.
	- Defines `TrackingServiceTest` extension exposing `testInjectPosition` which calls `checkAlarmForTest(p, s)`.
- Route setup: Uses `registerRouteRaw` with points [start, boarding, transfer], `stepBounds=[1113,6678]`, `stepStops=[0,5]`, and two `RouteEventBoundary`s: a 'boarding' event at 1113m and a 'transfer' event at 6678m.
- Flow/assertions:
	- Starts tracking with `alarmMode: 'stops'`, `alarmValue: 2.0`.
	- Injects a position at start and asserts `NotificationService.testRecordedAlarms` is empty.
	- Injects a position ~200m into walking leg and asserts an alarm was recorded.
	- Injects a position just past boarding, clears alarms, then injects a position at ~3000m and asserts no alarm recorded.
	- Injects a position at ~5000m and asserts an alarm was recorded.

### test/event_alarm_overlap_test.dart
- Purpose/role: Scenario scaffold around event alarms with overlapping routes.
- Content:
	- Builds a directions-like map with steps including WALKING and multiple TRANSIT steps; calls `TransferUtils.buildStepBoundariesAndStops` and `TransferUtils.buildRouteEvents` and asserts a transfer event exists.
	- Calls `TrackingService.registerRouteFromDirections(...)` and `startTracking(...)` with `allowNotificationsInTest: true` and `useInjectedPositions: true`.
	- Creates a `TestServiceInstance` and invokes `startTracking` on it.
	- Final assertion is `expect(true, isTrue)`; no assertions are made about emitted notifications.

### test/event_alarm_progress_source_test.dart
- Purpose/role: Integration-style test asserting an upcoming event alarm is triggered when within threshold based on progress.
- Setup: Initializes binding; mocks `SharedPreferences`; mocks sensors method channel; sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`; clears recorded alarms; resets `_mockTime`.
- Route/directions setup:
	- Builds a straight route line (50 points) and compresses it as `simplified_polyline`.
	- Builds directions with steps: WALKING 200m, TRANSIT 800m (arrival_stop 'Xfer Point' with location), TRANSIT 1000m.
	- Assigns a `StreamController<Position>` stream to `testGpsStream`, registers route via `registerRouteFromDirections`, and starts tracking with `alarmMode: 'stops'`, `alarmValue: 1.0`, `useInjectedPositions: false`.
- Flow/assertions:
	- Feeds two progress positions (origin and midpoint), then feeds a position near the transfer.
	- After a delay, asserts `NotificationService.testRecordedAlarms` contains at least one body including 'Approaching' or 'Board'.
	- Cleans up: stops tracking, closes stream, clears globals and test flags.

### test/time_alarm_vm_test.dart
- Purpose/role: Smoke test for time-based alarms during motion.
- Setup: Initializes binding; mocks `SharedPreferences`; sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`; clears recorded alarms.
- Flow/assertions:
	- Uses `MockLocationProvider` as `testGpsStream` and starts tracking with `alarmMode: 'time'`, `alarmValue: 3.0` (minutes).
	- Plays a short route, waits briefly, and asserts `NotificationService.testRecordedAlarms.length <= 2`.
- Timeout: 10 seconds.
- Permissions: calls notification permission check on init via `permission_handler`.
- Theme persistence: reads/writes a boolean preference `gw_dark_mode` using SharedPreferences.
- Invariants captured:
	- Flutter bindings are ensured before Hive init.
	- `NavigationService.navigatorKey` must be set for any non-context navigation.
	- Hive box flush during pause must not throw if the box isn’t open.

### lib/screens/splash_screen.dart
- Purpose/role: Visual splash + initializes core services and selects the initial navigation target.
- Init sequencing: kicks off `_initializeServices()` and immediately runs `_checkStateAndNavigate()`; `_checkStateAndNavigate()` waits for `_initFuture` before deciding between restore vs fresh.
- Service init order (best-effort, errors logged): ApiClient → NotificationService → TrackingService.
- Restore decision:
	- If `TrackingStateStore.isAlarmFired()` is true, it calls `TrackingService.completeEndTracking(navigateHome: false)` then navigates to `/`.
	- Else if `TrackingStateStore.isActive()` is true, it navigates to `/preloadMap` with `{ nextRoute: /mapTracking }`.
	- Else after a 3s timer, it navigates to `/preloadMap` with `{ nextRoute: / }`.
- Map warm-up: always routes via `/preloadMap` rather than directly to `/` or `/mapTracking`.
- Invariants captured:
	- Navigation must be guarded by `mounted` checks.
	- `_navTimer` must be cancelled on dispose to prevent late navigation.

### lib/screens/otherimpservices/preload_map_screen.dart
- Purpose/role: Warm up the Google Maps platform view and then hand off navigation.
- Input contract: requires `arguments: Map<String, dynamic>`.
	- Optional: `lat`/`lng` (numbers) used for initial camera target; defaults to (37.422, -122.084) if absent.
	- Optional: `nextRoute` (string) to choose destination route; defaults to `/mapTracking`.
	- Optional: `nextArgs` (any) to pass to the next route.
- Handoff behavior:
	- On first `onMapCreated`, sets `_isMapReady = true`, then starts a 700ms timer.
	- After timer: `Navigator.pushReplacementNamed` to `nextRoute`.
		- Special-case: if `nextRoute == '/mapTracking'` and `nextArgs == null`, it passes through the original `arguments`.
		- Otherwise it navigates with `nextArgs`.
- State management: `_handoffTimer` is cancelled in `dispose`.
- Observability: always logs the passed arguments in `build()`.
- Invariants captured:
	- `onMapCreated` must only schedule handoff once (guarded by `_isMapReady`).
	- `mounted` is checked before state changes and navigation.

### lib/services/notification_service.dart
- Purpose/role: Initializes notification plugin + channels, displays journey progress + alarm notifications, and routes notification responses to tracking actions.
- Core model: `NotificationActionOutcome` + `classifyAction(actionId, payload)`.
	- `IGNORE` becomes either `muteJourney` (when payload starts with `journey`) or `cancelAlarm`.
	- `STOP_ALARM`, `END_TRACKING`, `RESUME_TRACKING`, `DISMISS_ALARM` map one-to-one.
- Response handling:
	- Foreground: `onDidReceiveNotificationResponse` → `handleNotificationResponse(..., allowNavigation: true)`.
		- If `actionId == null`: navigates to `/mapTracking` using `NavigationService.navigatorKey.currentState.pushNamedAndRemoveUntil`.
		- Else: runs action handlers that call into `TrackingService` and/or `cancelAlarm()`.
	- Background: `notificationTapBackground` calls `handleNotificationResponse(..., allowNavigation: false)` (navigation suppressed).
- Notification IDs: alarm is `0`; progress is `888`; also cancels `8888` as a safety.
- Channels ensured on Android init:
	- `geowake_alarm_channel_v3` (Importance.max, vibration pattern, `playSound=false`).
	- `geowake_tracking_channel_v2` (default importance).
	- `geowake_tracking_channel` (legacy/service channel).
- Alarm notification (`showWakeUpAlarm`):
	- Uses full-screen intent + public visibility + category `alarm` + `ongoing=true`.
	- Adds `additionalFlags=[4]` (FLAG_INSISTENT) and vibration pattern.
	- Action buttons depend on `allowContinueTracking`:
		- true → STOP_ALARM (no UI) + END_TRACKING (shows UI)
		- false → END_TRACKING only
	- Persists “pending alarm” keys in SharedPreferences (`pending_alarm_flag/title/body/allow`).
	- Starts AlarmPlayer and shows notif in parallel (`Future.wait`).
- Journey progress (`showJourneyProgress`):
	- Uses channel `geowake_tracking_channel_v2`, `ongoing=true`, and a 0–1000 progress bar.
	- If `isTracking == true`, it consults `TrackingStateStore.notificationsMuted()` and skips if muted.
	- Action buttons depend on `isTracking`:
		- true → IGNORE (no UI) + END_TRACKING (shows UI)
		- false → RESUME_TRACKING + END_TRACKING (both show UI)
	- Persists a `TrackingProgressPayload` to `TrackingStateStore`.
- Test hooks: `isTestMode`, `testOnShowWakeUpAlarm`, and `testRecordedAlarms` allow tests to observe alarm triggers without platform calls.
- Invariants captured:
	- Alarm notification should not re-enter concurrently (`_alarmCurrentlyShowing` gate).
	- Progress payload and muted flag are the persistence coupling between notifications and tracking state.

### lib/services/tracking_state_store.dart
- Purpose/role: SharedPreferences-backed persistence for session resumption and notification state.
- Data models:
	- `TrackingSnapshot` persists destination/alarm settings and (optionally) directions JSON for restore.
	- `TrackingProgressPayload` persists the last journey notification title/subtitle/progress/isTracking.
- Key schema (v1):
	- `tracking_active_v1` (bool)
	- `tracking_snapshot_v1` (json string)
	- `tracking_notifications_muted_v1` (bool; key removed when false)
	- `gw_progress_payload_v1` (json string)
	- `tracking_alarm_fired_v1` (bool)
- Caching: uses a static `_cachedPrefs` and returns it from `_prefs()`.
- Freshness/cross-isolate note: only `notificationsMuted()` calls `prefs.reload()` before read.
- Error handling: JSON parse failures return `null` snapshot/payload.
- Invariants captured:
	- Key names must remain stable across foreground/background.
	- Snapshot must be safe to decode even after schema drift (best-effort defaults).

### lib/services/trackingservice.dart
- Purpose/role: Orchestrates tracking in foreground + background isolate, owns route/deviation pipelines and alarm triggering.
- Foreground API surface (observed):
	- `initializeService()` configures `flutter_background_service` with `_onStart` and uses the tracking notification channel/id.
	- `startTracking(...)` ensures service running, clears muted flag, shows an initial journey progress notification, then invokes `startTracking` into background.
	- `stopTracking(...)` stops alarm/vibration in foreground and invokes `stopTracking` into background (or runs `_onStop()` in test mode).
	- `muteJourneyNotifications()` sets muted flag and cancels journey progress.
	- `resumeFromNotification()` clears muted flag and reconstructs journey progress from persisted payload.
	- `completeEndTracking(...)` cancels notifications, clears snapshot, resets active/alarmFired/muted flags, stops tracking, then optionally navigates to `/` via `NavigationService.navigatorKey`.
- Background isolate lifecycle:
	- `_onStart(service, initialData)` calls `WidgetsFlutterBinding.ensureInitialized()` and registers service listeners before background init.
	- Listeners observed: `stopService`, `startTracking`, `useInjectedPositions`, `injectPosition`, `stopTracking`, `stopAlarm`, `registerRoute`.
	- After listeners: attempts `NotificationService.initialize()` and connects a `SimulationClient`.
	- If `initialData` provided, applies params and starts location stream (test path).
- Position loop + periodic tick:
	- `startLocationStream(...)` chooses stream source (simulation/injected/real GPS) and listens for positions.
	- Per position: updates ETA estimates, feeds active manager, calls `_checkAndTriggerAlarm(...)`, and invokes `updateLocation` back to the service.
	- A periodic timer calls `_updateNotification(service)` even when GPS is silent.
- Notification update strategy (background):
	- `_updateNotification(...)` prefers registry route entries with `lastProgressMeters` (most recent `lastUsed`), computes progress vs `lengthMeters`.
	- Fallback: straight-line remaining distance if registry state is insufficient.
- Alarm triggering (high-level):
	- `_checkAndTriggerAlarm(...)` supports `distance`, `time` (with eligibility gating), and `stops` semantics.
	- Event boundaries (`_routeEvents`) are evaluated for transfers/mode changes; destination can suppress event alarms under certain conditions.
	- Destination alarm triggers a `fireAlarm` invoke (or `NotificationService.showWakeUpAlarm` in test mode) and then invokes `stopTracking`.
- Route registration pipeline:
	- `registerRoute(...)` upserts routes into `_registry`, initializes `_activeManager`/deviation/reroute helpers, bridges state streams, and (when in foreground) forwards `registerRoute` to background via `_service.invoke`.
	- `registerRouteFromDirections(...)` extracts polyline, stop boundaries, route events, “first transit boarding” heuristics, and visualization segments/switch points, then calls `registerRoute(...)`.
- Invariants captured:
	- Listener registration is intended to precede any long init work.
	- `_onStop()` cancels all subscriptions/timers and disposes managers.
	- Background notification updates are gated by `TrackingStateStore.notificationsMuted()` inside `NotificationService.showJourneyProgress`.

### lib/screens/maptracking.dart
- Purpose/role: Live map screen that renders route geometry, shows remaining distance/ETA, and provides STOP ALARM + END TRACKING controls. It can also restore a session from persisted snapshot.
- Entry argument contract: in `didChangeDependencies` it reads `ModalRoute.of(context)?.settings.arguments`.
	- If args are `null`, it attempts restore via `_restoreState()` ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L59-L90)).
	- If required fields are missing (`lat/lng/destination/directions`), it shows an error dialog and then pops ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L72-L113)).
	- When args are present, it populates destination, user location, and `directions`, then calls `_processDirections(...)` and starts location updates ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L114-L156)).
- Restore path: `_restoreState()` checks `TrackingStateStore.isActive()` and loads `TrackingSnapshot`.
	- If not active or snapshot is null, it navigates to `/` ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L191-L206)).
	- On success, it sets destination + flags + `directions`, sets markers, processes directions, adjusts camera, starts location updates, and re-subscribes to TrackingService streams ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L207-L279)).
- Route rendering: `_processDirections(...)` builds segmented polylines via `DirectionService.buildSegmentedPolylines(...)` for both metro and non-metro flows (fallback to overview polyline if segmentation is empty) ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L280-L363)).
- Local ETA/distance computation (UI-only): `_startLocationUpdates()` uses `PowerPolicyManager.forBatteryLevel(...)` to choose a `distanceFilter`, listens to `Geolocator.getPositionStream`, snaps to `_routePoints` via `SnapToRouteEngine.snap(...)`, computes remaining meters as `routeLength - progress`, and uses `EtaUtils.etaRemainingSeconds(...)` if step durations exist (else speed-based fallback) ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L364-L503)).
	- It also derives a switch countdown using `_transferBoundariesMeters` if present ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L450-L503)).
- TrackingService subscriptions:
	- `routeSwitchStream` is used only to show a SnackBar (“Switched route...”) ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L138-L156)).
	- `activeRouteStateStream` updates `_etaText`, `_distanceText`, and `_switchNotice` using `remainingMeters` with a fixed fallback speed (12 m/s) ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L153-L189)).
- Navigation/back behavior: wrapped in `PopScope(canPop: false)`, so system back is disabled while on this screen ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L629-L639)).
- STOP ALARM button:
	- Visible when `AlarmPlayer.isPlaying` is true; it calls `AlarmPlayer.stop()` and invokes `stopAlarm` on `FlutterBackgroundService()` ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L792-L836)).
- END TRACKING button:
	- Calls `AlarmPlayer.stop()`, then `TrackingService().completeEndTracking()`, then performs a local `Navigator.pushNamedAndRemoveUntil('/', ...)` fallback ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L840-L894)).

### lib/screens/homescreen.dart
- Purpose/role: Destination entry (search + map pin), mode/threshold selection (time vs distance vs stops), directions fetch (online/offline coordinator), and tracking start that persists a snapshot and navigates into the warm-up map flow.
- Startup behavior:
	- On init, starts connectivity monitoring and forwards online/offline to `TrackingService().setOnline(...)` ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L60-L86)).
	- Defers building the `GoogleMap` widget until after first frame (`_deferHomeMapBuild`) and uses last-known then fresh location for initial marker ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L88-L141), [lib/screens/homescreen.dart](lib/screens/homescreen.dart#L656-L697)).
	- If `TrackingStateStore.isActive()` is true, it pushes `/mapTracking` via `Navigator.of(context).pushReplacementNamed('/mapTracking')` (no `/preloadMap` in this path) ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L142-L150)).
- Destination selection:
	- Text search uses `PlacesService.fetchAutocompleteResults` merged with recent-location matches; selecting a suggestion fetches place details and saves to recents keyed by `place_id` ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L268-L371)).
	- Map tap sets destination via reverse geocode (`ApiClient.instance.geocode(latlng: ...)`) and stores as selected location; single-tap is delayed to allow double-tap zoom detection ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L177-L233)).
	- Marker for selected destination is draggable; drag updates lat/lng in `_selectedLocation` but does not reverse geocode a new description ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L373-L410)).
- Mode + threshold input:
	- UI uses a switch labeled “Time” vs “Distance/Stops” (if metro enabled, distance mode displays as “Stops”) and exposes both slider and manual dialog entry for the selected threshold ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L783-L1022)).
- “Wake Me!” pressed:
	- Requires `_selectedLocation` and then requests essential permissions via `PermissionService.requestEssentialPermissions()` ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L444-L481)).
	- Fetches current location with `_getCurrentLocation()` (fresh high-accuracy fix with fallback to last-known) ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L589-L618)).
	- If metro mode is enabled, validates a metro route via `MetroStopService.validateMetroRoute(...)` and may adjust the destination to the closest stop ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L489-L529)).
	- Fetches directions via `OfflineCoordinator.getRoute(...)`, passing threshold derived from current mode selection ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L711-L754)).
	- Determines alarm mode/value:
		- default: `distance` (km) or `time` (minutes)
		- special-case: if metro mode and distance-mode UI selected, it sends `alarmMode='stops'` with `alarmValue=_stopsSliderValue` ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L541-L559)).
	- Starts tracking first via `TrackingService.startTracking(...)` and then registers the route via `registerRouteFromDirections(...)` ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L563-L601)).
	- Persists a `TrackingSnapshot` (including `directions`) via `TrackingStateStore.saveSnapshot(...)` and navigates with `Navigator.pushReplacementNamed(context, '/preloadMap', arguments: mapArgs)` ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L605-L618)).
- Disposal:
	- Cancels `_connectivitySubscription` and `_debounce`; disposes controllers/focus node. Battery state listener is attached via `onBatteryStateChanged.listen(...)` without a stored subscription for cancellation ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L235-L259), [lib/screens/homescreen.dart](lib/screens/homescreen.dart#L756-L774)).

### lib/services/active_route_manager.dart
- Purpose/role: Chooses an “active” route among routes in `RouteRegistry` by snapping the current raw position to nearby candidate routes and switching only after sustained evidence.

- Data model:
	- Emits `ActiveRouteState` containing `activeKey`, snapped point, lateral offset, progress meters, remaining meters, and optional pending-switch countdown (`pendingSwitchToKey`, `pendingSwitchInSeconds`) ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L16-L33)).
	- Emits `RouteSwitchEvent(fromKey, toKey, at)` when a switch occurs ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L8-L14)).
- Configuration defaults:
	- `sustainDuration = 6s` (candidate must remain best for this duration before switching)
	- `switchMarginMeters = 50` (candidate must be this much better in lateral offset)
	- `postSwitchBlackout = 5s` (suppresses immediate flip-flops) ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L55-L60)).
- Activation: `setActive(key)` sets `_activeKey` and starts the blackout timer immediately ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L62-L75)).
- Per-position ingestion: `ingestPosition(rawPosition)`
	- Snaps to the active route first and updates the registry session state (`lastSnapIndex`, `lastProgressMeters`) for that route ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L77-L89)).
	- Evaluates nearby candidates from `registry.candidatesNear(... radiusMeters: 1200, maxCandidates: 3)` and selects a “best” based on smaller lateral offset by at least `switchMarginMeters` plus a lightweight consistency check (`_headingAgreement` implemented as “progress not regressing beyond 10m” and returns nominal 0.5) ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L91-L124), [lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L214-L227)).
	- Switching requires the same candidate to remain best for `sustainDuration` and only if not in blackout; on switch, resets timers and emits `RouteSwitchEvent` ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L115-L144)).
	- State emission uses snap/progress corresponding to the actual active key. It explicitly avoids mixing candidate snap/progress with active route metrics, only using the candidate snap after a real switch has occurred ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L145-L213)).
	- Remaining meters is computed as `(activeEntry.lengthMeters - progress).clamp(0, inf)` using the registry entry for the current active key ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L169-L175)).
	- Pending switch countdown is derived from `sustainDuration - elapsed` and clamped into `[0, sustainDuration]` while a candidate is being sustained (and not in blackout) ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L176-L195)).
- Disposal: closes both broadcast stream controllers ([lib/services/active_route_manager.dart](lib/services/active_route_manager.dart#L228-L231)).

### pubspec.yaml
- Purpose/role: Declares the Flutter package name (`geowake2`), version (`1.0.0+1`), SDK constraint (`>=3.7.0 <4.0.0`), dependencies/dev_dependencies, and asset list.
- Declared runtime dependencies include: `flutter_local_notifications`, `geolocator`, `flutter_background_service` (+ android impl), `hive`/`hive_flutter`, `permission_handler`, `google_maps_flutter`, `google_places_flutter`, `google_mobile_ads`, `in_app_purchase`, `http`, `sensors_plus`, and `web_socket_channel`.
- Assets: includes `assets/geowake.png` and the directory `assets/ringtones/`.
- Tooling configuration blocks included: `flutter_native_splash` and `flutter_icons`.

### analysis_options.yaml
- Purpose/role: Dart analyzer configuration; includes `package:flutter_lints/flutter.yaml`.
- Linter rules: no custom rules are enabled/disabled (only commented examples present).

### android/build.gradle
- Purpose/role: Project-level Gradle file configuring repositories and build output directories.
- Repositories: `google()` and `mavenCentral()`.
- Build output: sets `rootProject.buildDir = '../build'` and maps subproject build dirs under it.
- Adds a `clean` task that deletes the root build directory.

### android/gradle.properties
- Purpose/role: Gradle properties.
- Config flags present: `org.gradle.jvmargs=-Xmx1536M`, `android.useAndroidX=true`, `android.enableJetifier=true`.

### android/app/build.gradle
- Purpose/role: Android app module Gradle config.
- Plugins: `com.android.application`, `kotlin-android`, and `dev.flutter.flutter-gradle-plugin`.
- SDK levels: `compileSdkVersion 35`, `minSdkVersion 23`, `targetSdkVersion 34`.
- App identity: `namespace` and `applicationId` are both `com.example.geowake2`.
- Manifest placeholders:
	- `googleMapsApiKey` is loaded from `key.properties` (property `googleMapsApiKey`) or falls back to a literal string default.
	- `applicationName` is set to `io.flutter.app.FlutterApplication`.
- Release build type: `minifyEnabled true` and `shrinkResources true`; uses default optimized proguard file + `proguard-rules.pro`.
- Desugaring: `coreLibraryDesugaringEnabled true` and dependency `com.android.tools:desugar_jdk_libs:2.1.4`.

### android/app/proguard-rules.pro
- Purpose/role: Proguard/R8 rules file for release builds.
- Content: contains `dontwarn` and `keep` for `com.google.android.gms.internal.location.zze`.

### android/app/src/main/AndroidManifest.xml
- Purpose/role: Main Android manifest declaring permissions, activity, services, and metadata.
- Permissions declared include: INTERNET, FINE/COARSE/BACKGROUND location, FOREGROUND_SERVICE, POST_NOTIFICATIONS, FOREGROUND_SERVICE_LOCATION, ACTIVITY_RECOGNITION, HIGH_SAMPLING_RATE_SENSORS, USE_FULL_SCREEN_INTENT.
- Application:
	- Label `geowake2` and icon `@mipmap/ic_launcher`.
	- `android:enableOnBackInvokedCallback="true"`.
	- Meta-data `com.google.android.gms.ads.APPLICATION_ID` is set to a literal string value.
	- Meta-data `com.google.android.geo.API_KEY` uses placeholder `${googleMapsApiKey}`.
- MainActivity:
	- `exported=true`, `launchMode=singleTop`, `showWhenLocked=true`, `turnScreenOn=true`.
	- Config changes include orientation/keyboard/screen/locale/layoutDirection/fontScale/density/uiMode.
	- Launcher intent-filter with MAIN/LAUNCHER.
- Background service:
	- Declares `id.flutter.flutter_background_service.BackgroundService` with `android:foregroundServiceType="location"`.
- Queries section includes PROCESS_TEXT intent for `text/plain`.

### android/app/src/debug/AndroidManifest.xml
- Purpose/role: Debug manifest overlay.
- Content: declares INTERNET permission and includes comments describing its role for development tooling.

### android/app/src/profile/AndroidManifest.xml
- Purpose/role: Profile manifest overlay.
- Content: declares INTERNET permission and includes comments describing its role for development tooling.

### ios/Runner/Info.plist
- Purpose/role: iOS Info.plist for the Runner app.
- App naming/version keys use build variables: `$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(FLUTTER_BUILD_NAME)`, `$(FLUTTER_BUILD_NUMBER)`.
- Declares usage descriptions:
	- `NSLocationWhenInUseUsageDescription`
	- `NSLocationAlwaysAndWhenInUseUsageDescription`
	- `NSMotionUsageDescription`
	- `NSUserTrackingUsageDescription`
	- `NSUserNotificationUsageDescription`
- Supported orientations include portrait + landscape (and additional portrait upside-down on iPad).

### macos/Runner/Info.plist
- Purpose/role: macOS Info.plist for the Runner app.
- Bundle identifiers/versions are driven by build variables (`$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(FLUTTER_BUILD_NAME)`, `$(FLUTTER_BUILD_NUMBER)`).
- Declares `LSMinimumSystemVersion` from `$(MACOSX_DEPLOYMENT_TARGET)`.

### macos/Runner/DebugProfile.entitlements
- Purpose/role: macOS entitlements for debug/profile builds.
- Entitlements: enables app sandbox, allows JIT (`com.apple.security.cs.allow-jit`), and enables network server (`com.apple.security.network.server`).

### macos/Runner/Release.entitlements
- Purpose/role: macOS entitlements for release builds.
- Entitlements: enables app sandbox (`com.apple.security.app-sandbox`).

### web/manifest.json
- Purpose/role: PWA manifest for the web build.
- Sets `name`/`short_name` to `geowake2`, `display` to `standalone`, `orientation` to `portrait-primary`, and defines four icons (including maskable variants).

### web/index.html
- Purpose/role: Web entrypoint HTML for the Flutter web build.
- Includes the base-href placeholder (`$FLUTTER_BASE_HREF`) and standard meta tags for viewport and iOS web app capability.
- Includes a Google Maps JavaScript API `<script>` tag with a literal key in the URL query string.
- Loads `flutter_bootstrap.js` asynchronously.

### windows/runner/CMakeLists.txt
- Purpose/role: Windows runner build rules.
- Runner target includes `Runner.rc` and `runner.exe.manifest` plus generated plugin registrant.
- Defines version macros from FLUTTER_VERSION variables for compilation.

### windows/runner/Runner.rc
- Purpose/role: Windows resources for icon + version metadata.
- Icon resource points to `resources\\app_icon.ico`.
- Version info strings include `CompanyName` = `com.example` and `ProductName`/`FileDescription` = `geowake2`.

### windows/runner/runner.exe.manifest
- Purpose/role: Windows application manifest.
- Declares DPI awareness `PerMonitorV2` and declares Windows 10/11 compatibility GUID.

### linux/CMakeLists.txt
- Purpose/role: Linux project-level build configuration and install bundle layout.
- Declares `BINARY_NAME` as `geowake2` and `APPLICATION_ID` as `com.example.geowake2`.
- Installs bundle under a build-directory "bundle" with separate `data/` and `lib/` directories and copies `flutter_assets` and plugin-bundled libraries.

### linux/runner/CMakeLists.txt
- Purpose/role: Linux runner build rules.
- Builds the executable from `main.cc`, `my_application.cc`, and the generated plugin registrant.
- Links against GTK and the Flutter Linux GTK library.

### linux/flutter/CMakeLists.txt
- Purpose/role: Flutter-managed CMake glue for Linux.
- Notes in file indicate it should not be edited and loads `ephemeral/generated_config.cmake`.
- Defines `flutter_assemble` custom command that invokes Flutter tool backend.

### ios/Runner.xcodeproj/project.pbxproj
- Purpose/role: iOS Xcode project definition for the Flutter Runner app + RunnerTests.
- Project metadata: `objectVersion = 54`, `compatibilityVersion = "Xcode 9.3"`, `LastUpgradeCheck = 1510`.
- Targets:
	- `Runner` (application) with phases including:
		- Run Script: calls `xcode_backend.sh build`.
		- Thin Binary: calls `xcode_backend.sh embed_and_thin`.
		- Sources include `AppDelegate.swift` and `GeneratedPluginRegistrant.m`.
		- Resources include `LaunchScreen.storyboard`, `Main.storyboard`, `Assets.xcassets`, and `Flutter/AppFrameworkInfo.plist`.
	- `RunnerTests` (unit-test bundle) with `RunnerTests.swift` in Sources and a dependency on `Runner`.
- Key Runner build settings (Debug/Release/Profile configs shown):
	- `INFOPLIST_FILE = Runner/Info.plist`.
	- `PRODUCT_BUNDLE_IDENTIFIER = com.example.geowake2`.
	- `CURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)"` and `VERSIONING_SYSTEM = apple-generic`.
	- `IPHONEOS_DEPLOYMENT_TARGET = 12.0`.
	- `ENABLE_BITCODE = NO`.
	- `SWIFT_VERSION = 5.0` and `SWIFT_OBJC_BRIDGING_HEADER = Runner/Runner-Bridging-Header.h`.
	- Code signing identity includes `"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "iPhone Developer"` in the project-level configs.
- RunnerTests build settings: uses `GENERATE_INFOPLIST_FILE = YES`, `MARKETING_VERSION = 1.0`, and `TEST_HOST` points at the built Runner executable.

### macos/Runner.xcodeproj/project.pbxproj
- Purpose/role: macOS Xcode project definition for the Flutter macOS Runner app, RunnerTests, and a Flutter Assemble aggregate target.
- Project metadata: `objectVersion = 54`, `compatibilityVersion = "Xcode 9.3"`, `LastUpgradeCheck = 1510`.
- Targets:
	- `Runner` (application) with Sources including `AppDelegate.swift`, `MainFlutterWindow.swift`, and `GeneratedPluginRegistrant.swift`.
	- `RunnerTests` (unit-test bundle) depends on `Runner` and uses `TEST_HOST` pointing at `geowake2.app`.
	- `Flutter Assemble` (aggregate) runs `macos_assemble.sh` with xcfilelists and touches `Flutter/ephemeral/tripwire`.
- Shell script build phases observed:
	- Runner target includes a shell script that writes `$PRODUCT_NAME.app` to `Flutter/ephemeral/.app_filename` and runs `macos_assemble.sh embed`.
	- Aggregate target runs `macos_assemble.sh` using `FlutterInputs.xcfilelist`/`FlutterOutputs.xcfilelist`.
- Capability wiring (TargetAttributes): `SystemCapabilities` includes `com.apple.Sandbox` with `enabled = 1`.
- Build settings highlights:
	- `INFOPLIST_FILE = Runner/Info.plist`.
	- `MACOSX_DEPLOYMENT_TARGET = 10.14`.
	- `CODE_SIGN_ENTITLEMENTS` maps debug/profile to `Runner/DebugProfile.entitlements` and release to `Runner/Release.entitlements`.
	- RunnerTests uses `GENERATE_INFOPLIST_FILE = YES` and `MARKETING_VERSION = 1.0`.

### test/flutter_test_config.dart
- Purpose/role: Defines `testExecutable(...)` which runs before any tests to initialize Hive into a per-run temp directory.
- Hive init: creates a system temp dir with prefix `geowake2_test_hive_` and calls `Hive.init(tmpDir.path)`.
- Cleanup: always calls `Hive.close()` in `finally`, then attempts to delete the temp directory recursively (errors are ignored).

### test/minimal_test.dart
- Purpose/role: Minimal unit test that instantiates `TrackingService` and asserts it is non-null.
- Imports: depends on `package:geowake2/services/trackingservice.dart`.

### test/log_helper.dart
- Purpose/role: Convenience wrappers around `print(...)` for section/step/info/pass/warn messages.
- Output content: includes unicode glyphs (e.g., arrows/checkmarks/warning) embedded in the printed strings.

### test/mock_location_provider.dart
- Purpose/role: Provides a fake GPS provider that emits `geolocator.Position` values for a supplied route (`List<LatLng>`).
- Stream model: maintains a `StreamController<Position>`; consumers read `positionStream`.
- Playback behavior: `playRoute(...)` iterates route points; for each point it constructs a `Position` with:
	- fixed `accuracy: 5.0`, `speed: 15.0`, `speedAccuracy: 1.0`, and zeroed altitude/heading fields,
	- `timestamp: DateTime.now()` at emission time.
- Timing: waits 50ms between emissions; after completion it closes the controller.
- Dispose: `dispose()` calls `_controller.close()`.

### test/test_routes.dart
- Purpose/role: Defines predefined LatLng sequences for tests.
- Exposed data: `TestRoutes.majesticToLalbagh` is a `static const List<LatLng>` containing 11 points.

### test/app_config_url_alignment_test.dart
- Purpose/role: Verifies `AppConfig.serverBaseUrl` invariants for non-localhost release defaults and alignment with `ApiClient.baseUrl` host.
- Assertions:
	- `AppConfig.serverBaseUrl` must not contain `localhost` or `127.0.0.1`.
	- Parsed host of `AppConfig.serverBaseUrl` equals parsed host of `ApiClient.baseUrl`.

### test/playground_bridge_flag_test.dart
- Purpose/role: Verifies the playground bridge is disabled when running under the Flutter test environment.
- Behavior asserted: `PlaygroundBridgeConfig.enabled` is `false` after `TestWidgetsFlutterBinding.ensureInitialized()`.

### test/places_session_token_test.dart
- Purpose/role: Verifies `PlacesService` reuses the same Places session token across autocomplete and place details calls.
- Setup: sets `ApiClient.testMode = true` and instantiates `PlacesService`.
- Behavior asserted: request bodies captured by `ApiClient.lastAutocompleteBody['sessiontoken']` and `ApiClient.lastPlaceDetailsBody['sessiontoken']` are equal (and the first is non-null).

### test/simplified_polyline_present_test.dart
- Purpose/role: Verifies `DirectionService.getDirections(...)` injects a `simplified_polyline` string into the returned directions payload.
- Setup: enables `ApiClient.testMode = true`; uses `DirectionService()`; requests directions with `transitMode: false` and `forceRefresh: true`.
- Assertions:
	- `directions['routes']` is non-empty and `routes.first` contains key `simplified_polyline`.
	- `routes.first['simplified_polyline']` is a `String`.
	- Uses `log_helper.dart` helpers for log output.

### test/notification_action_classification_test.dart
- Purpose/role: Verifies `NotificationService.classifyAction(actionId, payload)` maps notification actions to `NotificationActionOutcome`.
- Assertions include:
	- `('IGNORE', 'journey_active')` -> `muteJourney`.
	- `('IGNORE', 'open_alarm:1')` -> `cancelAlarm`.
	- `('RESUME_TRACKING', 'journey_paused')` -> `resumeTracking`.
	- `('END_TRACKING', 'journey_active')` -> `endTracking`.
	- `('STOP_ALARM', null)` -> `stopAlarm`.
	- `('DISMISS_ALARM', null)` -> `dismissAlarm`.
	- `(null, 'open_alarm:0')` -> `none` (comment notes null action handled elsewhere).
	- `('UNKNOWN', null)` -> `none`.

### test/notification_service_test.dart
- Purpose/role: Verifies NotificationService test-only hooks record wake-up alarm invocations when `NotificationService.isTestMode = true`.
- Setup: assigns `NotificationService.testOnShowWakeUpAlarm` callback and clears `NotificationService.testRecordedAlarms`.
- Behavior asserted: calling `NotificationService().showWakeUpAlarm(...)` increments the hook count and appends a record with expected fields (`title`, `allow`).
- Cleanup: resets `isTestMode` to false, clears hook, clears recorded alarms.

### lib/services/route_registry.dart
- Purpose/role: In-memory registry of recent routes (`RouteEntry`) with cached geometry-derived metrics and per-session snap/progress fields used by snapping/ETA/reroute logic.
- `RouteEntry` contents:
	- Identifiers: `key` (typically cache key), `mode` (`driving`/`transit`), `destinationName`.
	- Geometry: `points` (simplified polyline) plus derived fields computed at construction: `bbox` (LatLngBounds), `lengthMeters` (geodesic polyline length), `cumMeters` (cumulative meters along points) ([lib/services/route_registry.dart](lib/services/route_registry.dart#L5-L140)).
	- Usage tracking: `createdAt`, `lastUsed`, `usageCount`.
	- Session-only fields: `lastSnapIndex`, `lastProgressMeters`.
- Proximity filter: `RouteEntry.isNear(p, radiusMeters)` uses a padded bounding-box check (approx degree padding by latitude) and then a distance-to-bbox-center check with factor `2.5` to be permissive after passing the bbox prefilter ([lib/services/route_registry.dart](lib/services/route_registry.dart#L72-L114)).
- Registry ordering: `RouteRegistry.entries` returns values sorted by `lastUsed` descending ([lib/services/route_registry.dart](lib/services/route_registry.dart#L146-L149)).
- Upsert semantics:
	- If an entry with the same key already exists, `upsert` replaces the stored entry with a newly constructed `RouteEntry` that uses the new geometry while preserving `createdAt` and incrementing `usageCount`; `lastUsed` is set to now; session fields prefer new values if provided, else keep existing ([lib/services/route_registry.dart](lib/services/route_registry.dart#L150-L171)).
	- New keys are inserted and then capacity-based eviction runs (default capacity 8) based on `lastUsed` ordering ([lib/services/route_registry.dart](lib/services/route_registry.dart#L141-L201)).
- Session updates: `updateSessionState(key, lastSnapIndex, lastProgressMeters)` mutates the stored entry’s session-only fields if present ([lib/services/route_registry.dart](lib/services/route_registry.dart#L180-L190)).
- Candidate selection: `candidatesNear(p, radiusMeters: 1200, maxCandidates: 3)` iterates entries in recency order and returns the first N whose `isNear(...)` returns true ([lib/services/route_registry.dart](lib/services/route_registry.dart#L202-L216)).

### lib/services/snap_to_route.dart
- Purpose/role: Provides the core “snap a point to a polyline” primitive used by UI and services to compute a snapped location, lateral offset distance, progress-along-route meters, and the best segment index.
- `SnapResult` fields:
	- `snappedPoint` (LatLng on the polyline)
	- `lateralOffsetMeters` (geodesic distance from the raw point to the snapped point)
	- `progressMeters` (meters along the polyline to the snapped point)
	- `segmentIndex` (index i such that snapped point lies on segment i→i+1) ([lib/services/snap_to_route.dart](lib/services/snap_to_route.dart#L5-L16)).
- Search behavior:
	- If `hintIndex` is null, searches all segments.
	- If `hintIndex` provided, searches only `[hintIndex - searchWindow, hintIndex + searchWindow]` clamped to valid segment indices (`0..polyline.length-2`) ([lib/services/snap_to_route.dart](lib/services/snap_to_route.dart#L34-L41)).
	- Default `searchWindow` is 20 (callers commonly pass 30).
- Progress computation:
	- If `precomputedCumMeters` is provided, it is used as `cum` distances; otherwise cum distances are computed locally by summing consecutive `Geolocator.distanceBetween` distances for each polyline edge ([lib/services/snap_to_route.dart](lib/services/snap_to_route.dart#L49-L58)).
	- For each candidate segment i, projects onto segment (clamped to endpoints), computes `bestProgress = cum[i] + dist(A, proj)` when that projection yields the smallest distance ([lib/services/snap_to_route.dart](lib/services/snap_to_route.dart#L60-L68)).
- Projection math:
	- `_projectPointOnSegment` uses an equirectangular projection around the segment latitude: longitude scaled by `111320 * cos(lat)` and latitude by `110540`, then computes a clamped scalar projection `t` onto AB in that local meter space and converts back to lat/lon ([lib/services/snap_to_route.dart](lib/services/snap_to_route.dart#L80-L116)).
- Edge cases:
	- If polyline has <2 points, returns `lateralOffsetMeters = infinity`, `progressMeters = 0`, and `segmentIndex = 0` with `snappedPoint = point` ([lib/services/snap_to_route.dart](lib/services/snap_to_route.dart#L27-L33)).

### lib/services/eta_utils.dart
- Purpose/role: Computes an ETA (seconds remaining) from a progress-along-route value and per-step (distance, duration) data extracted from directions.
- Core API: `EtaUtils.etaRemainingSeconds(progressMeters, stepBoundariesMeters, stepDurationsSeconds)` returns `double?`.
	- Returns `null` if either list is empty or their lengths differ ([lib/services/eta_utils.dart](lib/services/eta_utils.dart#L2-L10)).
	- Returns `0.0` if `progressMeters >= stepBoundariesMeters.last` (route completed) ([lib/services/eta_utils.dart](lib/services/eta_utils.dart#L12-L13)).
	- Locates the first step boundary that is `> progressMeters` by incrementing an index while `boundary <= progressMeters` ([lib/services/eta_utils.dart](lib/services/eta_utils.dart#L15-L20)).
	- Computes a proportional remaining time for the *current* step based on remaining meters within that step, then adds the full durations of all subsequent steps (`tail`) ([lib/services/eta_utils.dart](lib/services/eta_utils.dart#L22-L33)).
- Input conventions (implied by code):
	- `stepBoundariesMeters` is expected to be monotonically increasing cumulative distances (end-of-step cumulative meters).
	- `stepDurationsSeconds` is expected to be the same length and aligned to the boundaries by index.

### lib/services/stop_logic_engine.dart
- Purpose/role: Provides stops-mode helper computations around “remaining stops” to next critical point (switch/destination), plus pre-boarding and leg-transition helpers.
- Data model coupling:
	- Consumes `RouteEventBoundary` from [lib/services/transfer_utils.dart](lib/services/transfer_utils.dart).
	- Uses `Position` (geolocator) and `LatLng` (google_maps_flutter) for distance checks.
- Configuration constants:
	- `preBoardingAlertDistance = 1200.0m`, `switchPointProximity = 200.0m`, `walkingSpeed = 1.4 m/s` ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L8-L10)).
- Remaining stops calculation:
	- `calculateRemainingStops(...)` returns a record with: `remainingStops`, `remainingStopsToDestination`, `nextSwitchIndex`, `targetName`, `isDestination`, optional `targetLat`/`targetLng`, and `targetMeters` ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L24)).
	- Next switch selection: iterates route events in order, skips indexes in `firedEventIndexes`, and selects the first event whose `event.meters` is ahead of `progressMeters` OR within 500m absolute difference (jitter/overshoot tolerance) ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L52-L71)).
	- Target selection: if no next switch is found, treats the target as destination (`targetMeters = stepBoundsMeters.last`, `nextSwitchIndex = -1`, `targetName = 'Destination'`) ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L75-L82), [lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L165-L174)).
	- Transit-stop interpolation: `_interpolateStops(meters, stepBoundsMeters, stepStopsCumulative)` linearly interpolates within a step only when the step’s `stepStopsDiff > 0`; for steps with zero stop delta (walking/driving), it returns the step’s start stop count (constant through that segment) ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L109)).
	- Hybrid “virtual stops” behavior (as implemented): if the computed remaining stops to the selected target is `< 0.1` but `targetMeters - progressMeters > 0`, it replaces remaining stops with `dist/500.0` (500m = 1 stop) and clamps non-negative ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L98-L121), [lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L165-L174)).
- Pre-boarding alert helper:
	- `checkPreBoarding(currentPosition, firstTransitBoarding, startPosition)` returns null if no boarding point; otherwise triggers when `distanceToStation <= 1200m` and not suppressed ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L201)).
	- Suppression rule: if `startPosition` exists and was within `switchPointProximity` (200m) of the boarding point, `shouldSuppress = true` ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L226-L233)).
- Leg transition helper:
	- `detectLegTransition(...)` returns null if `currentSwitchIndex` is null/out-of-range or if the target event is missing lat/lng; otherwise computes `distanceToSwitch` and returns:
		- `autoSwitch = (distanceToSwitch < 200m) && (currentSpeed < 1.4 m/s)`
		- `missedTransfer = (distanceToSwitch > lastDistanceToSwitch) && (distanceToSwitch > 200m)` ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L239-L278)).
- Threshold validation helper:
	- `validateThreshold(userThreshold, stepBoundsMeters?, stepStopsCumulative, routeEvents)` returns a record `(isValid, maxStops, errorMessage)` ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L285)).
	- Max-stops selection: defaults to `stepStopsCumulative.last`, but if `routeEvents` is non-empty and `stepBoundsMeters` is provided, it limits `maxStops` to the interpolated stop count at the first route event’s `meters` value ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L308-L324)).
	- Invalid condition: `userThreshold > maxStops` produces an error message of the form “Please choose < X stops (route has Y stops)” ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L326-L327)).
- Fallback progress estimator:
	- `estimateProgressFallback(totalRouteMeters, currentPosition, destination)` estimates progress as `totalRouteMeters - distance(currentPosition, destination)` and clamps to `[0, totalRouteMeters]` ([lib/services/stop_logic_engine.dart](lib/services/stop_logic_engine.dart#L330-L344)).
- Repository usage (as of workspace search): no direct call sites to `StopLogicEngine` were found under `lib/` beyond this file’s definition; [lib/main_dashboard.dart](lib/main_dashboard.dart#L981-L1019) contains commentary referencing StopLogicEngine for “logical triggering” vs marker placement.

### lib/services/transfer_utils.dart
- Purpose/role: Parses a Google Directions-like response map and derives (a) transfer/switch boundary meters, (b) rich route events for transfers and mode changes, (c) cumulative step boundaries and cumulative transit stop counts, and (d) visualization segments (decoded per-step polylines).
- Data model:
	- `RouteEventBoundary` is a plain DTO with fields: `meters` (double), `type` (string), optional `label`, optional `lat`/`lng`, plus `toJson()`/`fromJson(...)` for persistence ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L4-L33)).
	- `type` comment indicates intended values `'transfer' | 'mode_change'` ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L6-L6)).
- Transfer boundary meters:
	- `buildTransferBoundariesMeters(directions, metroMode: ...)` returns `[]` when `metroMode == false`; otherwise traverses routes→legs→steps and accumulates `cum` meters via each step’s `distance.value`.
	- When encountering a `TRANSIT` step, it looks ahead to the next `TRANSIT` step (skipping non-transit), compares line identifiers (`short_name`/`name`/`id`), and when they differ, records a boundary at the end of the current transit step (`result.add(cum)`) ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L36-L94)).
- Route event construction:
	- `buildRouteEvents(directions)` emits a sorted, deduplicated list of `RouteEventBoundary` events containing both:
		- `mode_change` events recorded at `meters=cum` *before* adding the current step distance when `travel_mode` changes vs previous step, with a label from `_modeLabel(mode)` and lat/lng from the step `start_location` ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L99-L160)).
		- `transfer` events for `TRANSIT` steps when a different next transit line is detected (or when line identity is unknown but a next transit step exists). Transfer label uses `arrival_stop.name` when present and location uses `arrival_stop.location.lat/lng` ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L162-L227)).
	- Deduplication: after sorting by `meters`, it removes events within 1.0m of the previous kept event ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L225-L247)).
- Step boundaries and cumulative stops:
	- `buildStepBoundariesAndStops(directions)` returns a record `{bounds, stops}` where `bounds[i]` is cumulative meters and `stops[i]` is cumulative **transit** stops only.
	- For each step boundary, it adds step distance to `cumM`, and if the step mode is `TRANSIT`, it adds `transit_details.num_stops` to `cumStops`; it appends `bounds.add(cumM)` and `stops.add(cumStops)` for every step ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L250-L290)).
- Virtual-stop helper for first boarding:
	- `firstTransitBoardingStops(directions)` increments `cumStops` by `distance/500.0` for each non-transit step until the first `TRANSIT` step, at which point it returns the accumulated value (interpreted as “virtual stops before boarding”) ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L313-L350)).
- Stops-prior helper:
	- `nStopsPriorTarget(stepData, events, eventIndex, nStops)` finds the first step boundary whose meters is >= the event’s `meters` value, uses the aligned `stops` value as the event cumulative stops, and returns `max(eventStops - nStops, 0)` ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L352-L375)).
- Visualization segments:
	- `buildRouteSegments(directions)` decodes each step’s `polyline.points` via [lib/services/polyline_decoder.dart](lib/services/polyline_decoder.dart) and emits a list of `{mode, points:[{lat,lng},...]}` segment maps for steps that contain polylines ([lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L377-L379)).
- Repository usage (as of workspace search):
	- [lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1656-L1675) uses `buildStepBoundariesAndStops(...)` and `buildRouteEvents(...)` to populate `_stepBoundsMeters`, `_stepStopsCumulative`, and `_routeEvents`.
	- [lib/screens/maptracking.dart](lib/screens/maptracking.dart#L556-L579) uses `buildTransferBoundariesMeters(...)` to derive `_transferBoundariesMeters` used for a user-facing “switch routes in X min” notice.

### lib/services/eta_engine.dart
- Purpose/role: Stateful ETA estimator that combines simple map-matching to a route polyline, exponential speed smoothing, optional dwell-time addition, and an uncertainty estimate (`sigmaEta`).
- Configuration constants (static):
	- Speed smoothing: `speedAlpha = 0.25`, minimum effective speed `vMin = 0.5 m/s` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L13-L15)).
	- Stop/dwell detection: `stopSpeedThreshold = 0.7 m/s`, `stopTimeThresholdMs = 8000`, `defaultDwellSeconds = 25` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L16-L18)).
	- Uncertainty defaults: `uncertaintyMinPos = 8m`, `sigmaVDefault = 1.5 m/s`, `largeSigmaEta = 1e6` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L19-L22)).
	- Speed-window sizing: `speedWindowMax = 10` and snap constraint `maxSnapDistance = 100m` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L23-L25)).
- Persisted state (SharedPreferences):
	- Loads `eta_smoothed_speed` (double) and `eta_speed_window` (StringList parsed as doubles) ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L35-L48)).
	- Saves `eta_smoothed_speed` if non-null and always writes `eta_speed_window` as stringified doubles; save is invoked asynchronously from `computeEta(...)` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L51-L70), [lib/services/eta_engine.dart](lib/services/eta_engine.dart#L320-L322)).
- Map-matching and remaining distance:
	- `matchToRoute(routeCoords, currentPoint)` searches route segments for the closest projection using a simple lon/lat dot-product projection onto each segment.
	- Snap safety: when `lastSnappedPoint` is known, it skips segments whose start vertex is more than `maxSnapDistance * 2` away from `lastSnappedPoint` (intended to reduce “wrong leg” snapping) ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L92-L107)).
	- If no segment projection is selected, it falls back to snapping to the nearest route vertex ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L137-L160)).
	- Remaining distance is computed as: remaining fraction of the best segment plus the geodesic lengths of all subsequent segments ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L168-L206)).
- Speed estimation:
	- Raw speed uses `gps.speed` when `> 0`, else `_estimateSpeedFromLast(gps)` computed from distance/time vs `lastGps` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L237-L259), [lib/services/eta_engine.dart](lib/services/eta_engine.dart#L268-L269)).
	- Smoothed speed uses exponential smoothing and maintains a bounded `speedWindow` used for sigma-v computation ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L211-L235)).
- Dwell-time add-on:
	- When raw speed stays below `stopSpeedThreshold` for at least `stopTimeThresholdMs`, it adds `defaultDwellSeconds` to ETA (`dwellAdd`) ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L273-L286)).
- ETA and uncertainty output:
	- `computeEta(routeCoords, gps)` returns a record containing: `etaSeconds`, `remainingMeters`, `vEst`, `sigmaEta`, `dwellAddedSeconds`, `snappedPoint` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L246-L266)).
	- ETA uses `remainingMeters / max(vEst, vMin) + dwellAdd` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L288-L291)).
	- Sigma-ETA uses a combined positional term and speed-uncertainty term; if `effectiveSpeed <= 0.1`, sets `sigmaEta = largeSigmaEta` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L293-L316)).
- Reset behavior:
	- `reset()` clears all state fields including `smoothedSpeed`, `lastGps`, stop timer, speed window, and `lastSnappedPoint` ([lib/services/eta_engine.dart](lib/services/eta_engine.dart#L331-L338)).
- Repository usage (as of workspace search): no instantiations or calls to `EtaEngine` were found under `lib/`; current tracking loop uses a simplified ETA computation stored in `_smoothedETA` within [lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1032-L1069).

### lib/services/deviation_detection.dart
- Purpose/role: Standalone deviation helper functions for a `RouteModel` polyline: nearest-point search (implemented as nearest decoded vertex) and deviation-threshold check.
- Data model coupling: expects a `RouteModel` with `polylineDecoded : List<LatLng>` ([lib/services/deviation_detection.dart](lib/services/deviation_detection.dart#L3-L3), [lib/services/deviation_detection.dart](lib/services/deviation_detection.dart#L25-L55)).
- Closest point computation:
	- `findClosestPointOnRoute(currentLocation, route)` iterates every decoded polyline point and chooses the one with minimum geodesic distance to `currentLocation` ([lib/services/deviation_detection.dart](lib/services/deviation_detection.dart#L25-L49)).
	- `distanceFromStart` is recomputed for each candidate “best” point by summing consecutive point-to-point distances from the start up to index `i` (nested loop) ([lib/services/deviation_detection.dart](lib/services/deviation_detection.dart#L41-L47)).
	- Returned `segmentIndex` is the chosen vertex index, not a segment i→i+1 projection index ([lib/services/deviation_detection.dart](lib/services/deviation_detection.dart#L11-L20)).
- Threshold behavior:
	- `determineThreshold(isOffline, ...)` returns a fixed base threshold: 1500m when offline, 600m when online ([lib/services/deviation_detection.dart](lib/services/deviation_detection.dart#L50-L56)).
	- `isDeviationExceeded(currentLocation, activeRoute, isOffline)` computes deviation as distance to the returned closest point and compares against that threshold ([lib/services/deviation_detection.dart](lib/services/deviation_detection.dart#L60-L65)).
- Repository usage (as of workspace search): no call sites were found under `lib/` beyond this file’s own definitions.

### lib/services/deviation_monitor.dart
- Purpose/role: Streaming deviation-state machine that consumes scalar lateral offset and speed samples and emits `DeviationState(offroute, sustained, offsetMeters, speedMps, at)`.
- Threshold model:
	- `SpeedThresholdModel.high(speedMps) = base + k * speedMps` (defaults base=15.0, k=1.5); `low = hysteresisRatio * high` (defaults 0.7) ([lib/services/deviation_monitor.dart](lib/services/deviation_monitor.dart#L19-L28)).
	- This introduces hysteresis: the “return on-route” threshold is lower than the “go off-route” threshold.
- State machine behavior (per `ingest`):
	- If currently on-route (`_offroute == false`) and `offsetMeters > high`, transitions to off-route and sets `_deviatingSince = now`.
	- If currently off-route and `offsetMeters < low`, transitions back on-route and clears timers.
	- If currently off-route and still above low, marks `sustained=true` after `sustainDuration` has elapsed since `_deviatingSince` ([lib/services/deviation_monitor.dart](lib/services/deviation_monitor.dart#L45-L69)).
	- Emits a `DeviationState` on every ingest call, regardless of state change ([lib/services/deviation_monitor.dart](lib/services/deviation_monitor.dart#L71-L78)).
- Lifecycle:
	- `reset()` clears state; `dispose()` closes the broadcast controller ([lib/services/deviation_monitor.dart](lib/services/deviation_monitor.dart#L80-L92)).
- Repository usage (as of workspace search): [lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1433-L1623) constructs `DeviationMonitor` once, ingests offset values derived from snapping, and uses sustained deviation states to (a) optionally switch locally between registered routes when offset is in 100–150m range, and (b) call `ReroutePolicy.onSustainedDeviation(...)` for offsets >150m.

### lib/services/reroute_policy.dart
- Purpose/role: Minimal policy gate that converts a “sustained deviation” signal into a `RerouteDecision(shouldReroute, at)` stream based on online status and cooldown.
- API surface:
	- Exposes `stream` as a broadcast stream of `RerouteDecision` ([lib/services/reroute_policy.dart](lib/services/reroute_policy.dart#L12-L16)).
	- `setCooldown(Duration)` updates `_cooldown`; `setOnline(bool)` updates `_online` ([lib/services/reroute_policy.dart](lib/services/reroute_policy.dart#L21-L29)).
	- `onSustainedDeviation(at: DateTime)` emits:
		- `shouldReroute=false` if offline (`_online == false`) or if cooldown is active;
		- otherwise sets `_lastRerouteAt = at` and emits `shouldReroute=true` ([lib/services/reroute_policy.dart](lib/services/reroute_policy.dart#L31-L50)).
	- `dispose()` closes the stream controller ([lib/services/reroute_policy.dart](lib/services/reroute_policy.dart#L52-L54)).
- Repository usage (as of workspace search):
	- Cooldown is updated in the background tracking loop based on power policy ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L998-L1006)).
	- Online/offline gating is driven by `TrackingService.setOnline(...)` ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1360-L1363)).
	- Sustained deviation invokes `onSustainedDeviation(...)` when lateral offset exceeds the 150m band in `TrackingService` ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1577-L1579)).
	- `TrackingService` listens to `ReroutePolicy.stream` and, when `shouldReroute` is true, fetches a new route through `OfflineCoordinator.getRoute(...)` and registers it ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1580-L1618)).

### lib/services/offline_coordinator.dart
- Purpose/role: Centralizes “offline mode” routing behavior: when offline, returns only cached directions; when online, delegates to a directions provider.
- Abstractions:
	- `DirectionsProvider` interface and `DefaultDirectionsProvider` (wraps `DirectionService.getDirections(...)`) ([lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L15-L52)).
	- `RouteCachePort` interface and `DefaultRouteCachePort` (wraps `RouteCache.get(...)`) ([lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L55-L80)).
	- Returns `OfflineRouteResult(directions, source)` with `source` in `{cache, network}` ([lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L6-L14)).
- Offline state:
	- Stores `_isOffline` and exposes `offlineStream` (broadcast) plus `setOffline(bool)` which only emits on changes ([lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L83-L109)).
- Route retrieval:
	- `getRoute(origin, destination, isDistanceMode, threshold, transitMode, forceRefresh)` computes `mode` as `'transit'` vs `'driving'` and `variant` as `'rail'` for transit.
	- If offline: calls cache port `get(...)` and throws `StateError('Offline and no cached route available')` when absent; otherwise returns cached directions with `source=cache` ([lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L110-L133)).
	- If online: calls directions provider `getDirections(...)` and returns `source=network` ([lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L134-L151)).
- Lifecycle: `dispose()` closes the stream controller ([lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L153-L155)).
- Repository usage (as of workspace search):
	- Foreground route fetch uses `OfflineCoordinator.getRoute(...)` from HomeScreen ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L74-L86), [lib/screens/homescreen.dart](lib/screens/homescreen.dart#L674-L690)).
	- Reroute fetch uses `OfflineCoordinator.getRoute(...)` in TrackingService when policy emits reroute (`shouldReroute==true`) ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1594-L1613)).
	- Connectivity status is forwarded into both `ReroutePolicy` and `OfflineCoordinator` by `TrackingService.setOnline(...)` ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1360-L1363)).

### lib/services/direction_service.dart
- Purpose/role: Fetches directions via `ApiClient.getDirections(...)`, applies a tiered refresh interval, persists results into `RouteCache`, and provides polyline grouping/styling helpers for the UI.
- Caching layers:
	- L2 persistent cache: if `forceRefresh == false`, first attempts `RouteCache.get(...)` for the `(origin, destination, mode, transitVariant)` key; if present, it seeds `_cachedDirections` and `_lastFetchTime` from cache ([lib/services/direction_service.dart](lib/services/direction_service.dart#L36-L56)).
	- In-memory cache: returns `_cachedDirections` if present and if `DateTime.now() - _lastFetchTime` is less than the computed `updateInterval` ([lib/services/direction_service.dart](lib/services/direction_service.dart#L77-L85)).
- Tiered refresh interval:
	- Computes straight-line distance between origin/destination (meters) and, in distance-alarm mode, selects `farInterval`/`midInterval`/`nearInterval` based on comparisons against multiples of `threshold` (in km converted to meters). Non-distance mode uses `nearInterval` ([lib/services/direction_service.dart](lib/services/direction_service.dart#L58-L76)).
- Network fetch and route enrichment:
	- Uses `ApiClient.getDirections(origin: 'lat,lng', destination: 'lat,lng', mode, transitMode:'rail' when transit)` ([lib/services/direction_service.dart](lib/services/direction_service.dart#L87-L94)).
	- If response `status != 'OK'` or `routes` is empty, throws an exception with `error_message` or `status` ([lib/services/direction_service.dart](lib/services/direction_service.dart#L96-L103)).
	- If `overview_polyline.points` exists, decodes+simplifies it (tolerance 10m), compresses the simplified points, and writes `route['simplified_polyline'] = compressedPolyline` into the response map ([lib/services/direction_service.dart](lib/services/direction_service.dart#L106-L126)).
	- Persists a `RouteCacheEntry` including `simplifiedCompressedPolyline` and timestamp via `RouteCache.put(...)` (errors logged but not rethrown) ([lib/services/direction_service.dart](lib/services/direction_service.dart#L129-L146)).
- Retry behavior:
	- On error, if `forceRefresh == false`, it recursively retries once with `forceRefresh:true`; otherwise it throws `Exception('Failed to fetch directions: ...')` ([lib/services/direction_service.dart](lib/services/direction_service.dart#L147-L171)).
- Polyline decode+simplify caching:
	- `_decodeAndSimplifyCached(encoded, tolerance)` caches simplified point lists in `_polylineSimplifyCache` keyed by `'{encoded.length}:{md5(tol|encoded)}'` ([lib/services/direction_service.dart](lib/services/direction_service.dart#L336-L360)).
- UI helper: segmented polylines
	- `buildSegmentedPolylines(directions, transitMode)` groups step polylines by “non_transit” mode (DRIVING vs WALKING) or by transit line name when metro-type transit is detected; walking groups are dashed, others solid; only green/purple are used for transit line groups within this helper ([lib/services/direction_service.dart](lib/services/direction_service.dart#L173-L334)).
- Repository usage (as of workspace search):
	- Used by OfflineCoordinator’s default provider ([lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L34-L52)).
	- Used directly by MapTracking screen to build segmented polylines for map display ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L283-L320)).

### lib/services/route_cache.dart
- Purpose/role: Hive-backed persistent cache of raw Directions API payloads plus optional precomputed simplified polyline.
- Storage:
	- Hive box name is a constant `route_cache_v1` and stores JSON strings (`Box<String>`) ([lib/services/route_cache.dart](lib/services/route_cache.dart#L54-L62)).
	- `_ensureOpen()` opens the box; on open failure, deletes the box from disk and recreates it, rethrowing if recreate also fails ([lib/services/route_cache.dart](lib/services/route_cache.dart#L64-L79)).
- Keying:
	- `makeKey(...)` returns a JSON string (not a hash) containing rounded origin/destination lat/lng (5 decimals), mode, and optional `transitVariant` ([lib/services/route_cache.dart](lib/services/route_cache.dart#L81-L92)).
	- Rounding is intended to increase hit rate for minor coordinate variation (~1.1m granularity).
- Read path (`get(...)`):
	- Loads by computed key and decodes JSON into `RouteCacheEntry` ([lib/services/route_cache.dart](lib/services/route_cache.dart#L94-L115)).
	- TTL eviction: default TTL is 5 minutes; if stale, deletes key and returns null ([lib/services/route_cache.dart](lib/services/route_cache.dart#L56-L58), [lib/services/route_cache.dart](lib/services/route_cache.dart#L116-L122)).
	- Origin deviation eviction: computes meters between requested origin and cached entry.origin using `Geolocator.distanceBetween`; default threshold is 300m; if exceeded, deletes key and returns null ([lib/services/route_cache.dart](lib/services/route_cache.dart#L59-L60), [lib/services/route_cache.dart](lib/services/route_cache.dart#L124-L134)).
	- Decode failure: on JSON decode/parse error, deletes key and returns null ([lib/services/route_cache.dart](lib/services/route_cache.dart#L135-L140)).
- Write path (`put(...)`): JSON-encodes `RouteCacheEntry.toJson()` and stores under `entry.key` ([lib/services/route_cache.dart](lib/services/route_cache.dart#L142-L147)).
- Clear path: `clear()` clears the entire box ([lib/services/route_cache.dart](lib/services/route_cache.dart#L149-L152)).
- Repository usage (as of workspace search):
	- Read: `DirectionService.getDirections(...)` consults `RouteCache.get(...)` before network when `forceRefresh=false` ([lib/services/direction_service.dart](lib/services/direction_service.dart#L36-L56)).
	- Write: `DirectionService.getDirections(...)` persists fetched directions via `RouteCache.put(...)` ([lib/services/direction_service.dart](lib/services/direction_service.dart#L129-L146)).
	- Offline reads: `OfflineCoordinator` default cache port wraps `RouteCache.get(...)` ([lib/services/offline_coordinator.dart](lib/services/offline_coordinator.dart#L55-L80)).
	- Key reuse: `TrackingService.registerRouteFromDirections(...)` uses `RouteCache.makeKey(...)` as the route registry key ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1628-L1645)).

### lib/services/route_queue.dart
- Purpose/role: In-memory singleton queue for `RouteModel` instances with a notion of “active” route.
- Structure:
	- Singleton access via `RouteQueue.instance` and private constructor `RouteQueue._internal()` ([lib/services/route_queue.dart](lib/services/route_queue.dart#L5-L11)).
	- Holds `_routes: List<RouteModel>`, `maxSize=8`, and an `activeRouteIndex` integer ([lib/services/route_queue.dart](lib/services/route_queue.dart#L7-L10)).
- Behavior:
	- `addRoute(route)` appends; if at capacity, drops the oldest (`removeAt(0)`) and decrements `activeRouteIndex` if it was > 0; then sets the newly added route as active and updates `isActive` flags across all routes ([lib/services/route_queue.dart](lib/services/route_queue.dart#L14-L29), [lib/services/route_queue.dart](lib/services/route_queue.dart#L44-L48)).
	- `getActiveRoute()` returns null if empty; otherwise returns the route at `activeRouteIndex` ([lib/services/route_queue.dart](lib/services/route_queue.dart#L31-L35)).
	- `setActiveRoute(index)` bounds-checks then sets active index and updates `isActive` flags ([lib/services/route_queue.dart](lib/services/route_queue.dart#L37-L42)).
	- `routes` getter returns an unmodifiable copy of the underlying list ([lib/services/route_queue.dart](lib/services/route_queue.dart#L51)).
- Repository usage (as of workspace search): workspace search did not find any references outside [lib/services/route_queue.dart](lib/services/route_queue.dart#L1-L52).

### lib/services/navigation_service.dart
- Purpose/role: Provides a global `navigatorKey` for non-context navigation.
- Structure: `NavigationService.navigatorKey` is a static `GlobalKey<NavigatorState>` ([lib/services/navigation_service.dart](lib/services/navigation_service.dart#L1-L5)).
- Repository usage (as of workspace search):
	- Wired into `MaterialApp(navigatorKey: ...)` ([lib/main.dart](lib/main.dart#L118)).
	- Used for notification-body tap navigation (foreground only) in `NotificationService` ([lib/services/notification_service.dart](lib/services/notification_service.dart#L60-L120)).
	- Used by `TrackingService.completeEndTracking(...)` to navigate home when allowed ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L205-L217)).

### lib/services/alarm_player.dart
- Purpose/role: Plays the selected ringtone asset on a loop using `audioplayers`, exposes `isPlaying` as a UI/test-facing latch, and calls into `NotificationService.stopVibration()` during stop.
- Initialization:
	- Lazily initializes a singleton `AudioPlayer` in `_ensureInit()` and configures `ReleaseMode.loop` ([lib/services/alarm_player.dart](lib/services/alarm_player.dart#L11-L22)).
	- If initialization throws `MissingPluginException`/`PlatformException` (or any exception), it sets `_audioAvailable=false` and keeps `_player=null` ([lib/services/alarm_player.dart](lib/services/alarm_player.dart#L23-L32)).
- Playback:
	- `playSelected()` attempts to read SharedPreferences key `selected_ringtone`; fallback default asset path is `assets/ringtones/(One UI) Asteroid.ogg` ([lib/services/alarm_player.dart](lib/services/alarm_player.dart#L34-L48)).
	- If audio is available, it calls `_player.stop()` and then `_player.play(AssetSource(...))` using the asset path with the `assets/` prefix stripped ([lib/services/alarm_player.dart](lib/services/alarm_player.dart#L50-L63)).
	- Regardless of plugin availability, it sets `isPlaying.value=true` at the end of `playSelected()` ([lib/services/alarm_player.dart](lib/services/alarm_player.dart#L69-L70)).
- Stop:
	- `stop()` attempts `_player.stop()` when available, then sets `isPlaying.value=false` ([lib/services/alarm_player.dart](lib/services/alarm_player.dart#L72-L90)).
	- It also tries `NotificationService().stopVibration()` and ignores errors ([lib/services/alarm_player.dart](lib/services/alarm_player.dart#L92-L98)).
- Repository usage (as of workspace search):
	- Triggered by alarm notifications: `NotificationService.showWakeUpAlarm(...)` starts `AlarmPlayer.playSelected()` in parallel with `flutter_local_notifications.show(...)` ([lib/services/notification_service.dart](lib/services/notification_service.dart#L404-L448)).
	- Stopped from notification actions and tracking stop flows (`TrackingService.stopTracking`, `NotificationService` action handlers) ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L120-L143), [lib/services/notification_service.dart](lib/services/notification_service.dart#L170-L200)).
	- MapTracking UI binds to `AlarmPlayer.isPlaying` and calls `AlarmPlayer.stop()` on user actions ([lib/screens/maptracking.dart](lib/screens/maptracking.dart#L793-L894)).
	- Debug/demo tooling calls `AlarmPlayer.playSelected()` ([lib/debug/demo_tools.dart](lib/debug/demo_tools.dart#L108-L120)).

### lib/services/permission_service.dart
- Purpose/role: UI-driven permission request flow (dialogs + settings redirect) for essential runtime permissions.
- Entry point: `requestEssentialPermissions()` requests, in order, location → notifications → activity recognition and returns `true` only if the critical permissions are granted ([lib/services/permission_service.dart](lib/services/permission_service.dart#L12-L28)).
- Location permissions:
	- Checks `Permission.location.status`; if permanently denied, shows a settings dialog and returns false ([lib/services/permission_service.dart](lib/services/permission_service.dart#L32-L42)).
	- If not granted, shows a rationale dialog and on consent requests `Permission.location` ([lib/services/permission_service.dart](lib/services/permission_service.dart#L44-L57)).
	- If foreground location is granted, it immediately requests background location via `Permission.locationAlways` and returns whether it’s granted ([lib/services/permission_service.dart](lib/services/permission_service.dart#L59-L83)).
- Notification permission:
	- Android-only gate: if not Android, returns true; otherwise requests `Permission.notification`, with a settings redirect when permanently denied ([lib/services/permission_service.dart](lib/services/permission_service.dart#L85-L105)).
- Activity recognition:
	- Android-only, requested opportunistically; treated as non-critical ([lib/services/permission_service.dart](lib/services/permission_service.dart#L107-L116)).
- Dialog behavior:
	- Rationale and settings dialogs check `context.mounted` and use `showDialog` with explicit user choices; settings flow uses `AppSettings.openAppSettings()` ([lib/services/permission_service.dart](lib/services/permission_service.dart#L123-L180)).
- Repository usage (as of workspace search): invoked from HomeScreen on “Wake Me” press before proceeding to directions fetch ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L417-L441)).

### lib/services/api_client.dart
- Purpose/role: HTTP client for server-backed Google Maps operations (directions, autocomplete, place details, nearby transit stations, geocode) plus token acquisition/storage.
- Singleton: `ApiClient.instance` lazily initializes a private instance; `baseUrl` exposes the constant base URL string ([lib/services/api_client.dart](lib/services/api_client.dart#L8-L26)).
- Persistent credentials:
	- Stores `_authToken` under key `geowake_api_token` and token expiration under `geowake_api_token_exp` in SharedPreferences ([lib/services/api_client.dart](lib/services/api_client.dart#L10-L13), [lib/services/api_client.dart](lib/services/api_client.dart#L82-L155)).
	- Also loads/saves `_deviceId` under key `geowake_device_id` (this file reads/writes it; generation is not shown here) ([lib/services/api_client.dart](lib/services/api_client.dart#L12-L13), [lib/services/api_client.dart](lib/services/api_client.dart#L86-L149)).
- Initialization sequence:
	- `initialize()` loads stored credentials, authenticates when missing/expired, and then calls `testConnection()` (connection test failures are logged but not rethrown) ([lib/services/api_client.dart](lib/services/api_client.dart#L34-L79)).
	- Expiration check treats token as expired if now is after `(expiration - 5 minutes)` ([lib/services/api_client.dart](lib/services/api_client.dart#L72-L80)).
- Request behavior:
	- `_makeRequest(method, endpoint, body, queryParams)` ensures a valid token (re-auth if missing/expired), performs GET/POST with 15s timeout, and on HTTP 401 re-authenticates and retries once ([lib/services/api_client.dart](lib/services/api_client.dart#L175-L308)).
	- In `testMode==true`, `_makeRequest` short-circuits HTTP and returns canned payloads for `/maps/autocomplete`, `/maps/place-details`, and `/maps/directions`, recording request bodies and incrementing `directionsCallCount` ([lib/services/api_client.dart](lib/services/api_client.dart#L193-L252)).
- API surface (all implemented via `_makeRequest('POST', ...)`):
	- `getDirections(...)` → `/maps/directions` ([lib/services/api_client.dart](lib/services/api_client.dart#L317-L353)).
	- `getAutocompleteSuggestions(...)` → `/maps/autocomplete` and returns `predictions` list when present ([lib/services/api_client.dart](lib/services/api_client.dart#L355-L384)).
	- `getPlaceDetails(...)` → `/maps/place-details` and returns `result` if present ([lib/services/api_client.dart](lib/services/api_client.dart#L386-L408)).
	- `getNearbyTransitStations(...)` → `/maps/nearby-search` and returns `results` list when present ([lib/services/api_client.dart](lib/services/api_client.dart#L410-L436)).
	- `geocode(latlng)` → `/maps/geocode`; request body uses `address: latlng`; returns first `results` element when present ([lib/services/api_client.dart](lib/services/api_client.dart#L438-L462)).
- Repository usage (as of workspace search):
	- Initialized on splash screen (best-effort, errors logged) ([lib/screens/splash_screen.dart](lib/screens/splash_screen.dart#L49-L67)).
	- Used by `DirectionService` for directions fetch ([lib/services/direction_service.dart](lib/services/direction_service.dart#L87-L94)).
	- Used by `PlacesService` and `MetroStopService` for server-backed maps operations ([lib/services/places_service.dart](lib/services/places_service.dart#L1-L90), [lib/services/metro_stop_service.dart](lib/services/metro_stop_service.dart#L1-L60)).
	- Used by HomeScreen for reverse geocode of a tapped location ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L160-L244)).

### lib/services/places_service.dart
- Purpose/role: Thin wrapper around `ApiClient` Places endpoints that manages a per-search session token and normalizes returned results for HomeScreen.
- Session token:
	- Maintains `_sessionToken` and `_sessionStartedAt` and rotates token when older than ~3 minutes; token is generated from `millisecondsSinceEpoch` ([lib/services/places_service.dart](lib/services/places_service.dart#L6-L26)).
	- `endSession()` clears token state ([lib/services/places_service.dart](lib/services/places_service.dart#L28-L32)).
- Autocomplete:
	- `fetchAutocompleteResults(query, countryCode, lat, lng)` builds optional `location='lat,lng'` and optional `components='country:XX'`, calls `ApiClient.getAutocompleteSuggestions(...)` with `sessionToken`, and returns list items with `{description, place_id, isLocal:false}` ([lib/services/places_service.dart](lib/services/places_service.dart#L34-L74)).
	- Errors are caught and return an empty list.
- Place details:
	- `fetchPlaceDetails(placeId)` calls `ApiClient.getPlaceDetails(...)` with `sessionToken` and (when result is present) reads `result['geometry']['location']` and returns `{description:name, lat, lng}` ([lib/services/places_service.dart](lib/services/places_service.dart#L76-L99)).
	- Errors are caught and return null.
- Repository usage (as of workspace search): HomeScreen uses `PlacesService` for debounced remote autocomplete and for resolving a `place_id` to coordinates on selection ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L268-L336)).

### lib/services/metro_stop_service.dart
- Purpose/role: Server-backed lookup of nearby transit stations + validation helpers used by metro-mode before directions fetch.
- Stop lookup:
	- `getNearbyTransitStops(location, radius)` calls `ApiClient.getNearbyTransitStations(...)` and maps each result to `TransitStop(name, location, placeId)`; errors return `[]` ([lib/services/metro_stop_service.dart](lib/services/metro_stop_service.dart#L10-L48)).
- Destination validation:
	- `validateDestination(destination, maxRadius)` fetches nearby stops at destination, selects the closest by `Geolocator.distanceBetween`, and returns `DestinationValidationResult(isValid:true, closestStop, distance)`; otherwise returns `isValid:false` with an error message ([lib/services/metro_stop_service.dart](lib/services/metro_stop_service.dart#L50-L86)).
- Metro route validation:
	- `validateMetroRoute(startLocation, destination, maxRadius)` validates destination first, then fetches nearby stops near start and rejects if the closest start stop has the same `placeId` as the destination stop; if no start stop is found, it still returns valid ([lib/services/metro_stop_service.dart](lib/services/metro_stop_service.dart#L88-L152)).
- Data models:
	- `TransitStop` and `DestinationValidationResult` are declared in this file ([lib/services/metro_stop_service.dart](lib/services/metro_stop_service.dart#L154-L188)).
- Repository usage (as of workspace search): used by HomeScreen when `_metroMode` is enabled (pre-check before proceeding with directions) ([lib/screens/homescreen.dart](lib/screens/homescreen.dart#L446-L476)).

### lib/services/polyline_decoder.dart
- Purpose/role: Decodes a Google encoded polyline string into `List<LatLng>`.
- Behavior:
	- Empty input returns `[]`.
	- Best-effort decoding: exceptions return the points decoded so far (partial result) ([lib/services/polyline_decoder.dart](lib/services/polyline_decoder.dart#L1-L52)).
- Repository usage (as of workspace search): used across DirectionService step decoding, TransferUtils segment building, and HomeScreen/TrackingService route-point extraction for UI/tracking ([lib/services/direction_service.dart](lib/services/direction_service.dart#L106-L126), [lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L360-L395), [lib/screens/homescreen.dart](lib/screens/homescreen.dart#L490-L520), [lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1628-L1785)).

### lib/services/polyline_simplifier.dart
- Purpose/role: Polyline simplification (Ramer–Douglas–Peucker) plus gzip+base64 serialization for storing simplified polylines.
- Simplification:
	- `simplifyPolyline(points, toleranceMeters)` recursively simplifies by max perpendicular distance to the segment `(first,last)`; within tolerance returns `[first,last]` ([lib/services/polyline_simplifier.dart](lib/services/polyline_simplifier.dart#L10-L39)).
	- Distance computations convert to radians and use a haversine-based metric within `_perpendicularDistance` / `_distanceBetweenRadians` ([lib/services/polyline_simplifier.dart](lib/services/polyline_simplifier.dart#L41-L101)).
- Compression:
	- `compressPolyline(points)` JSON encodes point maps, gzip compresses bytes, base64 encodes the result ([lib/services/polyline_simplifier.dart](lib/services/polyline_simplifier.dart#L103-L115)).
	- `decompressPolyline(compressed)` base64 decodes, gzip decompresses, JSON decodes, and maps entries to `LatLng(item['lat'], item['lng'])` ([lib/services/polyline_simplifier.dart](lib/services/polyline_simplifier.dart#L117-L126)).
- Repository usage (as of workspace search):
	- DirectionService writes `simplified_polyline` by simplifying then compressing the overview polyline and later can use it when present ([lib/services/direction_service.dart](lib/services/direction_service.dart#L106-L126)).
	- TrackingService prefers `simplified_polyline` and decompresses it into route points when registering a route from directions ([lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1646-L1656)).

### lib/screens/otherimpservices/recent_locations_service.dart
- Purpose/role: Persists and loads a capped, de-duplicated list of “recent locations” for HomeScreen.
- Storage:
	- Hive box name is `recent_locations` (exported as `boxName`).
	- Stores the list under the key `locations` as a `List` that is read back into `List<Map<String, dynamic>>`.
- Box-open gatekeeping:
	- Uses a static `_box` and a static `_opening` Future to ensure concurrent callers share a single open attempt.
	- On open failure, it attempts `Hive.deleteBoxFromDisk(boxName)` and then re-opens the box (treated as a corruption recovery path).
- Size + dedupe:
	- Caps at `_maxItems = 15`.
	- De-duplication key is `placeId` (preferred) then `place_id` then `"lat,lng"` string fallback.
- Error handling/observability: all public methods catch exceptions and return `[]` / no-op write, logging via `dart:developer`.
- Repository usage (as of workspace search): HomeScreen loads recents during init and persists after updating selection history; app lifecycle flushes the Hive box if open.

### lib/config/power_policy.dart
- Purpose/role: Encapsulates a small set of “power policy” knobs used to tune tracking cadence and GPS behavior.
- Data model: `PowerPolicy` contains `accuracy`, `distanceFilterMeters`, `gpsDropoutBuffer`, `notificationTick`, and `rerouteCooldown`.
- Presets:
	- `PowerPolicy.testing()` returns a high-frequency configuration intended for fast test/sim loops.
	- `PowerPolicyManager.forBatteryLevel(levelPercent)` returns three tiers keyed by `>50`, `>20`, else low-battery.
- Repository usage (as of workspace search): referenced by TrackingService (policy selection) and MapTracking (distanceFilter selection for UI stream).

### lib/services/sensor_fusion.dart
- Purpose/role: A lightweight sensor fusion / dead-reckoning helper that integrates accelerometer events into an approximate LatLng stream.
- Streams:
	- Exposes `fusedPositionStream` as a broadcast stream via a `StreamController<LatLng>`.
	- Accepts an optional `accelerometerStream` (defaults to `sensors_plus` `accelerometerEvents`).
- Integration behavior:
	- Maintains velocity/displacement in meters (`_velX/_velY`, `_posX/_posY`) and converts displacement to lat/lon using a constant meters-per-degree approximation.
	- Applies a damping factor (`accelerationDecayFactor = 0.9`).
	- Resets integration state when fusion has run longer than `maxFusionDuration` (10 seconds) to limit drift.
- Lifecycle:
	- `startFusion()` attaches a subscription; `stopFusion()` cancels it; `dispose()` cancels and closes the controller.
- Repository usage (as of workspace search): instantiated and started/stopped by TrackingService as an optional position source.

### lib/services/simulation_client.dart
- Purpose/role: WebSocket client for a dev/playground “simulation bridge” that can supply synthetic positions and receive route/state broadcasts.
- Gating: all connect/send operations are no-ops unless `PlaygroundBridgeConfig.enabled` is true.
- Connection management:
	- Default host is `PlaygroundBridgeConfig.relayUrl`, overridable by `connect(host: ...)`.
	- Uses exponential backoff reconnect (1s, 2s, 4s, 8s… capped at 30s) when `_shouldBeConnected` is true.
	- Runs a periodic connection health check (15s) and reconnects if no ping has been seen for 90s.
- Protocol handling:
	- On `type: ping`, updates `_lastPingReceived` and responds with a `pong` message.
	- On `type: simulation_update`, parses `lat/lng/timestamp` and emits a `geolocator.Position` onto `positionStream`.
	- Provides `broadcastRoute(...)` and `broadcastState(...)` which send JSON payloads to the server.
- Lifecycle: `disconnect()` stops timers and closes the socket; `dispose()` disconnects and closes the stream controller.

### lib/config/playground_bridge.dart
- Purpose/role: Central gating + configuration for the playground/simulation relay bridge.
- Test isolation:
	- Uses `detectFlutterTest()` from the platform test-flag helper (conditional import) and disables the bridge when Flutter sets `FLUTTER_TEST=true`.
- Build-time flags:
	- `PLAYGROUND_BRIDGE_ENABLED` (default: true) and `PLAYGROUND_BRIDGE_DISABLED` (default: false) are read via `bool.fromEnvironment`.
	- Relay URL `PlaygroundBridgeConfig.relayUrl` is read via `String.fromEnvironment('PLAYGROUND_RELAY_URL', defaultValue: 'ws://127.0.0.1:8081')`.
- Enablement logic:
	- `enabled` returns false for Flutter tests; false if disabled-flag is true; true if enabled-flag is true; otherwise defaults to `kDebugMode || kProfileMode`.
- Repository usage (as of workspace search): used by SimulationClient and by the dashboard entrypoint to resolve the relay endpoint.

### lib/simulation_engine.dart
- Purpose/role: A simple route playback engine used for simulation/dashboard to produce positions over time.
- State:
	- Holds a route as `List<LatLng>`, tracks a segment index and within-segment progress, and computes a normalized `progress` (0..1) based on cumulative segment distances.
	- Exposes a mutable `isPlaying`, `speedMultiplier` (applied to a base walking speed of ~1.4 m/s), and `noiseAmplitude` (meters).
- Route mechanics:
	- `loadRoute(route)` caches per-segment distances and total distance, resets index/progress, and sets `currentPosition` to the first point.
	- `seek(t)` computes the target distance along the cached total distance and moves index/progress to the corresponding segment.
	- `update(dtSeconds)` advances along the route while playing; stops and sets `isPlaying=false` when the end is reached.
- Noise:
	- Applies random lat/lng offsets based on meters-to-degrees approximations when `noiseAmplitude > 0`.
- Repository usage (as of workspace search): used by the dashboard entrypoint (`lib/main_dashboard.dart`).

### lib/debug/demo_tools.dart
- Purpose/role: Local demo helpers for triggering tracking/notifications without a network directions fetch.
- DemoRouteSimulator:
	- `startDemoJourney(origin: LatLng?)` initializes NotificationService, configures TrackingService background service, shows an initial journey progress notification, registers a synthetic straight-line route (`registerRoute(key:'demo_route', mode:'driving', ...)`), then starts tracking with `alarmMode:'distance'` / `alarmValue:0.2`.
	- Uses background-service invocations `useInjectedPositions` and `injectPosition` to feed synthetic `Position` updates into the background isolate loop.
	- Creates a periodic timer (300ms) to stream a sequence of interpolated points; for each point it both emits to a local stream controller and invokes `injectPosition` into the background service.
- Alarm demos:
	- `triggerTransferAlarmDemo()` and `triggerDestinationAlarmDemo()` call `NotificationService.showWakeUpAlarm(...)` with different `allowContinueTracking` values and then call `AlarmPlayer.playSelected()`.
- Permissions:
	- `_ensureNotificationsReady()` calls `NotificationService.initialize()` and requests notification permission via `permission_handler` if not granted.
- Repository usage (as of workspace search): referenced by `DevServer` request handlers.

### lib/debug/dev_server.dart
- Purpose/role: Minimal HTTP server for triggering demo flows from outside the app.
- Server behavior:
	- `DevServer.start(port: 8765)` binds to `InternetAddress.anyIPv4` and handles requests on the server stream.
	- Endpoints:
		- `/health` returns `{ ok: true }`.
		- `/demo/journey` optionally accepts `lat`/`lng` query params and calls `DemoRouteSimulator.startDemoJourney(origin: ...)`.
		- `/demo/transfer` calls `DemoRouteSimulator.triggerTransferAlarmDemo()`.
		- `/demo/destination` calls `DemoRouteSimulator.triggerDestinationAlarmDemo()`.
	- Uses JSON responses with explicit status codes (`404` for unknown paths, `500` on exceptions).
- Repository usage (as of workspace search): no other call sites observed beyond its own file.

### lib/main_dashboard.dart
- Purpose/role: Web dashboard UI for simulation and observability that connects to the playground relay, displays routes/events, and can broadcast simulated positions.
- Platform:
	- Imports `dart:html` (web-only) and renders a `MaterialApp` with `ThemeData.dark()`.
	- Uses `google_maps_flutter` to render the map, polylines, and markers.
- Relay URL resolution:
	- If the browser URL includes `?relay=...`, it uses that as the WebSocket URL.
	- Otherwise uses `PlaygroundBridgeConfig.relayUrl`.
	- If the configured URL starts with `ws://` and the page is served over `https:`, it rewrites to `wss://`.
- WebSocket lifecycle:
	- Connects to the relay via `html.WebSocket` and maintains `_connected`, `_status`, `_reconnectAttempts`, and `_lastPingReceived`.
	- Reconnects with exponential backoff (1s, 2s, 4s, 8s… capped at 30s) on close/error.
	- Runs a periodic timeout check (30s) and forces reconnect if no ping has been received for 90s while connected.
	- Handles `type: ping` by updating `_lastPingReceived` and sending `type: pong`.
- Incoming relay message types:
	- `type: route_update`: parses `points` (lat/lng list) and optional `segments`, `switch_points`, and `events`, updates the map route visualization, updates alarm markers, and may compute reroute latency if `_rerouteStartTime` is set.
	- `type: app_state`: updates UI metrics for ETA, distance travelled, remaining stops, alarm mode/value, alarm-fired indicator, and a debug summary string when `debug_info` is present.
- Outgoing relay message types:
	- Sends `type: simulation_update` with `lat/lng/timestamp` when the simulation engine is playing, GPS is enabled, and the WebSocket is open.
- Simulation engine integration:
	- Owns a `SimulationEngine` and ticks it on a 33ms timer (~30 FPS) while `isPlaying` is true.
	- Provides UI controls for play/pause, reset, speed multiplier (1x..200x), and scrubbing progress (seek).
	- Provides “Chaos Engineering” controls including a GPS signal toggle and a “Force Deviation” action that teleports the ghost position (and can swap to a loaded deviation route).
- Route persistence:
	- Saves and loads routes to browser `localStorage['saved_routes']` as JSON with a `name` and list of `points`.
	- Supports “Load as active route” and “Load as deviation route” per saved item.
- Map visualization:
	- Draws either a single active polyline (blue) or per-segment polylines with mode-specific styling (driving: blue solid, transit: alternating green/purple solid, walking: blue dashed).
	- Adds start/end markers (red), switch-point markers (blue), a “ghost” marker for simulated user (yellow), and translucent alarm-prediction markers (violet hue, alpha 0.7).

### lib/config/app_config.dart
- Purpose/role: Central app configuration constants with security-oriented API-key handling.
- API key access:
	- `AppConfig.googleMapsApiKey` throws an exception and is explicitly documented as disabled (calls should go through the server-backed `ApiClient`).
	- `AppConfig.apiKeySource` returns the string `Secure Server`.
- Server constants:
	- `serverBaseUrl` is set to `https://geowake-production.up.railway.app/api`.
	- `appBundleId` is `com.yourcompany.geowake`.
- Repository usage (as of workspace search): no call sites found outside this file.

### lib/config/platform_test_flag_io.dart
- Purpose/role: IO implementation of `detectFlutterTest()` used to identify the Flutter unit-test environment.
- Detection behavior:
	- Returns true if `bool.fromEnvironment('FLUTTER_TEST')` is true.
	- Otherwise checks `Platform.environment['FLUTTER_TEST']` and returns true when it equals `true` case-insensitively.
- Repository usage (as of workspace search): imported via conditional import by `PlaygroundBridgeConfig`.

### lib/config/platform_test_flag_stub.dart
- Purpose/role: Non-IO stub implementation of `detectFlutterTest()` for platforms where `dart:io` is unavailable.
- Detection behavior:
	- Returns `bool.fromEnvironment('FLUTTER_TEST')`.
- Repository usage (as of workspace search): imported via conditional import by `PlaygroundBridgeConfig`.

### lib/models/route_models.dart
- Purpose/role: Defines a minimal route data model used by the older route-queue/deviation utilities.
- Data models:
	- `TransitSwitch` holds a switch location (`LatLng`), `fromMode`/`toMode`, and `estimatedTime` seconds.
	- `RouteModel` holds:
		- `polylineEncoded` and `polylineDecoded` (`List<LatLng>`)
		- `timestamp`
		- `initialETA` and `currentETA` (seconds)
		- `distance` (meters)
		- `travelMode` string
		- `isActive` flag (mutable)
		- `routeId` string
		- `originalResponse` map (full API response)
		- `transitSwitches` list (default empty)
- Repository usage (as of workspace search): referenced by `RouteQueue` and by deviation helpers (`DeviationDetection`) that accept a `RouteModel`.

### lib/screens/ringtones_screen.dart
- Purpose/role: UI screen allowing the user to select and preview alarm ringtones.
- Data model:
	- Defines a `Ringtone { name, assetPath }` and a top-level `availableRingtones` list with `.ogg` asset paths under `assets/ringtones/`.
- Persistence:
	- Uses SharedPreferences key `selected_ringtone` to load/save the selected ringtone asset path.
- Preview:
	- Uses `audioplayers.AudioPlayer` to play/stop previews from assets via `AssetSource(assetPath.replaceFirst('assets/', ''))`.
	- Tracks `_currentlyPlayingPath` to control play/pause icon state.
- Typography:
	- Uses GoogleFonts Montserrat for the AppBar title.
- Repository usage (as of workspace search): navigated to from `SettingsDrawer`.

### lib/screens/settingsdrawer.dart
- Purpose/role: Drawer UI providing settings actions, including theme toggle and navigation to ringtone selection.
- Theme toggle:
	- Looks up `MyAppState` via `context.findAncestorStateOfType<MyAppState>()` and calls `toggleTheme()`.
	- The displayed icon/label flips based on `isDarkMode`.
- Ringtones:
	- Navigates to `RingtonesScreen` using a `MaterialPageRoute` after closing the drawer.
- Other actions:
	- Contains a placeholder “Go Premium” list item with no implementation.
- Repository usage (as of workspace search): used as the `drawer:` in both HomeScreen and MapTracking.

### lib/services/test_service_instance.dart
- Purpose/role: Test double for `flutter_background_service` `ServiceInstance` used by TrackingService in test mode.
- Behavior:
	- Implements `invoke(method, args)` and logs calls; if `method == 'triggerAlarm'`, it sets `TrackingStateStore.setAlarmFired(true)`.
	- Implements `on(event)` returning a broadcast stream controller per event name.
	- Implements `stopSelf()` as a logged no-op.
	- `dispose()` closes any created controllers.
- Repository usage (as of workspace search): TrackingService calls `_onStart(TestServiceInstance(), ...)` when `TrackingService.isTestMode` is enabled.

### lib/themes/appthemes.dart
- Purpose/role: Central theme definitions used by the app root.
- Themes:
	- `AppThemes.lightTheme` and `AppThemes.darkTheme` both set `useMaterial3: true` and use `GoogleFonts.montserratTextTheme()`.
	- Both set `primarySwatch: Colors.deepPurple`.
	- Dark theme sets `scaffoldBackgroundColor` and `appBarTheme` colors explicitly and provides a dark `InputDecorationTheme`.
- Repository usage (as of workspace search): used in `main.dart` to select theme based on persisted dark-mode flag.

### lib/widgets/pulsing_dots.dart
- Purpose/role: Small animated “three pulsing dots” widget used as a loading/working indicator.
- Behavior:
	- Cycles an active dot index (0..2) on a periodic timer (`period/3`).
	- Uses `AnimatedContainer` to animate each dot’s size, enlarging the active dot.
- Lifecycle:
	- Cancels the timer in `dispose()`.
- Repository usage (as of workspace search): used by MapTracking UI.

### test/tracking_alarm_test.dart
- Purpose/role: Integration-style test asserting the distance-based destination alarm triggers when injected GPS points approach the destination within a threshold.
- Test scaffolding:
	- Uses a local `MockLocationProvider` that emits `Position` values over a `StreamController`.
	- Defines a static test route (`TestRoutes.majesticToLalbagh`) as a list of `LatLng` points.
	- In `setUp`: clears `NotificationService` recorded alarms, ensures binding initialized, and uses mock `SharedPreferences`.
- Test flow:
	- Sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`.
	- Injects the GPS stream by assigning the provider stream to the global `testGpsStream` before calling `startTracking(...)`.
	- Starts tracking with `alarmMode: 'distance'` and `alarmValue: 1.0` (km).
	- Plays the route points with small delays.
- Assertions:
	- Expects `NotificationService.testRecordedAlarms` to be non-empty.
	- If non-empty, asserts the last alarm `title` contains 'Wake Up' and `allow` is `false`.
- Cleanup: Calls `stopTracking()` and disposes the mock provider.

### test/tracking_service_connectivity_test.dart
- Purpose/role: Connectivity simulation test for GPS dropout behavior and sensor fusion activation.
- Setup:
	- Ensures binding initialized and uses mock `SharedPreferences`.
	- Sets `TrackingService.isTestMode = true` and sets `gpsDropoutBuffer = Duration(seconds: 2)`.
	- Injects GPS via a `StreamController<Position>` assigned to the global `testGpsStream`.
	- Injects a synthetic accelerometer stream into the global `testAccelerometerStream` to avoid plugin exceptions.
- Test flow:
	- Starts tracking after emitting an initial GPS position.
	- Waits 1 second and asserts `trackingService.fusionActive` is `false`.
	- Waits past the dropout buffer and asserts `fusionActive` becomes `true`.
	- Adds a resumed GPS update, waits 1 second, and asserts `fusionActive` returns to `false`.
- Cleanup: Stops tracking; closes the GPS controller; resets `testGpsStream` to null in `tearDown`.

### test/tracking_service_reroute_integration_test.dart
- Purpose/role: Scenario test exercising deviation monitoring/reroute decisions and cached-route switching via `TrackingService` streams.
- Setup:
	- Sets `TrackingService.isTestMode = true` and `ApiClient.testMode = true`.
	- Injects GPS via a `StreamController<Position>` assigned to the global `testGpsStream`.
- Route setup:
	- Builds two 20-point routes: r1 east-west along latitude 0, and r2 north-south along longitude 0.
	- Registers both using `svc.registerRoute(key: ..., mode: 'driving', destinationName: ..., points: ...)`.
- Test flow:
	- Starts tracking (distance alarm) and subscribes to `routeSwitchStream` and `rerouteDecisionStream`.
	- Feeds GPS points near r1, then feeds points moving into the r2 corridor.
	- Includes delays (including ~900ms) to allow a sustained-deviation window to elapse.
- Assertions:
	- Expects either a recorded switch containing 'r1->r2' or at least one reroute decision with `shouldReroute == true`.
- Cleanup: Cancels stream subscriptions; closes GPS controller; resets `testGpsStream`; stops tracking in `tearDown`.

### test/tracking_service_stop_flow_integration_test.dart
- Purpose/role: Integration-style test asserting `completeEndTracking(...)` clears persisted tracking state.
- Setup:
	- Ensures binding initialized and uses mock `SharedPreferences`.
	- Sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`.
- Test flow:
	- Seeds a `TrackingSnapshot` via `TrackingStateStore.saveSnapshot(...)` and sets active via `TrackingStateStore.setActive(true)`.
	- Starts tracking in test mode with `allowNotificationsInTest: true` and `useInjectedPositions: true`.
	- Calls `svc.completeEndTracking(navigateHome: false)`.
- Assertions:
	- `TrackingStateStore.isActive()` returns `false`.
	- `TrackingStateStore.loadSnapshot()` returns `null`.
	- `TrackingStateStore.notificationsMuted()` returns `false`.

### test/simulated_route_integration_test.dart
- Purpose/role: VM integration-style test simulating a fast route with deviations and asserting alarm state changes.
- Setup:
	- Ensures binding initialized and uses mock `SharedPreferences`.
	- Sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true`.
	- Assigns `NotificationService.testOnShowWakeUpAlarm` to a function that logs via `debugPrint`.
- Test flow:
	- Constructs a synthetic list of `LatLng` points: approach, deviation, return, and final approach.
	- Adds a listener on `AlarmPlayer.isPlaying` that logs changes.
	- Injects GPS stream by assigning `MockLocationProvider.positionStream` to the global `testGpsStream`.
	- Starts tracking with `alarmMode: 'distance'` and `alarmValue: 1.0` and plays the route.
	- Waits 1 second for processing.
- Assertions:
	- Expects `tracking.alarmTriggered` is `true`.
- Cleanup:
	- Calls `stopTracking()` and disposes the mock provider.
	- Resets `NotificationService.testOnShowWakeUpAlarm` and clears test-mode flags in `tearDown`.

### test/stop_end_tracking_vm_test.dart
- Purpose/role: VM test asserting stop/end tracking flow stops alarm playback.
- Setup:
	- Ensures binding initialized and uses mock `SharedPreferences`.
	- Sets `TrackingService.isTestMode = true` and `NotificationService.isTestMode = true` and clears `NotificationService.testRecordedAlarms`.
- Test flow:
	- Injects GPS stream using `MockLocationProvider.positionStream` assigned to global `testGpsStream`.
	- Starts tracking with `alarmMode: 'distance'` and `alarmValue: 0.5`.
	- Plays a short 3-point route and then calls `tracking.stopTracking()`.
- Assertions:
	- Expects `AlarmPlayer.isPlaying.value` is `false` after stopping.
- Timeout: 10 seconds.

### test/ui/maptracking_end_tracking_navigation_test.dart
- Purpose/role: Placeholder widget test for MapTracking end-tracking navigation.
- Content: Single `testWidgets(...)` with an empty body.
- Execution: The test is marked `skip: true` (comment indicates waiting for a stable Google Maps test fake).

### test/ui/maptracking_reroute_refresh_test.dart
- Purpose/role: Placeholder widget test for MapTracking reroute/refresh UI.
- Content: Single `testWidgets(...)` with an empty body.
- Execution: The test is marked `skip: true` (comment indicates waiting for a stable Google Maps test fake).

### integration_test/device_alarm_integration_test.dart
- Purpose/role: Device integration test exercising end-to-end alarm flow using injected positions while keeping platform notifications enabled.
- Binding: Uses `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`.
- App launch: Calls `app.main()` (imports `package:geowake2/main.dart` as `app`) and `pumpAndSettle()`.
- Mode configuration:
	- Sets `TrackingService.isTestMode = true`.
	- Sets `NotificationService.isTestMode = false`.
	- Clears `NotificationService.testRecordedAlarms` and assigns `NotificationService.testOnShowWakeUpAlarm` to an empty async hook.
- Location injection:
	- Defines `SimpleLocationInjector` producing a `Stream<Position>`.
	- Assigns injector stream to global `testGpsStream`.
- Test flow:
	- Starts tracking via `TrackingService().startTracking(...)` with `allowNotificationsInTest: true` and a distance alarm.
	- Plays a short route approaching the destination and then replays the destination point multiple times.
	- Polls up to 25 seconds for `NotificationService.testRecordedAlarms` to become non-empty.
- Assertions:
	- Expects `NotificationService.testRecordedAlarms.isNotEmpty` is `true`.
- Cleanup: Stops tracking and closes the injector stream.
- Timeout: 5 minutes.

### test_driver/integration_test.dart
- Purpose/role: Integration test driver entrypoint used by `integration_test` tooling.
- Content: Imports `integration_test_driver_extended.dart` and defines `main()` as `integrationDriver()`.

### tools/relay_server.dart
- Purpose/role: Standalone WebSocket relay server for broadcasting messages between connected clients.
- Network binding: Binds `HttpServer` to `InternetAddress.anyIPv4` on port `8081`.
- WebSocket upgrade: Uses `WebSocketTransformer.isUpgradeRequest`/`upgrade`.
- Client handling:
	- Maintains a `clients` list and `clientLastPong` timestamps per socket.
	- On message: attempts JSON decode; if `{type: 'pong'}` updates last-pong and does not broadcast; otherwise broadcasts to all other open clients.
	- On disconnect/error: removes the socket from tracking structures.
- Heartbeat:
	- `Timer.periodic` every 30 seconds sends JSON `{type: 'ping', timestamp: ...}` to open clients.
	- If last pong is older than 60 seconds, closes the client and removes it.
- Non-WS requests: Responds with HTTP 403.

### tools/test_relay.dart
- Purpose/role: Standalone relay sanity test that validates the relay broadcasts a message from one client to another.
- Flow:
	- Connects `clientA` and `clientB` to `ws://localhost:8081`.
	- `clientB` listens and completes success if it receives exactly `Hello from A`; otherwise completes error.
	- `clientA` sends `Hello from A`.
	- Waits up to 2 seconds and exits with code 0 on success or 1 on timeout/error; closes both sockets in `finally`.

### geowake-server/src/server.js
- Purpose/role: Express API server for GeoWake backend.
- Middleware stack:
	- Uses `helmet` with `crossOriginEmbedderPolicy: false` and `contentSecurityPolicy: false`.
	- Uses `compression`, JSON/urlencoded body parsing (10mb limit), and `morgan` logging (format differs by NODE_ENV).
	- Uses CORS with an `origin` callback that allows missing origin, allows '*' or origins in `config.allowedOrigins`, otherwise rejects.
	- Applies `slowDownRules.general` for all routes.
- Routes:
	- `GET /` returns server status payload (success/message/version/environment/timestamp/uptime).
	- `GET /api/health` returns health payload.
	- `POST /api/auth/*` is mounted without auth.
	- `POST /api/maps/*` is mounted behind `authenticateDevice` middleware.
- Error handling:
	- 404 handler returns JSON `{success:false, error:'Endpoint not found', path:req.originalUrl}`.
	- Includes `handleRateLimitError` middleware.
	- Global error handler returns 500 (or err.status) and includes stack only when `NODE_ENV == 'development'`.
- Startup:
	- Listens on `config.port` and registers SIGINT/SIGTERM handlers to close the server.
	- Logs whether Google Maps API key and JWT secret are configured (based on truthiness).

### geowake-server/src/config/config.js
- Purpose/role: Environment-backed configuration object.
- Env inputs:
	- `PORT`, `NODE_ENV`, `GOOGLE_MAPS_API_KEY`, `JWT_SECRET`, `APP_BUNDLE_ID`, `ALLOWED_ORIGINS`, `MAX_REQUESTS_PER_HOUR`, `MAX_REQUESTS_PER_MINUTE`.
- Defaults:
	- `port` defaults to 3000; `nodeEnv` defaults to 'development'.
	- `allowedOrigins` defaults to `['https://geowake-production.up.railway.app', '*']` when `ALLOWED_ORIGINS` not set.
	- `cacheTimeouts`: directions 5m, places 10m, geocoding 15m.
	- Google URLs for directions/places/placeDetails/geocoding/nearbySearch are hardcoded.
- Validation:
	- If `googleMapsApiKey` is missing, logs an error and calls `process.exit(1)`.
	- If `jwtSecret` missing or length < 32, logs an error and calls `process.exit(1)`.

### geowake-server/src/middleware/security.js
- Purpose/role: Defines rate limiting and slowdown middleware.
- Rate limiting:
	- Uses `express-rate-limit` with standard headers (draft-7) and no legacy headers.
	- `keyGenerator` uses first `x-forwarded-for` value or `req.ip`.
	- Custom `handler` returns JSON `{success:false, error:'Too many requests...'}`.
	- Exposes `rateLimitRules`: general (per minute), auth (20 per 15 min), maps (per hour).
- Slow down:
	- Uses `express-slow-down` and a `delayMs(hits) => hits * 100` function.
	- Exposes `slowDownRules`: general (1 minute window, delayAfter half maxRequestsPerMinute) and maps (15 minute window, delayAfter 50).
- Error handler: `handleRateLimitError` checks for `rateLimit.RateLimitExceeded` and returns 429 JSON.

### geowake-server/src/middleware/auth.js
- Purpose/role: Auth middleware verifying Bearer JWT tokens for protected routes.
- Behavior:
	- Requires `Authorization` header starting with 'Bearer '.
	- Verifies JWT with `config.jwtSecret`.
	- Rejects if `decoded.bundleId !== config.appBundleId` (403).
	- On success, sets `req.device = { id: decoded.deviceId, bundleId: decoded.bundleId, appVersion: decoded.appVersion }`.
	- On JWT errors: returns 401 for expired/invalid token; otherwise returns 500 'Authentication error'.
- Also exports `generateDeviceToken(deviceId, appVersion)` which signs a payload including deviceId, bundleId, appVersion and iat.

### geowake-server/src/utils/cache.js
- Purpose/role: CacheManager wrapper around `node-cache` for caching upstream Google API responses.
- Cache configuration:
	- `stdTTL: 300`, `checkperiod: 120`, `useClones: false`.
	- Logs cache statistics every 5 minutes using `getStats()`.
- Key generation:
	- `directions`: includes origin/destination/mode/transit_mode.
	- `places`: includes input/location/radius/components.
	- `place-details`: includes place_id.
	- `geocoding`: includes latlng or address.
	- `nearby-search`: includes location/radius/type.
	- Default: `generic:${JSON.stringify(params)}`.
- TTL selection:
	- Uses `config.cacheTimeouts[type]` when present; otherwise uses 300 seconds.

### geowake-server/src/controllers/authController.js
- Purpose/role: Controller for generating a JWT token for an app/device based on bundle ID.
- Endpoint behavior (generateToken):
	- Expects `bundleId` in request body and requires it matches `config.appBundleId` (401 otherwise).
	- Signs JWT with payload `{bundleId, iss:'GeoWake-Server'}` and `expiresIn: config.jwtExpiration`.
	- Returns JSON `{success:true, message:'Token generated successfully.', token, expiresIn}`.
	- On exception returns 500 with error message.

### geowake-server/src/controllers/mapsController.js
- Purpose/role: Proxies Google Maps APIs and caches results server-side.
- Core helper: `googleApiProxy(req, res, {url, params, type})`.
	- Checks cache using `cache.get(type, params)`; returns cached JSON when present.
	- On miss, calls `axios.get(url, { params: {...params, key: config.googleMapsApiKey} })`.
	- Caches `response.data` via `cache.set(type, params, response.data)`.
	- On error returns status `error.response?.status || 500` with JSON `{success:false, error:'...', details: ...}`.
- Exported handlers:
	- `getDirections` reads origin/destination/mode/transit_mode from body and uses type 'directions'.
	- `getAutocomplete` reads input/sessiontoken/location/components and uses type 'places'.
	- `getPlaceDetails` reads place_id/sessiontoken and uses type 'place-details' (adds fields=name,geometry,formatted_address).
	- `getGeocoding` reads address and uses type 'geocoding'.
	- `getNearbySearch` reads location/radius/type and uses type 'nearby-search'.

### geowake-server/src/routes/auth.js
- Purpose/role: Express router for auth endpoints.
- Route: `POST /token` applies `rateLimitRules.auth` then calls `generateToken`.

### geowake-server/src/routes/maps.js
- Purpose/role: Express router for Google Maps proxy endpoints.
- Middleware: Applies `rateLimitRules.maps` to all routes.
- Routes:
	- `POST /directions` -> getDirections
	- `POST /autocomplete` -> getAutocomplete
	- `POST /place-details` -> getPlaceDetails
	- `POST /geocode` -> getGeocoding
	- `POST /nearby-search` -> getNearbySearch

### geowake-server/test/README.md
- Purpose/role: Documentation for backend Jest/Supertest test suite.
- Content:
	- Describes covered areas (auth, maps, security, error handling, caching).
	- Lists test files and claimed test counts (auth.test.js 13, maps.test.js 25).
	- Provides commands for running tests, coverage, and watch mode.
	- Lists required env vars (GOOGLE_MAPS_API_KEY, JWT_SECRET) and optional vars (APP_BUNDLE_ID, NODE_ENV).
	- Includes sample `.env.test` content.

### geowake-server/test/auth.test.js
- Purpose/role: Jest/Supertest tests for auth token generation, token validation behavior on protected routes, health endpoints, and 404 handling.
- Token generation tests:
	- Posts to `/api/auth/token` with bundleId and asserts 200 success response with token and expiresIn.
	- Invalid/missing/empty bundleId cases expect 401 and a fixed error string.
	- Sends 5 rapid requests and asserts all succeed (within rate limit).
- Token validation tests:
	- Fetches a token in `beforeAll`.
	- Sends a protected `/api/maps/directions` request with Bearer token and asserts response is not 401.
	- Missing token/malformed token/missing Bearer prefix cases expect 401 and error matching /token/i.
- Health/404:
	- `GET /` expects 200 and presence of fields (success/message/version/environment/timestamp/uptime).
	- `GET /api/health` expects 200 with fields (success/message/timestamp/version/environment).
	- Unknown routes expect 404 with error 'Endpoint not found' and path.

### geowake-server/test/maps.test.js
- Purpose/role: Jest/Supertest tests for maps proxy endpoints, authentication requirements, caching behavior, and error handling.
- Setup: Fetches a token in `beforeAll` by posting bundleId to `/api/auth/token`.
- Auth-required tests: Each maps endpoint without Authorization expects 401.
- Request-shape tests:
	- Sends requests to `/api/maps/directions` for driving/transit/walking and asserts status is in [200, 400, 500].
	- Sends requests to `/api/maps/autocomplete` with input and optional location/components and asserts status in [200, 400, 500].
	- Sends requests to `/api/maps/place-details`, `/api/maps/geocode`, `/api/maps/nearby-search` and asserts status in [200, 400, 500].
- Caching behavior tests:
	- Makes two identical directions requests and expects statuses match; if status 200, expects bodies JSON-equal.
	- Makes two identical autocomplete requests and expects statuses match.
- Error handling tests:
	- Missing required parameters expects status in [400, 500].
	- Malformed coordinates expects status in [400, 500].
