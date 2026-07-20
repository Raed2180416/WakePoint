# GeoWake — End-to-End Testing Handoff

> For the next agent. You have **remote access to a physical Android phone** and
> full latitude to drive the app, run the simulation dashboard, and reason about
> UX / intent / product optimality across edge cases. This doc is your ground
> truth for *what is real vs. hollow* so you don't waste time testing stubs or,
> worse, report a stub as "working."

**App:** GeoWake — Flutter, Android-first, India transit wake-alarm.
**Core promise:** *wake a transit rider before their stop — never late, even when
GPS dies underground.* Everything else is secondary to that promise.

---

## 0. Your mission

Test **deeply, end-to-end**, on the real device and via the simulation dashboard:
- **UX/UI:** every screen, flow, empty state, error state, dark/light, back-nav.
- **Intent:** does the app actually do what a sleepy commuter needs — arm a trip,
  survive backgrounding/Doze/GPS-loss, and *wake before the stop*?
- **Product:** is the flow optimal? Where's friction? What breaks trust?
- **Edge cases:** GPS blackout (tunnel/underground), transfers/interchanges,
  no-network, permission denials, battery-optimization kills, process death,
  reboot, very short and very long trips, arriving early, overshoot.

Reason about **optimality**, not just "does it crash." Where the product is
hollow (see §5), say so plainly — do not paper over it.

---

## 1. Non-negotiable invariants (these ARE the product — never violate)

1. **Never gate reliability or the core alarm.** The wake alarm, backstop alarm,
   basic on-time reliability, and a single active route are ALWAYS free. If you
   ever see the core alarm behind a paywall, that's a P0 bug.
2. **No ads on alarm / wake / lock surfaces.** Ads may only appear on the
   route-arming (pre-trip) surface, for free users. An ad on the ringing/lock
   screen is a P0 bug.
3. **Never store or sell an individual location trajectory.** The only
   permissible data egress is k-anonymous (k≥100) + differentially-private
   *aggregates*. (Today nothing egresses at all — see §5.)
4. **Never claim device proof from simulation.** The dashboard/sim is for
   behavior exploration. "Proven on device" requires a real ride. Say which is
   which in every report.
5. **Never fire late.** Early is safe; late is product death. The reachability
   cone (see §6) exists to guarantee at-or-before arrival.

---

## 2. Phone & tooling access

| Thing | Value |
|---|---|
| Device id | `ZN5225DML5` |
| Package | `com.geowake.app` (MainActivity: `com.geowake.app/.MainActivity`) |
| adb | `$HOME/Android/Sdk/platform-tools/adb` |
| Flutter | `/home/raed/flutter/bin/flutter` (3.44.6) · dart: `/home/raed/flutter/bin/dart` |
| Repo | `/home/raed/Projects/WakePoint` (branch `sim-validation`) |

Common commands:
```bash
ADB="$HOME/Android/Sdk/platform-tools/adb"
"$ADB" devices                               # confirm ZN5225DML5 is 'device'
"$ADB" shell monkey -p com.geowake.app -c android.intent.category.LAUNCHER 1   # launch
"$ADB" exec-out screencap -p > shot.png      # screenshot (then Read it)
"$ADB" shell dumpsys activity activities | grep -i ResumedActivity   # what's foregrounded
"$ADB" shell am force-stop com.geowake.app   # kill to test cold start
```
**Privacy note:** `screencap` captures whatever is on the phone. If a non-GeoWake
app is foregrounded (the owner uses this phone), you may capture their content —
confirm GeoWake is the ResumedActivity before capturing, and never mine
incidental content.

Rebuild + install a fresh debug APK (bakes in the live-share token so follow/
status works):
```bash
cd /home/raed/Projects/WakePoint
/home/raed/flutter/bin/flutter build apk --debug \
  --dart-define=GEOWAKE_SHARE_TOKEN=cc9972930f5e26933ac8e8adeb0bbfb602f7caf9060ed921
"$ADB" install -r build/app/outputs/flutter-apk/app-debug.apk
```
(If install fails once with no reason, retry — the first attempt can race a
running instance.)

---

## 3. Running the Unified Simulation Dashboard (phone ↔ laptop live map)

This is the "playground": you start a route **from the phone**, and a **live map
on the laptop** (in a browser) visualizes position/route/ETA in real time, with
knobs to simulate the journey (including GPS dropout / tunnel modes).

Three parts must run together (see also `.agent/workflows/launch_simulation.md`,
though its dashboard target is stale — use the *unified* one below):

1. **Relay server** (bridges phone ↔ dashboard, port 8081):
   ```bash
   cd /home/raed/Projects/WakePoint && /home/raed/flutter/bin/dart tools/relay_server.dart
   # → "Relay Server listening on ws://localhost:8081"
   ```
2. **Web dashboard** (the correct, unified entry point):
   ```bash
   /home/raed/flutter/bin/flutter run -d chrome -t lib/main_unified_dashboard.dart --web-port 3000
   ```
   (Dashboard code: `lib/dashboard/unified_dashboard.dart`; WS default
   `ws://127.0.0.1:8081` from `lib/config/playground_bridge.dart`.)
3. **Phone → relay bridge** (so the phone's `SimulationClient` reaches the
   laptop relay over localhost):
   ```bash
   "$ADB" reverse tcp:8081 tcp:8081
   ```
   The phone's `location_manager` connects `SimulationClient`
   (`lib/services/simulation_client.dart`) to `ws://127.0.0.1:8081`.

**Verify:** both the dashboard and the app should show a "Connected" state. Start
relay FIRST. If "connection refused," the relay isn't up or `adb reverse` wasn't
run. `main_unified_dashboard.dart` is **dev-only** and must never ship as the
launch target (production entry is `lib/main.dart`).

---

## 4. Deep-link testing (Friends' rides)

Two entry points are wired into the manifest:
- **Custom scheme (works now):**
  ```bash
  "$ADB" shell am start -a android.intent.action.VIEW -d "geowake://j/TESTID123"
  # → opens the app on "Friends' rides", follows TESTID123 (shows "Waiting…" for a fake id)
  ```
- **HTTPS App Link:** `https://geowake-share-production.up.railway.app/j/{id}` —
  registered with `autoVerify=true`. It only auto-opens (no chooser) **after** the
  backend redeploys `assetlinks.json` off-peak (Railway free-tier blocks deploys
  8am–8pm SGT) AND the app is reinstalled so Android re-verifies. Until then, use
  the `geowake://` path. Check status: `"$ADB" shell pm get-app-links com.geowake.app`.

To exercise a **real** share end-to-end: on the phone, arm a trip → "Share ride
status" → send the link to yourself → open it → confirm Friends' rides shows a
route-relative status (never raw GPS). A follower can add an optional **local
nickname** ("Amma") — stored on-device only, never sent anywhere.

---

## 5. HONEST current-state matrix — READ THIS BEFORE TESTING

Verified by code audit on this branch. **Do not report a stub as working.**

### Premium (Pro) features — mostly hollow
| Pro feature | Reality |
|---|---|
| **Ad-free** | ✅ **Works.** `isPro` genuinely suppresses every ad surface. |
| **Custom alarm sounds / escalation** | ⚠️ **Real feature, but NOT gated** — `RingtonesScreen` (11 tones, preview, "test my alarm", escalating volume ramp) ships **free**; `canUseCustomAlarmSounds` has zero callers. So it's not actually a Pro benefit today. |
| **Guardian mode** | ❌ **Stub.** Setup UI + gate + Hive persistence work, but **nothing is ever sent**: the auto-share-on-arm hook has no production caller, `GuardianService.init()` is never called at startup, and `_notifyContact()` is a hard-coded no-op. The saved contact is never messaged; "arrived safely" never fires. |
| **Home widget** | ❌ **Stub.** Full Dart bridge, but **no native Android widget** (no `AppWidgetProvider` Kotlin, no layout XML, no manifest `<receiver>`). A Pro user cannot place a widget at all. |
| **Wear OS** | ❌ **Missing** — zero implementation, yet **advertised on the paywall** (`paywall_screen.dart`). This is false advertising and a Play-policy risk. |
| **Family alarms** | ❌ **Missing** — dead gate, no feature, not even on the paywall. |

**Bottom line:** of six Pro capabilities, only **ad-free** is a real, enforced
benefit. If you test the paywall "product-wise," note that a paying user today
receives essentially only ad removal. Recommended founder decisions: wire up
Guardian (closest to done), build or drop the widget, and **remove Wear OS +
family from the paywall until built.**

### Data collection (opt-in aggregate mobility surface) — inert by design
- **Nothing leaves the device. Ever.** Consent (default OFF), capture, k-anon
  (k≥100), and Laplace-DP aggregation are implemented and unit-tested, but the
  only wired egress sink is a `NullEgressSink` no-op; there is no server endpoint,
  no cross-device merge backend, and the capture call site (`ArrivalHooks.
  fireArrived()`) is invoked with **no coordinates**, so nothing is even recorded
  on-device in the shipping app.
- **Privacy invariant holds by construction:** a single device cannot mint a
  transmittable cell; raw lat/lng exist only as transient locals. It's a
  legally-defensible scaffold, not a working pipeline.
- To make it real you'd need: a secure-aggregation merge backend, a server
  ingestion endpoint, an `HttpAggregateEgressSink`, upload scheduling, flip
  `kDataAssetEgressEnabled`, and wire real coordinates into `fireArrived()`.
  **Honest datasheet line: "zero data leaves the device today."**

### Telemetry & crash reporting — captured locally; report UI now added
- Crashes/fatals ARE captured (all three error hooks → `TelemetryService.
  recordError`) and persisted to a rotating JSONL under
  `getApplicationSupportDirectory()`. Events are **PII/coordinate-free by
  construction** (typed funnels never take lat/lng; error strings/stacks scrubbed
  of home paths + truncated). **No network egress** of telemetry.
- **NEW this session:** a user-facing **"Report a problem"** flow
  (`lib/screens/report_problem_screen.dart` + `telemetry_report_builder.dart`),
  reachable from the settings drawer, that packages app version + coarse device
  info + recent (PII-free) events, shows the user a **preview**, and sends via the
  share sheet / email — **user-initiated egress only, no silent upload.** Plus a
  **crash-on-next-launch** prompt (a fatal sets a flag in `main.dart`; next launch
  offers to report). Test both.
- *Future:* the report currently uses in-memory events (this session). Tailing the
  on-device JSONL would add last-session crash stacks — not yet done.

---

## 6. The never-late model + where the proof lives

- Reachability cone (`lib/core/reachability/reachability.dart`): `s_max(t) =
  anchor.sHi + V_LINE·(t−t0)`; the alarm fires when `s_max ≥ target` — i.e. as
  soon as the fastest physically-feasible train *could* reach the stop. A
  physics-only "fastest-feasible-train" tightening (accel/brake/curve/dwell)
  reduces early fires; it is **inert by default** (`dynamicLeversEnabled=false`).
- **Proof (deterministic, CI-gated):** `test/reachability/` and
  `test/scale/reachability_scale_test.dart` assert fire-at-or-before-arrival over
  route matrices. Run: `flutter test test/reachability/ test/scale/`. These are
  **simulation** proofs of the math — NOT device proof.
- When you test on the phone/sim, you're validating behavior & UX, not re-proving
  never-late (the math is gated). If you see a *late* fire in sim, that's a
  serious finding — capture the exact inputs.

---

## 7. Test plan

**A. Core flow (intent):** search destination → map renders → pick alarm mode
(time / distance / metro-stops) → set threshold → **Wake Me!** (now a docked
bottom CTA) → tracking → arrival alarm fires *before* the stop → dismiss.
Verify the alarm is loud/escalating and shows on the lock screen.

**B. Reliability edge cases (the whole point):**
- Background the app mid-trip; lock the screen; confirm it still wakes.
- Kill the app (`am force-stop`) mid-trip → does the exact-alarm backstop still
  fire? (Backstop receivers are declared in the manifest.)
- Enable battery optimization / Doze; confirm the pre-arm prompt to exempt.
- Simulate GPS blackout / tunnel via the dashboard; confirm dead-reckoning keeps
  the cone advancing and it still wakes before the stop.
- Transfers/interchanges: multi-leg trip fires a leg alarm at each transfer +
  destination (this is FREE and shipped).
- No-network: cached-route offline banner; arming behavior.
- Reboot mid-trip (boot receiver re-arms).

**C. UX/UI sweep:** dark/light, every settings entry, empty states (no recents,
no friends), permission-denied paths, very long destination names, back-nav from
every screen, the paywall, the data-consent screen, Report-a-problem preview +
send, Buy-me-a-coffee (placeholder — see §8), Friends' rides add-by-link +
nickname.

**D. Share loop:** arm → Share ride status → open link on the same device →
Friends' rides shows route-relative status; confirm NO raw GPS is ever shown.

**E. Product/optimality reasoning:** where is friction highest? Is the alarm-mode
choice (time/distance/stops) understandable to a sleepy user? Is the docked CTA
discoverable? Does anything imply a Pro feature works when it doesn't (§5)?

Report findings ranked by severity, each with repro steps + a screenshot, and
mark each as **device-observed** vs **sim-observed**.

---

## 8. Known gaps & founder-only items

- **Buy Me a Coffee** link (settings) is wired to a **placeholder**
  (`kBuyMeACoffeeUrl` in `settingsdrawer.dart` = `.../YOUR_HANDLE`); it shows a
  "set your link" hint until the real handle is set. Not a bug — needs the founder.
- **Maps key** is the previously-leaked one, gitignored locally; must be
  **rotated + restricted** (package `com.geowake.app` + signing SHA, Maps-SDK-only)
  before release.
- **Railway assetlinks** redeploy is peak-hour-blocked; run `cd backend/share &&
  railway up` off-peak to enable verified HTTPS App Links.
- **Real AdMob unit IDs** + **Play App Signing SHA-256** (for prod App Links) are
  founder-provided. Test AdMob IDs ship today.
- Pro pricing (₹199 placeholder) is a founder decision.

---

## 9. Traps — things that will fool you

1. **The paywall lies (today).** It advertises Wear OS / widget / Guardian, but
   §5 shows those are missing/stub. Don't test them as working.
2. **"Buy me a coffee" opens nothing** until the handle is set — that's expected.
3. **The banner ad is often invisible** — it collapses to zero height on no-fill,
   on non-GMS environments, and for Pro. A visible *test* banner needs a real
   free Android device with Google Play + network. (An init-race that kept it
   permanently blank was fixed with a bounded retry.)
4. **Recent-trips row is gone** from the home screen (removed as redundant with
   the search autocomplete). The RouteMemory store still records (the widget reads
   it) — but the widget itself is a stub (§5).
5. **Data "sharing" toggle** exists and the consent screen works, but toggling it
   ON still sends **nothing** — the pipeline is inert (§5). Don't report "data
   sharing works" from the toggle alone.
6. **Sim ≠ device.** Never upgrade a sim observation to a device claim.
