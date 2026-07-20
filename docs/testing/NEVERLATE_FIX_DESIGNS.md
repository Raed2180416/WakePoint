# GeoWake — Never-Late / Too-Early P0 Fix Designs (verified handoff)

> Produced 2026-07-20 by a design + adversarial-refute workflow (16 agents). Each
> design is minimal, cites exact file:line, and carries a never-late proof + the
> verdicts of 3 independent skeptics (late-hunter / too-early-hunter / implementability).
> The 395-ride oracle (`test/scale/reachability_scale_test.dart`) is the acceptance gate.

> **NOTE:** a concurrent session applied the P0-03 piecewise-V_LINE fix to
> reachability.dart + alarm_controller.dart during authoring; verify current source
> before applying (anchors may have shifted).


---

## P0-01-vline-collision

**Verdict: APPLY (never-late proven monotone; bounded too-early tradeoff accepted per prime-directive #1). Verify EDIT-9 call-site anchors.**

- risk=low implementable=True root_cause_confirmed=True
- files: ['/home/raed/Projects/WakePoint/lib/core/reachability/reachability.dart', '/home/raed/Projects/WakePoint/lib/services/transfer_utils.dart', '/home/raed/Projects/WakePoint/lib/services/tracking/alarm_controller.dart', '/home/raed/Projects/WakePoint/test/reachability/reachability_test.dart']

### Patch
```
Thread Google Directions vehicle.type onto the leg and add a NAME-FREE vehicle-class tier to forLine that can only RAISE V_LINE (max-combined with the keyword tier). 6 edits.

--- EDIT 1  lib/core/reachability/reachability.dart:130-136 (replace forLine + add helper) ---
Replace the body of `double forLine({String? city, String? lineName})` with a version that also accepts vehicleType and takes the MAX (never-late) of the keyword tier and a vehicle-class floor:

  double forLine({String? city, String? lineName, String? vehicleType}) {
    final o = overrides[_key(city, lineName)];
    if (o != null && o.isFinite && o > 0) return o; // operator-certified pin wins
    // Keyword tier (existing behaviour).
    double kw;
    if (looksRrts(city) || looksRrts(lineName)) {
      kw = rrtsMps;
    } else if (looksExpress(lineName) || looksExpress(city)) {
      kw = expressMps;
    } else {
      kw = defaultMps;
    }
    // Name-FREE vehicle-class floor from Google Directions vehicle.type. This is
    // independent of the collidable line name, so it closes the "fast line with a
    // slow name" hole (Mumbai Suburban as "Western Line" = HEAVY_RAIL). Both kw and
    // the floor are OVER-BOUND claims; taking the larger is always never-late-safe.
    final vFloor = _vehicleCeiling(vehicleType);
    return (vFloor != null && vFloor > kw) ? vFloor : kw;
  }

  /// Name-free V_LINE floor from the Google Directions `vehicle.type`. Returns the
  /// smallest ceiling that over-bounds the FASTEST admissible service in that
  /// Google vehicle class (precondition ii), or null for classes fully covered by
  /// `defaultMps`. Google lumps suburban EMUs and 160 km/h mainline expresses both
  /// under HEAVY_RAIL, so never-late forces the class-max (RRTS ceiling).
  static double? _vehicleCeiling(String? vehicleType) {
    if (vehicleType == null) return null;
    switch (vehicleType.trim().toUpperCase()) {
      case 'HIGH_SPEED_TRAIN':
      case 'LONG_DISTANCE_TRAIN':
        return absoluteCeilingMps; // ~200 km/h
      case 'HEAVY_RAIL':
      case 'RAIL':
      case 'COMMUTER_TRAIN':
        return rrtsMps; // 53 m/s (~190 km/h): certified above every Indian urban+regional rail top speed
      default:
        // SUBWAY / METRO_RAIL / MONORAIL / TRAM / LIGHT_RAIL / unknown → conventional
        // metro/tram; defaultMps (28 m/s / 100 km/h) already over-bounds. No lift, so
        // a genuine 90 km/h metro named "Orange" (Nagpur) is NOT over-fired.
        return null;
    }
  }

--- EDIT 2  lib/services/transfer_utils.dart  (TransitLegStops field) ---
After `final String? cityKey;` (line 65) add:
  /// GAP #9: Google Directions `transit_details.line.vehicle.type` (SUBWAY,
  /// HEAVY_RAIL, RAIL, COMMUTER_TRAIN, ...). A NAME-FREE V_LINE signal: a fast
  /// service reported with a slow/generic line name (Mumbai Suburban "Western
  /// Line") is HEAVY_RAIL here, so [VLineTable.forLine] can lift V_LINE off the
  /// 28 m/s metro default and stay never-late during a blackout on that leg.
  final String? vehicleType;

--- EDIT 3  lib/services/transfer_utils.dart:127-128 (constructor) ---
Add `this.vehicleType,` alongside `this.cityKey,`.

--- EDIT 4  lib/services/transfer_utils.dart:145 (toJson) ---
After `if (cityKey != null) 'cityKey': cityKey,` add:
    if (vehicleType != null) 'vehicleType': vehicleType,

--- EDIT 5  lib/services/transfer_utils.dart:182 (fromJson) ---
After `cityKey: m['cityKey'] as String?,` add:
      vehicleType: m['vehicleType'] as String?,

--- EDIT 6  lib/services/transfer_utils.dart:216 + :229 (copyWith) ---
Add param `String? vehicleType,` and body `vehicleType: vehicleType ?? this.vehicleType,`.
(The diverged branch at 1677 uses copyWith, so it now preserves vehicleType automatically.)

--- EDIT 7  lib/services/transfer_utils.dart:993-1024 (extractTransitLegStops populate) ---
At line 993 the `line` map is already extracted. Immediately after `final lineName = ...` (line 994) add:
          final vehicleType =
              ((line?['vehicle'] as Map<String, dynamic>?)?['type'])?.toString();
Then in the `TransitLegStops(...)` built at lines 1014-1024 add:
              vehicleType: vehicleType,

--- EDIT 8  lib/services/transfer_utils.dart:1679-1692 (preserve through OSM enhancement) ---
In the fresh `TransitLegStops(...)` (non-diverged branch) add:
                vehicleType: leg.vehicleType,
(Without this the enhanced leg — the one tracking actually uses — drops the type.)

--- EDIT 9  lib/services/tracking/alarm_controller.dart:346, 938, 1408 (pass it) ---
All three call sites change from
    _reach.vLineTable.forLine(city: <leg>.cityKey, lineName: <leg>.lineName)
to
    _reach.vLineTable.forLine(city: <leg>.cityKey, lineName: <leg>.lineName, vehicleType: <leg>.vehicleType)
(346: leg  /  938: leg  /  1408: l)

SCOPE NOTE (honest): this deterministically closes every leg Google types as HEAVY_RAIL/RAIL/COMMUTER_TRAIN (Mumbai/Chennai/Kolkata suburban, mainline, RRTS-if-typed-commuter). The residual is a line Google types as SUBWAY yet running >100 km/h with a fully generic name (Delhi Airport Express reported only as "Orange", type SUBWAY) — unresolvable by any name/type signal without over-firing Nagpur's genuine 90 km/h "Orange" metro; that remains the (city,line) dataset/override follow-up, unchanged by this fix (no regression).
```

### Never-late proof
The change can only RAISE V_LINE, and the reach bound is monotone non-decreasing in V_LINE, so firing time can only move EARLIER or stay equal — never later.

(1) Monotonicity of the raise: forLine now returns max(kw, vFloor) where kw is the pre-existing keyword result and vFloor∈{null (→ignored), rrtsMps, absoluteCeilingMps}. Hence new V_LINE ≥ old V_LINE for every (city, lineName, vehicleType). The operator override still short-circuits first (unchanged).

(2) Monotonicity of the bound in V_LINE: in Reachability.bound, freeRun = anchor.sHi + v·dtClamped with dtClamped = max(0, dt) ≥ 0, so ∂freeRun/∂v ≥ 0. Both tightening paths take min(freeRun, capped) where capped (_topologyCappedProgress / _fastestFeasibleProgress) is itself non-decreasing in v (every teleport/cell speed is v or a min() against v). Therefore sMaxMeters is non-decreasing in v, and reachesTarget (sMax ≥ target) flips to true no later than before. Firing time is non-increasing → never-late is preserved by construction.

(3) Precondition (ii) still holds — the new ceilings over-bound true max: HEAVY_RAIL/RAIL/COMMUTER_TRAIN → rrtsMps = 53 m/s (190 km/h), which reachability.dart:63-65 already certifies as 'Above every Indian urban+regional rail service's true top speed'; Mumbai Suburban's true ~120 km/h (33.3 m/s) ≪ 190. HIGH_SPEED/LONG_DISTANCE → absoluteCeilingMps = 56 m/s (200 km/h). Since Google merges suburban EMUs and 160 km/h mainline expresses under one HEAVY_RAIL label, choosing the class-max is the only never-late-correct assignment. Preconditions (i) anchor-is-real-fix and (iii) wall-clock-since-true-fix are untouched (no anchor/clock code changes).

Net: for every leg, V_LINE(new) ≥ V_LINE(old) ⇒ s_max(new) ≥ s_max(old) ≥ true progress at all t. No path can under-bound where it previously bounded.

### Too-early impact
No regression to the two-sided window; the 395-scale too-early distribution is provably unchanged, and new earliness is confined to blackouts of the specific fast lines that were previously at LATE risk.

Why the 395-scale test is unaffected: (a) the scale test injects each ride's certified V_LINE as an explicit override, so forLine's keyword/vehicle tiers are never exercised there — this patch cannot move any scale-test number; and (b) on healthy GPS the reach bound is INERT: with a fresh anchor dt≈0 ⇒ freeRun ≈ sHi ≈ current progress, and effectiveProgress = max(statistical, reach) is dominated by the EKF statistical path, so raising V_LINE changes nothing until GPS is actually lost.

Where earliness can grow: only during a GPS blackout on a leg whose vehicleType lifted its V_LINE (HEAVY_RAIL/RAIL/COMMUTER/HIGH_SPEED). There, the free-run cone widens (e.g. 53 vs 28 m/s) so the alarm fires earlier than before — but 'before' on those exact legs was a LATE-fire hazard, so this trades a rejected catastrophic-late outcome for a bounded early one, strictly on the safe side of the prime directive. Genuine metro/tram legs (SUBWAY/METRO_RAIL/MONORAIL/TRAM/LIGHT_RAIL) get vFloor=null ⇒ identical V_LINE ⇒ identical earliness (Nagpur 'Orange' metro is NOT over-fired). The stop-count topology cap continues to tighten the widened cone on stopping services, further limiting the blackout earliness.

### Regression test
Add to test/reachability/reachability_test.dart inside the existing VLineTable group (the file already defines _TrainSim, used at ~line 548). Two deterministic tests — the scale oracle cannot catch this because it injects a certified V_LINE override, bypassing forLine.

test('vehicleType lifts a fast line with a slow (collidable) name — GAP #9', () {
  const table = VLineTable();
  // Mumbai Suburban surfaced by Google as "Western Line": no express/rrts keyword.
  expect(table.forLine(lineName: 'Western Line'), VLineTable.defaultMps,
      reason: 'name-only path under-bounds — documents the hole');
  final v = table.forLine(lineName: 'Western Line', vehicleType: 'HEAVY_RAIL');
  expect(v, greaterThanOrEqualTo(33.4),
      reason: 'HEAVY_RAIL must over-bound a 120 km/h (33.3 m/s) EMU');
  expect(v, VLineTable.rrtsMps);
  // Lift is monotone: a genuine metro vehicleType never lowers a keyword tier.
  expect(table.forLine(lineName: 'Namo Bharat', vehicleType: 'SUBWAY'),
      VLineTable.rrtsMps);
  // Genuine metro named "Orange" (Nagpur) is NOT over-fired.
  expect(table.forLine(lineName: 'Orange', vehicleType: 'SUBWAY'),
      VLineTable.defaultMps);
});

test('vehicleType keeps a 120 km/h suburban EMU with a slow name never-late', () {
  const table = VLineTable();
  final vGood = table.forLine(lineName: 'Western Line', vehicleType: 'HEAVY_RAIL');
  final vBad = table.forLine(lineName: 'Western Line'); // name-only → 28 m/s
  final sim = _TrainSim(trueMaxMps: 33.3, stationMeters: const [], seed: 7);
  for (int i = 0; i < 5; i++) sim.step();
  final anchor = ReachabilityAnchor(
      sMeters: sim.progress, accuracyMeters: 10.0, tSeconds: sim.t);
  bool badUnderestimated = false;
  for (int i = 0; i < 400; i++) {
    sim.step();
    final safe = Reachability.bound(
        anchor: anchor, nowSeconds: sim.t, vLineMps: vGood);
    final bad = Reachability.bound(
        anchor: anchor, nowSeconds: sim.t, vLineMps: vBad);
    expect(safe.sMaxMeters, greaterThanOrEqualTo(sim.progress - 1e-6),
        reason: 'vehicleType-resolved ceiling stays never-late at t=${sim.t}');
    if (bad.sMaxMeters < sim.progress - 1.0) badUnderestimated = true;
  }
  expect(badUnderestimated, isTrue,
      reason: 'the name-only 28 m/s default is a real late-fire hazard here');
});

A regression that dropped vehicleType from the leg (e.g. omitting EDIT 8 in the OSM path) is caught by an integration assertion: build a leg via extractTransitLegStops from a directions fixture whose transit step has line.vehicle.type='HEAVY_RAIL' and generic name, run it through enhanceTransitLegStopsWithOsm, and assert the resulting leg.vehicleType == 'HEAVY_RAIL'.

### Refute verdicts

- **LATE-RISK** (action: implement-with-changes)
  - late counterexample: iOS rider on Mumbai Suburban. Google Directions returns line name "Western Line" (no express/rrts/suburban keyword hit) with transit_details.line.vehicle.type = "HEAVY_RAIL"; true top speed ~120 km/h (33.3 m/s). The patch raises the IN-APP reach V_LINE to rrtsMps=53 at alarm_controller.dart:346/938/1423/1428, but it does NOT touch the fourth never-late fire path: IosBackstopPlanner._earliestArrivalEpochMs (lib/services/ios/ios_backstop_planner.dart:232), which resolves V_LINE via forLine(city, lineName) with NO vehicleType and is unchanged by the patch (files_touched omits the file; grep '\.forLine(' shows 6 sites, EDIT 9 names 3 with a wrong line number — "1408" is a comment). Sequence: leg armed with ~12 km remaining -> backstop notification scheduled at now + 12000/28 = now+428 s (name-default 28 m/s). iOS suspends the process; in the final crowded-cell/tunnel stretch no GPS fix arrives so the geofence rings never trip, leaving the TIME backstop as the sole net. The train runs at 33.3 m/s and actually arrives at now+360 s; the rider is woken at now+428 s = ~68 s / ~2.3 km PAST the target stop. The patched app fires LATE on exactly the HEAVY_RAIL suburban leg the patch's scope note claims to "deterministically close." The in-app reach core is correctly raised, but on iOS the never-late guarantee during suspension lives in the unpatched backstop planner.
  - too-early: No never-late-side regression, and the 395-ride scale oracle is provably unaffected (test line 104 injects each ride's certified ceiling as a per-line override, which short-circuits forLine before any keyword/vehicle tier runs). However the patch UNDERSTATES its too-early expansion: it frames HEAVY_RAIL/RAIL/COMMUTER_TRAIN as suburban/mainline, but several genuine ~80-90 km/h Indian metros surface under those same types (metro_vehicle_types.dart notes HEAVY_RAIL/RAIL/METRO_RAIL and even LIGHT_RAIL are used for real metros; _isMetroTransitStep already accepts them). Under EDIT 1 those genuine metros jump from defaultMps=28 to rrtsMps=53, firing ~1.9x early on any blackout — safe (never-late) but broader than the "Mumbai/Chennai/Kolkata suburban only" claim, and invisible to the override-injecting scale test. This is a cost worth disclosing, not a late regression.
- **NEEDS-REWORK** (action: implement-with-changes)
  - late counterexample: No NEW late fire is introduced (forLine is a monotone raise: max(kw, vFloor), and every bound consumer is non-decreasing in v). However, the patch as specified can leave a PERSISTING late fire on the main production path: EDIT 9 mislabels the call sites ("346, 938, 1408") when the in-blackout path at alarm_controller.dart:1418-1456 actually has TWO forLine calls — 1423 (scalar vMaxFwd) and 1428 (per-leg vSegments). Reachability.bound uses the scalar only as tailV (coast PAST the last segment boundary, reachability.dart:534-541); the CURRENT leg's blackout speed comes from the segment built at 1428. Concrete scenario: rider on a Mumbai Suburban leg surfaced as "Western Line", type HEAVY_RAIL (true ~120 km/h = 33.3 m/s); GPS blackout mid-leg. If the implementer follows EDIT 9 literally (patches the scalar vMaxFwd at 1423 but not the segment builder at 1428, which the design points at as phantom line "1408, single site l"), _piecewiseFreeRun marches the current leg at the un-lifted segment ceiling forLine("Western Line")=28 m/s, under-bounds the 33.3 m/s EMU, and the patched app STILL fires LATE — the finding's hole stays open despite the patch appearing applied. Also unpatched: ios_backstop_planner.dart:232 (iOS backstop still under-bounds).
  - too-early: Real bounded inflation, and the design's scope claim is inaccurate. _vehicleCeiling maps COMMUTER_TRAIN/RAIL/HEAVY_RAIL -> rrtsMps=53 m/s, lifting the ENTIRE class including genuinely slow 60-90 km/h commuter/suburban services that were NEVER at late risk at the 28 m/s (100 km/h) default. On a GPS blackout on such a leg the free-run cone nearly doubles (28->53) -> up to ~2x-earlier fire. The design states earliness grows 'strictly on legs previously at LATE risk' — that is false for slow COMMUTER_TRAIN legs, which had no late risk yet get inflated. Mitigations are genuine and confirmed: the 395-scale distribution is untouched (the oracle injects certified V_LINE overrides, bypassing forLine entirely), and on healthy GPS the bound is inert (FINDING-3 gate at alarm_controller.dart:1466-1469 + EKF statistical dominance), so inflation manifests only during actual blackouts. It is on the SAFE side of the prime directive (no new late risk, class-max is the only never-late-correct name-free assignment), so not a rejecting TOO-EARLY-REGRESSION by itself — but it exceeds the finding's 'fast-line-slow-name' scope and must be disclosed accurately.
- **NEEDS-REWORK** (action: implement-with-changes)
  - late counterexample: None found as a REGRESSION: forLine now returns max(kw, vFloor) so new V_LINE >= old V_LINE pointwise, and every consumer (sHi+v*dt free-run at reachability.dart:541, _piecewiseFreeRun:656, _topologyCappedProgress:601, min(freeRun,_fastestFeasibleProgress):569) is monotone non-decreasing in v, so firing is never later than baseline. Residual (NOT a regression): a genuine HIGH_SPEED_TRAIN >200 km/h maps to absoluteCeilingMps=56 m/s and would still under-bound a true 300 km/h HSR (~83 m/s) -> late; but baseline (28/39 m/s) was strictly worse, and it is out of current Indian scope. The proof's absolute claim 'the new ceilings over-bound true max' is therefore an overclaim, though it introduces no new late risk.
  - too-early: No regression to the 395-ride oracle: the scale test injects each ride's certified V_LINE as an override, which short-circuits forLine at reachability.dart:132 before any tier logic, so the tier is never exercised and the too-early distribution is provably unchanged. Production earliness grows only during GPS blackouts on legs Google types HEAVY_RAIL/RAIL/COMMUTER_TRAIN (previously late-risk), which is the intended safe-side trade. One unstated caveat: a genuinely slow line mistyped by Google as HEAVY_RAIL is lifted 28->53 m/s (~2.4x cone) on a blackout -> bounded gratuitous earliness, tightened by the stop-count cap; acceptable but not called out.

---

## P0-02-8s-window

**Verdict: HOLD (narrow late gain vs healthy-GPS too-early risk on fast lines; refuters split). Log-only unless reworked.**

- risk=low implementable=True root_cause_confirmed=True
- files: ['/home/raed/Projects/WakePoint/lib/config/fire_decision_config.dart', '/home/raed/Projects/WakePoint/lib/services/tracking/alarm_controller.dart', '/home/raed/Projects/WakePoint/test/config/fire_decision_config_test.dart']

### Patch
```
Root cause: the reach-bound suppression gate uses a FLAT 8s window (FireDecisionConfig.reachBlackoutMinSeconds). During dt<8s the fire rests on dead-reckon (ekf_pipeline.dart:135 clamps velocity to +/-25 m/s) + sigma cushion. On a fast line V_LINE=39/53 >> the 25 m/s DR clamp, so the DR path under-progresses by (V_LINE-25)*dt while the target sits within V_LINE*8 of the anchor => late. Metros are safe only because their V_LINE (28) barely exceeds the 25 clamp (gap (28-25)*8 = 24 m, covered by the cushion; certified by the 391-ride scale oracle). Fix = make the window per-line so no line's suppressed DR-gap exceeds the metro-proven 24 m budget. Option (b), exact measure (no magic number). Physics bound math, anchor bookkeeping, and preconditions are UNTOUCHED.

EDIT 1 — lib/config/fire_decision_config.dart, insert immediately AFTER line 51 (the reachBlackoutMinSeconds = 8.0 declaration), inside the class:

  /// Dead-reckon velocity clamp (m/s), mirrored from EkfPipeline (ekf_pipeline.dart
  /// :135/:229/:240/:620 clamp _v to +/-25). During a blackout the statistical
  /// (dead-reckoned) progress advances no faster than this, so on a line whose
  /// V_LINE exceeds it the DR path UNDER-progresses vs the true train and the
  /// physics reach bound must take over sooner than the flat 8 s window.
  static const double deadReckonVelocityClampMps = 25.0;

  /// Max distance the DR path may lag the physics bound while reach is suppressed.
  /// = reachBlackoutMinSeconds(8) * (VLineTable.defaultMps(28) - clamp(25)) = 24 m,
  /// i.e. exactly the gap a conventional metro already carries at the 8 s window,
  /// which the 391-ride scale oracle certifies the sigma cushion covers with no
  /// late fire. Holding every faster line to the same 24 m gap closes the fast-line
  /// blackout-onset hole while leaving metro fire decisions byte-identical.
  static const double reachBlackoutGapBudgetMeters = 24.0;

  /// Per-line blackout window before the physics reach bound is un-suppressed.
  /// Flat 8 s only for V_LINE <= 25; for a fast line the window shrinks so the
  /// worst-case suppressed DR gap (V_LINE-clamp)*window <= 24 m. Returns:
  /// 28 -> 8.0 s (metro, unchanged); 39 -> 1.71 s; 53 -> 0.857 s; 56 -> 0.77 s.
  static double reachBlackoutMinSecondsForVLine(double vLineMps) {
    if (!vLineMps.isFinite || vLineMps <= deadReckonVelocityClampMps) {
      return reachBlackoutMinSeconds;
    }
    final w = reachBlackoutGapBudgetMeters / (vLineMps - deadReckonVelocityClampMps);
    return w < reachBlackoutMinSeconds ? w : reachBlackoutMinSeconds;
  }

EDIT 2 — lib/services/tracking/alarm_controller.dart:957 (distance/non-metro-time modes path; V_LINE in scope = vMaxModes):
  replace  `bb.dtSeconds >= FireDecisionConfig.reachBlackoutMinSeconds)) {`
  with     `bb.dtSeconds >= FireDecisionConfig.reachBlackoutMinSecondsForVLine(vMaxModes))) {`

EDIT 3 — lib/services/tracking/alarm_controller.dart:1469 (metro-stops path; V_LINE in scope = vMaxFwd):
  replace  `b.dtSeconds >= FireDecisionConfig.reachBlackoutMinSeconds)) {`
  with     `b.dtSeconds >= FireDecisionConfig.reachBlackoutMinSecondsForVLine(vMaxFwd))) {`

No change to ekf_pipeline.dart (the 25 m/s DR clamp is a safety guard against runaway-velocity spikes; the physics reach is the designed mechanism to cover the gap, so it takes over instead of loosening the clamp).
```

### Never-late proof
effectiveProgress = max(statistical, reach) at every eval. The physics reach (sHi + piecewise V_LINE*dt) is an UPPER bound on true progress at all times (preconditions i-iii and the bound math are untouched), so whenever reach is FED, effectiveProgress >= true => never late. The ONLY late window is while reach is SUPPRESSED (dt < window). PROOF OF NO REGRESSION: for every V_LINE, reachBlackoutMinSecondsForVLine(V) <= reachBlackoutMinSeconds (8 s) — it returns 8 for V<=25/28 and strictly less above — so the suppression window can only SHRINK or stay equal. A shorter window feeds reach EARLIER, and effectiveProgress is monotone non-decreasing in feeding reach earlier, so the fire time is <= the previous fire time at every (ride,t): the change can never make any fire later than before, hence cannot introduce a late fire (fires strictly never-later). PROOF THE HOLE CLOSES: by construction window = 24 / (V_LINE-25), so the worst-case distance the DR path can under-progress vs the physics bound during suppression is (V_LINE-25)*window <= 24 m for every line — the exact gap the metro carries at 8 s that the scale oracle certifies the cushion covers. Every fast line is thus held to a DR gap no larger than the metro's proven-safe gap and inherits its never-late margin; past the (short) window the late-proof physics bound governs. Only the suppression predicate changes — never the anchor, the bound, or the preconditions.

### Too-early impact
Metros (V_LINE <= 28, incl. the default line): reachBlackoutMinSecondsForVLine returns exactly 8.0 s = the current constant, so every metro fire decision is byte-identical => the 395-scale two-sided window and its too-early tail are UNCHANGED on the metro bulk (no early bias introduced on healthy-GPS metro fires — the stated constraint). Express/RRTS: reach is consulted after a shorter window, but (a) in the metro-stops path the fed bound is the piecewise per-leg reach that grows at the LOCAL leg's V_LINE near the anchor, so on a metro-anchored blackout with a downstream fast leg reach ~= dead-reckon and max() barely moves (~3*dt m); (b) any extra earliness is bounded by V_LINE*dt (<=~130 m) and only materialises during an ACTUAL blackout on a genuinely fast line whose inter-station spacing (RRTS ~5-10 km, express ~2-3 km) dwarfs it => strictly sub-stop, never egregiously early. Net: the 395-scale too-early metric cannot regress on metro rows and stays inside the accepted physics cone on fast rows.

### Regression test
New deterministic unit test (no external rides) test/config/fire_decision_config_test.dart:

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/config/fire_decision_config.dart';

void main() {
  group('reachBlackoutMinSecondsForVLine — fast-line blackout-onset hole', () {
    test('metro window is byte-identical 8s (no healthy-GPS early bias)', () {
      expect(FireDecisionConfig.reachBlackoutMinSecondsForVLine(28.0),
          FireDecisionConfig.reachBlackoutMinSeconds);
      expect(FireDecisionConfig.reachBlackoutMinSecondsForVLine(25.0),
          FireDecisionConfig.reachBlackoutMinSeconds);
    });
    test('every line holds the suppressed DR gap <= 24 m budget', () {
      const clamp = FireDecisionConfig.deadReckonVelocityClampMps;
      for (final v in <double>[28, 39, 53, 56]) {
        final w = FireDecisionConfig.reachBlackoutMinSecondsForVLine(v);
        expect((v - clamp) * w,
            lessThanOrEqualTo(FireDecisionConfig.reachBlackoutGapBudgetMeters + 1e-9),
            reason: 'V_LINE=$v leaves too large a suppressed gap');
      }
    });
    test('REGRESSION: RRTS target reached 7 s into a blackout is un-suppressed', () {
      const dt = 7.0; // old flat 8 s gate suppressed reach here -> LATE on RRTS
      expect(dt >= FireDecisionConfig.reachBlackoutMinSecondsForVLine(53.0), isTrue);
      // ...while the metro path stays suppressed at 7 s (unchanged).
      expect(dt >= FireDecisionConfig.reachBlackoutMinSecondsForVLine(28.0), isFalse);
    });
  });
}

Reverting EDIT 1-3 to the flat constant fails the gap-budget and RRTS-un-suppress assertions; a bad shrink of the metro window fails the byte-identical assertion. The existing 391-ride scale oracle (test/scale/reachability_scale_test.dart) is unaffected because it drives Reachability.bound directly and never exercises this controller gate.

### Refute verdicts

- **SAFE** (action: implement-with-changes)
  - late counterexample: None found that the PATCH introduces. Verified in-code: both edit sites FEED the physics reach bound when dt >= window (alarm_controller.dart:955-957 and :1466-1469), and reachBlackoutMinSecondsForVLine always returns a value in (0, 8] — exactly 8.0 for V<=28, and 24/(V-25) capped at 8 for V>28 — so the suppression window can only SHRINK, never grow, versus the flat-8s baseline. Reach is therefore fed at the same time or earlier for every V_LINE. Downstream consumption is monotone in feeding reach earlier: distance mode effProgress = max(reachBoundModes, progress) (:1148-1151), time mode ORs reachFireTime into the fire test (:1037-1063), metro-stops passes reachBoundMeters up as an upper bound. So the patched fire time is <= the pre-patch fire time at every (ride,t); since the baseline is the certified never-late core, no ride can be made late by this change — including GPS dying just before target, out-of-order fixes (blocked by the monotonic anchor guard at reachability.dart:882), process death, and fast-line blackout onset. PRE-EXISTING (not patch-introduced) late still stands: if a genuinely fast line is named as a slow metro so V_LINE misresolves to 28 (documented KNOWN RESIDUAL, reachability.dart:115-129), the window stays 8.0 AND the reach bound sHi+28*dt under-bounds a true 53 m/s train => late. The patch neither fixes nor worsens this precondition-(ii) hole, and its own regression test uses vLine=53 literals so it never exercises V_LINE resolution.
  - too-early: Negligible/none on the certified set. reachBlackoutMinSecondsForVLine(V) returns exactly FireDecisionConfig.reachBlackoutMinSeconds (8.0) for every V<=28 (metro/default): 24/(V-25) is >=8 for 25<V<=28 so min(.,8)=8, and V<=25 hits the early return. Metro fire decisions are byte-identical, so the 395-ride two-sided oracle (metro-dominated, injects certified V_LINE) cannot regress. For genuinely fast lines the shorter window feeds reach earlier only during an ACTUAL blackout; earliness is bounded by V_LINE*window and further muted because the metro-stops path feeds a PIECEWISE per-leg bound (reach ~= dead-reckon near a slow-leg anchor, so max() barely moves), and inter-station spacing (express ~2-3 km, RRTS ~5-10 km) dwarfs it => sub-stop, not egregiously early. Note the gate sizes the window to the FLAT fastest leg (vMaxFwd/vMaxModes) while the reach bound uses piecewise segments — conservative (earliest reach), so any bias is toward early (safe), never late.
- **TOO-EARLY-REGRESSION** (action: implement-with-changes)
  - late counterexample: none found — the never-late proof is sound. effectiveProgress = max(statistical, reach) and reachBlackoutMinSecondsForVLine(V) <= 8s for every V (returns 8 for V<=28, strictly less above), so the suppression window can only shrink. Feeding reach earlier is monotone non-decreasing in effectiveProgress, hence every fire is <= its previous fire time at every (ride,t). The change is strictly never-later and cannot introduce a late fire.
  - too-early: The 8s reachBlackoutMinSeconds exists specifically to keep the reach bound INERT during the normal 1-5s gap between HEALTHY fixes (fire_decision_config.dart:43-51: "8 s sits just above the 5 s GPS-dropout buffer... a healthy ride does not fire ~V_LINE·dt early"). dt is wall-clock since the last real fix and is nonzero during healthy GPS too (cycles 0->gap->0). The patch shrinks the window BELOW that healthy-gap buffer for any V_LINE>~29.8: express V=39 -> 1.71s, RRTS V=53 -> 0.857s (below even a 1Hz GPS cycle, so reach activates on EVERY healthy fix interval). Concrete scenario: a healthy RRTS ride (GPS fine, normal 3-5s fix gaps) approaching/dwelling near the destination with v_true~0 and V_LINE=53. On a 5s gap, reach = sHi + 53*5 = ~265m ahead of the correctly dead-reckoned stationary position; effectiveProgress=max(DR,reach)=reach fires ~150-265m early. Under the current 8s gate reach stays suppressed here (dt<8) and the calibrated EKF+sigma window governs. This is precisely the "~V_LINE·dt early on a healthy ride" failure the 8s constant was built to prevent, now reintroduced for every fast line — and it falls OUTSIDE the finding's blackout-onset scope, which is the mandate's TOO-EARLY-REGRESSION trigger. dt alone cannot distinguish a fast-line blackout at dt=2s from a fast-line healthy gap at dt=2s. Critically, the 395-scale oracle is STRUCTURALLY BLIND to this: it drives Reachability.bound directly and never exercises this controller gate, so "the 395-scale metric cannot regress" is vacuous (the metric never measures the gate), not evidence of safety.
- **TOO-EARLY-REGRESSION** (action: implement-with-changes)
  - late counterexample: none found — never-late is provably safe. Every consumer of the fed reach bound is monotone fire-forcing: effectiveProgress = math.max(statistical, reach) with +inf winning (reachability.dart:818-841); modes path effProgress = max(reachBoundModes, progress) (alarm_controller.dart:1148-1151) and reachFireTime is an OR (:1063); metro path uses reachesTarget (sMax >= target, :812) and reachFirePre/reachFireMain ORs (alarm_evaluator.dart:275-277,395-397). No path lets a larger/earlier bound suppress a fire, so shrinking the suppression window only feeds reach earlier ⇒ fire time is monotone non-increasing at every (ride,t). The 395-ride scale oracle drives boundNow with reach ALWAYS on (no gate; _simFire test/scale/reachability_scale_test.dart:100-134) and already certifies never-late; the patch only moves the live path toward that certified always-on regime. No V_LINE, dt, or journey shape produces a later fire than current behavior.
  - too-early: REAL and under-analyzed by the design. The 8s gate was deliberately set ABOVE the 5s GPS-dropout coast buffer (fire_decision_config.dart:48-50) so the physics bound stays inert through NORMAL healthy-GPS coast gaps and does not fire ~V_LINE*dt early. The patch shrinks the window to 0.857s (V=53) / 1.71s (V=39), which falls INSIDE that healthy-coast band. Because vMaxModes (alarm_controller.dart:936) and vMaxFwd (:1403) are the journey-MAXIMUM V_LINE across all legs, the shrunk window applies even while the rider is on the metro leg of a MIXED metro+RRTS/express journey — so 'metros byte-identical' holds only for pure-metro routes, not mixed ones. Worst case is the modes/distance path: line 948 builds a FLAT free-run bound at vMaxModes with no piecewise vLineSegments, so a routine 5s healthy coast gap injects sHi + 53*5 ~= +265m of reach progress ahead of true position, biasing distance-mode fires early on healthy GPS (recurring every coast gap). The design's too_early_impact claim that this earliness 'only materialises during an ACTUAL blackout' is factually wrong: reach activates at any dt >= window, which includes normal sub-5s coasting the system treats as healthy. This regression is invisible to both guards — the scale oracle bypasses this controller gate entirely (drives boundNow directly), and the supplied unit test only checks the window arithmetic, never fire timing.

---

## P0-00-eta-backstop

**Verdict: REWORK (all 3 refuters: monotonic clock freezes in Doze while RTC alarm fires at wall time → LATE. Recompute physicsFireAt in WALL clock).**

- risk=low implementable=True root_cause_confirmed=True
- files: ['lib/services/tracking/alarm_controller.dart', 'lib/services/tracking/notification_updater.dart', 'lib/services/trackingservice.dart', 'test/notification_physics_backstop_test.dart']

### Patch
```
ROOT CAUSE (confirmed by source): notification_updater.dart:227 derives the OS setAlarmClock backstop fire time from context.smoothedETA ?? context.apiEtaSeconds. smoothedETA is a "seconds remaining from now" quantity recomputed ONLY on real GPS fixes; during a blackout it FREEZES while `now` advances, so fireAt = DateTime.now().add(etaSeconds - lead) marches continuously forward (postponed). On process death mid-blackout the only surviving wake is that stale-anchored RTC alarm -> LATE. The in-process reachability net (alarm_controller.dart:350-357, 1423-1445) already holds the never-late free-run bound + target + anchor + V_LINE but never publishes a physics fire INSTANT to the backstop. docs/AGENT_HANDOFF_E2E.md:739 claims the backstop is `now + remaining/V_LINE` — a docs-lie vs the code.

FIX: schedule the backstop at min(eta_based_time, physics_time). physics_time = the absolute wall-clock instant the free-run bound reaches the mode-aware fire target, computed from the FROZEN anchor so it does NOT drift during a blackout. Thread it transiently (no serialization) from AlarmController into BroadcastContext. Four small edits + one new test.

=== EDIT 1  lib/services/tracking/alarm_controller.dart ===

(1a) After line 124 (`  DateTime? _lastAlarmFiredAt;`) add the transient field + getter:

  // P0 BACKSTOP PHYSICS INSTANT: absolute wall-clock time at which the FREE-RUN
  // reach bound (s_max = anchor.sHi + V_LINE*dt) reaches the mode-aware fire
  // target, from the CURRENT anchor. Refreshed each tick; because it is anchored
  // to the last REAL fix it is a FIXED wall instant that does NOT postpone during
  // a GPS blackout (unlike a frozen ETA). Threaded (transient) into the broadcast
  // so the OS setAlarmClock backstop can be armed at min(eta_time, this) and thus
  // never fires later than the physics never-late instant on process death. Null
  // when no anchor / route geometry yet. See notification_updater._maybeRearmEtaBackstop.
  DateTime? _backstopPhysicsFireAt;

  /// Absolute wall-clock instant (AppClock.now()) of the physics never-late
  /// backstop, or null if not computable this tick.
  DateTime? get backstopPhysicsFireAt => _backstopPhysicsFireAt;

(1b) Immediately AFTER coldStartFireTargetMeters (after line 438, the closing `}`) add the pure never-late math + the tick refresh:

  /// Pure never-late backstop math (deterministic; no clock/OS reads): seconds
  /// from [nowSeconds] until the FREE-RUN bound reaches [targetMeters] starting
  /// from an anchor at ([anchorSHiMeters], [anchorTSeconds]) travelling at at most
  /// [vLineMps]. May be <= 0 (fire immediately). Returns null when a physics time
  /// cannot be proven (non-finite / non-positive speed) so the caller falls back
  /// to the ETA path. NEVER-LATE: see [backstopPhysicsFireAt] proof.
  @visibleForTesting
  static double? backstopPhysicsFireInSeconds({
    required double anchorSHiMeters,
    required double anchorTSeconds,
    required double targetMeters,
    required double vLineMps,
    required double nowSeconds,
  }) {
    if (!anchorSHiMeters.isFinite ||
        !anchorTSeconds.isFinite ||
        !targetMeters.isFinite ||
        !nowSeconds.isFinite ||
        !vLineMps.isFinite ||
        vLineMps <= 0) {
      return null;
    }
    // Instant the free-run bound hits the target, expressed relative to t_anchor.
    final double reachAfterAnchor = (targetMeters - anchorSHiMeters) / vLineMps;
    final double elapsed = nowSeconds - anchorTSeconds;
    // Seconds from NOW. As `nowSeconds` advances against the frozen anchor this
    // shrinks 1:1 with `elapsed`, so `now + result` is a FIXED wall instant
    // (the postpone bug is structurally impossible). Negative => fire now.
    return reachAfterAnchor - elapsed;
  }

  /// Refresh [backstopPhysicsFireAt] from the current anchor + route geometry.
  /// Mirrors maybeFireColdStartBackstop's target/V_LINE derivation EXACTLY so the
  /// backstop aims at the same fire point as the in-process net. Never throws.
  void _refreshBackstopPhysicsFireAt(AlarmContext context) {
    try {
      final anchor = _reach.anchor;
      final legs = context.transitLegs;
      if (anchor == null || legs.isEmpty) {
        _backstopPhysicsFireAt = null;
        return;
      }
      double totalMeters = double.nan;
      for (final leg in legs) {
        if (leg.legEndMeters.isFinite) {
          totalMeters = totalMeters.isNaN
              ? leg.legEndMeters
              : max(totalMeters, leg.legEndMeters);
        }
      }
      if (totalMeters.isNaN) {
        final destEvt = context.routeEvents.where((e) => e.type == 'destination');
        if (destEvt.isNotEmpty) totalMeters = destEvt.last.meters;
      }
      if (!totalMeters.isFinite || totalMeters <= 0) {
        _backstopPhysicsFireAt = null;
        return;
      }
      // Fastest V_LINE across all legs => valid upper bound on any leg (safe).
      double vMax = VLineTable.defaultMps;
      for (final leg in legs) {
        final v = _reach.vLineTable.forLine(city: leg.cityKey, lineName: leg.lineName);
        if (v.isFinite && v > vMax) vMax = v;
      }
      final target = coldStartFireTargetMeters(context, totalMeters, legs, vMax);
      final fireInSeconds = backstopPhysicsFireInSeconds(
        anchorSHiMeters: anchor.sHi,
        anchorTSeconds: anchor.tSeconds,
        targetMeters: target,
        vLineMps: vMax,
        nowSeconds: _nowSeconds(),
      );
      if (fireInSeconds == null) {
        _backstopPhysicsFireAt = null;
        return;
      }
      // Map the monotonic "seconds from now" onto the wall clock exactly as the
      // ETA path does (AppClock().now().add(...)), producing an absolute RTC
      // instant for setAlarmClock. Clamp to [0, 1000 days]; <=0 => fire ~now.
      final int secs = fireInSeconds.clamp(0.0, 8.64e7).round();
      _backstopPhysicsFireAt = AppClock().now().add(Duration(seconds: secs));
    } catch (_) {
      _backstopPhysicsFireAt = null; // fail toward the ETA path
    }
  }

(1c) In checkAndTriggerAlarm, immediately AFTER the anchor-maintenance block closes at line 605 (`    }`) and before the dev.log at 607, add:

    // Publish the physics never-late backstop instant for this tick (transient).
    _refreshBackstopPhysicsFireAt(context);

=== EDIT 2  lib/services/tracking/notification_updater.dart ===

(2a) In class BroadcastContext, after line 40 (`  final double? stepTotalMeters;`) add:

  /// Transient (never serialized) absolute wall-clock instant at which the
  /// physics free-run reach bound reaches the fire target, threaded from
  /// AlarmController. Arms the OS backstop at min(eta, physics) so a process
  /// death mid-blackout still wakes on time. Null => physics unavailable.
  final DateTime? backstopPhysicsFireAt;

(2b) In the BroadcastContext constructor add the param after line 58 (`    this.stepTotalMeters,`):

    this.backstopPhysicsFireAt,

(2c) Replace the body of _maybeRearmEtaBackstop from line 227 through line 253 (the `final etaSeconds = ...` down to the final scheduleEtaBackstop call) with min(eta, physics):

      final now = DateTime.now();

      // (a) ETA-based candidate. During a blackout smoothedETA FREEZES, so this
      // instant marches forward (postponed) — the P0 late bug when it is the only
      // survivor of process death.
      DateTime? etaFireAt;
      final etaSeconds = context.smoothedETA ?? context.apiEtaSeconds;
      if (etaSeconds != null && etaSeconds > 0) {
        final leadSeconds = backstopLeadSeconds(
          context.alarmMode ?? '',
          context.alarmValue ?? 0.0,
        );
        etaFireAt = now.add(Duration(seconds: (etaSeconds - leadSeconds).round()));
      }

      // (b) PHYSICS candidate: the free-run never-late instant, anchored to the
      // last real fix => a FIXED wall time that does NOT drift during a blackout.
      final DateTime? physicsFireAt = context.backstopPhysicsFireAt;

      // Earliest available candidate. min() can only move the fire EARLIER; the
      // physics instant is proven <= true arrival (never-late), so the armed OS
      // alarm can never be later than physics even if the process then dies.
      DateTime? fireAt;
      for (final c in <DateTime?>[etaFireAt, physicsFireAt]) {
        if (c == null) continue;
        if (fireAt == null || c.isBefore(fireAt)) fireAt = c;
      }
      if (fireAt == null) return; // nothing to arm

      // Never schedule in the past — a dying process must still get a wake.
      final earliest = now.add(const Duration(seconds: 2));
      if (fireAt.isBefore(earliest)) fireAt = earliest;

      await NotificationService().scheduleEtaBackstop(
        fireAt: fireAt,
        title: 'Approaching ${context.destinationName ?? 'your stop'}',
        body: 'Wake up — you are almost there.',
      );

(This preserves prior behaviour when physicsFireAt is null; when eta is null but physics is present it now still arms — a strict improvement.)

=== EDIT 3  lib/services/trackingservice.dart ===

Inside the BroadcastContext(...) built in _broadcastSimulationState, after line 717 (`      stepTotalMeters: _lastComputedStepTotalMeters,`) add:

      backstopPhysicsFireAt: _alarmController.backstopPhysicsFireAt,

=== EDIT 4  NEW FILE  test/notification_physics_backstop_test.dart ===  (see regression_test field)
```

### Never-late proof
The armed backstop is min(etaFireAt, physicsFireAt); min never moves the fire LATER than physicsFireAt, so it suffices that physicsFireAt is never-late.

physicsFireAt = now + f, where f = backstopPhysicsFireInSeconds = (target - anchor.sHi)/V_LINE - (nowSeconds - anchor.tSeconds), all on the same monotonic clock (_nowSeconds), then mapped to wall via AppClock().now() (identical to the existing ETA path). The absolute monotonic fire instant is therefore t_reach = anchor.tSeconds + (target - anchor.sHi)/V_LINE.

Claim: true arrival at `target`, t_arrival, satisfies t_arrival >= t_reach. Proof: the free-run bound s_max(t) = anchor.sHi + V_LINE*(t - anchor.tSeconds) is a proven UPPER bound on true arc-progress under reachability.dart preconditions (i) anchor is a real accepted fix [alarm_controller.dart:592-604 gates on real accuracy; dead-reckon sentinels never re-anchor], (ii) V_LINE = max forLine over all legs >= true max speed, (iii) t - anchor.tSeconds is true elapsed on the monotonic clock (_nowSeconds). At t_arrival true progress = target, and target <= s_max(t_arrival) = anchor.sHi + V_LINE*(t_arrival - anchor.tSeconds) => t_arrival >= anchor.tSeconds + (target - anchor.sHi)/V_LINE = t_reach. QED. Furthermore `target` = coldStartFireTargetMeters is documented (alarm_controller.dart:398-399) as a LOWER bound on the true intended fire point, so firing at t_reach is at/before the intended (mode-aware) fire point, not merely at raw arrival.

Non-postpone (the actual bug killed): because anchor is FROZEN during a blackout, f decreases 1:1 as nowSeconds advances, so now + f = t_reach stays constant in wall-clock. Contrast the ETA path where smoothedETA is frozen but `now` advances, so etaFireAt marches forward. Thus even if the process dies mid-blackout, the last-scheduled RTC setAlarmClock instant equals t_reach and cannot be postponed. Clock choice is safe: monotonic pauses in deep sleep only BETWEEN ticks (no scheduling happens then); at each awake tick DateTime.now() is real wall clock and f is a short-horizon accurate delta, yielding a correct absolute RTC instant; setAlarmClock is RTC-wakeup so it fires at that instant through Doze. Corrupt-input path returns null -> caller keeps the pre-existing ETA behaviour (no regression, no new late path).

### Too-early impact
Zero change to the 395-ride scale oracle (test/scale/reachability_scale_test.dart): that oracle exercises the IN-PROCESS fire decision, and this change adds NO new in-process firing path — the OS backstop only actually rings when the process is DEAD. The scale test's two-sided too-early distribution is byte-identical.

User-visible earliness in live trips is unchanged: on every live trip the real in-process alarm fires and cancelEtaBackstop (notification_updater.dart:222-224, notification_service cancel of id 991) runs before the backstop instant, so an earlier-scheduled backstop is cancelled and never wakes the rider.

The only behavioural delta is confined to the process-death case: min() can pull the backstop instant earlier than the old frozen-ETA instant when the free-run physics time is sooner (e.g. a device that dies mid-trip while GPS was healthy now gets a backstop at the V_LINE worst-case reach time). This is an intentional, prime-directive-mandated trade — accepting a bounded too-early wake ONLY on an already-dead process to eliminate a catastrophic late wake; it never introduces late risk. Optional future tightening (out of scope, still never-late): feed the stop-count topology cap into the target-time computation to raise physicsFireAt toward real arrival and shrink this dead-process earliness.

### Regression test
NEW FILE test/notification_physics_backstop_test.dart — deterministic, no clock/OS, targets the pure static AlarmController.backstopPhysicsFireInSeconds:

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/tracking/alarm_controller.dart';

void main() {
  group('P0 physics backstop time (never-late, non-postpone)', () {
    // anchor at s0=0 @ t0=0, target 2800 m, V_LINE 28 m/s => reach at t=100 s.
    double? f(double now) => AlarmController.backstopPhysicsFireInSeconds(
          anchorSHiMeters: 0.0, anchorTSeconds: 0.0,
          targetMeters: 2800.0, vLineMps: 28.0, nowSeconds: now);

    test('basic reach time from a fresh anchor', () {
      expect(f(0.0), closeTo(100.0, 1e-9));
    });

    test('NON-POSTPONE: absolute fire instant is invariant as now advances', () {
      // The bug being guarded: a frozen-ETA style time keeps ~constant seconds-
      // from-now while now advances (postponing). Physics must shrink 1:1 so
      // (now + f) is fixed.
      for (final now in [0.0, 25.0, 50.0, 90.0, 99.0]) {
        expect(now + f(now)!, closeTo(100.0, 1e-9),
            reason: 'fire instant must not drift at now=$now');
      }
    });

    test('NEVER-LATE: fire instant <= true arrival for any true speed <= V_LINE', () {
      // A real train at 14 m/s (<=28) reaches 2800 m at t=200 s; physics=100 <=200.
      const tArrivalSlow = 2800.0 / 14.0; // 200 s
      expect(f(0.0)! <= tArrivalSlow, isTrue);
      // Worst case: train exactly at V_LINE reaches at t=100 => equal, not late.
      const tArrivalMax = 2800.0 / 28.0; // 100 s
      expect(f(0.0)! <= tArrivalMax + 1e-9, isTrue);
    });

    test('anchor already worst-case past target => negative => fire now', () {
      final r = AlarmController.backstopPhysicsFireInSeconds(
          anchorSHiMeters: 3000.0, anchorTSeconds: 0.0,
          targetMeters: 2800.0, vLineMps: 28.0, nowSeconds: 0.0);
      expect(r, isNotNull);
      expect(r! < 0, isTrue); // caller clamps to fire ~immediately
    });

    test('non-finite / non-positive speed => null (caller falls back to ETA)', () {
      expect(AlarmController.backstopPhysicsFireInSeconds(
          anchorSHiMeters: 0, anchorTSeconds: 0, targetMeters: 2800,
          vLineMps: 0, nowSeconds: 0), isNull);
      expect(AlarmController.backstopPhysicsFireInSeconds(
          anchorSHiMeters: double.nan, anchorTSeconds: 0, targetMeters: 2800,
          vLineMps: 28, nowSeconds: 0), isNull);
    });

    test('min(eta,physics) picks the earlier: frozen-ETA loses during a blackout', () {
      // Simulate a 60 s blackout: ETA frozen at 300 s (=> etaFireInSeconds 300),
      // physics anchored so its instant is fixed at 100 s. As now advances the
      // physics candidate stays earlier and is chosen.
      const etaSecondsFrozen = 300.0;
      for (final now in [0.0, 30.0, 60.0]) {
        final phys = f(now)!;                 // 100 - now
        final eta = etaSecondsFrozen;         // frozen: does not shrink
        expect(phys < eta, isTrue,
            reason: 'physics must win the min at now=$now');
      }
    });
  });
}

This test FAILS if the fire time is computed as a frozen "seconds from now" (the non-postpone invariant breaks) or if the sign/free-run formula regresses toward late.

### Refute verdicts

- **LATE-RISK** (action: implement-with-changes)
  - late counterexample: Metro tunnel, anchor = last real fix at tunnel mouth (s=0, mono=wall=0), target 2800 m, V_LINE=28 m/s so reachAfterAnchor=100 s; train runs 28 m/s and TRULY reaches the stop at real t=100 s. In the tunnel there are no GPS deliveries, so no wakelock is held and the Android CPU suspends. AppClock.monotonicSeconds() is a Dart Stopwatch = CLOCK_MONOTONIC, which FREEZES during suspend (only CLOCK_BOOTTIME counts suspend). The device wakes for one batch/maintenance tick at real t=90 s but monotonic has only advanced to ~12 s. _refreshBackstopPhysicsFireAt then computes elapsed=12, f=100-12=88, and arms setAlarmClock at wall_fire = now(90)+88 = real t=178 s. The process is then reclaimed (OEM battery killer); the RTC backstop is the only survivor. Stop reached at t=100 s, backstop fires at t=178 s => 78 s LATE. The proof's clock-safety step ("f is a short-horizon accurate delta") is false: f is anchored to anchor.tSeconds, which can predate a multi-minute suspend, so now+f is NOT a fixed wall instant once monotonic froze. Secondary inherited late hole: a fast line named as slow metro (Mumbai Suburban "Western Line" ~33 m/s, or Airport Express shown as "Orange Line" ~37 m/s) resolves via forLine() to defaultMps=28, inflating reachAfterAnchor => f too large => late on blackout+process-death; the scale oracle injects certified V_LINE overrides and cannot catch it.
- **LATE-RISK** (action: implement-with-changes)
  - late counterexample: Blackout + deep-sleep, the patch's exact target scenario. Rider's last real GPS fix as the train enters a tunnel: anchor (sHi=0, mono t=0, wall=0), fire target R=200 s away at V_LINE=28 m/s. Phone screen-off, Android Dozes; CLOCK_MONOTONIC (AppClock Stopwatch) freezes during suspend. A Doze maintenance-window tick runs at wall=180 s having accrued only A=20 s awake (S=160 s suspended): mono_now=20, elapsed=20, fireInSeconds=(2800-0)/28 - 20 = 100-20 = 80. _backstopPhysicsFireAt = wall_now(180) + 80 = wall 260. Process then dies. The surviving setAlarmClock RTC fires at wall 260, but a train actually at V_LINE reached the target by wall ~100 (worst case) — the backstop is LATE by S=160 s (= the suspend duration). General result: backstop_wall = wall_anchor + R + S, i.e. late by all deep-sleep accrued between the last real fix and the last pre-death tick. Root cause: fireInSeconds is measured in the monotonic (suspend-excluding) frame off anchor.tSeconds (mono, alarm_controller.dart:579-603 / app_clock.dart:151-161) but rebased onto the wall clock via AppClock().now().add(secs) — a frame mix. The claim 'structurally impossible to postpone / never-late by physics' fails. (Note: still less-late than the current frozen-ETA backstop, so not a regression vs shipped code, but it does NOT deliver the never-late guarantee it asserts.)
- **LATE-RISK** (action: implement-with-changes)
  - late counterexample: Metro all-underground blackout with device Doze-suspend. AppClock.monotonicSeconds() is a Stopwatch (CLOCK_MONOTONIC), which freezes during Android CPU suspend; the RTC backstop (scheduleEtaBackstop → AndroidScheduleMode.alarmClock) fires at an ABSOLUTE wall instant. Anchor = real fix at the platform: sHi=0, tSeconds(mono)=0; target 2800 m, V_LINE 28 m/s ⇒ reachAfterAnchor = 2800/28 = 100 s. Train departs; over the next 100 wall-seconds the screen is off and the device suspends ~40 s total, so the monotonic clock advances only 60 s. At the last awake tick before the OS kills the foreground service (wall t=100 s): elapsed = now_mono − anchor_mono = 60; f = backstopPhysicsFireInSeconds = 100 − 60 = 40 s; physicsFireAt = AppClock().now().add(40) = wall t=140 s. Worst-case TRUE arrival (train running at V_LINE the whole time) = wall t=100 s. The process is dead, so the only surviving wake is the RTC alarm at t=140 s ⇒ fires 40 s LATE (≈1.12 km past the platform at 28 m/s — station missed). Generally: because now_wall − monotonic_elapsed = anchorWall + accumulated_suspend, fireAt = anchorWall + suspend + reachAfterAnchor, so the 'physics never-late instant' drifts late by exactly the device-suspend time accrued between the anchor and the last tick. min(etaFireAt, physicsFireAt) selects this late physics instant whenever the frozen-ETA candidate is even later (e.g. smoothedETA stale at 300 s ⇒ etaFireAt=310 s vs physics 140 s). The design's proof precondition (iii) 't − anchor.tSeconds is true elapsed' is violated: the train moves in wall time, but the clock used excludes suspend.

---

## P0-03-multileg-modemax

**Verdict: APPLY/APPLIED (strictly tightens too-early, 395-scale byte-identical, never-late preserved; composes with P0-01). One SAFE/implement-as-is verdict.**

- risk=low implementable=True root_cause_confirmed=True
- files: ['/home/raed/Projects/WakePoint/lib/core/reachability/reachability.dart', '/home/raed/Projects/WakePoint/lib/services/tracking/alarm_controller.dart', '/home/raed/Projects/WakePoint/test/reachability/multileg_piecewise_vline_test.dart']

### Patch
```
Root cause confirmed at alarm_controller.dart:1403-1410 — vMaxFwd = max V_LINE over ALL forward legs (incl. RRTS 53 m/s) is fed as a single scalar to Reachability.bound, so the CURRENT slow-metro-leg free-run grows at 53 instead of 28 m/s (~2x too early). The compensating stop-count cap is dormant (dwellMinSeconds:0.0). Fix = piecewise per-leg V_LINE integration.

EDIT 1 — lib/core/reachability/reachability.dart, new value type (added after _Cell, ~line 462):
  class VLineSegment { final double endMeters; final double vLineMps; const VLineSegment(this.endMeters, this.vLineMps); }
  endMeters = a leg's legEndMeters; vLineMps must over-bound that leg's true max speed (precondition ii per leg).

EDIT 2 — reachability.dart Reachability.bound signature: add optional param `List<VLineSegment>? vLineSegments,` (all existing callers unchanged/inert).

EDIT 3 — reachability.dart, replace the flat free-run
  `final double freeRun = anchor.sHi + v * dtClamped;`
with a piecewise march when segments are present:
  final double freeRun = (vLineSegments != null && vLineSegments.isNotEmpty)
      ? _piecewiseFreeRun(sHi: anchor.sHi, dt: dtClamped, segments: vLineSegments, tailV: v)
      : anchor.sHi + v * dtClamped;
Everything downstream (T_max watchdog, corrupt-anchor fail-safe, topology-cap min(freeRun,...)) is unchanged; min of two valid upper bounds stays an upper bound.

EDIT 4 — reachability.dart, new pure helper _piecewiseFreeRun(sHi,dt,segments,tailV): march pos=sHi,timeLeft=dt; for each segment in ascending endMeters: skip if endMeters<=pos or non-finite; v=segment.vLineMps (fallback absoluteCeilingMps if <=0/non-finite); travel=(endMeters-pos)/v; if travel>=timeLeft return pos+v*timeLeft; else pos=endMeters, timeLeft-=travel. After the loop, coast remaining time at tailV (the flat max) beyond the last boundary.

EDIT 5 — lib/services/tracking/alarm_controller.dart:1403-1432 (the P1 multi-leg block): keep computing vMaxFwd (now used only as tail/coast speed + topology-cap scalar), and ADDITIONALLY build a sorted List<VLineSegment> over context.transitLegs (ALL legs, each = VLineSegment(leg.legEndMeters, forLine(leg))), then pass `vLineSegments: vSegments.isEmpty ? null : vSegments` into the same Reachability.bound call. Segments are built over ALL legs (not just forward) so an anchor still sitting on a previous FASTER leg uses that leg's ceiling for the arc it covers — closing an under-bound (late) hole the flat forward-only max shared.
```

### Never-late proof
Let P(t) be the piecewise march and S(t) true arc-progress, with P(0)=sHi=anchor.sHi>=S(0) (forward-overbounded anchor, precondition i). Define v(s)=the ceiling of the arc segment containing s. At every position s, v(s) >= the true train's instantaneous speed there: within a leg it is that leg's V_LINE >= the leg's true max (precondition ii applied per leg), and in a transfer gap between legs the rider is walking (~2-3 m/s), far below the metro/RRTS ceiling the march adopts there. The march integrates dP/dt=v(P) (v(P)>0 always, since every V_LINE>=defaultMps 28), while dS/dt <= v(S). By the standard scalar ODE comparison for dP/dt=f(P) with f>=0: since P(0)>=S(0) and whenever S catches up to P their rates satisfy dS/dt<=v(S)=v(P)=dP/dt, S can never overtake P; hence P(t)>=S(t) for all t in [0,dt]. So sMax=P(dt) is an upper bound on true progress => never fires late. Corrupt-input fail-safe, T_max watchdog, +inf fire-forcing, and topology-cap min() are all untouched. Past the boundary the march DOES adopt the faster RRTS ceiling (segment switch at legEndMeters), so a target on the fast leg still over-bounds a metro-then-RRTS train (asserted) — the fix does not create a late hole in the other direction.

### Too-early impact
Strictly improves (tightens) the too-early tail with ZERO late risk. Because v(P) at every march step is <= max_k v_k (the old flat max), P_piecewise(dt) <= P_flat(dt) for every dt (asserted for dt in [0,120] in the regression test) — the fix can only pull the fire LATER, never earlier, so it cannot add any new early fire. Worked example (metro[0,3000)@28 -> RRTS[3000,20000)@53, anchor sHi=1000, target 2500 on the metro leg): flat max fired at dt=(1500)/53=28.3s; piecewise fires at (1500)/28=53.6s (~1.9x later, i.e. the ~2x-early defect is removed) while a real 25 m/s metro train arrives at 60s (fires before arrival). The 395-ride scale oracle is byte-identical: it drives ReachabilityTracker.boundNow(), which never passes vLineSegments, so the scalar free-run path — and the certified-V_LINE two-sided window/too-early distribution — is unchanged.

### Regression test
New file test/reachability/multileg_piecewise_vline_test.dart (metro[0,3000)@28 -> RRTS[3000,20000)@53). Asserts, via Reachability.bound(vLineSegments:[VLineSegment(3000,28),VLineSegment(20000,53)]): (1) too-early regression caught — at dt=30s the flat-max bound (no segments) >= target 2500 (fires) while the piecewise bound < 2500 and == 1000+28*30 (grows at the metro ceiling, not RRTS); (2) it still fires by ~53.6s; (3) NEVER-LATE — for a true 25 m/s metro train, piecewise sMax >= sHi+25*t at every t in [0,80] step 0.5, and fire time 53.6s < arrival 60s; (4) piecewise sMax <= flat sMax for every dt in [0,120] (cannot add an early fire); (5) target on the FAST leg (sHi=2900,target=6000): the bound adopts the RRTS ceiling past the 3000 boundary and over-bounds a metro-26-then-RRTS-50 train at all t, firing before its arrival. Deterministic (pure math, no clock/emulator).

### Refute verdicts

- **LATE-RISK** (action: implement-with-changes)
  - late counterexample: Multi-leg journey, current leg = Delhi Airport Express labeled "Orange Line" by Google Directions -> forLine() falls through looksRrts/looksExpress to defaultMps=28 m/s (documented GAP #9, reachability.dart:115-129) while the train's true speed is ~37 m/s; target (New Delhi) sits ON this leg; a faster Namo Bharat RRTS leg (53 m/s) follows downstream. GPS dies in the Airport-Express tunnel. Anchor sHi=3000 m, target=4500 m, legEndMeters0=5000 m, blackout dt~54 s. PRE-PATCH: vMaxFwd=max(28,53)=53, bound reaches 4500 at t=(1500)/53=28.3 s, true 37 m/s train arrives at 1500/37=40.5 s -> fires 12 s EARLY = SAFE. POST-PATCH: _piecewiseFreeRun (reachability.dart:664-678) uses segment0=(5000,28) so the march is 3000+28*t, reaching 4500 only at t=1500/28=53.6 s while the train arrived at 40.5 s -> fires 13 s LATE; rider passes New Delhi asleep. The min() topology cap only lowers the bound further, hardTMaxSeconds defaults null (no watchdog), and during a tunnel blackout the EKF statistical term is stale so effectiveProgress=max(statistical,reach) is governed by the under-bounding reach. The patch strictly lowered the current-leg bound from 53*t to 28*t, converting a shipped too-early residual into a LATE fire. The never_late_proof breaks at its own premise 'precondition ii per leg': GAP #9 documents that ii is shipped-false for a fast-line-named-as-slow current leg, and the pre-patch flat max was the only thing over-bounding it via the faster downstream leg -- exactly the cross-leg cushion this patch removes.
- **SAFE** (action: implement-as-is)
  - late counterexample: None found within realizable route geometry. The march is never-late for any contiguous route, which is all transfer_utils.dart can emit: legs are built with legStartMeters=cumulativeMeters and legEndMeters=legStartMeters+stepLengthMeters (transfer_utils.dart:999,1017,1105-1109) with cumulativeMeters advancing monotonically, so arc ranges are contiguous, non-overlapping, and already ascending; alarm_controller.dart:1434 also sorts. The ONLY theoretical under-bound (=> late) requires two transit legs whose ARC SPANS OVERLAP with the smaller-endMeters leg being the SLOWER one: then _piecewiseFreeRun (reachability.dart:664-678) picks the first segment with endMeters>pos and applies its slow v across an arc that a faster overlapping leg also covers, missing the max. Because _piecewiseFreeRun keys purely on endMeters and ignores legStartMeters, it cannot detect the overlap. This is unrealizable with the current contiguous builder, so it is a latent-fragility caveat (defense-in-depth: have the march take the max V_LINE over all segments whose span could contain pos, or assert contiguity), not a live late hole.
  - too-early: No too-early regression. (1) 395-scale oracle is byte-identical: ReachabilityTracker.boundNow (reachability.dart:892-907) never passes vLineSegments, so the certified-V_LINE scalar path and its two-sided/too-early distribution are untouched. (2) Healthy-GPS is unaffected: the reachBlackoutMinSeconds gate (alarm_controller.dart:1466-1469) is unchanged, so the bound is only fed during a genuine blackout. (3) In the finding's forward scope (anchor on the slow current leg, fast leg downstream) the march grows at the current leg's ceiling, so P_piecewise <= P_flat and it fires LATER (less early) — strictly tightening the tail. Caveat, not a regression: the writeup's blanket claim 'P_piecewise(dt) <= P_flat(dt) for every dt' is false when the highest-V_LINE leg is BEHIND currentLegIndex — vMaxFwd is forward-only (alarm_controller.dart:1421-1425) while vSegments spans ALL legs (1426-1433), so over an upstream fast arc the march can exceed the flat bound and fire EARLIER than old behavior. But that earlier fire is (a) in the safe direction, (b) a REQUIRED never-late correction of a pre-existing forward-only-max under-bound, (c) bounded by the true reachable set, and (d) blackout-gated — not a healthy-GPS early bias and not egregious. The regression test (multileg_piecewise_vline_test.dart:90-96) only checks the forward scenario, so it passes despite the over-broad claim.
- **LATE-RISK** (action: implement-with-changes)
  - late counterexample: Multi-leg Delhi journey: Leg0 = Delhi Airport Express, lineName "Orange Line", cityKey null, span [0,8000], TRUE top speed ~37 m/s (design 135 km/h); Leg1 = RRTS "Namo Bharat" span [8000,40000]. forLine(null,"Orange Line") does not keyword-match RRTS/express (reachability.dart:130-136) so it returns defaultMps=28 — the documented GAP#9 under-resolution (reachability.dart:115-129). Rider is mid-Leg0 in a GPS blackout; anchor sHi=1000 at t0; target = a Leg0 stop at 6000. A real 37 m/s train reaches 6000 at (6000-1000)/37 = 135 s. OLD flat-max: vMaxFwd=max(28,53)=53, bound=1000+53t reaches 6000 at 94 s < 135 s — fires 41 s EARLY (safe). NEW piecewise: segments sorted = [(8000,28),(40000,53)] (alarm_controller.dart:1426-1434); _piecewiseFreeRun marches the [0,8000] span at 28, so bound=1000+28t reaches 6000 at 178 s > 135 s — alarm fires ~43 s LATE. During the blackout dead-reckoning lags, so effectiveProgress=max(statistical,reach) (alarm_evaluator.dart:102) is governed by the reach bound, making the late fire real and catastrophic. The patch converts a safe 41 s-early fire into a 43 s-late fire by removing the flat-max's coincidental masking of the current leg's GAP#9 under-resolution.
---

## GW-0147 — Process-death OS backstop armed on wall-clock RTC (never-late residual)
*(added 2026-07-20, session d0703995 — sim/code-read; NOT device-proven)*

**Defect.** The physics backstop fire-time is computed as a MONOTONIC duration
(`alarm_controller.dart:484-486`, both terms via `AppClock().monotonicSeconds()`,
immune to wall jumps) but then baked into an ABSOLUTE WALL instant at
`alarm_controller.dart:534`: `_backstopPhysicsFireAt = AppClock().now() [DateTime.now()] + secs`.
It is armed via `notification_updater.dart:254-274` → `NotificationService.scheduleEtaBackstop`
→ `notification_service.dart:~930` `AndroidScheduleMode.alarmClock` → `AlarmManager.setAlarmClock`
= **RTC_WAKEUP (wall clock)**. `flutter_local_notifications` exposes no ELAPSED_REALTIME mode.
While the process is alive the ~1 Hz re-arm loop keeps `now()+secs` pinned to the correct
wall instant, but after **total process death** (the OEM-kill scenario the backstop exists
for) the last-armed RTC instant is frozen. A **backward UTC-epoch step** (NTP correction or
manual/auto clock set) during the dead window makes the RTC alarm fire that Δ **later** in real
time → LATE if Δ exceeds the physics slack (which is ≈0 for an express travelling at V_LINE).
The monotonic clock was introduced (`app_clock.dart:138-161`) precisely to kill a reproducible
~28-min backward-jump late fire in the IN-PROCESS net; this finding shows that vector is
re-exposed at the OS boundary for the process-death survivor.

**Exposure (conjunction — narrow but real):** (1) total process death, AND (2) backward
UTC-epoch step after the last re-arm, AND (3) |step| > physics slack, AND (4) before true
arrival. RTC fires on UTC epoch, so timezone/DST does NOT shift it — only true NTP/manual UTC
steps do. The devices most prone to OEM-kill (cheap handsets, bad RTCs) are also the most prone
to NTP corrections, so the intersection is not empty. The primary in-process net is monotonic
and unaffected — exposure is bounded to (process-dead ∧ backward-clock-step).

**Fix options (ranked):**
- **A. ELAPSED_REALTIME_WAKEUP backstop (ideal; needs native).** Add a tiny platform channel
  calling `AlarmManager.setExactAndAllowWhileIdle(ELAPSED_REALTIME_WAKEUP,
  SystemClock.elapsedRealtime()+secs*1000, pi)` + a BroadcastReceiver. ELAPSED_REALTIME is
  monotonic, counts through Doze/suspend, and is immune to wall changes. KEEP the RTC
  `setAlarmClock` too (belt-and-suspenders + alarm-clock UI + strongest Doze exemption); fire on
  whichever lands first. **Must be device-proven** that `setExactAndAllowWhileIdle` survives
  Doze + OEM kill.
- **B. TIME_SET re-arm receiver (partial; pure-manifest).** Declare a manifest receiver for
  `android.intent.action.TIME_SET` (+ `TIMEZONE_CHANGED`) that restarts the FGS / re-arms the
  backstop on a clock change. Closes the "process alive when clock steps" case; does NOT reliably
  close "process already dead" on modern background-start rules. Cheap, defensive, incomplete.
- **C. Conservative wall pad (stopgap).** Subtract a fixed pad (30–60 s) from the RTC instant to
  absorb plausible backward steps. No native code; crude (misses large manual changes); adds
  earliness to the backstop path only.

**Recommendation:** A for correctness, with B as a cheap immediate mitigation. DO NOT ship blind —
this is exactly a case where "never claim device proof from simulation" applies. Until device-proven,
GW-0147 stays an OPEN P0-never-late residual (sim/code-read). Note it composes with the in-process
monotonic net: the guarantee only breaks when that net is already gone (process dead).
