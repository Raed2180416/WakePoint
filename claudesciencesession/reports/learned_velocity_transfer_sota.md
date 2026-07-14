# Learned Velocity for Metro Blackout: Real Signal, Transfer, and Safe-Fail

**Scope.** WakePoint's blackout EKF (state `[arc-position s, velocity v, accel-bias b]`) fuses a learned velocity as a pseudo-measurement. On our one real Bangalore ride we confirmed **no phone-accel frequency band tracks train speed** (surface metro-cruise windows, n=349: pearson r(log band-energy, GPS speed) flat-to-negative for every band 0.5–49 Hz; broadband RMS r=−0.33). The synthetic R²=0.84 was **circular** — the HistGBR regressor inverted its own speed-driven vibration generator. This memo answers three SOTA-as-of-July-2026 questions and gives a keep/demote/replace decision plus a safe-fail fusion spec. All arXiv IDs were resolved through the arXiv API to confirm title match; two invented control IDs (`2606.99999`, `2412.54321`) correctly returned *not found*.

*Evidence policy: the physics below is first-principles derivation (labeled as such) anchored to our own measured n=349 null and to two abstract-verified arXiv papers. The two general web searches on rail-vibration returned title/URL-only results (no body text), so no author names, quotes, or internal numbers are attributed to unread sources.*

---

## Q1 — Is there a physically real, transferable IMU→train-speed signal?

**Yes at the axle-box; effectively no at a pocketed consumer phone.** The real signal is track-periodicity excitation: as wheels pass discrete supports, the structure is excited at a tonal frequency **f = v / λ** (v = speed, λ = feature spacing). This periodic sleeper-passage excitation is real and measurable — but at **rigid axle-box mounts**. Vold-Kalman order tracking of axle-box accelerometers (arXiv:2209.12899, abstract) decomposes the signal into periodic wheel/track excitation–response pairs and relates the **sleeper-passage amplitude** to track stiffness and wheel–rail forces. That is a low-cost, bogie-mounted, high-rate sensing context — not a phone in a pocket.

Whether that tone reaches a pocketed phone is a question of **frequency, mount transfer, and sampling** (first-principles estimates, my derivation):

- **Frequency.** Sleeper spacing λ ≈ 0.6 m. At metro cruise 10–22 m/s (36–80 km/h) the sleeper-passing fundamental is **f = v/λ ≈ 17–37 Hz**. Rail-joint tones (λ ≈ 18 m) would sit at 0.6–1.2 Hz but exist only on jointed track; modern metro is continuous-welded, so that low tone is largely absent underground.
- **Two-stage low-pass to the phone.** (1) *Bogie → car-body:* secondary suspension has a car-body vertical mode near ~1 Hz; above resonance a single-DOF isolator's transmissibility falls as (f_n/f)². A back-of-envelope with f_n≈1 Hz gives order **−59 dB at 30 Hz** ((1/30)²) — i.e. the sleeper tone is strongly suppressed at the car floor even before structural resonances are considered. (2) *Car-body → seated passenger → pocket:* compliant soft-tissue/fabric coupling behaves as a further low-pass, attenuating the tens-of-Hz range more than the low band. The 17–37 Hz tone is therefore attenuated **twice** before reaching the IMU.
- **Sampling.** At 100 Hz (Nyquist 50 Hz) with consumer anti-alias rolloff, whatever survives near 25–35 Hz sits in the noise floor — consistent with our best (still weakly *negative*) band being 35–49 Hz.

What *does* reach the phone in the low band (<5 Hz) is car-body sway, passenger motion and quasi-static accel/decel — **none scales monotonically with cruise speed**, which is exactly our empirical null. The one abstract-verified smartphone-in-metro system agrees it is not a speed-regression problem: **M-Loc** (arXiv:2003.10531, abstract) is infrastructure-free **fingerprint/pattern-map localization** from accelerometer + magnetometer + barometer, reporting **93 % accuracy at 3 stations and 98 % at 5 stations** across 3 lines / 55 stations — it matches route patterns and counts stations, it never regresses cruise speed.

**Verdict:** the f=v/λ signal is real but a *rigid-mount, high-g, high-rate* phenomenon. At a pocketed phone it is destroyed by suspension + body damping and undersampling. This is **physics, not a data-collection artifact** — collecting more rides will not recover it. Two real signals *could* be engineered later, neither being pocket-accel vibration: **barometric pressure-rate** in deep grade tunnels (note M-Loc's use of the barometer), and **two-phone cross-correlation TDOA** (needs a second device). Treat both as future work, not the current channel.

---

## Q2 — Do pedestrian-trained inertial-odometry models transfer to train motion?

**No, and domain adaptation cannot fix it.** TLIO (arXiv:2007.01867), RoNIN (arXiv:1905.12853), EqNIO (arXiv:2408.06321), MosaicIMU (arXiv:2606.09355) and Inertia-1 (arXiv:2607.06617, 18.2 M hours of *wearable* accel) all learn a **neural displacement prior**: they map the quasi-periodic signature of *self-propelled human gait* (foot-strike cadence, body sway) to displacement. Their core assumption is that **the device moves with the person** and the person generates the motion.

A seated train passenger violates this at the root: the rider is **near-stationary relative to the vehicle**, and the vehicle's true motion leaves almost no distinctive inertial signature at the phone (Q1). The network's input manifold simply does not contain the train's speed. So these models regress either their stationary-passenger prior (≈0 displacement) or noise — and their **learned covariance was trained on pedestrian residuals**, so it will report *confident* wrong values off-distribution. TLIO's abstract is explicit that its network is "trained with pedestrian data from a headset" and produces displacement + uncertainty for EKF fusion — a pedestrian generative assumption that a seated passenger's motion, far outside that training distribution, does not satisfy.

This gap is **not distributional, it is informational.** Domain adaptation, sim-to-real and self-supervision (e.g. KISS-IMU's LiDAR-ICP pseudo-labels, arXiv:2603.06205; EqNIO's orientation canonicalization; MosaicIMU's carrier-expert mixture) all *align or reweight features that exist in the target signal*. None can synthesize a speed feature the sensor never captured. EqNIO/MosaicIMU improve **generalization across mounting orientation and carrier**, which is valuable for the parts of our stack that *are* observable, but they cannot manufacture cruise speed from a pocket.

**Verdict:** do not use pedestrian NIO models for train **velocity magnitude**. Their legitimate transferable use is only the observable sub-tasks: **motion-state / ZUPT classification** and **heading**, where a genuine inertial signature exists. Their covariance heads are the right *mechanism* (see Q3) but must be re-gated for OOD, not trusted as-trained.

---

## Q3 — Safe-fail: interval-valued velocity → EKF downweighting → early alarm

The constraint is **fire EARLY, never LATE**. The alarm is a critical-fractile rule: fire when the **upper** quantile of the position belief reaches the target, i.e. when `ŝ + z_fire·σ_s ≥ s_target − margin`. **Inflating `σ_s` makes the upper bound reach the target sooner → earlier alarm → safe.** The catastrophic failure is the opposite: an *over-confident low* velocity (small `vel_var` around a wrong slow value) that starves σ-growth and fires late. Everything below is engineered to make that impossible.

**Emit an interval, not a point.** Two compatible sources of interval width:
1. **Covariance-head regression** — TLIO/EqNIO already output displacement **and uncertainty**; TLIO fuses its learned uncertainty as the EKF update step and reports it outperforms velocity-integration for position (abstract). Use the head's variance as the *aleatoric* term.
2. **Conformal calibration** — wrap the regressor with **CQR** (arXiv:1905.03222) for finite-sample coverage, **ACI** (arXiv:2106.00170) to widen the interval online when realized coverage drops under shift, and **Mondrian / group-weighted conformal** (arXiv:2401.17452; crepes) to keep coverage *per-regime* (dwell / cruise / OOD) rather than only marginally.

**The OOD gate is mandatory** (else a pedestrian-calibrated interval stays narrow on train data). Add an explicit detector — **Mahalanobis distance of the 8 IMU features to the training manifold**, and/or ACI's coverage tracker — and enforce a **lower bound on interval width that grows with OOD score**. Because metro input is *always* OOD, the interval is always wide.

**Fusion into the 1-D EKF.** For velocity measurement `H = [0,1,0]`:
```
half = 0.5 * (v_hi − v_lo)            # conformal/covariance interval half-width (m/s)
vel_var = max( (half / z)^2 ,          # z = z-score of interval's nominal coverage (1.96 @95%)
               vel_var_floor(ood) )    # OOD-driven floor: ↑ with Mahalanobis / ACI score
```
On metro (always OOD) `half` is huge → `vel_var` huge → **Kalman gain on velocity → 0** → the update is a **safe no-op**; the EKF propagates on the process model, `σ_s` grows, dwell-count association + motion-gated ZUPT carry the estimate, and the critical-fractile rule fires early. This reproduces the graceful STOPS-mode degradation our ablation already showed. Never let the regressor *lower* `vel_var` below the OOD floor — that is the only way it could cause a late alarm.

**Libraries:** MAPIE (`scikit-learn-contrib/MAPIE`, CQR + PyTorch/TF wrappers + time-series) and crepes (`henrikbostrom/crepes`, Mondrian/normalized regressors) both wrap the existing HistGBR unchanged.

---

## Decision: DEMOTE (for metro)

Do **not keep** the regressor in its position-driving role (it is circular and there is no pocket-accel speed signal); do **not delete** the fusion channel.

1. **Strip position-driving authority.** The HistGBR velocity must never *tighten* `σ_s` on metro.
2. **Replace its internals** with an OOD-gated interval predictor (covariance-head and/or CQR+ACI+Mondrian) calibrated so metro → maximal width.
3. **Fuse as `vel_var=(half/z)²` with an OOD floor**, so the channel self-disables to a safe no-op; alarm rides on dwell-count + ZUPT + honest σ-growth → fires early.
4. **Keep the slot** so a *genuinely observable* velocity source (barometric pressure-rate; two-phone TDOA; a strong-periodic line) can be dropped in later without re-architecting.

**Net:** demote the point estimate to an OOD-aware interval whose default metro behavior is a downweighted no-op — preserving fail-early-never-late by construction.
