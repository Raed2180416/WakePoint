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

  /// Optional precomputed fastest-feasible velocity profile for the dynamic
  /// (accel + terminal-braking + curve) levers. When present AND
  /// [ReachabilityConfig.dynamicLeversEnabled] is set, [Reachability.bound] uses
  /// the profile sweep instead of the flat dwell cap. Null ⇒ Phase 0a behaviour.
  final RouteProfile? profile;

  RouteTopology({
    required List<double> stationMeters,
    this.dwellMinSeconds = 0.0,
    this.profile,
  }) : stationMeters = List<double>.unmodifiable(
          [...stationMeters]..sort(),
        );

  bool get isEmpty => stationMeters.isEmpty;
}

/// Precomputed, route-static velocity profile for the fastest-feasible-train
/// bound (TIGHTENING_IMPL.md §1). Built once per leg; the per-tick forward march
/// reads it in O(cells traversed). Every stored quantity is an UPPER bound on
/// the true train's speed at that arc position, so the resulting time is a LOWER
/// bound and the inverted position is an UPPER bound on true progress.
///
/// This class is pure arc-length math (no maps dependency): it takes the route
/// polyline as parallel lat/lng arrays and its own cumulative arc-lengths.
class RouteProfile {
  /// Strictly-increasing arc-length samples (m from anchorable origin).
  final List<double> s;

  /// Curve speed ceiling at each sample (m/s). = vLine where geometry untrusted
  /// or straight; ≤ vLine only inside a validated curve.
  final List<double> vCeil;

  /// Backward terminal-braking envelope at each sample (m/s): the fastest a
  /// train can pass sample i and still decelerate to 0 at the next served stop.
  final List<double> vBrake;

  /// Whether each sample coincides (within snap tolerance) with a SERVED station
  /// the train must stop and dwell at (this trip's stops ∪ target).
  final List<bool> served;

  /// The line speed ceiling (m/s) used for coasting past the last sample.
  final double vLine;

  const RouteProfile._(
      this.s, this.vCeil, this.vBrake, this.served, this.vLine);

  /// Build the profile from the route polyline (parallel [lats]/[lngs]), its
  /// [cumulativeMeters] (parallel, strictly increasing), the SERVED station
  /// arc-positions [servedStations] (this trip's stops ∪ target), and [config].
  ///
  /// The curve ceiling is only computed when [config.curveTrusted]; otherwise it
  /// stays at [vLine] everywhere (inert). Curvature uses a moving Menger
  /// circumradius over a ~[config.curveChordMeters] chord with a k·σ noise floor
  /// so vertex noise cannot fabricate a low ceiling (never-late guard R4/R5).
  factory RouteProfile.precompute({
    required List<double> lats,
    required List<double> lngs,
    required List<double> cumulativeMeters,
    required List<double> servedStations,
    required ReachabilityConfig config,
    required double vLine,
    double snapTolMeters = 40.0,
  }) {
    final n = cumulativeMeters.length;
    final s = List<double>.from(cumulativeMeters);

    // ── Curve ceiling ────────────────────────────────────────────────────
    final vCeil = List<double>.filled(n, vLine);
    if (config.curveTrusted && n >= 3 && lats.length == n && lngs.length == n) {
      final sigmaKappa =
          9.76 * config.curveSigmaPosMeters / (config.curveChordMeters *
              config.curveChordMeters);
      final floor = config.curveNoiseK * sigmaKappa;
      for (var i = 1; i < n - 1; i++) {
        final kappa = _mengerCurvature(
            lats, lngs, s, i, config.curveChordMeters);
        final kappaSafe = math.max(0.0, kappa - floor);
        if (kappaSafe > 0) {
          final vc = math.sqrt(config.aLatEffMps2 / kappaSafe);
          if (vc.isFinite && vc < vCeil[i]) vCeil[i] = vc;
        }
        if (!vCeil[i].isFinite) vCeil[i] = vLine;
      }
    }

    // ── Served stations → mark nearest sample within tolerance ───────────
    final served = List<bool>.filled(n, false);
    for (final st in servedStations) {
      if (!st.isFinite) continue;
      var best = -1;
      var bestD = snapTolMeters;
      for (var i = 0; i < n; i++) {
        final d = (s[i] - st).abs();
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
      if (best >= 0) served[best] = true;
    }

    // ── Backward terminal-braking pass ───────────────────────────────────
    final vBrake = List<double>.filled(n, vLine);
    vBrake[n - 1] = served[n - 1] ? 0.0 : math.min(vLine, vCeil[n - 1]);
    for (var i = n - 2; i >= 0; i--) {
      if (served[i]) {
        vBrake[i] = 0.0;
      } else {
        final ds = math.max(0.0, s[i + 1] - s[i]);
        final vb = math.sqrt(
            vBrake[i + 1] * vBrake[i + 1] + 2 * config.dMaxMps2 * ds);
        vBrake[i] = math.min(vCeil[i], vb);
      }
    }

    return RouteProfile._(s, vCeil, vBrake, served, vLine);
  }

  /// Menger curvature (1/R) at sample [i] over a chord of ~[chordM] metres,
  /// picking the samples ~chordM/2 before and after. Smoothing over the chord
  /// (rather than adjacent vertices) suppresses per-vertex GPS noise. Returns 0
  /// (straight ⇒ no cap) near the ends or when the three points are collinear.
  static double _mengerCurvature(List<double> lats, List<double> lngs,
      List<double> s, int i, double chordM) {
    final half = chordM / 2;
    var lo = i;
    while (lo > 0 && s[i] - s[lo] < half) {
      lo--;
    }
    var hi = i;
    while (hi < s.length - 1 && s[hi] - s[i] < half) {
      hi++;
    }
    if (lo == i || hi == i) return 0.0;
    // Local equirectangular projection (metres) about sample i.
    const mPerDegLat = 111320.0;
    final cosLat = math.cos(lats[i] * math.pi / 180.0);
    double px(int j) => (lngs[j] - lngs[i]) * mPerDegLat * cosLat;
    double py(int j) => (lats[j] - lats[i]) * mPerDegLat;
    final ax = px(lo), ay = py(lo);
    final bx = px(i), by = py(i);
    final cx = px(hi), cy = py(hi);
    final ab = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    final bc = math.sqrt((cx - bx) * (cx - bx) + (cy - by) * (cy - by));
    final ca = math.sqrt((ax - cx) * (ax - cx) + (ay - cy) * (ay - cy));
    // Twice the signed triangle area.
    final area2 = ((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)).abs();
    if (area2 < 1e-6 || ab < 1e-6 || bc < 1e-6 || ca < 1e-6) return 0.0;
    // Menger curvature = 4·area / (|AB|·|BC|·|CA|) = 1/R.
    final kappa = (2 * area2) / (ab * bc * ca);
    return kappa.isFinite ? kappa : 0.0;
  }
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

  // ── Fastest-feasible-train tightening (physics-only, see TIGHTENING_IMPL.md).
  // Every constant below is set to the REACH-MAXIMIZING (largest-plausible)
  // input so the bound can only over-estimate the fastest admissible train —
  // never under-bound (which would fire late). dwellMinSeconds is the sole
  // exception (must lower-bound). All levers default to the INERT state so the
  // cone is bit-identical to the free-run bound until a line is explicitly
  // validated and enabled.

  /// Launch acceleration ceiling (m/s²). Set to the wheel-rail ADHESION ceiling
  /// (~0.25 g) so it dominates any traction+grade combination — a downhill
  /// departure cannot out-accelerate it (red-team R1). NOT service/comfort accel.
  final double aMaxMps2;

  /// Terminal-braking deceleration ceiling (m/s²). Adhesion ceiling + upgrade
  /// assist + track brake, so an upgrade approach cannot out-brake it (R2).
  final double dMaxMps2;

  /// Effective lateral acceleration budget for the curve ceiling (m/s²).
  /// Empty-car overturning + max cant (NOT comfort/tilt). Larger only loosens
  /// v_curve = sqrt(aLatEff/kappa), so this is a safe UPPER input (R7).
  final double aLatEffMps2;

  /// Master switch for the dynamic (accel + terminal-braking + curve) levers.
  /// Default false ⇒ Phase 0a dwell-only path; the profile sweep is skipped and
  /// the cone equals free-run (or the proven dwell cap when dwellMinSeconds>0).
  final bool dynamicLeversEnabled;

  /// Whether the route geometry's curvature has passed the §3 validation
  /// (measured sigma_pos, repaired self-approaches). Until true, the curve
  /// ceiling is forced to V_LINE everywhere (inert) so noisy vertices can never
  /// fabricate a low ceiling that fires late (R4/R5).
  final bool curveTrusted;

  /// Assumed GPS horizontal-position sigma (m) feeding the curvature noise floor
  /// kappa_safe = max(0, |kappa| − k·9.76·sigmaPos/L²). Must be MEASURED per
  /// relation before curveTrusted is flipped (R5).
  final double curveSigmaPosMeters;

  /// Curvature smoothing chord length (m) and noise-floor multiplier (k≥3).
  final double curveChordMeters;
  final double curveNoiseK;

  const ReachabilityConfig({
    this.dwellMinSeconds = 0.0,
    this.hardTMaxSeconds,
    this.aMaxMps2 = 2.5,
    this.dMaxMps2 = 3.5,
    this.aLatEffMps2 = 7.0,
    this.dynamicLeversEnabled = false,
    this.curveTrusted = false,
    this.curveSigmaPosMeters = 5.0,
    this.curveChordMeters = 160.0,
    this.curveNoiseK = 3.0,
  });

  ReachabilityConfig copyWith({
    double? dwellMinSeconds,
    double? hardTMaxSeconds,
    double? aMaxMps2,
    double? dMaxMps2,
    double? aLatEffMps2,
    bool? dynamicLeversEnabled,
    bool? curveTrusted,
    double? curveSigmaPosMeters,
    double? curveChordMeters,
    double? curveNoiseK,
  }) =>
      ReachabilityConfig(
        dwellMinSeconds: dwellMinSeconds ?? this.dwellMinSeconds,
        hardTMaxSeconds: hardTMaxSeconds ?? this.hardTMaxSeconds,
        aMaxMps2: aMaxMps2 ?? this.aMaxMps2,
        dMaxMps2: dMaxMps2 ?? this.dMaxMps2,
        aLatEffMps2: aLatEffMps2 ?? this.aLatEffMps2,
        dynamicLeversEnabled: dynamicLeversEnabled ?? this.dynamicLeversEnabled,
        curveTrusted: curveTrusted ?? this.curveTrusted,
        curveSigmaPosMeters: curveSigmaPosMeters ?? this.curveSigmaPosMeters,
        curveChordMeters: curveChordMeters ?? this.curveChordMeters,
        curveNoiseK: curveNoiseK ?? this.curveNoiseK,
      );

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

/// Closed-form cell traversal result (time + exit speed) for the profile sweep.
class _Cell {
  final double time;
  final double vExit;
  const _Cell(this.time, this.vExit);
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
    if (topology?.profile != null && config.dynamicLeversEnabled) {
      // Phase 0b/0c: the fastest-feasible-train sweep (accel + terminal braking
      // + curve ceiling + dwell). Seed the departure speed at V_LINE — the safe
      // fallback until GPS speedAccuracy is threaded onto the anchor (R6). The
      // sweep can only REDUCE the free-run bound.
      final sFast = _fastestFeasibleProgress(
        sHi: anchor.sHi,
        dt: dtClamped,
        v0: v,
        aMax: config.aMaxMps2,
        dMax: config.dMaxMps2,
        wMin: config.dwellMinSeconds,
        profile: topology!.profile!,
      );
      sMax = math.min(freeRun, sFast);
    } else if (topology != null &&
        !topology.isEmpty &&
        config.dwellMinSeconds > 0.0) {
      // Phase 0a: proven flat dwell cap (teleport at V_LINE between served
      // stops, pay the dwell floor at each). Unconditionally safe.
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

  /// Fastest-feasible-train forward march over a precomputed [RouteProfile]
  /// (TIGHTENING_IMPL.md §1.2). Marches from [sHi] at the cell-max feasible speed
  /// (min of accel envelope from [v0], curve ceiling, terminal-braking envelope),
  /// paying [wMin] dwell at every served stop, until the time budget [dt] is
  /// exhausted. The returned position is an UPPER bound on true progress iff the
  /// constants over-bound the fastest admissible train (proof §1.5).
  static double _fastestFeasibleProgress({
    required double sHi,
    required double dt,
    required double v0,
    required double aMax,
    required double dMax,
    required double wMin,
    required RouteProfile profile,
  }) {
    final s = profile.s;
    final vCeil = profile.vCeil;
    final vBrake = profile.vBrake;
    final served = profile.served;
    final vLine = profile.vLine;
    final n = s.length;
    if (n == 0) return sHi + vLine * dt;

    double pos = sHi;
    double timeLeft = dt;
    double v = v0.isFinite ? v0.clamp(0.0, vLine) : vLine;

    var i = _firstIndexAfter(s, pos);
    while (i < n && timeLeft > 0) {
      final ds = s[i] - pos;
      if (ds <= 0) {
        i++;
        continue;
      }
      final prev = i - 1 < 0 ? 0 : i - 1;
      // Cell-MAX ceiling and cell-MAX brake envelope — both UPPER bounds on true
      // speed in the cell (a monotone envelope's max sits at a cell endpoint),
      // so marching at them over-bounds. Using the cell-MAX (not the entry) of
      // vBrake is essential: at a served-stop DEPARTURE the stop's own vBrake is
      // 0 (must be stopped there), which would otherwise freeze the march — the
      // departing sample's high vBrake unfreezes it while the APPROACH cells stay
      // capped by the braking parabola.
      final vCeilMax = math.max(vCeil[prev], vCeil[i]);
      final vBrakeMax = math.max(vBrake[prev], vBrake[i]);
      final vCap = math.min(vCeilMax, vBrakeMax);
      final cell = _cellTime(v: v, ds: ds, aMax: aMax, vCap: vCap);
      if (cell.time >= timeLeft) {
        pos += _cellAdvance(v: v, aMax: aMax, vCap: vCap, dt: timeLeft);
        timeLeft = 0.0;
        break;
      }
      pos = s[i];
      timeLeft -= cell.time;
      v = math.min(vCap, cell.vExit);
      if (served[i]) {
        v = 0.0; // must stop
        if (timeLeft <= wMin) {
          timeLeft = 0.0;
          break;
        }
        timeLeft -= wMin; // mandatory dwell plateau
      }
      i++;
    }
    if (timeLeft > 0) pos += vLine * timeLeft; // past last sample: coast at cap
    return pos;
  }

  /// Closed-form cell traversal time + exit speed under an accel cap [aMax] and
  /// an in-cell speed cap [vCap] (TIGHTENING_IMPL.md §1.3). Never divides by a
  /// near-zero speed (root-cause R3): the average-speed / triangular forms have
  /// no v→0 singularity.
  static _Cell _cellTime({
    required double v,
    required double ds,
    required double aMax,
    required double vCap,
  }) {
    final cap = math.max(vCap, 1e-3);
    if (v >= cap) {
      return _Cell(ds / cap, cap); // already at/above cap → cruise at cap
    }
    final vFree = math.sqrt(v * v + 2 * aMax * ds);
    if (vFree <= cap) {
      // Accel-limited over the whole cell: time = ds / ((v+vExit)/2), v+vExit>0.
      return _Cell((vFree - v) / aMax, vFree);
    }
    // Accelerate to the cap, then cruise at the cap.
    final dsAccel = (cap * cap - v * v) / (2 * aMax);
    final time = (cap - v) / aMax + (ds - dsAccel) / cap;
    return _Cell(time, cap);
  }

  /// Max distance advanced in the remaining budget [dt] within a cell, marching
  /// at the fastest feasible in-cell speed (over-estimates position ⇒ safe).
  static double _cellAdvance({
    required double v,
    required double aMax,
    required double vCap,
    required double dt,
  }) {
    final cap = math.max(vCap, 1e-3);
    final tToCap = (cap - v) / aMax;
    if (tToCap <= 0) return cap * dt; // already at/above cap → cruise
    if (dt <= tToCap) return v * dt + 0.5 * aMax * dt * dt; // pure accel
    final dAccel = v * tToCap + 0.5 * aMax * tToCap * tToCap;
    return dAccel + cap * (dt - tToCap);
  }

  /// First index `i` with `s[i] > pos` (binary search; `s` strictly increasing).
  static int _firstIndexAfter(List<double> s, double pos) {
    var lo = 0, hi = s.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (s[mid] > pos) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
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
