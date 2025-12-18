# HYPOTHESES

- Flutter toolchain absence is environment-only; app code may still build locally. Needs rerun on Flutter-enabled runner.
- Heartbeat timer (1s) plus 4s timeout may misclassify backgrounded app as dead on some OEMs/Doze; requires device run to verify false pauses.
- File-flag request consumption relies on `_startAlarmStopPollTimer`; if alarm never fired and background callback cannot invoke service, END_TRACKING/STOP_ALARM flags might remain unconsumed. Needs simulated background notification with service invoke intentionally failing.
- Geolocator stream error handling absent in `startLocationStream`; if Android revokes location mid-session, tracking may silently stall. Needs instrumented test with permission revocation.
