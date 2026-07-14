# WakePoint — ETA Estimation + Alarm-Trigger Decision Theory Under Position Uncertainty

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
