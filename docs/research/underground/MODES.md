# Underground Modes: Walk / Car / Mode-Classification

Consolidated findings from the walking-underground, car-tunnel, and mode-classification
simulations. All three are **physics simulations with datasheet-grounded and real-metro-grounded
sensor noise** — device-unproven at scale. The single job of this layer is to pick the right
`V_LINE` (along-route speed ceiling) for the never-late reachability cone when GPS is gone
underground, and to tighten the along-route position estimate where the motion model allows it.

`train` is the *main* underground case and is handled in a separate workflow (rail geometry +
station snapping + on-rail reachability). This document covers the two non-train modes and the
safety-critical classifier that switches between all four.

---

## 1. Per-mode motion model

| Mode | Motion model | Speed cap (V_LINE) | Observable underground? |
|------|--------------|--------------------|--------------------------|
| **still** | Sensor floor only (BMI160 ~150 ug/rtHz) | 0.0 m/s | — (non-excluding, see §4) |
| **walk** | Biomechanical gait: vertical bounce @ 2x step freq + fore-aft surge + lateral sway, rotated through a drifting handheld attitude | 2.0 m/s | **Yes** — PDR per-step, bounded error |
| **car** | Kinematic unicycle/bicycle (Rajamani 2012; Polack IEEE IV 2017); friction-circle corner cap; red-light stops | 22–25 m/s | **Partly** — only via turn/stop anchors; cruise speed unobservable |
| **train** | (separate workflow) | 22.2 m/s (Purple line 80 km/h) | via rail geometry, not IMU |

**Walk** — synthesized handheld IMU over an 863 m / 640 s concourse-interchange path (90-deg turns +
a wrong-exit U-turn), 50 Hz, MEMS noise (accel 180 ug/rtHz, gyro 0.008 dps/rtHz) plus a handheld OU
tilt drift of +/-8 deg. PDR pipeline: complementary-filter gravity (gyro-propagated, accel-corrected
only under a low-jerk gate to avoid the brake-leak trap), band-passed vertical-accel peak step
detection with refractory, Weinberg `L = K*(a_max - a_min)^0.25` with **K = 0.442** calibrated on 60 m,
gyro-yaw heading on the gravity axis.

**Car** — ~2 km curved tunnel road (straight + circular-arc segments), 195 s, 4 turns (R = 30–160 m),
2 red-light stops, mean 10.0 m/s / peak 14 m/s. Ground truth from a 50 Hz kinematic unicycle model
with a physically consistent speed profile (lateral-accel corner cap `sqrt(a_lat/kappa)`,
forward/backward accel-limit passes). Phone-in-mount IMU = specific force + gravity in a fixed tilted
mount frame + MEMS white noise + turn-on/in-run biases + road vibration + occasional handling bursts
(Bosch BMI160 class). Mount noise measured ~10x lower than the real handheld metro fixture; handling
bursts injected at the measured handheld level.

---

## 2. Simulated error numbers

### Walk — PDR distance error stays BOUNDED (per-step, no compounding)

| Horizon | Distance error | Position error |
|---------|----------------|----------------|
| 1 min | +1.6% | 5.6 m |
| 3 min | +2.6% | 34.9 m |
| 10 min | +3.8% | 256.7 m |

- 1179 true steps / 1322 detected (+12% over-count from a 2x vertical-bounce harmonic, absorbed by K).
- Position error is **heading-drift dominated** and grows ~linearly (not quadratically).
- **Naive double-integration of the identical signal = 9361 m error @ 10 min (~t^2). PDR beats it ~37x.**

### Car — along-route error is UNUSABLE raw, RESCUED by turn anchors

| Configuration | Final along-route error | RMS | Error per 100 m |
|---------------|-------------------------|-----|-----------------|
| **No anchors** | 852 m | 490 m | ~44 m / 100 m (unusable) |
| **With turn anchors** | 340 m | 119 m | bounded <=197 m between anchors |

- `|err|` **at** the 4 bends = {0.4, 14.2, 0.2, 0.4} m — turn anchors collapse along-route error to ~0.
- The residual 340 m final error is entirely the **522 m unanchored straight tail** after the last turn.
- Stop detection (matched filter: decel -> low-yaw dwell >= 3 s -> launch): **2/2 confirmed, ZERO corner
  false-positives** — the sustained low-yaw dwell gate rejects hard-corner decelerations.
- **Absolute cruise speed is UNOBSERVABLE** from specific force: a car at constant 14 m/s produces the
  same ~0 longitudinal signal as a full stop, so raw speed integrates on bias/noise and grows ~t^2 to
  ~1 route-length in ~3 min. Turns are the underground analog of a GPS fix.

_See `car_tunnel_analysis.png`, `car_tunnel_summary.json`._

---

## 3. Mode-classifier confusion matrix + resolve time

Feature extractor: 11 features / 4 s window, 2 s hop (accel energy bands — gait 1.2–2.6 Hz,
sustained-vehicle 0.1–0.6 Hz, jitter 5–20 Hz; gait_ratio; dominant freq; gyro energy; sustained
longitudinal force; jerk). Top discriminators: **gait_ratio (imp 0.47)** and **jerk_std (0.45)**.
Classifier: shallow decision tree (depth 4), **stream-level** train/test split (no window leakage).
Training data: **real** handheld Purple-line IMU for `train` (2 rides, Nallur + Nadaprabhu) +
grounded physics-simulated still/walk/car.

Confusion matrix (rows = true, cols = pred: still / walk / car / train):

```
         still  walk  car  train   recall
still  [  178    0   301    11 ]   0.363
walk   [    0  490     0     0 ]   1.000
car    [    4    0   483     3 ]   0.986
train  [   45    0   405   891 ]   0.664
```

- Overall window accuracy **0.726**.
- **WALK recall = 1.00** — gait cadence is cleanly detectable and is the only mode that resolves down.
- **train<->car confusion is SAFE** — both are high-V_LINE modes.
- Only danger cells: 45/1341 real train windows -> `still` (a dwelling train looks still).
  **train -> `walk` = 0/2460 across ALL real windows** — the forbidden late case never occurs on real data.

**Time to confidently resolve WALK** (K consecutive windows): median **8.0 s** at K=3 (4 s window + 2 hops).
K sensitivity: K=2 -> 6 s, K=3 -> 8 s, K=4 -> 10 s — all with **0 false-drop on real trains**.
Vehicle/still deliberately never resolve down to a lower mode (stay conservative).

**Adversarial residual:** a passenger pacing the aisle (walk gait on a real moving-train cruise) is
called `walk` in 28/29 windows and **would wrongly tighten to 2.0 m/s**. This is the honest limit of
IMU-only mode switching — walk-driven tightening must be gated on an independent off-vehicle
corroborator (GPS reacquired stationary/off-route, or route geometry).

_See `mode_fusion.png`._

---

## 4. NEVER-LATE model per mode + safe-under-mode-uncertainty rule

The reachability guarantee is an upper bound on along-route progress:

```
s_max(t) = s0 + V_LINE_used * (t - t0)
```

Because `s_max` is **monotone increasing in V_LINE**, keeping `V_LINE_used >= V_LINE(true mode)`
guarantees `s_max(t) >= s_true(t)` always — so the wake alarm can only fire **early, never late**.

### Per-mode bounds and why each holds

- **Walk — V_walk = 2.0 m/s.** True upper bound because `v_true(t) <= V_walk` (Bohannon 1997:
  comfortable ~1.34 m/s, brisk up to ~2.0; faster is running, classified out of walk mode). PDR
  tightening preserves it: measured along-route distance + its bounded (~4%) margin only moves the
  estimate conservatively; a missed step forgoes tightening but never advances past the physical
  bound. Using metro V_LINE=28 for a walker over-bounds ~14x and fires ~232 s (~4 min) too early to
  cover the last 500 m — safe but useless, which is *why* V_LINE must be mode-adaptive.

- **Car — V_LINE = 22 m/s (~1.3x the posted 16.7 m/s limit).** Padded deliberately ABOVE the limit
  because cars exceed posted limits; if V_LINE < a car's true peak the cone falls behind and fires
  **late**. Two provably-safe tightenings: (a) **confirmed dwell** — a matched-filter full stop
  freezes true `s` (v=0), so freezing the cone never drops it below truth; a missed stop only forgoes
  tightening. (b) **turn anchor** — at a matched bend the true arc-length is known, so reset
  `s0 := bend_s + ANCHOR_MARGIN` (40 m, covering turn-confirmation lag) and `t0 := confirm-time`,
  collapsing accumulated slack. **Verified: 0 cone-below-truth violations** across the whole drive for
  both baseline and tightened cones. Early-fire slack tightened 1219 -> 307 m mean (81% tighter in the
  final 2 min). **What cannot be guaranteed tight:** a straight tunnel, no turns, constant unknown
  speed — nothing anchors, `slack = (V_LINE - v_true)*t` grows unbounded — safe but very early; and
  the guarantee holds only while `v_true <= V_LINE`.

### V_LINE by mode (m/s)

```
still = 0.0    walk = 2.0    car = 25.0    train = 22.2
```

### Safe-under-mode-uncertainty rule (the core invariant)

```
V_LINE_used(t) = max over currently-plausible (not-yet-excluded) modes
```

**Never assume a slower mode that could fire late.** Take the max plausible V_LINE until confident;
only drop it when a mode is positively *excluded*. Correctness rests on a **physical asymmetry, not on
classifier accuracy**:

- **`still` / `car` / `train` predictions EXCLUDE NOTHING** — a stopped or dwelling vehicle is
  indistinguishable from `still`, so the ceiling holds at the conservative vehicle level VEH_CEIL = 25.
- **ONLY K consecutive `walk` windows exclude the vehicle modes** and drop the ceiling to 2.0.
- Empirically real train windows are **never** predicted `walk` (0/2460), so the forbidden late case
  (a train mistaken for a walker) does not occur on real data, while a walker briefly treated as a
  vehicle just fires early (safe).

Behavior at boundaries: wrong-platform / standing -> vehicle-ambiguous handling noise -> stays at max
V_LINE (over-estimates, safe). Just-walking / not-yet-boarded -> sustained gait -> tightens to 2.0 in
~8 s; on boarding, gait stops, walk de-confirms and **V_LINE rises back to 25** (a rising ceiling fires
earlier = safe transition). **Verified: 0/2460 fused under-estimate windows on both real rides.**

---

## 5. Per-mode honest verdict

- **Walk = tractable.** PDR is the right model — distance error is a bounded ~4% of travelled (per-step,
  no compounding) vs naive INS blowing up to 9361 m at 10 min. Never-late invariant holds with
  V_walk=2.0. The ~2 Hz cadence discriminator is clean in simulation (periodicity 0.66) but
  **device-unproven**: the two real fixtures start at boarding (no sustained pre-boarding walk) and
  handheld train handling yields comparable 1–2.5 Hz quasi-periodic energy, so neither band-energy
  (ratio 1.19x / 0.98x) nor autocorrelation (0.81x / 0.90x) separates walk from train on real data.
  A real walk recording is the required next step.

- **Car = the hardest mode.** Raw dead-reckoning is essentially unusable underground (cruise speed
  unobservable, error ~t^2 to ~1 route-length in ~3 min). The reachability floor + turn anchors carry
  the guarantee: anchors collapse along-route error to ~0 at each bend and bound it <200 m between
  bends, but the unanchored straight run-in to the destination is where the cone alone must hold —
  safe (never late) but can fire very early.

- **Train = the main case, handled in a separate workflow** (rail geometry, station snapping, on-rail
  reachability). Here it appears only as the classifier's high-V_LINE anchor mode, and the key safety
  fact is empirical: real train IMU is never misread as walk (0/2460), so the never-late fusion is not
  betrayed by the one confusion that would matter.

**All three are simulation results** (datasheet + real-metro-grounded noise), not device-proven at
scale. The residual limitation of IMU-only mode switching — a continuously-walking passenger on a
moving train — is confirmed adversarially and must be gated on an independent off-vehicle corroborator;
the reachability upper bound remains the true guarantee.

---

## Referenced figures (under `/home/raed/geowake_imu_analysis/work`)

- `walk_pdr_summary.png` — walk PDR distance/position error vs naive integration
- `real_cadence_Nallur.png`, `real_cadence_Nadaprabhu.png` — ~2 Hz discriminator on real metro fixtures
- `car_tunnel_analysis.png`, `car_tunnel_summary.json` — car DR with/without anchors + never-late cone
- `mode_fusion.png` — classifier confusion matrix + fused V_LINE never-late trace

## Scripts

- Walk: `walk_sim_pdr.py`, `walk_cadence_realcheck.py`, `periodicity_check.py`, `sim_periodicity.py`
- Car: `car_tunnel_sim.py`
- Mode classification: `common.py`, `inspect_real.py`, `characterize_noise.py`, `simulate_modes.py`,
  `classify.py`, `fusion.py`, `adversarial.py`
