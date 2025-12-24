# PREEXISTING SNAPSHOT (UNVERIFIED)

- Source: `review/ai_audit_2025-12-18/STATE_MACHINES.md`
- Snapshot date: 2025-12-18
- Status: UNVERIFIED (preserved for traceability; do not treat as audit conclusions)

---

# GeoWake Forensic Audit - State Machines

**Last Updated:** 2025-12-18

## 1. Tracking Session Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Idle: App launched
    
    Idle --> Starting: User taps "Start Tracking"
    Starting --> Active: startTracking ACK received
    Starting --> Active: ACK timeout (fallback invoke)
    
    Active --> AlarmFiring: Threshold reached
    AlarmFiring --> Active: Stop Alarm button
    AlarmFiring --> Stopped: End Tracking button
    
    Active --> Paused: App killed (no heartbeat 4s)
    Paused --> Active: Resume from notification
    Paused --> Stopped: End Tracking from notification
    
    Active --> Stopped: User ends tracking
    Stopped --> [*]
```

### State Ownership
- **Idle/Starting/Active/Stopped:** `_trackingSessionActive` in background isolate
- **Paused:** `tracking_paused_v1` in SharedPreferences
- **AlarmFiring:** `_destinationAlarmFired` + `_alarmCurrentlyShowing`

### Persistence Points
| State Transition | Persisted Keys |
|------------------|----------------|
| Idle → Active | `tracking_active_v1=true`, `tracking_snapshot_v1` |
| Active → Paused | `tracking_paused_v1=true` |
| Paused → Active | `tracking_paused_v1=false` |
| Any → Stopped | `tracking_active_v1=false`, clear snapshot |

---

## 2. Alarm State Machine

```mermaid
stateDiagram-v2
    [*] --> Idle: Tracking started
    
    Idle --> CheckingThreshold: Position update
    CheckingThreshold --> Idle: Not within threshold
    CheckingThreshold --> Firing: Threshold reached & not already fired
    
    Firing --> Muted: Stop Alarm pressed
    Muted --> Idle: Continues tracking (non-destination)
    
    Firing --> Ended: End Tracking pressed
    Muted --> Ended: End Tracking pressed
    
    Firing --> Reset: Dashboard slider moved back
    Muted --> Reset: Dashboard slider moved back
    Reset --> Idle: _resetAlarmState() called
```

### Alarm Firing Guards
| Check | Variable | Location |
|-------|----------|----------|
| Destination not already fired | `_destinationAlarmFired` | trackingservice.dart:752 |
| Event not already fired | `_firedEventIndexes` | trackingservice.dart:753-754 |
| Destination priority | `destinationWithinThreshold` | trackingservice.dart:1457 |

---

## 3. Foreground/Background Isolate States

```mermaid
stateDiagram-v2
    state Foreground {
        [*] --> FG_Idle
        FG_Idle --> FG_Tracking: startTracking()
        FG_Tracking --> FG_SendingHeartbeat: Timer.periodic(1s)
        FG_SendingHeartbeat --> FG_Stopped: stopTracking()
    }
    
    state Background {
        [*] --> BG_Idle
        BG_Idle --> BG_Listening: _onStart()
        BG_Listening --> BG_Tracking: startTracking event
        BG_Tracking --> BG_MonitoringHeartbeat: Timer.periodic(2s check)
        BG_MonitoringHeartbeat --> BG_DetectedAppKilled: No heartbeat 4s
        BG_DetectedAppKilled --> BG_ShowPausedNotif: Show "Tracking Paused"
        BG_Tracking --> BG_Stopped: stopTracking event
    }
```

### Heartbeat Flow
1. **Foreground:** `_startForegroundHeartbeat()` → Timer sends every 1s
2. **Background:** `_startHeartbeatMonitoring()` → Timer checks every 2s
3. **Timeout Detection:** If `_lastForegroundHeartbeat` older than 4s → paused notification

---

## 4. Notification State Machine

```mermaid
stateDiagram-v2
    [*] --> NoNotification
    
    NoNotification --> JourneyProgress: showJourneyProgress()
    JourneyProgress --> JourneyProgress: Progress update
    JourneyProgress --> AlarmShowing: showWakeUpAlarm()
    JourneyProgress --> TrackingPaused: App killed detected
    JourneyProgress --> NoNotification: cancelJourneyProgress()
    
    AlarmShowing --> JourneyProgress: cancelAlarm()
    AlarmShowing --> NoNotification: End Tracking
    
    TrackingPaused --> JourneyProgress: Resume
    TrackingPaused --> NoNotification: End Tracking
```

### Notification IDs
| ID | Purpose |
|----|---------|
| 0 | Alarm notification |
| 888 | Journey progress (also foreground service) |
| 889 | Tracking paused |

---

## 5. SimulationClient Connection States

```mermaid
stateDiagram-v2
    [*] --> Disconnected
    
    Disconnected --> Connecting: connect() called
    Connecting --> Connected: WebSocket handshake success
    Connecting --> ScheduleReconnect: Connection failed
    
    Connected --> SendingPing: Ping received from server
    SendingPing --> Connected: Pong sent
    
    Connected --> ScheduleReconnect: No ping for 90s
    Connected --> ScheduleReconnect: WebSocket error/close
    
    ScheduleReconnect --> Connecting: Backoff timer fires
    
    Connected --> Disconnected: disconnect() called
```

### Reconnect Backoff
```dart
delay = Duration(seconds: (1 << _reconnectAttempts).clamp(1, 30))
```
Sequence: 1s, 2s, 4s, 8s, 16s, 30s (max)

---

## 6. Route Registration State

```mermaid
stateDiagram-v2
    [*] --> NoRoute
    
    NoRoute --> Registering: registerRoute() / registerRouteFromDirections()
    Registering --> ACK_Pending: invoke with requestId
    ACK_Pending --> Registered: ACK received
    ACK_Pending --> Retry: Timeout 700ms
    Retry --> ACK_Pending: Retry invoke (up to 5x)
    Retry --> Registered: Fallback invoke after all retries
    
    Registered --> ActiveRouteInitialized: ActiveRouteManager created
    ActiveRouteInitialized --> DeviationMonitoring: Position updates
    DeviationMonitoring --> RerouteInFlight: Deviation detected
    RerouteInFlight --> Registered: New route registered
```

### Route Registry Keys
Routes keyed by: `"route_${origin.lat}_${origin.lng}_${destination.lat}_${destination.lng}"`

---

## Invariant Observations (For Phase 2)

1. **INV-01:** `_destinationAlarmFired` MUST be reset when new tracking session starts
2. **INV-02:** File flags MUST be consumed (deleted) after processing to prevent re-triggering
3. **INV-03:** Heartbeat timer MUST NOT be stopped on `paused` lifecycle state (only on `detached`)
4. **INV-04:** Alarm notification MUST remain visible until button action (ongoing=true, additionalFlags)
5. **INV-05:** Background isolate MUST initialize NotificationService for proper channel setup
