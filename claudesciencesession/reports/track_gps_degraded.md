# WakePoint — Localization under DEGRADED GNSS (walking / driving approach to a station)

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
