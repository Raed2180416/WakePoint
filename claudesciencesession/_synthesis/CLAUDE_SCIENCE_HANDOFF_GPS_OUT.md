# WakePoint — Claude-Science Handoff: making the GPS-out innovation actually work

**For: the next Claude-Science research session. From: the engineering pass (2026-07-10).**

The reliability + product engineering is largely done and verified (see `IMPLEMENTATION_STATUS.md`). What remains are the **research-grade, data-gated problems** at the heart of the core innovation — *waking a rider before their stop when there is NO GPS*. These cannot be responsibly "fixed" in code from a desk: every one of them needs **real multi-device, multi-ride data** and honest validation, or it makes the product *worse* (fires late = missed stop). This doc says exactly what to work on, why it's hard, what data to collect, and the success bar.

**The one meta-fact that gates everything:** the entire GPS-out engine is validated on **n=1 real ride** (Rajajinagar→Whitefield). The synthesizer is calibrated to that one ride, so any model trained on synthetic data risks **inverting its own generator** (confirmed: the learned velocity regressor scores R²=0.84 in sim but the real ride shows *no* accel band tracking speed, broadband RMS r=−0.33). **Priority zero is real data.**

---

## The binding constraint (name it plainly)

A 1D EKF underground can only **propagate** position (`s += v·dt`); with no GPS it cannot **correct** it. So the two things that decide whether the innovation works are:
1. **How well do we know velocity `v` during the blackout?** (error in `v` integrates directly into position error.)
2. **Is there ANY mid-blackout observation that can correct `s`?** (an anchor.)

Everything below is one of those two problems.

---

## P1 — Real velocity through a blackout (THE keystone; currently faked)

**Problem.** During a tunnel, GPS speed is gone and raw accel double-integration drifts. The prior session's fix (A4) was a learned speed-from-IMU regressor — but it is **circular** (the synthesizer makes vibration a function of speed; on the one real ride that signal is absent). We deliberately did **not** ship it. Without a trustworthy `v`, the honest σ grows to kilometres (which we now report honestly, so we fire *early/safe* — but so early it erodes trust on long underground segments).

**What to work on.**
- Collect real raw-IMU + GPS-truth rides across **≥3 phones × ≥5 rides × ≥2 metro lines** (mix underground + elevated).
- Build a **phone- and vehicle-independent** speed estimator on real data and validate on **held-out devices/rides** (not just held-out windows). Candidate features: 3–8 Hz & 8–20 Hz band energies, accel percentiles, gyro stats, dominant frequency — but prove they actually track speed on real hardware first.
- If speed-from-IMU does **not** generalise (likely), fall back to **anchor-and-reset** (P2/P3) + **schedule-anchored ETA** (use the route's own inter-station timetable as the velocity prior between confirmed stops).

**Success bar.** Held-out **real** cross-device velocity MAE that, propagated over the *worst* real inter-station blackout, keeps position error under ~½ inter-station spacing. Report the honest number; do not average away the tail.

**On-device deliverable.** If a model survives, export to LiteRT/ONNX-Runtime-Mobile and re-validate on-device with the OOD gate (`safe_vel_var`) so an out-of-distribution regressor self-downweights (fails safe).

---

## P2 — Station-dwell detection as the real anchor (validate cross-device)

**Problem.** If velocity-from-IMU is unreliable, the robust anchor is **detecting each station stop** (decel-to-zero + dwell ≥ 8 s) and **resetting integrated error** by snapping to that station's known arc-length. This is the strongest lever — one good anchor per station bounds the error. The prior "≤2.6% missed stops" was **sim-only, never checked against the real ride's annotated stops.**

**What to work on.**
- Annotate the real rides' true station arrivals; measure **dwell false-negative and false-positive rates per device and per carry-mode** (hand, pocket, bag, lap, to-ear) on REAL data.
- Harden the dwell detector to the real distribution (the current thresholds are tuned to one ride). Make it robust to **standing vs seated**, **jostling**, and **no-gyro** phones.
- Design the **dwell→ordinal-advance** association cleanly: advance the target station index by exactly one per confirmed dwell, position-gated — this is the honest way to stay correct under large σ (we currently lean on the `DEGRADED_NEAREST` fallback, which the tests show suffices but is heuristic).

**Success bar.** On real rides, ≤ small, quantified miss-rate across all 5 carry modes; zero phantom-dwell station advances.

---

## P3 — A second anchor (the only way to be never-late AND tight underground)

**Problem.** Never-late **and** ≤3-min-early **cannot both hold** on long-blackout + wide-spacing routes without a **real mid-blackout position observation**. Propagation alone can't do it. We need an anchor that *corrects* `s` underground.

**Candidates to research/build (ranked):**
1. **Curvature / route-shape matching** — extract tilt-compensated yaw-rate (gyro projected on gravity), bandpass ~0.01–0.3 Hz, match against the route's known curvature. Prototype exists (`wakepoint_curvature_anchor.py`): as a *desync detector* it correlates r=0.98; as a standalone position driver it **diverges** (5/8 seeds). Make it robust: corpus-wide tuning, better velocity input, and **fusion (not standalone)** — use it to correct, not to drive. This is the highest-value roadmap item.
2. **Barometer / altimeter** — underground segments descend ~10–30 m; the pressure profile is a repeatable per-line signature. Use it to (a) *confirm* tunnel entry/exit (state trigger), (b) coarse-anchor which underground segment we're in. Cheap, present on most phones, GPS-independent. Validate the pressure signature per line.
3. **Opportunistic RF** — station WiFi SSIDs / BLE beacons / cell-tower transitions as station fingerprints (many metros have platform WiFi). Assess coverage per city; even coarse "which station's platform" is a strong reset.

**Success bar.** With a working second anchor, close **cold-start-fully-underground** (P4) to 0/N late and bring the early-fire bound back under ~3 min on the worst routes.

---

## P4 — Cold-start fully underground (the one residual never-late gap)

**Problem.** If the journey *starts* already underground (no first GPS fix), the EKF has no initialization — the one scenario where the current design can fire late (1/6 in sim, ~+7 min). This is the *expected* case for someone boarding at an underground station.

**What to work on.** Bootstrap initialization from the **route start / nearest known station** + the P3 anchor (curvature/barometer) to establish `s` before the first GPS. Prove it on a real cold-start-underground ride.

---

## P5 — Motion-gated ZUPT threshold (A2) calibration

**Problem.** A spurious ZUPT during a smooth cruise zeroes velocity → position stalls → fires late. The fix is to **veto ZUPT when the 3–8 Hz rail-vibration band-energy says the train is moving** — but the threshold is **calibration-dependent** and we only have one ride. A wrong threshold suppresses *real* station dwells (missed stops). We deliberately deferred this.

**What to work on.** From the real multi-device rides, characterise the band-energy distributions for **cruise vs dwell** per device/train-type; set and validate the veto threshold; prove cruise/dwell separation. Only then ship the veto.

---

## P6 — Re-derive the honest never-late guarantee on real data

**Problem.** The "never-late" claims were overstated in sim (several small late-fires the summaries rounded away; the headline numbers describe an *unshipped* filter variant). Once P1–P3 give a **real** velocity/anchor error model, re-derive the **critical-fractile `k`** and the **honest early-fire bound** from real data, and prove `P(wake late) ≤ ε` with the real error distribution — not the synthesizer's.

**Success bar.** A defensible, real-data-backed statement of the guarantee and its bound, per route class (short tunnel / long fully-underground / elevated).

---

## The data-collection campaign (do this FIRST — it unblocks P1–P6)

Minimum that resolves the most uncertainty per rupee (the founder is budget-constrained):
- **Phones:** 3–4 spanning the range — one flagship (gyro, good MEMS), one mid-range, one **sub-₹12k / no-gyro** budget device (the India-critical case).
- **Rides:** ~8–10 total: ≥2 fully-underground segments, ≥2 elevated, ≥1 with a line transfer, ≥1 cold-start-underground, across ≥2 cities if possible (Bengaluru + Delhi).
- **Logger:** raw accel+gyro+magnetometer+**barometer** at 50–100 Hz + GPS (with truth), timestamped; log **screen-off in a foreground service** so you also measure the real background sample rate (validates the wakelock story).
- **Annotate:** true station-arrival timestamps + carry mode + posture per ride.

This single campaign feeds P1 (velocity), P2 (dwell), P3 (barometer/curvature), P5 (band-energy), and P6 (guarantee) — and finally answers the circularity question.

---

## What NOT to ask Claude-Science to do
- Don't re-tune models on synthetic data alone (circularity).
- Don't ship A4 or the A2 veto without real-data validation (they can make it *worse*).
- Don't claim a never-late guarantee from sim numbers.

**North star:** the innovation is only real when we can show, on real rides across real devices and the hard scenarios (long tunnel, no-gyro phone, cold-start-underground, transfers), that the rider is woken **before** their stop with a bounded, honest early margin.
