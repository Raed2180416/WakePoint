# GeoWake — Never-Late Validation Gaps: Simulation Consolidation

**Scope:** Seven gap-filling simulations run against the shipped free-run reachability
cone (`lib/core/reachability/reachability.dart`) and its roadmap variants, using the
generated synthetic ride corpus (391 metro + 4 long-haul RRTS rides, faithful Python
ports of `RouteGeometry` / `ReachabilityTracker` / `alarm_evaluator`). The alarm under
test throughout is **"wake N=2 stops before destination."**

**Never-late invariant (the thing every sim checks):**
`fire_time <= true target arrival` **AND** the certified upper bound
`s_hat(t) >= true s(t)` for all t. A *violation* is an actual **late fire** or a
**bound-below-truth** breach *in the shipped/correct configuration*.

> **Honesty caveat (applies to all seven):** these are simulations of the certified-bound
> *math* against synthetic ground truth. They prove the integration logic, not on-device
> detector precision, real GPS/tunnel behavior, or restore latency on hardware. "Validated
> in sim" is not "device-proven." See the final section for the exact split.

---

## Summary table

| # | Gap | Trials | Never-late violations (shipped/correct config) | Worst-case margin |
|---|-----|--------|--------------------------------------------------|-------------------|
| 1 | Monte-Carlo tail-risk (free-run cone) | 15,480 (ride,seed) | **0** | +0.00 s / bound never below truth (+0.00 m) |
| 2 | Process-death + restore mid-blackout | 1,847 kill-cells / 120 rides | **0** (FIXED snapshot re-seed) | +0.0 m cone margin (touches, never crosses) |
| 3 | Wrong-train / opposite / off-route | 348 rides × 3 scenarios | **0** (never-late axis) | on-route dip 0.000 m |
| 4 | Multi-leg + mode hand-off | 387 journeys × N=1..4 | **0** (mode-max V_LINE policy) | +0.1 s dest lead (min) |
| 5 | Never-wrong-place (spatial) | 395 rides (387 fired) | **0** (spatial-late) | 0.0 m deficit; all wrong fires EARLY |
| 6 | Property-based fuzzer | 11,000 rides / ~50.5M steps | **0** | invariant holds every step |
| 7 | Overnight/interstate + wall-clock | 4 rides × 6 phases | **0** healthy clock + forward anomalies; **3** cone-breaks + LATE under **backward jump** | **−1679.7 s (28 min) LATE** under adversarial backward jump |

**Aggregate: ~29,461 scenario-level trials (≥50.5M simulation steps).**
**Never-late violations in the shipped free-run configuration: 0 — with one real
exception (gap 7 backward wall-clock jump).** Every "unsafe variant" number below (gated
anchoring's 4, buggy restore's 117, naive hand-off's 387) comes from a configuration that
is either OFF in production or is explicitly the negative control; those confirm which
shipped behaviors are *load-bearing*, they are not defects in the shipped path.

---

## Per-gap verdicts

### Gap 1 — Monte-Carlo tail-risk (`scale/mc_never_late.py`)
**Method:** 15,480 (ride,seed) trials (15,320 metro + 160 long-haul) over 387 rides,
40 seeds/ride across 8 precision bins (0.80–1.0). Per seed: GPS hacc 5–30 m
(forward-overbound), blind-window position/length jitter ±25%, detector recall ~0.85 with
dwell noise, injected false stops. Ran both (a) the SHIPPED free-run cone
`s_max(t)=s0_hi+V_LINE·(t−t0)` re-anchored only on accepted fixes, and (b) the roadmap
GATED stop-anchoring (monotone-index + cone-admissible + min-travel-time gate).

**Numbers:** Free-run: **0 late fires**, `min(s_hat−s_true)=+0.00 m`, worst time margin
+0.00 s. Gated roadmap: **4 late fires / 15,320 metro (0.026%)**, all on short (4–5 stop)
rides where target=station 1 sits inside a blind window and a false stop re-anchors behind
true position; late fires vanish only at precision=1.0, persist as a low-rate tail at
p=0.95–0.99. Beneficial (safe) tightening in 10.7% of trials.

**Verdict:** SPLIT. The **shipped free-run cone is unconditionally never-late** at scale,
exactly as designed (V_LINE ≥ true top speed + forward-overbound ⇒ `s_hat ≥ s_true`
always). The **gated stop-anchoring is NOT unconditionally never-late** — a single
mistimed false stop suffices, bounded to ≤1 inter-station gap as FOUNDATION.md predicts.
**No never-late risk in shipped code**; confirms the stance that tightening must stay
gated until detector precision is device-proven.

---

### Gap 2 — Process-death + restore mid-blackout (`scale/sim_process_death.py`)
**Method:** Deterministic, no RNG. 120 long-blackout/coldstart rides, N=2, OS-kill swept
across 16 instants per ride = **1,847 (ride, t_k) cells**, restore at t_k+5 s. Compared
**FIXED** restore (re-seed anchor from persisted snapshot `s_snap@t_snap`) vs **BUGGY**
restore (seed `s=0 @ now`).

**Numbers:** FIXED: **0 late fires, 0 bound violations** (1e-6 tol) across all 1,847 cells,
worst cone-phase margin +0.0 m. BUGGY: certified bound violated in **1,846/1,847** cells
(deficit up to −21,686 m), **117 outright late fires** across 12 rides, max lateness 86 s,
max delay 855 s. (A harness bug — naive global-nearest GPS snap mis-projecting up to
−30,641 m on self-approaching 82 km routes — was fixed with a monotone along-track snap
before grading.)

**Verdict:** **FIXED restore is never-late** through kill+restore across every swept kill
instant. The snapshot re-seed on restore is **load-bearing** for the guarantee: without it
the bound collapses and produces real late fires. **Code implication:** the restore path
MUST re-seed the reachability anchor from the persisted snapshot, never `s=0@now` — verify
the shipped restore actually does this.

---

### Gap 3 — Wrong-train / opposite-direction / off-route (`scale/wrong_train_sim.py`)
**Method:** 348 rides (≥5 stations), faithful ports of `RouteGeometry.projectLatLng`
(NaN >75 m cross-track) + `ReachabilityTracker` + shipped deviation thresholds. Three
divergence scenarios: opposite/reversal, parallel-line lateral, express-skip no-dwell.

**Numbers:** **Never-late invariant held 348/348 in every scenario** (worst on-route dip
0.000 m) — the net always over-bounds true progress, so every false wake is EARLY (safe).
Divergence is **detectable when GPS is available** (progress-reversal 348/348, cross-track
348/348, no-dwell 348/348). **BUT** the shipped reachability fire path has **no deviation
gate** (`alarm_evaluator.dart:395-399` `shouldFire=reachFireMain||eta`; `alarm_controller`
`onAcceptedFix` is time-monotonic only, no s-monotonic guard), so the raw net **does fire a
false wrong-PLACE EARLY wake** when the anchor goes stale on a diverged rider: parallel
off-route 348/348; opposite-into-blackout once blackout > fire_target/V_LINE (59/348 at
300 s). Detection beats the fire with median +287 s margin, but for divergence <300 m
before target detection does NOT beat the fire (worst margin −52 s).

**Verdict:** **Never-late axis is clean** (0 late fires; a false stop-anchor remains the
only late mechanism and none occurred). The real gap is on the **never-wrong-PLACE / false-
EARLY-wake** axis, not never-late. **Recommendation (not a never-late fix):** gate the
reachability destination fire on a progress/deviation guard and add a monotonic-in-s guard
to `onAcceptedFix`, so a confirmed divergence suppresses or reclassifies the fire.

---

### Gap 4 — Multi-leg journeys + mode transitions (`scale/multileg_neverlate.py`)
**Method:** Synthesized walk→metro→interchange-walk→metro→walk journeys from the corpus,
per-leg V_LINE ceilings (walk 2.0, metro per-line), blind windows on metro legs, N sweep
{1,2,3,4}, 387 journeys. Compared **CORRECT** mode-max-since-anchor policy vs **NAIVE**
last-fix-leg ceiling.

**Numbers:** CORRECT: **0 upper-bound violations, 0 late target/dest fires, 0 walk-legs
using a metro ceiling** at every N (dest lead min +0.1 s). NAIVE under an adversarial
boarding-straddle blind [t0−6, t0+40]: breaks the certificate on **387/387** journeys and
late-fires the target on 4 (e.g. fire 2343.0 s > true arrival 2342.8 s).

**Verdict:** **PASS for the correct mode-max hand-off.** The literal "current-active-leg
ceiling" is UNSAFE across a boarding-straddling blackout (a walk ceiling of 2.0 m/s
under-bounds a train departing at up to 28 m/s). **Code implication:** the multi-leg
ceiling must be **mode-max V_LINE over the anchor interval** (plausible-mode-set
containment), not the active-leg ceiling.

---

### Gap 5 — Never-wrong-place, spatial (`scale/never_wrong_place.py`)
**Method:** 395 rides (387 fired), shipped free-run bound, true `s(t)` reconstructed
exactly from the generator trapezoidal profile (0.0 m error at every stop). Measured
meters-early, nearest made-stop, stops-early, and the never-late invariant on a 0.05 s grid.

**Numbers:** **Never-late (spatial) holds perfectly:** upper-bound break = 0 (worst deficit
0.0 m; max true_speed/V_LINE = 0.801 < 1), 0 fires past target, 0 after target/dest arrival.
Meters-early to target: median 12 m, p95 4,067 m, max 9,195 m. **Wrong-station rate
46/387 = 11.9% — all EARLY, none past target.** Materially wrong (≥2 stops early)
**32/387 = 8.3%, all inside a blind window**, concentrated in long_blind (47.6%) and
express_skip_long_blind (43.6%); clean scenarios 0% wrong.

**Verdict:** **Never-late is perfect; "fires AT the right station" is not** under long
mid-route blackouts — the free-run cone races ahead while GPS is dark and can fire up to 10
stops / 9.2 km early. **Every wrong fire is EARLY (safe direction) — a documented UX
trade-off, not a correctness bug.** Shipped lever to tighten: the topology stop-count cap
(`ReachabilityConfig.dwellMinSeconds>0`), currently OFF by default.

---

### Gap 6 — Property-based fuzzer (`scale/fuzz_never_late.py`)
**Method:** Two independent master seeds (20260718, 424242) generating **11,000 random
valid scenarios / ~50.5M steps**. Station counts 2–30, V_LINE ∈ {28,39,53,56}, five
blackout patterns. Asserted all four never-late invariants on free-run + gated anchoring.
Three negative controls + 7 corrupt-input cases.

**Numbers:** **0 invariant violations, 0 late fires** across ~50.5M steps. All 7 corrupt
inputs fail SAFE. The 3 negative controls (V_LINE below true speed; anchor 500 m behind
truth; dwellMin over-claiming) each **tripped the expected invariant** — so the fuzzer has
teeth and the clean pass is meaningful.

**Verdict:** **PASS.** Never-late follows structurally from the certified-bound invariant
(`s_max ≥ s_true` everywhere ⇒ at true arrival `s_max ≥ s_target` ⇒ fire already true).
The only paths that break it lie outside the valid-scenario preconditions (true speed >
V_LINE, anchor behind truth without forward overbound, or dwellMin over-claim). **No
never-late risk in shipped math.**

---

### Gap 7 — Overnight/interstate + wall-clock (`scale/sim_longhaul_neverlate_clock.py`)
**Method:** 4 new long-haul RRTS rides (2.05–4.22 h, V_LINE=53 m/s, legs up to ~300 km,
blackouts up to 15 min), 1 Hz over full duration, N=2, under injected clock anomalies
across 6 phases.

**Numbers:** Baseline (clean clock, 2–4.2 h): **0/4 failures**, tightest cone slack exactly
+12.0 m (= hacc overbound), **no degradation over 4.22 h / s_hat ≈ 590 km** (double
precision fine). Forward +30 min jump, fast skew, small slow skew: **SAFE all 4** (only
ever fires EARLY). **Backward −30 min jump: CONE-BREAK all 4** (deficit 68–71 km);
slow skew beyond ~−26% also breaks (but realistic crystal drift ≤100 ppm is ~2300× inside
tolerance). Phase 6 adversarial backward jump 120 s before wake target: **LATE fire on all
3 non-degenerate rides, ~1680 s (28 min) late** — worst `interstate_2h`, fire 5096 s vs
true arrival 3416 s = **−1679.7 s**. **Phase 3: the same anomalies on a MONOTONIC clock
(elapsedRealtime) are ALL SAFE (0 violations).**

**Verdict:** **This is the one real shipped-code never-late defect the seven sims found.**
Long-duration robustness holds (no float drift over 590 km/4.2 h; forward anomalies safe).
But `alarm_controller.dart:139 _nowSeconds()=DateTime.now()` and the anchor stamp
(`:572-577` = `currentPosition.timestamp`) are both **wall-clock**, so `dt=(t−t0)` is a pure
wall-clock difference. A **backward jump** (NTP step-back, carrier/user time correction,
DST/naive-DateTime underflow) makes every subsequent fix look stale, so the monotonic guard
(`reachability.dart:432`) rejects all fixes for the jump magnitude, freezing the cone and
producing a reproducible ~28-min LATE fire; the T_max watchdog can't rescue it
(dtClamped frozen at 0). **Fix (proven in Phase 3):** feed reachability elapsed time from a
MONOTONIC clock (Android `SystemClock.elapsedRealtime()` / a Dart `Stopwatch` anchored at
arm), with the anchor stamp and evaluation from the **same** monotonic source.

---

## Never-late risks that need a code fix

| Priority | Gap | Risk | Fix | Status |
|----------|-----|------|-----|--------|
| **P0 — real defect** | 7 | Backward wall-clock jump → reproducible **28-min LATE fire** on shipped code | Feed reachability elapsed time from a **monotonic clock** (`SystemClock.elapsedRealtime()` / `Stopwatch` at arm); same source for anchor stamp + evaluation. `alarm_controller.dart:139, :572-577` | **Unfixed** — sim-surfaced, fix proven in sim (Phase 3) |
| **P0 — load-bearing** | 2 | Restore after process-death with `s=0@now` → **117 late fires** | Restore MUST re-seed anchor from persisted snapshot `s_snap@t_snap` | Verify shipped restore does the snapshot re-seed |
| **P1 — design rule** | 4 | Naive per-active-leg V_LINE hand-off under boarding-straddle blackout → certificate break + 4 late fires | Use **mode-max V_LINE over the anchor interval**, not the active-leg ceiling | Confirm/implement in multi-leg hand-off |
| **P2 — not never-late** | 3 | No deviation gate on `reachFireMain` → false wrong-PLACE **EARLY** wakes on diverged riders | Gate destination fire on progress/deviation guard + monotonic-in-s guard in `onAcceptedFix` | Recommendation only (never-wrong-place, not never-late) |
| **Keep OFF** | 1, 5 | Gated stop-anchoring / dwellMin tightening → 4 late fires below precision=1.0 | Keep gated stop-anchoring OFF until detector precision device-proven; `dwellMinSeconds>0` is the lever for the early-fire UX | As-designed |

**Bottom line:** the shipped free-run never-late guarantee held in every sim **except the
backward wall-clock jump (gap 7)** — the single sim-surfaced defect on current code. The
process-death (gap 2) and multi-leg (gap 4) results are not shipped-path failures but proofs
of which behaviors (snapshot re-seed; mode-max hand-off) are load-bearing and must be
correct. Wrong-train (gap 3) is a never-wrong-place gap, not a never-late one.

---

## Validated-in-sim vs still device-only

**Now validated in simulation (integration/bound math):**
- Free-run reachability cone is **never-late** across ~27k structured trials + ~50.5M fuzz
  steps (gaps 1, 5, 6): 0 late fires, cone over-bounds true `s(t)` at every step
  (worst deficit 0.0 m) under all noise / blind-window / precision / duration variations.
- No float/precision drift over **4.22 h / ~590 km** long-haul; cone slack stays at the
  +12 m hacc floor (gap 7 baseline).
- Process-death restore is never-late **iff** the anchor is re-seeded from the persisted
  snapshot (gap 2).
- Multi-leg mode hand-off is never-late under the **mode-max V_LINE** policy, N=1..4 (gap 4).
- Route divergence (opposite / parallel / express-skip) is **detectable when GPS is
  available** (gap 3).
- Wall-clock robustness: **forward** jumps and realistic crystal skew (≤100 ppm, ~2300×
  inside tolerance) are safe; a monotonic clock closes the backward-jump hole (gap 7).

**Still device-only — NOT proven by these sims:**
- **On-device stop-detector precision/recall** — every sim assumed or swept it; none
  measured real hardware. The gap-1/gap-3 tail risks are precision-driven.
- **Snapshot persistence + restore latency on real Android** — OS-kill timing, disk-write
  survival, and restore speed under Doze are unverified (gap 2 is deterministic sim only).
- **Real GPS accuracy / hacc distributions, real tunnel blackout durations, multipath.**
- **Monotonic-clock behavior across device sleep/Doze** — `elapsedRealtime()` counts sleep
  on Android, but this must be confirmed on-device before relying on the gap-7 fix.
- **The deviation/progress gate (gap 3 recommendation)** — unimplemented and unproven.
- **Gated stop-anchoring on real detectors** (gap 1) — OFF in production, precision not
  device-proven.

**Scripts (all under `/home/raed/geowake_imu_analysis/scale/`):**
`mc_never_late.py`, `sim_process_death.py`, `wrong_train_sim.py`, `multileg_neverlate.py`,
`never_wrong_place.py`, `fuzz_never_late.py`, `sim_longhaul_neverlate_clock.py`
(+ `build_longhaul_rides.py`, result JSONs `sim_process_death_results.json`,
`never_wrong_place_results.json`).
