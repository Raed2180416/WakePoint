# TIGHTENING_IMPL — Physics-only Reachability Tightening (NO crowd data)

Implementation spec for tightening the never-late reachability cone in
`lib/core/reachability/reachability.dart` using only owned/static physics +
OSM geometry. Every lever is a `min()` term over the free-run bound, so a
missing/degraded term can only *relax the cone upward* (fire earlier), never
below true progress. **This spec is the reconciliation of the four lever
designs with their adversarial red-team verdicts (all four were returned
`valid_upper_bound:false`); the red-team fixes are folded in as MANDATORY
guards, not options.** Where a design and its red-team conflict, the red-team
wins.

Anchor truth today: `Reachability.bound` (l.249) computes
`freeRun = anchor.sHi + V_LINE·dt`; `_topologyCappedProgress` (l.321) already
marches "travel each gap at V_LINE, pay dwell at each station". This upgrade
keeps that loop shape and makes the marching speed *position-dependent*.

---

## 0. THE SINGLE MOST IMPORTANT RED-TEAM FINDING (read first)

Every red-team late-fire path reduces to **two root causes**, and both must be
closed before ANY dynamic (accel/brake) lever ships:

1. **GRADE breaks the dynamic constants.** The design docs say "grade is safe
   to omit". That is TRUE only for the curve *ceiling* (`vCeil`) — dropping a
   `min()` ceiling term loosens. It is **FALSE for `a_max` and `d_max`**, which
   are *reach-maximizing* inputs in the accel ramp and brake parabola. On a
   ~4% downgrade departure the true launch accel `a_traction + g·sinθ ≈
   1.3+0.39 = 1.69 > 1.5`; the model marches slower, `s_fast` lags true
   progress by ~70 m **per downhill launch**, and the lag STACKS across a
   multi-station blind run → LATE. Symmetric on upgrade braking. **Fix:** use
   the wheel-rail **adhesion ceiling as the dynamic constant** so it dominates
   any grade+traction combination — `a_max = 2.5`, `d_max = 3.5` — OR gate the
   dynamic levers OFF and ship dwell-only Phase 0a.

2. **`1/v*` at `v→0` and geometry mis-snap.** The forward sweep divides by
   in-cell speed; at a certified-rest launch and every terminal-brake approach
   `v*→0`, so a naive `ds/v` Riemann sum blows up `t*` → `s_fast` too small →
   LATE (or `NaN` poisons `min()` → NEVER-fire). And the curve layer's
   `project_to_arc` returns a multi-valued arc at self-approaches (the shipped
   green relation folds back on itself: idx0≡idx19 at 0 m spatial separation, a
   1282 m phantom stitch chord), snapping a straight fast segment onto a sharp
   arc branch → false low ceiling → LATE. **Fix:** closed-form gap times (never
   `ds/v` through `v≈0`), `NaN→V_LINE`, and perp + arc-monotonicity guards on
   every curvature read.

Consequence for ship order: **Phase 0a = dwell cap only** (teleport at V_LINE
between stops — an unconditional over-bound). Dynamic accel/brake and curve
levers ship only behind the adhesion-ceiling constants, closed-form numerics,
and the geometry guards below.

---

## 1. THE COMBINED NEVER-LATE ALGORITHM

### 1.1 Shape

Three route-static arrays precomputed once per leg; one forward march per tick;
composed as `sMax = min(freeRun, s_fast)`. TOPP forward-backward
velocity-profile sweep (SOTA min-time speed profile along a fixed path under a
position-dependent speed limit).

```
PRECOMPUTE ONCE PER LEG (anchor-independent), on a uniform grid ds ≤ 25 m:
  vCeil[i]  = curve ceiling from OSM curvature (see §3), = V_LINE where untrusted
  vBrake[i] = backward pass: terminal-braking parabola into every SERVED stop
  served[i] = this trip's stopMeters ∪ {target}   (user-selected service)

PER-TICK FORWARD MARCH from the anchor:
  seed v = v0  (over-bounded anchor speed; §4)
  for each cell forward:
     vHat  = min(vAccel_cellmax, vCeil_cellmax, vBrake_cellentry)   // UPPER bound on true speed in cell
     t_cell = CLOSED-FORM traversal time of the cell (never ds/v through v≈0)  // LOWER bound on true time
     consume t_cell from the time budget dt
     at a served station: force vOut = 0, subtract W_min (mandatory dwell)
  s_fast(dt) = position when budget dt is exhausted
```

### 1.2 Dart-ready pseudocode (mirrors the target file's style)

```dart
// ===== A. PRECOMPUTE: RouteProfile.precompute(polyline, served, cfg) =====
// 1. Curvature -> curve ceiling. Menger circumradius over a moving chord
//    L ≈ 160 m on an arc-length spline (NOT raw finite differences — vertex
//    noise fabricates phantom curves). Noise-floored:
//        kappaSafe = max(0, kappaSmoothed - k * 9.76 * sigmaPos / (L*L)),  k >= 3
//    vCeil[i] = (cfg.curveTrusted && kappaSafe > 0)
//                 ? min(V_LINE, sqrt(cfg.aLatEffMps2 / kappaSafe))    // R_used = 1/kappaSafe >= R_true
//                 : V_LINE;                                           // untrusted geometry => inert
//    if (!vCeil[i].isFinite) vCeil[i] = V_LINE;                       // NaN guard (dup/zero-spacing vertex)
//
// 2. served[i] = (s_i within snapTol of a served-station arc)         // this trip's stops ∪ target
//
// 3. Backward brake pass (route-static terminal-braking parabola):
//    vBrake[N] = served[N] ? 0 : V_LINE;                              // target is served => 0
//    for (i = N-1; i >= 0; i--)
//        vBrake[i] = served[i] ? 0
//                  : min(vCeil[i], sqrt(vBrake[i+1]*vBrake[i+1] + 2*dMax*ds));
//    // store { List<double> s, vCeil, vBrake; List<bool> served } on RouteTopology

// ===== B. FORWARD MARCH: _fastestFeasibleProgress (replaces _topologyCappedProgress) =====
double _fastestFeasibleProgress({
  required double sHi, required double dt, required double v0,
  required double aMax, required double dMax, required double wMin,
  required RouteProfile p,
}) {
  double pos = sHi, timeLeft = dt, v = v0;
  int i = _firstSampleStrictlyAfter(p.s, pos);            // binary search
  while (i < p.s.length && timeLeft > 0) {
    final double a = pos, b = p.s[i], ds = b - a;
    final double vCeilMax = math.max(p.vCeil[i - 1 < 0 ? 0 : i - 1], p.vCeil[i]);
    final double vBrakeEntry = p.vBrake[i - 1 < 0 ? 0 : i - 1];    // >= vBrake[i]
    // Closed-form cell traversal time under accel cap from v, ceilinged at
    // vCap = min(vCeilMax, vBrakeEntry). Three regimes; NO division by ~0.
    final double vCap = math.min(vCeilMax, vBrakeEntry);
    final _Cell c = _cellTime(v: v, ds: ds, aMax: aMax, vCap: vCap); // see §1.3
    if (c.time >= timeLeft) {                              // budget runs out mid-cell
      pos += _cellAdvance(v: v, aMax: aMax, vCap: vCap, dt: timeLeft); // closed-form, MAX-speed => over-bound
      timeLeft = 0; break;
    }
    pos = b; timeLeft -= c.time; v = math.min(vCap, c.vExit);
    if (p.served[i]) {                                     // train stops here
      v = 0;
      if (timeLeft <= wMin) { timeLeft = 0; break; }       // stuck dwelling
      timeLeft -= wMin;                                    // mandatory dwell plateau
    }
    i++;
  }
  if (timeLeft > 0) pos += p.vLine * timeLeft;             // past last sample: coast at line cap
  return pos;                                              // = s_fast(dt)
}

// ===== C. COMPOSE: Reachability.bound (outer structure UNCHANGED) =====
//   freeRun = anchor.sHi + v * dtClamped;                 // existing
//   sMax = freeRun;
//   if (topology?.profile != null && cfg.dynamicLeversEnabled) {
//     final sFast = _fastestFeasibleProgress(sHi: anchor.sHi, dt: dtClamped,
//         v0: _seedSpeed(anchor, v /*V_LINE*/, cfg),      // §4 over-bounded seed
//         aMax: cfg.aMaxMps2, dMax: cfg.dMaxMps2, wMin: cfg.dwellMinSeconds,
//         p: topology.profile);
//     sMax = math.min(freeRun, sFast);                    // cap can only REDUCE freeRun
//   }
//   // keep: non-finite anchor/clock => +inf ; hardTMax watchdog => +inf ; reachesTarget unchanged
```

### 1.3 The closed-form cell time (MANDATORY — closes red-team root cause #2)

Never integrate `ds/v*` across `v≈0`. Per cell, given entry speed `v`, accel
`aMax`, in-cell speed cap `vCap`, and length `ds`:

```
// speed reached under pure accel over ds, if uncapped:
vFree = sqrt(v*v + 2*aMax*ds)
if (vFree <= vCap):                        // accel-limited whole cell
    vExit = vFree
    time  = (vExit - v) / aMax             // = ds / ((v+vExit)/2)  — exact, v+vExit>0 always
else:                                       // accel to vCap, then cruise at vCap
    dsAccel = (vCap*vCap - v*v) / (2*aMax)
    time    = (vCap - v)/aMax + (ds - dsAccel)/vCap
    vExit   = vCap
```

`v+vExit > 0` for every cell that has any length because either `v>0` or
`aMax>0` gives `vExit=sqrt(2·aMax·ds)>0`; the average-speed form has no
`v→0` singularity. For a served-stop **exit** cell (`v=0`) the first regime
gives `time = sqrt(2·ds/aMax)` (triangular), the exact fastest launch time.
`_cellAdvance` uses the same closed forms to place `pos` at the MAX in-cell
speed when the budget expires (over-estimates position ⇒ safe).

### 1.4 Exact edits to `reachability.dart`

- **`VLineTable`** (l.50): unchanged. `RouteProfile` reads `V_LINE` via the
  resolved per-leg ceiling passed into `precompute` (store as `p.vLine`).
- **`ReachabilityConfig`** (l.191): add fields, all defaulting to the
  free-run-safe state:
  ```dart
  final double aMaxMps2;        // = 2.5  (adhesion ceiling; dominates traction+grade — §2)
  final double dMaxMps2;        // = 3.5  (adhesion + upgrade-grade assist + track-brake — §2)
  final double aLatEffMps2;     // = 7.0  (empty-car overturning + max cant — §2)
  final bool   dynamicLeversEnabled; // = false (Phase 0a dwell-only ships first)
  final bool   curveTrusted;    // = false (curve layer inert until §3 validation)
  // dwellMinSeconds stays (default 0.0)
  ```
- **`RouteTopology`** (l.176): add an optional
  `RouteProfile? profile` and a `RouteProfile.precompute(List<LatLng>
  polyline, List<double> servedStations, ReachabilityConfig cfg, double vLine)`
  factory (curvature helper + backward brake pass; O(N) build, O(N) memory).
- **`Reachability.bound`** (l.249): keep every fail-safe. Replace the l.292
  branch so the profile path runs only when `cfg.dynamicLeversEnabled &&
  topology.profile != null`; otherwise fall to the **existing**
  `_topologyCappedProgress` when `dwellMinSeconds > 0` (Phase 0a), else
  `freeRun`. Add an optional `bool anchorAtRest` is REMOVED in favor of the
  over-bounded seed (§4).
- **`_topologyCappedProgress`** (l.321): KEEP as-is for Phase 0a (dwell-only).
  Add the new `_fastestFeasibleProgress` alongside it; do not delete the proven
  dwell-only path — it is the fallback every degraded case lands on.
- **`alarm_controller.dart`** (l.1394–1445): build the `RouteProfile` once when
  the leg context is set (has `polylineDecoded` + `stopMeters`), hand it in via
  `RouteTopology.profile`. Keep the P1 multi-leg `vMaxFwd` over-bound and the
  FINDING-3 `reachBlackoutMinSeconds` gate exactly as today.

### 1.5 Pointwise proof: `s_fast(dt) ≥ s_true(t0+dt)`

Assume at the pessimistic edge: (A) `v0 ≥ v_true(t0)`; (B) `aMax ≥` true launch
accel *including grade*; (C) `dMax ≥` true brake decel *including grade*; (D)
`vCeil(s) ≥ v_true(s)`; (E) `served ⊆` true-stop-set with true dwell `≥ wMin`.

- **Step 1 (pointwise speed cap).** Any admissible true trajectory obeys three
  individually valid upper bounds at arc `s`: `v_true ≤ vCeil` (D); `v_true ≤
  sqrt(v0²+2·aMax·(s−s0))` and, having left the last served stop at rest, `≤
  sqrt(2·aMax·(s−p_prev))` (A,B,E); `v_true ≤ sqrt(2·dMax·(p_next−s))` for the
  next served stop it must brake to 0 at (C,E). So `v_true(s) ≤ v*(s) :=`
  min of the three. `vHat` uses the cell-MAX of each envelope, so `vHat ≥
  max_{s∈cell} v*(s) ≥ v_true(s)`.
- **Step 2 (time is a lower bound).** `T_true(s) = ∫ ds'/v_true + dwell`.
  Since `v_true ≤ vHat` cellwise and `t_cell` is the exact time at speed `≤
  vHat` (§1.3), `∫ ds'/v_true ≥ Σ t_cell`; and true dwell `≥ wMin` at each
  served stop (E), so `t*(s) := Σ t_cell + Σ wMin ≤ T_true(s)`. Extra unmodeled
  stops only add to `T_true` (loosen).
- **Step 3 (invert).** `s_fast(dt) = sup{s : t*(s) ≤ dt}`. At wall time
  `t0+dt` the true train is at `s_true(t)` with `T_true(s_true(t)) ≤ dt`. By
  Step 2, `t*(s_true(t)) ≤ dt`, so `s_true(t) ≤ s_fast(dt)`. ∎

The min-of-valid-upper-bounds lemma (monotone in the evidence set) guarantees
any dropped/degraded term only relaxes the cone. `min(freeRun, s_fast)` caps a
too-large `s_fast`; the only LATE direction is a term violating (A)–(E) at its
pessimistic edge, enumerated and guarded in §6.

---

## 2. CONSTANTS TABLE

Every kinematic constant is set to the **reach-maximizing (largest-plausible)
input**, reconciled with the red-team's grade and empty-car corrections. The
one exception is dwell, which must **lower-bound**.

| Constant | HARDCODE | Over-bound direction | Grounding / why this value (not the design's) | source_url |
|---|---|---|---|---|
| `aMaxMps2` (launch) | **2.5** | UPPER (larger ⇒ looser ⇒ safe) | Design proposed 1.3–1.5 (comfort/service). **RED-TEAM: on a downgrade departure true accel = traction(1.3–1.5)+g·sinθ; a 4% grade adds 0.39, a 6% grade 0.59 → 1.9–2.1 > 1.5 → LATE.** Set `aMax` to the **wheel-rail adhesion ceiling ~0.25 g = 2.45 → 2.5**, which dominates any traction+grade combination. Symmetric with `dMax`. | https://thecontactpatch.com/rail/r0816-railway-braking ; https://link.springer.com/article/10.1007/s40864-015-0012-y ; https://en.wikipedia.org/wiki/List_of_steepest_gradients_on_adhesion_railways |
| `dMaxMps2` (terminal brake) | **3.5** | UPPER | FOUNDATION §7: use the LARGEST achievable decel, not service brake ~1.3. Adhesion ceiling 2.45 (dry). **RED-TEAM: on an upgrade approach true decel = adhesion+g·sinθ ≈ 2.45+0.59 = 3.04; add track-brake margin → 3.5.** A too-low `dMax` puts the brake parabola below feasible hard-braking → LATE. | https://thecontactpatch.com/rail/r0816-railway-braking ; https://www.sciencedirect.com/topics/engineering/adhesion-coefficient ; https://railwaynews.net/wiki/train-braking-distance-how-long-does-a-train-take-to-stop |
| `aLatEffMps2` (curve) | **7.0** | UPPER | Design proposed 4.0 (overturning-only, loaded CG). **RED-TEAM #1: the cant gravity term ADDS to the lateral budget — `v_max = sqrt(R·(g·tanθ_cant + g·b/h_cg))`, +~1.2 at 180 mm cant. #2: the fastest-capable curve train is the EMPTY car (lower h_cg≈1.4) → overturning ≈ g·0.7175/1.4 = 5.0.** Sum 5.0+1.2 = 6.2 → hardcode **7.0** (higher only loosens). NOT comfort/tilt-deficiency 1.3–1.8 (those UNDER-bound and fire late). | https://en.wikipedia.org/wiki/Cant_deficiency ; https://railwaytrackblog.com/2015/10/29/11-82_cant-deficiency-un-compensated-acceleration-pway/ ; https://interfacejournal.com/archives/581 ; https://www.tandfonline.com/doi/full/10.1080/00423114.2021.1917631 ; https://www.thepwi.org/wp-content/uploads/2021/02/Journal-201910-Vol137-Pt4-Speed-restrictions.pdf |
| cant / superelevation | derive-only (≤180 mm) | (feeds `aLatEff`) | Max ~150–180 mm on 1435 mm gauge (UIC ~7°). Bundled into `aLatEff` as the +1.2 m/s² term; no separate config field (OSM has no per-curve cant). | https://www.law.cornell.edu/cfr/text/49/213.57 |
| `dwellMinSeconds` (W_min) | **0.0** default; **7.0** opt-in | LOWER (must UNDER-count) | Default 0 ⇒ dwell cap inert ⇒ unconditionally safe. Opt-in per certified all-stops line to the **door-cycle floor ~7–9 s** (PSD open 2–3 s + close 5–6 s). NEVER the 15–30 s mean (that over-subtracts ⇒ LATE). | https://www.railengineer.co.uk/station-stops-something-to-dwell-on/ |
| jerk | **NOT a cone constant** | n/a | The trapezoid is the `J→∞` limit; a real jerk-limited train reaches every position no later, so `s_scurve(t) ≤ s_trap(t)`. A finite jerk models a SLOWER train ⇒ under-bound ⇒ LATE. Jerk belongs only to the ESTIMATE/timing path, never the fire trigger. | https://link.springer.com/article/10.1007/s40864-015-0012-y |
| `V_LINE` | 28 / 39 / 53 m/s | UPPER | Existing `VLineTable` (metro / express / RRTS). Unchanged — already a real over-bound. | https://en.wikipedia.org/wiki/Delhi%E2%80%93Meerut_Regional_Rapid_Transit_System |

**Per-line overrides.** Conventional Namma/Delhi/Chennai/Kochi metros:
`aMax=2.5, dMax=3.5, aLatEff=7.0, W_min=7.0` (only if `allStopsService=true`),
`V_LINE=28`. RRTS/Namo Bharat: same kinematics, `V_LINE=53`, but
`allStopsService=false` by default (RRTS runs express patterns) ⇒ `W_min=0`
until the confirmed trip-stop set is trusted. Car mode: `aLatEff=15–16` (banked
road-curve envelope — §5), no dwell/brake. **Never tighten any constant toward
observed maxima** — a newer/faster/lower-CG stock exceeds the sample ⇒ LATE.

Curvature precompute constants: chord `L ≈ 160 m`, `sigmaPos ≥ 5 m`
(**must be MEASURED, not asserted — §3/§6**), noise-floor multiplier `k ≥ 3`,
grid `ds ≤ 25 m`.

---

## 3. DATA PLAN

### 3.1 The curvature source correction (critical)

`assets/osm/bengaluru.wkp` is a **ROAD** pathfinder graph (406,778 nodes /
856,298 edges, `roadType ∈ {motorway..service}`; the `RoadType` enum tops out
at `road(15)` with **no rail member**). It has no metro alignment. The
authoritative owned curvature source is **OSM rail route relations**, already
extracted into `claudesciencesession/data/rail_geometry.json` (keys `green`
rel 1798772: 503 vtx, 35,223 m; `purple` rel 7841331: 931 vtx, 43,526 m).

**But that file is NOT usable as-is** (three red-team blockers):
1. `curvature_invm` was computed with **raw `np.gradient`** — the noisy
   estimate, not a never-late-safe over-estimate of `R`. Never feed it to a cap.
2. The green relation **folds back on itself** (idx0 ≡ idx19 at 0 m spatial
   separation; a 1282 m phantom stitch chord; duplicate/zero-spacing vertices)
   → `project_to_arc` is multi-valued → mis-snap → LATE.
3. `sigmaPos` is **asserted (5 m) not measured**; low-zoom hand-digitised rail
   relations may be 10–15 m → the 3σ floor removes only ~1σ → phantom curvature
   survives on straight track → LATE.

### 3.2 `rail_geometry.json` v2 schema (ship into `assets/rail/`)

```jsonc
"<city>__<line>": {
  "rel_id": "1798772", "direction": "north", "network": "bmrcl",
  "V_LINE_mps": 28.0, "all_stops_service": false,
  "sigma_pos_m": 5.0, "chord_L_m": 160.0, "k_sigma": 3, "aLatEff_mps2": 7.0,
  "n_vertices": 503, "length_m": 35223.0,
  "lat": [...], "lon": [...], "arc_m": [...],          // real curved polyline (strictly monotone arc)
  "kappa_safe_invm": [...], "R_safe_m": [...], "vCurveCeil_mps": [...], // never-late-safe, precomputed
  "min_R_safe_m": 75.3, "frac_capped_below_vline": 0.219,
  "stations": [{"name": "...", "seq": 0, "s_travel_m": 0.0, "lat": ..., "lon": ..., "perp_m": 3.1}],
  "self_approach_zones": [[arc_lo, arc_hi], ...],      // detected folds — force vCeil=V_LINE here
  "provenance": {"source": "osm_overpass", "rel_url": "...", "extracted_utc": "...", "kernel": "wakepoint-rail-geometry"}
}
```

### 3.3 Extraction pipeline (deterministic, committed as a `tools/` script)

Regenerate via the on-disk `wakepoint-rail-geometry` skill
(`fetch_metro_routes → stitch_polyline → arclength_m → heading_curvature →
project_to_arc`) **plus the missing never-late post-process**:

1. **Repair geometry BEFORE it can cap anything** (guard for red-team blocker
   #2): detect chord-jumps `> 150 m` and duplicate/zero-spacing vertices;
   split/drop spur or mis-stitched members; rebuild `arc_m` strictly monotone;
   record any surviving self-approach (spatial `< 60 m` & arc-gap `> 500 m`) in
   `self_approach_zones`. **REFUSE to emit a line** (leave `vCeil=V_LINE`) if a
   self-approach cannot be resolved.
2. **Safe curvature**: fit smoothing spline / moving-chord Menger circumradius
   (`L≈160 m`) → `kappa_smoothed`; `sigma_kappa = 9.76·sigmaPos/L²`;
   `kappa_safe = max(0, |kappa_smoothed| − k·sigma_kappa)`, `k≥3`;
   `R_safe = kappa_safe>0 ? 1/kappa_safe : +inf`;
   `vCurveCeil = min(V_LINE, sqrt(aLatEff·R_safe))`. Map `NaN → V_LINE`.
3. **Served-stop-from-route insight**: the served-station set for a trip is
   **`leg.stopMeters ∪ {legEndMeters}`** — exactly the stations the
   user-selected service calls at (route_session_manager → sensor_fusion l.155
   → alarm_controller l.1415). This is correct-by-construction: express/skip
   traps are removed because the user picked the service. Project each station
   onto the rail (`project_to_arc`), assert `perp_m < 40 m` (flag, don't
   silently accept a cross-line wrong-snap).
4. **Per-line `all_stops_service` flag**: author by hand from published service
   patterns (Delhi Airport Express, RRTS/Namo Bharat, Mumbai Suburban run
   express) — DEFAULT `false`. Optional owned corroboration: BMRCL GTFS
   `stop_times` (static, owned — NOT crowd).

### 3.4 Committed real-curvature VALIDATION fixtures

The shipped fixtures' `oriented_polyline` is
`shipped_station_coords_straightline_densified` (29,483 m straightline vs
35,223 m real green = **19.5% under, zero curvature**) → the curve layer is
provably **inert** on every committed fixture. A green curve test there is
FALSE confidence. Emit new `<city>__<line>__realgeom_<scenario>/base.json` with
`oriented_polyline = rail_geometry.lat/lon` (real curve),
`polyline_source = "osm_rail_relation_<relid>"`, projected stations (real
`s_travel`), and a ground truth `s_true(t)` synthesized to OBEY
`v(s) ≤ min(V_LINE, sqrt(aLatTrue·R_true(s)))` with `aLatTrue` set just **below**
the overturning limit so GT actually corners fast and stresses the bound.

### 3.5 What is NOT owned

Track grade/elevation: no elevation columns anywhere in `lib/`. **OMIT grade
from `vCeil`** (a missing downhill ceiling only relaxes upward). Grade is
handled instead by the adhesion-ceiling `aMax/dMax` (§2), which dominate it —
so no per-segment grade data is required. If a downhill-cap is ever wanted,
acquire from SRTM 30 m / OSM `ele` — static, no crowd.

---

## 4. CREATIVE PHYSICS-ONLY EXTRA LEVERS (ranked)

| # | Lever | Never-late-valid? | Data? | Magnitude | Notes |
|---|---|---|---|---|---|
| 1 | **Over-bounded departure seed `v0`** | YES *with fix* | Owned (pre-blackout fixes) | ~120–200 m / blind window | Design proposed binary `atRest ⇒ v0=0`. **RED-TEAM: a noisy platform fix (multipath Doppler) reports 1.3 m/s while truly 4 m/s ⇒ v0 under-bound ⇒ LATE; and a downhill-dip departure beats flat `aMax`.** FIX: never hard-seed 0. `v0 = clamp(reportedSpeed + k·speedAccuracy, 0, V_LINE)`, `k≥3`, using GPS `speedAccuracy`; fall to `V_LINE` when absent. Drop the binary bit. Combined with `aMax=2.5` (grade-safe). |
| 2 | Grade-adjusted dynamics | YES | NOT owned (needs DEM) | ~10–70 m/launch | Superseded: instead of per-segment grade, `aMax/dMax` are set to the adhesion ceiling that dominates worst-case metro grade (§2). No DEM needed. |
| 3 | Turnout/junction civil cap | YES-conditional | OSM `railway=switch` | Small (rare nodes) | Hard 15–50 km/h cap at switches; largely already caught by the curve lever where OSM resolves switch curvature. One more `min()` into `vCeil`; unknown class ⇒ highest (loosest). |
| 4 | Superelevation refinement | Mandatory CORRECTION (loosens) | per-line constant | — | The +1.2 m/s² cant term already folded into `aLatEff=7.0`. Omitting it is the LATE direction, so it is non-optional whenever the curve lever is on. |
| 5 | Traction roll-off `a(v)` | YES-conditional | stock P/m | Marginal | Real accel falls below `aMax` near `V_LINE` (only tightens); hard to over-bound across future stock. Low ROI. |
| T1 | Jerk-limited ramp | **NO — TRAP** | — | — | Reach-max train jerks arbitrarily hard; `s_jerk < s_trap` ⇒ LATE. Keep trapezoid. |
| T2 | Headway / signal-block | **NO — TRAP** | not ownable | — | Block ahead may be empty ⇒ no valid travel-time floor. |
| T3 | Published timetable run time | **NO — TRAP** | — | — | Padded schedules upper-bound typical time; trains run early ⇒ not a lower bound. Only as discounted prior `sched·(1−f)` behind the P1 statistical flag, never a hard trigger. |

---

## 5. GATING / MODES TABLE

Within a known mode the cone is a `min()` of valid upper bounds (tightening);
across an ambiguous plausible-leg set `P` it is a `max()` over modes (least
tightening — the existing `vMaxFwd` loop). Every lever defaults OFF and
degrades to free-run.

| Data present | Levers active | Never-late? / proof |
|---|---|---|
| none / unknown mode | L0 freeRun only | YES — baseline `v ≤ V_LINE` |
| rail, `all_stops_service=true`, servedStops | L0 + dwell cap (+ terminal brake at V_LINE) | YES (Phase 0a) |
| rail, `curveTrusted=true` (validated geometry) | L0 + curve ceiling | YES — `vCeil ≥ v_true` (§1.5 D) |
| rail, full data + `dynamicLeversEnabled` | full stack (accel ramp + brake + curve + dwell) | YES if constants at adhesion ceiling (§2) |
| **car** | L0 + curve ceiling with `aLatEff=15–16` **only** | dwell/terminal HARD-DISABLED (a car has no mandatory stops ⇒ assuming a stop under-states progress ⇒ LATE). **RED-TEAM: `aLatEff=12` under-bounds banked road curves (`g·(μ+tanθ)/(1−μ·tanθ)` exceeds 12 for θ≳6°) ⇒ LATE. Use the banked envelope μ_max=1.3, e_max=0.12 ⇒ ≥15, OR keep curve OFF (freeRun) for car.** Default: car = freeRun-only until banked-curve geometry validated. |
| **walk** | L0 only, `V_LINE_walk = 12.5 m/s` (human-sprint over-bound) | all rail levers OFF. **RED-TEAM: bounded-PDR term assumes recall=1 step detection; real recall<1 ⇒ dropped step under-counts distance ⇒ LATE. Keep PDR DISABLED by default.** |
| ambiguous walk∪rail (tunnel mouth) | L0 at `max_P V_LINE`; dwell/terminal DROPPED (walk has no stops) | YES — mode-max; `P.every(rail)` predicate fails ⇒ stop levers inert |
| corrupt anchor/clock (non-finite) | +inf ⇒ fire now | YES — fail-safe toward firing |
| express present, `all_stops_service=false` (default) | L0 (+curve if trusted) | YES — express trap avoided by default |
| express present but `all_stops_service` MIS-SET true w/ skipped stop | over-subtracts | **NO — the ONLY late path; excluded by the negative test in §6** |

**Enable predicates** (each disabled lever contributes `+inf` to the `min()`):
- Dwell/terminal ON iff `P.every(mode==rail && allStopsService && servedStops
  non-empty)`.
- Departure seed uses over-bounded `v0` always (never binary 0).
- Curve ON iff `P.every(curveTrusted)` AND the read passes the perp +
  arc-monotonicity guards (§6); else `vCeil=V_LINE`.
- Dynamic levers ON iff `dynamicLeversEnabled` AND constants at adhesion
  ceiling. **Default OFF ⇒ Phase 0a dwell-only ships first.**
- Params use the LOOSEST over `P`: `V_LINE=max`, `aLatEff=max`, `aMax/dMax=max`.
- **Mode-gate**: dwell/brake/topology levers apply ONLY on the confirmed
  transit leg — never inherited by a car/road leg (a car drives through a rail
  station; rail dwell there forces `v=0` where the car keeps moving ⇒ LATE).

---

## 6. RED-TEAM SUMMARY — every late-fire path + its MANDATORY guard

These are not suggestions. Each ships with a **negative CI test** that must
FAIL the pointwise `s_max ≥ s_true` assertion when the guard is removed, proving
the guard is load-bearing.

| # | Late-fire path (source) | Root cause | MANDATORY guard |
|---|---|---|---|
| R1 | **Downhill departure ramp** — 4% downgrade, true accel 1.69 > model 1.3–1.5; ~70 m lag/launch STACKS over a multi-station blind run (combined_algorithm, WHOLE_ALGORITHM, creative_physics) | `aMax` is a reach-maximizing input, grade omitted | `aMax = 2.5` (adhesion ceiling, dominates traction+grade). Negative test: synthetic downgrade departure with true accel > aMax must FAIL under old `aMax=1.5`, PASS under 2.5. |
| R2 | **Upgrade brake approach** — true decel 2.84 > model 2.5 within ~157 m of station (combined_algorithm) | `dMax` grade omitted | `dMax = 3.5` (adhesion + upgrade assist + track-brake). |
| R3 | **`1/v*` at `v→0`** — naive `ds/v` Riemann sum at rest launch / brake node over-estimates `t*` ⇒ `s_fast` too small (or `NaN`⇒never-fire) (constants, WHOLE_ALGORITHM) | numeric singularity | Closed-form cell time §1.3 (average-speed / triangular forms); floor `vCap` never divides. Negative test: coarse-`ds` launch node must satisfy `s_fast ≥ s_true`. |
| R4 | **`project_to_arc` self-approach mis-snap** — green rel folds (idx0≡idx19), straight fast segment snaps to R≈75 m branch ⇒ ~450–550 m lag (data_extraction) | multi-valued space→arc map | Perp guard (reject perp > 15–20 m) + arc-monotonicity guard (reject arc jump > local live spacing) + `self_approach_zones ⇒ vCeil=V_LINE`; repaired extraction §3.3. Negative test: fold fixture must FAIL without guards. |
| R5 | **`sigma_pos` asserted not measured** — true 10–15 m ⇒ 3σ floor removes ~1σ ⇒ phantom curvature on straight track (data_extraction) | unvalidated noise floor | MEASURE `sigma_pos` vs GTFS-shapes/survey reference; set to ≥99th-pct; keep `curveTrusted=false` until then. Raw `curvature_invm` NEVER feeds a cap. |
| R6 | **Noisy platform `v0=0`** — multipath Doppler reads 1.3 m/s while truly 4 m/s ⇒ v0 under-bound (creative_physics) | binary at-rest certification | `v0 = clamp(reportedSpeed + k·speedAccuracy, 0, V_LINE)`, drop binary bit; fall to `V_LINE` when `speedAccuracy` untrusted. Negative test: moving-at-platform fix must FAIL under old `v0=0`. |
| R7 | **`aLatEff` too low** — cant term omitted (design 4.0) and loaded-CG used; empty car on 180 mm cant needs 6.2 (constants, data_extraction) | curve ceiling under-bound | `aLatEff = 7.0` (empty-car overturning + max cant). |
| R8 | **Car banked-curve** — `aLatEff=12` under-bounds superelevated road ramps in a tunnel (gating_modes) | flat-road friction ceiling | `aLatEff_car ≥ 15–16` (banked envelope) OR car curve layer OFF (freeRun). Negative test: banked R=60 m e=0.10 car @28 m/s must FAIL under 12. |
| R9 | **Walk PDR recall<1** — dropped step under-counts distance (gating_modes) | step-detection recall asserted =1 | PDR term DISABLED by default; walk uses sprint over-bound `V_LINE=12.5` free-run. |
| R10 | **Express skip-run** — statically-confirmed stop skipped by a delayed train ordered express; terminal brake forces `v=0` mid-gap (WHOLE_ALGORITHM, gating_modes) | dynamic (real-time) skip breaks served-set | `all_stops_service` default FALSE; terminal brake/dwell only on lines proven never to skip; **mode-gate to the confirmed transit leg**. Negative test: express with a skipped station in servedStops must FAIL. |

Residual (irreducible without sensing): dynamic real-time skip-running on a
line flagged all-stops. Bounded to the `all_stops_service` flag + R10 negative
test; the safe default (false) closes it at the cost of the dwell shave on
those lines.

---

## 7. WHAT ELSE WE NEED (concrete acquisition list)

Owned now (zero collection): served-stop arcs (`leg.stopMeters` +
`legEndMeters`), `V_LINE` (`VLineTable`), all kinematic constants (literature,
§2), green+purple curved polylines (`rail_geometry.json`, needs v2
post-process).

Must acquire (gated, out of scope, **NO crowd data**):
1. **Real per-line rail geometry** for every fixture/production city (agra,
   ahmedabad, chennai, delhi, delhimeerutrrts, …) — deterministic OSM via the
   `wakepoint-rail-geometry` skill, then the §3.3 repair + safe-curvature
   post-process. Public static OSM, not telemetry.
2. **Measured `sigma_pos`** per relation vs a GTFS-shapes/survey reference
   (expect 10–15 m). Load-bearing for R5.
3. **Per-line `all_stops_service`** flag + explicit express-line list
   (Delhi Airport Express, RRTS/Namo Bharat, Mumbai Suburban). Author by hand;
   default FALSE.
4. **GPS `speedAccuracy`** threaded onto the anchor (Android
   `getSpeedAccuracyMetersPerSecond` / iOS `speedAccuracy`) for R6.
5. **P0c acceptance gate**: replay Nallur/Majestic + the 391-ride scale set
   against REAL geometry, assert `s_max(t) ≥ s_true(t)` pointwise, 0 violations,
   before flipping `curveTrusted`.
6. (Optional) SRTM/OSM `ele` grade — only if a downhill ceiling is later wanted;
   omitting it stays safe because adhesion-ceiling `aMax/dMax` dominate grade.

**Expected early-fire reduction (physics-only, NO crowd data):**
- **Phase 0a (dwell cap only, ships first, unconditionally safe):** 14 min →
  **~12.5–13 min** on an all-stops line (6 stops × ~7 s door-floor + the
  teleport-at-V_LINE structure is a weak shave; most of the 14 min is the
  below-fastest-feasible gap).
- **Phase 0b (+ terminal braking + over-bounded departure seed, adhesion
  constants):** → **~11–11.5 min**.
- **Phase 0c (+ curve ceiling, after `curveTrusted` validation):** → **~10 min**
  (green min_R 75 m ⇒ 17 m/s hard cap on 22% of length).
- **Full stack, grade-safe constants:** → **~9.6–10 min** (~4 min shave, all
  physics-only). Note this is **more conservative than the design's 9.6 min**
  because the grade-safe `aMax=2.5`/`dMax=3.5` (vs 1.3/2.5) deliberately weaken
  the accel/brake bite to stay never-late — the extra looseness is the price of
  closing R1/R2. The remaining ~9.6 min is this run's genuine
  below-fastest-feasible gap, irreducible without sensing or crowd data.

---

## APPENDIX — all preserved source_urls

Time-optimal train motion is bang-bang (drop coasting):
https://www.sciencedirect.com/science/article/abs/pii/S0377221716307962 —
Forward-backward TOPP sweep is SOTA min-time profile:
https://arxiv.org/abs/2509.26428 —
Brake authority = adhesion ceiling:
https://thecontactpatch.com/rail/r0816-railway-braking —
Adhesion coefficient 0.17–0.25:
https://www.sciencedirect.com/topics/engineering/adhesion-coefficient —
Cant deficiency / curve speed law:
https://en.wikipedia.org/wiki/Cant_deficiency —
Tilt uncompensated 5–6 ft/s² is comfort not ceiling:
https://interfacejournal.com/archives/581 —
Metro accel/decel ~1.0–1.5, jerk ~1:
https://link.springer.com/article/10.1007/s40864-015-0012-y —
Dwell door-cycle floor ~8–9 s:
https://www.railengineer.co.uk/station-stops-something-to-dwell-on/ —
Curvature via moving-chord not finite differences:
https://www.mdpi.com/1424-8220/23/1/274 —
Min of upper bounds is a valid tighter bound:
https://hybrid-robotics.berkeley.edu/publications/CBVF.pdf —
Braking distance / mu ≥ 0.12:
https://railwaynews.net/wiki/train-braking-distance-how-long-does-a-train-take-to-stop —
Munich C2 max start accel 1.3:
https://www.railway-technology.com/projects/c2-metro-trains-munich-underground-bavaria/ —
Alstom Metropolis accel/decel:
https://en.wikipedia.org/wiki/Alstom_Metropolis_98B —
Cant-deficiency 11.82 law:
https://railwaytrackblog.com/2015/10/29/11-82_cant-deficiency-un-compensated-acceleration-pway/ —
Max superelevation 150–180 mm:
https://www.thepwi.org/wp-content/uploads/2021/02/Journal-201910-Vol137-Pt4-Speed-restrictions.pdf —
Lateral accel operational ≤0.15 g / rollover:
https://www.tandfonline.com/doi/full/10.1080/00423114.2021.1917631 —
Indian metro speed tiers / RRTS:
https://en.wikipedia.org/wiki/Delhi%E2%80%93Meerut_Regional_Rapid_Transit_System —
OSM positional accuracy RMSE:
https://wiki.openstreetmap.org/wiki/Accuracy —
Overturning / inner-wheel unloading:
https://www.frontiersin.org/journals/mechanical-engineering/articles/10.3389/fmech.2018.00008/full —
GTFS route-stop patterns (express detection):
https://www.transit.land/documentation/datastore/routes-and-route-stop-patterns.html —
BMRCL OSM rail relations / GTFS:
https://github.com/Vonter/bmtc-gtfs —
Steepest adhesion gradients (metros >4%):
https://en.wikipedia.org/wiki/List_of_steepest_gradients_on_adhesion_railways —
Ruling gradient:
https://en.wikipedia.org/wiki/Ruling_gradient —
Tractive effort ∝ 1/v:
https://en.wikipedia.org/wiki/Tractive_effort —
Turnout diverging speed caps (IRFCA):
https://irfca.org/faq/faq-pway.html —
Turnout speeds by frog number:
https://www.liquisearch.com/railroad_switch/turnout_speeds —
49 CFR 213.57 curve elevation rule:
https://www.law.cornell.edu/cfr/text/49/213.57 —
CBTC min headway 85–120 s:
https://railwaynews.net/wiki/what-is-headway-understanding-train-frequency —
GTFS schedule padding:
https://gtfs.org/documentation/schedule/reference/ —
Tire friction coefficient (car curve ceiling):
https://hpwizard.com/tire-friction-coefficient.html —
Cornering force:
https://grokipedia.com/page/Cornering_force —
Human footspeed 12.4 m/s:
https://en.wikipedia.org/wiki/Footspeed —
Fastest human:
https://www.britannica.com/story/how-fast-is-the-worlds-fastest-human —
Skip-stop service:
https://en.wikipedia.org/wiki/Skip-stop —
Safe speed on curves:
https://www.brainkart.com/article/Railway-Engineering--Safe-Speed-on-Curves_4226/ —
Car reduces to 1-D reachability:
https://www.mdpi.com/1424-8220/11/4/4244
