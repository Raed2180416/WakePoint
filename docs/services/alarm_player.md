# AlarmPlayer (lib/services/alarm_player.dart)

Purpose: Plays looping alarm sound from selected ringtone asset; resilient to MissingPlugin in tests; integrates with NotificationService to stop vibration.

- Class: line 7 — holds static `AudioPlayer`, `_audioAvailable`, `isPlaying` notifier.
- `_ensureInit()`: lines 11–29 — create player; set loop; degrade gracefully on plugin errors.
- `playSelected()`: line 31 — read `selected_ringtone` from SharedPreferences (best-effort); play asset; set `isPlaying=true` even if audio unavailable for UI/tests.
- `stop()`: line 60 — stop player; set `isPlaying=false`; attempt to stop native vibration via `NotificationService.stopVibration()`.

Tests: `stop_end_tracking_vm_test.dart`, `simulated_route_integration_test.dart`.
