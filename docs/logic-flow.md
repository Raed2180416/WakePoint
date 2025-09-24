# Complete Logical Flow

- App start: `main.dart` initializes Hive, `ApiClient`, `NotificationService`, and `TrackingService`; subscribes to background `fireAlarm` to show alarms.
- Permissions: Requests notification permission; restores any pending alarm UI when resuming.
- Start tracking: UI passes destination, name, `alarmMode` (`distance|time|stops`), `alarmValue` to `TrackingService.startTracking()`.
- Background `_onStart`:
  - Stores params; resets gating; optionally enables injected positions.
  - Initializes route/reroute managers on first `registerRoute...` call.
  - `startLocationStream()` chooses a `PowerPolicy` based on battery, sets geolocator stream, timers, and reroute cooldown.
- Position updates:
  - Update last position/time, distance traveled from start, ETA smoothing (distance/speed with floor), ETA sample count.
  - Ingest into `ActiveRouteManager` to update snap, offset, progress, remaining; drive `DeviationMonitor` with offset (from active snap) and speed.
  - `_checkAndTriggerAlarm()` evaluates alarms each sample:
    - Distance mode: triggers when straight-line distance <= threshold (km→m).
    - Time mode: only eligible after movement (>=100 m), >=3 ETA samples with speed >=0.5 m/s, and >=30 s since start; then triggers when smoothed ETA <= threshold (min→s).
    - Stops mode:
      - Pre-boarding (transit only): single alert near first transit boarding when d<=1000 m; allow continue tracking.
      - Event alarms (transfer/mode-change): based on thresholds mapped to meters/seconds/stops; allow continue tracking; one-shot per event.
      - Destination alarm: when remaining stops <= threshold; ends tracking.
  - On destination alarm, `fireAlarm` is invoked; foreground shows full-screen notification, launches native alarm activity, plays selected ringtone, sets vibration; STOP_ALARM/END_TRACKING actions supported.
- Deviation handling:
  - `DeviationMonitor` sustain window: ignore <100 m; 100–150 m local switch to better registered route when margin met (20 m test, 50 m prod); >150 m: invoke reroute policy (cooldown + online gating).
  - `ActiveRouteManager` exposes pending switch countdown and emits switch events; `MapTrackingScreen` shows snackbars and ETA/distance based on snap progress; also estimates upcoming transfer time based on speed.
- Offline/reroute:
  - `ReroutePolicy` enforces cooldown (battery-tiered); `OfflineCoordinator` provides route from cache/network.
  - On successful reroute, register new directions; recompute step bounds, stops, events, and first boarding.
- Notifications:
  - Progress notification updated on a periodic tick (battery-tiered) using route progress or straight-line fallback.
  - Alarm flow records events in tests; supports recovery of pending alarm UI on app resume.
- Power policy tiers:
  - High (>50%): high accuracy, 20 m filter, 25 s dropout, 1 s tick, 20 s reroute cooldown.
  - Medium (21–50%): medium accuracy, 35 m filter, 30 s dropout, 2 s tick, 25 s cooldown.
  - Low (<=20%): low accuracy, 50 m filter, 40 s dropout, 3 s tick, 30 s cooldown.

Key thresholds:
- Deviation: <100 m ignore; 100–150 m local switch; >150 m policy reroute.
- Pre-boarding: d<=1000 m to first transit boarding (stops mode only).
- Time-eligibility: moved>=100 m, >=3 samples at speed>=0.5 m/s, >=30 s since start.
- Local switch margin: 20 m (test), 50 m (prod).

Testing hooks:
- `TrackingService.isTestMode` accelerates timers and cooldowns.
- `NotificationService.isTestMode` and `testRecordedAlarms` provide observability without platform calls.
