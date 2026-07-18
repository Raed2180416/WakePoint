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
