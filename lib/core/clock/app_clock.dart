/// AppClock - Abstraction over DateTime.now() for simulation and testing.
///
/// In normal operation (warp factor 1.0): returns real DateTime.now()
/// In simulation mode: returns warped time based on warp factor
///
/// This enables the OSM deviation simulation dashboard to run time-dependent
/// logic (cooldowns, deviation detection, termination policy) at accelerated
/// rates while maintaining behavioral correctness.
///
/// Usage:
/// ```dart
/// // Instead of DateTime.now()
/// final now = AppClock().now();
///
/// // For simulation
/// AppClock().enableSimulation();
/// AppClock().setWarpFactor(100.0); // 100x faster
/// ```
library;

import 'dart:async';

/// Singleton clock that can operate in real-time or warped simulation mode.
class AppClock {
  static AppClock _instance = AppClock._internal();

  /// Factory constructor returns the singleton instance.
  factory AppClock() => _instance;

  AppClock._internal();

  // ─────────────────────────────────────────────────────────────────────────
  // Configuration State
  // ─────────────────────────────────────────────────────────────────────────

  double _warpFactor = 1.0;
  DateTime? _simulationStartReal;
  DateTime? _simulationStartVirtual;

  /// Monotonic elapsed-time source, started at app launch. Unlike [now]
  /// (DateTime.now(), which the OS can move BACKWARD on an NTP correction, a
  /// manual clock change, or a timezone/DST shift), a Stopwatch only ever moves
  /// forward. See [monotonicSeconds].
  final Stopwatch _monotonic = Stopwatch()..start();

  // ─────────────────────────────────────────────────────────────────────────
  // Warp Factor Control
  // ─────────────────────────────────────────────────────────────────────────

  /// Current warp factor (1.0 = real-time, up to 500.0 = 500x faster).
  double get warpFactor => _warpFactor;

  /// Whether simulation mode is active.
  bool get isSimulating => _simulationStartReal != null;

  /// Set warp factor. Values must be >= 1.0 and <= 500.0.
  ///
  /// When changing warp factor mid-simulation, the current virtual time is
  /// preserved and the new factor applies from that point forward.
  void setWarpFactor(double factor) {
    if (factor < 1.0 || factor > 500.0) {
      throw ArgumentError.value(
        factor,
        'factor',
        'Warp factor must be between 1.0 and 500.0',
      );
    }

    // If simulation is active, preserve current virtual time
    if (_simulationStartReal != null && _simulationStartVirtual != null) {
      final currentVirtual = now();
      _simulationStartReal = DateTime.now();
      _simulationStartVirtual = currentVirtual;
    }
    _warpFactor = factor;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Simulation Mode Control
  // ─────────────────────────────────────────────────────────────────────────

  /// Enable simulation mode with optional starting virtual time.
  ///
  /// If [startAt] is provided, virtual time starts from that point.
  /// Otherwise, virtual time starts from the current real time.
  ///
  /// Example:
  /// ```dart
  /// // Start simulation at current time
  /// AppClock().enableSimulation();
  ///
  /// // Start simulation at a specific time
  /// AppClock().enableSimulation(startAt: DateTime(2025, 1, 1, 12, 0));
  /// ```
  void enableSimulation({DateTime? startAt}) {
    _simulationStartReal = DateTime.now();
    _simulationStartVirtual = startAt ?? DateTime.now();
  }

  /// Disable simulation mode, returning to real-time.
  ///
  /// Resets warp factor to 1.0.
  void disableSimulation() {
    _simulationStartReal = null;
    _simulationStartVirtual = null;
    _warpFactor = 1.0;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Time Queries
  // ─────────────────────────────────────────────────────────────────────────

  /// Get the current time.
  ///
  /// In normal mode (not simulating or warp factor 1.0): returns DateTime.now()
  /// In simulation mode: returns warped time based on elapsed real time
  ///
  /// The formula for warped time is:
  /// ```
  /// virtual_time = simulation_start_virtual + (real_elapsed * warp_factor)
  /// ```
  DateTime now() {
    // Fast path: not simulating, return real time
    if (_simulationStartReal == null || _simulationStartVirtual == null) {
      return DateTime.now();
    }

    // Calculate warped time
    // Even at warp factor 1.0, we compute from simulation start to support
    // custom start times (e.g., starting virtual time at a specific point)
    final realElapsed = DateTime.now().difference(_simulationStartReal!);
    final virtualElapsedMicros =
        (realElapsed.inMicroseconds * _warpFactor).round();
    final virtualElapsed = Duration(microseconds: virtualElapsedMicros);
    return _simulationStartVirtual!.add(virtualElapsed);
  }

  /// MONOTONIC seconds — the correct clock for the never-late reachability math.
  ///
  /// Reachability computes the worst-case reachable progress as
  /// `s_max = s0 + V_LINE * (t - t0)`, which is only never-late if `(t - t0)` is
  /// the TRUE elapsed time. [now] is wall-clock and can jump BACKWARD (NTP
  /// correction, manual clock set, DST/timezone change); a backward jump makes
  /// `(t - t0)` clamp to 0, FREEZES the cone, and causes a LATE fire (found by
  /// clock-jump simulation — a reproducible ~28 min late). This source is
  /// monotonic (Stopwatch-based) and therefore immune to those jumps. In
  /// simulation mode it warps with the sim so the accelerated dashboard replay
  /// is still honored; reachability only ever uses DIFFERENCES of this value, so
  /// the absolute reference frame does not matter as long as it is consistent
  /// and non-decreasing within a session.
  double monotonicSeconds() {
    if (_simulationStartReal == null || _simulationStartVirtual == null) {
      // Real mode: elapsed since app start — never moves backward.
      return _monotonic.elapsedMicroseconds / 1e6;
    }
    // Simulation mode: warped virtual seconds (monotonic within the sim).
    final realElapsed = DateTime.now().difference(_simulationStartReal!);
    final virtualMicros = _simulationStartVirtual!.microsecondsSinceEpoch +
        (realElapsed.inMicroseconds * _warpFactor);
    return virtualMicros / 1e6;
  }

  /// Calculate elapsed duration since a past time.
  ///
  /// This uses the current (possibly warped) time.
  Duration since(DateTime past) => now().difference(past);

  /// Check if a duration has elapsed since a past time.
  ///
  /// Equivalent to `now().difference(since) >= duration`.
  bool hasElapsed(DateTime since, Duration duration) {
    return now().difference(since) >= duration;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Timer Utilities
  // ─────────────────────────────────────────────────────────────────────────

  /// Create a periodic timer that fires at real-time intervals.
  ///
  /// The callback receives the current (possibly warped) time.
  /// This is useful for simulation loops where you want consistent frame
  /// updates but warped timestamp perception.
  ///
  /// Example:
  /// ```dart
  /// final timer = AppClock().createPeriodicTimer(
  ///   Duration(milliseconds: 33), // ~30 FPS
  ///   (now) => processFrame(now),
  /// );
  /// ```
  Timer createPeriodicTimer(
    Duration interval,
    void Function(DateTime now) callback,
  ) {
    return Timer.periodic(interval, (_) => callback(now()));
  }

  /// Create a one-shot timer that fires after a real-time duration.
  ///
  /// The callback receives the current (possibly warped) time when fired.
  Timer createTimer(Duration duration, void Function(DateTime now) callback) {
    return Timer(duration, () => callback(now()));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Testing Utilities
  // ─────────────────────────────────────────────────────────────────────────

  /// Reset to a fresh real clock instance.
  ///
  /// Call this in test teardown to avoid state leakage between tests.
  static void reset() {
    _instance = AppClock._internal();
  }

  /// Install a custom clock instance (for unit testing).
  ///
  /// Example:
  /// ```dart
  /// final mockClock = MockAppClock();
  /// AppClock.install(mockClock);
  /// // ... run tests ...
  /// AppClock.reset(); // restore real clock
  /// ```
  static void install(AppClock clock) {
    _instance = clock;
  }

  /// Get the singleton instance (for testing inspection).
  static AppClock get instance => _instance;
}

/// Extension to make DateTime comparisons clock-aware.
extension DateTimeClockExtension on DateTime {
  /// Duration since this time, using AppClock.
  Duration get elapsed => AppClock().since(this);

  /// Whether the given duration has elapsed since this time.
  bool hasElapsed(Duration duration) => AppClock().hasElapsed(this, duration);
}
