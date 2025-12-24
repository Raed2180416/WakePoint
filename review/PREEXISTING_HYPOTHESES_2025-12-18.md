# PREEXISTING SNAPSHOT (UNVERIFIED)

- Source: `review/ai_audit_2025-12-18/HYPOTHESES.md`
- Snapshot date: 2025-12-18
- Status: UNVERIFIED (preserved for traceability; do not treat as audit conclusions)

---

# GeoWake Forensic Audit - Hypotheses

**Last Updated:** 2025-12-18

## Hypotheses Requiring Validation

Each hypothesis represents an unverified claim that could affect system reliability. Validation steps are provided for Phase 2 investigation.

---

### HYP-001: SharedPreferences Staleness Across Isolates [UNCERTAIN]

**Claim:** SharedPreferences may not reliably sync between foreground and background isolates without explicit `reload()`.

**Evidence Supporting:**
- `tracking_state_store.dart:189` explicitly calls `reload()` in `notificationsMuted()`
- Comment in `notification_service.dart:133`: "Ensure freshness across isolates"

**Evidence Against:**
- Most TrackingStateStore methods do NOT call reload()
- Cached `_cachedPrefs` could return stale data

**Validation Steps:**
1. Check if `isActive()`, `isPaused()`, `isAlarmFired()` call reload()
2. Trace scenarios where foreground writes and background reads without reload
3. Test: Write from foreground, immediate read from background - does it see new value?

**User Impact if True:** Background could miss state changes like "paused" or "muted", causing incorrect notifications or missed alarms.

**Likelihood:** MEDIUM

---

### HYP-002: Heartbeat Timer Survival on Background [UNCERTAIN]

**Claim:** Flutter Timer.periodic continues running reliably when app is backgrounded but not killed.

**Evidence Supporting:**
- Comment at `trackingservice.dart:529-536`: "When app is simply backgrounded (paused), the Flutter timer continues to run"

**Evidence Against:**
- Android aggressively kills background processes
- OEM battery optimizations may suspend Dart isolate
- No empirical testing evidence in codebase

**Validation Steps:**
1. Run tracking session, background app for 30 seconds on different OEMs
2. Check if heartbeats continue (via logs or debug dashboard)
3. Test on aggressive OEMs (Xiaomi, Huawei, Samsung)

**User Impact if True (timer dies):** False positive "app killed" detection → spurious paused notifications.

**Likelihood:** HIGH (especially on aggressive OEMs)

---

### HYP-003: File Flag Atomic Consume [STRONGLY_SUPPORTED]

**Claim:** File-based flag consume is atomic and prevents double-processing.

**Evidence Supporting:**
- `_consumeFlag()` checks existence and deletes in sequence
- Single-threaded Dart execution within isolate

**Evidence Against:**
- Two isolates could race: both check existence before either deletes
- No file locking mechanism

**Validation Steps:**
1. Trace exact execution: foreground writes, background polls
2. Check timing: How fast can poll timer run after write?
3. Simulate: Can two polls both see the file before deletion?

**User Impact if False:** Double-processing of Stop Alarm → could cause issues (though currently seems benign).

**Likelihood:** LOW (timing window very small)

---

### HYP-004: Alarm Notification Visibility Enforcement [UNCERTAIN]

**Claim:** `ensureAlarmNotificationVisible()` reliably prevents user from dismissing alarm notification.

**Evidence Supporting:**
- Uses `ongoing: true` and `FLAG_NO_CLEAR` flags
- Has re-post logic with rate limiting

**Evidence Against:**
- Android 14+ may allow dismissing ongoing notifications
- Comment at `notification_service.dart:319-322` acknowledges this
- Rate limiting (2s) could allow brief dismissal window

**Validation Steps:**
1. Test on Android 14+ device: Can alarm notification be swiped away?
2. If yes, does it reappear within acceptable time?
3. Check if alarm sound continues even if notification dismissed

**User Impact if False:** User could dismiss alarm notification and miss wake-up call.

**Likelihood:** MEDIUM (platform-dependent)

---

### HYP-005: Route Registration ACK Reliability [STRONGLY_SUPPORTED]

**Claim:** 5-retry ACK mechanism ensures route registration reaches background.

**Evidence Supporting:**
- Explicit retry loop with exponential backoff
- Falls back to best-effort invoke if all ACKs fail

**Evidence Against:**
- No verification that fallback invoke was received
- CRITICAL log suggests this is a known failure mode

**Validation Steps:**
1. Instrument logs to track ACK success rate in production
2. Test under poor conditions: airplane mode transitions, process restarts
3. Verify route events are populated after fallback

**User Impact if False:** Stop-mode alarms fail due to missing route events.

**Likelihood:** LOW (5 retries is robust)

---

### HYP-006: Simulation Stream Priority [PROVEN]

**Claim:** Once simulation receives first position, it takes priority over real GPS.

**Evidence Supporting:**
- `trackingservice.dart:1787-1794`: `onFirstPositionReceived` sets `_simulationPositionsReceived = true` and calls `startLocationStream`
- `startLocationStream` checks `_simulationPositionsReceived` to select stream source

**Status:** PROVEN - no validation needed.

---

### HYP-007: Vibration Resync Prevents Timeout [UNCERTAIN]

**Claim:** 3-second vibration resync timer prevents Android from stopping long-running vibrations.

**Evidence Supporting:**
- Explicit timer at `notification_service.dart:410-422`
- Re-triggers `AlarmHaptics.start()` every pattern period

**Evidence Against:**
- Android may ignore rapid re-start calls
- No empirical testing evidence

**Validation Steps:**
1. Run alarm for 60+ seconds on various devices
2. Verify vibration continues throughout
3. Compare with and without resync timer

**User Impact if False:** Vibration stops after ~15-30 seconds, user sleeps through alarm.

**Likelihood:** MEDIUM

---

### HYP-008: Background Route Restoration [UNCERTAIN]

**Claim:** Background isolate can restore route from snapshot if foreground registration invoke is dropped.

**Evidence Supporting:**
- `trackingservice.dart:1683-1712`: unawaited async block restores from snapshot

**Evidence Against:**
- Uses `unawaited()` - no error handling for failures
- Relies on snapshot having `directions` field populated
- `await TrackingService().registerRouteFromDirections()` in background may have issues

**Validation Steps:**
1. Trace when `directions` is saved to snapshot (HomeScreen)
2. Kill foreground during route registration
3. Verify background can still trigger stop-based alarms

**User Impact if False:** Stop-mode alarms fail after app restart.

**Likelihood:** MEDIUM

---

### HYP-009: Process Death State Recovery [UNCERTAIN]

**Claim:** All necessary state survives process death for reliable alarm delivery.

**Evidence Supporting:**
- TrackingSnapshot contains destination, alarm mode/value
- Background service continues running

**Evidence Against:**
- Route events, step bounds NOT in snapshot
- ETA state saved only on stop, not during tracking
- `_activeManager`, `_devMonitor` etc. are in-memory only

**Validation Steps:**
1. Start tracking with stop-based alarm
2. Kill foreground process
3. Verify alarms still fire correctly based on stops

**User Impact if True (incomplete recovery):** Alarm fires at wrong time or not at all after app kill.

**Likelihood:** HIGH (route events not persisted)

---

## Summary

| ID | Status | Likelihood | Priority |
|----|--------|------------|----------|
| HYP-001 | UNCERTAIN | MEDIUM | HIGH |
| HYP-002 | UNCERTAIN | HIGH | CRITICAL |
| HYP-003 | STRONGLY_SUPPORTED | LOW | LOW |
| HYP-004 | UNCERTAIN | MEDIUM | MEDIUM |
| HYP-005 | STRONGLY_SUPPORTED | LOW | LOW |
| HYP-006 | PROVEN | N/A | N/A |
| HYP-007 | UNCERTAIN | MEDIUM | MEDIUM |
| HYP-008 | UNCERTAIN | MEDIUM | HIGH |
| HYP-009 | UNCERTAIN | HIGH | CRITICAL |

**Validation Priority Order:**
1. HYP-009 (Process death recovery) - CRITICAL
2. HYP-002 (Heartbeat timer survival) - CRITICAL  
3. HYP-001 (SharedPreferences staleness) - HIGH
4. HYP-008 (Background route restoration) - HIGH
5. HYP-004 (Notification visibility) - MEDIUM
6. HYP-007 (Vibration resync) - MEDIUM
