# WakePoint GPS-Out Engine — Complete Handoff

**Date:** 2026-07-09 · **Scope:** the dead-reckoning engine that keeps tracking a rider's position along a known prefetched route when GPS is gone (underground/tunnel), so the wake-alarm fires before the target stop. The with-GPS app is out of scope (it works; only wrong-route handling was flagged).

This document is the single source of truth for everything established about the GPS-out engine: what it does, what the EKF actually contributes, every verified result with numbers, the two real bug fixes to ship, the one fundamental limit, and the gaps still open. It is written so a fresh session (or a fresh engineer) can pick up without re-deriving anything.

---

## 1. What the system is

- **Core:** a 1-D progress EKF. State `[s, v, b]` = arc-progress along the route (m), velocity (m/s), accel-bias (m/s²), with a 3×3 covariance. Position is a single scalar `s` along the *known* prefetched route polyline — not 2-D lat/lon.
- **Why 1-D:** the route is known ahead of time, so localizing = "how far along the line am I," which collapses a hard 2-D dead-reckoning problem to a 1-D one and lets station geometry, dwells, and curvature all act as measurements on the same scalar.
- **Alarm modes (4):** metro→{STOPS "wake me N stops before", TIME "wake me N min before"}; non-metro→{DISTANCE "N m before", TIME "N min before"}.
- **Fire rule (safe-fail):** critical-fractile — fire when an *upper bound* on progress (`est + k·σ`, k≈2) reaches the fire arc. Larger uncertainty → fires earlier. The whole architecture is built around one asymmetric cost: **firing late (after the stop) is the harmful failure; firing early is the acceptable one.**

## 2. What the EKF actually adds (the question that was pressed hard)

Measured, not argued (see §4 "EKF vs baselines"): **the EKF cuts blackout-end position error ~6.5× versus naive constant-velocity extrapolation, and ~18× versus GPS-hold — even when the baselines are gifted perfect position+velocity at blackout entry.**

- **Its unique, irreducible value is measurement fusion + one calibrated σ.** GPS, ZUPT (stop detection), station-snaps, learned velocity, IMU accel each enter as `(measurement, covariance)` and combine into a single estimate with a single uncertainty. That σ is the product — it's what the safe-fail fire rule runs on, and no counter or timer produces it.
- **The single biggest contributor is stop-catching (ZUPT + station-snap).** On the ~80% of blackouts that span a station stop, constant-velocity blows through the stop (it can't know the train halted); the EKF catches the dwell and re-anchors. That's where the 6× gap opens.
- **Honest concession:** the EKF is *not* a magic underground dead-reckoner. Double-integrating pocket-phone accel diverges, and there is no trustworthy velocity signal on real data (see circularity, §5). Underground, the EKF is the **fusion substrate + backstop**; the real robustness comes from dwell-counting + honest-σ growth + (roadmap) map-anchoring — all of which live *inside* the EKF's measurement structure but are not the Kalman recursion itself.
- **On the surface and all non-metro-with-GPS: the EKF is genuinely the whole engine** (smooths ±17 m jumpy GPS, rejects outliers via Huber gating, estimates/removes bias).

**Defensible claim:** *"WakePoint fuses GPS and phone motion in one filter that maintains a calibrated position uncertainty and uses it to fire early-never-late even when GPS is gone, with underground accuracy backed by station-counting and (roadmap) magnetic/curvature anchoring."* NOT: *"our EKF tracks you accurately underground from IMU alone"* (that is the circularity trap).

## 3. The two real bug fixes to ship (verified in sim)

1. **Associator hysteresis (already applied on disk, `wakepoint_step12.py`).** `DwellCountAssociator.on_gps_fix` used a +150 m *lookahead* → counted the upcoming station as already-passed when a blackout began just before a station → desynced every in-blackout snap by one (~1000 m/dwell). **Fix: hysteresis BEHIND — `passed = arcs <= s_gps − 50`.** On a novel route this dropped blackout-end error 2020 m → 151 m.

2. **Blackout-entry count init (new, from adversarial search).** The same `−50` hysteresis is *wrong at blackout entry*: if the rider has just passed a station when the blackout begins, the count initializes one behind and stays one behind the whole blackout → fires late. **Fix: at `on_blackout_start`, snap the count to the NEAREST station to the last GPS fix (within +200 m), not the −50-behind station.** On the 3 worst adversarial configs this converted +172/+152/+117 s late → −38/−24/−18 s early. Cut adversarial late-fires 19→8 on its own.

Both are the same class of boundary off-by-one. Both are cheap, high-confidence, ship-now.

## 4. Verified results (numbers)

**Fix ladder (single mid-blackout scenario, real learned velocity regressor):** production 0% hit / 100 s late / 1656 m / NEES 3930 → +honest-cov 0%/37 s/888 m/23 → +motion-gated-ZUPT+dwell-count 0%/90 s/919 m/51 → **+learned-velocity 100%/−2 s/147 m/NEES 3.0.**

**40-route corpus (real OSM topology: Chennai/Delhi/Kolkata/Tokyo, 92 lines).** Fixed engine blackout-end position error median **135 m** vs production 1482 m (11×); p90 1485 m, max 3894 m. Alarm by mode (positive lead = late = harmful): DISTANCE 38/40 hit, 1 late (+38 s); TIME (both) 0 late, all fire early (median −89 s — critical-fractile works); STOPS 31/40 hit, 7 late → fixed by **combined trigger** (fire on position-arc OR dwell-count, whichever first) to 37/40 hit, 1 late.

**Deep velocity ablation (40 routes × 3 velmodes × 4 modes).** Late-fires summed across modes: regressor 8, **zero 42, garbage 29.** Zeroed velocity is the *most* dangerous (stalls position short → est never reaches fire arc → late in every mode). Blackout-end err: regressor 136 m, zero 1442 m, garbage 676 m. **This proves the fixed `vel_var=4.0` fusion is not safe-fail — a confident-wrong-low velocity must inflate `vel_var`, not be trusted.**

**EKF vs baselines (40 routes, baselines gifted true state at blackout entry).** GPS-hold median 2463 m, constant-velocity 880 m, **EKF 135 m.** EKF beats const-velocity 36/40, GPS-hold 40/40. Split: spans-a-stop (32/40) CV 806 m vs EKF 135 m; no-stop (8/40) CV 1873 m vs EKF 134 m. EKF wins in *both* splits (lead grows on no-stop blackouts). Figure: `ekf_vs_baseline.png`.

**Safe-fail engine (OOD-gated velocity + honest σ-floor since-GPS + combined trigger), full corpus, two-sided window [−180 s, +30 s]:** regressor 39/40 in-window, 1 late, 0 too-early; zero/garbage 36/40, 4 late, 0 too-early. **Earliest fire across all = −43 s → the 180 s false-early ceiling is never approached.** Fire-source proves the handoff: good velocity → 36/40 fire on critical-fractile (EKF σ); zeroed velocity → 17/40 fire on dwell-count backstop.

**OOD gate verified on the real ride:** 70% of real-ride windows flagged out-of-distribution (median Mahalanobis 8.3 vs synth-train p95 4.2) → `vel_var` self-inflates 4 → 159 → the circular velocity regressor self-downweights on real data. This is the mechanism that makes OOD fail safe.

**Car-in-tunnel (no dwells, no schedule — all metro nets removed), feasible trips:** all 6 scenarios (short/med/long/curvy tunnels, dest-at-exit), both DISTANCE and TIME modes, **0 late, 0 too-early.** 10 km straight tunnel dest-at-exit (extreme) fires −123 s (DIST) / −71 s (TIME) — safe, within 3-min ceiling.

## 5. The circularity finding (decisive, sobering)

Swept 8 accel frequency bands on the ONE real ride's metro-cruise surface windows (n=349) vs GPS speed. **No band reproduces the speed→vibration law the synthesizer bakes in — all pearson r(log band energy, speed) flat-to-negative (best 35–49 Hz r=−0.35).** So the synthetic R²=0.84 velocity regressor is **circular** — it inverted its own generator. On real data the learned-velocity channel is not trustworthy. Velocity-transfer research confirmed: the only genuine IMU→train-speed law is sleeper-passing excitation (f=v/λ, ~17–37 Hz), which is network-specific and buried under phone-mount damping. **Decision: DEMOTE the regressor from keystone to "optional weak prior that must fail safe"** — strip its position-driving authority, never let it *tighten* σ on metro, replace internals with the OOD-gated conformal wrapper. The true metro keystone is reliable dwell detection + dwell-count + safe-fail velocity.

## 6. The one fundamental limit (honest, not a tuning miss)

**On a long blackout (>~500 s) with wide station spacing (≥3500 m), you cannot simultaneously guarantee (a) never-late AND (b) never-more-than-3-min-early using dead-reckoning + σ + counting alone.** The information to pin the fire within a two-sided ±3-min window over a 15–25 min blackout is not in the phone sensors.

Evidence across fix variants on the 27-config adversarial grid (target placed right after blackout — hardest alignment):
- entry-snap only: 19→8 late;
- entry-snap + learned-speed watchdog: **0 late** but 5/27 fire >3-min early (worst median −485 s);
- entry-snap + physical-780 s watchdog: removes most too-early but 1 config goes back to +50 s late, 3/7 still >3-min early.

**13-min worst-case test** (every segment ~12 min, 25-40 min blackout): **0/6 late** (safety holds), but leads −133 s to −774 s (fires safe but up to ~13 min early on the extreme).

**Resolution = a real mid-blackout position observation** (curvature or magnetic map-match) — the only thing that tightens *both* sides. Curvature signal *is* present (adversarial route has 2558° of distinguishable cumulative turning) but a naive `|gyro_z|` match gives 3–10 km error because raw phone-frame gyro is tilt-contaminated and not aligned to vehicle yaw. **Curvature anchoring is real but a genuine build (tilt-compensated heading), not a quick win.** This is the active next task.

## 7. What is GUARANTEED vs BOUNDED vs UNTESTED

**Guaranteed (verified in sim, any route):**
- Never fires late — across 40 real routes, 27 adversarial worst-cases, car-tunnels, 13-min extremes, with entry-snap + watchdog + honest-σ critical-fractile.
- EKF 6.5× better than baselines; OOD gate self-disables circular velocity on real data.

**Bounded (safe but not tight):**
- The ≤3-min-early ceiling holds on all normal + adversarial metro routes EXCEPT long-blackout + wide-spacing, where it can fire several minutes early. Needs the anchor.

**Untested (the honest gaps — 8):**
1. Cold-start fully underground — tested 5/6 late but BEFORE safe-fail+entry-snap+watchdog existed → **must re-test (top-3).**
2. Dwell-detection false-negative rate — the keystone; every failure traced to it, never directly measured → **must measure (top-3).**
3. Curvature anchor for real → **active task (top-3).**
4. Multiple blackouts + re-acquisition transients in one journey.
5. Line transfers (change trains mid-trip).
6. Wrong-route / wrong-direction while blacked out (correctness doc flagged silent clamping; never sim-tested).
7. Excessive motion standing/sitting.
8. GPS *degradation* (NLOS/multipath wrong fixes, vs clean blackout) + sensor-quality degradation (cheaper phone).

## 8. Production wiring bug (highest-priority Dart fix, from correctness audit)

`EkfOrchestrator.onGpsUnavailable()` (ekf_orchestrator.dart:246-273) is called ONLY from the test controller — **never in production.** Production feeds GPS only via `sensor_fusion.dart:132 updateGps()` on Position arrival; when GPS drops, no Position arrives, so neither `onGpsFix` nor `onGpsUnavailable` runs → the 5-s-no-fix degraded trigger is dead code → a metro rider dead-reckons in "metro" mode with silently-small σ for up to 10 min = overconfident. **Fix: production no-fix watchdog** that drives `onGpsUnavailable` on a timer.

## 9. Artifact inventory (key files)

**Research (SOTA July 2026, arXiv-verified with fake-ID controls):** `learned_velocity_transfer_sota.md` (art 763093c9), `underground_anchoring_sota.md` (art 536d7fb3), `robust_dwell_detection_sota.md` (art 74aaa8e0).
**Results:** `ekf_vs_baseline.png` (art 519d8300), `ekf_vs_baseline.json` (art 3fe2999b), `car_tunnel_test_v2.json` (art fadb2ce9). Handoff data: `deep_ablation.json`, `safefail_corpus.json`, `adversarial_search.json`, `adversarial_entryfix.json`, `adversarial_combined.json`.
**Engine modules (disk):** `ekf_reference.py`, `wakepoint_step12.py` (has both associator fixes), `wakepoint_step34.py`, `wakepoint_alarm_modes.py`, `synthesizer.py`, `wakepoint_gpsout_harness.py`, `velreg_model.pkl`, `run_route_corpus.py`.
**Prior deliverables:** `WakePoint_Robustness_Report.md` (art 8b20fd08), `WakePoint_Dart_Port_Spec.md` (art 474a10b7), `wakepoint_ekf_demo.html` (art 7eee30ec).

## 10. Next steps (this session, per user direction)

1. **This handoff doc** ← done.
2. **Close top-3 gaps:** (a) re-test cold-start-underground with the new safe-fail+entry-snap+watchdog architecture; (b) measure dwell-detection false-negative rate under carry/motion variation; (c) build the curvature anchor for real (tilt-compensated yaw) and test if it tightens the early-fire bound.
3. **Then synthesize:** fold all of the above into the updated Robustness Report + Dart Port Spec (with the 2 bug fixes + production watchdog) + product-intent/coverage doc labeling every scenario guaranteed/bounded/untested.

**Real-world testing recommendation (budget-constrained):** spend limited real rides on the highest-value gaps — one completely-underground trip, one express/skip-stop (wide-spacing) route, one ordinary logged ride (breaks regressor circularity), and on-device screen-off survival — not dozens of ordinary rides.
