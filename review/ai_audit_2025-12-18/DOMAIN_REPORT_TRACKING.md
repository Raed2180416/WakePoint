# DOMAIN_REPORT_TRACKING

- **GPS ingestion**: `startLocationStream` (trackingservice.dart) selects simulation/injected/geolocator stream. No error handler on `_positionSubscription`; permission loss or provider errors would silently stop updates, leaving `_trackingSessionActive` true and alarms never firing.
- **Power policy**: Uses `PowerPolicyManager.forBatteryLevel` to set `LocationSettings` accuracy/distance filter and reroute cooldown; battery read failure defaults to 100% battery (trackingservice.dart).
- **Timebase**: Alarm eligibility uses `DateTime.now()` for heartbeats, ETA smoothing, and time-mode thresholds; Geolocator `Position.timestamp` is ignored, so out-of-order or delayed samples may skew ETA/stop thresholds but still rely on distance computations.
- **Heartbeat pause**: 4s timeout may mark app paused if Android throttles timers when backgrounded; paused notification shown via `showTrackingPaused`, requires RESUME action to clear.
- **Stop/mute consumption**: `_startAlarmStopPollTimer` polls every 200ms for stop/mute/end flags, but timer is only started after an alarm/event triggers (or test initialData). Background notification actions expect consumption of file flags; if invoke fails before any alarm, end-tracking request may remain pending (see ISSUES_BACKLOG GW-AUDIT-002).
- **Battery/permission checks**: No explicit runtime permission revalidation in background; assumes prior grants. HomeScreen uses PermissionService before routing but background service does not re-check.
