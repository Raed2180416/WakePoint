## Alarm Fire Decision

**Role in the core promise:** This is the subsystem that decides *whether to scream right now*. Everything upstream — GPS, the EKF, snap-to-route, reachability physics, route parsing — exists only to feed two numbers into this decision: **how far along the route are we (progress in meters)** and **how uncertain is that** (σ). This subsystem turns those numbers, plus the user's chosen threshold ("wake me 2 stops before", "5 minutes before", "1 km before"), into exactly one irreversible act: firing the wake-up alarm. The core promise — *never late, never at the wrong place, even when GPS dies underground on a cheap phone in India* — lives or dies here. Every rule in these files is bent toward one asymmetry: **firing a little early is a minor annoyance; firing late means the rider misses their stop and never trusts the app again.** So the decision is deliberately biased early: it fires on the *critical fractile* (median − k·σ) rather than the median, and it layers a physics-based "worst-case reachable position" bound on top so that even a total GPS blackout cannot silently swallow the alarm.

**Files:**

| Path | What it does |
| --- | --- |
| `lib/services/alarm_evaluator.dart` | The pure state machine. `AlarmEvaluator.evaluateCoinciding(...)` takes progress + route geometry + σ + reachability bound and returns an `AlarmTrigger?` (fire) or `null` (don't). Also owns the ETA math (`estimateEtaSecondsToMeters`, `etaSigmaSeconds`). No side effects — deterministic, testable. |
| `lib/services/tracking/alarm_controller.dart` | The orchestrator. `AlarmController.checkAndTriggerAlarm(...)` is called every location tick. It maintains fire-state (which legs/destinations already fired), maintains the reachability anchor, runs the mode-specific destination checks (distance/time non-metro), calls the evaluator for the stops/metro path, applies suppression rules, and actually raises the notification. |
| `lib/services/tracking/notification_updater.dart` | The *non-alarm* notifications. Journey-progress notification ("Remaining: 3.2 km"), dashboard state broadcast, and the **G5 exact-alarm ETA backstop** (an OS-scheduled fallback wake in case the live pipeline dies). It never makes the primary fire decision. |
| `lib/config/fire_decision_config.dart` | The tunables: fractile multiplier `k=2.0`, σ clamp `300 m`, dead-reckon accuracy sentinel `9999 m`, approximate-location gate `500 m`, default gate `100 m`, dropout eval min interval `2 s`. |
| `lib/services/stop_logic_engine.dart` | Creation-time validation + UI helpers. `validateThreshold` / `validateThresholdAgainstMetroLegs` stop the user from choosing an impossible "N stops" value. `calculateRemainingStops` / `checkPreBoarding` are **legacy/dead** (no live callers). |

**Callers (who drives this subsystem):**
- `lib/services/trackingservice.dart` → `_alarmController.checkAndTriggerAlarm(...)` (line ~1349) on every processed position, and `_notificationUpdater.broadcastSimulationState / updateNotification` for the passive notifications.
- `lib/core/ekf/ekf_test_controller.dart` (line ~677) calls `AlarmEvaluator.evaluateCoinciding` directly — this is the offline replay harness (`sim-validation` branch) that proves fire behavior deterministically without a device.
- `lib/screens/homescreen.dart` (line ~880) calls `StopLogicEngine.validateThreshold*` at route-creation time.

---

### How it works, step by step

The whole thing runs once per location tick. A "tick" is either a real GPS fix or a synthesized **dead-reckon tick** (accuracy stamped `9999 m`, the `deadReckonAccuracySentinel`) generated while GPS is dead so the decision keeps running underground.

#### Phase A — `AlarmController.checkAndTriggerAlarm` (the orchestrator entry)

1. **Log + guard** (`alarm_controller.dart:354-386`). Emits `ALARM_CHECK_ENTRY`. Returns immediately if `trackingSessionActive == false`, or if `destination == null || alarmValue == null`. Nothing fires without a live session and a target.

2. **Maintain the reachability anchor** (`alarm_controller.dart:396-426`). This is the physics safety net.
   - `_reach.seedColdStart(tSeconds: now, sMeters: progress ?? 0)` — on the *very first* tick, plant an anchor at trip origin (progress 0 at start time). This closes the "cold start hole": if GPS never yields a single underground fix and the EKF never initializes, reachability still works from t=0.
   - Decide `isRealFix`: `accuracy.isFinite && accuracy > 0 && accuracy < 9999`. Only a **real** fix re-anchors (`_reach.onAcceptedFix`). A dead-reckon tick (accuracy 9999) is *refused* as an anchor — this is precondition (iii): the wall-clock "time since last true fix" must only reset on a genuine fix, never on a synthesized one, or the physics bound would silently shrink below reality and fire late.
   - Subtle detail (`alarm_controller.dart:402-410`): the anchor timestamp is the fix's **own acquisition time**, not `now`, guarded to be finite, not-future, and < 1 hour stale. A late-delivered fix (queued behind a wake) must not reset the clock too recently.

3. **Resolve the active route + events** (`alarm_controller.dart:434-478`). Look up `activeEntry` by key (fallback: first entry). Copy `routeEvents`. Compute `mainRouteLen` (`stepBoundsMeters.last` or `activeEntry.lengthMeters`). If no `'destination'` event exists, **synthesize one** at `mainRouteLen`. This guarantees there is always a destination target even for raw fixtures.

4. **BLOCK 1 — Distance mode, early path** (`alarm_controller.dart:493-633`). Runs *before* the evaluator, independent of route events.
   - If `progressMeters == null` (snap failed): fall back to **straight-line** `Geolocator.distanceBetween(current, destination)`; fire if `dist ≤ alarmValue·1000`.
   - Else compute `remainingMeters = totalMeters − progress` (totalMeters from registry length, or stepBounds.last, or dest event); fire if `remaining ≤ alarmValue·1000`.
   - On fire: `setDestinationAlarmFiredForKey(key, true)` → `triggerAlarmNotification(...)` → `onAlarmFired()` → `return`.

5. **Dispatch** (`alarm_controller.dart:640-660`): if `activeEvents.isNotEmpty && progress != null` → `_evaluateWithRoute` (the main path). Else if we have a destination and haven't fired → `_evaluateGeofence` (dumb straight-line fallback).

#### Phase B — `_evaluateWithRoute` (the main per-tick decision)

6. **Choose the speed source** (`alarm_controller.dart:677-687`). If `preferEkfSpeed` (EKF authoritative: metro leg / degraded / blackout) and `ekfSpeedMps` is finite, use the **dead-reckoned EKF velocity** — GPS speed is stale/zero underground. Otherwise use `smoothedSpeed`, then fall back to `lastSpeedMps` if smoothed ≤ 0.5 m/s.

7. **Time-alarm eligibility gate** (`alarm_controller.dart:727-738`). In time mode, if not a metro journey and not test mode and `timeAlarmEligible == false` (needs ~100 m traveled, 3 GPS samples, 30 s tracking), *skip*. Prevents an instant "you're arriving" the moment tracking starts. Metro journeys bypass this gate (they need per-leg time eval immediately).

8. **TIME MODE (non-metro), destination-only** (`alarm_controller.dart:743-828`). Fires once when ETA-to-destination ≤ N minutes.
   - `etaSeconds = smoothedETA` (authoritative engine ETA), else a speed-based fallback to route end via `estimateEtaSecondsToMeters`.
   - Compute `etaSigma` via `_etaSigmaSeconds` and fire on the **critical fractile**: `etaSeconds − k·etaSigma ≤ thresholdSeconds` (k = 2). This is the "fire early under uncertainty" rule.
   - On fire: mark destination fired, trigger, start the 200 ms poll timer.

9. **DISTANCE MODE (non-metro)** (`alarm_controller.dart:836-974`). Second, route-event-based distance check (redundant with BLOCK 1). `remaining = totalMeters − progress`; fire if `≤ alarmValue·1000`. Falls back to straight-line if there are no destination events. **No σ cushion and no reachability bound applied here** (see flaws).

10. **Metro-context detection** (`alarm_controller.dart:978-1009`). Walk every leg; set `isCurrentlyOnMetroLeg` if progress is inside a metro leg's `[legStart, legEnd]`. Also treat an **interchange walk between two metro legs** as metro context (so a platform-change walk doesn't spawn a spurious "prepare to board" alarm).

11. **Current leg index** (`alarm_controller.dart:1011-1033`). Find the leg whose `[legStart, legEnd]` contains progress. Overshoot → last leg; undershoot → leg 0. `isFinalLeg = (currentLegIndex == legs.length − 1)`.

12. **Compute the reachability bound** (`alarm_controller.dart:1111-1158`). This is the never-late physics injection.
    - Build `RouteTopology` from the current leg's `stopMeters + legEndMeters` (the stations the train must physically pass). Resolve V_LINE from `leg.lineName` via the `VLineTable`.
    - `b = _reach.boundNow(nowSeconds, lineName, topology)` → worst-case reachable arc-progress `sMaxMeters = s0_hi + V_LINE·(t − t0)` (see `reachability.dart`).
    - Pass `reachBoundMeters = b.sMaxMeters` through **unless it is NaN**. A `+infinity` bound is the fire-*forcing* signal (T_max watchdog / corrupt-input fail-safe) and must reach the evaluator — filtering on `isFinite` would silently re-open the never-fire gap.
    - Telemetry: if `reachBound − progress > 50 m`, record `reachabilityActivated` (the physics bound is materially carrying the decision, i.e. a blackout where dead-reckoning fell behind).

13. **Call the evaluator** (`alarm_controller.dart:1162-1183`): `AlarmEvaluator.evaluateCoinciding(mode, userValue, progressMeters, allEvents, firedLegIds, transitLegs, currentLegIndex, isFinalLeg, stepBounds, stepDurations, currentSpeed, positionSigma=ekfSigmaS, velocitySigma=ekfSigmaV, fractileK=2.0, reachableProgressBoundMeters=reachBound)`.

14. **Suppression + fire** (`alarm_controller.dart:1193-1398`). If a trigger came back:
    - **Metro+time destination-only**: if `destinationOnlyMetroTimeEnabled()` and the trigger isn't a destination → suppress.
    - **Preboarding toggle** (stops mode only): if `preboardingEnabled()` is off and this is a `preBoarding` event → suppress. In time mode the preboarding toggle does *not* apply.
    - **Destination protection**: if destination already fired → suppress (and suppress *all* non-destination alarms thereafter). If it's a destination and not yet fired → set `shouldMarkDestinationFired`.
    - If not suppressed: pick a **title** by event type (`Wake Up!` / `Upcoming change` / `Upcoming transfer` / `Prepare to board`), build the **body**, call `onAlarmFired()`, then `triggerAlarmNotification(...)`.
    - **Fire-then-mark ordering** (`alarm_controller.dart:1364-1393`): the fired markers (`markLegFired`, `setDestinationAlarmFiredForKey`) are set **only after** the notification succeeds, inside the `try`. If notification throws, the `catch` rolls back (returns without marking) so the alarm retries next tick instead of being stuck ALREADY_FIRED. This is a deliberate never-*lose*-the-alarm guard.

#### Phase C — `AlarmEvaluator.evaluateCoinciding` (the pure state machine)

Inputs: `mode` (stops/time/distance), `userValue` (N), `progressMeters`, event list, `firedLegIds`, `transitLegs`, `currentLegIndex`, `isFinalLeg`, `positionSigmaMeters`, `velocitySigmaMps`, `fractileK`, `reachableProgressBoundMeters`. Output: `AlarmTrigger?`.

15. **Fallback (no transit-leg context)** (`alarm_evaluator.dart:87-143`). If `transitLegs` is empty or the index is out of range: take the last `destination` event, compute an **effective progress** = `Reachability.effectiveProgress(deadReckoned, sigmaCushion = k·clamp(σ,0,300), reachBound)`, then:
    - **Direct fire**: if `dest.meters − effProgress ≤ 200 m` → fire "Arriving at Destination".
    - **60%-remaining rule**: if `effProgress ≥ finalLegStart + 0.4·finalLegLen` → fire.

16. **Overshoot at leg boundary** (`alarm_evaluator.dart:152-168`). If progress jumped past the transfer boundary (within `boundaryEpsilon = 10 m`) into the next leg and the *previous* metro leg hasn't fired → evaluate the previous leg instead (so a fast arrival exactly at the switch point still fires the transfer alarm).

17. **Rule 1 — strict one alarm per leg** (`alarm_evaluator.dart:183-192`). If `firedLegIds.contains(leg.legId)` → return `null`. `leg.legId` is a topology-derived stable string (metro: `line_firstStop_lastStop`; walk-to-station: `Walk_startM_endM`; else geometry/meters).

18. **TIME MODE** (`alarm_evaluator.dart:205-640`). `thresholdSeconds = userValue·60`.
    - **Metro journey targeting**: on a non-metro leg *before* the next metro, target the **next metro boarding point** and emit a `preBoarding`. On metro/interchange context, don't emit preBoarding.
    - Compute `etaSeconds` via `estimateEtaSecondsToMeters`, `etaSigma` via `etaSigmaSeconds`.
    - Fire if `reachFire` (physics bound already reached the target) **OR** `etaSeconds − k·etaSigma ≤ thresholdSeconds`.
    - Message assembly picks transfer/mode-change/final-station labels from nearby events (within 75 m boundary epsilon), with a destination-beats-switch override if the destination is ≤ 300 m past the boundary.

19. **STOPS MODE — metro leg** (`alarm_evaluator.dart:646-1106`). "Fire when N stops remain to this leg's end."
    - `dedupedStopMeters` = leg's intermediate stops strictly inside `(legStart, legEnd)`.
    - **Zero-intermediate-stops** (`:715-835`): use the **60% distance rule** on effective progress — fire when `effectiveMetersInLeg ≥ 0.4·legLength`. Crucially this uses `Reachability.effectiveProgress` (not raw dead-reckoned meters), so an adjacent-station hop ridden through a blackout still fires early, not late.
    - **Normal case** (`:837-1106`): `sigmaCushion = k·clamp(σ,0,300)`; `effectiveProgressForStops = effectiveProgress(progress, sigmaCushion, reachBound)`. Count `passedIntermediate` = stops with `effectiveProgress ≥ stopMeter`. `remainingStopsToTarget = (dedupedStopMeters.length − passedIntermediate) + 1` (the +1 is the alighting station itself). **Fire if `remainingStopsToTarget ≤ thresholdN`.** Counting stops via the *upper* confidence bound means a stop is counted "reached" as soon as we *might* have passed it — the only safe direction.
    - Type resolution (destination vs transfer vs mode-change), label enrichment, and the Mumbai "Alight at X → Walk to Y" interchange messaging follow.

20. **STOPS MODE — non-metro leg (60% rule)** (`alarm_evaluator.dart:1107-1345`). Walk/Drive/Bus.
    - If in the **driven portion before the first metro**: threshold = `0.4 · drivenPortionEnd` against raw `progressMeters`, with a stable `Preboarding_0_<end>` id so it fires once for the whole driven portion.
    - Otherwise: fire when `metersInLeg ≥ 0.4·legLength`.
    - Final leg → "Arriving at Destination" (but **distance mode returns null here** — distance mode is honored only by the controller's N-km check, `:1209-1211`).
    - Non-final → `preBoarding` only if the next leg is metro (or driven-portion-before-first-metro); short (<500 m) metro-to-metro transfer walks are skipped.
    - **This path uses raw `progressMeters` / `metersInLeg`, not effective progress** (no σ cushion, no reachability). See flaws.

21. **ETA math** (`alarm_evaluator.dart:1359-1534`). `estimateEtaSecondsToMeters`: prefer speed-based `remaining/v` (v>0.5) with a ×1.20 safety buffer; if step bounds+durations exist and cover the domain, compute step-proportional ETA; hybrid = pick speed-buffered unless step ETA is within ×1.50 (cap pessimism). Falls back to 1.4 m/s walking speed. `etaSigmaSeconds`: `σ_eta² = (σ_s/v)² + (ETA·σ_v/v)²`, with σ_s clamped to 300 m; returns 0 (median firing) when speed/σ unusable.

---

### Key types & functions

| Type / function | Responsibility | Signature (abridged) |
| --- | --- | --- |
| `AlarmMode` (enum) | stops / time / distance | `enum AlarmMode { stops, time, distance }` |
| `AlarmEventType` | String constants: `destination`, `transfer`, `mode_change`, `final_station`, `preBoarding` | static const strings |
| `AlarmTrigger` | The "fire this" value object: event type, leg index/id, reason, message, remaining stops/meters | `AlarmTrigger({eventType, legId, reason, message, remainingStops, remainingMeters})` |
| `AlarmEvaluator.evaluateCoinciding` | **Pure fire decision.** Returns `AlarmTrigger?` | `static AlarmTrigger? evaluateCoinciding({mode, userValue, progressMeters, allEvents, firedLegIds, transitLegs, currentLegIndex, isFinalLeg, positionSigmaMeters, velocitySigmaMps, fractileK, reachableProgressBoundMeters, ...})` |
| `AlarmEvaluator.estimateEtaSecondsToMeters` | Hybrid speed/step ETA to a target meter | `static double(...)` |
| `AlarmEvaluator.etaSigmaSeconds` | First-order ETA std-dev | `static double(...)` |
| `AlarmContext` | Immutable bundle of everything the controller needs per tick (destination, mode, value, progress, legs, events, EKF signals) | constructor with ~25 fields |
| `AlarmController.checkAndTriggerAlarm` | Per-tick orchestrator | `Future<void>({currentPosition, service, context, onAlarmFired})` |
| `AlarmController.triggerAlarmNotification` | Raise the alarm; **self-contained in background isolate** (G6) | `Future<void>({service, title, body, allowContinueTracking, isBackgroundIsolate, isTestMode, debugReason})` |
| `AlarmController.startAlarmStopPollTimer` | 200 ms poll for notification action buttons (Stop / Mute / End) | `void({trackingSessionActive})` |
| `AlarmController._etaSigmaSeconds` | Duplicate of the evaluator's σ_eta used in the non-metro time path | `static double(...)` |
| `ReachabilityTracker` (consumed) | Holds the anchor, resets only on real fixes, computes `boundNow` | from `reachability.dart` |
| `NotificationUpdater.broadcastSimulationState` | Push dashboard debug state; fire-and-forget re-arm of the ETA backstop | `void({alarmFired, remainingStops, context, extraDebugInfo})` |
| `NotificationUpdater._maybeRearmEtaBackstop` | **G5**: schedule/cancel an OS exact-alarm backstop at `ETA − lead` | `Future<void>(context, alarmFired)` |
| `NotificationUpdater.updateNotification` | Journey-progress notification; "No GPS (tunnel) — estimating from motion" when `gpsEstimating` | `void({registry, destination, gpsEstimating, ...})` |
| `StopLogicEngine.validateThreshold` | Creation-time: N must leave ≥1 stop on the first segment | returns `({isValid, errorMessage, maxStops})` |
| `StopLogicEngine.validateThresholdAgainstMetroLegs` | Creation-time: N < min(stops) across all metro legs | returns `({isValid, errorMessage, minMetroStops})` |
| `FireDecisionConfig` | Central tunables (see below) | static consts |

**FireDecisionConfig constants (`fire_decision_config.dart`):** `fractileK = 2.0` (fire at median − 2σ ≈ 97.7% one-sided), `dropoutEvalMinInterval = 2 s`, `deadReckonAccuracySentinel = 9999 m`, `approximateLocationAccuracyMeters = 500 m` (coarse Android location treated as no-GPS), `defaultAccuracyGateMeters = 100 m`, `maxFractileSigmaMeters = 300 m` (clamps only the σ *fed into firing*, not the EKF's reported σ).

---

### Design decisions (the WHY)

1. **Fire on the critical fractile (median − k·σ), not the median.** *Decision:* `shouldFire` compares `etaSeconds − k·etaSigma` (time) or an inflated `effectiveProgress` (stops) against the threshold, with `k = 2`. *Why:* uncertainty is symmetric but the *cost* is not. If our best guess of position/ETA is right on the threshold, there's ~50% chance we're actually already past it. Firing at −2σ means we only fire when we're ~97.7% confident we haven't overshot. *Trade-off:* systematically earlier alarms. On a healthy-GPS surface trip σ is tiny so the shift is negligible; underground it can be a stop or two early. *Alternative rejected:* firing at the median (would be late half the time — product death). *Flaw:* k is a single global constant; it can't distinguish "annoying-early on a short bus hop" from "necessary-early on a long metro blackout."

2. **σ used for firing is clamped to 300 m (`maxFractileSigmaMeters`).** *Decision:* clamp the position σ before multiplying by k. *Why:* the EKF is allowed to honestly report σ growing to ~3 km on a long fully-underground segment. Unclamped, `k·σ = 6 km` of cushion would count a dozen stops as "reached" and fire absurdly early, defeating the alarm and eroding trust. Clamping to ~1–2 inter-station spacings keeps it "early but tight." *Trade-off:* on a *very* long blackout the statistical cushion alone (≤ 600 m) can fall behind true progress and would fire late — **this is deliberately covered by the unclamped reachability bound** via `max()`. *Flaw:* the two mechanisms only compose correctly if the reachability anchor and V_LINE are sound; if reachability is degraded, the clamp becomes a late-fire hazard on long blackouts.

3. **Layer a physics "worst-case reachable position" bound on top (`effectiveProgress = max(deadReckoned+cushion, reachBound)`).** *Decision:* inject `reachableProgressBoundMeters` and take the more-progressed of the statistical and physics upper bounds. *Why:* dead reckoning on a cheap phone is unreliable, so instead of trusting it we compute `s_max = s0_hi + V_LINE·Δt` — the furthest the train *could physically* be. Firing when `s_max` reaches the stop is late-proof by physics: if we haven't fired, the train provably hasn't arrived. *Trade-off:* the free-run bound races ahead at V_LINE (28 m/s default), so long blackouts fire early. *Alternative rejected:* dead-reckoning position through the tunnel (proven unreliable). *Flaw:* depends on three preconditions (real anchor, V_LINE ≥ true max, honest wall-clock Δt); a misnamed line that resolves to the 28 m/s default on an RRTS line (true ~53 m/s) violates precondition (ii) and *can fire late*.

4. **Strict "one alarm per leg" via `firedLegIds` (string set).** *Decision:* refuse to fire if `leg.legId` is already in the fired set. *Why:* prevents re-screaming every tick once a leg's condition is met. *Trade-off:* correctness hinges entirely on `legId` stability. *Flaw:* `legId` for a metro leg is `line_firstStop_lastStop` (from `stopNames`); if OSM re-enhancement changes the first/last stop name mid-journey, the id changes and the leg could re-fire or (if it changes the other way) never fire. Walk legs are keyed on rounded meters to dodge this, but metro legs are not.

5. **Fire-then-mark ordering with rollback on notification failure.** *Decision:* set `markLegFired` / `setDestinationAlarmFiredForKey` only *inside* the `try`, after `triggerAlarmNotification` returns; the `catch` returns without marking. *Why:* if the notification plugin throws, we must not record the alarm as "fired" — otherwise it's permanently suppressed and the rider is never woken. *Trade-off:* a partially-shown notification that later throws could re-fire next tick (a double alarm). *Judgment:* a double alarm is annoying; a swallowed alarm is fatal — correct call.

6. **Background isolate raises the alarm self-contained (G6).** *Decision:* in the background isolate, call `NotificationService().showWakeUpAlarm(playSound: true)` directly rather than delegating to the UI isolate via `service.invoke('triggerAlarm')`. *Why:* at wake time the app is usually swiped away and the UI isolate is dead; delegating would drop the alarm. *Trade-off:* duplicates the plugin-invocation logic across isolates. *Flaw:* if the direct raise *throws*, the `catch` falls back to `service.invoke(..., playSound: false)` — but a dead UI isolate ignores it, yielding a **silent, sound-less failure** with only a log line. No retry, no OS-level fallback in this path (the G5 backstop is a separate mechanism).

7. **Reachability anchor only moves on real fixes (accuracy < 9999 sentinel).** *Decision:* dead-reckon ticks are stamped `9999 m` and refused as anchors; the anchor timestamp is the fix's own acquisition time. *Why:* precondition (iii) — Δt must be honest wall-clock since the last *true* fix. If a synthesized tick reset the clock, `s_max` would stop growing and the alarm could sleep through the whole blackout. *Trade-off:* couples this subsystem to the exact sentinel value and to accurate `Position.timestamp`. *Flaw:* if any upstream code forgets to stamp 9999 on a synthesized position, it silently re-anchors and breaks the guarantee — a fragile cross-module contract encoded as a magic number.

8. **`dwellMinSeconds = 0` in the controller's `ReachabilityConfig` — topology stop-cap disabled.** *Decision:* construct `ReachabilityTracker(config: ReachabilityConfig(dwellMinSeconds: 0.0))`, and `hardTMaxSeconds` left null. *Why:* the stop-count cap (which tightens `s_max` by making the train "pay" dwell time at each station) is only *safe* on a confirmed all-stops service; assuming dwell on an express/skip-stop train would push the bound below reality and fire late. So the "real UX lever" for tightening early-firing is switched off pending per-line opt-in. *Trade-off:* every long blackout fires on the loose free-run bound → noticeably early. *Flaw:* the tightening machinery exists but ships inert; and with no `hardTMaxSeconds`, a finite-but-wrong anchor won't trip a watchdog (only a non-finite anchor forces `+inf`).

9. **Two firing philosophies: geometry for stops, ETA for time, remaining-distance for distance.** *Decision:* stops mode counts passed stop-meters; time mode compares ETA; distance mode compares remaining meters. *Why:* they map directly to what the user asked for. *Trade-off:* three parallel code paths with subtly different protections — stops/metro gets the full `effectiveProgress` (σ + reachability); non-metro time gets σ but *no* reachability; distance mode gets *neither*. *Flaw:* protection is inconsistent across modes (see Gaps).

10. **Distance mode is evaluated twice per tick (BLOCK 1 in the controller + the block in `_evaluateWithRoute`).** *Decision:* an early route-independent check plus a later route-event check. *Why:* BLOCK 1 fires even when route events/snapping are missing (straight-line fallback); the later block prefers polyline-domain totals. *Trade-off:* redundant computation and two slightly different `totalMeters` sources that could disagree. *Flaw:* code duplication; a future edit to one path silently diverges from the other.

11. **"N stops prior" counts the alighting station itself (`remainingStopsToTarget = remainingIntermediate + 1`).** *Decision:* the target station counts as one of the N. *Why:* matches rider intuition ("2 stops before DN Nagar" = fire when DN Nagar is 2 away, inclusive). *Trade-off:* if the user picks N ≥ (intermediate+1), it fires at leg start. *Mitigation:* `validateThresholdAgainstMetroLegs` blocks `N ≥ min(stops)` at creation time. *Flaw:* that validation lives in a different file and is only enforced in the UI (`homescreen.dart`); a route created by another path, or a leg whose stop count shrinks after OSM enhancement, can still cause an immediate fire.

12. **G5 ETA backstop uses a fixed 60 s lead for stops/distance modes.** *Decision:* in `_maybeRearmEtaBackstop`, time mode uses `value·60`, but stops/distance use a hardcoded 60 s before raw ETA. *Why:* stops/distance don't map cleanly to an OS-schedulable "minutes before arrival," so a conservative floor guarantees *some* wake even if the live pipeline dies. *Trade-off:* the backstop doesn't honor the user's actual N-stops/N-km, so it fires at a different (usually later) point than the real alarm. *Judgment:* acceptable — it's a belt-and-suspenders last resort, and it's canceled once the real alarm fires (`:179`). *Flaw:* for a large distance threshold (e.g. 5 km) the real alarm fires long before the 60 s-to-arrival backstop, making the backstop effectively useless for that mode.

13. **Loud `print()` debug on the hot path.** *Decision:* `print('LEG_CHECK...')`, `print('ALREADY_FIRED...')`, `TIME_ETA_DEBUG`, and the `ETA_CALC*` prints run on **every tick**, ungated by `kDebugMode` (only the Mumbai box at `:914` is gated). *Why:* these were added during the hard debugging of the Mumbai/Nallur cases. *Trade-off:* on a cheap Android phone in the background, per-tick stdout logging is battery and latency drain and floods logcat. *Flaw:* directly at odds with the "cheap phone" clause of the core promise; should be routed through `alarmLog`/gated. (Contrast: G26 already removed per-tick *file* I/O — the `print`s are the remaining leak.)

14. **Suppression cascade: destination fired ⇒ suppress everything.** *Decision:* once the destination alarm fires, all subsequent triggers are suppressed (`:1258-1266`). *Why:* the journey is over; no more transfer/preboarding noise. *Trade-off:* if the destination alarm fires *early* (by design) and the rider chooses "continue tracking," later legitimate alarms are gone. *Flaw:* couples "destination reached" to "journey ended," which isn't always true for multi-destination or continue-tracking flows.

15. **`stopCountConfidence` (G16) is produced but never consumed here.** *Decision:* `transfer_utils` marks a leg `stopCountConfidence = 0.5` when OSM and Google disagree, intending downstream logic to "prefer firing early." *Why (intended):* a low-confidence stop count should widen the safety margin. *Flaw:* **no code in the evaluator or controller reads `stopCountConfidence`** — the signal is computed, serialized, and dropped. Low-confidence legs get the same firing margin as high-confidence ones, silently.

---

### Invariants (what must always hold)

- **Never fire late** is the cardinal invariant: for every mode, the value compared against the threshold is an *upper* bound on true progress / a *lower* bound on true ETA (via `effectiveProgress` and `median − k·σ`).
- **One alarm per leg**: a given `leg.legId` fires at most once per session (`firedLegIds`).
- **Destination is terminal**: after the destination alarm fires for a key, no further alarm fires for that key.
- **Fired markers are set only after a successful notification** — a notification failure never permanently suppresses an alarm.
- **The reachability anchor advances only on real fixes** (accuracy < 9999) and never moves backward in time (`onAcceptedFix` monotonic guard).
- **`effectiveProgress` is monotonic in each input** and never returns a value *below* dead-reckoned progress (it's a `max`), so adding the cushion/bound can only make the alarm earlier, never later.
- **A `+infinity` reachability bound always forces a fire** (T_max watchdog / corrupt input) and must never be filtered out before reaching the evaluator.
- **`k = 2` and the 300 m σ clamp** are the only knobs converting uncertainty into earliness; both are global constants.

---

### Interfaces (consumes / exposes)

**Consumes:**
- **EKF / dead-reckoning subsystem** → `ekfSpeedMps`, `ekfSigmaS`, `ekfSigmaV`, `preferEkfSpeed` (via `AlarmContext`). These are the σ that drive the fractile.
- **Reachability core** (`lib/core/reachability/reachability.dart`) → `ReachabilityTracker`, `RouteTopology`, `VLineTable`, `Reachability.effectiveProgress`. The never-late physics.
- **Snap-to-route / route progress** → `progressMeters`, `SnapResult`, `stepBoundsMeters`, `stepDurationsSeconds`.
- **Route parsing** (`transfer_utils.dart`) → `TransitLegStops` (leg geometry, `stopMeters`, `isMetro`, `legId`, `numStops`, `stopCountConfidence`) and `RouteEventBoundary` (transfer/mode-change/preboarding labels).
- **RouteRegistry** → active `RouteEntry` (length, destination name).
- **TrackingStateStore** → user toggles: `preboardingEnabled`, `destinationOnlyMetroTimeEnabled`, mute state.
- **AppClock** → testable `now()`.
- **TelemetryService** → `reachabilityActivated` funnel event.

**Exposes:**
- **NotificationService** ← the actual wake-up alarm (`showWakeUpAlarm`), journey-progress notification, and the G5 exact-alarm backstop (`scheduleEtaBackstop` / `cancelEtaBackstop`).
- **AlarmPlayer / Vibration** ← sound + haptics (via NotificationService, and `AlarmPlayer.stop()` on reset).
- **LocationManager** ← dashboard `broadcastState` / `broadcastRoute`.
- **TrackingService** ← `onDestinationAlarmFired` callback (blocks route switching once destination fired), `checkAndTriggerAlarm`, `startAlarmStopPollTimer` action handling.
- **Replay harness** (`ekf_test_controller.dart`) ← `AlarmEvaluator.evaluateCoinciding` called directly for deterministic proof.

---

### Gaps & flaws vs the core promise (brutally honest)

1. **[HIGH — never-late hole] Non-metro TIME and DISTANCE destination alarms have no reachability protection.** The `reachBound` is computed at `alarm_controller.dart:1111` and passed *only* to `evaluateCoinciding`. The non-metro time block (`:743-828`) uses `smoothedETA` with a σ cushion but **no physics bound**; the distance block (`:836-974`) uses raw `progressMeters` with **neither σ nor reachability**. If GPS dies on a surface leg (urban canyon, dense Indian city) so that `smoothedETA`/`progressMeters` freeze, these destination alarms can be **late or never fire**. The physics guarantee that protects the metro/stops path simply isn't wired into these two paths. Distance mode is common for driving/bus — this is a real exposure.

2. **[HIGH — never-late hole] The non-metro stops-mode 60% rule uses raw dead-reckoned progress.** In `evaluate` non-metro (`:1184`, `:1213`, `:1219`), firing is `metersInLeg ≥ 0.4·legLength` on raw progress — no `effectiveProgress`. A final **walking** destination in stops mode, or a preboarding approach, ridden through a GPS gap, fires on stalled progress → potentially late. The metro path was explicitly fixed to use effective progress (even for the zero-stop case at `:729`); the non-metro path was not.

3. **[MEDIUM — wrong place] Stop positions are uniformly interpolated unless OSM-enhanced.** `stopMeters` come from `j/(numStops+1)·legLength` (`transfer_utils.dart:996`). Real stations are not uniformly spaced, so "2 stops before" can fire at a geometrically wrong point when OSM enhancement is unavailable (coverage gaps outside Bengaluru/Mumbai). This attacks "never at the wrong place." The σ cushion partially hides it by firing early, but the *place* is still estimated.

4. **[MEDIUM] The entire cooldown-suppression subsystem is dead code.** `_cooldownSuppressed` / `_cooldownSuppressedByKey` are only ever *read* and *cleared* (`:232-258`); nothing ever writes a suppression timestamp, and `isLegCooldownSuppressed` has **zero callers**. It's inert machinery that reads as a safety feature but does nothing — a maintenance trap and a false sense of rate-limiting.

5. **[MEDIUM] `stopCountConfidence` (G16) is computed but never used in the fire decision.** `transfer_utils` sets `0.5` when OSM/Google stop counts diverge and documents that alarm logic "should prefer firing early," but no consumer exists in this subsystem. Low-confidence legs are treated identically to trusted ones — the intended extra safety margin is silently absent.

6. **[MEDIUM — cheap-phone] Per-tick `print()` logging on the hot path.** `LEG_CHECK`, `ALREADY_FIRED`, `TIME_ETA_DEBUG`, `ETA_CALC*` fire on every evaluation ungated (`alarm_evaluator.dart:176, 184, 280, 402, 1371…`). On a low-end Android in the background this is measurable battery/latency drain and logcat flooding — directly against the "cheap phone in India" clause.

7. **[MEDIUM — never-late precondition] V_LINE resolution is name-based and fragile.** Reachability's never-late guarantee needs `V_LINE ≥ true max speed`. It's resolved from `leg.lineName` via keyword matching (`looksRrts`/`looksExpress`). A misnamed or unlabeled RRTS/express line falls to the 28 m/s default, which is *below* its true speed → the physics bound grows too slowly → **late fire**. The guarantee is only as good as Google's line labeling.

8. **[MEDIUM] `legId` instability for metro legs.** Metro `legId = line_firstStop_lastStop` depends on `stopNames`. If OSM enhancement changes the endpoint names between ticks, one-alarm-per-leg can double-fire or, worse, mark the wrong leg fired and suppress a real alarm. Walk legs were hardened (meters-based id); metro legs were not.

9. **[LOW-MEDIUM] Silent failure if the background self-contained raise throws.** `triggerAlarmNotification` (`:321-333`) catches an exception and delegates to a dead UI isolate with `playSound: false`. No retry and no guarantee of sound — a swallowed-alarm path that only surfaces as a log line. (The G5 OS backstop may still cover it, but that's a separate, coarser mechanism.)

10. **[LOW] `dwellMinSeconds = 0` and `hardTMaxSeconds = null` ship the reachability tightening/watchdog levers disabled.** Correct for safety, but it means long blackouts fire *very* early (loose free-run bound) and there is no hard time-budget watchdog for a finite-but-corrupt anchor. Early is safe, but excessive earliness erodes trust — the exact failure mode the 300 m σ clamp was introduced to avoid.

11. **[LOW] Distance mode double-evaluation** (BLOCK 1 + `_evaluateWithRoute`) with two `totalMeters` sources risks silent divergence on future edits.

12. **[LOW] Dead/legacy `StopLogicEngine.calculateRemainingStops` and `checkPreBoarding`** have no callers; `checkPreBoarding` even has hardcoded thresholds annotated "assumed from test behavior." They're not on the live fire path but invite accidental reuse of guessed constants.

13. **[LOW] Global rate-limit (`_lastAlarmFiredAt`) is set but never enforced.** It's only exposed/broadcast; nothing throttles firing by it. Rate limiting is purely per-leg via `firedLegIds`, so distinct legs firing in rapid succession (short interchange walks) can stack alarms — a known, intentionally-accepted behavior per the `:1278` comment, but worth stating.
