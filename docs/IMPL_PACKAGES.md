# Implementation Packages — Integration Guide

Seven reviewed change packages, ordered by reviewer verdict. **Apply-as-is** packages
are clean to land verbatim; **apply-with-fixes** packages will land the production code
verbatim but require the listed test reconciliations before the suite goes green.

Every package was reviewed as **never-late-safe** (the arm/fire guarantee is preserved or
strengthened, never weakened) and every set of `old_string` edit anchors was confirmed to
match the current tree.

## Status summary

| # | Package | Tickets | Verdict | Corrections | Test-proves-fix |
|---|---------|---------|---------|-------------|-----------------|
| 1 | Metro-data correctness cluster | #13, #28, #12 | apply-as-is | none | yes |
| 2 | RouteCache active-route pin | #23 | apply-as-is | none | yes |
| 3 | Maps proxy error-body cache fix | #24 | apply-as-is | none | yes |
| 4 | OS backstop lead + 991 cancel | #10, #11 | apply-as-is | none | yes |
| 5 | Equirectangular cos(lat) snapping | #27 | apply-as-is | none | yes |
| 6 | FileTelemetrySink + flush() + configureDefaultSinks | #7, #16 | apply-with-fixes | 1 (test only) | no |
| 7 | Delivery-channel preflight completeness | #17, #18, #19, #20 | apply-with-fixes | 2 required + 1 optional (tests only) | yes |

---

## 1. Metro-data correctness cluster (#13, #28, #12) — apply-as-is

**Summary.** Three surgical, never-late-preserving fixes plus deterministic tests:
- **#13** — extract one shared `const Set<String> kMetroVehicleTypes` (SUBWAY, HEAVY_RAIL,
  RAIL, METRO_RAIL, MONORAIL, TRAM, COMMUTER_TRAIN, LIGHT_RAIL). Both
  `TransferUtils._isMetroTransitStep` and `RerouteConstraints._routeHasMetroLeg` now test
  membership of this one set, so reroute no longer rejects TRAM/COMMUTER_TRAIN alternates
  the transfer predicate accepts (which previously terminated tracking).
- **#28** — add optional `String? cityKey` to `TransitLegStops` (threaded through
  constructor/toJson/fromJson/copyWith). `enhanceTransitLegStopsWithOsm` prefers explicit
  `leg.cityKey` and only falls back to majority-vote-over-matched-OSM-stops when it is
  null/empty, so a border-corridor mis-vote is overridable. Pure plumbing today — no
  production caller sets it yet.
- **#12** — new `test/metro_data_integrity_test.dart`: a pure `flutter test` gate over the
  shipped Dart constants (`kMetroLineSequences` + `allIndiaStops`) asserting India bbox,
  ≥2 ordered stops/sequence, no <40 m consecutive dup, dense-line hop ≤6 km, gross hop
  ≤30 km (RRTS/Agra 2-stop termini exempt from 6 km), no repeated station within a
  sequence, and every sequence city+line key resolving to a known city.

**Files + actions**
| Path | Action |
|------|--------|
| `lib/services/metro_vehicle_types.dart` | create |
| `lib/services/reroute_constraints.dart` | edit |
| `lib/services/transfer_utils.dart` | edit |
| `test/metro_data_integrity_test.dart` | create |
| `test/metro_vehicle_types_test.dart` | create |

**Test command**
```
flutter test test/metro_data_integrity_test.dart test/metro_vehicle_types_test.dart
```

**Required corrections:** none.

**Reviewer watch-items (non-blocking).**
- The "single source of truth" framing is overstated: `kMetroVehicleTypes` unifies only the
  two predicates in #13. Three other inline metro checks still hardcode the old 5-type list
  and can drift — `route_session_manager.dart:1221` (`_isMetroStep`),
  `direction_service.dart:78`, and a SUBWAY/HEAVY_RAIL/RAIL-only check at
  `direction_service.dart:415`. Not a correctness defect.
- `LIGHT_RAIL` is now treated as metro in both predicates (was in neither). Correct for
  Indian systems that report it; flagged as a watch-item for classification changes.
- #28 benefit is deferred until a geocoding pass sets `cityKey`; the test exercises the
  override via `stopsOverride` only.

---

## 2. RouteCache active-route pin (#23) — apply-as-is

**Summary.** `RouteCache.get()` was a destructive read: a route past the 5-min TTL (or
schema/planned-window stale) was deleted on read, and the offline branch of
`offline_coordinator` reused `get()` — so an offline restore after 5 min evicted the
last-good route and `getRoute()` threw `StateError`, terminating tracking. Fix adds an
active-route **pin**: `RouteCache.get()` gains `bool pinned = false` (plus optional
`Duration? ttlOverride` for unpinned callers). When pinned, `get()` bypasses TTL, schema,
and planned-window guards and never deletes on any guard (including origin-deviation) —
fully non-destructive. Unpinned eviction is untouched. `RouteCachePort.get()` gains the
matching `pinned` param; `DefaultRouteCachePort` threads it; the `OfflineCoordinator`
offline branch passes `pinned: true`. Verified end-to-end: all 20 tests across the four
affected files pass, tree restored net-zero.

**Files + actions**
| Path | Action |
|------|--------|
| `lib/services/route_cache.dart` | edit |
| `lib/services/offline_coordinator.dart` | edit |
| `test/offline_coordinator_test.dart` | edit |
| `test/offline_routing_guard_test.dart` | edit |
| `test/integration/offline_scenario_test.dart` | edit |
| `test/route_cache_pin_test.dart` | create |

**Test command**
```
flutter test test/route_cache_pin_test.dart test/offline_coordinator_test.dart test/offline_routing_guard_test.dart test/integration/offline_scenario_test.dart
```

**Required corrections:** none.

**Reviewer watch-items (non-blocking).**
- "Reroute" is overclaimed: `RouteCache.makeKey` is origin-sensitive, so a moving rider with
  a changed origin produces a different key and misses regardless of pinning. The pin
  rescues the same-origin **restore** path (which the new test proves).
- The schema-version-bypass test asserts non-destructiveness by re-seeding rather than a
  second pinned read — slightly weaker than the TTL case, but valid.

---

## 3. Maps proxy error-body cache fix (#24) — apply-as-is

**Summary.** Google Maps web-service APIs return HTTP 200 even on failure, signalling the
real outcome in an in-body `status` field (OVER_QUERY_LIMIT / REQUEST_DENIED /
INVALID_REQUEST / …). axios does not throw on these, so `googleApiProxy` in
`mapsController.js` unconditionally `cache.set()` + `res.json()`-ed the error body,
poisoning the cache and serving "no route" for the whole TTL — blocking riders from arming.
All five handlers (directions, autocomplete, place-details, geocode, nearby-search) funnel
through this one function, so one edit fixes every endpoint. The fix reads
`response.data.status`: it caches + returns 200 only for OK / ZERO_RESULTS; otherwise it
does not cache and returns non-2xx (429 for OVER_QUERY_LIMIT, 502 otherwise) carrying the
upstream status so the client retries. The pre-existing HTTP/network catch block is
untouched. New jest test mocks axios (no network), drives the real controller + real cache
singleton — passes on the patch (4/4), fails on the original.

**Files + actions**
| Path | Action |
|------|--------|
| `geowake-server/src/controllers/mapsController.js` | edit |
| `geowake-server/test/maps_error_body.test.js` | create |

**Test command**
```
cd geowake-server && npx jest test/maps_error_body.test.js --forceExit
```

**Required corrections:** none. No reviewer watch-items.

---

## 4. OS backstop lead + 991 cancel (#10, #11) — apply-as-is

**Summary.**
- **#10** — `notification_updater.dart::_maybeRearmEtaBackstop` hardcoded
  `leadSeconds = 60.0` for stops/distance modes. Replaced with a pure, unit-testable
  `NotificationUpdater.backstopLeadSeconds(mode, value)`: minutes/time → `value*60`
  (unchanged); stops-before → `value * 90s` inter-stop (`kBackstopInterStopSeconds`);
  distance-before(km) → `value*1000 / V_LINE`. For never-late, distance is divided by
  `VLineTable.defaultMps` (28 m/s, standard-metro ceiling) rather than `absoluteCeilingMps`
  (56) — the smaller divisor yields the larger lead = earlier (never-late) fire. A
  missing/invalid value (≤0) falls back to the original 60 s floor.
- **#11** — ETA backstop id 991 was left armed after End Tracking. Added `plugin.cancel(991)`
  to (a) the background `notificationTapBackground` END_TRACKING branch (dead isolate, so
  `cancelEtaBackstop()` never runs there), (b) the `cancelAllNotifications()` real sweep
  (called by `completeEndTracking` on the live isolate) and its log line, and (c) the
  test-mode `testRecordedCancels` list. Uses the real const `_etaBackstopNotificationId`
  (=991) everywhere.

**Files + actions**
| Path | Action |
|------|--------|
| `lib/services/tracking/notification_updater.dart` | edit |
| `lib/services/notification_service.dart` | edit |
| `test/notification_backstop_lead_test.dart` | create |

**Test command**
```
flutter test test/notification_backstop_lead_test.dart
```

**Required corrections:** none.

**Reviewer watch-items (non-blocking).**
- The test covers #11 only through the `cancelAllNotifications()` sweep. The parallel fix in
  the background `notificationTapBackground` END_TRACKING branch is verified by inspection
  only (that top-level handler needs real platform channels).
- The 90 s inter-stop and 28 m/s V_LINE overbounds can under-shoot the *semantic* target
  (fire fewer-than-N-stops / less-than-D-km early) on unusually slow corridors, but never
  fire late — the derived lead is always positive and ≥ the old 60 s floor.

---

## 5. Equirectangular cos(lat) snapping (#27) — apply-as-is

**Summary.** `_projectPointOnSegment` in both `polyline_decoder.dart` and
`stop_matcher.dart` projected in raw degree space (dx=Δlng, dy=Δlat, weighted equally).
Away from the equator a degree of longitude spans fewer meters than a degree of latitude,
so the perpendicular foot on any east-west-leaning segment is skewed (37 m drift at 60°N in
the test case). `SnapToRouteEngine` already does the correct equirectangular projection;
the two stop snappers did not. Fix introduces one shared public helper
`projectPointOnSegment` in `polyline_decoder.dart` that scales the longitude delta by
cos(segment-midpoint latitude) before forming dx and reconstructs snapped lng directly from
the unscaled delta (`a.lng + t·(b.lng−a.lng)`), avoiding divide-by-cos. Both internal
snappers (`stopDistancesAlongPolyline`, `snapPointToPolyline`) and `StopMatcher` call the
single helper; the local duplicate in `stop_matcher.dart` is deleted. Provably identical for
pure N-S segments (Δlng=0) and pure E-W segments (cos cancels); diagonal/E-W-leaning
segments are now corrected. Never-late untouched — geometry only, no bound relaxed.

Scope note: the other `_projectPointOnSegment` copies (`eta_engine.dart`,
`testing/pathfinder.dart`, `core/ekf/imu_replay_engine_v2.dart`, `snap_to_route.dart`) are
out of scope for #27 and left untouched.

**Files + actions**
| Path | Action |
|------|--------|
| `lib/services/polyline_decoder.dart` | edit |
| `lib/services/stop_matcher.dart` | edit |
| `test/services/projection_correction_test.dart` | create |

**Test command**
```
flutter test test/services/projection_correction_test.dart
```

**Required corrections:** none. No reviewer watch-items.

---

## 6. FileTelemetrySink + flush() + configureDefaultSinks (#7, #16) — apply-with-fixes

**Summary.** Adds a durable, fail-open JSONL `FileTelemetrySink` (bounded RAM buffer,
auto-flush every N events, size-capped with `.1` rotation, fsync on write); adds
`Future<void> flush()` to the `TelemetrySink` interface (no-op default) plus
`TelemetryService.flush()` that flushes all sinks; and adds
`TelemetryService.configureDefaultSinks({required String dir})` that registers InMemory +
File sinks with `path_provider` kept out of the service (injected dir). The interface
change requires switching the three existing sinks from `implements` to `extends
TelemetrySink` so they inherit the no-op flush (Dart forces re-implementation under
`implements`). Optional real wiring in `main.dart` via `getApplicationSupportDirectory`,
fire-and-forget so it never blocks/crashes startup. Never touches
alarm_controller/location_stream_handler/trackingservice — telemetry stays strictly
fail-open and never throws into any caller.

**Files + actions**
| Path | Action |
|------|--------|
| `lib/services/telemetry/file_telemetry_sink.dart` | create |
| `lib/services/telemetry/telemetry_service.dart` | edit |
| `lib/main.dart` | edit |
| `test/telemetry/telemetry_edgecases_test.dart` | edit |
| `test/telemetry/telemetry_service_test.dart` | edit |
| `test/telemetry/file_telemetry_sink_test.dart` | create |

**Test command**
```
flutter test test/telemetry/
```

**Reviewer verdict.** apply-with-fixes. Production code (FileTelemetrySink,
telemetry_service.dart, main.dart) and six of the tests apply verbatim and are correct.
Never-late-safe: telemetry never throws into any caller. The failing piece is one test's
parameters, not the implementation (`testProvesIt: false` because that test is currently red
as written).

**Required corrections (integrator MUST apply — test only).**
- **Fix the size-cap test.** It asserts `total == 50` but a single-generation rotation with
  `maxBytes: 200` over 50 events preserves only ~6 events, so it fails as written. Raise the
  cap so exactly one rotation happens and no data is lost:
  `FileTelemetrySink(dir: tmp.path, flushEveryN: 1, maxBytes: 1500)` — update the `const cap`
  references consistently while keeping the 50 events. Verified at cap=1500/50-events:
  `rotatedExists == true`, `activeLen == 828 <= 1500`, `total == 50`. (Alternatives: lower
  the event count, or implement multi-generation retention — but that exceeds the stated
  single-generation design.)
- No change is needed to the production files or the other six tests — they apply verbatim.

---

## 7. Delivery-channel preflight completeness (#17, #18, #19, #20) — apply-with-fixes

**Summary.** Adds three OS-state reads to the arm-time reliability preflight, turns them into
honest verdicts, wires each fix button to its real deep-link, and hardens never-late on
aggressive OEMs.
- **#17 DND** — `ReliabilityProbe` gains `dndBypassGranted` + `dndActive`. When DND is active
  AND the app lacks policy access, `setBypassDnd(true)` silently no-ops, so DND can mute the
  wake — surfaced as **WARN** with `PreflightIssueCode.dnd` +
  `PreflightFixAction.openDndAccessSettings` → `ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS`.
- **#18 FSI** — `ReliabilityProbe` gains `fullScreenIntentAllowed` (reuses native
  `canUseFullScreenIntent`). When false the wake degrades to a quiet heads-up a sleeper can
  miss — **WARN** with `PreflightIssueCode.fullScreenIntent` +
  `openFullScreenIntentSettings` → `ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`.
- **#19** — fix routing no longer collapses every action to `openAppSettings()`. `_applyFix`
  is refactored into public `applyReliabilityFix(fixAction, {launcher})` over an injectable
  `PreflightFixLauncher`; `PlatformPreflightFixLauncher` routes battery → OEM deep-links,
  notification/alarm/location → app_settings, DND + FSI → android_intent_plus. Only a genuinely
  unknown action hits the fallback.
- **#20** — on an aggressive OEM with no battery-optimization exemption the background service
  is routinely killed, so the battery issue is raised from WARN to `PreflightSeverity.block`,
  which rolls up to `PreflightLevel.block` and refuses to arm. Stock ROMs stay advisory/WARN.
  This **strengthens** never-late.
- Native side (`packages/wakepoint_native`): two new methods
  `isNotificationPolicyAccessGranted` + `isDndActive` on the existing MethodChannel, with Dart
  wrappers. Enums/const-classes extended, not replaced. `homescreen.dart` and
  `alarm_controller` untouched.

**Files + actions**
| Path | Action |
|------|--------|
| `lib/services/reliability/reliability_preflight_service.dart` | edit |
| `lib/services/reliability/reliability_probe_impl.dart` | edit |
| `packages/wakepoint_native/lib/wakepoint_native.dart` | edit |
| `packages/wakepoint_native/android/src/main/kotlin/com/geowake/wakepoint_native/WakepointNativePlugin.kt` | edit |
| `lib/services/reliability/reliability_preflight_runner.dart` | edit |
| `test/reliability/reliability_preflight_test.dart` | edit |
| `test/reliability/reliability_preflight_combinatorial_test.dart` | edit |
| `test/reliability/reliability_preflight_delivery_channel_test.dart` | create |

**Test command**
```
flutter test test/reliability/reliability_preflight_delivery_channel_test.dart
```

**Reviewer verdict.** apply-with-fixes. All edit anchors match; compiles (android_intent_plus
^6, app_settings ^6.1.1, package_info_plus ^9, wakepoint_native path all in pubspec; Kotlin
NotificationManager APIs valid at minSdk 24). Never-late preserved (#20 tightens the arm gate,
#17/#18 additive WARNs). The new delivery-channel test genuinely proves the fix (the #19
collapse-to-fallback bug would fail the spy launcher). The two edited reliability test files
are correctly reconciled, so `flutter test test/reliability/` stays green — **but** #20 turns
previously-green assertions red in two *other* tracked test files, which the package
under-sold; those must be reconciled or the whole-suite `flutter test` goes red.

**Required corrections (integrator MUST apply — tests only).**
1. **`test/integration/preflight_arm_scenario_test.dart` S2** (≈ lines 102/104/114): under #20,
   Xiaomi (aggressive) + `!batteryExempt` must now expect `PreflightLevel.block`,
   `isBlocked == true`, and battery `severity == PreflightSeverity.block` — the file currently
   asserts `warn`/`isBlocked == false`/`severity == warn`. Leaving it red is caused directly by
   this change.
2. **`test/widgets/preflight_dialog_widget_test.dart` WARN case** (lines 46–57): oppo +
   `!batteryExempt` is now a block, so the WARN/"Got it" path must switch to a
   non-aggressive-battery scenario (e.g. `precise:false` on google, or `exactAlarm:false` on
   stock); otherwise it asserts `hasWarnings`/"Got it" against a blocking result.

**Optional but recommended.**
- Also fix the pre-existing stale "Proceed anyway" expectations in both files (widget line 43,
  scenario line 290) to match the landed enforcing dialog's "Cancel" button — a reconcile pass
  touching these files should not leave them red.

**Reviewer watch-items (non-blocking).**
- "BLOCK dominates" `hasLength(2)` and `issues.first.code == notifications` now rely on
  `List.sort` stability for two equal-severity block issues. Dart insertion-sort is stable for
  ≤32 elements, so it holds, but it is now load-bearing.
- Product note: #20 will refuse arming on most India-mix devices
  (Xiaomi/Oppo/Vivo/Samsung/Transsion) lacking a battery exemption — matches BACKLOG #20
  (BLOCK) but is a large gate worth product confirmation.

---

## Suggested landing order

1. Land the five **apply-as-is** packages (1–5) first; each is independently verifiable with
   its own test command.
2. Land package 6 (telemetry) after applying the single size-cap test correction; verify with
   `flutter test test/telemetry/`.
3. Land package 7 (reliability preflight) last, applying both required test reconciliations,
   then run the whole suite (`flutter test`) to confirm the cross-file #20 regressions are
   resolved.
