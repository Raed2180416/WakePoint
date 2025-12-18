# ISSUES_BACKLOG

## GW-AUDIT-001
- **Title**: Flutter toolchain missing in CI runner blocks baseline verification
- **Severity**: Major
- **Impact**: Cannot run `flutter pub get`, `flutter analyze`, or `flutter test`; code changes go unvalidated in CI.
- **Evidence**: Baseline outputs `review/ai_audit_2025-12-18/baseline_pub_get.txt`, `baseline_analyze.txt`, `baseline_tests.txt` show `bash: flutter: command not found`.
- **Failure mechanism**: CI environment lacks Flutter binary so standard build/analyze/test steps fail immediately.
- **Repro steps**: Run `flutter pub get` in repo on current runner; observe command not found.
- **Minimal fix**: Install Flutter SDK in CI workflow or use Flutter-enabled runner before executing pub/analyze/test.
- **Regression test idea**: Add CI check that `flutter --version` succeeds before running project commands.

## GW-AUDIT-002
- **Title**: Background notification stop/end flags may be stranded before first alarm
- **Severity**: Major
- **Impact**: If user taps STOP_ALARM/END_TRACKING from background callback before any alarm fires and the invoke bridge is unavailable, file/prefs flags may never be consumed, leaving alarm audio or tracking running until another event triggers polling.
- **Evidence**: `notificationTapBackground` writes file flags via `requestStopAlarmForService`/`requestEndTrackingForService` (notification_service.dart lines ~1260, ~1390) because `FlutterBackgroundService.invoke` may be unavailable. Consumption occurs only inside `_startAlarmStopPollTimer` (trackingservice.dart line ~666) which is started in `_checkAndTriggerAlarm` after an alarm/event or in test `initialData` path (lines ~1099, ~1213, ~1486, ~1564, ~2134); no poll is started when tracking begins normally.
- **Failure mechanism**: Without poll timer running, persisted stop/end flags remain unread; if invoke bridge fails, actions appear to do nothing until an alarm later starts polling.
- **Repro steps**: Start tracking; before any alarm, simulate background notification action invoking `notificationTapBackground` (STOP_ALARM/END_TRACKING) while service.invoke is unavailable. Observe flags written in docs dir/SharedPreferences but background isolate never reads them and tracking continues.
- **Minimal fix**: Start `_startAlarmStopPollTimer()` when tracking session becomes active (e.g., upon `startTracking` handling) and/or add a one-shot poll when background starts to consume pending flags immediately.
- **Regression test idea**: Unit/integration test that writes `.gw_end_tracking_flag` before alarm, triggers `_onStart` startTracking, and asserts flag is consumed and service stops without waiting for alarm trigger.

## GW-AUDIT-003
- **Title**: GPS stream lacks error handling leading to silent tracking stall
- **Severity**: Major
- **Impact**: If Geolocator stream emits an error (permissions revoked, provider disabled), `_positionSubscription` stops; `_trackingSessionActive` remains true, but no positions arrive, so alarms and reroutes never fire while notifications may persist.
- **Evidence**: `startLocationStream` subscribes to `Geolocator.getPositionStream` without `onError`/`onDone` handling (trackingservice.dart lines ~2180 onward).
- **Failure mechanism**: Stream termination leaves no restart logic or user-visible error, causing stuck session.
- **Repro steps**: Start tracking, then revoke location permission or disable location services; Geolocator stops emitting; observe no further updates and no alarm despite proximity.
- **Minimal fix**: Add `onError` handler to resubscribe or stop tracking with user notification when stream ends; monitor `done` to restart.
- **Regression test idea**: Mock Geolocator stream that throws after first event; assert TrackingService either restarts stream or transitions to paused/ended state with notification.
