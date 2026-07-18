## Deviation Detection & Rerouting

**Role in the core promise:** GeoWake must wake a rider before their stop — never late, never at the wrong place. Deviation detection is the subsystem that answers "is the rider still on the route we're tracking against?" and, if not, "should we fetch a new route, quietly switch to a cached alternative, or admit defeat and end tracking with an honest message?" It matters because a stale route silently breaks every downstream promise: the alarm distance/stops/ETA are all measured against a polyline the rider is no longer on. If the rider boards the wrong train, gets off early, or the driver takes a detour, this subsystem is the only thing that notices the geometry no longer matches reality. Critically, it must NOT over-react to GPS noise (a false reroute mid-tunnel could discard the correct route and leave the rider tracking nothing), and it must fail *loud* — if it cannot recover a valid route, it terminates tracking with a message rather than pretending everything is fine.

**Files:**

| Path | What it does |
| --- | --- |
| `lib/services/deviation_monitor.dart` | The live state machine. Consumes `(offsetMeters, speedMps)` samples, applies a speed-adaptive threshold with hysteresis and a "sustain" timer, and emits `DeviationState(offroute, sustained, …)` on a stream. This is the production deviation detector. |
| `lib/services/reroute_policy.dart` | The gatekeeper. Given a *sustained* deviation, decides whether an API reroute is actually allowed right now — blocks it if offline or inside a cooldown window — and emits `RerouteDecision(shouldReroute)`. |
| `lib/services/reroute_constraints.dart` | The validator. After a new route is fetched, checks that it still honours the rider's original alarm settings (transit mode present, enough stops, feasible time/distance, transfer budget). Returns `RerouteValidationResult` with a user-facing message on failure. |
| `lib/services/deviation_detection.dart` | **Legacy / dead in production.** Pure Haversine "closest point on polyline" + a fixed 600m (online) / 1500m (offline) threshold. Superseded by `DeviationMonitor` + `SnapToRouteEngine`. Only referenced by one test. |
| `lib/services/trackingservice.dart` (`_handleRerouteDecision`, ~line 1369) | The orchestrator. Turns a `RerouteDecision(true)` into a real action: guard checks → termination policy → fetch new directions → validate constraints → register new route, or terminate tracking. |
| `lib/services/route_session_manager.dart` (wiring, ~lines 909–1209) | The glue. Constructs the monitor/policy, ingests each position into them, and implements the 100m/150m offset **band logic** that decides ignore-vs-local-switch-vs-API-reroute. This is where the real decision thresholds live — not in `DeviationMonitor`. |
| `lib/services/tracking_termination_policy.dart` | The graceful-exit brain. Multi-signal (distance + duration + moving-away + failed reroutes) decision on when to give up and end tracking. Invoked from `_handleRerouteDecision`. |
| `lib/config/deviation_config.dart` | Central constants table. **Warning: partly aspirational** — several values here are NOT the ones actually wired (see flaws). |

---

**How it works, step by step (the atomic walkthrough):**

The pipeline is driven by one GPS fix at a time. Here is the exact call chain from a fix landing to a reroute firing.

**Stage 0 — a fix arrives.** `_checkAndTriggerAlarm(currentPosition, service)` (`trackingservice.dart:1250`) runs on every location update.
- It first classifies the fix: `isDeadReckoned = !accuracy.isFinite || accuracy >= 9000.0` (`:1281`). A dead-reckoned sample is a *synthesized* underground/GPS-blackout position produced by the EKF, flagged with sentinel accuracy ≥ 9000m.
- **Only real fixes feed deviation.** If `!isDeadReckoned`, it records `_lastProcessedPosition` / `_lastSpeedMps` and calls `_sessionManager.ingestPosition(currentPosition)` (`:1287–1294`). Dead-reckoned samples are deliberately excluded so a guessed tunnel position can never be mistaken for "the rider left the route."

**Stage 1 — offset computation & monitor ingest.** `RouteSessionManager.ingestPosition(position)` (`route_session_manager.dart:1194`):
1. `activeManager!.ingestPosition(latLng)` snaps the point onto the active route and (asynchronously) updates `lastActiveState`, which carries `offsetMeters` — the lateral distance from the route polyline.
2. `devMonitor!.ingest(offsetMeters: s.offsetMeters, speedMps: position.speed)` (`:1207`) where `s = lastActiveState`. **The offset is the perpendicular distance to the snapped route, not straight-line distance to the nearest vertex.**

**Stage 2 — the deviation state machine.** `DeviationMonitor.ingest(offsetMeters, speedMps)` (`deviation_monitor.dart:52`):
- Computes a *speed-adaptive* threshold: `T_high = base + k·speed`, `T_low = hysteresisRatio · T_high` (`SpeedThresholdModel`, `:32–33`). With the **defaults actually in force** (`base=15.0, k=1.5, hysteresisRatio=0.7`): at 0 m/s `T_high=15m, T_low=10.5m`; at 10 m/s (36 km/h) `T_high=30m, T_low=21m`.
- Hysteresis + sustain FSM:
  - If currently **on-route** and `offset > T_high` → flip to off-route, stamp `_deviatingSince = now`, `_sustained=false`, log `deviationDetected` (`:61–75`).
  - If currently **off-route** and `offset < T_low` → flip back on-route, clear timer, log `backOnRoute` (`:78–94`). The `T_high`/`T_low` gap prevents flapping when the rider hovers near the boundary.
  - If still off-route and `now − _deviatingSince ≥ sustainDuration` (default **5s**, `:48`, test mode 300ms) → set `_sustained=true` once, log `deviationSustained` (`:97–110`).
- Emits `DeviationState(offroute, sustained, offsetMeters, speedMps, at)` on the broadcast stream every ingest (`:114`).

**Stage 3 — band logic (the REAL thresholds).** `RouteSessionManager._setupDeviationListeners` (`route_session_manager.dart:1102`) listens to `devMonitor.stream`:
1. Forwards every `DeviationState` to `_deviationStateCtrl` (consumed by the termination policy — Stage 6).
2. Recomputes a fresh `off` by re-snapping `lastIngestedPosition` with `SnapToRouteEngine.snap(...)` (`:1118–1123`), falling back to `lastActiveState.offsetMeters`.
3. Branches on `ds.sustained` and `off`:
   - **Not sustained**: only acts if `100m ≤ off ≤ 150m` → `_attemptLocalRouteSwitch(off, sustained:false)` (`:1129`). Otherwise returns.
   - **Sustained**: `if (off < 100) return;` (ignore as noise, `:1136`); `if (off ≤ 150)` → `_attemptLocalRouteSwitch(off, sustained:true)` (`:1138`); `else` (`off > 150`) → `reroutePolicy?.onSustainedDeviation(at: ds.at)` (`:1143`).
- **Key consequence:** the `DeviationMonitor`'s own 15–30m threshold flags "offroute" early, but **nothing happens below 100m of offset.** The DeviationMonitor state is used only as a *gate/timer*; the effective action thresholds are 100m (any action) and 150m (API reroute). A rider 40m off route for 10s produces `sustained=true` but is silently ignored (`off < 100`).
- `_attemptLocalRouteSwitch` (`:1147`) tries to switch to a *cached* alternative route already in the registry, choosing the one whose re-snapped offset is lower by at least a `margin` (50m prod / 20m test). This is a free, offline, no-API recovery — used when e.g. two candidate metro lines were both fetched at start.

**Stage 4 — the reroute gate.** `ReroutePolicy.onSustainedDeviation(at)` (`reroute_policy.dart:37`):
- If `!_online` → log `rerouteSkipped(reason: offline)`, emit `RerouteDecision(false)` (`:39–52`). **No reroute is possible offline.**
- If cooldown active (`now − _lastRerouteAt < _cooldown`) → log `rerouteSkipped(reason: cooldown)`, emit `RerouteDecision(false)` (`:53–70`).
- Otherwise set `_lastRerouteAt = now`, log `rerouteTriggered`, emit `RerouteDecision(true)` (`:71–84`).
- Cooldown default is 20s (`:20`), overridden per battery tier by `PowerPolicy.rerouteCooldown` (20s / 25s / 30s as battery drops — `config/power_policy.dart:36,46,55`) via `_reroutePolicy!.setCooldown(...)` in `startLocationStream` (`trackingservice.dart:2250–2256`).

**Stage 5 — orchestration.** The `RerouteDecision` flows `reroutePolicy.stream → RouteSessionManager._rerouteCtrl → _sessionManager.rerouteStream`, and `TrackingService` subscribes (`trackingservice.dart:1650` in the background-start path, `:1895` in `_onStart`) calling `await _handleRerouteDecision(d)`.

`_handleRerouteDecision(decision)` (`trackingservice.dart:1369`) — the critical path:
1. `if (!decision.shouldReroute) return;` (`:1370`) — skipped/false decisions are no-ops here (they were already logged in Stage 4).
2. **Post-arrival suppression:** `if (_alarmController.anyDestinationAlarmFired) return;` (`:1378`). Once the wake alarm has fired the trip is over; a late deviation must not resurrect a finished session or fire a spurious post-arrival alarm.
3. **Reentrancy guard:** `if (_rerouteInFlight) return;` (`:1384`). Only one reroute at a time.
4. **State guards:** bail if `_destination`/`_alarmMode`/`_alarmValue` are null (`:1389`), or if `_lastProcessedPosition == null` (`:1397` — then `_terminationPolicy.onRerouteFailed()`).
5. Set `_rerouteInFlight = true` (`:1404`).
6. **Termination check first** (unless simulation): `_terminationPolicy.shouldTerminate(currentPosition, speedMps)` (`:1417`). If it says terminate → `_terminateTrackingWithMessage(...)` and return (`:1422–1432`). This catches "rider gave up / went the wrong way" before wasting an API call.
7. **Fetch new directions:** if `offlineCoord == null || offlineCoord.isOffline` → `onRerouteFailed()` and return (`:1436–1444`). Otherwise `offlineCoord.getRoute(origin: currentPosition, destination: _destination, isDistanceMode: _alarmMode != 'time', threshold: _alarmValue, transitMode: _transitMode, preferMetroEvenIfClosed: _transitMode, forceRefresh: true)` (`:1446`).
8. **Race re-check:** the fetch can take seconds; re-verify `_trackingSessionActive && !anyDestinationAlarmFired` before committing (`:1460–1464`) so a late route can't resurrect a stopped session.
9. **Validate:** build `RerouteConstraints(alarmMode, alarmValue, transitMode)` (`:1467`, note `maxTransfers` is left null) and call `constraints.validate(newDirections.directions)` (`:1473`).
   - **Invalid** → `onRerouteFailed()`; if `failedRerouteAttempts >= 3` → terminate with the validator's `userMessage` (`:1483`); else show a "Unable to find valid alternate route (attempt N/3)" notification and continue (`:1489–1499`).
   - **Valid** → `registerRouteFromDirections(..., activateRoute: true)` (`:1509`), then `_terminationPolicy.onRerouteSuccess()` (`:1519`), update the journey notification, done.
10. `catch` → `onRerouteFailed()`, terminate if `failedRerouteAttempts >= 3` (`:1538–1547`). `finally` → `_rerouteInFlight = false` (`:1549`).

**Stage 6 — parallel termination-signal path.** Independently of reroute, `_devStateForTerminationSub` (`trackingservice.dart:1658` / `:1903`) listens to `deviationStateStream` and feeds the termination policy edges: on `ds.offroute` rising edge → `_terminationPolicy.onDeviationStart(position, at)`; on falling edge → `onReturnToRoute()`. This runs the "started deviating at position X, time T" bookkeeping the termination rules need.

**Stage 7 — constraint validation internals.** `RerouteConstraints.validate(directions)` (`reroute_constraints.dart:54`) checks, in order, over `routes.first`:
1. **Transit compat** (`:57`): if `transitMode` and no leg has a step with `travel_mode == TRANSIT` and vehicle type in `{SUBWAY, HEAVY_RAIL, RAIL, METRO_RAIL, MONORAIL}` → invalid ("Alternate route has no metro service"). `_routeHasMetroLeg`, `:154`.
2. **Stops mode** (`:70`): total transit stops (summed via `TransferUtils.extractTransitLegStops`) must be > 0 and `≥ alarmValue`, else invalid.
3. **Time mode** (`:92`): total duration (sum of leg `duration.value` / 60) must be > 0 and `> alarmValue` minutes, else the alarm would fire immediately/never → invalid.
4. **Distance mode** (`:112`): total distance (sum of leg `distance.value` / 1000) must be > 0 and `> alarmValue` km, else invalid.
5. **Transfers** (`:133`): only if `maxTransfers != null && transitMode` — count TRANSIT steps − 1, invalid if over budget. **Dead in production** because `_handleRerouteDecision` never sets `maxTransfers`.
- Any thrown exception → invalid with generic "Unable to validate alternate route" (`:145`). Every failure carries both a developer `failureReason` and a rider-facing `userMessage`.

---

**Key types & functions:**

- `DeviationState` (`deviation_monitor.dart:6`) — immutable snapshot: `{bool offroute, bool sustained, double offsetMeters, double speedMps, DateTime at}`. The wire format between monitor and everything downstream.
- `SpeedThresholdModel` (`:21`) — `high(speed)=base+k·speed`, `low(speed)=hysteresisRatio·high(speed)`. Defaults `base=15, k=1.5, hysteresisRatio=0.7`.
- `DeviationMonitor` (`:36`) — `ingest({offsetMeters, speedMps, at})` drives the FSM; `stream` exposes `DeviationState`; `reset()` clears FSM; `dispose()` closes the stream. Holds `_offroute`, `_sustained`, `_deviatingSince`.
- `RerouteDecision` (`reroute_policy.dart:5`) — `{bool shouldReroute, DateTime at}`.
- `ReroutePolicy` (`:11`) — `onSustainedDeviation({at})` is the entry point; `setOnline(bool)`, `setCooldown(Duration)` mutate gating; `stream` exposes decisions. Holds `_lastRerouteAt`, `_online`, `_cooldown`.
- `RerouteConstraints` (`reroute_constraints.dart:31`) — `validate(Map directions) → RerouteValidationResult`. Fields: `alarmMode`, `alarmValue`, `transitMode`, `maxTransfers?`. Private helpers `_routeHasMetroLeg`, `_extractTotalStops`, `_getTotalDuration`, `_getTotalDistance`, `_countTransfers`.
- `RerouteValidationResult` (`:11`) — `{bool isValid, String? failureReason, String? userMessage}`, via `.valid()` / `.invalid(...)`.
- `TrackingTerminationPolicy` (`tracking_termination_policy.dart:63`) — `shouldTerminate({currentPosition, speedMps, at}) → TerminationDecision`; edge callbacks `onDeviationStart`, `onReturnToRoute`, `onRerouteFailed`, `onRerouteSuccess`; `isDeviating`, `failedRerouteAttempts` getters.
- `TrackingService._handleRerouteDecision(RerouteDecision)` (`trackingservice.dart:1369`) — the orchestrator described in Stage 5.
- **Legacy (dead):** `findClosestPointOnRoute`, `determineThreshold`, `isDeviationExceeded`, `calculateDistance`, `PointInfo` in `deviation_detection.dart`.

---

**Design decisions (the WHY):**

1. **Speed-adaptive threshold `T = base + k·speed` instead of a fixed distance.**
   *Why:* GPS error and "acceptable" lateral wander both grow with speed — a car at 100 km/h legitimately swings wider around a snapped centreline than a walker. A fixed 30m would false-trigger on a highway and miss a walker who's genuinely lost.
   *Trade-off:* Requires a trustworthy speed. If GPS speed is noisy/zero (stationary jitter), the threshold collapses to `base` and becomes twitchy.
   *Flaw:* `speedMps` here is the raw geolocator speed, not the EKF-smoothed speed, so it inherits GPS speed noise. The monitor's threshold is also largely moot because the 100m band gate (decision 4) dominates.

2. **Hysteresis (`T_low = 0.7·T_high`) + a 5s sustain timer before "sustained".**
   *Why:* Two independent anti-flap mechanisms. Hysteresis stops rapid on/off toggling when the rider hovers at the boundary; the sustain timer stops a single bad fix from ever escalating to a reroute. This directly protects the core promise: a spurious reroute could discard the correct route mid-tunnel.
   *Trade-off:* Adds latency — a genuine deviation isn't "sustained" for 5s, delaying recovery.
   *Flaw:* 5s is fine for driving but at metro speed (~15 m/s) the rider travels ~75m during the sustain window before anything escalates; combined with the 150m reroute floor, real recovery only begins well after the rider has clearly left.

3. **The real decision thresholds (100m / 150m) live in `route_session_manager.dart`, NOT in `DeviationMonitor`.**
   *Why:* The band structure encodes a recovery *strategy*, not just detection: <100m = noise (do nothing), 100–150m = try a free local switch to a cached alternative, >150m = spend an API call on a fresh route. Cheapest recovery first.
   *Trade-off:* Two separate notions of "deviation" (the monitor's ~15–30m and the band's 100m) that can confuse a maintainer. The monitor essentially only supplies the `sustained` timer.
   *Flaw:* **Dead sensitivity.** Because nothing acts below 100m, the monitor's carefully-tuned 15–30m threshold and its `deviationDetected`/`backOnRoute` logs fire constantly for offsets that will never cause an action — noise in the constraint log, and a false impression that detection is more sensitive than it is.

4. **Local cached-route switch before API reroute.**
   *Why:* If the app fetched multiple candidate routes at trip start (e.g. two metro lines), a rider who's actually on the *other* one can be recovered instantly, offline, with zero API cost — exactly the underground/cheap-data scenario the core promise targets.
   *Trade-off:* Only works if alternatives were pre-fetched; most trips have one route, so this band usually falls through.
   *Flaw:* The switch requires the candidate to be ≥50m closer; a rider midway between two near-parallel lines may satisfy neither the switch margin nor cleanly belong to either route.

5. **No reroute when offline; offline deviation counts as a failed attempt.**
   *Why:* Fetching a new route needs the network. Honest: the system can't invent a route it can't fetch.
   *Trade-off / Flaw:* This is a **direct hole in the core promise.** The promise explicitly includes "when GPS dies underground, in India" — precisely when the device is most likely offline. If the rider genuinely leaves the route while offline (gets off at the wrong station, no signal), there is *no* recovery: local switch may not apply, API reroute is blocked, and the only outcome is eventual termination. The mitigation is that underground the rider is usually still *on* the tracked line and the EKF carries progress — but a wrong-place exit offline is unhandled.

6. **`maxTransfers` is never passed, so transfer-count validation is dead.**
   *Why (inferred):* Simplicity — the UI never captured a transfer budget, so `_handleRerouteDecision` constructs `RerouteConstraints` without it.
   *Trade-off:* A reroute could hand the rider a 3-transfer itinerary when they'd tolerate one, and it will be accepted.
   *Flaw:* Untested code path shipped as if live; the constraint exists but silently no-ops.

7. **Metro whitelist = `{SUBWAY, HEAVY_RAIL, RAIL, METRO_RAIL, MONORAIL}`.**
   *Why:* These are the Google `vehicle.type` values for metro/subway service; a "transit-mode" trip that reroutes onto a bus-only path should be rejected because the rider chose metro.
   *Trade-off / Flaw:* The list omits `LIGHT_RAIL`, `TRAM`, and — importantly for India — `COMMUTER_TRAIN`. A Mumbai-local reroute (COMMUTER_TRAIN) for a transit-mode rider would fail validation and **terminate tracking**, even though it's exactly the service they're on. This is a real India-specific gap against the core promise.

8. **Terminate after 3 constraint/fetch failures; multi-signal termination policy otherwise.**
   *Why:* Rather than terminating on raw distance (which nukes legitimate highway detours), `TrackingTerminationPolicy` combines distance + duration + "moving away from destination" + failed-reroute count. This lowers false terminations while still catching genuine abandonment. Failing loud (a "Tracking Ended" notification) is deliberately better than silently tracking a dead route.
   *Trade-off:* More state and tuning; several magic thresholds (5km stopped, 2km+10min+2-fails, 3km moving-away × 5 checks).
   *Flaw:* Two different failure counters coexist — `_handleRerouteDecision` terminates at `failedRerouteAttempts >= 3` (`trackingservice.dart:1483,1543`) while the policy's compound RULE 2 uses `minFailedReroutesForTermination = 2`. Also `onRerouteFailed()` increments `_deviationState?.failedRerouteAttempts`, which is a **no-op if `_deviationState` is null** (deviation ended between detection and the reroute completing), so the counter can silently stay at 0 and never reach the termination threshold.

9. **Dead-reckoned (GPS-blackout) fixes are excluded from deviation ingest.**
   *Why:* A synthesized underground position (accuracy ≥ 9000m) is a guess. Feeding it to deviation would let EKF drift masquerade as the rider leaving the route and trigger a bogus reroute in a tunnel — catastrophic for the promise.
   *Trade-off:* During a long blackout, deviation detection is effectively *paused* — if the rider really does leave the route underground, it won't be noticed until a real fix returns.
   *Flaw:* Acceptable, but it means "never at the wrong place" leans entirely on the EKF being right during blackouts; deviation offers no backstop there.

10. **`deviation_detection.dart` retained but dead.**
    *Why (inferred):* Early implementation kept for reference / its one integration test.
    *Trade-off / Flaw:* Confusing dead code. Its `findClosestPointOnRoute` is O(n²) (a nested loop recomputing cumulative distance for every candidate vertex, `:31–44`) and its 600m/1500m thresholds are an order of magnitude looser than the live system — a maintainer who edits it thinking it's live would change nothing.

11. **`DeviationConfig` is treated as the source of truth but is largely NOT wired.** *(Cross-cutting flaw — see Invariants.)*
    *Why it exists:* Intent to centralise tuning.
    *Flaw:* `RouteSessionManager` constructs `DeviationMonitor(sustainDuration: …)` **without a `model:`**, so it uses `SpeedThresholdModel`'s hardcoded `base=15.0` — NOT `DeviationConfig.baseThresholdMeters = 30.0` (whose own comment claims 15m "was too tight" and was replaced). The mode-specific transit/walking/driving thresholds (`transitBaseThresholdMeters=50`, etc.) are never read. `defaultRerouteCooldown=10s` is dead too — the wired default is 20s, overridden by `PowerPolicy` (20/25/30s). `route_session_manager.dart` imports neither `SpeedThresholdModel` nor `DeviationConfig`. So the config file documents values the running app does not use.

12. **Reroute origin is `_lastProcessedPosition` (last real fix), not the live/EKF position.**
    *Why:* Route from where the rider actually, verifiably is — not a dead-reckoned guess.
    *Trade-off / Flaw:* If the last real fix is stale (long blackout before the deviation was even detected), the reroute origin can be well behind the rider, yielding a route from the wrong point.

---

**Invariants (what must always hold):**

- A reroute is only *actioned* when `shouldReroute == true` AND `!_rerouteInFlight` AND `!anyDestinationAlarmFired` AND session still active — enforced at `_handleRerouteDecision` entry (`:1370,1378,1384`) and re-checked after the fetch (`:1460`).
- `_rerouteInFlight` is set true before the await and cleared in `finally` (`:1404,1549`) — no path may leave it stuck true, or all future reroutes are silently dropped.
- At most one API reroute per `cooldown` window (20–30s) per `ReroutePolicy._lastRerouteAt`.
- `DeviationMonitor` hysteresis: once off-route it stays off-route until `offset < T_low` (strictly below the return threshold, never merely below `T_high`).
- Dead-reckoned fixes (`accuracy ≥ 9000`) never reach `devMonitor.ingest` — deviation is computed only from real GPS.
- A valid rerouted path must satisfy the *original* alarm's constraints (mode/value feasibility) — `registerRouteFromDirections` is only called after `validation.isValid`.
- Termination must always surface a user-facing message (`_terminateTrackingWithMessage`), never a silent stop.

**Interfaces (consumed / exposed):**

- **Consumes** from *Route/Session* (`RouteSessionManager`, `ActiveRouteManager`): `lastActiveState.offsetMeters` and `SnapToRouteEngine.snap(...)` for offset; the registry of cached routes for local switching. From *Location/EKF* (`_checkAndTriggerAlarm`): the raw `Position` and the dead-reckoned flag. From *Connectivity* (`setOnline`): online/offline state. From *Power* (`PowerPolicy`): the reroute cooldown.
- **Exposes to** *TrackingService orchestration*: `RerouteDecision` (via `rerouteStream`) and `DeviationState` (via `deviationStateStream`). To *Routing/Directions* (`OfflineCoordinator.getRoute` + `registerRouteFromDirections`): the reroute request and the new route. To *Notifications* (`NotificationService`): failed-reroute and termination banners. To *Dashboard/telemetry* (`ConstraintLogger`): `deviationDetected`, `deviationSustained`, `backOnRoute`, `rerouteTriggered`, `rerouteSkipped` events. To *Termination policy*: deviation edges and failure counts.
- **Note:** the dashboard's own `_calculateDistanceFromRoute` (`deviation_dashboard.dart`, `unified_dashboard.dart`) is a *third*, independent offset computation used only for display — not the one that drives decisions.

**Gaps & flaws vs the core promise:**

- **Offline deviation = no recovery (highest-severity gap).** The one scenario the promise names — underground / poor connectivity in India — is exactly where API reroute is disabled. A wrong-place exit while offline has no path back to a valid route; the system can only eventually terminate. Local cached-switch only helps if alternatives were pre-fetched.
- **India transit-type gap.** Metro whitelist excludes `COMMUTER_TRAIN` (Mumbai locals) and `LIGHT_RAIL`/`TRAM`. A legitimate reroute onto these services is rejected and tracking is terminated for a transit-mode rider — a direct "never at the wrong place" failure for a large Indian ridership.
- **Config drift / unwired thresholds.** The running detector uses `base=15m` (via `SpeedThresholdModel` defaults) while `DeviationConfig` advertises 30m and mode-specific values that are never read; `defaultRerouteCooldown=10s` is dead. Tuning the documented knobs changes nothing — dangerous for anyone trying to make detection safer.
- **Effective 150m + 5s + cooldown latency.** Nothing escalates to a reroute until offset > 150m *and* it has persisted ≥5s *and* the cooldown allows it. At metro/driving speed the rider can be hundreds of metres past the divergence before recovery starts — a "never late" risk if the wrong path is shorter to a same-named area.
- **One-cycle staleness in the fed offset.** `ingestPosition` calls `activeManager.ingestPosition(...)` then immediately reads `lastActiveState.offsetMeters`, but the state is updated via an async broadcast-stream listener — so the offset handed to `DeviationMonitor` can lag by one position sample (the code comments themselves flag the uncertainty, `route_session_manager.dart:1074–1084`).
- **Failure-counter fragility.** `onRerouteFailed()` no-ops when `_deviationState` is null, and the `>=3` (orchestrator) vs `>=2` (policy RULE 2) thresholds disagree, so "terminate after N failures" is not the crisp guarantee it appears to be.
- **Unfinished SoftLock deviation hook.** In `_checkAndTriggerAlarm`, a non-metro SoftLock deviation only logs a warning with a literal `// TODO: Trigger actual reroute if DeviationMonitor doesn't pick this up` (`trackingservice.dart:1201–1207`) — a second, parallel deviation signal that currently does nothing.
- **Single-route validation.** `RerouteConstraints` only inspects `routes.first`; if Google returns a valid alternative as `routes[1]`, it's ignored and the reroute may be rejected/terminated when a usable route existed.
