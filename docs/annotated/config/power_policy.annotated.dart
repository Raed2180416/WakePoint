// Annotated copy of lib/config/power_policy.dart
// Purpose: Explain power tiers and how they affect tracking cadence and reroute behavior.

import 'package:geolocator/geolocator.dart'; // Provides LocationAccuracy enums to adjust GPS quality vs power

class PowerPolicy { // Encapsulates a set of power-related runtime parameters
  final LocationAccuracy accuracy; // Desired GPS accuracy level
  final int distanceFilterMeters; // Minimum distance change to deliver a new location update
  final Duration gpsDropoutBuffer; // Grace period tolerated without GPS before declaring a dropout
  final Duration notificationTick; // Cadence for progress/foreground notification updates
  final Duration rerouteCooldown; // Minimum time between successive reroute attempts

  const PowerPolicy({ // Immutable settings bundle
    required this.accuracy,
    required this.distanceFilterMeters,
    required this.gpsDropoutBuffer,
    required this.notificationTick,
    required this.rerouteCooldown,
  }); // End constructor

  static PowerPolicy testing() => const PowerPolicy( // Aggressive cadence for tests to run fast
        accuracy: LocationAccuracy.high, // High accuracy for deterministic tests
        distanceFilterMeters: 5, // Small movement threshold to generate frequent updates
        gpsDropoutBuffer: Duration(seconds: 2), // Short tolerance window in tests
        notificationTick: Duration(milliseconds: 50), // Rapid UI/notification ticks for testing
        rerouteCooldown: Duration(seconds: 2), // Quick reroute cooldown for test scenarios
      ); // End testing()
} // End class PowerPolicy

class PowerPolicyManager { // Selects a policy based on current battery level
  static PowerPolicy forBatteryLevel(int levelPercent) { // Returns tiered policy
    // Default/normal tier when battery is healthy
    if (levelPercent > 50) {
      return const PowerPolicy(
        accuracy: LocationAccuracy.high, // High accuracy to keep snapping tight
        distanceFilterMeters: 20, // Reasonable movement threshold to save power
        gpsDropoutBuffer: Duration(seconds: 25), // Tolerate brief GPS gaps without churn
        notificationTick: Duration(seconds: 1), // 1s foreground update cadence
        rerouteCooldown: Duration(seconds: 20), // Avoid frequent reroutes
      );
    }
    // Medium tier for moderate battery
    if (levelPercent > 20) {
      return const PowerPolicy(
        accuracy: LocationAccuracy.medium, // Reduce accuracy to save battery
        distanceFilterMeters: 35, // Fewer GPS callbacks
        gpsDropoutBuffer: Duration(seconds: 30), // Slightly longer dropout buffer
        notificationTick: Duration(seconds: 2), // Slower updates
        rerouteCooldown: Duration(seconds: 25), // Longer cooldown between reroutes
      );
    }
    // Low battery tier: be conservative
    return const PowerPolicy(
      accuracy: LocationAccuracy.low, // Lowest accuracy acceptable
      distanceFilterMeters: 50, // Minimize callbacks
      gpsDropoutBuffer: Duration(seconds: 40), // Long grace period for gaps
      notificationTick: Duration(seconds: 3), // Slowest reasonable cadence
      rerouteCooldown: Duration(seconds: 30), // Back off rerouting to save power
    );
  }
} // End class PowerPolicyManager

/* File summary: PowerPolicy and PowerPolicyManager adapt the app's runtime behavior to battery level. TrackingService
   applies this to configure Geolocator, throttle notifications, and back off reroutes. The testing() profile accelerates
   cycles to keep integration tests fast and reliable. */
