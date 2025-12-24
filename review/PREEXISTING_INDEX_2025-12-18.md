# PREEXISTING (UNVERIFIED) - INDEX.md snapshot

Captured on 2025-12-18 during audit bootstrap. This file predates the current evidence-driven audit run and MUST NOT be treated as authoritative without re-validation.

----

# GeoWake Forensic Audit - Index

**Audit Date:** 2025-12-18  
**Scope:** Flutter Android application + supporting infrastructure (relay server, dashboard)  
**Phase:** 1 - Mental Model Construction

## Repository Structure

| Path | Description |
|------|-------------|
| `lib/` | Main Flutter app (49 items) |
| `lib/services/` | Core services (29 files, ~300KB) |
| `lib/services/trackingservice.dart` | Main tracking logic (3522 lines) |
| `lib/services/notification_service.dart` | Notifications, alarms, file-based IPC (1495 lines) |
| `lib/services/tracking_state_store.dart` | SharedPreferences persistence (230 lines) |
| `lib/services/simulation_client.dart` | WebSocket client for dashboard (349 lines) |
| `tools/relay_server.dart` | WebSocket relay hub (103 lines) |
| `geowake-server/` | Express API for maps/auth (Node.js) |
| `android/` | Android-specific config |
| `test/` | 68 test files |

## Grounding Artifacts (All Complete)

| File | Purpose | Status |
|------|---------|--------|
| [FACT_BASE.md](./FACT_BASE.md) | 17 verified facts with code evidence | ✅ |
| [STATE_MACHINES.md](./STATE_MACHINES.md) | 5 mermaid state diagrams | ✅ |
| [CALL_FLOWS.md](./CALL_FLOWS.md) | 8 execution flow diagrams | ✅ |
| [MESSAGE_SCHEMAS.md](./MESSAGE_SCHEMAS.md) | All IPC message formats | ✅ |
| [GLOSSARY.md](./GLOSSARY.md) | 50+ domain terms | ✅ |
| [HYPOTHESES.md](./HYPOTHESES.md) | 9 hypotheses for validation | ✅ |
| **[FINDINGS.md](./FINDINGS.md)** | **6 prioritized defects** | ✅ |

## Key Architectural Patterns

### 1. Dual-Isolate Architecture
- **Foreground isolate:** UI, notification display, alarm audio
- **Background isolate:** GPS tracking, alarm logic, service lifecycle
- Communication via `flutter_background_service` invoke/on

### 2. File-Based IPC (NotificationService)
Flag files in app documents directory for cross-isolate signaling:
- `.gw_stop_alarm_flag`
- `.gw_end_tracking_flag`
- `.gw_mute_journey_flag`

Rationale: SharedPreferences can be stale across isolates; files are more reliable.

### 3. ACK-Based Invoke Retry (TrackingService)
5-attempt retry with exponential backoff (50ms → 900ms) for critical IPC:
- `registerRoute` / `registerRouteAck`
- `registerRouteDirections` / `registerRouteDirectionsAck`
- `startTracking` / `startTrackingAck`

### 4. Heartbeat-Based App Death Detection
Foreground sends 1s heartbeat to background. If no heartbeat for 4s, background shows "Tracking Paused" notification.

### 5. Simulation Bridge (PlaygroundBridge)
WebSocket connection to `relay_server.dart` for dashboard-controlled testing:
- Position injection from dashboard
- Route/state broadcasting to dashboard
- Alarm reset on progress slider backward

## Static Analysis Summary
```
flutter analyze: Exit code 1
Issues: Lint warnings only (prefer_const, avoid_print)
No compilation errors
```

## Files Examined
- `lib/services/trackingservice.dart` (lines 1-2000+)
- `lib/services/notification_service.dart` (lines 1-800)
- `lib/services/tracking_state_store.dart` (complete)
- `lib/services/simulation_client.dart` (complete)
- `tools/relay_server.dart` (complete)
- `geowake-server/src/server.js` (complete)
- `android/app/src/main/AndroidManifest.xml` (complete)
