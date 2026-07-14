# WakePoint — Runtime & Lifecycle Reliability Map

**Question:** When the user is asleep, phone in pocket, screen off, app backgrounded — will the tracker even be *running* to fire the alarm? All claims cite real `file:line` in the repo. **Read-only audit; no files modified.**

**Verdict:** On **Android** the correct primitive (a `location` foreground service) is in place, so tracking *can* survive screen-off — but three unguarded gaps (OEM battery-killer, no wakelock, pause-on-UI-death) mean it frequently won't for a multi-hour sleeping commute. On **iOS the background premise is non-functional**: there is no `UIBackgroundModes`, so the OS suspends the app within seconds.

---

## 1. How is tracking kept alive in the background?

**Android — foreground service (correct mechanism, present).**
- `flutter_background_service` runs the tracking loop in a background isolate under an Android foreground service: `android/app/src/main/AndroidManifest.xml:52-54` declares the service with `android:foregroundServiceType="location|mediaPlayback"`.
- Permissions present: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` (`AndroidManifest.xml:7-10`); `ACCESS_BACKGROUND_LOCATION` (`:6`).
- Configured `isForegroundMode: true`, persistent notification id 888 (`lib/services/trackingservice.dart:210-218`). This is the standard, OS-sanctioned way to keep location + sensor work alive with the screen off. **This part is right.**

**iOS — the background premise is missing.**
- `IosConfiguration(autoStart: false, onForeground: _onStart, onBackground: onIosBackground)` (`lib/services/trackingservice.dart:219-222`).
- `onIosBackground()` is an empty stub — it only calls `WidgetsFlutterBinding.ensureInitialized(); return true;` (`lib/services/trackingservice.dart:604-607`). It does no tracking work.
- **`ios/Runner/Info.plist` contains NO `UIBackgroundModes` key at all** (`ios/Runner/Info.plist:1-60`). Without `location` (and/or `audio`/`processing`) in `UIBackgroundModes`, iOS suspends the process seconds after backgrounding and delivers no background location or isolate execution. `NSLocationAlwaysAndWhenInUseUsageDescription` exists (`:52-53`) but grants nothing without the background mode. **On iOS, tracking a sleeping user is effectively impossible as built.**

---

## 2. Sensor sample rate with screen OFF / Doze

- IMU fusion subscribes to the **default** `accelerometerEvents` / `gyroscopeEvents` streams (`lib/services/sensor_fusion.dart:184, 255`) — **no `SensorInterval`/`samplingPeriod` is ever specified.** The rate defaults to the plugin/OS default, not a controlled high rate.
- The manifest requests `HIGH_SAMPLING_RATE_SENSORS` (`AndroidManifest.xml:12`) but **no code uses it** (no `SensorInterval` anywhere) — the permission is dead weight; dead-reckoning quality in background is uncontrolled.
- Under **Doze / app-standby**, even a foreground service sees sensor delivery and `Timer.periodic` callbacks deferred/batched by the OS — and there is no wakelock (§4) to prevent it. The EKF/dead-reckoning is fed by whatever throttled rate the OS chooses.
- **`sensor_fusion.dart:45` hard-caps a fusion run at `maxFusionDuration = 10 s`.** On expiry the integrator is zeroed — `_velX/_velY/_posX/_posY = 0` and `_fusionStartTime` reset (`sensor_fusion.dart:193-200`) — so accumulated displacement is discarded every 10 s. This bounds drift but also means the IMU-only progress estimate is repeatedly reset, undercutting the "keep tracking through a long GPS outage" premise for underground metro legs longer than 10 s.

---

## 3. If the OS kills the app/isolate mid-journey — restart/persistence?

- **`autoStart: false` on BOTH platforms** (`lib/services/trackingservice.dart:212, 220`). If the OS kills the service, the plugin will not auto-restart it.
- **No `BOOT_COMPLETED` / boot receiver anywhere** (grep of `android/` for `BOOT_COMPLETED`/`BroadcastReceiver` is empty). A phone reboot mid-journey kills tracking permanently until the user manually reopens the app.
- **`android/app/src/main/java/com/example/geowake2/AlarmReceiver.kt` is 0 bytes** — an empty stub. There is no `AlarmManager`/exact-alarm fallback path; the alarm depends entirely on the continuously-running service.
- Persistence *state* exists but nothing triggers a restart: `_onStart` checks for a saved snapshot when `initialData == null` (`lib/services/trackingservice.dart:2023-2028`), restored via `snapshot_route_restorer.dart` + `TrackingStateStore`. So *if* something restarts the isolate it can restore the route — but no mechanism restarts it.
- **Pause-on-UI-death (high risk).** `HeartbeatMonitor` watches for the foreground UI process dying (4 s timeout, 2 s check — `lib/services/tracking/heartbeat_monitor.dart:22-26`). On timeout it does **not** restart or keep going — it sets `paused=true`, shows a "tracking paused" notification, and stops monitoring (`heartbeat_monitor.dart:83-91`). Tracking only un-pauses when the UI returns (`lib/services/trackingservice.dart:1761-1765`). For a sleeping user who swiped the app away or whose UI was reclaimed, tracking sits **paused** — the exact failure mode we must avoid.

---

## 4. Battery: wakelock or best-effort?

- **No wakelock anywhere** — grep for `wakelock`/`WAKE_LOCK`/`keepAwake` across `lib/` **and** `android/` returns nothing; `WAKE_LOCK` is not even in the manifest. A foreground service does **not** guarantee CPU wake during Doze, so the `notificationTick` timers (1–3 s) and sensor callbacks can be deferred. Tracking is **best-effort**, not CPU-guaranteed.
- **No battery-optimization exemption.** No `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission, no `isIgnoringBatteryOptimizations`/`requestIgnore…` call anywhere (`lib/services/permission_service.dart` has none; grep empty). OEM battery managers (Xiaomi/MIUI, Samsung, OnePlus, Huawei, Oppo) **will** kill an unexempted foreground service during sleep — the single most common real-world cause of dead tracking/alarm apps on Android.
- **Battery-adaptive policy degrades reliability as battery drains** (`lib/config/power_policy.dart:28-57`): >50% → `LocationAccuracy.high`, 5 m filter, 25 s dropout buffer; 20–50% → `medium`, 15 m, 30 s; **≤20% → `LocationAccuracy.low`, 50 m filter, 40 s dropout buffer**. On a long overnight ride the battery falls exactly when the alarm matters most, and the low tier drops to coarse network location (useless underground) with a loose 40 s outage tolerance.

---

## 5. Permissions

- Requested in-app via `lib/services/permission_service.dart:13-99`: foreground location → **`locationAlways` (background)** → notification → activity-recognition, each with rationale dialogs. Manifest also declares `POST_NOTIFICATIONS` (`:8`), `ACTIVITY_RECOGNITION` (`:11`), `USE_FULL_SCREEN_INTENT` (`:13`). Reasonable coverage.
- **Missing: battery-optimization exemption prompt** (see §4) — the highest-impact omission.
- **Missing: exact-alarm capability** — no `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM`, consistent with the empty `AlarmReceiver.kt`; there is no scheduled-alarm safety net if the service is killed.
- iOS notification permission is skipped entirely (`permission_service.dart:75` returns `true` for non-Android), so iOS users may never be prompted — compounding §1.
- **Alarm delivery itself is well-configured** (assuming the service is alive): full-screen intent + `IMPORTANCE_HIGH`/`Importance.max`, `category: alarm`, lockscreen-visible (`lib/services/notification_service.dart:726-731`; `android/.../MainActivity.kt:124-135`); `MainActivity.showWhenLocked/turnScreenOn` set (`AndroidManifest.xml:31-32`). The weak link is *keeping the service running*, not the alarm's presentation.

---

## Absent capabilities (each absence is itself a finding)

1. **No `UIBackgroundModes` in `ios/Runner/Info.plist`** → iOS background tracking non-functional.
2. **No wakelock** (`lib/`+`android/`) → CPU/timers throttled in Doze; best-effort only.
3. **No battery-optimization exemption request** → OEM killers terminate the service during sleep.
4. **No `BOOT_COMPLETED` receiver** → no recovery after reboot.
5. **No `autoStart` / no service auto-restart** (`autoStart: false` both platforms) → OS kill = permanently dead.
6. **No exact-alarm (`AlarmManager`) fallback** (`AlarmReceiver.kt` empty) → single point of failure on the foreground service.
7. **No explicit high-rate sensor request** despite holding `HIGH_SAMPLING_RATE_SENSORS` → uncontrolled IMU rate in background.
8. **Heartbeat pauses tracking on UI death instead of sustaining it** → swipe-away/UI-reclaim silences the alarm.
