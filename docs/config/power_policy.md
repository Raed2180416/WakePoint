# power_policy.dart

Defines `PowerPolicy` tiers controlling GPS accuracy, distanceFilter, dropout buffer, notification tick, and reroute cooldown.

- `PowerPolicy.testing()`: high accuracy, fast ticks, short cooldown for tests.
- `PowerPolicyManager.forBatteryLevel(level)`: returns normal/medium/low battery profiles.

Applied in `TrackingService.startLocationStream()` to tune runtime behavior.
