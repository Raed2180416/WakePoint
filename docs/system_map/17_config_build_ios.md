## Config, Build System, Platform & iOS

**Role in the core promise:** This subsystem is the *substrate* the wake-alarm runs on. It does not decide when to fire — but if it is wrong, nothing else can be right. Three things here directly gate the core promise ("wake a rider before their stop, never late, even when GPS dies underground, on a cheap Android phone in India"): (1) the **Android manifest + build config** must grant the OS permissions and declare the native receivers that let the app stay alive underground and wake the user after process death — miss one line and the alarm silently never fires; (2) the **tunable constants** (`FireDecisionConfig`, `DeviationConfig`, `PowerPolicy`) encode the "fire early rather than late" bias and the battery-vs-accuracy trade that must survive a 90-minute commute on a 3000 mAh phone; (3) the **iOS backstop planner** is the *only* never-late mechanism iOS gives us, because iOS suspends the app in a tunnel and forbids Android-style dead reckoning. As documented below, the Android substrate is solid and battle-hardened, but the iOS half is a **pure, well-tested module that is not wired to any real iPhone** — so on iOS the core promise is currently unmet at the code level.

---

**Files:**

| Path | What it does |
|---|---|
| `lib/config/app_config.dart` | Global constants: server base URL, app bundle id; deliberately *throws* on direct Maps-key access (keys now server-side). Largely documentation-only — see gaps. |
| `lib/config/fire_decision_config.dart` | The "never fire late" tunables: sigma multiplier `fractileK=2`, dead-reckon sentinels, accuracy gates, the 300 m sigma clamp. Consumed by the alarm decision core. |
| `lib/config/deviation_config.dart` | Centralised (aspirationally) deviation/reroute/termination magic numbers. In practice only the *termination* constants are wired; the rest are duplicated inline elsewhere. |
| `lib/config/power_policy.dart` | Battery-tiered location policy (`PowerPolicy` value object + `PowerPolicyManager.forBatteryLevel`): accuracy, distance filter, GPS-dropout buffer, notification tick, reroute cooldown. |
| `lib/config/playground_bridge.dart` | Feature flag + relay URL for the simulation/dashboard WebSocket bridge; auto-disabled in tests and release. |
| `lib/config/platform_test_flag_io.dart` / `_stub.dart` | Conditional-import pair: `detectFlutterTest()` — reads `FLUTTER_TEST` at compile-time (both) and from the process environment (io only). |
| `lib/config/test_mode_flag.dart` | File-based, cross-isolate test-mode flag. **Dead code** — zero consumers. |
| `pubspec.yaml` | Dart/Flutter dependency manifest, asset bundle list, app version (`1.0.0+1`), icon/splash config. |
| `android/app/build.gradle` | App-module Gradle: SDK levels, applicationId, keystore/Maps-key injection, R8/shrink release config, desugaring. |
| `android/build.gradle` | Project-level Gradle: repositories, shared build dir, clean task. |
| `gradle.properties` | JVM heap for the Gradle/Kotlin daemons (1536 MB). |
| `android/app/proguard-rules.pro` | R8 keep rules for `flutter_local_notifications` (dexterous) and gms location — protects the wake path from being stripped. |
| `android/app/src/main/AndroidManifest.xml` | (adjacent, load-bearing) Permissions, foreground-service types, exact-alarm receivers, OEM battery-manager query intents, Maps key placeholder. |
| `ios/Runner/Info.plist` | iOS permission strings, `location` background mode, orientation, bundle metadata. |
| `ios/Runner/AppDelegate.swift` | Bare Flutter app delegate — plugin registration only; **no native backstop wiring**. |
| `lib/services/ios/ios_backstop_planner.dart` | Pure planner for the iOS never-late backstop: earliest-arrival notification time + geofence rings. Unit-tested with a fake scheduler; **not connected to any real iOS scheduler**. |

---

### How it works, step by step

#### A. Android build → running app (the substrate the alarm needs)

1. **Version toolchain.** `android/settings.gradle` pins Android Gradle Plugin `8.9.2`, Kotlin `2.1.10`, and loads the Flutter plugin loader. The root project name is `geowake2`.
2. **SDK envelope** (`android/app/build.gradle:14-23`): `namespace "com.example.geowake2"`, `compileSdk 36`, `ndkVersion "28.2.13676358"`, `minSdkVersion 24` (Android 7.0 — deliberately low to reach cheap/old phones in India), `targetSdkVersion 35`, `versionCode 1`, `versionName "1.0"`, `applicationId "com.geowake.app"`.
3. **Maps key injection** (`build.gradle:7-11, 30-33`): if `android/key.properties` exists (gitignored), its `googleMapsApiKey` is loaded into `manifestPlaceholders`. `AndroidManifest.xml:56-58` substitutes `${googleMapsApiKey}` into the `com.google.android.geo.API_KEY` meta-data that the Maps SDK reads at runtime. If the file is absent the placeholder is `''` — the map renders blank and *fails loudly* rather than shipping a hardcoded secret (see Design Decision 6).
4. **`applicationName` placeholder** → `AndroidManifest.xml:28` sets `android:name="${applicationName}"` = `io.flutter.app.FlutterApplication`, the stock Flutter Application class.
5. **Release shrinking** (`build.gradle:47-54`): `minifyEnabled true` + `shrinkResources true` run R8. It consumes the default optimize rules plus `proguard-rules.pro`. That file keeps the `com.dexterous.**` classes (the `flutter_local_notifications` scheduled-alarm + boot + action receivers) and the gms location `zze` class, so R8 cannot strip the exact-alarm wake path in release.
6. **Desugaring** (`build.gradle:36-40, 62-63`): `coreLibraryDesugaringEnabled true` + `desugar_jdk_libs:2.1.4` — lets `flutter_local_notifications` (which uses `java.time`) run on `minSdk 24` where those APIs are otherwise missing.
7. **Runtime permission surface** (`AndroidManifest.xml:3-25`): fine+coarse+background location, `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `POST_NOTIFICATIONS`, `WAKE_LOCK` (G1 — hold CPU with screen off), `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (G2 — escape Doze), `SCHEDULE_EXACT_ALARM`+`USE_EXACT_ALARM` (G5 — the process-death backstop), `RECEIVE_BOOT_COMPLETED` (G4 — re-arm after reboot), `ACCESS_NOTIFICATION_POLICY` (G9a — bypass Do-Not-Disturb on the alarm channel), plus `ACTIVITY_RECOGNITION`, `HIGH_SAMPLING_RATE_SENSORS`, `USE_FULL_SCREEN_INTENT`.
8. **Components** (`AndroidManifest.xml:37-90`): `MainActivity` is `showWhenLocked`+`turnScreenOn` (the alarm screen appears over the lockscreen); the `flutter_background_service` `BackgroundService` is declared `foregroundServiceType="location|mediaPlayback"`; and — critically — the three `com.dexterous.flutterlocalnotifications.*` receivers are hand-declared because plugin v16+ stopped auto-declaring them (without these, `zonedSchedule(alarmClock)` fires but nothing catches it → the post-process-death alarm never delivers).
9. **OEM survival plumbing** (`AndroidManifest.xml:94-117`): `<queries>` lists Xiaomi/Oppo/Vivo/Huawei/OnePlus/Samsung security-center packages so the app can detect and deep-link into the aggressive OEM "autostart / battery" managers that would otherwise kill a background tracker in India.

#### B. The fire-decision tunables (`FireDecisionConfig`) — the never-late knobs

These constants are read directly by the alarm core (`alarm_evaluator.dart`, `alarm_controller.dart`, `location_manager.dart`, `location_stream_handler.dart`):

- `fractileK = 2.0` — fire at `(median − 2σ)` of ETA/position. Two sigmas ≈ 97.7% one-sided confidence that we are *not late*. Used at `alarm_controller.dart:795, 1181` and `alarm_evaluator.dart:71`.
- `maxFractileSigmaMeters = 300.0` — clamps the σ *fed into firing* to 300 m even though the EKF's honest σ can grow to ~3 km underground. Prevents the k·σ cushion from ballooning to kilometres and firing every stop absurdly early. Applied via `.clamp(0.0, 300)` at `alarm_evaluator.dart:101, 728, 847, 1551` and `alarm_controller.dart:1583`. (Does NOT clamp the filter's *reported* σ — only the fire input.)
- `deadReckonAccuracySentinel = 9999.0` — accuracy stamped on a synthesized dead-reckoned evaluation `Position` so downstream refuses to snap/ingest it as a real fix. Written at `location_stream_handler.dart:570`; checked at `alarm_controller.dart:416` (`acc < 9999` ⇒ real fix).
- `dropoutEvalMinInterval = 2 s` — throttle for the GPS-dropout re-evaluation tick (which can run every 1 s) to avoid notification churn. Gated at `location_stream_handler.dart:560`.
- `approximateLocationAccuracyMeters = 500.0` — fixes worse than 500 m are treated as *no GPS* (Android 12 "approximate location" grant). Checked at `location_manager.dart:314`.
- `defaultAccuracyGateMeters = 100.0` — fallback accuracy gate when no alarm-threshold-derived gate exists. Used at `location_manager.dart:318`.

#### C. Battery policy (`PowerPolicy` / `PowerPolicyManager.forBatteryLevel`)

`PowerPolicyManager.forBatteryLevel(int levelPercent)` returns one of three immutable `PowerPolicy` tiers, consumed at `trackingservice.dart:2246-2247` and `location_stream_handler.dart:201-202` (which substitute `PowerPolicy.testing()` when in test mode):

| Tier | Battery | accuracy | distanceFilter | gpsDropoutBuffer | notificationTick | rerouteCooldown |
|---|---|---|---|---|---|---|
| Normal | > 50% | high | 5 m | 25 s | 1 s | 20 s |
| Medium | 20–50% | medium | 15 m | 30 s | 2 s | 25 s |
| Low | ≤ 20% | low | 50 m | 40 s | 3 s | 30 s |
| Testing | (flag) | high | 5 m | 2 s | 50 ms | 2 s |

As battery drops, GPS precision is traded away and the "how long before we treat GPS as dropped" buffer stretches (25→40 s) so the app doesn't thrash the radio — a survival trade for the tail end of a long commute.

#### D. iOS backstop planner (pure) — `IosBackstopPlanner.plan()` → `.arm()`

1. **Input**: `plan({routeDistanceMeters, nowEpochMs, city?, lineName?, originProgressMeters?, vLineTable, radii...})`.
2. **Resolve the speed ceiling**: `_earliestArrivalEpochMs` calls `vLineTable.forLine(city, lineName)` (from `core/reachability/reachability.dart`). This returns an *overbound* of the line's true top speed: `defaultMps=28` (100 km/h metro), `expressMps=39` (~140 km/h airport express), `rrtsMps=53` (~190 km/h Namo Bharat / RRTS), or `absoluteCeilingMps=56` (~200 km/h, used when unknown). RRTS/express detection is keyword-based (`looksRrts`, `looksExpress`).
3. **Compute earliest arrival** (`ios_backstop_planner.dart:224-255`): `remaining = max(0, routeDistanceMeters − originProgressMeters)`; `t_earliest = now + (remaining / V_LINE) * 1000 ms`. Because `V_LINE ≥ true max speed`, the train *physically cannot* arrive before `t_earliest` → scheduling a notification there is **never-late by physics** (it merely fires early when the train runs slower, which is the safe state).
4. **Every guard falls to the safe side**: a non-finite/≤0 V_LINE → `absoluteCeilingMps` (faster → earlier → safe); a non-finite distance → return `now` (fire immediately → safe); `_toEpochInt` *floors* (never rounds up) so sub-ms remainder pulls the fire time earlier.
5. **Emit rings**: a `destination` ring (default 200 m radius) and a `pre_stop` "N stops before" ring (default 500 m), radii sanitised to positive-finite via `_sanitiseRadius`.
6. **`arm(plan, scheduler)`** (`ios_backstop_planner.dart:199-215`): schedules exactly one backstop notification, then registers each ring — **each in its own `try/catch`** so one failing net never prevents the others arming ("one failure ⇒ never fires" is the cardinal sin).
7. **Seam**: the concrete `IosScheduler` (which would call `UNUserNotificationCenter` + `CLLocationManager` region monitoring) is abstract; only `FakeIosScheduler` (test-only, records calls) exists in the repo. **No production implementation is present** (see gaps).

---

### Key types & functions

- `AppConfig` (`app_config.dart`) — `static String get googleMapsApiKey` *throws* (deliberate); `apiKeySource → 'Secure Server'`; `const serverBaseUrl`, `const appBundleId = 'com.geowake.app'`. Consumed only nominally by `api_client.dart` (which re-hardcodes both values).
- `FireDecisionConfig` (`fire_decision_config.dart`) — 7 static `const` never-late tunables. Pure constant holder; no methods.
- `DeviationConfig` (`deviation_config.dart`) — private ctor `DeviationConfig._()`; ~30 static `const` deviation/reroute/termination constants + test overrides.
- `PowerPolicy` (`power_policy.dart`) — immutable value object `{accuracy, distanceFilterMeters, gpsDropoutBuffer, notificationTick, rerouteCooldown}`; `static testing()`.
- `PowerPolicyManager.forBatteryLevel(int) → PowerPolicy` — pure tier selector.
- `PlaygroundBridgeConfig` (`playground_bridge.dart`) — `static bool get enabled` (false in tests / when disabled-flag set; true if enabled-flag or debug/profile); `const relayUrl = ws://127.0.0.1:8081`.
- `detectFlutterTest() → bool` — conditional-import shim; io variant also checks `Platform.environment['FLUTTER_TEST']`.
- `TestModeFlag` — `setTestMode(bool)`, `isTestMode() → Future<bool>`, `clearCache()`; disk-file flag under the app documents dir. **Unused.**
- `IosBackstopPlanner.plan(...) → BackstopPlan` and `static Future<void> arm(BackstopPlan, IosScheduler)` — pure planner + arming driver.
- `GeofenceRing {id, radiusMeters, kind}`, `GeofenceRingKind {destination, preStop}`, `BackstopPlan {earliestArrivalEpochMs, rings}`, `abstract IosScheduler {scheduleLocalNotification, monitorRegion}`, `FakeIosScheduler` (test double).

---

### Design decisions (the WHY)

1. **Maps API key comes only from gitignored `key.properties`, empty fallback fails loudly** (`build.gradle:25-33`). *Why:* a prior build shipped a *live* key hardcoded in source (and it leaked into chat transcripts) — a billing/abuse risk and a Play policy flag. *Trade-off:* a fresh clone or CI with no `key.properties` builds an app whose map is blank; developers must be handed the key out-of-band. *Flaw:* the comment says "ROTATE the exposed key AIzaSyC0v…XHw0" — this is an **open security action item**; if the leaked key was never rotated, the abuse window is still open regardless of this fix.

2. **Google Maps key access in Dart throws** (`app_config.dart:4-8`). *Why:* all Maps/Places/Directions calls are proxied through the Railway server (`ApiClient`) so no key ships in the Dart/JS-reachable layer. *Trade-off:* every geocode/route needs a network round-trip to your own server — a latency and availability dependency. *Flaw:* the native Android Maps *rendering* key still ships in the manifest (unavoidable for the Maps SDK), so "no key in the app" is only true for the *web-service* key, not the map-tile key.

3. **`fractileK = 2` and the 300 m σ clamp** (`fire_decision_config.dart:11, 41`). *Why:* firing at `median − 2σ` buys ~97.7% confidence against a late alarm; clamping the *fire-input* σ to 300 m stops the honest ~3 km underground σ from making the alarm fire absurdly early and eroding trust. *Trade-off:* explicitly biases toward early fires (minor annoyance) over late (product death). *Flaw:* the 300 m clamp is a hand-picked "1–2 inter-station spacings" heuristic — on a line with >300 m station spacing during a long blackout the clamp could in principle admit a *late* fire, because it discards real uncertainty above 300 m. It is safe only under the assumption that station topology (the stop-count cap in `reachability.dart`) dominates before σ would exceed 300 m.

4. **Three battery tiers, coarse boundaries at 50%/20%** (`power_policy.dart:27-57`). *Why:* a wake alarm must survive a 60–90 min commute; degrading GPS precision and stretching the dropout buffer as battery falls trades accuracy for endurance. *Trade-off:* the "low" tier uses `LocationAccuracy.low` + 50 m distance filter — on a slow metro that coarse fix could blur which station you're at. *Flaw:* the tiers are hard step functions with no hysteresis; a phone hovering at 50% or 20% (common with charging quirks) can flip tiers repeatedly, churning the location-stream config mid-trip. There is also no tier that *raises* accuracy as the destination nears.

5. **`DeviationConfig` presented as "centralized… consistent tuning across the codebase"** (`deviation_config.dart:1-5`). *Why (intended):* one place to tune deviation/reroute magic numbers. *Reality / FLAW:* only `tracking_termination_policy.dart` actually reads it (the termination constants). The core deviation params it documents — `baseThresholdMeters`, `speedCoefficientK`, `hysteresisRatio`, `sustainDuration`, `switchMarginMeters` — are **re-declared as inline defaults** in `deviation_monitor.dart` (`SpeedThresholdModel(... k=1.5, hysteresisRatio=0.7)`) and `active_route_manager.dart` (`sustainDuration=6s`, `switchMarginMeters=50`). So editing `DeviationConfig.baseThresholdMeters` changes *nothing* in the live deviation detector. The "centralized" claim is misleading and a **config-drift trap**: two sources of truth that can silently diverge.

6. **`AppConfig.serverBaseUrl` / `appBundleId` are constants nobody uses** (`app_config.dart:16-23`). *Why (intended):* single source of truth for server URL and bundle id, with a comment demanding they match `build.gradle` and the server config. *Reality / FLAW:* `api_client.dart:9-10` re-hardcodes the identical URL in its own `_baseUrl` const, and `api_client.dart:114` hardcodes `'com.geowake.app'` with the comment *"Must match AppConfig.appBundleId"* — i.e. the constant is copied by hand, not referenced. `AppConfig` is effectively dead documentation; the very drift it was meant to prevent is baked in.

7. **`versionCode 1` / `versionName "1.0"` hardcoded in Gradle** (`build.gradle:22-23`), *not* wired to `flutterVersionCode`/`flutterVersionName` from `pubspec.yaml` (`version: 1.0.0+1`). *Why:* likely a scaffold left-over. *FLAW (release blocker):* the Play Store **rejects any upload whose `versionCode` is not strictly greater than the last**. With `versionCode` frozen at `1`, every build ships the same code and the *second* production upload will be refused. Bumping `pubspec.yaml` does nothing because Gradle ignores it here. This must be changed to `flutter.versionCode`/`flutter.versionName` before a real release.

8. **R8 keep-rules are minimal and hand-curated** (`proguard-rules.pro`). *Why:* keep only what reflection/AlarmManager needs — `com.dexterous.**` (notifications wake path) and gms location `zze`. *Trade-off:* smaller, faster-to-reason-about rules. *FLAW:* the list is not exhaustive. `google_mobile_ads`, `in_app_purchase`, and the local `wakepoint_native` plugin (which has **no consumer `-keep` `.pro` file** of its own — verified: `packages/wakepoint_native/android/` ships none) rely entirely on Flutter's default keep rules + being referenced from generated code. If R8 ever strips a reflectively-accessed method channel in the native wake-lock/full-screen-intent plugin, the failure would appear *only in release builds* and only on the wake path — the worst possible place. No release-mode wake-path smoke test is evident.

9. **iOS backstop is pure and injectable via `IosScheduler`** (`ios_backstop_planner.dart:95-101`). *Why:* keeps the never-late math unit-testable headless (no plugin import, no wall-clock read), and lets the two safety nets (time + geofence) be armed independently so one failing can't disarm the others (`arm` per-call try/catch). *Trade-off:* the whole thing depends on a concrete `IosScheduler` that someone must implement in Swift. *FLAW (critical):* **that implementation does not exist.** Repo-wide search finds `IosBackstopPlanner`/`IosScheduler` referenced only by the module itself and its two test files (`test/ios/*`), and `AppDelegate.swift` is bare (plugin registration only). On a real iPhone nothing calls `plan()`/`arm()`, so the iOS never-late guarantee is *designed and proven in isolation but never invoked*.

10. **iOS `Info.plist` declares only the `location` background mode** (`Info.plist:56-59`). *Why:* iOS suspends the app in a tunnel within seconds; the `location` mode + `allowBackgroundLocationUpdates=true` is the one lever that keeps the tracker alive, and region-entry can wake a suspended app. *Trade-off:* no `audio`/`processing` background mode — the alarm must come from a scheduled local notification, not from a background-running player. *FLAW:* combined with #9, the plist grants the capability but no code uses region monitoring or `UNUserNotificationCenter` scheduling, so the capability is inert today.

11. **`minSdk 24`, `targetSdk 35`, `compileSdk 36`** (`build.gradle:15, 20-21`). *Why:* `minSdk 24` (Android 7.0) reaches the cheap/old Android base in India — central to the core promise. *Trade-off:* pre-API-26 devices lack `java.time` (handled by desugaring) and have weaker background-execution guarantees. *FLAW/watch:* `targetSdk 35` is one behind `compileSdk 36`; Google Play's rolling "target within one year of latest" requirement means 35 may fall below the accepted floor during this app's shelf life and force a bump (which can surface new background-execution restrictions to re-validate).

12. **`namespace "com.example.geowake2"` ≠ `applicationId "com.geowake.app"`** (`build.gradle:14, 19`; `settings.gradle` root name `geowake2`; `Info.plist` `CFBundleName geowake2`). *Why:* the Dart package and scaffold were named `geowake2`; the shippable identity was later set to `com.geowake.app`. Gradle permits namespace ≠ applicationId. *Trade-off:* the generated `R`/`BuildConfig` and `MainActivity` live under `com.example.geowake2` while the installed package is `com.geowake.app`. *FLAW:* it is an inconsistency landmine — the AdMob `APPLICATION_ID` (below), server `APP_BUNDLE_ID`, in-app-purchase product owner, and any future deep-link/signing config must all key off `com.geowake.app`, and the lingering `com.example.*` namespace invites copy-paste of the wrong identifier. (User-facing name is fine: `android:label="GeoWake"`, `CFBundleDisplayName GeoWake` — matches the memory rule; only internal identifiers say `geowake2`.)

13. **`PlaygroundBridgeConfig` auto-disables in tests and release** (`playground_bridge.dart:34-39`). *Why:* release builds must not try to open a `ws://127.0.0.1:8081` localhost socket (would stall startup with no relay), and unit tests must stay hermetic without extra dart-defines. *Trade-off:* the simulation mirror is unavailable in profile-mode field testing unless the enable-flag is passed. Clean, low-risk decision.

14. **`test_mode_flag.dart` uses a disk file for cross-isolate visibility** (`test_mode_flag.dart:1-9`). *Why (intended):* `static bool` lives per-isolate, so the background service isolate can't see a flag flipped in the UI isolate; a file on disk is visible to both. *FLAW:* it is **dead code** — no file in the repo references `TestModeFlag`. Test mode is actually driven elsewhere (`PowerPolicy.testing()`, `detectFlutterTest()`, and dart-define flags). It is either an abandoned approach or a latent trap someone may wire up assuming it's live.

15. **AdMob application id in the manifest is Google's public *test* app id** (`AndroidManifest.xml:33-35`: `ca-app-pub-3940256099942544~3347511713`), matching the test *unit* ids in `ad_service.dart`. *Why:* safe placeholder during development (real ads would be policy-violating on a dev build). *Trade-off/FLAW:* ships zero real ad revenue until swapped, and — cross-referencing the iOS side — `Info.plist` has **no `GADApplicationIdentifier` key at all**. `google_mobile_ads` on iOS *hard-crashes at launch* (native `GADInvalidInitializationException`) if that key is missing once `MobileAds.initialize()` runs; the Dart-side try/catch in `ad_service.dart` cannot catch a native launch-time assert. So enabling ads on iOS in its current state would crash the app before the never-late logic ever runs. (Details belong to `13_monetization.md`; flagged here as a build/plist gap.)

---

### Invariants

- **The three notification receivers must stay declared** (`AndroidManifest.xml:75-90`) and their classes kept by R8 (`proguard-rules.pro:14`) — else the post-process-death exact alarm fires into the void.
- **`applicationId` = `com.geowake.app`** must remain identical across `build.gradle`, the server's `APP_BUNDLE_ID`, and any in-app-purchase/AdMob config (`app_config.dart:19-23` documents this contract even though it isn't enforced in code).
- **`V_LINE ≥ true max line speed`** for every value in `VLineTable` — the entire iOS backstop (and reachability) never-late proof rests on this; a single too-low ceiling admits a late fire.
- **The iOS earliest-arrival time is monotonically ≤ true arrival** — preserved by flooring in `_toEpochInt` and by the safe-side fallbacks in `_earliestArrivalEpochMs`.
- **`arm()` must never let one net's failure disarm another** — enforced by per-call try/catch; must be preserved if the arming loop is refactored.
- **Release builds must have a strictly increasing `versionCode`** — currently *violated* by the hardcoded `1` (Design Decision 7).
- **A dead-reckoned Position carries `accuracy == 9999`** and must never be treated as a real fix (`FireDecisionConfig.deadReckonAccuracySentinel`).

### Interfaces

- **Consumes:** `core/reachability/reachability.dart` (`VLineTable`, `absoluteCeilingMps`) — the iOS planner's speed ceiling. `geolocator` (`LocationAccuracy`) — `PowerPolicy`. `path_provider` — `TestModeFlag`. `flutter/foundation` (`kDebugMode`/`kProfileMode`) — `PlaygroundBridgeConfig`.
- **Exposes to alarm core:** `FireDecisionConfig` → `alarm_evaluator.dart`, `alarm_controller.dart`, `location_manager.dart`, `location_stream_handler.dart`. `PowerPolicy`/`PowerPolicyManager` → `trackingservice.dart`, `location_stream_handler.dart`. `DeviationConfig` → `tracking_termination_policy.dart` (only).
- **Exposes to dashboards/sim:** `PlaygroundBridgeConfig` → `deviation_dashboard.dart`, `unified_dashboard.dart`, `simulation_client.dart`.
- **Build-time contracts:** `manifestPlaceholders.googleMapsApiKey` → `AndroidManifest.xml` Maps meta-data; `key.properties` (gitignored) → build.gradle; `pubspec.yaml` → the entire native/Dart dependency graph and the asset bundle (`assets/geowake.png`, `assets/ringtones/`, `assets/osm/`).
- **Platform-layer stub (unfulfilled):** `IosScheduler` is the seam a future Swift/plugin implementation must satisfy for the iOS backstop to actually arm; `AppDelegate.swift` is where region-monitoring + `UNUserNotificationCenter` delegate wiring would live.

---

### Gaps & flaws vs the core promise (brutally honest)

1. **[BLOCKER — iOS] The iOS never-late backstop is not wired to anything.** `IosBackstopPlanner`/`IosScheduler` are referenced only by their own tests; `AppDelegate.swift` is bare; `Info.plist` grants `location` background mode but no code does region monitoring or notification scheduling. iOS suspends the app in a tunnel and dead reckoning is forbidden there — so with the backstop unarmed, **an iPhone user gets no reliable underground wake at all.** The core promise is met on Android and *unmet in production on iOS*, despite the iOS math being proven in isolation.

2. **[BLOCKER — release] Frozen `versionCode 1`.** Play will reject the second upload; the app cannot ship iterative releases until Gradle is switched to `flutter.versionCode`/`flutter.versionName`.

3. **[HIGH — config drift] `DeviationConfig` and `AppConfig` are false single-sources-of-truth.** Live deviation thresholds are hardcoded inline in `deviation_monitor.dart`/`active_route_manager.dart`, not read from `DeviationConfig`; the server URL and bundle id are hand-copied into `api_client.dart` rather than referenced from `AppConfig`. Tuning the "central" file silently does nothing, and the duplicated bundle id can diverge from the server's `APP_BUNDLE_ID`, breaking auth. This directly risks the promise because deviation thresholds gate whether a reroute/late-stop is detected.

4. **[HIGH — iOS ads crash] Missing `GADApplicationIdentifier` in `Info.plist`.** If ads are enabled on iOS, `MobileAds.initialize()` triggers a native launch-time crash the Dart try/catch can't catch — killing the app before any wake logic runs. Must be added (with real ids) or ads must stay hard-disabled on iOS.

5. **[MEDIUM — release wake path] Non-exhaustive R8 keep rules + no release wake-path smoke test.** `wakepoint_native` (partial wake lock / full-screen-intent) ships no consumer `-keep` rules; a future R8 optimization could strip a reflective method channel and break the wake path *only* in release. There is no evidence of a release-mode end-to-end alarm test.

6. **[MEDIUM — security] Unrotated leaked Maps key.** The code correctly stopped hardcoding the key, but the comment indicates the previously-leaked key (`AIzaSyC0v…XHw0`) still needs rotation; until then it remains a billing/abuse exposure independent of the code fix.

7. **[LOW — battery tiers] Step-function tiers with no hysteresis and no near-destination boost.** Battery hovering at a boundary can churn the location config mid-trip, and the low-battery `LocationAccuracy.low`/50 m filter can blur station identity exactly when the rider most needs precision near the end of the trip.

8. **[LOW — hygiene] Dead code and identity smell.** `TestModeFlag` is unused (a latent trap), and the `com.example.geowake2` namespace vs `com.geowake.app` applicationId split invites wrong-identifier copy-paste across AdMob/IAP/server config.

9. **[LOW — platform reach] `targetSdk 35` behind `compileSdk 36`.** Likely to require a forced bump during the app's life, re-exposing background-execution behavior that must be re-validated against the underground-survival requirement.
