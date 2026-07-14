# TRACK — Walking-to-Station PDR + Transport-Mode-Transition Detection

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
