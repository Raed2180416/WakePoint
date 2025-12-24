# PREEXISTING SNAPSHOT (UNVERIFIED)

- Source: `review/ai_audit_2025-12-18/CALL_FLOWS.md`
- Snapshot date: 2025-12-18
- Status: UNVERIFIED (preserved for traceability; do not treat as audit conclusions)

---

# GeoWake Forensic Audit - Call Flows

**Last Updated:** 2025-12-18

## 1. Tracking Start Flow

```
┌──────────────────┐              ┌──────────────────┐
│ FOREGROUND       │              │ BACKGROUND       │
│ (UI Isolate)     │              │ (Service)        │
└──────────────────┘              └──────────────────┘
        │                                  │
        │ User taps "Start Tracking"       │
        ▼                                  │
  startTracking()                          │
        │                                  │
        ├─► TrackingStateStore.setActive(true)
        ├─► TrackingStateStore.setPaused(false)
        ├─► NotificationService.showJourneyProgress()
        │                                  │
        │ _invokeWithAckRetry(             │
        │   'startTracking', params)       │
        │──────────────────────────────────►│
        │                                  │
        │                     service.on('startTracking')
        │                                  │
        │                     ├─► service.invoke('startTrackingAck')
        │◄─────────────────────────────────│
        │                                  │
        │                     ├─► _registry.clear()
        │                     ├─► Reset alarm flags
        │                     ├─► Set _destination, _alarmMode, _alarmValue
        │                     ├─► unawaited: restore route from snapshot
        │                     ├─► Create SimulationClient with callbacks
        │                     └─► startLocationStream(service)
        │                                  │
  _startForegroundHeartbeat()              │
        │                                  │
        │ Every 1s: 'foregroundHeartbeat'  │
        │──────────────────────────────────►│ _lastForegroundHeartbeat = now
        │                                  │
```

---

## 2. Alarm Trigger Flow

```
┌──────────────────┐              ┌──────────────────┐
│ BACKGROUND       │              │ FOREGROUND       │
└──────────────────┘              └──────────────────┘
        │                                  │
  Position update received                 │
        │                                  │
  _checkAndTriggerAlarm()                  │
        │                                  │
        ├─► Calculate progress on route    │
        ├─► Check distance/stops/time      │
        │                                  │
        │ if threshold reached:            │
        │                                  │
        ├─► _destinationAlarmFired = true  │
        ├─► _lastAlarmFiredAt = now        │
        ├─► _broadcastSimulationState()    │
        │                                  │
  _triggerAlarmNotification()              │
        │                                  │
        │ service.invoke('triggerAlarm',   │
        │   {title, body, allowContinue})  │
        │──────────────────────────────────►│
        │                                  │
        │                     _service.on('triggerAlarm')
        │                                  │
        │                     └─► NotificationService.showWakeUpAlarm()
        │                           ├─► AlarmPlayer.playSelected()
        │                           ├─► _startAlarmVibrationLoop()
        │                           └─► Show notification with fullScreenIntent
        │                                  │
  _startAlarmStopPollTimer()               │
        │                                  │
```

---

## 3. Stop Alarm Flow (via Notification Button)

```
┌──────────────────┐              ┌──────────────────┐
│ FOREGROUND       │              │ BACKGROUND       │
│ (notif callback) │              │ (poll timer)     │
└──────────────────┘              └──────────────────┘
        │                                  │
  User taps "Stop Alarm" button            │
        │                                  │
  notificationTapBackground()              │
        │                                  │
  NotificationService.classifyAction()     │
        │                                  │
        ├─► Returns 'stopAlarm'            │
        │                                  │
  NotificationService.requestStopAlarmForService()
        │                                  │
        ├─► _writeFlag('.gw_stop_alarm_flag')
        ├─► SharedPreferences backup       │
        │                                  │
        │                    ┌─── Timer.periodic(200ms) ───┐
        │                    │                             │
        │                    │ NotificationService.consumeStopAlarmRequest()
        │                    │                             │
        │                    │ ├─► _consumeFlag() → true   │
        │                    │                             │
        │                    │ NotificationService.cancelAlarm()
        │                    │                             │
        │                    │ ├─► AlarmPlayer.stop()      │
        │                    │ ├─► _stopAlarmVibrationLoop()
        │                    │ ├─► Cancel notification     │
        │                    │ └─► restoreJourneyProgress()│
        │                    │                             │
        │                    └─────────────────────────────┘
```

---

## 4. App Killed Detection Flow

```
┌──────────────────┐              ┌──────────────────┐
│ FOREGROUND       │              │ BACKGROUND       │
└──────────────────┘              └──────────────────┘
        │                                  │
  User swipes app away (kill)              │
        │                                  │
  Process dies                             │
  - Timer stops                            │
  - No more heartbeats                     │
        X                                  │
                                           │
                          ┌─── Timer.periodic(2s) ───────┐
                          │                              │
                          │ Check _lastForegroundHeartbeat
                          │                              │
                          │ if (now - lastHeartbeat > 4s):
                          │                              │
                          │ ├─► TrackingStateStore.setPaused(true)
                          │ ├─► NotificationService.showTrackingPaused()
                          │ │     "Tap to resume tracking"
                          │ │                            │
                          │ └─► _stopHeartbeatMonitoring()
                          │                              │
                          └──────────────────────────────┘
```

---

## 5. Resume from Paused Flow

```
┌──────────────────┐              ┌──────────────────┐
│ FOREGROUND       │              │ BACKGROUND       │
└──────────────────┘              └──────────────────┘
        │                                  │
  User taps "Resume" on notification       │
        │ OR taps notification body        │
        │                                  │
  resumeFromNotification()                 │
        │                                  │
        ├─► TrackingStateStore.isPaused() → true
        ├─► TrackingStateStore.loadSnapshot()
        │                                  │
        │ if (snapshot.alarmMode == 'distance'
        │     && already within threshold):
        │   └─► completeEndTracking()      │
        │                                  │
        ├─► TrackingStateStore.setActive(true)
        ├─► TrackingStateStore.setPaused(false)
        ├─► NotificationService.cancelTrackingPaused()
        │                                  │
        │ _service.invoke('startTracking', │
        │   snapshot data)                 │
        │──────────────────────────────────►│
        │                                  │
        │                     service.on('startTracking')
        │                     └─► Re-initialize tracking state
        │                                  │
```

---

## 6. Route Registration Flow

```
┌──────────────────┐              ┌──────────────────┐
│ FOREGROUND       │              │ BACKGROUND       │
└──────────────────┘              └──────────────────┘
        │                                  │
  MapTrackingScreen receives directions    │
        │                                  │
  TrackingService.registerRouteFromDirections()
        │                                  │
        │ _invokeWithAckRetry(             │
        │   'registerRouteDirections')     │
        │──────────────────────────────────►│
        │                                  │
        │                     service.on('registerRouteDirections')
        │                                  │
        │                     ├─► registerRouteFromDirections() [LOCAL]
        │                     │     ├─► Parse polyline
        │                     │     ├─► Build step bounds
        │                     │     ├─► Extract events (transfers, modchanges)
        │                     │     └─► _registry.upsert(route)
        │                     │                            │
        │                     ├─► Initialize ActiveRouteManager
        │                     ├─► Initialize DeviationMonitor
        │                     │                            │
        │                     └─► service.invoke('registerRouteDirectionsAck')
        │◄─────────────────────────────────│
        │                                  │
```

---

## 7. Deviation & Reroute Flow

```
┌──────────────────┐              ┌──────────────────┐
│ BACKGROUND       │              │ EXTERNAL         │
└──────────────────┘              └──────────────────┘
        │                                  │
  Position update                          │
        │                                  │
  _devMonitor.update(position)             │
        │                                  │
  _devSub receives DeviationState          │
        │                                  │
        │ if (deviation && policy.allowReroute):
        │                                  │
        ├─► _rerouteInFlight = true        │
        │                                  │
        │ DirectionService.fetchDirections()
        │──────────────────────────────────►│ Google Maps API
        │◄──────────────────────────────────│
        │                                  │
        ├─► registerRouteFromDirections()  │
        ├─► _registry.upsert(newRoute)     │
        ├─► _rerouteInFlight = false       │
        │                                  │
        │ service.invoke('routeSwitch',    │
        │   {fromKey, toKey, points})      │
        │──────────────────────────────────►│ FOREGROUND
        │                                  │
        │                     _routeSwitchCtrl.add(event)
        │                     └─► UI updates map polyline
        │                                  │
```

---

## 8. Simulation Dashboard Flow

```
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ BACKGROUND       │   │ RELAY SERVER     │   │ DASHBOARD        │
└──────────────────┘   └──────────────────┘   └──────────────────┘
        │                       │                       │
  SimulationClient.connect()    │                       │
        │──────────────────────►│ WebSocket upgrade     │
        │◄──────────────────────│                       │
        │                       │                       │
        │ broadcastRoute()      │                       │
        │──────────────────────►│──────────────────────►│
        │                       │   route_update msg    │
        │                       │                       │
        │                       │                       │ User drags slider
        │                       │◄──────────────────────│
        │◄──────────────────────│   simulation_update   │
        │                       │   {lat, lng, ts}      │
        │                       │                       │
  onFirstPositionReceived()     │                       │
  _simulationPositionsReceived  │                       │
        = true                  │                       │
        │                       │                       │
  positionStream.add(Position)  │                       │
        │                       │                       │
  _checkAndTriggerAlarm()       │                       │
        │                       │                       │
        │                       │                       │ User moves slider back
        │                       │◄──────────────────────│
        │◄──────────────────────│   reset_alarm_state   │
        │                       │                       │
  _onAlarmReset() callback      │                       │
  _resetAlarmState()            │                       │
        │                       │                       │
```
