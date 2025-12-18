# TEST_GAPS

Baseline tests not executed (flutter tool missing). Observed gaps:

- `lib/services/trackingservice.dart`: No automated coverage for `_startAlarmStopPollTimer` consumption of file flags, heartbeat timeout pause, or ack retry behavior.
- `lib/services/notification_service.dart`: Lacks tests for `notificationTapBackground` persistence flags and alarm resurrection (`ensureAlarmNotificationVisible`).
- `lib/services/tracking_state_store.dart`: No tests asserting reload semantics and snapshot (de)serialization with directions payload.
- Routing stack (`direction_service.dart`, `active_route_manager.dart`, `route_registry.dart`, `snap_to_route.dart`, `reroute_policy.dart`): No integration tests for route switch events, reroute cooldown, or snap jitter handling.
- UI restore (`MapTrackingScreen._restoreState`) untested for missing snapshot/directions and resubscribe flow.

High-yield candidates:
- Unit test message schema round-trips for invoke payloads and ack handling.
- Poll-timer tests that write `.gw_*` flags and verify TrackingService consumes STOP_ALARM/END_TRACKING quickly.
- Reroute hysteresis test that simulates oscillating deviation and ensures cooldown respected.
- State machine test covering start→pause (heartbeat timeout)→resume→stop transitions.
