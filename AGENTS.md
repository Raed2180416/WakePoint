# AGENTS.md — Agent Orientation for GeoWake

> Orientation document for AI agents working on the GeoWake codebase.

## Identity

- **App name:** GeoWake (package: `geowake2`, applicationId: `com.geowake.app`)
- **Repo dir:** `WakePoint`
- **Platform:** Flutter, Android-first, India-first
- **Branches:** `production-ready-audit-v2` (dev), `stable-release-1` (release)
- **Flutter:** 3.44.x stable
- **Android:** minSdk 24, targetSdk 35

## Critical Invariants

1. **Core alarm is always free.** Never gate `canUseCoreAlarm`, `canUseBasicReliability`, `canUseBackstopAlarm`, or `canUseSingleActiveRoute` behind Pro. See `lib/services/monetization/premium_service.dart`.
2. **Never-late guarantee.** The alarm must fire on time or not at all — never silently late. CI gate: `test/ekf/replay_harness_test.dart`.
3. **Consent is default-OFF.** Mobility data sharing requires explicit opt-in. Egress is a no-op without consent. See `lib/services/data_asset/mobility_consent_service.dart`.
4. **Fail-open for Pro features.** Anti-theft, guardian, monetization — all degrade gracefully. A Pro feature failure must never affect the core alarm.
5. **No snooze.** A wake alarm must never be delayable. Escalating re-alert is the correct behavior.

## Key Files

| File | Purpose |
|------|---------|
| `lib/main.dart` | Entry point, routing, service initialization |
| `lib/services/trackingservice.dart` | Core tracking orchestrator (~2770 lines, intentionally monolithic) |
| `lib/services/notification_service.dart` | Alarm delivery, full-screen intent, sound + vibration |
| `lib/services/monetization/premium_service.dart` | Entitlement logic, feature gates |
| `lib/services/monetization/monetization_service.dart` | IAP facade, reactive tier |
| `lib/services/anti_theft_service.dart` | Sensor fusion snatch detection |
| `lib/services/data_asset/data_asset_pipeline.dart` | Consent-gated DP aggregate pipeline |
| `lib/services/share/guardian_service.dart` | Auto-share commute with contact |
| `lib/core/ekf/ekf_orchestrator.dart` | Extended Kalman Filter for GPS-denied tracking |
| `lib/core/reachability/reachability.dart` | Never-late reachability physics |
| `geowake-server/src/server.js` | Express.js backend entry |

## Service Initialization Order

In `main.dart`, services init fire-and-forget in this order:
1. `Hive.initFlutter()` — await (blocking, fast)
2. `TelemetryService` — fire-and-forget, durable JSONL + optional HTTP
3. `MonetizationService.instance.init()` — fire-and-forget, defaults to free
4. `GuardianService.instance.init()` — fire-and-forget, inert unless Pro
5. `AntiTheftService.instance.load()` — fire-and-forget, inert unless Pro
6. `DataAssetPipeline.instance.init()` — fire-and-forget, consent-gated
7. `HomeWidgetBridge.instance.initialize()` — fire-and-forget
8. `ShareBackendConfig.configure()` — fire-and-forget
9. `runApp()` — starts UI

In `SplashScreen._initializeServices()`:
- `ApiClient.instance.initialize()` — await (auth token)
- `NotificationService().initialize()` — await (channels)
- `TrackingService()` — restore session if active

## Routing

Routes defined in `lib/main.dart` `onGenerateRoute`:
- `/splash` → SplashScreen (initial)
- `/` → HomeScreen
- `/preloadMap` → PreloadMapScreen
- `/mapTracking` → MapTrackingScreen
- `/paywall` → GeoWakePaywallScreen
- `/dataConsent` → DataSharingConsentScreen
- `/guardian` → GuardianSetupScreen
- `/postArrival` → PostArrivalScreen
- `/antiTheft` → AntiTheftSetupScreen

## Testing

```bash
flutter test          # all 1373+ tests
flutter analyze lib/  # 0 errors required
```

CI gates (`.github/workflows/ci.yml`):
- `flutter analyze lib/ --no-fatal-infos`
- Never-late replay: `test/ekf/replay_harness_test.dart`
- Reachability: `test/reachability/`
- Scale: `test/scale/reachability_scale_test.dart`
- Playground E2E: `test/dashboard/playground_reachability_e2e_test.dart`
- Clock: `test/core/clock/`
- Metro data: `test/metro_data_integrity_test.dart`
- Full suite: `flutter test`

## Build-Time Defines

| Define | Default | Purpose |
|--------|---------|---------|
| `GEOWAKE_TELEMETRY_URL` | `''` | Telemetry HTTP endpoint (empty = local only) |
| `GEOWAKE_TELEMETRY_TOKEN` | `''` | Telemetry auth token |
| `ENABLE_FLUTTER_DRIVER` | `false` | Flutter Driver extension for E2E |
| `GEOWAKE_SHARE_BASE_URL` | Railway URL | Journey share backend |
| `GEOWAKE_SHARE_TOKEN` | `''` | Share backend auth |

## Backend

Express.js server in `geowake-server/`. See `docs/BACKEND.md` for API reference.

```bash
cd geowake-server && npm install && npm start
```

## Native Plugin

`packages/wakepoint_native/` — Android-only plugin for:
- `canUseFullScreenIntent()` — checks Android 14+ full-screen intent permission
- `scheduleExactAlarm()` — OS-scheduled exact alarm as process-death backstop
