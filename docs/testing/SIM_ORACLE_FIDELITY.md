# L0 Simulation-Oracle Fidelity Audit

**Scope:** Does the synthetic GPS/IMU that GeoWake's never-late proof rests on actually
match real-world sensor behaviour? This audits the *foundation* — the two code paths that
manufacture the "truth" every never-late PASS is graded against — against the recorded
ride corpus in `~/geowake_imu_analysis/extracted/` (16 real Bengaluru bus/metro rides,
iPhone 15 + Android, Dec 2025).

**Audited artifacts**
- `lib/core/ekf/imu_replay_engine_v2.dart` — the Dart IMU+GPS synthesizer (dashboard + `loadFromPolyline`).
- `~/geowake_imu_analysis/scale/build_scale_rides.py` — the 395-ride scale-matrix generator (GPS-only).
- `test/scale/reachability_scale_test.dart` — the at-scale never-late gate that consumes the matrix.
- `test/ekf/replay_harness_test.dart` — the offline never-late gate over recorded + synthetic fixtures.
- `lib/core/reachability/reachability.dart` — the bound whose preconditions the oracle must respect.

Methodology note: I did not run flutter/emulator. All numbers below are static reading of the
generators + statistics computed directly from the recorded CSVs (script:
`scratchpad/analyze_recorded.py`, run against the 14 rides with non-empty `Location.csv`).

---

## (a) Honest verdict

**The L0 oracle is NOT a faithful proxy for reality for the one failure mode that breaks
never-late; it is faithful only for the failure mode it was built to demonstrate.** The
never-late guarantee in `reachability.dart` holds iff two preconditions are true on a real
ride (`reachability.dart:535-537`): (i) every accepted GPS fix, forward-overbounded by its
reported accuracy, is *at least as far along the route as the train truly is*
(`anchor.sHi >= true progress`), and (ii) the V_LINE ceiling is `>= true speed` everywhere.
Both the scale generator and the scale gate **construct the data so these preconditions can
never be violated**: the never-late scale gate does not even read the synthesized noisy GPS —
it re-anchors the tracker to the *exact true arc position* with a fixed `accuracyMeters: 10.0`
during every non-blind second (`reachability_scale_test.dart:129-132`), and the Python
generator injects position scatter *purely perpendicular to the direction of travel*
(`build_scale_rides.py:256-258`), which the recorded-fixture harness then *projects back onto
the known route* (`replay_harness_test.dart:831`), discarding it. In other words the oracle
proves "if GPS is either perfectly-true-but-blanked or true-plus-10 m, the cone never fires
late" — a statement about the geometry engine, not about GPS. The real corpus shows the
missing middle: fixes that pass the 100 m accuracy gate but are tens to hundreds of metres
wrong, GPS blackouts up to **139 s** (vs the sim's clean windows), hacc reaching **3948 m**
mid-metro (vs the sim's frozen 100 m), a gyro channel that in reality carries the entire
turn-rate signal but in the sim is *pure noise with a permanent `TODO`*
(`imu_replay_engine_v2.dart:2287`), and iOS accelerometer that is **gravity-removed and
tilted ~24°** where the synthesizer emits a clean level `z = 9.81`. The single most dangerous
gap — an *along-track-backward* GPS bias that passes the accuracy gate and drops `anchor.sHi`
below true progress — is structurally impossible to generate with the current oracle, is a
direct never-late violator per the bound's own precondition, and is exactly the "frozen
confident fix" the harness's own phantom probe annotates as **"expectation: FAIL — no phantom
defense in current lib/"** (`replay_harness_test.dart:1111`, report-only). Bottom line: a
sim "never-late PASS" is strong evidence the *reachability math and blackout dead-reckoning*
are sound, and near-zero evidence that never-late survives *real GPS error, real detector
error, real device orientation, or a real train faster than 0.8×V_LINE*.

---

## (b) Phenomenon-by-phenomenon fidelity table

Legend for risk: **NL↑** = gap can cause a LATE fire (breaks the core promise);
**E↑** = gap causes wildly-early fire (product issue, not safety); **DR** = corrupts
dead-reckoning validation only.

| Phenomenon | What the sim assumes | What reality is (recorded corpus / research) | Fidelity gap | Never-late risk |
|---|---|---|---|---|
| **GPS accuracy (normal)** | Hardcoded `accuracy: 10.0` in every normal fix (`imu_replay_engine_v2.dart:2148`); scale gen draws hacc from `{4,8,12}+|N(0,1.5)|` (`build_scale_rides.py:253`); scale **gate ignores this entirely** and uses `accuracyMeters: 10.0` on the true position (`reachability_scale_test.dart:131`). | Pooled recorded hacc: median **6.8 m**, p90 **15.9 m**, **p99 782 m**, max **3948 m**; 4.3% of fixes > 50 m. Reported hacc is a *lower bound* on true error in urban canyon (well documented; corpus has no survey truth to measure the residual, but see multipath row). | Sim treats reported accuracy as ground truth and never lets a "good-hacc" fix be positionally wrong. The fat tail (p99 = 782 m) exists but is only ever seen as a *blanked* fix, never as an *accepted-but-wrong* fix. | **NL↑** |
| **GPS blackout onset/duration** | Sim: clean binary windows. `tunnelSimulation` blanks all between-station fixes (`:2163-2176`); `loadFromPolyline` blackout windows return `shouldEmit:false` (`:2133-2137`); scale gen freezes last position + hacc=100 for windows of 20–60 s / 300–600 s (`build_scale_rides.py:401-427`). | Real metro: on Nallur→Vijaynagar, **61 % of ride time was in GPS gaps > 5 s**; individual gaps up to **139.8 s / 97.3 s / 81.3 s**; and the *rest* of the time GPS emitted garbage (hacc>100 for **32 %** of samples, hacc>500 for **18 %**). Blackouts are ragged, not rectangular, and are interleaved with bad fixes not silence. | Sim models a tunnel as either silence (correct-ish) OR a frozen hacc=100 fix (which the app's 100 m gate drops → effectively silence). Reality is silence *plus* a stream of accepted-but-drifting fixes at the tunnel mouth. The "clean edge" of a sim blackout is the least dangerous version. | **NL↑** |
| **GPS along-track error / multipath / urban-canyon** | Scale gen scatter is **purely cross-track**: `off=N(0,5); lat+=off·cos(h+π/2)` (`build_scale_rides.py:256-258`) — zero along-track component *by construction*. Dashboard `urbanCanyon` mode adds isotropic jitter (`:2202-2209`) but is **not used by any gate**. Harness snaps every fix to the route (`replay_harness_test.dart:831`), deleting cross-track error. | Real multipath near tunnel mouths / high-rises produces **along-track** position error (fix dragged forward or, dangerously, backward along heading) with a *plausible* reported hacc. This is the classic "confident phantom." | The oracle's error is 100 % orthogonal to the axis that matters and is then projected away. A backward along-track bias > (true error − hacc) sets `anchor.sHi < true progress` → violates `reachability.dart:535` → **LATE**. This mode cannot be generated at all today. | **NL↑ (top gap)** |
| **GPS sample rate** | Dashboard normal mode emits a fix *every 100 Hz tick* (`_computeGpsState` returns `shouldEmit:true`, `:2148`); scale gen at 1 Hz (`GPS_DT=1.0`). | Recorded GPS is **1 Hz** (median inter-sample gap 1.00 s across all rides). | Scale gen matches reality (1 Hz). Dashboard over-emits 100×, but the dashboard is not a gate. | DR |
| **IMU accel noise/bias** | `z=9.81` gravity baseline + motion terms (+0.5/−0.8 m/s²) + **uniform** noise ±0.05–0.1 (`imu_replay_engine_v2.dart:2238-2276`). Deterministic `Random(42)` (`:621`). No bias, no temperature drift, no scale-factor error. | Quiet-window accel σ (recorded): **0.019–0.147 m/s²** (device-dependent), stationary bench 0.005. Motion σ up to **4.3 m/s²** (vibration). Noise is Gaussian-ish, not uniform. | Noise magnitude is roughly plausible at rest but (a) uniform not Gaussian, (b) no per-run bias, (c) misses the heavy motion-vibration tail. Only affects DR, and **only on the dashboard path** — the scale gen emits *no IMU at all* (`build_scale_rides.py:24,373`). | DR |
| **IMU gravity frame / units** | Sim bakes gravity into `z=9.81` (gravity-*included*). | iOS `Accelerometer.csv` is **gravity-removed** (recorded mean\|a\| = **0.57**, values ±0.1–0.7); Android `TotalAcceleration` includes gravity (~9.7 tilted). Frame + gravity handling differ *per device*. | Sim's single fixed convention matches neither recorded stream. Any EKF ingestion path tuned on synthetic gravity-inclusive data will see a different DC level on real iOS data. | DR |
| **IMU gyroscope / turn-rate** | `_generateGyroscope` emits **only** uniform noise ±0.01–0.02; the actual angular velocity is a **permanent `TODO: Calculate actual angular velocity from bearing changes`** (`:2287`). Scale gen: no gyro. | Recorded gyro: quiet bias ~0.001 rad/s, quiet σ 0.002–0.007, **motion σ\|ω\| = 0.26 rad/s** carrying real curve/turn signal. Curves are the primary heading observable underground. | The sim's synthetic gyro contains **zero turn information**. Any heading/curvature/curve-anchor logic "validated" on synthetic routes is validated against noise. | DR (and invalidates any curvature-tightening claim on synth routes) |
| **Tilt / device orientation** | Level device: gravity fixed to `(0,0,9.81)`, no tilt, no orientation change over time (`:2242-2244`); fix `headingAccuracy:10, speedAccuracy:0.5, altitude:900` all constant (`:2213-2232`). | iPhone at Nallur: **roll 0.13 rad, pitch −0.43 rad (~−24°)**, yaw varying — device is tilted and reorients (pocket/hand). Full quaternion logs exist and are non-trivial. | Sim has no tilt and no gravity-projection error; a real EKF must estimate and subtract a tilted, time-varying gravity vector — untested by the synth path. | DR |
| **Station dwell time** | Dashboard: per-station `dwellTimeSeconds` default **25 s** (`:154`), 20 s in unified path (`:1118`). Scale gen: uniform **20–40 s** at every served stop (`build_scale_rides.py:58,209`). Never-late gate's ARMED cap uses `dwellMin=10 s` "safe because ground truth ≥ 20 s" (`reachability_scale_test.dart:99,322`). | Real Bengaluru metro dwell is commonly **~15–30 s** and can be shorter at minor stops; express services dwell less. The corpus can't isolate dwell cleanly (annotation is a single press) but inter-station intervals were 87–183 s. | The ≥ 20 s floor is an *assumption baked into the ground truth*, not a measured fact. If a real dwell < the armed `dwellMinSeconds`, the topology cap over-charges dwell and under-bounds progress → **LATE**. The test *itself* flags this (GW-0148, `reachability_scale_test.dart:304-313`): production even-spaces `stopMeters`, so arming the cap today is a never-late trap. | **NL↑ (if dwell cap armed)** |
| **Station spacing / arc length** | Polyline is **straight-line densified through shipped station coords** (`build_scale_rides.py:105-125,351`) — an explicit *lower bound* on true curved-track length. | Real track curves; true inter-station arc is longer than the straight-line chord. | For never-late this is *conservative on distance* (shorter modeled route ⇒ target reached sooner in the model ⇒ earlier fire) — the doc calls it out honestly. But it distorts the speed profile and any curvature signal. | E↑ (safe direction) |
| **Speed profile** | Trapezoidal, accel **1.0**, brake **1.1 m/s²**, cruise capped at `op_frac ∈ [0.70, 0.80] × V_LINE` (`build_scale_rides.py:56-57,282-283`); dashboard eases at ±1.2/2.0 m/s² with a 200 m linear braking ramp (`:2098-2104`). | Recorded Nallur metro: **max 24.6 m/s (89 km/h)**, p95 20.5, median 12.5 — i.e. **0.88 × V_LINE_DEFAULT (28)**, above the sim's 0.70–0.80 band. | Ground-truth cruise in the sim sits further below the ceiling (12–30 % headroom) than the one real ride measured (12 % headroom). The never-late "margin" is partly manufactured by the optimistic op_frac. | **NL↑ (margin inflation)** |
| **V_LINE ceiling** | `28 / 39 / 53 m/s` by line-name heuristic (`build_scale_rides.py:67-89`), a faithful port of `VLineTable`; generator caps truth strictly below it, so precondition (ii) is true by construction. | Bengaluru Purple observed peak 24.6 m/s < 28 ✓. But the ceiling is a *classification* (`looks_express`/`looks_rrts` string match). A misclassified fast line, a downhill over-speed, or GPS-Doppler noise pushing measured speed above the ceiling would violate (ii). | Sim can *never* exceed its own ceiling (truth is derived from it). Real trains are not guaranteed to respect a string-matched ceiling. Precondition (ii) is assumed, never tested against an adversarial real speed. | **NL↑ (if ceiling misclassified)** |
| **Clock behaviour** | Deterministic fixed 0.01 s step (`_fixedTickSeconds`, `:622`); monotonic; sample timestamps derived from elapsed seconds; no jitter, no jumps. | Android doze/process-death produces timestamp gaps and wall-clock jumps; the bound depends on `nowSeconds` on the *same clock* as the anchor (`reachability.dart:537`). | The L0 oracle assumes a perfect monotonic clock. (Separate Monte-Carlo sims — `sim_longhaul_neverlate_clock.py`, `sim_process_death.py` — cover this, but the *replay oracle itself* does not.) | NL↑ (covered elsewhere, not by this oracle) |
| **Detector (brake/stop) error** | Scale gen emits **no IMU and no detector** and refuses to fake one; the measured recall/precision/timing-jitter model is meant to be injected as a stochastic layer by the sim, not baked into the oracle (`build_scale_rides.py:20-26`). | Real stop-detection has device-dependent false positives/negatives; a *false stop* is the ONLY late-fire path the generator claims to model. | Honest omission, clearly stamped. But it means the ride oracle proves integration safety *only*, contingent on a separate, un-baked detector model — real detector precision is out of scope of every PASS here. | NL↑ (explicitly out of scope) |

---

## (c) Top fidelity gaps that could turn a sim-PASS into a real LATE fire (ranked)

1. **Along-track backward GPS bias that passes the 100 m accuracy gate is un-generatable.**
   The bound's never-late precondition is `anchor.sHi = fixArc + hacc ≥ true progress`
   (`reachability.dart:208-211,535`). A real fix reading, say, 60 m *behind* true with a
   reported hacc of 20 m yields `sHi = true − 40 < true` and is accepted by the 100 m gate
   (`fire_decision_config.dart:30`). This is a textbook LATE fire. The oracle cannot produce
   it: the scale gate feeds *true* arc + 10 m (`reachability_scale_test.dart:129-131`), the
   generator's scatter is 100 % cross-track (`build_scale_rides.py:256-258`), and the harness
   projects fixes onto the known route (`replay_harness_test.dart:831`), erasing what little
   perpendicular error exists. Every never-late PASS is silent on the dominant real hazard.

2. **"Confident phantom" (frozen/stale fix at the tunnel mouth) is measured but not gated —
   and the sim's version is defanged.** The harness phantom probe re-injects a frozen fix but
   routes it so it *cannot* anchor reachability, and openly annotates
   *"expectation: FAIL — no phantom defense in current lib/"* with a report-only
   `expect(r.window, isNotNull)` (`replay_harness_test.dart:813-818,1111`;
   `docs/system_map/04_ekf_replay.md` gap 3). The recorded metro rides show exactly the
   substrate for this: hacc>100 for 32 % and hacc>500 for 18 % of a real underground ride,
   i.e. a continuous stream of low-confidence-but-sometimes-accepted fixes at tunnel
   transitions. A phantom that drifts *backward* is gap #1; a phantom that *freezes* stalls
   EKF progress so the rider overshoots. Neither is blocked.

3. **The never-late "margin" is inflated by an optimistic speed band and a straight-line
   track.** Ground-truth cruise is 0.70–0.80 × V_LINE (`build_scale_rides.py:282`) while the
   one real metro ride peaked at 0.88 × ceiling; and the modeled route is a straight-line
   *lower bound* on track length. Both make the cone's headroom over truth larger in the sim
   than on the rail. A PASS with (say) 30 s of margin may be <10 s on a real, curvier,
   faster segment.

4. **The dwell ≥ 20 s assumption is a generator input, not a fact — and arming the tightening
   on it is a known trap.** The ARMED-cap test proves never-late survives `dwellMin=10 s`
   *only because the synthetic ground truth dwells 20–40 s* (`reachability_scale_test.dart:99,
   322`). Production fabricates station positions by even spacing (GW-0148,
   `reachability_scale_test.dart:304-313` → `transfer_utils.dart:1023`); a real short dwell or
   bunched geometry under an armed cap under-bounds progress → LATE. The oracle's dwell
   distribution never dips below the floor it's later asked to certify.

5. **V_LINE is assumed ≥ true speed rather than tested against an adversarial real speed.**
   Truth is *derived from* the ceiling (`v_cruise = op_frac × vceil`), so the sim can never
   exceed it. Precondition (ii) is therefore untested. A misclassified line
   (`looks_express`/`looks_rrts` string match, `build_scale_rides.py:71-89`), a GPS-Doppler
   speed spike, or a genuine over-speed would break it silently.

6. **Synthetic IMU cannot validate dead-reckoning or any curvature/heading tightening.** The
   synth gyro is pure noise with a standing `TODO` (`imu_replay_engine_v2.dart:2287`), synth
   accel is decoupled from the trajectory and gravity-inclusive/level while real iOS is
   gravity-removed/tilted-24°. Any confidence that "the EKF tracked the synthetic metro route"
   is false confidence for the underground scenario (`docs/system_map/04_ekf_replay.md`
   gaps 4/decision 9). Only the finite, Bengaluru-only recorded fixtures test DR honestly.

---

## (d) Concrete recommendations to close each gap

1. **Inject recorded-noise-matched, along-track GPS error into the gate (kills gap #1).**
   Replace the scale gate's `onAcceptedFix(sMeters: _trueS(...), accuracyMeters: 10.0)`
   (`reachability_scale_test.dart:129-131`) with fixes drawn from an **error model fit to the
   corpus**: sample hacc from the empirical distribution (median 6.8, p90 15.9, heavy tail)
   and add a *2-D* position error with a real **along-track component** whose magnitude can
   exceed the reported hacc (multipath). Crucially, include a backward-biased regime near
   blackout edges. Then assert never-late still holds — or, more honestly, *measure the LATE
   rate* it produces. In the generator, change `emit_gps` so `off` has both cross- and
   along-track components (`build_scale_rides.py:256-258`), and stop the harness from silently
   projecting error away (or project, but add a residual along-track term post-projection).

2. **Promote the phantom probe to a hard gate with a real drift model.** Generate a "tunnel-
   mouth" scenario: on blackout exit, emit 5–15 s of fixes with hacc 20–90 m that lag/drift
   backward along heading (not a pure freeze). Wire a phantom-rejection defense in `lib/`
   (freeze-detector + max-jump/consistency check against EKF DR) and flip
   `replay_harness_test.dart:1111` from report-only to `expect(defended)`. Until a defense
   exists, the phantom test's own "expectation: FAIL" should be treated as an open never-late
   defect, not a passing test.

3. **Fuzz the speed band above the certified ceiling and use real track geometry.** Raise
   `op_frac` sampling to include 0.85–0.98 × V_LINE and add a small fraction of rides that
   *transiently* exceed the ceiling (Doppler-spike model), to test precondition (ii) failure
   directly. Replace straight-line densification with OSM rail geometry where available
   (already contemplated in `TIGHTENING_IMPL.md`) so arc length and curvature are truthful.

4. **Fuzz dwell below the assumed floor.** Sample dwell from a distribution with real mass
   below 20 s (e.g. 8–30 s) in a dedicated ride set, and prove the ARMED cap either stays
   never-late or fails — making the trap explicit rather than assumed-away. Keep the armed cap
   OFF in production until real per-line station arc positions replace the even-spacing in
   `transfer_utils.dart:1023` (GW-0148).

5. **Model the clock inside the replay oracle, not only in side sims.** Add timestamp
   jitter/jumps and doze gaps to the deterministic tick so the same never-late gate that
   proves geometry also proves clock robustness, rather than delegating it to
   `sim_process_death.py` / `sim_longhaul_neverlate_clock.py` that don't run the real Dart
   bound.

6. **Fix or retire the synthetic IMU for validation claims.** Either (a) implement the
   `_generateGyroscope` turn-rate TODO (`imu_replay_engine_v2.dart:2287`) from bearing
   derivatives, make accel integrate to the trajectory, add per-run bias + Gaussian noise fit
   to the corpus (σ ≈ 0.02–0.15 accel, gyro bias ~0.001 rad/s), and emit device-specific
   gravity/tilt frames; or (b) formally mark the synthetic-route EKF/DR results as
   **non-validating** and restrict every dead-reckoning claim to the recorded-fixture path.
   Expand the recorded corpus beyond Bengaluru before generalizing the never-late claim to
   "all 46 lines."

---

## Corroboration & honesty credit

Several of these gaps are already documented candidly in
`docs/system_map/04_ekf_replay.md` (decisions 3, 5, 9; gaps 3, 4, 11) and stamped in the
generators' own `honesty` blocks (`build_scale_rides.py:20-26,364-374`;
`reachability_scale_test.dart:96-99,304-313`). This audit's contribution is to (1) quantify
the gaps against the recorded corpus and (2) rank the **along-track-backward accepted fix** as
the single un-generatable, never-late-breaking hazard that every current PASS is blind to —
the foundation's blind spot, not merely its documented caveats.
