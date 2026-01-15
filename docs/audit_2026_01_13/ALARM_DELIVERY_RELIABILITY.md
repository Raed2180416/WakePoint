# Alarm Delivery Reliability (Safety-Critical)

## What this file covers

- Trigger logic (time/distance/stops)
- Idempotency/deduplication
- Foreground vs background behavior
- Notification channels / importance
- Audio focus / vibration / alarms
- OEM/background restriction risks
- Failure handling / user feedback (no silent failures)

## Findings (evidence-backed)

### Finding template

- **Severity**: STOP_SHIP | HIGH | MEDIUM | LOW
- **Evidence**: (file + symbol + line range)
- **Impact**:
- **Repro/Trigger**:
- **Fix**:
- **Confidence**: CERTAIN | HIGH | MEDIUM | LOW | UNKNOWN

## Alarm trigger logic

### Proven trigger pipeline (code)

1. Background position update → `TrackingService._checkAndTriggerAlarm(...)`
	- **Evidence**: `lib/services/trackingservice.dart` [L1124-L1252]

2. Alarm evaluation → `AlarmController.checkAndTriggerAlarm(...)`
	- **Evidence**: `lib/services/tracking/alarm_controller.dart` [L309-L360] and [L980-L1110]

3. Trigger delivery policy → `AlarmController.triggerAlarmNotification(...)`
	- If background isolate: emits `service.invoke('triggerAlarm', {..., playSound:true})`
	- If foreground isolate: directly calls `NotificationService.showWakeUpAlarm(...)`
	- **Evidence**: `lib/services/tracking/alarm_controller.dart` [L262-L308]

4. Foreground receives `triggerAlarm` event → `ForegroundBridge._handleTriggerAlarm(...)` → `NotificationService.showWakeUpAlarm(...)`
	- **Evidence**: `lib/services/tracking/foreground_bridge.dart` [L67-L218]

5. Alarm UI + effects → `NotificationService.showWakeUpAlarm(...)`
	- Uses `fullScreenIntent:true` and `Importance.max`/`Priority.max`
	- Plays sound via `AlarmPlayer.playSelected()` and vibration via `AlarmHaptics.start(...)`
	- Persists `pending_alarm_*` for recovery
	- **Evidence**: `lib/services/notification_service.dart` [L600-L790]

### Idempotency / deduplication

- `NotificationService.showWakeUpAlarm(...)` gates duplicates via `_alarmCurrentlyShowing`.
- `AlarmController` prevents repeated destination alarms per route key and tracks “one alarm per leg” via `firedLegIdsForKey`.
- **Evidence**: `lib/services/notification_service.dart` [L634-L668]; `lib/services/tracking/alarm_controller.dart` [L84-L220] and [L1010-L1060]

### Action handling (Stop/Mute/End)

- Action buttons exist on alarm notification (`STOP_ALARM`, `END_TRACKING`) and paused notification (`RESUME_TRACKING`, `END_TRACKING`).
- `NotificationService.initialize()` wires both foreground response and background callback (`notificationTapBackground`).
- Background callback persists the action request so the tracking isolate can consume it.
- Tracking isolate consumes action requests via:
  - `AlarmController.startAlarmStopPollTimer()` (200ms polling)
  - `LocationStreamHandler._processNotificationActions()` (tick-based processing)
- **Evidence**:
  - Actions + init: `lib/services/notification_service.dart` [L520-L558] and [L700-L760]
  - Background callback: `lib/services/notification_service.dart` [L1296-L1345]
  - Poll timer: `lib/services/tracking/alarm_controller.dart` [L1112-L1285]
  - Tick processing: `lib/services/tracking/location_stream_handler.dart` [L360-L430]

### Finding

- **Severity**: MEDIUM
  - **Evidence**: `lib/services/tracking/alarm_controller.dart` [L1112-L1285] (200ms timer)
  - **Impact**: Increased battery/CPU usage while alarm-active, especially if the timer remains active longer than necessary.
  - **Repro/Trigger**: Alarm fires; user does not dismiss; background isolate remains alive.
  - **Fix**: Gate timer strictly to “alarm visible” state; stop timer immediately after a successful stop/end; add backoff (e.g., 200ms → 1s) when no action flags present.
  - **Confidence**: HIGH

## Alarm delivery mechanism

### Notification channels and properties

- Channels are created in `NotificationService.initialize()`:
	- `geowake_alarm_channel_v4`: `Importance.max`, vibration disabled, sound disabled (sound via `AlarmPlayer`)
	- `geowake_tracking_channel_v2`: tracking progress
	- `geowake_tracking_channel`: legacy/service channel
- **Evidence**: `lib/services/notification_service.dart` [L566-L615]

### Android native channel creation (additional)

- `MainActivity.configureFlutterEngine(...)` creates:
	- `geowake_tracking_channel`
	- `geowake_alarm_channel_v3`
- **Evidence**: `android/app/src/main/kotlin/com/example/geowake2/MainActivity.kt` `createNotificationChannel()`

### Finding

- **Severity**: MEDIUM
	- **Evidence**:
		- Kotlin channel id: `geowake_alarm_channel_v3` (`MainActivity.kt`)
		- Dart channel id: `geowake_alarm_channel_v4` (`NotificationService.initialize()`)
	- **Impact**: Channel configuration may diverge across IDs (importance/visibility/vibration policies), increasing the chance of misconfigured alarm notifications on some devices.
	- **Repro/Trigger**: Fresh install; OS-level channel settings may be applied/modified independently for v3 vs v4.
	- **Fix**: Use a single alarm channel id across Kotlin + Dart (or remove Kotlin-created alarm channel if Dart is authoritative).
	- **Confidence**: CERTAIN

### Full-screen intent

- Alarm notification uses `fullScreenIntent: true`.
- Manifest declares `USE_FULL_SCREEN_INTENT` permission.
- **Evidence**: `lib/services/notification_service.dart` [L706-L731]; `android/app/src/main/AndroidManifest.xml` [L1-L15]

### Audio/vibration

- Sound playback: `AlarmPlayer.playSelected()` (foreground), and AlarmController explicitly delegates sound triggering to foreground isolate when fired from background.
- Vibration: `AlarmHaptics.start(pattern: ...)` with fallback resync.
- **Evidence**: `lib/services/notification_service.dart` [L760-L820]; `lib/services/tracking/alarm_controller.dart` [L288-L308] and [L240-L260]

### Finding

- **Severity**: LOW
	- **Evidence**: `lib/main.dart` [L78-L86] and `lib/services/notification_service.dart` [L553-L565]
	- **Impact**: Duplicate notification permission prompts/requests (startup + notification init) can confuse users.
	- **Repro/Trigger**: Fresh install on Android 13+; app start then later init notifications.
	- **Fix**: Centralize permission request in a single UX flow (prefer user-initiated request), and make `NotificationService.initialize()` assume permission already handled.
	- **Confidence**: HIGH

## Action handlers (Stop/Snooze)

- TBD

## Background reliability risks

- TBD

## Unknowns (must be in Certainty Matrix)

- TBD
