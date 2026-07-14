# WakePoint — Synthetic Scenario Design Matrix

*What rides to generate, and why each one earns its place. The spec for Stage B's Monte Carlo corpus.*

## Principle: coverage-driven, not uniform-random

With n=1 real ride, synthetic scenarios are the only route to statistical confidence. But random rides waste compute on easy cases. Instead:
- **Stratify** across the axes below so every meaningful combination is hit.
- **Importance-sample** rare-but-critical configs (over-represent the tail).
- **Adversarially construct** worst-case timing (not just sample it).
- **Bound every extreme** by physical plausibility (realism gate + hard limits) — an impossible ride gives a meaningless "failure."
- **Flag extrapolation**: any scenario type never seen in the one real ride is a hypothesis, not a measurement, until a matching real ride is captured.

---

## Axes of variation (the dimensions every ride is sampled on)

| Axis | Levels (average → extreme) | Why it matters |
|---|---|---|
| **A. Route topology** | single line · 1 transfer · 2+ transfers · express/skip-stop | transfer = interchange confusion; skip-stop = schedule mismatch |
| **B. Route length / #stops** | 3 stops · ~10 · 25+ (the real ride) | more stops = more reset opportunities but more mis-snap chances |
| **C. Inter-station spacing** | even ~1.2 km · mixed · two stops <500 m apart underground | close stops underground = station-snap ambiguity |
| **D. GPS condition** | full surface · short tunnel (60 s) · long blackout (388 s+) · intermittent urban-canyon · complete dropout · cold-reacquire glitch on exit | the core stressor; drift grows as ½·b·t² |
| **E. Blackout *timing*** | mid-segment · **ending exactly at target stop** · spanning an interchange | worst case = max drift at the decision moment |
| **F. Carry mode** | in-hand steady · pocket · bag · on-lap · to-ear · **mode change mid-ride** | tilt error leaks gravity into forward axis; transitions are transients |
| **G. Phone quality (domain randomization)** | flagship (low noise) · mid · budget (high bias/noise) · sample-rate 50/100/200 Hz | cross-device robustness (MosaicIMU/Inertia-1 axis) |
| **H. Motion anomalies** | smooth · slow creep-to-halt · emergency brake · held-at-station · standing/walking during ride | ZUPT false-positive/negative triggers |
| **I. Rider behavior** | seated still · gets up early · moves to door pre-stop · changes carriage | pre-arrival motion can spoof a ZUPT or station event |
| **J. Track gradient** *(fidelity gate)* | flat · 3° ramps at tunnel entry/exit · steep | position-correlated gravity leak (sin θ·g) the TiltFilter mistracks underground — same ramp every ride = systematic bias where GPS is blind |
| **K. Background throttle regime** *(fidelity gate)* | foreground 100 Hz · doze-batched 50 Hz · throttled 10 Hz | a screen-off wake alarm loses sensor rate (Android Doze / iOS batching); 100 Hz results are optimistic |

**Fidelity gate items folded into the synthesizer (validated before trusting any Stage-C number):**
1. **Track gradient** (axis J) — synthetic ramps at tunnel entry/exit; gravity projects a real forward artifact (0.16 m/s² at 3°) the TiltFilter must reject. *Importance is that it's the untested underground input; the "km-scale drift" is a hypothesis Stage C measures, not a proven figure — a sustained constant-speed grade lets the complementary filter reconverge, so the damage is in the transients.*
2. **Speed-tracking vibration chirp** — vibration dominant frequency tracks speed (rail-joint f = v/spacing + wheel/bogie harmonics; validated r≈0.8, 0.9 Hz→3 Hz across the speed range), with spectral shape matched to the real 3–8 Hz peak. Gates MotionClassifier validity (it reads walk/vehicle from FFT band energy).
3. **Background throttle** (axis K) — decimate+hold to emulate screen-off rate loss.
4. **Reference-σ propagation** — *Stage C requirement, not synthesizer:* scoring must propagate silver-reference σ (2–40 s); an underground "error" within reference σ is reference noise, not filter error.

Average ride = middle levels on every axis. Edge ride = extreme on one or more.

---

## Named edge-case scenarios (each targets ONE failure mode from §5.5)

| # | Scenario | Construction | Failure mode it hunts |
|---|---|---|---|
| E1 | **Worst-timed blackout** | long GPS gap that *ends at the target-stop arrival* | max accumulated drift → alarm at wrong place |
| E2 | **Interchange in the dark** | transfer station inside a GPS blackout | snap-to-wrong-line; stop-count off across transfer |
| E3 | **Twin close stops underground** | two stations <500 m apart, no GPS | station-snap picks the wrong one → off-by-one |
| E4 | **Missed ZUPT at critical stop** | dwell too short / phone jostled at target stop | no velocity reset → unbounded drift right at the end |
| E5 | **False ZUPT while moving** | slow creep (the real "creeping to a halt" note) | filter zeroes velocity mid-motion → position frozen |
| E6 | **Bag-carry tilt divergence** | high sustained tilt + tilt-estimate error | gravity leaks into forward axis → constant bias E1-style |
| E7 | **Carry-mode change mid-blackout** | in-hand → pocket transition during GPS gap | transient the TiltFilter can't track underground |
| E8 | **Budget phone + long tunnel** | high bias-instability device on the 388 s gap | device-quality floor meets worst GPS |
| E9 | **Cold-reacquire overshoot** | tunnel-exit GPS glitch (large innovation) | robust gate rejects good fix, or accepts a bad one |
| E10 | **Express skip-stop** | train skips a scheduled stop | stop-counting alarm fires one stop early |

Average-case scenarios (A1–A∞) fill the middle: single/one-transfer lines, normal GPS with the odd short tunnel, steady carry, mid-tier phone — these establish the baseline hit rate the edge cases are measured against.

---

## Sampling plan (how many of each)

- **Baseline corpus:** ≥200 average rides per route family → establishes mean hit rate with bootstrap CIs.
- **Edge corpus:** ≥50 rides per named edge scenario (E1–E10) → measures each failure mode's rate with a tight enough CI to see a 2% catastrophe.
- **Domain-randomization sweep:** every ride samples axis G (phone) independently, so metrics can be sliced *per device bin* to prove cross-phone robustness.
- **Adversarial refinement:** after a first pass, take the configs that failed and jitter them (search the neighborhood) to map the *boundary* of failure, not just its existence.

## What this buys you
1. A **failure Pareto** (which of E1–E10 dominates) → tells you exactly what to fix first in Stage 1.
2. A **per-device robustness table** → answers the "no quality loss across phones" goal with numbers.
3. A **tail hit-rate** (P99, catastrophic-miss rate) → the product metric that a mean error hides.
4. **Extrapolation flags** → an honest list of scenario types not yet backed by any real ride, i.e. your capture priorities for ride #2, #3, ...
