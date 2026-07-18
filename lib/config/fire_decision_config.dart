// lib/config/fire_decision_config.dart
//
// Central tunables for the "never fire late" fire-decision cluster.
// See android-reliability-hardening gaps G10-G13.

class FireDecisionConfig {
  /// Critical fractile multiplier (number of sigmas) applied to ETA and
  /// position uncertainty when deciding to fire. Firing at (median - k*sigma)
  /// trades a slightly-early alarm (minor annoyance) for never firing late
  /// (product death). Default 2 is ~97.7% one-sided confidence.
  static const double fractileK = 2.0;

  /// Minimum spacing between alarm evaluations driven by the GPS-dropout tick
  /// (dead-reckoned). The periodic tick can run as often as every 1s; this
  /// throttles re-evaluation to avoid notification churn while staying
  /// responsive underground.
  static const Duration dropoutEvalMinInterval = Duration(seconds: 2);

  /// Sentinel accuracy (meters) stamped on a synthesized dead-reckoned
  /// evaluation Position so downstream code can distinguish it from a real GPS
  /// fix and refuse to snap/ingest it.
  static const double deadReckonAccuracySentinel = 9999.0;

  /// Detection threshold (meters) for coarse-only 'approximate' Android
  /// location. Fixes worse than this are treated as no-GPS (G27).
  static const double approximateLocationAccuracyMeters = 500.0;

  /// Fallback accuracy gate (meters) used when no alarm-threshold-derived gate
  /// is available (G27).
  static const double defaultAccuracyGateMeters = 100.0;

  /// Upper bound (meters) on the position σ used in the fire decision.
  ///
  /// A1 lets EKF σs grow honestly to ~3km during a long fully-underground
  /// segment. The critical-fractile firing (G12/G13) uses k·σ, so an unbounded
  /// σ would inflate the stop-cushion by kilometres and fire many stops early
  /// (safe, but so early it defeats the alarm and erodes trust). Clamping the
  /// σ used *for firing* to ~1–2 inter-station spacings keeps the alarm both
  /// safe (early, never late) AND tight. This does NOT clamp the filter's
  /// reported σ — only the value fed into the fire decision.
  static const double maxFractileSigmaMeters = 300.0;

  /// Adversarial FINDING 3: the reachability bound only OVERRIDES the
  /// dead-reckoned progress once the last real fix is at least this stale — i.e.
  /// a genuine GPS blackout, not the normal 1-5 s gap between healthy fixes.
  /// Below this the physics bound is inert and the statistical (EKF) progress
  /// governs, so a healthy ride does not fire ~V_LINE·dt early. A fire-forcing
  /// (+inf) watchdog bound always applies regardless. 8 s sits just above the
  /// 5 s GPS-dropout buffer, so the EKF carries the first few seconds of any gap
  /// (well within its reliable-coast window) and reachability takes over after.
  static const double reachBlackoutMinSeconds = 8.0;

  /// GAP #21: velocity floor (m/s) used to convert position uncertainty into an
  /// ETA-time cushion when the measured speed is unobservable (stale <= 0.5 m/s,
  /// the normal underground state). Without a floor the ETA sigma collapses to 0
  /// and the fire test degrades to firing at the median (late-risk). 9.2 m/s is
  /// the metro scheduled cruise speed (~33 km/h with dwell), so the cushion is
  /// realistic rather than exploding as v -> 0.
  static const double etaSigmaSpeedFloorMps = 9.2;
}
