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
