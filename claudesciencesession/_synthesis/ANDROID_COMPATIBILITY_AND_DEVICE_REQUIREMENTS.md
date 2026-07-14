# WakePoint — 2026 Android Compatibility & Per-Device Requirements

**Recommended SDK config:** compileSdk 36 · targetSdk 36 · minSdk 24 · Java 11 + core-library desugaring · NDK r28. Delete the dead `.kts` build files.

## Actions (code guardrails)

- GRADLE (Groovy android/app/build.gradle): targetSdkVersion 34 -> 36 (URGENT — 34 is already Play-rejected); replace minSdkVersion flutter.minSdkVersion -> 24; sourceCompatibility/targetCompatibility VERSION_1_8 -> VERSION_11; kotlinOptions jvmTarget '1.8' -> '11'; keep compileSdk 36, ndkVersion 28.2.13676358, coreLibraryDesugaringEnabled true + desugar_jdk_libs 2.1.4.
- DELETE android/build.gradle.kts and android/app/build.gradle.kts — verified dead code (settings.gradle is Groovy-only). Then unify identity: move namespace off com.example.geowake2 to com.geowake.app in the surviving Groovy build (applicationId is already com.geowake.app).
- MANIFEST — ADD the missing permissions: WAKE_LOCK (CPU awake — currently missing, a direct product-death gap), USE_EXACT_ALARM (no maxSdk) + SCHEDULE_EXACT_ALARM android:maxSdkVersion=32, ACCESS_NOTIFICATION_POLICY (DND bypass), and RECEIVE_BOOT_COMPLETED (only if you implement reboot restart).
- MANIFEST — CHANGE the FGS type: android:foregroundServiceType="location" only (remove |mediaPlayback) and remove FOREGROUND_SERVICE_MEDIA_PLAYBACK. location has no Android-15 timeout and is boot-restart-legal; mediaPlayback adds zero lifetime, is banned from BOOT_COMPLETED, and forces an unjustifiable Play declaration.
- MANIFEST — REMOVE the unused permissions ACTIVITY_RECOGNITION and HIGH_SAMPLING_RATE_SENSORS (raw accel/gyro at <=100Hz need neither; each is needless onboarding friction / permission-profile bloat). Keep ACCESS_FINE + ACCESS_COARSE + ACCESS_BACKGROUND_LOCATION, FOREGROUND_SERVICE + FOREGROUND_SERVICE_LOCATION, POST_NOTIFICATIONS, USE_FULL_SCREEN_INTENT, INTERNET.
- ALARM ARCHITECTURE — pre-arm AlarmManager.setAlarmClock(AlarmClockInfo(triggerAtMillis, showIntent), opPi) at ride start as the guaranteed, Doze-immune, process-death-proof terminal fire. Do NOT use setExact/setExactAndAllowWhileIdle/WorkManager for the wake. Guard with canScheduleExactAlarms() on SDK_INT>=31.
- WAKELOCK — hold a single reference-counted PARTIAL_WAKE_LOCK inside the native location FGS for the whole ride (acquire with a ~2.5h safety timeout); register accel+gyro with maxReportLatencyUs=0 (no batching) for real-time delivery.
- BATTERY EXEMPTION — because a stationary sleeping rider's phone hits deep Doze (which ignores wake locks), guide users to a battery-optimization exemption FRAMED AROUND THE FOREGROUND SERVICE via the non-restricted ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS, plus per-OEM autostart deep-links. Do not hard-depend on the restricted direct-prompt for the alarm.
- NOTIFICATIONS/AUDIO — create channel 'wake_alarm_v1' once: IMPORTANCE_HIGH, USAGE_ALARM + CONTENT_TYPE_SONIFICATION sound (rings through silent/vibrate), setBypassDnd(true), CATEGORY_ALARM; loop the sound yourself. Separate low-importance channel for the ongoing FGS notice. Channel settings are immutable — bump the id to change them.
- SDK_INT GUARDS (implement all): >=30 two-step location request (foreground then background via Settings, never bundled); >=31 canScheduleExactAlarms() before setAlarmClock, approximate-only detection, try/catch ForegroundServiceStartNotAllowedException; >=33 request POST_NOTIFICATIONS; >=34 canUseFullScreenIntent() gate with heads-up fallback, ACCESS_BACKGROUND_LOCATION verified before background FGS start; every newer permission no-ops below its level.
- EDGE-TO-EDGE (mandatory at target 36) — wrap all screens in SafeArea and set SystemChrome.setSystemUIOverlayStyle so the full-screen alarm and map controls are not hidden under status/nav bars.
- BUILD OEM-BATTERY ONBOARDING WIZARD (device_info_plus + android_intent_plus) deep-linking Xiaomi Autostart, Oppo/Vivo/Realme auto-launch, Samsung 'Never sleeping apps' — the single biggest reliability lever for the India-first market, independent of Android version.
- GRACEFUL DEGRADATION — detect gyroscope absence and no-GMS at runtime; fall back to accel+GPS-only estimation (wider safety margin) and platform LocationManager instead of fused location, and disable ads/IAP/maps on no-GMS. Keep all GMS features off the alarm-critical path.
- PLAY CONSOLE — file all declarations before upload: Foreground Service (location type, 2h screen-off justification + video), Background Location (prominent in-app disclosure + video + privacy policy), exact-alarm restricted-permission (alarm), and full-screen-intent (alarm). Missing declarations = policy rejection even with correct SDK config.
- PRE-RELEASE HYGIENE — replace the hardcoded Google Maps dev key in build.gradle defaultConfig and the AdMob TEST app-id (ca-app-pub-3940256099942544~3347511713) in the manifest with real IDs via key.properties; add a real release signingConfig (currently none in the Groovy release block). Confirmed no Firebase in pubspec, so no Firebase Gradle plugin is needed.

## Full synthesis

## WakePoint — Unified 2026 SDK config, code guardrails & per-device-class capability

Synthesis of five compatibility research outputs, cross-checked against the live project files (`android/app/build.gradle`, the dead `.kts` pair, `AndroidManifest.xml`, `pubspec.yaml`).

---

### 1. RECOMMENDED gradle SDK config

Edit the **Groovy** `android/app/build.gradle` (the live file — Gradle ignores the `.kts` when both exist, and `settings.gradle` is Groovy-only so there is no `.kts` fallback):

```groovy
android {
    namespace "com.geowake.app"          // move off com.example.geowake2
    compileSdk 36                         // already correct
    ndkVersion "28.2.13676358"            // NDK r28 -> 16 KB-aligned by default (keep)

    defaultConfig {
        applicationId "com.geowake.app"
        minSdkVersion 24                  // floor is 23 (AdMob GMA v24); 24 = 99.1% reach
        targetSdkVersion 36               // was 34 -> ALREADY Play-rejected; 36 future-proofs
        versionCode 1
        versionName "1.0.0"
    }
    compileOptions {
        coreLibraryDesugaringEnabled true            // REQUIRED by flutter_local_notifications ^19
        sourceCompatibility JavaVersion.VERSION_11   // was VERSION_1_8
        targetCompatibility JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = "11" }               // was "1.8"; match Kotlin 2.1.10
    buildTypes {
        release {
            minifyEnabled true
            shrinkResources true
            signingConfig signingConfigs.release      // add a REAL release signing config
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }
}
dependencies { coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4' }
```

| Setting | Value | Justification |
|---|---|---|
| compileSdk | **36** | Compile against Android 16 APIs; required for targetSdk 36. Already set. |
| targetSdk | **36** | Play floor is 35 since 31 Aug 2025 and **36 from 31 Aug 2026**. Live value `34` is rejected today. One jump = one migration. |
| minSdk | **24** | Hard floor **23** (google_mobile_ads → GMA SDK v24). 24 keeps 99.1% reach for a clean base. Replaces `flutter.minSdkVersion`. |
| Java src/tgt | **11** | AGP 8.9.2 baseline; keep desugaring for flutter_local_notifications ^19. Live value is 1.8. |
| Kotlin jvmTarget | **11** | Must match Java. Live value is 1.8. |
| NDK | **r28** (28.2.13676358) | 16 KB page alignment (mandatory for targetSdk 35+). Already set. |

**Build-file resolution (VERIFIED):** the live config is the Groovy pair; the `.kts` pair (Java 11, `com.geowake.app`, `flutter.*` values) is dead code and a maintenance trap. **Delete `android/build.gradle.kts` and `android/app/build.gradle.kts`.** Confirmed by the presence of a Groovy-only `settings.gradle`.

---

### 2. CODE GUARDRAILS CHECKLIST — every `Build.VERSION.SDK_INT` branch

| SDK_INT | Guard | Do |
|---|---|---|
| **>= 30** | Background-location split | Request `ACCESS_FINE`(+COARSE) first; only after grant, separately request `ACCESS_BACKGROUND_LOCATION` (OS opens Settings). Never bundle — bundling grants neither. Re-check at every ride start (one-time grants + auto-reset drop silently). |
| **>= 31** | Exact-alarm gate | `if (SDK_INT < 31 \|\| alarmManager.canScheduleExactAlarms()) setAlarmClock(...) else startActivity(ACTION_REQUEST_SCHEDULE_EXACT_ALARM)`. With `USE_EXACT_ALARM` declared this returns true on 33+. |
| **>= 31** | Approximate-only location | Detect FINE-requested-but-COARSE-granted; block with "Precise location required". |
| **>= 31** | Background FGS start | Wrap `startForegroundService` in try/catch for `ForegroundServiceStartNotAllowedException`; only (re)start from a visible activity, exact-alarm fire, notification tap, or BOOT_COMPLETED. |
| **>= 33** | Notifications | Request `POST_NOTIFICATIONS` at runtime (no-op below 33). |
| **>= 34** | Full-screen intent | `if (SDK_INT < 34 \|\| nm.canUseFullScreenIntent()) postFSI() else { startActivity(ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT); post max-importance heads-up + looping USAGE_ALARM audio }`. Denied FSI must never mean silence. |
| **>= 34** | Location FGS prereq | Verify `ACCESS_FINE_LOCATION` granted + location services ON + `ACCESS_BACKGROUND_LOCATION` for background start, before `startForeground`, else catch `SecurityException`. |
| **>= 35** | FGS type | Start service as **`location`** only from BOOT_COMPLETED (mediaPlayback/dataSync are boot-banned). |
| **all** | Doze/wake lock | Hold `PARTIAL_WAKE_LOCK`; gate ride-arm on `isIgnoringBatteryOptimizations()` and warn if false (deep Doze ignores wake locks). |
| **all** | Sensors | Register accel+gyro at <=100 Hz, `maxReportLatencyUs=0`; detect gyro absence → accel+GPS fallback; log delivered rate (mic-toggle-off throttles). Keep sensor+location work INSIDE the FGS (Android 16 job quotas). |

---

### 3. PER-DEVICE-CLASS capability statement (for founder → users/investors)

- **Mainstream Android (Pixel / recent Samsung / stock) — FULLY.** Wakes reliably with only standard permission prompts. The no-timeout location service + Doze-piercing `setAlarmClock` deliver the 2h screen-off guarantee. *Samsung caveat:* add WakePoint to "Never sleeping apps" so live tracking survives (the alarm fires either way).
- **Aggressive-OEM Android (Xiaomi, Oppo, Vivo, Realme, OnePlus, Transsion) — WITH_SETUP.** The dominant India class and the top product-death risk. The pre-armed system alarm still rings, but the live tracking service is killed unless the user enables **Autostart**, sets battery to **Unrestricted**, and **locks the app in recents** — driven by an in-app OEM onboarding wizard. Honest limit: some firmware ignores even these; the system-level pre-armed alarm is the safety net.
- **Android Go / low-RAM (2GB) — WITH_SETUP.** Memory pressure kills the service; the pre-armed `setAlarmClock` (in system AlarmManager, not the app process) is the anchor. Needs battery exemption, a lightweight throttled/batched service, and a persistent notification. Live accuracy degrades; the wake is preserved.
- **No-gyroscope phones — DEGRADED.** Still wakes the rider via GPS + accelerometer + alarm; loses gyro-fused precision between fixes (tunnels, tight stops). App detects gyro absence and widens the safety margin (wakes slightly earlier).
- **Huawei/Honor & no-GMS/AOSP — DEGRADED.** The entire wake path works **offline** (exact alarm, sensors, location FGS, alarm audio, vibration, full-screen intent). Maps, Places, Ads, IAP, fused location, and FCM re-wake all fail — require raw LocationManager + bundled OSM assets + disabled monetization, all kept off the alarm-critical path. Some forks pre-deny exact alarms; verify on-device.
- **iOS — UNSUPPORTED (honest, un-closable for this architecture).** iOS gives no equivalent to a long-lived location foreground service + partial wake lock + high-rate background IMU + arbitrary alarm audio from a suspended app. A reduced iOS product (region monitoring, significant-location-change, critical-alert local notifications needing Apple approval) is possible but cannot make the same on-time screen-off promise. Scope separately or defer; do not represent it as feature-parity.

---

### HARD FACT vs INFERENCE
- **HARD FACT (official docs):** Play target-API floors (35 now / 36 by 31 Aug 2026); 16 KB alignment for targetSdk 35+; edge-to-edge at 36; FGS types + per-type permission (34); location FGS has no timeout and is boot-restart-legal while mediaPlayback/dataSync are boot-banned (35); `SCHEDULE_EXACT_ALARM` denied by default on 14; `USE_EXACT_ALARM` un-revokable + Restricted-bucket exemption (33); FSI appop for alarm/calling apps (34); deep Doze ignores wake locks; non-wake-up sensors don't hold a wake lock; 200 Hz cap (31); GMA v24 minSdk 23; Groovy-over-`.kts` precedence.
- **INFERENCE / field consensus:** `setAlarmClock` not being bucket-throttled (consistent with its Doze exemption though not named in the power table); OEM battery-killer severity ranking and OEM alarm-whitelisting behavior (empirical, not documented by Android); the API-36 → 31 Aug 2026 date (Google's rolling annual policy, widely reported) — targeting 36 is strictly safe either way.

### Key files
- `/home/raed/Projects/WakePoint/android/app/build.gradle` (fix SDK/Java/Kotlin/minSdk/namespace)
- `/home/raed/Projects/WakePoint/android/build.gradle.kts` + `/home/raed/Projects/WakePoint/android/app/build.gradle.kts` (delete)
- `/home/raed/Projects/WakePoint/android/app/src/main/AndroidManifest.xml` (add WAKE_LOCK / USE_EXACT_ALARM / SCHEDULE_EXACT_ALARM@maxSdk32 / ACCESS_NOTIFICATION_POLICY / RECEIVE_BOOT_COMPLETED; change FGS type to location-only + drop FOREGROUND_SERVICE_MEDIA_PLAYBACK; remove ACTIVITY_RECOGNITION + HIGH_SAMPLING_RATE_SENSORS; replace test AdMob id)