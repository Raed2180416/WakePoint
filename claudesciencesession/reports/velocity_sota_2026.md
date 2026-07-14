# Learned Inertial Velocity — SOTA & Circularity-Breaking Verification (July 2026)

**Context.** WakePoint dead-reckons underground by regressing along-route speed from 8
phone-independent IMU features (accel percentiles, 3–8 Hz / 8–20 Hz band energies, gyro
stats) and fusing it as a 1-D EKF velocity pseudo-measurement during GPS blackout. Current
model: `HistGradientBoostingRegressor`, held-out **MAE 1.52 m/s, R²=0.84, synthetic-only**.
**The circularity problem:** the synthesizer's vibration amplitude is speed-driven, so the
regressor may be *inverting its own generator* rather than learning a transferable IMU→speed
map. Only n=1 real ride exists. This doc gives (a) the verified SOTA landscape, (b) a
concrete circularity-breaking verification protocol, (c) a fail-safe uncertainty fusion.

All arXiv IDs below were verified via `arxiv_get_papers` (a deliberate fake ID and an
unrelated control both returned correctly, so titles are not confabulated). **0 not-found.**

---

## (a) SOTA landscape (verified arXiv IDs)

### Learned inertial velocity / odometry

The dominant paradigm regresses **displacement (or velocity) *plus* a covariance head** from
short IMU windows and fuses it in a Kalman filter — exactly WakePoint's shape, and the source
of the key SOTA upgrade (a *learned, input-dependent* velocity variance instead of a fixed
`vel_var=4.0`).

- **TLIO (2007.01867, 2020)** — the archetype. A network regresses 3-D displacement **and its
  covariance** from IMU windows; fused in a tightly-coupled stochastic-cloning EKF for
  IMU-only state estimation. WakePoint's velocity-pseudo-measurement fusion is the 1-D case of
  this. Take the covariance head.
- **RoNIN (1905.12853, 2019)** — velocity regression benchmark; robust to device pose /
  attachment by resolving IMU into a **heading-agnostic frame**. This is the principled version
  of "phone-independent features."
- **EqNIO (2408.06321, 2024)** — sub-equivariant network regressing displacement **+
  uncertainty** with equivariance to gravity-aligned rotations/reflections → generalization
  across device orientation without hand-crafted invariants. Directly relevant to carry-mode
  robustness.
- **AirIO (2501.15659, 2025)** — identifies **body-frame velocity** as the learnable quantity
  for highly-dynamic (UAV) motion where pedestrian priors fail; explicit velocity target.
- **Neural IO from Lie Events (2505.09780, 2025)** — neural displacement priors that
  **generalize across IMU sampling rates and trajectory profiles** — the exact failure mode a
  synth-trained model risks; addresses profile over-fitting.
- **GNIO (2603.15281, 2026)** — gated network handling **micro-drift during stationarity** and
  **mode fusion at motion transitions** — mirrors WakePoint's dwell/ZUPT + cruise handoff.
- **X-IONet (2511.08277, 2025)** — cross-platform network (pedestrian ↔ legged) showing models
  "degrade severely" off their training platform — the generalization gap made explicit.
- **MosaicIMU (2606.09355, 2026)** — newest; mixture of **carrier experts** for
  cross-platform generalization. The frontier answer to "one model, many carriers/carry-modes."
- **UNRIO (2604.13584, 2026)** — **uncertainty-aware ego-velocity learning** from raw signal;
  the closest analog to "regress velocity + calibrated uncertainty for filter fusion."

**How they quantify uncertainty:** a covariance/uncertainty head co-trained with the point
estimate (TLIO, EqNIO, Lie-events, UNRIO), whose output is consumed as the measurement noise
`R` in an EKF/MSCKF. WakePoint should replace the fixed `vel_var` with such an input-dependent
variance — this is both the SOTA move and the fail-safe hook (§c).

### Sim-to-real for inertial models (virtual-IMU)

- **CROMOSim (2202.10562, 2022)** — a deep-learning **cross-modality IMU simulator** (per its
  title, retrieved and verified). It is the canonical "learn to synthesize IMU" reference and the
  natural sim-to-real anchor; I confirmed the ID/title but its full abstract could not be
  re-fetched this session (arXiv API timeouts), so treat the specific validation-mechanism detail
  as to-be-confirmed against the paper before citing it as method.
- **IMUGPT / IMUGPT 2.0 (2305.03187, 2023 / 2402.01049, 2024)** — virtual IMU from text/video.
  Two load-bearing findings: (i) synthetic must be **mixed with a small portion of real** data;
  (ii) **filtering unrealistic synthetic samples** materially improves transfer.
- **Scaling HAR (2506.07612, 2025)** — direct comparison of virtual-IMU generation strategies
  (video- vs language-based) against classical augmentation, evaluated on **real** benchmark HAR
  datasets; finds **virtual IMU data significantly improves accuracy over real-or-augmented data
  alone, especially under limited data**. Evidence that a well-built synthetic corpus is a strong
  prior — but note this is HAR *classification*, not a speed-regression gap measure, so treat it
  as motivation, not proof, for WakePoint.
- **Diffusion-based MEMS IMU (2605.16391, 2026)** — a conditional diffusion model that
  **upgrades low-cost IMU to high-fidelity "virtual high-grade" IMU** (high-grade measurements as
  priors, low-cost as conditional input), improving downstream positioning/attitude — a
  *denoising*, not a noise-injection, technique. Relevance: a route to enhance raw phone IMU
  before feature extraction, not a synthesizer error model.

**The standard synth-validation protocol these papers share:** train on synthetic, **test on
held-out real** (leave-real-out) to measure the true gap; **align synthetic vs real feature
distributions**; **domain-randomize** nuisance factors; report a **few-shot real** curve. This
is the backbone of the protocol in §b.

---

## (b) Circularity-breaking verification protocol for WakePoint

The generator couples vibration amplitude to speed, so a regressor can score well on synthetic
by learning `amplitude → speed` — a shortcut that *will not* survive on real rails (real
amplitude depends on track roughness, carriage, suspension, load, joint spacing). Physics that
*does* transfer lives mostly in the **frequency domain**: the rail-joint passing frequency
`f = v / spacing` (0.3–1.5 Hz, confirmed) and the 3–8 Hz carriage band. The protocol below is
ordered by decisiveness; run 1–2 first.

1. **Generator-inversion ablation (decisive).** Regenerate corpora that **decorrelate the
   amplitude↔speed coupling**: (A) current (amplitude ∝ speed); (B) amplitude driven by an
   *independent* latent (track roughness / carriage) with the speed→amplitude gain randomized
   per ride. Train on a coupling-randomized mix; test on B-style held-out **and** the real ride.
   If accuracy survives when amplitude is no longer a reliable speed cue, the model uses real
   structure, not the generator's fingerprint. This is the single test that most directly
   refutes circularity.

2. **Amplitude-whitening / frequency-only ablation.** Per-ride **normalize (whiten) amplitude**
   and retrain using only frequency-domain features (band energies, joint-passing frequency,
   spectral centroid). If speed is still recoverable, the signal is a *frequency* cue
   (real physics: `f = v/spacing`), not the generator's amplitude gain. Also run per-feature
   drop-one ablations — if `a_p90` alone carries the model, that is the generator signature.

3. **Leave-real-out evaluation (the only true gap measure).** Train on synthetic, report
   MAE / R² / calibration on the **held-out real ride(s)** — the IMUGPT/Scaling-HAR standard.
   Publish the real-minus-synth MAE gap as the headline honesty metric. Prioritize collecting
   ≥5–10 real rides; n=1 supports calibration checking but not a real test set.

4. **Synthetic-vs-real distribution alignment (classifier two-sample test).** Train a
   classifier to distinguish synth from real on the 8 features. **AUC ≈ 0.5 ⇒ indistinguishable
   (good); AUC → 1.0 ⇒ the generator is unrealistic** and synth accuracy won't transfer.
   Report per-feature MMD / KS distance to pinpoint which features are unrealistic and must be
   fixed in the synthesizer.

5. **Domain-randomization sufficiency.** Randomize generator nuisances (carry mode, phone
   orientation, track gradient, joint spacing, gain) and show accuracy is **invariant** to them.
   Invariance ⇒ the model keys on transferable structure, not a fixed generator config.

6. **Independent physics cross-check.** Integrate predicted velocity → displacement and compare
   to the **known inter-station arc-length** from `rail_geometry.json` — a constraint the IMU
   generator never injected. Optionally cross-check speed-driven bearing-rate against rail
   curvature. Agreement is evidence from a channel the generator cannot fake.

7. **Few-shot real fine-tuning curve.** Plot real-test MAE vs amount of real data mixed in. A
   small amount collapsing the gap ⇒ synth is a sound prior; a gap that never closes ⇒ synth is
   misleading and must be re-derived.

8. **Fail-safe calibration on OOD.** On real and deliberately-OOD inputs (novel carry mode,
   speed faster than trained), verify the prediction interval (§c) **covers at the nominal rate
   and widens on OOD**, that the fused EKF `sigma` inflates, and that the alarm fires **early,
   not late** (track NEES on real). Passing 1–4 refutes circularity; 8 proves the failure mode
   is safe.

---

## (c) Recommended uncertainty-aware fail-safe fusion

**Goal:** an out-of-distribution IMU window (real vibration unlike synthetic) must yield a
**wide, calibrated velocity interval** so the EKF inflates `sigma` and the alarm fires early —
never a confident wrong point.

**Recommendation: Conformalized Quantile Regression (CQR, 1905.03222) wrapped in Adaptive
Conformal Inference (ACI, 2106.00170), with a deep-ensemble / quantile-gradient-boosting base.**

- **CQR** replaces the fixed `vel_var=4.0` with an **input-adaptive interval** whose width grows
  where the model is uncertain, while retaining conformal prediction's distribution-free,
  finite-sample coverage guarantee (2107.07511). `HistGradientBoostingRegressor` already
  supports quantile loss, so lower/upper quantile heads + a conformal calibration set is a small
  change to the existing model.
- **Epistemic widening on OOD:** a **deep ensemble (1612.01474)** (or GBR quantile ensemble)
  disagrees on inputs unlike training data; that disagreement inflates the interval on
  unfamiliar real vibration — the desired fail-open behavior. (Deep Evidential Regression,
  1910.02600, is a cheaper single-pass alternative but is known to mis-calibrate; prefer
  conformal calibration on top of whatever base.)
- **Handle the synth→real shift honestly at calibration:** the calibration set is real, the
  training set synthetic — a **covariate shift**. Use **weighted conformal prediction
  (1904.06019)** to re-weight the (few) real calibration residuals by the synth→real likelihood
  ratio, and **ACI (2106.00170)** to maintain coverage *online* as the distribution drifts
  entering the tunnel. ACI is the piece that keeps the guarantee valid under the exact
  non-stationarity WakePoint faces.

**Fusion mechanics:** from the calibrated interval half-width `h` (at level α), set the EKF
measurement variance `vel_var = (h / z_α)²` (map the interval to a Gaussian `R`), matching how
TLIO/EqNIO feed a learned covariance into the filter. Wide interval → large `vel_var` → EKF
down-weights the velocity pseudo-measurement → the route/reference-sigma prior dominates →
`sigma` inflates → **alarm fires early = safe**. This closes the loop: the uncertainty channel
that verification test 8 audits is the same channel that makes an OOD real ride fail safe rather
than fail silent.

---

*Sweep: `arxiv_search` + `arxiv_get_papers` via the literature MCP, July 2026. Every ID above
was fetched and confirmed; the tool's not-found list was exercised with a control and returned
correctly.*
