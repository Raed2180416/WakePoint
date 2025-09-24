# main.dart (line-by-line)

Purpose: App bootstrap, service initialization, permissions, lifecycle handling, and route setup.

Imports: Material, Permission Handler, Hive, background service, debug server, services, screens, themes, navigation.

main():
- Ensures Flutter bindings.
- Initializes Hive (engine only) with try/catch log.
- Awaits `_initializeServices()` then `runApp(MyApp())`.

_initializeServices():
- `ApiClient.initialize()` in try/catch (server proxy).
- `NotificationService.initialize()` creates channels, handlers, permissions.
- `TrackingService.initializeService()` binds background service callbacks.
- Starts `DevServer` in debug/profile.

MyAppState.initState():
- Adds lifecycle observer.
- Calls `_checkNotificationPermission()`.
- `NotificationService.showPendingAlarmScreenIfAny()` to surface any pending alarm.
- Subscribes to `FlutterBackgroundService().on('fireAlarm')` and calls `NotificationService.showWakeUpAlarm()`.

MyAppState.dispose():
- Removes observer and closes Hive.

MyAppState.didChangeAppLifecycleState():
- On paused: flushes `RecentLocationsService` Hive box to persist.
- On resumed: re-checks for pending alarm screen.

_checkNotificationPermission():
- Requests permission if denied.

Theme toggle:
- `isDarkMode` toggled by `SettingsDrawer` via `toggleTheme()`.

MaterialApp routing:
- `/splash` -> `SplashScreen` (initial route)
- `/preloadMap` -> `PreloadMapScreen` with args
- `/mapTracking` -> `MapTrackingScreen`
- `/` -> `HomeScreen`
