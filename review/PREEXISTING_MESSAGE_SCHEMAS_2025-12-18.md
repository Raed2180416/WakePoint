# PREEXISTING SNAPSHOT (UNVERIFIED)

- Source: `review/ai_audit_2025-12-18/MESSAGE_SCHEMAS.md`
- Snapshot date: 2025-12-18
- Status: UNVERIFIED (preserved for traceability; do not treat as audit conclusions)

---

# GeoWake Forensic Audit - Message Schemas

**Last Updated:** 2025-12-18

## Foreground → Background (via `service.invoke`)

### startTracking
```json
{
  "destinationLat": 28.123456,
  "destinationLng": 77.654321,
  "destinationName": "Home",
  "alarmMode": "distance|stops|time",
  "alarmValue": 2.0,
  "useInjectedPositions": false,
  "routePoints": [{"lat": 28.1, "lng": 77.6}, ...],  // optional
  "requestId": "1702900000000_0"  // for ACK
}
```

### registerRoute
```json
{
  "key": "route_28.1_77.6_28.2_77.7",
  "mode": "driving|transit",
  "destinationName": "Home",
  "points": [{"lat": 28.1, "lng": 77.6}, ...],
  "segments": [...],  // optional
  "switchPoints": [...],  // optional
  "events": [...],  // optional
  "requestId": "1702900000000_1"
}
```

### registerRouteDirections
```json
{
  "directions": { /* Google Directions API response */ },
  "originLat": 28.1,
  "originLng": 77.6,
  "destinationLat": 28.2,
  "destinationLng": 77.7,
  "transitMode": true,
  "destinationName": "Home",
  "requestId": "1702900000000_2"
}
```

### stopTracking
```json
{
  "stopSelf": true  // whether to call service.stopSelf()
}
```

### foregroundHeartbeat
```json
{
  "timestamp": 1702900000000
}
```

### foregroundResumed
```json
{}
```

---

## Background → Foreground (via `service.invoke`)

### startTrackingAck
```json
{
  "requestId": "1702900000000_0"
}
```

### registerRouteAck
```json
{
  "requestId": "1702900000000_1"
}
```

### registerRouteDirectionsAck
```json
{
  "requestId": "1702900000000_2"
}
```

### triggerAlarm
```json
{
  "title": "Wake Up!",
  "body": "Approaching: Central Station",
  "allowContinue": true
}
```

### activeRouteUpdate
```json
{
  "activeKey": "route_28.1_77.6_28.2_77.7",
  "progressMeters": 1500.0,
  "offsetMeters": 5.2,
  "etaSeconds": 300
}
```

### routeSwitch
```json
{
  "fromKey": "route_28.1_77.6_28.2_77.7",
  "toKey": "route_28.15_77.62_28.2_77.7",
  "timestamp": "2025-12-18T12:00:00.000Z",
  "points": [{"lat": 28.15, "lng": 77.62}, ...]
}
```

---

## SimulationClient ↔ Relay Server (WebSocket JSON)

### ping (Server → Client)
```json
{
  "type": "ping",
  "timestamp": 1702900000000
}
```

### pong (Client → Server)
```json
{
  "type": "pong",
  "timestamp": 1702900000001
}
```

### route_update (App → Dashboard)
```json
{
  "type": "route_update",
  "destinationName": "Home",
  "points": [{"lat": 28.1, "lng": 77.6}, ...],
  "segments": [...],
  "switch_points": [...],
  "events": [...],
  "transit_mode": true
}
```

### app_state (App → Dashboard)
```json
{
  "type": "app_state",
  "eta": 300,
  "distance_travelled": 1500.5,
  "alarm_mode": "stops",
  "alarm_value": 2,
  "alarm_fired": false,
  "remaining_stops": 5.2,
  "debug_info": {...}
}
```

### simulation_update (Dashboard → App)
```json
{
  "type": "simulation_update",
  "lat": 28.123456,
  "lng": 77.654321,
  "timestamp": 1702900000000
}
```

### reset_alarm_state (Dashboard → App)
```json
{
  "type": "reset_alarm_state"
}
```

---

## File-Based Flags (Cross-Isolate)

### Flag Files (in app documents directory)
| Filename | Purpose |
|----------|---------|
| `.gw_stop_alarm_flag` | User pressed Stop Alarm button |
| `.gw_end_tracking_flag` | User pressed End Tracking button |
| `.gw_mute_journey_flag` | User pressed Ignore button |

**Content:** ISO 8601 timestamp of when flag was written
**Lifecycle:** Written by foreground, consumed (deleted) by background

### SharedPreferences Keys (Backup)
| Key | Type | Purpose |
|-----|------|---------|
| `gw_stop_alarm_request_v1` | bool | Stop alarm flag |
| `gw_stop_alarm_request_v1_ts` | int | Timestamp (epoch ms) |
| `gw_end_tracking_request_v1` | bool | End tracking flag |
| `gw_end_tracking_request_v1_ts` | int | Timestamp |
| `gw_mute_journey_request_v1` | bool | Mute journey flag |
| `gw_mute_journey_request_v1_ts` | int | Timestamp |

---

## TrackingStateStore Keys

| Key | Type | Description |
|-----|------|-------------|
| `tracking_active_v1` | bool | Is tracking session active? |
| `tracking_paused_v1` | bool | Is app paused (killed)? |
| `tracking_alarm_fired_v1` | bool | Has alarm been triggered? |
| `tracking_notifications_muted_v1` | bool | Did user mute notifications? |
| `tracking_snapshot_v1` | JSON string | Full session state for resume |
| `gw_progress_payload_v1` | JSON string | Last notification content |

### TrackingSnapshot Schema
```json
{
  "destinationName": "Home",
  "destinationLat": 28.2,
  "destinationLng": 77.7,
  "alarmMode": "stops",
  "alarmValue": 2,
  "metroMode": true,
  "userLat": 28.1,
  "userLng": 77.6,
  "createdAt": "2025-12-18T12:00:00.000Z",
  "directions": { /* Optional: cached Google Directions response */ }
}
```

### TrackingProgressPayload Schema
```json
{
  "title": "Journey to Home",
  "subtitle": "5 stops remaining",
  "progress": 0.75,
  "isTracking": true
}
```

---

## Notification Payloads

| Notification ID | Payload String | Purpose |
|-----------------|----------------|---------|
| 0 (Alarm) | `open_alarm:1` | Alarm, continue tracking allowed |
| 0 (Alarm) | `open_alarm:0` | Final destination alarm |
| 888 (Progress) | `journey:tracking` | Active journey progress |
| 889 (Paused) | `tracking_paused` | App killed, resume available |

### Notification Action IDs
| Action ID | Outcomes |
|-----------|----------|
| `STOP_ALARM` | Stop alarm sound/vibration, continue tracking |
| `END_TRACKING` | End entire tracking session |
| `IGNORE` | Mute journey notifications (if journey payload) |
| `RESUME_TRACKING` | Resume from paused state |
| `DISMISS_ALARM` | Dismiss final alarm |
