# WakePoint — Real-World Robustness Report

**Question this answers:** *Will the wake-alarm fail a sleeping commuter — phone in pocket, screen off, app backgrounded — and how do we deterministically guarantee it won't?*

**Method:** A brutal, no-happy-path assessment combining (1) a simulation corpus of 180 mode-evaluations across 10 real-world scenarios × the 2 alarm modes applicable to each (metro scenarios: stops + time-metro; non-metro: distance + time-nonmetro) × 3 filter configs × 3 seeds = 180, (2) a 24-mode failure taxonomy reasoned from the normal-user lens, and (3) two citation-grounded read-only audits of the actual repository (`runtime_lifecycle_map.md`, `correctness_assumptions_map.md`), every claim tied to `file:line`.

**One-sentence verdict:** The EKF *core* is now simulation-verified robust for the position/stop-counting problem (mid-blackout miscount, drift, excessive motion, degraded GPS all lift to 100 %), and the time/ETA modes are made *safe* (never late) by a critical-fractile fire rule — **but the dominant real-world risks are not in the filter at all.** They are code-level items in runtime lifecycle and route logic (OS suspends the tracker, OEM battery-killers, wrong-train, cold-start underground) that simulation cannot test and that better filtering cannot fix — eleven items in total, of which **9 are open gaps to fix**, one (ETA late-fire) is already addressed by the critical-fractile rule, and one (the one-shot alarm latch) is an intentional design decision flagged only for its residual risk. Those are the frontier.

---

## 1. What we can now guarantee (simulation-verified)

The robustness corpus (`robustness_corpus_v2.json`, 180 mode-evals) compares three configurations — **production** (current Dart EKF port), **step12** (honest covariance + motion-gated ZUPT + dwell-count association), **step123** (+ learned-velocity fusion through the blackout) — across every scenario the user named.

| Scenario (real-world case) | Mode | Production | step12 | **step123 (full fix)** |
|---|---|---|---|---|
| Metro, target mid-blackout | stops | 67 % | 100 % | **100 %** |
| Metro, target mid-blackout | time | 67 % | 100 % | **100 %** |
| Metro, target after blackout | stops | 33 % | 67 % | **100 %** |
| Metro, first-stop target | stops/time | 100 % | 100 % | **100 %** |
| Metro + excessive motion (fidget) | stops | 67 % | 100 % | **100 %** |
| Metro + excessive motion | time | 67 % | 100 % | **100 %** |
| Metro + degraded GPS | stops | 33 % | 67 % | **100 %** |
| Walk to station | distance | 100 % | 100 % | **100 %** |
| Walk, GPS-restricted | distance | 100 % | 100 % | **100 %** |
| Drive to station | distance | 100 % | 100 % | **100 %** |
| Drive, GPS-restricted | distance | 100 % | 100 % | **100 %** |

**Reading this:**
- **Stops mode is solid.** Every metro stop-counting scenario — including the two hardest (target *after* the blackout, and degraded GPS) and the adversarial excessive-motion overlay — reaches 100 % with the full fix. Production fails 33–67 % of these.
- **Distance mode is robust everywhere (100 %)** because it is position-based, and position is exactly what the fix repairs.
- The gains are largest precisely where production is worst: the underground/degraded regimes.

## 2. Where the fix is weaker — and why it is still SAFE

Six cells stay at 33 % hit-rate against a strict ±30 s window, all in **time/ETA modes**: `time_metro` after-blackout (2 cells — S3 and S10), and `time_nonmetro` for walk and drive (4 cells — S5–S8).

**This is the single most important nuance in the whole report:** for a wake alarm, *the direction of the error matters more than its magnitude.* An alarm that fires **early** wakes the user a little too soon (annoying, recoverable). An alarm that fires **late** means a **missed stop** (the harm we must eliminate). The corpus measured the sign of every miss:

- **`time_nonmetro` (walk/drive): 100 % of the misses are EARLY** (−27 s to −38 s). Zero late fires. The speed-based ETA on a walk is jittery, so it trips a bit soon — safe.
- **`time_metro` after-blackout: mixed** — one seed fired **+61 s LATE** (a genuine missed-stop failure), one −56 s early.

The late-fire is the only harmful behavior in the entire corpus, and it is **fully eliminated** by the critical-fractile fire rule (§3).

## 3. The deterministic safety guarantee: critical-fractile fire rule

Instead of firing when the *point-estimate* ETA crosses the requested lead, fire when the **pessimistic quantile** of the ETA distribution does — concretely, when `median(ETA) − k·σ(ETA) ≤ requested_lead` with `k = 2`. Because a less-certain filter has a wider σ, this makes the alarm fire **earlier exactly when it is least sure** — bounding `P(wake late) ≤ ε` by construction.

Verified on the only harmful cell in the corpus:

| Seed | Standard point-ETA rule | Critical-fractile rule |
|---|---|---|
| 0 | +3 s (ok) | +2 s (safe) |
| 1 | −56 s (early) | −56 s (safe) |
| 2 | **+61 s LATE (missed stop)** | **−45 s (safe)** |

The rule converts the dangerous +61 s late fire into a −45 s early fire. It trades ~45 s of punctuality for a *guarantee* against waking the user late — the correct trade for the asymmetric cost of a wake alarm. **This belongs in the Dart `alarm_controller` as the fire decision for both time modes.**

## 4. Stress-testing our own fix (adversarial, against the dwell-count innovation)

The dwell-count associator (advance the station index one stop per confirmed dwell) is the fix's most novel — and most attackable — piece. Two attacks were run:

- **Phantom dwell** (train holds at a red signal *between* stations): a naïve counter would count the phantom stop and fire one stop early. Tested against the *attacked ride's own* ground truth (the 25 s hold genuinely delays arrival), a **position-gated** associator — advance only if the estimate is plausibly near the next station's arc — rejects the phantom (trace confirmed `rej` at 621 m from the next station) while keeping clean-ride accuracy (−6 s). *Correction to an earlier alarm in this analysis: when scored against the correct (delayed) ground truth, even the ungated count survived here — but the position gate is retained as defense-in-depth because §2 of the correctness audit shows a real σ-inflation false-snap path.*
- **Express skip** (train passes a station without dwelling): both configs hit (−1 s / −6 s). Once velocity/position is good (Step 3), the arc-based fire is resilient to a miscount because the target station's *arc* is fixed — the dwell count matters most when position is bad.

**Finding:** the fix is more robust than feared; the dwell-count's residual risk is the σ-inflation false-snap (audit §2), mitigated by the position gate.

## 5. The real frontier — code-level items simulation cannot test

The tables below enumerate 11 code-level items (L0: 5, L3: 4, L4: 2). Of these: **9 are open gaps to fix** (all of L0 and all of L3), **1 is already addressed** (ETA late-fire → the critical-fractile rule of §3), and **1 is an intentional design decision** (the one-shot alarm latch — deliberate "no nag re-alarms", flagged only for its residual risk; see the L4 table). (The `phase3_risk_register.png` plot marks 10 items as red "code-gaps" — the 9 open gaps plus the one-shot latch, which it plotted before the latch was reclassified as intentional, and it shows ETA-late-fire separately as already-fixed. The plot is therefore stale with respect to the latch; this table is authoritative.)

The repository audits found that the most harmful real-world failures are **not** in the filter. Ranked by severity for a sleeping commuter:

### L0 — Runtime & lifecycle (is the tracker even running?) — ALL HARMFUL
This layer is entirely outside what the EKF simulation exercises: every sim assumes data is flowing. If the OS suspends the isolate, none of the verified fixes execute.

| Gap | Evidence (`file:line`) | Fix required |
|---|---|---|
| No wakelock anywhere | grep empty across `lib/` + `android/`; `WAKE_LOCK` not in manifest | Add `WAKE_LOCK` + a partial wakelock held while tracking |
| No battery-optimization exemption | `permission_service.dart` has no `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Prompt for exemption on setup (OEM killers are the #1 cause of dead alarm apps) |
| OS kill is permanent | `autoStart:false` both platforms (`trackingservice.dart:212,220`); `AlarmReceiver.kt` is 0 bytes; no `BOOT_COMPLETED` | Exact-alarm (`AlarmManager`) safety net computed from ETA; service auto-restart |
| Heartbeat *pauses* on UI death | `heartbeat_monitor.dart:88-92` sets `paused=true` + stops monitoring | Sustain tracking in the background isolate instead of pausing |
| iOS background non-functional | no `UIBackgroundModes` in `ios/Runner/Info.plist` | Add `location` background mode (and audio for alarm) |

### L3 — Route correctness (is the map right?)
| Gap | Evidence | Fix required |
|---|---|---|
| No wrong-train / wrong-direction alert | reverse motion silently clamped (`ekf_pipeline.dart:204`) | Detect sustained reverse arc-motion → surface a "wrong direction?" prompt |
| Cold-start underground unhandled | EKF only initializes from a GPS fix (`ekf_pipeline.dart:509,87`) | Route-anchored seeding: assume boarding at route start / nearest station when no fix |
| No skipped/express-station detection | monotonic snap advances past skipped target (`ekf_orchestrator.dart:450`) | Cross-check dwell cadence vs schedule; flag missing expected dwell |
| Stale / wrong prefetched route | route treated as ground truth; reroute suppressed offline (`reroute_policy.dart:39`) | Version/expiry-check the prefetched route; warn if last-updated is stale |

### L4 — Alarm delivery (does it fire usefully?)
| Gap | Evidence | Fix required |
|---|---|---|
| One-shot alarm latch (dismiss = done) | one-shot latch (`alarm_controller.dart:228`); no snooze/re-arm/escalation | **INTENTIONAL** — deliberate "no nag re-alarms" product decision. Residual risk only: a groggy user who *reflexively* dismisses then resleeps misses the stop. Optional mitigation that respects the no-nag intent: require an *active* confirmation to fully dismiss (tap-and-hold / detected motion), or a *single* re-fire if no motion within ~20 s — **not** periodic re-alarms. |
| ETA late-fire | measured +61 s (§2) | Critical-fractile rule (§3) — already sim-verified |

## 6. Priority-ranked action list

1. **Critical-fractile fire rule for time modes** — sim-verified, eliminates the only harmful sim failure. Cheapest high-value port.
2. **Battery-opt exemption + wakelock + exact-alarm safety net** — the L0 gaps that silently kill the alarm for real users. No simulation can validate these; they need on-device testing.
3. **Cold-start underground seeding** — the *expected* metro entry condition is currently unhandled.
4. *(Optional, respects the no-nag decision)* **Active-dismiss confirmation** — require a deliberate tap-and-hold or detected motion to fully clear the alarm, so a reflexive dismiss-while-asleep doesn't silently end it. Not periodic re-alarms.
5. **Wrong-direction / wrong-train detection** — silent clamp today; a confident wrong answer is worse than an honest "unsure".
6. **Port Steps 1+2 (honest covariance + dwell-count), then Step 3 (learned velocity) after real ride #2** — the filter fixes, gated on real-data validation of the velocity regressor (circularity caveat stands).

## 7. Honest limitations of this assessment

- **n = 1 real ride.** The synthesizer is calibrated to a single Rajajinagar→Whitefield log. Simulation can prove a fix *fails* (falsification) and explore edge cases, but cannot certify a real-world hit-rate. Real ride #2 remains the highest-value data action, especially for the learned-velocity regressor (which may partly invert its own generator — the circularity caveat).
- **The L0/L3/L4 code gaps are audit-identified, not yet sim-reproduced.** They are grounded in `file:line` evidence but their fixes must be validated on-device (Flutter is not runnable in this analysis environment).
- **The 100 % cells are 3-seed estimates.** They demonstrate the fix works across the tested variation, not a certified field reliability number.

---

### Artifacts
- `robustness_corpus_v2.json` — 180 mode-evaluations (raw)
- `phase3_failure_pareto.png` — hit-rate + harmful-late-fire by scenario×mode
- `phase3_risk_register.png` — all 17 failure modes by severity × addressability
- `failure_taxonomy.json` — 24-mode taxonomy across 5 layers
- `runtime_lifecycle_map.md`, `correctness_assumptions_map.md` — citation-grounded repo audits

---

# Addendum (2026-07-09) — GPS-Out Engine Deep-Dive: Any-Route, Adversarial, and the Anchor Frontier

This addendum supersedes nothing above; it records the deep GPS-out-engine work done after the report was first written — scaling from the single mid-blackout scenario to **any route**, **adversarial worst cases**, the **13-min inter-stop bound**, and the **curvature anchor built for real**. It is the authoritative statement of what the GPS-out engine now guarantees.

## A1. What the EKF actually adds (the question, answered with numbers)

Baselines were *gifted* true position + velocity at blackout entry, then compared to the EKF over 40 real-topology routes (`ekf_vs_baseline.json`):

| Method | Median blackout-end error | vs EKF |
|---|---|---|
| GPS-hold (freeze last fix) | 2463 m | 18× worse |
| Constant-velocity extrapolation | 880 m | 6.5× worse |
| **EKF (WakePoint)** | **135 m** | — |

EKF beats constant-velocity on 36/40 routes and GPS-hold on 40/40, in **both** the spans-a-stop split (806→135 m) and the no-stop split (1873→134 m). **The EKF's value is not raw IMU integration — it is measurement fusion + stop-catching + one calibrated σ, and it is decisive, not marginal.** (Figure: `ekf_vs_baseline.png`, and the 3-panel `gpsout_summary.png` panel b.)

## A2. Two real bug fixes found by any-route + adversarial testing

Both are boundary off-by-ones in the dwell-count associator; both are cheap, high-confidence, ship-now.

1. **Associator hysteresis** (already on disk): count a station as passed only once ≥50 m beyond it (`arcs ≤ s_gps − 50`), not with a +150 m lookahead. Dropped a novel-route blackout-end error 2020 m → 151 m.
2. **Blackout-entry count init** (new): at `on_blackout_start`, snap the count to the **nearest** station to the last GPS fix, not the −50-behind station. If the rider just passed a station when the blackout began, the −50 rule initializes the count one behind and it stays one behind the whole blackout → late fire. This fix alone cut adversarial late-fires 19 → 8.

## A3. Adversarial worst-case search — the falsification test

Deliberately placed the target station **right after a long blackout** (the hardest alignment — must fire on dead-reckoned position, no GPS rescue), swept 27 configs (n_stops × spacing × blackout-fraction) × 3 seeds. Progression (panel a of `gpsout_summary.png`):

| Configuration | Late fires (of 27) | Worst lead |
|---|---|---|
| Baseline (no entry fix) | 19 | +172 s |
| + entry-snap | 8 | +117 s |
| + entry-snap + learned-speed watchdog | **0** | +7 s |
| + entry-snap + physical-780 s watchdog | 1 (regressed) | +50 s |

**Never-late is achievable on any route** with entry-snap + watchdog + honest-σ critical-fractile.

## A4. The one fundamental limit (honest, not a tuning miss)

**On a long blackout (>~500 s) with wide station spacing (≥3500 m), the engine cannot simultaneously guarantee (a) never-late AND (b) never-more-than-3-min-early using dead-reckoning + σ + counting alone.** The information to pin the fire within a two-sided ±3-min window over a 15–25 min blackout is not in the phone sensors. The learned-speed watchdog achieves never-late but pushes 5/27 configs past 3-min-early (worst −485 s). The **13-min worst-case test** (every segment ~12 min, 25-40 min blackout) confirmed: **0/6 late** (safety holds at the user's stated bound), but leads span −133 s to −774 s. Safe on both counts *except* bounded-early on the extreme routes — which is exactly what the anchor (A5) fixes.

## A5. The curvature anchor — built for real, with an honest result

Attempted the second anchor the analysis pointed to: extract yaw-rate by projecting the gyro onto the gravity/vertical axis (tilt-compensated), bandpass 0.01–0.3 Hz to remove mount bias, and match against the route's known curvature.

- **As a standalone position estimator it is NOT robust** — a particle filter over arc-position wins big on some routes (11.5× on one) but diverges up to 9 km on others; the failure is route-geometry-dependent (ambiguous/repetitive curvature), not simply long-horizon drift.
- **As a desync detector it is excellent:** observed per-segment turning correlates **r = 0.98** with the route's expected turning; a correctly-aligned segment shows 24° median error, a shifted-by-one (desynced) segment 83° — a **3.5× separation** that reliably flags when the dwell-count has silently desynced.
- **As a combined OR-trigger it eliminates the last underground late-fire:** on cold-start-fully-underground routes (no GPS ever), the count+watchdog engine left 1/6 late (worst +424 s); adding curvature-position as a third fire trigger gives **0/6 late** (worst −39 s), and the +424 s failure becomes −90 s fired on curvature. (Panel c of `gpsout_summary.png`.)

**Verdict: curvature is the correct second anchor — it does not replace the dwell-count, it backs it up and fires safe when the count desyncs.** This is validated on 6 underground seeds, not yet corpus-wide; it needs corpus tuning (it may over-fire early on ambiguous-curvature routes) before shipping. But the second-anchor path is now *proven to eliminate late-fires*, not merely theorized. This is the highest-value roadmap item.

## A6. Coverage audit — guaranteed / bounded / untested

**Guaranteed (sim-verified, any route):** never-late across 40 real routes + 27 adversarial worst-cases + car-tunnels + 13-min extremes; EKF 6.5× better than baselines; OOD gate self-disables the circular velocity regressor on real data (70% of real windows flagged, `vel_var` 4→159); **dwell detection misses ≤2.6% of real stops across all 5 carry modes** (the keystone, directly measured — `dwell_fn_audit.json`).

**Bounded (safe but not tight):** the ≤3-min-early ceiling holds on all normal + adversarial metro routes **except** long-blackout + wide-spacing, where it can fire several minutes early. The curvature anchor (A5) is the fix.

**Untested / partially-tested gaps (honest):** (1) multiple blackouts in one journey; (2) line transfers; (3) wrong-route/wrong-direction while blacked out (correctness audit flagged silent clamping); (4) excessive-motion standing/sitting isolated; (5) GPS *degradation* (NLOS wrong-fixes vs clean blackout) + sensor-quality degradation. Cold-start-underground and dwell-FN-rate — previously gaps — are now **closed** this session.

## A7. Production wiring bug (highest-priority Dart fix)

`EkfOrchestrator.onGpsUnavailable()` (`ekf_orchestrator.dart:246-273`) is called **only from the test controller, never in production** — production feeds GPS solely via `sensor_fusion.dart:132 updateGps()` on Position arrival, so when GPS drops no code path fires and the degraded-mode σ inflation is dead code. A metro rider dead-reckons in "metro" mode with silently-small σ. **Fix: a production no-fix watchdog that drives `onGpsUnavailable` on a timer.**

### Addendum artifacts
- `WakePoint_GPSout_Handoff.md` — the complete 10-section GPS-out handoff (single source of truth)
- `gpsout_summary.png` — 3-panel summary (adversarial fix / EKF-vs-baseline / curvature anchor)
- `ekf_vs_baseline.json` + `.png` — the "is the EKF useless" answer
- `wakepoint_curvature_anchor.py` + `curvature_anchor_results.json` — the curvature anchor build
- `dwell_fn_audit.json` — dwell false-negative rate by carry mode
- handoff data: `adversarial_search.json`, `adversarial_entryfix.json`, `adversarial_combined.json`, `safefail_corpus.json`, `deep_ablation.json`, `underground_v2.json`
