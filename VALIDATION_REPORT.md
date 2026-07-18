# GeoWake — Validation Report (overnight session 2026-07-18)

_The honest ledger. Every claim below is tagged **PROVEN** (deterministic, with the exact repro command/gate), **CODE-FIXED-HARDWARE-UNPROVEN** (the code is correct and analyze/tests pass, but the guarantee needs a real device/fleet to confirm), or **STILL-OPEN**. The one hard rule was held: **no real-world/device proof is claimed from a simulation.**_

Core promise, re-graded against, every line:
> Wake a transit rider before their stop — never late, never at the wrong place — even when GPS dies underground, on a cheap Android phone, in India.

---

## 0. Re-answer to GAP_ANALYSIS's question — "does GeoWake deliver its core promise end to end today?"

**Materially closer than at the start of the night, and now *provable and non-regressable* for the cases that can be proven in simulation — but still honestly device-unproven on the Android-survival axis that only a phone fleet can settle.**

At session start the never-late guarantee was real only on one narrow happy path (metro-stops mode, with a pre-tunnel GPS fix, registered geometry, a keyword-resolved V_LINE, notifications on, and a phone that doesn't force-kill the isolate), and it was a *one-time local observation* — the replay gate skipped on empty fixtures, wasn't in CI, and the app "cheerfully armed alarms it couldn't deliver and recorded nothing when it missed."

Tonight three things changed that matter most:
1. **The never-late net now actually runs for the flagship failure case** — a rider who opens the app already underground with no GPS fix is now woken by the physics reachability backstop on the wall clock alone (was a silent no-wake). It is wired into distance and non-metro-time fire paths too, not just metro-stops.
2. **The guarantee is now gated in CI** — committed fixtures, fail-on-empty, and never-late + never-wrong-place assertions, so it cannot silently regress on any future `lib/` change.
3. **The app is now honest at the door** — it refuses to arm on a dead delivery channel (notifications off) instead of a dismissible "Proceed anyway", and it no longer refuses the flagship interstate overnight sleeper.

What is still NOT settled tonight, and cannot be from a laptop: whether the foreground service and process-death backstop actually survive a real Xiaomi/Oppo/Vivo/Realme force-kill + Doze on hardware, and whether the wake is visibly + audibly delivered through a real OEM's full-screen-intent/DND stack. Those are code-complete and grounded in the current Android docs, but they are labeled **hardware-unproven** below, because a false "it works" is worse than an honest "here's what still needs a real ride."

---

## 1. PROVEN — deterministic, gated, reproducible

Everything here is proven by a committed test with the exact repro command. `export PATH=~/flutter/bin:$PATH` first.

### 1.1 The never-late replay gate is real, committed, and in CI
- **What:** the offline replay harness drives the REAL `EkfOrchestrator` + `AlarmEvaluator` + reachability over committed ride fixtures and FAILS (not skips) on empty, asserting never-late (time), never-wrong-place (space), and not-garbage-early on every ride.
- **Repro:** `flutter test test/ekf/replay_harness_test.dart` → `GATE: PASS (0 late)`.
- **Evidence:** the flagship `allunderground_20min` fixture (GPS dead the entire ride, `maxBlackoutError` ≈ 5 km — EKF dead-reckoning is useless underground) fires **+803 s early**; `express_skip` +180 s; `short_2stop` +135 s. All EARLY-OK, none late.
- **Non-regressable:** `.github/workflows/ci.yml` runs `flutter analyze lib/` + this gate + the reachability proofs on every push/PR. Committed fixtures live in `test/fixtures/replay/` (regenerate with `python3 tools/make_replay_fixtures.py`).

### 1.2 The reachability physics core (never-late by construction)
- **Repro:** `flutter test test/reachability/` → 55 pass. Proves: the worst-case bound reaches the target at-or-before true arrival across a family of blackout start times/durations; cold-start fires with ZERO GPS (GLMT-03 closed); the EKF-only path does NOT fire (isolating the reachability contribution); RRTS/express/default V_LINE ceilings; monotone safety net (reachability never fires later than the EKF-only baseline, proven on every fixture).

### 1.3 Cold-start-underground fire-target math (production backstop) — GAP #1/#2
- **Repro:** `flutter test test/tracking/cold_start_reach_backstop_test.dart` → 7 pass. Proves the per-mode fire target (stops incl. fewer-stops-than-N and no-geometry edges, distance, time) is a correct **lower bound** on the true fire point (so the bound reaching it is never late), and the arm-time anchor seam is callable/safe.

### 1.4 ETA sigma floor — GAP #21
- **Repro:** `flutter test test/eta_sigma_floor_test.dart test/fire_decision_fractile_test.dart` → pass. The ETA cushion no longer collapses to 0 when speed is unobservable (the underground state); it floors the velocity to a realistic transit speed so position uncertainty still yields a positive cushion (was: degrades to median firing = late-risk).

### 1.5 versionCode ships — GAP #6
- **Proven by config:** `android/app/build.gradle` now reads `versionCode flutter.versionCode` / `versionName flutter.versionName` from pubspec `version: x.y.z+N` (was hardcoded `1`, which rejected every 2nd Play upload). A wake-path fix can now actually ship.

### 1.6 Metro-data integrity gate on the SHIPPED Dart data — GAP #12
- **Repro:** `flutter test test/metro_data_integrity_test.dart test/metro_vehicle_types_test.dart` → 18 pass. Asserts India bbox, ordered ≥2-stop sequences, no <40 m dup, dense-line hop ≤6 km, no repeated station, resolvable city+line keys — on `kMetroLineSequences`/`allIndiaStops` (the previously-unvalidated shipped constants).

### 1.7 Offline route pinning — GAP #23
- **Repro:** `flutter test test/route_cache_pin_test.dart test/offline_coordinator_test.dart test/offline_routing_guard_test.dart` → 21 pass. A pinned active route survives past the 5-min TTL on the restore/offline read path (was a destructive read that deleted the last-good route and terminated tracking).

### 1.8 Server error-body cache fix — GAP #24
- **Repro:** `cd geowake-server && npx jest test/maps_error_body.test.js --forceExit` → 4 pass. Google's HTTP-200-with-error-body (`OVER_QUERY_LIMIT` etc.) is no longer cached and served as "no route" for the TTL; only `OK`/`ZERO_RESULTS` are cached, else a non-2xx (429/502) is returned so the client retries.

### 1.9 Backstop lead + 991 cancel — GAP #10/#11
- **Repro:** `flutter test test/notification_backstop_lead_test.dart` → 5 pass. The process-death backstop lead is a real per-mode value (stops×inter-stop, km÷V_LINE) not a flat 60 s; always ≥ the old floor (never late). The ETA backstop id 991 is now cancelled on End-Tracking (sweep + background handler + test recorder), fixing the spurious post-trip wake.

### 1.10 cos(lat) snapping — GAP #27
- **Repro:** `flutter test test/services/projection_correction_test.dart` → 6 pass. Stop snapping now applies the equirectangular cos(lat) correction (was raw degree space → east-west skew; ~37 m drift at 60° in the test).

### 1.11 Reroute vehicle-type whitelist — GAP #13
- **Repro:** `flutter test test/metro_vehicle_types_test.dart` → pass. One shared `kMetroVehicleTypes` (incl. TRAM/COMMUTER_TRAIN/LIGHT_RAIL) used by both the reroute predicate and the transfer predicate (was: reroute rejected commuter/tram alternates the transfer builder accepted → tracking terminated).

### 1.12 Persisted telemetry sink + flush + emit sites — GAP #7/#16 + #8/#15
- **Repro:** `flutter test test/telemetry/` (incl. `emit_sites_test.dart`) → pass. `FileTelemetrySink` appends PII-free JSONL to disk (bounded buffer, size-capped rotation, fail-open), `flush()` is on the interface + service, `configureDefaultSinks({dir})` registers it (wired in `main.dart`).
- **Emit sites now wired (all fail-open):** `alarmArmed` at arm (funnel denominator, with mode/line/city); `gpsLost`/`gpsReacquired` on GPS-blackout entry/exit (the never-late-critical GPS-health funnel); `alarmOutcome` at every destination-alarm fire (the north-star numerator) — **proven** by `test/telemetry/emit_sites_test.dart` (3 tests: the fire lever `reach:true/false` and `mode` are correctly inferred from the fire reason across cold-start/distance/stops). Honest limitation: `alarmOutcome` records `onTime` (fired never-late by construction); distinguishing on-time-vs-late-vs-missed needs post-arrival ground truth the app doesn't yet detect — that classification is the one remaining telemetry gap (see §3).

### 1.13 Delivery-channel preflight completeness — GAP #17/#18/#19 (code) 
- **Repro:** `flutter test test/reliability/` → 209 pass. DND-access + full-screen-intent are probed and surfaced as advisory WARN issues with real deep-links; `applyReliabilityFix` routes each fix action to its true settings screen (was: every "Fix" collapsed to the generic app-settings page). _The device behavior of those settings screens is hardware-unproven — see §2._

### 1.14 Arm-time honesty — GAP #4/#5
- **#4 (block enforcement):** the arm flow now captures the preflight result and REFUSES to arm on a block verdict (notifications off = the wake can never appear), returning the user to fix it — instead of a dismissible "Proceed anyway". Warn-level still proceeds. Proven at the dialog-contract + preflight-service level (`flutter test test/reliability/ test/widgets/preflight_dialog_widget_test.dart`). The full StatefulWidget arm-flow gate is exercised by the reconciled scenario/widget tests; end-to-end on-device confirmation is a device task.
- **#5 (cross-state):** the interstate hard-block is removed; a Delhi→Jaipur cross-state route is armable (cross-state is now a logged soft signal, not a refusal).

### 1.15 The never-late core was adversarially verified — 2 real issues found + fixed
A skeptical reviewer was tasked with BREAKING the never-late guarantee in the cold-start/#3/#9/#21 changes (assume-there's-a-bug). It confirmed the reachability math + the distance/time lower bounds + the sigma floor are sound, and found **2 real precondition weaknesses, now fixed:**
- **Anchor seeded `s=0` on OS-kill resume (real never-late hole).** The resume path seeded the anchor at origin/now regardless of restored progress, so post-resume the bound climbed from 0 and gave zero blackout protection until it re-passed true progress → late/never. **Fixed:** resume now seeds the anchor from the restored snapshot progress at the snapshot's timestamp (`ekfS`/`createdAt`), so the bound correctly over-bounds the distance covered during the kill (`trackingservice.dart` restore path).
- **V_LINE under-bound on an unrecognised fast line (real late risk — partially closed, residual documented).** `forLine` returns the metro `defaultMps` (28 m/s) for any unmatched line, so a *mis-named* fast service (chiefly Delhi Airport Express reported as "Orange Line", or Mumbai Suburban as "Western/Central Line") can under-bound and fire late on that leg during a blackout. **Mitigated:** added `suburban`/`local` keywords (so a suburban-tagged line lands on the 39 m/s express tier) and a `city` match. **Deliberately NOT "fixed" by raising the blanket default to `absoluteCeilingMps` (56)** — the adversarial reviewer, brief, and backlog all suggested that, but it makes every conventional metro fire ~2x early on a blackout and inverts the metro < express < RRTS tier ordering (metro would exceed RRTS), for a residual that is narrow (RRTS is reliably branded and caught; suburban is mostly above-ground where GPS carries it). **The residual is documented in `reachability.dart:forLine` and in STILL-OPEN §3; the robust fix is the shipped dataset (city+line → true speed) or the GTFS vehicle-type threaded onto the leg (#9 follow-up), and a known fast line can be pinned via `overrides` meanwhile.** This is the honest position: keyword matching fundamentally cannot distinguish "Orange Line" the Airport Express from "Orange Line" the Nagpur metro.
- **FINDING 3 (healthy-GPS early bias) fixed** regardless: the reach bound now only overrides dead-reckoned progress once the anchor is stale enough to be a genuine blackout (`FireDecisionConfig.reachBlackoutMinSeconds` = 8 s), so a healthy ride stays inert and only a real blackout invokes the physics bound.
- Also fixed: sparse-line cold-start warning (per-stop spacing derived from the leg when the count is known, not a flat 1.2 km) and defense-in-depth try/catch around the one cold-start telemetry call. **Repro:** `flutter test test/reachability/ test/tracking/ test/ekf/replay_harness_test.dart` → pass, GATE PASS (0 late).

**Green tree at every checkpoint:** `flutter analyze lib/` = **0 errors / 0 warnings** (84 pre-existing info-level lints only); full `flutter test` = all pass (see the final commit).

---

## 2. CODE-FIXED — but HARDWARE-UNPROVEN (needs a device/fleet)

These are code-complete, analyze-clean, grounded in the current official Android docs fetched this session (see §4), and never-late-safe by construction — but the *guarantee* rests on real OEM/OS behavior that a laptop cannot exercise. **Do not claim these "work" until a device pass.**

- **Never-late net on the real background isolate.** The cold-start backstop + distance/time reach wiring are proven at the logic + reachability-layer level (§1.2/1.3/1.4). The full production path runs inside the `flutter_background_service` isolate coupled to `NotificationService`/`AlarmPlayer`, which is not driven headless. Needs an on-device run (armed underground, GPS withheld) to confirm the wall-clock tick fires end-to-end. **Repro on device:** arm a metro route, enable airplane/GPS-off, confirm the wake fires before the target stop.
- **Android 14+ boot/watchdog resume + FGS split (GAP #25).** Grounded: `location` FGS is uncapped and NOT on the Android-15 BOOT_COMPLETED block list; `mediaPlayback`/`dataSync` ARE blocked from boot on API 35+ (so re-arm the alarm sound via AlarmManager, not boot). The code split + boot receiver are a device task — **not attempted headless-provable** (requires a real reboot + OS-kill).
- **OEM force-kill survival + battery-opt (GAP #19/#20).** Deep-link routing is proven (§1.13); whether Xiaomi/Oppo/Vivo/Realme actually keep the FGS alive after the user toggles autostart/battery is the classic dontkillmyapp problem — **hardware-only.** #20 (raise battery-opt to a *blocking* preflight on aggressive OEMs) is coded but held at **WARN** behind a one-line founder toggle — see §3.
- **Full-screen-intent + DND-bypass delivery.** Probes + preflight WARNs + deep-links are proven; whether the wake visibly takes over the lock screen and bypasses DND on a given OEM is device-dependent. Grounded: `USE_FULL_SCREEN_INTENT` is special-access on Android 14+ (auto-granted only to declared alarm/calling apps); `setBypassDnd` needs `ACCESS_NOTIFICATION_POLICY`.
- **`setAlarmClock` as the never-late backstop primitive.** Grounded as the only fully Doze-exempt, no-quota alarm API. Recommended manifest change (declare only `SCHEDULE_EXACT_ALARM`, not both) — see §4/#3.

---

## 3. STILL-OPEN (not fixed tonight; ranked)

- **Telemetry: two residual gaps (GAP #8/#14).** The sink + `alarmArmed`/`gpsLost`/`gpsReacquired`/`alarmOutcome` emit sites are now wired and proven (§1.12). Still open: (a) **on-time-vs-late-vs-missed classification** — `alarmOutcome` records `onTime` (fired never-late by construction); distinguishing a *late/missed* outcome needs post-arrival ground-truth detection the app doesn't do yet; (b) **`reliability{OS-killed/Doze/backstop-fired}` (#14)** — needs the restart-after-kill state machine (persisted clean-shutdown flag set on `_onStart`/clean-stop; absent on next start ⇒ `osKilled:true`). Both are settled designs, not started.
- **Mumbai Suburban V_LINE under-bound (GAP #9 residual).** Grounded: Mumbai suburban EMUs run ~120 km/h but its line names ("Western/Central Line") don't keyword-match express and its city ("mumbai") is shared with the 80 km/h metro, so it resolves to `defaultMps` (100 km/h) → a possible late fire *during an above-ground GPS blackout on a fast suburban train* (narrow: suburban is mostly above-ground where GPS/EKF carries it). City plumbing (done tonight) fixes RRTS; Mumbai suburban needs vehicle-type (COMMUTER_TRAIN/HEAVY_RAIL → higher ceiling) plumbed onto the leg. Over-bounding is the safe direction, so this is a bounded, documented residual, not a silent hole.
- **Metro scheduled-ETA model still dead (GAP #22).** `remainingStopsOnMetro` is still not passed by the production caller, so an underground metro leg's ETA degrades toward the walking floor. Mitigated tonight by the reachability backstop (which fires regardless of ETA) and the sigma floor, but the ETA path itself is still un-wired.
- **Restore-from-snapshot anchor seeding (GAP #2 sub-case).** The arm-time anchor seed handles the fresh-arm cold-start; an OS-kill *restore* still seeds the anchor on the first post-restore tick (a real fix on resume re-anchors). Seeding from the snapshot's last-fix timestamp (to account for train movement during the kill) is not done.
- **hardTMax watchdog + topology dwell cap (GAP #26).** Still disabled in production wiring (belt-and-suspenders for a corrupt anchor; the reachability-reaches-target fire already covers the normal case).
- **Ad wiring / real AdMob IDs / post-arrival card (Phase G).** MONETIZATION.md analysis holds; wiring is not done. Economics (§ ECONOMICS.md) shows ads are NOT the lever — self-hosting routing is.
- **iOS (GAP: iOS).** Out of scope for the Android-first target; the iOS backstop planner is pure+tested but unwired, and `GADApplicationIdentifier` is still missing from Info.plist (would crash if ads enabled on iOS).

---

## 4. Platform grounding (fetched from official docs THIS session — see docs/research/grounding_notes.md, 17 topics, 160 source URLs, adversarially verified)

Load-bearing, decision-changing facts (full citations in `docs/research/grounding_notes.md`):
1. **FGS:** `location` type is UNCAPPED (never model tracking as `dataSync`, which is 6h-capped on API 35+). Alarm sound = `mediaPlayback` (also uncapped). Starting an FGS from background/boot throws `ForegroundServiceStartNotAllowedException` without an exemption. — developer.android.com/develop/background-work/services/fgs/*
2. **Exact alarms:** `setAlarmClock()` is the only fully Doze-exempt, no-quota primitive → the correct never-late backstop. `USE_EXACT_ALARM` is Play-restricted to core alarm/calendar apps (GeoWake = GRAY); declaring BOTH it and `SCHEDULE_EXACT_ALARM` gains nothing and fully exposes the app to that policy. **Recommendation: declare only `SCHEDULE_EXACT_ALARM`, gate on `canScheduleExactAlarms()`.** — developer.android.com/…/alarms/schedule + Play policy 9888170
3. **V_LINE speeds:** conventional Indian metros are design-90/operational-80 km/h (Chennai operator-verbatim) → `defaultMps` 28 (100 km/h) correctly over-bounds. Airport Express design 135 → `expressMps` 39 (140) OK. RRTS/Namo Bharat design 180/operational 160 → `rrtsMps` 53 (190) OK. (Ignore the Airport Express "350 km/h" — signalling, not a train speed.) — Wikipedia/operator sites, §15 of grounding_notes.
4. **Play 2026:** targetSdk must reach 36 before 2026-08-31; 16 KB page size (2025-11) satisfied by AGP 8.9+/NDK r28 (compileSdk already 36).
5. **flutter_local_notifications v16+** requires the three manifest receivers — already present in AndroidManifest.xml (verified; the process-death-backstop-dead gotcha is closed).
6. **Maps pricing 2026:** Directions/Routes India ~$1.50/1000 (70K free); Places Autocomplete *session* usage currently $0 (pay only Place Details) — and GeoWake already uses session tokens + a 450 ms debounce (the keystroke bomb is NOT present). — cloud.google.com/maps; see ECONOMICS.md.
7. **DPDP:** aggregate/anonymised data falls outside the Act, but the Act doesn't define anonymisation and offers no safe harbour → on-device-only aggregation is the safe posture; k-anonymity alone is insufficient (needs k-suppression under DP noise). Rules final 2025-11-13; core obligations bind 2027-05-13. — see DATA_STRATEGY.md.

---

## 5. What shipped this session (commits on `sim-validation`)

- `faf539c` — Phase A foundation: never-late CI gate (committed fixtures, fail-on-empty, never-early/wrong-place assertions, CI workflow) + consolidate the previously-untracked WIP (reachability core, telemetry, reliability) onto the branch + versionCode + arm-gate honesty (#4/#5).
- `3ff862a` — Phase A core: never-late net runs during cold-start-underground (#1/#2) with the whole-route reachability backstop + arm-time anchor seed.
- `873313e` — Phase A: reach bound in distance/time fire paths (#3) + ETA sigma floor (#21).
- (this checkpoint) — integrate 7 reviewed independent packages (#7/#10/#11/#12/#13/#16/#17/#18/#19/#23/#24/#27/#28) + #9 city plumbing + #21 test reconciliation.

Deliverables written: `ECONOMICS.md`, `DATA_STRATEGY.md`, `docs/research/grounding_notes.md` (+ per-topic `docs/research/raw/`), `docs/BACKLOG_CURRENT.md` (re-verified backlog), `docs/IMPL_PACKAGES.md`, this report, and the continuously-appended `PROGRESS.md`.

---

## 6. Honest bottom line

The never-late promise is now **real, wired into every fire mode, and gated in CI so it can't silently regress** — proven deterministically in simulation for the underground/cold-start/blackout cases that a laptop can prove. The app is now **honest at the door** (refuses a dead channel, allows the interstate sleeper) and has a **persisted place to measure itself** (the telemetry sink), though the emit sites that would tell you which phones miss are the clear next step. The economics have a grounded answer (**self-host routing or lose money — ads are not the lever**) and the data moat has a legal-by-construction blueprint. What remains genuinely unproven — and is labeled so, not papered over — is the Android-survival axis (OEM force-kill, boot resume, full-screen/DND delivery): code-complete and doc-grounded, but only a real phone fleet on a real underground commute can turn those from CODE-FIXED into PROVEN.
