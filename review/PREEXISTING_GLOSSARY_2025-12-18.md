# PREEXISTING SNAPSHOT (UNVERIFIED)

- Source: `review/ai_audit_2025-12-18/GLOSSARY.md`
- Snapshot date: 2025-12-18
- Status: UNVERIFIED (preserved for traceability; do not treat as audit conclusions)

---

# GeoWake Forensic Audit - Glossary

**Last Updated:** 2025-12-18

## Core Concepts

| Term | Definition |
|------|------------|
| **GeoWake** | Location-based alarm app that wakes users before reaching their destination |
| **Tracking Session** | Period from startTracking() to stopTracking() or completeEndTracking() |
| **Alarm Mode** | How alarm threshold is measured: `distance` (km), `stops` (transit stops), or `time` (minutes) |
| **Alarm Value** | Numeric threshold for triggering alarm (e.g., 2 = 2km, 2 stops, or 2 minutes) |

## Isolate Architecture

| Term | Definition |
|------|------------|
| **Foreground Isolate** | Main Flutter UI isolate; handles user interaction, notification display, alarm audio |
| **Background Isolate** | `flutter_background_service` isolate; runs GPS tracking and alarm logic when app backgrounded |
| **Cross-Isolate Communication** | Mechanism for isolates to exchange data (invoke/on, file flags, SharedPreferences) |

## Route System

| Term | Definition |
|------|------------|
| **Route** | Sequence of LatLng points from origin to destination |
| **Route Registry** | In-memory cache of routes keyed by origin/destination coordinates |
| **Active Route Manager** | Manages current route state, progress, and route switching |
| **Route Event** | Significant point on route: `boarding`, `alighting`, `transfer`, `mode_change`, `destination` |
| **Step Bounds** | Cumulative distances at each route step boundary |
| **Step Stops** | Cumulative transit stop counts at each step boundary |
| **Transit Mode** | Route involves public transit (metro, bus) vs. driving/walking |

## Alarm System

| Term | Definition |
|------|------------|
| **Destination Alarm** | Final alarm when approaching destination; fires once, cannot continue tracking |
| **Intermediate Alarm** | Alarm for transfers/mode changes; can be stopped and tracking continues |
| **Pre-boarding Alert** | Warning before first transit boarding point |
| **Event Priority Suppression** | When destination is within threshold, intermediate alarms are suppressed |
| **Alarm Value Reset** | Dashboard slider moved backward triggers `_resetAlarmState()` to allow re-firing |

## Persistence

| Term | Definition |
|------|------------|
| **TrackingStateStore** | Static class wrapping SharedPreferences for tracking session state |
| **TrackingSnapshot** | Full session state serialized to JSON for recovery after app kill |
| **File-Based Flags** | `.gw_*_flag` files in app documents dir for reliable cross-isolate signaling |
| **Pending Alarm Prefs** | SharedPreferences storing last alarm params for recovery |

## Service Lifecycle

| Term | Definition |
|------|------------|
| **Foreground Service** | Android service type that shows persistent notification |
| **Heartbeat** | 1-second ping from foreground to background to detect app kill |
| **Heartbeat Timeout** | 4 seconds without heartbeat → assume foreground killed |
| **Tracking Paused** | State when app killed; shows "Resume" notification |
| **Resume from Notification** | User taps paused notification → restore session from snapshot |

## IPC Mechanisms

| Term | Definition |
|------|------------|
| **ACK-Based Invoke** | Invoke with retry until background sends acknowledgment event |
| **Invoke/On Pattern** | flutter_background_service's bidirectional message passing |
| **Trigger Alarm Bridge** | Background sends `triggerAlarm` event to foreground for notification display |
| **Poll Timer** | 200ms timer checking file flags for Stop Alarm/End Tracking requests |

## Simulation

| Term | Definition |
|------|------------|
| **Simulation Client** | WebSocket client connecting app to relay server for dashboard control |
| **Relay Server** | WebSocket hub (`tools/relay_server.dart`) broadcasting messages between clients |
| **Dashboard** | Web UI (`main_dashboard.dart`) for testing: displays route, controls position slider |
| **Playground Bridge** | Feature flag system enabling simulation mode |
| **Position Injection** | Dashboard sends `simulation_update` messages to control app's reported position |

## Deviation & Reroute

| Term | Definition |
|------|------------|
| **Deviation Detection** | Algorithm detecting when user is off-route beyond threshold |
| **Deviation Monitor** | Class watching for off-route conditions |
| **Reroute Policy** | Rules controlling when deviation triggers automatic reroute |
| **Reroute In-Flight** | Flag preventing concurrent reroute API calls |
| **Offline Coordinator** | Manages behavior when network unavailable |

## Notifications

| Term | Definition |
|------|------------|
| **Journey Progress Notification** | Ongoing notification showing tracking status and ETA |
| **Alarm Notification** | High-priority fullscreen notification with sound/vibration |
| **Tracking Paused Notification** | Shown when app killed; offers Resume/End buttons |
| **Full-Screen Intent** | Android feature to show notification over lockscreen |
| **Ongoing Notification** | Cannot be swiped away (requires button action) |

## ETA

| Term | Definition |
|------|------------|
| **ETA** | Estimated Time of Arrival in seconds |
| **Smoothed ETA** | ETA with noise filtering to prevent jumpy values |
| **API ETA** | ETA from Google Directions API |
| **ETA Engine** | Module calculating and smoothing ETA values |

## Android Specifics

| Term | Definition |
|------|------------|
| **Foreground Service Type** | `location` - allows background location access |
| **Notification Channel** | Required Android 8+ grouping for notifications |
| **FLAG_INSISTENT** | Android flag making notification sound loop |
| **FLAG_NO_CLEAR** | Android flag preventing "Clear All" dismissal |
| **AudioAttributesUsage.alarm** | Android audio attribute for alarm priority |
