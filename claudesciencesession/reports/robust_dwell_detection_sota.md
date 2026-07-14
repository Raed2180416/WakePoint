# Desync-Robust, Fail-Safe Station-Sequence Estimator (WakePoint STOPS mode)

**Scope.** Underground, GPS-blackout metro tracking. The alarm must fail **EARLY** (fire before the target stop), never late. Current STOPS mode counts station dwells (ZUPT + `DwellCountAssociator`) and advances the known station index one stop per detected dwell; the combined "fire on position-arc **or** dwell-count, whichever first" rule scored 37/40 on-time with 1 residual late (a genuine missed dwell on a 358 s blackout). Residual failure modes: **missed dwells** → undercount → count never reaches target → **LATE** (dangerous); **double-counts** (spurious mid-tunnel quiet window) → overcount → early (annoying, safe-side). This document specifies a replacement that is robust to both and fails safe by construction. *Status: SOTA-grounded design, to be sim-verified before Dart port (per the project's verify-in-sim-first rule).*

## Core principle

Replace the **hard integer counter** (one dwell = one station advance) with a **probabilistic station-sequence estimator**: a discrete Bayesian filter (HMM) over station index, running alongside the continuous 1D arc-length EKF `[s, v, b]`. Two ideas do the heavy lifting:

1. **Advance the belief on TIME + ARC, not on dwells alone.** A missed dwell can no longer starve the estimator, because elapsed time (against a timetable prior) and the EKF arc-position independently push the belief forward.
2. **Carry uncertainty, not a point count.** When station identity is ambiguous (desync risk), the belief spreads; that spread is mapped directly onto the position sigma fed to the critical-fractile alarm, so **more desync ⇒ wider sigma ⇒ earlier fire.** The fail-early guarantee is monotone.

## (a) Dwell-detection front-end — recall-biased, asymmetric-cost

The detector's job is **high recall** (rarely miss a true stop); **precision is delegated to the HMM** (schedule consistency rejects spurious dwells). Three layers, analytic-first to avoid the known velocity-circularity trap:

- **Change-point segmentation** of the 2 s accel-variance / 3–8 Hz band-energy signal into run/dwell segments, replacing the hand-tuned `min_dwell_s` threshold with principled boundaries + a per-boundary probability. Online: **Bayesian Online Changepoint Detection** (`0710.3742`); robust/scalable variant for heavy-tailed carry-motion (`2302.04759`); offline review + method taxonomy (`1801.00718`). OSS: **ruptures**, **bayesian_changepoint_detection**, **bayesloop**.
- **Adaptive-threshold Bayesian ZUPT** as the physical stationarity test (`1903.07929`), which uniquely lets the **asymmetric cost of a missed vs false detection** be built into the likelihood-ratio threshold — bias toward over-detection because undercount→LATE dominates overcount→early. Context in the ZUPT review (`2008.09208`). OSS: **pyshoe** (robust/learned ZUPT). Handheld-phone inertial specifics: `1703.00154`; low-rate transit-mode features: `2404.15323`.
- **Soft dwell-probability gate** (SOTA direction): GNIO's gated head models "motion validity" and stationarity micro-drift, emitting a soft stop-probability rather than a binary flag (`2603.15281`) — feeds the HMM as a likelihood. *Deferred until real ride #2 (learned channels are circularity-gated here).*

## (b) Station-sequence estimator — HMM/Viterbi over the known station list

**Hidden state** `k ∈ {0…N}` = index of the most-recently-departed station (segment k→k+1 currently traversed). The prefetched route gives station arc-positions `x_0<…<x_N`; the **timetable prior** gives nominal inter-station run time `τ_k` and dwell time `d_k`.

**Transition model (predict).** Probability of advancing 0/1/2+ stations given elapsed time, modelling run-time as log-normal around `τ_k`. This is the missed-dwell fix: **time + arc advance the belief even with zero dwells observed.** Explicit `k→k+2` skip transitions (weighted by the schedule) cover express/skipped/missed-dwell cases.

**Emission model (update).** A detected dwell emits a likelihood over which station it is, scoring its **measured duration against `d_k`** — a 4 s "dwell" mid-run is inconsistent with any station and is down-weighted (double-count rejection). The EKF arc-position emits a soft Gaussian likelihood over segment span, coupling the continuous filter to the discrete belief **without a hard snap** (hard snapping caused the arc-lag late fire).

This is exactly HMM/Viterbi map-matching cast onto a 1-D station list: cells-as-hidden-states + Viterbi most-likely-sequence in a GNSS-denied INS-aiding setting (`2204.10492`); robustness when the map/sequence is imperfect — missed/extra nodes (`1809.09755`); sparse/noisy-observation matching (`2601.08482`, DiffMM); online/streaming matching (`2502.06825`, RLOMM); particle-filter formulation (`1611.09706`). Run **forward filtering** online for the belief; **fixed-lag Viterbi** for the MAP station sequence.

**Multiple-hypothesis variant.** The forward belief *is* a hypothesis bank over station index; for richer state (station index × in-dwell flag × cumulative-missed count) use a small **particle filter / MHT** with prune-merge to stay cheap on-device (`1106.2263`, `2105.01379`). OSS: **Stone-Soup** (MHT/PDA/PF), **filterpy** (KF/PF), **LeuvenMapMatching**, **fmm**, **valhalla/Meili** (HMM map-matchers to adapt from 2-D roads to the 1-D line).

**Coupling to the EKF.** Feed a **soft station pseudo-measurement**: expected arc under the belief `x̂ = Σ_k b_t(k)·mid(seg k)` with measurement variance = **belief variance** `Σ_k b_t(k)(x−x̂)²`. Confident belief → tight pseudo-measurement → EKF sigma shrinks; spread belief → wide variance → EKF sigma stays large. Uncertainty flows automatically from discrete ambiguity into continuous sigma.

## (c) Desync detection + fail-safe

We cannot observe truth underground, so we detect **inconsistency** and convert every signal into **one lever — inflation of the position sigma `σ_s`** feeding the alarm.

**Four desync signals**

1. **Schedule-residual / innovation monitoring** (`2301.11573`, KF residuals as the standard fault signal): flag when time between detected dwells departs from `τ_k` — e.g. 2.5× a nominal run with no dwell (overdue), or 3 dwells inside one run (excess).
2. **Belief entropy**: high `H(b_t)` or near-tied top-2 hypotheses ⇒ station identity ambiguous.
3. **EKF-arc vs HMM-station disagreement**: a NIS-style gate on the divergence between the continuous arc estimate and the belief's expected arc — the two subsystems disagreeing is a direct desync flag.
4. **Online conformal calibration** for the synth→real shift we *know* exists (velocity circularity): ACI (`2202.07282`), Conformal PID (`2307.16895`), error-quantified conformal for time series (`2502.00818`) adapt dwell-timing interval width to recent coverage; when timings are mispredicted, the interval widens → wider transition uncertainty → wider `σ_s`. "Report the Floor" (`2606.09473`) supplies a **mandatory uncertainty floor**: `σ_s ≥ σ_floor(t)`, growing with time-since-last-GPS and time-since-last-confirmed-dwell.

**Fail-safe mechanism.** The critical-fractile alarm fires when `s + k·σ_s ≥ fire_arc` (position) or `median_ETA − k·σ_ETA ≤ threshold` (time). Widening `σ_s` moves the fire point **earlier** — monotone, never late. The combined trigger stays: fire on **position-arc critical-fractile OR dwell-count-belief-reaching-target OR schedule-time critical-fractile, whichever first** — three independent safe-side triggers, earliest wins.

**Why this fixes the residuals.** *Missed dwell (the 358 s residual late):* belief advances on time+arc without the dwell (b), the schedule-residual flags the overdue dwell and the conformal time-since-dwell floor inflates `σ_s` (c) — all three push the critical-fractile earlier, so the missed dwell no longer yields a late fire. *Double-count:* the duration-scored emission down-weights schedule-inconsistent dwells, so a spurious quiet window does not advance the belief; any residual ambiguity widens sigma (early/safe).

## Validation plan (sim-first)

Re-run the 40-route OSM corpus + edge cases E1–E10 (esp. E4 missed-ZUPT-at-target, E5 false-ZUPT-creep, E10 express skip-stop). Metrics: STOPS hit-rate, **signed lead-error (late fires = 0 is the pass bar)**, dwell-detector precision/recall, station-index confusion vs gold, NEES/NIS consistency, and desync-flag ROC. Ablate each layer to confirm none re-introduces a late fire. Port to Dart (`station_association.dart`, `alarm_controller.dart`) only after zero-late is sim-confirmed; keep the soft-gate/learned-velocity layer gated on real ride #2.

## Verification note (anti-confabulation control)

All 22 arXiv IDs below were confirmed via `arxiv_get_papers` to resolve to the cited title. Controls: `2699.99999` (malformed) → correctly `not_found`; `2606.19999` (plausible-format guess) → resolved to a real but unrelated hep-ph paper on vector-boson scattering and is therefore **not cited** — demonstrating the tool surfaces true titles, so a wrong ID cannot be laundered into a plausible citation. OSS repos below returned HTTP 200; bogus control `github.com/yzslab/mapie` → 404.

### arXiv (verified)
| ID | Title |
|---|---|
| 0710.3742 | Bayesian Online Changepoint Detection |
| 2302.04759 | Robust and Scalable Bayesian Online Changepoint Detection |
| 1801.00718 | Selective review of offline change point detection methods |
| 1903.07929 | Zero-Velocity Detection — A Bayesian Approach to Adaptive Thresholding |
| 2008.09208 | Fifteen Years of Progress at Zero Velocity: A Review |
| 1703.00154 | Inertial Odometry on Handheld Smartphones |
| 2404.15323 | Transportation mode recognition based on low-rate acceleration and location signals … (attention-based multiple-instance learning network) |
| 2603.15281 | GNIO: Gated Neural Inertial Odometry |
| 2204.10492 | Gravity aided navigation using Viterbi map matching algorithm |
| 1809.09755 | Map matching when the map is wrong |
| 1611.09706 | Probabilistic map-matching using particle filters |
| 2601.08482 | DiffMM: … Trajectory Map Matching via One Step Diffusion |
| 2502.06825 | RLOMM: … Robust Online Map Matching … Reinforcement Learning |
| 1106.2263 | A Library for Implementing the Multiple Hypothesis Tracking Algorithm |
| 2105.01379 | Randomized Multiple Model Multiple Hypothesis Tracking |
| 2301.11573 | On the optimality of Kalman Filter for Fault Detection |
| 2202.07282 | Adaptive Conformal Predictions for Time Series |
| 2307.16895 | Conformal PID Control for Time Series Prediction |
| 2502.00818 | Error-quantified Conformal Inference for Time Series |
| 2606.09473 | Report the Floor: A Training-Free Conformal Interval Is a Mandatory Baseline |
| 2007.01867 | TLIO: Tight Learned Inertial Odometry |
| 2408.06321 | EqNIO: Subequivariant Neural Inertial Odometry |

### OSS (HTTP 200)
- ruptures — https://github.com/deepcharles/ruptures (CPD)
- bayesian_changepoint_detection — https://github.com/hildensia/bayesian_changepoint_detection (BOCPD)
- bayesloop — https://github.com/christophmark/bayesloop (BOCPD-style)
- pyshoe — https://github.com/utiasSTARS/pyshoe (robust/learned ZUPT)
- LeuvenMapMatching — https://github.com/wannesm/LeuvenMapMatching (HMM/Viterbi)
- fmm — https://github.com/cyang-kth/fmm (HMM map matching)
- valhalla — https://github.com/valhalla/valhalla (Meili HMM map matching)
- Stone-Soup — https://github.com/dstl/Stone-Soup (MHT/PDA/PF)
- filterpy — https://github.com/rlabbe/filterpy (KF/PF)
- MAPIE — https://github.com/scikit-learn-contrib/MAPIE (conformal, ACI/EnbPI)
- TLIO — https://github.com/CathIAS/TLIO (learned inertial odometry)
