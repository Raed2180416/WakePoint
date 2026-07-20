# GeoWake — Autonomous Testing Session Log (resumable)

> Append-only running log for the autonomous testing/hardening mandate
> (`docs/AGENT_TESTING_CHARTER.md`). Companion to `docs/testing/ISSUES.jsonl`.
> Every claim here is tagged **sim** / **emulator** / **real-device**. NEVER
> claim device proof from simulation.

## Environment / how to resume (2026-07-20)
- Project: `/home/raed/Projects/WakePoint`, branch `sim-validation`.
- Flutter 3.44.6 at `/home/raed/flutter/bin`; Android SDK at `~/Android/Sdk`.
  Env helper (PATH etc.): source it before any flutter/adb call.
- Emulator `geowake_test` (emulator-5554, Android 14 / API 34) is UP; the app
  `com.geowake.app` (runtime pkg; source ns `com.example.geowake2`) is INSTALLED
  (debug build). Real phone `ZN5225DML5` NOT currently connected.
- **Box is RAM-constrained (~1 GB free, heavy swap).** HARD RULE: no parallel
  local flutter builds/tests; ONE Workflow orchestrator at a time. Read/analysis
  fan-out (subagents = API calls) is safe; local builds/emulator are not.
- **Headless emulator limitation (emulator):** swiftshader can't allocate the
  Google Maps *platform-view* surface (`ANativeWindow::dequeueBuffer ... error -19`)
  → map renders BLACK on this AVD. Flutter-widget screens render fine. Map/visual
  UX testing needs a windowed emulator or real device. (Not an app bug.)

## Primary confidence source: the L0 never-late oracle (sim)
- `test/scale/reachability_scale_test.dart` drives the REAL
  ReachabilityTracker/VLineTable/Reachability.bound. Made ride-dir configurable:
  `GEOWAKE_SCALE_DIR=/home/raed/geowake_imu_analysis/scale/rides` runs the full
  395-ride matrix (in-repo `test/fixtures/scale` = 15-ride subset otherwise).
- **395-ride result (sim/oracle):** never-late HOLDS on all 395 (LATE=0,
  never-fired=0) — the core promise is bulletproof *in simulation*. Too-early
  tail: stops-early median 1.0 / p95 3.0 / **max 10** (859 s), egregious 22/395,
  all on `long_blind` / `express_skip_long_blind` (sustained GPS blackout). = GW-0005.
- **Root cause (GW-0011):** production ships the pure FREE-RUN bound — the whole
  fastest-feasible tightening subsystem is dormant (`alarm_controller.dart:136`
  `dwellMinSeconds:0.0`, `dynamicLeversEnabled` never set, production topology
  built with `profile:null`).
- **Proven fix direction (sim/oracle):** added an ARMED comparison test. Arming
  the PROVEN Phase-0a dwell cap (dwell floor 10 s ≤ 20 s generated min ⇒ valid
  never-late upper bound; served set = `stations`, correct-by-construction, no
  express trap) keeps never-late (LATE=0 incl. express_skip) AND collapses the
  tail: p95 3.0→2.0, max 10→7, egregious 22→14 (−36%). Test self-guards
  `armed ≤ free-run`. NOTE: wiring `dwellMin>0` to production is a never-late
  *risk* (trades zero-assumption safety) — needs adversarial design first.

## VERIFIED P0 NEVER-LATE HOLES (sim/code-read; the cardinal-sin class)
Independently re-verified against production source (scale test can't catch these
because it injects each ride's certified V_LINE override):
1. **GW-0016 [01] V_LINE line-name collision** — production `_reach.vLineTable =
   const VLineTable()` (no overrides); `forLine` is pure keyword matching. A fast
   service whose Directions name lacks a keyword (Airport Express as "Orange Line"
   135 km/h; Mumbai Suburban as "Western Line" ~120 km/h) → 28 m/s → free-run
   UNDER-bounds during a blackout → **LATE**. Code's own KNOWN RESIDUAL admits it.
   Fix: thread Directions `vehicle_type` onto the leg (data already parsed in
   direction_service.dart) → classify HEAVY_RAIL/RAIL/COMMUTER/HIGH_SPEED to a
   higher ceiling. Only affects blackout earliness (never healthy GPS).
2. **GW-0017 [02] 8 s + 25 m/s window** — reach bound suppressed <8 s of blackout
   (`reachBlackoutMinSeconds=8`) AND dead-reckon velocity clamped to 25 m/s
   (`ekf_pipeline.dart:135`) while express=39/RRTS=53 → a target reached within
   ~8 s of GPS loss on a fast line can fire LATE.
3. **GW-00xx [00] ETA backstop not physics-based** — the OS setAlarmClock backstop
   (the ONLY wake surviving process death) is scheduled from a FROZEN `smoothedETA`
   (`notification_updater.dart:227`), NOT the `now + remaining/V_LINE` physics bound
   the oracle (AGENT_HANDOFF_E2E.md:739) CLAIMS. On a long blackout the ETA freezes
   and the fire time is postponed → on process death, late risk. **Oracle docs-lie.**

## P0 TOO-EARLY
- **[03] multi-leg mode-max** (`alarm_controller.dart:1403`) uses max V_LINE over
  ALL forward legs; a downstream RRTS/express leg inflates the current metro-leg
  blackout bound ~2× → fires ~2× too early. Compensating cap is dormant.
- **[04] tightening is UNWIRED not just OFF** — production topology has
  `profile:null` (RouteProfile.precompute only called in ekf_test_controller), and
  `bound()` reads `config.dwellMinSeconds` not `RouteTopology.dwellMinSeconds` (a
  dead field). Flipping `dynamicLeversEnabled` alone silently no-ops. (refines GW-0011)

## Oracle diff (AGENT_HANDOFF_E2E.md, unsealed after independent findings)
- Oracle is honest that never-late is "proven in the harness, NOT on a real ride."
- Oracle DOCS-LIE: claims the OS backstop is physics/V_LINE-based (line 739);
  code uses frozen smoothedETA → finding [00] stands.
- Oracle presents the multi-leg mode-max as pure safety (line 823); omits its
  too-early cost (finding [03]).
- Oracle admits V_LINE free-run "UNDER-bounds an express that skips dwells" but
  does NOT surface the live line-name-collision LATE hole the CODE documents.
- Real ad ids are NOT wired (`AdService.configure()` never called; test ads only).

## Discovery workflow (39 agents, 0 err, 2.67M tok, ~12 min)
- 23 confirmed + 6 partial high-sev + 105 low-sev findings merged into ISSUES.jsonl
  as GW-0012..GW-0145 (145 total; refute-verified ones tagged accordingly).
- Notable classes beyond the P0s: silent arm-abort on permission deny (UX P1×3),
  a11y unlabeled critical controls (emulator-confirmed: 4/7 clickables unlabeled),
  backstop notification doesn't loop/insist, post-reboot FGS-from-BOOT illegal,
  share write endpoints not owner-bound (location spoof), XFF rate-limit bypass,
  free basic-link shares stream live position by default, per-second disk hammering,
  double GPS stream on map, ad banner rendered on the active tracking surface.

## NEXT (resume here)
1. Fix the 3 P0-never-late holes with deterministic guards (targeted tests +
   395-scale oracle must stay never-late). Order: [01] V_LINE (vehicle-type
   plumbing), [00] physics backstop (min(eta, physics)), [02] 8 s window.
2. Then P0-too-early: arm the tightening correctly ([04] wiring) + cap mode-max [03].
3. L1/L2: build+drive an armed trip on the emulator with adb OS-failure injection,
   read telemetry (needs a Gradle build — do when RAM is quiet). Tag emulator.
4. Security Tier 1 scans (mobsfscan/osv) + libapp.so secret dump; backend authz matrix.
5. Re-verify P0/P1 on the real phone when connected. NEVER claim device proof from sim.

## Light runtime/static verification (emulator + APK-static, 2026-07-20)
- **Perms (emulator, runtime):** USE_EXACT_ALARM granted=true, USE_FULL_SCREEN_INTENT
  granted=true, FOREGROUND_SERVICE(_LOCATION) granted — softens GW-0006/0007 on API34
  (backstop already has the non-revocable exact-alarm path). ABL declared (confirms GW-0004).
  SCHEDULE_EXACT_ALARM granted=false (both exact-alarm perms declared).
- **a11y (emulator, runtime):** home has 7 clickables, 4 UNLABELED incl. BOTH toggles
  (Metro Mode, Time/Distance) + a clickable FrameLayout; hamburger + SeekBar ARE labeled.
  So GW-0009 is "critical toggles unlabeled", not literally zero.
- **APK-static (release app-arm64):** libapp.so has dedicated high-priority channels
  `geowake_alarm_channel_v4` ("GeoWake Alarms (High Priority)") + `geowake_backstop_channel_v1`,
  and an HONEST in-app disclaimer ("no phone app can guarantee it... battery savers, DND,
  deep sleep can delay or silence"). GW-0010 nuance: share token is a String.fromEnvironment
  CONSTANT (extractable IF baked) but this release was built WITHOUT it (no railway URL/token
  in strings → share disabled/BASIC in this artifact). Not confirmed present in this build.
- **Share backend privacy (source):** server.js is latest-only / no-history / TTL / "never
  into a data pipeline" — BUT rounds to 5 dp (~1.1 m = essentially EXACT, mislabeled "COARSE").
  Live-position egress is a USER-INITIATED opt-in share, distinct from the egress-OFF aggregate
  surface — not a covert guardrail breach. [17] owner-binding gap (recipient can spoof writes) is real.
- **Guardrail [28] (source):** GatedBannerAd(AdPlacement.mapTracking) renders on the tracking
  screen for free users but collapses underground and the full-screen wake supersedes it → the
  WAKE/alarm surface itself stays ad-free. Taste/subpar (P2), not a P0 guardrail breach.
- **L1 seam:** integration_test/device_alarm_integration_test.dart drives the REAL app via
  TrackingService.isTestMode + testGpsStream + NotificationService.testRecordedAlarms, gated on
  --dart-define=RUN_DEVICE_INTEGRATION=true. Needs a Gradle build (RAM-heavy) → run when quiet.
- **Security tooling:** only semgrep + strings present locally; osv-scanner/trivy/mobsfscan/
  apkleaks/jadx/apktool/gitleaks MISSING (install for Tier 1-2).

## ⚠️ CONCURRENT-SESSION HAZARD (2026-07-20 ~16:18) — engine writes stood down
- A SEPARATE autonomous Claude session (scratchpad `d27c1c53-...`, launched the
  geowake_test emulator) is ACTIVELY editing the same never-late files: it applied
  the **P0-03 piecewise-V_LINE fix** (`VLineSegment`/`_piecewiseFreeRun` in
  reachability.dart + segment-build +25 lines in alarm_controller.dart) DURING this
  session (reachability.dart grew 828→~910 lines after I first read it).
- Two autonomous writers on never-late code = the never-worse cross-agent hazard.
  I applied a P0-01 `_vehicleCeiling` edit, verified the combined state compiles +
  the 395-oracle stays green (LATE=0), then **REVERTED my edit** to restore
  single-writer coherence (their P0-03 intact). I will NOT edit shared engine files
  while the concurrent session is live.
- **Ready-to-apply, adversarially-verified fix designs handed off in
  `docs/testing/NEVERLATE_FIX_DESIGNS.md`:** P0-01 (APPLY, never-late proven),
  P0-03 (APPLY/APPLIED by the other session), P0-00 (REWORK — Doze/monotonic-clock
  LATE-RISK: recompute physicsFireAt in WALL clock), P0-02 (HOLD — healthy-GPS
  too-early risk on fast lines).
- My non-colliding contributions continue: verification, the ranked report, and
  static security analysis. Shared engine code is the other session's to write.

## Front C security — concrete results (2026-07-20, non-colliding)
- **Tier 1 (dep CVEs):** osv-scanner 2.4.0 on pubspec.lock (172 pkgs) + backend
  package-lock (0 pkgs) → **No known vulnerabilities.** Flutter 3.44.6 satisfies
  the CVE-2026-27704 (Pub Zip-Slip) floor. semgrep on backend → 1 false positive
  (server.js:91 is correct HMAC + crypto.timingSafeEqual).
- **Tier 2 (APK static):** release libapp.so has no baked share token/URL (built
  without --dart-define ⇒ share disabled in this artifact); token is a
  String.fromEnvironment constant (extractable IF baked) = GW-0010 architectural risk.
- **Tier 4 (backend, DEMONSTRATED against a local instance — tag sim/local-backend):**
  - **GW-0087 location-spoof CONFIRMED:** any holder of the global bearer token can
    `POST /v1/share/{id}/ping` to overwrite ANY share's coordinates (victim 12.9,77.6
    → attacker 0.0,0.0 shown on /j/{id}). No per-share owner/capability. Root: GW-0010.
  - **GW-0088 rate-limit bypass CONFIRMED:** rotating X-Forwarded-For defeats the
    per-IP limiter entirely (clientIp takes the spoofable leftmost XFF). Constant IP
    correctly 429s after the limit.
  - Auth (Bearer) correctly enforced (401 missing/wrong). HMAC verify correct +
    timing-safe. CORS single-origin. Backend is latest-only/TTL/no-history (good) but
    the "COARSE 5dp" label ≈ 1.1 m (essentially exact) is misleading.

## Session 2026-07-20 (d0703995) — verification, oracle extension, discovery v2

**Grounding (re-confirmed):** Flutter 3.44.6 + adb + emulator-5554 (API 34, com.geowake.app
installed, pid live) + KVM all up. RAM still tight (~950 MB free, 18 GB swap used) → single-
orchestrator rule held (no parallel local builds; API-fan-out workflows are safe). codebase-
memory index is at HEAD 9064b0e (3390 nodes, ready). 395-ride matrix present.

**Never-late ground truth (sim/oracle):** full 395-ride oracle GREEN with the current
(uncommitted) engine — ran=395 fired=395 never-fired=0 LATE=0; too-early tail median 1.0 /
p95 3.0 / max 10 stops (unchanged; GW-0005 still open). ARMED dwell=10s cuts p95→2.0/max→7.

**The 3 prior P0-never-late holes are CLOSED in the working tree (independently verified):**
- P0-00 GW-0080 physics backstop: `min(eta, physics)`, physics fire-in-seconds computed on the
  MONOTONIC timeline (immune to NTP/DST), refreshed each tick (alarm_controller.dart:1589),
  tested (notification_physics_backstop_test + backstop_lead_test). Frozen-ETA docs-lie closed.
- P0-01 GW-0076 vehicle-type: wired into the PRODUCTION live bound (vMaxFwd + vSegments at
  alarm_controller.dart:1521-1531) AND the backstop (:518). `boundNow` (test-harness only) had
  omitted it → FIXED this session (additive passthrough, production-inert). GW-0159.
- P0-03 piecewise V_LINE: implemented + wired; NEVERLATE_FIX_DESIGNS.md carries full SAFE/LATE-
  RISK analysis (the LATE-RISK there is mitigated by the vehicle-type floor when vehicleType is
  present; residual = fast generic-named leg with NULL vehicleType).

**Oracle extended (charter §7):** added test/reachability/never_late_vehicle_type_piecewise_test.dart
(metamorphic: generic-named fast line fires LATE without the vehicle floor, on-time with it;
piecewise never-late AND tighter incl. anchor-behind) and dwell_cap_even_spacing_late_trap_test.dart
(guards GW-0148). reachability/ dir = 86 tests green; 395-oracle byte-identical post-edit.

**NEW findings (workflow-v2: 21 agents, 0 err, 1.5M tok; + direct) → GW-0146..GW-0159:**
- **GW-0147 P0-never-late (OPEN, sim/code-read):** the process-death OS backstop is armed on
  wall-clock RTC (setAlarmClock=RTC_WAKEUP), but the physics instant is a MONOTONIC duration.
  After total process death a BACKWARD UTC-epoch step (NTP/manual) delays the frozen RTC fire →
  late, when |step| > physics slack (≈0 for an express). Narrow conjunction (process-dead ∧
  backward-step ∧ magnitude ∧ timing) but real. Fix-design (A: ELAPSED_REALTIME channel;
  B: TIME_SET receiver; C: wall pad) in NEVERLATE_FIX_DESIGNS.md. NOT device-proven → not fixed.
- **GW-0148 P1 (latent LATE trap, verified by oracle):** wiring `dwellMinSeconds>0` (the "proven"
  −36% tail fix) is UNSAFE in production — production feeds the cap EVEN-SPACED estimated stop
  positions (transfer_utils.dart:1023 `j/(numStops+1)`), NOT the true served positions the scale
  ARMED proof used. On bunched geometry the even-spaced cap over-charges dwell → under-bounds →
  LATE. Production is SAFE today only because dwellMinSeconds=0 (inert). Guarded + scale-test
  comment corrected. **Do NOT flip the floor positive until real per-line station arc positions
  are threaded.**
- GW-0146 P2 metro TIME-mode drops a +inf fire-forcing bound via .isFinite (latent; +inf can't
  arise on shipped metro TIME today). GW-0149/0150 deep-link (unvalidated id into follower URL;
  silent auto-follow w/ zero consent, over lockscreen). GW-0151/0152 privacy (exact dest address
  on public /j page; coarse coord retained after arrival until TTL). GW-0153/0154/0155 UX
  (stale-selection arms OLD location; current-location marker deleted; no search empty/error
  state). GW-0156/0157 perf (1 Hz notif re-post + disk write, no change detection; triple 1 Hz
  setState rebuilds). GW-0158 rotate the git-history-recoverable Maps key.

**Security (Tier 1-4, sim/local-backend):** osv-scanner 2.4.0 pubspec.lock (172 pkgs) = No issues;
npm audit backend = 0 vulns; gitleaks: no real tracked-source secret (only false positive
mobility_consent_service.dart:29 persistKey). Backend exploits LIVE-RE-CONFIRMED against the
current modified server.js: **GW-0087 location-spoof** (victim 12.9716,77.5946 → attacker ping
204 no owner check → 0,0) and **GW-0088 XFF bypass** (rotating X-Forwarded-For → 7×200 vs
constant → 429 after 5). Both UNFIXED.

**Emulator (emulator-tagged, no rebuild):** receivers correct — BOOT_COMPLETED handled by both
flutter_background_service.BootReceiver AND ScheduledNotificationBootReceiver (manifest:107-113);
FGS type location|mediaPlayback. Runtime perms: USE_EXACT_ALARM=granted (backstop path live),
FULL_SCREEN_INTENT/POST_NOTIFICATIONS/FGS all granted, RECEIVE_BOOT_COMPLETED granted, but
ACCESS_BACKGROUND_LOCATION=granted=FALSE (runtime state). SCHEDULE_EXACT_ALARM=false (USE_EXACT
covers it).

**Uncommitted:** all engine work (P0-00/01/03 from prior sessions + my boundNow passthrough +
doc fixes) + my 3 test files are UNCOMMITTED in the working tree. Multi-session hazard remains.

**NEXT (resume):** (1) GW-0147 fix needs a native ELAPSED_REALTIME backstop + DEVICE proof —
#1 never-late residual. (2) GW-0148: thread real per-line station arc positions (OSM rail
geometry) before ever arming the dwell floor. (3) L1/L2 on emulator needs a test-mode Gradle
build (RUN_DEVICE_INTEGRATION=true) in a RAM-quiet window — still no device-proven never-late.
(4) Backend GW-0087/0088 fixes (per-share capability token; rightmost-XFF/trust-proxy-count).
(5) Real phone for Doze/OEM-kill/reboot backstop survival.

## Session 2026-07-20 PART 2 (d0703995) — real emulator L1/L2 + discovery-v3

**RAM constraint lifted by founder ("don't care about RAM"). Scope = (a) real
emulator L1/L2 + (c) keep hunting; NOT (b) apply fixes — so findings logged, not fixed.**

### 🎯 L1 ACHIEVED (emulator, API 34) — the shipped alarm chain fires on real Android
- The full-app integration test (device_alarm_integration_test.dart) is UNRUNNABLE on this
  headless emulator: (1) pumpAndSettle() never settles (perpetual splash/pulsing animations +
  the Google Maps platform view renders BLACK under swiftshader → RenderAndroidView), and
  (2) app.main() CRASHES the Google Mobile Ads SDK (zzgah IllegalAccessException in
  gms.internal.ads; Play services "out of date: Requires 242115000 found 231818047"). = GW-0170
  (FIXED the test: bounded pump() loops, not pumpAndSettle).
- Built a LEAN harness `integration_test/alarm_chain_ondevice_test.dart` that drives the REAL
  TrackingService->EKF->AlarmController->NotificationService with injected GPS, NO map/ads/main().
- Hit the charter's known wall: vanilla `integration_test` cannot tap the OS runtime-permission
  dialog (GrantPermissionsActivity), and each `flutter test` reinstall wipes `pm grant` — the
  exact reason the charter mandates Patrol. WORKAROUND: a concurrent adb uiautomator tapper
  (per-node resource-id `permission_allow_button`; a single-pass regex FAILS — use per-node).
- **RESULT (emulator-tagged):** with dialogs auto-allowed, the chain FIRED:
  `WAKE ALARM fired -> "Wake Up!" / "You are 1.0 km from your destination." (autoDismiss=false);
  recorded alarms = 1; +1: All tests passed!` First on-device confirmation the shipped alarm
  chain works (distance mode). Still emulator, NOT real device.

### L2 (backstop Doze survival) — integration_test/backstop_doze_ondevice_test.dart
- Schedules a REAL exact-alarm backstop (NotificationService.scheduleEtaBackstop ->
  AndroidScheduleMode.alarmClock = AlarmManager.setAlarmClock RTC_WAKEUP — the GW-0147
  mechanism) and holds the process; a concurrent adb harness (scratchpad/l2_harness.py) checks
  `dumpsys alarm` registration, forces deep Doze (`deviceidle force-idle`), and watches for the
  fire. [RESULT: see the line appended below once the harness reports.]
- NOTE: real-FGS backstop survival through OEM battery-kill / autostart is EXPLICITLY real-device
  territory (charter §5): the black-map emulator can't drive the real UI arm flow, and
  geowake://arm is deliberately foreground-only (Android 12+ FGS-from-background ban). So the
  emulator L2 proves the exact-alarm+Doze OS MECHANISM, not OEM-kill survival.

### Discovery v3 (21 agents, 1.6M tok, 0 err) -> GW-0160..GW-0173 (ISSUES.jsonl now 173)
- **GW-0160 P1 (never-late):** on metro/degraded legs the reach ANCHOR is seeded from the
  rate-limited, velocity-clamped EKF _sPub (+1600 m/tick cap, DR clamp 25 m/s), NOT the accepted
  fix's raw route-snap — so after a long fast-line blackout sHi can sit BELOW true progress
  (precondition (i) violation) → late-fire path. (trackingservice.dart:1215-1225 overrides snap
  with ekfState.s.)
- **GW-0162 P1 (never-FIRE):** LocationManager.accuracyGateMeters is DECLARED "set from the
  alarm threshold" but ASSIGNED NOWHERE → gate permanently 100 m; onGpsAccuracyRejected never
  surfaced. A coarse-location / sustained >100 m ride drops every fix → EKF never bootstraps →
  SILENT no-wake, no feedback. (Independently re-verified; v3 rated P0, I log P1 — conditional on
  coarse-perm; the dead wiring itself is certain.)
- GW-0161 non-metro STOPS branch ignores the reach bound entirely (blackout on a non-metro final
  leg fires late, P2). GW-0163 resumeFromNotification silently ENDS a within-threshold distance
  ride (P2). GW-0164 Pro entitlement grant-only (refund not revoked). GW-0165 report-a-problem
  exports commute city+line telemetry. GW-0166 widget zero a11y. GW-0167 paywall footer overflow
  at large text scale. GW-0168 friends avatar substring(0,1) emoji break. GW-0169 write-only
  _routePayloadsByKey leak. GW-0171 §7.2 harness loadFromPolyline STILL not done. GW-0172 Maps
  proxy (geowake-production/api) sees every origin/destination+Places search. GW-0173 shipped
  buymeacoffee YOUR_HANDLE placeholder.

### Security part 2 (emulator/apk-static + local backend)
- Debug APK: egress-OFF guardrail ENFORCED in code ("Refusing to construct a transmitting sink",
  kDataAssetEgressEnabled=false); gw_share_secret is per-device; widget correctly wired via
  qualifiedAndroidName. Two baked backends: share (geowake-share-production) + the Maps proxy
  (geowake-production/api, device-token auth). GW-0158: rotate the git-history Maps key.
- Backend GW-0087 (location-spoof, no owner binding) + GW-0088 (XFF bypass) LIVE-re-confirmed
  against current server.js (Python repro: victim 12.9716,77.5946 -> attacker 0,0; rotating XFF
  7x200 vs constant 429-after-5).

### New test files this session (all green, UNCOMMITTED)
- test/reachability/never_late_vehicle_type_piecewise_test.dart (metamorphic vehicle-type + piecewise)
- test/reachability/dwell_cap_even_spacing_late_trap_test.dart (GW-0148 guard)
- integration_test/alarm_chain_ondevice_test.dart (lean on-device L1 — PASSES with adb tapper)
- integration_test/backstop_doze_ondevice_test.dart (L2 backstop Doze)
- device_alarm_integration_test.dart REWRITTEN (bounded pumps)

### L2 RESULT (honest, emulator): PARTIAL — mechanism confirmed, runtime-Doze blocked on Patrol
- **Confirmed (emulator/static+runtime):** USE_EXACT_ALARM granted; backstop = setAlarmClock/
  RTC_WAKEUP (GW-0147 mechanism, static); BOOT_COMPLETED re-arm receivers declared correctly;
  FGS type location|mediaPlayback; `deviceidle force-idle` works (Doze injectable); app survives
  force-stop/standby (Task 4).
- **Blocked:** the runtime "backstop schedules + fires through Doze" proof — 3 attempts of
  backstop_doze_ondevice_test.dart all timed out at startTracking / NotificationService init
  (permission-dialog automation is flaky without Patrol; NotificationService.initialize() hangs
  headless; `flutter test` reinstall wipes `pm grant`). = GW-0174. Needs Patrol (charter §3).
- **Real-device-only (unchanged):** OEM battery-kill / autostart survival — charter §5 says farms
  + emulators structurally can't prove it. Still the #1 outstanding objective; no hardware attached.
- NET on the charter's #1 gap: MOVED from pure-sim to "alarm chain fires on a real Android build
  (emulator, distance mode)" — a real step, but never-late is STILL not device-proven on an
  underground ride. ISSUES.jsonl now 174 findings (GW-0174 = the Patrol testability blocker).

## Session 2026-07-20 PART 3 — END-TO-END COVERAGE SELF-AUDIT
- Grounded in the COMPLETE handoff (unsealed docs/AGENT_HANDOFF_E2E.md all 7 sections: UI/UX,
  reliability, monetization, share/guardian, data/telemetry, infra/sim-dashboard/CI/config,
  business values) + charter + specs.
- Ran an 11-agent self-critical coverage audit (mandate vs actual artifacts) → **158 gap items,
  26 P0 / 59 P1 / 53 P2 / 20 P3; only 3 items fully DONE.** Full ranked map =
  **docs/testing/END_TO_END_GAP_AUDIT.md** (632 lines).
- HEADLINE: never-late MATH proven in sim; almost everything else not-done/partial/device-pending;
  0/174 findings are real-device. Biggest buckets NOT done: whole §5 Device column (7
  DEVICE-PENDING items, real phone never attached); 8-persona roster never DROVE the app (Chaos
  Monkey never ran; Perf Profiler = 0 runtime numbers; a11y TalkBack never done); toolchain mostly
  unused (Patrol/Maestro/mobile-mcp/MobSF/reFlutter/mitmproxy+Frida/nuclei/ZAP/Fastbot/Firebase);
  4 build mandates (Semantics=0, loadFromPolyline, harness_runner, FlutterDriverExtension all
  missing; emulator matrix = 1 AVD vs 15; no goldens/Patrol/Maestro CI); 12 screens never driven
  (no screenshots); security Tier 2/3 not run; monetization no real IAP/restore/refund/ad-ids;
  meta: SYSTEM_MAP stale, multi_target_scale_test still deleted, ALL work UNCOMMITTED, sim-oracle
  fidelity itself never audited (critic).

## Session 2026-07-20 PART 4 — GAP-CLOSING GRIND ("so deeply do all that")
Committed checkpoints: 9947358 (protect) → 8b9295a (§7) → 3fd1a56 (security/audit) → 1a5fb25 (map/matrix).

**CLOSED (software, verified):**
- §7 build mandates ALL done + full suite 1364 GREEN: ImuReplayEngineV2.loadFromPolyline +
  EkfTestController.loadRouteFromPolyline + GpsBlackoutWindow (§7.2); lib/testing/harness_runner.dart
  (§7.3, proven driving an arbitrary polyline → fired/neverLate/lead=36s/ekfDrift metrics);
  semanticLabel on 12 icon-only controls + enableFlutterDriverExtension gate (§7.1); restored
  multi_target_scale_test (387 rides × 5 offsets = 1884 targets, never-fired=0 LATE=0).
- Toolchain installed + RUN: MobSF (Docker) → GW-0175 allowBackup, GW-0176 exported components,
  GW-0177 minSdk24; reFlutter/strings on release AOT → GW-0178 (GW-0010 CONFIRMED: --dart-define
  token recoverable by plain strings in all 3 ABIs); apkleaks; Chaos Monkey first run (GW-0179,
  no crash but black-map injection-fail); Perf cold-start 11s/PSS 267MB (GW-0180, debug/emu).
- SIM_ORACLE_FIDELITY.md + GW-0181 (P1 FOUNDATIONAL): the never-late scale gate re-anchors to
  TRUE position (acc=10m) and never reads noisy GPS → the dominant real LATE hazard (along-track-
  backward fix, under-stated accuracy) is un-generatable; LATE=0 partly circular. Quantified vs the
  14-ride recorded corpus (real hacc p99=782m vs sim 10m; 61% of a real metro ride in GPS gaps>5s).
- SYSTEM_MAP.md + docs/system_map/{02,03,04} regenerated to HEAD.
- ISSUES.jsonl now 183 findings.

**BLOCKED / PARTIAL (honest):**
- Real device: no hardware attached — the #1 gap, unchanged. 0/183 findings are real-device.
- Emulator matrix (GW-0183): images 29/33/34/35 downloaded but avdmanager/emulator SDK-XML-v4
  mismatch → new AVDs won't boot; only API-34 runs. Needs cmdline-tools/emulator version sync.
- Tier-3 dynamic egress (GW-0182): Flutter ignores the system proxy → needs iptables-redirect +
  Frida BoringSSL-unpinning; static egress conclusion (egress-OFF enforced, only routing-proxy +
  share destinations) stands.
- Patrol: patrol_cli 4.5.1 installed; a full Patrol on-device suite (the charter backbone that
  would unblock repeatable L1/L2 + the persona committee) is a larger build not yet stood up.
- Personas driving the RUNNING app, real IAP/restore/refund, TalkBack, foldable/tablet/Go: still
  not done (need Patrol + real device / windowed emulator).
