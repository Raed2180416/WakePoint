# WakePoint — Sim-Gated Dart Port Specification

**Purpose:** Exactly what to change in `/home/raed/Projects/WakePoint`, each change **gated on the simulation evidence** that justifies it. Nothing here is speculative — every fix maps to a measured result in the robustness corpus, the fix-ladder, or a citation-grounded repo audit.

**Hard rule honored:** *"only when it's verified to work do we make fixes in the actual repo."* Each item is tagged with its verification status:
- ✅ **SIM-VERIFIED** — proven in simulation; safe to port now.
- 🟡 **SIM-VERIFIED, DATA-GATED** — works in sim, but rests on the synthesizer; validate on real ride #2 before trusting the magnitude.
- 🔧 **AUDIT-IDENTIFIED** — a code gap found by repo audit; fix is engineering, must be validated on-device (no sim possible).

**Port order (cheapest-highest-confidence first):** B1 (alarm rule) → A1 (honest covariance) → A2/A3 (ZUPT + association) → C1–C3 (simulator rewire) → A4 (learned velocity, after real ride #2) → D1–D8 (on-device).

---

## Part A — EKF filter fixes

### A1. Honest covariance ✅ SIM-VERIFIED — port first
**Evidence:** Fix-ladder (n=6 seeds): production NEES ≈ 3930 (a consistent filter is ≈ 1). After this change NEES → 23. Necessary (not sufficient) for the alarm fix. Root cause is two lines.

**Change 1 — `lib/core/ekf/ekf_pipeline.dart:463-464`** (post-ZUPT tightening):
```dart
// BEFORE (the bug): ZUPT tightens POSITION covariance, but a zero-velocity update
// observes VELOCITY, not position — so this fabricates position certainty.
P[0][0] = min(P[0][0], 10.0 * 10.0);   // ← DELETE THIS LINE
P[1][1] = min(P[1][1], 0.5 * 0.5);     // keep: ZUPT legitimately tightens velocity
```
Remove the position-tightening line. ZUPT may tighten `P[1][1]` (velocity) and update the bias, never `P[0][0]`.

**Change 2 — `lib/core/ekf/ekf_pipeline.dart:555`** (max position sigma):
```dart
// BEFORE: static const maxSigmaS = 200.0;   // caps honest uncertainty growth underground
static const maxSigmaS = 3000.0;             // let sigma grow honestly through a blackout
```
**Why gated safe:** in the JS port verification, these two changes alone reproduced the Python `EkfFixed` behavior to 0.3 m mean. The fixed filter's σ band grows to ~76 m through the blackout (honest) instead of being pinned at a false ~16 m.

**Test after porting:** re-run the existing 445-test suite; NEES on the captured-real-route replay should drop from ~thousands to tens.

### A2. Motion-gated ZUPT ✅ SIM-VERIFIED — port with A1
**Evidence:** Production fires **2581 spurious ZUPTs** during a 330 s cruise (the demo counter). Each zeroes velocity; in constant-velocity cruise tangential accel ≈ 0, so once velocity is zeroed there is no signal to rebuild it → the estimate stalls (in-tunnel error 3108 m → 184 m when spurious ZUPTs are suppressed). This is the mechanism behind the 0 % alarm.

**Change — `lib/core/ekf/zupt_detector.dart`** + caller: gate ZUPT acceptance on a **band-energy vehicle-motion test**, not just low variance. A stationary phone and a smoothly cruising train both have low broadband variance; they differ in the **3–8 Hz band energy** (rail vibration). Only accept a ZUPT when the 3–8 Hz band energy is *below* a dwell threshold (the band-energy gate separated cruise 94 % / dwell 5 % in calibration).
```
accept ZUPT  ⇔  (existing low-variance test)  AND  band_energy_3_8Hz < dwell_threshold
```
Keep the existing `imuUltraQuiet` fast-path. This is the `ZuptQuiet` → `DwellDetector` logic in the Python reference (`min_dwell_s = 8` → 21/21 true stops matched, 1 false-positive).

### A3. Dwell-count station association ✅ SIM-VERIFIED — port with A1/A2
**Evidence:** With honest large σ (A1), the geometric snap window `3σ + margin` (`station_association.dart:106-210`) grows so wide it snaps to the wrong station; the margin then *shrinks* to avoid MULTIPLE_CANDIDATES (`:74-82`), which re-introduces overconfidence — a self-defeating loop. Replacing the geometric snap with a **dwell counter** breaks it: advance the known station index by exactly one per *confirmed physical dwell*, immune to arc-length lag.

**Change — `lib/core/ekf/station_association.dart`:** add a `DwellCountAssociator` that (a) counts confirmed dwells (≥ 8 s, band-energy-gated), (b) advances the target station index one stop per dwell, (c) **position-gates** the advance — only accept if the current estimate is plausibly within one inter-station spacing of the next station's arc (defense-in-depth against phantom dwells; §4 of the robustness report showed the gate rejects a phantom dwell at 621 m from the next station). Keep the geometric snap as a secondary correction on the surface where GPS is present.

### A4. Learned-velocity fusion through blackout 🟡 SIM-VERIFIED, DATA-GATED — port AFTER real ride #2
**Evidence:** This is the keystone that lifts the alarm 0 % → 100 % (fix-ladder Step 3). A `HistGradientBoostingRegressor` on 8 phone-independent IMU features (band energies, accel percentiles, gyro stats) predicts along-route speed at held-out MAE 1.52 m/s, R² 0.84; fused as an EKF velocity measurement `H = [0,1,0]`, `vel_var = 4.0`, every 0.5 s during the blackout.

**⚠ WHY DATA-GATED:** the R² = 0.84 is **simulation-only**. The synthesizer's vibration amplitude is speed-driven, so the regressor may partly be inverting its own generator (circularity). **Do not ship A4 to production on sim evidence alone.** Port A1+A2+A3 first (they are physics/logic, low circularity risk); capture **real ride #2** on a different phone; re-train and re-validate the regressor on real held-out data; only then port A4. Until then, the underground behavior in production should degrade *honestly* (wide σ, no false alarm) rather than fire on an unvalidated velocity.

**Implementation when ready:** the 8 features are deliberately phone-independent (no absolute-scale dependence) so a model trained on one device generalizes. Export the trained model to a lightweight on-device form (TFLite or a hand-rolled GBM evaluator — the model is small).

### A5. Blackout-entry count initialization ✅ SIM-VERIFIED — port with A3 (new, 2026-07-09)
**Evidence:** The adversarial worst-case search (target station right after a long blackout) found 19/27 configs firing LATE (worst +172 s). Root cause traced: the `DwellCountAssociator` uses an `arcs ≤ s_gps − 50` hysteresis (correct for mid-cruise GPS resync). But **at blackout entry**, if the rider has just passed a station, the −50 rule initializes the count to the station *behind* → the count stays one behind the entire blackout → never reaches target → fires late. This fix alone cut adversarial late-fires **19 → 8**.

**Change — `DwellCountAssociator.on_blackout_start(last_s_gps)`:** at blackout entry, snap the count to the **nearest** station to the last GPS fix (not the −50-behind station):
```
on_blackout_start(last_s_gps):
    nearest = argmin(|arcs − last_s_gps|)
    if arcs[nearest] ≤ last_s_gps + 200:   # within 200m-ahead tolerance
        k = max(k, nearest)                 # advance only, never rewind
    in_blackout = true
```
Keep the `−50` hysteresis for `on_gps_fix` (mid-cruise resync); this fix applies **only** to the blackout-entry transition. Same class as the A3 hysteresis fix — a boundary off-by-one.

### A6. Physical "13-min" watchdog ✅ SIM-VERIFIED — port with A5 (new, 2026-07-09)
**Evidence:** After A5, 8 configs still fired late on long multi-stop blackouts where the count lags. The user's real-world bound — **max inter-stop time in India ≈ 13 min (780 s)** — gives a deterministic backstop: if more than 780 s have elapsed since the last confirmed dwell or GPS fix, a station *must* have been passed (physically certain), so force-advance the count. **Verified scope (be precise):** A5 + physical-780 s watchdog holds **0/6 late on the explicit 13-min-segment worst-case test** (leads −133 s to −774 s — safe but can be very early). It does **NOT** achieve unconditional never-late: on the 27-config adversarial grid the physical-watchdog variant regressed one config back to +50 s late (the *learned-speed* watchdog reached 0/27 late but at the cost of 5/27 firing >3 min early), and on **cold-start-fully-underground** (no GPS ever) it leaves **1/6 late (+424 s)** — only the curvature anchor (R1, roadmap) closes that to 0/6. So A5+A6 are the ship-now never-late fixes for the *normal* case (GPS re-acquires at least once, corpus + multi-blackout + transfer all 0-to-1 late); the residual late-fire cases are fully-underground-long and long-blackout-wide-spacing, which need R1.

**Change — in the blackout tracking loop:**
```
if in_blackout and (t_now − t_last_count_advance) ≥ MAX_INTERSTOP_S (=780):
    advance count by 1; snap EKF to that station's arc; reset t_last_count_advance
```
**Caveat (see A7 / report §A4):** the physical-780 s watchdog guarantees never-late but on long-blackout + wide-spacing routes the honest-σ critical-fractile can still fire >3 min early. That residual is the anchor's job (roadmap R1), not a bug — the alarm is still SAFE (early), just not tight.

---

## Part B — Alarm fire rule

### B1. Critical-fractile fire rule for time modes ✅ SIM-VERIFIED — port first (cheapest high-value)
**Evidence:** In the robustness corpus, the *only* harmful behavior (waking the user **late** = missed stop) was a +61 s late fire in `time_metro` after-blackout. The critical-fractile rule converted it to −45 s early (safe). It bounds `P(wake late) ≤ ε` by construction.

**Change — `lib/services/tracking/alarm_controller.dart`** (time-mode fire decision, ~`:646-712`): instead of firing when the point-estimate ETA ≤ threshold, fire when the **pessimistic quantile** does:
```
fire  ⇔  ETA_median − k · ETA_sigma  ≤  requested_lead        (k = 2)
```
where `ETA_sigma` is derived from the EKF's `sigmaS`/`sigmaV` propagated through the ETA computation (a less-certain filter → wider `ETA_sigma` → fires *earlier*). This is a few lines around the existing `estimateEtaSecondsToMeters` call — you already expose `EkfPublicState.sigmaS`/`sigmaV`.

**Why it matters most:** it is the single change that makes the *time* modes safe, it is independent of the underground filter fixes, and it needs no new data. Port it even before A1.

---

## Part C — The web simulator rewire (fixes the buggy demo)

**Goal:** the dashboard panel must show the **real EKF**, not linear interpolation. The verified reference implementation is `wakepoint_ekf_demo.html` + `ekf_js.js` (this runs the real filter, headless-validated: production alarm 229 s late, fixed +3 s on-time). The Dart panel should reproduce that behavior by feeding the replay engine's output into a real `EkfOrchestrator`.

### C1. Delete the fake interpolation — `lib/dashboard/ekf_replay_panel.dart:158-176`
**The current fake (confirmed on disk):**
```dart
ekfProgressMeters: tick.elapsedSeconds / route.durationSeconds * route.totalMeters,  // LINEAR INTERP — not EKF
ekfSigmaMeters: 50.0,        // TODO: Get from actual EKF   ← hardcoded
zuptActive: false,           // TODO: Get from EKF          ← hardcoded
ekfPosition: tick.gpsPosition, // TODO: Get from EKF        ← just echoes GPS
```
This shows GPS relabeled as "EKF"; it structurally cannot display the underground failure or the fix.

### C2. Wire a real `EkfOrchestrator` into the panel
`EkfOrchestrator` (`lib/core/ekf/ekf_orchestrator.dart`) has the clean interface needed:
- `onImuSample(ImuSample{ax,ay,az,gx,gy,gz,timestamp})`
- `onGpsFixAuto(GpsFix{lat,lng,accuracyMeters,speedMps,timestamp})` / `onGpsUnavailable(Duration)`
- `publicState` getter → `EkfPublicState{s, v, sigmaS, sigmaV, biasA, mode, motion}`
- constructed `EkfOrchestrator(route: routeGeometry)`

The replay engine `ImuReplayEngineV2` already emits ground-truth IMU + GPS per tick. **The rewire:**
```dart
// in _EkfReplayPanelState: construct once when the route loads
_ekf = EkfOrchestrator(route: _engine.route!);

// in onTick(tick): feed the engine's emitted sensors into the REAL filter
_ekf.onImuSample(ImuSample(
  ax: tick.imu.ax, ay: tick.imu.ay, az: tick.imu.az,
  gx: tick.imu.gx, gy: tick.imu.gy, gz: tick.imu.gz,
  timestamp: tick.timestamp));
if (tick.gpsDroppedOut) {
  _ekf.onGpsUnavailable(Duration(milliseconds: 100));
} else if (tick.gpsPosition != null) {
  _ekf.onGpsFixAuto(GpsFix(
    lat: tick.gpsPosition!.latitude, lng: tick.gpsPosition!.longitude,
    accuracyMeters: tick.gpsAccuracy ?? 15.0, speedMps: tick.gpsSpeed ?? 0,
    timestamp: tick.timestamp));
}
final st = _ekf.publicState;  // the REAL filter state

// surface the REAL values (replaces the four fakes)
widget.onVisualizationUpdate?.call(EkfReplayVisualization(
  ekfProgressMeters: st.s,           // real EKF progress (was linear interp)
  ekfSigmaMeters: st.sigmaS,         // real uncertainty (was hardcoded 50)
  gpsProgressMeters: tick.gpsDroppedOut ? null : _routeProgressOf(tick.gpsPosition),
  gpsDroppedOut: tick.gpsDroppedOut,
  motionState: st.motion.name.toUpperCase(),
  zuptActive: st.motion == MotionState.stationary,  // real ZUPT state (was false)
  lastStationSnapped: tick.currentStation?.officialName,
  ekfPosition: _latLngAtProgress(st.s),  // real EKF position on polyline (was GPS echo)
  gpsPosition: tick.gpsDroppedOut ? null : tick.gpsPosition,
  // ... station markers unchanged
));
```
Add two small helpers: `_routeProgressOf(latlng)` (project a fix onto the polyline → arc metres) and `_latLngAtProgress(s)` (inverse: arc metres → LatLng on the polyline). `RouteGeometry` already has the polyline + `stationMeters` to build both.

### C3. Visualization cleanup (the "not clean" complaint)
Mirror the verified HTML demo's panel, which the user validated as the clean target:
1. **Plot the σ band** around the EKF track (`st.sigmaS`) — this is what makes "honest covariance" visible; production's band balloons, the fixed filter's stays tight.
2. **Show both a true/GPS reference and the EKF estimate** so divergence underground is visible (today only one relabeled line is drawn).
3. **Live counters**: ZUPT fires, velocity-fusion count, current mode (surface/degraded), position error.
4. **Alarm-fire marker** with lead-error label (on-time / late / early) using the critical-fractile rule from B1.
5. **Shade the GPS-blackout span** so the underground regime is unmistakable in a demo.

**Verification before merge:** run `flutter run -d chrome -t lib/main_unified_dashboard.dart`, replay the `capturedRealRoute` with `GpsDropoutMode.tunnelSimulation`, and confirm the EKF line diverges from GPS underground and the σ band grows — matching `wakepoint_ekf_demo.html`. (This cannot be verified in the analysis sandbox — Flutter is not available there — so it is gated on your local run.)

---

## Part D — Runtime & route-correctness gaps 🔧 AUDIT-IDENTIFIED (on-device, no sim)

These are the dominant real-world risks (see robustness report §5). They cannot be simulation-verified — they need on-device testing — but they are grounded in `file:line` evidence.

| # | Fix | File evidence | Priority |
|---|---|---|---|
| D1 | Request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; hold a partial `WAKE_LOCK` while tracking | no wakelock in `lib/` or `android/`; no exemption in `permission_service.dart` | **highest** — OEM killers are the #1 cause of dead alarm apps |
| D2 | Exact-alarm (`AlarmManager`) safety net computed from ETA; service auto-restart + `BOOT_COMPLETED` | `autoStart:false` (`trackingservice.dart:212,220`); `AlarmReceiver.kt` empty | high |
| D3 | Sustain tracking in the bg isolate instead of pausing on UI death | `heartbeat_monitor.dart:88-92` sets paused + stops | high |
| D4 | Add iOS `UIBackgroundModes: location` (+ audio for alarm) | absent in `ios/Runner/Info.plist` | high (iOS unusable without) |
| D5 | Cold-start underground: seed the filter from route start / nearest station when no GPS fix | EKF requires GPS init (`ekf_pipeline.dart:509,87`) | high — this is the *expected* metro entry |
| D6 | *(Optional)* Active-dismiss confirmation (tap-and-hold / motion) — NOT periodic re-alarms | one-shot latch (`alarm_controller.dart:228`) is **intentional** (no-nag decision); this only closes the reflexive-dismiss-while-asleep gap | low / optional |
| D7 | Wrong-direction detection: surface sustained reverse arc-motion instead of silently clamping | clamp at `ekf_pipeline.dart:204` | medium |
| D8 | Version/expiry-check the prefetched route | route = truth; reroute suppressed offline (`reroute_policy.dart:39`) | medium |

---

## Part E — Production wiring bug (highest-priority, 2026-07-09)

### E1. `onGpsUnavailable` is never called in production 🔧 AUDIT-IDENTIFIED — fix FIRST of the on-device items
**Evidence:** `EkfOrchestrator.onGpsUnavailable()` (`ekf_orchestrator.dart:246-273`) — the method that switches the filter to degraded mode and lets σ inflate — is invoked **only** from `ekf_test_controller.dart:666` (a test path). Production feeds GPS solely through `sensor_fusion.dart:132 updateGps()`, which fires on Position *arrival*. When GPS drops, no Position arrives, so **neither `onGpsFix` nor `onGpsUnavailable` runs.** Consequence: on a real metro descent the filter never enters degraded mode — it dead-reckons in "metro" mode with a silently-small σ (the `maxSigmaS` cap, pre-A1) and produces a confident-wrong position. **This nullifies every GPS-out fix above unless wired.**

**Change:** add a production no-fix watchdog — a timer (e.g. in `TrackingService` or the sensor-fusion loop) that, if no GPS Position has arrived for `noFixSeconds` (the `gps_degradation_detector.dart` threshold of 5 s exists but is dead code), calls `orchestrator.onGpsUnavailable()`. This is the single change that makes the entire GPS-out engine actually engage in production. **No sim can validate it (it is a wiring/lifecycle fix); validate on-device with a logged tunnel descent.**

---

## Part F — Roadmap (research, not ship-now)

### R1. Curvature anchor (the second anchor) 🔬 RESEARCH — resolves the bounded-early limit
**Evidence:** Built and tested this session (`wakepoint_curvature_anchor.py`). Extract yaw-rate by projecting gyro onto the gravity axis (tilt-compensated), bandpass 0.01–0.3 Hz, match against the route's known curvature. **As a standalone position driver it diverges (not robust). But as a desync detector it correlates r=0.98 with expected per-segment turning, and as a combined OR-trigger it takes cold-start-underground from 1/6 late to 0/6 late.** This is the fix for the one fundamental limit (never-late AND ≤3-min-early cannot both hold on long-blackout+wide-spacing routes without a real mid-blackout position observation). **Scope: a genuine build** — needs corpus-wide tuning (may over-fire early on ambiguous-curvature routes), better velocity input, and fusion-not-standalone integration. Highest-value roadmap item after the ship-now fixes. Do not claim it done.

---

## Summary — what to hand your other agent

**Do FIRST (wiring — makes everything else engage):** E1 (production no-fix watchdog → `onGpsUnavailable`). Without this, the GPS-out fixes are dead code in production.

**Do now (sim-verified, low risk):** B1 (critical-fractile), A1 (honest covariance, 2 lines), A2 (motion-gated ZUPT), A3 (dwell-count association), **A5 (blackout-entry count init), A6 (13-min watchdog)**, C1–C3 (simulator rewire to real EKF). Re-run the 445-test suite after A1–A3/A5/A6.

**Do after real ride #2:** A4 (learned-velocity fusion) — the keystone, but circularity-gated. Keep the OOD gate (`safe_vel_var`) so an out-of-distribution regressor self-downweights (fails safe).

**Do on-device (no sim possible, highest real-world impact):** D1–D8, starting with the battery-optimization exemption + wakelock (D1).

**Roadmap (research):** R1 (curvature anchor) — resolves the bounded-early limit on extreme routes; a genuine build, not ship-now.

The verified reference for the whole EKF is `ekf_js.js` (matches the Python `EkfFixed` to 0.3 m) and its Python origin `ekf_reference.py` / `wakepoint_step12.py` (A3+A5) / `wakepoint_step34.py` (A4). The GPS-out engine's full findings are in `WakePoint_GPSout_Handoff.md`; the curvature anchor in `wakepoint_curvature_anchor.py`.
