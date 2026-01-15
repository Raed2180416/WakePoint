# Entrypoints and Lifecycle Map (Android-only Flutter)

## Scope

- Dart entrypoints (`main*.dart`)
- Background service entrypoints/callbacks (e.g., `flutter_background_service`)
- Notification action handlers (Stop/Snooze/etc.)
- Android manifest/config entrypoints (services/receivers/providers)
- Persisted state read/write for each entrypoint

## Conventions

For each entrypoint:

- **File**:
- **Symbol**:
- **Who calls it**:
- **When it runs**:
- **Reads persisted state**:
- **Writes persisted state**:
- **Side effects**:
- **Failure modes**:
- **Confidence**: CERTAIN/HIGH/MEDIUM/LOW/UNKNOWN (must match Certainty Matrix row)

## Dart entrypoints

### Primary Android app

- **File**: `lib/main.dart`
- **Symbol**: `Future<void> main()`
- **Who calls it**: Flutter engine (Android `MainActivity` → Flutter runtime)
- **When it runs**: App process start
- **Reads persisted state**:
  - SharedPreferences: `gw_dark_mode` (theme)
- **Writes persisted state**:
  - SharedPreferences: `gw_dark_mode` (theme)
  - Hive: `RecentLocationsService.boxName` flush on background
- **Key side effects / lifecycle hooks**:
  - `MyAppState.initState()` requests notification permission via `permission_handler` and restores theme pref.
  - `MyAppState.didChangeAppLifecycleState()` flushes the Hive recent-locations box when paused, and forwards lifecycle transitions to `TrackingService().handleAppLifecycleChange(state)`.
- **Evidence**: `lib/main.dart` `main()` [L13-L21], `MyAppState` [L23-L123]
- **Confidence**: CERTAIN (code)

#### App startup router / restore gate

- **File**: `lib/screens/splash_screen.dart`
- **Symbol**: `_SplashScreenState.initState()` → `_initializeServices()` → `_checkStateAndNavigate()`
- **Who calls it**: Flutter navigation (initial route/widget tree)
- **When it runs**: Immediately after app startup when SplashScreen is shown
- **Reads persisted state**:
  - `TrackingStateStore.isAlarmFired()` (zombie/alarm-fired cleanup path)
  - `TrackingStateStore.isActive()` (restore session decision)
  - `TrackingStateStore.loadSnapshot()` (restore payload)
- **Writes persisted state**:
  - Indirectly via cleanup: `TrackingService().completeEndTracking(...)` clears snapshot and sets `active=false`, `paused=false`, `alarmFired=false`, `notificationsMuted=false` (best-effort)
- **Side effects**:
  - Initializes `ApiClient` (server auth + health ping)
  - Initializes `NotificationService` (channels + callbacks)
  - Initializes `TrackingService` background service configuration
  - If restore is active and snapshot valid, navigates to `/mapTracking` with snapshot fields
- **Failure modes**:
  - If init future fails/times out (8s), navigation continues anyway
  - If snapshot missing/corrupt, cleanup and navigate home
- **Evidence**: `lib/screens/splash_screen.dart` `_initializeServices` and `_checkStateAndNavigate`
- **Confidence**: CERTAIN (restore gate) / HIGH (OS behavior still needs device validation)

### Alternate entrypoints (dashboards / tooling)

These appear to be testing/simulation dashboards (not Android app runtime) because they import `dart:html` and/or are explicitly documented as “run with flutter run -d chrome”.

- **File**: `lib/main_dashboard.dart`

  - **Symbol**: `void main()`
  - **Runs**: `DashboardApp` (simulation dashboard, web)
  - **Evidence**: `lib/main_dashboard.dart` `main()` [L20-L22] and `dart:html` import [L12-L13]
  - **Confidence**: CERTAIN
- **File**: `lib/main_deviation_dashboard.dart`

  - **Symbol**: `void main()`
  - **Runs**: `DeviationDashboardApp` (web)
  - **Evidence**: `lib/main_deviation_dashboard.dart` [L1-L15]
  - **Confidence**: CERTAIN
- **File**: `lib/main_unified_dashboard.dart`

  - **Symbol**: `void main()`
  - **Runs**: `UnifiedDashboardApp` (web)
  - **Evidence**: `lib/main_unified_dashboard.dart` [L1-L14]
  - **Confidence**: CERTAIN

## Background execution entrypoints

### Background service isolate entrypoint (Android)

- **File**: `lib/services/trackingservice.dart`
- **Symbol**: `@pragma('vm:entry-point') Future<void> _onStart(ServiceInstance service, { Map<String, dynamic>? initialData })`
- **Who calls it**: `flutter_background_service` Android service isolate
- **When it runs**:

  - When `TrackingService.initializeService()` configures the service (`AndroidConfiguration.onStart = _onStart`) and later `TrackingService.startTracking()` calls `FlutterBackgroundService.startService()`.
- **Reads persisted state** (examples):

  - `TrackingStateStore.isPaused()` and `TrackingStateStore.loadSnapshot()` on `foregroundResumed`
  - `TrackingStateStore.loadSnapshot()` via `SnapshotRouteRestorer.restoreFromStoreIfActiveAndNotPaused(...)` during background start-tracking
  - `EtaEngine.loadState()`
- **Writes persisted state**:

  - `TrackingStateStore.setActive(true)`, `setPaused(false)`, `setAlarmFired(false)` (when background startTracking received)
- **Side effects**:

  - Initializes notifications in the background isolate: `NotificationService().initialize()`
  - Registers event listeners via `BackgroundHandlers.registerAll()`
- **Evidence**:

  - `TrackingService.initializeService()` [lib/services/trackingservice.dart L168-L199]
  - `_onStart(...)` [lib/services/trackingservice.dart L1718-L1860]
  - Background command handlers: [lib/services/tracking/background_handlers.dart L1-L120]
- **Confidence**: CERTAIN

### Background alarm check entrypoint

- **File**: `lib/services/trackingservice.dart`
- **Symbol**: `@pragma('vm:entry-point') Future<void> _checkAndTriggerAlarm(Position currentPosition, ServiceInstance service)`
- **Who calls it**: `LocationStreamHandler.onCheckAlarm` callback (wiring in `TrackingService`)
- **When it runs**: For each location update (subject to sequential guard)
- **Evidence**: `lib/services/trackingservice.dart` [L1124-L1252]; `lib/services/tracking/location_stream_handler.dart` [L160-L205]
- **Confidence**: HIGH (needs wiring confirmation in `TrackingService` sections not yet audited)

## Notification action handlers

### Foreground notification response callback

- **File**: `lib/services/notification_service.dart`
- **Symbol**: `NotificationService.initialize()` registering `onDidReceiveNotificationResponse: (response) async { ... await handleNotificationResponse(response); }`
- **Who calls it**: `flutter_local_notifications` plugin (foreground isolate)
- **When it runs**: User taps notification body or action button while app process alive and plugin routes callback
- **Reads/writes persisted state**:
  - Writes: may request `TrackingService` operations; also uses `TrackingStateStore` (various methods) and SharedPreferences “pending_alarm_*” values.
- **Evidence**: `lib/services/notification_service.dart` [L520-L558] and `handleNotificationResponse(...)` [L206-L252]
- **Confidence**: CERTAIN

### Background notification response callback

- **File**: `lib/services/notification_service.dart`
- **Symbol**: `@pragma('vm:entry-point') void notificationTapBackground(NotificationResponse response)`
- **Who calls it**: `flutter_local_notifications` background isolate
- **When it runs**: Notification action tapped while app is backgrounded (plugin callback isolate)
- **Persisted state strategy**:
  - Persists action intent via file flags + SharedPreferences fallback (e.g., `NotificationService.requestStopAlarmForService()`) so the *running tracking isolate* can consume it.
- **Evidence**: `lib/services/notification_service.dart` [L1296-L1345]
- **Confidence**: CERTAIN

## Android-specific entrypoints (Manifest)

### Android Manifest: permissions + background service

- **File**: `android/app/src/main/AndroidManifest.xml`
- **Entrypoint**: `<activity android:name=".MainActivity" ...>` with LAUNCHER intent
- **Background service**: `<service android:name="id.flutter.flutter_background_service.BackgroundService" android:foregroundServiceType="location|mediaPlayback" />`
- **Permissions declared (partial list)**:
  - `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`
  - `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`
  - `POST_NOTIFICATIONS`, `USE_FULL_SCREEN_INTENT`, `ACTIVITY_RECOGNITION`, `HIGH_SAMPLING_RATE_SENSORS`
- **Evidence**: `android/app/src/main/AndroidManifest.xml` [L1-L55]
- **Confidence**: CERTAIN

## Android native entrypoints (Kotlin)

### MainActivity engine configuration + alarm haptics bridge

- **File**: `android/app/src/main/kotlin/com/example/geowake2/MainActivity.kt`
- **Symbol**: `MainActivity.configureFlutterEngine(FlutterEngine)`
- **Who calls it**: Flutter Android embedding when creating the engine
- **When it runs**: App startup (before Dart UI fully running)
- **Reads persisted state**: None observed
- **Writes persisted state**: None observed
- **Side effects**:
  - Creates Android notification channels (`geowake_tracking_channel`, `geowake_alarm_channel_v3`)
  - Exposes method channel `geowake/alarm_haptics` with methods `start`/`stop` to drive OS-level vibration using `USAGE_ALARM`
- **Failure modes**:
  - Channel ID mismatch risk vs Dart-created channels (Dart uses `geowake_alarm_channel_v4`)
- **Evidence**: `android/app/src/main/kotlin/com/example/geowake2/MainActivity.kt`
- **Confidence**: CERTAIN

## Unknowns (must be in Certainty Matrix)

- Device/runtime confirmation for background execution + alarm delivery (lockscreen, screen-off, OEM restrictions)
- Process-kill and restore behavior on real devices
