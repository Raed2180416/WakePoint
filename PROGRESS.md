# GeoWake Overnight Progress Log

_Append-only. Newest entries at the bottom. Written by the autonomous engineering agent so a crash/restart never loses the place, and the founder can read exactly what was done and why._

Core promise being graded against, every entry:
> Wake a transit rider before their stop — never late, never at the wrong place — even when GPS dies underground, on a cheap Android phone, in India.

The ONE honesty rule: never claim real-world/device proof from a simulation. Every claim is tagged PROVEN (with repro) / CODE-FIXED-HARDWARE-UNPROVEN / STILL-OPEN.

---

## Session start — baseline (2026-07-18)

**Branch:** `sim-validation` (working off one branch, as directed). Remote `origin` = github.com/Raed2180416/WakePoint.

**Green-tree baseline established:**
- `flutter analyze lib/` → **0 errors** (84 info-level lints: avoid_print, deprecated withOpacity, prefer_initializing_formals). Meets the "0 errors" bar.
- Flutter 3.44.6 stable / Dart 3.12.2 (fetched from `flutter --version` this session).
- Fixtures: 7 real+synthetic fixtures exist at the EXTERNAL path `/home/raed/geowake_imu_analysis/fixtures/` (Nallur, Nadaprabhu/Majestic real rides; allunderground_20min, express_skip, long_fullline, short_1stop synthetic). IMU CSVs are 1.6–19 MB — cannot commit raw.

**Re-verified vs GAP_ANALYSIS.md (docs are hypotheses until re-confirmed):**
- Reachability core (`lib/core/reachability/reachability.dart`, 438 L) — CONFIRMED present, pure, sound. `seedColdStart`, `onAcceptedFix`, `boundNow`, topology cap, `effectiveProgress` all as documented. `hardTMaxSeconds`/`dwellMinSeconds` default disabled (GAP MED "watchdog unarmed" confirmed).
- Replay harness (`test/ekf/replay_harness_test.dart`, 1174 L) — MORE ADVANCED than GAP_ANALYSIS implies: it already `expect(fixtures, isNotEmpty)` (FAILS not skips on empty, line 993), already seeds reachability cold-start at s=0/t0 (line 517), and TASK "COLD_START" already hard-asserts reachability fires early with zero GPS (GLMT-03 closed) + A/B proves the EKF-only path does NOT fire. So the *harness-level* proof of the reachability layer exists. The GAP is that (a) fixtures are external/uncommitted so CI can't run it, and (b) PRODUCTION wiring (location_stream_handler, alarm_controller) still has the BLOCK early-return + s=0 anchor + metro-only reach bound.

**Plan:** Execute brief phases A→H in order. Phase A (never-late net real in PRODUCTION + committed CI fixtures) is highest priority. Grounding research (Android 14/15/16, Maps pricing, DPDP, eCPMs, line speeds) fanned out via parallel workflows.

---

## Phase A + B execution (2026-07-18, continued)

**Orchestration:** launched 3 background workflows (Ultracode mode):
1. `geowake-grounding` (35 agents, 2M tok) — 17 platform/economics/legal/data families, adversarially verified. DONE. (Scribe truncated at slice(0,120000) — full data recovered from journal by a follow-up agent → docs/research/grounding_notes.md.)
2. `geowake-backlog-reverify` (9 agents) — re-verified GAP_ANALYSIS vs current code → docs/BACKLOG_CURRENT.md (supersedes stale file:line). DONE.
3. `geowake-impl-independent` (7 impl + 7 adversarial review + scribe) — independent, disjoint-file backlog items (telemetry sink, reroute whitelist+leg-city+metro CI test, route-cache pin, server error-body cache, backstop lead+991 cancel, cos(lat) snapping, DND/FSI/OEM preflight) → docs/IMPL_PACKAGES.md. Running; agents edit the tree directly on disjoint files; I integrate+verify holistically.

**Committed checkpoint faf539c (green: analyze 0 err, 1108 tests):**
- Never-late CI gate foundation: committed compact fixtures (test/fixtures/replay, IMU decimated via tools/make_replay_fixtures.py), harness reads in-repo set first + FAILS on empty, added spatial never-wrong-place + garbage-early hard assertions, .github/workflows/ci.yml. GATE: PASS (0 late) — allunderground_20min (GPS dead whole ride) fires +803s early, express_skip +180s, short_2stop +135s.
- #6 versionCode from pubspec (was hardcoded 1 → 2nd Play upload rejected). PROVEN (config).
- #4 preflight block enforcement: notifications-off now HONESTLY REFUSES to arm (dialog→Future<bool>), warn still proceeds. CODE-FIXED (dialog-contract; full arm-flow widget test deferred as too-coupled).
- #5 cross-state hard block removed: interstate sleeper armable. CODE-FIXED.

**Never-late CORE (#1/#2/#3-partial) — the crown jewel, landed (uncommitted, verifying):**
- Root cause confirmed: cold-start-underground → progressMeters resolves NULL → dispatch at alarm_controller only ran _evaluateWithRoute (where the reach bound lives) when progressMeters!=null, else geofence (can't fire underground). Relaxing the location_stream_handler guards alone was insufficient.
- Fix (3 files):
  1. location_stream_handler `_maybeEvaluateAlarmDuringDropout`: removed the `last==null`/`no-EKF` hard bails → the physics tick now runs during cold-start (sentinel synth position; timer starts unconditionally at arm).
  2. alarm_controller: NEW `_maybeFireColdStartReachBackstop` — whole-route worst-case bound to the final destination using the FASTEST V_LINE across legs (overbound ⇒ never late), fires when the bound reaches a per-mode target (`coldStartFireTargetMeters`, @visibleForTesting). Dispatch routes progressMeters==null && hasAnchor → this backstop before geofence.
  3. trackingservice: seed the anchor at ARM (`seedReachabilityAnchorAtArm(s=0)`) so t0 is honest from arm, not first tick.
- PROVEN: test/tracking/cold_start_reach_backstop_test.dart (7 tests) — target math correct for stops (incl. fewer-stops-than-N, no-geometry), distance, time, clamped ≥0; arm-seed seam. Reachability bound-reaches-target never-late proven in test/reachability/ (55 tests). Honest status: CODE-FIXED + logic-proven-in-sim; full production isolate path (NotificationService-coupled) not driven headless — flagged for device pass.
- STILL-OPEN in this cluster: restore-from-snapshot anchor seeding (train moved during kill → seed from snapshot fix-timestamp, not now) — noted; real-fix-on-resume corrects. Multi-leg cold-start uses fastest-V_LINE whole-route bound (safe/early).

---

## Integration + deliverables (2026-07-18, wave 2)

**Parallel implementation workflow (7 items) integrated** — analyze lib/ 0 err/0 warn; full suite 1171 green:
- #23 RouteCache pin, #24 server error-body cache, #10/#11 backstop lead+991 cancel, #27 cos(lat) snapping, #13 reroute whitelist, #28 leg-cityKey, #12 metro-data integrity gate, #7/#16 FileTelemetrySink+flush+configure, #17/#18/#19 DND/FSI/fix-routing preflight. All adversarially reviewed (docs/IMPL_PACKAGES.md), integrated + retested holistically by an integrator agent.
- #20 (battery-opt → block on aggressive OEM) coded but HELD AT WARN behind a one-line FOUNDER TOGGLE — refusing to arm on every India phone lacking a battery exemption is a big product gate needing founder sign-off; documented in VALIDATION_REPORT §2/§3.
- #9 V_LINE city plumbing (myself): leg.cityKey → every reach V_LINE resolution (cold-start, distance/time modes, per-leg). RRTS resolves via city now. Grounded: current VLineTable validated (metros design 90 ⇐ 28; AirportExpress 135 ⇐ 39; RRTS 180 ⇐ 53). Residual: Mumbai suburban (120 km/h, name "Western Line", no keyword/city match) under-bounds — documented STILL-OPEN (narrow: suburban mostly above-ground).
- #21 test reconciled (fire_decision_fractile_test) to the new positive-cushion contract.

**Deliverables written (all grounded + cited):**
- VALIDATION_REPORT.md — the honest ledger: PROVEN (with repro) / CODE-FIXED-HARDWARE-UNPROVEN / STILL-OPEN + re-graded core-promise answer.
- ECONOMICS.md — grounded unit economics. Bottom line: loses money on Google metered pricing at scale (Directions/Geocoding/NearbySearch/Maps per-arm calls); ads are NOT the lever (India eCPM net $0.02-0.18/DAU/mo vs ~$0.27-1.46 cost/user); self-host OSRM/Valhalla (India OSM 1.6GB → ~$90-300/mo vs $7-15K Google) flips it green on cost alone. Session tokens + 450ms debounce ALREADY correctly in place (autocomplete keystroke bomb is NOT present). Nearby-Search (metro validation) is an unpriced SKU = priority-1 to confirm.
- DATA_STRATEGY.md — legal-by-construction aggregate O-D moat. Flagship: station×hourly-bin O-D flow matrices (DP-noised, k≥50-100 suppression, on-device aggregation only). DPDP-grounded (aggregate outside Act but no safe harbour → on-device only). US Census LEHD OnTheMap = precedent (production DP O-D). Consent flow + on-device aggregation scaffold = v2.
- docs/research/grounding_notes.md (701 L, 17 topics, 160 cited sources, adversarially verified) + docs/research/raw/ per-topic + docs/IMPL_PACKAGES.md + docs/BACKLOG_CURRENT.md.

**Canon reconciliation:** GAP_ANALYSIS.md + VALIDATION.md prepended with dated reconciliation headers marking fixed items + pointing to BACKLOG_CURRENT.md / VALIDATION_REPORT.md as current sources of truth.

**Commits on sim-validation:** faf539c (Phase A foundation + CI gate), 3ff862a (cold-start core #1/#2), 873313e (#3 + #21), 6660d10 (7-package integration + #9 + deliverables), + doc reconciliation.

**Honest bottom line (VALIDATION_REPORT §6):** never-late promise is now real, wired into every fire mode, gated in CI (can't silently regress), proven deterministically in sim for underground/cold-start/blackout. App is honest at the door + has a persisted place to measure itself. What remains genuinely device-unproven (labeled, not papered over): OEM force-kill survival, boot resume, full-screen/DND delivery — code-complete + doc-grounded, but only a real phone fleet settles them.

---

## Phase D telemetry emits + Phase E R8 + final CI (2026-07-18, wave 3)

- **Telemetry emit sites (#8/#15)** wired + proven (commit 64a6790): alarmArmed at arm; gpsLost/gpsReacquired on blackout entry/exit; alarmOutcome at every fire (reach/mode inferred from reason). test/telemetry/emit_sites_test.dart (3) proves the alarmOutcome site. All fail-open. Residual: on-time/late/missed classification (needs post-arrival detection) + reliability{osKilled} (#14, restart-flag state machine) = STILL-OPEN, documented.
- **CI hardened**: added metro-data integrity gate + full `flutter test` step (whole suite gates every push/PR, not just the never-late gate). Full suite = 1174 green; analyze lib/ 0 err/0 warn.
- **R8 keep-rules (#57, Phase E)** commit dd5e54d: keep com.geowake.wakepoint_native.** (reflective wake-lock/FSI native plugin) + io.flutter.plugins/embedding registrants, so a release R8 pass can't strip the wake path (release-only bug class). Code-fixed; release-mode on-device smoke test still required to PROVE.
- **USE_EXACT_ALARM**: grounding recommends dropping it (Play-restricted; setAlarmClock + only SCHEDULE_EXACT_ALARM is the safe path) — documented in VALIDATION_REPORT §4, NOT changed tonight (would alter the Android-14+ exact-alarm grant flow the never-late backstop relies on; needs device verification first — honest never-late-caution).

- **Adversarial self-verification** of the never-late core (cold-start backstop, #3, #9, #21) launched — a skeptical reviewer hunting for any late/never/wrong/crash path the tests miss. Findings to be processed.

### Definition-of-done status (brief §10)
1. Green tree + never-late scenario harness in CI (fail-on-empty, never-early/wrong-place) — DONE.
2. Phase A + B closed + proven (promise real for every mode; arm-time honest; backstop mode-accurate) — DONE (sim-proven; device axis labeled).
3. Data correctness (Phase C) fixed + gated; 9 flagged lines researched (grounding_notes §16) — sequences researched, shipping-into-data = follow-up; integrity gate live.
4. Telemetry emitting to a persisted sink — DONE (sink + emits); osKilled + classification = documented residual.
5. Android hardening (Phase E) code-complete + labeled PROVEN-in-sim / CODE-FIXED-HARDWARE-UNPROVEN — DONE.
6. ECONOMICS.md, ad strategy (analyzed), DATA_STRATEGY.md — DONE (ad wiring = follow-up; economics shows ads aren't the lever).
7. VALIDATION_REPORT.md — DONE.
8. PROGRESS.md appended continuously — DONE (this file).
9. Every canon doc reconciled; platform claims grounded in current official docs (grounding_notes.md, 160 sources) — DONE.

---

## Adversarial verification of the never-late core (2026-07-18, wave 4 — FINAL)

Launched a skeptical reviewer to try to BREAK the never-late guarantee in the crown-jewel changes (cold-start backstop, #3 distance/time, #9 V_LINE, #21 sigma floor). It confirmed the core math + lower bounds + sigma floor are SOUND, and found real issues — all now fixed (commit 013b62f), full suite 1175 green, GATE PASS, analyze 0/0:

- **FINDING 1 (HIGH, real never-late hole):** OS-kill resume seeded the anchor at s=0/now → bound climbed from zero → zero blackout protection post-resume until it re-passed true progress → late/never. FIXED: resume seeds the anchor from the snapshot's restored progress (ekfS) at the snapshot timestamp (createdAt) — bound correctly over-bounds the kill-duration movement; eliminates the first-tick race.
- **FINDING 3 (healthy-GPS early bias):** reach bound now only overrides dead-reckoned progress once the anchor is stale (>= FireDecisionConfig.reachBlackoutMinSeconds = 8s) — inert on healthy GPS, active only in a real blackout. (+inf watchdog always applies.)
- **FINDING 4 (sparse-line under-warn):** cold-start stops target derives per-stop spacing from legLen/numStops when the count is known (RRTS ~5-10km/stop warns N stops ahead, not a flat 1.2km).
- **FINDING 6:** defense-in-depth try/catch around the cold-start telemetry.
- **FINDING 2 (V_LINE under-bound on mis-named fast line):** mitigated with suburban/local + city keywords; blanket ceiling default REJECTED (fires every metro ~2x early on blackout + inverts metro<express<RRTS ordering). Narrow residual (Airport Express as "Orange Line", Mumbai suburban as "Western Line") documented honestly in forLine + VALIDATION_REPORT §1.15/§3 as a dataset/vehicle-type follow-up — keyword matching fundamentally can't distinguish it. RRTS stays reliably branded/caught.

**FINAL STATE:** 10 commits on sim-validation (faf539c → 013b62f). Full `flutter test` = 1175 green; `flutter analyze lib/` = 0 errors/0 warnings; never-late GATE = PASS (0 late). All 8 brief phases addressed to the definition-of-done: every gap is fixed-and-proven (with repro) OR honestly documented with the exact reason it needs hardware/a human. The core never-late promise is real for every alarm mode, gated in CI, and the crown-jewel core has been adversarially verified. Deliverables complete: VALIDATION_REPORT.md, ECONOMICS.md, DATA_STRATEGY.md, docs/research/grounding_notes.md (+raw/), docs/BACKLOG_CURRENT.md, docs/IMPL_PACKAGES.md, PROGRESS.md, canon reconciled.

---

## Deep underground-positioning research (2026-07-18, wave 5)

User asked to deeply attack the braking-force / stop-detection lead, model it to SOTA (not naive), simulate on the real polyline/stops, cover car/walk modes, verify on-train detection, and evaluate the observed-speed idea. Ran 4 adversarially-verified parallel workflows (~40 agents) + hands-on real-data validation on the 2 REAL Bengaluru Purple-line rides. Committed 2fb2ca9 (docs/research/underground/, no lib/ changes, suite green 1175).

VERDICT (SYNTHESIS.md): the win is REAL + large (43-46% early-firing cut; worst 9-min blackout +7279m->-34m, ~214x) but SENSOR-GATED. Never-late core deliberately UNTOUCHED.
- Braking force works for STOP-EVENT detection -> re-anchor to KNOWN station geometry, NOT velocity integration (longitudinal sign unobservable on handheld). Needs high-precision detection (false stop = sole late-fire path) -> needs barometer/magnetometer/WiFi corroborator we don't log yet.
- Observed-speed: literal V_LINE:=observed-max PROVEN UNSAFE; accel-limited cone dips 24/33 real windows with naive v0 (needs dwell-gated v0 + a_max upper bound). Safe uses: mode confirm, kinematic params, crowd-sourced design-speed-floored segment speeds (data-moat tie-in).
- On-train vs parallel car: unsolvable from motion (SHL F1 ~89%); solvable from geometry (route-correlated GPS-outage + station-cadence). 2 adversarial late-fire holes found+fixed-in-design.
- Modes: walk PDR bounded (tractable); car hardest; classifier train->walk error 0/2460, V_LINE=max-plausible rule 0/2460 under-estimates.
- Adversarial verifiers caught REAL never-late breaks (train-kinematics terminal-decel direction; HMM tail-quantile trigger; accel-cone a_max) — all corrected in-doc. My own per-tau validation independently confirmed the accel-cone naive-v0 dip.
- V_LINE=28 confirmed valid ceiling (max true 21.6 m/s); 22.2 is NOT.

Roadmap (build-off-existing): log baro+mag (sensor_fusion) + collect real rides incl. a parallel-car ride -> precision-gated HMM stop detector (active_route_manager/station_association) -> reachability-gated stop-anchor min()-term (default-OFF) -> mode-max V_LINE selection -> on-train gate (G v B) with the 2 fixes -> accel-limited cone with dwell-gated v0. Everything device-unproven at scale until on-device data.

---

## Deep simulation + validation + P0/P1 fixes (2026-07-18, wave 6)

User asked to make everything usable, deeply simulate all routes, use the sim engine, generate real-ish data, and validate exhaustively. Launched 6 workflows (~55 agents) + hands-on validation. Findings + fixes (all committed, suite green):

**Scale simulation (391 rides / 19 cities / 46 lines / 9 scenarios, generated from the shipped dataset via scale/build_scale_rides.py):**
- Free-run reachability cone: 0/391 late (Python) AND 0/391 late through the REAL Dart code (test/scale/reachability_scale_test.dart) — closes the model-vs-code gap.
- Gated stop-anchoring: 0/1144 late but 1085 transient sub-truth dips => NOT a provable fire bound; keep it DISPLAY-only, fire on the pure cone. (docs/research/underground/SCALE_SIMULATION.md)
- Early-firing is 5m median to target (already tight); the km-scale tail is entirely long-blackout/cold-start.

**Validation-gaps (~29,461 trials / 50.5M steps across 7 gap sims — docs/research/underground/VALIDATION_GAPS.md):**
- Found ONE real shipped-config never-late defect: a BACKWARD WALL-CLOCK JUMP freezes the cone -> ~28-min LATE fire. FIXED (P0, commit df34ebc): reachability now on AppClock.monotonicSeconds (Stopwatch-based) + fix-age/snapshot-age mapping into the monotonic frame. Guard test/core/clock/monotonic_clock_test.dart.
- P1: multi-leg reach bound used only the current leg's V_LINE -> walk->metro boarding straddle under-bounds (387/387). FIXED (fca0fc3): max V_LINE over forward legs. Single-leg unchanged; GATE PASS.
- P2: 46 EARLY wrong-station wakes — inherent never-late cost (a reach-fire progress-gate would BREAK never-late underground); documented, mitigated by the deviation monitor. Wrong-train never-late axis clean (0 late).
- Process-death restore, multi-leg mode-max, fuzzer (11k), overnight 4.2h, clock-forward: all 0 violations.

**Mutation testing (docs/research/underground/scripts/mutation_test.sh): 8/8 injected never-late bugs CAUGHT, 0 survived** — the reachability tests have teeth.

**Honest converged verdict:** the underground early-firing tail is real but the safe fix (stop-anchoring) is DISPLAY-only + sensor-gated (needs on-device baro/mag for precision); the ALARM must fire on the provable free-run cone. Simulation is now near-exhaustive on the never-late LOGIC (0 violations across ~30k+391+1144 trials + real Dart + 8/8 mutations); remaining unknowns are hardware-only (OEM kill, Doze, FSI/DND, elapsedRealtime under Doze, real detector precision). Residual: express/airport tier (Delhi Orange "Orange Line" -> defaultMps 28 under-bounds ~135km/h Airport Express) needs the dataset (keyword collides with Nagpur metro Orange).

---

## Session 2026-07-19 — physics-only tightening + playground wiring + security

**Reachability TIGHTENING (fastest-feasible-train, NO crowd data — docs/research/underground/TIGHTENING.md + TIGHTENING_IMPL.md, 2 design workflows + adversarial red-team):**
- Replaced the flat free-run cone with a forward-backward velocity-profile sweep: `sMax = min(freeRun, s_fast)` where s_fast obeys accel ramp + terminal-braking envelope + curve ceiling V(s) + mandatory dwell. Implemented in `lib/core/reachability/reachability.dart` (RouteProfile.precompute, _fastestFeasibleProgress, closed-form _cellTime/_cellAdvance).
- Constants set to the REACH-MAXIMIZING (largest-plausible) inputs so they can only over-bound: aMax=2.5, dMax=3.5 (wheel-rail ADHESION ceilings — dominate any grade, closing the red-team's downhill/upgrade LATE paths), aLatEff=7.0 (empty-car overturning + cant). dwell=lower-bound door floor (7s). v0 seeded at V_LINE (drops the binary at-rest bit → structurally avoids the R1/R6 late paths).
- **INERT BY DEFAULT**: dynamicLeversEnabled=false, curveTrusted=false, dwellMin=0 → the cone is bit-identical to free-run until a line is validated + enabled. Cannot regress never-late.
- Validated never-late on REAL Bengaluru Purple Line curved geometry (test/reachability/tightening_never_late_test.dart): 318 anchor→station pairs, **0 violations**; full-blackout early-fire reduction 83–168s (pure math), 146–192s through the real playground engine — all still at/before true arrival.
- Guards proven load-bearing (test/reachability/tightening_guards_test.dart): a phantom served stop (R10) and a comfort aLatEff (R7) each FAIL the pointwise s_max≥s_true assertion when the guard is removed; inert-default == free-run.
- Honest magnitude: the reduction is real but bounded — most of the 14-min early-firing is the irreducible below-fastest-feasible gap (the safe dwell floor is 7s not the real ~20s). Design projects 14min → ~9.6min physics-only; achieved 2–3min on these routes (route-dependent, scales with intermediate stops).
- **What still needs doing to ENABLE in production (all NO crowd data): real per-line rail geometry + measured sigma_pos + per-line all_stops_service flags + curveTrusted validation per line + GPS speedAccuracy threaded to the anchor.** bengaluru.wkp is a ROAD graph (no rail) — curvature must come from OSM rail relations. See TIGHTENING_IMPL.md §7.

**Playground / simulation web engine:**
- Wired the never-late ReachabilityTracker into the REAL playground engine (EkfTestController) — previously it ran only the EKF + AlarmEvaluator; the cone was never exercised there. E2E (test/dashboard/playground_reachability_e2e_test.dart, CI-gated) drives the real engine over the real metro routes: never-late holds; complete-blackout early-firing 21–28min (the case the tightening targets); tightening delays the fire 146–192s while staying never-late.
- Repaired the stripped playground metro assets: rebuilt assets/ekf_test_routes/bengaluru_metro_routes.json (89KB) from REAL Purple Line ride ground truth (real curved polylines, verified ~3.8°/vertex; station arc-lengths; timing); registered in pubspec; fixed a dead placeholder so nallur→vijayanagar loads.

**Security:** removed both committed Google Maps keys from the working tree (web/index.html JS key → out-of-band gitignored web/maps_key.js; second scraping key in scripts/ + .wake index redacted). Web build verified working after the change. ROTATION in Google Cloud is still required (git history retains the keys) — user action.
