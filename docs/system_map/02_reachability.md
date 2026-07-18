## Reachability Protection Level (the "never-late" physics core)

**Role in the core promise:**
GeoWake's one job is to wake a transit rider *before* their stop — never late, never at the wrong place — even when GPS dies in a tunnel on a cheap Android phone. Every other subsystem (the EKF, snapping, ETA smoothing) is a *statistical* estimate of where the rider is, and statistics can silently drift kilometres wrong in minutes underground (per `HANDOFF.md:15`, open-loop dead-reckoning "fires late ~30–55% of the time"). The Reachability Protection Level (PL) is the *non-statistical* backstop that makes "never late" a **provable physical fact** rather than a hope. It answers one question with pure arithmetic: *given the last place we truly saw the train and the fastest that line can physically move, what is the furthest along the route the train could possibly be right now?* If that worst-case position has reached the target stop, the alarm fires. If the alarm has **not** fired, the train **provably** has not reached the stop. No accelerometer, gyroscope, magnetometer, or map-matching is required, so the guarantee is device-agnostic — which is exactly why it survives the cheap-phone long tail. The cost of this certainty is that the alarm fires *early* (the worst case is looser than reality); the rest of the fire-decision cluster exists to keep "how early" tolerable.

**Files:**

| Path | What it does |
| --- | --- |
| `lib/core/reachability/reachability.dart` | The entire PL. Pure math (`Reachability.bound`, `effectiveProgress`, the topology cap) + data holders (`ReachabilityAnchor`, `RouteTopology`, `ReachabilityConfig`, `ReachabilityBound`) + the per-line speed table (`VLineTable`) + the stateful `ReachabilityTracker` that the controller drives. Time is passed in explicitly (no wall-clock reads) so every claim is deterministically testable. |
| `lib/services/tracking/alarm_controller.dart` | Owns the single `ReachabilityTracker _reach`. Each tick it (a) seeds/re-anchors the tracker from the incoming `Position`, (b) computes `reachBoundMeters = _reach.boundNow(...)`, (c) passes it into `AlarmEvaluator.evaluateCoinciding(reachableProgressBoundMeters:)`, and (d) emits telemetry when the physics bound is materially ahead of dead-reckoning. |
| `lib/services/alarm_evaluator.dart` | Consumes `reachableProgressBoundMeters`. Folds it into an "effective progress" via `Reachability.effectiveProgress` for the metro stop-count and 60%-rule paths, and uses a direct `reachBound >= target` short-circuit on the two time-mode ETA paths. |
| `lib/config/fire_decision_config.dart` | Supplies the shared constants the PL leans on: `fractileK = 2.0`, `maxFractileSigmaMeters = 300`, `deadReckonAccuracySentinel = 9999`. |
| `lib/services/tracking/location_stream_handler.dart` (context only) | Produces the dead-reckoned "dropout" `Position` with `accuracy = 9999` sentinel that must **not** re-anchor reachability. |
| `lib/services/ios/ios_backstop_planner.dart` (interface only) | A second consumer of `VLineTable` (earliest-arrival scheduling for iOS). Not part of the fire loop. |

---

### How it works, step by step (the atomic walkthrough)

The PL has two halves: (1) the **pure math** in `reachability.dart` that computes an upper bound on progress, and (2) the **wiring** in `alarm_controller.dart` that keeps the anchor honest and feeds the bound into the fire decision.

#### The physical claim, in plain arithmetic

While GPS is lost, the train cannot be further along the route than:

```
s_max(t) = s0_hi + V_LINE · (t − t0)
```

- `s0_hi` = arc-progress (meters from route origin) of the **last accepted real GPS fix**, pushed *forward* by that fix's accuracy so we never under-claim how far along it already was. (`ReachabilityAnchor.sHi`, `reachability.dart:143` — `sMeters + accuracyMeters`.)
- `V_LINE` = a speed chosen to be **≥ the line's true top speed** (`VLineTable`).
- `t − t0` = wall-clock seconds elapsed since that last true fix, reset **only** by another gate-passing fix.

If `s_max(t) ≥ targetMeters` and we fire, we are early or on time — never late — because reality is always `≤ s_max`.

#### Step 1 — Anchor maintenance (every tick, in `AlarmController.checkAndTriggerAlarm`, `alarm_controller.dart:391–426`)

1. Compute `nowSec = AppClock().now().millisecondsSinceEpoch / 1000.0` (`_nowSeconds()`, line 139).
2. Derive a trustworthy fix timestamp `fixTs`: default it to `nowSec`, but prefer `currentPosition.timestamp` **only if** it is finite, not in the future (`ts <= nowSec`), and not absurdly stale (`nowSec - ts < 3600`) (lines 403–410). This prevents a late-delivered GPS fix from resetting `t_since_last_true_fix` too recently and shrinking the bound below reality — a precondition-(iii) late-fire hazard.
3. `_reach.seedColdStart(tSeconds: nowSec, sMeters: progressMeters ?? 0.0)` (line 411). Because `seedColdStart` uses `_anchor ??=` (`reachability.dart:393`), this only fires **once** — on the very first tick — establishing an anchor at the trip's start position and time even if GPS never yields a single underground fix. This closes the "cold-start hole" where the EKF never initialises and the alarm never fires.
4. Decide `isRealFix`: `acc.isFinite && acc > 0 && acc < 9999` (the `deadReckonAccuracySentinel`, lines 413–416). A dead-reckoned dropout `Position` carries `accuracy = 9999`, so it is rejected here.
5. If it is a real fix with finite progress, `_reach.onAcceptedFix(sMeters: progressMeters, accuracyMeters: acc, tSeconds: fixTs)` (lines 417–425). `onAcceptedFix` has a monotonic guard: it drops any fix whose `tSeconds` is earlier than the current anchor's (`reachability.dart:410`), so the anchor never walks backward in time.

Net effect: the anchor advances **only** on genuine gate-passing fixes; through a blackout it stays put and `t` keeps growing, which is precisely what makes `s_max` inflate toward the target.

#### Step 2 — Compute the bound (`alarm_controller.dart:1111–1158`)

1. If a current transit leg exists, read `reachLineName = leg.lineName` and build a `RouteTopology` from `leg.stopMeters + leg.legEndMeters` with `dwellMinSeconds: 0.0` (lines 1119–1132).
2. Call `_reach.boundNow(nowSeconds: _nowSeconds(), lineName: reachLineName, topology: reachTopo)` (line 1134), which resolves `V_LINE` via `vLineTable.forLine(city: null, lineName: ...)` and delegates to the pure `Reachability.bound(...)`.
3. Inside `Reachability.bound` (`reachability.dart:227–289`):
   - **Corrupt-input fail-safe** (lines 239–248): if `anchor.sHi`, `anchor.tSeconds`, or `nowSeconds` is non-finite, return `sMaxMeters = +infinity, watchdogTripped = true`. Rationale: we *cannot prove* the train is short of the target, and silently freezing the bound would suppress the alarm forever — so fail toward firing.
   - `dt = nowSeconds − anchor.tSeconds`, clamped to `≥ 0` (lines 250–251).
   - `v = vLineMps` if finite and `> 0`, else the `absoluteCeilingMps = 56` fallback (lines 252–254).
   - `freeRun = anchor.sHi + v · dtClamped` (line 256). **This is the shipped bound.**
   - **Hard T_max watchdog** (lines 259–267): if `config.hardTMaxSeconds != null && dtClamped >= hardTMaxSeconds`, return `+infinity`. In production `hardTMaxSeconds` is **null**, so this branch never executes (see Gaps).
   - **Topology cap** (lines 269–282): only if `topology != null && !topology.isEmpty && config.dwellMinSeconds > 0.0`, tighten via `_topologyCappedProgress` and take `min(freeRun, capped)`. In production `config.dwellMinSeconds == 0.0`, so this branch never executes either — `sMax == freeRun` always.
   - Return `ReachabilityBound(sMaxMeters: sMax, freeRunMeters: freeRun, dtSeconds: dtClamped)`.
4. Back in the controller (lines 1143–1157): pass `sMaxMeters` through as `reachBoundMeters` **unless it is NaN** (a `+infinity` bound is the fire-forcing signal and must reach the evaluator; only NaN — "no information" — is dropped). If `reachBoundMeters − progressMeters > 50.0`, emit `TelemetryService.reachabilityActivated(...)` — the reliability funnel record that the physics bound is materially carrying the decision.

#### Step 3 — Fold the bound into the fire decision (`alarm_evaluator.dart`)

The evaluator combines the drift-prone statistical estimate with the late-proof physics bound via `Reachability.effectiveProgress` (`reachability.dart:346–369`):

```
statistical = deadReckonedProgressMeters + sigmaCushionMeters      // clamped, tight, can fire late
reach       = reachableProgressBoundMeters (if finite)             // unclamped, late-proof
effective   = max(statistical, reach)                              // never late, as tight as the tighter bound
```

Special cases inside `effectiveProgress`:
- `reach == +infinity` → return `+infinity` immediately (forces every stop to count as reached → fire). This is "the never-fire fix": previously `+infinity` was discarded.
- `statistical` non-finite (cold start, EKF not yet initialised → NaN dead-reckoned progress) → fall back to `reach ?? statistical`, because `max(NaN, x) == NaN` would otherwise silently poison the decision.

The `sigmaCushionMeters` passed in is `fractileK · clamp(positionSigma, 0, 300)` = up to `2 · 300 = 600 m` (`alarm_evaluator.dart:99–101, 726–728, 845–848`). The clamp is why the statistical cushion alone can fire late on a long blackout — and why the *unclamped* reachability bound is needed to close that hole.

Where `effectiveProgress` / the reach bound is actually used:
- **Fallback path (no transit legs, `alarm_evaluator.dart:102–140`):** `effProgressFallback` drives the "direct-fire if `dest − eff ≤ 200 m`" rule and the final-leg "40% progressed → fire" rule.
- **Metro, zero intermediate stops (`alarm_evaluator.dart:729–737`):** `effectiveMetersInLeg` drives the 60%-remaining rule so an adjacent-station hop ridden through a blackout can't fire late.
- **Metro, ≥1 intermediate stop (`alarm_evaluator.dart:854–868`):** `effectiveProgressForStops` is compared against each `dedupedStopMeters` entry to count how many stops have been "reached." A stop counts as passed as soon as *either* the σ-cushion or the physics bound crosses it.
- **Time mode, main + pre-boarding (`alarm_evaluator.dart:275–279, 395–399`):** a direct short-circuit `reachFire = reachBound.isFinite && reachBound >= target` fires the alarm regardless of the (drift-prone) ETA.

---

### Key types & functions

| Type / function | Signature (abridged) | Responsibility |
| --- | --- | --- |
| `VLineTable` | `double forLine({String? city, String? lineName})` | Resolve the **over-bounding** line-speed ceiling. Order: explicit override → RRTS (53 m/s) → express (39 m/s) → default (28 m/s). Static helpers `looksRrts`/`looksExpress` do keyword matching on the line/city string. |
| `VLineTable` constants | `defaultMps=28` (100 km/h), `expressMps=39` (~140), `rrtsMps=53` (~190), `absoluteCeilingMps=56` (~200) | Every value is a *ceiling*, not an average — a too-high `V_LINE` only fires earlier (safe), a too-low one can fire late (unsafe). |
| `ReachabilityAnchor` | `{sMeters, accuracyMeters, tSeconds, fromRealFix}`; `double get sHi` | The last accepted fix in arc-length coordinates. `sHi = sMeters + accuracyMeters` forward-overbounds the anchor (the only direction that matters for never-late). |
| `RouteTopology` | `RouteTopology({stationMeters, dwellMinSeconds})` | Sorted, immutable list of station arc-positions the train must pass, for the stop-count cap. **Note:** its `dwellMinSeconds` field is never read by `bound()` (see flaw #5). |
| `ReachabilityConfig` | `{dwellMinSeconds=0, hardTMaxSeconds}` | Tunables. `dwellMinSeconds` gates the topology cap; `hardTMaxSeconds` gates the blackout watchdog. Both default to the safe-but-dormant setting. |
| `ReachabilityBound` | `{sMaxMeters, freeRunMeters, dtSeconds, watchdogTripped}` | Result of one evaluation. `sMaxMeters` is the upper bound on true progress. |
| `Reachability.bound` | `static ReachabilityBound bound({anchor, nowSeconds, vLineMps, topology, config})` | Pure worst-case-progress math. The correctness core. |
| `Reachability._topologyCappedProgress` | `static double _topologyCappedProgress({sHi, dtSeconds, vLineMps, stationMeters, dwellMinSeconds})` | Fastest-train forward simulation: travel each gap at `V_LINE`, pay `dwellMin` at each intermediate station passed. Tighter than free-run when a stopping service dwells. |
| `Reachability.reachesTarget` | `static bool reachesTarget(ReachabilityBound b, double targetMeters)` | `b.sMaxMeters >= targetMeters`. **Unused in `lib/`** (the evaluator inlines the comparison); present for tests. |
| `Reachability.effectiveProgress` | `static double effectiveProgress({deadReckonedProgressMeters, sigmaCushionMeters, reachableBoundMeters})` | `max(statistical, reach)` with `+infinity` and NaN guards. The single fusion point of statistics and physics. |
| `ReachabilityTracker` | `seedColdStart(...)`, `onAcceptedFix(...)`, `boundNow(...)`, `reset()` | Stateful holder of the current anchor for the controller. Resets the anchor **only** on accepted real fixes. |

---

### Design decisions (the WHY)

1. **Bound reachability instead of estimating position.**
   *Decided:* compute a provable *worst-case* position from `last_fix + V_LINE·t` rather than dead-reckoning the actual position through the tunnel.
   *Why:* statistical estimates (EKF/IMU dead-reckoning) drift kilometres wrong within minutes and can never *prove* the train hasn't arrived — so they fire late a large fraction of the time (`HANDOFF.md:15–20`). A worst-case bound converts "never late" from a statistical hope into a physical certainty that needs no sensors.
   *Trade-off / rejected alternative:* the bound is loose, so the alarm fires early (measured 1–7 min on short/medium blackouts, `HANDOFF.md:18`). Full sensor-fusion dead-reckoning was rejected because it is unreliable on consumer hardware and unprovable.
   *Flaw:* "early" is a real UX cost; on very long blackouts it can be minutes early. The two tightening levers meant to fix this (topology cap, σ-cushion) are either dormant (#5) or clamped (#8).

2. **`V_LINE` is a per-line *ceiling*, never an average.**
   *Decided:* the speed table returns an upper bound on the line's true top speed (28 / 39 / 53 / 56 m/s), resolved by keyword matching on the line name.
   *Why:* the entire never-late guarantee rests on precondition (ii): `V_LINE ≥ true max speed`. If `V_LINE` is too high the alarm only fires earlier (annoying but safe); if it is too low the bound grows slower than the train and the alarm can fire **late** (product death). So every value is deliberately padded above real rolling-stock maxima.
   *Trade-off:* padding `V_LINE` upward widens the early-firing margin.
   *Flaw:* resolution depends on brittle **string matching** of `leg.lineName`. `boundNow` is always called with `city: null` (`alarm_controller.dart:1134` passes only `lineName`), so `looksRrts(city)` can never contribute — RRTS/Namo Bharat detection hinges entirely on the *line name string* containing tokens like `rrts`, `namo bharat`, `meerut`, `rapidx`. If Google Directions labels a 160 km/h regional service with a name lacking those tokens, it silently falls to `expressMps=39` (≈140 km/h) or `defaultMps=28` (100 km/h) — **below true speed → a genuine late-fire path** for the fastest services. This is the single most fragile link in precondition (ii).

3. **Fail *toward firing* on corrupt input.**
   *Decided:* non-finite `sHi`/`tSeconds`/`nowSeconds` returns `sMaxMeters = +infinity` (fire), not a frozen or zero bound.
   *Why:* if we can't prove the train is short of the target, the only safe assumption is that it might have arrived. Waking early is recoverable; never waking is the cardinal sin.
   *Trade-off:* a transient NaN would trigger a spurious early alarm.
   *Flaw:* in the shipped wiring this path is essentially unreachable — the anchor is always seeded with finite numbers and `nowSeconds` comes from a monotonic clock — so the "fire on corruption" safety valve almost never actually engages. It protects against a class of bug that the seeding already prevents.

4. **Re-anchor *only* on accepted real fixes; dead-reckoned ticks must never reset `t`.**
   *Decided:* `onAcceptedFix` is called only when `accuracy < 9999`; the dropout `Position` (`accuracy = 9999`, `location_stream_handler.dart:570`) is rejected, and a monotonic guard blocks backward-in-time anchors.
   *Why:* precondition (iii) — `t` must be the wall-clock elapsed since the last *true* fix. If a snapped/dead-reckoned position reset the anchor, `t` would shrink, `s_max` would collapse back toward the (drifting) dead-reckoned position, and the physics guarantee would evaporate exactly when it is needed (underground).
   *Trade-off:* a genuinely-good fix that happens to be stamped with a slightly-earlier timestamp than the anchor is discarded by the monotonic guard.
   *Flaw:* **first-tick anomaly.** `seedColdStart` sets the anchor at `tSeconds = nowSec`, but `onAcceptedFix` on the *same first tick* uses `fixTs = currentPosition.timestamp`, which is typically a second or two in the past. Since `fixTs < nowSec`, the monotonic guard (`reachability.dart:410`) **rejects the first real fix**, leaving the cold-start seed (which has `accuracyMeters = 0.0`, i.e. *no* forward overbound) as the anchor. For that first tick the bound under-claims true progress by up to one fix-accuracy (tens of metres) — a small precondition-(i) softening that self-heals on the next accepted fix. Real, but bounded to ~one tick.

5. **The stop-count topology cap exists but is *disabled* in production.**
   *Decided:* `ReachabilityConfig(dwellMinSeconds: 0.0)` in the controller (`alarm_controller.dart:136`), and `RouteTopology(..., dwellMinSeconds: 0.0)` (line 1131). `bound()` only runs the cap when `config.dwellMinSeconds > 0.0`.
   *Why:* the cap is only *safe* on a confirmed all-stops service. A stopping-service dwell that an express/skip-stop train never actually pays would push the bound *below* true progress → late fire. Defaulting to 0 makes the bound degrade to the unconditionally-safe free-run `sHi + V_LINE·t`.
   *Trade-off:* the topology cap is the "real UX lever" for tightening early-firing (`reachability.dart:28–30`), and shipping it off means every blackout fires as early as the raw free-run allows.
   *Flaw:* **substantial dead machinery.** `_topologyCappedProgress`, the whole `RouteTopology` construction on every tick (allocating a sorted unmodifiable list, `alarm_controller.dart:1125–1132`), and the topology plumbing are all inert in the shipped app. It is wasted per-tick work and a large body of untested-in-production code paths. The founder-facing early-firing that users will actually feel is the *un-tightened* free-run bound.

6. **`RouteTopology.dwellMinSeconds` is a misleading dead field.**
   *Decided (implicitly):* `bound()` passes `config.dwellMinSeconds` — **not** `topology.dwellMinSeconds` — into `_topologyCappedProgress` (`reachability.dart:278`).
   *Why:* the tunable was centralised on `ReachabilityConfig`.
   *Flaw:* `RouteTopology` still *has* a `dwellMinSeconds` constructor field (line 156) that is **never read**. A future maintainer could set `RouteTopology(dwellMinSeconds: 45)` expecting the cap to tighten and see no effect — a latent correctness trap. It should be removed or wired.

7. **The blackout watchdog (`hardTMaxSeconds`) is defined but *never armed*.**
   *Decided:* `hardTMaxSeconds` defaults to `null` and no code sets it (grep-confirmed: only the definition and the guard reference it).
   *Why:* the reachability-reaching-target condition already fires eventually on any real route, so an absolute time budget was treated as optional belt-and-suspenders (`reachability.dart:178–181`).
   *Trade-off:* without it, if `V_LINE·t` grows but the target is very far (e.g. anchor stuck near route origin on a long line), the bound may take a long time to reach the target — there is no independent "you've been dark too long, wake anyway" cutoff.
   *Flaw:* `HANDOFF.md:39` explicitly lists the T_max watchdog as required ("if a blackout exceeds the budgeted time with no re-anchor, fire pre-emptively"). It is coded but not activated, so the intended last-resort safety net is not actually in effect.

8. **Statistical cushion is clamped to 300 m; reachability is the un-clamped partner.**
   *Decided:* `sigmaCushion = fractileK · clamp(σ, 0, maxFractileSigmaMeters)` with `fractileK=2`, `max=300` → cushion ≤ 600 m; the reachability bound is unclamped and `max()`-combined.
   *Why:* an honest EKF σ can reach ~3 km on a long underground segment (`fire_decision_config.dart:34–41`); feeding that raw into `k·σ` would inflate the cushion by kilometres and fire many stops early, defeating the alarm and eroding trust. Clamping keeps the *statistical* fire tight; the *physics* bound (unclamped) supplies the never-late guarantee the clamp would otherwise break.
   *Trade-off:* the clamped σ-cushion alone *can* fire late on a long blackout — accepted, because the reachability `max()` covers it.
   *Flaw:* this coverage only holds on the code paths that actually call `effectiveProgress` / check the reach bound (metro stop-count, metro 60%-rule, fallback, metro time-mode). Modes that don't (below) inherit the clamp's late-fire risk with no physics backstop.

9. **Cold-start seed at trip origin.**
   *Decided:* seed an anchor at `(progressMeters ?? 0, nowSec)` on the first tick, marked `fromRealFix: false`.
   *Why:* if the rider boards and immediately descends underground before any GPS fix, the EKF never initialises and, without a seed, `boundNow` returns `null` and the alarm never arms. Seeding from the known start position makes reachability work from `t=0`.
   *Trade-off:* the seed's position is only as good as the first `progressMeters`; if that first value is itself dead-reckoned it could be slightly off.
   *Flaw:* the seed uses `accuracyMeters: 0.0` (no forward overbound). Combined with flaw #4, the very first bound is the tightest (least conservative) it will ever be — acceptable because it self-corrects, but worth knowing.

10. **Fire when *either* upper bound passes the stop (`max`, not `min` or average).**
    *Decided:* `effectiveProgress = max(statistical, reach)`; a stop counts reached as soon as the *more progressed* of the two crosses it.
    *Why:* never-late means we must treat the train as *at least* as far as our most-advanced credible bound. Taking the min or the mean would let a lagging estimate suppress a fire the other bound already justified.
    *Trade-off:* biases toward earlier firing (both bounds get a vote to fire; neither can veto).
    *Flaw:* none for correctness; this is the correct direction for the guarantee. It does mean a single over-large σ spike (up to the 600 m cushion) can fire ~1–2 stops early even when GPS is fine.

---

### Invariants

- **I1 (over-bound):** `ReachabilityBound.sMaxMeters ≥ true arc-progress` at `nowSeconds`, provided (i) `anchor.sHi ≥ true progress at anchor.tSeconds`, (ii) `V_LINE ≥ true max speed`, (iii) `nowSeconds` shares the anchor's clock and `t` is elapsed-since-last-true-fix. Every late fire is a violation of exactly one of (i)/(ii)/(iii).
- **I2 (forward-only overbound):** the anchor is pushed forward by accuracy (`sHi = sMeters + accuracyMeters`), never backward.
- **I3 (monotonic anchor time):** `onAcceptedFix` never moves the anchor to an earlier `tSeconds` (`reachability.dart:410`).
- **I4 (dead-reckon isolation):** a `Position` with `accuracy ≥ 9999` never re-anchors (`alarm_controller.dart:414–416`); `t` keeps growing through a blackout.
- **I5 (cap can only tighten):** when active, `sMax = min(freeRun, capped)` — the topology cap can only *reduce*, never inflate, the bound (`reachability.dart:281`).
- **I6 (fire-forcing propagates):** a `+infinity` bound must reach the evaluator and force a fire; only NaN is dropped (`alarm_controller.dart:1143`, `reachability.dart:355`).
- **I7 (dt ≥ 0):** elapsed time is clamped non-negative (`reachability.dart:251`), so the bound never *decreases* with a clock hiccup.

---

### Interfaces

**Consumes:**
- `Position.accuracy` and `Position.timestamp` from the location pipeline (`location_stream_handler.dart`) — the accuracy sentinel (9999) and the fix timestamp gate the re-anchoring.
- `context.progressMeters` — arc-progress from the snap/EKF pipeline; used as the anchor `sMeters` and as the `deadReckonedProgressMeters` baseline. (During a blackout this is EKF.s.)
- `context.ekfSigmaS` → the σ-cushion; `TransitLegStops.lineName / stopMeters / legEndMeters` → `V_LINE` resolution and the (dormant) topology.
- `AppClock().now()` — the monotonic wall clock for `nowSeconds`.
- `FireDecisionConfig` constants — `fractileK`, `maxFractileSigmaMeters`, `deadReckonAccuracySentinel`.

**Exposes:**
- `reachBoundMeters` → `AlarmEvaluator.evaluateCoinciding(reachableProgressBoundMeters:)`, which drives the actual fire decision on the metro-stops, metro-60%-rule, fallback, and metro-time-mode paths.
- `TelemetryService.reachabilityActivated(dtSeconds, boundMeters, deadReckonedMeters, watchdog)` — the reliability-funnel signal (`HANDOFF.md:82`) recorded when `reachBound − progress > 50 m`, doubling as the crowdsourced per-line speed-calibration feed.
- `VLineTable` is additionally consumed by `ios_backstop_planner.dart` for earliest-arrival scheduled-notification backstops (a separate subsystem).

**Downstream siblings it depends on being correct:** the accuracy gate in `location_manager` / EKF phantom-fix rejection (guarantees the anchor `s0` is a real fix, precondition i) and the snap-to-route arc-length computation (guarantees `sMeters`/`progressMeters` are true route arc-progress).

---

### Gaps & flaws vs the core promise (brutally honest)

1. **The two "tightening" levers are both off — users feel the raw, loosest bound.** The topology cap is disabled (`dwellMinSeconds = 0`, flaw #5) and the T_max watchdog is unarmed (`hardTMaxSeconds = null`, flaw #7). In the shipped app, `sMaxMeters == freeRun == sHi + V_LINE·t`, full stop. The elegant machinery documented in the file header (stop-count cap "the real UX lever") does not execute. Consequence: on a long blackout the alarm can fire *many* minutes early (bounded only by `V_LINE·t` vs the σ-cushion). This is safe (never late) but the early-firing is worse than the design implies, and the dormant code is untested in the real fire path.

2. **`V_LINE` resolution is a brittle string match, and it is the load-bearing precondition.** With `city` never passed (always `null`), RRTS detection depends solely on `leg.lineName` containing hard-coded tokens. A mislabeled or differently-named fast regional service silently resolves to a *lower* ceiling than its true speed — a direct late-fire path for exactly the highest-speed lines (the ones where late-firing is most likely). There is no telemetry that flags "V_LINE looked suspiciously low for the observed speed."

3. **Whole alarm modes have zero reachability protection.** The reach bound is computed at `alarm_controller.dart:1115`, *after* the controller's own **distance-mode** blocks (lines 505–633, 836–974) and **non-metro time-mode destination** block (lines 743–828) have already early-returned. Those paths compare **raw `progressMeters`** (or ETA) to the threshold with no physics inflation. Additionally, inside the evaluator the **non-metro leg 60%-rule branch** (`alarm_evaluator.dart:1107–1346`) never calls `effectiveProgress`. So: a rider in **distance mode** ("wake me 1 km before") whose GPS dies gets a **late fire** if dead-reckoned progress lags — with no reachability backstop at all. The never-late guarantee is real *only for the metro stops/time paths*, which is the core promise's centre, but it is **not** a whole-app property, and the code comments oversell it as universal.

4. **The reachability guarantee is only as good as `progressMeters` (arc-progress) itself.** The PL over-bounds *progress along the route*; it says nothing about whether the rider is on the right route. If snapping put the anchor on the wrong branch, or arc-length is miscomputed, `sHi` is wrong and I1 breaks silently. Reachability trusts, and cannot verify, the snap subsystem.

5. **First-tick real fix is dropped by the monotonic guard (flaw #4), leaving a zero-accuracy seed as the anchor for one tick.** Bounded (~one fix-accuracy, ~one tick) but a genuine, currently-unmitigated softening of precondition (i) at the moment tracking starts.

6. **Dead/misleading code invites future regressions.** `RouteTopology.dwellMinSeconds` is never read (flaw #6); `Reachability.reachesTarget` is unused in `lib/`; the corrupt-input `+infinity` valve and the watchdog `+infinity` valve are effectively unreachable in production. This is a maintenance hazard: the shipped behaviour is a small, always-finite-free-run subset of what the module appears to offer, so tests that exercise the caps/watchdog are proving properties the app never actually uses.

7. **Clock-source duality.** The anchor timestamp comes from `currentPosition.timestamp` (device/GPS clock) while `nowSeconds` comes from `AppClock().now()`. If those clocks diverge (device time adjustment, NTP correction), `dt` could be mis-measured. The `fixTs` sanity gate (finite, `≤ nowSec`, `< 3600 s` stale) mitigates gross cases, but a modest skew feeds directly into `s_max` and is not independently monitored.
