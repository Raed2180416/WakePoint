## ETA Estimation

**Role in the core promise:** GeoWake must wake a rider *before* their stop, "never late, never at the wrong place." When the alarm mode is **time** ("wake me N minutes before I arrive"), the whole decision hinges on one number: *how many seconds until I reach the target?* ETA estimation produces that number. It also feeds the human-facing "X min remaining" text and the speed estimate that other subsystems reuse. Because a *too-large* ETA means the alarm fires *late* (product death) and a *too-small* ETA means it fires *early* (mild annoyance), the entire subsystem is deliberately biased to under-estimate time-to-arrival — but, as documented below, several of its safety cushions quietly collapse to zero exactly when GPS is worst (underground), which is why ETA is **not** trusted alone: the reachability physics bound (documented elsewhere) is layered on top as the real never-late backstop.

There are, importantly, **three separate pieces of ETA code that do overlapping jobs** and do not fully agree with each other:

1. `EtaEngine` (`lib/services/eta_engine.dart`) — the stateful, GPS-driven, route-matched engine that produces the *display* ETA and a smoothed speed. Its output (`smoothedETA`) is also the **first-choice** ETA for the non-metro time-mode destination alarm.
2. `EtaUtils` (`lib/services/eta_utils.dart`) — pure, stateless step-domain arithmetic used by the map UI and as a fallback.
3. `estimateEtaSecondsToMeters` + `etaSigmaSeconds` (in `lib/services/alarm_evaluator.dart`) — a *fourth, self-contained* ETA implementation that is the **safety-critical fire-decision ETA** for switchpoints, pre-boarding, and (as a fallback) the destination.

This document maps all three, in atomic detail, and is blunt about where they diverge.

---

**Files:**

| Path | What it does |
| --- | --- |
| `lib/services/eta_engine.dart` | Stateful ETA engine: map-matches GPS to the route polyline, smooths speed (EMA), detects stop/dwell, computes a hybrid physics/step ETA, and a first-order ETA uncertainty (σ_eta). Persists a little state to `SharedPreferences`. Produces the **display** ETA and the smoothed speed reused downstream. |
| `lib/services/eta_utils.dart` | Two **pure functions** over "step boundaries + step durations": `etaRemainingSeconds` (progress → route end) and `etaToTargetSeconds` (progress → an intermediate meter mark). No GPS, no state, no speed. Used by the map screen for its local ETA and as a fallback. |
| `lib/services/alarm_evaluator.dart` → `estimateEtaSecondsToMeters` | The **fire-decision ETA**: hybrid of speed-based ETA and step-duration ETA, with anti-optimism buffers and a domain-mismatch guard. Called by the evaluator for switchpoint/pre-boarding alarms and by the controller as a destination fallback. |
| `lib/services/alarm_evaluator.dart` → `etaSigmaSeconds` | First-order ETA standard deviation from EKF position/velocity σ. Converts uncertainty into the safety cushion `k·σ_eta` that is subtracted from the ETA before comparing to the threshold. |

**Consumers / plumbing (not owned here but essential to the story):**

| Path | Relevance |
| --- | --- |
| `lib/services/tracking/location_stream_handler.dart` (`_computeEta`, ~L328–383) | The **only** production caller of `EtaEngine.computeEta`. Stores `result.etaSeconds` → `_smoothedETA` and `result.vEst` → `_smoothedSpeed`. **Discards `sigmaEta`.** Never passes `remainingStopsOnMetro`. |
| `lib/services/trackingservice.dart` | Owns `_smoothedETA`, `_smoothedSpeed`, `_lastSpeedMps`, `_stepBoundsMeters`, `_stepDurationsSeconds`; pumps `_smoothedETA` onto `etaSecondsStream`; builds the `AlarmContext`. |
| `lib/services/tracking/alarm_context_builder.dart` | Packs `stepBoundsMeters`, `stepDurationsSeconds`, `smoothedSpeed`, `smoothedETA`, `lastSpeedMps`, `ekfSpeedMps`, `ekfSigmaS`, `ekfSigmaV` into the `AlarmContext` the evaluator reads. |
| `lib/services/tracking/alarm_controller.dart` | Chooses `currentSpeed`, calls `AlarmEvaluator.evaluateCoinciding(...)`, and (for non-metro time destination) calls `estimateEtaSecondsToMeters` + a **private duplicate** `_etaSigmaSeconds` (L1570) that is byte-for-byte the same as the evaluator's. |
| `lib/services/route_session_manager.dart` (~L341–382) | Builds `stepBoundsMeters` (cumulative meters at each Directions step boundary) and `stepDurationsSeconds` (each step's planned duration) from the Google Directions response. This is the *source* of the "plan." |
| `lib/config/fire_decision_config.dart` | `fractileK = 2.0`, `maxFractileSigmaMeters = 300.0` — the constants that turn σ into a fire cushion. |
| `lib/screens/maptracking.dart` (~L479–800) | Display path: prefers `etaSecondsStream`, else `EtaUtils.etaRemainingSeconds`, else a `remaining / speedEMA` fallback. Also re-implements the same 1.20/1.50 hybrid locally. |

---

**How it works, step by step:**

### A. `EtaEngine.computeEta` — the display-and-primary ETA (eta_engine.dart:352–565)

**Inputs:** `routeCoords` (the route polyline as `List<LatLng>`), `gps` (a `Position`), `isMetroMode`, optional `stepBoundsMeters`, `stepDurationsSeconds`, `totalRouteMeters`, and (never supplied in production) `remainingStopsOnMetro`.

**Step 1 — Map-match to the route (`matchToRoute`, L101–289).** The rider's `(lat,lng)` is projected onto the route polyline to find *where on the line they are* and *how far remains*.
- If a previous match exists (`lastSegmentIndex != null && lastSnappedPoint != null`), the search is **windowed** to ±50 segments around the last index (L122–124) — "approx 1–2 km." This makes the per-tick cost roughly O(1) on long routes instead of O(number-of-vertices).
- **Context-loss guard:** if the new point is >2000 m from the last snapped point (L133), it assumes the window is stale and does a **full-route search** instead.
- For each candidate segment `[i, i+1]`, `_projectPointOnSegment` (L85–98) computes the closest point. **Critically, this projection treats latitude/longitude as a flat Cartesian plane** (`dx = Δlon`, `dy = Δlat`, `t = dot/len²`, clamped to `[0,1]`). The *distances* it then compares are true geodesic (`Geolocator.distanceBetween`), but the *fraction along the segment* is computed in raw degree space.
- A "snap safety" skip (L161–174) discards segments whose start is more than `maxSnapDistance*20 = 2000 m` from the last snap — but only in full-search mode (`!usingWindow`).
- Nearest segment wins (`minDist`), recording `bestSegmentIndex` and `bestFraction` (fraction of that segment already passed, computed from geodesic sub-distances, L181–193).
- **Two fallbacks:** if windowed search's best is still >100 m off route (L199), it re-runs a full loop; if *nothing* matched (`bestSnapped == null`, L241), it falls back to nearest **vertex**.
- **Remaining distance** (L263–286) = `(1 − bestFraction)·(length of current segment)` + Σ(lengths of all later segments). This is a **forward-only sum from the snapped point to the polyline end.**
- Side effects: `lastSnappedPoint` and `lastSegmentIndex` are updated for next tick.
- **Output:** `(remainingMeters, snapped)`.

**Step 2 — Raw speed → smoothed speed (L369–370, `_updateSmoothedSpeed` L292–310).**
- `rawSpeed = gps.speed > 0 ? gps.speed : _estimateSpeedFromLast(gps)`. `_estimateSpeedFromLast` (L324–342) divides the geodesic distance between the last two fixes by their timestamp gap (dt floored at 0.001 s).
- Exponential moving average: `smoothed = 0.25·raw + 0.75·smoothed` (α = `speedAlpha = 0.25`). First sample seeds directly.
- The **smoothed** value is appended to `speedWindow` (kept to the last `speedWindowMax = 10`).
- `vEst = max(smoothed, 0)`.

**Step 3 — Stop/dwell detection (L372–387).** Disabled entirely in metro mode (a stop in a tunnel is a station, not traffic). Otherwise: if `rawSpeed < stopSpeedThreshold = 0.7 m/s`, arm `stoppedSince`; once stopped ≥ `stopTimeThresholdMs = 8000 ms`, add a flat `dwellAdd = defaultDwellSeconds = 25 s`. It is binary: 0 or 25 s, never scaled.

**Step 4 — Physics ETA (L389–418).** `effectiveSpeed = max(vEst, vMin=0.5)`. Three branches:
- **Metro scheduled model** (`isMetroMode && remainingStopsOnMetro > 0`, L393–404): `eta = remainingMeters / 9.2 + remainingStops·25`. Uses `metroScheduledSpeedMps = 9.2` (≈33 km/h) and `metroDwellTimePerStopSec = 25`. **This branch never runs in production** — no caller passes `remainingStopsOnMetro`.
- **Metro without stop info** (L405–413): if `effectiveSpeed > 2.5`, floor it to ≥5.0 m/s; `eta = remaining/eff + dwell`.
- **Non-metro** (L414–418): `eta = remaining / effectiveSpeed + dwell`.

**Step 5 — "Smart" hybrid step ETA (L420–533).** *This overrides the Step-4 number whenever step metadata is present and the current step can be located.* This is the key anti-optimism logic (solves "walking to the train makes the whole-trip ETA look absurdly short").
- `accumulatedProgress = max(0, totalRouteMeters − remainingMeters)`.
- Find `currentStepIndex` = first step whose cumulative bound ≥ `accumulatedProgress` (L432–438).
- `plannedRemainingSeconds` = the current step's planned duration scaled by the fraction of the *step* still ahead (L457–466).
- `speedBasedSeconds = distRemainingInStep / effectiveSpeed`.
- **Dynamic floor factor (L482–501):** normally the current step's time is allowed to beat the plan (rider genuinely moving faster), but never by an unbounded amount. A `floorFactor ∈ [0.60, 0.90]` is derived from the *worse* of (a) GPS-accuracy badness normalized over `[8, 30] m` and (b) speed noise `σ_v / 2.0`. Worse GPS / noisier speed ⇒ factor near 0.90 (barely allowed to beat plan); clean signal ⇒ 0.60 (may drop to 60% of plan). The factor only applies if `allowFasterThanPlan` (accuracy finite ≤30 m, ≥3 speed samples, effectiveSpeed > 1.0); otherwise `floorFactor = 1.0` (cannot beat plan at all).
- `timeForCurrentStep = max(speedBasedSeconds, plannedRemainingSeconds·floorFactor)`.
- Add the **raw planned durations** of all future steps (L520–528). No live adjustment.
- `etaSeconds = timeForCurrentStep + timeForFutureSteps + dwellAdd`.

**Step 6 — Uncertainty σ_eta (L535–548).** `sigmaP = max(gps.accuracy, 8 m)`; `sigmaV = _computeSigmaV()` = sample std-dev of `speedWindow` (or `1.5` if <2 samples). If `effectiveSpeed ≤ 0.1` ⇒ `σ_eta = 1e6` (near-infinite). Else `σ_eta = sqrt((sigmaP/v)² + (remaining·sigmaV/v²)²)`. **This value is returned but discarded by the production caller** (the handler keeps only `etaSeconds` and `vEst`).

**Step 7 — Persist & return (L550–564).** `saveState()` (throttled to every 15 s) writes only `smoothedSpeed` and `speedWindow`. Returns `(etaSeconds, remainingMeters, vEst = effectiveSpeed, sigmaEta, dwellAddedSeconds, snappedPoint)`.

### B. `EtaUtils` — pure step arithmetic (eta_utils.dart)

Stateless, GPS-free. Given `stepBoundariesMeters` (cumulative meters, ascending) and `stepDurationsSeconds` (same length):
- **`etaRemainingSeconds`** (L2–39): returns seconds from `progressMeters` to the route end. Finds the step containing progress (first boundary > progress), pro-rates the remainder of that step by distance, adds all later steps' full durations. Returns `null` on missing/mismatched arrays; `0.0` if progress ≥ last boundary.
- **`etaToTargetSeconds`** (L45–117): same idea but between two arbitrary meter marks `progressMeters → targetMeters` (clamped into `[0, total]`), summing partial start step + whole middle steps + partial end step. Returns `null` if metadata missing or result non-finite.

Both assume the **step domain and the progress domain are the same meter coordinate system** — an assumption the fire-decision code explicitly does *not* trust (see the domain-mismatch guard below).

### C. `estimateEtaSecondsToMeters` — the fire-decision ETA (alarm_evaluator.dart:1359–1534)

**Inputs:** `progressMeters`, `targetMeters`, `stepBoundsMeters`, `stepDurationsSeconds` (ints), optional `currentSpeedMps`.

1. `remainingMeters = clamp(target − progress, 0, ∞)`. If `≤ 0` ⇒ return `0.0` (already there).
2. **Speed ETA** (L1375–1379): `speedEta = remaining / v` **only if `v > 0.5 m/s`**, else `null`.
3. **Step ETA** (L1381–1482): only if step arrays are non-empty and equal length.
   - **Domain-mismatch guard (L1390–1397):** if `target` or `progress` exceeds the step total by > `50 m`, **ignore steps entirely** (the polyline-meter and step-meter coordinate systems disagree, and using steps would clamp to 0 and fire a ghost alarm). This is a real defensive patch, but its consequence underground is dangerous (see flaws).
   - Otherwise clamp target/progress into `[0, total]`; if `clampedTarget ≤ clampedProgress`, fall through to fallback.
   - Else sum partial start step + whole middle steps + partial end step (same math as `EtaUtils.etaToTargetSeconds`, re-implemented inline).
4. **Hybrid selection (L1494–1533):**
   - **Both speed & step available:** `speedEtaBuffered = speedEta·1.20` (dampen speed spikes); `stepCap = speedEtaBuffered·1.50` (cap pessimism). `chosen = stepEta ≤ buffered ? buffered : (stepEta ≤ cap ? stepEta : cap)`. So the answer is at least `1.2×` the raw speed ETA and at most `1.8×` it.
   - **Step only:** return `stepEta` raw (no cap).
   - **Speed only:** return `speedEta·1.20`.
   - **Neither:** `remaining / 1.4` — **treats the rider as walking at 1.4 m/s.**

### D. `etaSigmaSeconds` — the safety cushion (alarm_evaluator.dart:1538–1560)

First-order error propagation: `σ_eta² = (σ_S / v)² + (ETA·σ_V / v)²`, where `σ_S` is EKF position σ and `σ_V` is EKF velocity σ.
- If `ETA` non-finite ⇒ `0`. If `v` is not `> 0.5` ⇒ treat `v = 0` ⇒ **return `0`** ("degrades to median firing").
- `σ_S` is clamped to `maxFractileSigmaMeters = 300 m` before use (so honest EKF σ of kilometres cannot inflate the cushion to kilometres of early firing).
- Returns `sqrt(termS² + termV²)`.

### E. How ETA becomes a fire decision (alarm_evaluator.dart:259–399; alarm_controller.dart:774–796)

The evaluator computes, for a target (switchpoint / next-metro boarding / destination):
```
etaSeconds = estimateEtaSecondsToMeters(...)
etaSigma   = etaSigmaSeconds(etaSeconds, currentSpeedMps, ekfSigmaS, ekfSigmaV)
shouldFire = reachFire  OR  (etaSeconds − fractileK·etaSigma) <= thresholdSeconds
```
- `thresholdSeconds = userValue · 60` (the "N minutes" setting).
- `fractileK = 2.0`, so the fire test uses `ETA − 2σ` — the **lower** ~97.7% confidence bound on arrival time. Firing on the low bound means firing early rather than late.
- `reachFire` is the reachability physics bound (`reachableProgressBoundMeters >= targetMeters`): if the worst-case physics position has already reached the target, fire **regardless** of the ETA. This is the true never-late backstop when the ETA path degrades.
- `currentSpeed` (controller L677–687) is chosen: EKF speed if `preferEkfSpeed`, else `smoothedSpeed` (from `EtaEngine`), else `lastSpeedMps`.
- For the **non-metro time destination** alarm (controller L743–796) the *primary* ETA is `context.smoothedETA` (the `EtaEngine` number), with `estimateEtaSecondsToMeters` used only as a fallback when `smoothedETA` is null/non-finite.

---

**Key types & functions:**

| Symbol | Responsibility & signature |
| --- | --- |
| `EtaEngine.computeEta({routeCoords, gps, isMetroMode, stepBoundsMeters?, stepDurationsSeconds?, totalRouteMeters?, remainingStopsOnMetro?}) → ({etaSeconds, remainingMeters, vEst, sigmaEta, dwellAddedSeconds, snappedPoint})` | Master routine: map-match + smooth + dwell + hybrid ETA + σ. |
| `EtaEngine.matchToRoute(routeCoords, currentPoint) → ({remainingMeters, snapped})` | Windowed nearest-segment projection; forward remaining-distance sum. Mutates `lastSnappedPoint`, `lastSegmentIndex`. |
| `EtaEngine._projectPointOnSegment(point, segStart, segEnd) → LatLng` | Closest point on a segment, computed in **flat lat/lon space**. |
| `EtaEngine._updateSmoothedSpeed(raw) → double` | EMA α=0.25; maintains 10-sample window. |
| `EtaEngine._computeSigmaV() → double` | Sample std-dev of the (smoothed) speed window; `1.5` default. |
| `EtaEngine._estimateSpeedFromLast(gps) → double` | Fallback speed = Δdistance/Δtime between last two fixes. |
| `EtaEngine.loadState() / saveState({force}) / reset()` | Persist/restore/clear engine state. `saveState` throttled 15 s; only `smoothedSpeed` + `speedWindow` persisted. `reset()` clears most state but **not `lastSegmentIndex`/`lastSigma`**. |
| `EtaUtils.etaRemainingSeconds({progressMeters, stepBoundariesMeters, stepDurationsSeconds}) → double?` | Pure ETA to route end from step plan. |
| `EtaUtils.etaToTargetSeconds({progressMeters, targetMeters, stepBoundariesMeters, stepDurationsSeconds}) → double?` | Pure ETA between two meter marks. |
| `AlarmEvaluator.estimateEtaSecondsToMeters({progressMeters, targetMeters, stepBoundsMeters, stepDurationsSeconds, currentSpeedMps?}) → double` | Fire-decision hybrid ETA with anti-optimism buffers and domain guard. |
| `AlarmEvaluator.etaSigmaSeconds({etaSeconds, speedMps?, sigmaSMeters?, sigmaVMps?}) → double` | First-order ETA σ; `0` when `v ≤ 0.5`; `σ_S` clamped to 300 m. |

---

**Design decisions (the WHY):**

1. **Fire on `ETA − k·σ` with `k = 2`, not on the raw ETA.** *Why:* the median ETA fires late half the time; a transit alarm that fires late is worthless. Firing on the lower ~97.7% bound trades a slightly-early alarm (annoyance) for almost never being late (`fire_decision_config.dart:6–11`). *Trade-off / rejected:* a fixed time buffer (e.g. "always fire 60 s early") was implicitly rejected because it ignores how *uncertain* the estimate is — 2σ scales the cushion with actual noise. *Flaw:* the cushion `k·σ_eta` **collapses to exactly 0 whenever `v ≤ 0.5 m/s`** (`etaSigmaSeconds` returns 0), i.e. precisely when stopped/creeping underground with a stale speed. In that regime the ETA path fires at the *median* with zero margin — the never-late guarantee is then carried **entirely by the reachability bound**, not by ETA.

2. **Clamp the position σ used for firing to 300 m (`maxFractileSigmaMeters`).** *Why:* the EKF is allowed to grow σ_S honestly to kilometres during long underground segments; feeding an unclamped σ into `k·σ` would fire many stops early — so early the alarm "defeats itself and erodes trust" (config comment L32–41). Clamping to ~1–2 station spacings keeps firing both safe and *tight*. *Trade-off:* if the true position uncertainty really is >300 m, the cushion is under-sized and the ETA test *could* fire late — but that scenario is exactly what the reachability bound is meant to catch. *Flaw:* the "right" clamp value is a single hard-coded constant tuned for metro spacing; it is not adapted to inter-stop distance for the specific route.

3. **Hybrid speed/step ETA with `1.20×` buffer and `1.50×` cap (`estimateEtaSecondsToMeters`).** *Why:* pure speed-based ETA is jumpy and over-optimistic on GPS speed spikes; pure step-plan ETA is stale and, when simulation speeds are scaled up, absurdly pessimistic. The buffer damps speed spikes; the cap stops the stale plan from inflating the estimate beyond 1.5× the (buffered) live estimate. *Trade-off:* two magic multipliers tuned by feel, not derived. *Flaw:* when there is **no** usable speed (`v ≤ 0.5`), the cap logic is bypassed and **raw `stepEta` is returned** (L1514–1516) — an uncapped, purely-planned number that can be far from reality.

4. **The "smart" step ETA in `EtaEngine` uses a dynamic floor factor in [0.60, 0.90].** *Why:* it wants to let the ETA beat the plan when the rider is *credibly* faster, but only in proportion to how trustworthy the signal is (good GPS + steady speed ⇒ trust it more; noisy ⇒ barely). This directly fixes the "walking to the station makes trip ETA look tiny" bug. *Trade-off:* elaborate, hard to reason about, and **a second, different anti-optimism scheme** from the evaluator's 1.20/1.50 one. *Flaw / real divergence:* `EtaEngine.computeEta` (drives the display **and** the primary non-metro destination ETA) and `estimateEtaSecondsToMeters` (drives switchpoint/pre-boarding fire) are **two independent implementations of the same idea with different constants**, so the number the user *sees* can disagree with the number the alarm *fires on*.

5. **Map-match with a ±50-segment window and a 2 km context-loss reset.** *Why:* a naive nearest-segment scan is O(vertices) every GPS tick; on a long metro route that is wasteful. Windowing around the last match makes it effectively O(1). The 2 km jump check catches teleport-like GPS errors and forces a full re-search. *Trade-off:* the window can "trap" the match on the wrong nearby segment if the route folds back on itself within the window. *Flaw:* the code itself is admittedly messy — duplicated fallback loops and a comment "Duplicate loop logic or refactor?" (L203) — increasing the chance a future edit breaks one path but not the other.

6. **Project points onto segments in flat lat/lon space (`_projectPointOnSegment`).** *Why:* it's cheap and simple, and the *distances* it compares are still true geodesic, so the chosen segment is usually right. *Trade-off:* the *fraction along* a segment (hence the snapped point and remaining distance) is computed treating 1° longitude = 1° latitude, which at ~20°N India is off by ~6% (cos 20° ≈ 0.94). *Flaw:* for a "never at the wrong place" product this introduces a small, systematic along-track bias on diagonal segments; it is tiny per-segment but is the kind of thing that should use an equirectangular scaling of longitude by cos(lat).

7. **Binary 25 s dwell, added once after 8 s stopped, disabled in metro.** *Why:* a bus/car that stops in traffic will resume; adding a fixed dwell prevents the ETA from collapsing toward the stop. Metro stops are stations (already modelled by the plan), so dwell is disabled there. *Trade-off:* 25 s is a single guess; real dwell varies. *Flaw:* it does not scale with number of remaining stops or observed dwell, and it is added to `dwellAdd` which is then also added on top of the step-based ETA (L531) that *already* includes planned stop time — potential double-counting on non-metro transit.

8. **Persist only `smoothedSpeed` and `speedWindow`; throttle saves to 15 s.** *Why:* to survive the Android OS killing the foreground service mid-trip without hammering `SharedPreferences`. *Trade-off:* `lastSnappedPoint`, `lastSegmentIndex`, `stoppedSince`, `lastGps` are **not** persisted — after a restart the match does a full search (fine) but dwell state is forgotten and the first `_estimateSpeedFromLast` returns 0 (a cold-start speed dip). *Flaw:* `reset()` (L568–574) clears most fields but leaves `lastSegmentIndex` and `lastSigma` set, so a reset engine still holds a stale segment index (harmless today only because the windowing guard also requires `lastSnappedPoint`, which *is* cleared).

9. **Domain-mismatch guard: ignore steps if progress/target overshoot the step total by >50 m.** *Why:* the step meters (from Directions steps) and the progress meters (from polyline snapping) are two coordinate systems that can drift apart; when they do, the step math clamps to 0 and would fire a *ghost* alarm instantly. Detecting the mismatch and dropping steps is safer than a false immediate fire (L1386–1397). *Trade-off:* on mismatch the function loses the plan and falls back to speed-only (or, if stopped, to the **1.4 m/s walking fallback**). *Flaw:* underground on a metro leg with no live speed, a domain mismatch degrades the ETA to "remaining ÷ 1.4 m/s" — i.e. it models a metro rider as *walking*, producing an ETA ~6× too large and firing **very late** on the ETA path. Only the reachability bound prevents a missed alarm here.

10. **`EtaEngine` produces a σ_eta that the fire path never uses.** *Why (historical):* the engine was designed as a self-contained estimator with its own uncertainty; the fire decision was later re-anchored on EKF σ via `etaSigmaSeconds`. *Trade-off:* consistency — the fire path's σ is computed from EKF `ekfSigmaS/ekfSigmaV`, not from the engine's own speed-window σ. *Flaw:* dead computation and a latent trap: if anyone re-wires the fire decision to trust `EtaEngine.sigmaEta`, note that `_computeSigmaV` takes the std-dev of *already-smoothed* speeds, which **understates** true speed variance and would produce an over-tight (unsafe) cushion.

11. **The "science-backed" metro scheduled model (9.2 m/s + 25 s/stop) is never invoked.** *Why it exists:* GPS speed is useless in tunnels, so a scheduled model was written to estimate metro ETA from remaining stop count. *Flaw:* the sole production caller (`location_stream_handler._computeEta`) **does not pass `remainingStopsOnMetro`**, so the branch (L393–404) is dead. Live metro rides fall through to the "metro without stops" clamp and then to the step-based hybrid. For the app's headline scenario (underground metro in India), the purpose-built metro ETA model is effectively unused.

12. **Duplicate `_etaSigmaSeconds` in `alarm_controller.dart` (L1570).** *Why:* the controller needed the same σ math for its non-metro destination path. *Trade-off / flaw:* it is a **verbatim copy** of `AlarmEvaluator.etaSigmaSeconds`. Two copies of a safety-critical formula will eventually drift; a shared function should be used.

13. **Fallback speed 1.4 m/s (evaluator) vs 2.8 m/s (handler) vs 1.4 m/s (map).** *Why:* different fallbacks for "no route/speed/steps." *Flaw:* the inconsistency means the same "no signal" situation yields different ETAs depending on which code path is live — the evaluator is conservative (walking, longer ETA), the handler optimistic (`2.8 m/s`, shorter ETA). Shorter ETA in the display vs longer in the fire path is at least *safe-biased*, but it is unprincipled.

---

**Invariants:**

- `remainingMeters ≥ 0` always (clamped) in every ETA path.
- ETA comparisons that decide firing always use `ETA − k·σ_eta` (never the bare ETA), with `k = 2` — *except* when `v ≤ 0.5` where `σ_eta = 0` and it degenerates to the median.
- `σ_S` fed into the fire cushion is always clamped to `[0, 300] m`; the EKF's *reported* σ is not clamped (only the fire-decision copy).
- `estimateEtaSecondsToMeters` uses step ETA **only** when `stepBoundsMeters.isNotEmpty && stepBoundsMeters.length == stepDurationsSeconds.length` **and** neither progress nor target overshoots the step total by >50 m.
- `speedEta` exists only when `currentSpeedMps > 0.5`; below that the estimate is step-based or the 1.4 m/s walking fallback.
- `EtaEngine.speedWindow` holds at most 10 entries of *smoothed* speeds; `_computeSigmaV` needs ≥2 to return anything but the 1.5 default.
- The reachability bound (`reachFire`) can only ever *add* fires (fire earlier), never suppress one — it is OR-ed with the ETA test.

**Interfaces:**

- **Consumes from GPS/EKF subsystem:** `Position` (lat/lng, `speed`, `accuracy`, `timestamp`); EKF `ekfSpeedMps`, `ekfSigmaS`, `ekfSigmaV`, and the reachability `reachableProgressBoundMeters` (all via `AlarmContext`).
- **Consumes from Routing/Directions subsystem:** the route polyline (`routeCoords`), `stepBoundsMeters`, `stepDurationsSeconds`, `totalRouteMeters` — produced by `route_session_manager.dart` from the Directions response and passed through `trackingservice.dart` / `alarm_context_builder.dart`.
- **Exposes to Alarm-decision subsystem:** `estimateEtaSecondsToMeters` (the fire ETA) and `etaSigmaSeconds` (the cushion), used inside `AlarmEvaluator.evaluateCoinciding` and `AlarmController`.
- **Exposes to UI subsystem:** `EtaEngine.computeEta().etaSeconds` → `TrackingService.etaSecondsStream` → `maptracking.dart` "X min remaining"; and `EtaUtils.*` used directly by the map screen. Also `vEst` (smoothed speed) is reused as `smoothedSpeed` by the controller when EKF speed isn't preferred.

**Gaps & flaws vs the core promise:**

- **The ETA safety cushion vanishes exactly underground.** `etaSigmaSeconds` returns 0 when `v ≤ 0.5 m/s`, which is the normal state when a metro rider's GPS is dead and speed is stale. The ETA-based fire then has *no* margin. The promise is only kept because the **reachability bound is OR-ed in** — meaning ETA is not, by itself, a never-late mechanism. Anyone reading "we fire at ETA − 2σ" must understand σ is often 0 when it matters most.
- **Domain mismatch → walking-speed ETA underground.** When step and progress meter domains disagree (>50 m), and speed is unusable, the fire ETA becomes `remaining / 1.4 m/s`, modelling a train rider as a pedestrian and producing an ETA that fires the alarm *far too late* on the ETA path. Again survivable only via reachability.
- **The purpose-built metro ETA model is dead code.** `remainingStopsOnMetro` is never supplied, so the 9.2 m/s + 25 s/stop scheduled model never runs for the app's flagship underground scenario. Metro ETA in production is whatever the step-plan hybrid yields, which depends on GPS-derived progress that is itself unreliable in tunnels.
- **Four overlapping ETA implementations that disagree.** `EtaEngine.computeEta`, `EtaUtils`, `estimateEtaSecondsToMeters`, and the map screen's inline hybrid each compute ETA with different constants (0.60–0.90 floor factor vs 1.20/1.50 buffers; 1.4 vs 2.8 m/s fallbacks). Display ETA and fire ETA can differ, and the duplication is a standing correctness/maintenance risk (plus the byte-for-byte `_etaSigmaSeconds` copy).
- **Map-match can pick the wrong nearby segment on folded routes.** Nearest-segment snapping within a ±50-segment window has no along-track continuity constraint; a route that passes near itself (loop, out-and-back, adjacent platforms) can snap to the wrong branch and produce a large remaining-distance error → wrong ETA → wrong-place risk. The 2 km reset and window mitigate but do not eliminate it.
- **Flat-earth segment projection** introduces a small systematic along-track bias (~6% on diagonal segments at India's latitudes) in the snapped position and remaining distance.
- **Dwell double-counting risk on non-metro transit:** the flat 25 s dwell is added on top of a step-based ETA that already embeds planned stop time.
- **No live traffic correction of future steps.** Both hybrids sum *planned* future-step durations; a real delay (traffic, slow train) is not reflected until the rider is *in* that step, so a whole-trip ETA can read optimistically early for the tail of the journey (safe-biased for firing, but misleading in the UI and it shrinks the effective lead time the "N minutes before" setting is supposed to guarantee).
