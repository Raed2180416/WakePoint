# Website claims vs. shipping code

Audit of `website/index.html` against HEAD of `production-ready-audit-v2`.
Decide each row: **KEEP** / **SOFTEN (proposed wording)** / **CUT**.

---

## A. Claims that are false as written

### A1. Guardian Mode — "Your family knows you're safe, every commute, automatically"
`index.html:842`

- Auto-delivery sender is **null by default** — no SMS gateway ships.
  `lib/services/share/guardian_service.dart:45-52,100-103`
- Delivery is user-mediated: it opens *your own* SMS/WhatsApp composer.
  `guardian_service.dart:290-316`
- On a stock build the backend **rejects every call**: share auth token defaults to `''`,
  header omitted, server enforces bearer auth → `createShare`/`ping`/`arrived` all 401,
  silently swallowed. The `/j/{id}` link resolves to **410 Gone**.
  `share_backend_config.dart:35-38`, `live_share_backend.dart:115-118,146-198`,
  `backend/share/server.js:446,467-471,534`
- Even authenticated, "arrived safely" **notifies nobody** — `onArrived()` is a `console.log`,
  FCM/SMS dispatch is a TODO. `backend/share/server.js:426-435`

> **Proposed:** "Share a live tracking link with a saved contact, straight from your own
> SMS or WhatsApp."

### A2. Home Widget — "One-tap arm **and disarm**. No need to open the app."
`index.html:859-860`

- **There is no disarm.** `WidgetAction.stop` just navigates to `/mapTracking`; the bridge
  never emits a stop deep link.
  `widget_arm_handler.dart:188-191`, `home_widget_bridge.dart:246-303`
- It is **not** headless — the provider attaches a launch intent and `_handleArm` always
  navigates home. The app *does* foreground. Deliberate, per the comment at `:14-22`.
  `GeoWakeWidgetProvider.kt:76-82`, `widget_arm_handler.dart:229-233`

> **Proposed:** "Tap the widget to re-arm your usual route."

### A3. Ad-Free — "the tracking and alarm screens are *always* ad-free (even on free tier)"
`index.html:878`

- Alarm half is **true** (`alarm`, `wake`, `lockScreen` are hard-denied).
- Tracking half is **false** — `AdPlacement.mapTracking` is banner-eligible.
  `lib/services/monetization/ad_policy.dart:27-28` vs `:41-48`

> **Proposed:** "The alarm and lock screen are never ad-supported, on any tier. Pro removes
> ads everywhere else, including the tracking map."

### A4. "DND-Breaking Alarm"
`index.html:8,10,529,601,786-789`

- `setBypassDnd(true)` is wrapped in a swallowing try/catch and only takes effect if the user
  separately grants **Notification Policy Access** — which the app only *detects*, never
  *requests*, and treats as a **WARN, not a block**. The preflight literally says
  *"We cannot confirm the channel truly breaks through."*
  `NotificationChannels.kt:63,86`, `reliability_preflight_service.dart:384-399`
- No `setInterruptionFilter` anywhere in the repo.
- Channel importance is `IMPORTANCE_HIGH`, not MAX — native creates the channel first, so the
  Dart `Importance.max` never wins. `NotificationChannels.kt:57,73`
- "Full-screen lock-screen takeover" is capability-gated; on Android 14+ GeoWake is not a
  registered alarm-clock app, so the OS may deny FSI and degrade it to a heads-up banner.
  The code comment admits this. `notification_service.dart:833-836,964-979`
- **Never validated on a real device.** `docs/business_os/01_launch_readiness.md:83-86`

> **Proposed:** "Wakes you through silent mode and ringer-off on the alarm audio channel —
> and breaks Do Not Disturb once you grant notification-policy access."

### A5. "Survives OEM battery killers (Xiaomi, Samsung, Oppo)"
`index.html:622-623,756,812-813`

The backstop itself is real and boot-safe. The **OEM survival claim is unproven**:

- `USE_EXACT_ALARM` was deliberately dropped; only `SCHEDULE_EXACT_ALARM` ships, so the grant
  is user-revocable and the backstop degrades. `AndroidManifest.xml:22-31`
- Direct-boot is explicitly unsolved (payload sits in credential-encrypted storage).
  `NotificationChannels.kt:29-32`
- OEM-kill and locked-screen validation are still open items.
  `docs/business_os/01_launch_readiness.md:83-86`

> **Proposed:** drop the named OEM list. "An OS-scheduled exact-alarm backstop keeps working
> even if the app is killed."

### A6. "CI-gated by a never-late replay harness on every commit"
`index.html:616,662,801`

- The gate runs **only on `sim-validation`, `stable-release-1`, `main`** — not every commit,
  and not this branch. `.github/workflows/ci.yml:11-14`
- All three committed replay fixtures are `"synthetic": true`. The real-ride fixtures live at
  a hardcoded dev-machine path unavailable in CI.
  `test/fixtures/replay/*.json`, `test/ekf/replay_harness_test.dart:44`
- "Guarantee" is not backed by device evidence. A documented residual remains: `VLineTable.forLine`
  falls back to metro 28 m/s for any unmatched line name, so a mis-named fast service
  (Airport Express, Mumbai Suburban) is **under-bounded**.

> **Proposed:** "Physics-based reachability bound, gated by a replay harness in CI on release
> branches." Drop the word *guarantee*.

### A7. Offline Metro Dataset — "no network needed"
`index.html:637`

The dataset is compiled in and the nearby scan is local — but it has **exactly one caller**
(route validation), and setting a destination still **requires network + Google Places**;
a selection without a `place_id` is rejected outright, and routing needs the server.
The site's own step 1 ("Search via Google Places", `:741`) contradicts the card.
`homescreen.dart:362,392-396,399,718`, `api_client.dart:350-351`

> **Proposed:** "Station data ships in the app, so stop matching never waits on the network."
> (Don't claim the app works offline.)

---

## B. Wrong numbers

| Site says | Reality | Source |
|---|---|---|
| **869 stations** (`:28,540,637,807`) | 869 is the count in the raw OSM asset, which **is not what the app searches**. The shipped list has 875 rows / **~790 unique stations**. 5 raw entries have `name: null`. | `lib/all_india_stops.dart` |
| **20 cities** (`:540,637`) | 20 *keys*, but one is `delhimeerutrrts` (an RRTS corridor, not a city) and noida/gurugram/navimumbai are NCR/MMR suburbs. The metro dataset says 19. | "20 metro networks" is defensible; "20 cities" is a stretch |
| **56 m/s RRTS** (`:660`) | **53.0 m/s**. 56 is `absoluteCeilingMps`, for high-speed/long-distance rail. | `reachability.dart:61` vs `:65` |
| **"400 m station spacing"** (`:804`) | No such constant in the code. Rhetorical figure. | — |
| **85 M Indians / 11 M metro riders / "377 upvotes, 2020"** (`:580-582`) | Nothing in the repo substantiates these. | Cite a source or cut |

---

## C. Other

- **`:991`** — footer links to `https://github.com/yourorg/geowake`, a dead placeholder. Repo is private.
- **`:933-950`** — live Play Store link + QR, but the app isn't published (SKUs not created,
  Play forms unsubmitted, $25 fee unpaid). The URL will 404.
  → **Decided: replace with a pre-launch / waitlist CTA.**
- AdMob ships Google **test** unit IDs and `configure()` has zero call sites, so the free tier
  doesn't actually monetize today. Not site copy, but the pricing narrative rests on it.
  `ad_service.dart:30-46`, `AndroidManifest.xml:42-43`

---

## D. Claims that are TRUE — keep as-is

EKF tunnel tracking (real 3-state along-route EKF, accel+gyro+route geometry, on by default) ·
never-late reachability core `s_max(t)=s₀+V_LINE·(t−t₀)` · V_LINE 28 m/s metro ·
multi-leg transfers with per-interchange alarms, free · custom sounds + escalating volume
(0.25→1.0 over 12×400 ms) and haptics, Pro-gated · anti-theft snatch detection (accel+gyro
fusion, really rings) · rewarded day pass = 24 h full Pro · no auto-renew (passes are
consumables) · core alarm free forever · ₹7/₹35/₹99/₹899 ladder, all unlocking the same set ·
alarm uses the ALARM audio stream with alarm-usage vibration · backstop armed, boot-safe,
receivers manually declared · preflight checks before arming · distance/time/stops modes.
