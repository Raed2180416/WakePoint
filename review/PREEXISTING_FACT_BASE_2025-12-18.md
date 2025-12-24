# PREEXISTING (UNVERIFIED) - FACT_BASE.md snapshot

Captured on 2025-12-18 during audit bootstrap. This file predates the current evidence-driven audit run and MUST NOT be treated as authoritative without re-validation.

----

# GeoWake Forensic Audit - Fact Base

**Last Updated:** 2025-12-18  
**Certainty Matrix:** PROVEN | STRONGLY_SUPPORTED | UNCERTAIN | UNVERIFIED

## Android Manifest & Permissions

### FACT-001: Foreground Service Declared [PROVEN]
**Evidence:** `android/app/src/main/AndroidManifest.xml:51-53`
```xml
<service
    android:name="id.flutter.flutter_background_service.BackgroundService"
    android:foregroundServiceType="location" />
```
**Implication:** Service can run with location access when app backgrounded.

### FACT-002: Background Location Permission [PROVEN]
**Evidence:** `android/app/src/main/AndroidManifest.xml:6`
```xml
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
```

### FACT-003: Full-Screen Intent Permission [PROVEN]
**Evidence:** `android/app/src/main/AndroidManifest.xml:12`
```xml
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
```
**Implication:** Alarm notifications can wake device screen.

---

## Cross-Isolate Communication

### FACT-010: File-Based Flag System [PROVEN]
**Evidence:** `lib/services/notification_service.dart:35-82`
- Flags: `.gw_stop_alarm_flag`, `.gw_end_tracking_flag`, `.gw_mute_journey_flag`
- Write: `_writeFlag()` writes ISO timestamp to file
- Consume: `_consumeFlag()` checks existence and deletes atomically
- Fallback: SharedPreferences with reload() as backup

**Rationale (line 49):** "File-based flag write - more reliable across isolates than SharedPreferences"

### FACT-011: ACK-Based Invoke Retry [PROVEN]
**Evidence:** `lib/services/trackingservice.dart:200-244`
```dart
final delays = <Duration>[
  const Duration(milliseconds: 50),
  const Duration(milliseconds: 150),
  const Duration(milliseconds: 300),
  const Duration(milliseconds: 600),
  const Duration(milliseconds: 900),
];
```
- 5 retry attempts
- 700ms ACK timeout per attempt
- Logged as CRITICAL if all fail

### FACT-012: Alarm Trigger Bridge [PROVEN]
**Evidence:** `lib/services/trackingservice.dart:160-197`
Background isolate cannot show notifications (null Android Context), so it invokes `triggerAlarm` event to foreground which calls `showWakeUpAlarm()`.

---

## Alarm Triggering Logic

### FACT-020: Three Alarm Modes [PROVEN]
**Evidence:** `lib/services/trackingservice.dart:970-1575` (_checkAndTriggerAlarm)
1. **Distance mode:** Trigger when `distanceToDestination <= alarmValue * 1000m`
2. **Stops mode:** Trigger when `remainingStops <= alarmValue`
3. **Time mode:** Trigger when `etaSeconds <= alarmValue * 60s`

### FACT-021: Destination Alarm Fires Once [PROVEN]
**Evidence:** `lib/services/trackingservice.dart:752, 1469`
```dart
bool _destinationAlarmFired = false; // fire destination alarm only once
// ...
if (_destinationAlarmFired) { continue; }
_destinationAlarmFired = true;
```

### FACT-022: Event Priority Suppression [PROVEN]
**Evidence:** `lib/services/trackingservice.dart:1456-1462`
```dart
// Conflict resolution: if destination is already within threshold,
// suppress intermediate alarms in the same window to avoid double-firing.
if (destinationWithinThreshold && ev.type != 'destination') {
  continue;
}
```

### FACT-023: Alarm State Reset on Dashboard Slider [PROVEN]
**Evidence:** `lib/services/trackingservice.dart:896-915` (_resetAlarmState)
Called via `SimulationClient.onAlarmReset` when dashboard sends `reset_alarm_state` message.

---

## State Persistence

### FACT-030: TrackingStateStore Keys [PROVEN]
**Evidence:** `lib/services/tracking_state_store.dart:111-116`
- `tracking_active_v1` - bool
- `tracking_snapshot_v1` - JSON (TrackingSnapshot)
- `tracking_notifications_muted_v1` - bool
- `gw_progress_payload_v1` - JSON (TrackingProgressPayload)
- `tracking_paused_v1` - bool
- `tracking_alarm_fired_v1` - bool

### FACT-031: Cached SharedPreferences [PROVEN]
**Evidence:** `lib/services/tracking_state_store.dart:117-133`
```dart
static SharedPreferences? _cachedPrefs;
```
Prefs cached for performance; `reload()` called in `notificationsMuted()` for freshness.

---

## Foreground Heartbeat Mechanism

### FACT-040: Heartbeat Parameters [PROVEN]
**Evidence:** `lib/services/trackingservice.dart:602-605`
```dart
const Duration _heartbeatTimeout = Duration(seconds: 4);
const Duration _heartbeatCheckInterval = Duration(seconds: 2);
```

### FACT-041: Heartbeat Send Rate [PROVEN]
**Evidence:** `lib/services/trackingservice.dart:481`
```dart
_heartbeatSendTimer = Timer.periodic(const Duration(seconds: 1), (_) { ... });
```

### FACT-042: Heartbeat Survival on Background [STRONGLY_SUPPORTED]
**Evidence:** `lib/services/trackingservice.dart:529-536` (comment)
```dart
// IMPORTANT: Do NOT stop heartbeats on paused state!
// When app is simply backgrounded (paused), the Flutter timer continues to run
// and heartbeats will still be sent.
```
**Note:** Behavior depends on Android/OEM process management.

---

## Simulation/Dashboard Bridge

### FACT-050: Relay Server Port [PROVEN]
**Evidence:** `tools/relay_server.dart:6`
```dart
final server = await HttpServer.bind(InternetAddress.anyIPv4, 8081);
```

### FACT-051: Relay Heartbeat [PROVEN]
**Evidence:** `tools/relay_server.dart:14`
- Ping: Every 30s
- Timeout: 60s without pong → close connection

### FACT-052: SimulationClient Reconnect [PROVEN]
**Evidence:** `lib/services/simulation_client.dart:160-170`
Exponential backoff: 1s, 2s, 4s, 8s, max 30s

---

## Notification Behavior

### FACT-060: Alarm Notification Flags [PROVEN]
**Evidence:** `lib/services/notification_service.dart:700-703`
```dart
additionalFlags: Int32List.fromList([4, 32]),
// FLAG_INSISTENT = 4: Makes sound/vibration loop
// FLAG_NO_CLEAR = 32: Prevents from "Clear All"
```

### FACT-061: Vibration Resync Timer [PROVEN]
**Evidence:** `lib/services/notification_service.dart:410-422`
Vibration pattern re-triggered every 3 seconds to overcome Android stopping long-running vibrations.

### FACT-062: Fast Poll Timer [PROVEN]
**Evidence:** `lib/services/trackingservice.dart:666-739`
200ms polling for Stop Alarm/Mute/End Tracking file flags while tracking active.

---

## Certainty Summary

| Class | Count |
|-------|-------|
| PROVEN | 17 |
| STRONGLY_SUPPORTED | 1 |
| UNCERTAIN | 0 |
| UNVERIFIED | 0 |

**False Negative Risk:** Low - all critical paths examined with code evidence.
