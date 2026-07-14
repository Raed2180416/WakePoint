> # ⚠ STALE — SUPERSEDED 2026-07-10
> This handoff predates the deterministic re-audit. Several numbers in it were re-run from disk and
> **corrected or superseded** since. Do **not** cite this file as authoritative. The current source of truth is:
> - **`WakePoint_Reconciliation_Dossier.md` (v9, 2026-07-10 session addendum)** — the reconciled master doc.
> - **`WakePoint_Audit_Ledger.md`** — every headline number marked REPRODUCED / SUPERSEDED / REFINED.
> - **`WakePoint_Fire_Rule_Spec.md`**, **`never_late_corrected.json`**, **`ekf_arc_reconciliation.json`**,
>   **`turnmatch_particle_filter.json`**, **`WakePoint_iOS_Background_Fix.md`** — the current deliverables.
>
> Key things this file gets wrong or out-of-date: the "+744 m overshoot / fires early" reading (it was scored
> against a zeroed-tunnel truth; the EKF actually **under-shoots −2988 m** and fires **late** underground); the
> "velocity decay" mechanism (it is **init-speed-dominated coasting**); the never-late framing (on corrected
> truth, EKF-alone is **54.7 %**, and no IMU-only rule ships at 98 % two-sided — the guarantee needs the
> timetable anchor); the turn-matching anchor is now **built** (a prior-robust exit anchor). iOS background
> execution now has a **prepared fix** (staged, uncommitted). See the dossier's SESSION ADDENDUM for the full
> supersede register.
>
> _Kept for history; read the dossier instead._

---

# WakePoint GPS-Out Engine — Complete Handoff

**Written:** 2026-07-09/10, by the prior Claude Science agent, for the next agent picking this up cold.
**You are being asked to be a superior, more rigorous auditor and builder than I was.** I found real bugs in my own work this session (an auditor caught me overstating a "never-late" guarantee twice — see §7). Assume everything below could have a similar error until you've re-derived it yourself. Don't take my word for a number — re-run the code, it's all here.

This folder (`claudesciencesession/`) contains **every artifact produced across this entire project's chat history** — copied out of the ephemeral session artifact store onto disk, in this repo, under version control. Nothing here is a summary-of-a-summary; the reports are the actual deliverables, the code is the actual code that produced every number quoted in them, and the JSON files are the actual raw results.

---

## 1. What this project IS

**WakePoint** (Raed's project — 21, financially constrained, building this to pitch/get funded — be direct and rigorous with him, he wants brutal honesty not reassurance) is a Flutter/Dart Android+iOS app: a **transit wake-up alarm**. The user prefetches their route (metro/train line + stops, or a non-metro destination), falls asleep, and the app wakes them before their stop — using GPS when available, and **dead-reckoning via phone IMU (accelerometer + gyroscope) when GPS is unavailable** (the core hard problem — tunnels, underground metro, etc).

**The core engine is a 1D-progress Extended Kalman Filter (EKF).** State vector `[s, v, b]` = arc-length progress along the route (meters), velocity (m/s), accelerometer bias (m/s²). It is NOT a 2D/3D position filter — the route is prefetched and known, so the problem reduces to "where am I along this known 1D path," which is a much easier and more robust problem than general PDR (pedestrian dead reckoning) or INS.

**Real repo code** (this is the actual Dart app, not a simulation):
- `lib/core/ekf/ekf_pipeline.dart` — the EKF itself
- `lib/core/ekf/ekf_orchestrator.dart` — wires GPS/IMU into the EKF, manages degraded-mode transitions
- `lib/core/ekf/station_association.dart` — snaps estimated position to known station stops
- `lib/services/sensor_fusion.dart` — feeds GPS updates in production
- `lib/services/tracking/alarm_controller.dart` — the alarm fire logic (4 modes, see below)
- `lib/services/alarm_evaluator.dart` — ETA/distance/stop-count computation

**IMPORTANT — as of this handoff, the EKF is built but NOT wired into production alarm logic** (`_enableEkf` defaults false somewhere in the codebase — verify this yourself, it may have changed). All of the verification below was done in **Python simulation**, faithfully porting the exact Dart EKF logic (see `code/ekf_reference.py`, ported line-for-line from `ekf_pipeline.dart`, verified to match a JS port (`code/ekf_js.js`) to within 0.3m). **Two bug fixes and one production-wiring gap identified this session have NOT yet been applied to the actual Dart files in `lib/` — that porting is unstarted work, see §8.**

**Four alarm modes** (user-selectable): metro mode → {N-stops-before, N-minutes-before}; non-metro mode → {distance-before, time-before}.

**The one design principle everything is built around: asymmetric cost.** Firing the alarm a few minutes early is a minor annoyance. Firing after the target stop is a product-killing failure (the whole point of the app is defeated). So every uncertain decision is architected to **fail toward early, never late** — this shows up throughout as "critical-fractile" firing rules, honest (large) uncertainty estimates, and watchdog backstops.

---

## 2. Repo-vs-session map — where things live

| Location | What |
|---|---|
| `/home/raed/Projects/WakePoint/lib/` | The real Dart/Flutter app. This is what ships. |
| `/home/raed/Projects/WakePoint/docs/` | Pre-existing docs folder — has the ONE real logged ride (`docs/Sandalsoap-whitefield/`), some early-session docs, and OSM data. |
| `/home/raed/Projects/WakePoint/claudesciencesession/` (**this folder**) | Every artifact from the Claude Science chat session(s) that did the GPS-out engine analysis. Organized by type: `reports/`, `code/`, `figures/`, `data/`, `demo/`. |
| Claude Science artifact store (ephemeral, `proj_1b75eb6c1ea0`) | The canonical source — 91 raw artifacts (84 unique after dedup), reachable via `host.artifacts()` in a Claude Science session. This folder is a disk copy of the **latest version** of each; if you continue in Claude Science, the store has full version history this disk copy doesn't. |

**The one real dataset:** `docs/Sandalsoap-whitefield/` — a single logged ride, Rajajinagar→Whitefield metro trip in Bangalore, ~1h41m, with a 388-second real GPS blackout (tunnel). This is the ONLY non-simulated ground truth in the whole project. Every other "route" and "ride" in this analysis is **synthetic** — generated by a custom IMU simulator calibrated against this one real ride (see §4, and the circularity caveat in §7 — this is the single biggest epistemic weakness of everything below).

---

## 3. Reading order — reports (in `reports/`)

Read these in this order; each supersedes/extends the previous, and skipping ahead will cost you context.

1. **`WakePoint_Product_Coverage.md`** — START HERE. Plain-language, investor/pitch-facing: what's GUARANTEED, what's BOUNDED-but-safe, what's tested-and-safe, and the one structural gap found. Written for Raed, not for you, but it's the fastest way to get oriented on the state of the truth as of this handoff.
2. **`WakePoint_GPSout_Handoff.md`** — the technical single-source-of-truth for the GPS-out engine specifically (10 sections: what the EKF adds, the fix ladder, circularity, the fundamental two-sided-window limit, coverage map, production bug, next steps).
3. **`WakePoint_Robustness_Report.md`** — the original brutal-assessment report (180 mode-evaluations across 10 real-world scenarios) PLUS an appended "Addendum (2026-07-09)" section with all the GPS-out deep-dive findings (any-route corpus, adversarial search, EKF-vs-baseline, curvature anchor). Read the addendum; the original body is now partially superseded by it (see §7 for exactly which claims to distrust).
4. **`WakePoint_5Gap_Results.md`** — the most recent work: the 5 previously-untested real-world gaps (multiple blackouts, line transfers, wrong-direction/wrong-route, excessive motion, GPS/sensor degradation), each tested end-to-end against the full engine. **This surfaced the one genuinely new, unresolved safety requirement: a pre-blackout GPS route-match gate (§6, item 9).**
5. **`WakePoint_Dart_Port_Spec.md`** — exactly what to change in the Dart repo, each item gated on the simulation evidence that justifies it, with file:line citations. This is your porting checklist. **A6 in this doc was corrected mid-session — read the "Verified scope" paragraph carefully, don't trust the section header alone.**
6. **Research docs** (`velocity_sota_2026.md`, `underground_anchoring_sota.md`, `learned_velocity_transfer_sota.md`, `robust_dwell_detection_sota.md`, `track1_zupt_motion.md`, `track_eta_alarm.md`, `track_pedestrian.md`, `track_gps_degraded.md`) — literature reviews as of ~July 2026, each with arXiv IDs, on: learned-velocity transfer, underground/anchoring methods, dwell detection, pedestrian dead reckoning, ETA/alarm design, GPS degradation. Use these as your starting bibliography, not gospel — verify anything load-bearing before citing it further.
7. **Audit docs** (`runtime_lifecycle_map.md`, `correctness_assumptions_map.md`, `gps_out_correctness_map.md`) — citation-grounded (`file:line`) audits of the actual Dart repo, done early in the session. These found the production wiring bug (§6 item on `onGpsUnavailable`) and the lifecycle risk (OS suspension, battery killers — separate from the filter entirely).
8. **`WakePoint_Master_Analysis.md`, `WakePoint_Research_Consolidated.md`, `WakePoint_Methodology_Plan.md`, `WakePoint_Scenario_Matrix.md`, `WakePoint_Fidelity_Checklist.md`** — earlier-session planning and synthesis docs. Historical context; the later reports supersede their factual claims where they overlap, but the methodology (synthesizer design rationale, scenario taxonomy) is still the reference.

---

## 4. How to reload the simulation engine (code in `code/`)

Everything is Python. There is no saved "environment" — you rebuild the engine by loading these files in order in a fresh Python kernel:

```python
import importlib.util, sys, numpy as np, json, pickle, inspect
def L(n,p):
    s=importlib.util.spec_from_file_location(n,p); m=importlib.util.module_from_spec(s)
    sys.modules[n]=m; s.loader.exec_module(m); return m

ekf_ref = L("ekf_reference", "code/ekf_reference.py")       # faithful Python port of ekf_pipeline.dart
step12  = L("wakepoint_step12", "code/wakepoint_step12.py") # EkfFixed (honest-cov fix), DwellDetector, DwellCountAssociator
step34  = L("wakepoint_step34", "code/wakepoint_step34.py") # EkfVel (velocity-fusion variant), learned_velocity_series, imu_features2 (OOD features)
AM      = L("wakepoint_alarm_modes", "code/wakepoint_alarm_modes.py")  # the 4 alarm-mode fire rules, ported from alarm_controller.dart
synth   = L("synthesizer", "code/synthesizer.py")           # the IMU synthesizer (4-layer: kinematics, orientation/carry-mode, sensor noise, GPS)

velreg = pickle.load(open("data/velreg_model.pkl","rb"))    # trained HistGradientBoostingRegressor, learned-velocity model
calib  = json.load(open("data/synth_calibration.json"))     # synthesizer physical params (v_cruise, accel, dwell times, etc)
noise  = json.load(open("data/synth_noise.json"))           # sensor noise model (white noise, bias instability, bias random-walk)
```

**IMPORTANT GOTCHA:** the `synthesizer.py` on disk (as saved) does NOT emit the gravity-in-device-frame channels (`grx`,`gry`,`grz`) that the tilt-filter code needs — this was patched live in-session by monkeypatching `synth_imu_v2`'s source and re-exec'ing it. If you see a `KeyError: 'grx'`, you need this patch. The patch (verbatim, apply once per kernel):
```python
src = inspect.getsource(synth.synth_imu_v2)
src = src.replace(
    "f_dev=np.einsum('nij,nj->ni',np.transpose(R,(0,2,1)),f_world)",
    "f_dev=np.einsum('nij,nj->ni',np.transpose(R,(0,2,1)),f_world)\n    g_dev=np.einsum('nij,nj->ni',np.transpose(R,(0,2,1)),grav)")
src = src.replace(
    "roll=roll,pitch=pitch,yaw=yaw,",
    "roll=roll,pitch=pitch,yaw=yaw,grx=g_dev[:,0],gry=g_dev[:,1],grz=g_dev[:,2],")
exec(compile(src, "<patched>", "exec"), synth.__dict__)
```
**This patch is real technical debt — it should be applied permanently to `synthesizer.py` (not re-applied via monkeypatch every session) as your first cleanup task.**

**OOD gate for the velocity regressor** (see §7 circularity discussion) — needs `data/velreg_corpus.npz` (the training corpus, 93740 windows) to compute the Mahalanobis-distance-to-training-manifold gate:
```python
corpus = np.load("data/velreg_corpus.npz", allow_pickle=True)
Xtr = np.vstack([corpus[f"F_{k}"] for k in range(100,140) if f"F_{k}" in corpus])
mu = Xtr.mean(0); Cinv = np.linalg.pinv(np.cov(Xtr.T))
def ood_maha(x):
    d = x - mu; return float(np.sqrt(max(0.0, d @ Cinv @ d)))
md_p95 = float(np.percentile(np.array([ood_maha(x) for x in Xtr[::20]]), 95))  # ~4.18
```

**The route-corpus generator and the canonical full-engine runner (`run_full_engine`) were NOT saved as standalone files** — they were built inline in the chat session and are NOT in this folder as a clean script. **This is a real gap in this handoff: you will need to reconstruct `run_full_engine` (the function that runs the complete engine — entry-snap count init, 13-min watchdog, honest sigma-floor, OOD-gated velocity, combined trigger — over one synthetic ride) from the descriptions in `WakePoint_5Gap_Results.md` and `WakePoint_GPSout_Handoff.md`, OR from the Claude Science session transcript if you have access to it (frame_id `3e7bbb26-fa28-41e6-969a-9dda05072172`, project `proj_1b75eb6c1ea0`).** This is your first real engineering task — see §9.

---

## 5. What the EKF actually adds (verified, not assumed)

A skeptical first question worth asking: does the EKF even help, or is it dead weight? **Verified answer: no, it's decisive.** Baselines were *gifted* true position+velocity at blackout entry (an unfair advantage), then compared to the EKF over 40 real-topology routes (`data/ekf_vs_baseline.json`, `figures/ekf_vs_baseline.png`):

| Method | Median blackout-end position error |
|---|---|
| GPS-hold (freeze last fix) | 2463 m |
| Constant-velocity extrapolation | 880 m |
| **EKF (WakePoint)** | **135 m** |

EKF beats constant-velocity 36/40 routes, GPS-hold 40/40. The value is **not raw IMU integration** — it's measurement fusion (stop-detection snaps position, velocity fusion corrects drift) plus one honestly-calibrated uncertainty estimate that the alarm-fire rule uses correctly.

---

## 6. Everything verified this session — status map

Use this table as your starting checklist; **re-verify every row yourself**, don't inherit it as fact.

| Claim | Status | Evidence file |
|---|---|---|
| Dwell (stop) detection misses ≤2.6% of real stops, all 5 carry modes (hand/pocket/bag/lap/to-ear) | GUARANTEED | keystone measurement, referenced in `WakePoint_GPSout_Handoff.md` |
| Never-late whenever GPS re-acquires at least once (normal case) | GUARANTEED, verified across 40 routes + adversarial + multi-blackout + transfers + excessive-motion + GPS/sensor-degradation | `WakePoint_5Gap_Results.md`, `data/gap*.json` |
| Never-late on cold-start-fully-underground (no GPS ever) | **NOT guaranteed** — 1/6 late (worst ~+7min) with ship-now fixes; only the unshipped curvature anchor closes it to 0/6 | `WakePoint_GPSout_Handoff.md` §A4, corrected in `WakePoint_Product_Coverage.md` v3 |
| ≤3-min-early bound | Holds except long-blackout(>500s)+wide-spacing(≥3500m) routes, where it can fire several minutes early (safe, not tight) | `WakePoint_Robustness_Report.md` addendum §A4 |
| Multiple blackouts in one journey | SAFE, 0/16 late | `data/gap1_multiblk.json` |
| Line transfers (train A→walk→train B) | Safe, 1 minor caveat: 1/10 late (+69s) — transfer-walk is a dwell-less segment the count can't advance through | `data/gap2_transfer.json` |
| Wrong-direction (rider reverses during blackout) | SAFE — 0/10 false alarms (reverse motion is clamped on metro legs, so the alarm never falsely fires); but this means wrong-direction is currently **silently** handled, not flagged to the user | `data/gap3_wrongdir.json` |
| Wrong-route (rider on a DIFFERENT line than prefetched) | **STRUCTURAL, UNRESOLVED** — 1/6 late (+468s), leads scatter -1099s to +468s. The engine tracks its prefetched belief and is blind to the mismatch during a blackout — this is not fixable from IMU alone. **Needs an app-level pre-blackout GPS route-match gate.** | `data/gap3_wrongroute.json` |
| Excessive motion (fidgeting/walking-in-car) during blackout | SAFE, 0/12 late — the band-energy vehicular-motion gate rejects non-vehicular motion, dwell count unaffected | `data/gap4_excessmotion.json` |
| GPS degradation (NLOS/multipath wrong-fixes, not clean blackout) | SAFE, 0/12 late even at 300m correlated bias — Huber gate absorbs it | `data/gap5a_nlos.json` |
| Cheap-phone sensor quality (2-4x noisier IMU) | SAFE, 0/12 late — degrades gracefully (noisier → larger honest sigma → fires earlier, not later) | `data/gap5b_sensordegrade.json` |
| Curvature/turning as a position anchor | Feasible as a **desync detector** (r=0.98 correlation with expected turning) and as a **combined-OR-trigger backup** (eliminates cold-start-underground's one late-fire case) — NOT robust as a standalone position tracker (diverges on ambiguous-curvature routes) | `code/wakepoint_curvature_anchor.py`, `data/curvature_anchor_results.json` |
| Velocity-regressor circularity | The learned-velocity model was trained on the SAME synthesizer used to test it — real-ride validation shows the synthesizer's vibration-vs-speed relationship does NOT match reality (all correlations flat-to-negative on real data, vs positive in synth). **This means the regressor's accuracy numbers are sim-only and may not transfer.** MITIGATED by an OOD gate: on real IMU data the regressor self-detects as out-of-distribution 70% of the time and inflates its own uncertainty, which makes it fail SAFE (fires early) rather than fail dangerously (confident-wrong). This mitigation is verified but the underlying circularity is NOT resolved — it needs a second real ride on a different phone. | `WakePoint_GPSout_Handoff.md` §5, `WakePoint_Robustness_Report.md` |
| Production wiring: `onGpsUnavailable()` is never called in production Dart code | **CONFIRMED BUG, NOT YET FIXED IN `lib/`** — verify still true; it may have been fixed since this handoff if anyone touched the repo | `WakePoint_Dart_Port_Spec.md` §E1, `runtime_lifecycle_map.md` |

---

## 7. Errors I made this session — read this before trusting any of my other numbers

An adversarial auditor (a fresh-context reviewer with no stake in my prior claims) caught me overstating results **twice** in the same session, both times in the *strongest-confidence* documents:

1. I wrote in `WakePoint_Dart_Port_Spec.md` that the entry-snap + 13-minute-watchdog fixes (A5+A6) achieve **"0/27 adversarial late-fires"** and **"0/6 late on the 13-min worst-case test."** This was **false** — that "0/27" figure belonged to a *different* variant (a learned-speed watchdog, which I had tested and rejected because it caused 5/27 routes to fire >3 minutes early). The actual A5+A6 (the ship-now fix) left **1/27 configs regressed to late** and, separately, **1/6 late on cold-start-fully-underground**. My own saved figure (`figures/gpsout_summary.png`, panel c) directly contradicted my own prose — the +424s late bar for seed2005 was plotted right there.
2. I then repeated the same overstatement in `WakePoint_Product_Coverage.md` — the investor/pitch-facing document — under the "GUARANTEED" header, which is the worst place to have an error.

**Both are now corrected** (see the corrected text in those files, and in `WakePoint_5Gap_Results.md`), but **this is a pattern, not a one-off** — I was working across many long-running background computations, holding many partial results in a chat context, and conflated two very similar-looking experiments. You should assume there may be other instances of this same failure mode elsewhere in the earlier reports that were never audited. **Recommended first task: re-derive the headline numbers in `WakePoint_GPSout_Handoff.md` and `WakePoint_Robustness_Report.md` directly from the raw JSON files in `data/`, rather than trusting the prose summaries.**

Other things to independently re-verify, not just re-read:
- The synthetic-vs-real circularity finding (item above) is itself only checked against ONE real ride. It's a real and important finding, but "all correlations flat-to-negative" from n=1 real data point is a thin evidence base for as strong a claim as "the synthesizer's core physical assumption is wrong." Get a second real ride if at all possible before treating this as settled.
- The dwell-detection false-negative rate (≤2.6%) was measured only in simulation, on synthetic data, across carry modes — it has NEVER been checked against the one real ride's actual annotated stops in detail (spot-check this specifically).
- I did not have time to verify: multiple-blackout journeys with a wrong-route AND wrong-direction combined (compounding failures); the interaction between the curvature anchor and cold-start-underground when GPS-degradation (not clean blackout) is ALSO present; whether the "excessive motion" injection model is realistic for a standing/hanging-strap rider vs a seated one (only one carry/posture model was used).

---

## 8. The Dart port — status: SPEC WRITTEN, ZERO LINES PORTED

**Nothing in `lib/` has been changed as a result of this analysis.** `WakePoint_Dart_Port_Spec.md` is a complete, file:line-cited specification of what to change and why, gated on simulation evidence, but **porting has not started.** In order, cheapest/highest-confidence first:

1. **E1 (production wiring bug, `ekf_orchestrator.dart:246-273` / `sensor_fusion.dart:132`)** — `onGpsUnavailable()` is currently only called from test code, never from the production GPS-update path. Without this wired, **none of the GPS-out engine work in this handoff actually engages when a real user loses GPS.** This should be your first Dart change, before anything else, because it's what makes everything else matter.
2. **A1 (honest covariance, `ekf_pipeline.dart:463-464`)** — 2-line fix, delete the position-covariance-tightening on ZUPT.
3. **A2/A3 (motion-gated ZUPT + dwell-count association, `station_association.dart`)** — the hysteresis fix (`arcs ≤ s_gps − 50`, not `+150`).
4. **A5 (blackout-entry count init, NEW this session)** — snap count to nearest station at blackout entry, not the −50-behind station.
5. **A6 (13-min physical watchdog, NEW this session)** — force-advance count if >780s since last confirmed dwell/GPS. **Read the corrected "Verified scope" note in the spec — this does NOT achieve unconditional never-late, see §6/§7 above.**
6. **C1-C3 (simulator/demo rewire)** — the web demo (`demo/wakepoint_ekf_demo.html`) had a fake non-EKF simulation loop; this was identified and a real-EKF JS port built (`code/ekf_js.js`) but verify it's actually wired into the demo's UI before treating this as done.
7. **A4 (learned-velocity fusion)** — LOWEST priority to port given the circularity caveat (§7/§6) — do this only after a second real ride, or port it gated behind the OOD safety mechanism (which IS validated).
8. **D1-D8 (on-device lifecycle: wakelock, battery-optimization exemption, `BOOT_COMPLETED`, background isolate survival, etc.)** — these are NOT simulatable and were flagged by the repo audit as possibly the **actual dominant real-world risk** (the filter can be perfect and the OS can still kill the whole tracking service while the user sleeps). See `runtime_lifecycle_map.md`.

---

## 9. Recommended next steps, in order

This is a suggestion, not a constraint — you have more capability than I did and may see a better path. But if you want a concrete starting sequence:

1. **Reconstruct `run_full_engine`** (§4) as a clean, tested, standalone Python module — this is the single most valuable piece of missing infrastructure. Everything downstream depends on having this as reusable code, not chat-session-only inline functions.
2. **Re-derive the headline numbers** in the two most-cited reports directly from `data/*.json`, and correct any further overstatements you find (§7).
3. **Get a second real ride** on a different phone — this is repeatedly flagged as the highest-value real-world data point, because it's the only thing that can validate or falsify the synthesizer circularity concern (§6/§7). Raed is financially constrained (his words) — a friend riding once with the app's raw-sensor logger running is enough; you don't need a fleet.
4. **Resolve the wrong-route structural gap (§6)** — design and prototype the pre-blackout GPS route-match gate. This is architecturally outside the EKF (it's a boarding-time check), and is the one genuinely new, unaddressed safety requirement from this entire body of work.
5. **Start the Dart port**, in the order given in §8, starting with E1 (the wiring bug) since nothing else matters until that's fixed.
6. **Build the curvature anchor properly** — it's promising (proven to eliminate the one cold-start-underground late-fire) but needs corpus-wide tuning before it's shippable; right now it's validated on only 6 underground seeds.
7. **Address the on-device lifecycle risks (D1-D8)** in parallel with the filter work — these are Android/iOS engineering, not data science, and don't depend on anything above.

---

## 10. Contact context for continuity

Raed (project owner) is 21, recently graduated (B.Tech, math & computing, 8.5 CGPA), financially constrained, building this to pitch for funding or monetize directly. He wants brutal, no-happy-path honesty over reassurance — he has explicitly said this multiple times ("no happy trigger tests, brutal real world tests"). He is testing-budget constrained, so prioritize simulation-verifiable fixes over things requiring expensive real-world data collection, and when you do recommend real-world testing, be specific about the *minimum* real data that resolves the *most* uncertainty (see §9 point 3).

Good luck. Be more rigorous than I was — the auditor findings in §7 are the bar to clear.