# Deviation & Reroute Findings (Living Document)

Date started: 2025-12-21

This file is continuously updated while auditing and stress-testing:
- Deviation detection logic
- Reroute decision logic
- New route fetching / switching behavior
- MapTracking UI reflection (polylines, state, messaging)

## Quick index
- [Entry points / files of interest](#entry-points--files-of-interest)
- [Questions this audit answers](#questions-this-audit-answers)
- [Running findings](#running-findings)
- [Stress test plan](#stress-test-plan)

## Entry points / files of interest
- lib/services/trackingservice.dart
- lib/services/deviation_monitor.dart
- lib/services/deviation_detection.dart
- lib/services/reroute_policy.dart
- lib/services/direction_service.dart
- lib/services/route_cache.dart
- lib/services/route_registry.dart
- lib/services/active_route_manager.dart
- lib/screens/maptracking.dart
- lib/services/simulation_client.dart (simulation-driven behavior)
- lib/simulation_engine.dart (deviation mode in sim)

## Questions this audit answers
1. Is deviation logic robust against GPS noise, dropouts, and jitter?
2. Is reroute triggered only when warranted (debounce/hysteresis/cooldown)?
3. When reroute triggers, does the app *actually fetch* a new route and switch active polyline/steps consistently?
4. Are there concurrency issues (multiple overlapping reroutes, stale responses, cancellation)?
5. Does MapTracking UI reflect the current active route/polyline after reroute (and during local “switch” to better registered route)?

## Running findings

### 2025-12-21 (initial discovery)
- There is explicit deviation/reroute machinery in `trackingservice.dart` (search hits show: route management section, reroute stream/controller, `_rerouteInFlight`, and a comment noting a threshold change from 100m to 30m).
- Dedicated modules exist: `deviation_monitor.dart`, `deviation_detection.dart`, `reroute_policy.dart`, plus route caching/registry.

### 2025-12-21 (deep audit: architecture + key risks)

#### What actually drives deviation/reroute in production
- **Primary path**: `TrackingService` wires `ActiveRouteManager` → `DeviationMonitor` → `ReroutePolicy`.
  - Deviation is computed from snap-to-route lateral offset (`SnapToRouteEngine.snap().lateralOffsetMeters`).
  - `DeviationMonitor` adds hysteresis and “sustained deviation” timing.
  - When sustained deviation is confirmed:
    - If offset < 30m: ignored as noise.
    - If 30m–150m: prefers a **local route switch** among registered routes.
    - If >150m (or no better local route): `ReroutePolicy` decides (online + cooldown).

#### Multiple deviation implementations exist
- `lib/services/deviation_detection.dart` implements a different deviation check:
  - Finds nearest point on polyline by scanning all points.
  - Uses very large thresholds (600m online / 1500m offline).
  - Appears **unused** (no calls found in repo search).
  - Risk: if someone wires this in later, it will behave very differently and is O(n^2) in worst case.

#### MapTracking UI wiring
- Map polyline refresh on route switch is handled via `TrackingService().routeSwitchStream`.
- Visual “snap vs raw marker” decision uses `_lastOffsetMeters` (from `activeRouteStateStream`):
  - offset < 30m → snap marker visually
  - offset >= 30m → show raw location so deviation is visible

#### Critical correctness bug found (fixed)
- `DirectionService` maintained an in-memory `_cachedDirections` without keying it by request.
  - This means a subsequent call with a *different origin/destination* could incorrectly return the previous route if the update interval window had not elapsed.
  - This is particularly dangerous for reroutes since origin changes are expected.
- Fix applied: in-memory cache is now keyed by request (origin+destination+mode+variant) and only reused when the current request matches.

#### Reroute duplication risk
- Before the fix, the background reroute handler both:
  1) emitted `reroute_needed` to the foreground UI, AND
  2) performed its own route fetch + registration.
- MapTracking also listens for `reroute_needed` and fetches/registers a new route.
- Net effect: **double fetch / race risk** (two reroutes may compete).
- Fix applied: background now only emits `reroute_needed` as a fallback when background fetch fails.

#### Reroute freshness
- Background deviation-triggered reroute previously called `OfflineCoordinator.getRoute(... forceRefresh: false)`.
- Fix applied: deviation-triggered reroute now uses `forceRefresh: true` to avoid update-interval suppression.

#### Stress tests added
- Added test suite: `test/deviation_reroute_stress_test.dart`
  - Validates `DeviationMonitor` hysteresis + sustain behavior.
  - Validates `ReroutePolicy` online gating + cooldown behavior.
  - Validates `DirectionService` cache correctness using `ApiClient.testMode` (ensures cached directions are not reused across different origin/destination).

#### Simulation considerations
- `SimulationClient` estimates speed from dashboard points and writes it into `Position.speed`.
  - This matters because `DeviationMonitor` thresholds are speed-dependent.
  - If dashboard timestamps jump, speed is clamped (0–60 m/s) which reduces extreme threshold swings.

#### Threshold interactions (potential gap to be aware of)
- `DeviationMonitor` default model: `T_high = 15 + 1.5*speedMps`, with `T_low = 0.7*T_high`.
- `TrackingService` additionally hard-gates sustained deviation handling with `if (off < 30m) return;`.
  - Result: offsets in ~15–29m can become “sustained” in the monitor but will never trigger reroute/switch.
  - This is probably intentional (treat as noise), but it means the sustain signal is partly redundant in that band.

---

## Fixes Applied (2025-12-22)

### Fix 1: DirectionService Cache Keying (HIGH SEVERITY)
**File:** `lib/services/direction_service.dart`
**Problem:** In-memory cache `_cachedDirections` was not keyed by request. A reroute with a *new origin* could incorrectly return the *previous* route if within the update interval.
**Solution:** Added `_cachedDirectionsKey` field and `_makeRequestKey()` helper. Cache now only returns data when the current request matches the cached key.
**Test:** `test/deviation_reroute_stress_test.dart` - "does not reuse in-memory cache across different origin/destination"

### Fix 2: Reroute forceRefresh (MEDIUM SEVERITY)
**File:** `lib/services/trackingservice.dart`
**Problem:** Deviation-triggered reroutes used `forceRefresh: false`, which could return stale cached routes from OfflineCoordinator.
**Solution:** Changed to `forceRefresh: true` for deviation-triggered reroutes.
**Line:** ~3359

### Test Suite Status (Post-Fix)
- All 147 tests pass (3 skipped)
- New stress test file: `test/deviation_reroute_stress_test.dart` (5 tests)

---

#### Test suite status (pre-fix note, retained for history)
- New stress tests pass (single-file run).
- Full `flutter test` currently fails due to an existing failing test unrelated to reroute caching changes:
  - `test/reproduce_stop_alarm_overshoot_test.dart` (reports an alarm being skipped near a switch point).
  - Not modified as part of this deviation/reroute audit.

Open items (next reads):
- Confirm deviation detection algorithm and thresholds (distance to polyline, nearest segment, snapping).
- Confirm reroute policy gating (cooldown, online/offline, GPS dropout).
- Confirm route fetch path: which service calls Directions, how request parameters are built, caching, and how response is applied.
- Confirm MapTracking listens to the right streams/state updates to repaint polyline.

## Stress test plan
- Unit-test `deviation_detection` with synthetic tracks:
  - on-route with noise (5–20m jitter)
  - brief off-route spikes (1–2 samples)
  - sustained deviation (e.g., >150m) for N seconds
  - parallel roads / ambiguity (close polylines)
- Unit-test `reroute_policy`:
  - sustained deviation emits at most once per cooldown
  - online/offline gating prevents network reroute when offline
  - recovers after cooldown and after returning on route
- Integration-ish test around `TrackingService` in test mode:
  - inject fake `DirectionService` returning distinct polylines
  - ensure active route switches and UI-facing state updates fire

(Will refine after reading implementation details.)
