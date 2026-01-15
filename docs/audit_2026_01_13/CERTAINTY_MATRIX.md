# Certainty Matrix (Behavior × Confidence × Evidence)

## Confidence levels

- CERTAIN: Proven by code path + tests/logs (or trivially deterministic)
- HIGH: Strongly supported by code; minor uncertainty; needs one runtime confirmation
- MEDIUM: Plausible but unverified; multiple branches or platform behavior unknown
- LOW: Speculative; missing evidence; needs targeted instrumentation/tests
- UNKNOWN: Not enough information; must be investigated

## Table

| Behavior | Confidence | Evidence (file/symbol) | What would raise confidence (specific test/run) |
|---|---|---|---|
| Wake Me starts tracking and persists snapshot | CERTAIN | `lib/screens/homescreen.dart` `HomeScreen._onWakeMePressed` / `_proceedWithDirections` | Covered by unit/widget test verifying snapshot + startTracking invoked |
| Background service isolate entrypoint registered | CERTAIN | `lib/services/trackingservice.dart` `TrackingService.initializeService` (AndroidConfiguration.onStart=_onStart) | N/A (static code) |
| Background isolate registers command handlers | CERTAIN | `lib/services/tracking/background_handlers.dart` `BackgroundHandlers.registerAll` | N/A (static code) |
| Alarm evaluation invoked from location processing | HIGH | `lib/services/tracking/location_stream_handler.dart` `LocationStreamHandler._handlePositionUpdate` calls `onCheckAlarm` + `lib/services/trackingservice.dart` `_checkAndTriggerAlarm` | Run device with logs enabled; confirm alarms evaluated per update |
| Alarm triggers from background delegate to foreground | CERTAIN | `lib/services/tracking/alarm_controller.dart` `triggerAlarmNotification` uses `service.invoke('triggerAlarm', ...)` when background | Instrument foreground listener; confirm receipt |
| Foreground receives triggerAlarm and shows alarm notification | HIGH | `lib/services/tracking/foreground_bridge.dart` `_handleTriggerAlarm` → `NotificationService.showWakeUpAlarm` | Run device: force trigger; verify notif + sound + vibration |
| Notification actions persist requests in bg callback | CERTAIN | `lib/services/notification_service.dart` `notificationTapBackground` uses `request*ForService()` | Run device: tap action while app backgrounded; confirm flags consumed |
| Alarm notification re-posting keeps it visible | HIGH | `lib/services/notification_service.dart` `ensureAlarmNotificationVisible` | Run device on Android 13/14; try dismiss; verify re-post |
| Background service starts/stops reliably | UNKNOWN | TBD | Validate service lifecycle logs + OS kill simulation |
| Location stream continues in background | UNKNOWN | TBD | Run with screen off; capture timestamps/updates |
| Alarm evaluation correctness (distance-mode core) | HIGH | `lib/services/tracking/alarm_controller.dart` `checkAndTriggerAlarm` + automated tests (e.g. `test/tracking_alarm_test.dart`) | Device run with background service + real GPS noise; confirm no missed/false alarms |
| Alarm evaluation correctness (time-mode + stops/metro) | MEDIUM | `lib/services/tracking/alarm_controller.dart` `checkAndTriggerAlarm` | Add targeted unit tests for time-mode and per-leg/stops triggers; device run in metro scenarios |
| Notification delivery with sound/vibration | MEDIUM | `lib/services/notification_service.dart` `showWakeUpAlarm` | Device run with lockscreen + DND + battery saver scenarios |
| Stop/Snooze/End actions work end-to-end | MEDIUM | `NotificationService.handleNotificationResponse` + flag consumption | Device run: press each action; confirm state + audio/vibe stops |
| State restoration after process death | UNKNOWN | TBD | Kill process; reopen; verify persisted state + safety preserved |
| Offline behavior fails safe (no route ⇒ no tracking) | HIGH | `lib/services/offline_coordinator.dart` `getRoute()` throws when offline+no cache; `lib/screens/homescreen.dart` uses `_offline.getRoute(...)` before starting tracking | Airplane mode before “Wake Me”; verify UX blocks start and explains offline/no-cache |
| Offline cached-route availability (TTL/origin drift constraints) | MEDIUM | `lib/services/route_cache.dart` TTL=5min, originDeviation=300m evicts entries | Offline for >5 min; move >300m; verify behavior and user messaging |
| GPS degradation handled (stale/jitter/loss) | MEDIUM | `lib/services/tracking/location_stream_handler.dart` dropout + SensorFusionManager | Inject dropout; confirm fusion start/stop and no false alarms |
| Deviation/reroute/termination policy wired end-to-end | HIGH | `lib/services/trackingservice.dart` `_handleBackgroundStartTracking()` wires `deviationStateStream` + `rerouteStream` to `_handleRerouteDecision`; `lib/services/tracking_termination_policy.dart` rules | Live route deviation; confirm reroute attempts, failure counts, and termination notification path |
| Termination policy correctness under real movement | MEDIUM | Same as above; termination triggers only evaluated on reroute attempts | Device run with controlled deviation patterns; verify no premature termination / no missed terminations |
| Debug/test modes isolated from production | UNKNOWN | TBD | Inspect build flags + runtime toggles |
| Server proxy security adequate | UNKNOWN | TBD | Review geowake-server endpoints + auth |

| Process death restore gate (active session → snapshot required, else cleanup) | HIGH | `lib/screens/splash_screen.dart` `_checkStateAndNavigate()` | Device run: start tracking → kill app/process → relaunch → verify restore/cleanup behavior and user feedback |
| Server proxy auth prevents 3rd-party abuse | LOW | geowake-server `/api/auth/token` only checks `bundleId` (`geowake-server/src/controllers/authController.js`) | Add non-forgeable device attestation (Play Integrity) or per-install secret; verify abuse attempts fail |
| Mobile app does not embed Google Maps API key | LOW | Android build has a hardcoded fallback key in `android/app/build.gradle` | Remove fallback, require injected key or server-only usage, verify no `AIza` appears in built APK |
| Alarm notification channel configuration consistent | MEDIUM | Kotlin creates `geowake_alarm_channel_v3`; Dart uses `geowake_alarm_channel_v4` | Unify channel id; verify alarm notification channel settings stable on fresh install |

| Alarm stop/mute/end action consumption uses 200ms polling while alarm-active | HIGH | `lib/services/tracking/alarm_controller.dart` `startAlarmStopPollTimer()` | Profile on-device battery/CPU during alarm-active; add gating/backoff and confirm reduced wakeups |
| Foreground service heartbeat emits every 1s | CERTAIN | `lib/services/tracking/foreground_bridge.dart` `startHeartbeat()` | Validate that increasing interval does not break reliability watchdog assumptions |

| Foreground-kill detection pauses tracking via heartbeat timeout | CERTAIN | `lib/services/tracking/heartbeat_monitor.dart` sets `tracking_paused_v1` and shows “tracking paused” notification when heartbeat gap >4s | Swipe away foreground app while tracking; verify pause notification and resume path |

| Splash restore proceeds after 8s init timeout | CERTAIN | `lib/screens/splash_screen.dart` `_checkStateAndNavigate()` waits `_initFuture.timeout(8s)` then continues | Simulate slow init; confirm whether restore path hits missing-service failures; add gating UI |
| Android build embeds fallback Google Maps API key when key.properties missing | CERTAIN | `android/app/build.gradle` `manifestPlaceholders.googleMapsApiKey` fallback | Remove fallback; verify no key in built APK |

| Notification permission requested in multiple flows | HIGH | `lib/main.dart` requests notifications; `lib/services/notification_service.dart` `initialize()` requests permission; `lib/screens/splash_screen.dart` calls `NotificationService().initialize()` | Consolidate permission UX and verify a single prompt path on Android 13+ |

| TrackingStateStore persisted schema (keys + types) | CERTAIN | `lib/services/tracking_state_store.dart` (`TrackingStateStore` constants + read/write methods) | N/A (static code) |
| Transit leg stops persistence per route key | HIGH | `lib/services/tracking_state_store.dart` `saveTransitLegStops/loadTransitLegStops`; `lib/services/route_session_manager.dart` restores/enhances/persists legs | Start transit session; kill/restart; verify preboarding/leg alarms remain stable |
