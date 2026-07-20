# GeoWake — Autonomous Testing Charter

> **You are the testing agent. This is a mandate, not a manual.**
> The app under test is a **black box**. Assume nothing. Discover every screen, flow, setting, background behavior, and failure mode *yourself*, from a cold install, the way a user (and an attacker) would. Your job is not to confirm what someone told you works — it's to find what's wrong, what's missing, what feels off, and what breaks the one promise this product makes. Test it across three fronts — **user-end UI/UX**, **core background engineering**, and **security** — exhaustively, with adversarial rigor, and **log every issue you find.**
>
> There is a detailed spec of how the app *supposedly* behaves at `docs/AGENT_HANDOFF_E2E.md`. **It is SEALED.** Do not open it until you have formed your own independent findings — then use it only to measure what you missed and to catch places where the docs lie about reality. The docs are a suspect, not a source of truth.

---

## 0. Prime directives (non-negotiable — these bound everything)

1. **Fire in the right WINDOW — never late, but never egregiously early either.** The promise: wake the rider *just before* their stop, even when GPS dies underground. **A late fire is catastrophic** (they miss the stop). **A wildly-early fire is also a deal-breaker** — firing 5 stops early defeats the alarm and makes people uninstall. The objective is a TIGHT two-sided window: `0 ≤ lead ≤ a small tolerance`. On EVERY replay, measure BOTH: the never-late floor (`lead ≥ 0`) AND the earliness distribution (median / p95 / max lead, and how many stops early). A reproducible **late** fire is **P0-never-late** and stops the world; a systematically **too-early** fire is **P0-too-early** and is a first-class finding, not a footnote. Hunt both edges.
2. **Never claim device proof from simulation.** Tag every finding **`sim`**, **`emulator`**, or **`real-device`**. The never-late math is CI-proven in simulation; it has *never* been confirmed on a real underground ride. Closing that gap is your #1 objective.
3. **Do not weaken the guardrails.** Never gate the core alarm; no ads on alarm/wake/lock surfaces; raw individual location must never leave the device (only k-anon + DP aggregates — today, nothing leaves at all). If you find a violation, that's a P0.
4. **The runtime package is `com.geowake.app`** (the source namespace `com.example.geowake2` is different — many tools/docs will show the wrong one; always target `com.geowake.app` in adb).
5. **Maximize determinism.** Real devices are scarce, slow, and non-reproducible; the deterministic sim + emulator harness (§5 L0/L1, §7) is your PRIMARY confidence source — push it to cover as close to 100% of the product as physically possible, including the two-sided timing window. Reserve real hardware only for what genuinely cannot be simulated (deep Doze / OEM battery-kill / exact-alarm delivery / boot re-arm / full-screen-intent over lock). For each such behavior, FIRST deep-research that the approach is sound against *today's* Android + Play + OEM reality (see `docs/research/real_device_reliability.md` once written), THEN confirm on hardware.
6. **Operating context — full autonomy, no restrictions.** This is PRIVATE testing on the founder's own system with throwaway/rotated keys. You have full system permissions and may install and use ANY tool, SDK, emulator, model, dependency, or API key you need — there are no restrictions. Automate aggressively for exhaustive, unattended overnight coverage; do not wait for approvals.

---

## 1. Method: adversarial discovery, not checklist-following

Run testing as a **fleet of independent adversarial personas** (spawn them as deep workflows), each of which **discovers the app from a cold, wiped install with no briefing** beyond a one-line role card, explores independently, and logs issues to one shared schema (§7). Then **cross-verify** — a finding survives only with ≥2-persona consensus *or* a deterministic oracle confirming it. Personas are the creativity/coverage multiplier; the **oracles (§6) are the truth** — never let a persona's opinion override a metamorphic never-late test.

This is grounded in current (2025–26) research: multi-agent heuristic-eval / cognitive-walkthrough committees hit ~92–100% issue coverage vs ~78% single-agent. Use it.

### The persona roster (each gets its own `adb shell pm clear com.geowake.app` state)
- **First-Time User** — cognitive walkthrough of the primary task (set a wake alarm for a stop → arm → sleep). At every step ask the 4 CW questions (will they try this? notice the control? associate it with the effect? see progress feedback?). Log every hesitation.
- **Power User** — recurring commuter; recents, transfers, sharing, widget, re-arm. Find friction on the 10th use.
- **The Critic** — hostile design reviewer against Nielsen's 10 heuristics; nitpick copy, hierarchy, affordances, empty/error states.
- **The Skeptic** — disbelieves the never-late claim; tries to make it fire late or not at all (see Front B).
- **The Red-Teamer** — abuse, injection, permission denial, malformed deep links, offline, airplane mode mid-ride (see Front C).
- **The Accessibility Auditor** — TalkBack, contrast, touch targets, text scaling, one-handed reach.
- **The Performance Profiler** — cold start, jank, memory-over-time, and the battery/CPU cost of the always-on foreground service.
- **The Chaos Monkey** — `adb monkey` / Fastbot2 stochastic fuzzing for crashes/ANRs/state-loss.

---

## 2. Bootstrap — nothing is installed here

`flutter`, `adb`, `emulator`, `sdkmanager`, `avdmanager` are **not on PATH**. Step zero, before any testing:

```bash
# 1. Verify KVM (mandatory for usable emulator speed on Linux)
egrep -c '(vmx|svm)' /proc/cpuinfo   # > 0
sudo apt install -y qemu-kvm libvirt-daemon-system && sudo usermod -aG kvm $USER  # re-login

# 2. Android cmdline-tools + platform-tools + emulator  (ANDROID_HOME=$HOME/Android/Sdk)
#    then: yes | sdkmanager --licenses
sdkmanager "platform-tools" "emulator" "build-tools;35.0.0"

# 3. Flutter SDK (a working copy already exists at /home/raed/flutter/bin) — put it on PATH:
export PATH="/home/raed/flutter/bin:$PATH"   # flutter + its bundled dart
flutter doctor -v   # Android toolchain must be green
```
A real phone (`ZN5225DML5`) is already reachable via `$HOME/Android/Sdk/platform-tools/adb`. Build+install: `flutter build apk --debug --dart-define=GEOWAKE_SHARE_TOKEN=<token>` then `adb install -r build/app/outputs/flutter-apk/app-debug.apk`.

---

## 3. The 2026 toolchain (install what each front needs)

**Drive the app (UI):**
- **Patrol** (LeanCode) — *backbone.* Flutter-native E2E on top of `integration_test`, reuses the app's existing `Key()` finders, runs real Dart assertions, and — decisively — its native automator taps the OS **Location "Allow all the time" / notification / battery-optimizer dialogs** the foreground service depends on. `flutter pub add dev:patrol` + `dart pub global activate patrol_cli`; run with `patrol test`. Add **`patrol_mcp`** so you can run/re-run flows + grab screenshots as MCP tools.
- **Maestro** (mobile.dev) **+ Maestro MCP** — agentic YAML flows, self-healing, system-level steps (deep links like the `geowake://j/{id}` share links, notification taps, backgrounding). Fast UX-smoke + regression layer.
- **mobile-mcp** (`npx @mobilenext/mobile-mcp@latest`) — lowest-friction agent-native controller for free-form exploration across the real phone + emulators.
- **Dart/Flutter MCP** (`dart mcp-server`) — inner dev loop: hot reload, widget-tree introspection, runtime errors, screenshots.
- **DroidBot-GPT / LLM-Explorer** — LLM-vision autonomous crawler for open-ended discovery (LLM-Explorer is far cheaper).
- **adb monkey / Fastbot2** — stochastic chaos.

**Emulator matrix (core-background OS truth):** cmdline-tools + KVM. Use **`google_apis`** images (NOT `google_apis_playstore` — Play images block `adb root`/mock-location, which you need). Matrix API **{24, 29, 33, 34, 35}** × {`pixel_7` phone, `pixel_tablet`, `pixel_fold` foldable} + one low-RAM "Go" profile. Boot headless: `emulator -avd NAME -no-window -no-audio -no-snapshot -gpu swiftshader_indirect -no-boot-anim`, gate on `adb wait-for-device` + `getprop sys.boot_completed`. For CI, `reactivecircus/android-emulator-runner` on a KVM Linux runner.

**Accessibility oracles:** Flutter `meetsGuideline()` matchers (`androidTapTargetGuideline` 48×48, `textContrastGuideline` 4.5:1, `labeledTapTargetGuideline`), on-device **Accessibility Scanner** + **axe-Android** for WCAG 2.2. Automated a11y catches only 20–40% — the **manual TalkBack pass on the real phone is non-negotiable.**

**Visual regression:** **Alchemist** goldens (golden_toolkit is discontinued) across text-scale × light/dark × locale.

**Security:** `mobsfscan` + **MobSF** (Docker REST), `osv-scanner` + `trivy`, `apkleaks`, `jadx`/`apktool`, **`reFlutter`/Blutter** (dump `libapp.so`), `mitmproxy` + **Frida** (BoringSSL unpinning), `nuclei` + OWASP ZAP, `gitleaks`/`semgrep`.

**Device farms:** **Firebase Test Lab** free tier (`gcloud firebase test android run`, 5 physical runs/day) for OEM-matrix crash-smoke breadth. LambdaTest/BrowserStack trials to eyeball OEM skins you don't own. **But see Front B — farms structurally cannot prove background survival.**

---

## 4. Front A — User-end UI/UX

Run the persona committee (§1). Each persona: cold-wiped install → hit the real first-run permission gauntlet (fine + background location, notifications on 13+) exactly as a user does → discover and complete tasks → log every issue. Drive with Maestro/mobile-mcp; capture a screenshot per screen/flow; feed screenshots to a multimodal-LLM **judge committee** scoring each against Nielsen's 10 heuristics + a per-persona cognitive-walkthrough script (keep ≥2-consensus findings).

**Gate with deterministic oracles (CI veto):** Alchemist goldens (visual regression across sizes/scale/theme/locale) + `meetsGuideline()` a11y matchers. **Known systemic lead:** the codebase has essentially **zero `Semantics()`/`semanticLabel`** — every icon-only control (FABs, map overlays, toggles) is invisible to TalkBack *and* to black-box tools. Confirm it, quantify it, and it's both an a11y bug **and** a testability blocker you must fix (see §5).

Cover every micro-interaction you discover: search + recents dropdown, map tap / double-tap-zoom / long-press, mode toggles, the threshold slider bounds, the arm CTA enable logic, confirm sheets, dialogs, snackbars, empty/error/offline states, dark/light, back-nav from everywhere, deep-link entry, the paywall, consent, report-a-problem, widget.

---

## 5. Front B — Core background engineering (the heart)

**No UI tool proves this front.** The never-late engine (EKF + ZUPT dead-reckoning + reachability + foreground-service survival) is proven only by **replaying position streams and injecting OS failure states via adb, then reading the app's own telemetry/logs** — not by watching pixels.

**Three layers:**
- **L0 — pure-Dart determinism (run on every change):** drive `ImuReplayEngineV2` + `EkfOrchestrator` + `ReachabilityTracker` + `AlarmEvaluator` headless in `flutter test` at ~100× warp; assert the **metamorphic never-late invariant** (`reach leadSeconds >= 0`) and EKF drift bounds over a large route set. This is the never-late gate. **This is the single highest-value test in the whole product** — expand it relentlessly (more lines, more blackout patterns, more speeds, adversarial geometry).
- **L1 — real app on the emulator matrix:** `adb install -r` the debug APK to every AVD; replay GPS with an `adb emu geo fix <lon> <lat>` loop (longitude first!) or NMEA from a GPX/CSV track (there's **no headless GPX player** — script the loop); assert the shipping app's geolocator → EKF → alarm chain.
- **L2 — OS failure injection (the whole point):** `adb shell dumpsys deviceidle force-idle` (+ `step`) for deep Doze; `adb shell am set-standby-bucket com.geowake.app restricted|rare` for App-Standby; `adb shell am kill` / `am force-stop com.geowake.app` for process death → assert the **exact-alarm backstop** still fires; `adb reboot` → assert **BOOT_COMPLETED re-arm**; `cmd appops`/battery-optimizer toggles. After each, read telemetry to confirm the alarm fired at-or-before arrival.

**The truth about OEM background-kill:** cloud farms **cannot** prove it — sessions are time-boxed (~45 min), devices are plugged/awake/screen-mounted (the opposite of Doze), and you can't walk MIUI Autostart / One UI "Deep sleeping apps" / ColorOS battery settings. **Prove this on real OEM phones over adb** (buy/borrow 2–3 cheap used Xiaomi/Samsung/Oppo handsets — cheaper than a month of any farm). Cross-reference **dontkillmyapp.com** per OEM. This is the make-or-break reliability front and it lives on real hardware.

---

## 6. Front C — Security audit (MASVS-aligned, mostly free, CLI-scriptable)

- **Tier 1 (every CI build):** `mobsfscan` on `lib/` + `android/` (Dart/Kotlin SAST, SARIF); `osv-scanner` on `pubspec.lock` + `backend/share/package-lock.json`; `npm audit`; `flutter pub outdated`. Gate on high severity. (Watch **CVE-2026-27704** Pub Zip-Slip → needs Flutter ≥3.41/Dart ≥3.11.)
- **Tier 2 (per release APK):** MobSF static (Docker REST → JSON), `apkleaks`, `jadx`, and — because this is Flutter — **`reFlutter`/Blutter to dump `libapp.so`** and confirm what `--dart-define` secrets are recoverable.
- **Tier 3 (dynamic, rooted emulator/real phone):** `mitmproxy` + Frida BoringSSL-unpinning to record **all** egress and **prove no raw trajectory/PII ever leaves the device.**
- **Tier 4 (backend, against a NON-prod Railway instance):** `nuclei` + ZAP + a curl matrix — authz on the share bearer token (missing/wrong/valid), **IDOR/share-id guessing** on `/j/{id}` and `/v1/share/{id}`, rate-limit bypass (the limiter is in-memory per-IP — verify `X-Forwarded-For` handling behind Railway's proxy), body-size/TTL, JSON injection.

**High-value leads to verify first** (starting threads, not the whole map): the **share bearer token is a single shared secret compiled into the client** (extractable — treat as public; the backend must move to per-device/per-share capability tokens); **HMAC link-token verification is OFF by default**; the **Maps key is client-side** (must stay API-restricted); audit the **`app_links` deep-link surface** for intent-redirection/exported-component issues.

---

## 7. Standing build mandates (build these so testing *can* be exhaustive)

You are expected to **change the app and its harness**, not just poke it. Every setting/component must become agent-configurable. Concretely:

1. **Instrument for visibility + a11y:** add `semanticLabel`/`Semantics(identifier:)` to icon-only controls and major screens (fixes the TalkBack gap *and* unblocks black-box drivers). Gate `enableFlutterDriverExtension()` behind a `--dart-define`.
2. **Rebuild the sim dashboard so it can test *any* trip, not just canned metro routes.** Today arbitrary polylines already flow into the *position* simulator (via the `route_update` relay message), but **the EKF/IMU synthesizer's route builder is hardcoded** — so arbitrary trips don't get EKF/ZUPT/reachability values. Add `ImuReplayEngineV2.loadFromPolyline(...)` (mirror `_loadMetroRoute`) + `EkfTestController.loadRouteFromPolyline(...)` so **(a) any arbitrary trip synthesizes full EKF, (b) real recorded trips replay, and (c) the same trips replay end-to-end through the *actual app* on an emulator** (mock-location injection + route playback).
3. **Build a headless harness runner** (`lib/testing/harness_runner.dart`) mapping a JSON scenario spec (route, warp, GPS-dropout mode, tolerances) → `EkfTestController` → JSON metrics out, so you can sweep hundreds of scenarios from the CLI and diff results.
4. **Stand up the emulator matrix + CI** so unit/widget/golden run on every commit and Patrol + Maestro + the never-late replay run nightly across the matrix, with a real-phone lane for Doze/reboot/OEM.

Reuse the seams that already exist: `integration_test/` with `SimpleLocationInjector.playRoute`, `test/mock_location_provider.dart`, `test/process_death_recovery_test.dart`, `TrackingService.isTestMode` + `testGpsStream`.

---

## 8. Issue-log protocol (log EVERYTHING)

One append-only log (`docs/testing/ISSUES.jsonl`), one object per finding:

```json
{
  "id": "GW-0001",
  "title": "short imperative summary",
  "front": "ux | background | security | perf | a11y",
  "persona": "which persona/oracle found it",
  "kind": "bug | too-early | subpar | complaint | risk | missing",
  "severity": "P0-never-late | P0-too-early | P0 | P1 | P2-subpar | P3-nit | complaint",
  "evidence": "device tag (sim|emulator|real-device) + screenshot path / log excerpt / adb repro",
  "repro": "numbered steps that reliably reproduce it",
  "expected": "…", "actual": "…",
  "verified_by": "≥2-persona consensus | oracle | single (unverified)",
  "status": "open | confirmed | fixed | wontfix"
}
```
**A reproducible late-fire is P0-never-late and stops the world; a systematically too-early fire, a gated core alarm, an ad on a wake surface, or any raw-location egress is a top-priority finding.** And log EVERYTHING else too — not just crashes and bugs, but **every feature that's done subpar** and **every complaint about any aspect**: a confusing label, an ugly transition, a janky scroll, a slow screen, a feature that technically works but feels cheap, a missing affordance. **If any persona would grumble about it, it gets an entry.** Better a thousand logged nits than one unlogged rough edge. Rank the log; re-verify P0/P1 on real hardware before reporting.

---

## 9. Your first day
1. Bootstrap the toolchain + one emulator + confirm the real phone (§2).
2. Wipe + cold-install; run the **First-Time User** and **Skeptic** personas manually to calibrate.
3. Build the arbitrary-trip EKF into the dashboard (§7.2) and run one **tunnel-blackout metamorphic never-late** replay (§5 L0) — that single flow is the product.
4. Spin up the persona committee + the emulator matrix + the Tier-1 security scan in parallel.
5. Only after you have independent findings: unseal `docs/AGENT_HANDOFF_E2E.md` and diff reality against the docs.

Report findings ranked by severity, each tagged sim/emulator/real-device, most-severe first. Trust the oracles over opinions, real hardware over emulators, and your own eyes over any doc — including this one.
