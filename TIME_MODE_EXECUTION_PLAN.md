# Time Mode — Codebase Execution Plan (as of 2026-01-10)


It is intentionally “mechanical” and trace-like so we can reason about correctness, edge cases, and efficiency with high confidence before making changes.

---

## 0) What you said you want (requirements)

### Time mode (non-metro mode)

- **Desired behavior:** fire the alarm **N minutes prior to reaching the final destination**.
- Implication: a **single destination-focused trigger**, not transfer/mode-change alerts.

### Time mode (metro mode)

- **Desired behavior:** alert **N minutes before each switchpoint** (end of each `TransitLegStops` leg) **and the final destination**.
  - If `N > ETA` for a given leg when that leg starts, the alarm should be able to **fire immediately at leg start**.
  - **Exactly one alarm per leg.**
  - A **cooldown** may be applied to reduce spam on very short legs/interchanges.

---

## 1) Key files / owners (where the logic lives)

- UI start + persistence:
  - [lib/screens/homescreen.dart](lib/screens/homescreen.dart)
  - [lib/services/tracking_state_store.dart](lib/services/tracking_state_store.dart)
- Background service plumbing:
  - [lib/services/trackingservice.dart](lib/services/trackingservice.dart)
  - [lib/services/tracking/background_handlers.dart](lib/services/tracking/background_handlers.dart)
  - [lib/services/tracking/location_stream_handler.dart](lib/services/tracking/location_stream_handler.dart)
- Alarm evaluation:
  - [lib/services/tracking/alarm_controller.dart](lib/services/tracking/alarm_controller.dart)
  - [lib/services/alarm_evaluator.dart](lib/services/alarm_evaluator.dart)
  - [lib/services/tracking/alarm_context_builder.dart](lib/services/tracking/alarm_context_builder.dart)
- Route metadata generation used by alarm logic:
  - [lib/services/transfer_utils.dart](lib/services/transfer_utils.dart)
- Reroute compatibility checks:
  - [lib/services/reroute_constraints.dart](lib/services/reroute_constraints.dart)

---

## 2) Data model: what “time mode” means in the code

- `alarmMode` is a string passed around as `'stops' | 'time' | 'distance'`.
- `alarmValue` is a `double`.
  - In **time mode**, it is interpreted as **minutes**.
- `transitMode` / `metroMode` is a boolean.
  - It changes how routes are fetched/validated, and how ETA is computed in the separate ETA engine, but **time-mode alarm evaluation currently does not use the ETA engine output**.

---

## 3) End-to-end execution trace (what runs, in order)

### 3.1 UI → persist snapshot → start background service

**Entry:** the app starts tracking from UI.

- UI persists state:

  - Saves `TrackingSnapshot(alarmMode, alarmValue, metroMode, directions, ...)`.
  - See: [lib/screens/homescreen.dart](lib/screens/homescreen.dart#L690-L760)
- UI starts background tracking:

  - Calls `TrackingService.startTracking(...)` passing:
    - `alarmMode`, `alarmValue`, `transitMode: _metroMode`.
  - See: [lib/screens/homescreen.dart](lib/screens/homescreen.dart#L762-L776)
- Then UI registers the route (fire-and-forget):

  - Calls `trackingService.registerRouteFromDirections(...)`.
  - That populates route events, step bounds, transit legs, etc.

### 3.2 Foreground → background IPC handler

- Background receives `'startTracking'` and forwards to the actual callback:
  - See: [lib/services/tracking/background_handlers.dart](lib/services/tracking/background_handlers.dart#L66-L163)

### 3.3 Location tick → alarm check

In background isolate:

- `TrackingService.startLocationStream()` wires a callback:

  - `LocationStreamHandler.onCheckAlarm = (...) => _checkAndTriggerAlarm(position, service)`
  - See: [lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1990-L2060)
- `LocationStreamHandler` processes GPS updates and periodically:

  - computes ETA/speed samples
  - evaluates **time-alarm eligibility**
  - invokes `onCheckAlarm`

---

## 4) Route progress (the “meters” domain time-mode uses)

Time-mode evaluation depends heavily on `progressMeters` along a polyline.

### 4.1 Progress is computed by snapping to the active route polyline

- `_resolveAlarmRouteState(...)` selects an active route and calls `SnapToRouteEngine.snap(...)`.
- It updates `progressMeters` and stores `_lastSnapResult`.
- See: [lib/services/trackingservice.dart](lib/services/trackingservice.dart#L988-L1065)

### 4.2 The “leg” system used by alarms is built from Directions steps

- `TransferUtils.extractTransitLegStops(directions)` builds a list of legs for **every step**:
  - Transit steps → a `TransitLegStops` with `isMetro` depending on vehicle type.
  - Driving/Walking steps → `TransitLegStops` with `isMetro=false` and `numStops=0`.
  - It coalesces adjacent non-transit steps by name.
- This means **even non-metro routes usually still have legs** (e.g., a single “Drive” leg).
- See: [lib/services/transfer_utils.dart](lib/services/transfer_utils.dart#L788-L1040)

---

## 5) Time-alarm eligibility gate (very important)

Before *any* time-mode alarm evaluation is allowed (route-based or geofence), the system requires:

- moved distance ≥ **100m**
- ETA samples ≥ **3** (only counts samples when `position.speed >= 0.5 m/s`)
- tracking duration ≥ **30s**

This is computed inside the `LocationStreamHandler` and exposed via `AlarmContext.timeAlarmEligible`.

- See: [lib/services/tracking/location_stream_handler.dart](lib/services/tracking/location_stream_handler.dart#L505-L517)

**Consequence (non-metro):** in heavy traffic, at startup, in tunnels, or with low-speed jitter, time mode may not evaluate for a while.

**Consequence (metro journeys):** route-based time-mode evaluation bypasses this gate when the route contains metro legs, so alarms can fire immediately at the start of each leg.

---

## 6) AlarmController routing: route-based vs geofence fallback

### 6.1 AlarmContext is built

- `_checkAndTriggerAlarm(...)` constructs an `AlarmContext` via `AlarmContextBuilder.build(...)`.
- It selects per-route-key data if available, else uses fallbacks.
- See: [lib/services/trackingservice.dart](lib/services/trackingservice.dart#L1168-L1206)
- Builder: [lib/services/tracking/alarm_context_builder.dart](lib/services/tracking/alarm_context_builder.dart#L13-L94)

### 6.2 `AlarmController.checkAndTriggerAlarm(...)`

Core gates:

- If tracking inactive → return.
- If destination/value missing → return.

Then:

- Builds `activeEvents` from `context.routeEvents`.
- Ensures there is a `'destination'` event (synthetic if missing) using either `stepBoundsMeters.last` or route length.
- For **distance mode**, it runs an early route-length/progress check.
- For **time mode (non-metro)**, it now runs an early **destination-only** check (ETA-to-destination <= N minutes) and returns.

Decision point:

- If `activeEvents.isNotEmpty && progressMeters != null` → `_evaluateWithRoute(...)`.
- Else if destination exists → `_evaluateGeofence(...)`.

See: [lib/services/tracking/alarm_controller.dart](lib/services/tracking/alarm_controller.dart#L266-L516)

---

## 7) Current Time Mode logic (route-based): EXACT behavior

### 7.1 `_evaluateWithRoute(...)` sets up evaluation

- Speed source passed into evaluator:
  - prefers `context.smoothedSpeed`
  - else uses `context.lastSpeedMps` if smoothed is missing/≤0.5
- Applies the **time eligibility gate**:
  - if time mode and not eligible (and not test mode) → return (skip)
  - **except** when the route contains metro legs (metro journey), where evaluation is allowed immediately to support “fire at leg start if N > ETA”.

See: [lib/services/tracking/alarm_controller.dart](lib/services/tracking/alarm_controller.dart#L524-L573)

### 7.2 It computes “metro context” (mostly for suppressing spurious preBoarding)

- Scans `context.transitLegs` and treats “interchange walk between metro legs” as metro context.
- Note: `AlarmEvaluator` mostly relies on `leg.isMetro` not this computed boolean.

See: [lib/services/tracking/alarm_controller.dart](lib/services/tracking/alarm_controller.dart#L703-L799)

### 7.3 It computes `currentLegIndex`

- Finds the leg where `legStartMeters <= progressMeters <= legEndMeters`.
- Overshoot handling: if progress beyond last end, pins to last leg.

See: [lib/services/tracking/alarm_controller.dart](lib/services/tracking/alarm_controller.dart#L801-L845)

### 7.4 It calls `AlarmEvaluator.evaluateCoinciding(...)`

See: [lib/services/tracking/alarm_controller.dart](lib/services/tracking/alarm_controller.dart#L817-L849)

---

## 8) AlarmEvaluator Time Mode: EXACT decision logic

**This is the heart of current “time mode”.**

### 8.1 “One alarm per leg” is enforced

- If a leg’s `legId` is already in `firedLegIds`, evaluator returns null.

### 8.2 Overshoot-at-boundary handling

- If you jump over a leg boundary (within ~10m epsilon), and the *previous* leg was metro and hasn’t fired, it evaluates the previous leg instead.

See: [lib/services/alarm_evaluator.dart](lib/services/alarm_evaluator.dart#L84-L132)

### 8.3 Time mode formula

When `mode == AlarmMode.time`:

1) `thresholdSeconds = userValue * 60`
2) `remainingMeters = clamp(leg.legEndMeters - progressMeters, 0..∞)`
3) `etaSeconds = estimateEtaSecondsToMeters(...)`

- if `currentSpeedMps > 0.5`, uses `remainingMeters / currentSpeedMps`
- else, estimates using `stepBoundsMeters + stepDurationsSeconds` when available
- final fallback uses a conservative walking-speed model

4) fire if `etaSeconds <= thresholdSeconds`

See: [lib/services/alarm_evaluator.dart](lib/services/alarm_evaluator.dart#L171-L214)

### 8.4 What it fires (NOT just destination)

If `shouldFire`:

A) **If final leg** → fires `eventType = 'destination'`.

B) If not final leg:

- If current leg is **non-metro** and the next leg is **metro**:

  - fires `eventType = 'preBoarding'` with a label like “Approaching metro station …”
- Else:

  - fires one of: `transfer | mode_change | final_station` (best-effort label)

C) Special override:

- If destination is within **300m after the boundary**, it fires **destination** instead of a switch/transfer.

See: [lib/services/alarm_evaluator.dart](lib/services/alarm_evaluator.dart#L214-L318)

### 8.5 Important implication

**Time-mode ETA is computed to the end of the current leg**, not necessarily to the final destination.

So on multi-leg routes, time mode can fire “early” relative to the destination if the current leg’s endpoint is near.

---

## 9) Time mode (geofence fallback) behavior

This is used when route context is missing (no progress meters or no events).

- If time mode:
  - If not time-eligible → skip.
  - `speed = 1.4 m/s` (walking default) unless `position.speed > 0.5`
  - `etaSec = straightLineDistance / speed`
  - `thresholdSec = userMinutes * 60 + 30` (adds a **+30s buffer**)
  - fire destination if `etaSec <= thresholdSec`

See: [lib/services/tracking/alarm_controller.dart](lib/services/tracking/alarm_controller.dart#L962-L1010)

---

## 10) Metro time mode: what exists today

There is **no separate “metro time mode” algorithm**.

If the user chooses **metroMode=true** and **alarmMode='time'**, the system still uses the **same time-mode logic** above:

- ETA is computed from:
  - remaining meters to **current leg end**
  - divided by a speed value (with a hard fallback to **10 m/s**)
- It can fire:
  - destination alarms
  - transfer/mode-change/final-station alarms
  - preBoarding alarms
- It is still governed by the time-eligibility gate.

(Separate note: the codebase *does* contain metro-specific logic, but it’s for **stops mode**, not time mode.)

---

## 11) Efficiency characteristics (current)

Per GPS tick, worst-case work is dominated by:

1) **Snap-to-route** in `_resolveAlarmRouteState` (polyline-domain):

   - complexity roughly proportional to polyline segments (implementation-dependent).
2) AlarmController evaluation:

   - `activeEvents` creation: O(#events)
   - metro-context scan: O(#legs)
   - current-leg scan: O(#legs)
3) AlarmEvaluator time-mode arithmetic:

   - O(1)

So overall time-mode is computationally cheap; the main cost is snapping.

---

## 12) Known correctness risks / edge cases to account for

### 12.1 Speed fallback is optimistic

- Route-based time mode no longer uses a fixed `10.0 m/s` fallback.
  - It uses speed when credible, otherwise falls back to step-duration estimates (when available), and finally a conservative walking-speed model.

### 12.2 Two different “fallback” worlds

- Route-based time mode fallback: step-duration estimate → conservative walking-speed model.
- Geofence fallback: `1.4 m/s` (walking) + `+30s` buffer.

So behavior can change drastically depending on whether route progress is available.

### 12.3 “Time mode means leg-end ETA”, not destination ETA

- On multi-leg routes (including metro journeys with walk segments), this can produce alarms that do not match “N minutes before destination”.

### 12.4 Eligibility gate can delay alarms unexpectedly

- If you start tracking while already near destination, or stuck in slow traffic, the gate can prevent evaluation until conditions are met.

### 12.5 Missing / inconsistent leg data

- If `transitLegs` is empty or misaligned to events, evaluator falls back to distance-ish rules (not time).
  - This can happen in some fixtures or if route registration doesn’t populate legs.

### 12.6 Reroute changes the route mid-trip

- On reroute, the active route key changes; AlarmController migrates fired sets per key.
- `RerouteConstraints` rejects time-mode reroutes if alarm minutes ≥ new route duration.

---

## 13) Changes applied to match desired behavior

### Non-metro time mode (implemented)

- Alarm fires **once** when `ETA_to_final_destination <= N minutes`.
- Route-based time mode ignores intermediate events (transfer/mode-change/preboarding).
- Implementation: early destination-only check in `AlarmController._evaluateWithRoute(...)`.

### ETA quality improvements (implemented)

- Removed optimistic fixed-speed fallback in route-based time-mode evaluation.
- Uses speed when credible; otherwise uses step-duration estimate (when available) and a conservative fallback.
- Implementation: `AlarmEvaluator.estimateEtaSecondsToMeters(...)` and time-mode branch.

### Metro time mode (current behavior + guardrails)

- Metro journeys bypass the time eligibility gate so “fire immediately at leg start if N > ETA” is possible.
- A 3-minute cooldown is applied to **non-destination** metro time-mode alarms to reduce rapid back-to-back notifications on very short legs.

---

## 14) Testing notes

- Unit/integration tests should cover:
  - non-metro time mode fires only destination
  - metro time mode can fire immediately at leg start (when N > ETA)
  - cooldown behavior under warp time (`AppClock`) so tests remain deterministic
