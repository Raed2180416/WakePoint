# WakePoint GPS-Out Correctness Map

Scope: ONLY the GPS-absent / GPS-degraded 1D dead-reckoning (DR) path. With-GPS
tracking, UI, onboarding, alarm delivery are out of scope. Extends
`correctness_assumptions_map.md`. All refs `file:line` from repo HEAD.
Safe-fail principle for a wake alarm: **fail toward early alarm / honest wide
sigma / surfaced "uncertain" — never confident-wrong or late.**

State `[s, v, b]`, 3x3 cov `P`. Modes `EkfMode { surface, metro, degraded }`
(`ekf_types.dart:3`).

---

## CROSS-CUTTING FINDING (affects cases 1,3,4) — GPS-loss is not detected in production

`EkfOrchestrator.onGpsUnavailable()` (`ekf_orchestrator.dart:246-273`) is the
only path that tells the engine "no fix this tick" (feeds detector
`hasFix:false`, `innovationSigma:999`). **It is called from exactly one place:
`ekf_test_controller.dart:666` — never from production.** Production feeds the
EKF only via `sensor_fusion.dart:132 updateGps()` → `onGpsFixAuto` (`:155`),
which fires only when a `Position` actually arrives. When GPS drops, no
`Position` arrives, so **neither `onGpsFix` nor `onGpsUnavailable` runs**, and
`GpsDegradationDetector`'s 5s-no-fix trigger (`noFixSeconds=5`,
`gps_degradation_detector.dart:5,38-45`) is dead code in the shipping app.
No production `Timer`/watchdog synthesizes no-fix (grep: none).

Consequence: `_hasGpsFix` (set `true` at `:213`) stays `true` after the first
fix until `reset()` clears it (`:310`; note `:305` clears the sibling
`_ekfInitialized`), so `_updateMode` (`:486`) never re-enters the
`!_hasGpsFix → degraded` branch (`:489`). Mode→degraded then depends
*solely* on `_degradedMode.update()` via `onImuSample` (`:140`), which for a
metro leg needs `sigmaS ≥ 2000` (`thresholdOverride`, `:504`) — **impossible
because `_inflateCovariance` caps `sigmaS` at 200m** (`ekf_pipeline.dart:555`)
— or `noZuptGap ≥ 10 min` (`degraded_mode.dart:6,33`). So a metro rider can DR
for up to **10 minutes in `metro` mode (not `degraded`)** before any
degraded-specific handling engages. During that window covariance grows only
by process noise Q (`sigmaAccel=0.15`, `ekf_types.dart:119`) — σ stays small =
**silently overconfident**, and public `s` uses the monotonic clamp, not
internal `s` (see Case 4).

Safe-fail needed: wire a production no-fix watchdog (timer or
staleness check in `sensor_fusion`/`trackingservice`) to call
`onGpsUnavailable` every tick GPS is missing; drive degraded entry off
**elapsed-since-last-fix**, not off a σ that is capped below its own trigger.

---

## CASE 1 — COLD-START UNDERGROUND (no init GPS fix)

**Current behavior:** DR never starts; engine is inert at `s=0`.
- Orchestrator gate: `if (!_predictionEnabled) return;` (`ekf_orchestrator.dart:159`).
  `_predictionEnabled` starts `false` (`:76`) and is set `true` only in
  `onGpsFix` (`:211`) or in the no-fix path **guarded by `_ekfInitialized`**
  (`:257-258`) — and `_ekfInitialized` itself only becomes `true` in `onGpsFix`
  (`:212`). No fix ⇒ both stay false ⇒ every IMU sample dropped at `:159`.
- Pipeline second gate: `onForwardAccel` returns if `!_initialized` (`ekf_pipeline.dart:87-90`);
  `_initialized` set only in `_initializeFromGps` (`:518`), reached only from a
  real fix / hard-reset (`:267,282`).
- Mode is forced `degraded` while `!_hasGpsFix` (`ekf_orchestrator.dart:487-492`),
  but with predictions disabled it produces no motion.
- Pre-GPS static-bias collection runs (`:709-725`) but only *prepares* bias; it
  does not start integration.

So a rider who boards already underground gets **no position movement at all**;
`s` is pinned at 0 until the first surface fix. This is honest (no false
progress) but the alarm engine is non-functional for the entire underground
leg — if the destination is reached before the first fix, **the alarm cannot
fire** (late/never = the harmful direction).

**Safe-fail needed:** allow a *provisional* cold init from the known route
origin / boarding station (seed `s` at the entrance station, `v=0`) with a
**large honest σ** (e.g. σ_s ≥ station-spacing), enter `degraded` explicitly,
and surface an "uncertain — using route seed" state. DR from a wide prior is
better than a dead engine; if it cannot init at all, it must surface "cannot
track underground yet" rather than sit silently at `s=0`.

---

## CASE 2 — WRONG-ROUTE / WRONG-DIRECTION while blacked out

**Current behavior:** reverse motion is silently clamped; no event surfaced.
- Metro legs set `allowReverse=false` via `setStationContext →
  setAllowReverse(!isMetroLeg)` (`ekf_orchestrator.dart:287-288`).
- Clamp in prediction: `if (!_allowReverse) { if (_v<0) _v=0; if (_s<sOld)
  _s=sOld; }` (`ekf_pipeline.dart:204-208`, `sOld=_s` at `:137`). A rider on the
  **opposite-direction train** decelerates/accelerates backward along route
  arc-length; the filter zeroes negative `v` and freezes `s` — it looks
  *stationary/forward*, never backward.
- There is **no wrong-direction or wrong-train detector** in the EKF
  (grep `wrongDirection|opposite|reverse.*detect`: none in `lib/core/ekf/`).
- `DeviationMonitor` (`route_session_manager.dart:902`) is the only off-route
  check, and it is fed from `lastIngestedPosition` via `ingestPosition`
  (`:1066-1076`) — i.e. **raw GPS**. During blackout no position is ingested,
  so deviation detection is blind. Off-route GPS, when present, is also
  discarded upstream: `projectLatLng` returns `NaN` beyond
  `maxLateralErrorMeters=75` (`route_geometry.dart:10,60-62`) and
  `onGpsFixAuto` early-returns on `NaN` (`ekf_orchestrator.dart:237-238`).

Result: a wrong-direction or wrong-line rider is rendered as *slow forward
progress on the intended route* — the exact **confident-wrong** failure, and
because progress only ever increases (Case 4), the alarm will eventually fire
as if the correct stop were approaching (**false alarm on the wrong train**;
worse, the real stop is missed).

**Safe-fail needed:** treat sustained reverse/opposite IMU integration as a
signal, not noise. Count clamp events (`:204-208`); if reverse persists beyond
a threshold, raise a `wrongDirectionSuspected` event and force `degraded` +
wide σ + surfaced "direction uncertain". Never present clamped-forward motion
as confident progress.

---

## CASE 3 — REROUTE / STALE ROUTE offline

**Current behavior:** reroute is suppressed whenever offline.
- `ReroutePolicy.onSustainedDeviation`: `if (!_online) { log rerouteSkipped
  'offline'; add RerouteDecision(false); return; }` (`reroute_policy.dart:39-51`).
- `_online` is driven by connectivity: `homescreen.dart:92
  setOnline(!_noConnectivity)` → `trackingservice.dart:2444` →
  `reroute_policy.dart:30`. Underground = offline ⇒ every deviation is skipped.

This is defensible (cannot fetch a new route with no network), but combined
with Case 2 it means: **on a wrong train underground, the app can neither
reroute nor detect the wrong route** — it silently DRs along the stale intended
route. The suppression is also *silent to the user* (only a `ConstraintLogger`
entry, `:41-49`); the tracking state is not marked stale/uncertain.

**Safe-fail needed:** when a deviation is detected but reroute is suppressed
offline, propagate an "on stale route, reroute unavailable — tracking
uncertain" state to the alarm layer and widen σ / bias toward early alarm.
Suppressing the reroute silently while continuing to report confident progress
on a possibly-wrong route is the unsafe combination.

---

## CASE 4 — BLACKOUT ENTRY/EXIT reacquisition transients

**Current behavior:**
- **Entry / long IMU gap:** `dt > 1s` ⇒ `_v=0; _b=0; _inflateCovariance(4.0);
  return` (`ekf_pipeline.dart:117-124`). Marginal dt ⇒ inflate 1.1 (`:128`).
  In degraded, gentle inflate `1.0002`/tick (`:156`) — designed to keep σ_s
  <100m for ~3 min (`:151-155`). All inflation capped at **σ_s=200m**
  (`:555`). Over a multi-minute metro leg the true DR error easily exceeds
  200m, so **σ_s saturates and understates real uncertainty** (overconfident).
- **Public progress is monotonic:** `_sPub = max(_sPub, _s)`
  (`ekf_pipeline.dart:575-581`). In `degraded` the public getter bypasses the
  clamp and exposes internal `s` (`:49-50`); in `surface`/`metro` it exposes
  the clamped `_sPub`. So on **exit** from degraded back to metro/surface, any
  DR *overshoot* accumulated during blackout is frozen into `_sPub` and can
  **never be corrected backward** — a returning GPS fix that says "you are
  behind where DR thought" cannot pull public progress back.
- **GPS reacquisition gate:** `onGpsFix` computes `nu=sGps-_s`,
  `normInnov=|nu|/σ_s` (`:272-274`); `>15σ ⇒ hard reset` to the fix
  (`:278-282`); Huber weight with `c=2.5`, `weight<0.2 (12.5-15σ) ⇒ soft
  reject + inflate 1.2 + return` (`:289-296`); otherwise weighted fuse
  (`:300-...`). Because σ_s is capped at 200m and often saturated-but-small
  relative to true drift, a large genuine error can land in the mid-innovation
  band and be **down-weighted rather than trusted**, or a moderate error
  (~100m vs σ≈27m ⇒ ~3.7σ) is fused while `P` still reports high confidence.

Net: at exit the estimate can be **confident-wrong** (overshoot frozen by the
monotonic clamp; σ understated), and the first good fix is partially rejected.

**Safe-fail needed:** (1) drop / greatly raise the σ_s=200m cap so uncertainty
grows honestly with blackout duration (σ should reflect meters-of-drift, not
saturate); (2) on degraded→normal transition, *re-seed* `_sPub` from the fused
`_s` (allow backward correction) instead of `max()`-locking overshoot; (3) on
first fix after a long gap, prefer a **soft re-init** (reset `P` to the fix's
own accuracy) over Huber down-weighting, so a returning fix is trusted.
Bias toward early alarm during the transient, never freeze overshoot.

---

## CASE 5 — STATION SNAP under inflated sigma during blackout

**Current behavior:** snap window widens with σ and, in degraded mode,
multi-candidate ambiguity is *resolved* rather than rejected.
- Window `= 3σ_s + adaptiveMargin`, `adaptiveMargin = 50 + 0.5σ` capped
  [50,150] (`station_association.dart:74-82,116-117`). At σ_s=200 (the cap):
  window ≈ 3*200 + 150 = **750m** — wide enough to swallow several metro
  stations.
- Normally `candidates.length != 1 ⇒ reject MULTIPLE_CANDIDATES` (`:143,176`).
  **But if `isDegraded`, it picks `DEGRADED_NEAREST` — nearest station ahead of
  `sEst`, else nearest overall** (`:144-171`). So under exactly the
  high-uncertainty condition where snapping is riskiest, the code *forces* a
  snap to a guessed station.
- Gating that mitigates: snap requires `isMetroLeg && zuptConfirmed &&
  dwell≥3s` (`:133-138`), and the orchestrator confirms the ARM/alarm update
  only if post-snap `σ_s ≤ 60m` (degraded) / `30m` (normal) **and** monotonic
  index (`ekf_orchestrator.dart:449-452`). A wrong `DEGRADED_NEAREST` snap
  still moves internal `s` (`ekf_pipeline.dart:472-506`) even when the confirm
  gate later rejects the *event*.

Risk: a false ZUPT (train slows but doesn't stop, or dwell noise) plus wide
window plus `DEGRADED_NEAREST` can snap `s` to the **wrong station**, and the
snap sharply *reduces* σ_s (`:490-497`) → newly **confident-wrong**, which can
then pass the σ≤60m confirm gate and fire the alarm at the wrong stop.

**Safe-fail needed:** in degraded/high-σ, **prefer rejection over
`DEGRADED_NEAREST` guessing** when candidates are ambiguous; require stronger
ZUPT evidence (longer dwell, true zero-velocity) before any snap; and do not
let a snap *collapse* σ below an honest floor tied to how the snap was chosen
(a guessed snap should keep wide σ, not manufacture confidence). Ambiguous ⇒
stay uncertain and bias early, never snap-and-confirm to a guess.

---

## Severity summary
- **Critical:** Cross-cutting no-fix watchdog missing (blackout undetected up to
  10 min); Case 1 (no DR on cold-start underground); Case 2 (silent
  wrong-direction clamp, confident-wrong).
- **High:** Case 4 (σ cap 200m + monotonic overshoot lock = confident-wrong at
  exit); Case 5 (`DEGRADED_NEAREST` forces snap under max uncertainty).
- **Medium:** Case 3 (offline reroute suppression is silent; safe only if the
  uncertain state is surfaced).
