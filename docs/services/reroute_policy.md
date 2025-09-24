# ReroutePolicy (lib/services/reroute_policy.dart)

Purpose: Decides when to request a reroute based on sustained deviation, cooldown, and connectivity.

- Class: line 9 — holds `cooldown`, `_online`, `_lastRerouteAt`, broadcast stream.
- `setOnline(bool)`: line 21 — updates connectivity gate.
- `_cooldownActive(now)`: line 24 — within cooldown window since last reroute.
- `onSustainedDeviation(at)`: lines 28–45 — gates by online and cooldown; emits `RerouteDecision(true|false)` and updates `_lastRerouteAt` on allow.
- `dispose()`: line 47 — closes stream.
- TrackingService listens and triggers `OfflineCoordinator.getRoute` when allowed.
