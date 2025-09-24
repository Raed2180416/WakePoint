# alarm_fullscreen.dart

- Stateless screen presented for alarms (full-screen intent or fallback navigation).
- Props: `title`, `body`, `allowContinueTracking`.
- UI:
  - Title/body text styled for high contrast.
  - If `allowContinueTracking`, shows "Stop Alarm" button: stops AlarmPlayer and pops.
  - Always shows "End Tracking" (red): stops AlarmPlayer, calls TrackingService.stopTracking(), and pops to root.
