# GeoWake — END-TO-END COVERAGE GAP AUDIT

> Generated 2026-07-20 (session d0703995) by an 11-agent self-critical coverage audit
> mapping the FULL mandate (docs/AGENT_TESTING_CHARTER.md + the sealed oracle
> docs/AGENT_HANDOFF_E2E.md + HANDOFF_TESTING + FEATURES/SCENARIO specs) against what
> was ACTUALLY done (docs/testing/ISSUES.jsonl, test/, integration_test/, filesystem).
> Every status was verified against an artifact, not trusted from prose.

## The one-line verdict

**The never-late MATH is exhaustively proven in simulation (395-ride oracle LATE=0, 86 reachability tests). Almost everything ELSE the mandate asked for is not done, partial, or device-pending. NOTHING is proven on real hardware — the charter's #1 objective (never-late on a real underground ride) remains open, and 0 of 174 findings carry a `real-device` tag.**

## Scoreboard

- **158 gap items** across 11 mandate dimensions.
- By priority: **P0=26, P1=59, P2=53, P3=20**.
- By status: **NOT-DONE=94, PARTIAL=21, DEVICE-PENDING=36, UNVERIFIED=4, DONE=3**.
- Only **3** of 158 audited items are fully DONE.

## P0 — the critical gaps (do these first)

- **Skeptic persona — never tried to break never-late on the running app or a real ride; proven only through the L0 deterministic sim oracle. The charter's #1 objective (confirm never-late on a real underground ride) is unmet.** — 📱 DEVICE-PENDING
  - _mandated by:_ charter §1 (Skeptic) + §0.2 ('never claim device proof from simulation… never confirmed on a real underground ride. Closing that gap is your #1 objective')
  - _missing:_ The single #1 charter objective: a real underground ride (or real-phone L2 with GPS blackout) confirming lead>=0. The sim oracle is legitimate primary confidence but cannot discharge device proof.
- **Patrol + patrol_cli + patrol_mcp (charter's declared UI E2E 'backbone'; the only tool that can tap the OS Location/notification/battery dialogs the FGS depends on)** — ✖ NOT-DONE
  - _mandated by:_ charter §3 'Drive the app (UI)' bullet 1; §7.1
  - _missing:_ Add dev:patrol to pubspec, `dart pub global activate patrol_cli`, register patrol_mcp, and re-run the L2 Doze/permission-dialog flows that GW-0174 says are blocked without it.
- **HomeScreen §01.2 checklist — the 25-row micro-interaction table (recents dropdown, 450ms debounce autocomplete, ×-chip recent removal, single-tap 280ms drop-pin vs double-tap<300ms/<40m zoom, draggable marker, Metro/Time-Distance toggles, value-box clamp dialog, slider bounds per mode, Wake-Me enable logic, all Wake-Me dialogs/sheets, offline-cached arm, decorative low-battery button, AbsorbPointer-while-tracking) never exercised on a running UI** — ✖ NOT-DONE
  - _mandated by:_ Oracle §01.2.11 checklist (25 rows) + charter §4 'cover every micro-interaction: search+recents, map tap/double-tap-zoom, mode toggles, slider bounds, arm CTA enable logic, confirm sheets…'
  - _missing:_ A device/emulator Patrol flow exercising the 25 rows, plus goldens; on the map-touching rows a real device is required (black-map emulator can't render the mini-map).
- **MapTrackingScreen §01.4 checklist — the 13-row table (route-bounds fit, marker snap + ETA/dist decrement + traveled-polyline trim, 12s GPS-out orange banner + orange marker + countdown-continues, share icon podcasts-flip + Stop/Keep sheet, STOP ALARM enable, arrival SNOOZE 60s re-alert, two differently-routing END TRACKING buttons, PopScope back-block, transfer notice, missing-args error dialog) never driven on a rendered map** — ✖ NOT-DONE
  - _mandated by:_ Oracle §01.4.5 checklist (13 rows) + charter §4 (GPS-out/tunnel micro-interaction)
  - _missing:_ Real-device (Maps-rendering) Patrol flow + GPS-cut simulation; nothing short of a real device satisfies this per the log's own admission.
- **Charter §4/§5 systemic a11y fix — the charter said the zero-Semantics gap is a blocker to FIX; it remains unfixed** — ✖ NOT-DONE
  - _mandated by:_ Charter §4 'Confirm it, quantify it, and it's both an a11y bug and a testability blocker you must fix (see §5)'
  - _missing:_ Add Semantics/semanticLabel/Key to icon-only controls across all 12 screens, then re-attempt black-box driving.
- **Emulator black-map limitation not worked around — Maps-dependent screens (Home mini-map, PreloadMap, MapTracking) cannot be driven on the only available emulator** — 📱 DEVICE-PENDING
  - _mandated by:_ Oracle §01 (Home mini-map, MapTracking) + charter §4 map micro-interactions
  - _missing:_ A real device (ZN5225DML5 per the runbook) or a Maps-rendering emulator config to exercise the three map screens; until then these rows are unverifiable.
- **3.1 GPS blackout / tunnel — EKF DR → physics cone, fire ≤ arrival** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §02 3.1 + §5 matrix row 3.1 (sim ✔P / device ✖D)
  - _missing:_ Real tunnel / airplane-mode-60-120s ride on ZN5225DML5 confirming anchor NOT reset (accuracy-9999 sentinel), dt on monotonic clock, alarm at/before stop. No emulator blackout test either.
- **3.2 Doze / battery-opt — OS backstop + FGS survival, id-991 fires** — ◐ PARTIAL
  - _mandated by:_ oracle §02 3.2 + §5 row 3.2 (sim — / device ✖D)
  - _missing:_ A repeatable run showing id-991 firing after `dumpsys deviceidle force-idle` with screen off, WITH and WITHOUT battery-opt exemption. Needs Patrol (GW-0174) on emulator, and real-device confirmation.
- **3.3 Process death (am force-stop) — Layer 3 + manifest receivers, id-991 fires (the acid test)** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §02 3.3 + §5 row 3.3 (sim — / device ✖D); §4 DEVICE-PENDING #2
  - _missing:_ Runtime proof that the OS-owned exact-alarm fires after force-stop (R8/release build with receivers live) + snapshot-restore on relaunch. Zero runtime evidence on any platform.
- **3.4 Reboot — BOOT_COMPLETED re-arm + snapshot restore** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §02 3.4 + §5 row 3.4 (sim — / device ✖D); §4 DEVICE-PENDING #2
  - _missing:_ `adb reboot` after arming, then verify backstop survives + journey notification restored + FGS legally restarts. Entirely unexecuted; concern that BOOT-triggered FGS start is Android-12+ illegal is unresolved.
- **3.5 Aggressive OEM killer — preflight WARN + OS backstop wakes anyway** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §02 3.5 + §5 row 3.5 (sim — / device ✖D); §4 DEVICE-PENDING #3
  - _missing:_ A real aggressive-OEM device: remove battery-opt exemption, lock 10+ min, confirm OS backstop still wakes and preflight raised WARN. Genuinely real-device-only; #1 outstanding objective per the log.
- **3.10 Permission denials — preflight BLOCK/WARN + accuracy gate correctness** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §02 3.10 + §5 row 3.10 (sim ◐P / device ✖D)
  - _missing:_ Real per-permission revocation runs (precise/notifications/background) confirming preflight BLOCK-on-notifications-off / WARN-on-approximate. AND fix the dead accuracyGateMeters wiring (GW-0162) before the accuracy-gate half can even be true.
- **3.11 Accuracy gate + phantom rejection — bad fix dropped** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §02 3.11 + §5 row 3.11 (sim ✔P / device ✖D); §4 DEVICE-PENDING #4
  - _missing:_ Real urban-canyon/tunnel ride confirming 1-3km approximate fixes dropped (onGpsAccuracyRejected) and frozen-confident underground fix rejected as phantom. Synthetic corpora ≠ this handset's live GPS.
- **§4 DEVICE-PENDING #1 — alarm sounds + full-screen over lock screen (channel/DND-bypass/full-screen-intent)** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §4 DEVICE-PENDING item 1
  - _missing:_ Real lock-screen test: screen off + DND on, confirm full-screen intent shows over keyguard and audio bypasses DND. Never visually confirmed; log notes 'backstop notification doesn't loop/insist'.
- **§4 DEVICE-PENDING #2 — exact-alarm backstop (id 991) fires after force-stop AND reboot (R8 receivers survive)** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §4 DEVICE-PENDING item 2
  - _missing:_ Release-build (R8) run: schedule backstop, `am force-stop` then separately `adb reboot`, confirm id-991 notification appears. The single most important unproven safety behavior.
- **§4 DEVICE-PENDING #3 — FGS survives Doze + the specific OEM battery killer** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §4 DEVICE-PENDING item 3
  - _missing:_ Real device: forced Doze + real OEM battery-kill/autostart-off, 10+ min locked, confirm FGS or backstop still wakes. Zero runtime evidence.
- **§4 DEVICE-PENDING #4 — accuracy gate + phantom rejection on REAL degraded GPS** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §4 DEVICE-PENDING item 4
  - _missing:_ Real urban-canyon + tunnel GPS on the handset; plus fixing the dead gate wiring so the behavior under test actually exists.
- **GW-0174 — Patrol testability blocker: no repeatable on-device E2E suite exists** — ✖ NOT-DONE
  - _mandated by:_ charter §3 (2026 toolchain mandates Patrol) + oracle §5 device column
  - _missing:_ A Patrol-based on-device suite that natively grants the permission gauntlet and runs alarm-chain + backstop + OS-failure-injection repeatably. Until then the whole Device column cannot advance past one-shot manual runs.
- **Whole Device column empty — target hardware ZN5225DML5 never attached** — 📱 DEVICE-PENDING
  - _mandated by:_ oracle §5 'driven end-to-end on ZN5225DML5' + §4 bottom line
  - _missing:_ Physical ZN5225DML5 (or any real handset) to execute the entire §4 DEVICE-PENDING list and §5 Device column. The honest founder-facing statement stands: never-late proven in principle/harness; device wake-up pending physical verification.
- **Real phone ZN5225DML5 connected and used for device-only-pending behaviors (Doze, boot re-arm, exact-alarm, OEM battery-kill)** — 📱 DEVICE-PENDING
  - _mandated by:_ charter §2 (device reachable) + §5 L2 + AGENT_HANDOFF_E2E §04 DEVICE-PENDING (7 items)
  - _missing:_ The phone is only ever named as the future target. Nothing in the reliability core (deep Doze / OEM kill / exact-alarm delivery / BOOT_COMPLETED re-arm / full-screen-intent over lock) has been confirmed on real hardware. The charter's #1 objective — never-late on a real underground ride — remains untouched.
- **OEM real phones (Xiaomi/Samsung/Oppo) for background-kill proof** — ✖ NOT-DONE
  - _mandated by:_ charter §5 'Prove this on real OEM phones over adb (buy/borrow 2-3 cheap used handsets)'
  - _missing:_ Cloud farms structurally cannot prove OEM background-kill (charter §5); no MIUI Autostart / One UI 'Deep sleeping' / ColorOS testing exists. The make-or-break reliability front has zero OEM coverage.
- **Real Play Billing sandbox purchase (buyPro → geowake_pro_onetime → charge → Pro) exercised on device** — 📱 DEVICE-PENDING
  - _mandated by:_ Oracle §03.6 B (steps 5-7); §03.1 entitlement model
  - _missing:_ A real Play sandbox tester purchase on ZN5225DML5 confirming _proOwned persist blob '1;0', instant ad removal + gate unlock with no restart, and survival across kill/relaunch.
- **Commit the session's work — the entire multi-session effort (174 findings, never-late fixes, new tests, integration tests) is UNCOMMITTED and one `git clean`/`checkout` from deletion** — ✖ NOT-DONE
  - _mandated by:_ Charter §8 issue log durability + general repo hygiene; oracle §4 test-matrix traceability
  - _missing:_ A commit (or at minimum a stash/branch) capturing all Jul 20 modifications; nothing protects the never-late fixes or the 174-finding corpus from loss.
- **docs/testing/ (ISSUES.jsonl 174 findings, RANKED_FINDINGS_REPORT, TESTING_SESSION_LOG, NEVERLATE_FIX_DESIGNS) is entirely UNTRACKED by git** — ✖ NOT-DONE
  - _mandated by:_ Charter §8 (issue log) — the deliverable must be a durable artifact
  - _missing:_ git add + commit of docs/testing/; the primary work-product of the whole mandate is untracked.
- **The mandate documents themselves (docs/AGENT_TESTING_CHARTER.md, docs/AGENT_HANDOFF_E2E.md sealed oracle, docs/HANDOFF_TESTING.md) are UNTRACKED** — ✖ NOT-DONE
  - _mandated by:_ Meta: the charter/oracle are the spec-of-record and must be version-controlled
  - _missing:_ Commit the charter and sealed oracle so the spec cannot silently drift or be lost.
- **Sim-fidelity of the L0 oracle itself was never audited — the foundation everyone treats as 'truth' has documented open fidelity gates and is extrapolated from n=1 real ride. The reliability audit audited whether the never-late MATH holds in sim; no one audited whether the SIM resembles reality.** — ◐ PARTIAL
  - _mandated by:_ docs/WakePoint_Fidelity_Checklist.md + WakePoint_Scenario_Matrix.md (Stage B/C fidelity gates) + charter §0.2 ('never claim device proof from simulation'); the reliability audit's own reliance on the L0 sim oracle as charter-blessed truth
  - _missing:_ An explicit fidelity audit stating which never-late scenarios are backed by a validated synthesizer vs which extrapolate past the single real ride; close (or scope-flag) the queued/deferred fidelity gates before the '0 violations in sim' claim can be treated as reality-grade rather than model-internal.

---

## Full gap map by dimension

### Charter §1 — the 8-persona roster (cold-install personas DRIVING the running app)

_The charter (§1) mandates a fleet of independent adversarial personas, each getting its own wiped state (`adb shell pm clear com.geowake.app`) and DRIVING THE RUNNING APP from a cold install (cognitive walkthrough, Maestro/mobile-mcp, adb monkey, TalkBack, profilers). That mandate was NOT met for any of the 8. What actually ran were spawned code-review agents — the ISSUES.jsonl persona fields are `discovery:ux-firsttime`, `discovery:ux-power-critic`, `discovery:a11y-audit`, `discovery:perf-profiler`, etc. — and 160 of 174 findings carry `sim/code-read` evidence, 162 begin with the literal tag "sim", and ZERO carry `real-device`. `pm clear` appears only in the charter, never in the session log or any script; Patrol/Maestro/adb-monkey/Fastbot/mobile-mcp are absent from pubspec.yaml and were never installed or run (they surface only as the unmet blocker GW-0174 and as charter text). Concretely: the Chaos Monkey persona never ran in ANY form (0 monkey/fastbot references, no `discovery:chaos` agent). The Accessibility Auditor never did the charter's explicitly "non-negotiable" manual TalkBack pass — all 11 TalkBack repros are hypothetical scripts written from source-reading. The Performance Profiler produced zero runtime numbers (no systrace/gfxinfo/batterystats/meminfo). The First-Time User / Power / Critic never cold-installed or completed a task against the UI (map renders black on the emulator; no screenshot judge committee per §4 ever ran). The Skeptic and Red-Teamer are the least-bad: the Skeptic is proven only via the L0 deterministic sim oracle (charter-blessed as truth, but the #1 objective — a real underground ride — is device-pending), and the Red-Teamer demonstrated two backend exploits (GW-0087 owner-binding spoof, GW-0088 XFF rate-limit bypass) via live Python repros against a LOCAL backend, but ran no on-device dynamic red-teaming (no Frida/mitmproxy egress capture, no deep-link fuzzing against the app, no airplane-mode-mid-ride on hardware). Net: 1 of 8 never ran at all, and 0 of 8 ever drove the running app from a wiped cold install as the charter defines the method._

- **[P0] 📱 DEVICE-PENDING** — Skeptic persona — never tried to break never-late on the running app or a real ride; proven only through the L0 deterministic sim oracle. The charter's #1 objective (confirm never-late on a real underground ride) is unmet.
  - missing: The single #1 charter objective: a real underground ride (or real-phone L2 with GPS blackout) confirming lead>=0. The sim oracle is legitimate primary confidence but cannot discharge device proof.
  - evidence: discovery:bg-neverlate (11) + bg-reliability (14) verified by 395-ride sim gate (oracle); evidence tags all 'sim'; real-device count in ISSUES.jsonl = 0; session log 'Still emulator, NOT real device'
- **[P1] ✖ NOT-DONE** — Chaos Monkey persona — never run in ANY form (no adb monkey / Fastbot2 stochastic fuzzing; no code-review analog either). This is the only persona with zero corresponding discovery agent.
  - missing: Install/run adb monkey or Fastbot2 against the installed APK from a wiped state; capture crashes/ANRs/state-loss. No crash-fuzz coverage exists at all.
  - evidence: grep monkey|fastbot across ISSUES.jsonl = 0; across session log = 0; no `discovery:chaos` in the 34 persona-field values; Fastbot/monkey absent from pubspec.yaml and repo except charter text
- **[P1] ✖ NOT-DONE** — Performance Profiler persona — zero runtime measurement. Cold-start time, jank/frame timings, memory-over-time, and FGS battery/CPU cost were all assessed by reading source, not measured.
  - missing: Actual on-device/emulator profiling numbers (dumpsys gfxinfo jank, meminfo trend over a long ride, batterystats for the FGS, cold-start trace). The persona's entire deliverable — measurements — is absent.
  - evidence: discovery:perf-profiler (15) + workflow-v2:perf-fgs-cost + workflow-v3:perf-memory-over-time — every finding tagged sim/code-read; no systrace/dumpsys gfxinfo/batterystats/meminfo output anywhere in docs/testing
- **[P1] ◐ PARTIAL** — Accessibility Auditor persona — the charter's explicitly NON-NEGOTIABLE manual TalkBack pass on the real phone never happened. All TalkBack findings are code-read; contrast/touch-target/text-scale never checked with Accessibility Scanner/axe-Android or meetsGuideline() matchers.
  - missing: A real TalkBack navigation session on the ZN5225DML5 phone; Accessibility Scanner/axe-Android run; meetsGuideline() a11y matchers wired into widget tests. Contrast/tap-target claims are unverified against a running render.
  - evidence: 14 discovery:a11y-audit findings all 'sim/code-read'; 11 TalkBack repros are hypothetical ('1. TalkBack on...'); only real touch is one emulator UiAutomator clickable-label dump (4/7 unlabeled); grep meetsGuideline|androidTapTargetGuideline in test/ = 0
- **[P2] ◐ PARTIAL** — Red-Teamer persona — no on-device dynamic red-teaming. Deep-link/permission-denial/offline/airplane-mid-ride abuse was code-read only; only the backend was exercised dynamically (against a LOCAL, not deployed, instance).
  - missing: Malformed geowake:// deep-link fuzzing against the installed app; airplane-mode-mid-ride on hardware; Tier-3 mitmproxy+Frida on-device egress proof that no raw trajectory/PII leaves. Backend exploits were real but ran against a local server, not the deployed Railway instance.
  - evidence: discovery:sec-static (15)+sec-privacy (13) all sim/code-read; GW-0087/GW-0088 'oracle/demonstrated (local backend exploit)' via Python repro; no Frida/mitmproxy egress capture on device; app_links deep-link surface audited by code-read (GW-0172 etc.)
- **[P2] ✖ NOT-DONE** — First-Time User persona — never cold-installed and completed the primary task (set alarm → arm → sleep) against the UI; the 4-question cognitive walkthrough was applied to source, not to a running app hitting the real permission gauntlet.
  - missing: An actual cold-install cognitive-walkthrough session driving the UI (the emulator's black Google-Maps view under swiftshader + Ads-SDK crash, GW-0170, blocked full-app runs). No 'hesitation log' from a real first run.
  - evidence: 16 discovery:ux-firsttime findings all sim/code-read; the only runtime permission-dialog tap was an adb uiautomator auto-tapper inside the lean non-persona integration_test alarm_chain_ondevice_test.dart, not a persona walkthrough
- **[P2] ✖ NOT-DONE** — Power User & Critic personas — merged into one code-review agent (discovery:ux-power-critic); no 10th-use friction test (inherently longitudinal/runtime) and no §4 multimodal-LLM screenshot judge committee scoring against Nielsen's 10 heuristics.
  - missing: Repeated real app usage to surface 10th-use friction; a screenshot-based heuristic judge committee. Two distinct charter personas collapsed into a single static reviewer.
  - evidence: 20 discovery:ux-power-critic findings all sim/code-read; no screenshots of the running app captured (map renders black on emulator); no judge-committee scoring artifacts in docs/testing
- **[P2] ✖ NOT-DONE** — Per-persona wiped state (`adb shell pm clear com.geowake.app`) was never executed — no persona got its own independent cold-install state; the shared-schema/≥2-consensus method ran over code-review agents, not app-driving personas.
  - missing: The method's foundational step (wiped per-persona state driving the running app) never occurred; 'verified_by ≥2-persona consensus' is consensus among static reviewers, not among app-driving personas.
  - evidence: 'pm clear' string appears only at charter line 27; absent from TESTING_SESSION_LOG.md and any script under docs/ or scripts/
- **[P2] ✖ NOT-DONE** — None of the mandated app-driving tools were installed or run — Patrol, Maestro, mobile-mcp, DroidBot/LLM-Explorer are absent; they surface only as the unmet testability blocker GW-0174.
  - missing: Any UI automation harness capable of tapping OS permission dialogs and driving the app; without it the entire persona committee reduced to source review. FlutterDriver/Semantics instrumentation (§7.1) also not added, keeping the app un-driveable by black-box tools.
  - evidence: grep patrol|maestro|mobile-mcp in pubspec.yaml = none; the tools appear only in charter + ISSUES GW-0174 ('Needs Patrol') + session log 'the exact reason the charter mandates Patrol'

### Charter §3 — the mandated 2026 toolchain: install + actual use, verified against binaries, pubspec, MCP config, CI, AVDs, and testing docs

_The §3 toolchain is overwhelmingly NOT installed and NOT used. Of the ~20 mandated tools, only 5 low-value CLIs (osv-scanner, apkleaks, jadx, gitleaks, semgrep) are present on PATH — and even those were installed the same day (Jul 20, 18:04–18:43), are not wired into CI, and their actual execution/findings are unverified. Every high-value driver is absent: Patrol (the charter's declared "backbone", and the app has NO patrol dep in pubspec, no patrol_cli, no patrol_mcp) — its absence is self-documented as the blocker GW-0174 that prevented real-Doze L2 proof; Maestro/Maestro-MCP, mobile-mcp, and Dart MCP are not configured (the only MCP server is codebase-memory); DroidBot/LLM-Explorer and adb-monkey/Fastbot2 chaos were never run. The mandated emulator MATRIX (API {24,29,33,34,35} × {pixel_7, tablet, fold} + Go) is a single AVD: android-34 / pixel_7 / google_apis — 1 of ~16 cells (the one correct choice is that it IS google_apis, not playstore). No accessibility oracle exists (zero meetsGuideline/androidTapTargetGuideline in test/, no Accessibility Scanner/axe), no Alchemist goldens (not in pubspec). Security Tier 2–4 dynamic tooling is entirely missing: mobsfscan, MobSF/Docker, trivy, apktool, reFlutter/Blutter, mitmproxy, Frida, nuclei, ZAP, and gcloud/Firebase Test Lab are all absent — meaning the Tier-3 "prove no raw location egress" mandate (mitmproxy+Frida) was never executed, and the ISSUES.jsonl/RANKED references to "mobsfscan"/"reFlutter"/"Blutter" findings cite tools that are not installed, so those security claims are unverified. The session log itself concedes "only semgrep + strings present locally" and lists the rest as MISSING. Net: the discovery/coverage work leaned on hand-rolled Dart tests + adb + one emulator; the professional 2026 toolchain the charter mandates was largely skipped._

- **[P0] ✖ NOT-DONE** — Patrol + patrol_cli + patrol_mcp (charter's declared UI E2E 'backbone'; the only tool that can tap the OS Location/notification/battery dialogs the FGS depends on)
  - missing: Add dev:patrol to pubspec, `dart pub global activate patrol_cli`, register patrol_mcp, and re-run the L2 Doze/permission-dialog flows that GW-0174 says are blocked without it.
  - evidence: pubspec.yaml dev_dependencies has NO patrol/dev:patrol; `which patrol` = not found; no patrol_cli in ~/.pub-cache/bin (only scip_dart); grep patrol in *.dart/*.yaml = 0 hits; no patrol_mcp in ~/.claude.json MCP config. Session log line 320 + GW-0174 explicitly: 'Needs Patrol (charter §3)' as the L2 
- **[P1] ◐ PARTIAL** — Emulator MATRIX: API {24,29,33,34,35} × {pixel_7, pixel_tablet, pixel_fold} + one low-RAM Go profile, google_apis images
  - missing: 14 API×form-factor cells absent — no API 24/29/33/35, no tablet, no fold, no Go profile. Version-fragmentation and foldable coverage is unproven.
  - evidence: Only ONE AVD exists: ~/.config/.android/avd/geowake_test.avd → target=android-34, hw.device.name=pixel_7, tag.id=google_apis, x86_64. That is 1 of ~16 mandated cells. Correct choice: it IS google_apis (not google_apis_playstore) as §3 requires.
- **[P1] ✖ NOT-DONE** — Accessibility oracles: Flutter meetsGuideline() matchers (androidTapTargetGuideline 48×48, textContrastGuideline 4.5:1, labeledTapTargetGuideline) + Accessibility Scanner + axe-Android
  - missing: The mandated a11y CI-veto matchers do not exist; the known zero-Semantics systemic lead (§4/§7.1) has no automated oracle enforcing it.
  - evidence: grep -rl 'meetsGuideline|androidTapTargetGuideline|textContrastGuideline|labeledTapTargetGuideline' test/ integration_test/ = 0 files. No Accessibility Scanner / axe-Android output anywhere.
- **[P1] ◐ PARTIAL** — Security Tier-1 SAST/deps: mobsfscan, osv-scanner, npm audit, flutter pub outdated — gated on every CI build
  - missing: mobsfscan not installed; no security scanner is wired into CI, so the 'every CI build' Tier-1 gate does not exist. mobsfscan-attributed findings are unbacked.
  - evidence: osv-scanner INSTALLED but only Jul 20 18:04 (late in session) and NOT invoked in .github/workflows/ci.yml (CI only runs analyze + never-late replay). mobsfscan NOT on PATH (`which` = not found). Session log line 128 concedes mobsfscan MISSING. ISSUES/RANKED cite 'mobsfscan' findings from a tool that
- **[P1] ✖ NOT-DONE** — Flutter-specific reverse engineering: reFlutter / Blutter (dump libapp.so, confirm --dart-define secret recoverability)
  - missing: The core Flutter-secret-extraction proof (does the compiled share bearer token / Maps key fall out of libapp.so?) was never actually executed; the claims are unverified prose.
  - evidence: `which reflutter blutter`=not found; `pip show reflutter`=nothing; `find ~ -iname '*blutter*'`=nothing. Yet ISSUES.jsonl (2×) and RANKED reference 'reFlutter'/'Blutter' findings — citing tools that are not installed.
- **[P1] ✖ NOT-DONE** — Security Tier-3 dynamic egress proof: mitmproxy + Frida (BoringSSL unpinning) to PROVE no raw trajectory/PII leaves the device
  - missing: The dynamic egress capture that would actually prove the no-raw-egress guardrail was never run; that guarantee currently rests only on static code reading, not observed network truth.
  - evidence: `which mitmproxy frida`=both not found; no capture/pcap/flow artifact in repo. This is the tool pair for the single most important guardrail (raw-location-never-leaves).
- **[P2] ✖ NOT-DONE** — Maestro + Maestro MCP (agentic YAML UX-smoke/regression, deep-link + notification-tap steps)
  - missing: Install Maestro + MCP and author the deep-link (geowake://j/{id}) and notification-tap smoke flows; none exist.
  - evidence: `which maestro` = not found; `find . -iname '*maestro*'` and `-path '*maestro*' -name '*.yaml'` returned nothing; no Maestro MCP in ~/.claude.json. Only reference is a single aspirational mention in ISSUES.jsonl.
- **[P2] ✖ NOT-DONE** — mobile-mcp (npx @mobilenext/mobile-mcp — agent-native controller for free-form exploration)
  - missing: Register mobile-mcp as an MCP server; it was never wired up.
  - evidence: ~/.claude.json mcpServers = only ['codebase-memory-mcp']; project .mcp.json = only codebase-memory. mobile-mcp appears once in ISSUES.jsonl prose but is not configured or run.
- **[P2] ✖ NOT-DONE** — Dart/Flutter MCP (`dart mcp-server`) for hot-reload/widget-tree/runtime-error inner loop
  - missing: Register dart mcp-server and add the dart-define-gated enableFlutterDriverExtension() seam.
  - evidence: Not present in MCP config; grep enableFlutterDriverExtension in lib/ = 0 hits (the §7.1 driver seam was never added).
- **[P2] ✖ NOT-DONE** — adb monkey / Fastbot2 stochastic chaos fuzzing (crashes/ANRs/state-loss)
  - missing: No stochastic fuzz run was ever executed; the Chaos-Monkey persona produced no monkey/Fastbot artifact.
  - evidence: `find ~ -iname '*fastbot*'` = nothing; grep 'adb.*monkey|fastbot' across docs/testing, scripts/, tool/ = 0 hits; only a single 'monkey' mention in HANDOFF_TESTING.md as a recommendation.
- **[P2] ✖ NOT-DONE** — Alchemist visual-regression goldens (text-scale × light/dark × locale)
  - missing: No visual-regression suite exists at all; UI cannot be gated against theme/scale/locale drift.
  - evidence: grep -rl 'alchemist' repo = 0; not in pubspec dev_dependencies; no golden test files under test/.
- **[P2] ◐ PARTIAL** — Security Tier-2 APK static: MobSF (Docker REST), apkleaks, jadx, apktool
  - missing: MobSF and apktool absent; even for installed apkleaks/jadx there is no committed scan output proving they were run against a release APK.
  - evidence: apkleaks + jadx INSTALLED (Jul 20 18:36–18:43); docker present but MobSF NOT installed (`which mobsf`=not found, no MobSF dir); apktool NOT found. No SARIF/JSON scan artifact committed under docs/testing/.
- **[P2] ✖ NOT-DONE** — Security Tier-4 backend: nuclei + OWASP ZAP against the non-prod Railway share instance
  - missing: nuclei and ZAP never installed/run; automated web-vuln scanning of the share backend was not performed (only manual curl/unit checks).
  - evidence: `which nuclei`=not found; no ZAP install or report. (Backend authz was probed via curl/backend.test.js per session log, but the mandated nuclei/ZAP scanners were not used.)
- **[P3] ✖ NOT-DONE** — DroidBot-GPT / LLM-Explorer (LLM-vision autonomous crawler for open-ended discovery)
  - missing: Never installed or run; the open-ended autonomous crawl leg of discovery was done by hand-authored persona prose, not an actual crawler.
  - evidence: `find ~ -iname '*droidbot*' / '*llm-explorer*'` = nothing; no mention in testing docs beyond charter.
- **[P3] ◐ PARTIAL** — Secret/SAST scanners: gitleaks + semgrep
  - missing: Tools present but no artifact proving a scan was run and triaged, and they are not CI-gated.
  - evidence: gitleaks + semgrep both INSTALLED on PATH. But no committed scan report under docs/testing/, and neither is invoked in ci.yml, so actual execution against the repo is unverified.
- **[P3] ✖ NOT-DONE** — Firebase Test Lab (gcloud firebase test android run — OEM-matrix crash-smoke breadth)
  - missing: No cloud OEM crash-smoke pass; OEM breadth entirely unaddressed by any farm.
  - evidence: `which gcloud`=not found; no firebase/gcloud config in repo. (Charter also cautions farms can't prove background survival, but the crash-smoke breadth use was still mandated and not done.)
- **[P3] ✖ NOT-DONE** — trivy (container/dep vuln scanner alongside osv-scanner)
  - missing: Never installed or run.
  - evidence: `which trivy`=not found; session log line 128 lists trivy among MISSING tooling.

### Charter §7 — the four standing build mandates (build these so testing can be exhaustive)

_Of the four standing build mandates, NONE is fully delivered; three are effectively not-done and one is partial. §7.1 (a11y Semantics + Flutter Driver gate) is 0% done — grep of lib/ finds zero semanticLabel/Semantics widgets (the only two "semantics" hits are code comments in alarm_evaluator.dart and telemetry_service.dart) and zero enableFlutterDriverExtension / dart-define driver gate; the systemic a11y+testability blocker the charter flagged remains completely unaddressed. §7.2 (arbitrary-trip EKF via loadFromPolyline/loadRouteFromPolyline) is partial-at-best: the mandated APIs do not exist anywhere in the repo, the route builder is still hardcoded to a fixed TestRouteId enum switch (_loadMetroRoute/_loadNonMetroRoute/_loadMultiModalRoute); a bespoke loadCapturedRouteReplay(json,logDir) exists giving partial credit for "real recorded trips replay," but arbitrary-polyline EKF synthesis (part a) and end-to-end replay through the actual app on emulator with mock-location injection (part c) are missing. §7.3 (lib/testing/harness_runner.dart JSON-spec→EkfTestController→JSON-metrics CLI runner) is not-done — no lib/testing/ directory and no harness_runner file exist; test/ekf/replay_harness_test.dart is a flutter_test gate, not the mandated CLI JSON-in/JSON-out sweeper. §7.4 (emulator matrix + CI: unit/widget/golden per commit, Patrol+Maestro+replay nightly across a device matrix with a real-phone lane) is only fractionally done — ci.yml runs analyze + never-late/reachability Dart gates + full `flutter test` per push/PR on a plain ubuntu runner, but there is NO emulator matrix, NO nightly/schedule/cron, NO Patrol, NO Maestro, NO golden/Alchemist tests at all, NO real-phone lane, and integration_test/ is never invoked by CI. Net: the deterministic Dart never-late gate is real and CI-enforced, but the entire black-box/device/matrix scaffolding the charter demanded to make testing "exhaustive" was not built._

- **[P1] ✖ NOT-DONE** — §7.1a — Add semanticLabel/Semantics(identifier:) to icon-only controls + major screens (a11y fix AND black-box-driver unblocker)
  - missing: Every icon-only control (FABs, map overlays, toggles) still has no accessibility label; nothing was added. TalkBack-invisible and black-box-tool-invisible, exactly as the charter warned.
  - evidence: grep -rn 'semanticLabel|Semantics(' lib/ = 0 matches; grep -rin 'semantics' lib/ = 2 hits, both code comments (alarm_evaluator.dart:658, telemetry_service.dart:75); semanticsLabel = 0
- **[P1] ✖ NOT-DONE** — §7.2a — ImuReplayEngineV2.loadFromPolyline(...) so ANY arbitrary trip synthesizes full EKF/ZUPT/reachability
  - missing: The EKF/IMU synthesizer route builder is still hardcoded to canned metro routes; arbitrary polylines still get no EKF/ZUPT/reachability values — the exact gap the charter names.
  - evidence: grep 'loadFromPolyline' across repo = 0 matches; imu_replay_engine_v2.dart route loading is a hardcoded switch on TestRouteId enum (lines 674-698) dispatching to _loadMetroRoute (line 1104) / _loadNonMetroRoute / _loadMultiModalRoute
- **[P1] ✖ NOT-DONE** — §7.2b — EkfTestController.loadRouteFromPolyline(...)
  - missing: No controller-level entry to load an arbitrary polyline into the EKF test path.
  - evidence: grep 'loadRouteFromPolyline' across repo = 0 matches; ekf_test_controller.dart holds polyline FIELDS (routePolyline etc.) but exposes no arbitrary-polyline route loader
- **[P1] ✖ NOT-DONE** — §7.2 part (c) — same trips replay end-to-end through the ACTUAL app on an emulator (mock-location injection + route playback)
  - missing: No mechanism replays a trip through the shipped app via OS mock-location on an emulator; the on-device tests bypass map/ads and inject a synthetic stream instead of real geolocator playback.
  - evidence: grep 'emu geo fix|mockLocation|setMockLocation' in code/scripts = 0 (only appears in charter prose); integration_test/ uses in-Dart Position stream injectors, and its full-app test (device_alarm_integration_test.dart) is documented as NOT viable on the CI emulator (ads/maps crash), so the real app+m
- **[P1] ✖ NOT-DONE** — §7.4b — Patrol + Maestro + never-late replay run NIGHTLY across the emulator MATRIX
  - missing: No Patrol, no Maestro, no emulator matrix, no nightly schedule. CI is a single ubuntu unit-test lane; the entire black-box + device-matrix nightly layer does not exist.
  - evidence: pubspec.yaml has no patrol/maestro dep (only integration_test); grep patrol|maestro across repo hits only docs (charter, ISSUES.jsonl, session log); ci.yml has no schedule/cron/nightly, no matrix, no reactivecircus/android-emulator-runner, no emulator job; integration_test/ is never invoked by CI
- **[P1] 📱 DEVICE-PENDING** — §7.4c — Real-phone lane for Doze/reboot/OEM
  - missing: No CI lane (self-hosted or otherwise) targeting real hardware; Doze/reboot/OEM-kill validation remains manual and un-gated, so the device-only truths stay unproven by any pipeline.
  - evidence: grep 'real-phone|self-hosted' .github/ = 0; the only on-device assets are integration_test/*_ondevice_test.dart gated behind --dart-define=RUN_DEVICE_INTEGRATION, run manually, never in CI
- **[P2] ✖ NOT-DONE** — §7.1b — Gate enableFlutterDriverExtension() behind a --dart-define
  - missing: No Flutter Driver extension exists at all, gated or otherwise; black-box automation has no entry point into the running app.
  - evidence: grep -rn 'enableFlutterDriverExtension|flutter_driver' lib/ integration_test/ test/ = 0; the only fromEnvironment gates in lib/ are FLUTTER_TEST flags in platform_test_flag_*.dart and tracking_state_store.dart, unrelated to a driver extension
- **[P2] ◐ PARTIAL** — §7.2 part (b) — real recorded trips replay
  - missing: A bespoke single captured-route path exists, but it is NOT the mandated general loadFromPolyline API and is limited to a specific JSON+log format; it does not generalize to arbitrary trips.
  - evidence: imu_replay_engine_v2.dart:709 loadCapturedRouteReplay(routeJsonPath, logDir) decodes a Directions-API JSON polyline + real logs into TestRouteId.capturedRealRoute; wired at ekf_test_controller.dart:603
- **[P2] ✖ NOT-DONE** — §7.3 — lib/testing/harness_runner.dart mapping JSON scenario spec (route, warp, dropout, tolerances) → EkfTestController → JSON metrics, CLI-sweepable
  - missing: No CLI harness that ingests a JSON scenario spec and emits JSON metrics; hundreds of scenarios cannot be swept/diffed from the command line as mandated.
  - evidence: lib/testing/ directory does not exist; find -name 'harness_runner*' = 0; test/ekf/replay_harness_test.dart exists but is a flutter_test baseline GATE over fixed fixtures, not a JSON-in/JSON-out CLI sweeper driven by a scenario spec
- **[P2] ◐ PARTIAL** — §7.4a — CI runs unit/widget/GOLDEN on every commit
  - missing: Per-commit unit gate is real and strong, but there are NO golden/visual-regression tests and no widget-golden step; the Alchemist visual-regression CI veto was never built.
  - evidence: .github/workflows/ci.yml runs on push/PR: flutter analyze + never-late replay gate + reachability proofs + scale + playground e2e + clock guard + metro integrity + full `flutter test`; BUT grep 'matchesGoldenFile|alchemist|goldenTest' test/ = 0 and pubspec has no alchemist dep — zero golden tests ex

### Oracle §01 — the twelve screens: were their micro-interaction checklists actually DRIVEN and verified on device/emulator, or only code-reviewed? Plus charter §4 Alchemist goldens + multimodal judge committee.

_Brutal verdict: ZERO of the twelve screens' micro-interaction checklists were ever driven on device or emulator. Not one screenshot of any screen exists anywhere in the repo (only static science/figure PNGs). The entire §01 UX surface was audited by SOURCE CODE READING only: 156 of 174 ISSUES.jsonl findings are tagged `sim/code-read`, and the 46 `ux` + 17 `a11y` findings are 100% code-read — their `repro` fields are prescriptive step lists a future device-agent is TOLD to run, not evidence of anything executed. The charter §4 mandate is almost entirely unmet: NO Alchemist goldens exist (zero golden files, alchemist not in pubspec), NO Patrol, NO Maestro, NO multimodal-LLM judge committee, and the systemic a11y blocker the charter said to FIX is unfixed — there are still literally ZERO `Semantics()`/`semanticLabel` in all of lib/ (the charter called this both an a11y bug and a black-box-testability blocker; it remains both). Only ONE screen (PostArrival) has any headless widget test that renders the actual screen widget; the other eleven have none. The three `integration_test/*.dart` files are on-device but drive the alarm/notification/backstop plumbing via a trivial host widget — they never navigate to, render, or exercise a single one of the twelve screens or any micro-interaction. The session log itself admits the "black-map emulator can't drive the real UI arm flow," so even the emulator that exists cannot exercise these screens. Net: §01 is a well-written test PLAN that was never executed against a running UI._

- **[P0] ✖ NOT-DONE** — HomeScreen §01.2 checklist — the 25-row micro-interaction table (recents dropdown, 450ms debounce autocomplete, ×-chip recent removal, single-tap 280ms drop-pin vs double-tap<300ms/<40m zoom, draggable marker, Metro/Time-Distance toggles, value-box clamp dialog, slider bounds per mode, Wake-Me enable logic, all Wake-Me dialogs/sheets, offline-cached arm, decorative low-battery button, AbsorbPointer-while-tracking) never exercised on a running UI
  - missing: A device/emulator Patrol flow exercising the 25 rows, plus goldens; on the map-touching rows a real device is required (black-map emulator can't render the mini-map).
  - evidence: No HomeScreen widget test (grep pumpWidget+HomeScreen = 0). No screenshot. All Home findings (GW-0012/0013/0014 etc.) are evidence:'sim/code-read', repro fields are un-run step lists ('1. Fresh install… 2. Pick a destination…'). The 39 'Home' string hits in ISSUES.jsonl are all source-derived.
- **[P0] ✖ NOT-DONE** — MapTrackingScreen §01.4 checklist — the 13-row table (route-bounds fit, marker snap + ETA/dist decrement + traveled-polyline trim, 12s GPS-out orange banner + orange marker + countdown-continues, share icon podcasts-flip + Stop/Keep sheet, STOP ALARM enable, arrival SNOOZE 60s re-alert, two differently-routing END TRACKING buttons, PopScope back-block, transfer notice, missing-args error dialog) never driven on a rendered map
  - missing: Real-device (Maps-rendering) Patrol flow + GPS-cut simulation; nothing short of a real device satisfies this per the log's own admission.
  - evidence: No MapTracking widget/integration test renders the screen (grep MapTrackingScreen in test/integration_test = 0). The 22 'MapTracking' ISSUES hits are code-read. Session log line 272 explicitly admits 'the black-map emulator can't drive the real UI arm flow' — the GoogleMap-dependent screen literally
- **[P0] ✖ NOT-DONE** — Charter §4/§5 systemic a11y fix — the charter said the zero-Semantics gap is a blocker to FIX; it remains unfixed
  - missing: Add Semantics/semanticLabel/Key to icon-only controls across all 12 screens, then re-attempt black-box driving.
  - evidence: grep Semantics\(|semanticLabel in all of lib/ = 0 hits (unchanged). It was CONFIRMED/quantified (GW-0009 and refinements GW-0048/0049) but NOT fixed — every icon-only control (FABs, map overlays, toggles, ringtone preview, low-battery button) is still invisible to TalkBack and to black-box drivers, 
- **[P0] 📱 DEVICE-PENDING** — Emulator black-map limitation not worked around — Maps-dependent screens (Home mini-map, PreloadMap, MapTracking) cannot be driven on the only available emulator
  - missing: A real device (ZN5225DML5 per the runbook) or a Maps-rendering emulator config to exercise the three map screens; until then these rows are unverifiable.
  - evidence: Session log line 272: 'the black-map emulator can't drive the real UI arm flow, and geowake://arm is deliberately foreground-only.' No Maps-API-enabled emulator image or real-device UI pass was stood up, so every map-touching micro-interaction is strictly device-pending.
- **[P1] ✖ NOT-DONE** — SplashScreen §01.1 checklist (5 rows: cold-start animation, force-stop-mid-trip restore to MapTracking, zombie-alarm cleanup, corrupt-snapshot fallback, theme-persist-not-system) never driven on device or emulator
  - missing: Patrol/Maestro flow that cold-starts, force-stops during tracking, relaunches, and asserts landing screen + a golden of the animated splash in both themes.
  - evidence: No screenshot of Splash anywhere (find *.png → only assets/figures). No widget/integration test renders SplashScreen (grep of test+integration_test for SplashScreen = 0 hits). Session-restore router logic is only covered abstractly by test/integration/lifecycle_restore_scenario_test.dart, not by dri
- **[P1] ✖ NOT-DONE** — SettingsDrawer §01.6 checklist — the 12-row table (theme flip+persist, preboarding toggle enable-gating on Metro, ProBadge→paywall routing for Ringtones/Guardian, Friends/DataConsent/Report navigation, Buy-Me-Coffee placeholder-guard snackbar, orphaned Home-widget toggle absence) never driven
  - missing: Emulator drawer-navigation flow asserting each tile's destination + the placeholder-guard snackbar.
  - evidence: No SettingsDrawer widget/integration test (grep = 0). 17 'Settings' ISSUES hits all code-read. The orphaned-WidgetSettingsTile finding is a grep result ('grep of lib/ finds no usage'), confirmed by source not by UI.
- **[P1] ✖ NOT-DONE** — RingtonesScreen §01.7 checklist (preview play/pause exclusivity, radio-select persist, 'Test my alarm now' fires REAL alarm + 5s auto-stop + STOP action, dispose cancels alarm, reopen keeps selection) never driven
  - missing: Device test that taps the FAB and confirms the production alarm rings + auto-stops, plus preview audio behavior.
  - evidence: No RingtonesScreen render test; 3 'Ringtone' ISSUES hits are code-read (GW-0048 a11y is 'sim/code-read'). Real-alarm-from-FAB path never fired on device.
- **[P1] ✖ NOT-DONE** — FriendsRidesScreen §01.8 checklist (empty state, garbage-link snackbar, valid-link→nickname→follow, skip-nickname headline, 30s status refresh, unfollow, deep-link auto-follow) never driven on device
  - missing: Maestro deep-link launch (geowake://j/{id}) asserting auto-follow + screen open, plus live-poll status refresh against the Railway backend.
  - evidence: No FriendsRidesScreen render test (share tests cover ShareJourneyAction + models + deep-link parsing at the service layer only: test/share/share_deep_link_test.dart, journey_share_*). 3 'Friends' ISSUES hits code-read. The geowake://j/{id} auto-follow UI path never exercised end-to-end on a device.
- **[P1] ✖ NOT-DONE** — GuardianSetupScreen §01.9 checklist (free-user locked card→paywall, empty-name/phone snackbar, phone-field filtering to [0-9+ ], save-valid snackbar, auto-share disabled-until-contact, arm-with-Guardian→SMS/WhatsApp composer opens) never driven on device
  - missing: Device flow entering Guardian as Pro, saving a contact, and confirming the real SMS/WhatsApp intent fires on arm.
  - evidence: No GuardianSetupScreen render test; test/share/guardian_service_test.dart covers the service, not the screen or the SMS/WhatsApp composer launch. 7 'Guardian' ISSUES hits code-read. Oracle itself flags Guardian 'arrived' send is foreground-isolate-only — a known gap never device-confirmed.
- **[P1] ✖ NOT-DONE** — Charter §4 Alchemist goldens across text-scale × light/dark × locale (CI-veto visual regression) — entirely absent
  - missing: Add alchemist, author goldens for all 12 screens across the scale×theme×locale matrix, and wire them into ci.yml as a veto.
  - evidence: grep alchemist|matchesGoldenFile|goldenTest across test/integration_test/lib = 0 hits; alchemist NOT in pubspec dev_dependencies (only flutter_test, flutter_lints, integration_test, native_splash, launcher_icons, meta); no test/goldens directory exists.
- **[P1] ✖ NOT-DONE** — Charter §4 multimodal-LLM judge committee scoring screenshots vs Nielsen heuristics + per-persona cognitive walkthrough (≥2-consensus) — never run
  - missing: Capture per-screen screenshots on device, run the multimodal heuristic-scoring committee, keep ≥2-consensus visual findings.
  - evidence: No screenshots of any screen exist to feed a judge (find *.png = assets/figures only). ISSUES verified_by field shows 'refute-verified' (a second agent re-reading SOURCE) and 'persona consensus' from code-read personas — not a screenshot-based visual judge. Zero mention of a heuristic score per scre
- **[P1] ✖ NOT-DONE** — Charter §4 Patrol + Maestro flows (the mandated E2E/UX-smoke tooling that would natively tap OS permission dialogs and drive deep links) — never installed or authored
  - missing: pub add dev:patrol, author Patrol flows for the arm gauntlet + Maestro YAML for deep-link/notification-tap smoke across the 12 screens.
  - evidence: grep patrol|maestro across dart/yaml (excluding docs) = 0 hits; not in pubspec; no .maestro flows; patrol_cli/patrol_mcp never wired. The 3 integration_test files use plain flutter integration_test with a trivial host widget, not Patrol, and drive alarm plumbing not screens.
- **[P2] ✖ NOT-DONE** — PreloadMapScreen §01.3 checklist (auto-advance ~0.3s, dispose-on-background no-crash) never driven
  - missing: A device/emulator pass observing the pass-through transition and backgrounding during preload.
  - evidence: Zero ISSUES.jsonl hits for 'Preload'; no test file references PreloadMapScreen; no screenshot.
- **[P2] ◐ PARTIAL** — PostArrivalScreen §01.5 checklist — PARTIALLY covered by a headless widget test, but the device-observable rows (real OS share sheet opens, ride-hailing provider bottom sheet opens external browser, food/directions Maps launch, real rewarded-ad → 24h Pro grant + snackbar) never driven on device
  - missing: Device verification of external app launches (share sheet, browser, Maps) and a real rewarded-ad grant path.
  - evidence: test/monetization/post_arrival_screen_widget_test.dart renders PostArrivalScreen and asserts header/share-row/rewarded-strip-hidden/Done→Home in a headless flutter-test host (7 testWidgets) — the ONLY screen with such coverage. But it asserts widget presence, not the external-intent / real-ad / OS-s
- **[P2] ✖ NOT-DONE** — DataSharingConsentScreen §01.10 checklist (sections render, age-gate blocks toggle, check-age→grant→age-box-locks, withdraw, service-not-ready disabled state) never driven
  - missing: Emulator flow toggling age+sharing and asserting snackbars/locked-state transitions.
  - evidence: No consent-screen render test (test/data_asset/consent_test.dart tests the consent record/service, not the DPDP screen UI). 6 'Consent' ISSUES hits code-read.
- **[P2] ✖ NOT-DONE** — ReportProblemScreen §01.11 checklist (PII-free diagnostics preview loads monospace, note entry, Send→OS share sheet, crash-variant reached from next-launch dialog) never driven on device
  - missing: Device pass loading the diagnostics preview + confirming the crash-relaunch dialog offers the report once.
  - evidence: No ReportProblemScreen render test; telemetry builder covered at test/telemetry/* only. 11 'Report' ISSUES hits code-read. The crash-on-next-launch dialog→report path never exercised on device.
- **[P2] ✖ NOT-DONE** — Paywall §01.12 checklist (source-row highlight, Unlock-forever billing flow, Watch-video rewarded→24h, Restore, Terms/Privacy external URL, already-Pro state) never driven on device
  - missing: Device flow opening paywall from a locked feature asserting row-highlight + the billing/rewarded/restore surfaces.
  - evidence: No GeoWakePaywall render test (monetization tests cover premium_service/entitlement logic, not the screen). 9 'Paywall' ISSUES hits code-read. Real billing/rewarded-ad flows never touched on device.

### Oracle §4/§5 — reliability (never-late edge cases 3.1–3.12 + §4 DEVICE-PENDING 7 items) across sim(L0)/emulator(L1-L2)/real-device columns

_The never-late MATH is well-covered in sim and the test files backing that claim genuinely exist (test/reachability/, test/scale/reachability_scale_test.dart, test/ekf/replay_harness_test.dart) — though I verified their EXISTENCE, not their green result (READ-ONLY: I did not run flutter test, so the "63/63, ran=15 fired=15 LATE=0" figure is claimed-in-prose, not re-observed by me). The entire Device column of the §5 matrix is honestly ✖/◐ and remains so: NO real hardware was ever attached this session (target ZN5225DML5 never touched; log says "no hardware attached" repeatedly). The ONLY new device-class evidence this session is a single emulator (API34) L1 run: the shipped TrackingService→EKF→AlarmController→NotificationService chain fired ONE distance-mode alarm ("recorded alarms = 1") via alarm_chain_ondevice_test.dart, using an adb-uiautomator permission-tapper workaround. That is a real step but a thin slice: it does NOT exercise any OS-failure scenario (no blackout/DR, no Doze, no process-death, no reboot). L2 (backstop firing through forced Doze) is BLOCKED — 3 attempts of backstop_doze_ondevice_test.dart timed out at startTracking/NotificationService.initialize(); logged as GW-0174 (the Patrol testability blocker, issue #174). The referenced scratchpad/l2_harness.py does not exist (session scratchpad wiped) and the log's "[RESULT: see line appended below]" placeholder was never filled — so even the emulator L2 mechanism proof is incomplete, only static/runtime facts (exact-alarm granted, receivers declared, deviceidle force-idle injectable) were confirmed. Net: 3.2 Doze, 3.3 process-death, 3.4 reboot, 3.5 OEM-kill, 3.10 permission-denial — the five you flagged — have ZERO runtime proof of the actual safety behavior (backstop id-991 firing / wake surviving) on either emulator or device. All 7 §4 DEVICE-PENDING items remain unproven. Additionally the sim column has a regression the oracle itself flags: test/scale/multi_target_scale_test.dart is git-DELETED (status D)._

- **[P0] 📱 DEVICE-PENDING** — 3.1 GPS blackout / tunnel — EKF DR → physics cone, fire ≤ arrival
  - missing: Real tunnel / airplane-mode-60-120s ride on ZN5225DML5 confirming anchor NOT reset (accuracy-9999 sentinel), dt on monotonic clock, alarm at/before stop. No emulator blackout test either.
  - evidence: SIM: proven-file exists — reachability_test.dart core theorem + fire-timing on real-line geometry across blackout start/durations; ekf/replay_harness_test.dart DR/ZUPT. EMULATOR: NOT exercised — the one L1 run was a healthy distance-mode approach, no blackout/DR segment. DEVICE: ✖ never run.
- **[P0] ◐ PARTIAL** — 3.2 Doze / battery-opt — OS backstop + FGS survival, id-991 fires
  - missing: A repeatable run showing id-991 firing after `dumpsys deviceidle force-idle` with screen off, WITH and WITHOUT battery-opt exemption. Needs Patrol (GW-0174) on emulator, and real-device confirmation.
  - evidence: SIM: N/A by design. EMULATOR: only STATIC/runtime facts confirmed — USE_EXACT_ALARM granted, backstop=setAlarmClock RTC_WAKEUP, `deviceidle force-idle` injectable. The runtime proof (backstop actually FIRES through forced Doze) is BLOCKED = GW-0174; scratchpad/l2_harness.py referenced by the log doe
- **[P0] 📱 DEVICE-PENDING** — 3.3 Process death (am force-stop) — Layer 3 + manifest receivers, id-991 fires (the acid test)
  - missing: Runtime proof that the OS-owned exact-alarm fires after force-stop (R8/release build with receivers live) + snapshot-restore on relaunch. Zero runtime evidence on any platform.
  - evidence: SIM: N/A. EMULATOR: manifest receivers (ScheduledNotificationReceiver, ActionBroadcastReceiver, BOOT_COMPLETED/MY_PACKAGE_REPLACED) verified DECLARED in AndroidManifest.xml lines 102-147; log claims 'app survives force-stop/standby (Task 4)' but the acid test — id-991 backstop firing AFTER `am force
- **[P0] 📱 DEVICE-PENDING** — 3.4 Reboot — BOOT_COMPLETED re-arm + snapshot restore
  - missing: `adb reboot` after arming, then verify backstop survives + journey notification restored + FGS legally restarts. Entirely unexecuted; concern that BOOT-triggered FGS start is Android-12+ illegal is unresolved.
  - evidence: SIM: N/A. EMULATOR: BOOT_COMPLETED receiver declared (manifest:109) but NO reboot test was run (`adb reboot` never executed — READ-ONLY session anyway). Log also flags 'post-reboot FGS-from-BOOT illegal' as an open concern. DEVICE: ✖.
- **[P0] 📱 DEVICE-PENDING** — 3.5 Aggressive OEM killer — preflight WARN + OS backstop wakes anyway
  - missing: A real aggressive-OEM device: remove battery-opt exemption, lock 10+ min, confirm OS backstop still wakes and preflight raised WARN. Genuinely real-device-only; #1 outstanding objective per the log.
  - evidence: SIM: N/A. EMULATOR: structurally impossible — charter §5 and the log both state emulators/farms CANNOT reproduce OEM battery-kill/autostart. ReliabilityPreflightService.isAggressiveOem exists but WARN-escalation never runtime-verified. DEVICE: ✖ — and target is a generic handset, not even a Xiaomi/O
- **[P0] 📱 DEVICE-PENDING** — 3.10 Permission denials — preflight BLOCK/WARN + accuracy gate correctness
  - missing: Real per-permission revocation runs (precise/notifications/background) confirming preflight BLOCK-on-notifications-off / WARN-on-approximate. AND fix the dead accuracyGateMeters wiring (GW-0162) before the accuracy-gate half can even be true.
  - evidence: SIM: only ◐ even in sim (matrix). DEVICE: ✖ — no revoke-precise/notifications/background runs. WORSE: GW-0162 found LocationManager.accuracyGateMeters is DECLARED 'set from alarm threshold' but ASSIGNED NOWHERE → gate permanently pinned 100m; onGpsAccuracyRejected never surfaced — so the approximate
- **[P0] 📱 DEVICE-PENDING** — 3.11 Accuracy gate + phantom rejection — bad fix dropped
  - missing: Real urban-canyon/tunnel ride confirming 1-3km approximate fixes dropped (onGpsAccuracyRejected) and frozen-confident underground fix rejected as phantom. Synthetic corpora ≠ this handset's live GPS.
  - evidence: SIM: covered by unit + edgecases + replay corpora (accuracy sanitisation sHi≥sMeters; NaN-anchor fails-safe). DEVICE: ✖ — 'sim bypasses the gate' by design (oracle 3.11), so real degraded GPS is the ONLY real proof and it never happened. Also entangled with GW-0162 dead gate wiring.
- **[P0] 📱 DEVICE-PENDING** — §4 DEVICE-PENDING #1 — alarm sounds + full-screen over lock screen (channel/DND-bypass/full-screen-intent)
  - missing: Real lock-screen test: screen off + DND on, confirm full-screen intent shows over keyguard and audio bypasses DND. Never visually confirmed; log notes 'backstop notification doesn't loop/insist'.
  - evidence: EMULATOR/STATIC: channels exist (geowake_alarm_channel_v4 High Priority, geowake_backstop_channel_v1); USE_FULL_SCREEN_INTENT granted=true on API34. But the L1 fire was asserted only via testOnShowWakeUpAlarm callback in-process — NOT a visible full-screen lock-screen alarm. DEVICE: ✖.
- **[P0] 📱 DEVICE-PENDING** — §4 DEVICE-PENDING #2 — exact-alarm backstop (id 991) fires after force-stop AND reboot (R8 receivers survive)
  - missing: Release-build (R8) run: schedule backstop, `am force-stop` then separately `adb reboot`, confirm id-991 notification appears. The single most important unproven safety behavior.
  - evidence: Receivers declared in manifest (verified). Mechanism static-confirmed (setAlarmClock/RTC_WAKEUP). Runtime FIRE after force-stop/reboot NEVER proven — blocked GW-0174 on emulator, never attempted on device, and never on a release/R8 build (only debug APK examined). DEVICE: ✖.
- **[P0] 📱 DEVICE-PENDING** — §4 DEVICE-PENDING #3 — FGS survives Doze + the specific OEM battery killer
  - missing: Real device: forced Doze + real OEM battery-kill/autostart-off, 10+ min locked, confirm FGS or backstop still wakes. Zero runtime evidence.
  - evidence: Emulator can inject Doze (force-idle) but the FGS-survives-Doze runtime run is blocked (GW-0174); OEM-killer is structurally un-emulatable (charter §5). DEVICE: ✖ — no hardware.
- **[P0] 📱 DEVICE-PENDING** — §4 DEVICE-PENDING #4 — accuracy gate + phantom rejection on REAL degraded GPS
  - missing: Real urban-canyon + tunnel GPS on the handset; plus fixing the dead gate wiring so the behavior under test actually exists.
  - evidence: Only synthetic corpora (replay_harness) exercise this; oracle explicitly says sim bypasses the gate. Compounded by GW-0162 (accuracyGateMeters assigned nowhere). DEVICE: ✖.
- **[P0] ✖ NOT-DONE** — GW-0174 — Patrol testability blocker: no repeatable on-device E2E suite exists
  - missing: A Patrol-based on-device suite that natively grants the permission gauntlet and runs alarm-chain + backstop + OS-failure-injection repeatably. Until then the whole Device column cannot advance past one-shot manual runs.
  - evidence: ISSUES.jsonl #174 (last entry): vanilla integration_test can't tap GrantPermissionsActivity and each `flutter test` reinstall wipes `pm grant`; NotificationService.initialize() hangs headless; 3 backstop_doze attempts timed out. Only a manually-assisted single-shot L1 succeeds.
- **[P0] 📱 DEVICE-PENDING** — Whole Device column empty — target hardware ZN5225DML5 never attached
  - missing: Physical ZN5225DML5 (or any real handset) to execute the entire §4 DEVICE-PENDING list and §5 Device column. The honest founder-facing statement stands: never-late proven in principle/harness; device wake-up pending physical verification.
  - evidence: Session log states 'no hardware attached' / 'no hardware attached; #1 outstanding objective' repeatedly; every device run this session was the API34 EMULATOR, not the phone. `real-device` tag count in ISSUES.jsonl = 0 findings closed by device proof.
- **[P1] 📱 DEVICE-PENDING** — 3.6 No network — offline EKF/physics, fire ≤ arrival
  - missing: Real device with data+wifi off (GPS on) mid-ride confirming alarm still fires. Not exercised on emulator or phone.
  - evidence: SIM: covered — offline routing guard / EKF path proven no code awaits network in fire loop (offline_routing_guard_test.dart etc. exist). DEVICE: ✖ — never toggled data+wifi off on a real armed ride.
- **[P1] 📱 DEVICE-PENDING** — 3.7 Transfers / interchange — leg logic + max-V_LINE bound, only intended alarms
  - missing: Ride an actual metro→walk→metro interchange verifying no spurious pre-boarding/mode-change alarm and only intended per-leg alarms. Device-only.
  - evidence: SIM: covered — multileg_piecewise_vline_test.dart + alarm_controller interchange logic proven in unit tests. DEVICE: ✖ — no real multi-leg interchange ride.
- **[P1] 📱 DEVICE-PENDING** — 3.8 Early arrival / overshoot — idempotency, fires once ≤ arrival
  - missing: Real (or full emulator) run that overshoots the target and runs faster-than-schedule confirming single fire at/before stop. Only one healthy emulator fire so far.
  - evidence: SIM: proven — firedLegIds/destinationAlarmFired idempotency in reachability/alarm tests. EMULATOR: the single L1 run fired exactly once (recorded alarms = 1) — weak partial support for idempotency. DEVICE: ◐/✖ — matrix itself marks device ◐, no real overshoot ride.
- **[P1] 📱 DEVICE-PENDING** — 3.12 Stale-fix / corrupt-input watchdog — fail-safe → +inf, fire never freeze
  - missing: On-device fault-injection (NaN anchor/clock) in a debug build confirming fail-safe fire rather than freeze across the EKF→physics 8s boundary. Device column empty.
  - evidence: SIM: strongly covered — reachability_edgecases_test.dart proves NaN anchor/clock ⇒ +inf ⇒ fire (a fixed defect with regression test), 8s reachBlackoutMinSeconds handoff no dead-zone. DEVICE: ✖ — fault-injection debug-build run on phone never done.
- **[P1] 📱 DEVICE-PENDING** — §4 DEVICE-PENDING #5 — arm-time preflight actually wired to arm button + concrete ReliabilityProbe, blocks/warns as designed
  - missing: Drive the real arm flow (Patrol/device) and confirm preflight fires, calls the concrete probe, and BLOCKs/WARNs. Currently only code-read, never executed.
  - evidence: ReliabilityPreflightService + ReliabilityProbe exist in code but the arm-button→service→probe wiring and its BLOCK/WARN behavior were never runtime-driven (black-map emulator can't drive the real arm UI; no Patrol; no device). GW-0171 also flags §7.2 harness loadFromPolyline still not done. DEVICE: 
- **[P1] 📱 DEVICE-PENDING** — §4 DEVICE-PENDING #6 — real IMU tilt/bias on this device keeps the tight cone usable
  - missing: A live ride on ZN5225DML5 confirming real accelerometer/gyro bias doesn't blow up the DR cone. Recorded-corpus proof ≠ live-sensor proof.
  - evidence: replay_harness_test.dart uses RECORDED corpora, not this handset's live sensors (oracle states this explicitly). DEVICE: ✖ — no live-IMU ride on target.
- **[P1] 📱 DEVICE-PENDING** — §4 DEVICE-PENDING #7 — end-to-end latency: monotonic clock across real sleep/wake + ~1Hz re-arm freshness without battery churn
  - missing: Instrumented real-device session across screen sleep/wake measuring monotonic-clock drift, backstop re-arm freshness, and battery cost. No data exists.
  - evidence: Entirely unmeasured — no real sleep/wake cycle timed, no battery-drain measurement, no ~1Hz re-arm churn observation. DEVICE: ✖. Emulator L2 (which would touch this) is blocked.
- **[P2] 📱 DEVICE-PENDING** — 3.9 Very short trip — eligibility-gate bypass (metro), fires
  - missing: A real 1-2 stop metro trip confirming the 100m/3-sample/30s gate doesn't suppress it. Not run on device; emulator run was distance mode, not short-metro.
  - evidence: SIM: covered — metro bypass of non-metro eligibility gate proven in unit tests. EMULATOR: L1 distance-mode fire is tangential (not a 1-2-stop metro trip). DEVICE: ◐/✖.
- **[P2] ✖ NOT-DONE** — Sim coverage REGRESSION — test/scale/multi_target_scale_test.dart deleted (git status D)
  - missing: Restore or rewrite multi-target scale coverage. Currently the sim column lost a test the oracle expected.
  - evidence: git status shows `D test/scale/multi_target_scale_test.dart`; only reachability_scale_test.dart remains under test/scale/. Oracle §4 note: 'If the multi-target scale coverage is wanted, it must be restored/rewritten.'
- **[P2] ? UNVERIFIED** — Sim '63/63 pass, ran=15 LATE=0' — claimed in prose, not re-observed by this audit
  - missing: An independent CI/local run to confirm the green figure. Files existing is necessary but not sufficient evidence of passing.
  - evidence: READ-ONLY audit: I verified the test FILES exist (test/reachability/*.dart, test/scale/reachability_scale_test.dart, test/ekf/replay_harness_test.dart) but did NOT run flutter test. The pass counts are the prior session's assertion, not independently reproduced here.

### Charter §3 emulator matrix — API {24,29,33,34,35} × {pixel_7, pixel_tablet, pixel_fold} + 1 low-RAM 'Go' (google_apis images), plus real phone ZN5225DML5

_The charter §3 mandates a 16-cell emulator matrix (5 API levels × 3 form factors + 1 low-RAM Go profile), all on google_apis images. Reality: exactly ONE AVD exists — `geowake_test` (API 34, pixel_7, google_apis, x86_64, 1536M RAM), and only ONE system image is installed on disk (`android-34/google_apis/x86_64`). That is 1 of 16 cells = ~6% of the mandated matrix. The image-type requirement (google_apis, NOT playstore) is the only part fully satisfied — `PlayStore.enabled = no`, `tag.id = google_apis`. Fifteen cells are entirely missing: every non-API-34 level (24, 29, 33, 35), both alternate form factors (pixel_tablet, pixel_fold), and the Go profile. No emulator matrix exists in CI either — `.github/workflows/ci.yml` runs only the pure-Dart never-late scale test; there is no `android-emulator-runner`, no `api-level` matrix, no emulator boot. The single AVD is also crippled for its intended purpose: the map renders BLACK under swiftshader (GW-0020) and app.main() crashes the Ads SDK (GW-0170), so even API-34 L1 was proven only ONCE via a flaky manual dialog-tapper (GW-0174), never repeatably. The real phone ZN5225DML5 is referenced throughout the docs purely as the *pending target* — it is NOT currently connected (session log line 14) and every "device" reference in AGENT_HANDOFF_E2E sits under DEVICE-PENDING / "the next agent must verify" headings. Net: the OS-version and form-factor coverage the matrix was designed to catch — legacy notif/FGS behavior, scoped/background location eras, the POST_NOTIFICATIONS runtime gate, foldable/tablet layout, and low-RAM process-death — is entirely unexercised._

- **[P0] 📱 DEVICE-PENDING** — Real phone ZN5225DML5 connected and used for device-only-pending behaviors (Doze, boot re-arm, exact-alarm, OEM battery-kill)
  - missing: The phone is only ever named as the future target. Nothing in the reliability core (deep Doze / OEM kill / exact-alarm delivery / BOOT_COMPLETED re-arm / full-screen-intent over lock) has been confirmed on real hardware. The charter's #1 objective — never-late on a real underground ride — remains untouched.
  - evidence: TESTING_SESSION_LOG.md:14 'Real phone ZN5225DML5 NOT currently connected'; adb devices shows only emulator-5554; every ZN5225DML5 grep hit in AGENT_HANDOFF_E2E is under 'DEVICE-PENDING — NOT proven by any test; the next agent must verify' (lines 900, 942, 958)
- **[P0] ✖ NOT-DONE** — OEM real phones (Xiaomi/Samsung/Oppo) for background-kill proof
  - missing: Cloud farms structurally cannot prove OEM background-kill (charter §5); no MIUI Autostart / One UI 'Deep sleeping' / ColorOS testing exists. The make-or-break reliability front has zero OEM coverage.
  - evidence: Only device ever seen is one emulator; no OEM device referenced in ISSUES.jsonl or session log; ZN5225DML5 is a single Motorola-class handle, not the MIUI/OneUI/ColorOS trio
- **[P1] ◐ PARTIAL** — API 34 × pixel_7 cell (the one baseline that exists)
  - missing: Even this cell has no repeatable UI/L1 run — map+ads unusable headless; needs Patrol per GW-0174. It is emulator-touched, not emulator-proven.
  - evidence: emulator-5554 up (TESTING_SESSION_LOG.md:12); AVD config = pixel_7/android-34. But GW-0020 (map renders BLACK under swiftshader), GW-0170 (app.main crashes Ads SDK), GW-0174 (L1 alarm chain passed ONCE via flaky manual tapper, not repeatable)
- **[P1] ✖ NOT-DONE** — API 24 (Android 7) × all form factors — legacy notification + pre-O foreground-service semantics
  - missing: Would catch pre-Oreo notification channels absent, unbounded background services, legacy alarm behavior, no runtime notif permission. Entirely untested — no image, no AVD.
  - evidence: Only android-34 system image installed (find ~/Android/Sdk/system-images); no android-24 image, no AVD
- **[P1] ✖ NOT-DONE** — API 29 (Android 10) × all form factors — background-location (ACCESS_BACKGROUND_LOCATION introduced), scoped storage
  - missing: API 29 is where background-location became a separate runtime grant — the exact permission the always-on FGS depends on. The background-location gauntlet on the era it first appeared is completely unexercised.
  - evidence: No android-29 system image on disk; no AVD; no grep hits for API 29 in tests/docs/CI
- **[P1] ✖ NOT-DONE** — API 33 (Android 13) × all form factors — POST_NOTIFICATIONS runtime permission gate
  - missing: API 33 introduced the runtime POST_NOTIFICATIONS prompt — if denied, the wake notification (the alarm surface) is silently suppressed. This make-or-break permission path is untested on the API where it first gates.
  - evidence: No android-33 system image installed; no AVD; no CI matrix
- **[P1] ✖ NOT-DONE** — API 35 (Android 15) × all form factors — newest FGS restrictions / latest Doze behavior
  - missing: Android 15 tightened foreground-service-launch and background-start rules — the newest OS the app will actually ship onto is unvalidated for FGS survival.
  - evidence: android-35 platform is installed under platforms/ but NO system-image (only android-34/google_apis exists); no AVD
- **[P1] ✖ NOT-DONE** — Low-RAM 'Go' profile — process-death under memory pressure
  - missing: Go/low-RAM is where Android aggressively kills the foreground service under memory pressure — the exact scenario the exact-alarm backstop (L2) must survive. The most hostile process-death environment is never simulated.
  - evidence: Only AVD has hw.ramSize = 1536M (standard pixel_7); no low-RAM/Go AVD exists
- **[P1] ✖ NOT-DONE** — Emulator matrix wired into CI (android-emulator-runner on KVM)
  - missing: No emulator ever boots in CI; the L1/L2 on-device chain is not gated or re-run automatically on any API level. All emulator work is one-off local against the single API-34 AVD.
  - evidence: .github/workflows/ci.yml has no emulator/api-level/android-emulator-runner/matrix keys — only line 41 'Never-late AT SCALE (real Dart)'. grep for emulator|pixel|api-level in workflows returns nothing
- **[P2] ✖ NOT-DONE** — pixel_tablet form factor (all API levels) — large-screen / tablet layout
  - missing: Wide-screen layout, split panes, map+list proportions, large-screen touch-target reach — no tablet cell exists at any API level.
  - evidence: Only AVD is hw.device.name = pixel_7; no pixel_tablet AVD; no golden/layout test referencing tablet
- **[P2] ✖ NOT-DONE** — pixel_fold foldable (all API levels) — fold/unfold config changes, hinge, dual layouts
  - missing: Foldable posture changes trigger Activity config-change / recreation — a classic place to lose tracking state or the FGS. Entirely untested.
  - evidence: No pixel_fold AVD; no foldable/hinge references anywhere in test/ or docs/testing
- **[P3] ✔ DONE** — google_apis image type (NOT google_apis_playstore) — required so adb root / mock-location works
  - missing: Nothing for this cell — image type is correct.
  - evidence: ~/.config/.android/avd/geowake_test.avd/config.ini: PlayStore.enabled = no; tag.id = google_apis; image.sysdir.1 = system-images/android-34/google_apis/x86_64/

### Oracle §03 Monetization &amp; Premium — coverage audit (WORKS/STUB/GATED/DROPPED matrix + what was actually verified vs never exercised)

_The monetization LOGIC layer is real and exhaustively tested HEADLESS — but nothing money-related is device-proven, and the oracle itself opens by admitting exactly that ("Nothing here is device-proven"). Every entitlement path (buyPro / restore / day-pass grant+expiry / late-UPI grant / decline-leaks-nothing) is covered by test/monetization/*.dart, all driven by FakePurchaseBackend + SharedPreferences.setMockInitialValues — i.e. no real Play Billing, no real AdMob SDK, no device ZN5225DML5. There are ZERO monetization/paywall/ad tests in integration_test/ (only the three alarm/backstop on-device tests exist), so the entire §03.6 device checklist (A free-sees-ads incl. the historical banner init-race, B buy→ads-vanish, C rewarded day-pass, D restore + negative, E late/UPI clear) is device-only-pending and was never run. AdService.configure() is confirmed NEVER called anywhere in lib/test/integration_test (only TelemetryService.configureDefaultSinks matches "configure"), so real ad unit ids are unwired and every ad shown is a Google TEST id — including the AndroidManifest APPLICATION_ID (still ca-app-pub-3940256099942544~3347511713). All five §7 "business values REQUIRED before shipping" are confirmed still placeholders (test ad ids, ₹199 hardcoded fallback, geowake.app/privacy + /terms non-existent pages, no affiliate ids). On top of the untested device surface, prior agents FOUND but never FIXED a cluster of confirmed logic defects: GW-0164 (refund/chargeback never revokes Pro — monotonic _proOwned, no downgrade path → buy-refund-keep-Pro-forever), GW-0131 (day-pass expiry never re-syncs tierListenable → stale Pro UI), GW-0133 (client-side plaintext entitlement blob trivially spoofable, no store/SSV validation), GW-0132 (paywall markets the FREE ramping-volume safety as a Pro benefit, breaking its own trust strip), GW-0130 (ad banner on the active tracking surface), plus P3 nits GW-0134/0135/0136/0138/0139/0167. Net: the money code is fail-safe and well-unit-tested, but revenue is inert and UNVERIFIED end-to-end, and the single most dangerous real-money path (refund→revoke, and UPI-late-clear) has neither a fix nor a device test._

- **[P0] 📱 DEVICE-PENDING** — Real Play Billing sandbox purchase (buyPro → geowake_pro_onetime → charge → Pro) exercised on device
  - missing: A real Play sandbox tester purchase on ZN5225DML5 confirming _proOwned persist blob '1;0', instant ad removal + gate unlock with no restart, and survival across kill/relaunch.
  - evidence: test/monetization/monetization_journey_test.dart Journey 3 uses FakePurchaseBackend(buyShouldSucceed:true) only; grep shows NO paywall/buyPro coverage in integration_test/ (only alarm_chain/backstop/device_alarm on-device tests). IapPurchaseBackend (purchase_backend_impl.dart) never driven by a real
- **[P1] ✖ NOT-DONE** — Refund / chargeback revokes Pro (buy → refund → downgrade to Free)
  - missing: A revoke path: reconcile persisted blob against a shrunken owned-set on restore, clear _proOwned on Play revocation, and a device test proving refunded user loses Pro. Neither the fix nor any test exists.
  - evidence: GW-0164 (confirmed, ≥2-persona): premium_service.dart _proOwned assigned true only (buyPro/applyOwnedProducts/restore/load); the ONLY false assignment is the field initializer L64. purchase_backend_impl.dart _onPurchases has no revoke branch; restore() only ADDS ids. Verified by grep — no downgrade 
- **[P1] 📱 DEVICE-PENDING** — Restore purchases on fresh install — positive re-grant AND negative 'no previous purchase'
  - missing: Device restore against a real Play account that owns / does-not-own the SKU, confirming snacks 'Pro restored ✓' vs 'No previous purchase found.'
  - evidence: Journey 5 (monetization_journey_test.dart) proves restore via FakePurchaseBackend(initiallyOwned:{proOneTime}) and empty-owned negative — headless only. No device/real-store restore ever run.
- **[P1] 📱 DEVICE-PENDING** — Late/pending UPI purchase clears after dialog closes → Pro unlocks via onEntitlementChanged→applyOwnedProducts
  - missing: A real Play sandbox pending→cleared purchase on device proving Pro grants with no manual restore. This is the single highest-risk real-money path and is entirely unverified.
  - evidence: late_purchase_grant_test.dart + Journey uses FakePurchaseBackend.simulateLatePurchase only. Oracle §03.6 E itself labels this 'device-only, hard to reproduce'. No real UPI/net-banking pending flow exercised.
- **[P1] ✖ NOT-DONE** — Real AdMob unit ids wired (AdService.configure called) — banner/interstitial/rewarded
  - missing: Decide remote-config vs build-time id injection and actually call AdService.configure(...) with production ids; today every served ad is a Google TEST ad → zero revenue.
  - evidence: grep 'configure(' across lib/test/integration_test returns only TelemetryService.configureDefaultSinks (main.dart:88); AdService.configure() (ad_service.dart:40) is never invoked. _bannerUnitId/_interstitialUnitId/_rewardedUnitId stay pinned to _testBanner/_testInterstitial/_testRewarded (ca-app-pub
- **[P1] ✖ NOT-DONE** — AndroidManifest AdMob APPLICATION_ID replaced with real app id
  - missing: Replace with the real AdMob app id before shipping; unchanged since the handoff was written.
  - evidence: AndroidManifest.xml:35 android:value still 'ca-app-pub-3940256099942544~3347511713' (Google's TEST app id).
- **[P2] 📱 DEVICE-PENDING** — Free user sees a real banner within ~12s (the historical init-race / 'test ad disappeared on device' bug)
  - missing: Device run confirming banner fill under a slow-init race, plus a reactive re-gate so a mid-screen day-pass expiry/grant updates the slot (GW-0138 unfixed).
  - evidence: gated_banner_ad.dart implements the _maxAttempts=6 / _retryEvery=2s retry as described, but it is only reasoned about — no on-device confirmation that a real banner fills on arming (homescreen.dart:1424) or map (maptracking.dart:1101). GW-0138 (confirmed) additionally notes the widget gives up perma
- **[P2] 📱 DEVICE-PENDING** — NEGATIVE ad policy: NO ad ever on alarm / wake / lock-screen — visually verified on device
  - missing: On-device visual confirmation during a live alarm ring on the lock screen that no ad surface mounts; and a decision on GW-0130 (banner on tracking surface).
  - evidence: ad_policy.dart alwaysForbiddenPlacements {alarm,wake,lockScreen} is exhaustively UNIT-tested (test/monetization/*), but the 'no ad surface mounts during a real ring' claim is never visually verified on device. Related: GW-0130 (confirmed P2) shows a banner IS rendered on the active tracking surface,
- **[P2] ◐ PARTIAL** — Rewarded 'Pro for a day' grant → expiry with reactive UI revert
  - missing: Fix GW-0131 (re-sync tier on resume/timer); play a real rewarded video on device; verify the post-arrival strip eligibility at ridesSinceLastAd>=3.
  - evidence: Grant-then-expire is deterministically proven headless via injected nowMs (premium_gates_wave0_test.dart + Journey 4). BUT GW-0131 (confirmed): _syncTier() runs only on explicit mutations/init — no timer/AppLifecycle.resumed re-sync, so tierListenable stays EntitlementTier.pro after the 24h pass ela
- **[P2] ✖ NOT-DONE** — Business value: real Pro price + Play SKU aligned to proPriceFallback
  - missing: Create the Play SKU, ensure list price matches fallback, and let live price come from queryPrice. Placeholder unchanged.
  - evidence: monetization_service.dart proPriceFallback = '₹199' hardcoded; no Play Console SKU wired. GW-0136 (open) warns the hardcoded price can differ from the amount charged.
- **[P2] ✖ NOT-DONE** — Business value: real Privacy & Terms pages
  - missing: Stand up the actual privacy/terms pages (Play requires a working privacy policy URL to ship a paid/ads app). Unchanged.
  - evidence: paywall_screen.dart:18-19 _kPrivacyUrl='https://geowake.app/privacy', _kTermsUrl='https://geowake.app/terms' — confirmed placeholder pages that do not exist; buttons no-op if unopenable.
- **[P2] 📱 DEVICE-PENDING** — Guardian mode auto-share-on-arm + arrived-via-backend verified on device
  - missing: Device run of auto-share-on-arm and 'arrived safely' push through the live backend; and the backend post-arrival retention fix (GW-0152).
  - evidence: ProGate.run gating for guardian is wired (settingsdrawer.dart:151, guardian_settings_section.dart:43) and guardian_service.dart self-gates; guardian_service_test.dart covers logic. But the arrived-push depends on the Railway backend and is explicitly device-only; GW-0152 (confirmed) shows the backen
- **[P2] 📱 DEVICE-PENDING** — Home-screen widget render/placement + Pro-locked state verified on device
  - missing: On-device placement of the widget, locked-state render when not Pro, one-tap arm, and a11y labels (GW-0166).
  - evidence: Native provider exists and is correctly registered: GeoWakeWidgetProvider.kt (package com.example.geowake2) matches manifest '.GeoWakeWidgetProvider' under namespace com.example.geowake2; ProGate gating at widget_settings_tile.dart:66. But no device placement/render verification, and GW-0166 (per se
- **[P3] ✖ NOT-DONE** — Client-side entitlement cannot be trivially spoofed (store / SSV validation)
  - missing: Server/receipt validation or rewarded SSV. Fail-closed parsing is implemented and unit-tested, but there is zero authenticity check — no fix attempted.
  - evidence: GW-0133 (confirmed): premium_service.dart persists plaintext 'flag;expiry' in SharedPreferences; load() grants permanent Pro for a well-formed '1;0'; rewarded reward accepted client-side with no SSV. A prefs edit on a rooted/emulator device grants permanent free Pro.
- **[P3] ✖ NOT-DONE** — Paywall bullets describe only what Pro actually adds (no free-safety sold as Pro)
  - missing: Reword the bullet to only the paid delta (custom sound files); fix the stale getter comment. Contradicts the paywall's own trust promise and is unfixed.
  - evidence: GW-0132 (open): paywall_screen.dart 'Custom & escalating alarm — ramping volume that won't let you sleep through it' is sold under Pro, but alarm_player.dart G9b volume ramp (0.25→1.0) and alarm_haptics.dart escalation run unconditionally for FREE users. premium_service.dart:226 comment doubles down
- **[P3] ✖ NOT-DONE** — Business value: last-mile affiliate ids for post-arrival ride-hailing CTA
  - missing: Add affiliate/referral ids to the ride-hailing deep links. No id present.
  - evidence: post_arrival_screen.dart _showRideChooser uses generic Rapido/Namma Yatri/Uber/Ola entry URLs with no affiliate ids (per oracle; a revenue line that currently earns nothing).
- **[P3] ✔ DONE** — DROPPED features (Wear OS, Family/shared alarms) are NOT advertised or gated
  - missing: Nothing outstanding for this row (the guard is honored); keep it this way until those ship.
  - evidence: grep confirms no canUseWear/canUseFamily getter; paywall_screen.dart _kItems lists exactly the four working items (Guardian, Custom alarm, Widget, Ad-free). The false-advertising guard holds in the current build.
- **[P3] ◐ PARTIAL** — Ad frequency-cap counter correctness (no double-count; reset after paywall rewarded grant)
  - missing: De-dupe the ride counter, reset the cap on the paywall rewarded grant, and either wire or delete the dead interstitial path. All three unfixed.
  - evidence: Frequency-cap floor (>=3) is unit-tested (Journey 1). GW-0135 (open): a ride is double-counted against the cap (recordRide called from both arrival_hooks.dart:112 and post_arrival_screen.dart:97). GW-0139 (open): markAdShown not called after the paywall's rewarded grant, so the cap isn't reset on th
- **[P3] ✖ NOT-DONE** — Paywall footer layout robust at large text scale
  - missing: Wrap/flex the footer for large accessibility text sizes. Unfixed.
  - evidence: GW-0167 (confirmed, a11y): the paywall footer Row (Restore · Terms Privacy) RenderFlex-overflows at large text scale.

### Accessibility (charter §4 personas + §7.1 a11y oracles + the 'zero Semantics' systemic lead)

_Accessibility is the most cleanly-failed dimension in the whole mandate: the diagnosis is thorough but the delivery is zero. Prior agents CONFIRMED and quantified the systemic lead the charter predicted — grep proves `semanticLabel`=0 and `Semantics(`=0 across all 171 Dart files in lib/, so every icon-only control (10x IconButton, 3x GestureDetector, 2x InkWell, 2x FAB.extended) is invisible to TalkBack and to black-box UI drivers. But that is where it stopped. NOT ONE remediation was made: git log -40 shows zero a11y/semantic/label fix commits; the only labeling mechanism present is `tooltip:` (11 uses, 8 on debug/dashboard panels — the debug surface is ironically better-labeled than production wake/alarm screens). The charter §7.1 automated oracles do not exist: zero `meetsGuideline()` / androidTapTargetGuideline / textContrastGuideline / labeledTapTargetGuideline matchers in test/ or integration_test/ — the CI a11y veto the charter demands was never built. The three device-only mandates — on-device Accessibility Scanner, axe-Android WCAG 2.2, and the explicitly NON-NEGOTIABLE manual TalkBack pass on a real phone — have zero evidence of ever running (axe/scanner appear only in planning docs as mandate text, never as run logs). All 14 a11y findings are tagged `sim/code-read` (static source reads); none is device-proven. Net: the a11y product gap is fully open AND the black-box-testability blocker it causes is fully open. This is both an accessibility failure and a reason the UX-front agentic testing could not drive icon-only controls by label._

- **[P1] ✖ NOT-DONE** — Add semanticLabel/Semantics(identifier:) to icon-only controls + major screens (the core systemic-lead fix)
  - missing: Every production icon-only control is still unlabeled. Nothing was added; the finding was written but no source change followed.
  - evidence: grep lib/ for Semantics(/semanticLabel = 0 hits across 171 dart files (GW-0050 census, independently reproduced). git log -40 grep a11y|semantic|label = 0 commits. Only labeling = tooltip: x11, 8 on debug panels.
- **[P1] ✖ NOT-DONE** — meetsGuideline() a11y matchers wired as deterministic CI-veto oracles (androidTapTargetGuideline 48x48, textContrastGuideline 4.5:1, labeledTapTargetGuideline)
  - missing: No accessibility guideline test exists anywhere. The CI a11y gate the charter requires was never authored; nothing would fail CI on a contrast/tap-target/label regression.
  - evidence: grep test/ integration_test/ for meetsGuideline|TapTargetGuideline|ContrastGuideline|labeledTapTarget|AccessibilityGuideline = 0 hits. The two test/*semantics* files are domain stop-counting logic, not a11y.
- **[P1] 📱 DEVICE-PENDING** — Non-negotiable manual TalkBack pass on the real phone
  - missing: A blind-user walkthrough on hardware of home/tracking/alarm/paywall was never performed. Every TalkBack 'repro' in the findings is a predicted announcement inferred from source, not an observed one.
  - evidence: All 14 a11y findings (GW-0009, GW-0048-0061, GW-0166/0167) tagged sim/code-read; none device-verified. No TalkBack run log in docs/testing/. TESTING_SESSION_LOG has no TalkBack session.
- **[P1] ✖ NOT-DONE** — Label the ringtone preview play/pause button (GW-0048, refines GW-0009)
  - missing: tooltip/semanticLabel reflecting preview + play/pause state; a blind user still cannot audition the alarm tone they depend on.
  - evidence: ringtones_screen.dart:251-258 IconButton still has icon/color/iconSize/onPressed only, no tooltip/semanticLabel (confirmed in RANKED_FINDINGS_REPORT). No fix commit.
- **[P1] ✖ NOT-DONE** — Label + enlarge + wire the low-battery alert button (GW-0049)
  - missing: semanticLabel, a real action callback, and >=48dp target. Currently unlabeled, sub-min-size, AND inert (empty onPressed).
  - evidence: homescreen.dart:1793 _buildAlertButton InkWell over 40x40 Container, Icon only, no semanticLabel, invoked at :1702 with onPressed: (){} empty. No fix.
- **[P1] ✖ NOT-DONE** — Announce alarm arrival to the a11y tree (liveRegion / SemanticsService.announce) — zero live regions app-wide (GW-0051)
  - missing: The arrival/alarm-fired event is still silent to TalkBack; for a screen-reader user the wake depends entirely on the audio ringtone + an unannounced visual banner.
  - evidence: grep lib/ for liveRegion|SemanticsService = 0 matches. maptracking.dart:1289-1302 arrival banner + 'Time to get off.' are plain Text, no announce. No fix.
- **[P2] ✖ NOT-DONE** — On-device Accessibility Scanner run (WCAG 2.2)
  - missing: The Scanner was never run; there is no scan report enumerating tap-target/contrast/label suggestions from an actual rendered app.
  - evidence: grep docs/ for 'Accessibility Scanner' hits only planning docs (Scenario_Matrix, Methodology_Plan, charter). No scan result/export artifact exists.
- **[P2] ✖ NOT-DONE** — axe-Android WCAG 2.2 automated run
  - missing: axe-Android is neither integrated nor executed; no automated WCAG violation report exists.
  - evidence: grep for axe-Android/axe across repo: only mandate text in charter + a testability mention inside GW-0009 evidence. No axe config, dependency, or output.
- **[P2] ✖ NOT-DONE** — Native home-screen widget accessibility — CTA/progress/card contentDescription (GW-0166)
  - missing: android:contentDescription on container/CTA and a spoken progress value; the one-tap arm affordance is unreachable by screen reader.
  - evidence: grep android/app/src/main/res/ for contentDescription = 0 hits. geowake_widget.xml CTA is a plain TextView with click intent, no role/label, ProgressBar no value text. No fix.
- **[P2] ✖ NOT-DONE** — Label the wake-threshold value editor and the Time/Distance + Metro-Mode switches (GW-0052, GW-0054)
  - missing: Semantics(button:)/MergeSemantics/SwitchListTile so the timing controls announce purpose + current value. Blind users cannot discover or set how early they are woken.
  - evidence: homescreen.dart:1598 bare GestureDetector wrapping Text (unlabeled); :1589 and :1409 bare Switch() with detached Text siblings. Semantics/MergeSemantics count = 0. No fix.
- **[P2] ✖ NOT-DONE** — TalkBack traversal-order management + decorative-icon ExcludeSemantics + status-change announcements (GW-0056, GW-0060, GW-0061)
  - missing: Explicit traversal order on the alarm-dismiss row, ExcludeSemantics on decorative icons, and announced GPS-degraded/dead-reckoning transitions — none exist; traversal is incidental to build order app-wide.
  - evidence: grep lib/ for sortKey/FocusTraversalOrder/OrdinalSortKey/ExcludeSemantics/MergeSemantics = 0. GPS-degraded/ETA states are plain Text, no liveRegion. No fix.
- **[P3] ✖ NOT-DONE** — Text-scaling verification on fixed-fontSize alarm/paywall controls (GW-0058, GW-0167)
  - missing: Golden/widget tests at 1.3x-2.0x text scale (charter §7.1 Alchemist goldens across scale) proving the dismiss and legal/restore rows do not RenderFlex-overflow or clip.
  - evidence: No textScaler clamp (fine) but SNOOZE/END TRACKING fontSize:16 in Expanded Row (maptracking.dart:1322) and paywall footer 3-TextButton Row (paywall_screen.dart:171-179) unverified at 1.5-2.0x. No Alchemist/golden scale test in test/. No fix.
- **[P3] ✖ NOT-DONE** — Light-mode input hint/prefix contrast (black54 on grey200 ~4.4:1) fix (GW-0057)
  - missing: Darken hint/prefix to >=4.5:1 and add a textContrastGuideline matcher so contrast regressions fail CI.
  - evidence: appthemes.dart:18-20 lightTheme still fillColor grey[200] + hintStyle black54 (~4.40:1, under AA floor). No textContrastGuideline test to catch it. No fix.

### Unknown-unknowns safety net: scenarios/features/invariants the oracle (AGENT_HANDOFF_E2E.md), FEATURES_SPEC.md, and WakePoint_Scenario_Matrix.md explicitly list that have NO corresponding ISSUES.jsonl finding, test, or verification anywhere.

_The narrow lenses (UX micro-interactions, never-late math, security, monetization logic) are well covered, but this cross-cutting sweep exposes three whole classes of un-addressed scope. (1) The Scenario Matrix's named adversarial edge cases E1–E9 and its four "fidelity gate" inputs (track gradient, vibration-chirp spectrum, background-throttle rate loss, reference-σ propagation) have essentially zero targeted test coverage — only E10 (express skip-stop) has a fixture. The scale corpus is ~15 routes across 4 blackout archetypes, not the stratified ≥200-avg + ≥50-per-edge + per-device-bin corpus the matrix mandates, so the "per-device robustness" and "P99 catastrophic-miss" numbers the matrix promises simply do not exist. (2) Every non-reliability device flow in the oracle (share live-follow loop, Guardian arrived-in-background-isolate, widget placement/one-tap arm, deep-link geowake://arm/stop/open dispatch, DPDP consent, billing, ringtone real-alarm test, ETA accuracy, cross-state interstate arming) is unit-tested only — the entire "device column" is unverified, and several (widget arm dispatch, cross-state arming, snooze 60s re-alert) have no test at ANY level. (3) FEATURES_SPEC.md still fully specifies a Pro tier (recurring auto-arm, multi-alarm, smart-snooze, trip-stats, saved-routes screen, offline packs, onboarding) that grep proves was never built and the oracle silently reclassified as dropped/N-A — a live documentation divergence with reviewer-flagged never-late risks that are moot only because the code doesn't exist. The physics-math core is genuinely proven in CI; almost nothing else is proven anywhere but the unit layer._

- **[P1] ✖ NOT-DONE** — E1 'Worst-timed blackout' — a GPS gap that ENDS exactly at target-stop arrival (max accumulated drift at the decision moment). This is the single worst adversarial timing and the matrix's #1 named case.
  - missing: A replay/scale fixture whose blackout window is adversarially aligned to end at the target stop, asserted fire<=arrival.
  - evidence: test/fixtures/scale/ has only coldstart_underground / long_blind / express_skip_long_blind / noblackout archetypes; grep 'worst.timed'/'endAtTarget' in test/ + fixtures = 0 hits. long_blind is not constructed to terminate at the target.
- **[P1] ✖ NOT-DONE** — E2 'Interchange in the dark' — transfer station inside a GPS blackout (snap-to-wrong-line, stop-count off across transfer).
  - missing: Multi-leg fixture with the blackout positioned over the interchange, asserting only the intended per-leg alarms and correct cross-transfer stop count.
  - evidence: grep 'interchange in the dark' test/ = 0; no scale fixture combines a transfer leg with a blackout spanning the interchange (transfer logic tested only on-surface in transfer_utils_test.dart).
- **[P1] ✖ NOT-DONE** — E3 'Twin close stops underground' — two stations <500 m apart with no GPS; station-snap picks the wrong one → off-by-one wake. Directly threatens never-late (mis-snap can under-count).
  - missing: Fixture with two sub-500m adjacent underground stations proving the monotonic single-candidate snap does not fire one stop early/late.
  - evidence: grep 'twin close'/'close stop' test/ = 0. station_association snap gating is code-asserted (ekf_orchestrator) but no fixture exercises the <500m-underground ambiguity the matrix calls out.
- **[P1] ✖ NOT-DONE** — E4 'Missed ZUPT at critical stop' and E5 'False ZUPT while moving' (slow creep-to-halt) — the two ZUPT failure modes that cause unbounded drift or frozen position right at the decision point.
  - missing: Two adversarial IMU fixtures (short-dwell/jostled target; slow creep) asserting the physics floor still catches the stop when ZUPT misbehaves.
  - evidence: grep 'missed ZUPT'/'false ZUPT'/'creep' test/ = 0. ZUPT logic has code (zupt_detector.dart) and the replay harness runs recorded corpora, but no fixture is constructed to force a missed-ZUPT-at-target or a false-ZUPT-during-creep.
- **[P1] ✖ NOT-DONE** — Fidelity-gate inputs: (J) track gradient at tunnel entry/exit, vibration-chirp spectral fidelity for the MotionClassifier FFT, (K) background-throttle rate loss (screen-off 10 Hz), and reference-σ propagation in scoring.
  - missing: Synthesizer/test coverage validating gradient-leak rejection, chirp-matched FFT classification, decimated screen-off rates, and reference-σ-aware scoring before any accuracy number is trusted.
  - evidence: grep 'gradient'/'vibration chirp'/'doze.batch'/'domain random' test/ = 0; 'throttle' hits 2 unrelated files. The matrix explicitly warns '100 Hz results are optimistic' and gradient is 'the untested underground input' — neither is gated.
- **[P1] ◐ PARTIAL** — Deep-link ACTION matrix geowake://arm | stop | open(?paywall=1) — parse is tested, but the actions are not wired into the app's deep-link dispatcher and are unverified end-to-end.
  - missing: End-to-end wiring + test that a geowake://arm intent (and stop/open) actually reaches _consumeWidgetArm and arms, and confirmation the custom-scheme action intents are registered.
  - evidence: main.dart _initShareDeepLinks/_handleShareLink routes ONLY /j/{id} share links; grep shows no arm/stop/open dispatch in main.dart. WidgetArmRequest.parse is unit-tested (test/widget/home_widget_test.dart) but no test drives parse→pending→_consumeWidgetArm→startTracking, and the geowake://arm/stop/op
- **[P2] ✖ NOT-DONE** — E6 'Bag-carry tilt divergence' and E7 'Carry-mode change mid-blackout' — tilt-estimate error leaks gravity into the forward axis (constant bias) and carry-mode transitions are transients the TiltFilter can't track underground.
  - missing: IMU fixtures with high sustained tilt and an in-hand→pocket transition during the GPS gap, asserting bounded forward-axis bias / safe fire.
  - evidence: grep 'bag.carry'/'carry.mode'/'tilt diverg' test/ = 0. tilt_filter.dart exists but no fixture varies carry mode or injects sustained tilt during a blackout.
- **[P2] ✖ NOT-DONE** — E8 'Budget phone + long tunnel' + the whole domain-randomization / per-device robustness sweep (axis G sample-rate & bias bins).
  - missing: Domain-randomized corpus over phone-quality/sample-rate bins and the sliced robustness table the matrix promises as a product metric.
  - evidence: grep 'budget phone'/'domain random' test/ = 0. Scale corpus fixtures carry no device-quality/sample-rate axis; there is no per-device-bin metric table anywhere.
- **[P2] ✖ NOT-DONE** — E9 'Cold-reacquire overshoot' — tunnel-exit GPS glitch (large innovation): does the robust gate reject a good fix or accept a bad one.
  - missing: Replay fixture with a large-innovation fix at blackout exit, asserting correct accept/reject and no position jump that shifts the fire point.
  - evidence: grep 'cold.reacquire' test/ = 0 (only one incidental 'reacquire' hit). Frozen-phantom rejection is coded in ekf_orchestrator.onGpsFixAuto but no fixture injects a tunnel-exit innovation spike.
- **[P2] 📱 DEVICE-PENDING** — Share/Guardian LIVE-follow loop end-to-end on device (arm→share→backend register→follow→ETA updates→arrived flip→410 expiry), and Guardian 'arrived' when the wake fires in a DEAD isolate.
  - missing: A device/emulator run of the live loop against the Railway backend, plus explicit verification of arrived-delivery after am force-stop.
  - evidence: test/share/* and test/tracking/post_alarm_multicast_test.dart are unit-only; integration_test/ contains only alarm-chain/doze/device-alarm reliability tests — zero share/guardian on-device coverage. Oracle itself flags the background-isolate arrived path as unverified.
- **[P2] 📱 DEVICE-PENDING** — Home-widget placement + one-tap arm on a real home screen (the oracle's own top open item for the widget being a legitimate paid feature).
  - missing: Device placement/tap verification and a decision on the orphaned enable/disable tile before charging for it.
  - evidence: Native files exist (GeoWakeWidgetProvider.kt, res/layout|xml, geowake_widget_* drawables in git status). Unit tests cover render-state precedence + evaluate truth table only. No device verification; oracle §01.6 also notes WidgetSettingsTile is orphaned (no in-app enable/disable UI).
- **[P2] ✖ NOT-DONE** — Cross-state / interstate overnight arming (the 'flagship overnight interstate use case', e.g. Delhi→Jaipur arms anyway; same-state validation is advisory-only).
  - missing: A test asserting cross-state route arming succeeds (advisory-only), protecting the flagship use case from a future hard-block regression.
  - evidence: Logic lives in homescreen.dart but grep for cross-state/interstate/Jaipur across test/ = 0; 0 ISSUES.jsonl hits for 'cross-state'/'interstate'. No test asserts a cross-state route is not hard-blocked.
- **[P2] ✖ NOT-DONE** — Snooze one-shot 60s re-alert (arrival SNOOZE silences, keeps tracking, re-fires the real alarm after 60s if still onboard, then button vanishes).
  - missing: A widget/logic test for the snooze→silence→60s re-arm→re-fire path and the one-shot button removal.
  - evidence: grep 'maybeReAlert'/'reAlert'/'snoozeUsed' in test/ returns only unrelated files (replay_harness, followed_rides). No dedicated test of the 60s re-alert or the one-time button lifecycle.
- **[P2] ◐ PARTIAL** — DPDP consent flow: legal placeholders (Grievance Officer + Data Protection Board contacts) still shipped, and no device/DPIA verification of the consent+withdrawal+erasure flow.
  - missing: Real DPB/grievance contacts, DPIA sign-off, and device verification of the consent UI + erasure record before egress could ever be considered.
  - evidence: Unit coverage exists (test/data_asset/consent_test.dart, pipeline_hive_test.dart withdrawal-erasure). But mobility_consent_copy.dart contacts remain placeholder strings (oracle §05.5), no DPIA, and no device run of the 18+-gate→grant→withdraw→erasure UI.
- **[P2] ✖ NOT-DONE** — Telemetry from the TRACKING (background) isolate — the FGS-OS-kill reliability funnel, the single most important reliability measurement, is exactly the case most likely NOT recorded.
  - missing: Route background-isolate errors/outcomes into the durable FileTelemetrySink (or the UI-isolate bridge) so FGS-kill events are actually captured, plus a test.
  - evidence: Crash hooks + funnels run in the main isolate (main.dart:53-62,137); the tracking FGS runs in its own isolate with separate error handlers and in-memory sink. Oracle flags wiring the tracking isolate's errors/flush into the durable sink as open work. No test bridges isolate errors.
- **[P2] ✖ NOT-DONE** — Deleted multi-target scale coverage — test/scale/multi_target_scale_test.dart is deleted in the working tree, removing never-late-at-scale coverage for multiple simultaneous wake targets.
  - missing: Restore or rewrite the multi-target scale test (or formally accept that multi-target is out of scope, since the feature itself is unbuilt — see divergence item).
  - evidence: git status shows 'D test/scale/multi_target_scale_test.dart'; only reachability_scale_test.dart remains under test/scale/. Oracle explicitly says it 'must be restored/rewritten' if multi-target coverage is wanted.
- **[P2] ✖ NOT-DONE** — FEATURES_SPEC Pro tier vs oracle divergence: recurring auto-arm, multiple simultaneous alarms (AlarmTarget), smart snooze, escalation sound profiles, trip-stats + ShareStatCard, SavedRoutesScreen, offline all-cities pack, and OnboardingScreen are fully specified (with reviewer-flagged never-late risks) but were NEVER built; the oracle silently reclassifies them N/A/dropped.
  - missing: Reconcile the two mandate docs: either mark FEATURES_SPEC sections as superseded/dropped, or build+test them. As-is, FEATURES_SPEC advertises a Pro tier that does not exist.
  - evidence: grep in lib/ found NO files for onboarding, scheduling/auto_arm*, tracking/alarm_target*, alarm/smart_snooze*, alarm/alarm_sound_profile*, stats/trip_record*/trip_stats*, offline_maps, or savedRoutes screen; grep 'onboard' lib/ = 0. saved_routes_service.dart exists but no screen.
- **[P3] 📱 DEVICE-PENDING** — Ringtones 'Test my alarm now' firing the REAL production alarm (showWakeUpAlarm, playSound, 5s auto-stop) — the only in-app way a user triggers the actual wake surface.
  - missing: Device verification that the test-alarm fires sound+vibration+full-screen and auto-stops, and cancels on screen-leave.
  - evidence: No widget/integration test drives RingtonesScreen's FAB; grep for ringtone tests shows only share/link-builder incidental hits. Real full-screen-alarm behavior is device-only anyway.
- **[P3] ? UNVERIFIED** — ETA / 'N min away' accuracy — never-late (fire<=arrival) is proven, but the ACCURACY of the displayed ETA and follower 'N min away' is measured nowhere.
  - missing: An ETA-error metric over the replay corpus (displayed ETA vs actual arrival) to substantiate the UX 'arriving ~h:mm' claim.
  - evidence: grep 'eta.accuracy'/'ETA accuracy' test/ = 0. eta_engine_test.dart covers mechanics, not closeness-to-truth. No error-vs-truth metric exists.
- **[P3] ✖ NOT-DONE** — FEATURES_SPEC reviewer-flagged never-late BREAKS for the unbuilt Pro features have no regression tests guarding them if/when the features are ever built (auto-arm active-session stomp; multi-alarm id-collision re-keying the destination fired-flag; smart-snooze late-refire from wrong deadline quantity; trip-stats background-isolate undercount/corruption).
  - missing: If these features are revived, the four required-fix regression tests must land first; if dropped, remove the specs so the risks are not silently inherited later.
  - evidence: The named files do not exist (verified by grep above), so the mandated load-bearing tests (collision case still wakes destination; snooze deadline == reachability inversion; background-isolate enqueues exactly one record; startTracking refuse-when-active) also do not exist.
- **[P3] ◐ PARTIAL** — Post-arrival last-mile ride-hailing/affiliate CTA matrix (Rapido/Namma Yatri/Uber/Ola entry URLs; food/directions Maps deep-links) — the per-user revenue lever's URL matrix is unverified.
  - missing: A test over the ride/food/directions URL builders and device verification each opens the intended external target.
  - evidence: test/monetization/post_arrival_decision_test.dart covers the decision to show, not the launched provider URLs. Affiliate ids are placeholders (oracle §03.7). No test asserts each provider opens the correct external URL.
- **[P3] 📱 DEVICE-PENDING** — iOS backstop (local notification at now+remaining/V_LINE + two geofence rings) has unit tests but zero device proof; no iOS device is in scope, so the entire iOS wake path is unverified.
  - missing: iOS device verification of the pre-scheduled notification + geofence-ring wake, or an explicit 'iOS unverified' ship gate.
  - evidence: test/ios/ios_backstop_planner_test.dart + edgecases are unit-only; integration_test/ is Android-only (adb ZN5225DML5). No iOS geofence-wake verification exists.

### Meta-mandate / process compliance & repo hygiene

_Process compliance is the weakest dimension of the whole effort. The single most dangerous fact: NOTHING from this session (Jul 20) is committed — git log --since="2026-07-20" is empty, and the entire testing corpus (docs/testing/ with 174 findings, the ranked report, session log, fix designs), the charter + sealed-oracle docs themselves, 34 modified tracked source/test files carrying the never-late fixes, ~20 new untracked source and test files, and 2 new on-device integration tests are ALL uncommitted with no protective stash. A single `git checkout`/`git clean` would erase multi-session work. SYSTEM_MAP.md + docs/system_map/* were NOT regenerated — every file is frozen at Jul 15 22:xx while HEAD is Jul 19 and heavy work landed Jul 20; the prior handoff's "not regenerated" flag is still true (the Jul 18 commit merely first-committed the stale Jul 15 files). Charter §7.1's enableFlutterDriverExtension() black-box drivability gate was never implemented — it exists only as a TODO sentence in the charter. The docs are internally inconsistent: RANKED_FINDINGS_REPORT claims "145 findings" but ISSUES.jsonl holds 174 unique ids, so GW-0146..GW-0172 are unranked. The deleted test/scale/multi_target_scale_test.dart is still gone (staged deletion). The one bright spot: the auto-memory index (MEMORY.md) IS freshly updated (Jul 20 18:21) with a new residuals memory file. Verdict: substantial engineering done, near-zero durability/traceability guarantees._

- **[P0] ✖ NOT-DONE** — Commit the session's work — the entire multi-session effort (174 findings, never-late fixes, new tests, integration tests) is UNCOMMITTED and one `git clean`/`checkout` from deletion
  - missing: A commit (or at minimum a stash/branch) capturing all Jul 20 modifications; nothing protects the never-late fixes or the 174-finding corpus from loss.
  - evidence: `git log --since="2026-07-20 00:00"` returns empty (zero commits today; HEAD=9064b0e is Jul 19 05:57). `git status --porcelain` = 63 entries: 34 ' M' modified tracked (reachability.dart, trackingservice.dart, alarm_controller.dart, notification_updater.dart, main.dart, monetization + share services,
- **[P0] ✖ NOT-DONE** — docs/testing/ (ISSUES.jsonl 174 findings, RANKED_FINDINGS_REPORT, TESTING_SESSION_LOG, NEVERLATE_FIX_DESIGNS) is entirely UNTRACKED by git
  - missing: git add + commit of docs/testing/; the primary work-product of the whole mandate is untracked.
  - evidence: `git ls-files docs/testing/` returns nothing; `git log -- docs/testing/` empty. Files exist on disk (ISSUES.jsonl 241KB, updated Jul 20 19:24) but git has never seen them.
- **[P0] ✖ NOT-DONE** — The mandate documents themselves (docs/AGENT_TESTING_CHARTER.md, docs/AGENT_HANDOFF_E2E.md sealed oracle, docs/HANDOFF_TESTING.md) are UNTRACKED
  - missing: Commit the charter and sealed oracle so the spec cannot silently drift or be lost.
  - evidence: `git ls-files docs/AGENT_TESTING_CHARTER.md docs/AGENT_HANDOFF_E2E.md docs/HANDOFF_TESTING.md` returns nothing. All three show as '??' in git status.
- **[P1] ✖ NOT-DONE** — SYSTEM_MAP.md + docs/system_map/*.md NOT regenerated this session — stale vs HEAD and vs Jul 20 work
  - missing: Regenerate the system map against current code (share/telemetry/data-asset/widget modules and never-late fixes added since Jul 15 are unrepresented).
  - evidence: SYSTEM_MAP.md mtime Jul 15 22:41; all 18 docs/system_map/*.md files mtime Jul 15 22:15-22:23. HEAD is Jul 19; heavy work (ISSUES.jsonl, integration tests, new lib/ sources) landed Jul 20. The only commit touching them (faf539c, Jul 18) added SYSTEM_MAP.md as a 196-line full-file first-commit of the 
- **[P1] ✖ NOT-DONE** — Charter §7.1 enableFlutterDriverExtension() gate for black-box drivability — never implemented
  - missing: Add the gated enableFlutterDriverExtension() call in the app entrypoint (behind --dart-define) plus the Semantics identifiers that unblock black-box drivers.
  - evidence: `grep -rn enableFlutterDriverExtension .` hits ONLY the charter TODO sentence (line 120); zero occurrences in any .dart source. test_driver/integration_test.dart uses integrationDriver() (standard integration_test harness) but the app-side driver-extension gate behind a --dart-define is absent.
- **[P1] ◐ PARTIAL** — Doc internal inconsistency: RANKED_FINDINGS_REPORT says 145 findings, ISSUES.jsonl has 174
  - missing: Regenerate/reconcile the ranked report to cover all 174 findings; the newest 29 (including a P2 security/privacy item) are unranked and could be missed.
  - evidence: RANKED_FINDINGS_REPORT.md:17 'Severity histogram (145 findings)'; `wc -l ISSUES.jsonl` = 174, and 174 unique "id" values (GW-0001..GW-0172 + extras). ISSUES.jsonl mtime Jul 20 19:24 is AFTER RANKED_FINDINGS_REPORT.md mtime Jul 20 16:23 — the ranked report predates the last ~29 findings (GW-0146..GW-
- **[P2] ✖ NOT-DONE** — Deleted test/scale/multi_target_scale_test.dart NOT restored (oracle §4 note)
  - missing: Either restore the multi-target scale test or document/commit a justification; currently it is silently staged for removal.
  - evidence: `git status` shows 'D  test/scale/multi_target_scale_test.dart' (staged deletion). ls test/scale/ shows only reachability_scale_test.dart remains. File is gone, deletion staged for the (uncommitted) session.
- **[P3] ✔ DONE** — Auto-memory index refreshed (the one hygiene item that IS current)
  - missing: Nothing — note this is the auto-memory (~/.claude .../memory/) index, distinct from the SYSTEM_MAP/codebase-memory-MCP graph, which is stale.
  - evidence: MEMORY.md mtime Jul 20 18:21; new memory file neverlate-residuals-2026-07-20.md (Jul 20 18:20) added. Index reflects current session state.
- **[P3] ◐ PARTIAL** — Branch/worktree sprawl — 9 worktree-wf_* branches plus a separate .wake/ self-updating map on another branch; work fragmented across refs
  - missing: Consolidate/prune stale worktree branches; reconcile the two competing repo-map systems (docs/system_map on this branch vs .wake/ on stable-release-1).
  - evidence: `git branch -v`: 9 worktree-wf_7a4c86c3-cd0-* branches at e387512/bf09030, android-reliability-hardening, backup/pre-cleanup-20260709, and stable-release-1 (ahead 1 with a .wake/ repo-intelligence-map commit ee20326 not on sim-validation). Session work sits on sim-validation while a competing repo-m

### completeness-critic

_Seven mandate dimensions fell BETWEEN the 11 audit lenses and are still invisible. The deepest is that the whole L0 sim oracle — the "charter-blessed truth" the reliability audit and everyone else leans on — was never itself audited for FIDELITY: docs/WakePoint_Fidelity_Checklist.md and WakePoint_Scenario_Matrix.md document unclosed fidelity gates (multipath, post-tunnel reacquisition, curve cant, non-metro legs, gyro g-sensitivity all "queued"/"deferred") and META item #13 concedes every distribution is "calibrated to n=1" real ride, so "never-late proven in sim" rests on a synthesizer with known holes and single-ride extrapolation. Next: iOS is a shipping platform (test/ios/ios_backstop_*) with ZERO coverage in any of the 11 Android-only lenses. The data-business surface (DATA_SURFACE_SPEC.md, data_business/STRATEGY.md) — a stated product/revenue surface with a P0 no-raw-egress guardrail — was audited by nobody; its guardrails are implemented and unit-tested but the egress-path/DPDP-consent were never dynamically verified (same Tier-3 gap the toolchain audit noted, but for a dimension no one owned). The backend share service (backend/share/server.js) was only touched by the red-teamer for two authz exploits; its privacy contract (GW-0152: last coord persists post-"arrived" until TTL — confirmed in server.js) and its Node test suite were never assessed as a dimension. The deviation/reroute engine (dozens of tests: deviation_*, reroute_*, dashboard/*) appears in ZERO oracle sections and no audit — a never-late-relevant mid-ride behavior that is both unspecced and unaudited. The new native Home-widget (GeoWakeWidgetProvider.kt) is advertised as a Pro feature but has no native test and its one-tap-arm uses geowake://arm which the reliability audit says is "deliberately foreground-only" — likely broken from a locked widget tap. Finally, an over-generosity pattern: only the reliability audit carried the READ-ONLY caveat that test-existence ≠ passing; the screens/monetization/toolchain audits assert unit tests "cover" behaviors as established fact without ever observing them green._

- **[P0] ◐ PARTIAL** — Sim-fidelity of the L0 oracle itself was never audited — the foundation everyone treats as 'truth' has documented open fidelity gates and is extrapolated from n=1 real ride. The reliability audit audited whether the never-late MATH holds in sim; no one audited whether the SIM resembles reality.
  - missing: An explicit fidelity audit stating which never-late scenarios are backed by a validated synthesizer vs which extrapolate past the single real ride; close (or scope-flag) the queued/deferred fidelity gates before the '0 violations in sim' claim can be treated as reality-grade rather than model-internal.
  - evidence: Fidelity_Checklist status table: items 6 (GPS multipath), 8 (post-tunnel reacquisition transient), 4 (curve cant/superelevation), 7 (cross-axis non-Gaussian noise), 10 (non-metro escalator/stair legs) = 'queued'; items 5 (gyro g-sensitivity), 9 (temperature bias) = 'deferred'; item 13 META: 'everyth
- **[P1] 📱 DEVICE-PENDING** — iOS platform reliability — ZERO coverage in all 11 lenses. The app ships iOS (test/ios/ios_backstop_planner_test.dart, ios_backstop_edgecases_test.dart) but every audit is Android-only (Doze/OEM/BOOT_COMPLETED/exact-alarm). iOS has no exact alarms, no full-screen intent, no BOOT re-arm — a structurally different never-late model that is unit-tested only and never device/simulator-driven or audited.
  - missing: An iOS reliability dimension: does the wake fire under iOS background suspension / low-power mode / after force-quit, given no exact-alarm equivalent? Never-late on iOS is entirely unproven and was scoped by no auditor.
  - evidence: test/ios/ios_backstop_*.dart exist (unit only); grep of charter/oracle for iOS shows only passing mentions, no iOS L1/L2 matrix, no iOS simulator in the emulator-matrix audit (Android AVDs only), no iOS device; integration_test/ is Android-only (*_ondevice with adb/Doze).
- **[P1] ◐ PARTIAL** — Data-business / data-surface dimension (DATA_SURFACE_SPEC.md, docs/data_business/STRATEGY.md) — a stated product+revenue surface with a P0 'no raw-coordinate egress' guardrail — was audited by NONE of the 11. The consent SCREEN got a UI row in oracle §01.10, but the k-anon/DP/egress-gate/DPDP-consent pipeline as a coverage dimension fell through.
  - missing: A data-surface audit: dynamic proof the pipeline emits zero coordinates, DPDP consent default-OFF/withdraw device-verified, and the ReleasedCell-only egress contract exercised. Guardrails look sound in code but are unaudited and unverified at runtime.
  - evidence: DataAssetPipeline.instance.init() IS wired (main.dart:110); egress is doubly-OFF (kDataAssetEgressEnabled=false + NullEgressSink, pipeline comment lines 19-20); unit tests exist (dp_and_kanon_test, k_anonymity, station_binner, http_egress_sink, consent_test). But the doubly-off egress guardrail and 
- **[P1] ◐ PARTIAL** — Backend share service (backend/share/server.js + server.test.js) as a coverage dimension — only the red-teamer touched it (GW-0087/0088 authz, vs a LOCAL instance). Its privacy CONTRACT and Node test suite were assessed by no one. GW-0152 (last coordinate persists in the record after 'arrived' until TTL) is confirmed in the code and owned by no dimension.
  - missing: A backend dimension: test-suite coverage assessment, privacy-contract verification (purge coord on arrival, not just TTL), and dynamic checks against the DEPLOYED Railway instance rather than a local server.
  - evidence: server.js sets rec.arrived=true/arrivedAtMs (lines 165-166) but only TTL-sweep or explicit DELETE hard-deletes (lines 145,171,181) — the last stored coord survives post-arrival until expiry, matching GW-0152. server.test.js exists (Node) but no auditor reported its coverage, the deployed Railway ins
- **[P2] ? UNVERIFIED** — Deviation / reroute engine — a large implemented+tested subsystem (deviation_*, reroute_*, dashboard/* — ~30 test files) that appears in ZERO oracle sections and was scoped by no audit. Mid-ride reroute is never-late-relevant (a wrong reroute can drop the target or fire spurious alarms) yet is both unspecced in the sealed oracle and unaudited.
  - missing: Either the oracle is incomplete (reroute behavior unspecced) or the feature is out of the audited scope — either way the never-late-under-reroute invariant and spurious-alarm-on-reroute risk are unaudited in sim AND device.
  - evidence: grep reroute|deviation in AGENT_HANDOFF_E2E.md = 0 hits (not in the sealed oracle at all); test files exist (deviation_detection_integration_test, reroute_chain_integration_test, reroute_policy_continuity_test, dashboard/deviation_*), but no auditor mapped them to a mandate or judged coverage. Green
- **[P2] ✖ NOT-DONE** — Native Home-screen widget (android/.../GeoWakeWidgetProvider.kt, new/untracked) — advertised as a Pro feature ('Home widget — one-tap arm') but has NO native test and its one-tap-arm deep-link is geowake://arm, which the reliability audit states is 'deliberately foreground-only' — so tapping the widget from a locked/backgrounded home screen likely cannot actually arm. This paid-feature contradiction was flagged by no auditor.
  - missing: Proof the advertised one-tap-arm actually arms from the widget (deep-link foreground-only likely breaks it), plus any test of the native provider's render/tap. A Pro feature is being sold on unverified/likely-broken behavior.
  - evidence: GeoWakeWidgetProvider.kt + manifest APPWIDGET registration exist; no android/app/src/test dir, no Kotlin test. widget_field_contract_test.dart:70 confirms 'the idle card carries an arm deep-link' = geowake://arm, but the reliability/screens audits note geowake://arm is foreground-only and the emulat
- **[P2] ? UNVERIFIED** — OVER-GENEROSITY PATTERN across audits: only the reliability audit carried the READ-ONLY caveat that test-existence ≠ passing ('63/63 claimed in prose, not re-observed'). The screens (§01), monetization (§03), and toolchain audits repeatedly assert unit tests 'cover'/'prove' behaviors as established fact without ever observing a green run — inheriting the same unverified-green risk but not disclosing it.
  - missing: A single CI/local green run (or the reliability audit's explicit 'unverified' caveat) applied uniformly. As stated, several 'done'/'partial' headless statuses across audits rest on file-existence, not observed passing results.
  - evidence: Reliability audit item explicitly marks the sim pass 'unverified'. By contrast the monetization audit states entitlement paths are 'covered by test/monetization/*.dart' and the screens audit says PostArrival 'renders … asserts' — all as fact; none re-ran flutter test (READ-ONLY). The 'headless-teste