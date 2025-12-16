# GeoWake Comprehensive Review Process

This document defines the **file-by-file, line-by-line** review workflow for GeoWake.
It is designed to be exhaustive while remaining trackable and auditable.

## Goals
- Build a complete mental model of the app: **UI → services → background isolate → persistence → notifications → tests**.
- Identify and record: **logical gaps**, **inconsistencies**, **redundancies**, **race conditions**, **state leaks**, **incorrect assumptions**, and **test gaps**.
- Keep all findings cross-referenced to:
  - The product spec (see review/spec_checklist.md)
  - The audit log (see review/lib_audit.md)
  - Concrete code locations (file links + line ranges)

## Core Artifacts (living documents)
- review/lib_audit.md — Findings log (issues, rationale, suggested fixes, status).
- review/spec_checklist.md — Your desired behavior as testable requirements.
- review/architecture_map.md — System map (modules, ownership, state, data flow).
- review/file_review_index.md — Per-file review status + summary + invariants.

## Naming + Cross-Reference Conventions
### Finding IDs
All findings get a stable ID: `GW-<area>-<nnnn>`.

Areas:
- `NOTIF` notifications
- `TRACK` tracking/background service
- `ROUTE` routing/reroute/ETA/stop logic
- `STATE` persistence + stores
- `UI` screens/widgets
- `PERF` performance
- `TEST` tests/coverage
- `PLAT` Android/iOS integration constraints

Example: `GW-NOTIF-0007`.

### Finding Format (in review/lib_audit.md)
Each entry uses:
- **ID / Title / Severity** (blocker/major/minor)
- **Location links** (1+ file links with ranges)
- **Spec impact** (links to checklist items)
- **Root cause** (why it happens)
- **Proof** (how we know: trace, test, reasoning)
- **Fix plan** (minimal change)
- **Test plan** (what test validates the fix)

### Per-file Review Format (in review/file_review_index.md)
For each file:
- Purpose + responsibility
- Public API surface (what other modules call)
- Inputs/outputs/events
- State ownership (in-memory vs persisted)
- Thread/isolate model (main isolate vs background service)
- Failure modes + recovery
- Invariants (what must always be true)
- Open questions
- Related tests

## Review Phases (repeatable)
### Phase 0 — Build the dependency map (fast pass)
For each file: list imports, exported classes, and which other files reference it.
Output goes into review/architecture_map.md and review/file_review_index.md.

### Phase 1 — End-to-end runtime flows (before deep dive)
We map the app’s main flows as *timelines*:
1. Cold start → Splash → Home
2. Home → Wake Me → MapTracking + journey notification
3. Background tracking loop → alarm triggers → notification actions
4. App backgrounded / task removed → paused notification → resume/end
5. Reroute path: deviation → route queue → active route switch

These timelines are written in review/architecture_map.md.

### Phase 2 — File-by-file, line-by-line review (the deep pass)
We review in a stable order so cross references are natural:

**Entry points & routing**
- lib/main.dart
- lib/screens/splash_screen.dart
- lib/screens/homescreen.dart
- lib/screens/maptracking.dart

**Persistence & global state**
- lib/services/tracking_state_store.dart
- any Hive boxes/services used for recent locations

**Notifications & alarm stack**
- lib/services/notification_service.dart
- lib/services/alarm_player.dart
- any vibration/foreground-service wiring

**Core tracking engine (background isolate)**
- lib/services/trackingservice.dart (including `_onStart`, background event handlers)

**Routing/ETA/stop logic**
- stop_logic_engine.dart
- eta_engine.dart / eta_utils.dart
- transfer_utils.dart
- snap_to_route.dart

**Route caching/queue/switching**
- route_registry.dart
- active_route_manager.dart
- route_cache.dart
- route_queue.dart
- reroute_policy.dart
- deviation_monitor.dart

**Peripheral services**
- permission_service.dart
- offline_coordinator.dart
- api_client.dart

For each file we do:
- 1st pass: *facts only* (what it does), record invariants.
- 2nd pass: *failure modes* (nulls, races, missing permissions, background constraints).
- 3rd pass: *spec alignment* (link each behavior to checklist items).

### Phase 3 — Fixes + tests (only after we understand)
We batch fixes in priority order:
- Blockers to correctness and user safety (notif actions, end tracking reliability)
- State corruption (route registry, active-route progress)
- Races/duplicate listeners
- Performance issues that impact correctness (e.g., dropped notif updates)

Every fix must have:
- A reproduction description
- A test (unit/integration) when feasible

## What “line-by-line” means in practice
Because files are large, we review in **contiguous blocks** (e.g., 200–400 lines at a time) and log:
- what the code does
- why it exists
- who calls it
- what it assumes
- what happens on failure

We only move forward when the block’s invariants and responsibilities are captured.

## Definition of Done (for the review)
- Each file in lib/ has an entry in review/file_review_index.md with purpose + invariants.
- Each product behavior in review/spec_checklist.md is either:
  - confirmed implemented, or
  - linked to 1+ open findings in review/lib_audit.md.
- Test coverage map exists for critical flows.
