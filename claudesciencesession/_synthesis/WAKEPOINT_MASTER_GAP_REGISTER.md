# WakePoint — Master Gap Register & Corrected Build Plan

**Compiled 2026-07-10 by an independent audit + deep-research pass (5 parallel investigative "legs", ~55 agents).**
This supersedes the optimistic framing of `claudesciencesession/HANDOFF.md`. It is grounded in: re-derived raw numbers, a line-by-line EKF port diff, verified `file:line` code citations, primary-source platform docs, and an exhaustive 138-scenario real-world sweep. Raw per-agent evidence is in `claudesciencesession/_synthesis/*.json`.

> **One-line verdict:** The EKF is real and good, but it is the *deepest* problem, not the *widest* one. WakePoint currently cannot reliably wake a sleeping rider on **any** platform — not because of filter accuracy, but because the OS-integration layer (background sensor delivery, process survival, self-contained alarm, exact-alarm backstop) is largely unbuilt, and the alarm loop is structurally frozen during the exact GPS-blackout the EKF exists for. Fixing the filter without fixing these changes nothing.

---

## 1. The intent, reasoned top-down (why the gaps are where they are)

**L0 — the single intent:** *wake a sleeping transit rider, with lead time, before their stop — effectively never after.* Asymmetric cost: early = annoyance, late = product death.

**L0 is a conjunction, not a sum.** Model it as a fault tree — the rider misses their stop if **any one** link fails, so P(success) is the *product* and the **weakest link governs**:

| # | Link | Status today |
|---|------|--------------|
| 1 | Route is right (correct line/stops/geometry, not stale, right train) | **FRAGILE** — no versioning; wrong-train undetected |
| 2 | Localization is right (GPS + EKF DR) | **BUILT, UNWIRED** — good filter, but see links 3/6 |
| 3 | Fire-decision is right (timely, uses EKF, has margin) | **BROKEN** — GPS-event-driven (frozen in tunnel); ignores EKF; no margin |
| 4 | Alarm is audible (silent/DND/locked/screen-off) | **FRAGILE** — delegated to a possibly-dead isolate |
| 5 | Process is alive (survives ~2h screen-off, Doze, OEM killers) | **FRAGILE/MISSING** — no wakelock, no backstop, no boot recovery |
| 6 | Sensors + permissions exist (bg location, IMU actually streaming) | **MISSING** — IMU not delivered w/o wakelock; bg-location flow broken |
| 7 | Journey shape handled (transfers, wrong-dir, express, sleeper) | **PARTIAL** — wrong-direction silently swallowed |
| 8 | User trusts it (perms, battery, no false alarm, honest limits) | **MISSING** — no reliability disclosure, no OEM onboarding |

The science session invested ~100% in link **2**. The product dies at links **3, 4, 5, 6** first.

---

## 2. Scorecard on the prior science session (what's real vs overstated)

### ✅ Solid — reproduced exactly, trust it
- **Core EKF value.** Median blackout-end error **EKF 135m vs constant-velocity 880m vs GPS-hold 2463m**; EKF beats CV **36/40**, hold **40/40**. Re-derived from `ekf_vs_baseline.json` to the decimal.
- **Port fidelity.** `ekf_reference.py` is a faithful line-for-line port of shipping `ekf_pipeline.dart` (state matches to `Δs=1.4e-14`). The Python sim is a valid stand-in for the filter's *math*.
- **Code citations.** Every `file:line` in `WakePoint_Dart_Port_Spec.md` (A1@463-464 & 555, B1@646-712, C1@158-176, D1/D2, E1) verified accurate against current `lib/`.
- **Synth calibration.** `v_cruise=19.3 m/s`, `dwell=22s`, `accel=1.1` all consistent with the one real ride.
- **Standalone web demo** (`demo/wakepoint_ekf_demo.html`) runs the *real* EKF in-browser and is self-contained/openable.

### ⚠️ Overstated or wrong — do not repeat these in a pitch
- **"Never-late GUARANTEED across 40 routes."** WRONG. By the prior agent's own `lead_err>0 = late` rule, the raw data has late fires the summaries zero out: `gap5a_nlos` **6/12 late**, `gap3_wrongroute` **2/6**, `gap1_multiblk` **1/16**. (Most are <30s and still before arrival, but the tables round them away — the §7 pattern, a 3rd/4th instance.)
- **The headline numbers describe an *unshipped* filter.** The experiments use `EkfVel = EkfFixed(A1) + learned-velocity(A4)`, **not** the shipping filter. Shipping σ-cap is 200m vs the experiment's 3000m → after a 300s blackout the critical-fractile safety margin is **43s (shipping) vs 500s (experiment)**. **Wiring the EKF in *without* porting A1 gives you a filter that fires close to late.**
- **Velocity regressor (the 0%→100% keystone) is circular — and confirmed to collapse on real data.** The synth makes IMU vibration a function of speed; on the *real* ride "no accel band tracks speed (broadband RMS r=−0.33, n=349)." **Do not ship A4 on sim evidence.** The real underground anchor must be **stop-event / ZUPT detection**, not learned velocity.
- **Dwell "≤2.6% miss, GUARANTEED"** — sim-only, never checked against the real ride's annotated stops. It is a *hypothesis*, not a guarantee.
- **`run_full_engine` (the driver behind every `gap*.json`) was never saved** → those specific numbers are not independently reproducible from disk (only circumstantially attributable to `EkfVel`).

---

## 3. The master gap register (deduplicated root gaps)

Severity: 🔴 SHOWSTOPPER (product dead) · 🟠 CRITICAL · 🟡 HIGH · ⚪ MED/LOW.
"Convergence" = how many independent legs found it (higher = more certain).

### Link 6 — Sensors & background execution (the new foundation)
| ID | Sev | Gap | Evidence | Fix |
|----|-----|-----|----------|-----|
| **G1** | 🔴 | **Background IMU is not delivered without a wakelock.** Android accel/gyro are *non-wake-up* sensors; when the screen turns off the AP suspends and events are buffered/dropped, not streamed. So the EKF is fed stale/batched data through the whole tunnel. The science session validated on a 50 Hz stream **the app never receives in production.** | AOSP suspend-mode doc; no wakelock in `lib/` or `android/` | FGS(location) + **partial wakelock held for the ride** + zero-latency listener (`maxReportLatency=0`). 50–100 Hz is under the 200 Hz cap → no special perm. |
| **G2** | 🔴 | **No Doze/battery-optimization exemption & no per-OEM autostart onboarding.** ~60–75% of the India market (Xiaomi/Oppo/Vivo/Realme/Samsung) kills the FGS within minutes of screen-off. | `AndroidManifest.xml` has no `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; `permission_service.dart:13-26` stops at location+notif+activity | System exemption dialog + `device_info_plus` → per-OEM autostart deep-links (verbatim ComponentNames in `reliability_agents.json`) + liveness re-nag on next open. |

### Link 5 — Process survival & backstop
| ID | Sev | Gap | Evidence | Fix |
|----|-----|-----|----------|-----|
| **G3** | ⚪ MED | **Misleading "Tracking paused" notification on UI death** (was flagged CRITICAL; **corrected by adversarial verification**). When the foreground heartbeat stops, `HeartbeatMonitor` sets `paused=true`, cancels the journey notification and shows "Tracking paused — Resume". **But alarm *evaluation* continues in the background-service isolate** (`trackingservice.dart:2105`), so this does **not** stop the alarm — it only shows a misleading/worrying notification. Real risk is delivery (G6), not evaluation. | `heartbeat_monitor.dart:83-91`; bg isolate at `trackingservice.dart:2105` | Reword/suppress the "paused" notification; don't imply tracking stopped. |
| **G4** | 🟡 | **Boot recovery exists but is disabled** (was flagged SHOWSTOPPER; **corrected**). `flutter_background_service_android` ships a `BootReceiver` — the "no boot path" claim is refuted — but `autoStartOnBoot` is off and there's no OEM-autostart whitelisting, so reboot recovery is unreliable in practice. | plugin `BootReceiver`; `autoStart:false` | Set `autoStartOnBoot:true`; add a reboot integration test; pair with G2 OEM autostart. |
| **G5** | 🔴 | **No independent exact-alarm dead-man's-switch.** Every alarm is a *live* notification from the tracking loop; if the loop dies (Doze, OEM kill, LMK, reboot) nothing re-fires. | no `SCHEDULE_EXACT_ALARM`/`setAlarmClock` anywhere | `AlarmManager.setAlarmClock()` (Doze-exempt) scheduled at the ETA and **re-armed as ETA updates** — fires even if the process is dead. |

### Link 4 — Alarm delivery (last mile)
| ID | Sev | Gap | Evidence | Fix |
|----|-----|-----|----------|-----|
| **G6** | 🔴 | **The alarm raise is delegated from the bg isolate to the (possibly dead) UI isolate** via fire-and-forget `service.invoke('triggerAlarm')` with no ACK. Swipe the app away → service lives, but the alarm is **silent and invisible**. | `alarm_controller.dart` bg branch | Post the full-screen notification **and** start audio/vibration directly from the bg isolate. |
| **G7** | 🟡 | Android 14 **full-screen-intent not guaranteed**; no `canUseFullScreenIntent()` check. | `USE_FULL_SCREEN_INTENT` declared, no runtime check | Check at setup; route to `ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`. |
| **G8** | 🟡 | **BT earphones fall out → alarm plays to a dead route.** No `AUDIO_BECOMING_NOISY` / route-change handling. | `alarm_player.dart:13-24`, no route listener | Listen for route changes; force alarm to loudspeaker. |
| **G9** | ⚪ | DND "total silence" hole; no `bypassDnd`/notification-policy; no volume ramp for deep sleepers. | `notification_service.dart`, `alarm_player.dart` | Request notification-policy access; `setBypassDnd(true)`; escalating volume + stronger haptics. |

### Link 3 — Fire decision
| ID | Sev | Gap | Evidence | Fix |
|----|-----|-----|----------|-----|
| **G10** | 🔴 | **The alarm loop is GPS-event-driven — frozen during a blackout.** `onCheckAlarm` runs *only* from `_handlePositionUpdate`. In a tunnel no `Position` arrives → the alarm is **never re-evaluated**; if the target stop is reached underground, it never fires **even with a perfect EKF.** This is a *new* keystone, a peer of E1. | `trackingservice.dart` position-driven eval | Drive `onCheckAlarm` from a timer / IMU tick during GPS-out, using EKF state. |
| **G11** | 🔴 | **EKF is not consumed by the alarm.** `_enableEkf` defaults false; the alarm is computed from raw GPS; `EKF.v` is entirely unused (GPS speed collapses to ~0 in a tunnel). E1 (`onGpsUnavailable` never called in prod) is real but *insufficient*. | `sensor_fusion.dart:90`; `alarm_evaluator.dart` | Wire E1 **and** feed `EKF.s/v/σ` into the evaluator for metro/degraded. |
| **G12** | 🔴 | **No uncertainty-aware (critical-fractile) firing** (B1). Fires on point-estimate ETA / exact stop count despite `sigmaEta` & `EKF.σ` being available. | `alarm_controller.dart:646-712` | Fire when `median_ETA − k·σ_ETA ≤ lead`; inflate effective stop-reach by `k·σ_s`. |
| **G13** | 🟡 | **Metro stop-count has zero position-error tolerance** — one `σ_s` bigger than an inter-station gap miscounts a full station → fires a stop **late**. | `alarm_evaluator.dart` metro path | σ cushion on "reached"; combine remaining-stops with a distance guard. |
| **G27** | 🟡 | **No GPS-accuracy gate on the fire decision** (new, adversarially confirmed). A rider who granted only "Approximate location" (Android 12+ coarse toggle) gets ~1–3 km fixes; the alarm computes against them → fires km-early or reports not-near → miss. Any grant is treated as success. | `permission_service.dart:48`; alarm evaluator | Reject/hold fixes whose accuracy exceeds a fraction of the alarm threshold; detect coarse-only grant and warn. |
| **G28** | 🟡 | **Location Services turned off mid-journey is silently swallowed** (new, adversarially confirmed). No service-status handling; the position-stream error is swallowed → stream stops with no warning → no alarm. | `location_manager.dart:95-100` | Subscribe to `getServiceStatusStream()` + a position-silence watchdog; warn / force-fire conservatively. |

### Link 1/7 — Route correctness & journey shape
| ID | Sev | Gap | Evidence | Fix |
|----|-----|-----|----------|-----|
| **G14** | 🔴 | **Wrong-direction / wrong-train silently swallowed.** Metro legs disable lateral-deviation checks; `_headingAgreement` is stubbed to `0.5` (ignores compass); EKF integrates *speed magnitude* with no signed direction, plus a backward-movement penalty. A rider on the opposite-direction or wrong-but-parallel train is carried away with **no alarm ever approaching.** | `active_route_manager.dart:273-283`, `snap_to_route.dart:171-173`, `route_session_manager.dart:1114-1130` | Signed along-track direction check vs the leg's boarding→alighting bearing; alert on sustained reverse/opposing. |
| **G15** | 🟡 | Branching / short-turn / depot-divert undetected on metro legs (same root as G14). | metro deviation disabled | Same geometry/direction gate + terminus awareness. |
| **G16** | 🟡 | **OSM stop-undercount corrupts "N stops before."** `enhanceTransitLegStopsWithOsm` **ignores Google `num_stops`** and counts only bundled OSM stations within 500m; thin coverage outside Delhi → wrong denominator → fires at the wrong station. | `transfer_utils.dart:1234-1372`, `all_india_stops.dart` | Cross-check OSM count vs Google `num_stops`; fall back / flag low-confidence on divergence. |
| **G17** | 🟡 | **No route versioning / expiry / service-change / staleness** (D8). Only a 5-min cost TTL; a route planned pre-midnight for a line that stops running is never re-validated. | `route_cache.dart:62`, `direction_service.dart:130-138` | Stamp fetch time + planned window + schema version; re-validate on session start & foreground. |
| **G18** | 🟠 | **Long intercity sleeper journey (6–10h, one stop) — the core use case — appears to be *refused at creation*.** | scenario leg (verify in `route_session_manager`) | Confirm & lift the limit; this is the flagship scenario. |

### Link 2 — Localization / EKF
| ID | Sev | Gap | Evidence | Fix |
|----|-----|-----|----------|-----|
| **G19** | 🟠 | **A4 learned-velocity is circular → will collapse on real data.** Don't ship it. | audit + research legs | Anchor underground on **stop/ZUPT detection**, not learned speed. Keep the OOD gate so any velocity hint self-downweights. |
| **G20** | 🟡 | **Shipping σ-cap (200m) → tiny safety margin** → fires close to late. | `ekf_pipeline.dart:555`; audit port-diff | Port **A1** (raise cap to ~3000; remove ZUPT position-tightening `:463`). |
| **G21** | 🟡 | **No-gyro budget phones → DR quality collapse** (categorical, untested). Also: mid-journey reorientation (hand→lap) untested; no motion/tilt gating; EKF has no orientation state. | scenario/research legs | Detect missing gyro → widen σ / fall back to GPS+schedule; add a motion-mode gate. |
| **G22** | 🟡 | Post-reacquire **sticky phantom progress**: Dart's `_updatePublicProgress` monotonic-clamps public `s` (even in degraded mode), so after a tunnel overshoot it over-reports progress. Fails *early* (safe) but can trigger a slightly-early fire. | `ekf_pipeline.dart:575-582` | Acceptable given asymmetric cost; document. Optionally relax the clamp post-GPS-correction. |

### Link 5/6 — iOS (entire platform)
| ID | Sev | Gap | Evidence | Fix |
|----|-----|-----|----------|-----|
| **G23** | 🔴 | **iOS is entirely non-functional.** `UIBackgroundModes` absent → app suspends on lock → zero position/EKF/alarm. And even fixed, **deep-tunnel DR is impossible on iOS** (no background raw-IMU mode; CoreMotion stops when suspended). | `ios/Runner/Info.plist`; Apple docs | Add `location`(+`audio`) background modes, `allowsBackgroundLocationUpdates`, region-monitoring relaunch backstop, Time-Sensitive/Critical-Alerts. **Scope iOS as fast-follow, not launch.** |

### Link 8 — Trust, legal, accessibility
| ID | Sev | Gap | Evidence | Fix |
|----|-----|-----|----------|-----|
| **G24** | 🟡 | No reliability disclaimer / safety framing anywhere; a silent miss can strand a rider. | scenario leg | In-app honesty: show the reliability tier per device, disclose un-closable OEM/iOS limits. |
| **G25** | 🟡 | **Deaf/HoH riders:** single fixed vibration absorbed by a soft seat; no escalation. | scenario leg | Escalating/patterned haptics; optional screen-flash; recommend on-body placement. |
| **G26** | ⚪ | Per-tick debug file write (`mumbai_alarm_debug.txt`) + large `print()` on the hot path → battery/latency on a 2h ride. | `alarm_evaluator.dart` | Gate behind `kDebugMode`; remove per-tick file append. |

---

## 4. The honest reliability *ceiling* (un-closable — must be disclosed, not hidden)
1. **Huawei/Honor no-GMS (PowerGenie)** — kills anything off its private whitelist; removal needs ADB. Treat as **unsupported** with a hard warning.
2. **User force-stop / recents-swipe on force-stop-happy OEMs** — cancels the `AlarmManager` backstop *and* disables receivers until the next manual launch. Un-closable by any API; re-nag only protects the *next* trip.
3. **iOS deep-tunnel DR** — impossible; iOS grants no background raw-IMU. Best iOS can do is GPS + schedule + region-monitoring relaunch.
4. **Strict DND "total silence"** — silent unless the user grants notification-policy access.
5. **Extreme/Ultra battery saver** — can suspend even exempted apps.

These are not bugs to fix; they are **product boundaries to communicate.** A funder-credible pitch names them.

---

## 5. Corrected build plan (priority = reliability gained per unit effort)

**Phase 0 — Make the engine actually run in the background (before any filter work).**
`P0.1` FGS(location)+wakelock+zero-latency IMU (G1) · `P0.2` self-contained bg alarm delivery (G6) · `P0.3` exact-alarm ETA backstop (G5) · `P0.4` battery-exemption + OEM autostart onboarding (G2) · `P0.5` enable `autoStartOnBoot` + reboot test (G4).

**Phase 1 — Make the fire decision correct & EKF-aware.**
`P1.1` drive alarm eval on a tick during GPS-out (G10) · `P1.2` wire E1 + consume `EKF.s/v` (G11) · `P1.3` critical-fractile firing (G12) · `P1.4` stop-count σ cushion (G13) · `P1.5` GPS-accuracy + service-status gates (G27/G28).

**Phase 2 — Filter honesty (sim-verified, low risk).**
`P2.1` A1 honest covariance (G20) · `P2.2` motion-gated ZUPT + dwell-count association (anchor, replaces A4) (G19).

**Phase 3 — Route/journey correctness.**
`P3.1` signed wrong-direction/wrong-train detection (G14/G15) · `P3.2` OSM-vs-Google stop cross-check (G16) · `P3.3` route versioning (G17) · `P3.4` sleeper long-haul (G18).

**Phase 4 — iOS** (G23) as a scoped fast-follow. **Phase 5 — trust/accessibility polish** (G24–26).

**Do NOT ship:** A4 learned-velocity (circular).

**What I can implement + verify *here*** (`dart`/`flutter analyze`/`flutter test` + a standalone real-EKF Dart harness + web build): P1.1–P1.4, P2.1–P2.2, G16/G17, the manifest declarations, and the web-sim rewire (C1–C3).
**What needs a real device to verify** (no emulator can prove background survival): P0.1–P0.6, G23 (iOS), the OEM deep-links — I can write the code, but *trust it only after the on-device tests below.*

---

## 6. Minimum real-world validation (cheap, highest-uncertainty-killing)
1. **Background-sensor experiment** (1 metro ride): log timestamped accel/gyro sample counts, screen-off, in the FGS — *measure the real background sample rate* before trusting DR. Settles G1 empirically.
2. **Second real ride on a different phone** (1 friend, raw-logger): settles the circularity question (G19) — the single highest-value data point.
3. **OEM kill test:** arm a journey on a Redmi/Realme, screen off 30 min, confirm the FGS + exact-alarm backstop survive. Settles G2/G5.

---

*Evidence artifacts:* `_synthesis/{coverage,scenario,reliability,research,audit}_agents.json`, `_synthesis/unified_gaps.json`. Numbers re-derived in-session from `data/*.json`.
