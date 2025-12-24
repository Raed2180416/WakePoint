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

  /// Base threshold in meters for deviation detection at zero speed
  static const double baseThresholdMeters = 15.0;

  /// Speed coefficient: additional threshold meters per m/s of speed
  static const double speedCoefficientK = 1.5;

  /// Hysteresis ratio: return-to-route threshold = ratio * high threshold
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

  /// Default cooldown between API reroute requests
  static const Duration defaultRerouteCooldown = Duration(seconds: 20);

  /// Low battery tier reroute cooldown
  static const Duration lowBatteryRerouteCooldown = Duration(seconds: 30);

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
