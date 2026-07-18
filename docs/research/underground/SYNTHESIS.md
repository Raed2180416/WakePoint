# Underground positioning — SYNTHESIS & VERDICT

_Consolidates four deep, adversarially-verified research workflows (FOUNDATION, EMPIRICAL_RESULTS, MODES, ON_ROUTE_CONFIRMATION) + independent hands-on validation on the two REAL Bengaluru Purple-line rides. Every empirical number below was measured on real handheld data. The one hard rule held throughout: **never claim device/real-world proof from a simulation, and never ship a change that isn't provably never-late.**_

## The question
Can we make the underground never-late alarm tighter (less absurdly early) than the raw reachability cone — by detecting station stops from the braking force, by using observed speed, and by knowing whether we're actually on the train? And is any of it never-late-safe to ship?

## The verdict in one paragraph
**The win is real, large, and validated — but it is sensor-gated, not shippable tonight.** Braking-force → *stop-event detection* → re-anchoring to *known station geometry* cuts alarm early-firing **43–46%** on the real rides and closes the worst case from **+7279 m to −34 m** on a 9-minute / 3-station blackout (~214× tighter than the raw cone). But this is only never-late-safe with **high-precision** stop detection (a false stop is the *sole* late-fire mechanism), and precision on a *handheld* phone requires an independent corroborator — **barometer / magnetometer / WiFi** — that GeoWake does **not log yet**. Until that data exists, the safe default is the current **mode-max free-run reachability cone**, which is never-late by construction. Nothing in the never-late core was changed tonight, on purpose.

---

## What we learned (with the real numbers)

### 1. The braking force works for *stop detection*, not for velocity/position
- Attitude fix confirmed: gyro-propagated gravity (never low-pass — that erases the brake) keeps `|g|` at 9.70–9.92 (std 0.03) with no brake-leak. Brake SNR **2.5–3.1×** cruise.
- **But the longitudinal *sign* is unobservable** on handheld (correlation 0.05–0.09) — handling dominates. So you **cannot** integrate the brake into velocity (Δv error ≈ v_cruise itself; only 1–3 of 12–16 stops confirmed by Δv magnitude; distance MAPE 71–83%). *This is a fundamental result, not a bug.*
- Naive `|accel|`-variance ZUPT is **disproven** on real data — station dwells have *more* motion energy than cruise (people move at stops). Must use spectral vibration-band power, and even then handheld recall is 38–56%, precision 25–36% (**monotone over-count**).

### 2. The actual win: binary stop-count anchoring, reachability-gated
- Detecting *that* a stop happened (~85% recall) and snapping arc-length to that station's **known `s_travel`** is what works. On the hardest real blackout (Nallur, 549 s, 3 stations): naive DR **+236 m**, raw cone **+7279 m**, stop-anchored **−34 m**.
- Fed into the cone as a `min()` of individually-valid upper bounds, this cuts early-firing **43–46%** while **the cone under-shot true progress 0/30 points** (never-late empirically preserved). Missed stops only loosen the bound (safe); **a false stop is the only late-fire path** → precision-over-recall is mandatory.

### 3. The observed-speed idea (your proposal) — right instinct, sensor-gated
- Literal form (`V_LINE := observed max`): **proven unsafe** — the rides saw only 21.6 m/s vs a ≥25 m/s true ceiling, so it under-bounds → late.
- Safe form (accel-limited cone `s_max = s₀ + v₀·τ + ½·a_max·τ²`): valid *in principle*, but my per-τ validation on real data shows it **dips below truth in 24/33 windows with a naive v₀** (last GPS speed is unreliable — the train launches from near a station where GPS read it slow). Safe only with **dwell-gated v₀** (v₀=0 at a *confirmed* station) + `a_max` as a true upper bound (≥2.0–3.0, since real accel hit 1.5–2.8) — i.e. it *also* depends on stop-confirmation. Modest payoff (~25% tightening) even when safe.
- The genuinely-safe uses of observed speed survive: **mode confirmation**, **kinematic params** for the between-station model, and the elegant one — **crowd-sourced per-segment max speeds, design-speed-floored** (ties to the aggregate-data moat) → a valid *tighter* per-segment V_LINE.
- V_LINE sanity: max true speed on the real rides is **21.6 m/s (78 km/h)**; production `defaultMps=28` (100 km/h) is a valid ceiling; the operational 80 km/h (22.2) is **not** (segment data implies a higher true max).

### 4. "Are we on the train, or driving/walking along the line?"
- **Unsolvable from motion/IMU classification alone** — train↔subway and car↔bus are the most-confused SHL classes (best user-independent F1 ~89%, unbroken 2024–25). Rail-vibration is dead on handheld (d′=−0.22).
- **Solvable from geometry:** (G) sustained route-correlated GPS outage (minutes dark on the train vs <10 s for a surface car) and (B) repeated dwell at station arc-positions — either near-perfectly *excludes* a car. Cross-track offset is a *gate only* (5 m median on a good ride → parallel road ≥30 m detectable; 14 m on a coarse ride → a near road is invisible). **Boarding is detectable** (dwell→launch, SNR 3–4.5×).
- Adversarial holes found + must be fixed before enabling: a highway car in a *parallel road tunnel* also latches G (fix: G requires confirmed route *progress* + road-class speed bound); express/RRTS exceed hardcoded ceilings (fix: gate-ON uses the real per-line `VLineTable` ceiling). Until fixed, safe default = untightened mode-max cone.

### 5. Modes (car / walk)
- **Walk = tractable:** PDR distance error bounded at 1.6/2.6/3.8% over 1/3/10 min (37× better than naive integration). Using the metro V_LINE for a walker is dangerous → mode selection matters.
- **Car = hardest:** raw DR unusable (~44 m/100 m — cruise speed unobservable); turn-to-polyline anchors collapse error at bends, <200 m between. Reachability floor + turn anchors is the only guarantee.
- **Mode classifier** (depth-4 tree, 11 features): the safety-critical mistake — **train misread as walk = 0/2460** on real data — with a proven rule `V_LINE = max over not-yet-excluded modes` (0/2460 under-estimates). This is a real, safe never-late *hardening* (closes the fast-parallel-car late hole), pending the classifier wiring.

---

## What is safe to ship *now*
**Only the current mode-max free-run reachability cone** (`V_LINE=28`), which is never-late by construction. **No tightening was applied to the never-late core tonight** — the verifiers and the real-data validation both showed every cone-tightening is either sensor-gated or not-yet-safe. Shipping a half-validated tightening to the crown jewel would violate the honesty rule.

## The validated roadmap (build-off-existing, ordered)
1. **Log barometer + magnetometer** (extend `sensor_fusion.dart`) and **collect real underground rides** across ≥3 lines + at least one *parallel-car* ride (to measure the on-train false-positive rate, currently UNMEASURED). This is the gating data-collection step everything else needs.
2. **Precision-gated stop detector**: {cruise,brake,dwell,launch} HMM on spectral band-power + Δv + **≥2 corroborators** (baro step / mag event / "reachability interval contains exactly one station"), tuned for near-zero false positives. Reuse `active_route_manager` station-snap + `station_association`/ZUPT.
3. **Reachability-gated stop-anchoring** as a `min()`-of-upper-bounds term with a one-gap cap — provably never-late even with imperfect detection (missed → loosen; false → the gated risk). Extend `reachability.dart` behind a default-OFF flag; enable only after (1)+(2) validate on device.
4. **Mode-max V_LINE selection** (still/walk/car/train → max plausible ceiling). Reuse the modes classifier; a never-late *hardening*.
5. **On-train gate** (G ∨ B) with the two adversarial fixes; enables the tightening only when on-train confidence is high.
6. **Accel-limited cone** with dwell-gated v₀ (after stop-confirmation exists) + the terminal-braking envelope toward confirmed scheduled stops (largest-plausible d_max).

## Honest status of every claim
Every number here is measured on **real handheld data** but from only **two Bengaluru Purple-line rides** on one device — **device-unproven at scale**, no barometer/magnetometer/WiFi columns, no parallel-car fixture, no express/skip data. The reachability never-late guarantee is **untouched and intact**. The path to a materially tighter underground alarm is clear, validated in principle, and blocked only on a device-sensor data-collection phase — not on the physics.

_Artifacts: `FOUNDATION.md` (SOTA + derivations, 958 L, 160 cites, rigor-checked), `EMPIRICAL_RESULTS.md`, `MODES.md`, `ON_ROUTE_CONFIRMATION.md`; analysis scripts + plots under `/home/raed/geowake_imu_analysis/work/` (e4_position_*.png, e5_cone_*.png, crosstrack_discriminator.png, …); reproduction scripts copied to `docs/research/underground/scripts/`._
