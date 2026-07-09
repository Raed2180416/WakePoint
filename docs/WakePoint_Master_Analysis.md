# WakePoint — Master Analysis & Verified Next Steps
*State of the project as of 2026-07-09. This is the synthesis of everything: goals, what we built, what we proved, what's broken, and the fix path — in the order it must happen.*

---

## 1. The goal, restated precisely

WakePoint fires a **wake alarm N metres before a user's target metro station**, and must keep working **when GPS is gone** (underground, tunnels) by dead-reckoning the user's 1D progress along a **known, prefetched rail route** from phone IMU. The filter is a 3-state EKF `[s, v, b]` = arc-progress (m), velocity (m/s), accel bias (m/s²).

Two success criteria, staged (your call, "Both, staged"):
- **Alarm reliability** — right stop, right time, especially underground. *This is the product.*
- **Underground drift / filter consistency** — the engineering property that enables the alarm.

---

## 2. The core problem we had to solve first (and did)

We have **exactly one real ride** (Rajajinagar→Whitefield, 33.5 km, 1h41m, 388 s tunnel blackout). You cannot measure a "2%-of-the-time you miss the stop" failure rate from one trip, and you cannot trust a synthetic test that shares assumptions with the filter it tests (the **circularity trap**).

Our answer, built end-to-end this project:
1. **Phase 0 — data hygiene.** A loader that reconstructs true 100 Hz raw accel (= linear+gravity; the raw channels only logged at 57 Hz), fixes a garbage row, aligns gyro, flags stale GPS.
2. **Phase A — silver ground truth.** Because the manual taps are unreliable (±tens of seconds, 2 stations missed), we rebuilt a **30-station reference** from OSM rail arc-length + GPS on the surface + IMU dwell anchors underground + monotone interpolation, with a per-station uncertainty σ (2 s surface, 20 s underground).
3. **Stage B — physics synthesizer.** A 4-layer phone-IMU generator on the real rail geometry, **held to the real ride's statistics by a realism gate** (it caught a 26× vibration-energy deficiency and a spectral-shape error and forced fixes — the circularity trap actively avoided). Plus a fidelity pass (gradient, speed-tracking vibration chirp, background throttling).
4. **Stage C — evaluation harness.** A **faithful Python port of the production Dart EKF** (verified line-by-line against `lib/core/ekf/`), scored on synthetic rides where truth is exact.

That machinery is the deliverable that lets us *measure* "subpar" instead of guessing. It works.

---

## 3. What "subpar" actually IS — the root-cause chain (all proven, in code and simulation)

We ran the production filter through a station **arriving mid-blackout** (the case that matters). Result: **0% alarm hit-rate, alarm fires ~100 s late.** Then we isolated *why*, and it is a chain, not one bug:

**(A) Spurious ZUPT stalls velocity during cruise — the trigger mechanism.**
The zero-velocity update is a pedestrian foot-stop detector. A metro cruises at near-constant velocity, where tangential accel ≈ 0 and the accelerometer is quiet-with-vibration — exactly what a variance-threshold detector reads as "stopped." When it misfires it **zeroes velocity, and with a≈0 there is no signal to rebuild it**, so position flatlines. Proven by isolation: turning ZUPT **off** dropped in-tunnel error **3108 m → 184 m** even with near-perfect acceleration. Source: `zupt_detector.dart:51,58,71` (the `imuUltraQuiet` / degraded paths) and `motion_classifier.dart:127` (the degraded-mode guard `recentMaxAFwd > 0.15` fails precisely in constant-velocity cruise where accel is ~0).

**(B) The filter is grossly overconfident — why it won't self-correct.**
Measured **NEES ≈ 3930** (a consistent filter is ≈1; the ladder/`stageC_fix_ladder.json` value). It reports σ≈10 m while being ~2,800 m wrong. Two coded causes: `ekf_pipeline.dart:463` **tightens position covariance after every ZUPT** (a ZUPT observes *velocity*, not position — unjustified), and `:555` **hard-caps position σ at 200 m**. An overconfident filter trusts its own wrong position and refuses corrections.

**(C) The self-defeating contradiction — why (B) exists.**
Station association (`station_association.dart:117`) is a **2D spatial nearest-neighbour search** whose candidate window = `3·σ + margin`, and the margin **shrinks as σ grows** to avoid `MULTIPLE_CANDIDATES` (`:74-82`). So they *must* keep σ small to identify stations — which forces the overconfidence in (B). The filter **lies about its confidence to keep station-matching tractable.**

**(D) The binding constraint is velocity quality through the blackout.**
The surprising, hypothesis-overturning result: once covariance is made honest, **reducing accel bias alone does nothing** (1294 m → 1249 m, alarm still 0%). The alarm only recovers when the *velocity estimate through the blackout* improves. Honest covariance is **necessary but not sufficient**; good GPS-denied velocity is the real gate.

### The verified fix ladder (n=6 seeds, mid-blackout target)
| Configuration | Alarm hit | Lead err | In-tunnel max | NEES |
|---|---|---|---|---|
| Production (σ-cap 200 m, ZUPT tightens position) | **0%** | 100 s | 1656 m | 3930 |
| + honest covariance (3 km cap, ZUPT vel/bias only) | 0% | 37 s | 888 m | **23** |
| + motion-gated ZUPT | 0% | 37 s | 887 m | 23 |
| **+ 4× better velocity (learned-IO proxy)** | **100%** | **9 s** | 536 m | 19 |

The table *is* the argument: consistency is fixable cheaply; **the alarm needs the velocity fix.**

---

## 4. What the SOTA research says the fix is (grounded, 2024–2026)

From the literature track (25+ citations, real URLs, in `research_zupt_motion_odometry.md`), the field is unanimous and maps 1:1 onto our findings:

1. **Motion-state-gated ZUPT** (ship first, cheap). Classify {dwell, cruise, accel/decel}; permit a zero-velocity pseudo-measurement **only in dwell**, with hysteresis + minimum-dwell (~5–10 s) so a sub-second cruise dip can never fire it. (Wagstaff & Kelly 2018/2019; Skog–Hendeby–Kok jump-Markov filter bank 2023.)
2. **Learned forward-speed pseudo-measurement during cruise** — regress along-route speed from IMU, fuse projected onto the route tangent, so velocity is *maintained* not zeroed. (OdoNet 2021; Freydin & Or 2022.) This directly supplies the finding-(D) velocity fix.
3. **Best long-term: learned displacement+covariance regressor as the EKF update (TLIO/GNIO), uncertainty replaces the detector.** GNIO's (2026) "gated prediction head" is a **soft differentiable ZUPT** — ~0 displacement with tight covariance at a true stop, scales up in cruise, no binary trigger, no unrecoverable zeroing (reports 60% error reduction on the exact micro-drift-during-stationarity + frequent-stops cases we hit). Wrap in EqNIO gravity-aligned canonicalisation for phone-orientation robustness. On-device budget is generous, so a compact CNN backbone (IONext-class) is feasible.
4. **Dwell = duration + spatial consistency, not variance.** Declare a stop only when a ~15–25 s low-motion window co-occurs with proximity to the next expected station arc-position. (Löffler & Bengtsson 2024 track-map particle filter holds <10 m through 30 s outages on curves — direct analog to us; MLoc 2020.)
5. **Fix covariance regardless of path** — stop tightening position on ZUPT; remove the 200 m cap; make station association gate on **1D route ordering / arc-distance** (an HMM/sequence match along the known stop order) rather than a 2D spatial set. This dissolves the (C) contradiction. Add NEES/NIS monitoring as an acceptance gate.

Reference OSS to build on: **PyShoe** (ZUPT + learned detectors), **TLIO**, **RoNIN**, **EqNIO**; **SHL dataset** for the motion-state gate.

---

## 5. Where each stage stands

| Stage | Status |
|---|---|
| Phase 0 — data hygiene loader | ✅ done, skill published (`wakepoint-ride-loader`) |
| Phase A — silver ground truth (30 stations) | ✅ done, skill published (`wakepoint-rail-geometry`) |
| Stage B — synthesizer + realism gate | ✅ core done; fidelity gate items folded in (gradient, chirp, throttle) |
| Scenario matrix (E1–E10 edge cases) | ✅ spec authored |
| **Corpus generator** (200+ rides w/ gold s(t)) | ⏳ **not built** — the bridge to statistical claims |
| Stage C — eval harness + faithful EKF port | ✅ port verified; harness works; **first numbers produced** |
| **Fix ladder** | ✅ proven in sim (honest-cov + motion-gate + velocity) |
| Filter Stages 1/2/3 (harden→learned-IO→hybrid) | ⏳ Stage 1 designed & partially tested; 2/3 are the learned-IO work |

---

## 6. Verified next steps — the sequence that will work

**Discipline (your rule): nothing touches the real repo until it's verified in sim.** Every step below is "prove in the harness → then port to Dart."

**Step 1 — Lock the covariance fix (nearly done, cheap, high-confidence).**
`EkfFixed` already shows NEES 3930→23. Finalize: (a) ZUPT updates velocity+bias only, (b) remove 200 m cap, (c) re-architect station association as a **1D sequence/HMM match** on known stop order so it tolerates honest large σ. *Verify:* NEES→~1, no station mis-ID with σ=3 km. This is the enabler; ship-ready first.

**Step 2 — Motion-gated ZUPT + duration/spatial dwell test (cheap, ship-first per literature).**
Precomputed band-energy gate already separates cruise 94% / dwell 5%. Wire it as a hard veto + hysteresis + 15–25 s dwell-duration + arc-position proximity. *Verify:* zero spurious ZUPT during cruise across all seeds; dwells still caught.

**Step 3 — The velocity fix (the one that recovers the alarm; the real work).**
Add a **learned along-route speed/displacement pseudo-measurement** fused into the EKF (OdoNet-style first for speed; TLIO/GNIO-style displacement+covariance as the target architecture). Train on the **corpus generator** output (domain-randomized phones) + the one real ride for calibration. *Verify:* the 4×-velocity row of the fix ladder reproduced by a *real* regressor, not a proxy — alarm hit-rate →100%, lead-err <15 s on mid-blackout targets.

**Step 4 — Build the corpus generator (prerequisite for Step 3 training + all statistical claims).**
Wire the scenario matrix into a generator emitting ≥200 average + ≥50/edge-case rides, each with gold s(t) and randomized phone. Run the full metric suite (ATE/RTE/NEES/NIS/ZUPT-PR/station-assoc/alarm-hit-rate + failure Pareto) with **reference-σ propagation**.

**Step 5 — Only then, port the verified changes into `lib/core/ekf/` and re-run the 445-test suite.**

**Immediate recommendation:** do **Step 1 + Step 2** now (cheap, independently valuable, unblock everything) and **Step 4** (corpus) next because Step 3's learned model needs it to train. Step 3 is the headline fix but depends on 1/2/4.

---

## 6b. VERIFIED (this session) — the fix works end-to-end with a real learned model

Everything in §6 was then **built and verified in simulation**, holding to the rule that nothing touches the repo until proven. Results on the mid-blackout target (n=6 seeds):

| Configuration | Alarm hit | Lead err | In-tunnel max | NEES |
|---|---|---|---|---|
| Production (no fixes) | 0% | 100s late | 1656 m | 3930 |
| + honest covariance | 0% | 37s | 888 m | 23 |
| + motion-gated ZUPT + dwell-count seq-assoc | 0% | 90s | 919 m | 51 |
| **+ learned velocity (Step 3, real regressor)** | **100%** | **−2s** | **147 m** | **3.0** |

**What was built and verified:**
- **Step 1 — honest covariance** (`EkfFixed`): σ cap 200 m → 3 km; ZUPT updates velocity+bias only (never tightens position). NEES 3930 → 23.
- **Step 1b — dwell-count sequence association** (`DwellCountAssociator`): replaces the 2D spatial NN search with counting confirmed dwells and advancing the known station order one stop per dwell. **Immune to arc-position lag; enables honest large σ.** Verified: picks correct next station even at σ=2 km.
- **Step 2 — motion-gated dwell detector** (`DwellDetector`, `min_dwell_s=8`): band-energy gate separates cruise (94% vehicle) from dwell (5%); tuned to **21/21 true stops matched, 1 false positive** on the real ride.
- **Step 3 — learned velocity regressor** (`velreg_model.pkl`): HistGradientBoosting on 8 phone-independent IMU features (a_p90 r=0.99 with speed; 3–8 Hz vibration band r=0.91). Trained on 32 domain-randomized synthetic rides, tested on 8 held-out (ride-level split, no leakage): **MAE 1.52 m/s, R²=0.84**, cruise MAE 1.79 m/s. Fused as an EKF velocity measurement during blackout.
- **Step 4 — corpus generator**: 40 domain-randomized rides (5 carry modes × 3 throttle regimes × variable route length/blackout), each with gold s(t). Scales to the 200+ the plan calls for.

**The decisive finding, confirmed with a real model:** Steps 1+2 alone leave the alarm at 0% — they make the filter *consistent* (NEES→low) and station-snapping *trustworthy*, but the filter still lags because velocity through the blackout is wrong. **Only when the learned velocity is fused does the alarm recover to 100%** (−2 s lead, 147 m in-tunnel error, NEES 3.0). The three steps are mutually dependent; velocity is the keystone.

**Verified artifacts:** `wakepoint_verified_fix.png` (the 4-panel result), `wakepoint_step12.py` (Steps 1+2), `wakepoint_step34.py` (Steps 3+4), `velreg_model.pkl` (trained regressor), `velreg_corpus.npz` (corpus), `stageD_verified_results.json`.

**Still to do before repo port:** (1) scale corpus to 200+ and confirm the ladder holds across route families and edge cases E1–E10; (2) real-world validation with ride #2 to exclude the circularity risk in the velocity regressor (see caveats); (3) then port Steps 1+2 to Dart first (cheap, high-confidence), Step 3 after the model is validated on real data.

## 7. Honest caveats
- **n=1.** Every synthesizer constant is a point estimate from one phone/crowd/time-of-day. Anything never seen in the real ride is flagged **extrapolation** — a hypothesis until ride #2..#N is captured. The extrapolation list is your capture-priority list.
- **The "4× velocity" row uses a proxy** (blend toward true accel), not a trained network. It proves the *lever exists*; Step 3 must reproduce it with a real regressor before we believe the 100%.
- **My earlier "ZUPT is the whole story" was wrong** and I corrected it: a port bug (missing the Dart velocity gate) over-blamed ZUPT. The corrected experiment shows velocity quality is the binding constraint. Verification over narrative — that's the standard for the rest.
- **The velocity regressor's R²=0.84 is encouraging but not yet trustworthy for production.** It is trained and tested entirely on synthetic rides, and the synthesizer's vibration model is itself speed-driven — so the regressor may be partly *inverting my own generator* rather than learning a phone-universal speed cue. The held-out (by ride) split rules out trivial memorization, and the physical basis is real (vibration amplitude genuinely grows with speed), but the circularity is not fully excluded until the model is tested on a **second real ride**. Treat the 100% alarm number as "verified in simulation," not "verified in the world." Capturing ride #2 is the single highest-value next data action.
