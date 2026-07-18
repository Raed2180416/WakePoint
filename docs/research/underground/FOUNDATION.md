# GeoWake Underground Positioning — FOUNDATION

**Scope:** the end-to-end model for never-late arrival alarming when GPS goes dark (metro tunnels, car tunnels/parking) on a **loosely handheld phone**. This document is the consolidated research foundation: one section per research facet, each with a summary, methods table, full derivation (equations preserved verbatim for the math facets), never-late implications, pitfalls, a recommendation, and — where an adversarial verifier flagged issues — a **Rigor check** with the corrections that must be applied.

**Standing caveat (applies to every facet):** every accuracy number below comes from published literature on *other* datasets/devices. GeoWake's current real fixtures log only `t, ax, ay, az, gx, gy, gz` (accel+gyro). No pressure/magnetometer columns exist yet, and the synthetic rides cannot validate signal realism. **Nothing here is device-proven on GeoWake's real Bengaluru handheld rides until measured on the two real fixtures (Nadaprabhu Kempegowda / Majestic, Nallur→Vijaynagar).**

---

## PART 0 — THE MODEL, TO THE MAX (executive architecture)

### 0.1 Recommended end-to-end architecture

The pipeline is a strict **tightening layer on top of the existing reachability Protection Level**, never a replacement. Firing always reads an **upper bound** on along-route progress `s`; every sensing stage can only pull that bound *down toward truth*, and any missed detection degrades gracefully back to the pure physics cone.

```
                    ┌─────────────────────────────────────────────────────────────┐
   IMU 50 Hz ──▶    │  (1) MODE CLASSIFY  {still, walk, car, train}                │
   (accel+gyro)     │      → plausible-mode SET P(t) (containment, not accuracy)   │
                    └───────────────┬─────────────────────────────────────────────┘
                                    │ V_LINE(t) = max_{m∈P(t)} V_max(m)
                    ┌───────────────▼─────────────────────────────────────────────┐
                    │  (2) PER-MODE MOTION MODEL                                   │
                    │   walk → velocity-adaptive Weinberg PDR (walk-gated only)    │
                    │   train→ jerk-limited S-curve (estimate) / trapezoid (cone)  │
                    │   car  → RISS-on-phone + learned pseudo-odometer (OdoNet)    │
                    └───────────────┬─────────────────────────────────────────────┘
   Attitude:                        │ clean longitudinal a_L(t) (gyro-gated gravity)
   gyro-propagated,   ┌─────────────▼─────────────────────────────────────────────┐
   accel-corrected    │  (3) EVENT-ANCHORED 1-D PARTICLE FILTER on the route       │
   only in low-jerk   │   state x=(s, v) on oriented_polyline (arc length)         │
                      │   predict: jerk/accel/speed-limited train kinematics       │
                      │   HMM {cruise,brake,dwell,launch} steers the proposal      │
                      │   anchors (weight×):  confirmed-stop ZUPT snap to s_travel  │
                      │                       curvature/yaw-rate match κ(s)         │
                      │                       barometer piston step / WiFi-cell     │
                      │                       GPS (when not blind)                  │
                      └───────────────┬─────────────────────────────────────────────┘
                                      │ deterministic UPPER support (sentinels)
                      ┌───────────────▼─────────────────────────────────────────────┐
                      │  (4) NEVER-LATE UPPER BOUND                                  │
                      │   U(t) = min( s_max_protected(t),  s_upper(t) )             │
                      │   s_max_protected: reachability, re-anchored only on         │
                      │       corroborated confirmed stop (one-sided margin)        │
                      │   s_upper: deterministic sentinel envelope, descends past a  │
                      │       station ONLY on ≥2 independent corroborators          │
                      │   FIRE when U(t) ≥ s_dest − d_lead                          │
                      └─────────────────────────────────────────────────────────────┘
```

The four never-late load-bearing facts:

1. **Firing reads an upper bound `U(t)` on true progress `s_true(t)`.** As soon as it is *physically possible* the rider is within the wake-lead distance of the destination, the alarm fires. Because `U ≥ s_true`, remaining distance `s_dest − s_true ≥ s_dest − U ≥ d_lead` at fire time → **never late by construction**. The only cost of a loose bound is *early* firing.
2. **The physics ceiling is `s_max(t) = s0 + V_LINE·(t−t0)`**, valid because instantaneous route speed `v ≤ V_LINE`. This is the α=0 hard guarantee the whole stack degrades to.
3. **Every tightening enters as a `min()` of individually-valid upper bounds.** Min of upper bounds is still an upper bound. Fewer/missed detections drop min-terms and only relax `U` upward — safe. The *only* dangerous direction is a **false-positive** (a phantom stop / false anchor that pushes the bound *below* truth), so every detector is tuned for **precision over recall**, and station re-anchoring is gated on independent corroboration.
4. **1-D on-route collapse.** Projecting onto the known destination polyline annihilates cross-track error (Simon & Chia projection theorem), so heading drift is irrelevant to the safety bound. Only along-route arc length `s` matters.

### 0.2 Ranked sensor stack (handling-immunity + never-late value)

| Rank | Signal | What it buys | Handling-immune? | Availability | Never-late role |
|---|---|---|---|---|---|
| **1** | **IMU brake-count** (longitudinal `a_L` + rail-vibration band-power + gyro) | Confirmed-stop anchors via HMM {cruise,brake,dwell,launch}; Δv≈−v_cruise; station counting | No — needs gyro-gated attitude to survive handling | Universal (every phone has accel+gyro) | Primary tightener; each confirmed dwell re-zeros DR |
| **2** | **Barometer** | Piston/elevation step at station approach; 35–55 dB SNR; orientation/shake invariant | **Yes** (sealed pressure sensor) | Mid/high-end Android only | Cleanest re-anchor corroborator; DB-free peak-counting is provably never-late |
| **3** | **WiFi / cell / BLE** | Station-AP fingerprint pins identity to ~30 m; leaky-feeder cell-ID coarse | Yes | Infrastructure-dependent; absent mid-tunnel; Android throttles scans | Opportunistic platform-only hard confirm; never a dependency |
| **4** | **Magnetometer** | Traction-current + ferromagnetic-mass field signature; ~96% stop/departure | Only via rotation-invariant \|B\| + gyro de-skew | Universal | Universal fallback corroborator; needs per-device/per-line calibration |

Barometer ranks above WiFi/cell **for the never-late core** because it is offline, handling-immune, and present in the tunnel; WiFi/cell is *more accurate when present* but is absent exactly where the blind window is worst. On the largely-**elevated** Bengaluru Purple line, barometer depth-fingerprinting only helps in the Majestic underground stretch.

### 0.3 The honest ceiling of handheld IMU alone

- **Inertially blind to constant velocity.** A train cruising at 22 m/s and a phone at rest produce *identical* specific force. IMU can **confirm stops** but can **never safely lower-bound speed mid-cruise**. Safe downward tightening of `V_LINE` must come from *certified physical exclusions* (GPS-confirmed stationarity, detected launch transient, route/map-match, confirmed dwell), never from "the accelerometer looks quiet."
- **Free double-integration of position diverges.** ~400 m over a 90 s leg at 0.1 m/s² bias; the EKF's real 518 km `s_est` spike is this failure mode. Position is only ever obtained by **event-anchored resets**, never open-loop integration.
- **Single-stop identification is ambiguous.** London Underground: 32–63% line+station ID after 1 stop, rising to ~91–100% after 3 and 100% after ≥4. Counting is only reliable after chaining **≥3–4 inter-station segments** — early in a ride the estimate must stay wide.
- **Realistic handheld subway ceiling (IMU only):** per-stop detection F1 ≈ 0.90–0.95 (recall 0.90–0.96, precision 0.95–0.99 *with* corroboration); dwell-time MAE ≈ 5–10 s; exact stop-count over a 13–16-station line ≈ 85–95%, rising toward ~99% only once route-length/timetable/baro corroboration is added.
- **On the train during a blind window, PDR does essentially nothing** — the rider isn't walking. The blind-window problem is solved by the trapezoidal/HMM stop-counting physics, not step counting.

---

## PART I — SENSING & DETECTION

## 1. Train / transit stop-counting on a handheld phone (`sota_train_stop`)

### Summary
The robust idea: a stopped/dwelling rail vehicle is distinguished from a moving one **not** by `|accel|` magnitude but by the **absence of broadband track-vibration energy**. Time-domain `|accel|` fails because at a dwell `a_train=0`, so specific force is just gravity + zero-mean handheld noise (RMS ~1–3 m/s² from riders shuffling), whose variance can *exceed* smooth cruise — a naive ZUPT/variance threshold thus **false-alarms during fidgeting and misses dwells while the rider walks**. SubwayPS detects stations as low-variance windows across all three axes (~85.8% across 4 cities). The strongest counting result is the **London Underground DDTW** work: PCA of acceleration magnitude gives an orientation-independent per-segment footprint matched with Derivative DTW (threshold 0.30; same-route mean 0.14 vs 0.63 non-colocated); line+station ID is 32–63% after 1 stop but ~91–100% after 3 and 100% after ≥4 — accumulating segments resolves the ambiguity a single stop cannot. SEDA-family accel arrival/departure detectors reach ~96% recall (410/427) with ~99% precision once WiFi/baro corroboration or an ordered state machine is added. Transit-mode detection (SHL) reaches F1 ~86–93% but **Train-vs-Subway and Vehicle-vs-Still are the dominant confusions** — mode ID sets the motion model, it cannot count stops.

### Methods
| Name | Idea | Accuracy / bound | Applicability to GeoWake | Source |
|---|---|---|---|---|
| SubwayPS (all-axis accel variance) — Stockx, Hecht, Schöning, SIGSPATIAL 2014 | Remove gravity, flag stations as low-variance windows across all 3 axes; also next-station alert | ~85.8% station detection across Brussels/Cologne/London/Minneapolis; ~30% better than baseline | Direct dwell-vs-cruise separator; upgrade variance→spectral band-power to survive fidgeting | https://grouplens.org/site-content/uploads/bhecht_sigspatial2014_subwayps.pdf |
| London Underground DDTW footprint — Nguyen et al., Sensors 2019 19(19):4184 | PCA of scalar accel magnitude → orientation-independent segment footprint; Derivative DTW, accept if score < 0.30; chain matched segments | 32–63% @1 stop, ~91–100% @3, 100% @≥4; 381 stations/11 lines; same-route DDTW 0.14 vs 0.63 | Best evidence counting is reliable only after ≥3–4 segments; known `s_travel` can replace the trained DB (match duration + vibration) | https://pmc.ncbi.nlm.nih.gov/articles/PMC6806589/ |
| SEDA-style accel arrival/departure + WiFi/baro validation — MobiSys'19 poster | Accel proposes stop/leave events (sustained decel then quiet); second modality validates | ~96% recall (410/427), ~3/427 false positives (precision ~99%); accel-only fell to ~363/427 | The precision/recall split to exploit: accel gives recall, corroboration gives precision (never-late-safe) | https://dl.acm.org/doi/pdf/10.1145/3307334.3328635 |
| HMM / matched filter over {cruise,brake,dwell,launch} — SHL 3-Year Review, Frontiers CS 2021 | Emissions = band-power B(t), signed a_L(t), yaw \|ωz\|; transition matrix enforces cyclic order, forbids brake→cruise; Viterbi = matched filter | HMM/majority-vote are the standard TMD post-processors; an impulse cannot fake the ordered decel→quiet→accel sequence | Recommended core: replaces naive thresholding; ordered-sequence constraint is exactly the DATA_CONTRACT ask | https://www.frontiersin.org/journals/computer-science/articles/10.3389/fcomp.2021.713719/full |
| Transit-mode classifier (SHL; CNN-LSTM / FPN-biLSTM) | Spectral+statistical windows → Still/Walk/Run/Bike/Car/Bus/Train/Subway; sets motion model & V_LINE | Best-team F1 ~93.4% (2018), avg ~86.9%; ~92% cross-position; Train↔Subway & Vehicle↔Still dominant confusions | Use for mode-adaptive V_LINE, NOT counting; Train/Subway confusion harmless (same trapezoid) | https://www.sciencedirect.com/science/article/pii/S2590198224001672 |
| Barometer elevation-sequence matching — SIGSPATIAL 2016 | Motion state from elevation change; match at-stop elevation sequence to per-station altitude map | ~86% motion-state, ~58% stop-station (Tokyo) — weak alone | Corroborator only (pressure step), not a primary counter | https://dl.acm.org/doi/abs/10.1145/2996913.2996999 |

### Full derivation

**Feature justification — why time-domain `|accel|` fails.** Handheld specific force
```
f(t) = R(t)(a_train(t) − g) + n_hand(t).
```
At a **dwell** `a_train=0`, so `f = R(t)(−g) + n_hand`; the only informative part is `n_hand` (rider shuffling/handling), RMS ~1–3 m/s², broadband but concentrated <5 Hz. During smooth **cruise** `a_train≈0` too (constant v), but wheel/rail interaction injects a vibration band. So `var(|f|)_dwell` can **exceed** `var(|f|)_cruise` when the rider fidgets ⇒ a variance/ZUPT threshold both false-alarms (still rider mid-tunnel) and misses (fidgeting at platform).

The separable feature is **band-power** in the track-vibration band, present in motion and absent in dwell, largely orientation-free. Sleeper-passing tone: `f_sleeper = v / L_sleeper` (L≈0.6 m) ⇒ at v=15 m/s, ~25 Hz; rail-joint/rolling energy spans ~2–40 Hz. Define
```
B(t) = ∫_{f1..f2} |FFT(|f| − mean)|² over a ~1 s window,
f1 ≈ 4 Hz (above the hand band),  f2 ≈ min(40 Hz, Nyquist = 25 Hz @ 50 Hz sampling).
```
Motion: `B` high. Dwell: `B` collapses to the noise floor. This is SubwayPS's "variance on all axes" made spectral, and the London footprint's substrate.

**Longitudinal projection (clean gravity + brake axis).** Attitude by gyro propagation `R_k = R_{k−1} exp([ω Δt]×)`; correct toward accel-derived vertical **only** when jerk `|df/dt| < J_min` (low-jerk gate) so the sustained horizontal brake force does not leak into gravity. Gravity estimate `ĝ = R_k · e_z · |g|`. Horizontal specific force `f_h = f − (f·ĝ)ĝ`. Over a brake window run PCA on `{f_h(t)}`; principal axis `û` = longitudinal track tangent (or align to the polyline tangent). Signed `a_L(t) = f_h(t)·û`, sign fixed so cruise→stop is negative. Zero-mean isotropic hand-rotation noise averages out of the projection; a coherent 0.5–1.5 s DC decel survives.

**Δv integration + zero-velocity constraint (bounded, event-scoped).** Over brake window `[t1,t2]` of length `T`: `dv = ∫ a_L dt`. Error model: with residual accel bias `b` and white accel noise density `σ_a` (m/s²/√Hz),
```
σ_dv = b·T (bias, dominant) + σ_a·√T (velocity random walk).
```
Consumer MEMS: `σ_a≈0.05` ⇒ RW over T=8 s = 0.05·√8 = 0.14 m/s; bias `b≈0.1` ⇒ 0.8 m/s. So a single brake event resolves `dv` to ~0.5–1 m/s — more than enough to confirm a decel from `v_cruise≈15 m/s` to 0 (SNR ~15–30). **Confirmed full stop** := `dv ≈ −v_cruise` AND `B(t)` collapses for ≥ `T_dwell_min`. But **position** integration over a whole leg is hopeless: `x_err ≈ 0.5·b·T_leg² = 0.5·0.1·90² = 405 m`. ⇒ never free-integrate position; use **event-anchored resets**: each confirmed stop resets `s := s_travel[k]` (known from JSON). Between anchors use the route-constrained trapezoidal profile over the known inter-station distance.

**HMM / matched filter.** States `S={cruise,brake,dwell,launch}`; emissions `(B, a_L, |ωz|)`; transition matrix `A` permits only `cruise→brake→dwell→launch→cruise` (`A[brake→cruise]=0`, etc.). Viterbi = temporal matched filter for the ordered stop signature ⇒ an impulse cannot mint a stop; this buys phantom-stop **precision**.

**Never-late upper-bound proof (monotone stop-anchor).** Along-route progress `s*(t)` nondecreasing; certified upper bound `U(t)` with invariant `U(t) ≥ s*(t)`. Reachability seed `U(t)=s0+V_LINE·(t−t0)` is valid since `V_LINE ≥` true top speed. Alarm fires when `U(t) ≥ s_tgt − margin` ⇒ firing time ≤ true arrival ⇒ never late; the only cost is early firing, which IMU tightening reduces.

*Tightening rule on a confirmed dwell at time τ:* let `C = {stations k : s_travel[k] ≤ U(τ)}` (not beyond the certified bound). Re-anchor to the **most-advanced reachable station** `k* = argmax_{k∈C} s_travel[k]`. New bound
```
U'(t) = min( U(t),  s_travel[k*] + V_LINE·(t−τ) )  for t ≥ τ.
```
*Lemma (validity preserved):* IF the confirmed dwell means the train truly sits at a real station `m` at τ, then `s_travel[m]=s*(τ) ≤ U(τ)` ⇒ `m∈C` ⇒ `s_travel[k*] ≥ s_travel[m] = s*(τ)`. Hence `U'(τ) ≥ s*(τ)`. For `t>τ`, top speed from the true station gives `s*(t) ≤ s*(τ)+V_LINE·(t−τ) ≤ s_travel[k*]+V_LINE·(t−τ)`; and `s*(t) ≤ U(t)`. So `s*(t) ≤ min(...) = U'(t)`. QED. Min of two valid upper bounds is a valid upper bound, and `U' ≤ U` ⇒ strictly **tighter** whenever `k*` sits below the loose seed.

*Failure analysis vs detector errors:* (a) **Missed** stop ⇒ no re-anchor, `U` unchanged, still `≥ s*` — safe, just looser. (b) **False-phantom** stop mid-tunnel (premise violated): true `s*` lies between stations `k*` and `k*+1`, so `s_travel[k*]` can be `≤ s*(τ)` by up to one inter-station gap ⇒ `U'(τ)` may **under-state** ⇒ late-fire risk of at most **one station**. This is the only dangerous direction, and it is exactly why **phantom-stop precision** (not recall) is the safety-critical metric. Mitigations: (i) require the full matched signature (`dv≈−v_cruise` AND B-collapse ≥ `T_dwell_min` AND HMM ordered path AND one corroborator) ⇒ residual false-anchor probability → negligible; or (ii) **cap** the tightening so `U'` can never drop more than one inter-station gap below the seed in a single anchor. If absolute never-late is mandatory, apply stop-count tightening only to the **lower edge** of the reported band and leave the fire-trigger upper edge on the pure reachability seed (zero late risk, no early-firing benefit).

### Never-late implications
Stop-counting is **safety-asymmetric** and this is the central design fact. Anchoring a confirmed stop to `s_travel[k*]` is a **monotone tightening** of the reachability upper bound using the most-advanced physically-reachable station. Missed stops only make `U` looser — always safe. The single dangerous event is a **phantom stop mid-tunnel**, which can under-state progress by at most one inter-station gap. Therefore **precision, not recall**, is the never-late-critical metric: drive false stops toward zero with the full matched signature plus one independent corroborator (baro step, WiFi/cell change, or "reachability interval contains exactly one station"). SEDA-family (~3 false in 427, precision ~99%) shows single-modality precision is close but not sufficient for a hard guarantee; add the one-gap cap, or (for absolute guarantee) tighten only the band's lower edge. Every additional *confirmed* stop legitimately shrinks the `V_LINE` slack accumulated since the last anchor — the mechanism by which stop-counting reduces absurd early firing without risking a late one.

### Pitfalls
- Naive `|accel|`/ZUPT variance threshold is **actively wrong** on handheld data: dwell RMS can exceed smooth-cruise RMS, so it both false-alarms and misses.
- Low-pass "gravity" leaks the sustained brake force into the gravity estimate. Must gate accel correction to low-jerk windows only.
- Free double-integration of position diverges (~400 m over 90 s at 0.1 m/s² bias). Only event-anchored, route-constrained trapezoidal DR is viable.
- Single-stop ID is inherently ambiguous (32–63% @1 stop); reliable counting needs ≥3–4 chained segments — stay wide early in a ride.
- Phantom stops from congestion/rough track / long red-signal holds mid-tunnel are the never-late killer; suppress by corroboration, not thresholds.
- Very short dwells (skip-stop/express) and riders walking inside the car during a dwell degrade recall (vibration band may not fully collapse).
- Nyquist: at 50 Hz you see only up to 25 Hz — plan the band as ~4–25 Hz, not the ~40 Hz of fixed-mount rail studies.
- Mode classifiers confuse Train↔Subway (harmless) but also Vehicle↔Still (same physics as the dwell problem) — don't use mode ID to gate stop detection.
- Barometer-only (~58%) and magnetometer-only are too weak to count alone; strictly precision corroborators.
- Auto-summarized PDF metrics can be fabricated — over-precise crowdsourced-metro numbers (e.g. 92.3/89.7/91.2%, ±8.3 s) were discarded; only abstract/full-text-confirmable numbers (London, SubwayPS, barometer, SHL, SEDA) are retained.

### Recommendation
Build the stop detector as: (1) spectral vibration-band power `B(t)` over ~4–25 Hz as the primary motion/dwell separator (replaces the failing `|accel|` variance); (2) gyro-propagated attitude with low-jerk-gated gravity correction, then PCA/polyline-tangent projection to signed `a_L(t)`; (3) a 4-state HMM {cruise,brake,dwell,launch} with a cyclic-order transition matrix, Viterbi-decoded (the temporal matched filter for phantom-stop precision); (4) confirm each stop with Δv≈−v_cruise plus a B-collapse dwell ≥ minimum duration, and require **one corroborator** (baro step / route-interval-contains-one-station) before anchoring. Feed only *confirmed* stops into the reachability layer as monotone advance-only anchors `U'(t)=min(U, s_travel[k*]+V_LINE·(t−τ))` with the most-advanced-reachable-station rule and a one-gap cap. Realistic handheld expectations: per-stop F1 ~0.90–0.95; dwell MAE ~5–10 s; exact count over 13–16 stations ~85–95% IMU-only, → ~99% with route-length/timetable/baro. **Validate on the two real Bengaluru Purple-line fixtures** and report brake-event SNR vs handling noise, per-stop P/R/count, and blind-window position error — never claim device proof from synthetic rides.

---

## 2. Attitude / gravity estimation & ZUPT — the low-pass braking trap (`sota_zupt_attitude`)

### Summary
A phone accelerometer measures specific force `f_b = R^T(a_lin_w − g_w)`; recovering linear acceleration requires knowing the gravity direction, and the naive method (low-pass `a_meas`) is **fundamentally broken** here because a sustained metro brake is a DC horizontal specific force in the *same low-frequency band* as a real tilt — a static LPF cannot separate them. A 1.0 m/s² brake tilts the LP gravity estimate by `atan(1.0/9.81)=5.8°` (0.087 g leakage), and for any gravity cutoff ≥0.05 Hz the LPF absorbs >95% of an 8–12 s brake within one event, so subtracting `ĝ` **erases the very brake signal we need** (`a_lin_hat → 0`). The fix: propagate gravity with the **gyro** (which reports ω≈0 during a straight-line brake, so it does not rotate gravity) and correct with the accelerometer **only in low-jerk / low-linear-accel windows** — exactly what Mahony, Madgwick, Valenti's adaptive-gain CF, and a quaternion ESKF do via a gated accel gain. Critical subtlety: **magnitude-only gating is necessary but insufficient** because a 1 m/s² brake changes `|a|` by only 0.5% (9.81→9.86); add a **jerk gate** plus a **gyro-consistency test**. Clean longitudinal accel then comes from `a_lin_w = R(q)a_meas − g_w`, take the horizontal part, recover the travel axis heading-agnostically by PCA and/or route-tangent projection; sign fixed by brake→dwell→launch. For stops, classical SHOE/ARED/MV/MAG detectors were built for foot-mounted IMUs and **mislead on handheld transit data** (dwells have MORE handling energy). Never-late is preserved by anchoring the reachability bound to confirmed stops via a min-of-upper-bounds construction with an asymmetric (precision-first) detector.

### Methods
| Name | Idea | Accuracy / bound | Applicability to GeoWake | Source |
|---|---|---|---|---|
| Mahony explicit complementary filter on SO(3) | Gyro propagates; correction `ω_mes = v_a × ĝ_b` with gain `k_P` + integral gyro-bias `−k_I ω_mes`; down-weight `k_P` during braking | Static tilt <1°, dynamic RMS ~1–2°; `k_P≈1.0, k_I≈0.3` | Cheapest robust attitude core; add jerk+gyro-consistency gate on `k_P` | https://hal.science/hal-00488376/document |
| Madgwick gradient-descent filter | Fuse `q̇_ω` with one normalized gradient step `−β∇f`, `∇f=J_g^T f_g`; `β=√(3/4)·gyro_error` | <0.8° static, ~1.7° dynamic RMS; `β≈0.033` | Lightweight; fixed β leaks braking — must schedule β down during high-jerk | https://courses.cs.washington.edu/courses/cse466/14au/labs/l4/madgwick_internal_report.pdf |
| Valenti adaptive-gain quaternion CF | Accel gain scaled by magnitude error `e_m=\|‖a‖−g‖/g` (1 below 0.1, ramp to 0 by 0.2) | ~0.5–1.5° RMS; robust to short spikes | Right mechanism but **insufficient**: a 1 m/s² brake gives `e_m=0.005`, never trips; must add jerk + gyro-consistency | https://www.mdpi.com/1424-8220/15/8/19302 |
| ESKF / quaternion kinematics (Solà) | Gyro-integrated nominal state + error state δθ; accel innovation `y=v_a−ĝ_b`, `K=PHᵀ(HPHᵀ+V)⁻¹`; inflate V on high jerk/inconsistency | Manifold-consistent ~1° attitude; yields covariance | Statistically optimal "correct only in low-jerk"; covariance feeds the reachability band | http://www.iri.upc.edu/people/jsola/JoanSola/objectes/notes/kinematics.pdf |
| SHOE/ARED/MV/MAG zero-velocity detectors (Skog GLRT) | `T=(1/W)Σ[(1/σ_a²)‖a−g·ā/‖ā‖‖² + (1/σ_ω²)‖ω‖²]`; declare ZV if `T<γ` | Foot-nav 0.14% distance error; `γ_SHOE≈8.5e7, γ_ARED≈0.55` | Built for foot-mounted; accel terms **mislead** on handheld (dwells have MORE energy). Use ARED-like gyro + rail-vibration-floor loss + brake-Δv | https://www.researchgate.net/publication/224198580_Evaluation_of_zero-velocity_detectors_for_foot-mounted_inertial_navigation_systems |
| Data-driven / LSTM zero-velocity detection | Learn the ZV classifier from IMU windows | Outperforms fixed-threshold SHOE across mixed gaits; needs labels | Path to a handheld-transit dwell classifier on real fixtures; keep inside the asymmetric-precision guard | https://arxiv.org/pdf/1910.00529 |
| Smartphone longitudinal-accel via PCA reorientation (Sensors 2018 18:2624) | After gravity removal, PCA of horizontal specific force: principal eigenvector = accel/brake axis; keep within 45°; sign fixes direction | Recovers vehicle longitudinal axis without absolute yaw | Heading-agnostic `a_L` recovery for long GPS-blind windows — key enabler for clean brake Δv | https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6111255/ |

### Full derivation

**Sensor model** (body frame b, world ENU w, `g_w=[0,0,−g]`, g=9.81):
```
a_meas(t) = R(q)^T (a_lin_w(t) − g_w) + b_a + n_a
```
A stationary phone reads `a_meas = R^T[0,0,+g]` (specific force points UP). To get `a_lin` we need `R(q)`, i.e. `ĝ_b = R(q)^T[0,0,1]`.

**1) The low-pass gravity contamination trap (quantified).** Naive `ĝ_b = LP(a_meas)` assumes `E[a_lin]=0`. Then `a_lin_hat_b = a_meas − ĝ_b = HP(a_meas)`. A metro service brake is a sustained horizontal decel `a_b` (typ. 1.0–1.3 m/s², emergency ≤1.3), lasting `T_b≈8–12 s` (e.g. 22 m/s → 0 at 1.2 m/s² = 18 s, 200 m). Its energy sits at `1/T_b ≈ 0.02–0.1 Hz`.

(a) *Tilt error.* If the LPF passes the brake (`τ_LP ≪ T_b`), `ĝ_b` absorbs `a_b`:
```
θ_err = atan(a_b / g).
a_b=1.0 → 5.82° (leakage 0.102 g ≈ 87 mG);  a_b=1.3 → 7.55°;  a_b=2.0 → 11.5°.
```
(b) *Brake-signal erasure (worse).* First-order LPF, `τ=1/(2πf_c)`; a brake step of amplitude `a_b` leaves residual `a_b·e^{−t/τ}`. Fraction destroyed by end of an 8 s event:
```
f_c=0.50 Hz (τ=0.32 s): 1−e^{−25} ≈ 100% erased.
f_c=0.10 Hz (τ=1.59 s): 1−e^{−5.0} = 99.3% erased.
f_c=0.05 Hz (τ=3.18 s): 1−e^{−2.5} = 91.8% erased (96% by 10 s).
```
⇒ **any gravity LPF with `f_c≥0.05 Hz` annihilates the metro brake.** Lowering `f_c` below the brake band (≪0.02 Hz) preserves the brake but leaves handling jitter in `ĝ` and lags real tilts by tens of seconds. This is a fundamental **bandwidth conflict**: braking and true tilt occupy the same 0.02–0.5 Hz band; no LTI low-pass can separate them. QED the trap.

**2) The fix: gyro propagation + gated accel correction.** A straight-line brake is a pure translation with `ω≈0`; the gyro reports no rotation, so gyro-propagated gravity stays put while the LPF wrongly rotates it by `θ_err`.

*Complementary-filter tilt intuition:* `θ̂_k = α(θ̂_{k−1} + ω_k Δt) + (1−α)θ_acc,k`, `α=τ/(τ+Δt)`.

*Mahony explicit CF on SO(3):*
```
ĝ_b = R(q̂)^T e_z = [2(q_x q_z − q_w q_y), 2(q_w q_x + q_y q_z), q_w²−q_x²−q_y²+q_z²]^T
v_a = a_meas / ‖a_meas‖
ω_mes = v_a × ĝ_b
ḃ = −k_I ω_mes            (k_I≈0.3)
ω_corr = ω_gyro − b̂ + k_P ω_mes   (k_P≈1.0)
q̇ = ½ q ⊗ [0, ω_corr];  q ← (q + q̇Δt)/‖·‖
```
*Madgwick gradient-descent:*
```
f_g(q,a) = [2(q_x q_z − q_w q_y) − a_x; 2(q_w q_x + q_y q_z) − a_y; 2(½ − q_x² − q_y²) − a_z]
J_g = [[−2q_y,2q_z,−2q_w,2q_x],[2q_x,2q_w,2q_z,2q_y],[0,−4q_x,−4q_y,0]]
∇f = J_g^T f_g
q_t = q_{t−1} + (½ q ⊗ [0,ω] − β·∇f/‖∇f‖)Δt, then normalize   (β=√(3/4)·ω̄_β)
```
β large ⇒ trust accel (braking leaks in); β small ⇒ trust gyro. The trap demands **β be adaptively reduced during braking**.

*Valenti adaptive gain:* `e_m = |‖a_meas‖ − g|/g`; factor 1 for `e_m<0.1`, linear→0 on [0.1,0.2], 0 above. **Critical critique:** a 1.0 m/s² brake gives `‖a_meas‖=√(9.81²+1.0²)=9.86`, `e_m=0.005 ≪ 0.1` ⇒ the gate **does not fire** — a brake barely changes `|f|` but rotates it. Required additions:
```
(i)  JERK GATE: correct only if ‖da_meas/dt‖ < ε_j.
(ii) GYRO-CONSISTENCY GATE: predicted gravity rotation over Δt is bounded by ∫‖ω‖dt.
     If accel direction moves more than that bound relative to gyro-propagated ĝ_b,
     the excess is LINEAR acceleration (the brake) — freeze the accel correction.
     Residual r = angle(v_a, ĝ_b) − ∫‖ω‖dt is a direct brake detector AND must never
     feed back into gravity.
Combined gate: correct only when |‖a‖−g|<ε_a (≈0.03 g) AND ‖ω‖<ε_ω AND ‖jerk‖<ε_j AND r<ε_r.
```
*ESKF (Solà):* same idea, optimal weighting — inflate the accel measurement covariance `V` (chi-square/Mahalanobis gating) when `|‖a‖−g|`, jerk, or gyro-inconsistency is high. This is the principled "correct only in low-jerk", and the covariance propagates into the position band.

**3) Clean longitudinal accel from a handheld phone.**
```
Step1: attitude via gated Mahony/ESKF → clean gravity (roll/pitch observable, yaw drifts).
Step2: a_lin_w = R(q)a_meas − [0,0,g]; horizontal part a_h=[a_E,a_N] free of the 9.81 pedestal
       AND free of LPF brake-erasure (gravity was gyro-propagated, so the brake SURVIVES).
Step3: recover the LONGITUDINAL axis without absolute yaw:
   (a) PCA of a_h over a 5–15 s window: C=(1/W)Σ(a_h−ā)(a_h−ā)^T; principal eigenvector û=travel axis
       (a coherent 1 m/s²×10 s brake dominates horizontal variance; broadband handling spreads
       incoherently). a_L = a_h·û. Sign by brake(−)→dwell→launch(+).
   (b) ROUTE PROJECTION (best): known oriented_polyline tangent t̂ gives a_L once a yaw anchor is set.
Step4: band-limit a_L: remove >~5 Hz handling jitter, KEEP 0.02–1 Hz (brake band). Do NOT high-pass
       below ~0.02 Hz or you re-erase the brake.
SNR: brake ≈1.0–1.3 m/s²; raw handling RMS ≈0.3–1.0 m/s² broadband → in-band (<1 Hz) ≈0.1–0.3 m/s²
     ⇒ in-band brake SNR ≈ 3–10×. Confirmed FULL STOP = ∫_brake a_L ≈ −v_cruise, reset at each station.
```

**4) ZUPT / dwell detectors (formulas + transit adaptation).** Classical foot-mounted over window `Ω_n` (Skog 2010):
```
MAG:  T = (1/(σ_a²W)) Σ (‖a_k‖−g)²
MV:   T = (1/(σ_a²W)) Σ ‖a_k−ā‖²
ARED: T = (1/(σ_ω²W)) Σ ‖ω_k‖²
SHOE (GLRT): T = (1/W) Σ [ (1/σ_a²)‖a_k − g·ā/‖ā‖‖² + (1/σ_ω²)‖ω_k‖² ]
Declare zero-velocity iff T < γ.  (foot: γ_SHOE≈8.5e7, γ_ARED≈0.55, σ_a≈0.01, σ_ω≈0.1745)
```
**Transit adaptation:** at a train dwell the passenger keeps handling the phone, so accel variance/energy does NOT drop — MV/MAG/SHOE(accel term) false-negative or misfire. Discriminative dwell features for a train: (i) **loss of the rail-vibration floor** `E_hf = RMS(a_meas, >15 Hz)`; (ii) **brake Δv match** `∫a_L ≈ −v_cruise`; (iii) ARED gyro energy (train yaw-rate ≈0 at stop / straight track). Dwell = HMM/matched filter over {cruise,brake,dwell,launch}, not a single SHOE threshold.

### Never-late implications
Gravity/attitude and ZUPT only enter never-late through **confirmed-stop anchors**, safe via min-of-upper-bounds. Keep the physics cone `s_max(t)=s0+V_LINE(t−t0)`. On a confirmed stop at station `k`, set `A(t)=s_travel[k]+V_LINE·(t−t_dwell[k])` and report `ŝ_up(t)=min(s_max(t),A(t))`. If station `k` is a true stop, `s_true=s_travel[k]` at `t_dwell[k]` and thereafter `s_true(t) ≤ A(t)`; also `s_true ≤ s_max`. Min of two valid upper bounds ⇒ `s_true ≤ ŝ_up ≤ s_max`: tighter than physics, never below truth. A **missed** stop drops `A(t)`, leaving `s_max` — safe, just looser. The only way to violate never-late is a **false-positive** stop anchoring to a not-yet-reached station. So the guarantee reduces to one rule: **tune the detector for near-zero false-positive stops** (extreme precision), accepting lower recall. The gravity fix matters here because the naive LPF's brake-erasure would destroy the brake-Δv evidence and cause *missed* stops (loss of tightening); the gyro-gated attitude estimate preserves the brake, raising recall without touching the precision-driven safety margin. Guard: only confirm `k` if `s_travel[k] ≤ s_max(t)` and take the largest cone-admissible dwell-confirmed station, so an anchor can only move `ŝ_up` backward/earlier (safe).

### Pitfalls
- Low-pass gravity **erases the metro brake** (>90% of an 8–12 s brake absorbed at f_c≥0.05 Hz). Never derive gravity by low-passing accel on this data.
- Magnitude-only accel gating does **not** catch braking (0.5% magnitude change). Must add a jerk gate and a gyro-consistency gate.
- Classical SHOE/MV/MAG assume the sensor is momentarily still; handheld passengers keep moving during dwell ⇒ accel-based ZUPT false-negatives. Use rail-vibration-floor loss + brake-Δv + ARED.
- Yaw is unobservable underground without a reliable magnetometer (steel tunnels distort it). Use PCA of horizontal specific force or route-tangent projection.
- Δv integration drifts if the window is long; integrate only over the ~10 s brake and reset at each confirmed station.
- A single **false-positive** stop is the only thing that makes the alarm late; tune for extreme precision.
- Do not over-high-pass `a_L` below ~0.02 Hz — it re-erases the brake.
- Synthetic fixtures cannot validate signal realism; brake-SNR (~3–10×) and dwell numbers must be measured on real Bengaluru rides.

### Recommendation
Adopt a quaternion **ESKF** (or gated Mahony CF fallback) and **never** estimate gravity by low-passing the accelerometer. Gate accel correction with a four-part test — `|‖a‖−g|<0.03g` AND `‖ω‖<ε_ω` AND `‖jerk‖<ε_j` AND gyro-consistency residual `r<ε_r`. Extract `a_L` by removing gyro-clean gravity, taking horizontal specific force, recovering the travel axis via PCA over 5–15 s and/or route-tangent projection, keeping the 0.02–1 Hz brake band. For stops, drop foot-mounted SHOE/MV/MAG in favor of a {cruise,brake,dwell,launch} HMM whose dwell evidence is rail-vibration-floor loss + brake Δv≈−v_cruise + low gyro energy. Feed only confirmed stops into the reachability cone as `min(s_max, anchored-bound)`; provably never-late with near-zero false-positive stops. Validate brake SNR and dwell P/R on the two real Bengaluru fixtures — the gyro-gated attitude fix is the specific mechanism that keeps the brake alive through the blind windows the naive LPF pipeline would have erased.

---

## 3. Non-inertial underground re-anchors — barometer / magnetometer / WiFi-BLE-cell (`sota_baro_mag_wifi`)

### Summary
Three handling-immune re-anchor families. (1) **Barometer** is the strongest reliable, offline, infrastructure-free signal: pressure is orientation/handling invariant, so a station-approach piston transient (~50–500 Pa at the platform, up to 1.5 kPa in tight tunnels) rides ~35–55 dB above modern MEMS-baro noise (BMP390 ≈0.9 Pa RMS, BMP581 ≈0.08 Pa; ~1 m/12 Pa resolution). M-Loc (accel+mag+baro + DTW tunnel fingerprinting) reports 93% correct station over 3 stops and 98% over 5 across 55 stations; Tokyo pressure-only hit 85% station-ID over 192 stations; Snips got >90% station-count and >90% direction-after-two-stops from baro peaks. (2) **Magnetometer** is universal and gives ~96% subway stop/departure detection (410/427) from the DC traction-current + ferromagnetic-mass signature, but it is orientation-dependent (must use `|B|` + gyro de-skew) and needs per-line/per-device fingerprints. (3) **WiFi/BLE/cell** is situationally the most accurate — a station AP/beacon fingerprint pins identity within ~30 m — but infrastructure-dependent, essentially absent mid-tunnel, throttled by Android scan limits, coverage unproven. For a handheld, offline, never-late core: **barometer top, magnetometer universal fallback, WiFi/BLE/cell opportunistic bonus.** All three are device-**unproven** on GeoWake today (no pressure/mag columns).

### Methods
| Name | Idea | Accuracy / bound | Applicability to GeoWake | Source |
|---|---|---|---|---|
| M-Loc — Ye, Gu, Tao, Lu, INFOCOM 2014 | Crowdsource accel+mag+baro per-tunnel fingerprints; DTW-match live trace to identify tunnel/station | 93% correct station over 3 stops, 98% over 5; 3 lines, 55 stations | DTW tunnel fingerprint = re-anchor between stops; monotone sequence maps to the never-late counter gate | https://arxiv.org/pdf/2003.10531 |
| SubwayAPPS (Air-Pressure Positioning) | Barometer relative-pressure changes detect stop/run and position underground | Barometer viable standalone with high multi-stop accuracy | Fully handling-immune, offline; gated by device barometer availability | https://link.springer.com/chapter/10.1007/978-3-319-47289-8_4 |
| At Which Station Am I? (Tokyo Metro) | Motion state from elevation change; match stopped-elevation series to per-station elevation map | 85% station-ID over 9 lines/192 stations; direction >90% after 2 stops (Bayesian) | Absolute station pinning from a per-station elevation table; GeoWake could add a baro-elevation prior | https://www.researchgate.net/publication/261316874 |
| Subway stop/departure via magnetic sensor — SIGSPATIAL 2018 | DC traction + ferromagnetic mass → characteristic `|B|` change per accel/brake cycle | ~96%: 410/427 stops, 3 false positives, 17 misses | Universal event anchor; 17 misses = safe missed-tightening; 3 FPs are the risk the never-late gate must suppress | https://dl.acm.org/doi/pdf/10.1145/3271553.3271614 |
| Snips underground tracking | Count stations from downward pressure peaks (Venturi/piston); direction from duration priors | >90% station counting; >90% direction after 2 stations; durations 43–53 s | Simplest DB-free variant: monotone counter that can only ADD tightening — safest possible re-anchor | https://medium.com/snips-ai/underground-location-tracking-3ea56803dddc |
| Transit app "Go Underground" (production) | Accel-only vibration signature (train ~5 Hz vs walk ~2 Hz) + schedule "Mixer" to count down stations | ~90% correct location; deployed at scale; no baro/mag | Confirms schedule fusion is the key multiplier (GeoWake's V_LINE + s_travel); but IMU+schedule is handling-sensitive | https://blog.transitapp.com/go-underground/ |
| WiFi/BLE station-AP fingerprint + leaky-feeder cell-ID | RSSI fingerprint pins station in range; tunnel DAS cell-ID + timing advance for coarse position | Station-level near-certain within ~30 m; tunnel cell-ID coarse (100s m) | Opportunistic hard anchor at platforms; not a never-late dependency (absent mid-tunnel; scan throttling) | https://arxiv.org/pdf/1904.01675 |

### Full derivation

**Never-late upper-bound proof for re-anchoring.** Let `s_true(t)` be true arc length, `V_LINE` certified max line speed, `s_travel[k]` known station arc-lengths. The fire decision uses a certified upper bound `s_hat(t) ≥ s_true(t)`. Alarm fires when `s_hat(t) ≥ S_dest − d_trigger`; since `s_true ≤ s_hat`, true remaining `S_dest − s_true ≥ d_trigger` at fire time ⇒ never late. Safety reduces to: does a re-anchor preserve `s_hat ≥ s_true`?

*(A) Physics propagation (no anchor).* Between anchors `s_hat(t)=s_hat(t_k)+V_LINE·(t−t_k)`. Because motion is speed-limited, `s_true(t)−s_true(t_k) ≤ V_LINE·(t−t_k)`. With the induction hypothesis `s_hat(t_k) ≥ s_true(t_k)`:
```
s_hat(t) = s_hat(t_k)+V_LINE(t−t_k) ≥ s_true(t_k)+(s_true(t)−s_true(t_k)) = s_true(t). QED
```
A **missed** detection never breaks safety — `s_hat` keeps growing per physics, merely stays loose.

*(B) Station re-anchor (the only way a soft signal can decrease `s_hat`).* On a detection claiming arrival at `k` we set `s_hat ← s_travel[k]`. If TRUE, `s_true=s_travel[k]`, equality holds. The hazard is a **false-earlier** detection naming station `j` with `s_travel[j] < s_true`: then `s_hat ← s_travel[j] < s_true`, violating the bound. Hence the **certification gate** — accept an anchor only if ALL hold:
```
(i)   monotone counter: k ≥ last_anchor_index (no snapping backward);
(ii)  never-increase-by-soft-signal: s_hat ← max(s_min(t), min(s_hat(t), s_travel[k]))
      so a soft signal can only LOWER s_hat toward truth, down to the certified lower bound
      s_min(t) (last confirmed station's arc-length, since progress is monotone on a line);
(iii) timing consistency: elapsed since last anchor ≥ d[k−1,k]/V_LINE;
(iv)  confidence: match posterior P(correct) ≥ 1 − eps.
```
Under (i)–(iv) the residual event that a wrong-earlier anchor is committed has probability ≤ eps per station, union-bounded to `N·eps` over an N-station leg. From the magnetic FP rate (3/427 = 7.0e-3 raw; the false-*earlier* subset after gates (i),(iii) is far smaller), `N·eps` is negligible.

**SNR / handling-immunity bound (why baro is cleanest).** A sealed MEMS pressure reading is invariant to orientation and shake, so the handling-noise term that kills `|accel|` ZUPT is ~0 for pressure. Signal `A_sig ∈ [50, 500] Pa`; noise `σ_p ~ 0.9 Pa` (BMP390):
```
SNR = 20·log10(A_sig/σ_p) = 35 to 55 dB.
```
Slow confounds (weather drift <~0.5 Pa/min, HVAC) are removed by a high-pass/differential over the ~20–60 s inter-station window, leaving the transient and the per-station relative-elevation fingerprint (station depth Δ 5–30 m ⇒ 60–360 Pa ≫ σ_p) as clean, near-binary arrival anchors.

### Never-late implications
Re-anchoring is safe **iff** a station anchor can only *lower* the certified upper bound `s_hat` toward truth and never below the monotone lower bound `s_min(t)`. Formally `s_hat ← max(s_min(t), min(s_hat(t), s_travel[k]))`, accepted only under the four gates. Then the physics lemma is preserved, a **missed** detection only loosens tightening (never late), and the only late-fire pathway is a **false-earlier** anchor with probability ≤ eps per station (≤ `N·eps` over the leg). Barometer is preferred precisely because its handling-immunity drives eps lowest (near-binary piston transient, no orientation confound); magnetometer's 3/427 raw FP rate is acceptable only after the timing+monotone gates; WiFi/BLE, when present, is the strongest single confirm and can reset eps to near-zero at platforms.

### Pitfalls
- Barometer is **not on all Android phones** (mostly mid/high-end); if the test device lacks one, magnetometer becomes primary.
- Current fixtures log only accel+gyro — all three signals are **device-unproven** on GeoWake's real data; validating requires new logging, not a re-run.
- Barometer confounds: weather drift, HVAC pressurization, door transients; absolute station-ID needs a per-line elevation DB (arrival-*event* counting is DB-free).
- Bengaluru Purple line is largely **elevated** — depth-fingerprinting only helps in the Majestic underground stretch; on elevated track pressure adds little.
- Magnetometer is orientation-dependent: use `|B|` + gyro de-skew and per-device hard/soft-iron calibration; fingerprints transfer poorly across models.
- WiFi/BLE/cell: essentially no mid-tunnel signal without leaky-feeder/DAS; Android throttles WiFi scans (~4/2 min since Android 9); coverage unverified.
- False-earlier station anchors are the single late-fire mechanism — never fuse a re-anchor as a raw position write; always route through the gate + clamp.

### Recommendation
Rank: (1) **Barometer** primary handling-immune re-anchor (35–55 dB SNR, offline, 85–98% station-ID) in the Majestic underground blind windows to reset `s_hat` to `s_travel[k]`. (2) **Magnetometer** universal fallback/corroborator (~96%) via `|B|` + gyro de-skew + per-device cal. (3) **WiFi/BLE/cell** opportunistic platform-only hard confirm, never a dependency. Fuse all three **only** through the never-late gate — a re-anchor may lower `s_hat` to truth but never below `s_min`, never raise it, must pass monotone-index + min-travel-time + confidence. **Action before any claim:** add barometer + magnetometer logging and record 2–3 real Purple-line underground rides. If the target device has no barometer, promote magnetometer to primary. Cheapest safe first step: DB-free barometer peak-counting (Snips-style) as a monotone station counter — it can only ADD tightening, so it is provably never-late even before any fingerprint DB exists.

---

## 4. Pedestrian Dead Reckoning (PDR) (`sota_pdr`)

### Summary
Smartphone PDR decomposes displacement into (step detection) × (step-length) × (heading) instead of double-integrating acceleration — which makes walking fundamentally MORE tractable than vehicle/train DR: each footfall has a quasi-stationary stance phase that bounds velocity drift (the ZUPT principle), quantizing motion into ~0.6–0.8 m increments, whereas a train/car never returns to zero velocity so raw double integration diverges cubically. Step detection reaches >95–99% count accuracy for firmly-held/pocketed phones on flat ground but degrades badly for a loose handheld. **Step-length models are the dominant error source:** Weinberg `L=K·⁴√(a_max−a_min)` and Kim `L=K·∛(mean|a|)` show ~2.8–9% relative distance error with a personally-calibrated K, but 20–24% with a generic K; velocity-adaptive / PCA / ML models cut this to ~1–5%. **Heading, not step length, dominates long-run position error:** raw MEMS gyro drifts ~1–10°/min; fused <4° indoors but corrupted by tunnel magnetic interference. Handheld PDR gives ~2–5% distance error over short spans but position error grows roughly linearly-to-superlinearly with distance. **Decisive caveat: PDR is only valid on WALKING segments; on the moving train the handheld accel is human-handling noise with no steps, so step-counting must be gated off by a mode classifier** — the train blind-window position must come from the trapezoidal/reachability model, not PDR.

### Methods
| Name | Idea | Accuracy / bound | Applicability to GeoWake | Source |
|---|---|---|---|---|
| Weinberg step-length | `L=K·(a_max−a_min)^{1/4}` (peak-to-peak vertical, one K) | ~2.8–9.1% with personal K; ~20% generic | Cheapest walk-segment model; use `K_hi` upper-confidence variant for the never-late bound | https://pmc.ncbi.nlm.nih.gov/articles/PMC5038701/ |
| Kim step-length | `L=K·((1/N)Σ\|a_i\|)^{1/3}` (cube-root mean abs accel) | ~20–24% generic, comparable calibrated | Less peak-sensitive, marginally more robust to handling spikes | https://pmc.ncbi.nlm.nih.gov/articles/PMC5038701/ |
| Scarlett | Min, max AND mean vertical accel, extreme-normalized | few-% tuned; body-worn | Better if pocket/chest; needs placement assumption handheld violates | https://www.researchgate.net/publication/224198572_Comparison_and_evaluation_of_acceleration_based_step_length_estimators_for_handheld_devices |
| Velocity-adaptive Weinberg K(v) | `K(v)=0.68−0.37v̄+0.15v̄²` | ~4.2–4.9% vs ~20–24% fixed-K | Best classical trade-off; auto-adapts slow shuffle vs brisk walk | https://pmc.ncbi.nlm.nih.gov/articles/PMC5038701/ |
| Context/personalized (2024) | Context-assisted personalized regression | 0.5–2%, avg ~1.1% | SOTA accuracy, needs per-user calibration; not conservative by default | https://www.tandfonline.com/doi/full/10.1080/10095020.2024.2338225 |
| Step detection: peak / ZC / autocorr / spectral | Threshold / sign-changes / gait-period / dominant-freq | >95–99% firm/flat; degrades loose handheld; autocorrelation most robust | Use autocorrelation/adaptive-threshold; tune to recall=1 for never-late | https://arxiv.org/pdf/2407.21676 |
| Threshold-free / ML step detection | Learned/adaptive detection for unconstrained phones | Handles varied postures | Needed because GeoWake phone is handheld | https://www.mdpi.com/1424-8220/18/1/297 |
| Heading: gyro+mag Kalman / PCA of horizontal accel | Integrate yaw, correct with mag; or PCA principal horizontal axis | Raw gyro ~1–10°/min; fused <4° @80th pct; corrupted by interference | Irrelevant to the 1-D never-late bound; only 2-D display | https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6022069/ |
| ZUPT | Reset velocity to 0 during stance each step | Foot-mounted sub-1% of distance | Why walk-mode is tractable; hard to exploit handheld but motivates step-quantization | https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6766805/ |
| Map-matching / particle-filter closure | Constrain PDR to corridors / GPS re-acquire | Map-aided PF ~0.9 m mean vs ~6.3 m raw | The along-route projection IS a 1-D map-match | https://www.mdpi.com/2220-9964/14/12/476 |

### Full derivation

**Step-length models** (vertical accel `a_z`, extremes `a_max/a_min`, N samples/step):
```
1) Weinberg (field standard):  L = K·(a_max − a_min)^{1/4}
   (inverted-pendulum leg length ℓ, horizontal step ≈ 2√(2ℓh−h²) ≈ K·h^{1/2}, bounce h ~ accel
    amplitude, empirically fourth-root of peak-to-peak accel; K≈0.4–0.6 person/placement dependent)
2) Kim:  L = K·((1/N) Σ_{i=1..N} |a_i|)^{1/3}
3) Scarlett:  L = K·[ (Σ|a_i|)/N − a_min ] / (a_max − a_min)
4) Constant/linear:  L = K·h·f_step   or   L = α + β·f + γ·σ_a
5) Velocity-adaptive:  L = K(v)·(a_max − a_min)/4,  K(v) = 0.68 − 0.37v̄ + 0.15v̄²  (~4.2–4.9% error)
6) ML/PCA: regress L from per-step window (~1–3%, needs training, risks non-conservative extrapolation)
```
**Position update (2-D):**
```
x_k = x_{k−1} + L_k·cos(ψ_k),   y_k = y_{k−1} + L_k·sin(ψ_k)
ψ_k = gyro-integrated yaw ∫ω dt, mag-corrected, or PCA of horizontal accel
```
**Error growth:**
```
Along-track:  d_err ≈ Σ (L_k − L̂_k) ≈ (ΔK/K)·distance  (2–10% of distance)
Cross-track from constant heading bias δψ over distance D:  lateral ≈ D·sin(δψ) ≈ D·δψ
Gyro drift rate r (rad/s): δψ(t)=r·t → cross-track ≈ ∫ v·r·t dt = ½·v·r·t²  (QUADRATIC in time)
```
This (not step length) is why raw PDR "blows up" over minutes.

**Never-late upper-bound proof (PDR as a reachability tightener).** Let `s_true(t)` be true along-route progress. Reachability gives `s_phys(t)=s0+V_LINE·(t−t0) ≥ s_true(t)`. Construct a PDR UPPER bound on walked distance:
```
d_upper(t) = Σ_{k: step confirmed} L_k^hi,  L_k^hi = K_hi·(a_max−a_min)^{1/4}, K_hi = K̄+zσ_K,
AND step detection tuned for recall=1 (never miss a real step; false positives only inflate the bound).
```
*Claim:* `d_upper(t) ≥ d_true(t)` w.p. ≥ 1−α. *Proof:* per-step `P(L_k^hi ≥ L_k^true) ≥ 1−α` by the one-sided K bound; missed steps (the only way to under-count) are excluded by recall=1; extra steps only add nonnegative terms. So `Σ L_k^hi ≥ Σ L_k^true = d_true`. □

*Tightened estimate:* `s_tight(t) = min( s_phys(t), s0 + d_upper(t) )`. Both are upper bounds on `s_true`; min of two upper bounds is an upper bound: `s_tight ≥ s_true`. Firing when `s_tight ≥ s_target` never fires late. □

**Critical scope:** this holds only where PDR measures the SAME motion as `s` (the pedestrian's own along-route walk). It does NOT hold on the train (PDR would under-count → violate the bound). A **mode gate is mandatory**: apply the PDR term only in walk mode; in train mode fall back to `s_phys` alone.

### Never-late implications
PDR can only **tighten** the reachability cone on walking segments, and only if made one-sided-conservative: (a) step detection at **recall=1** (a missed step under-counts and risks a late fire — false-positive steps are harmless, they only inflate the bound); (b) an **upper-confidence** step-length coefficient `K_hi`; (c) heading is **irrelevant** to the 1-D along-route bound (arc-length cares about distance magnitude, not direction) — so tunnel magnetic interference does NOT threaten the guarantee, only the point-accuracy. The `min(s_phys, s0+d_upper)` fusion is proven never-late. Hard boundary: PDR **must** be gated to walk mode; applying step-counting to handheld-on-train data would under-count and break the bound. Net: PDR is a legitimate cone-tightener for the station-walk portions (shrinking worst-case early-fire when the rider is on foot near/at the destination), but contributes **nothing** to the train blind-window problem — the fixtures' actual headline challenge.

### Pitfalls
- Applying step-counting to handheld-on-train IMU reads handling noise, not gait — under-counts and **breaks** the never-late bound. Mode gate mandatory.
- Generic (uncalibrated) K gives ~20% error; personalize or use velocity-adaptive K(v).
- Loose handheld phone violates the firm-attachment / vertical-axis assumption; pocket/body-worn accuracy claims do not transfer and are device-unproven until measured.
- Heading drift + tunnel magnetic interference wreck 2-D point accuracy — but do NOT affect the 1-D never-late bound; don't over-invest in heading for the guarantee.
- Non-conservative ML/personalized models can under-estimate distance on out-of-distribution gaits, silently violating the upper bound; only one-sided upper-confidence coefficients are safe.
- ZUPT's sub-1% comes from FOOT-mounted IMUs; a handheld lacks a clean stance-phase zero-velocity signal.

### Recommendation
Treat PDR as a **walk-mode-only cone tightener, never a train estimator**. Implement: (1) a mode classifier (still/walk/train) that gates step-counting strictly to walk mode; (2) autocorrelation/adaptive-threshold step detection tuned to recall=1; (3) velocity-adaptive Weinberg `L=K(v)·(a_max−a_min)^{1/4}` with an upper-confidence `K_hi=K̄+zσ_K`; (4) fuse as `s_tight=min(s_phys, s0+Σ L_hi)`, provably never-late. Skip heading for the safety guarantee (the 1-D bound is direction-free); add gyro/mag/PCA heading only for a 2-D display. Honest verdict: on the real Bengaluru fixtures the rider is on the **train** during blind windows, so PDR does essentially nothing for the headline blind-window position — that must be solved by the trapezoidal/HMM physics. Any pocket/foot-mounted accuracy number is device-unproven for GeoWake's loose-handheld case until measured on the fixtures.

---

## PART II — ESTIMATION ARCHITECTURE

## 5. Map-matched / route-constrained inertial navigation — collapsing 2-D DR to 1-D arc-length (`sota_mapmatch_pf`)

### Summary
The decisive move: stop estimating a 2-D/3-D pose and parameterize state purely by **arc length along the known route** — `x=[s, ṡ]`, where `s` indexes the polyline and full pose is recovered by a map function `f(s)`. This is a hard equality constraint (perpendicular distance ε=0); by the **Simon & Chia (2002) estimate-projection theorem**, projecting the unconstrained estimate onto the constraint surface yields `P̃ = P − PDᵀ(DPDᵀ)⁻¹DP ⪯ P` — the cross-track variance is annihilated and only along-track uncertainty survives. This is why a ~15–30 m circular GPS/DR error collapses to a ~1-D error the width of the track. On real trams von Einem report RMSE 4.78 m and 94.9% track selectivity vs 10.63 m for an unconstrained EKF; Heirich (RBPF+GNSS+IMU+track map) keeps tunnel error bounded via curvature/yaw-rate map-aided DR; indoor "don't-walk-through-walls" PDR PFs reach ~1.35 m RMSE over 336 m; onboard metro IMU+track-geometry fusion reports <1% along-track error. The core sensing insight: **turns are large-signal event anchors** — the map defines a curvature signature `κ(s)`, and measurement models `z_ω = ṡ·κ(s)` and `z_alat = ṡ²·κ(s)` let each bend and each station (virtual balise / ZUPT) sharply re-localize `s`. For a single underground line the hard part of railway RBPFs (parallel-track / switch multi-hypothesis) disappears, leaving a clean 1-D filter; never-late is preserved by clamping the constrained band to the physics bound `s_hi(t)=min(s_max(t), ŝ+zσ_s)`.

### Methods
| Name | Idea | Accuracy / bound | Applicability to GeoWake | Source |
|---|---|---|---|---|
| Path-constrained EKF in curve coords `[s,ṡ]` (von Einem) | 1-D state on track geometry; pose via `f(s)`; Euclidean measurements projected via `ρ()`; outlier gate on ε | RMSE 4.78 m, 94.9% track selectivity vs 10.63 m unconstrained (~2× reduction) | Directly the recommended core; `f/ρ` are cheap polyline projections; single line → no multi-hypothesis | https://arxiv.org/pdf/2308.12082 |
| RBPF GNSS+IMU+track map (Heirich 2016) | Non-strapdown IMU; centripetal accel + yaw rate for along-track; particles handle switch nonlinearity; virtual balises | Keeps DR error bounded through tunnels; loosely-coupled, low-cost IMU | Blueprint for blind-window propagation; RBPF over-engineered for a single line → collapse to plain 1-D PF | https://onlinelibrary.wiley.com/doi/10.1155/2016/2672640 |
| Estimate-projection constrained KF (Simon & Chia 2002) | Project unconstrained estimate onto equality-constraint surface each step | `P̃ = P − PDᵀ(DPDᵀ)⁻¹DP ⪯ P` — cross-track variance annihilated | Formal justification the polyline pin strictly reduces error; underpins the never-late clamp | https://engagedscholarship.csuohio.edu/enece_facpub/158/ |
| Map-constrained "don't walk through walls" PDR PF | PDR propagates particles; forbidden-region weight 0; corridor-heading snap | 2-D RMSE 1.35 m over 336.6 m; 3-D endpoint 2.45 m (0.46%) over 536.5 m | "Forbidden ⇒ w=0" maps to "clamp s to [prevStation,nextStation]"; corridor snap = turn-to-bend anchoring | https://pmc.ncbi.nlm.nih.gov/articles/PMC9698600/ |
| Onboard metro IMU + track-geometry fusion | Single MEMS IMU; curvature/turn features map-matched to along-track location | <1% avg along-track error underground | Confirms curvature-signature anchoring for exactly GeoWake's setting; `κ(s)` from polyline is the matchable feature | https://researchwith.njit.edu/en/publications/onboard-metro-train-localization-based-on-the-train-motion-and-tr/ |
| Train track-change detection via IMU yaw rate | Detect turnout/bends from transient yaw-rate signatures | IMU-only switching-event discrimination (qualitative) | Yaw-rate pulses as robust anchors that survive handheld noise | https://www.mdpi.com/2624-8921/8/4/80 |
| Subway arrival/departure via linear accelerometer | Sustained decel→dwell→accel pattern (matched-filter/HMM), position-independent | Demonstrated arrival/departure from a phone accelerometer | Confirmed stops = ZUPT/virtual-balise anchors that re-zero drift and give certified lower bounds | https://dl.acm.org/doi/10.1145/3307334.3328635 |

### Full derivation

**1) State-space 1-D reduction (Frenet / curve coordinates).** Route polyline `P(s)`, arc length `s∈[0,L]`. Map function (von Einem Eq.1):
```
(x_w, y_w, θ_w, ẋ_w, ẏ_w) = f(s, ṡ | map),   θ_w = atan2(dP_y/ds, dP_x/ds) = θ_map(s).
Inverse:  (s, ṡ, ε_pos, ε_vel) = ρ(x_w, y_w, ẋ_w, ẏ_w | map).
Constrained state:  x = [s, ṡ]ᵀ   (2 DOF, was 4–6). The 2D→1D collapse IS the constraint ε_pos ≡ 0.
```

**2) Cross-track collapse — projection theorem (Simon & Chia 2002).** Unconstrained 2-D estimate `p̂=(x,y)`, covariance `P`. Local frame: tangent `t̂`, normal `n̂`. On-route equality `D p = d` with `D = n̂ᵀ`:
```
p̃ = p̂ − P Dᵀ (D P Dᵀ)⁻¹ (D p̂ − d)
P̃ = P − P Dᵀ (D P Dᵀ)⁻¹ D P.
```
Since `P Dᵀ(DPDᵀ)⁻¹DP ⪰ 0`, `P̃ ⪯ P` (Löwner order): constrained covariance never larger, strictly smaller in `n̂`. Hard-constraint limit `σ_n²→0`; residual = along-track `σ_t`. `√(σ_t²+σ_n²)` (≈ GPS hacc) → `σ_t`. Single track ⇒ unambiguous projection, cross-track half removed with zero wrong-track risk.

**3) Motion model (1-D CV + jerk-limited trapezoidal prior).**
```
x_{k|k-1}=F x_{k-1}, F=[[1,Δt],[0,1]],  P_{k|k-1}=F P Fᵀ + Q,
Q = q_j·[[Δt³/3, Δt²/2],[Δt²/2, Δt]].
Metro prior: ṡ follows a trapezoid; feasibility box ṡ∈[0,V_LINE], s monotone, s∈[s_prevStation, s_nextStation].
```

**4) Measurement models (IMU projected to curve coordinates).**
```
(a) Longitudinal specific force as ODOMETRY: a_long ≈ s̈ → ṡ_k = ṡ_{k-1} + a_long,k Δt + η_a.
(b) YAW-RATE / CURVATURE anchor: κ(s)=dθ_map/ds precomputed.
      z_ω    = ṡ·κ(s)   + n_ω        (gyro yaw rate)
      z_alat = ṡ²·κ(s)  + n_a        (lateral/centripetal accel)
    h(x)=[ṡκ(s); ṡ²κ(s)], H=∂h/∂x with ∂/∂s = ṡκ'(s). A yaw pulse's likelihood peaks where κ(s) matches.
(c) STATION / dwell anchor (virtual balise + ZUPT): confirmed stop → ṡ≈0 ∧ s≈s_travel[k].
(d) GPS (not blind): s_gps=ρ(lat,lng); z=s_gps, σ_s²=(hacc·t̂)², H=[1,0].
Outlier gate (Eq.7): accept if ε_pos ≤ κ_gate√S; else reject and inflate P.
```

**5) Particle filter (1-D on-route).** Particles `x^(i)=(s^(i),ṡ^(i))`, weights `w^(i)`.
```
PROPAGATION (feasibility-clamped):
  ṡ^(i)_k = clip( ṡ^(i)_{k-1} + (a_long,k + η_a^(i))Δt , 0, V_LINE )
  s^(i)_k = s^(i)_{k-1} + ṡ^(i)_k Δt     (monotone ⇒ forward-only)
WEIGHT (product over anchors):
  w^(i)_k ∝ w^(i)_{k-1} · ∏ p(z|x^(i))
   yaw:     N(z_ω ; ṡ^(i)κ(s^(i)), σ_ω²)
   station: N(dist(s^(i),{s_travel}); 0, σ_stn²)·1[ṡ^(i)≈0]
   GPS:     N(s^(i); s_gps, σ_s²)
   off-route: w=0 if s outside [prevStation, nextStation] box
RESAMPLE when N_eff = 1/Σ(w^(i))² < N/2 (systematic).
ESTIMATE: ŝ=Σw^(i)s^(i); report weighted-quantile BAND [s_lo, s_hi], not a point.
```

**6) Event anchors as a matched filter (turns ↔ polyline bends).** Precompute `θ_map(s)` and `κ(s)=Δψ_j/Δℓ_j` per vertex (smooth with an arc-length spline BEFORE differencing — finite differences on a 429/495-pt polyline amplify noise). Integrate measured yaw `ψ_meas(t)=∫ω_z dt`. Cross-correlate cumulative measured heading against `θ_map(·)` over candidate arc-length offsets; the lag maximizing correlation = current `s`. Each sharp bend and each station dwell is a distinctive, large-signal anchor that survives handling noise — rely on anchors + the trapezoidal timing prior, never open-loop position.

### Never-late implications
**Invariant:** fire no later than true arrival, using the most-advanced plausible progress (an upper bound on `s_true`). Physics ceiling (α=0): `ṡ ≤ V_LINE` ⇒ `s_max(t)=s0+V_LINE(t−t0) ≥ s_true(t)` (hard bound). Fused fire bound: `s_hi(t) = min( s_max(t), ŝ(t) + z·σ_s(t) )`, `z` chosen so `P(s_true > ŝ+zσ_s) ≤ α`. Because `s_max` is a hard bound, the composite fails to upper-bound truth only in `{ŝ+zσ_s < s_true} ∧ {ŝ+zσ_s < s_max}`, so `P(late) ≤ α`. **Graceful degradation to α=0:** whenever anchor confidence is low, set tightening off ⇒ `s_hi = s_max` ⇒ exact physics guarantee. A missed detection only inflates the band toward `s_max` (monotone dominance) — never a late fire. **The one danger** = a false-positive equality anchor (matching a turn to an earlier identical bend, or ZUPT-snapping to a not-yet-reached station) pinning `s` too low ⇒ late. Three gates neutralize it (all cheap on a single line): (1) forward-monotonic gating; (2) Mahalanobis innovation gate `κ_gate√S`; (3) keep `min(s_max,·)` as ceiling plus a confirmed-stop lower bound (a certified full stop at `k` proves `s_true ≥ s_travel[k]` — only makes firing earlier). Net: the route constraint shrinks worst-case early-firing (~2× RMSE reduction) while the min-clamp keeps the never-late proof intact.

### Pitfalls
- False curvature match on repetitive geometry (two similar bends, or a loop) pins `s` too low ⇒ LATE. Mitigate with forward-monotonic gating, Mahalanobis gate, station-box clamp, and keeping the PF multi-modal until a bend is unambiguous.
- `κ(s)` from a coarse polyline is noisy — fit an arc-length spline and differentiate that; expect few usable bend anchors on near-straight metro segments ⇒ lean on stop-count + trapezoidal timing.
- The yaw-rate model `ω=ṡκ` assumes the gyro yaw axis is vertical; handheld tilt means you MUST run attitude/gravity estimation first or the curvature anchor mismatches.
- Longitudinal double-integration drifts unboundedly — only a between-anchor bridge under the trapezoidal prior with zero-velocity-at-station reset.
- A single global `V_LINE` clamp can be too loose; use segment-wise `V_LINE` from schedule/geometry — but only tighten with certified bounds.
- Constraining to the polyline before confirming you are on it (cold start in a blind window) can lock onto the wrong arc-length; require an initial GPS/station anchor to seed `s`, keep the band = full feasible box until seeded.
- Equality (snap) anchors reduce covariance aggressively — over-trusting makes the filter overconfident and `s_hi` too tight; inflate σ after each snap and retain the `min(s_max,·)` ceiling.

### Recommendation
Adopt a single-track **1-D route-constrained particle filter** with state `x=[s, ṡ]` on GeoWake's `oriented_polyline` (32–200 particles ample for 1-D), rather than the RBPF/multi-hypothesis EKF of the railway literature — a single line has no parallel-track/switch ambiguity. Precompute `κ(s)` from a smoothed arc-length spline and station arc-lengths `s_travel` as virtual balises. Propagate `ṡ` from tangent-projected longitudinal specific force under a jerk-limited trapezoidal prior with feasibility clamps; update weights from three anchor types (yaw-rate/curvature, confirmed-stop ZUPT to nearest `s_travel`, GPS when not blind). This buys the ~2× along-track reduction and cross-track annihilation the constrained filters demonstrate. Wire firing to `s_hi(t)=min(s_max(t), ŝ(t)+zσ_s(t))` so the never-late bound is preserved by construction. Validate along-track error through the two real fixtures' blind windows against `s_travel`/`arrival_t_s`, and report the credible band, never a point. Honest caveat: on metro, inter-station segments are often nearly straight, so curvature anchors are sparse — underground accuracy leans heavily on stop-count/ZUPT anchors and the trapezoidal timing prior, exactly where handheld attitude quality becomes the limiting factor and must be proven on the real IMU.

---

## 6. Car dead-reckoning in tunnels/parking (`sota_car_dr`)

### Summary
A phone in a car in a tunnel/parking is the classic land-vehicle DR problem; the field converged on the **Reduced Inertial Sensor System (RISS)**: heading from the single vertical (yaw) gyro and forward speed from a longitudinal odometer/accelerometer, fused under the **non-holonomic constraint (NHC)** that lateral/vertical body velocity ≈ 0. This collapses unbounded 3-axis double-integration into ONE scalar speed integration plus ONE heading integration — the same structure as the train. Free 2-D DR error is heading-dominated: an uncompensated gyro bias `b_g` gives cross-track error `δy ≈ b_g·D²/(2v)` (0.055°/s → ~5%/km at city speed). Phone-only speed aiding (no wheel tap) is solved by learned pseudo-odometers: **OdoNet** (RMSE 0.49 m/s, 68% error cut over 60 s outages), **VeTorch** (placement-invariant TCN), **DMDVDR** (<0.5% of distance; 0.64% drift over 578 m). The decisive GeoWake simplification: the route is KNOWN, so projecting onto the destination polyline (degenerate 1-D Newson-Krumm HMM) makes cross-track heading error irrelevant and leaves only `s(t)` — the train's reachability problem. Unlike a train's fixed stations, a car's anchors are (a) **turns matched to known polyline bends** (hard fixes) and (b) **stop-start ZUPTs** at lights (reset speed drift, demote error growth from cubic to linear). A never-late-safe `V_LINE` for a car on a known route is a per-segment **physical** speed ceiling (legal limit + margin, capped by curvature `v≤√(a_lat,max·R)`), which upper-bounds true progress and admits the same monotone tightening proof.

### Methods
| Name | Idea | Accuracy / bound | Applicability to GeoWake | Source |
|---|---|---|---|---|
| RISS (Iqbal, Okou & Noureldin) | 1 vertical gyro heading + forward odometer/accel speed; 3D-RISS `p=arcsin((a_f−a_od)/g)` decouples brake force from gravity leak | Bounded through GNSS outages w/ map-matching; ~1–2% unaided (heading-limited) | Reference car motion model; no odometer → learned pseudo-odometer + route projection + ZUPT | https://www.mdpi.com/1424-8220/11/4/4244 |
| Non-Holonomic Constraint (NHC) | Assert body lateral+vertical velocity ≈ 0 as a zero-pseudo-measurement | Cuts free-INS drift; pseudo/wheel odometer adds ~68–74% | Core to reducing car to scalar speed; must model phone-in-car mounting angle | https://link.springer.com/article/10.1007/s10291-023-01483-9 |
| OdoNet — learned pseudo-odometer (i2NAV) | 1-D CNN maps an IMU window to forward speed (software wheel-odometer) | Speed MAE 0.315, RMSE 0.490 m/s (0–25 m/s); ~68% outage error cut vs NHC-only | Direct along-route speed from handheld IMU; its RMSE sets the arc-length band width | https://arxiv.org/abs/2109.03091 |
| VeTorch / "Glow in the Dark" (Gao & Xiao) | TCN learns vehicle motion, transforms phone→vehicle frame regardless of placement | Real-time in tunnels/garages; ~0.5–0.6% of distance | Handles "phone loose at any orientation" the DATA_CONTRACT flags | https://ieeexplore.ieee.org/document/9372287/ |
| DMDVDR — data+model-driven DR | Hybrid learned + physics vehicle position from phone inertial only | <0.5% of distance; 0.64% drift over 578 m GPS loss | Best quantitative anchor for expected along-route error in a ~500 m–1 km descent: single-digit meters | https://www.eurekalert.org/news-releases/1089377 |
| ZUPT at stop-start | Detect stationary intervals, inject v=0, calibrate bias | Demotes error growth CUBIC → LINEAR | Every red light is a free error reset; detection must survive handheld noise (HMM/matched filter) | https://navi.ion.org/content/70/4/navi.608 |
| Newson & Krumm HMM map-matching | Match noisy position to road graph (Gaussian emission, transition plausibility) | >95% correct-segment | For a KNOWN single route degenerates to 1-D orthogonal projection — converts 2-D DR to scalar reachability | https://www.microsoft.com/en-us/research/wp-content/uploads/2016/12/map-matching-ACM-GIS-camera-ready.pdf |
| Classical gyro-drift automotive DR law | `δy ≈ b_g·D²/(2v)` | 0.055°/s → ~5%/km, ~25%/5 km | Quantifies why FREE 2-D car DR is untrustworthy; known-route projection cancels cross-track | https://metisengineering.com/dead-reckoning-technology-maintaining-vehicle-position-accuracy-during-gps-signal-loss/ |

### Full derivation

**1) Kinematic bicycle (non-holonomic) model.** State (rear-axle): `x, y, θ, v`, steer `δ`, wheelbase `L`.
```
ẋ = v·cosθ ;  ẏ = v·sinθ ;  θ̇ = ω = (v/L)·tanδ
```
NHC: body-frame lateral & vertical velocity = 0 ⇒ velocity is always aligned with heading; only forward scalar `v` is free. Integrate ONE scalar for speed and ONE gyro channel for heading.

**2) RISS / phone mechanization.** No `δ`, so use measured yaw rate:
```
θ(t) = θ0 + ∫ ω_z dt           (heading; body-z ≈ vertical after attitude comp)
v(t) = v0 + ∫ a_long dt         (speed from gravity-compensated longitudinal specific force)
s(t) = ∫ v dt                    (arc length)
[x,y](t) = [x0,y0] + ∫ v·[cosθ, sinθ] dt
```
*Gravity-leak trap:* `a_long = a_body,x − g·sin(pitch)`. 3D-RISS decouples via the odometer: `p = arcsin((a_f − a_od)/g)`. A phone with **no odometer** cannot form `a_od`, so brake force and pitch/gravity residual are confounded — why phone-only forward-accel is hard and NHC + ZUPT + route projection are load-bearing.

**3) Error-growth derivation.**
```
(a) CROSS-TRACK (heading/gyro-bias dominated). With bias b_g, δθ(t)=b_g·t. Straight run at speed v:
    δy(t) = ∫₀ᵗ v·sin(δθ) dt' ≈ v·∫₀ᵗ b_g·t' dt' = ½·v·b_g·t².  With D=v·t:  δy = b_g·D²/(2v).
    VALIDATION: b_g=0.055°/s=9.6e-4 rad/s, v=10 m/s, D=1000 m (t=100 s):
       δy = 9.6e-4·1e6/(2·10) = 48 m ≈ 5% of distance (matches "0.055°/s → 5%/km").
       At v=15 m/s ≈ 32 m (~3.2%/km). Error grows as D²/v: heading error is the killer for FREE 2-D DR.
(b) ALONG-TRACK (speed/accel-bias). δv=b_a·Δt, δs=½·b_a·Δt². Pure INS grows CUBICALLY; a ZUPT resets
    δv→0, demoting to LINEAR. City cadence Δt≈30–60 s; b_a=0.03, Δt=45 s ⇒ ~30 m unaided,
    → a few meters with per-stop ZUPT + NHC + learned speed (~0.5–1%/dist).
```

**4) Route projection → 1-D (the GeoWake collapse).** Known polyline `P(s)`; map-matching degenerates to orthogonal projection `s* = argmin_s ‖[x,y] − P(s)‖`. Cross-track heading error `δy` is absorbed by projection (moves off the polyline, snaps back) and does not corrupt `s*` to first order; it only injects `O(δy·κ)` second-order along-track error. The alarm-relevant quantity is scalar `s(t)` — identical to the train.

**5) Anchor structure (car vs train).**
```
Train: fixed stations at known s_i, arrival dwell → hard (position+velocity) fixes.
Car:
  • TURN-MATCH (HARD position anchor): sustained yaw ∫ω_z dt ≈ Δψ_k matches a known vertex at s_k;
    detecting the k-th distinguishable turn → set s := s_k. The CAR ANALOG OF A STATION.
  • STOP-START ZUPT (velocity anchor): |v|→0 at a light → δv:=0. Location not known a priori,
    so a bare stop is a SOFT position anchor; HARD only if co-located with a known intersection.
```

**6) Never-late V_LINE model for a car on a known route.**
```
v_cap(s) = min( v_legal(s)·(1+m),  √(a_lat,max·R(s)),  V_abs )
   (a_lat,max ≈ 4–6 m/s² comfort/grip; a curve physically caps speed at √(a_lat,max·R))
s_max(t) = s0 + ∫_{t0}^{t} v_cap(s_max(τ)) dτ   (≥ the single-slope train form with V_LINE = sup v_cap)
```

**7) Never-late upper-bound proof.** *Claim:* with `s_max` as above, `s(t) ≤ s_max(t)` ∀t, so firing when `s_max ≥ s_target − wake_margin` is never late. *Proof.* Physical constraint `v(t) ≤ v_cap(s(t))`. Let `e(t)=s_max(t)−s(t)`, `e(t0) ≥ 0`. Then `ė = v_cap(s_max) − v(t) ≥ v_cap(s_max) − v_cap(s)`. Using the interval-supremum `v̄_cap(s_max) := sup_{σ∈[s_last, s_max]} v_cap(σ)`, `ė ≥ 0` whenever `e=0`; by Grönwall/comparison, `e(t) ≥ 0 ∀t`. ∎ *Monotone tightening:* IMU anchors only move `s_max` DOWN — a confirmed ZUPT caps speed to 0 (tightens); a matched turn resets `s_max := max(s_k, s)`. A **missed** detection leaves `s_max` at the looser higher value = still a valid upper bound. No IMU event can push `s_max` below true `s`; detection **false-negatives cost early-firing margin but never a late fire**. ∎

### Never-late implications
The car case reduces **exactly** to the train's 1-D reachability invariant once projected onto the known route. The one structural difference to respect: a train's `V_LINE` is a genuine physical cap, whereas a car's legal limit is a **legal** cap a speeder can exceed. To keep a hard guarantee, `V_LINE_car` must be a physically/absolutely defensible ceiling — `legal_limit×(1+margin)` AND curvature-capped `√(a_lat,max·R)` on bends AND an absolute road cap — never the bare posted limit. Turn-matches act as hard station-like anchors; stop-start ZUPTs bound along-track drift and act as soft anchors (hard only if co-located with a known intersection). Any IMU tightening is downward-only and false-negative-safe, so a missed turn/stop only sacrifices early-firing tightness. Practical worst-case early-firing margin ≈ (segment length between turn anchors) × (`v_cap/v_typical − 1`) plus speed-estimate uncertainty (~0.5 m/s RMS).

### Pitfalls
- Legal speed limit is NOT a physical cap: using `v_legal` directly risks a LATE fire. Use `v_legal×(1+margin)`, curvature cap, absolute ceiling.
- Gravity-leak is worse than the train: no odometer to form `a_od`, so RISS pitch-decoupling is unavailable; gate gravity correction to low-jerk windows.
- Turn-matching is ambiguous on routes with many similar-angle bends; a mis-match is a hard position error. Require distinguishable turn angles + spacing; treat low-confidence turns as soft anchors.
- ZUPT false positives from handheld jostling at cruise, and false negatives at a stop where passengers keep moving (the "stops have MORE energy" problem applies to cars too). Use an HMM/matched filter, not `|accel|` thresholding.
- Phone mounting-angle drift breaks NHC; needs online phone-to-vehicle rotation estimation (VeTorch-style) or NHC injects a systematic cross-track bias.
- OdoNet-class estimators degrade badly >20 m/s — lean harder on the reachability cap on high-speed tunnels.
- Underground helical parking ramps (large sustained yaw, low speed) may not be a simple polyline; out-of-route → fall back to a loose reachability cone, not a false tight fix.
- Route projection injects second-order along-track error `O(δy·κ)` at sharp bends; keep the cross-track gate (reject projections beyond a few×σ).

### Recommendation
Model car mode as **RISS-on-a-phone projected onto the known destination polyline**, collapsing it to the SAME 1-D never-late reachability problem as the train — reuse the cone/GLMT machinery. (1) Heading `θ=∫ω_z dt`, forward speed `v` from a learned pseudo-odometer (~0.5 m/s RMS) under NHC, gravity-corrected only in low-jerk windows. (2) Orthogonally project the DR pose onto the polyline for scalar `s(t)`, cancelling the dominant cross-track error. (3) Set `V_LINE` as a per-segment PHYSICAL ceiling `v_cap(s)=min(v_legal·(1+margin), √(a_lat,max·R(s)), V_abs)` — never the bare posted limit; propagate `s_max`. (4) Use TWO anchor types: turn-matches as hard station-like re-fixes (only when distinguishable), and stop-start ZUPTs as velocity resets (hard position anchors only when co-located with a known intersection). Expected along-route accuracy through a 500 m–1 km descent is single-digit meters (DMDVDR 0.64%/578 m), inside a wake margin, provided the max-speed ceiling is physical. Honest caveat: SOTA-plausible and derivation-sound but device-unproven on GeoWake's handheld car fixtures; highest-risk assumptions are turn-match uniqueness, ZUPT robustness to in-car human motion, and the speeding-driver speed cap.

---

## PART III — MATHEMATICAL FOUNDATIONS

## 7. Train kinematics: jerk-limited/trapezoidal profile & tightened never-late bound (`math_train_kinematics`)

> **Rigor check (verifier: sound = FALSE, never_late_holds = FALSE).** The derivation is largely correct but **voids the never-late guarantee in one place** and must be corrected before use. See the Rigor check box at the end of this section for the four required corrections; the most important is that the **terminal braking envelope must use the LARGEST plausible achievable deceleration (an upper bound on brake authority), not the guaranteed-available lower bound** — symmetric with `a_max` being an upper bound on acceleration. The text below is the original derivation; read it *together with* the corrections.

### Summary
Rest-to-rest inter-station motion is modeled two ways: (a) the physically-realistic seven-segment jerk-limited S-curve the real train follows, and (b) its `J→∞` limit, the three-phase trapezoid (accel-cruise-brake), which the never-late cone must use. Pontryagin's Maximum Principle confirms the time-optimal (max-reach) regime is bang-bang. The crude bound `s_max=s0+V_LINE(t−t0)` is valid (`v≤V_LINE`) but loose (Nallur `V_LINE=22.2 m/s` vs realized leg average ~9.7 m/s). Two rigorous tightenings: (i) **confirmed-dwell subtraction** `s_max=s0+V_LINE·((t−t0)−W_conf)`, valid iff `W_conf ≤ W_true`; (ii) **terminal must-stop braking envelope** `v(s)≤√(2·d_max·(s_B−s))`, forcing speed to zero approaching `s_B`. Combined with the departure ramp `v(s)≤√(2·a_max·(s−s_A))` and `v≤V_LINE`, every admissible trajectory rides below the same phase-plane envelope, so the time-optimal trapezoid dominates pointwise. The final never-late bound is the **min of individually-valid upper bounds**, monotone in the set of confirmed detections. The departure ramp tightens the cruise cone by `V_LINE²/(2·a_max) ≈ 247 m`; the terminal envelope begins ~224 m before each station; each confirmed 20–30 s dwell removes ~440–670 m of over-count.

### Methods
| Name | Idea | Accuracy / bound | Applicability to GeoWake | Source |
|---|---|---|---|---|
| Seven-segment jerk-limited S-curve | Bounded-jerk trajectory (up to 7 phases); `a=a0+J·t`, `v=v0+a0·t+½Jt²`, `s=s0+v0·t+½a0·t²+(J/6)t³` | Reduces to trapezoid as J→∞; comfort jerk 0.7–1.0 m/s³ adds ~a_max/J ≈ 1–1.4 s/transition | EXPECTED/estimate profile for predicted timing & IMU jerk-signature fitting; NOT the cone | https://www.pmdcorp.com/resources/type/articles/get/mathematics-of-motion-control-profiles-article |
| Three-phase trapezoid (accel-cruise-brake) | J→∞ limit; `D_crit=(V_LINE²/2)(1/a_max+1/d_max)` splits full vs triangular | Time-optimal `T_min=D/V_LINE+(V_LINE/2)(1/a_max+1/d_max)` | SAFE never-late cone: over-estimates reachable position vs any jerk-limited real train | https://www.mdpi.com/2071-1050/17/24/11371 |
| Pontryagin / bang-bang time-optimal (MA/CR/CO/BR) | Optimal regimes: max-accel, cruise, coast, max-brake; max-reach is bang-bang | Establishes the trapezoid as the pointwise upper envelope | Justifies `s_true(t) ≤ s_opt(t)` | https://www.sciencedirect.com/science/article/abs/pii/S0377221716307962 |
| Phase-plane braking parabola / must-stop envelope | `v(s)≤√(2·d_max·(s_B−s))`; with departure ramp and V_LINE gives `v_env(s)` | Braking begins at `s_B − V_LINE²/(2·d_max)` (~224 m); v→0 at s_B | Terminal tightening: flattens the cone before the station | https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10093331 |
| Forward reachable set / control-invariant bound | Min of individually-valid upper bounds is a valid tighter bound, monotone in evidence | Soundness (≥truth) + graceful degradation to crude line | Formal backbone for the never-late-under-detection-error proof | https://hybrid-robotics.berkeley.edu/publications/CBVF.pdf |
| Passenger-comfort accel/decel/jerk limits | ISO/empirical: `|a|,|d|~1.1–1.5 m/s²` (caps 2.0/3.5), jerk `±1 m/s³` | Service metro `a_max~1.0–1.3, d_max~1.1–1.3` | Parameterizes `V_LINE=22.2 m/s` (80 km/h) and the constants | https://link.springer.com/article/10.1007/s40864-015-0012-y |

### Full derivation (equations preserved)

**Part A — speed/position profile between two stations.** Leg data: departs A at `(s_A, t_A)` at rest, arrives B at `(s_B, t_B)` at rest. `D = s_B − s_A`. Limits: `a≤a_max`, `|a|≤d_max` (brake), `|v|≤V_LINE`, `|da/dt|≤J`.

*A.1 Trapezoidal (J→∞):* three phases — accelerate at `a_max` to peak `V_p`, cruise, brake at `d_max` to 0.
```
Accel:  t1 = V_p/a_max,   d1 = V_p²/(2 a_max)
Brake:  t3 = V_p/d_max,   d3 = V_p²/(2 d_max)
Cruise: d2 = D − d1 − d3, t2 = d2/V_p
Critical distance:  D_crit = (V_LINE²/2)·(1/a_max + 1/d_max).
(1) FULL TRAPEZOID (D ≥ D_crit):  V_p = V_LINE.
(2) TRIANGULAR (D < D_crit):  V_p = V_tri = √( 2D·a_max·d_max/(a_max+d_max) ) = √( 2D/(1/a_max+1/d_max) ).
Closed-form (u=t−t_A, s from s_A):
  Phase 1, 0≤u≤t1:            v = a_max·u,             s = 0.5·a_max·u²
  Phase 2, t1≤u≤t1+t2:        v = V_p,                 s = d1 + V_p·(u−t1)
  Phase 3, t1+t2≤u≤T (w=u−t1−t2): v = V_p − d_max·w,   s = d1 + d2 + V_p·w − 0.5·d_max·w²
Min leg duration:
  FULL:      T_min = D/V_LINE + (V_LINE/2)·(1/a_max + 1/d_max)
  TRIANGLE:  T_min = √( 2D·(1/a_max + 1/d_max) )
```
*A.2 Jerk-limited seven-segment S-curve (real train):* segments [1] jerk +J, [2] const a_max, [3] jerk −J, [4] cruise, [5] jerk −J, [6] const −d_max, [7] jerk +J.
```
Per segment:  a(t)=a0+J·t,  v(t)=v0+a0·t+0.5·J·t²,  s(t)=s0+v0·t+0.5·a0·t²+(J/6)·t³.
Accel ramp time to a_max: T_j = a_max/J; velocity in the two ramps: dv_ramp = a_max²/J.
  If V_p ≥ a_max²/J: a_max reached; const-accel Ta=(V_p − a_max²/J)/a_max; accel-side = Ta + 2·T_j.
  If V_p <  a_max²/J: triangular accel; peak a_pk=√(J·V_p)<a_max; each ramp √(V_p/J).
The trapezoid A.1 is the exact J→∞ limit.
```
**Key modeling split:** S-curve = EXPECTED profile (arrival timing + IMU jerk fitting); trapezoid = never-late CONE (bounded jerk only makes the real train SLOWER, so the trapezoid reaches every position no later: `s_scurve(t) ≤ s_trap(t)`). Using the comfort S-curve as the bound would UNDER-estimate reachable position and risk a late fire.

*Numbers (Namma Metro, 80 km/h):* `V_LINE=22.2 m/s`; `a_max~1.0–1.3, d_max~1.1–1.3, J~0.7–1.0`. Nallur leg `D=1600 m, a_max=1.0, d_max=1.1`: `D_crit=487 m < 1600` → full trapezoid; `T_min = 72.1+21.2 = 93 s` pure running vs realized ~166 s. *(See Rigor check: `D_crit` should be ~470 m.)*

**Part B — never-late along-route upper bound.**

*B.0 Crude bound.* `s_max^0(t) = s0 + V_LINE·(t−t0)`. Proof: `v(t)≤V_LINE ⇒ s_true(t)=s0+∫v dt ≤ s0+V_LINE(t−t0)`. QED.

*B.1 Departure accel ramp (from a confirmed rest).* `v(t)≤a_max·(t−t0)` AND `v≤V_LINE`:
```
s_max^acc(t) = s0 + min( 0.5·a_max·(t−t0)² , V_LINE·(t−t0) − V_LINE²/(2 a_max) ).
```
Sits below the crude line by `V_LINE²/(2 a_max)` (~247 m for V_LINE=22.2, a_max=1.0). *(See Rigor check: rewrite as a piecewise bound.)*

*B.2 Terminal must-stop braking envelope.* Must rest at `s_B` with brake `≤d_max`; stopping distance `v²/(2 d_max)` must fit:
```
v(s) ≤ v_brake(s) = √( 2 d_max·(s_B − s) )   → 0 as s→s_B.
Combined phase-plane envelope:  v_env(s) = min{ √(2 a_max (s−s_A)),  V_LINE,  √(2 d_max (s_B−s)) }.
Cruise begins at s_A + V_LINE²/(2 a_max); braking begins at s_B − V_LINE²/(2 d_max) (~224 m, d_max=1.1).
```
**Pointwise-domination theorem:** for every admissible trajectory `s_true(t) ≤ s_opt(t)`. Proof: for any `s∈[s_A,s_B]`: (a) `v²(s)=2∫a ds ≤ 2 a_max(s−s_A)`; (b) `v≤V_LINE`; (c) `v²(s) ≤ 2 d_max(s_B−s)`. Hence `v(s) ≤ v_env(s)`. First-passage `T(s)=∫_{s_A}^{s} ds'/v(s') ≥ ∫ ds'/v_env(s') = T_opt(s)`. So every trajectory reaches each position no earlier than the optimal profile ⇒ `s_true(t) ≤ s_opt(t)`. QED.

*B.3 Confirmed-dwell subtraction.* `W_conf(t)` = time in `[t0,t]` the HMM confirms stationary.
```
s_true(t) = ∫_{moving} v dt ≤ V_LINE·((t−t0) − W_true(t)).
Bound: s_max^dwell(t) = s0 + V_LINE·((t−t0) − W_conf(t)).
Validity REQUIRES W_conf(t) ≤ W_true(t) (conservative under-estimate). Over-estimating dwell → LATE (FORBIDDEN).
```
*B.4 Combined bound.* `s_max(t) = min{ s_max^acc(t), s_max^dwell(t), s_opt(t; confirmed s_A,s_B), s_B }.` Each argument is individually a proven upper bound; min is a valid tighter bound.

**Part C — never-late under detection error.** Let `A` = set of confirmed events/anchors used (subset of TRUE events, conservative timing).
```
Lemma 1 (Soundness): if every anchor genuine and every dwell under-counted, s_max(t;A) ≥ s_true(t) ∀t.
Lemma 2 (Monotonicity): if A' ⊆ A (a detection MISSED), then s_max(t;A') ≥ s_max(t;A).
THEOREM: for any subset of confirmed detections, s_max(t) ≥ s_true(t); a missed dwell/arrival/anchor only
         RELAXES the bound upward (toward crude s0+V_LINE(t−t0)), never below true progress → the alarm can
         only become MORE conservative (earlier), never late.  Worst case A'=∅ → crude bound, still valid.
```
**Crucial asymmetry:** a tightening enters `min()` only if provably `≥ s_true` at its detection-confidence extreme. Over-tightening (over-counted dwell, phantom station anchor, false at-rest anchor) is the only way to break never-late and is excluded by construction. Detection **false-negatives are safe**; only **false-positives/over-estimates** are dangerous.

### Never-late implications
The invariant survives all three tightenings because the final bound is a **minimum of terms each independently proven to dominate true progress**, each valid at the pessimistic edge of its detection confidence. (1) Departure accel ramp is unconditionally valid and buys ~247 m of cruise tightening. (2) Terminal braking envelope forces `v→0` approaching `s_B`, collapsing the cone ~224 m before the station — the single biggest safe tightening near the destination. (3) Dwell subtraction is valid only as a conservative under-estimate; each confirmed dwell removes ~440–670 m. **Design rule (strict):** only false-negatives are tolerated (Lemma 2 relaxes upward); false-positives are the only failure mode and must be excluded — detectors tuned for high precision. Use the **trapezoid** (J→∞), NOT the comfort S-curve, for the cone.

### Pitfalls
- Using the comfort S-curve as the never-late CONE under-estimates reachable position and can fire LATE — the cone must use the trapezoid.
- Over-counting dwell breaks never-late (`W_conf > W_true`). Only conservative under-estimates are admissible; a handheld's dwell has MORE motion energy, so a naive `|accel|` ZUPT over-triggers dwell (the dangerous FP direction).
- Phantom/false station anchors placing `s_B` too close, or an at-rest departure anchor asserted while moving, over-tighten and can fire late; favor precision over recall.
- Only `min()` over terms EACH `≥ s_true` preserves the bound; averaging, or min-ing a point estimate (the S-curve position), voids the guarantee.
- `V_LINE` must be the design cap (22.2 m/s), not the realized average (~9.7 m/s).
- The braking-envelope tightening assumes the next station `s_B` is correctly identified; on express/skip runs, only apply the terminal cap to a CONFIRMED scheduled stop.
- Gradients/regen fade change effective `a_max/d_max`. *(See Rigor check — the direction of the safe bound on `d_max` was originally stated wrong.)*

### Recommendation
Two-model split. (1) ESTIMATE: seven-segment jerk-limited S-curve for predicted timing & IMU jerk matched-filtering. (2) SAFETY CONE: the trapezoidal time-optimal profile `s_opt(t)` as the never-late upper bound, built as `s_max(t)=min{ departure ramp; dwell bound with W_conf a strict under-estimate; terminal envelope from v_env(s); hard cap s_B }`. Apply the braking parabola only to CONFIRMED next stops. Enforce in code: a candidate tightening enters `min()` only if unit-proven to dominate `s_true` at its worst-case detection confidence; tune all detectors for high precision. Validate by replaying the Nallur/Majestic fixtures and confirming `s_max(t) ≥ s_true(t)` pointwise with shrunken slack vs the crude line.

> **Rigor check — required corrections (verifier flagged the derivation as unsound / never-late NOT holding as written):**
> 1. **Terminal braking envelope must use the LARGEST plausible achievable deceleration** (an *upper* bound on brake authority, including downgrade/regen assist), **NOT** the guaranteed-available lower bound. This is symmetric with `a_max` being an upper bound on acceleration. This single change restores the never-late guarantee the original text voided by recommending "guaranteed-available `d_max` (a lower bound)". *(A lower-bound `d_max` makes the braking parabola `√(2 d_max (s_B−s))` too low, forcing the cone below feasible trajectories that brake harder — a late-fire path.)*
> 2. **Rewrite B.1 as an explicit piecewise bound:** `s0 + 0.5·a_max·(t−t0)²` for `(t−t0) ≤ V_LINE/a_max`, and `s0 + V_LINE·(t−t0) − V_LINE²/(2·a_max)` afterward. The compact `min(quad, linear)` form is wrong in the launch region.
> 3. **Correct `D_crit` to ~470 m** for `a_max=1.0, d_max=1.1` (= 247 + 224), replacing the stated 487 m.
> 4. **For the max-reach cone, cite the three-regime TIME-optimal (bang-bang max-accel / cruise-at-cap / max-brake) result; drop the coasting regime**, which belongs to energy-optimal train control and only lowers reachable position.

---

## 8. Stop-counting HMM + 1-D-on-route particle filter, never-late from the cloud (`math_particle_hmm`)

> **Rigor check (verifier: sound = FALSE, never_late_holds = FALSE).** The **HMM half is sound and should be kept**; the **never-late claim and the particle-filter safety plumbing are broken** as originally derived. Ten problems and six corrections are recorded in the Rigor check box at the end. Read the derivation *only together with* those corrections — in particular, do **not** read the never-late bound off a Monte-Carlo tail quantile.

### Summary
Two coupled estimators. (a) A left-to-right cyclic **HMM** over {C=cruise, B=brake, D=dwell, L=launch} whose transition matrix zeroes every edge except the physical cycle `C→B→D→L→C`, so any Viterbi decode is a well-formed sequence of stops and the count `N` equals the number of `B→D` transitions; emissions are Gaussians on signed longitudinal `a_L` times a rail-vibration-energy feature `e` — `e` separates dwell from handheld-noisy cruise, defeating the naive `|accel|` ZUPT. A dwell upgrades to a **confirmed station** only when the brake integrates to `Δv≈−v_cruise` and `e` collapses. (b) A **particle filter** on arc-length `(s,v)` with a jerk/accel-limited motion model and station/launch/baro/WiFi/GPS likelihoods; multiplying a broad prior by a narrow station bump collapses the along-track std from O(10²–10³ m) to `σ_stat≈5–15 m`, re-zeroing DR error every confirmed stop. *Originally proposed* never-late trigger `U(t)=min(s_max(t), Q_{1−α}(s))` — **this is where the verifier found the flaw; use the corrected deterministic-envelope trigger below instead.**

### Methods
| Name | Idea | Accuracy / bound | Applicability to GeoWake | Source |
|---|---|---|---|---|
| MetroEye (HMM underground metro-trip inference) | Accel/mag/baro features → Markov/HMM station-event inference | High station-inference accuracy underground (MobiQuitous 2016) | Precedent for an HMM station/dwell detector; motivates {C,B,D,L} + multi-feature emissions | https://tik-old.ee.ethz.ch/file/365ee27a42f71d6b5cd7212571f7185b/mobiquitous16-gu.pdf |
| Detecting Arrivals/Departure via linear accelerometer | Decel→stop→accel sequence identifies a station stop | ~96%: 410/427 detected, 3 false, 17 missed (multi-sensor incl. baro) | Empirical SOTA recall (~0.96) that sets α and the corroboration policy *(see correction: not uniformly 0.96)* | https://dl.acm.org/doi/10.1145/3307334.3328635 |
| London Underground footprint matching (Sensors 2019) | Match accel footprint against inter-station timing to place the passenger | Real-time footprint matching to stations | Validates the decel-dwell-accel ordering + travel-time association prior `π_m` | https://www.mdpi.com/1424-8220/19/19/4184 |
| Crowdsourced Smartphone Sensing in Metro Trains | Crowdsourced accel/baro to localize station/segment | Segment/station-level localization | Supports baro + accel anchoring, inter-station segment modeling | https://arxiv.org/pdf/2003.10531 |
| Bayesian train localization w/ PF, GNSS, IMU, track map (Heirich) | 1-D map-matched PF; separates linear 1-D transition from nonlinear map transition | Track/switch selectivity *(see correction: NOT "sub-5 m over 21.6 km")* | Core precedent for the (s,v) 1-D-on-route PF and map-collapse; low-speed/cold-start caveat is our pitfall | https://onlinelibrary.wiley.com/doi/10.1155/2016/2672640 |
| Particle Filter for 1-D underground localization (PDR) | 1-D PF constrained to a known path, DR-propagated | Meter-level 1-D on constrained paths | Template for the arc-length-constrained PF and DR-between-anchors | https://ieeexplore.ieee.org/document/8867679 |
| Path-Constrained State Estimation for Rail Vehicles | Constrain estimate to the 1-D rail path (arc-length) | Cross-track error → map accuracy | Formal basis for collapsing 2-D to (s,v) on oriented_polyline | https://arxiv.org/pdf/2308.12082 |
| Passenger-comfort longitudinal accel & jerk limits | Comfortable accel/decel & jerk envelopes bound the motion model | ~0.11–0.15 g (~1.08–1.47 m/s²); jerk ~±1 m/s³ | Sets `a_max≈1.2 m/s², j_max≈1 m/s³` and the sentinel envelope | https://link.springer.com/article/10.1007/s40864-015-0012-y |
| Smartphone MEMS barometer altitude resolution (BMP390) | ~1 m relative altitude at 0.1 mbar, differential use | ~1 m; drifts with weather/HVAC/piston | Justifies `σ_h≈1–2 m` for baro anchor; station data-association only | https://pmc.ncbi.nlm.nih.gov/articles/PMC6720727/ |

### Full derivation (equations preserved)

**Part (a) — HMM for stop counting.** States `S = {C, B, D, L}`. Features windowed from ~50 Hz IMU to ~1–2 Hz frames (window `W≈0.5–1.0 s`, 50% overlap).
```
OBSERVATION o_k = (a_L,k , e_k , g_k):
  a_L,k = signed longitudinal specific force on the track axis, after gravity removal (gyro-propagated
          attitude, accel-corrected only in low-jerk windows) and polyline-tangent/PCA projection.
          a_L<0 brake, ~0 cruise/dwell, >0 launch.
  e_k   = rail vibration energy = variance of 3–15 Hz band-passed vertical+lateral accel over W.
          HIGH while rolling, near-zero when physically stopped. THE dwell/cruise separator (since a_L≈0 for both).
  g_k   = gyro yaw-rate energy over W, a gate to down-weight windows corrupted by large handheld rotations.

TRANSITION MATRIX (illegal edges = 0):
           to:  C     B     D     L
   from C  [ a_CC  a_CB   0     0  ]
        B  [  0    a_BB  a_BD   0  ]
        D  [  0     0    a_DD  a_DL]
        L  [ a_LC   0     0    a_LL]
   → every legal path is a concatenation of C…B…D…L…C cycles; STOP COUNT N = #(B→D transitions).

EMISSION (conditional Gaussian/GMM, gyro-gated):
  p(o_k|x_k=s) = N(a_L,k; μ_s, σ_s²)·N(e_k; ν_s, τ_s²)·guard(g_k)
  μ_C=0, μ_B=−a_brake(≈−1.0), μ_D=0, μ_L=+a_acc(≈+1.0);  ν_C,ν_L high, ν_B moderate-falling, ν_D = floor.
  Because μ_C=μ_D=0, ONLY the e-term separates cruise from dwell — the whole defense against naive-ZUPT failure.

FORWARD:  α_k(s) = [ Σ_{s'} α_{k−1}(s') A_{s',s} ]·p(o_k|s);  γ_k(s)=α_k(s)/Σ α_k;  "dwelling now?" = γ_k(D).
VITERBI:  δ_k(s)=max_{s'}[δ_{k−1}(s') A_{s',s}]·p(o_k|s); backtrack → path → N=#(B→D edges).

STATION CONFIRMATION: over the B-run, Δv=∫ a_L dt (event only 5–15 s). CONFIRMED iff Δv≈−v_cruise AND e→floor.
  (Refinement: HSMM/explicit-duration — dwell~Gamma(15–40 s), brake~5–15 s — removes geometric-duration bias.)
```

**Part (b) — 1-D-on-route particle filter, state `x=(s,v)`.** Particles `{x_i=(s_i,v_i,a_i)}`, weights `w_i`, N≈500–2000, augmented with per-particle accel for a jerk limit.
```
PREDICT (jerk/accel/speed limited), step Δt:
  j_i ~ N(0, σ_j²)
  a_i,k = clip( a_i,k−1 + j_i Δt , −a_max, +a_max )     a_max≈1.2 m/s²
  v_i,k = clip( v_i,k−1 + a_i,k Δt , 0 , V_LINE )
  s_i,k = s_i,k−1 + v_i,k−1 Δt + ½ a_i,k Δt²             [SEE CORRECTION: use trapezoidal s += ½(v_{k−1}+v_k)Δt]
  IMU coupling: γ_k(B) high → bias j_i,a_i negative; γ_k(L) high → positive; γ_k(D) high → force v_i→0.

UPDATE  w_i ← w_i·L_i, normalize wh_i = w_i/Σ w_j.  Anchors:
  (1) Confirmed-station bump:  L_i = Σ_m π_m·N(s_i; S_m, σ_stat²)·N(v_i; 0, σ_v0²)   σ_stat≈5–15 m
  (2) Launch anchor: departure at S_m resets DR at known s.
  (3) Baro:  L_i = N( h(s_i) − h_meas ; 0, σ_h² ),  σ_h≈1–2 m
  (4) WiFi/cell: fingerprint → same bump; cell-ID handoff → box likelihood over an s-interval.
  (5) GPS (not blind):  N( proj(lat,lng)→s ; s_i, σ_gps² )
  Resample (systematic) when ESS = 1/Σ wh_i² < N/2.
  Estimates: sh = Σ wh_i s_i; quantiles from weighted empirical CDF.

POSTERIOR COLLAPSE AT A CONFIRMED STATION:
  Prior p⁻(s) broad (std σ⁻ ~ σ_j·T during a blind run); ℓ(s)=N(s; S_m, σ_stat²); p⁺ ∝ p⁻·ℓ.
  If p⁻ locally flat over ℓ's support, p⁺ ≈ N(S_m, σ_stat²). Kalman form:
     σ⁺ = ( 1/σ⁻² + 1/σ_stat² )^{−1/2} ≈ σ_stat  (σ_stat ≪ σ⁻).
  → each confirmed station RE-ZEROES along-track error to ~σ_stat; DR re-accumulates only over ONE gap
    (~ σ_j·T_gap², T_gap~60–120 s), not the whole line.
```

**Never-late upper bound from the cloud (ORIGINAL — flawed, see Rigor check).**
```
Reachability:  s_max(t)=s0+V_LINE·(t−t0) ≥ s_true(t) (prob 1).
Weighted empirical CDF Fh(x)=Σ wh_i·1[s_i≤x]; upper quantile Q_{1−α}=inf{x: Fh(x)≥1−α}.
TRIGGER:  U(t) = min( s_max(t), Q_{1−α}(t) );  fire when U(t) ≥ s_dest − d_lead.
THEOREM (claimed): if PF calibrated so P(s_true ≤ Q_{1−α}) ≥ 1−α (*), then U(t) ≥ s_true w.p. ≥ 1−α, U ≤ s_max.
   PROOF: s_max ≥ s_true (1); Q_{1−α} ≥ s_true w.p. 1−α (2); min(A,B)≥x ⇔ A≥x ∧ B≥x → (3). □
```
The verifier showed **(\*) is an unproven PF-calibration assumption, not a theorem**, and that the `min`-with-`s_max` clamp adds **zero** never-late safety (it can only lower `U`). The corrected trigger is below.

**Corrected trigger (from the Rigor check).**
```
U(t) = min( s_max_protected(t),  s_upper(t) ), where
  (i)  s_upper is a DETERMINISTIC upper support maintained by a sentinel set EXEMPT from weighting/resampling,
       descending past a station ONLY on ≥2 independent corroborators (Δv≈−v_cruise AND e-floor AND baro/WiFi);
  (ii) s0 for the reachability line is re-anchored on the SAME corroboration with a one-sided margin
       (anchor to S_m only when the train is provably at-or-past S_m; else keep max(old envelope, S_m)).
This removes the quantile hole, the sentinel-death hole, and the s_max-corruption hole.
Guarantee (honest): never-late holds DETERMINISTICALLY except on a false corroborated collapse; residual risk
  = Π_over_stops(1 − P(false corroborated collapse)); quantify P(false) from the empirical FALSE-detection
  rate (~3/427 ≈ 0.7%/stop BEFORE corroboration gating), NOT from the miss rate.
```

### Never-late implications
The alarm trigger must be the **deterministic-envelope** `U(t)=min(s_max_protected(t), s_upper(t))`, not the tail-quantile form. The critical asymmetry holds: a **missed** stop leaves sentinels untrimmed, so `U` stays conservative → fires early, never late. The only way to violate never-late is a **false corroborated collapse** that pushes both the sentinel support and the re-anchored `s_max` line below true progress — neutralized by requiring **≥2 independent corroborators** and biasing to under-collapse. The residual guarantee is `Π_over_stops(1 − P(false corroborated collapse))`, quantified from the empirical false-detection rate, and must be reported honestly rather than as "deterministic / prob-1".

### Pitfalls
- Gravity leakage during sustained braking biases `μ_B`; use gyro-propagated attitude, correct only in low-jerk windows.
- The separator `e` is placement/behavior-dependent (in-hand vs pocket; user walking during dwell); corroborate with Δv and GPS-reacquire before confirming.
- Data-association ambiguity: express trains skipping stations, and mid-tunnel signal/traffic HOLDS mimicking brake→stop→launch NOT at a station. Only collapse to `S_m` if travel-time AND baro AND geometry are consistent.
- Particle degeneracy / collapse to the WRONG station is the single thing that breaks never-late; systematic resampling, corroboration-gated collapse, deliberate under-collapse bias.
- Geometric state-duration bias — use an HSMM/explicit-duration model.
- Barometer drift from weather/HVAC/piston pulses — differential over short baselines only.
- Cold-start / low-speed degradation (Heirich): before the first confirmed station the cloud has no anchor → rely on `s_max` until the first corroborated collapse.

### Recommendation
Implement the two-stage estimator as a **tightening layer on top of the reachability core**. (1) Run the 4-state HMM (or HSMM) at ~1–2 Hz on cleaned `a_L` plus the 3–15 Hz vibration-energy `e`; emit a confirmed-station event only when the preceding brake integrates to `Δv≈−v_cruise` AND `e` hits the dwell floor. (2) Feed confirmed stations, launches, and any baro/WiFi/GPS as anchor likelihoods into the `(s,v)` jerk/accel-limited PF; let the station bump collapse the posterior to ~5–15 m at each stop. (3) Trigger on the **corrected** `U(t)=min(s_max_protected(t), s_upper(t))` with **collapse-only-on-corroboration** so misses cost only over-early firing. Validate on the two real handheld Bengaluru fixtures: first prove the vibration feature actually separates dwell from handheld cruise on real data (the make-or-break, unproven-on-device risk), then measure stop-count accuracy vs `arrival_t_s` and blind-window `s`-error vs the current EKF. Gate entirely on corroboration and treat the residual late-risk as `Π(1 − P(false corroborated collapse))`.

> **Rigor check — verifier findings (sound = FALSE, never_late_holds = FALSE). Problems (P) and corrections (C):**
> - **P1 — the min-with-`s_max` clamp adds ZERO never-late safety.** Since `s_max ≥ s_true`, `U=min(s_max, Q_{1−α}) ≥ s_true` **iff** `Q_{1−α} ≥ s_true`. The clamp only ever lowers `U` (a tightening/early-fire knob), so the whole guarantee reduces to the *unproven* PF-calibration assumption `(*) P(s_true ≤ Q_{1−α}) ≥ 1−α`. The summary's "proven" bound is only *conditional* on (\*).
> - **P2 — the quantile is not the max; sentinels at `s_max` do NOT pin `Q_{1−α}`.** For any α>0, `Q_{1−α} < max_i s_i`. Late scenario: train near `V_LINE` (`s_true ≈ s_max`) but a spurious update (GPS multipath, baro pulse, association error) puts >α weight *behind* `s_true` → `Q_{1−α} ≪ s_true` → `U < s_true` → LATE. PF over-confidence/degeneracy makes this tail-starvation common.
> - **P3 — "deterministic upgrade" and "tightening" are mutually exclusive.** As α→0, `Q_{1−α}→max_i s_i→s_max`, so `U→s_max` = pure reachability with zero tightening. The only α at which determinism holds is α=0 (no tightening). Every α>0 that tightens leaves only the conditional prob-(1−α) bound (P2 applies).
> - **P4 (deepest) — a false corroborated collapse corrupts `s_max` ITSELF.** Station collapse re-anchors `s0`. A premature/false confirmed stop sets `s0 := S_m < s_true`, so `s_max = S_m + V_LINE(t−t0) < s_true` for a window ~ `(s_true−S_m)/(V_LINE−v_true)` (never closes if `v_true≈V_LINE`) → GUARANTEED LATE. Premise "`s_max ≥ s_true` prob 1" FAILS after any false low re-anchor. Corroboration shrinks `P(false)` but cannot zero it.
> - **P5 — sentinels die in a standard PF.** `max_i s_i = s_max` is not maintained under weight-multiply + resampling: max-accel-envelope sentinels get low likelihood and are discarded. Sentinels must be structurally EXEMPT from weighting/resampling (a deterministic side-track).
> - **P6 — empirical `Q_{1−α}` is unreliable at these N.** α=0.04, N=500–2000 estimates the quantile from ~20–80 particles; after ESS collapse the leading tail may hold single-digit distinct `s`-values → high-variance quantile. (\*) fails empirically even if the true posterior were calibrated.
> - **P7 — motion-model bug: `s` can move backward.** `s_i,k = s_{k−1} + v_{k−1}Δt + ½ a_k Δt²` uses unclipped kinematics while `v` is clipped at [0,V_LINE]; at rest with residual `a<0`, `s` decreases though the train cannot roll backward. **C:** use trapezoidal `s += ½(v_{k−1}+v_k)Δt` so `s` halts exactly when `v` hits 0.
> - **P8 — Δv confirmation is attitude-limited, not "drift-bounded".** During sustained brake, accel-correction is disabled, so attitude runs on gyro alone; bias 0.002–0.01 rad/s over 15 s → 1.7°–8.6° → g-projection 0.29–1.47 m/s² spurious longitudinal → 4.4–22 m/s integration error, comparable to/exceeding `v_cruise`. `Δv≈−v_cruise` can be spoofed by a partial brake + attitude drift (the P4 trigger). Needs a quantified SNR and fresh gyro-bias calibration (cold-start chicken-and-egg).
> - **P9 — particle depletion at the anchor.** DR spread O(10²–10³ m) vs `σ_stat=5–15 m` (10–100× narrower): only ~15 of 1000 particles land within ±15 m of `S_m`; if zero cover `S_m`, all weights →0 → divergence. Needs a regularized/roughening PF or an MCMC move.
> - **C (citations/rates):** Heirich 2016 headline is **track-selectivity 99.3% / switch-way 97.2% over 230 km with 107 split switches** (RBPF with embedded KFs), **NOT** "sub-5 m over 21.6 km" — correct the framing. SOTA stop-detection recall is **not uniformly ~0.96**: the 96% (410/427) is a best-case multi-sensor+baro poster result; competing studies report ~81% (StationSense) and lower. Set α from the worst credible recall (~0.19 miss), or — given P4 — do **not** tie the safety bound to the miss rate at all.
> - **C (kept):** the **HMM half is sound**: zeroing illegal transitions makes every Viterbi path a well-formed cycle, `N = #(B→D)` is a valid count, and using 3–15 Hz rail-vibration energy `e` as the dwell/cruise separator (since `μ_C=μ_D=0`) is the correct answer to the naive-ZUPT failure. The Kalman precision-addition `σ⁺=(1/σ⁻²+1/σ_stat²)^{−1/2}≈σ_stat` is correct. Failure is confined to the never-late claim and PF safety plumbing.
> - **C:** add an **HSMM/explicit-duration** model as a de-biasing improvement, but note it does NOT fix any never-late problem (those are PF/trigger issues).

---

## 9. Mode-adaptive estimation: choosing V_LINE and the motion model under mode uncertainty (`math_mode_adaptive`)

> **Data note:** the source material for this facet was **truncated** mid-derivation (it ends inside "WHY MAX, NOT MIXTURE"). The Summary and the setup/proof portion of the Derivation are preserved verbatim; the Never-late implications, Pitfalls, and Recommendation below are reconstructed *only* from statements already present in the Summary — no new claims were invented. No methods table and no verifier record were available for this facet.

### Summary
Never-late safety under mode uncertainty does **NOT** require the mode classifier to be correct — it reduces to a single one-sided condition: the plausible-mode set `P(t)` must **CONTAIN** the true mode at every instant (a **recall/containment** guarantee, not accuracy). Under containment, setting `V_LINE(t) = max_{m∈P(t)} V_max(m)` makes the reachability cone `s_max(t)=s_a+∫V_LINE dτ` a provable upper bound on true progress, and firing occurs ≥ `T_lead` before arrival. This is decisive because SOTA smartphone mode classifiers are ~86–90% accurate overall but **train/subway are the WEAKEST classes** (~11% car↔train confusion) and carry 1–5 s decision latency plus HMM smoothing lag — so you must never bet the guarantee on a correct train call. The safe rule is **asymmetric**: exclude a fast mode (tighten `V_LINE`) only on sustained strong evidence, but re-include it instantly on any evidence (**one-sided hysteresis**), and use a **hard `max` over `P`, never a probability-weighted IMM mixture** (an expectation is not an upper bound and leaks ~`p(train)` late-fire probability). The early-firing cost obeys the master equation `E = d0·(1/v_eff − 1/V_LINE)`: assuming the fastest plausible mode on a 20 km leg while the rider is actually still can fire ~10 min early, and a confident boarding/still resolution collapses that to ≈0. Crucially, a phone IMU is **inertially blind to constant-velocity motion** (a train at 30 m/s and a phone at rest produce identical specific force), so IMU can CONFIRM stops but can NEVER safely lower-bound speed mid-cruise; safe downward tightening of `V_LINE` must come from **certified physical exclusions** (GPS-confirmed stationarity, a detected train-launch transient, route/map-match excluding road modes, a confirmed dwell), with a **staleness floor** that snaps back to the fast mode and bounds worst-case lateness deterministically.

### Full derivation (equations preserved; source truncated after "WHY MAX, NOT MIXTURE")
```
SETUP. Route arc-length s(t) along the oriented polyline; destination at arc-length D; last certified anchor
(GPS fix or confirmed station stop) at (t_a, s_a). Per-mode speed ceiling V_max(m):
  still ≈ 0 (allow 0.5 m/s handheld along-route ≈ 0)
  walk  V_w = 2.5 m/s (covers brisk walk / light jog to catch a train; PDR nominal 1.4)
  car   V_c ≈ 25 m/s (90 km/h)
  train = LINE-SPECIFIC certified track/rolling-stock max V_T (Purple ≈ 22 m/s = 80 km/h;
          generic modern metro 33–44 m/s)
Plausible set P(t) ⊆ {still, walk, car, train}.  Define V_LINE(t) = max_{m∈P(t)} V_max(m).

CONE.  s_max(t) := s_a + ∫_{t_a}^{t} V_LINE(τ) dτ   (piecewise-linear if V_LINE piecewise-constant).

FIRING RULE. Fire at first t with s_max(t) ≥ D − s_lead, where s_lead = V_max^P·T_lead and
   V_max^P = sup_{τ near t} V_LINE(τ)  (use the max plausible speed for the lead distance too — conservative).

ASSUMPTIONS.
  (A1 Containment)  m*(τ) ∈ P(τ) for all τ.
  (A2 Ceiling)      instantaneous true along-route speed v_true(τ) ≤ V_max(m*(τ)) ≤ V_LINE(τ),
                    which holds by definition of the per-mode ceiling given A1.

LEMMA (valid upper bound). s(t) − s_a = ∫_{t_a}^t v_true dτ ≤ ∫_{t_a}^t V_LINE dτ = s_max(t) − s_a
   ⇒ s(t) ≤ s_max(t).  ∎

THEOREM (mode-robust never-late, lead T_lead). Let t_arr be arrival (s(t_arr)=D), t_f the fire time.
Evaluate the cone at t_arr − T_lead:
   s_max(t_arr−T_lead) ≥ s(t_arr−T_lead) = D − ∫_{t_arr−T_lead}^{t_arr} v_true dτ ≥ D − V̄·T_lead,
where V̄ = sup of v_true over the final window ≤ V_max^P (by A1/A2). Hence
   s_max(t_arr−T_lead) ≥ D − V_max^P·T_lead = D − s_lead,
so the firing threshold is already met at t_arr−T_lead ⇒ t_f ≤ t_arr − T_lead. The alarm fires at least
T_lead before arrival. ∎

NOTE: the entire guarantee rests ONLY on A1 (containment); classifier accuracy is irrelevant.
A missed detection = keep extra modes = larger P = larger V_LINE = earlier (still-safe) fire — exactly the
contract's "missed detection may reduce tightening but never cause a late fire."

WHY MAX, NOT MIXTURE. A soft IMM estimate V_eff = Σ_m p_m V_max(m) is an EXPECTATION. If p(train)=0.1,
V_eff is pulled ≈ 0.9·V_walk …   [SOURCE TRUNCATED HERE]
```
*Interpretation of the truncated point (consistent with the Summary):* a probability-weighted IMM mixture `V_eff = Σ_m p_m V_max(m)` under-weights the fast mode whenever `p(train) < 1`, so `V_eff < V_LINE = max_m V_max(m)`. Since an expectation is **not** an upper bound, using `V_eff` in the cone leaks a late-fire probability of order `p(train)` — hence the hard `max` over the plausible set is mandatory.

### Never-late implications (reconstructed from the Summary)
Safety is a **containment (recall) property of the classifier, not an accuracy property**: as long as the true mode is in `P(t)`, `V_LINE(t)=max_{m∈P(t)}V_max(m)` upper-bounds true speed and the cone upper-bounds true progress (Lemma), giving a firing time `≥ T_lead` before arrival (Theorem). Consequences: (1) a **missed** detection (extra modes kept in `P`) only inflates `V_LINE` → fires earlier → still safe; (2) the dangerous direction is **wrongly excluding the true (fast) mode** from `P`, so exclusion of a fast mode must require *sustained strong evidence*, while re-inclusion is *instant on any evidence* (**one-sided hysteresis**); (3) never use a probability-weighted **IMM mixture** — an expectation is not an upper bound and leaks ~`p(train)` late-fire probability; use the hard `max`; (4) because IMU is **inertially blind to constant velocity**, `V_LINE` can only be tightened downward by **certified physical exclusions** (GPS-confirmed stationarity, detected launch transient, route/map-match excluding road modes, confirmed dwell), never by "the accelerometer looks quiet"; (5) a **staleness floor** snaps `V_LINE` back to the fast mode after evidence goes stale, bounding worst-case lateness deterministically.

### Pitfalls (reconstructed from the Summary)
- Betting the guarantee on a **correct train/subway call** — these are the weakest classifier classes (~11% car↔train confusion) with 1–5 s decision latency + HMM smoothing lag.
- Using a **probability-weighted IMM mixture** for `V_LINE` — the expectation `Σ p_m V_max(m)` is not an upper bound and leaks a late-fire probability of order `p(train)`.
- **Symmetric** hysteresis on mode exclusion — excluding a fast mode on weak evidence risks under-bounding speed; exclusion needs sustained strong evidence, re-inclusion must be instant.
- Trying to lower `V_LINE` from IMU quietness alone — the IMU cannot distinguish constant-velocity cruise from rest; only certified physical exclusions may tighten downward.
- Letting a stale exclusion persist — without a staleness floor snapping back to the fast mode, worst-case lateness is not bounded.
- The early-firing cost `E = d0·(1/v_eff − 1/V_LINE)` can be large (~10 min over a 20 km leg when assuming the fastest plausible mode while actually still) — the price paid for containment when the mode is unresolved; a confident boarding/still resolution collapses it to ≈0.

### Recommendation (reconstructed from the Summary)
Choose `V_LINE(t) = max_{m∈P(t)} V_max(m)` over a **plausible-mode set** `P(t)` maintained for **containment** (recall of the true mode), not classifier accuracy — the never-late Theorem depends only on containment. Use per-mode ceilings (still ≈0, walk 2.5 m/s, car ≈25 m/s, train = line-specific certified max, e.g. 22 m/s on Purple). Apply **one-sided hysteresis**: exclude a fast mode from `P` (tightening `V_LINE`) only on sustained strong evidence, and re-include it instantly on any evidence. **Never** use a probability-weighted IMM mixture for the cone — always the hard `max`. Tighten `V_LINE` downward only via **certified physical exclusions** (GPS-confirmed stationarity, detected train-launch transient, route/map-match excluding road modes, confirmed dwell), and pair every exclusion with a **staleness floor** that snaps back to the fast mode so worst-case lateness stays deterministically bounded. Accept the early-firing cost `E = d0·(1/v_eff − 1/V_LINE)` as the price of containment when the mode is unresolved, and drive it down by resolving mode confidently (a confirmed boarding/still resolution collapses `E` toward 0).

---

## Appendix A — Complete source URL index (every source_url preserved)

**Train / transit stop-counting (§1, §8)**
- https://grouplens.org/site-content/uploads/bhecht_sigspatial2014_subwayps.pdf
- https://pmc.ncbi.nlm.nih.gov/articles/PMC6806589/
- https://dl.acm.org/doi/pdf/10.1145/3307334.3328635
- https://www.frontiersin.org/journals/computer-science/articles/10.3389/fcomp.2021.713719/full
- https://www.sciencedirect.com/science/article/pii/S2590198224001672
- https://dl.acm.org/doi/abs/10.1145/2996913.2996999
- https://tik-old.ee.ethz.ch/file/365ee27a42f71d6b5cd7212571f7185b/mobiquitous16-gu.pdf
- https://dl.acm.org/doi/10.1145/3307334.3328635
- https://www.mdpi.com/1424-8220/19/19/4184

**PDR (§4)**
- https://pmc.ncbi.nlm.nih.gov/articles/PMC5038701/
- https://www.researchgate.net/publication/224198572_Comparison_and_evaluation_of_acceleration_based_step_length_estimators_for_handheld_devices
- https://www.tandfonline.com/doi/full/10.1080/10095020.2024.2338225
- https://arxiv.org/pdf/2407.21676
- https://www.mdpi.com/1424-8220/18/1/297
- https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6022069/
- https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6766805/
- https://www.mdpi.com/2220-9964/14/12/476

**Attitude / gravity / ZUPT (§2)**
- https://hal.science/hal-00488376/document
- https://courses.cs.washington.edu/courses/cse466/14au/labs/l4/madgwick_internal_report.pdf
- https://www.mdpi.com/1424-8220/15/8/19302
- http://www.iri.upc.edu/people/jsola/JoanSola/objectes/notes/kinematics.pdf
- https://www.researchgate.net/publication/224198580_Evaluation_of_zero-velocity_detectors_for_foot-mounted_inertial_navigation_systems
- https://arxiv.org/pdf/1910.00529
- https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6111255/

**Map-matched / route-constrained PF (§5)**
- https://arxiv.org/pdf/2308.12082
- https://onlinelibrary.wiley.com/doi/10.1155/2016/2672640
- https://engagedscholarship.csuohio.edu/enece_facpub/158/
- https://pmc.ncbi.nlm.nih.gov/articles/PMC9698600/
- https://researchwith.njit.edu/en/publications/onboard-metro-train-localization-based-on-the-train-motion-and-tr/
- https://www.mdpi.com/2624-8921/8/4/80
- https://ieeexplore.ieee.org/document/8867679

**Non-inertial re-anchors: baro / mag / wifi (§3)**
- https://arxiv.org/pdf/2003.10531
- https://link.springer.com/chapter/10.1007/978-3-319-47289-8_4
- https://www.researchgate.net/publication/261316874
- https://dl.acm.org/doi/pdf/10.1145/3271553.3271614
- https://medium.com/snips-ai/underground-location-tracking-3ea56803dddc
- https://blog.transitapp.com/go-underground/
- https://arxiv.org/pdf/1904.01675
- https://pmc.ncbi.nlm.nih.gov/articles/PMC6720727/

**Car DR (§6)**
- https://www.mdpi.com/1424-8220/11/4/4244
- https://link.springer.com/article/10.1007/s10291-023-01483-9
- https://arxiv.org/abs/2109.03091
- https://ieeexplore.ieee.org/document/9372287/
- https://www.eurekalert.org/news-releases/1089377
- https://navi.ion.org/content/70/4/navi.608
- https://www.microsoft.com/en-us/research/wp-content/uploads/2016/12/map-matching-ACM-GIS-camera-ready.pdf
- https://metisengineering.com/dead-reckoning-technology-maintaining-vehicle-position-accuracy-during-gps-signal-loss/

**Train kinematics / reachability math (§7)**
- https://www.pmdcorp.com/resources/type/articles/get/mathematics-of-motion-control-profiles-article
- https://www.mdpi.com/2071-1050/17/24/11371
- https://www.sciencedirect.com/science/article/abs/pii/S0377221716307962
- https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10093331
- https://hybrid-robotics.berkeley.edu/publications/CBVF.pdf
- https://link.springer.com/article/10.1007/s40864-015-0012-y

---

## Appendix B — Cross-cutting engineering rules (the non-negotiables)

1. **Firing always reads an upper bound `U(t)` on `s_true`**, and `U(t) = min(...)` of individually-valid upper bounds. Never average; never min-in a point estimate.
2. **Physics ceiling is the floor of safety:** everything degrades to `s_max = s0 + V_LINE·(t−t0)` when evidence is absent.
3. **Precision over recall, everywhere.** Missed detections only loosen `U` (safe). False-positive anchors are the *only* late-fire mechanism. Gate every station re-anchor on **≥2 independent corroborators** + monotone-index + min-travel-time.
4. **Never low-pass the accelerometer for gravity.** Gyro-propagate attitude, correct only in low-jerk windows with a four-part gate (magnitude + jerk + gyro-rate + gyro-consistency).
5. **Never free-integrate position.** Event-anchored resets only; route-constrained trapezoidal DR between anchors.
6. **The dwell/cruise separator is rail-vibration band-power, not `|accel|` variance** — handheld dwells have MORE motion energy than cruise.
7. **1-D on-route.** Project onto the polyline; cross-track/heading error is irrelevant to the safety bound (only affects a 2-D display).
8. **`V_LINE` is a physical cap.** For cars, that means legal×(1+margin) capped by curvature and an absolute ceiling — never the bare posted limit. Choose `V_LINE` from a plausible-mode `max`, never an IMM mixture.
9. **Everything here is device-unproven until measured on the two real Bengaluru handheld fixtures.** Report brake-event SNR vs handling noise, per-stop P/R/count, and blind-window `s`-error as a credible band — never a false point, never device-proof from synthetic rides.
