# 14. Reliability Preflight & Telemetry

**Role in the core promise:** GeoWake's one job is to wake a transit rider before their stop — never late, never at the wrong place — even on a cheap Android phone in India where the OS actively fights background apps. Two subsystems exist to *protect* and *measure* that promise. (1) The **Reliability Preflight** is the pre-arm safety check: before a rider trusts the alarm for a real commute, it reads the four OS switches that decide whether the alarm can physically fire (notifications, exact-alarm rights, battery-optimization exemption, precise-location) and, weighting the risk by how aggressive the phone's manufacturer ROM is, warns the rider and offers a fix. (2) The **Telemetry** subsystem is the black-box recorder: privacy-safe, on-device event funnels that are *meant* to answer "did the alarm fire on time?" and "which phones fail to wake their riders?" so the team can find and fix the devices where the promise breaks. Both are built to be *fail-open* — neither may ever throw into, block, or delay the arming/alarm path. That fail-open stance is correct for safety, but as this document shows it also means both subsystems are, in the shipped build, **advisory-only and largely non-functional against the very failures they target** — the preflight cannot stop a doomed arm, and the telemetry never leaves RAM.

---

## Files

| Path | What it does |
| --- | --- |
| `lib/services/reliability/reliability_preflight_service.dart` | The **pure decision core**. Defines the verdict model (`PreflightLevel`, `PreflightSeverity`, `PreflightIssue`, `PreflightResult`), the `ReliabilityProbe` abstraction + a `FakeReliabilityProbe` for tests, the aggressive-OEM detector, and `ReliabilityPreflightService.check()` which turns four OS booleans + a manufacturer string into a ranked list of issues and an overall verdict. No plugins, no `BuildContext` — fully headless-testable. |
| `lib/services/reliability/reliability_probe_impl.dart` | The **device adapter**. `PlatformReliabilityProbe` implements `ReliabilityProbe` by calling the real plugins (`permission_handler`, `geolocator`, `device_info_plus`). Deliberately conservative error mapping. |
| `lib/services/reliability/reliability_preflight_runner.dart` | The **integration facade + UI**. `ReliabilityPreflightRunner.run()` wires the real probe, bounds the whole check with a 4-second timeout, and returns `ok` on any failure. `showReliabilityPreflightDialog()` renders the warnings; `_applyFix()` deep-links to settings. |
| `lib/services/telemetry/telemetry_service.dart` | The **telemetry core + facade**. Event model (`TelemetryEvent`), sink interface (`TelemetrySink`), the default bounded RAM sink (`InMemoryTelemetrySink`), the `TelemetryService` singleton with one typed method per funnel (session, alarm-armed, GPS lost/reacquired, alarm-outcome, reliability, reachability, EKF health, error), plus PII-scrubbing and outcome-classification helpers. |
| `lib/services/telemetry/telemetry_session.dart` | **Session bootstrap glue**. `recordSessionStart()` stamps device/OEM/Android-version context and emits `session_start` (with the four arm-time permission states, read in parallel) + `alarm_armed`. Called unawaited from the arm flow. |

**Callers (interfaces into the rest of the app):**
- `lib/screens/homescreen.dart:1039–1042` — runs the preflight during arming and shows the dialog.
- `lib/services/trackingservice.dart:250` — fires `recordSessionStart(...)` unawaited when tracking starts.
- `lib/main.dart:31,35,60` — routes all uncaught Flutter/zone/platform errors to `TelemetryService.recordError`.
- `lib/services/tracking/alarm_controller.dart:1150` — the only in-trip funnel actually wired: `reachabilityActivated(...)`.

---

## How it works, step by step

### A. Reliability Preflight — the atomic walkthrough

**Trigger.** When the rider taps "start/arm" on the home screen, `homescreen.dart:1039` calls `await ReliabilityPreflightRunner.run()` *before* `trackingService.startTracking(...)`.

**Step 1 — Runner constructs the pure service over the real probe.**
`reliability_preflight_runner.dart:21` builds `ReliabilityPreflightService(const PlatformReliabilityProbe())`. The service is pure; the probe is the only thing that touches the OS.

**Step 2 — Runner bounds the check with a hard 4 s timeout and a fail-open default.**
`run()` (lines 18–34) declares `const okResult = PreflightResult(level: PreflightLevel.ok, issues: [])` and does:
```
return await service.check().timeout(const Duration(seconds: 4), onTimeout: () => okResult);
```
wrapped in a `try/catch` that also returns `okResult`. Two distinct failure modes are handled on purpose: a *thrown* error (caught) and a *hung* platform channel (a misbehaving permission plugin can block forever without throwing — a `try/catch` can't catch that, so the timeout is the real guard). Either way the verdict degrades to `ok`.

**Step 3 — `check()` reads the five OS states, sequentially.**
`reliability_preflight_service.dart:264–270` awaits, one after another:
1. `probe.notificationsEnabled`
2. `probe.exactAlarmAllowed`
3. `probe.batteryOptExempt`
4. `probe.preciseLocation`
5. `probe.manufacturer` → fed to `isAggressiveOem(...)` → `bool aggressive`

Each is a separate platform-channel round-trip and they are **not** parallelized here (contrast the telemetry path, which does `Future.wait` — see §B).

**Step 4 — The probe maps raw OS status to booleans, erring toward "warn".**
In `reliability_probe_impl.dart`:
- `exactAlarmAllowed` (24–34): non-Android → `true`. On Android, `Permission.scheduleExactAlarm.status` is `true` if `isGranted || isLimited || isProvisional`; **on any error → `false`** (warn).
- `batteryOptExempt` (37–45): non-Android → `true`. On Android, `Permission.ignoreBatteryOptimizations.status.isGranted`; **error → `false`** (warn).
- `notificationsEnabled` (48–55): `Permission.notification.status` is `true` if `isGranted || isProvisional`; **error → `false`** (warn — this is the hard-block input).
- `preciseLocation` (58–65): `Geolocator.getLocationAccuracy() == precise`; **error → `true`** (the *opposite* default — "don't nag; the runtime accuracy gate still protects us").
- `manufacturer` (68–76): lower-cased `androidInfo.manufacturer`; error → `''`; non-Android → the OS name.

**Step 5 — `check()` builds issues, most-severe first.** For each failing precondition it appends a `PreflightIssue` with a stable `code`, a `severity`, a plain-English `title`/`message`, and a stable `fixAction`:
- `!notifications` → **`block`** severity, `notifications` code. Message: *"GeoWake can't wake you while notifications are turned off…"*. This is the only hard block.
- `!exactAlarm` → **`warn` if aggressive OEM, else `advisory`**. On an aggressive ROM the copy escalates to "your phone can hold back timed alarms, so the backup alarm might go off late."
- `!batteryExempt` → **`warn` if aggressive OEM, else `advisory`**. On an aggressive ROM: "your phone's battery saver can close GeoWake while it's in your pocket and stop the alarm."
- `!precise` → always **`warn`** (`precise_location` code): "…the alarm may be off."

**Step 6 — Sort + roll up.** Issues are sorted ascending by `severity.index` (line 338); since `PreflightSeverity` is ordered `block(0) < warn(1) < advisory(2)`, the most severe lands first. `_rollUp` (346–353) walks the issues and takes the worst `PreflightLevel` via `levelForSeverity` (block→block, warn/advisory→warn), defaulting to `ok`. The result's `issues` list is wrapped `List.unmodifiable`.

**Step 7 — Runner shows a dialog (or not).** Back in `homescreen.dart:1040`, if `!preflight.isOk && mounted`, it calls `showReliabilityPreflightDialog(context, result)`. The dialog (`runner` 40–85):
- Returns immediately if `isOk` or no issues.
- Titles itself "Your alarm may not be able to wake you" when `isBlocked`, else "Make your alarm more reliable".
- Renders one bulleted `issue.message` per issue, each with a "Fix" `TextButton` → `_applyFix(issue.fixAction)`.
- Has a single dismiss action labeled "Proceed anyway" (block) or "Got it".

**Step 8 — Fix deep-links (stubbed).** `_applyFix` (89–100) is a `switch` on `fixAction` whose four named cases and the `default` **all fall through to `openAppSettings()`** — the generic app-info page. `fixAction` is effectively ignored today.

**Step 9 — Arm proceeds regardless.** After the dialog `await` returns, `homescreen.dart:1046` unconditionally calls `trackingService.startTracking(...)`. There is **no branch on the verdict** — even a `block` result does not stop the arm.

### B. Telemetry — the atomic walkthrough

**Session bootstrap.** `trackingservice.dart:250` calls `unawaited(recordSessionStart(alarmMode, alarmValue))`. Inside `telemetry_session.dart`:
1. Reads `DeviceInfoPlugin().androidInfo` (or `iosInfo`) and calls `TelemetryService.instance.setDeviceContext(manufacturer, model, androidSdkInt, platform)`. This context map is then merged into *every* subsequent event.
2. Reads the four permission booleans **in parallel** via `Future.wait([...])` on a `PlatformReliabilityProbe` and emits `sessionStart(locationPrecise, notificationsEnabled, exactAlarmAllowed, batteryOptExempt)`.
3. Emits `alarmArmed(mode, value, city?, line?)`.
Every step is wrapped in its own `try/catch`; device context and telemetry are both best-effort.

**Emission path.** Each typed funnel method delegates to the private `_emit(type, props)` (telemetry_service.dart:134–148):
1. If `!_enabled` → return silently.
2. Build a `TelemetryEvent{type, timestampMs: nowMs(), props: {..._deviceContext, ...props}}`. `nowMs` is an injectable clock (wall clock in prod, fixed in tests).
3. For each sink, `s.add(ev)` inside a per-sink `try/catch` so a bad sink can't break the others.
4. The whole body is wrapped in an outer `try/catch` — **telemetry can never throw into the caller.**

**Serialization + PII safety.** `TelemetryEvent.toJson()` (54–61) maps `t`/`ts`/props, and passes every prop value through `_jsonSafe`, which turns **non-finite doubles (NaN/Infinity) into `null`** — because `jsonEncode` throws on them and a bad tick can legitimately produce a NaN speed or Infinity ETA. `toJsonLine()` is `jsonEncode(toJson())`. `recordError` scrubs strings with `_scrub` (268–273), which rewrites `/home/<user>` and `/Users/<user>` paths to `/~` and truncates (300 chars for the message, 1200 for the stack).

**The default sink.** `TelemetryService` starts with exactly one sink: `InMemoryTelemetrySink(capacity: 2000)` (line 112). `add()` appends and, while `_buf.length > capacity`, `removeFirst()` — guarded by `isNotEmpty` so a zero/negative capacity can't throw. It exposes `events` (unmodifiable copy), `length`, `clear()`, `countOfType(type)`.

**Classification helper.** `classifyOutcome(leadSeconds, {onTimeWindow = 30.0})`: `< 0` → `late`; `<= 30` → `onTime`; else `early`. `_round(v)` snaps a finite double to 1 decimal, and returns `0.0` for non-finite.

**What is actually emitted in the shipped app (verified by grep of `lib/`):**

| Funnel method | Emit call-sites in `lib/` | Where |
| --- | --- | --- |
| `recordError` | 3 | `main.dart` FlutterError/PlatformDispatcher/zone handlers |
| `reachabilityActivated` | 1 | `alarm_controller.dart:1150` (only when the physics bound leads dead-reckoning by > 50 m) |
| `setDeviceContext` + `sessionStart` + `alarmArmed` | 1 path | via `recordSessionStart` from `trackingservice.dart:250` |
| `gpsLost`, `gpsReacquired`, `ekfHealth`, **`alarmOutcome`**, `reliability` | **0** | **never called anywhere** |
| `configure` (install a real sink) | **0** | never called on `TelemetryService` |

The single `.configure(` hit in `lib/` (`trackingservice.dart:211`) is the `flutter_background_service` config — **not** telemetry.

---

## Key types & functions

**Reliability core (`reliability_preflight_service.dart`):**
- `enum PreflightLevel { ok, warn, block }` — overall verdict, ordered least→most severe by `index`.
- `enum PreflightSeverity { block, warn, advisory }` — per-issue, ordered most→least severe by `index`.
- `class PreflightIssueCode` / `class PreflightFixAction` — stable string keys (`notifications`, `exact_alarm`, `battery_optimization`, `precise_location`; `openNotificationSettings`, `openExactAlarmSettings`, `openBatteryOptimizationSettings`, `openLocationSettings`). They double as telemetry/analytics keys and UI deep-link routes.
- `class PreflightIssue{code, severity, title, message, fixAction}` — one problem, with user-facing copy.
- `class PreflightResult{level, issues}` — verdict + ranked issues; helpers `isOk/isBlocked/hasWarnings`, `blocking`, `fixActions`, `issueOf(code)`.
- `abstract class ReliabilityProbe` — 5 async getters: `exactAlarmAllowed`, `batteryOptExempt`, `notificationsEnabled`, `preciseLocation`, `manufacturer`.
- `class FakeReliabilityProbe implements ReliabilityProbe` — all-good defaults (`oem: 'google'`), each field flippable; the test seam.
- `class ReliabilityPreflightService{probe}`:
  - `static const List<String> aggressiveOemNeedles` — 30 manufacturer substrings.
  - `static bool isAggressiveOem(String manufacturer)` — trim→lower→substring-`any`; empty-safe (`''` → false).
  - `static PreflightLevel levelForSeverity(PreflightSeverity)` — block→block, warn/advisory→warn.
  - `Future<PreflightResult> check()` — the single entry point (steps 3–6 above).
  - `static PreflightLevel _rollUp(List<PreflightIssue>)` — worst level, default `ok`.

**Reliability adapter (`reliability_probe_impl.dart`):**
- `class PlatformReliabilityProbe implements ReliabilityProbe` — const, plugin-backed, conservative error mapping (Step 4 above).

**Reliability integration (`reliability_preflight_runner.dart`):**
- `static Future<PreflightResult> ReliabilityPreflightRunner.run()` — wires probe, 4 s timeout, fail-open.
- `Future<void> showReliabilityPreflightDialog(BuildContext, PreflightResult)` — non-blocking dialog.
- `Future<void> _applyFix(String fixAction)` — best-effort deep-link (currently always `openAppSettings()`).

**Telemetry (`telemetry_service.dart`):**
- `enum AlarmOutcome { onTime, early, late, missed, dismissed, snoozed }` — the north-star outcome space.
- `class TelemetryEventType` — stable event tags.
- `class TelemetryEvent{type, timestampMs, props}` — immutable; `toJson()` (NaN/Inf→null), `toJsonLine()`.
- `abstract class TelemetrySink { void add(TelemetryEvent); }` — must not throw.
- `class InMemoryTelemetrySink implements TelemetrySink` — bounded ring buffer, `capacity` default 2000.
- `class TelemetryService` (singleton `instance`): injectable `nowMs`; `_deviceContext`; `_sinks`; `_enabled`; `configure({sinks, replace, enabled})`; `memorySink`; `_emit`; typed funnels `sessionStart`, `alarmArmed`, `gpsLost`, `gpsReacquired`, `alarmOutcome`, `reliability`, `reachabilityActivated`, `ekfHealth`, `recordError`; helpers `_round`, `_scrub`, `classifyOutcome`.

**Telemetry glue (`telemetry_session.dart`):**
- `Future<void> recordSessionStart({alarmMode, alarmValue, city?, line?})` — device context + `session_start` + `alarm_armed`; parallel permission read; fail-open.

---

## Design decisions (the WHY)

1. **Pure core + injected probe (headless-testable preflight).** *Decided:* all decision logic lives in `ReliabilityPreflightService`, which reads the OS only through the abstract `ReliabilityProbe`; the real plugin adapter is a separate file wired at integration. *Why:* every permission combination (2⁴ × aggressive/not) becomes a deterministic unit test via `FakeReliabilityProbe`, with no device, no `BuildContext`, no plugin channel. *Trade-off / rejected:* calling `permission_handler` directly inside the logic would have been fewer files but untestable and platform-coupled. *Flaw:* none in the core; the risk is that the *adapter* (`PlatformReliabilityProbe`) is device-verifiable only and is **not** exercised by the pure tests — a wrong plugin-status mapping (e.g. treating `isDenied` as granted) would pass every unit test and still ship broken.

2. **Fail-open everywhere (timeout → `ok`, catch → `ok`, dialog non-blocking).** *Decided:* a preflight failure, hang, or exception must never stop the rider from arming; the arm proceeds regardless of verdict. *Why:* the app's job is to wake people; a buggy safety check that *prevents* arming would itself cause a missed stop and is worse than no check. The 4 s timeout also defends against a permission plugin that blocks the channel without throwing. *Trade-off:* it converts every hard guarantee into a suggestion. *Flaw (serious):* the phones most likely to kill the app — slow, aggressive-OEM budget Androids in India, the exact core-promise target — are also the ones most likely to make five sequential permission channel calls exceed 4 s, at which point the preflight silently returns `ok` and the rider gets **no warning at all on precisely the device that most needs it**.

3. **`block` semantics defined but not enforced.** *Decided:* notifications-off is modeled as `PreflightSeverity.block` → `PreflightLevel.block`, and the enum docs say "the UI must block arming until it is resolved." *Why the model exists:* to distinguish "alarm physically cannot appear" from "alarm at risk." *Reality / flaw (serious):* the runner is explicitly non-blocking and `homescreen.dart:1046` calls `startTracking` unconditionally after the dialog; the block dialog's own button literally reads "Proceed anyway." So a rider with notifications disabled arms an alarm that **cannot ever fire**, sees a dialog, taps "Proceed anyway," and boards the train believing they're covered. The strongest word in the model (`block`) is downgraded to a dismissible tooltip in practice. This is the single largest contradiction between the subsystem's stated intent and its shipped behavior.

4. **Deep-links are stubbed to a single generic screen.** *Decided (nominally):* each issue carries a `fixAction` the UI maps to the correct settings deep-link, "reusing OemAutostartService for the OEM screens." *Reality:* `_applyFix` collapses all four cases + default into `openAppSettings()`. *Why it's like this:* expedient — one call that always works. *Flaw:* on a MIUI/ColorOS/Funtouch phone the fix the rider needs (autostart allowlist, "Alarms & reminders," battery-unrestricted) is buried several screens deep inside the OEM security app — a screen `OemAutostartService` already knows how to reach (`oem_autostart_service.dart` has explicit component intents) but which the runner does not use. The rider is dropped on the app-info page and left to hunt. The `fixAction` abstraction is real but unwired.

5. **Aggressive-OEM weighting sharpens severity.** *Decided:* `isAggressiveOem` upgrades the exact-alarm and battery warnings from `advisory` to `warn` on 30 manufacturer substrings (Xiaomi/Redmi/Poco, Oppo/Realme/OnePlus, Vivo/iQOO, Huawei/Honor, Samsung, plus Transsion's Tecno/Infinix/Itel that dominate the India/Africa budget tier). *Why:* on a ROM that kills background work, a missing battery exemption is the #1 cause of a missed wake-up, so it deserves louder copy than on stock Android. *Trade-off:* substring matching is simple but blunt. *Flaw:* short needles (`itel`, `hmd`, `wiko`, `sony`) risk false positives inside longer manufacturer strings, and the list is a hardcoded snapshot — a new aggressive OEM ships unweighted until someone edits this constant.

6. **"Mirrors OemAutostartService" — but the two lists are maintained by hand and already differ.** *Decided:* keep `aggressiveOemNeedles` in sync with `OemAutostartService`'s matching "without importing its platform plugins," to keep the pure module pure. *Why:* importing the plugin-coupled service into the headless core would destroy its testability. *Flaw:* "in sync" is aspirational — the preflight list is a *superset* (adds poco, blackshark, iqoo, meizu, asus, lenovo, tecno, infinix, itel, …) while `OemAutostartService` only handles xiaomi/redmi/oppo/realme/vivo/huawei/honor/oneplus/samsung. They have already drifted and nothing enforces parity, so an OEM can be flagged "aggressive" in the warning yet have no deep-link target in the fixer (compounding decision #4).

7. **Asymmetric error defaults in the probe (`precise` → true, others → false).** *Decided:* on a plugin error, `preciseLocation` defaults to `true` (don't nag) while the other three default to `false` (warn). *Why:* an unreadable notification/exact-alarm/battery state is safest treated as "possibly off," but location accuracy has a separate runtime gate downstream, so nagging on an unknown would be noise. *Trade-off / flaw:* the reasoning is sound but subtle and undocumented at the call site; a future refactor that "makes error handling consistent" could silently start over- or under-warning. It also means a phone where the geolocator throws will *never* get the precise-location warning even if it truly is approximate-only.

8. **Sequential probe reads in `check()`, parallel reads in `recordSessionStart`.** *Decided:* `check()` awaits the five getters one-by-one; the telemetry path `Future.wait`s four of them. *Why (likely):* `check()` was written for clarity; the telemetry path was explicitly optimized "so the arm path is never blocked for long." *Flaw:* the inconsistency means the *user-facing* preflight is the slower of the two and is the one racing the 4 s fail-open timeout (decision #2). Parallelizing `check()` would materially reduce the chance of a silent timeout on a slow device — a low-cost fix that is not done.

9. **Telemetry is PII-free by construction.** *Decided:* the typed funnel methods never accept a lat/lng; events carry only station/zone-granular ids (`city`, `line`), coarse rounded durations, device/OEM/SDK, and outcome enums. `_scrub` strips home paths from error text; `toJson` nulls non-finite doubles. *Why:* the same schema is meant to double as a k-anonymous crowdsourced-calibration feed without ever holding a trajectory (HANDOFF §4), and the app must be trustworthy to run in the background. *Trade-off:* coordinate-free events are far less useful for debugging a specific mis-fire ("where exactly did it go wrong?"). *Flaw:* `oem` + `model` + `city` + `line` + `sdk` on one event is low-cardinality but not provably anonymous for a rare device on a rare line; there is no k-threshold enforced here (it would live in the aggregation layer, which does not exist — see decision #11).

10. **Fail-open telemetry (never throws, bad sink isolated, disable switch).** *Decided:* `_emit` swallows all errors, isolates each sink, respects `_enabled`, and `InMemoryTelemetrySink.add` guards its own eviction. *Why:* telemetry sitting on the alarm path must be incapable of crashing or delaying it. *Trade-off:* silent failure — a sink that quietly drops everything looks identical to a healthy one. *Flaw:* combined with there being no health signal or delivery receipt, telemetry can be 100 % lossy in production and nothing surfaces it.

11. **In-memory-only sink; "file-backed sink provided for production" is not true in this build.** *Decided (nominally):* the core takes an injectable sink so a file/network/Crashlytics/PostHog sink "can be added later behind the same interface." *Reality (verified):* the only `TelemetrySink` implementation in `lib/` is `InMemoryTelemetrySink`; `TelemetryService.configure(...)` is **never called**; no `FileSink`/`JsonlSink`/`NetworkSink` class exists anywhere in `lib/` (the phrase appears only inside the source comment). *Flaw (severe, and the crux for the core promise):* every telemetry event lives in a 2000-entry RAM ring buffer that **nothing reads and nothing persists**. On the exact failures the reliability funnel exists to measure — OS-kill, crash, Doze death — the process terminates and the buffer evaporates *before* any of it is written or sent. The "which phones fail to wake their riders?" dataset (HANDOFF §3) is, as shipped, architecturally present and operationally empty.

12. **North-star and reliability funnels are dead code.** *Decided:* rich typed methods exist for `alarmOutcome` (the "did it fire on time?" north star), `reliability` (FGS survived / OS killed / Doze / backstop), `gpsLost`, `gpsReacquired`, `ekfHealth`. *Reality (verified by grep):* **zero** emit call-sites for any of them; `classifyOutcome` is also never called. Only `recordError`, `reachabilityActivated`, and the `session_start`/`alarm_armed` bootstrap actually fire. *Why it matters:* the two metrics that would tell the team whether the core promise is being kept — on-time fire rate and OS-kill rate per device — are never recorded, even into RAM. *Flaw:* the subsystem *looks* instrumented (thorough API, good tests) but the trip lifecycle never calls the instruments.

---

## Invariants

- **Preflight and telemetry never block, delay, throw into, or gate the arm/alarm path.** `run()` is timeout-bounded and returns `ok` on any failure; the dialog is dismissible; `recordSessionStart` is `unawaited`; every telemetry method swallows its own errors. Reliability is never paywalled (`PremiumService.canUseCoreAlarm` is always `true`).
- **The preflight decision core is pure**: no `dart:io`, no plugins, no `BuildContext`; identical inputs → identical `PreflightResult`. All OS access is behind `ReliabilityProbe`.
- **Issue ordering is total and stable**: issues sorted ascending by `severity.index` (block→warn→advisory); `PreflightResult.issues` is unmodifiable; the overall level is the worst issue's roll-up (never *less* severe than any issue).
- **Telemetry carries no raw coordinates and no free-form user text**; the typed API cannot accept a lat/lng, non-finite doubles serialize to `null`, and error strings are path-scrubbed and length-capped.
- **The RAM sink is bounded**: `InMemoryTelemetrySink` never exceeds `capacity` events and never `removeFirst()`s an empty queue.
- **`_deviceContext` is stamped on every event** emitted after `setDeviceContext` runs (events emitted before it — e.g. an early `recordError` at startup — will lack OEM/model).

## Interfaces

**Consumes from:**
- `permission_handler` (`Permission.notification / scheduleExactAlarm / ignoreBatteryOptimizations`, and `openAppSettings`), `geolocator` (`getLocationAccuracy`), `device_info_plus` (`androidInfo`/`iosInfo`) — all only through `PlatformReliabilityProbe`.
- Conceptually mirrors (but does not import) `OemAutostartService` for the aggressive-OEM list and for the settings screens the fixer *should* deep-link to.

**Exposes to:**
- **Home screen / arm flow** (`homescreen.dart:1039`): `ReliabilityPreflightRunner.run()` + `showReliabilityPreflightDialog(...)`.
- **Tracking service** (`trackingservice.dart:250`): `recordSessionStart(...)`.
- **App bootstrap** (`main.dart`): `TelemetryService.instance.recordError(...)` from the three global error handlers.
- **Alarm controller** (`alarm_controller.dart:1150`): `TelemetryService.instance.reachabilityActivated(...)`.
- **The (future) reliability/monetization dashboards**: the `PreflightIssueCode.*` and `TelemetryEventType.*` string keys are the stable analytics vocabulary those layers would key on.

**Test surface:** `test/reliability/reliability_preflight_test.dart`, `test/reliability/reliability_preflight_combinatorial_test.dart`, `test/integration/preflight_arm_scenario_test.dart`, `test/widgets/preflight_dialog_widget_test.dart`, `test/telemetry/telemetry_service_test.dart`, `test/telemetry/telemetry_edgecases_test.dart` — the pure core and the RAM sink are well covered; the plugin adapter and real persistence/transport are not (there is nothing to persist).

## Gaps & flaws vs the core promise

1. **BLOCKER — a doomed arm is never actually blocked.** Notifications-off is modeled as a hard `block`, yet the rider can tap "Proceed anyway" and `homescreen.dart:1046` arms anyway. The alarm literally cannot fire, and the rider is not stopped. The core promise ("never late") is silently unmet with zero enforcement. *Minimal fix:* branch on `preflight.isBlocked` in the home screen and require an explicit fix (or an unmistakable second confirmation) before `startTracking`.

2. **BLOCKER — the reliability dataset never persists or transmits.** No sink beyond the RAM ring buffer is ever installed (`configure` is never called; no `FileSink`/network sink exists). The "which phones fail to wake their riders?" funnel (HANDOFF §3) captures nothing durable, and captures *nothing at all* across the OS-kill/crash/Doze events it exists to measure, because the process — and its RAM — dies with them. The subsystem cannot answer the one question it was built to answer. *Minimal fix:* a JSONL file sink flushed on each `_emit` (append-only), uploaded opportunistically on next launch.

3. **HIGH — the north-star and OS-kill funnels are never emitted.** `alarmOutcome` (on-time vs late), `reliability` (FGS survived / OS killed / Doze / backstop fired), `gpsLost`, `gpsReacquired`, `ekfHealth`, and `classifyOutcome` have **zero** call-sites. Even if persistence existed, the app would still record neither its success metric nor its primary failure mode. The trip lifecycle (alarm controller, backstop, FGS lifecycle) must call these at fire/miss/kill time.

4. **HIGH — silent fail-open on slow, aggressive-OEM devices hides the warning where it matters most.** Five sequential permission channel calls racing a 4 s timeout, on the low-end India-market phones that are the core-promise target, can time out to `ok` and show the rider nothing. Parallelizing `check()` (as `recordSessionStart` already does) would sharply cut this; it is not done.

5. **MEDIUM — "Fix" buttons don't fix the specific problem.** All `fixAction`s deep-link to the generic app-info page, not to the OEM autostart / "Alarms & reminders" / battery / precise-location screens. On the ROMs where those screens are buried, a rider who *wants* to comply is left to navigate a hostile settings tree unaided — undercutting the warning's usefulness.

6. **MEDIUM — the aggressive-OEM list is a hand-maintained snapshot that has already drifted from `OemAutostartService`.** New/renamed OEMs are unweighted until edited in, short substrings risk false positives, and a device can be flagged "aggressive" in copy while having no deep-link target in the fixer. Nothing tests or enforces parity between the two lists.

7. **LOW/MEDIUM — plugin-adapter mapping is untested and could ship a wrong verdict invisibly.** The pure tests never exercise `PlatformReliabilityProbe`; a misread OS status (e.g. counting a provisional/limited state as granted) would pass every unit test yet make the preflight report all-clear on a phone that isn't. Device/instrumented tests are needed to close this.

8. **LOW — no delivery/health signal and no k-anonymity threshold in the telemetry layer.** A silently-lossy sink is indistinguishable from a healthy one, and per-event `oem`+`model`+`city`+`line`+`sdk` is only *coarse*, not provably k-anonymous — the k-threshold the design assumes lives in an aggregation layer that does not exist. Startup errors emitted before `setDeviceContext` also lack the OEM/model breakdown the funnel needs.
