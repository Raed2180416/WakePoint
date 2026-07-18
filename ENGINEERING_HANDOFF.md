# GeoWake — Engineering Onboarding Handoff

_For the next engineer picking this up cold. App name is **GeoWake** (never "geowake2"/"WakePoint" in user-facing strings). Flutter, Android-first, India-first. Repo dir `WakePoint`; active branch `sim-validation`; main `stable-release-1`. Read `SYSTEM_MAP.md` and `GAP_ANALYSIS.md` alongside this._

---

## 0. The one thing to understand first

**The never-late guarantee is NOT the Kalman filter. It is physics.** For a year the assumed mechanism was an EKF dead-reckoning position through the tunnel. That mechanism is **measured not to work** on a consumer phone (`HANDOFF.md §0`, evidence in `/home/raed/geowake_imu_analysis/`): handheld accelerometer has ~0 correlation with train acceleration; ZUPT/station detection fails; open-loop dead-reckoning drifts kilometres in minutes and fires late 30–55% of the time; and "never fire late" is information-theoretically unprovable with the data you can collect.

The actual, provable solution is the **reachability Protection Level** (`lib/core/reachability/reachability.dart`, mapped in `docs/system_map/02_reachability.md`): once GPS is lost, the train cannot be further along the route than `last_true_anchor + V_LINE × time_since_last_real_fix`. Fire when that worst-case reaches the target stop → late-proof by physics, no sensors, works on any metro. The **EKF is demoted, not deleted** — it still does GPS-present tracking (~90% of a trip), protects the reachability anchor via phantom-fix rejection, and carries the fire-decision plumbing. It is just not trusted for the tunnel fire.

If you internalize one rule: **reachability is a strict, monotone safety net — it can only make an alarm fire earlier, never later. Never add a code path that lets it fire later, and never let its three preconditions silently break** ((i) anchor is a real fix, (ii) `V_LINE ≥ true max speed`, (iii) `t` is wall-clock since the last true fix). Every possible late-fire is a violation of one of those three.

---

## 1. Build / run / test (real commands)

Toolchain: Flutter 3.44.x / Dart 3.12 (pubspec `sdk: '>=3.7.0 <4.0.0'`). Android-first (minSdk 24, compileSdk 36, targetSdk 35). The repo assumes Flutter on PATH:

```bash
export PATH=~/flutter/bin:$PATH

# Install deps
flutter pub get

# WHOLE TEST SUITE (the definitive gate) — expect ~1106 passing, 0 failures
flutter test

# Fast pure never-late theorem + preconditions (~1s, 400k+ invariant checks)
flutter test test/reachability/reachability_test.dart

# The offline never-late REPLAY gate over real ride fixtures
#  ⚠ reads fixtures from a HARDCODED external path and SILENTLY SKIPS if absent (GAP: not in CI)
#  test/ekf/replay_harness_test.dart:38 → kFixturesDir = /home/raed/geowake_imu_analysis/fixtures
flutter test test/ekf/replay_harness_test.dart

# Static analysis
flutter analyze     # analysis_options.yaml; CI runs Qodana (see below)

# Build a release APK (⚠ versionCode is hardcoded to 1 in build.gradle — see landmines)
flutter build apk --release

# Server (Node 18, in geowake-server/)
cd geowake-server && npm install && npm start        # node src/server.js
cd geowake-server && npm test                         # jest (auth.test.js, maps.test.js)
```

**CI reality (important):** the only GitHub workflow is `.github/workflows/qodana_code_quality.yml` — static analysis, and it triggers on push to `experimental-playground` + PRs, **not** on `flutter test` and **not** on the never-late replay gate. There is no automated correctness gate in CI today. The "1106 green" and the never-late replay proof are **local observations on one machine** (`VALIDATION.md`). Treat re-running them yourself as step one.

**The one test no simulation replaces:** a real force-killed tunnel commute — ride an underground line, phone in pocket, screen off, battery-saver ON, force-kill the app mid-ride, and confirm something audible wakes you. Nothing on-device proves this today (`GAP_ANALYSIS` telemetry blocker).

---

## 2. Repo layout

```
lib/                     Flutter app (Dart)
  main.dart              PRODUCTION entry (main_unified_dashboard.dart is DEV-ONLY, must never ship as launch target)
  config/                fire_decision_config.dart, app_config.dart, deviation_config.dart (⚠ some are false SoT)
  core/reachability/     reachability.dart  ← the never-late physics core
  core/ (ekf)            EKF orchestrator/pipeline/state bounds
  services/
    tracking/            alarm_controller.dart, location_stream_handler.dart, notification_updater.dart  ← the live loop
    alarm_evaluator.dart the fire decision (modes, effectiveProgress, one-per-leg)
    eta_engine.dart eta_utils.dart          ETA + σ cushion
    location_manager.dart sensor_fusion.dart gps_health_monitor.dart  GPS gate + fusion (⚠ health monitor is dead)
    direction_service.dart api_client.dart route_cache.dart route_registry.dart snap_to_route.dart  route fetch/cache/snap
    transfer_utils.dart stop_matcher.dart polyline_decoder.dart metro_stop_service.dart  metro stops / N-stops
    deviation_monitor.dart reroute_policy.dart reroute_constraints.dart offline_coordinator.dart  off-route/reroute
    notification_service.dart oem_autostart_service.dart permission_service.dart  delivery + reliability
    reliability/         reliability_preflight_service.dart, reliability_preflight_runner.dart
    telemetry/           TelemetryService + InMemoryTelemetrySink (⚠ no persistent sink)
    ios/                 ios_backstop_planner.dart (pure, ⚠ unwired to any iPhone)
    monetization/        AdPolicy, PremiumService, MonetizationService (walled off from alarm)
    position/            ⚠ UNUSED PositionProvider — the ONLY place with correct iOS bg-location settings
    trackingservice.dart the background isolate: _onStart/_onStop, ~40 module-level session globals
    tracking_state_store.dart  isActive/paused/alarmFired + snapshot (recovery source of truth)
  screens/               homescreen.dart (arm + cross-state block), maptracking.dart, splash_screen.dart
  data/, all_india_stops.dart, metro_line_sequences.dart  shipped station inventory (compiled Dart)
android/                 app/build.gradle, src/main/AndroidManifest.xml, MainActivity.kt (native channels), 0-byte AlarmReceiver.kt
packages/wakepoint_native/  local plugin: partial wake lock + canUseFullScreenIntent (WakepointNativePlugin.kt)
ios/                     Runner (⚠ bare AppDelegate.swift, no GADApplicationIdentifier)
geowake-server/          Node/Express Railway proxy: src/server.js, test/ (jest)
assets/                  osm/ (20MB bengaluru.wkp — bundled, phone-unusable), india_metro/ (⚠ NOT in pubspec)
test/                    ~1106 tests; test/ekf/replay_harness_test.dart is the never-late gate; test/reachability/ is the theorem
tools/                   validate_metro_data.py (audits UNSHIPPED json), relay_server.dart, wake-* repo-intelligence (.wake/)
scripts/                 build_line_sequences.py (metro seq generator), scrapers, python analysis
docs/system_map/         01..18 atomic subsystem maps  ← authoritative per-subsystem detail
HANDOFF.md VALIDATION.md MONETIZATION.md README.md   prior narrative docs (this file supersedes HANDOFF.md as the onboarding doc)
```

---

## 3. Where each capability lives

- **The wake decision:** `lib/services/tracking/alarm_controller.dart` (`checkAndTriggerAlarm`) → `lib/services/alarm_evaluator.dart`. `effectiveProgress = max(deadReckoned + k·σ, reachBound)`, `k=2`.
- **Never-late physics:** `lib/core/reachability/reachability.dart` (`boundNow`, `onAcceptedFix`, `seedColdStart`). `V_LINE` table + `VLineTable.forLine` are here; `absoluteCeilingMps=56`, `defaultMps=28`.
- **GPS-present tracking / dead-reckoning:** the EKF under `lib/core/` (orchestrator/pipeline/state-bounds), driven by `lib/services/sensor_fusion.dart`; exists **only** when a `RouteGeometry` with ≥2 points is registered.
- **The live background loop:** `lib/services/trackingservice.dart` (`_onStart`/`_onStop`) + `lib/services/tracking/location_stream_handler.dart` (GPS stream + wake-locked dropout tick, the countdown-keeper underground).
- **Delivery:** `lib/services/notification_service.dart` (channels, live alarm id 0, backstop id 991, `scheduleEtaBackstop`/`cancelEtaBackstop`), `AlarmPlayer` (loud tone + haptics), `packages/wakepoint_native` (wake lock, full-screen-intent capability), `android/.../MainActivity.kt` (native channel creation + `setBypassDnd`).
- **OS-death backstop lead computation:** `lib/services/tracking/notification_updater.dart` (~1 Hz re-arm; the 60 s stops/distance lead lives here).
- **Route fetch + identity:** `lib/services/direction_service.dart` → `lib/services/api_client.dart` → Railway proxy; `RouteCache` (Hive L2, 5-min TTL) / `RouteRegistry` / `RouteSessionManager`.
- **Metro N-stops:** `lib/services/transfer_utils.dart` (stop building, city vote, `stopCountConfidence`), `stop_matcher.dart`, `polyline_decoder.dart`, `lib/all_india_stops.dart` + `lib/data/metro_line_sequences.dart`.
- **Preflight/telemetry:** `lib/services/reliability/*`, `lib/services/telemetry/*`.
- **Recovery:** `lib/screens/splash_screen.dart` reads `TrackingStateStore` snapshot; native + FLN boot receiver re-arm scheduled notifications (no FGS restart).

---

## 4. Server + native + key management

- **Server:** `geowake-server/src/server.js` — an Express (Node 18) proxy on Railway. Its whole job is to hide the Google Maps key: the key exists only in Railway env (`GOOGLE_MAPS_API_KEY`), injected inside `googleApiProxy`, never in a response/log/APK. The app authenticates by POSTing the public bundle id (`com.geowake.app`) to `/api/auth/token` for a 24 h JWT, then hits `/api/maps/*`. **This is a hard, un-fallbacked dependency for starting a trip** — if the proxy is down/slow, no route can be fetched and nothing can be armed. Auth is only a bundle-ID string (quota is drainable); there is no attestation. See `docs/system_map/16_server_railway.md`.
- **Native (Android):** `MainActivity.kt` creates notification channels natively **before** any Dart post (importance/DND/sound freeze on first creation) and calls `setBypassDnd(true)` (no-op without `ACCESS_NOTIFICATION_POLICY` grant — never requested). `packages/wakepoint_native/.../WakepointNativePlugin.kt` provides the partial wake lock and `canUseFullScreenIntent()`. `android/app/src/main/AndroidManifest.xml` declares `USE_FULL_SCREEN_INTENT`, `SCHEDULE_EXACT_ALARM`, `USE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED`, `ACCESS_NOTIFICATION_POLICY`; FGS type is `location|mediaPlayback`; the only boot receiver is FLN's (scheduled notifications), not an FGS-restarting one. `AlarmReceiver.kt` is a 0-byte orphan.
- **Key management:** the previously leaked Maps key (`AIzaSyC0v…XHw0`) still needs rotation per the `build.gradle` comment (hardcoding was removed, exposure remains). Identity must stay aligned: `applicationId == com.geowake.app` across app `build.gradle`, server `APP_BUNDLE_ID`, and AdMob/IAP — a divergence 401s every token and kills routing. Real AdMob unit IDs are **not** wired (`AdService.configure` never called → ships Google's public TEST IDs; do not ship those to production).

---

## 5. What's proven vs unproven

**Proven (re-runnable):**
- The reachability theorem + its three preconditions (`test/reachability/reachability_test.dart`, 400k+ invariant checks): the bound is a real upper bound on progress and monotone-safe.
- Reachability wired into the real fire decision and validated end-to-end on the real EKF over real Bengaluru ride data in the offline replay harness (never-late: `fired==true && secondsMargin≥0`; monotonicity: reachability only advances a fire).
- The EKF reliability fixes on `sim-validation` (commit `cfe52d8`): covariance-PSD guard that killed a 518 km `s_est` spike, phantom-GPS rejection, velocity clamp, dt>1 s bounded coast, the audible backstop channel.
- ~1106-test whole-suite green locally, including reachability edge cases, telemetry, monetization, preflight (181 combinatorial), iOS backstop unit tests.

**Unproven / false confidence (do not trust):**
- **Never-late as an app-wide property** — proven only for **metro-stops mode** with a pre-tunnel fix and registered geometry (the one path the harness exercises). Distance / non-metro time / non-metro 60% / geofence have no physics net.
- **The flagship "boarded already underground" case** — the dropout evaluator early-returns without a prior fix/EKF, and the anchor seeds `s=0` at the route origin. The replay harness does not exercise this.
- **Real-device survival** — zero on-device instrumented proof that the wake fires after a force-kill/Doze/reboot on an aggressive-OEM Android 14/15 phone. Telemetry that would show it has no emit sites and evaporates on the kill it measures.
- **Synthetic dashboards** — dead-reckoning is not honestly validated there (`_positionAtTime` is linear-in-time, decoupled from the fabricated IMU). Only the recorded-fixture path is honest for GPS-dead.
- **Metro data** — the shipped `allIndiaStops`/`kMetroLineSequences` are never validated at runtime; the CI-style validator audits an unshipped JSON; the one Dart test is circular. The 9 flagged lines + Gurugram fall to uniform guesses.
- **iOS** — the backstop is pure+tested but unwired; the live location manager lacks iOS background flags. iOS is effectively unbuilt for the underground case.

---

## 6. Prioritized backlog (from `GAP_ANALYSIS.md`)

Do these in order; the first four are ship-blockers.

1. **Arm-time honesty.** Enforce the preflight `block` verdict (refuse to arm on notifications-off/DND/no-exact-alarm; "Fix & retry" not "Proceed anyway"). Stop hard-blocking cross-state routes (the interstate sleeper). `homescreen.dart:263,791,1038-1052`.
2. **Make the never-late net run and cover every mode.** Drive reachability from a wall-clock tick that never early-returns; seed the anchor at arm time from the first real on-route fix (not `s=0` at origin); feed the reach bound / symmetric ETA lower-bound into distance, non-metro time, non-metro 60%, and geofence. `location_stream_handler.dart:446-555`, `alarm_controller.dart:411,1182`, `alarm_evaluator.dart:1177-1184`, `ekf_orchestrator.dart:342-358`.
3. **A trustworthy, mode-accurate, kill-surviving backstop.** Real stops/distance lead (not 60 s) re-derived from the reach bound; cancel/re-arm 991 on every path; fix Android-14+ boot/watchdog resume (split the FGS to `location`-only + custom boot receiver catching `IllegalStateException`). `notification_updater.dart:191-218`, `notification_service.dart:1466-1507,1663-1682`, `AndroidManifest.xml:64-66`.
4. **Measure + gate.** Persistent telemetry sink emitting on-time-vs-late + OS-kill/Doze/backstop-fired; commit fixtures and put the never-late replay gate in CI (fail-not-skip) with never-early/wrong-place assertions; bump `versionCode` off the hardcoded `1`. `telemetry/*`, `test/ekf/replay_harness_test.dart:38`, `build.gradle:22-23`.
5. **Fix-soon (high harm):** `V_LINE` city plumbing + unknown→`absoluteCeilingMps`; route-geometry-independent DR + compact persisted polyline; DND + full-screen-intent request paths; OEM `_applyFix` deep-links + verification; offline route pinning; reroute whitelist for commuter/tram/light-rail; audible wrong-direction alert; ETA σ floor + wire the scheduled metro ETA; runtime metro-data validation + ordered sequences for the 9 flagged lines/Gurugram; consume `stopCountConfidence`; server attestation + `response.data.status` handling.
6. **Monitor:** watchdog `hardTMaxSeconds`/topology cap; power-tier re-evaluation; arm-race ordering; equirectangular snapping; APK bloat; R8 keep-rules; `RouteLogger` privacy; monetization wiring.

---

## 7. Landmines — "if you touch X, beware Y"

- **If you touch reachability, beware you cannot ever make it fire later.** It is the whole safety story. Preserve monotonicity (`fireTs(reach on) ≤ fireTs(reach off)`), never re-anchor on a sentinel (`accuracy ≥ 9999`), and never let `V_LINE` resolve below the true line speed. A too-low `V_LINE` is a silent late-fire; an unknown line must default to the **highest** ceiling, not the lowest.
- **If you touch the alarm controller / evaluator, beware the reach bound is passed only to the metro `evaluateCoinciding` path.** Adding a new mode without threading `effectiveProgress`/reach bound ships a mode with no never-late guarantee, and the code comments will lie to you that protection is universal.
- **If you touch `trackingservice.dart`, beware the ~40 module-level session globals** reset by hand in ≥4 places (`_onStop`, `_handleBackgroundStartTracking`, `resetForTesting`, `initialData`). A missed field bleeds state into the next journey (stale EKF snapshot / max-progress → misfire). Also: `startService()` precedes `setActive()` — do not widen that window (recovery `_onStart(null)` can `stopSelf()` the isolate being armed).
- **If you touch the EKF, beware it only exists when a `RouteGeometry` with ≥2 points is registered**, and cold-start seeds `s=0` at the route origin. Both are load-bearing bugs, not features.
- **If you touch notifications/backstop, beware backstop cancellation is duplicated and inconsistent** (`trackingservice.dart:925`, `notification_updater.dart:180`, and **omitted** in the background `END_TRACKING` handler + `cancelAllNotifications`). Any new stop path must call `cancelEtaBackstop()` or it leaks a spurious wake. The live alarm channel is silent by design; the backstop channel self-sounds — don't "fix" the silence.
- **If you touch the Android manifest/FGS, beware the type is `location|mediaPlayback`** and starting that from background/boot throws `ForegroundServiceStartNotAllowedException` (an `ISE`) on 14+, which the plugin does not catch. Splitting the FGS is the fix, but test boot + OEM-kill on a real 14/15 device.
- **If you touch config, beware `DeviationConfig`/`AppConfig` are false single-sources-of-truth** — live deviation thresholds and the server bundle id are re-hardcoded inline. Editing the "central" config changes nothing live, and a bundle-id divergence 401s every token and kills all routing.
- **If you touch metro data, beware the validator audits `assets/india_metro/metro_dataset.json` — a file no device loads.** The app runs `all_india_stops.dart` + `metro_line_sequences.dart`, cross-checked by nothing; the only Dart test is circular (matches the shipped order against itself). `assets/india_metro` isn't even in `pubspec.yaml`.
- **If you touch simulation/dashboards, beware dormant demo code (`DemoRouteSimulator`/`DevServer`) forces `isTestMode=false` and would fire REAL alarms if re-wired**, and any injected `SimulationClient` position mutes real GPS for the rest of the session. Keep the release build flag `PLAYGROUND_BRIDGE_ENABLED` off.
- **If you touch monetization, beware the no-ad-on-alarm guarantee is convention, not structure** — a raw `BannerAd` bypassing `AdPolicy` would break it. Route every ad surface through `AdPolicy`; the reliability getters must stay unconditionally `true` (the alarm must never depend on entitlement).
- **If you build a release APK, beware `versionCode 1` is hardcoded** (Play rejects the second upload) and R8 keep-rules miss `wakepoint_native`/ads/IAP (the wake path can break **only in release**). Smoke-test the wake path on a release build.
