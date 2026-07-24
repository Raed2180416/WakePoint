# GeoWake — Android Setup & Configuration

> Android-specific build configuration, permissions, and native plugin reference.

---

## Build Configuration

### `android/app/build.gradle`

| Setting | Value |
|---------|-------|
| `applicationId` | `com.geowake.app` |
| `minSdkVersion` | 24 |
| `targetSdkVersion` | 35 |
| `compileSdkVersion` | 35 |
| `testInstrumentationRunner` | `pl.leancode.patrol.PatrolJUnitRunner` |

Google Maps API key is loaded from `android/key.properties`:
```properties
googleMapsApiKey=YOUR_GOOGLE_MAPS_API_KEY
```

### `android/app/src/main/AndroidManifest.xml`

#### Permissions

| Permission | Purpose |
|-----------|---------|
| `INTERNET` | API calls, maps, telemetry |
| `ACCESS_FINE_LOCATION` | GPS tracking |
| `ACCESS_COARSE_LOCATION` | Approximate location fallback |
| `ACCESS_BACKGROUND_LOCATION` | Background tracking (foreground service) |
| `FOREGROUND_SERVICE` | Location foreground service |
| `FOREGROUND_SERVICE_LOCATION` | Android 14+ FGS type declaration |
| `POST_NOTIFICATIONS` | Android 13+ notification permission |
| `WAKE_LOCK` | Keep CPU awake during alarm |
| `USE_FULL_SCREEN_INTENT` | Android 14+ full-screen alarm |
| `SCHEDULE_EXACT_ALARM` | Exact alarm scheduling (backstop) |
| `USE_EXACT_ALARM` | Android 14+ exact alarm (alarm apps) |
| `RECEIVE_BOOT_COMPLETED` | Re-initialize after reboot |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Ask user to disable battery optimization |
| `VIBRATE` | Alarm vibration |
| `HIGH_SAMPLING_RATE_SENSORS` | Anti-theft 20Hz accelerometer/gyro |

#### Components

| Component | Purpose |
|-----------|---------|
| `MainActivity` | App entry point, Flutter engine host |
| `BackgroundService` | `flutter_background_service` FGS for tracking |
| `flutter_local_notifications` receivers | Notification action handling, boot receiver |
| `home_widget` receivers | Home screen widget updates |

### Data Extraction Rules

**`android/app/src/main/res/xml/data_extraction_rules.xml`** — Android 12+ auto backup rules. Excludes sensitive data (auth tokens, consent state) from cloud backup.

---

## Native Plugin: `wakepoint_native`

**`packages/wakepoint_native/`** — Android-only Flutter plugin.

### Platform Channel: `wakepoint_native`

#### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `canUseFullScreenIntent()` | `bool` | Checks `USE_FULL_SCREEN_INTENT` permission (Android 14+) |
| `scheduleExactAlarm()` | `void` | Schedules OS-level exact alarm via `AlarmManager` |

### Purpose

1. **Full-screen intent check:** Android 14+ requires explicit permission for full-screen notifications. The plugin checks this at runtime so the app can fall back gracefully.

2. **Exact alarm backstop:** If the app process is killed (OEM battery killer, low memory), the OS-scheduled exact alarm will still fire, re-launching the app to deliver the wake alarm. This is the last line of defense in the never-late guarantee.

---

## OEM Battery Killer Mitigation

Android OEMs (Xiaomi, Oppo, Vivo, Samsung) aggressively kill background apps. GeoWake mitigates this via:

1. **Foreground service** with `location` type — highest priority background execution
2. **Exact alarm backstop** — OS-scheduled alarm survives process death
3. **Battery optimization request** — asks user to disable optimization for GeoWake
4. **OemAutostartService** — handles OEM-specific autostart permission flows
5. **Heartbeat monitor** — detects if background isolate is alive, restarts if needed

---

## ProGuard / R8

Release builds use default Flutter ProGuard rules. No custom rules needed — all native code is in the `wakepoint_native` plugin which ships its own consumer rules.

---

## Signing

Release signing config should be set up in `android/key.properties`:
```properties
storeFile=your keystore path
storePassword=your password
keyAlias=your alias
keyPassword=your key password
googleMapsApiKey=your key
```

Referenced in `build.gradle` via `keystoreProperties`.
