# WakePoint — End-to-End IMU Simulation & Filter Evaluation Methodology

*How to synthesize realistic phone IMU along prefetched routes, and prove — with trustworthy numbers — whether the EKF actually tracks position underground.*

*Current to 2026-07-09. Diagnostics computed from `docs/Sandalsoap-whitefield/` this session; SOTA sources retrieved via arXiv this session (IDs listed at end).*

---

## 0. The one-paragraph thesis

You cannot validate a dead-reckoning filter against a single hand-logged ride, because the reference is uncertain by tens of seconds and tens-to-thousands of meters exactly where the filter matters most (the 388 s / 3.2 km underground blackout in your real trace has **no** independent position reference at all). The only dataset with *trustworthy* ground truth is one you generate, because then you know `s(t)` by construction. So the real ride is demoted from "test set" to "realism calibrator," and a physics-based, statistically-validated **synthesizer** becomes the test-set generator. Around it we build a **Monte Carlo evaluation harness** that measures the four things your current single-scalar error does not: ZUPT detection quality, station-association correctness, filter *consistency* (is the reported σ believable?), and the end-to-end alarm hit rate — with a **failure-mode taxonomy and rates**, not just a mean. Then, and only then, we use that harness to (Stage 1) harden the analytical EKF, (Stage 2) benchmark learned inertial odometry on identical data, and (Stage 3) build toward a TLIO-style learned+filter hybrid.

---

## 1. What the diagnostics already proved

Every number below is measured from your files this session, not assumed.

### 1.1 The drift physics (why "subpar" is expected without perfect resets)
Position error from a constant along-track accelerometer bias `b` grows as **½·b·t²**. Using your ride's real 388 s tunnel:

| residual accel bias | pure-INS error at 388 s | with ZUPT at each stop | with ZUPT + station-snap |
|---|---|---|---|
| 5 mg (0.005 m/s²) | 377 m | — | — |
| 10 mg | 753 m | — | — |
| **20 mg** | **1506 m** | 332 m (peak) | **81 m (peak)** |
| 50 mg | 3765 m | — | — |

Your *stationary* accel std was 0.20–0.53 m/s² per axis, so a 20 mg **residual** (post tilt-correction) is optimistic. **Implication:** the resets (ZUPT, station-snap) are not optional refinements — they are the entire mechanism. If tracking is subpar, a reset is failing to fire, or firing wrong. That is a testable hypothesis, and §5 tests it.

### 1.2 Ground-truth quality (why the real ride can't score the filter)
- **Station labels are manual button taps** with human-reaction lag. The cleanest measurement: in-tunnel, the train's IMU quiet-window ends at 1245.7 s and the "Br Ambedkar" tap lands at 1257.6 s — **~12 s of tap-after-event lag**. Other stations show tens of seconds of tap-vs-GPS-nearest-approach offset in *both* directions (some confounded by transit-endpoint matching). Net: tap timing is unreliable by tens of seconds, in either direction.
- **Missing stations, admitted in your own log:** "missed Sri M Visveswaraya," "missed kadugodi tree park." The station *count* — the exact quantity a stop-counting alarm depends on — is wrong in the reference.
- **The blackout has no position reference:** 388 s, 3.2 km straight-line, 2 annotated stations inside, last pre-gap fix reported speed 0 at 100 m accuracy.
- **GPS is a noisy measurement, not truth:** accuracy blows to 2700 m on bad fixes (mean 17 m); 96 gaps > 5 s. Grading a GPS-consuming filter against raw GPS is circular.
- **n = 1 (confirmed):** one phone (A059P), one rider, one route, one direction, one day; two carry modes total ("sitting, phone in hand" leg 1; "standing, walking" leg 2). Gravity vector wobble measured at **5.5° RMS, 46° peak** while walking — orientation isn't even fixed within a leg. *No other real rides exist yet — this is the constraint the synthesizer must overcome, not one more capture can fix today.*

### 1.3 The recoverable-truth finding (what saves the approach)
Train physical stops **are** visible in the IMU during the blackout: rolling 2 s accel-variance troughs mark dwells (8 quiet windows ≥ 3 s found in the tunnel section, including a clean 23.8 s dwell). This lets us **reconstruct a cleaned interior reference** from IMU + known metro schedule that is far better than the taps — the basis of the "silver" reference in §3.3.

### 1.4 Sensor/logging artifacts the synthesizer must reproduce (or replay must handle)
- **Gyro logs at ~57 Hz, not the 100 Hz metadata claims** (dt median 17.5 ms, jitter CoV 0.08, max dt 131 ms). Accel/gravity at 100 Hz (max dt 140 ms — occasional stalls).
- First accelerometer row is `(0,0,0)` — a garbage sample.
- Available channels: `Accelerometer` (linear/gravity-removed), `AccelerometerUncalibrated`, `TotalAcceleration` (raw), `Gravity`, `Gyroscope`, `GyroscopeUncalibrated`, `Orientation` (fused quaternion qx,qy,qz,qw + roll,pitch,yaw), `Location`, `Battery`. **The app feeds RAW accel and removes gravity internally (§8 Q1), so faithful replay must use `TotalAcceleration.csv`, not `Accelerometer.csv`.**

---

## 2. Architecture of the whole system

```
                    ┌─────────────────────────────────────────────┐
                    │  REAL RIDE (Sandalsoap→Whitefield, n=1)      │
                    │  role: realism calibrator, NOT test set      │
                    └───────────────┬─────────────────────────────┘
                                    │ fit statistics (spectra, noise
                                    │ floor, dt-jitter, GPS-dropout,
                                    │ orientation wobble)
                                    ▼
   prefetched route ─────▶ ┌──────────────────────┐
   (polyline + stations,   │   IMU  SYNTHESIZER    │───▶ synthetic ride:
    schedule, GPS model)   │  (physics + noise +   │     • raw device-frame accel/gyro/mag
                           │   orientation + GPS)  │     • GPS stream w/ realistic dropouts
                           └──────────┬───────────┘     • EXACT s(t), v(t), stop times,
                                      │                   true station indices  ← GOLD truth
                                      │ hundreds of rides (Monte Carlo)
                                      ▼
                           ┌──────────────────────┐
                           │  FILTER UNDER TEST    │  Stage1: analytical EKF (your code)
                           │  (replay through the  │  Stage2: + RoNIN/TLIO learned baseline
                           │   real Dart pipeline) │  Stage3: learned+filter hybrid
                           └──────────┬───────────┘
                                      ▼
                           ┌──────────────────────┐
                           │  EVALUATION HARNESS   │  metrics: ATE/RTE, drift-during-blackout,
                           │  (metrics + failure   │  NEES/NIS consistency, ZUPT PR, station
                           │   taxonomy + MC rates)│  assoc accuracy, alarm hit-rate + tail
                           └──────────────────────┘
```

The real ride re-enters once more at the end: **cross-validation**. A synthesizer whose fake rides the filter aces, but which fails on the one real ride, is a synthesizer that's lying. The realism gate (§4.2) is what prevents that.

---

## 3. STAGE A — Fix the ground truth before anything else

You cannot evaluate against a reference you don't trust. Build a **three-tier reference**:

### 3.1 Gold (synthetic only)
For synthetic rides, `s(t)`, stop times, and true station indices are known exactly. This is the only reference used for *scoring accuracy*. No real-ride reference is ever used to score sub-meter accuracy — only for realism and sanity.

### 3.2 Bronze (raw taps) — kept only as a sanity band
The manual taps, with an explicit uncertainty of roughly ±[−15, +15] s applied as an interval, never a point. Used only to check that nothing is grossly wrong (filter within the band), never for fine error.

### 3.3 Silver (reconstructed interior reference) — the real contribution
Rebuild a better real-ride reference by fusing sources that don't share the taps' lag:
1. **IMU stop-detection:** rolling accel-variance troughs → candidate dwell intervals (method validated in §1.3).
2. **Station anchors (mostly local):** `lib/all_india_stops.dart` ships **84 Bengaluru stations with lat/lng** (OSM-sourced). A name search covers most ride stations incl. one of the two you missed — **Kadugodi Tree Park matches; Pattanduru Agrahara does NOT** (empty match — likely a name-spelling mismatch, so its coordinate must be fetched/reconciled from OSM in Phase A, not assumed present). `docs/india-metro-data` lists Green/Purple stations in order and DOES name Pattanduru Agrahara, so the ordered sequence is known even where the coordinate is missing.
3. **Schedule / inter-station run times:** fetch from public sources + BMRCL, and cross-check against this ride's own IMU-derived segment times (per your Q3 answer). Use to constrain the *sequence* and reject spurious troughs.
4. **GPS where trustworthy:** surface segments with accuracy < 15 m pin absolute position at segment ends.
Fuse via a forward-backward smoother (offline, non-causal — allowed because this is reference-building, not the live filter) to get station arrival times good to ~1–2 s instead of ~12 s. Store as `route_silver_reference.json` with per-event uncertainty.

**Deliverable A:** `reference_builder.py` + `route_silver_reference.json` + a QA figure overlaying bronze taps, silver reconstruction, and GPS.

---

## 4. STAGE B — The synthesizer (the hard, central part)

The current generator (`imu_replay_engine_v2.dart`, `y += 0.5 + rand*0.3`) is disqualified by **circularity**: it encodes the same motion assumptions the filter uses, so the filter grades its own homework. The replacement is a **forward physics + measured-noise** model, and its realism is *gated* against the real ride's statistics — never hand-tuned to please the filter.

### 4.1 Layered generative model (build bottom-up; each layer independently testable)

**Layer 1 — Kinematics (route → true motion).** Given a prefetched polyline and a per-leg speed profile, generate `s(t), v(t), a(t)` along the route with realistic behaviors: acceleration/cruise/braking per inter-station segment, dwell stops (v=0) with realistic dwell-time distribution, jerk-limited transitions, and mode-specific profiles (walk / metro / bus). This is the part you know exactly → it becomes gold truth.

**Layer 2 — Rigid-body → device frame (the orientation layer, the biggest hidden error source).** Per §1.2 the phone frame ≠ travel frame and *changes mid-trip*. Model:
- A **carry-mode sequence** (in-hand, pocket, bag, on-lap, to-ear) with transition events; each has a characteristic orientation distribution and superimposed motion (walking bounce, pocket sway).
- Time-varying orientation `q(t)` producing gravity projection onto all three axes, calibrated to the **measured 5.5° RMS / 46° peak wobble**.
- **Decision (per your steer): emit RAW device-frame accel + gyro + mag and let the app's own `TiltFilter` estimate gravity — and fail realistically.** This tests the real weak point rather than hiding it. (Gravity leaking into the forward axis from a few degrees of tilt error *is* the killer bias in §1.1.)

**Layer 3 — Sensor error model (fit to your ride).** Add, per the IMU error-model literature (Allan-variance parameters):
- White noise (fit to stationary floor: accel 0.2–0.53 m/s²/axis, gyro 0.12–0.27 rad/s/axis measured).
- Bias instability + random walk (the slow drift that double-integrates into disaster).
- Scale-factor & axis-misalignment errors, gravity-dependent bias.
- **Sample-rate jitter and dropouts** matching measured dt distributions (gyro 57 Hz irregular, occasional 130 ms stalls). This alone breaks naive replay and must be simulated.
- Temperature/battery slow drift over the ~100 min horizon.

**Layer 4 — GPS/GNSS model.** Emit a 1 Hz GPS stream with: accuracy that degrades in urban canyon (measured up to 2700 m), **correlated dropouts** (the 388 s underground blackout; 96 gaps > 5 s), multipath position bias, cold-reacquire glitch on tunnel exit, and speed/bearing fields with their own noise. Dropout boundaries are known → they become labeled test segments.

### 4.2 The realism gate (this is what makes the synthesizer trustworthy)
The synthesizer is only accepted if synthetic rides are **statistically indistinguishable** from the real ride on held-out statistics it was *not* tuned to:
- **Spectral:** Welch PSD of accel/gyro magnitude in walk vs cruise vs dwell windows must match (walking cadence peak, train vibration band).
- **Distributional:** marginal and lag-autocorrelation of each channel; noise-floor histograms.
- **Two-sample tests:** maximum mean discrepancy (MMD) and a classifier-two-sample-test (C2ST) — if a classifier can't tell real from synthetic above chance, the synthesizer passes; if it can, its top features tell you exactly what's unrealistic.
- **Cross-validation:** run the *unmodified app pipeline* on the real ride; its error profile must fall inside the distribution of errors on synthetic rides of the same route. If the real ride is an outlier, the synthesizer is missing something.

**Deliverable B:** `synthesizer/` package (4 layers, seedable), `realism_report.html` (spectra overlays, MMD/C2ST scores, cross-validation), and a corpus of `N` synthetic rides with gold truth.

### 4.3 Where the July-2026 SOTA plugs in (synthesis)
- **CROMOSim (2022, arXiv 2202.10562)** — cross-modality virtual-IMU generation; template for physics+learned synthesis.
- **PIM (2025, 2503.17978)** — physics-informed multi-task pretraining for IMU-based recognition; supports the physics-first stance for Layers 1–3.
- **Diffusion IMU enhancement (2026):** "Overcoming the Intrinsic Performance Limitations of MEMS IMU via Diffusion-Based Generative Learning" (2605.16391) and **PedestrianDiffusion** (2607.03349) — spectral-domain generative models for realistic MEMS noise; candidate for a Layer 3 upgrade beyond analytical Allan-variance noise.
- **Caveat, also 2026:** "Challenges and Limitations of Generative AI in Synthesizing Wearable Sensor Data" (2505.14206) — documents where GAN/diffusion synthetic IMU is *not* realistic. Use learned synthesis only *behind* the realism gate, never in front of it.
- **Approach:** start analytical (physics + Allan-variance noise). Add diffusion noise only if the realism gate (§4.2) flags the analytical noise as distinguishable.

---

### 4.4 Device generalization (cross-phone robustness) — a synthesizer requirement, not a separate project
Target: lose ~no quality regardless of Android/iOS phone or sample rate. Three sub-problems:
1. **Sample-rate heterogeneity — fully solvable.** A canonical resampling front-end (resample every device to one internal rate, e.g. 50–100 Hz, anti-aliased) makes the pipeline rate-invariant. Hard floor = Nyquist: cadence ~2 Hz + train vibration ≤ ~30 Hz, so any phone ≥ ~60 Hz loses nothing meaningful (essentially all modern phones qualify). Requires the front-end so the filter never sees raw device rates.
2. **OS/orientation convention — solvable with a per-platform adapter.** iOS CoreMotion vs Android SensorManager expose differently-filtered/framed signals; map all to one convention (raw device-frame accel + gravity, consistent axes). The app's own internal gravity removal reduces dependence on each OS's fusion.
3. **Intrinsic sensor quality — NOT fully solvable (honest floor).** Cheaper MEMS = higher noise density, larger bias instability, worse scale factor; no algorithm recovers uncaptured information. Achievable guarantee is *graceful degradation*, not zero loss.
**Mechanism (the design consequence):** the synthesizer must **domain-randomize** phone characteristics (rate, noise density, bias, scale-factor, axis misalignment, placement) sampled across the real distribution of phones, so Stage-1 tuning and Stage-3 models are robust to *any* device rather than overfit to the single A059P we captured. This is the analytical version of what 2026 learned SOTA does — **MosaicIMU** (2606.09355, carrier-conditioned MoE) and **Inertia-1** (2607.06617, cross-device foundation model). The eval harness (§5.6) then reports metrics *per device-parameter bin* to prove cross-phone robustness. Cross-phone quality can only be *validated* (not just claimed) once a second real device is captured — until then it rests on domain-randomization coverage.

---

## 5. STAGE C — The evaluation harness (what your current single scalar misses)

Your current evaluation prints one number per tick: `error = ekfS − trueProgress` (ekf_test_controller.dart). That is a start, but it cannot answer "does it work" because it has no aggregation, no consistency check, no failure taxonomy, and no notion of the alarm. Replace it with the following, computed over the whole Monte Carlo corpus.

### 5.1 Accuracy metrics (borrowed from the inertial-odometry benchmarks: RoNIN, TLIO)
- **ATE** (Absolute Trajectory Error): RMS of `s_est − s_true` over the whole ride.
- **RTE** (Relative Trajectory Error): error over fixed time windows (e.g. 60 s) — the standard learned-IO metric; insensitive to a single early offset.
- **Drift-during-blackout:** error growth *rate* (m per 100 s) inside GPS-denied segments — the metric that matters most for your project. Reported separately from surface error.
- **Terminal/arrival error:** `|s_est − s_true|` at each true station arrival.

### 5.2 Consistency metrics (the ones that catch a lying covariance)
A filter can be accurate on average yet **overconfident** — reporting a tight σ while actually wandering. That is what makes an alarm fire early/late with false certainty. Measure:
- **NEES** (Normalized Estimation Error Squared): `(x_true − x_est)ᵀ P⁻¹ (x_true − x_est)`. Over the MC ensemble it must sit inside the χ² confidence bounds for the state dimension. Above → overconfident (P too small); below → conservative.
- **NIS** (Normalized Innovation Squared): same test on GPS/station innovations — computable *without* truth, so it also works as an online health monitor.
- **Bias observability:** track the estimated accel bias `b` vs the synthetic true bias — does the filter actually converge it, or is `b` unobservable during long GPS gaps (it usually is, which is *why* drift leaks)?
Only synthetic data can compute NEES (needs exact truth) — another reason the synthesizer is load-bearing.

### 5.3 Event-detection metrics (ZUPT & station association — the resets that §1.1 proved are everything)
- **ZUPT detector:** precision/recall/F1 against gold stop intervals; false-ZUPT-while-moving rate (a false ZUPT injects a hard velocity error); missed-stop rate. Sweep the detector thresholds (your `zuptVar`, `vThresh`, durations) → ROC curve.
- **Station association:** confusion matrix of snapped-station vs true station; adjacent-station mis-snap rate; snap-to-wrong-line rate at interchanges (Majestic Green→Purple transfer is the known hard case).

### 5.4 The product metric — alarm hit rate (with the tail, not just the mean)
For "wake me N stops before my stop":
- **Alarm lead error:** distribution of (alarm-fire time − ideal-fire time) across all MC rides.
- **Hit rate:** P(alarm fires within the acceptable window) — and its complement split into **early misses** (annoying) vs **late/no-fire misses** (product-fatal, the user misses their stop).
- **Tail focus:** report P95/P99 and the catastrophic-failure rate, per failure mode. For an alarm, a 2% "sleeps past the stop" rate is a product killer that a 40 m mean error completely hides.

### 5.5 Failure-mode taxonomy (enumerate, then measure the rate of each)
Run the MC corpus, auto-classify every failed ride into: (a) missed ZUPT → unbounded drift; (b) false ZUPT while moving; (c) station mis-association / interchange confusion; (d) GPS reacquire glitch on tunnel exit throwing a large innovation; (e) express/skip-stop schedule mismatch; (f) carry-mode-change transient; (g) orientation/tilt divergence leaking gravity into forward axis. Output a **Pareto chart of failure causes** — this tells you exactly what to fix first, which no average error can.

### 5.6 Statistical rigor
- **Monte Carlo:** ≥ 200 rides per route per condition; report means with bootstrap 95 % CIs, not point estimates.
- **Seed control:** every ride reproducible from a seed (your code already seeds `Random(42)` — parametrize it).
- **Ablations:** turn each mechanism off (no ZUPT, no station-snap, no GPS-degradation detection) to quantify its individual contribution — this is how you *prove* each component earns its place.
- **Route diversity:** the 6 built-in test routes + procedurally varied ones (different #stops, interchange counts, blackout lengths).

**Deliverable C:** `eval_harness/` (metrics library, MC runner, failure classifier) + `evaluation_report.html` (all metrics, consistency plots, ROC/PR curves, alarm hit-rate, failure Pareto).

---

## 6. The three staged filter targets (per your "work sequentially through every option")

### Stage 1 — Harden the analytical EKF (fastest to results, no ML)
Wire the synthesizer + harness to your **existing Dart pipeline** (`SensorFusionManager → EkfOrchestrator → EkfPipeline`; note `_enableEkf` currently defaults false — the harness flips it on). Then:
- Use §5.5 Pareto to find the dominant failure mode; fix tuning/logic (your EKF already has Huber robust GPS gating at ekf_pipeline.dart:250 — good; check ZUPT thresholds, station-snap σ-gate=30 m, bias limits).
- Add an **adaptive process-noise / bias-observability** improvement if NEES shows overconfidence during blackouts.
- Re-run; show the failure Pareto shrink. **This is where you get the biggest win for least effort.**

### Stage 2 — Benchmark learned inertial odometry on identical data (future-proof)
Because the synthesizer emits RoNIN/TLIO-format data with gold truth, you can train/test learned models on the *same* rides:
- **RoNIN (2019, arXiv 1905.12853)** — the benchmark & regression architectures; the reference point.
- **TLIO (2020, 2007.01867)** — learned displacement + EKF, the closest match to your hybrid goal.
- **IONet (2018, 1802.02209)** — the original "cure the curse of drift."
- **July-2026 currency:** **MosaicIMU** (2606.09355, carrier-conditioned MoE for cross-carrier generalization — directly relevant since walk/metro/bus are different "carriers"); **Delta-position MLP/KAN** (2606.25454, incremental-displacement formulation avoids constant-offset errors); **Inertia-1** (2607.06617, open wearable-motion *foundation model* — candidate pretrained backbone). Run these as **baselines on your synthetic + silver-referenced real ride**, model-agnostic metrics from §5.

### Stage 3 — Learned + filter hybrid (TLIO-style, current SOTA robustness)
Treat the hardened analytical EKF as the baseline to beat:
- A neural network regresses **displacement over short windows + its uncertainty**; feed that as a measurement into your EKF (exactly the TLIO recipe), replacing or augmenting hand-tuned ZUPT.
- Learned ZUPT (LSTM-based, 2018, 1807.05275) as a drop-in for the threshold detector — far more robust to carry-mode changes (§1.2).
- **Uncertainty calibration matters:** use §5.2 NEES/NIS to verify the learned uncertainty is honest; 2026 work **MUSE** (2605.17421) and **PedestrianDiffusion** (2607.03349) specifically target calibrated/uncertainty-aware state estimation — adopt their calibration tests.
- **Compute budget (per your Q4 answer): generous — large models OK for now; generalize/optimize for on-device later.** So Stage 3 can use a large backbone (e.g. Inertia-1-derived) first, then distill/quantize for the phone as a separate optimization pass.
- Needs training data → this is *why* the synthesizer must be excellent first.

---

## 7. Build order & milestones

| Phase | Deliverable | Proof it worked |
|---|---|---|
| 0. Data hygiene | loader that fixes the (0,0,0) row, aligns 57 Hz gyro to 100 Hz accel, uses `TotalAcceleration` (raw) | replay of real ride reproduces logged behavior |
| A. Reference | `route_silver_reference.json` + QA fig + rail alignment from OSM | station times good to ~1–2 s vs ~12 s taps |
| B1. Synth (analytical) | 4-layer synthesizer, seedable | realism gate: C2ST ≈ chance on held-out stats |
| B2. Realism report | spectra/MMD/C2ST + real-ride cross-val | real ride inside synthetic error distribution |
| C. Harness | metrics + MC runner + failure classifier | full report on 200+ rides/route |
| S1. EKF hardening | failure Pareto → fixes → re-run | dominant failure-mode rate drops, NEES in-bounds |
| S2. Learned baselines | RoNIN/TLIO/MosaicIMU on same data | head-to-head table, analytical vs learned |
| S3. Hybrid | learned displacement + EKF | beats hardened EKF on blackout drift + alarm tail |

---

## 8. Open questions — answered this session

1. **Which acceleration channel does the app feed the EKF? RESOLVED.** `ekf_orchestrator.dart:695-699` feeds **raw accelerometer** and removes gravity *internally*: `ax = sample.ax - g[0]*9.81`, `g = tiltOutput.gravityDevice`. Consequences: (a) the synthesizer emits **raw device-frame accel with gravity included**; (b) faithful replay uses **`TotalAcceleration.csv`**, NOT the gravity-removed `Accelerometer.csv` (double-removal bug). Confirms the orientation decision.
2. **Magnetometer / heading? RESOLVED.** No standalone magnetometer stream, but `Orientation.csv` carries the OS-fused quaternion (qx,qy,qz,qw) + roll/pitch/yaw. Heading is *not* an EKF state (filter is 1D-progress), so no gap. Synthesizer emits raw IMU for the TiltFilter; can optionally emit fused orientation for comparison.
3. **Metro schedule source? ANSWERED — fetch public + BMRCL + check IMU.** Station coordinates already ship locally (84 BLR stations in `all_india_stops.dart`). Inter-station run/dwell times: fetch from public sources + BMRCL, cross-checked against this ride's IMU-derived segment times.
4. **On-device budget for Stage 3? ANSWERED — generous.** Large models OK now; generalize/optimize for phone later as a separate pass.
5. **Route geometry? ANSWERED — real rail alignment.** Fetch Green/Purple track geometry from OpenStreetMap (Overpass access granted) and project progress onto the actual rail path for metro legs.
6. **Other real rides? ANSWERED — only this one exists.** n=1 stands; the synthesizer is the answer to it.

---

*Sources (arXiv, retrieved & title-verified this session, current to 2026-07-09): RoNIN 1905.12853 · TLIO 2007.01867 · IONet 1802.02209 · CROMOSim 2202.10562 · LSTM-ZUPT 1807.05275 · PIM 2503.17978 · GenAI-wearable-limits 2505.14206 · MosaicIMU 2606.09355 · Delta-pos MLP/KAN 2606.25454 · MUSE 2605.17421 · Diffusion-MEMS 2605.16391 · PedestrianDiffusion 2607.03349 · Inertia-1 2607.06617. Diagnostics computed from docs/Sandalsoap-whitefield/ this session.*
