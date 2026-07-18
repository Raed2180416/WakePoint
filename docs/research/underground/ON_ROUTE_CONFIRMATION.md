# On-Route / On-Train Confirmation — Consolidated Research

**Scope.** How accurately can GeoWake tell that the rider is *on the train* (versus driving or walking along the same line), and can the founder's "use the observed speed" idea be made *never-late-safe* and useful? All numbers below are measured on the **two real Bengaluru Purple-line handheld rides** (Nallur↔Vijayanagar and Nadaprabhu/Majestic↔Nallurahalli — same line, opposite directions, a natural cross-validation) unless a source is cited. Analysis scripts live under `/home/raed/geowake_imu_analysis/work/`.

**The one invariant everything is checked against.** Reachability upper bound (`lib/core/reachability/reachability.dart`):

```
s_max(t) = s0_hi + V_LINE · (t − t0)
```

Never-late holds iff `V_LINE ≥ V_true(actual mode)` and every re-anchor `s0 ≥ true progress`. Tightening (stop-anchoring, dwell-subtraction, accel cone) may only ever *reduce* `s_max` — and is safe only when its preconditions provably hold. A missed detection must degrade to the looser bound (fire early), never the tighter one.

---

## 0. Executive summary

1. **On-train-vs-parallel-car is unsolvable from IMU/mode-classification alone.** SHL (the field benchmark) shows Train↔Subway and Car↔Bus are the two most-confused classes and accelerometer-alone cannot separate the motorized modes; best user-independent F1 ever posted is ~88.9% (2020), 2024/2025 editions did not break the motorized ceiling.
2. **Two geometric discriminators *can* exclude a car**, and both are things a surface vehicle physically cannot fake: **G = a sustained, route-correlated GPS outage** (train goes underground/grade-separated; a surface car keeps GPS), and **B = repeated dwell at *station arc-positions* on the line's cadence** (a car stops at lights, not station geometry). On the real rides G produced a single **549 s continuous GPS-dark run** (Nallur) / 123 s (Nadaprabhu); a surface car essentially never loses GPS >~10 s.
3. **Cross-track offset is NOT a standalone discriminator.** On-train is not reliably ~0 m: one ride is tight (median 4.5 m) but the other carries a **persistent +9.8 m registration/multipath bias** with a ~111 s autocorrelation that time-averaging cannot remove. It only becomes reliable (AUC ≥ 0.99) when the parallel road is ≥30 m away — the common killer road hugging a viaduct at 5–20 m defeats it.
4. **Rail-vibration is a non-discriminator on handheld data** — the hand dominates; dwell vibration ≥ cruise vibration (d′ ≈ −0.22). Do not use it in the never-late path.
5. **Boarding *is* detectable** — a dwell→sustained-launch (0.5–1.1 m/s² held 8–17 s) at the first (above-ground) station fired inside the ground-truth bracket on both rides. But it must key on the low-frequency sustained force, station co-location, and the per-station stop *sequence* — not vibration and not walking cadence (both washed out on handheld).
6. **The observed-speed idea splits cleanly:** the founder's literal form (`V_LINE := observed max`) is **PROVEN UNSAFE** (a sample-minimum of the true ceiling → under-bound → late fire). But observed *kinematics* enable a **SAFE accel-limited cone** `s_max = s0 + v0·τ + ½·a_max·τ²` (tighter yet still a valid upper bound), plus safe uses for mode confirmation, DR parameters, and crowd-sourced per-segment `V_LINE` (design-speed-floored).
7. **The accel-cone as first written did not pass its own never-late check** (verifier CONFIRMED intra-window undershoot and an under-margined `a_max`). It is safe *only* with the corrections below (physical-max `a_max ≥ ~2.0`, dwell-gated `v0`, per-tau validation, no unconditional `min`). Net tightening then ~25%, not the advertised 34%.
8. **The safety-gate decision table is the right shape but its first cut had two CONFIRMED late-fire holes**: a highway-speed car in a *road tunnel* parallel to the metro latches G, and any express/RRTS line faster than the hardcoded 28/33 m/s ceilings under-bounds. Fixes: gate-ON must use the line's *real* `VLineTable` ceiling; gate-OFF must over-bound the fastest plausible car; G must require confirmed route progress and be bounded by the parallel road's speed class.
9. **Everything builds on existing repo code** — `snap_to_route.dart`, `gps_health_monitor.dart`, `active_route_manager.dart`, `station_association.dart`/`zupt_detector.dart`, `sensor_fusion.dart` FFT path, and `reachability.dart` (V_LINE table + cone). No green-field subsystem is required.
10. **Bottom line.** We can *confirm on-train* with high confidence via G∨B (near-perfect car exclusion on real data), and we can *tighten* the reachability cone with the accel model — but only after the flagged corrections land; until then the safe default is the untightened mode-max free-run bound, which is never-late by construction.

---

## 1. The problem: the parallel-road killer case

A car on a road parallel to the metro can simultaneously (a) match the route polyline (small cross-track), (b) match metro-band speed, (c) weakly match rail vibration, and (d) fool an IMU mode classifier. So the naive pipeline "classify mode → pick `V_LINE` → tighten" is **unsafe**: it can falsely confirm on-train and tighten the cone below true progress, producing a **late fire** — the one failure GeoWake must never make.

The never-late direction matters. A parallel car that is *faster* than the train only makes the cone fire **early** (safe). The hazard is exclusively: *falsely confirm on-train → tighten → under-bound true progress*. Every design decision below is oriented to that asymmetry.

---

## 2. Discriminator scorecard (measured on real data)

### 2.1 Cross-track (perpendicular) offset — *cheap, always-available GATE only*

Projected every real GPS fix (hacc ≤ 30 m) onto the oriented route polyline with the **same equirectangular projection as `SnapToRouteEngine`** (`work/crosstrack_analysis.py`).

- **On-train |cross-track| is NOT reliably ~0 m.** Nadaprabhu is tight (median 4.5 m, 95th 13.6 m, signed mean −1.5 m → zero-centered). **Nallur is wide with a persistent lateral bias** (median 13.5 m, 95th 60.2 m, signed mean **+9.8 m**, std 10.5 m, |mean|/std = 0.94 → genuinely off-centered). Pooled n=3723: median 9.5 m, 95th 45.4 m.
- **Densifying the polyline to 5 m changed nothing** → this is *not* chord error; it is real GPS registration/multipath bias on the elevated viaduct.
- **Averaging is defeated.** Signed cross-track autocorrelation 1/e time: Nallur **~111 s**, Nadaprabhu ~14 s. Windowed-mean H0 std barely shrinks: 9.9 m (30 s) → 9.2 m (60 s) → 8.2 m (120 s).

**Discriminator power (ROC of a persistent windowed-mean detector; `work/crosstrack_roc.py`).** H0 = pooled real on-train windowed means; H1(car) = H0 + road-track separation D. 60 s window: **D=10 m AUC 0.77** (useless; FPR@TPR0.95 = 0.57), D=20 m AUC 0.94 (FPR 0.24, marginal), **D=30 m AUC 0.99** (FPR 0.04, good), D=40 m AUC 0.9995 (excellent). Single-fix is strictly worse (D=10 m AUC 0.68).

**Verdict.** Reliable only when the parallel road is ≥30 m away **and** the polyline is well-registered. For a road hugging a viaduct at 5–20 m it is unreliable, and a Nallur-style 10 m registration bias collapses even the 20–30 m case. **Cannot stand alone.**

**Never-late role.** Use as a one-directional GATE that *suppresses* IMU stop-anchor tightening when a persistent offset is detected — never to tighten the cone. Suppressing tightening only widens the cone → fires earlier → provably never late. Require a persistent signed offset over ≥60 s, trigger only above ~25–30 m (AUC ≥ 0.99), and auto-calibrate each route's own baseline offset during the first GPS-healthy minute (but never subtract more than the observed on-track spread).

**Builds on.** `lib/services/snap_to_route.dart` (`SnapResult.lateralOffsetMeters` via the same `_projectPointOnSegment`; add signed cross-track = cross product of segment tangent × point vector) → `lib/services/active_route_manager.dart` (already tracks `bestOffset` per candidate) → `lib/services/soft_lock_manager.dart` (extend its 50 m/200 m corridor + hysteresis from a binary gate to a graded persistent-offset confidence). Note the existing 50 m corridor is a valid on-route gate but ~2–5× too coarse to resolve a 10–40 m parallel road.

*Sources:* GPS cannot separate parallel tracks; gyroscope curvature proposed as supplement — https://pmc.ncbi.nlm.nih.gov/articles/PMC11889165/ (2024). Urban-canyon multipath >10 m; 2025 SOTA weighting only reduces horizontal RMSE ~11.6–13.0 m → ~3.8–4.7 m — https://www.mdpi.com/1424-8220/25/15/4678 (2025). GPS-trajectory TMD ~80% with speed/network features (no single geometric cue decisive) — https://link.springer.com/article/10.1007/s11116-024-10472-x (2024).

### 2.2 GPS-drop pattern — *strong, reproducible, route-anchored*

Mapped every declared blind window and raw GPS gap onto ground-truth along-route arc-length `s(t)` (`work/gps_drop_geometry.py`).

- **Blackouts are structural, not random**, and reproduce in *both directions*. Core blind zone in both rides: Majestic ↔ Sir M. Visvesvaraya ↔ Cubbon Park (the ~4 km central underground stretch). Per-segment blind-fraction correlates **r = 0.83** across the 10 shared segments; core segments 90–100% / 100% blind; the elevated eastern half ~0% blind in both.
- **Two on-train signatures.** (1) *Sustained unavailability* in the underground zone: on-train availability only **17%** (ride B) to **51%** (ride A) vs a surface car's ~95%. (2) *Phantom coarseness* — the few fixes that leak underground have median hacc **100 m** (max 336/437 m) vs **9.9 m** on the surface (~10× separation).
- **Honest correction to the original hypothesis:** recovery is **tunnel-mouth-geometry driven, not station-proximity driven** — hacc is flat (~10 m) across all distance-to-station bins because underground stations sit *inside* the blind zone. The predictive unit is the **inter-station SEGMENT**, not "near a station."

**Design.** Ship an **Expected GPS Availability** route prior `a_exp(s) ∈ [0,1]` per inter-station segment, obtained (in priority order): (1) OSM cold prior — tag segments overlapping `tunnel=yes` ways or connecting `location=underground` stations as expected-blind (zero ride history; the common case); (2) self-learned as a **LOWER-bound envelope** of availability from past rides (proven learnable: r=0.83 from one reverse ride); (3) bootstrap from the first ride. Emit a **surface-mode vote** when observed availability stays HIGH (>0.5) **and** hacc stays LOW (<25 m) through a whole expected-blind segment — a signature the on-train data never produces.

**Discriminator power.** Strong (availability margin ≈ 0.6, hacc ~10× separation), reproducible, direction-invariant on this line. **Limitation:** N=2 rides, one line; per-line generalization needs the OSM cold prior or ≥1 historical ride, and the **surface false-positive rate is unmeasured** (no parallel-car fixture exists) — the ~95% surface figure is physically reasoned, not measured. Validate against a real parallel-road drive before enabling any tightening.

**Never-late (by construction).** This prior feeds ONLY discretionary on-train tightening, as a confidence gate. GPS *persisting* through an expected-underground segment reduces on-train confidence → reduces tightening → looser cone → earlier fire (safe). Two guardrails: (a) store `a_exp` as a lower-bound availability envelope (can only *withhold* tightening, never add it); (b) **never** use the prior to distrust a real accepted on-route low-hacc fix ("we expect tunnel here so ignore this fix") — a gate-passing fix always resets the reachability clock regardless of `a_exp` (preserves precondition iii).

**Builds on.** `gps_health_monitor.dart` (add `expectedAvailability(s)` + a directional anomaly flag: unexpected-persist = surface vote, unexpected-drop = confirms underground; existing 25 s / 50 m thresholds capture the raw dropout, this contextualizes them). `snap_to_route.dart` provides per-fix `s` and hacc-vs-route. `active_route_manager.dart` holds the `a_exp(s)` table alongside the station list. `ekf_orchestrator.dart` already rejects off-route phantoms ("138 off-route phantoms on the real ride") — the high-hacc-in-tunnel finding validates that path; add the dual rule "LOW-hacc fix inside an expected-underground segment = surface anomaly." `sensor_fusion.dart` E1 combined with `a_exp` distinguishes "silent because underground (expected, keep DR)" from "alive because surface (anomalous)."

*Sources:* Context-aware GNSS uses satellite count/DOP/C-N0 as environment indicators — https://doi.org/10.3390/engproc2025088014 (2025). 3D-mapping-aided (3DMA) GNSS / shadow matching predicts per-location satellite visibility — https://link.springer.com/article/10.1007/s10291-025-01962-1 (2025). Graph-Transformer GNSS visibility prediction in urban canyons — https://navi.ion.org/content/71/4/navi.676 (2024). Sky-visibility estimation classifies rail above/underground context — https://link.springer.com/article/10.1007/s10291-020-0973-5 (2020). TMD review: 'train' (subway) intermixes with car/bus — https://www.mdpi.com/1424-8220/24/22/7369 (2024). GNSS-independent (magnetometer) TMD motivated by underground GNSS disruption — https://www.sciencedirect.com/science/article/pii/S2590198224001672 (2024).

### 2.3 Rail-vibration micro-signature — *do not use*

Handheld phone rail-vibration **does not discriminate** train from a parallel car; the hand dominates the signal. On both rides dwell vibration ≥ cruise vibration (d′ ≈ −0.22; cruise/near-station RMS ratio 0.81–0.86; pre-board vib 0.43 ≈ onboard cruise 0.33). **Excluded from the never-late path.** Use stop pattern and along-route position instead.

### 2.4 Boarding / alighting detection — *the state transition that enables tightening*

Core question — "is the initial launch from the first station detectable on the real rides?" — answered **YES**, but only with a *sequence*-based detector (`work/boarding_sm.py`).

- **Nallur:** station-0 arrival t=45.4 s → quiet dwell → **launch onset t=64.1 s**, duration 17.2 s, peak |a_long| 1.12 m/s², SNR vs pre-board handling **4.5×**.
- **Nadaprabhu:** arrival t=12.7 s → dwell → **launch onset t=33.9 s**, duration 11.2 s, peak 0.84 m/s², SNR **3.0×**.
- Both first launches fall inside the [arrival0, arrival1] ground-truth bracket. GPS is available at the first (above-ground) station, so the launch can be station-co-located.

**Two honest failures shaping the design.** (1) A **vib-gated** launch detector MISSED Nadaprabhu's real launch (fired at t=399 s instead of 34 s): high-freq rail vibration does *not* co-occur with the launch — the train is still slow; vib rises later at cruise. The gate must key on the **low-frequency sustained force**, not vibration. (2) The classic "walking cadence ~2 Hz" signature is **washed out** on handheld: gait-band (1.2–2.6 Hz) power ratio is 0.24 pre-board / 0.22 cruise / 0.21 post-alight — statistically indistinguishable (in-hand fiddling mimics gait). So **alighting-via-gait-resumption is unreliable**; infer alighting from the final brake→dwell + reappearance of a valid surface GPS fix at the destination (which re-anchors reachability anyway).

**Design — a `BoardingGate` state machine** that ENABLES/DISABLES stop-anchoring & topology tightening, defaulting to the loose (safe) free-run bound:

- `PRE_BOARD → DWELL_AT_STATION`: rider co-located with a station arc-position (via snap; first station above-ground) AND sustained |a_long| quiet (<0.30 m/s² for ≥4 s).
- `DWELL → LAUNCH → ONBOARD` (**boarding confirmed**): sustained |a_long| ≥ **0.45 m/s²** held ≥**8 s** begins within ~40 s after the dwell, at that station. Use magnitude (sign is weakly determined on handheld, GPS-dv/dt corr ≈ 0.05–0.09) and the *dwell-BEFORE* ordering to distinguish a launch from a brake (brake = same force, dwell-AFTER).
- `ONBOARD` maintenance: keep the gate TRUE only while each subsequent expected station produces brake→dwell→launch; if a station's stop-sequence is missed within a window, **REVERT to `PRE_BOARD`** (free-run bound). Monotone-safe fallback.

**Discriminator power.** vs WALKING: strong (launch gate fired 0/40 synthetic walk, 0/40 still; SNR 3.0–4.5×). vs PARALLEL CAR (the killer): pure IMU insufficient and **not device-proven** (fixtures contain no stop-and-go parallel car; the synthetic car is steady-state and under-tests the danger). The real discriminator is **geographic**: dwell→launch must be co-located with a known station arc-position and must *repeat at each station* — a traffic-light-paced car does not phase-lock to metro station arc-positions.

**Never-late.** Monotone-safe ENABLE on tightening only. While boarding is unconfirmed (or reverted), `dwellMinSeconds = 0`, IMU stop-anchoring ignored → estimator falls back to pure free-run with `V_LINE = max` over plausible modes. Only a positive, station-co-located confirmation activates the topology cap. Every missed boarding fires early; the *only* late-fire path is a false-positive confirmation → tune for precision and require station co-location + per-station repetition.

**Builds on.** `active_route_manager.dart` `onStationSnapConfirmed` (§24.2 monotonic, σ≤30 m gate) is the co-location anchor. `reachability.dart` `ReachabilityConfig.dwellMinSeconds` + `ReachabilityTracker` is the topology-cap lever the gate toggles (0 ↔ per-line d) — no new reachability math. `sensor_fusion.dart:112` `setFftEnabled` (already wired through `ekf_orchestrator`) computes the 0.05–0.4 Hz sustained-force (launch) and 1.2–2.6 Hz gait-band features. `snap_to_route.dart` `lateralOffsetMeters` for co-location tolerance.

*Sources:* Subway arrival/departure from linear-accel sustained decel/accel — https://dl.acm.org/doi/pdf/10.1145/3307334.3328635 (2019). MetroEye HMM over stop/dwell/move + timetable, ~96% stop detection — https://tik-old.ee.ethz.ch/file/365ee27a42f71d6b5cd7212571f7185b/mobiquitous16-gu.pdf (2016). SVM-HMM / change-point vehicle-stop detection — https://www.researchgate.net/publication/301564508_Classification_Algorithms_for_Detecting_Vehicle_Stops_from_Smartphone_Accelerometer_Data (2016). "Walk as transition" trip segmentation — https://arxiv.org/pdf/2312.04821 (2023). PELT/change-point mode-transition detection (SOTA) — https://link.springer.com/article/10.1007/s11116-024-10472-x (2025). Train vs car hard from motion; geographic distance-to-rail is the disambiguator — https://www.sciencedirect.com/science/article/pii/S2590198224001672 (2024). SubwayPS station-stop patterns + line map for GPS-free positioning — https://arxiv.org/pdf/1904.01675 (2019).

### 2.5 Mode classification (IMU) — *coarse prior only, never the on-train gate*

Per current SOTA the on-train-vs-metro-speed-parallel-car call is **unsolvable by an IMU mode classifier alone**. SHL (8 classes: Still/Walk/Run/Bike/Car/Bus/Train/Subway) shows the motorized modes are the confusable cluster: **Train↔Subway and Car↔Bus are the two most-confused pairs**, and accelerometer-alone is explicitly insufficient — it is *location/map* data that supplies the discriminating power. On the real rides, measured naive cues fail: vibration-at-speed is inverted (d′=−0.22), raw threshold stop-detection is noisy (matched 11/14 & 6/11 interior stations with 37 & 32 between-station false stops), and only **GPS-outage-while-progressing** is clean (30% / 12% of the two rides advanced with zero GPS while position kept moving — a surface car cannot fake this).

**Verdict.** Keep the coarse still/walk/car/train tree (`work/classify.py` + `mode_tree.pkl`) as a mode prior; **do not rely on it for on-train confirmation.** Gate tightening on geometry (G + B), not mode class.

**Discriminator power summary:**

| Discriminator | Separates on-train from parallel car? | Real-data evidence | Never-late use |
|---|---|---|---|
| Cross-track offset | Only if road ≥30 m away & polyline well-registered | AUC 0.77 (D=10 m) → 0.99 (D=30 m); Nallur +9.8 m bias | GATE that *suppresses* tightening |
| GPS-drop / `a_exp(s)` | **Yes, strong** (structural, r=0.83 both directions) | avail. 17–51% vs ~95% surface; hacc 100 m vs 9.9 m | On-train confidence (not position) |
| Rail-vibration | **No** (hand dominates) | d′ = −0.22; dwell ≥ cruise vib | **Excluded** |
| Boarding (dwell→launch) | Weak on IMU alone; **strong when station-co-located** | launch SNR 3.0–4.5×; 0/40 walk/still FP | ENABLE gate for tightening |
| Mode classification | **No** at matched speed (SHL ceiling) | best F1 88.9%; Car↔Train residual | Coarse prior only |

---

## 3. SOTA survey (2024–2026) with cited accuracies

**Transportation-mode detection (the ceiling).** SHL is the field benchmark; the 2025 edition moved to a foundation-model track (TimesNet/Chronos/GPT/BERT), results Oct 2025 UbiComp — https://www.shl-dataset.org/challenge-2025/ (2025-10). SHL-2020 best user-independent **F1 = 88.9%** (top-10 avg only 69.5%, 5 s window); Train↔Subway and Car↔Bus most confused; accel-alone insufficient — https://www.frontiersin.org/journals/computer-science/articles/10.3389/fcomp.2021.713719/full (2021). SHL-2024 "missing modalities" edition topped out in the **70–80% F1** band — https://dl.acm.org/doi/10.1145/3675094.3678456 (2024-10). CNN/BiLSTM/attention/transformer hybrids continue with no break past the motorized ceiling — https://arxiv.org/html/2407.11048v1 (2024-07). Ensemble + multisensor fusion reaches F1 ≈ 97.49% (non-perfect; Car↔Train residual) — https://www.researchgate.net/publication/393692736_IMU-Based_Transportation_Mode_Recognition_using_Ensemble_Learning_and_Multisensor_Fusion (2025). SHL-2023 adds GPS reception/location specifically to separate subway/train from surface modes — https://dl.acm.org/doi/10.1145/3594739.3610758 (2023).

**Confirming "on THIS line/vehicle" (what works).** Boarding-action detection via fuzzy inference **91.1–94.0%** (≥87.8% across phone positions) — https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5335990/ (2017). SubwayPS dead-reckoning: **85.8%** station detection, 78% fully-correct trips — https://grouplens.org/site-content/uploads/bhecht_sigspatial2014_subwayps.pdf (2014). London Underground footprint matching: **~90%** departure-station ID with ≥3 stops — https://doi.org/10.3390/s19194184 (2019). Metro-trace accelerometer fingerprinting: up to **~92%** — https://ieeexplore.ieee.org/document/7572080/ (2017).

**Map-matching / parallel-road problem.** Best smartphone map-matching **70–90%** but still needs manual post-processing; inertial cues improve HMM matching — https://www.mdpi.com/2079-9292/14/18/3608 (2025-09). 2024 HMM map-matching (95.3%) names parallel/mixed road sections as the residual failure mode, disambiguated by lateral-offset stability + heading + accuracy-scaled confidence — https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0302656 (2024). Parallel/adjacent-road disambiguation remains open; heading alone does not resolve it — https://www.tandfonline.com/doi/full/10.1080/17538947.2024.2328366 (2024). Repetitive/homogeneous lane geometry needs an explicit ambiguity-resolution step — https://www.tandfonline.com/doi/full/10.1080/17538947.2024.2383479 (2024).

**Integrity / bounding basis (for the reachability cone).** Protection Level = a statistical/geometric bound at a target integrity risk — https://ieeexplore.ieee.org/document/7954172/ (2024). Metro service accel ~1.0 m/s², service/emergency brake 1.0–1.4, comfort 1.1–1.5 — https://link.springer.com/article/10.1007/s40864-015-0012-y (2024). Backward/forward reachable-set analysis on the double-integrator with bounded input (naive reach-sets over-approximate) — https://arxiv.org/pdf/2108.04140 (2024). Tight position bounding trades directly against safety margin — https://insidegnss.com/tight-position-bounding-for-automotive-integrity/ (2024).

**Takeaway.** The literature agrees with the measured data: no single IMU cue separates on-train from a matched-speed parallel car; the discriminating power comes from *geometry/map context* (GPS-availability prior + station-cadence footprint). Design accordingly.

---

## 4. The founder's "observed-speed" idea, rigorously resolved

Scripts: `work/facet_ontrain_reachability.py`, `work/facet_trap_and_cone.py`.

### 4.1 The TRAP — proven UNSAFE

Setting `V_LINE := observed MAX speed` **under-bounds** the true line ceiling. The observed max is a *sample minimum* of the ceiling — it only rises as more track is seen. Both rides only ever observed **21.0–21.6 m/s (76–78 km/h)** yet the Purple design/operational ceiling is **80 km/h = 22.2 m/s**. Concretely, a later fix exceeded the running-max established 60 s earlier **59 times** (Nallur, worst +3.5 m/s) and **100 times** (Nadaprabhu, worst +11.4 m/s); some blind-segment *average* speeds (a strict lower bound on the peak inside) exceeded the pre-window observed max. A train can go faster in an unobserved dark section than while observed → frozen observed-max under-bounds → free-run cone under-shoots → **LATE fire**.

**Conclusion.** `V_LINE` must stay **≥ the true line ceiling** (design speed / shipped dataset), NEVER the observed max. Observed max is only ever a lower witness / mode signal.

### 4.2 The SAFE win — accel-limited reachability cone (with derivation)

Replace `s_max(t) = s0 + V_LINE·t` (which assumes an *instantaneous* jump to `V_LINE`) with a launch ramp:

```
τ* = (V_LINE − v0) / a_max
for τ ≤ τ*:   s_max(τ) = s0 + v0·τ + ½·a_max·τ²
for τ > τ*:   s_max(τ) = s0 + v0·τ* + ½·a_max·τ*² + V_LINE·(τ − τ*)
```

**Why it is still a valid upper bound.** The true trajectory obeys BOTH `v(τ) ≤ v0 + a_max·τ` (bounded accel) and `v(τ) ≤ V_LINE` (ceiling), so `v(τ) ≤ min(v0 + a_max·τ, V_LINE)`; integrating gives `s_true(τ) ≤ s_max(τ)` **provided** `a_max ≥ true max accel`, `V_LINE ≥ true ceiling`, and `v0 ≥ true speed at t0`. Asymptotic deficit below free-run = `½·(V_LINE − v0)²/a_max` (constant once past τ*). Biggest win right after a confirmed station stop where `v0 ≈ 0`.

**Deficit table (m below free-run):** `v0=0` → 164 (V=22.2)/261 (V=28); `v0=5` → 99/176; `v0=10` → 50/108.

### 4.3 Other safe reuses of observed speed (all never-late-preserving)

- **(a) Mode confirmation** — sustained observed speed ≫ walk ceiling confirms vehicle mode.
- **(b) Kinematic params** — `(v0, a_max, V_LINE)` feed the between-station trapezoidal DR model.
- **(c) Crowd-sourced per-segment `V_LINE(seg)`** — a tighter-but-valid ceiling, valid **ONLY** as an over-bound: `V_LINE(seg) = max(observed_p100_over_N_rides + margin, design_speed)`. Per the trap, the crowd sample max under-estimates the true max, so the design-speed floor is mandatory.

**Never-late note (idea-level).** The observed-max trap is the one unsafe use and is ruled out. The accel cone can only ever sit *below* free-run; any missing `v0` degrades to free-run (`v0 → V_LINE`). Even under mode misclassification (parallel car) the cone stays valid — you bound whichever object you actually measure.

### 4.4 Rigor check — verifier flagged the accel cone as NOT-yet-safe-to-ship (sound = false, never_late_holds = false)

A verification pass found the *abstract math* is never-late-safe **given its three preconditions**, but the delivered configuration and validation **do not meet them** on the real fixtures:

1. **`a_max = 1.5 m/s²` is NOT a valid over-bound of these very rides.** IMU `a_long` true-launch max = **1.51 m/s²** (Nallur, exceeds 1.5); GPS-derived sustained accel max = 2.83 (pooled p99 = 2.10); global |a_long| max = 3.66. The facet used p95 (1.43) and dismissed the excess as "GPS jitter" without proof. p95 is the wrong statistic for a hard over-bound → precondition `a_max ≥ true max accel` violated with zero/negative margin → the cone can under-shoot and fire **LATE**.
2. **"Never-late in ALL 39 windows" was asserted ONLY at each window's END** (`facet_trap_and_cone.py:118` checks `sa ≥ s_true_end` only). Sampling the cone every second against the facet's own linear-interp ground truth, the cone falls **below truth in 32/39 windows** (worst 43 m), all at `v0=0` post-station launches — i.e. the invariant breaks exactly where it is most likely to (early ramp, small τ).
3. **The recommended `sMax = min(freeRun, cone)` PROPAGATES an under-shoot** rather than guarding against it: `min()` selects the smaller (under-shooting) cone, so when `v0` is present but the real launch profile makes the cone dip below truth, `sMax < truth` → late fire. "Degrades gracefully to free-run" only holds when `v0` is *absent*.
4. **Proof and recommendation use DIFFERENT `v0`.** The validation script uses raw last GPS speed (`:108`), not the recommended EKF speed over-bounded by `+k·σ_speed`; `v0=0` is inferred from a GPS-speed-0 reading before blackout, which does not confirm a physical stop. The proven config is not the recommended config.
5. **The headline "34% tighter (407 → 267 m)" is the most-optimistic value at the least-safe `a_max`.** At a true over-bound (`a_max ≈ 2.1`) the tightening drops to ~25% (100 m); at the ride's own 2.83 it is ~18% (74 m).
6. **The mode-misclassification argument ("a road vehicle is generally faster") is loose** — a parallel car in stop-and-go can be slower. The safety conclusion happens to hold (you bound whatever you measure), but the stated reasoning is not sound.

**Corrections to make it shippable-safe:** set `a_max` from the physical max + real margin (≥ ~2.0 m/s²), justify the GPS 2.83 tail as differentiation noise backed by the cleaner IMU signal, and report ~25% tightening; validate `cone(τ) ≥ truth(τ)` at **every** τ inside each window, not just the end; apply the cone **only** when `v0` is trustworthy and use `v0=0` exactly only on a `StationSnapConfirmed` dwell (over-bound `v0` by `+k·σ_speed`); **do not** ship an unconditional `min(freeRun, cone)` — guard it so the cone is used only where its preconditions provably hold, else fall back to free-run. The TRAP finding (4.1) and the existing free-run baseline remain sound and safe; the *tightening* is not yet proven safe to ship.

**Builds on.** Extend `Reachability.bound()` / `_topologyCappedProgress` in `reachability.dart` (it already forward-simulates the fastest train; the accel ramp slots in as the launch phase from each anchor/station). `v0` from `EkfState.speedMps` (`lib/core/ekf/ekf_types.dart`) over-bounded by `gpsSpeedVar`; the `v0=0` confirmed-stop anchor uses the `StationSnapConfirmed` stream in `active_route_manager.dart`. Per-line ceilings reuse `VLineTable` (add a parallel `aMaxTable`).

---

## 5. The never-late SAFETY GATE decision table

Scripts: `work/onrail_confidence.py`, extends `work/fusion.py` (max-of-plausible K-confirm) and `work/classify.py`.

### 5.1 The gate rule

The soft cues (cross-track, vib, mode-class) can only MODULATE a UX confidence `C ∈ [0,1]`; they may **never** set the hard car-exclusion boolean. Exactly two discriminators may exclude a car, both un-fakeable by a surface vehicle:

- **G = sustained route-correlated GPS OUTAGE** (train grade-separated/underground; a surface car keeps open-sky GPS). Measured: Nallur 33 blind windows merge into one **549 s continuous** dark run; Nadaprabhu 123 s. A surface car essentially never loses GPS >~10 s (`gps_health_monitor` unavailable threshold = 25 s). Near-perfect separation.
- **B = repeated dwell at STATION arc-positions** on the line's cadence (measured inter-station 1044–2396 m / 106–340 s). A car stops at lights, not station geometry.

**Hard rule:** `car_excluded = latch(G) ∨ latch(B)`. When latched → `V_used` drops to the train over-bound and the TIGHT model turns on (stop-anchoring + dwell-subtraction + accel cone). When not latched → `V_used = mode-MAX` (over the fastest plausible mode). Sustained cross-track routes to the deviation/reroute branch. On the real rides the latch fired at t=55 s (Nadaprabhu, via G) / t=267 s (Nallur, via B) and stayed latched 91–98% of the ride.

### 5.2 Decision table

| Gate state | `V_used` | walk | surface car | highway car | train | Safe? |
|---|---|---|---|---|---|---|
| NOT-excluded | mode-MAX ceiling | ✓ | ✓ | ✓ | ✓ | over-bounds all |
| EXCLUDED | line V_LINE (tight) | ✓ | ✓ (≤ car ceiling, still over-bound) | **see rigor check** | ✓ | conditional |
| OFF-ROUTE | mode-MAX, deviation | — | — | — | — | reroute/re-anchor |

### 5.3 Proof sketch (as originally stated)

`s_max(t) = s0 + V_used·(t−t0)` is monotone increasing in `V_used` and `s0`. The invariant holds iff `V_used ≥ V_true(actual mode)` and every re-anchor `s0 ≥ true progress`. `V_used = max over NOT-yet-excluded modes ⇒ V_used ≥ V_true` **always UNLESS a mode is wrongly excluded**. A car is excluded only by G∨B; the argument claimed a vehicle with `V_true > V_train` is a highway car that cannot produce G or B, making the dangerous under-bound cell "structurally unreachable." Tightening only ever moves `V_used` DOWN or re-anchors `s0` to a known station arc-position — both monotone-safe; a missed detection leaves `V_used` at mode-MAX (looser, earlier).

### 5.4 Rigor check — verifier found the first-cut gate has CONFIRMED late-fire holes (sound = false, never_late_holds = false)

The keystone "excluded × highway-car is unreachable" is **FALSE**, and the hardcoded ceilings under-bound fast lines:

1. **CONFIRMED late fire — parallel road/expressway TUNNEL car.** `onrail_confidence.py` latches G on outage *duration alone* (`if outage_len>=30: seen_long_outage=True`) with **no route-progress check**, despite the text claiming G requires "continued route progress." A car in a road tunnel/underpass/parking structure paralleling the metro at 30–33 m/s (108–119 km/h, normal expressway speed) latches G → `V_used → V['train']=28`. On Nallur geometry over the 549 s outage: `s_max = 15372 m` but a 30 m/s car reaches **16470 m ⇒ s_max < true ⇒ LATE** (worse at 33 m/s). The "car speed-limited ≤ ~80 km/h" claim is unsupported — highway tunnels routinely allow 90–120 km/h.
2. **CONFIRMED late fire — express/RRTS train faster than the hardcoded ceilings.** `v_used()` uses `V['train']=28` (gate-ON) and mode-MAX `=33` (gate-OFF), both **below** speeds `reachability.dart` itself models (`expressMps=39`, `rrtsMps=53`). Per-instant over a 120 s outage: express (37.5 m/s) true 4500 m vs `s_max` 3360(28)/3960(33); RRTS (44–53 m/s) true 5280–6360 m vs 3360/3960 — **LATE in every case**. Mode-MAX is built from *car* ceilings, not the line's `V_LINE`, so it under-bounds any service faster than 33 m/s. The 0-violation validation only holds because both fixtures are slow conventional Purple line (~12 m/s peak segment).
3. **REGRESSION — the safety action causes the late fire.** Car-exclusion lowers `V_used` 33 → 28. On express/RRTS this is strictly worse than doing nothing (correct line detection would use 39/53). The gate turns a never-late baseline into a late-firing one on fast lines, amplifying the pre-existing reachability gap where a fast line whose name doesn't keyword-match falls to `defaultMps=28`.
4. **Station re-anchor validated with ground truth production can't access.** `gated_cone:172` sets `s0 = max(s_anchor, true_s_of_t(t))` — the `max(…, true)` floor guarantees `s0 ≥ true` *in the sim only*. In production only `s_anchor` is known, so a station **mis-association** (confirming station N while physically past it, or a false-B latch snapping a car's traffic dwell to a nearby station) re-anchors `s0` **behind** true progress ⇒ LATE. The re-anchor's safety rests on an unstated precondition (anchor only to a *provably-passed* station) the deliverable never proves.
5. **Discriminator B false-latch understated.** Metro stations sit at major intersections; a car in stop-and-go on a parallel arterial can dwell near 2 station arc-positions (lights, bus stops), latch B, then open to highway speed — same late-fire mechanism.

**Corrections to close the holes:** gate-ON must use the line's real ceiling `VLineTable.forLine(city,line)` (28/39/53), never hardcoded 28. Gate-OFF must over-bound *both* the fastest plausible car AND the line's train: `V_used = max(VLineTable.forLine(...), car_highway_ceiling)`; for unknown/fast lines use `absoluteCeilingMps=56` (≥ RRTS 53). Enforce in code: **car-exclusion may only remove the car ceiling from the `max`, never lower `V_used` below the line's own `V_LINE`.** Add the route-progress / grade-separation precondition to G (latch only when the outage co-occurs with confirmed progress on a grade-separated/underground segment); bound a wrongly-excluded road-tunnel car by the parallel road's mapped speed class (keep `V_used` at that road's ceiling even when excluded). Re-anchor `s0` to a station **only** when that station is provably passed (a later healthy GPS fix or monotone lower-bound confirms it), never to the nearest/associated station; remove reliance on `true_s_of_t`. Re-validate on a fast-line (express/RRTS) fixture — the current 0-violation result is proven only for conventional metro with correct line detection and no highway-speed parallel tunnel.

**Builds on.** `reachability.dart` (V_LINE table, cone, topology/dwell cap, `onAcceptedFix` re-anchor — the gate just selects `V_LINE` and enables/disables the cap). `gps_health_monitor.dart` (states → G; 10 s/25 s thresholds already exist). `snap_to_route.dart` (`lateralOffsetMeters` + heading penalty → cross-track modulation + deviation branch). `station_association.dart` + `zupt_detector.dart` (ZUPT-confirmed dwell → B). `motion_classifier.dart` (band energy → soft `C` only). Python: `work/fusion.py`, `work/classify.py`, new `work/onrail_confidence.py`.

*Sources:* SHL-2024 Car↔Train↔Subway residual confusion — https://dl.acm.org/doi/10.1145/3675094.3678456 (2024). Ensemble F1 ≈ 97.49% (non-perfect) — https://www.researchgate.net/publication/393692736_IMU-Based_Transportation_Mode_Recognition_using_Ensemble_Learning_and_Multisensor_Fusion (2025). SHL-2023 adds GPS to separate subway/train — https://dl.acm.org/doi/10.1145/3594739.3610758 (2023). HMM map-matching 95.3%, parallel roads the residual failure — https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0302656 (2024). Parallel-lane ambiguity needs explicit resolution — https://www.tandfonline.com/doi/full/10.1080/17538947.2024.2383479 (2024).

---

## 6. What builds on existing repo code (no green-field)

| Existing file | Existing capability | Extension for on-route confirmation |
|---|---|---|
| `lib/services/snap_to_route.dart` | `lateralOffsetMeters` via equirectangular projection; search-window snap | Signed cross-track (tangent × point vector); rolling persistent-offset estimator; deviation branch |
| `lib/services/active_route_manager.dart` | station list, `bestOffset` per candidate, `onStationSnapConfirmed` (§24.2 monotonic, σ≤30 m) | Home for `a_exp(s)` prior table; co-location anchor for boarding + station re-anchor |
| `lib/services/soft_lock_manager.dart` | 50 m/200 m corridor + hysteresis | Graded persistent-offset confidence (not just binary gate) |
| `lib/services/gps_health_monitor.dart` | healthy/degraded/unavailable (10 s/25 s, 50 m) | `expectedAvailability(s)` + directional anomaly flag; discriminator **G** |
| `lib/core/ekf/station_association.dart`, `zupt_detector.dart` | ZUPT-confirmed station dwell | Discriminator **B** (station-cadence dwell match) |
| `lib/core/ekf/motion_classifier.dart` | train/walk band energy | Soft confidence `C` only (never the hard gate) |
| `lib/services/sensor_fusion.dart:112` `setFftEnabled` | FFT path wired through `ekf_orchestrator` | 0.05–0.4 Hz sustained-force (launch) + 1.2–2.6 Hz gait-band features |
| `lib/core/ekf/ekf_orchestrator.dart` | frozen-phantom + off-route rejection ("138 off-route phantoms") | Dual rule: low-hacc fix inside expected-underground segment = surface anomaly |
| `lib/core/ekf/ekf_types.dart` `EkfState.speedMps` | speed + `gpsSpeedVar` | `v0` for the accel cone, over-bounded by `+k·σ_speed` |
| `lib/core/reachability/reachability.dart` | `VLineTable`, cone `s0+V·dt`, `dwellMinSeconds` topology cap, `onAcceptedFix` re-anchor | Accel-limited launch branch; gate selects per-line `V_LINE` + toggles cap (add `aMaxTable`) |
| `work/fusion.py`, `work/classify.py` + `mode_tree.pkl` | max-of-plausible K-confirm; still/walk/car/train tree | Extend "exclude a mode" trigger to require a geometric (G∨B) confirmation before tightening |

---

## 7. Consolidated source list (every `source_url` preserved)

- https://pmc.ncbi.nlm.nih.gov/articles/PMC11889165/ — GPS cannot separate parallel tracks; gyro curvature supplement (2024)
- https://www.mdpi.com/1424-8220/25/15/4678 — urban-canyon multipath >10 m; 2025 weighting → 3.8–4.7 m RMSE (2025)
- https://link.springer.com/article/10.1007/s11116-024-10472-x — GPS-trajectory TMD ~80%; PELT/change-point mode transitions (2024/2025)
- https://doi.org/10.3390/engproc2025088014 — context-aware GNSS (satellite count/DOP/C-N0) (2025)
- https://link.springer.com/article/10.1007/s10291-025-01962-1 — 3DMA GNSS / shadow matching visibility prediction (2025)
- https://navi.ion.org/content/71/4/navi.676 — Graph-Transformer GNSS visibility in urban canyons (2024)
- https://link.springer.com/article/10.1007/s10291-020-0973-5 — sky-visibility classifies rail above/underground (2020)
- https://www.mdpi.com/1424-8220/24/22/7369 — TMD review: 'train'/subway intermixes with car/bus (2024)
- https://www.sciencedirect.com/science/article/pii/S2590198224001672 — magnetometer TMD; distance-to-rail disambiguates train vs car (2024)
- https://dl.acm.org/doi/pdf/10.1145/3307334.3328635 — subway arrival/departure from linear-accel (2019)
- https://tik-old.ee.ethz.ch/file/365ee27a42f71d6b5cd7212571f7185b/mobiquitous16-gu.pdf — MetroEye HMM + timetable, ~96% stop detection (2016)
- https://www.researchgate.net/publication/301564508_Classification_Algorithms_for_Detecting_Vehicle_Stops_from_Smartphone_Accelerometer_Data — SVM-HMM / change-point vehicle-stop detection (2016)
- https://arxiv.org/pdf/2312.04821 — "walk as transition" trip segmentation (2023)
- https://arxiv.org/pdf/1904.01675 — SubwayPS station-stop patterns + line map (2019)
- https://www.shl-dataset.org/challenge-2025/ — SHL 2025 foundation-model track (2025-10)
- https://www.frontiersin.org/journals/computer-science/articles/10.3389/fcomp.2021.713719/full — SHL-2020 best F1 88.9%; Train↔Subway most confused (2021)
- https://dl.acm.org/doi/10.1145/3675094.3678456 — SHL-2024 missing-modalities, 70–80% F1; Car↔Train↔Subway residual (2024-10)
- https://arxiv.org/html/2407.11048v1 — CNN/BiLSTM/transformer TMD, no break past ceiling (2024-07)
- https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5335990/ — boarding-action fuzzy inference 91.1–94.0% (2017)
- https://grouplens.org/site-content/uploads/bhecht_sigspatial2014_subwayps.pdf — SubwayPS 85.8% station detection (2014)
- https://doi.org/10.3390/s19194184 — London Underground footprint ~90% departure-station ID (2019)
- https://ieeexplore.ieee.org/document/7572080/ — metro-trace fingerprinting ~92% (2017)
- https://www.mdpi.com/2079-9292/14/18/3608 — smartphone map-matching 70–90%; semMatch (2025-09)
- https://ieeexplore.ieee.org/document/7954172/ — Protection Level integrity bound (2024)
- https://link.springer.com/article/10.1007/s40864-015-0012-y — metro accel/brake 1.0–1.5 m/s² (2024)
- https://www.tandfonline.com/doi/full/10.1080/17538947.2024.2328366 — parallel-road disambiguation open; heading insufficient (2024)
- https://arxiv.org/pdf/2108.04140 — reachable-set analysis, double-integrator bounded input (2024)
- https://insidegnss.com/tight-position-bounding-for-automotive-integrity/ — tight position bounding vs safety margin (2024)
- https://www.researchgate.net/publication/393692736_IMU-Based_Transportation_Mode_Recognition_using_Ensemble_Learning_and_Multisensor_Fusion — ensemble F1 ≈ 97.49% (2025)
- https://dl.acm.org/doi/10.1145/3594739.3610758 — SHL-2023 adds GPS to separate subway/train (2023)
- https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0302656 — HMM map-matching 95.3%; parallel roads residual failure (2024)
- https://www.tandfonline.com/doi/full/10.1080/17538947.2024.2383479 — parallel-lane ambiguity needs explicit resolution (2024)

---

*Data basis: two real Bengaluru Purple-line handheld rides (opposite directions). Scripts under `/home/raed/geowake_imu_analysis/work/`. Two facets (accel-cone tightening §4, safety-gate §5) carry verifier "Rigor check" notes with CONFIRMED never-late issues; the underlying TRAP finding, the free-run baseline, the discriminator scorecard, and the SOTA survey are sound. The tightening and the gate are safe to ship only after the listed corrections land.*
