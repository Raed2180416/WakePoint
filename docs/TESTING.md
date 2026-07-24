# GeoWake — Testing Guide

> 1373+ tests. 0 analysis errors. CI gates protect the never-late guarantee.

---

## Quick Reference

```bash
# Full suite
flutter test

# Static analysis (must be 0 errors)
flutter analyze lib/

# CI-critical gates
flutter test test/ekf/replay_harness_test.dart          # never-late replay
flutter test test/reachability/                           # reachability physics
flutter test test/scale/reachability_scale_test.dart      # scale stress
flutter test test/dashboard/playground_reachability_e2e_test.dart  # E2E
flutter test test/core/clock/                             # monotonic clock
flutter test test/metro_data_integrity_test.dart          # metro data
```

---

## CI Pipeline

**`.github/workflows/ci.yml`** — runs on push/PR to `sim-validation`, `stable-release-1`, `main`.

Steps (all must pass):
1. `flutter pub get`
2. `flutter analyze lib/ --no-fatal-infos` — 0 errors, infos non-fatal
3. Never-late replay gate — drives real EKF + AlarmEvaluator over committed fixtures
4. Reachability physics proofs
5. Scale tests — real Dart over committed route matrix
6. Playground E2E — simulation engine with real geometry
7. Monotonic clock guard — backward wall-jump never-late
8. Metro data integrity — shipped Dart data validation
9. Full test suite — all pass

---

## Test Categories

### Core Tests (`test/core/`)

| Area | Files | Purpose |
|------|-------|---------|
| EKF | `test/core/ekf/` (10 files) | EKF orchestrator, pipeline, ZUPT, tilt filter, motion classifier, station association, route geometry, GPS degradation |
| Clock | `test/core/clock/` (3 files) | Monotonic clock, app clock integration, backward wall-jump |
| Reachability | `test/reachability/` | Never-late physics proofs |

### Service Tests (`test/services/`)

| Area | Files | Purpose |
|------|-------|---------|
| Data Asset | `test/services/data_asset/` | HTTP egress sink, candidate sink |
| EKF Integration | `test/services/ekf_integration/` | Ambiguous station, GPS recovery, long tunnel, smooth acceleration |
| Projection | `test/services/projection_correction_test.dart` | Route projection corrections |
| Testing Utils | `test/services/testing/` | OSM graph, pathfinder |

### Feature Tests

| Area | Key Files | Purpose |
|------|-----------|---------|
| Alarm logic | `test/alarm_logic_test.dart`, `test/alarm_logic_rewrite_test.dart` | Alarm threshold evaluation |
| Tracking | `test/tracking_alarm_test.dart`, `test/tracking/` | Tracking service, arrival hooks, cold start, post-alarm multicast |
| Monetization | `test/monetization/` (3 files) | Entitlement, IAP, edge cases, journey flow |
| Share | `test/share/` (6 files) | Journey share, guardian, deep links, followed rides |
| Telemetry | `test/telemetry/` (5 files) | Service, sinks, edge cases, emit sites |
| Data Asset | `test/data_asset/` (5 files) | Consent, DP + k-anon, pipeline, egress, station binner |
| Reliability | `test/reliability/` (2 files) | Preflight, delivery channel |
| Widget | `test/widget/` (3 files) | Home widget, field contract, post-arrival card |

### Integration Tests (`test/integration/`)

| File | Purpose |
|------|---------|
| `lifecycle_restore_scenario_test.dart` | Session restore after lifecycle events |
| `offline_scenario_test.dart` | Offline tracking + reroute gating |
| `preflight_arm_scenario_test.dart` | Reliability preflight before arming |
| `reachability_ride_scenario_test.dart` | Full ride with reachability |
| `reachability_scenarios_test.dart` | Multiple reachability scenarios |

### Scale Tests (`test/scale/`)

| File | Purpose |
|------|---------|
| `reachability_scale_test.dart` | Reachability over committed route matrix |
| `never_late_gps_error_stress_test.dart` | Never-late under GPS error stress |
| `multi_target_scale_test.dart` | Multi-target alarm at scale |

### Dashboard / Simulation (`test/dashboard/`)

| File | Purpose |
|------|---------|
| `playground_reachability_e2e_test.dart` | E2E through simulation playground |
| `constraint_event_integration_test.dart` | Constraint events |
| `deviation_dashboard_integration_test.dart` | Deviation dashboard |
| `simulation_state_test.dart` | Simulation state management |

### E2E / Integration (`integration_test/`)

Patrol-based on-device tests:
- `patrol_alarm_test.dart` — full alarm flow on device
- `backstop_doze_ondevice_test.dart` — exact alarm backstop under doze

---

## Test Infrastructure

### Test Mode

`TrackingService.isTestMode` and `NotificationService.isTestMode` — when true, bypasses platform channels and uses in-memory mocks. Set via `lib/config/test_mode_flag.dart`.

### Test Service Instance

`TestServiceInstance` (`lib/services/test_service_instance.dart`) — implements `ServiceInstance` for testing the background service without a real isolate.

### Test Helpers

- `test/helpers/ekf_test_helpers.dart` — EKF test fixtures and helpers
- `test/log_helper.dart` — test logging utilities
- `test/test_routes.dart` — shared test route definitions

### Flutter Driver

Enabled via `--dart-define=ENABLE_FLUTTER_DRIVER=true`. Production builds never register the extension.

---

## Test Conventions

1. **Never weaken or delete tests** without explicit direction
2. **Design tests before major implementation** work
3. **Never-late tests are sacred** — any change to EKF, reachability, or alarm logic must pass the replay harness
4. **Fail-open behavior is tested** — Pro feature failures must never affect core alarm
5. **Consent tests verify default-OFF** — no data sharing without explicit opt-in
