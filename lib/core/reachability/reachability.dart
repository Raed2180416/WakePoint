// lib/core/reachability/reachability.dart
//
// PHYSICS-BASED "NEVER FIRE LATE" PROTECTION LEVEL (PL).
//
// This is the correctness core of GeoWake. It does NOT dead-reckon position
// through a tunnel (that is proven unreliable on a consumer phone). Instead it
// computes a *worst-case reachable position* from first principles:
//
//     while GPS is lost, the train cannot be further along the route than
//
//         s_max(t) = s0_hi + V_LINE * (t - t0)
//
//     where  s0_hi = arc-progress of the last ACCEPTED real GPS fix, overbounded
//                    forward by that fix's accuracy,
//            V_LINE = a speed that is >= the line's true maximum speed,
//            (t - t0) = wall-clock elapsed since that last true fix.
//
// Firing the alarm when s_max(t) reaches the target stop is LATE-PROOF BY
// PHYSICS: if the alarm has not fired, the train provably has not reached the
// target yet. No accelerometer, gyro, magnetometer or ZUPT is required, and the
// guarantee holds on any metro line.
//
// Cost: the alarm fires *early* (the worst case is looser than reality). Two
// levers tighten "how early" without ever risking a late fire:
//   1. The statistical sigma cushion (handled in the EKF path) dominates when
//      GPS is healthy / the blackout is short.
//   2. The STOP-COUNT TOPOLOGY CAP (below): the train must physically pass each
//      intermediate station, and a stopping service dwells >= dwellMin at each,
//      so s_max is capped below the free-running V_LINE * t. This is the real
//      UX lever, and it is deterministic from the route fetch.
//
// THREE PRECONDITIONS the guarantee rests on. Every conceivable late fire is a
// violation of exactly one of these, and each is tested explicitly:
//   (i)   the anchor s0 is a REAL accepted fix, never a phantom (protected by
//         the accuracy gate in location_manager + EKF phantom rejection);
//   (ii)  V_LINE >= the line's true maximum achievable speed;
//   (iii) t is wall-clock elapsed since the last *true* fix, reset ONLY by a
//         gate-passing fix (never by a snapped/dead-reckoned dwell).
//
// The math here is PURE and time is passed in explicitly (no wall-clock reads),
// so every claim is deterministically testable and reproducible.

import 'dart:math' as math;

/// Per-line maximum-speed table used as `V_LINE`.
///
/// Values are chosen to *overbound* real maximum speeds (precondition ii). A
/// too-high V_LINE only fires earlier (safe); a too-low V_LINE can fire late
/// (unsafe), so every value here is a ceiling, not an average.
class VLineTable {
  /// Default line-speed ceiling: 100 km/h. Covers standard metro rolling stock
  /// (typical top speed 80 km/h, so 100 is a real overbound).
  static const double defaultMps = 28.0; // 100 km/h

  /// Express / airport metro ceiling: ~140 km/h (e.g. Delhi Airport Express).
  static const double expressMps = 39.0; // ~140 km/h

  /// Regional Rapid Transit (RRTS / Namo Bharat) ceiling: 190 km/h. The rolling
  /// stock is designed for 180 km/h and runs ~160 km/h operationally, so a
  /// metro-grade V_LINE would be far below true max speed and could fire LATE.
  static const double rrtsMps = 53.0; // ~190 km/h

  /// Hard ceiling used when a line is unknown but we must never underestimate.
  /// Above every Indian urban+regional rail service's true top speed.
  static const double absoluteCeilingMps = 56.0; // ~200 km/h

  /// Optional per-line overrides, keyed by a normalised `city|line` token.
  final Map<String, double> overrides;

  const VLineTable({this.overrides = const {}});

  static String _key(String? city, String? line) =>
      '${(city ?? '').trim().toLowerCase()}|${(line ?? '').trim().toLowerCase()}';

  /// Returns true when a line/city denotes a Regional Rapid Transit service
  /// (RRTS / Namo Bharat / Delhi–Meerut) that far exceeds metro speeds.
  static bool looksRrts(String? cityOrLine) {
    if (cityOrLine == null) return false;
    final l = cityOrLine.toLowerCase();
    // Brand/keyword tokens for Regional Rapid Transit (>140 km/h). Google
    // Directions names this service "Namo Bharat" / "RapidX"; the shipped
    // dataset city key is "delhimeerutrrts". All must route to the RRTS ceiling
    // rather than the metro-express one (39 m/s would still be below its
    // ~160 km/h operational speed and could fire late).
    return l.contains('rrts') ||
        l.contains('rapidx') ||
        l.contains('namo bharat') ||
        l.contains('regional rapid') ||
        l.contains('rapid rail') ||
        l.contains('meerut');
  }

  /// Returns true when a line name denotes an express/airport/suburban service
  /// that can exceed the standard metro ceiling (but is not full RRTS). The
  /// 'suburban'/'local' tokens catch Mumbai Suburban EMUs (~120 km/h), which run
  /// well above the 80-90 km/h conventional-metro envelope. Grounded in
  /// docs/research/grounding_notes.md §15 (India line speeds).
  static bool looksExpress(String? cityOrLine) {
    if (cityOrLine == null) return false;
    final l = cityOrLine.toLowerCase();
    return l.contains('airport') ||
        l.contains('express') ||
        l.contains('rapid') ||
        l.contains('suburban') ||
        l.contains('local'); // Mumbai suburban ("Western/Central/Harbour Line")
  }

  /// Resolve the V_LINE ceiling (m/s) for a given city/line.
  ///
  /// Resolution order: explicit override -> RRTS -> express/suburban -> metro
  /// default. `defaultMps` (28 m/s = 100 km/h) is a real over-bound for every
  /// conventional Indian metro (grounded: design speed ~90 km/h — see
  /// docs/research/grounding_notes.md §15), so it is correct for the common case.
  ///
  /// KNOWN RESIDUAL (adversarial FINDING 2 / GAP #9, honest): a *fast* service
  /// whose name does not keyword-match — chiefly Delhi Airport Express when
  /// reported as "Orange Line" (design 135 km/h) or Mumbai Suburban named
  /// "Western/Central Line" (~120 km/h) — falls to `defaultMps` and can
  /// UNDER-bound → a late-fire risk during a GPS blackout on that leg. This is
  /// NOT fixable by keyword matching alone (the names collide with slow metro
  /// lines, e.g. Nagpur's "Orange Line" IS a 90 km/h metro). The robust fix is
  /// the shipped dataset (city+line -> true top speed) or the GTFS vehicle-type
  /// threaded onto the leg — tracked as the #9 follow-up. Two mitigations already
  /// reduce it: RRTS/Namo Bharat is reliably branded and caught by [looksRrts];
  /// and a known fast line can be pinned via `overrides`. Raising the blanket
  /// default to `absoluteCeilingMps` was rejected — it makes every conventional
  /// metro fire ~2x early on a blackout and inverts the metro < express < RRTS
  /// tier ordering (metro would exceed RRTS), for a residual that is narrow and
  /// better closed with real data.
  double forLine({String? city, String? lineName}) {
    final o = overrides[_key(city, lineName)];
    if (o != null && o.isFinite && o > 0) return o;
    if (looksRrts(city) || looksRrts(lineName)) return rrtsMps;
    if (looksExpress(lineName) || looksExpress(city)) return expressMps;
    return defaultMps;
  }
}

/// The last ACCEPTED real GPS fix, expressed in route arc-length coordinates.
///
/// `sMeters` is the snapped arc-progress at the fix; `accuracyMeters` is the
/// reported horizontal accuracy, used to overbound the anchor *forward* (the
/// only direction that matters for never-late — the train might already be a
/// little further than we measured). `tSeconds` is a monotonic wall-clock
/// timestamp (seconds) of the fix.
class ReachabilityAnchor {
  final double sMeters;
  final double accuracyMeters;
  final double tSeconds;

  /// True when this anchor came from a real gate-passing fix. A synthesized
  /// cold-start anchor (trip origin) sets this false; it is still safe because
  /// the trip origin is a known real position, but callers may want to know.
  final bool fromRealFix;

  const ReachabilityAnchor({
    required this.sMeters,
    required this.accuracyMeters,
    required this.tSeconds,
    this.fromRealFix = true,
  });

  /// Forward-overbounded anchor progress: the furthest along the route the train
  /// could *already* have been at the instant of the fix.
  double get sHi =>
      sMeters + (accuracyMeters.isFinite && accuracyMeters > 0 ? accuracyMeters : 0.0);
}

/// Ordered route topology used by the stop-count cap.
///
/// `stationMeters` is the strictly-increasing list of station arc-positions
/// (cumulative meters from route origin) that the train MUST pass, including
/// intermediate stations. `targetMeters` is the fire target (the stop we wake
/// for). `dwellMinSeconds` is a *lower bound* on the dwell time at each
/// intermediate station for a stopping service.
class RouteTopology {
  final List<double> stationMeters;
  final double dwellMinSeconds;

  RouteTopology({
    required List<double> stationMeters,
    this.dwellMinSeconds = 0.0,
  }) : stationMeters = List<double>.unmodifiable(
          [...stationMeters]..sort(),
        );

  bool get isEmpty => stationMeters.isEmpty;
}

/// Tunables for the Protection Level.
class ReachabilityConfig {
  /// A per-station dwell lower bound (s). ONLY safe (never-late) if it truly
  /// lower-bounds real dwell on a *stopping* service. Defaults to 0 so the
  /// topology cap degrades to the unconditionally-safe free-run bound; enable a
  /// positive value per-line only where the service is known to stop at every
  /// station.
  final double dwellMinSeconds;

  /// Absolute hard blackout budget (s). If the elapsed time since the last true
  /// fix exceeds this, fire pre-emptively regardless of geometry — belt-and-
  /// suspenders for a broken/absent anchor. Waking early is the safe state.
  /// Null disables the hard watchdog (reachability-reaching-target still fires).
  final double? hardTMaxSeconds;

  const ReachabilityConfig({
    this.dwellMinSeconds = 0.0,
    this.hardTMaxSeconds,
  });

  static const ReachabilityConfig defaults = ReachabilityConfig();
}

/// The result of one reachability evaluation.
class ReachabilityBound {
  /// Worst-case arc-progress the train could have reached (meters). This is an
  /// UPPER bound on true progress under the three preconditions.
  final double sMaxMeters;

  /// The free-running bound before any topology tightening (for diagnostics).
  final double freeRunMeters;

  /// Seconds elapsed since the last true fix (wall-clock).
  final double dtSeconds;

  /// True when the hard T_max watchdog is what forced [sMaxMeters] to +inf.
  final bool watchdogTripped;

  const ReachabilityBound({
    required this.sMaxMeters,
    required this.freeRunMeters,
    required this.dtSeconds,
    this.watchdogTripped = false,
  });
}

/// Pure reachability mathematics.
class Reachability {
  /// Worst-case reachable arc-progress at [nowSeconds].
  ///
  /// Guarantee (never-late): given
  ///   - [anchor].sHi >= the train's true progress at [anchor].tSeconds, and
  ///   - [vLineMps] >= the train's true speed at all times, and
  ///   - [nowSeconds] measured on the same wall clock as [anchor].tSeconds,
  /// the returned `sMax` >= the train's true arc-progress at [nowSeconds].
  ///
  /// The optional [topology]+[config] tighten the bound via the stop-count cap.
  /// The cap remains a valid upper bound iff [config].dwellMinSeconds truly
  /// lower-bounds dwell on a stopping service (precondition-adjacent).
  static ReachabilityBound bound({
    required ReachabilityAnchor anchor,
    required double nowSeconds,
    required double vLineMps,
    RouteTopology? topology,
    ReachabilityConfig config = ReachabilityConfig.defaults,
  }) {
    // FAIL-SAFE toward firing: a non-finite anchor position, anchor time, or
    // clock means we CANNOT prove the train is still short of the target — so we
    // must NOT silently freeze the bound (which would suppress the alarm
    // forever). Waking early is the safe state; never-firing is the cardinal
    // sin. Force a fire-forcing (infinite) bound in these corrupt-input cases.
    if (!anchor.sHi.isFinite ||
        !anchor.tSeconds.isFinite ||
        !nowSeconds.isFinite) {
      return const ReachabilityBound(
        sMaxMeters: double.infinity,
        freeRunMeters: double.infinity,
        dtSeconds: 0.0,
        watchdogTripped: true,
      );
    }

    final dt = (nowSeconds - anchor.tSeconds);
    final dtClamped = dt.isFinite ? math.max(0.0, dt) : 0.0;
    final v = (vLineMps.isFinite && vLineMps > 0)
        ? vLineMps
        : VLineTable.absoluteCeilingMps;

    final double freeRun = anchor.sHi + v * dtClamped;

    // Hard T_max watchdog: force a fire when the blackout outlives its budget.
    if (config.hardTMaxSeconds != null &&
        dtClamped >= config.hardTMaxSeconds!) {
      return ReachabilityBound(
        sMaxMeters: double.infinity,
        freeRunMeters: freeRun,
        dtSeconds: dtClamped,
        watchdogTripped: true,
      );
    }

    double sMax = freeRun;
    if (topology != null &&
        !topology.isEmpty &&
        config.dwellMinSeconds > 0.0) {
      final capped = _topologyCappedProgress(
        sHi: anchor.sHi,
        dtSeconds: dtClamped,
        vLineMps: v,
        stationMeters: topology.stationMeters,
        dwellMinSeconds: config.dwellMinSeconds,
      );
      // The cap can only *reduce* the bound (never inflate it).
      sMax = math.min(freeRun, capped);
    }

    return ReachabilityBound(
      sMaxMeters: sMax,
      freeRunMeters: freeRun,
      dtSeconds: dtClamped,
    );
  }

  /// Fastest-possible-train forward simulation used by the topology cap.
  ///
  /// Models the *fastest* train consistent with the physics: travel each gap at
  /// exactly [vLineMps] and pay exactly [dwellMinSeconds] at every intermediate
  /// station it fully passes. The furthest position reachable within
  /// [dtSeconds] is an upper bound on true progress iff real dwell >= dwellMin
  /// and real speed <= vLine. Because a real stopping train spends time dwelling
  /// that this fastest model also spends, the cap is tighter than free-run.
  static double _topologyCappedProgress({
    required double sHi,
    required double dtSeconds,
    required double vLineMps,
    required List<double> stationMeters,
    required double dwellMinSeconds,
  }) {
    double position = sHi;
    double timeLeft = dtSeconds;

    for (final p in stationMeters) {
      if (p <= position) continue; // already at/past this station
      final travelTime = (p - position) / vLineMps;
      if (travelTime >= timeLeft) {
        // Can't even reach the next station; coast as far as time allows.
        position += vLineMps * timeLeft;
        timeLeft = 0.0;
        break;
      }
      // Reach the station, then it MUST dwell before departing.
      position = p;
      timeLeft -= travelTime;
      if (timeLeft <= dwellMinSeconds) {
        // Not enough time left to finish dwelling and depart -> stuck here.
        timeLeft = 0.0;
        break;
      }
      timeLeft -= dwellMinSeconds;
    }

    if (timeLeft > 0.0) {
      // Past the last known station: coast freely with remaining time.
      position += vLineMps * timeLeft;
    }
    return position;
  }

  /// True when the worst-case reachable progress has reached the fire target.
  /// This is the physics fire condition and doubles as the T_max watchdog
  /// (an infinite [ReachabilityBound.sMaxMeters] always fires).
  static bool reachesTarget(ReachabilityBound b, double targetMeters) {
    return b.sMaxMeters >= targetMeters;
  }

  /// The effective arc-progress the fire decision should use: the larger (more
  /// progressed) of the statistical upper bound and the physics upper bound.
  /// Firing when EITHER upper bound passes a stop is the never-late rule.
  static double effectiveProgress({
    required double deadReckonedProgressMeters,
    required double sigmaCushionMeters,
    double? reachableBoundMeters,
  }) {
    // A fire-FORCING reach bound (+infinity from the T_max watchdog or a
    // corrupt-input fail-safe) must WIN — returning it makes every stop count as
    // reached so the alarm fires. Only a NaN reach (genuinely no information) is
    // ignored. This is the never-fire fix: previously +infinity was discarded.
    if (reachableBoundMeters == double.infinity) return double.infinity;
    final statistical = deadReckonedProgressMeters + sigmaCushionMeters;
    final double? reach =
        (reachableBoundMeters != null && reachableBoundMeters.isFinite)
            ? reachableBoundMeters
            : null;
    // Cold start: the EKF may not have initialised, so dead-reckoned progress is
    // NaN. Fall back to the physics bound rather than propagating NaN (which
    // would silently suppress firing). math.max(NaN, x) == NaN, so guard first.
    if (!statistical.isFinite) {
      return reach ?? statistical;
    }
    if (reach == null) return statistical;
    return math.max(statistical, reach);
  }
}

/// Stateful helper for the tracking/controller layer. Holds the current anchor,
/// resets it ONLY on an accepted real fix (precondition iii), and computes the
/// bound on demand. The heavy lifting stays in the pure [Reachability] math.
class ReachabilityTracker {
  ReachabilityAnchor? _anchor;
  final VLineTable vLineTable;
  final ReachabilityConfig config;

  ReachabilityTracker({
    VLineTable? vLineTable,
    this.config = ReachabilityConfig.defaults,
  }) : vLineTable = vLineTable ?? const VLineTable();

  ReachabilityAnchor? get anchor => _anchor;
  bool get hasAnchor => _anchor != null;

  /// Establish the cold-start anchor at trip origin. Progress 0 at the trip's
  /// start time is a known real position, so reachability works from t=0 even
  /// if GPS never yields a single underground fix (closes the cold-start hole
  /// where the EKF never initialises and never fires).
  void seedColdStart({required double tSeconds, double sMeters = 0.0}) {
    _anchor ??= ReachabilityAnchor(
      sMeters: sMeters,
      accuracyMeters: 0.0,
      tSeconds: tSeconds,
      fromRealFix: false,
    );
  }

  /// Reset the anchor on an ACCEPTED real GPS fix. Call this ONLY from the
  /// gate-passing path (never on a snapped dwell / dead-reckoned tick), or the
  /// never-late guarantee (precondition iii) is void.
  void onAcceptedFix({
    required double sMeters,
    required double accuracyMeters,
    required double tSeconds,
  }) {
    // Monotonic guard: never move the anchor backwards in time.
    if (_anchor != null && tSeconds < _anchor!.tSeconds) return;
    _anchor = ReachabilityAnchor(
      sMeters: sMeters,
      accuracyMeters: accuracyMeters,
      tSeconds: tSeconds,
      fromRealFix: true,
    );
  }

  /// Compute the reachability bound now, or null if no anchor exists yet.
  ReachabilityBound? boundNow({
    required double nowSeconds,
    String? city,
    String? lineName,
    RouteTopology? topology,
  }) {
    final a = _anchor;
    if (a == null) return null;
    return Reachability.bound(
      anchor: a,
      nowSeconds: nowSeconds,
      vLineMps: vLineTable.forLine(city: city, lineName: lineName),
      topology: topology,
      config: config,
    );
  }

  void reset() => _anchor = null;
}
