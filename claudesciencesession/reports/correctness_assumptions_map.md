# WakePoint — Correctness Assumptions & Failure-Handling Map

**Scope:** What breaks the position/alarm logic for a *sleeping commuter* (phone in pocket/bag, screen off, app backgrounded). Every claim cites real `file:line` from `/home/raed/Projects/WakePoint`. Absences are stated as findings.

## Executive summary

The tracker is a **1-D geometric progress filter on a KNOWN route**. Two structural assumptions dominate every failure below: (a) the prefetched route **is** the train's actual path, and (b) the EKF got at least one **GPS fix** to initialize. The station "count" is **not a running counter** — it is a geometric re-snap of the estimate `sEst` onto the nearest station within an uncertainty window (`station_association.dart:106-210`), gated by a ZUPT dwell. Nothing in the codebase detects a wrong train, a skipped/express station, an early termination, or a wrong-direction boarding at the metro-leg level. And the most dangerous background finding: when the foreground UI isolate is killed (routine under screen-off memory pressure), the heartbeat monitor **marks tracking PAUSED and stops monitoring** (`heartbeat_monitor.dart:88-92`).

---

## 1. Route assumptions — wrong / rerouted / skipped / terminated / wrong train

The filter clamps motion to the route; it never questions the route.

- **Wrong direction is silently clamped, not flagged.** On metro legs reverse motion is forbidden: `setAllowReverse(!isMetroLeg)` (`ekf_orchestrator.dart:288`), enforced at `ekf_pipeline.dart:204-205`. A user who boards the **opposite-direction** train moves backward along route arc-length; the filter simply pins `sEst` and reports no progress. **No wrong-direction event is emitted.** Grep for `wrong.?direction|opposite|backward` in `lib/` returns only this clamp and unrelated UI code.
- **No skipped/express/closed-station detection.** Grep `skip.?station|express|closed.?station|not.?stopping` → nothing in production logic (only a UI enum `rerouteSkipped` meaning "reroute skipped due to cooldown", `constraint_logger.dart:23-24`). An express train that skips the target station will pass it; the geometric snap only advances station index monotonically (`ekf_orchestrator.dart:450`) and will happily snap to a *later* station.
- **Deviation detection is LATERAL only** — distance off the route corridor (`deviation_config.dart:50` `apiRerouteThresholdMeters=150`, `reroute_policy.dart:37 onSustainedDeviation`). A rerouted train that leaves the corridor triggers reroute **only if online** (`reroute_policy.dart:39` `if (!_online)` skips). Underground/asleep = offline → **reroute suppressed**. Critically, a train on the **same line geometry** going wrong-way or skipping stops **never leaves the corridor**, so lateral deviation cannot catch it.
- **Early termination of the train** (train terminates short): no detection that the vehicle stopped permanently before the target. ZUPT will read "stopped" indefinitely; `sEst` freezes; the stop/time alarm simply never reaches threshold.

**Risk:** Sleeping user on a wrong/rerouted/express train is **never warned** and the alarm never fires. This is the single largest correctness gap.

---

## 2. Dwell → station association (phantom / missed dwell)

Snap logic (`station_association.dart:106-210`): requires `isMetroLeg && zuptConfirmed && dwell≥3s` (`dwellSeconds=3`, line 60), then finds stations within window `3·σ + adaptiveMargin` (line 117; margin 50–150m, line 74-82). Requires **exactly one** candidate unless degraded (line 143), then applies a post-snap confidence gate `σ≤30m` (≤60m degraded) and **monotonic index** (`ekf_orchestrator.dart:449-459`).

- **Phantom dwell (signal-failure stop between stations):** ZUPT confirms the stop. If `σ` is small, no station falls in the window → `NO_CANDIDATES_IN_WINDOW` (line 142) → correctly no false snap. **But** after long dead-reckoning `σ` inflates: at σ=100 the window is `3·100+100 = 400m` (line 78). A between-stations stop within 400m of a real station produces a **false forward snap**, which then resets `sEst` to that station's meters and corrupts progress.
- **Missed dwell (brief/uncertain stop):** dwell <3s or ZUPT not confirmed (platform vibration, phone jostle) → snap skipped. `sEst` keeps advancing on DR, so a *later* station may snap and the index jumps (e.g. 2→4). Each missed snap is a lost correction → `σ` grows unbounded → mode goes DEGRADED (`ekf_orchestrator.dart:511-517`, metro threshold 2000m). The "count" of confirmed snaps then **undercounts** stations actually passed.
- **The count can drift both ways:** snap index only moves monotonically forward (`ekf_orchestrator.dart:450`), so it can never *correct downward* if it over-snaps in a large window. There is no reconciliation against wall-clock or GPS re-acquisition to repair a bad index.

**Risk:** Stop-count alarm fires late (missed dwells) or early (phantom snap in inflated σ).

---

## 3. Cold start — user boards already underground, no GPS fix

**The EKF cannot initialize without GPS.** `_initializeFromGps` is the *only* path that sets `_initialized=true` (`ekf_pipeline.dart:509-518`), called from `onGpsFix` (line 267). IMU ticks are dropped while uninitialized: `if (!_initialized) { skip IMU }` (`ekf_pipeline.dart:87-88`). The orchestrator stays DEGRADED while `!_hasGpsFix` (`ekf_orchestrator.dart:489-492`).

- Pre-GPS the code only accumulates **static accelerometer bias** when stationary (`ekf_orchestrator.dart:709-725`) — this estimates bias, **not position**. There is **no route-anchored cold-start seeding** (e.g. "assume boarding at route start / nearest station"). Grep `cold.?start` → zero hits.

**Risk:** A user who descends underground, boards, and *never* had a fix on this journey gets **no dead-reckoning at all** — `sEst` never leaves its uninitialized state, no station snaps occur, stop-count and distance alarms never advance. For a metro app this is the *expected* entry condition, and it is unhandled.

---

## 4. Boarding mid-route (not at route origin)

- Route stop totals are computed per leg as `numStops + 1` over the **whole leg** (`stop_logic_engine.dart:258`); `initialStopsRemaining` is seeded from route metadata (`route_metadata.dart:38,75`), **not** from where the user actually boards.
- There is **no "nearest station to boarding point" index** — grep `boardIndex|boardingIndex|startStation|firstStation` → nothing. Initialization relies on the **first GPS fix** projecting `sEst` onto the route (`ekf_pipeline.dart:509`), which *implicitly* handles mid-route boarding **only if a fix is available at boarding**. Combined with §3, mid-route + underground boarding is doubly unhandled.

**Risk:** Stops-remaining/ETA computed against the full route rather than the user's actual boarding point can be off by the pre-boarding segment.

---

## 5. Alarm escalation / snooze / dismiss-then-resleep

- **The destination-alarm latch is one-shot per route key.** `_destinationAlarmFired` and the fired-index/leg sets are cleared **only** in one place (`alarm_controller.dart:228-232`, a reset on route change/session start). Once fired, `destinationAlarmFiredForKey` returns true forever for that key (`alarm_controller.dart:111-113`).
- **No snooze, no re-arm, no escalation exist.** Grep `snooze|re.?arm|escalat|second.?alarm|fall.?back` across `lib/` (excluding tests) → **zero** matches in alarm logic (only unrelated "fallback" strings).
- The alarm audio loops (`ReleaseMode.loop`, `alarm_player.dart:53`) with **no auto-stop timeout** — good (won't self-silence) — but there is **no logic to re-trigger** if the user dismisses and falls back asleep, nor any second-chance alarm.

**Risk:** If the sleeping user swipes the notification (or it fires while phone is buried and they don't rouse), the latch blocks any re-fire → **they miss the stop with no recovery.**

---

## 6. Very short trip (target < ~2 stops from boarding)

- Handled defensively at *setup*: `if (userThreshold >= minStopsOnAnyMetroLeg)` the stop-count threshold is **rejected** with a user-facing error (`stop_logic_engine.dart:272-281`).
- "Direct fire" when destination <200m (`alarm_evaluator.dart:89`) and start-too-close suppression <200m to avoid instant spam (`stop_logic_engine.dart:150`).

**Risk:** Lower — short trips are guarded at configuration time. But the <200m direct-fire depends on position accuracy; underground with no fix (§3), the 200m test never evaluates meaningfully.

---

## 7. Clock / timestamp / timezone

- **ETA is speed-based, not timetable-based:** `etaSeconds = remainingMeters / effectiveSpeed` (`eta_engine.dart:412,416`). So absolute timezone/DST is **not** a first-order risk (no scheduled-arrival wall-clock math). The dominant risk is **stale/wrong speed**: underground, `effectiveSpeed` comes from IMU-derived velocity; if it collapses toward 0, `etaSeconds→∞` and the **time alarm never fires**; if overestimated, ETA is too short and it fires early.
- **Mixed clock sources:** station-snap timestamps use raw `DateTime.now()` (`ekf_orchestrator.dart:464`) while alarm timing uses `AppClock().now()` (`alarm_controller.dart:265`). `AppClock` is a warp/simulation abstraction (`app_clock.dart:1-3,119`). A simulation/test warp flag is cross-isolate file-based (`test_mode_flag.dart:5-9`); if it leaked into production, snap and alarm clocks would **disagree**.

**Risk:** Time-before-stop alarm accuracy is only as good as the underground speed estimate; no independent wall-clock/timetable cross-check exists.

---

## Absent capabilities (consolidated — each absence is a finding)

1. **No wrong-train / wrong-direction alert** — reverse motion is clamped silently (`ekf_pipeline.dart:204`), never surfaced.
2. **No skipped/express/closed-station detection** — snap advances monotonically past a skipped target (`ekf_orchestrator.dart:450`).
3. **No early-train-termination detection** — frozen `sEst` = alarm just never fires.
4. **No underground cold-start seeding** — EKF requires a GPS fix to initialize (`ekf_pipeline.dart:509`, `87`); metro entry condition unhandled.
5. **No boarding-point anchoring** — stops/ETA seeded from full route, not boarding index (`route_metadata.dart:38`, `stop_logic_engine.dart:258`).
6. **No snooze / re-arm / escalation** — one-shot latch (`alarm_controller.dart:228`); dismiss-then-resleep is unrecoverable.
7. **Background-death degrades to PAUSE, not fallback.** Foreground-isolate death → heartbeat timeout → `setPaused(true)` + "tracking paused" notification + **`stop()` monitoring** (`heartbeat_monitor.dart:88-92`). A sleeping user gets a *paused* notification, not tracking. Background isolate also **cannot reliably play alarm audio** and delegates sound to the (possibly-dead) foreground isolate (`alarm_controller.dart:277-286`).
8. **No independent timetable/wall-clock cross-check** on ETA (§7).
9. **Reroute suppressed offline** (`reroute_policy.dart:39`) — exactly the underground condition.

**Manifest note:** app declares `FOREGROUND_SERVICE(_LOCATION|_MEDIA_PLAYBACK)`, `ACCESS_BACKGROUND_LOCATION` (`AndroidManifest.xml:6-10,53-54`) but **no** `WAKE_LOCK`, `SCHEDULE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED`, or battery-optimization-exemption request — so Doze/OEM battery killers can suspend the service with no exact-alarm safety net.
