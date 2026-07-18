# Underground Position — Empirical Results (Real Handheld Data)

**Scope.** End-to-end validation of braking-force stop-anchoring for GeoWake's
underground / GPS-dark position problem, run on **two real Bengaluru Purple-line
rides recorded with a handheld phone** (fused GPS + ~50 Hz IMU):

- **Nada** — Nadaprabhu Kempegowda (Majestic), 13 stations, 2270 s, leg length 20 973.6 m
- **Nallur** — Nallur → Vijayanagar (opposite direction), 16 stations, 3036 s, leg length 24 044.2 m

Everything below is measured on those fixtures. Where the signal is weak, this
document says so. The never-late invariant
`s_max(t) = s0 + V_LINE·(t − t0)` is untouched by every result here — all IMU
evidence is **one-way tightening only** and can never advance the estimate past
the physics upper bound.

Plots referenced by filename live under `/home/raed/geowake_imu_analysis/work/`.

---

## 1. Signal extraction + brake SNR (E1)

**Attitude/gravity fix — the headline extraction win.** A gyro-propagated,
low-jerk-gated complementary filter estimates gravity **without** letting the
sustained brake force leak into the gravity vector (correction applied only in
near-1 g / low-spin / low-jerk windows — not a low-pass). On real handheld data
`|g|` stays clean through every brake:

| Ride  | mean \|g\| | std   | min   | max   | per-approach min |
|-------|-----------|-------|-------|-------|------------------|
| Nada  | 9.831     | 0.031 | 9.721 | 9.902 | 9.722            |
| Nallur| 9.838     | 0.032 | 9.704 | 9.920 | 9.704            |

No dip toward 8–9 m/s² during braking → **attitude fix confirmed**; the brake
force survives in the linear specific force instead of corrupting gravity.

**Brake-event SNR** (median `|a_long|` in ±12 s of arrival ÷ cruise median):

| Ride  | median | mean | min  | max  | stations > 1.5× |
|-------|--------|------|------|------|-----------------|
| Nada  | 1.22×  | 1.30×| 0.84×| 1.97×| 3 / 13          |
| Nallur| 1.55×  | 1.64×| 0.54×| 3.50×| 9 / 16          |

The ±12 s median is **diluted by the near-zero-force dwell**. The physically
correct peak-sustained approach SNR (window [−15,+8] s, 4 s-smoothed) is strong:

| Ride  | median | mean | min  | max  | stations > 2× |
|-------|--------|------|------|------|---------------|
| Nada  | 2.48×  | 2.53×| 1.61×| 3.61×| 10 / 13       |
| Nallur| 3.14×  | 3.41×| 1.61×| 7.93×| 14 / 16       |

**Honest limitation carried forward:** the along-track **sign** is only weakly
observable on handheld data — `corr(a_long, GPS dv/dt | accel events)` = 0.050
(Nada) / 0.089 (Nallur). Handling/jitter dominates the sign; the reliable brake
carrier is the `|a_long|` **magnitude**, not the signed value. Downstream stages
use magnitude + the decel→dwell→accel sequence, never the raw sign.

Plots: `fixture_Nada..._signals.png`, `fixture_Nallur_to_Vijaynagar_signals.png`.

---

## 2. Stop / dwell detection (E2)

Final detector = dip-gated brake→launch **pair** matched filter (kf = 1.5, ±10 s
tolerance, 75 s NMS). Per-station recall (±10 s), precision, and stop-count error:

| Ride  | detected | recall      | precision      | count-err mean / max | exact count | arrival offset (median / \|max\|) |
|-------|----------|-------------|----------------|----------------------|-------------|-----------------------------------|
| Nada  | 20       | 5/13 = 38 % | 5/20 = 25 %    | 3.77 / 7             | 2/13        | −2.3 s / 6.9 s                    |
| Nallur| 25       | 9/16 = 56 % | 9/25 = 36 %    | 4.38 / 8             | 0/16        | −2.5 s / 9.0 s                    |

Count error is **one-signed** — the detector monotonically **over-counts**
(Nada signed `[0,0,2,3,3,3,4,4,4,5,7,7,7]`; Nallur `[−1,1,2,2,3,3,2,4,4,4,6,7,7,8,8,8]`).
This is the never-late-**dangerous** direction (a false stop would advance the
estimate) → the unguarded IMU stop-count **must be reachability-gated** before it
can move position.

**Why vibration/ZUPT is disproven on this data:** dwell is *noisier* than cruise
(passengers board). Dwell/cruise energy ratios — >4 Hz vib 1.05 (Nada) / 1.27
(Nallur); 0.2–2 Hz 1.32 / 0.87; 0.5–4 Hz 1.05 / 1.17. A stop does not quiet a
handheld phone, so ZUPT-via-vibration fails.

**Separability wall:** force pulses are present at 13/13 and 15/16 stations
(event sensitivity high), but ~60 % of strong pulses are handling / curves /
signal-stops; the full dipole score puts the median true station only around the
80th percentile of all windows. Many Nallur "false" positives cluster in
1900–2400 s near the Majestic interchange, where the train genuinely crawls and
signal-stops — IMU alone cannot separate signal-stop from station-stop.

Plot: `e2_stop_detection.png`.

---

## 3. Velocity + full-stop confirmation (E3) — honest negative

Integrating `a_long` over each brake event to recover Δv and confirm a full stop
**does not work** on handheld data.

Ground-truth full stops (GPS min-speed < 2 m/s within ±8 s of arrival):
Nada 12/13, Nallur 11/16 — the stops are real.

| Confirmed full stops (Δv in 0.6–1.6·v_cruise) | BLIND (signed) | PHYSMAG (magnitude) |
|-----------------------------------------------|----------------|---------------------|
| Nada                                          | 1 / 12         | 2 / 12              |
| Nallur                                        | 1 / 15         | 3 / 15              |

Δv **magnitude error** vs GPS v_cruise ≈ the cruise speed itself (~11 m/s median;
measured \|Δv\| scatters 3–40 m/s vs a 12–21 m/s target). Anchored speed-integral
distance vs true inter-station `s_travel`:

| Ride  | DR median\|e\| | DR MAPE | DR total vs true        | TRAP median\|e\| | TRAP MAPE | TRAP total       |
|-------|----------------|---------|-------------------------|------------------|-----------|------------------|
| Nada  | 1234 m         | 71 %    | 5 955 / 20 974 m (−72 %)| 691 m            | 40 %      | 16 315 m (−22 %) |
| Nallur| 1324 m         | 83 %    | 7 440 / 24 044 m (−69 %)| 723 m            | 71 %      | 29 010 m (+21 %) |

Root cause = E1's caveat compounded: signed integration is near-zero-mean noise
(collapses to ~30 % of true distance), and even granting the physics sign the
per-event magnitude carries a v_cruise-sized error. This is **not a pipeline
bug** — the handheld specific-force signal simply lacks per-event velocity
observability. Where the brake ramp is strong the magnitude does land near
v_cruise (a handful of stations: Nada st3 −16.2 vs 20, st8 −12.2 vs 15.5; Nallur
st10 −14.3 vs 18.6, st14 −10.9 vs 12.4, st15 −17.1 vs 15.6), so brake **energy**
is a better stop feature than integrated Δv.

Plot: `e3_speed_reconstruction.png`.

---

## 4. HEADLINE — position through the GPS blackout (E4)

Route-constrained 1-D (arc-length) estimator, three variants per GPS-dark
segment: **(a) naive constant-velocity DR**, **(b) free-run reachability cone**
(the never-late upper bound), **(c) stop-anchored route-constrained** trapezoid
that decelerates to each *known* station position, dwells, and re-launches on a
gated IMU cue. Params from GPS aggregate (not per-window GT): a_max = d_max =
0.8 m/s², V_cruise = 13 m/s, V_LINE = 22.2 m/s.

### 4.1 Position error, both rides (median / max \|err\| at window-end, good-anchor windows)

| Estimator                       | pooled median | pooled max | vs naive DR |
|---------------------------------|---------------|------------|-------------|
| (a) naive DR (CV)               | **158 m**     | 414 m      | —           |
| (b) reachability cone (free-run)| 670 m         | **7279 m** | 4.2× worse  |
| (c) stop-anchored route-constr. | **139 m**     | 414 m      | 1.1× better |

Pooled over n = 12 good-GPS-anchor window-ends (hacc ≤ 40 m). By window length
(median \|err\| CV / CONE / RC): short < 40 s (n=6) 161 / 581 / 139; medium
40–120 s (n=5) 110 / 854 / 296; long > 120 s multi-station (n=1) 236 / 7279 / 34.

### 4.2 THE headline case — Nallur 1874–2424 s (549 s dark, 3 stations, GPS out > 9 min)

| Estimator | error @ window-mid | error @ window-end |
|-----------|--------------------|--------------------|
| (a) naive DR      | +42 m   | **+236 m**  |
| (b) cone (free-run)| +3569 m | **+7279 m** |
| (c) stop-anchored | −308 m  | **−34 m**   |

On the hardest real blackout, stop-anchoring tracks true position to **−34 m** —
a **~7× edge over naive DR** and a **~214× edge over the free-run cone**.

### 4.3 Robustness — the safety-critical win (poor-anchor, GPS dies while stopped)

When GPS dies while the train is stopped at a station, naive CV extrapolates
v = 0 and concludes the train **never moved** — the alarm never arms and the
rider sleeps past the stop. RC, anchored to the known boarding-station position,
launches and drives to the next station:

| Nada segment (hacc = 100, excluded from aggregate) | naive CV | stop-anchored RC |
|----------------------------------------------------|----------|------------------|
| 26–149 s (blind right after departure, v_fix = 0)  | −1389 m  | **−85 m**        |
| 160–238 s                                          | −751 m   | **+245 m**       |
| 312–328 s (GPS re-acquisition itself corrupt — 880 m jump; **all** estimators fail) | +752 m | +924 m |

Per-window detail: `e4_errors.csv`. Plots: `e4_position_Nada.png`,
`e4_position_Nallur.png`.

**Honest limits on E4:** (1) the JSON `blind_windows` **understate** true dark
time — a whole 237–327 s Nada stretch is hacc = 100 garbage yet unmarked, and its
first re-acquired fix is 880 m off, which no downstream estimator can fix;
(2) IMU dwell timing is RC's main error source over long multi-station windows;
(3) RC's along-track speed uses the last GPS cruise speed + fixed profile, not IMU
dead-reckoning (E1: sign weakly determined). Never-late: the cone under-shoots true
progress in **0/30** evaluation points (empirically preserved); RC is a point
estimate and under-shoots in 6/15 window-ends (worst −296 m), so **RC must not
replace the cone for the fire decision** — it is a UX "likely position" only.

---

## 5. Reachability-cone tightening + early-firing reduction (E5)

"Wake 2 stops before destination" with a simulated GPS blackout over the
approach. Fire time under (i) free-run, (ii) dwell-subtracted, (iii)
stop-count-anchored, measured against the **true destination arrival**
(V_LINE = 22 m/s both rides):

| Ride   | (i) free-run  | (ii) dwell-subtracted | (iii) stop-anchored | tightening | never-late |
|--------|---------------|-----------------------|---------------------|------------|------------|
| Nada   | +518.7 s early| +518.7 s (dwell missed, graceful) | **+297.3 s** | −43 %      | all fires ≤ dest arr ✓ |
| Nallur | +471.2 s early| +466.1 s (D = 5.1 s)  | **+254.7 s**        | −46 %      | all fires ≤ dest arr ✓ |

Early-firing shrinks **43–46 %** from free-run to stop-anchored while **every
fire stays strictly before true destination arrival**. Missed-detection probe
(proves tightening only ever relaxes): dropping a Nallur dwell moves the fire
2–3 s **earlier**; missing the target stop degrades (iii) → (ii) (211.5 s
earlier) — every miss fires earlier, never later, all still ≤ destination arrival.

On handheld IMU the confirmed sub-vibration-floor stopped **core** is short
(~1–5 s, sometimes < 1 s or missed), so *dwell-duration* subtraction yields only a
few seconds; the dominant, robust tightening is **binary stop-count anchoring**
via dip-depth. Depth-based recall is imperfect (6/13 Nada, 11/16 Nallur across
all stations) but a miss only relaxes toward the free-run backstop.

Plots: `e5_cone_Nadaprabhu.png`, `e5_cone_Nallur.png`.

---

## 6. HONEST VERDICT

**How much does braking-force stop-anchoring improve underground position vs the
current EKF/reachability?**

- **Position through a real GPS blackout: large and decisive in the worst case.**
  On the 549 s / 3-station Nallur blackout, stop-anchoring lands at **−34 m** vs
  **+236 m** naive DR and **+7279 m** for the free-run reachability cone (~7× and
  ~214× better). Across all good-anchor windows it edges naive DR on median
  (139 vs 158 m), matches it on max (414 m), and cuts the cone's
  over-conservatism ~5× (670 → 139 m). Its **decisive** advantage is robustness
  in the safety-critical case — GPS dying while stopped, where naive DR freezes at
  v = 0 and never arms the alarm (−1389 m) while stop-anchoring drives to the next
  station (−85 m).

- **Alarm early-firing: 43–46 % tighter** (Nada 518.7 → 297.3 s, Nallur
  471.2 → 254.7 s) with never-late preserved by construction on both real rides.

- **The improvement comes almost entirely from BINARY stop-count anchoring to
  known station geometry, not from IMU velocity.** Per-event Δv integration is a
  quantified negative (1–3 of ~12–16 stops confirmed; distance MAPE 71–83 %), and
  standalone IMU stop *counting* tops out at 38–56 % recall / 25–36 % precision
  and monotonically over-counts. So IMU is a **weak, reachability-gated anchor,
  not a standalone position source.**

**Residual error.** With a good pre-blackout GPS anchor, expect **~140 m median /
~400 m max** route-constrained position error, and **tens of metres** at the
*next station* when a stop is confirmed (the anchor resets to known geometry). The
binding failure modes are **(a)** long multi-station blackouts where dwell-timing
drift accumulates, and **(b)** corrupted GPS *re-acquisition* (Nada's 880 m jump),
which defeats every estimator equally.

**What needs better placement / baro / WiFi / more data.**

1. **Along-track sign observability** is the root limitation (corr ≈ 0.05–0.09).
   A **fixed / cradle-mounted** phone (or a known-orientation wearable) would
   likely recover the sign and unlock real Δv integration — the single highest-
   value hardware change.
2. **Barometer** for a vertical-motion / grade cue and an independent
   dwell-vs-move discriminator, since vibration ZUPT is disproven here (dwell is
   noisier than cruise on handheld).
3. **WiFi/BLE station beacons** (or cell-ID) for a GPS-independent *hard* stop
   anchor — the clean way to reset the cone origin at a confirmed platform and
   collapse the residual to near-zero at each station.
4. **More rides**, including **express/skip-stop** patterns (neither real ride
   skips, so express is currently untestable) and multiple phone placements, to
   move detection thresholds off two rides.
5. **Truth-quality GPS logging** — the fixtures' `blind_windows` understate true
   dark time and one re-acquisition is 880 m off; better ground truth is needed
   to trust the tails.

**Bottom line.** On real handheld data, braking-force stop-anchoring is a genuine,
measured win for underground position — dramatic in the long-blackout and
GPS-dies-while-stopped cases, and worth a 43–46 % cut in alarm early-firing — but
its power is **map-geometry anchoring gated by reachability**, not IMU dead-
reckoning. The never-late guarantee rests on the reachability cone throughout;
every IMU signal here can only tighten it, never fire it late.
