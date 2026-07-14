# WakePoint — Real-World Scenario Research (consolidated)

Verified as of 2026-07-09. Three tracks researched in parallel; **every arXiv ID was verified** via `arxiv_get_papers` (records returned, exact title match). Consolidated from child-agent artifacts.


## Table of contents

1. ETA + Alarm-Trigger Decision Theory

2. Pedestrian PDR + Mode-Transition Detection

3. Localization under Degraded GNSS



---

# ETA + Alarm-Trigger Decision Theory

**Scope:** turning the 1D-progress EKF posterior (arc-length `s`, velocity `v`, with covariance) on a KNOWN prefetched route into (i) an arrival-time distribution, (ii) a *fire/no-fire* decision that bounds "wake late" probability under asymmetric cost, for all 4 alarm modes: **N stops**, **N minutes**, **X distance**, **X time**. Currency verified to 2026-07-09.

---

## (i) Arrival-time + confidence interval from uncertain 1D (position, velocity) + schedule

On a known route the state collapses to scalar arc-length `s`; remaining distance to target `d = s_target − s`. Three composable ways to get an arrival *distribution* (not a point):

1. **Schedule-anchored segment sum (metro / rail — preferred).** ETA = Σ over remaining segments of (scheduled run time + dwell). Position uncertainty only decides *which* segment/station you are currently in (a discrete index posterior); the schedule supplies the rest. Segment times are near-independent ⇒ variances add (CLT), so ETA ≈ Gaussian with mean = schedule sum and variance = Σ segment-time variances + the between-station index uncertainty. This is the standard transit formulation and is what BusTr (2007.00882) and the bus-arrival models (2003.10373, 2210.00733, 2303.15495, and the 2025 NN model 2501.10514) all reduce to.
2. **Ratio propagation (road / non-metro).** ETA = `d / v`. A ratio of two Gaussians → propagate `σ_s, σ_v` with the **delta method** or an **unscented transform** (3 sigma-points, negligible on-device). Gives a closed-form `σ_ETA` when velocity is bounded away from 0.
3. **Monte-Carlo particle push (most honest, cheap in 1D).** Sample `(s, v)` from the EKF posterior, push each sample through the segment/speed model, read off the empirical arrival **CDF**. Directly yields any quantile needed for the fire rule below; ~200 particles is trivial on a phone.

The **industry schema for exactly this output** is the GTFS-Realtime `StopTimeEvent`: predicted `time`/`delay` **plus an `uncertainty` field** (expected error in the delay). Emitting arrival ± uncertainty in that convention gives interoperability and a natural place to store `σ_ETA`.

---

## (ii) Decision theory: WHEN to fire to bound P(wake late), asymmetric cost

**Framing.** Cost of waking *late* (missed stop) ≫ cost of waking *early*. This is a **newsvendor / critical-fractile** problem, not a point-estimate threshold. With under-cost `Cu` (late) and over-cost `Co` (early), the optimal action fires at the **critical fractile** `τ* = Cu/(Cu+Co)`; making late 20× worse than early ⇒ `τ* ≈ 0.95`.

**The mapping "position σ → fire time" (one-sided quantile rule).** Let `TTA` = time-to-arrival, whose distribution comes from (i). Pick an allowed-late probability `ε` (e.g. 0.05). "Wake late" means firing *after* `arrival − lead`. To guarantee `P(late) ≤ ε`, **fire the instant the ε-quantile (fast tail / earliest-plausible arrival) of `TTA` drops to the requested lead** — because once even the optimistic ε-tail is only `lead` away, waiting longer risks lateness with prob > ε. Concretely per mode:

- **N minutes / X time before:** fire when `Q_ε(TTA) ≤ lead`.
- **X distance before:** fire when `P(remaining_distance ≤ X) ≥ 1−ε` (map through the position posterior directly).
- **N stops before:** fire when `P(remaining_stops ≤ N) ≥ 1−ε` — this uses the discrete station-index posterior, and inherits the dwell-count / station-association machinery already in the underground fix.

A wider position σ automatically pushes the fire time **earlier** (the ε-tail reaches `lead` sooner), so the alarm self-adjusts to trade punctuality for safety exactly as uncertainty grows underground — no hand-tuned margins.

**Making the ε guarantee real (distribution-free + drift-robust).** The EKF's own σ is not trustworthy underground, so a Gaussian quantile can silently under-cover. Wrap the arrival estimate in **conformal prediction** calibrated on real arrival residuals (from GTFS-RT ground truth or user-confirmed arrivals):

- **One-sided / asymmetric conformal** for the late tail only — late and early are not symmetric, so calibrate the upper bound on `TTA` (equivalently the lower bound used in the fire rule). **Conformalized Quantile Regression (CQR, 2202.08756)** and **Relaxed Quantile Regression for asymmetric noise (2406.03258, 2024)** give exactly the asymmetric pinball-loss intervals this needs.
- **Online / adaptive conformal** to hold coverage under nonstationarity (traffic regime, tunnel entry/exit, crowding): **Adaptive Conformal Inference** and **Conformal PID control (2307.16895)** recalibrate the quantile every step so the ε target is maintained even as the base model drifts. This is the key robustness lever for the underground case where EKF covariance is least reliable.
- Conformal sets have been shown to **measurably improve human decision quality (2401.13744, 2024)** — relevant because the alarm *is* an automated decision on the user's behalf.

**Operational guards.** (a) **Hysteresis / latch:** fire once and latch so the alarm doesn't chatter as the estimate wobbles across the threshold. (b) **Hard fallback:** if signal quality collapses, fire at the maximum-plausible-progress bound so a wake is *guaranteed* rather than missed — the asymmetric cost says a false-early beats a silent-late.

---

## (iii) Current (2024–2026) proactive transit-alerting / ETA-under-uncertainty

- **Real-Time Bus Departure Prediction Using Neural Networks (2501.10514, 2025)** — current deep model for schedule-anchored departure/arrival prediction; the point-estimate backbone to conformalize.
- **Relaxed Quantile Regression: Prediction Intervals for Asymmetric Noise (2406.03258, 2024)** — asymmetric prediction intervals, direct fit for the late≫early cost.
- **Conformal Prediction Sets Improve Human Decision Making (2401.13744, 2024)** — evidence that calibrated uncertainty sets improve the kind of act-on-your-behalf decision the alarm makes.
- **GTFS-Realtime `uncertainty` field (ongoing industry standard)** — predicted arrival + uncertainty is already the deployed interchange format; align to it.
- Foundational point-ETA transit models to sit under the conformal layer: **BusTr (2007.00882)**, **BusTime (2003.10373)**, **Dynamic spatial-pattern bus ETA (2210.00733)**, **Real-Time Bus Arrival DL (2303.15495)**.
- UQ foundations: **Conformal prediction for time series (2010.09107)**, **Conformal PID control (2307.16895)**, **Ensemble Conformalized Quantile Regression (2202.08756)**.

---

## Ranked recommendations for WakePoint

1. **Represent ETA as a distribution, not a point.** Monte-Carlo push the EKF `(s,v)` posterior through a schedule-anchored segment-sum model (metro) or `d/v` ratio (road) to get the full arrival CDF on-device (~200 particles).
2. **Fire via a one-sided critical-fractile quantile rule.** Set allowed-late `ε` from the cost ratio (`τ*=Cu/(Cu+Co)`); fire when `Q_ε(TTA) ≤ lead` (minutes/time), `P(remaining_stops ≤ N) ≥ 1−ε` (stops), or `P(remaining_dist ≤ X) ≥ 1−ε` (distance). Wider σ ⇒ earlier fire, automatically.
3. **Guarantee the ε bound with online, asymmetric conformal calibration** (Adaptive CI / Conformal PID) on real arrival residuals, calibrated on the *late* tail only — this is what keeps the promise underground where EKF σ is untrustworthy. Use CQR / relaxed-QR for the asymmetry.
4. **Anchor the mean to schedule / GTFS-RT** (segment sum + dwell); let position uncertainty decide only the current segment. Emit arrival ± σ in the GTFS-RT `StopTimeEvent` convention.
5. **Add hysteresis-latch + hard max-progress fallback** so exactly one wake fires even if the estimator degrades — a false-early is cheap, a silent-late is not.
6. **Implementation:** calibrate offline with **crepes** (conformal predictive systems → full CDF, ideal for the quantile fire rule) or **MAPIE** (`MapieTimeSeriesRegressor`/EnbPI, CQR); ship the precomputed conformal quantiles to the phone. **TorchCP** if the base model is a Torch net.



---

# Pedestrian PDR + Mode-Transition Detection

**Scope for WakePoint:** the walk legs (home→station, platform, station→destination) and the *transitions* between them — boarding, alighting, line-switch — feeding the **same 1D-progress EKF** that already tracks arc-length `s` along a prefetched route polyline. Currency: SOTA as of 2026-07-09, 2024–2026 prioritised. Every arXiv ID below was verified via `arxiv_get_papers`.

---

## (i) SOTA pedestrian dead reckoning for the walk legs (2024–2026)

Three families are usable; all reduce to *distance travelled → project onto the prefetched walk polyline → 1D progress `s`*, so heading only disambiguates direction (the polyline constrains the rest).

- **Classical step-and-heading (SHS) + stop-ZUPT — MVP default.** Step detection + Weinberg/Kim step-length + heading, with velocity-zero pseudo-measurements at true full stops (crossings, platform waits). Cheap, no training, robust to a hand/pocket phone. This reuses our existing motion-gated ZUPT verbatim. **ForestBack** (arXiv:2606.14421, 2026) is a current infrastructure-free, breadcrumb SHS return-nav system — evidence that step-based DR without GPS/beacons is viable for the walk leg.
- **Learned displacement regressor, uncertainty-aware — recommended upgrade.** Regress a short-window displacement + σ from raw IMU and fuse it as an EKF measurement. **TLIO** (tight EKF, displacement+σ into a stochastic-cloning filter) and **RoNIN** are the reference designs; **KISS-IMU** (arXiv:2603.06205, 2026) is the current self-supervised, uncertainty-aware, motion-balanced successor — attractive because it needs no hand-labelled trajectories and emits calibrated σ, exactly the signal our EKF consumes. This *mirrors the velocity regressor we already fuse underground*, so the architecture is unchanged: only the trained head differs (pedestrian displacement vs vehicle velocity). **EqNIO** (equivariant neural IO, 2024) is a robustness option for device-orientation invariance.
- **Attitude / bias handling (our known weak points).** Accel-bias-driven velocity drift (issue #1) is addressed by **Invariant-EKF PDR** (arXiv:2508.11396, 2025) and **learned IMU bias prediction** (arXiv:2505.06748, 2025) — both give more consistent covariance during IMU-only stretches. Heading/tilt error when the phone is reoriented is addressed by the **quaternion-averaging adaptive complementary filter** (arXiv:2607.05451, 2026), directly relevant to our TiltFilter failure mode. **ReLoc-PDR** (arXiv:2309.01646, 2023) shows the anchor-relocalisation pattern we can reuse at the station entrance (a known route node) to reset accumulated drift.

## (ii) Transport-mode + TRANSITION detection (boarding / alighting)

Detecting the *mode* is well-solved; detecting the *transition instant* is the harder, WakePoint-critical part.

- **Mode classification:** **Feature-Pyramid biLSTM** (arXiv:2310.11087, 2023) is a current smartphone-sensor TMD baseline (walk/bus/car/train/subway). **Consistency-based weakly self-supervised HAR** (arXiv:2408.07282, 2024) reduces the label cost — useful since we have little labelled boarding data.
- **Transition instant (the key capability):** frame it as **online change-point detection**, not per-window classification. **"Unify Change Point Detection and Segment Classification in a regression task for transportation mode"** (arXiv:2312.04821, 2023) is directly on-point: it locates *when* the mode changes and labels the segment jointly — precisely the boarding/alighting detector we need.
- **IMU signatures to gate on (our synthesis):**
  - **Boarding (walk→vehicle):** loss of step periodicity + a platform **dwell (ZUPT)** + onset of sustained low-frequency carriage sway/vibration (the 3–8 Hz band already characterised in our carry-vibration model) + the phone often being pocketed/held (a reorientation event).
  - **Alighting (vehicle→walk):** a vehicle **stop (ZUPT)** followed by return of step periodicity and disappearance of the vibration band.
  - **Line-switch:** alight → walk segment → board, i.e. a *sequence* of the above, matched against the prefetched interchange geometry.
  - Confirm every transition with **route context** (are we at/near a station node?) so a bumpy escalator or a bus-stop pause is not mislabelled.

## (iii) Switching the DR model at a transition WITHOUT a position jump

**This is structurally solved by our architecture and should be stated as the headline design decision.** Because WakePoint tracks a *single scalar* arc-length `s` (and `ṡ`) along a known polyline in *one* EKF:

- A mode transition swaps only the **process model** (PDR step-length dynamics ↔ vehicle velocity regressor) and the **measurement model** (which learned head feeds the update). The **state `(s, ṡ)` and its covariance `P` are carried across the boundary unchanged** → there is **no position discontinuity by construction.** A jump is only possible if you run separate per-mode trackers and hand off a position; we never do that.
- At the detected change point, briefly **inflate process noise `Q`** for ~1–3 s to absorb model mismatch during the transition, then relax. This is the map-matched/route-constrained fusion pattern; **floor-plan-assisted PDR** (arXiv:2504.09905, 2025) is the current example of keeping position on a constraint manifold across context changes.
- Handle the **phone-reorientation spike** that coincides with boarding/alighting explicitly: detect the reorientation, boost the attitude filter's process noise (per 2607.05451), and **gate the transient accel spike out of the velocity update** so the model switch itself doesn't inject drift.

---

## OSS
- **TLIO** — github.com/CathIAS/TLIO — tight EKF fusing learned displacement + σ; the template for our learned-PDR-as-EKF-measurement path.
- **RoNIN** — github.com/Sachini/ronin — reference learned-PDR benchmark + data-driven displacement network.
- **ruptures** — github.com/deepcharles/ruptures — production-ready online/offline change-point detection for the boarding/alighting transition detector.
- **SHL dataset** — shl-dataset.org — large labelled smartphone locomotion set (walk/bus/car/train/subway) to train + validate the TMD and transition-timing detector offline.

## Ranked recommendations (WakePoint-specific)
1. **Keep one continuous 1D EKF across all legs**; a mode transition swaps process+measurement models only, state+covariance carried over → position jumps eliminated by design. Inflate `Q` ~1–3 s at each change point.
2. **Transition detector = online change-point** (ruptures / CPD+classification à la 2312.04821) on step-periodicity + 3–8 Hz band-energy features, **confirmed by route context (near a station node) + a ZUPT dwell.** Boarding = periodicity loss + sustained sway after dwell; alighting = periodicity return after a vehicle stop.
3. **Walk-leg model:** ship SHS+stop-ZUPT with polyline projection for the MVP; upgrade to an **uncertainty-aware learned displacement regressor** (KISS-IMU / TLIO pattern) fused exactly like our underground velocity regressor.
4. **Treat the boarding/alighting phone-reorientation as a first-class event:** detect it, raise attitude-filter noise (2607.05451), and gate the accel transient out of velocity — protects our known TiltFilter weak point.
5. **Attack accel-bias velocity drift on walk legs** with honest covariance + optionally InEKF (2508.11396) / learned bias prediction (2505.06748).
6. **Validate on SHL** for transition *timing* accuracy, not just mode accuracy — the alarm depends on catching the alight instant, not the average label.



---

# Localization under Degraded GNSS

**Scope.** The user walks or drives *to* a station before boarding. GNSS is present but **degraded**: urban canyon, multipath/NLOS, sparse or high-latency fixes, occasional dropouts. Unlike the underground-metro case (GNSS *absent*), here we still get fixes — the problem is **trusting them correctly**. Our current filter already applies a Huber gate on the GPS innovation; this track is about doing better, and about exploiting the fact that WakePoint **already has the prefetched route** (a 1D polyline). As of 2026-07-09; all arXiv IDs below verified via `arxiv_get_papers`.

---

## (i) SOTA 2024–2026: smartphone multipath / urban-canyon mitigation

The field has moved from *geometry-only* NLOS exclusion toward **learning the pseudorange error** from raw Android GNSS measurements and toward **sky-aware** rejection.

- **Diff-GNSS (2509.17397, 2025)** — a diffusion model estimates the *pseudorange error distribution* rather than a point correction, giving a calibrated per-measurement uncertainty. Directly usable as a learned, per-fix measurement-noise term.
- **PrNet (2309.12204, 2023)** — a neural net corrects pseudoranges from **Android raw GNSS** (Cn0DbHz, elevation, residuals) on real phones. Establishes that the phone already exposes the features needed to weight each satellite — the same features we can feed a lightweight quality model without any NN.
- **Sky-GVIO (2404.11070, 2024)** — FCN sky-segmentation of an up-facing image classifies each satellite LOS/NLOS. We can't assume a sky camera, but the principle (predict NLOS, then reject/down-weight) transfers to our route+IMU consistency checks.

**Takeaway for us:** the modern move is *per-fix* adaptive weighting driven by phone-reported quality (Cn0, pseudorange σ, AGC, #sats/DOP), not a single global R.

## (ii) Robust weighting / rejection beyond the Huber gate

Huber only *soft-down-weights* the innovation tail; NLOS in a canyon produces **biased** (not just heavy-tailed) fixes that Huber can still let leak in.

- **Graduated Non-Convexity (GNC)** — GraphGNSSLib's smartphone-decimeter pipeline uses GNC to **progressively reject** gross outliers; more aggressive than Huber and avoids local minima of a fixed hard gate.
- **Adaptive FGO tightly-coupled GNSS/IMU (2511.23017, 2025)** and **real-time FGO GNSS/IMU (2603.03556, 2026)** — sliding-window optimization re-linearizes over several epochs, so a single bad fix is outvoted by IMU + neighbours rather than trusted instantly (an EKF's weakness at a dropout edge).
- **Robust state + protection-level estimation, tightly-coupled GNSS/INS (2103.10696, 2021)** — computes an **integrity/protection level**; useful to decide *when to stop trusting GPS at all* and coast on IMU+route (our EKF's honest-covariance handoff).
- **Robust EKF, MEMS IMU land nav (2606.29271, 2026)** — confirms robust-EKF variants remain viable when IMU quality is the binding constraint (our phone case), i.e. FGO is not mandatory.
- **FGO vs EKF for GNSS/INS (2004.10572, 2020)** — the reference "is it time to switch?" comparison; FGO wins accuracy, EKF wins compute/battery. Frames our default-EKF-with-optional-FGO decision.

## (iii) Fusing sparse / degraded fixes with IMU + the prefetched route map

- **GNSS/PDR trajectory smoothing via FGO in urban canyons (2212.14264, 2022)** — pedestrian dead-reckoning + sparse GNSS smoothed in a factor graph; the closest published analogue to our *walking-approach* leg.
- **Smartphone IMU ultra-tight GNSS (2111.02613, 2021)** — IMU aids the GNSS baseband so partial/weak signals still contribute. We won't touch baseband, but it validates IMU-tightening under weak signal.
- **Map as a constraint (our leverage):** because the route is a **known 1D polyline**, we can project every GPS fix onto it and use the **cross-track residual as an NLOS detector** — a multipath fix that lands 40 m off-route is rejected by geometry, not statistics. This is cheaper and more decisive than any filter tuning and is unique to WakePoint's prefetch design.

---

## Ranked recommendations (tied to our 1D-progress EKF on a known route)

1. **Replace the single Huber R with a per-fix adaptive measurement noise** built from Android raw-GNSS quality (Cn0DbHz, reported pseudorange σ, #sats/HDOP, AGC), then **projected onto the route tangent** before the EKF update. Phone-only, no NN, biggest win per unit effort. *(Diff-GNSS / PrNet show the signals matter; Diff-GNSS gives the calibrated-σ framing.)*
2. **Add a map-aided cross-track rejection gate**: project each fix onto the prefetched polyline; if the perpendicular offset exceeds a route-width threshold, **hard-reject** (don't just down-weight). Exploits our known route; catches biased NLOS that Huber passes.
3. **Upgrade rejection from Huber to GNC-style graduated rejection** on the along-track innovation for the residual outliers that survive (2)–(1). Matches GraphGNSSLib's proven smartphone approach without leaving the EKF.
4. **Coast on IMU + route with honest covariance when a protection-level / integrity check trips** (fix count low, DOP high, cross-track large). Reuse the underground-metro handoff logic; (2103.10696) gives the integrity trigger.
5. **Keep EKF as default; prototype a short sliding-window FGO only for the driving leg** if EKF proves brittle at fast fix-dropout edges. Decide with the FGO-vs-EKF trade-off (2004.10572); FGO costs battery/compute, so gate it behind measured need.
6. **Validate on real urban-canyon smartphone data before trusting**: UrbanNav (Tokyo/HK canyons) + our own Sensor Logger walking & driving rides. Report along-track error and false-alarm rate for the wake trigger, not just RMSE.

## Open-source to reuse
- **GraphGNSSLib** — github.com/weisongwen/GraphGNSSLib — FGO GNSS positioning/RTK with **GNC outlier mitigation** (ION GNSS+ 2022 smartphone-decimeter); reference for rec. 3 and for an FGO leg (rec. 5).
- **gtsam_gnss (arXiv 2502.08158, 2025 — id verified via arxiv_get_papers)** — arxiv.org/abs/2502.08158 — GTSAM-based FGO for GNSS incl. **smartphone GNSS+IMU** and robust M-estimator error models; cleanest starting point if we build the sliding-window FGO.
- **Google gps-measurement-tools** — github.com/google/gps-measurement-tools — desktop companion to GNSSLogger for parsing/analysing **Android raw GNSS** (Cn0, pseudorange, AGC); the exact features rec. 1 needs.
- **UrbanNav dataset** — github.com/weisongwen/UrbanNavDataset — labelled urban-canyon localization data (Tokyo, Hong Kong) for rec. 6 validation.
- **RTKLIB** — github.com/tomojitakasu/RTKLIB — reference GNSS engine / RINEX decoding (used internally by GraphGNSSLib).
- **awesome-gnss** — github.com/barbeau/awesome-gnss — curated index of the above and more.

**Bottom line:** we do **not** need to leave the EKF for the approach leg. The highest-leverage moves are (1) a per-fix adaptive R from phone-reported GNSS quality and (2) a map-aided cross-track rejection gate that our prefetched route makes almost free — both beat further Huber tuning. Keep FGO as a measured, driving-leg-only fallback.
