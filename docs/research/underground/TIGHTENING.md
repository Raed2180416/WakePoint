# TIGHTENING — minimizing early fires on long GPS-dark stretches

**Scope.** How to shrink the never-late reachability cone so the alarm stops firing minutes
early on long GPS-blind runs, **without ever firing late**. The shipped bound is the free-run
cone `s_max(t) = s0 + V_LINE·(t − t0)` (`lib/core/reachability/reachability.dart`, `freeRun` at
line 278). On a stopping metro this cruises the whole blackout at the scalar top speed
(~28 m/s) while the real train averages ~10–11 m/s — that gap **is** the early-fire error.

Everything below is one design rule: **the min of individually-valid upper bounds is itself a
valid upper bound** (proof in §3). Each tightener enters as one more `min()` term; a missing or
dropped term only relaxes the cone upward (earlier, safe). The **only** way to fire late is an
individually-*invalid* term — a term whose parameter under-bounds the fastest admissible train.
Every verifier finding below reduces to exactly that, and every fix is "over-bound the
reach-maximizing input."

> **Fixture caveat (applies to all geometry-dependent tighteners).** Each ride's
> `base.json oriented_polyline` is *straight-line-densified* (zero curvature), so the curve layer
> is **inert** on the shipped fixtures — a green test there is false confidence. Validate curvature
> against `claudesciencesession/data/rail_geometry.json` and the `assets/osm/bengaluru.wkp` graph.

---

## 1. Ranked table

Ranked by ship-priority = (available-now × provable-HARD × worst-case magnitude). Worst-case
column is the marginal shave on the canonical **14-min / 9-km / 6-station** `long_blind` run
(100 km/h line, V_LINE=28 m/s, true avg ~10.7 m/s, ~1.5 km spacing).

| # | Tightener | Available now? | Data needed | Never-late-valid? (verifier verdict) | Worst-case reduction |
|---|-----------|:--------------:|-------------|--------------------------------------|----------------------|
| 1 | **Mandatory dwell cap** (topology) | **Yes** — already coded (`_topologyCappedProgress`, l.321), just set `dwellMinSeconds>0` | Owned: `s_travel` station arcs, `V_LINE`. To gate: GTFS `stop_times` or per-line `all_stops_service` flag | **Conditional-HARD.** Valid iff `w`= proven dwell *lower* bound (door-cycle ~8–10 s) **and** every counted stop is confirmed served. Trap: express/skip-stop over-counts → LATE | ~1.3 min on 6 stops (`N·w`); **~5 min / ~35 %** on a 20-station blind run |
| 2 | **Accel + terminal-braking ramps** (kinematic bang-bang) | **Yes** — owned data + physics constants; rewrite the inner loop of `_topologyCappedProgress` | Owned: station arcs, `V_LINE`; constants `a_max`, `d_max` set to *largest plausible* | **Conditional-HARD.** Valid iff `a_max`,`d_max`= largest-plausible authority (adhesion-limited `d_max≈2.5`), applied only to confirmed stops, departure ramp only from a *certified* at-rest anchor | ~2.1 min more (effective ceiling 28 → ~16–18 m/s); `τ_ramp≈20–27 s`/stop |
| 3 | **Curve geometry speed profile** `V(s)` | **Yes** (geometry-gated) — from owned OSM polyline curvature | Owned: real OSM polyline (`rail_geometry.json`/`.wkp`, **not** the densified fixture). Constants: `a_lat_eff`, noise σ, chord ℓ | **Conditional-HARD.** Valid iff `a_lat_eff`= *overturning* limit (~4 m/s², not comfort 1.3/2.5) **and** R over-bounded (spline-smooth + multi-σ noise floor). Else omit (falls back to V_LINE) | ~1.0 min typical (0.15–0.4 station); ~0–2 min route-dependent; largest at sharp curves & station approaches |
| — | *(umbrella)* **Forward reachable set** = `min` of 1–3 in one velocity-profile sweep | Yes | (same as 1–3) | Valid iff each component is | **~4.4 min HARD** total: 14 → ~9.6 min |
| 4 | **Crowd / GTFS min segment time** | **No** — needs data pipeline | GTFS `stop_times` (bootstrap, day-1); crowd per-segment min via DP low-quantile + k-anon (v2 moat) | **STATISTICAL only.** Fastest-*observed* ≠ fastest-*possible* (new stock / empty / signal-priority beats it). Never a hard trigger; keep physics floor via `min()` + margin δ, or demote to soft/UX lead | ~0.9–1.4 min more (removes residual V_LINE over-bound 28 → ~22.2 m/s): ~9.6 → ~8.7 min |

**Reading the table.** Rows 1–3 are the **available-now HARD stack** (physics-proven, zero new
data collection). Row 4 is the **data moat** — tighter still (it encodes the *real*, not
over-bounded, dynamics) but only probabilistically never-late, so it is gated to a non-triggering
role. Every verifier returned `valid_upper_bound = false` for the *unconditional* form of each
tightener; each becomes a proven upper bound once its one unsafe parameter is over-bounded (the
"Never-late-valid?" column states the guard). The residual **~8.7 min is largely irreducible** —
it is this slow run's genuine gap below the fastest-*feasible* run, and no never-late bound may
fire inside it.

---

## 2. Per-tightener: derivation · upper-bound proof · quantified reduction · verifier rigor-check

Notation throughout: arc length `s` on the oriented polyline; true progress `s_true(t)`
non-decreasing; instantaneous speed `v ≤ V_LINE`; anchor `(s0, t0)` with `s0 = anchor.sHi ≥
s_true(t0)`; elapsed `Δt = t − t0`. Fire when the certified upper bound `U(t)` reaches
`s_dest − d_lead`; because `U ≥ s_true`, remaining true distance `≥ d_lead` ⇒ never late.

### 2.1 Mandatory dwell cap (topology)

**Derivation.** On an all-stops service the fastest train must physically pass and dwell ≥ `w` at
each intermediate station. With ordered intermediate arcs `p_1<…<p_M` strictly between anchor and
target, the minimum time to reach `s` is `T_reach(s) = (s−s0)/V_LINE + n(s)·w`, where
`n(s) = #{j : s0 < p_j < s}`. Inverting gives the piecewise-linear cap
`s_cap(Δt) = s0 + V_LINE·(Δt − N(Δt)·w)`, rising at slope `V_LINE` between stations and holding a
flat plateau of width `w` at each (position frozen while dwelling). This is **exactly** the
forward simulation already in `_topologyCappedProgress` (travel each gap at `V_LINE`, pay `w` at
each fully-passed station). The subtraction is **topology-coupled** — `Σ = N(t)·w`, only stations
*already passed* — not a flat `Σ` of all downstream dwells (that would over-subtract early).

**Upper-bound proof.** Fix `t`. Let `n = #{j : p_j < s_true(t)}`. On an all-stops service with
true dwell ≥ `w`, the real train spent ≥ `n·w` of `Δt` stationary, advancing 0. In the remaining
≤ `Δt − n·w` moving time, `v ≤ V_LINE`, so `s_true(t) − s0 ≤ V_LINE·(Δt − n·w)` ⇒
`T_reach(s_true(t)) ≤ Δt`. Since `s_cap(t)` is the largest `s` with `T_reach(s) ≤ Δt`,
`s_true(t) ≤ s_cap(t)`. ∎ Anchor conservatism (`s0 = sHi ≥ s_true(t0)`, counted stations have
`p_j > sHi`) guarantees each counted dwell falls inside `[t0, t]` — no double-count.

**Quantified reduction.** Firing at the target is delayed by exactly `M·w` — this lever **scales
with dark-stretch length**, unlike the one-time ramps. Namma Metro, `w=15 s`: 6 intermediate
stations ⇒ 90 s ≈ 1.5 min; **20 stations ⇒ 300 s ≈ 5.0 min ≈ 35–40 %** of a long_blind
over-count. Each intermediate station shaves `w·V_LINE ≈ 15×28 ≈ 420 m`.

**Verifier rigor-check → `valid_upper_bound = false` (conditional).** Confirmed LATE fire via
**dwell over-count**, root cause = counting a dwell that did not happen:
- *Express / skip-stop* (headline, deterministic): a limited service skipping `k` of the `M`
  "mandatory" stations pays 0 dwell there; the cap over-subtracts `k·w`. At `w=15 s`, `k=4` ⇒ fires
  ~60 s and up to ~2.3 km late. Skip-stop is a live peak-hour pattern (CTA A/B, Santiago L2/4/5).
- *Cross-line wrong-snap* (repo-specific): `enhanceTransitLegStopsWithOsm` historically injected a
  parallel other-line station ~145 m off the polyline (`test/metro_wrong_snap_test.dart`); a
  phantom station inflates `M` → one extra `w` late per phantom.
- *`w` over-estimate*: `w=15 s` is **not** a proven floor; the hard floor is the door cycle
  (~7–9 s). Any real off-peak dwell `< w` at a counted station over-counts → LATE.

**Fixes (make it valid):** set the mandatory-dwell set to **exactly this trip's scheduled stops**
from GTFS `stop_times` (skipped stations simply aren't in the set — express-safe by construction),
or gate behind a per-system `all_stops_service:true` flag; drop `w` to the door-cycle floor
(~8–10 s); exclude the target station; keep `sMax = min(freeRun, capped)`. Degrades to `w=0`
(= free-run, unconditionally safe) whenever all-stops cannot be certified. *NOT* a failure mode:
curve/`a_lat`/grade errors cannot make this term late — it cruises every gap at `V_LINE` and only
subtracts time.

### 2.2 Accel + terminal-braking ramps (kinematic bang-bang)

**Derivation.** The dwell cap still *teleports* between stations at instantaneous `V_LINE`. The
fastest **feasible** train must decelerate to 0 into each stop and re-accelerate out, obeying
`|a|≤a_max`, `|decel|≤d_max`, `v≤V_LINE`. Rest-to-rest the time-optimal (Pontryagin bang-bang)
profile is the three-phase trapezoid accel→cruise→brake (the coasting regime of energy-optimal
control drops out of the *time*-optimal problem — keep pure MA-CR-MB). Per gap of length `D`:
`D_crit = (V_LINE²/2)(1/a_max + 1/d_max)`; if `D ≥ D_crit`,
`T_gap = D/V_LINE + (V_LINE/2)(1/a_max + 1/d_max)`; else triangular
`T_gap = √(2D(1/a_max + 1/d_max))`. The per-station overhead the instant-`V_LINE` model misses is
`τ_ramp = (V_LINE/2)(1/a_max + 1/d_max)`, **independent of gap length** in the trapezoid regime.
The phase-plane envelope per gap is
`v(s) ≤ v_env(s) = min{√(2a_max(s−p_prev)), V_LINE, √(2d_max(p_next−s))}` — the middle-term is the
line cap, the third is the **terminal-braking parabola** into the next mandatory stop.

**Upper-bound proof.** Any admissible trajectory satisfies (a) `v² ≤ v0² + 2a_max(s−s0)` (accel
from anchor), (b) `v ≤ V_LINE`, (c) `v² ≤ 2d_max(p_next−s)` (must reach 0 by the next stop within
brake authority). Hence `v(s) ≤ v_env(s)` pointwise; first-passage `T(s)=∫ds'/v ≥ ∫ds'/v_env`, so
the true train reaches every `s` no earlier ⇒ `s_true(t) ≤ s_kin(t)`. Adding constraints only
shrinks the reachable set, so `s_kin ≤ freeRun` always — strictly tighter, still an upper bound. ∎

**Quantified reduction.** `a_max=1.3, d_max=1.5, V_LINE=28`: `τ_ramp = 14·(1/1.3+1/1.5) ≈ 20.1 s`,
`D_crit ≈ 563 m` (= per-station position tightening). Effective ceiling on 1.5 km spacing drops
from 28 to `D/T_gap ≈ 1500/75.1 ≈ 16.0–18 m/s` (a 36–43 % slope cut) with **zero** dwell
assumption. On the 6-station worst case: ~2.1 min beyond the dwell cap. Corroboration: Namma
Purple Line realizes ~29 km/h against an 80 km/h ceiling and needs ">400 m to accelerate from, or
decelerate to, a halt" on ~1 km spacing — >80 % of every gap is ramp.

**Verifier rigor-check → `valid_upper_bound = false` (conditional).** Three unsafe directions:
- *`d_max`/`a_max` too low* (the FOUNDATION §7 rigor-check inversion): the terminal parabola
  `√(2d_max(s_B−s))` needs the **largest** plausible decel. Emergency service brake ~1.5 m/s² is
  *below* the wheel-rail adhesion ceiling ~0.25 g ≈ 2.45 m/s²; a train braking at 2.4 sits above
  the `d_max=1.5` envelope near each stop → LATE. Symmetric for `a_max` on departure.
- *Express/skip-stop*: forcing `v=0` + a terminal parabola at a station the express blows through
  at `V_LINE` under-states progress by up to one gap per skipped stop → several-minute LATE.
- *Phantom departure ramp*: `0.5·a_max·τ²` from rest when the true train is already at `V_LINE`
  under-states early progress → LATE. Only start the ramp from a **certified** at-rest anchor.

**Fixes:** `d_max` = adhesion-limited upper bound (~2.5 m/s²), `a_max` = largest launch accel of
*any* stock on the line; terminal parabola + `v=0` only at **confirmed** scheduled stops (drop for
any station some service may skip); default anchor `v0 = V_LINE`, use `v0=0` only when rest is
certified; keep `sMax = min(freeRun, s_kin)`. Never crowd-*shrink* `a_max`/`d_max` toward observed
maxima (a newer/faster train exceeds the sample → LATE).

### 2.3 Curve geometry speed profile `V(s)`

**Derivation.** The route is a known curvy alignment; physics caps curve speed at
`v_curve(s) = √(a_lat_eff·R(s))` from the local radius `R(s)=1/κ(s)`, giving a *position-dependent*
ceiling `V(s) = min(V_LINE, v_curve(s), v_grade(s))` fed through the same forward-backward velocity
sweep as §2.2. Curvature from a **spline-smoothed** arc-length parameterization (Menger /
moving-chord circumradius, chord ℓ≈160 m), **not** raw finite differences on the 429/495-pt
polyline (which amplify vertex noise into phantom curves). Rail curve-speed law:
`V_kmh = √(11.82·R·(D+E))` with cant `D` + cant-deficiency `E`.

**Upper-bound proof.** Need `v_curve(s) ≥ v_true(s)`, i.e. over-bound both factors. Noise σ on each
vertex perturbs the sagitta, adding `δκ ≈ 9.76σ/ℓ²`; a spurious `+δκ` on truly-straight track fakes
a curve and lowers `v_curve` below truth (the one forbidden direction). Guard:
`κ_safe(s) = max(0, κ_est(s) − 9.76σ/ℓ²)` ⇒ `R_used = 1/κ_safe ≥ R_true`. With
`a_lat_eff ≥ a_lat_true` **and** `1/κ_safe ≥ R_true`, `√(a_lat_eff/κ_safe) ≥ √(a_lat_true·R_true)
≥ v_true`. Enters as one more `min()` term, so an over-smoothed / missed curve only relaxes `V(s)`
toward `V_LINE` — safe. ∎

**Quantified reduction.** Real Green line (OSM rel 1798772, 35.2 km), `a_lat_eff=2.5`, σ=5 m
(8.5 % of route capped): removes 196 m @2-min blind rising to 483 m @10-min (~0.15–0.37 station,
~7–17 s). Guaranteed single-curve cut at the sharpest noise-floored R=58 m: `V(s)=12 m/s` (43 km/h)
— a hard 16 m/s cut below the flat ceiling regardless of window length. Typical contribution on a
curvy underground stretch ≈ 1 min; it **stacks orthogonally** on the terminal-braking envelope and
dwell cap (its bite is concentrated at sharp curves + station approaches).

**Verifier rigor-check → `valid_upper_bound = false` (conditional).**
- *`a_lat_eff` under-estimate*: a legal high-cant-deficiency / tilting service can pull ~3.0 m/s²
  track-plane lateral; `a_lat_eff=2.5` caps a true-R=200 m curve at 22.4 m/s while the train runs
  24.5 → LATE. Every value in (2.5, ~4] m/s² is an unproven tightening. **Fix:** set `a_lat_eff` to
  the *overturning/rollover* limit `g·(b/h_cg) ≈ 3.5–4.1 m/s²` for the most-stable (fastest-capable)
  stock — a train exceeding it derails and makes no further progress, so it is the true never-late
  ceiling. Higher `a_lat_eff` only loosens; lower is the sole late direction.
- *1-σ noise floor too shallow*: `9.76σ/ℓ²` subtracts only ~1.22σ; a genuinely straight segment at
  +2–3σ survives → phantom curve → LATE. **Fix:** subtract ≥3× the RMS floor (or an absolute
  digitization bound); ensure σ *upper*-bounds true OSM error (5 m is optimistic for rail relations).
- *Clamp-direction bug*: the RESULT's guardrail `s_curve(t) ≤ freeRun` bounds the term from *above*
  (tighter). The late direction is `s_curve` too *small*, which no upper clamp catches — so the
  whole never-late guarantee rests on `κ_safe` and `a_lat_eff` being conservative. They must carry
  the full burden; there is no geometry-derivable lower guard.
- Do **not** fold mandatory dwells into this pure curve+accel/brake profile (an express skipping an
  assumed dwell arrives earlier → LATE); keep dwell as a separate, confirmed-stop-gated term.

With `a_lat_eff` at the overturning limit and a multi-σ floor the tightener is provably valid but
materially smaller: Green-line capped fraction 23 % → 15 %, sharpest-curve cut 13.7 → 17.4 m/s
(roughly half the advertised benefit). Still real; still worth shipping geometry-gated.

### 2.4 Crowd / GTFS min segment time (the data moat)

**Derivation.** Replace "coast at `V_LINE`" with a station-by-station envelope that cannot advance
past station `k+1` before the earliest *provable* `k→k+1` travel time. Three layered lower bounds,
combined by `max` (largest provable = tightest, still ≤ true iff each ≤ true):
`minTravel_safe[k] = max(T_phys[k], sched[k]·(1−f), q̃_p[k] − Δ[k])` —
(1) **physics floor** `T_phys` (the §2.2 trapezoid; deterministic);
(2) **GTFS bootstrap** `sched·(1−f)` (published schedules are padded ⇒ ≥ median true; discount by
`f≈0.2–0.3` for a strict lower bound; day-1, no crowd data);
(3) **crowd term** `q̃_p − Δ` — a DP low-quantile (p≈0.02–0.05) of observed segment times minus a
margin. Then `τ_min[k] = t0 + Σ minTravel_safe`, and
`S_up(t) = min_k [ s_travel[k] + V_LINE·(t − τ_min[k])⁺ ]` — one V_LINE-slope cone launched from
each station at its earliest feasible departure.

**Upper-bound proof.** For every `k`: if `t < τ_min[k] ≤ A_k` (true arrival) the train hasn't
reached `k` ⇒ `s_true(t) ≤ s_travel[k]` = the flat term; if `t ≥ τ_min[k]` and `k` is passed,
`s_true(t) = s_travel[k] + ∫v ≤ s_travel[k] + V_LINE·(t−A_k) ≤` the sloped term (since
`A_k ≥ τ_min[k]`). Each per-station term ≥ `s_true`, so `S_up = min_k term_k ≥ s_true`. ∎ Validity
reduces to each floor being a true lower bound; raw crowd-min carries per-segment late-prob
`1/(n+1)` (union-bounds too high), so the `−Δ` margin and the DP low-quantile (not the raw min) are
mandatory. The minimum is the worst query for differential privacy (unbounded sensitivity, leaks a
quasi-trajectory) — release a DP low-quantile via the exponential mechanism, k-anon-gated (k≥50–100).

**Quantified reduction.** Measured on `bengaluru__green__long_blind` (24 stations, 29.5 km): the
observed/free-run segment-time ratio averages **2.39×** — free-run over-counts progress ~2.4× per
dark segment. Full-blind cold start: free-run fires 24.4 min early; **physics floor alone → 3.4 min
early** (recovers ~86 % of the gap, zero risk); crowd-min +5 % margin → 2.1 min. On the measured
mid-route 341 s window the station over-count drops from ~2–3 stations to 0 and distance from
~5.6 km to ~0.1 km. Marginal over the available-now stack on the 6-station case: ~0.9 min (removes
the residual V_LINE over-bound 28 → ~22.2 m/s).

**Verifier rigor-check → `valid_upper_bound = false` (STATISTICAL).**
- *Express / skip-stop breaks the "deterministic" physics floor* (the damaging one): `T_phys[k]`
  bakes in a brake-to-0-and-reaccelerate dip (~26.7 s) **plus** an assumed dwell — both are lower
  bounds *only for a train that actually stops at `k`*. A non-stopping express traverses the segment
  faster than `T_phys`, so `τ_min > A_k` → `S_up < s_true` → LATE (~3 min / ~5 km for a 4-station
  skip). The claim "Layer 1 is deterministic never-late" is **false** for non-stopping trains — it
  breaks the very floor the probabilistic layers rely on to bound their downside.
- *Train faster than the crowd sample*: fastest-*observed* ≠ fastest-*possible*; new stock, empty
  runs, or signal-priority beat `q̃_p − Δ` → LATE (unbounded on a just-upgraded line).

**Fixes:** correct the floor to a **non-stopping pass-through** `T_phys_safe = D/V_LINE` (no assumed
dip, no assumed dwell); add stop-time **only** from confirmed dwell anchors; relabel layers 2–3 as
**probabilistic**, never a hard trigger — fire on `t_obs⁻¹(t+δ)` with margin δ **and** keep the
physics free-run floor via `min()`, or surface crowd only in the displayed lead / lower band and
keep the fire trigger on physics. With the pass-through floor the envelope
`S_up = min_k[s_travel[k] + V_LINE·(t−τ_min[k])⁺]` is again a proven upper bound and still recovers
most of the 24 → ~3 min reduction, because the dominant error was free-run's
continuous-`V_LINE`-no-stops assumption, not the trapezoid dip.

---

## 3. THE STACKED BOUND

### 3.1 Central lemma (the whole design rule)

If `B_1…B_n` each satisfy `B_i(t) ≥ s_true(t) ∀t`, then `U(t) = min_i B_i(t) ≥ s_true(t) ∀t`.
*Proof:* fix `t`; `s_true(t)` is a lower bound of the finite set `{B_i(t)}` ⇒ `s_true(t) ≤ min_i
B_i(t)`. ∎
- **Corollary A (stacking is monotone-safe):** adding a valid tightener replaces `U` by
  `min(U, B_{n+1}) ≤ U` — can only push the fire *later*, never below `s_true`.
- **Corollary B (graceful degradation):** dropping/missing a term raises `U` — looser/earlier,
  still ≥ `s_true`. False-negatives are always safe.
- **Corollary C (the only hazard):** `U` falls below `s_true` **only** if some `B_i` is itself
  invalid. This is the entire failure surface — every verifier finding in §2 is a Corollary-C
  break, and every fix restores `B_i ≥ s_true` at its worst-case input.

**Unifying rule** (restating every verifier's `required_fix`): *every stacked term must over-bound
the reach-maximizing input — model the physically **fastest admissible** train, quantified over all
service patterns and all rolling stock: the train that skips the most stops it is allowed to skip,
brakes at the highest achievable decel, departs with the highest achievable accel, and corners at
the overturning limit.*

### 3.2 The combined bound

The six candidate facets collapse into **two objects**:

**Object (1) — the fastest-feasible-train minimum-time velocity profile (HARD).** One
forward-backward sweep simultaneously *is* the reachable-set/time-optimal bound, the curve
geometry, the accel-limit, the terminal-braking envelope, and the dwell cap:

```
V_ceil(s) = min( V_LINE, √(a_lat_eff · R(s)) [, v_grade(s)] )      # §2.3 ceiling (grade safe to omit)
v_f(s+ds) = min( V_ceil(s+ds), √(v_f(s)² + 2·a_max·ds) )           # forward accel pass  §2.2
v_b(s−ds) = min( V_ceil(s−ds), √(v_b(s)² + 2·d_max·ds) )           # backward brake pass, v=0 at each confirmed stop
v*(s)     = min( V_ceil(s), v_f(s), v_b(s) )                        # reachable max-speed profile
t*(s)     = ∫ ds'/v*(s') + Σ_{stops≤s} W_min                        # + confirmed dwell (§2.1)
s_fast(t) = t*⁻¹(t)
```

**Object (2) — crowd/GTFS min-time (STATISTICAL, §2.4):** `s_crowd_safe(t) = t_obs⁻¹(t + δ)`,
stacked by `min` but kept off the hard trigger.

**Combined:**

```
s_max(t) = min( freeRun(t),  s_fast(t) [object 1, HARD],  s_crowd_safe(t) [object 2, gated] )
```

with `freeRun = s0 + V_LINE·(t−t0)` the unconditional floor everything degrades to. By §3.1 this is
a valid upper bound whenever each argument is (each proven in §2 at its worst-case input).

### 3.3 Estimated combined reduction of the 14-min / 9-km / 6-station worst case

Time for the bound to cross the 9 km / 6-stop gap (V_LINE=28, true avg ~10.7, `a_max=d_max=1.3`,
`W_min=15 s`):

| Bound | crossing time | early-fire | Δ | class |
|-------|:-------------:|:----------:|:--:|-------|
| `s0 + V_LINE·t` (shipped free-run) | 321 s | **14.0 min** | — | baseline |
| + dwell cap (§2.1) | 396 s | 12.7 min | −1.3 | HARD |
| + accel/brake ramps (§2.2) | 526 s | 10.6 min | −3.4 cum | HARD |
| + curve geometry (§2.3, typical) | ~586 s | **~9.6 min** | **−4.4 cum** | **HARD, available-now** |
| + crowd/GTFS min-time (§2.4) | 639 s | **~8.7 min** | −5.3 cum | +0.9 STATISTICAL |

**Clean scaling law (the memorable result):** the available-now HARD stack removes
```
Δt ≈ N_stops·[ W_min + (V_LINE/2)(1/a_max + 1/d_max) ] + ∫(1/V_ceil − 1/V_LINE) ds
   ≈ 0.6 min per mandatory station in the blind window  +  the curve integral
```
so the reduction **grows with blind-window length** — exactly the long_blind regime (6 stops ≈
4.4 min; a 10-stop tunnel ≈ 6 min + curves). Crowd/GTFS then removes the residual V_LINE over-bound
`(1/22.2 − 1/28)·9000 ≈ 84 s ≈ 1.4 min` gross, ~0.9 net of what curves already took.

**Honest floor.** The remaining **~8.7 min is largely irreducible** — it is this run's genuine gap
below the fastest-feasible-observed run (639 s vs this run's ~1161 s to target), i.e. run-to-run
variance, not bound looseness. No never-late bound may fire inside it; closing it requires
*sensing* (confirmed-stop IMU/baro re-anchors), a separate mandate. All figures are model estimates
**pending replay** on the Nallur/Majestic real fixtures + the 391-ride scale set (assert
`s_max(t) ≥ s_true(t)` pointwise, 0 violations, and report shrunk slack).

### 3.4 Concrete recommended computation for `reachability.dart`

Upgrade `_topologyCappedProgress` (l.321–356) from "travel each gap at `V_LINE` + dwell" to the
forward velocity-profile sweep. Still pure, deterministic, O(#vertices); precompute `v*(s)` and the
arc-time table `t*(s)` **once per route** so per-tick evaluation is an O(1) table lookup/inversion.

1. **Config** (`ReachabilityConfig`): add `aMaxMps2`, `dMaxMps2` as *largest-plausible* upper bounds
   (`d_max≈2.5` adhesion-limited, `a_max≈1.3`), `aLatEff` (overturning limit ~4 m/s²), keep
   `dwellMinSeconds` (default 0.0 = safe free-run). Per-line overridable.
2. **`RouteTopology`**: add precomputed `vCeil[]` = per-arc `min(V_LINE, √(aLatEff·R(s)))` from a
   spline-smoothed curvature of the **real OSM polyline** (`rail_geometry.json`/`.wkp`, not the
   densified `base.json`), with `κ_safe = max(0, κ_est − k·9.76σ/ℓ²)`, `k≥3`. Where R is untrusted,
   `vCeil = V_LINE`.
3. **State** `(position, v, timeLeft)`, `v` seeded = `V_LINE` (worst-case anchor speed) or 0 **only**
   when the anchor is a certified at-rest fix.
4. **March** arc segments forward: `v ← min(vCeil[seg], √(v² + 2·a_max·ds))`; within braking distance
   `v²/(2·d_max)` of the next **confirmed** stop ride the parabola `v ← √(2·d_max·(s_k − s))`; at
   `s_k` set `v=0`, subtract `W_min` from `timeLeft`; advance position/time by `ds/v` until
   `timeLeft` exhausts. Return position = `s_fast(Δt)`.
5. **Compose** in `Reachability.bound()`: `sMax = min(freeRun, s_fast)`; optionally
   `min(…, s_crowd_safe)` behind a flag with margin δ, physics kept as floor.
6. **Certify** the mandatory-stop set per trip from GTFS `stop_times` (or a per-system
   `all_stops_service` flag) — **never** from the raw Directions station list — and drop any station
   an express may skip. Keep every existing fail-safe: non-finite anchor/clock → `+∞`, `hardTMax`
   watchdog, and the invariant that the cap can only *reduce* `freeRun`.
7. **Gate C:** no new argument enters the `min()` until unit-proven `≥ s_true` at its pessimistic
   input, exactly as the current dwell cap already is (default 0, opt-in per line).

---

## 4. Phased plan

**Phase 0 — ship first (available-now, HARD, provable): geometry speed-profile + dwell cap +
terminal-braking.** Zero new data collection; all owned inputs + physics constants; each proven
`≥ s_true` in §2 with its guard.
- **P0a — dwell cap (§2.1):** highest ROI, already coded — set `dwellMinSeconds>0` for certified
  all-stops lines (`w≈8–15 s`, a genuine under-estimate). Gate the stop set to GTFS `stop_times` or
  `all_stops_service:true`. Removes ~35–40 % of the worst-case over-count.
- **P0b — accel/brake ramps + terminal braking (§2.2):** rewrite the `_topologyCappedProgress` inner
  loop as the bang-bang forward sim; `a_max`/`d_max` = largest plausible (`d_max≈2.5`); confirmed
  stops only; anchor `v0=V_LINE` unless rest certified. Effective ceiling 28 → ~16–18 m/s.
- **P0c — curve geometry `V(s)` (§2.3):** geometry-gated. `a_lat_eff` at the overturning limit
  (~4 m/s²), multi-σ noise floor, spline-smoothed R, `vCeil=V_LINE` where R untrusted. Validate
  `v_curve(s) ≥ realized GPS speed` on the open segments of the 391 rides **before** enabling.
- **Phase-0 acceptance:** replay Nallur/Majestic + 391 scale rides against **real** geometry
  (`rail_geometry.json`/`.wkp`, not the densified fixtures); assert `s_max(t) ≥ s_true(t)` pointwise
  (0 violations) and report the early-fire distribution vs free-run. Add a **negative** test: a
  synthetic express trip with skipped stations present in the topology must **fail** the pointwise
  assertion — proving the confirmed-stop guard is load-bearing.

**Phase 1 — needs data (STATISTICAL, gated): crowd / GTFS min-time (§2.4).**
- **P1a — GTFS bootstrap:** `sched[k]·(1−f)` from published `stop_times` (Namma Metro/BMRCL GTFS is
  available). Day-1 tightening of the residual V_LINE over-bound, no crowd panel.
- **P1b — crowd moat (v2):** per-(segment, hour_bin, day_type) observed times aggregated on-device
  into a DP low-quantile (exponential mechanism), k-anon ≥50–100, sparse cells auto-fall-back to
  GTFS then physics. **Always** `max()` with the pass-through physics floor `T_phys_safe = D/V_LINE`;
  never a hard fire trigger — fire on `t_obs⁻¹(t+δ)` with the physics floor via `min()`, or demote
  crowd to the displayed lead / lower band. Quantify per-line `α/K` before enabling.

**Deferred (out of scope here) — sensing to close the residual ~8.7 min:** confirmed-stop IMU/baro
re-anchors and on-train discriminators. These are the only levers that can tighten toward *this
train's* realized speed without violating never-late; they plug into the same `min()`.

---

## 5. Sources (every `source_url`, grouped by tightener)

**Reachable set / time-optimal umbrella**
- Pontryagin driving regimes (MA-CR-CO-MB; coast drops for max-reach): https://www.sciencedirect.com/science/article/abs/pii/S0377221716307962
- Forward reachable sets, bang-bang boundary (HJ/CBF containment): https://arxiv.org/pdf/2310.17180
- 2025 HJ-reachability with soft speed/comfort constraints: https://arxiv.org/html/2510.24933
- Closed-form time-optimal constrained double integrator: https://arxiv.org/pdf/2604.13007
- Bang-bang principle, time-optimal target on reachable-set boundary: https://liberzon.csl.illinois.edu/teaching/cvoc/node86.html
- Time-optimality via arrival times to reachable sets: https://lavalle.pl/planning/node794.html
- Max curve speed = cant + cant-deficiency lateral cap: https://en.wikipedia.org/wiki/Cant_deficiency
- 2024 optimal train speed-profile across variable limits/gradients: https://ietresearch.onlinelibrary.wiley.com/doi/full/10.1049/itr2.12482
- Robust tube / funnel control (containment tube): https://arxiv.org/pdf/2310.03449
- Minimum-time function via reachable sets (first-passage): https://arxiv.org/pdf/1512.08617

**Curve geometry speed profile**
- Safe speed on curves (cant + deficiency, `v=√(R(a_cant+a_def))`): https://www.brainkart.com/article/Railway-Engineering--Safe-Speed-on-Curves_4226/
- Urban rail lateral-accel comfort ~1.0 m/s² (110 mm deficiency): https://www.thepwi.org/wp-content/uploads/2021/02/Presentation_200304_Passenger-comfort-design-analysis.pdf
- Moving-chord curvature from noisy coordinates (denoised): https://ascelibrary.org/doi/10.1061/%28ASCE%29SU.1943-5428.0000402
- Identifying railway curvature via moving chord (Sensors 2023): https://www.mdpi.com/1424-8220/23/1/274
- Track curvature from GPS trajectory (Sci Reports 2025): https://www.nature.com/articles/s41598-025-91255-x
- Forward-backward velocity profile / minimum-time-over-path (FBGA): https://arxiv.org/html/2505.05157

**Topology / dwell**
- Empirical metro dwell (~20–30 s minimum): https://pedestrianobservations.com/2024/08/24/more-on-american-incuriosity-new-york-regional-rail-edition-part-2-station-dwell-times/
- Door open/close cycle (~8–9 s floor): https://www.railengineer.co.uk/station-stops-something-to-dwell-on/
- Dwell lognormal (use a low quantile, not the mean): https://www.tandfonline.com/doi/abs/10.1080/23249935.2020.1798555
- GTFS route/route-stop patterns (express detection): https://www.transit.land/documentation/datastore/routes-and-route-stop-patterns.html
- Stable identification of transit schedules / canonical patterns: https://arxiv.org/pdf/2606.14713
- Skip-stop service (the all-stops premise failure case): https://arxiv.org/pdf/2011.12674
- Rail timetabling: dwell + running-time lower bounds: https://arxiv.org/pdf/1612.03336
- Namma Metro / BMRCL GTFS availability: https://github.com/Vonter/bmtc-gtfs
- Forward reachable set = min-of-valid-upper-bounds (CBVF): https://hybrid-robotics.berkeley.edu/publications/CBVF.pdf

**Crowd / GTFS min-time**
- Minimum segment travel time reliability baseline: https://www.mdpi.com/2076-3417/14/24/11599
- Lognormal travel time with hard free-flow floor: https://arxiv.org/pdf/2503.04062
- Limited-data (few-sample) bus travel-time reliability: https://arxiv.org/pdf/2303.17888
- GTFS static `stop_times` reference (padded schedules): https://gtfs.org/documentation/schedule/reference/
- Min/max is maximally DP-sensitive; exponential-mechanism quantile: https://arxiv.org/pdf/2102.08244
- Unbounded DP quantile & min/max estimation: https://arxiv.org/pdf/2305.01177
- User-level DP mobility reports (aggregation pattern): https://arxiv.org/pdf/2209.08921
- Free-flow travel time + buffer (FHWA reliability): https://ops.fhwa.dot.gov/publications/tt_reliability/TTR_Report.htm
- Metro on-time performance ~74 %, probabilistic run times: https://onlinelibrary.wiley.com/doi/full/10.1155/2024/8249757
- Crowd/GTFS observed run+dwell times dataset: https://www.mdpi.com/2306-5729/10/8/119
- Skip-stop is real/established (verifier): https://en.wikipedia.org/wiki/Skip-stop · https://www.sciencedirect.com/science/article/pii/S1077291X23000255 · https://www.sciencedirect.com/science/article/pii/S1877042813009816 · https://www.mta.info/article/new-metro-north-schedules-start-october-6-2024

**Kinematic ramps / bang-bang**
- Bang-bang trapezoid dominates jerk-limited profiles (max-reach cone): https://journals.sagepub.com/doi/10.1177/03611981221096443
- Optimal metro speed profile (drop coast for max-reach): https://ietresearch.onlinelibrary.wiley.com/doi/full/10.1049/itr2.12482
- Urban metro accel/decel ~1.0–1.5 m/s², jerk ~1 m/s³: https://link.springer.com/article/10.1007/s40864-015-0012-y
- Passenger-train braking (service 0.8–1.3, emergency ~1.5): https://railwaynews.net/wiki/train-braking-distance-how-long-does-a-train-take-to-stop
- Namma Purple Line: 80 km/h ceiling, ~29 km/h realized, >400 m ramps: https://www.fabhotels.com/blog/indian-metro-rail-networks/bangalore-metro/purple-line/
- Over-approx reachable set as intersection (min) of certificates: https://arxiv.org/abs/2404.18813
- 2024 metro accel-coast-decel cycle (short headways): https://ietresearch.onlinelibrary.wiley.com/doi/full/10.1049/itr2.12582
- Wheel-rail adhesion braking ceiling ~0.25 g (verifier): https://thecontactpatch.com/rail/r0816-railway-braking · https://en.wikipedia.org/wiki/Emergency_brake_(train)

**Stacked bound (synthesis)**
- FBGA SOTA real-time time-optimal velocity profile: https://arxiv.org/abs/2509.26428
- Time-optimal path-following (velocity-limit-curve integration): https://www.roboticsproceedings.org/rss08/p27.pdf
- Numerical-integration TOPP (max-velocity-curve passes): https://arxiv.org/pdf/1610.02881
- Cant-deficiency law `V_kmh=√(11.82·R·(D+E))`: https://railwaytrackblog.com/2015/10/29/11-82_cant-deficiency-un-compensated-acceleration-pway/
- 49 CFR 213.57 curve speed / cant deficiency: https://www.law.cornell.edu/cfr/text/49/213.57
- Geometry of comfort / transition curves (lateral cap): https://railwaynews.net/wiki/the-geometry-of-comfort-transition-curves-explained

**Creative / SOTA survey**
- Optimal train control 4 regimes (Howlett/Pudney/Albrecht): https://www.sciencedirect.com/science/article/abs/pii/S0377221716307962
- Löffler & Bengtsson — GNSS-outage train localization, curvature-constrained particle filter: https://arxiv.org/abs/2406.02339

---

*Every tightener enters the fire decision only through `min()`; a missing or over-smoothed term can
only fire the alarm earlier, never later. The full never-late guarantee reduces to one discipline:
no term joins the `min()` until it is unit-proven `≥ s_true` at the pessimistic edge of its own
inputs — the fastest admissible train.*
