/// Centralized deviation detection and rerouting configuration.
///
/// Contains all magic numbers for the deviation pipeline,
/// enabling consistent tuning across the codebase.
class DeviationConfig {
  DeviationConfig._();

  // ─────────────────────────────────────────────────────────────────────────
  // SpeedThresholdModel parameters (deviation_monitor.dart)
  // Formula: T_high = base + k * speed; T_low = hysteresisRatio * T_high
  // ─────────────────────────────────────────────────────────────────────────

  /// Base threshold in meters for deviation detection at zero speed.
  /// 30m covers 95% of urban GPS noise (buildings cause multipath errors).
  /// Previous value (15m) was too tight for urban environments.
  static const double baseThresholdMeters = 30.0;

  /// Speed coefficient: additional threshold meters per m/s of speed.
  /// At 10 m/s (36 km/h): threshold = 30 + 1.5*10 = 45m
  static const double speedCoefficientK = 1.5;

  /// Hysteresis ratio: return-to-route threshold = ratio * high threshold.
  /// Prevents oscillation between on/off route states.
  static const double hysteresisRatio = 0.7;

  // ─────────────────────────────────────────────────────────────────────────
  // ActiveRouteManager timing (active_route_manager.dart)
  // ─────────────────────────────────────────────────────────────────────────

  /// How long a candidate route must be better before switching
  static const Duration sustainDuration = Duration(seconds: 6);

  /// Cooldown after a route switch before considering new switches
  static const Duration postSwitchBlackout = Duration(seconds: 5);

  /// Margin in meters: candidate must be this much better than current route
  static const double switchMarginMeters = 50.0;

  // ─────────────────────────────────────────────────────────────────────────
  // TrackingService sustained deviation thresholds
  // ─────────────────────────────────────────────────────────────────────────

  /// Below this offset: ignore (noise/GPS jitter)
  static const double noiseFloorMeters = 100.0;

  /// Between noiseFloor and this: prefer local cached route switch over API reroute
  static const double localSwitchThresholdMeters = 150.0;

  /// Above localSwitchThreshold: allow API reroute (subject to cooldown/online)
  static const double apiRerouteThresholdMeters = 150.0;

  // ─────────────────────────────────────────────────────────────────────────
  // ReroutePolicy (reroute_policy.dart, power_policy.dart)
  // ─────────────────────────────────────────────────────────────────────────

  /// Default cooldown between API reroute requests.
  /// Reduced from 20s to 10s for faster response to genuine deviations.
  static const Duration defaultRerouteCooldown = Duration(seconds: 10);

  /// Low battery tier reroute cooldown
  static const Duration lowBatteryRerouteCooldown = Duration(seconds: 20);

  // ─────────────────────────────────────────────────────────────────────────
  // Mode-specific deviation parameters
  // Transit has larger thresholds (station footprints are large)
  // Walking has tighter thresholds (slower movement, more accurate GPS)
  // Driving has highest speed multiplier (GPS lag at high speeds)
  // ─────────────────────────────────────────────────────────────────────────

  /// Transit mode base threshold (metros have large station areas)
  static const double transitBaseThresholdMeters = 50.0;

  /// Transit mode speed coefficient
  static const double transitSpeedCoefficientK = 1.5;

  /// Transit mode hysteresis ratio
  static const double transitHysteresisRatio = 0.6;

  /// Walking mode base threshold
  static const double walkingBaseThresholdMeters = 25.0;

  /// Walking mode speed coefficient
  static const double walkingSpeedCoefficientK = 1.0;

  /// Walking mode hysteresis ratio
  static const double walkingHysteresisRatio = 0.7;

  /// Driving mode base threshold
  static const double drivingBaseThresholdMeters = 40.0;

  /// Driving mode speed coefficient (higher for highways)
  static const double drivingSpeedCoefficientK = 2.0;

  /// Driving mode hysteresis ratio
  static const double drivingHysteresisRatio = 0.65;

  // ─────────────────────────────────────────────────────────────────────────
  // Tracking Termination Policy
  // Smart termination using distance + time + behavior signals
  // ─────────────────────────────────────────────────────────────────────────

  /// Extreme deviation distance for termination check (km)
  static const double extremeDeviationKm = 5.0;

  /// Speed threshold below which user is considered "stopped" (m/s)
  static const double stoppedSpeedThresholdMps = 2.0;

  /// Moderate deviation distance for compound termination check (km)
  static const double moderateDeviationKm = 2.0;

  /// Duration threshold for compound termination check
  static const Duration moderateDeviationDuration = Duration(minutes: 10);

  /// Minimum failed reroute attempts before compound termination
  static const int minFailedReroutesForTermination = 2;

  /// Distance threshold for "moving away" termination (km)
  static const double movingAwayDeviationKm = 3.0;

  // ─────────────────────────────────────────────────────────────────────────
  // Legacy deviation_detection.dart thresholds (unused in production)
  // ─────────────────────────────────────────────────────────────────────────

  /// Online deviation threshold
  static const double legacyOnlineThresholdMeters = 600.0;

  /// Offline deviation threshold (more lenient)
  static const double legacyOfflineThresholdMeters = 1500.0;

  // ─────────────────────────────────────────────────────────────────────────
  // Test mode overrides
  // ─────────────────────────────────────────────────────────────────────────

  /// Sustain duration for tests (faster)
  static const Duration testSustainDuration = Duration(milliseconds: 300);

  /// Post-switch blackout for tests (faster)
  static const Duration testPostSwitchBlackout = Duration(milliseconds: 300);

  /// Switch margin for tests (tighter)
  static const double testSwitchMarginMeters = 20.0;

  /// Reroute cooldown for tests (faster)
  static const Duration testRerouteCooldown = Duration(seconds: 2);
}
