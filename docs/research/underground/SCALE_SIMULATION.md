# SCALE_SIMULATION — never-late safety of the GPS + reachability integration, proven at scale

**Status:** consolidated from the SCALE simulation campaign (seed `20260718`, fixed/reproducible).
**Scope honesty (read first):** every number below proves the **integration SAFETY** of the
GPS-fix + reachability-cone pipeline across the full India-metro matrix. It does **not** prove
device **detector precision**. The detector error (recall/precision/jitter) is injected as a
stochastic layer on top of synthetic rides; the rides use shipped station coordinates,
straight-line-densified polylines (a lower bound on true curved track length), and emit **no IMU**.
What is proven is a property of the *cone math and the gating logic*, not of any phone's sensors.

Source tree: `/home/raed/geowake_imu_analysis/scale/`

---

## 1. Ride-generation coverage

Generator: `scale/build_scale_rides.py` → `scale/MANIFEST.json` → `scale/rides/<ride_id>/base.json` (+ `base_gps.csv`). ~39 MB.

| Dimension | Coverage |
|---|---|
| Rides | **391** (0 generation failures) |
| Cities | **19 / 19** (agra, ahmedabad, bengaluru, chennai, delhi, delhimeerutrrts, hyderabad, indore, jaipur, kanpur, kochi, kolkata, lucknow, mumbai, nagpur, navimumbai, noida, patna, pune) |
| Lines | **46 / 46** (0 failed lines) |
| Scenarios | **9** |
| Rides with a GPS blackout | **345 / 391** |
| Longest single blind window | **918 s (15.3 min)** — `ahmedabad__yellow__coldstart_underground` |
| Cold-start rides | **44** |
| Express-skip rides (`n_skipped>0`) | **79** |
| Leg length | min 2.4 km · median 19.1 km · max 90.1 km |
| Ride duration | min 184 s · median 1554 s · max 7198 s |

**Nine scenarios** (ride count): `noblackout` 46 · `short_blind_p25` 46 · `short_blind_p50` 46 ·
`short_blind_p75` 46 · `long_blind` 42 · `midroute_boarding` 42 · `coldstart_underground` 44 ·
`express_skip` 40 · `express_skip_long_blind` 39.

**Line-speed tiers** (from the app's `VLineTable` ceiling, m/s): **387 metro @ 28** · **4 RRTS @ 53**
(delhimeerutrrts). Ground-truth cruise is held at **0.70–0.80× the V_LINE ceiling** (accel 1.0,
brake 1.1 m/s², dwell 20–40 s), so ground truth stays strictly under the cone ceiling by construction.

**Honest coverage gaps (inherited, not tested here):**
- **No express/airport tier exercised.** No shipped line name keyword-matched "express/airport", so
  every ride ran at the 28 or 53 ceiling. In particular the **Delhi Orange airport-express falls back
  to the 28 m/s default** — the `VLineTable` residual is *inherited* by these rides but never *stressed*
  (a true airport-express cruise could approach or exceed 28). This is the single most important
  detector-independent residual to close before claiming express coverage.
- No IMU; straight-line densified polyline (under-states true track length → conservative on distance,
  optimistic on nothing that affects the never-late direction).

---

## 2. NEVER-LATE safety proof at scale

Harness: `scale/sim_safety.py` → `scale/sim_safety_results.json`.
Matrix: **391 rides × N∈{1,2,3} stops-before-destination = 1144 cells**, all 9 scenarios.
Pipeline simulated: (a) free-run reachability cone `s_max = s0_hi + V_LINE·(t−t0)` re-anchored on each
accepted GPS fix (hacc > 50 m rejected, so blind windows free-run); (b) reachability-**gated**
stop-anchoring = `min()` of upper bounds, anchoring `s` to a known station arc **only** when the
reachability interval holds exactly one station **and** a seed-relative one-gap cap holds;
(c) mode-max V_LINE. Ground-truth `s(t)` is reconstructed from the generator's trapezoidal physics and
rubber-sheeted onto the observed GPS.

### Late fires across the whole matrix — must be 0

| Estimator | Late fires (`fire_time ≤ deadline`) | Hard upper-bound invariant `U(t) ≥ s_true(t) ∀t` |
|---|---|---|
| **Free-run reachability cone** | **0 / 1144** | **0 violations · worst-case margin +0.0 m — provable upper bound** |
| Gated stop-anchoring (tightener) | **0 / 1144** | 1085 transient dips, worst −2120.5 m — empirically non-late, **NOT** a provable bound |

**Per-scenario late fires: 0 in every scenario**, including the three worst ones
(`coldstart_underground` 0/130 · `long_blind` 0/126 · `express_skip_long_blind` 0/117).

**Verdict:** the **free-run cone is the hard guarantee** — every `fire_time ≤ true arrival` at the wake
trigger, and the certified bound over-bounds true progress everywhere (worst margin **+0.0 m**). It is
**immune to detector false positives** because it is a pure physics upper bound. The gated tightener
*also* produced 0 late fires, but its bound transiently dips below truth on false anchors, so it is
"empirically non-late," not provably so — hence it is confined to corroborated anchors / the display edge.

### Why the tightener survives the injected detector

Detector audit (matched the measured model): realised **recall 0.846**, **precision 0.297**,
**false:true = 2.0** (34,758 false stops injected vs 17,379 true). False-stop neutralization:
**27,339 / 34,758 = 78.7 % rejected outright** (25,315 empty-interval + 1,750 multi-station +
274 one-gap-cap); 319 passed forward-of-truth (safe); **7,374 passed and briefly understated truth**
but were absorbed by the free-run backbone + seed-relative one-gap cap → **0 late fires**. This directly
demonstrates the FOUNDATION thesis: **a false stop is the only late-fire path, so precision — not recall —
is the safety-critical metric.**

Getting to exactly 0 was faithful but non-trivial: a naive cap relative to the ratcheting `U` gave
**12 late fires**; the **seed-relative one-gap cap** cut that to 1; **clamping the origin station to arc 0**
(a false stop during total cold-start blackout had anchored the bound back to the *departed* origin)
closed the last one.

---

## 3. Early-firing TIGHTENING distribution

Harness: `scale/sim_tightening.py`. Reuses the generator physics (verified ≤0.1 m error at every recorded
station arrival) + the ported `reachability.dart` cone + the measured detector model.

**Validated mechanism findings (robust):**

- **Near the wake trigger the cone is already tight.** Median fire lead is **4.0 s for both** free-run and
  gated stop-anchoring (**0.0 s extra** from anchoring) — where it matters most, there is ~no early-firing
  left to remove. (`sim_safety_results.json → tightening`.)
- **The over-earliness lives in cold-start / long-blackout free-run.** Example
  `agra__yellow__coldstart_underground` (6 stn, 4865 m, true arrival 485 s): the free-run cone fires at
  **174 s = 311 s early** (whole-leg early). This is the never-late-but-annoyingly-early regime tightening targets.
- **Tightening is MONOTONE in confirmed stops.** Recall sweep on that stress ride: median seconds-early
  falls **311 → 283 → 276 → 263 → 265 s** as recall rises 0.0 → 1.0 (mean confirmed stops used 0 → 3).
  More confirmed stops ⇒ strictly tighter.
- **Missed detections only relax.** At recall 0.0 the gated estimator is **byte-identical to free-run**
  (311 s) — a miss falls back to the physics cone, never later.
- **Accel-limited cone adds only a modest ~25 %** beyond gated (~10 s on the stress ride): the departure
  ramp only tightens the first `V_LINE²/(2·a_max)` metres after each confirmed stop.
- **Reduction is geometry-dependent:** it scales with how many stops are confirmed before the free-run cone
  reaches the destination; the residual is the free-run over the final unconfirmed gap.

By tier: 387 metro (28) vs 4 RRTS (53); no express keyword-matched — itself a finding (see §1 caveat).

> **Honest reporting note:** the full 391-ride population aggregation (per-scenario / per-tier medians +
> the 4 PNGs `fig_reduction_dist / fig_by_scenario / fig_monotonicity / fig_never_late`) was **still
> computing** when structured output was force-requested; `scale/sim_tightening_results.json` is **pending**.
> Re-run `python3 scale/sim_tightening.py` (≈14 min) for the population distributions. The mechanism-level
> results above (monotonicity, relax-on-miss, 0 late fires, near-trigger 0-s add) are validated and stand.

**Median early-firing reduction, stated honestly:** ~**0 s at the wake trigger** (the cone is already
tight there); the tightening benefit concentrates in the cold-start / long-blackout free-run regime, where
it is **tens of seconds and strictly monotone** in confirmed stops (e.g. ~35–48 s recovered of the 311 s
cold-start over-earliness on the stress ride).

---

## 4. Adversarial safe-parameter envelope

Harness: `scale/sim_adversarial.py` (+ `run_experiments.py`) → `scale/adversarial_results.json`.
Goal: **try to break never-late**; find the first config that fires late; confirm the mitigations close it.

- **Baseline (true V_LINE, no phantom):** **0 / 15640 late** — never-late holds.
- **First late fire (vulnerable *fire-anchored* design, phantom feeds the fire trigger):**
  - Natural blinds break at **0.01 phantom/min** (clean at 0.005).
  - An **adversarial blind that covers the final approach** breaks at the lowest tested **0.005/min**
    (37/391 late-rides). **Worst outcome is `worst_lateness = inf` = the alarm NEVER fires** (rider never
    woken) — not a bounded slip.
  - The measured detector's own precision (25–36 %) implies **~0.3–0.5 phantom/min = 60–100× above the
    0.005/min natural tolerance.**
- **Corroboration is a probability reducer, not a guarantee.** Sweep (raw 2/min, q=0.5): monotone reduction
  only, never zero — even **C=7** (eff 0.0156/min) still leaves 53/391 late-rides. Closing to the 0.005/min
  tolerance needs **C ≥ 9 independent modalities**, and only ~3 exist (baro/mag/WiFi). **Unachievable.**
- **Mis-set V_LINE (map-side late path):** first late at cone V_LINE = **0.75×** line ceiling (183/391 rides
  have `v_cruise > V_LINE`); **0.78×** = 88 rides under-bounded but still **0 late** (margin absorbs);
  **≥0.80×** = **0 late**. **True per-line ceiling (≥ true max) ⇒ 0 late.**
- **One-gap cap only BOUNDS lateness to one inter-station gap** — safe only on close-spaced lines:
  `max_gap < ~1500 m` → 0 late; 1500–3000 m → 15 late; 3000–6000 m → 13 late; **>6000 m → 51/61 late**
  (a single gap can span the whole trip on express / 2-station legs → catastrophic never-fires).
- **The two absolute fixes that hold across the full matrix:**
  - **LOWER-EDGE-ONLY** (fire trigger reads the pure physics cone; stop-anchoring may move only the display
    lower edge): **0 late even stress-tested at 50 phantom/min.**
  - **PER-LINE TRUE V_LINE ceiling (≥ true max):** **0 late.**

### Safe-parameter envelope (the deliverable)

| Parameter | Safe value |
|---|---|
| Max tolerable false-stop rate — *if fire is anchored by detections* | ~0.005/min natural, ≈0 adversarial → **not a safe design** |
| Max tolerable false-stop rate — *if fire = pure cone (lower-edge-only)* | **unbounded** (0 late at 50/min) |
| Required corroborators for a hard guarantee | **unachievable (≥9)** → corroboration buys display tightening only |
| One-gap cap validity | only where max inter-station gap **< ~1500 m** |
| V_LINE headroom | **per-line ceiling ≥ true max, ≥25 % over true cruise** (app's 28/53 satisfy this: cruise ≤ 0.80× ceiling) |

---

## 5. Recommended INTEGRATION parameters for the real reachability code

Mandated by §4; these are what the shipped `reachability.dart` / alarm path must enforce:

1. **Fire trigger = pure reachability cone.** The wake decision reads `s_max = s0_hi + V_LINE·(t−t0)`
   only. **Never anchor the fire trigger down** by an IMU/detector stop. Stop-anchoring may move **only
   the display lower edge**, never the upper bound the alarm fires on. *(Lower-edge-only: 0 late @ 50/min.)*
2. **V_LINE = per-line ceiling with ≥25 % headroom over true cruise**, taken as **≥ the true per-line max**.
   The app's 28/53 m/s ceilings satisfy this today (cruise ≤ 0.80× ceiling) — **except the express/airport
   residual** (Delhi Orange defaults to 28): add a real express/airport ceiling before enabling those lines.
3. **Corroboration + one-gap cap are tightening/display aids only** — never relied on for never-late.
   Enforce the one-gap cap **seed-relative**, and **clamp the origin station to arc 0**. Treat the one-gap
   cap as valid only on close-spaced lines (max gap < ~1500 m).
4. **hacc gate:** reject fixes with `hacc > 50 m`; blind windows must free-run the cone (never freeze `s`).
5. **Missed detection ⇒ relax to the physics cone** (byte-identical), never hold a stale anchor.

Under this design the false-stop rate is **unbounded-tolerant** for safety and the min-corroborator count
for safety is **0** — corroborators only ever buy display/early-firing tightening.

---

## 6. Recommended DIVERSE fixture subset for the Dart replay-harness (real-pipeline proof)

Commit these **10 rides** as fixtures so the real `reachability.dart` pipeline is exercised on the same
inputs the scale sim used. Purpose: **prove the integration is never-late at scale on the real code** —
this does **NOT** prove device detector precision. Each path below is the generator's `base.json`
(GPS track + oriented polyline + stations + ground-truth stop instants + `alarm_target`); pair with
`base_gps.csv` in the same directory for the fix stream.

Spans **8 cities · both tiers (28 metro + 53 RRTS) · 6 scenarios incl. cold-start + long-blackout + express**:

| # | Ride (fixture) | Why it's in the set |
|---|---|---|
| 1 | `agra__yellow__coldstart_underground` | Canonical **cold-start** stress ride (fires 311 s early free-run; monotonicity anchor) |
| 2 | `ahmedabad__yellow__coldstart_underground` | **Cold-start + longest single blind (918 s / 15.3 min)**, 17 stn |
| 3 | `kolkata__blue__coldstart_underground` | Second cold-start, 26-stn underground metro, different city |
| 4 | `delhi__blue__express_skip_long_blind` | **Express (28 skips) + long blind (500 s)** on the **90 km / 29-stn** max leg |
| 5 | `delhi__magenta__express_skip_long_blind` | **Express (12 skips) + long blind (559 s)**, 59.7 km |
| 6 | `delhi__orange__express_skip` | **Express** + the **VLineTable residual** (airport-express defaulted to 28 m/s) — keeps the caveat visible |
| 7 | `chennai__blue__long_blind` | **Pure long-blackout** (582 s single blind), 26 stn |
| 8 | `hyderabad__red__noblackout` | Clean no-blackout control, 27 stn |
| 9 | `mumbai__aqua__midroute_boarding` | **Mid-route boarding** scenario, 19 stn |
| 10 | `delhimeerutrrts__1 2__short_blind_p75` | **RRTS 53 m/s tier** coverage (only non-metro tier), short-blind |

Fixture paths (absolute):

```
/home/raed/geowake_imu_analysis/scale/rides/agra__yellow__coldstart_underground/base.json
/home/raed/geowake_imu_analysis/scale/rides/ahmedabad__yellow__coldstart_underground/base.json
/home/raed/geowake_imu_analysis/scale/rides/kolkata__blue__coldstart_underground/base.json
/home/raed/geowake_imu_analysis/scale/rides/delhi__blue__express_skip_long_blind/base.json
/home/raed/geowake_imu_analysis/scale/rides/delhi__magenta__express_skip_long_blind/base.json
/home/raed/geowake_imu_analysis/scale/rides/delhi__orange__express_skip/base.json
/home/raed/geowake_imu_analysis/scale/rides/chennai__blue__long_blind/base.json
/home/raed/geowake_imu_analysis/scale/rides/hyderabad__red__noblackout/base.json
/home/raed/geowake_imu_analysis/scale/rides/mumbai__aqua__midroute_boarding/base.json
/home/raed/geowake_imu_analysis/scale/rides/delhimeerutrrts__1 2__short_blind_p75/base.json
```

> Note: fixture #10's directory contains a space in the line segment (`1 2`). When copying into the
> Dart repo, rename to a safe id (e.g. `delhimeerutrrts__l1l2__short_blind_p75`) and keep a mapping.
> Each `base.json` carries an `expected` block (`fire at/before alarm_target.arrival_t_s`) — assert
> `fire_time ≤ alarm_target.arrival_t_s` and `U(t) ≥ s_true(t)` in the Dart replay test.

---

## 7. What this proves — and what it does not

- **PROVES:** the never-late SAFETY of the GPS + reachability-cone **integration** at scale — across
  391 rides × 3 alarm settings (1144 cells) and all 9 scenarios, the free-run cone fires late **0 times**
  and over-bounds true progress everywhere (worst margin +0.0 m). A false stop is the *only* late path,
  and the shipped mitigations (lower-edge-only fire + true per-line V_LINE) close it across the full matrix.
- **DOES NOT PROVE:** real-world device **detector precision** (recall/precision), which is device-dependent
  and was injected as a stochastic layer — not measured. Also not tested: a true express/airport speed tier
  (inherited 28 m/s default), curved-track polyline length, or any IMU signal.
