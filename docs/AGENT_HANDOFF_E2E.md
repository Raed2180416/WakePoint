> ⚠️ **SEALED ORACLE — DO NOT READ FIRST.**
> Your handoff is `docs/AGENT_TESTING_CHARTER.md`. This document is a detailed spec of how the app *supposedly* behaves. Open it **only after** you have independently discovered and tested the app and formed your own findings — then use it *solely* to (a) measure how much you missed, and (b) catch places where this doc lies about the running reality. Treat every claim here as a suspect to verify, not a fact. Reading it first will bias your discovery and defeat the point.

---

# GeoWake — Complete End-to-End Agent Handoff

> **You are the next agent.** You have remote access to a physical Android phone and the simulation dashboard, and your job is to drive and test **every aspect** of GeoWake end-to-end — UX, intent, product, reliability, edge cases — and reason about optimality. This document is exhaustive: it maps every screen, every micro-interaction, the full reliability stack, monetization, share/Guardian, data/telemetry, the infra/build/sim runbook, and every business decision the founder must make.
>
> This supersedes/extends the shorter `docs/HANDOFF_TESTING.md`. The mobility-data strategy lives in `docs/data_business/STRATEGY.md`.

---

## The one rule above all
**Never late.** Early is safe; late is product death. And **never claim device proof from simulation** — the never-late math is CI-proven in the sim harness (`flutter test test/reachability/ test/scale/` → LATE=0), but *no real underground ride has confirmed it yet*. Every finding you report must be tagged **device-observed** or **sim-observed**.

Other invariants you must not break: never gate the core alarm/reliability; no ads on alarm/wake/lock surfaces; never store or sell an individual location trajectory (only k-anon + DP aggregates — and today **zero data leaves the device**).

## 5-minute setup
```bash
ADB="$HOME/Android/Sdk/platform-tools/adb"
FLUTTER="/home/raed/flutter/bin/flutter"
"$ADB" devices                      # expect ZN5225DML5  device
# Build + install (bakes the live-share token so follow/status works):
cd /home/raed/Projects/WakePoint
"$FLUTTER" build apk --debug --dart-define=GEOWAKE_SHARE_TOKEN=cc9972930f5e26933ac8e8adeb0bbfb602f7caf9060ed921
"$ADB" install -r build/app/outputs/flutter-apk/app-debug.apk
"$ADB" shell monkey -p com.geowake.app -c android.intent.category.LAUNCHER 1
```
Confirm GeoWake is the foreground app before any `screencap` (the phone is the owner's — don't capture other apps). Full runbook + the **simulation dashboard** launch (to watch ZUPT + the EKF↔reachability handoff live) is in §6.

## The single most important test
Drive a **tunnel / GPS-blackout metro route** on the unified simulation dashboard and confirm: the EKF dead-reckons with **ZUPT firing at each station stop** (velocity drift arrested), the **reachability physics net** takes over past the 8 s blackout gate, and the alarm fires **before** the stop. Then repeat the reliability matrix in §2 (process death, reboot, Doze, transfers…). That flow is the entire product.

## Honest state of the app (read before testing)
- **Works:** core arm→track→alarm→arrival; never-late stack (sim-proven); free share loop; Friends' rides + nickname; **Guardian mode**; **custom alarm sounds (Pro-gated)**; ad-free Pro; Report-a-problem + crash-on-next-launch; **home widget** (native, built — *placement/tap needs device verification*).
- **Dropped (were false advertising):** Wear OS, family alarms.
- **Inert by design (zero egress):** the mobility-data pipeline — consented capture + k-anon/DP aggregation are wired, but nothing is transmitted. Telemetry is PII-free local-only unless a telemetry endpoint is configured.
- **Known live issues to expect (details in-section):**
  - **https App Links won't verify yet** — the deployed `assetlinks.json` still has the placeholder package + empty fingerprints (the off-peak Railway redeploy hasn't landed). The `geowake://j/{id}` custom scheme is the working deep-link path today. (§4, §6)
  - Guardian "arrived" send + telemetry HTTP egress only fire from the **foreground isolate** (a background/process-death wake won't send them) — functional, not safety, gaps. (§4, §5)
  - Widget **placement/tap** is unverified on-device. (§1, §3)

## What's on the founder (not you) — see §7
Values to paste (BMC handle, rotated+restricted Maps key, real AdMob ids, Pro price, Play signing SHA, optional telemetry/SMS/domain), accounts to create (Play Developer $25, AdMob, BMC), and strategic calls (pricing, the data-business go/no-go, legal/DPDP, Play track). §7 is decision-grade with recommendations.

---

## Table of contents
1. **UI/UX surface** — every screen + every micro-interaction, with per-screen test checklists
2. **Reliability core** — the never-late stack + every edge case + test matrix (the heart of the product)
3. **Monetization + premium** — entitlement, paywall, ads, the works/gated matrix
4. **Share / social / Guardian** — share loop, deep links, Friends' rides, Guardian
5. **Data / telemetry / diagnostics** — inert data pipeline, telemetry, Report-a-problem
6. **Infra / build / sim / config** — phone, build, the simulation dashboard, Railway, every config value
7. **Business decisions + values + accounts** — everything the founder must decide or provide

---


<div style="page-break-before:always"></div>

---

# Section 01 — UI/UX Surface: Every Screen, Every Micro-Interaction

> For the next agent driving the physical device (ZN5225DML5, `com.geowake.app`) end-to-end.
> This documents the UI **as written in the source** (`lib/screens/`, `lib/widgets/`), not
> as imagined. Where behaviour depends on device state (permissions, ads, Pro entitlement,
> GPS), that is called out so you know what to physically reproduce. **Never** record a PASS
> from the simulation dashboard — a checklist row is only "device-proven" if you saw it on
> ZN5225DML5.

Route table (from `lib/main.dart` `onGenerateRoute`, initialRoute `/splash`):

| Route | Screen | How reached |
|---|---|---|
| `/splash` | `SplashScreen` | App cold start (initialRoute) |
| `/` | `HomeScreen` | After splash; `END TRACKING` (non-arrival); post-arrival `Done`/Home fallback |
| `/preloadMap` | `PreloadMapScreen` | `pushReplacement` from Home after Wake-Me confirm |
| `/mapTracking` | `MapTrackingScreen` | `pushReplacement` from preloadMap; direct from splash on session restore |
| `/paywall` | `GeoWakePaywallScreen` | `ProGate.run` (locked tap) or drawer "Go Premium" |
| `/guardian` | `GuardianSetupScreen` | Drawer "Guardian mode" (Pro-gated via ProGate) |
| `/dataConsent` | `DataSharingConsentScreen` | Drawer "Anonymous data sharing" |
| `/postArrival` | `PostArrivalScreen` | `pushReplacement` from map after arrival alarm `END TRACKING` |
| (pushed, unnamed) | `FriendsRidesScreen` | Drawer "Friends' rides"; deep-link `…/j/{id}` |
| (pushed, unnamed) | `RingtonesScreen` | Drawer "Alarm Ringtones" (Pro-gated) |
| (pushed, unnamed) | `ReportProblemScreen` | Drawer "Report a problem"; crash-report dialog on next launch |

**Cross-cutting facts to reproduce on-device:**
- Every screen is **theme-aware**. Theme is a manual toggle in the drawer (`Dark Mode`/`Light Mode`), persisted in `SharedPreferences` key `gw_dark_mode`. There is **no** system-follow mode — the app boots light unless the user toggled dark. Test both explicitly.
- Two Scaffolds host a **`GatedBannerAd`** in `bottomNavigationBar` (Home = `AdPlacement.routeArming`, MapTracking = `AdPlacement.mapTracking`). It renders `SizedBox.shrink()` (zero height) for Pro, no-fill, or before the ad SDK initialises, and only reserves height once a real ad loads. It retries up to 6 times, every 2s, to close the mount-before-init race. On a free device with fill you should see a banner appear a beat late; on Pro you should see nothing, ever.

---

## 1. SplashScreen (`splash_screen.dart`, route `/splash`)

**Purpose:** brand moment + service init + session-restore router.

**Visual states / animation:**
- `assets/geowake.png` clock logo, **pulsing** scale (`1 ± 0.05·sin`, 2s repeat, `ringController`).
- "GeoWake" title in `GoogleFonts.pacifico`, 36px, **fade + slide-up** (starts 0.4 offset below, `textController`) beginning 800ms after mount.
- Background `scheme.surface`; title colour `scheme.onSurface` (so it flips with theme).

**Logic / transitions:**
- Initialises `ApiClient`, `NotificationService`, `TrackingService` (each try/caught; failures logged, not fatal). Init future is `timeout(8s)`.
- If `TrackingStateStore.isAlarmFired()` → cleans up zombie state (`completeEndTracking(navigateHome:false)`) → `pushReplacementNamed('/')`.
- Else if `TrackingStateStore.isActive()` → loads snapshot; if snapshot/directions missing → cleanup → Home; otherwise `pushReplacementNamed('/mapTracking', arguments:{…})` restoring lat/lng/destination/directions/metroMode/user pos/mode/value. **This is the "app was killed mid-trip and relaunched" path — test it by force-stopping during tracking and reopening.**
- Else normal path: 3s timer → `pushReplacementNamed('/')`.

**No interactive elements.** Micro-interactions are purely time/animation driven.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Cold start, no active session | Logo pulses, title fades/slides in ~0.8s, lands on Home after ~3s | |
| Force-stop app **while tracking**, relaunch | Splash → restores directly to Map Tracking with the same destination/route | |
| Relaunch after alarm was firing when killed | Zombie state cleared, lands on Home (no ghost alarm) | |
| Corrupt/missing snapshot on restore | Falls back to Home, no crash | |
| Toggle device dark mode before launch | Splash still honours the app's stored theme, not system (bg + title recolour only if app theme is dark) | |

---

## 2. HomeScreen (`homescreen.dart`, route `/`) — THE core flow, 1891 lines

The most micro-interaction-dense screen. Layout top→bottom: AppBar (title + Metro Mode switch) · offline banner (conditional) · destination search field · autocomplete dropdown (conditional) · inline mini-map (30% height) · Time/Distance(Stops) toggle · tappable threshold value box · threshold slider · low-battery button (conditional) · **docked Wake-Me bar** (persistent) · gated ad banner (bottomNavigationBar). Body scroll area is wrapped in `AbsorbPointer(absorbing: _isTracking)`.

### 2.1 AppBar
- Title "GeoWake" in Pacifico, size `screenWidth*0.07`.
- **Metro Mode** label + `Switch`. `onChanged` is `null` (disabled) while `_isTracking`. Flipping it changes the Time/Distance toggle's right label from "Distance" → "Stops" and rebuilds slider bounds/divisions.
- Hamburger opens the `SettingsDrawer`.

### 2.2 Offline banner
- Shown only when `_noConnectivity` (amber `Colors.amber.shade700`, wifi-off icon, "Offline mode: using cached routes only"). Driven by `Connectivity().onConnectivityChanged`; treated offline only when **all** interfaces report `none`. Also calls `TrackingService().setOnline(...)` and `_offline.setOffline(...)`.

### 2.3 Destination search + autocomplete (recents dropdown)
- `TextField` (`_searchController`, `_searchFocus`), rounded (radius 24), filled grey; hint "Enter your destination"; search prefix icon; **clear (×) suffix** appears only when text non-empty (tooltip "Clear search"), clears text and re-shows top-3 recents.
- **Focus with empty field** → `_showTopRecentLocations()` shows top-3 recents (each tagged `isLocal:true`).
- **Typing** → `_onSearchChanged` debounced **450ms** → merges local recent matches (case-insensitive `contains`) with remote `PlacesService.fetchAutocompleteResults` (deduped by `place_id`), biased by `_currentCountryCode` + current lat/lng.
- **Blur** → clears `_autocompleteResults`.
- Dropdown is a shrink-wrapped non-scrolling `ListView` in a rounded container (grey[800] dark / white light). Each row: `ListTile` title = description; **recents rows** (`isLocal`) show a trailing circular **× chip** → `_removeRecentLocation` (removes from recents + persists). Tapping a row → `_onSuggestionSelected`: unfocus, clears dropdown, fetches `fetchPlaceDetails(place_id)`, sets selected location + camera to zoom 14, and upserts into recents (max 10, dedup by place_id).
- Recents persist via `RecentLocationsService` (Hive box, flushed on app pause).

### 2.4 Inline mini-map (tap-to-drop-pin, double-tap-zoom, drag)
- `GoogleMap`, height `screenHeight*0.3`, `ClipRRect` radius 12, initial camera `_currentPosition ?? Bengaluru(12.9716,77.5946)` zoom 12.
- Initial marker = "Current Location" (from `_getCurrentLocation`, then reverse-geocoded for country code).
- **Tap** `_handleMapTap`: custom single/double-tap arbitration. A second tap **within 300ms AND within ~40m** = double-tap → `animateCamera` zoom `_lastZoom+1`, cancels pending single-tap. Otherwise a **280ms** debounce fires `_setDestinationFromLatLng`.
- `_setDestinationFromLatLng`: immediately sets destination label "Dropped pin" (responsive even offline), then reverse-geocodes (`ApiClient.geocode`) and updates the label **only if** the user hasn't since picked a different point.
- Selected-destination marker is **draggable** (`onDragEnd` updates `_selectedLocation` lat/lng in place — note: does NOT re-geocode the dragged label).
- `onCameraMove` stores `_lastZoom` (used by the double-tap zoom math).

### 2.5 Time / Distance(Stops) toggle
- Centered Row: `Text('Time')` · `Switch(value:_useDistanceMode)` · `Text(_metroMode ? 'Stops' : 'Distance')`.
- `_useDistanceMode=false` → time mode; `true` → distance (or stops when Metro Mode on). This switch is **NOT** disabled during tracking (only Metro Mode + Wake-Me are), but the body is under `AbsorbPointer` while tracking so taps are swallowed anyway.

### 2.6 Threshold value box + slider (per-mode bounds)
- **Value box** (`GestureDetector`): grey rounded box showing the resolved copy:
  - distance: `Alert me within X.X km`
  - stops (metro): `Alert me X stops prior`
  - time: `Alert me in X min`
  - Tapping opens `_EnterValueDialog` (AlertDialog with numeric `TextField`). Titles/hints per mode: "Enter distance (km)" / "How many stops prior…" (hint "Number of stops (1 - 10)") / "Enter time (minutes)". Decimal keyboard only for distance. On OK, value is parsed and **clamped**; invalid parse → dialog closes with no change.
- **Slider** — bounds/divisions depend on mode:
  - distance: **min 0.5, max 10.0, 19 divisions**, label `X.X`.
  - stops (metro+distance): **min 1.0, max 10.0, 9 divisions**, value snapped via `round()`, label integer.
  - time: **min 1.0, max 60.0, 59 divisions**, label integer.
  - Value box and slider are two views of the same three state fields (`_distanceSliderValue` default 5.0, `_stopsSliderValue` default 2.0, `_timeSliderValue` default 15.0).

### 2.7 Low-battery button
- When `_lowBattery` (battery `< 25%`, from `battery_plus`), a red `battery_alert` icon button appears bottom-right of the form. **Its `onPressed` is an empty closure `(){}` — it is decorative only.** (Concrete finding: taps do nothing.)

### 2.8 Docked "Wake Me!" CTA bar (`_buildWakeMeBar`)
- Persistent bar above the ad banner, top border line. Full-width `ElevatedButton`.
- **Enabled iff** `_selectedLocation != null && _searchController.text.isNotEmpty && !_isLoading && !_isTracking`. Otherwise disabled (greyed).
- While `_isLoading`: shows inline white spinner + "Loading route..." and is non-tappable.
- Tap → `_onWakeMePressed` (see flow below).

### 2.9 The Wake-Me flow (dialogs, sheets, permission prompts)
`_onWakeMePressed` → `_proceedWithDirections`:
1. If no destination → **error AlertDialog** "Destination Missing".
2. Sets `_isLoading`, requests essential permissions (`PermissionService.requestEssentialPermissions` — location etc.). If denied, service shows its own dialog; loading resets. **Reproduce grant + deny paths physically.**
3. **One-time reliability disclaimer** (`_maybeShowReliabilityDisclaimer`): AlertDialog "Please keep a backup alarm" with single "Got it". Persisted via `reliability_disclaimer_shown` — shows **once ever**. (To re-test, clear app data.)
4. Gets fresh/cached (<30s) GPS. No location → error dialog "Location Error".
5. If **Metro Mode**: `MetroStopService.validateMetroRoute`; invalid → "Metro Route Unavailable" dialog.
6. Same-state validation runs but is **advisory only** — cross-state routes are allowed (flagship overnight interstate use case).
7. Fetches directions (`OfflineCoordinator.getRoute`). Total planned duration `> 24h` → "Route Too Long" dialog.
8. If **stops mode**: two-stage validation (`StopLogicEngine.validateThreshold` + `validateThresholdAgainstMetroLegs`); failure → "Invalid Stops Threshold" dialog with the max allowed.
9. **"Ready to sleep?" confirmation bottom sheet** (`_showPreArmConfirmation`): drag-handle, dismissible. Icon `bedtime`, title "Ready to sleep?", line "Arriving at <dest> in ~<eta>", bold wake line resolved to concrete terms:
   - stops: "We'll wake you N stop(s) before <last alighting stop or dest>."
   - distance: "We'll wake you X km before <dest>."
   - time: "We'll wake you N min before <dest>."
   - Buttons: **"Not yet"** (OutlinedButton → abort, stay home) and **"Wake me"** (ElevatedButton, `notifications_active` icon → confirm). Dismissing by drag/scrim = abort.
10. On confirm: persists active/snapshot state, then **reliability preflight** (`ReliabilityPreflightRunner.run` + `showReliabilityPreflightDialog`):
    - `warn` (no exact-alarm, battery optimisation): dialog "Make your alarm more reliable", per-issue **"Fix"** buttons (deep-link to OS settings), single **"Got it"** → proceeds.
    - `block` (notifications disabled): dialog "Your alarm can't wake you yet", **not dismissible by scrim/back**, only **"Cancel"** → **refuses to arm**. (Reproduce by disabling notifications for the app, then arming.)
11. Starts `TrackingService.startTracking`; fires (fire-and-forget) Guardian auto-share, route-memory record, route registration; `pushReplacementNamed('/preloadMap', …)`.
- **General error** anywhere → "Route Error" dialog, resets tracking/loading.

### 2.10 States to reproduce on Home
loading (spinner in CTA), empty (no destination → CTA disabled), error (each dialog above), offline (amber banner + cached-route path), tracking-locked (`AbsorbPointer` — after arming, before nav, body is inert), dark/light, low-battery (decorative button), permission-denied (service dialog).

### 2.11 Home micro-interaction checklist

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Focus empty search box | Top-3 recents dropdown appears | |
| Type 3+ chars, wait ~0.5s | Debounced autocomplete: local recents + Places results, deduped | |
| Tap × in search field | Text clears, recents re-shown | |
| Tap a remote suggestion | Map recenters (zoom 14), pin drops, destination set, added to recents | |
| Tap × chip on a recents row | That recent removed from dropdown and persisted | |
| Single-tap empty map spot | After ~280ms, "Dropped pin" set, then label updates to reverse-geocoded address | |
| Double-tap same spot fast (<300ms, <40m) | Map zooms in one level; no pin dropped | |
| Drag the destination marker | Selected lat/lng follows drop point (label stays prior text) | |
| Toggle Metro Mode ON | Right toggle label reads "Stops"; slider becomes 1–10 (9 div) in distance mode | |
| Toggle Metro Mode while arming/tracking | Switch is disabled (no-op) | |
| Toggle Time↔Distance | Value box + slider swap ranges/labels (time 1–60 / dist 0.5–10 / stops 1–10) | |
| Tap value box | Numeric entry dialog opens; OK clamps to range; garbage input = no change | |
| Drag slider to extremes | Clamps at min/max; stops mode snaps to integers | |
| Wake-Me with no destination | Disabled CTA (can't tap) | |
| Wake-Me first-ever arm | "Please keep a backup alarm" dialog once, then continues | |
| Wake-Me with notifications OFF | Blocking preflight dialog; only Cancel; does NOT arm | |
| Wake-Me with battery-opt/exact-alarm issue | Warn dialog with Fix buttons + Got it; arms after Got it | |
| "Ready to sleep?" sheet → Not yet | Aborts, returns to Home, nothing armed | |
| "Ready to sleep?" sheet → Wake me | Proceeds to preloadMap → map tracking | |
| Dismiss "Ready to sleep?" by drag-down | Same as Not yet (abort) | |
| Cross-state destination (e.g. Delhi→Jaipur) | Arms anyway (no hard block) | |
| Go offline, arm with a cached route | Amber banner; arming succeeds from cache | |
| Low battery (<25%) | Red battery button appears; tapping it does nothing (decorative) | |
| Open drawer while tracking | Drawer opens (AppBar not absorbed); body remains inert | |

---

## 3. PreloadMapScreen (`otherimpservices/preload_map_screen.dart`, route `/preloadMap`)

**Purpose:** warm the Google Map tiles so MapTracking appears instantly (avoids white-map flash).

- Full-screen `GoogleMap` centered on destination lat/lng, `myLocationEnabled:false`, with a centered `CircularProgressIndicator` until `onMapCreated`.
- On map-ready → 300ms timer → `pushReplacementNamed` to `_nextRoute` (default `/mapTracking`) with the same/next args.
- **No interactive elements** (a pass-through). If you can tap or linger here it's a bug.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Arrive from Wake-Me | Brief map + spinner, auto-advances to Map Tracking in ~0.3s | |
| Backgrounding during preload | Timer cancels on dispose; no crash | |

---

## 4. MapTrackingScreen (`maptracking.dart`, route `/mapTracking`) — 1571 lines

**Purpose:** live tracking, ETA/distance, transfer notices, and the **alarm surface**. `PopScope(canPop:false)` — hardware back is intercepted and does nothing (you must END TRACKING).

### 4.1 AppBar
- Title "Metro Tracking" (+ `train` icon) when metro, else "Map Tracking", Pacifico 26.
- **Action: `ShareJourneyAction`** — the FREE viral share button (no entitlement). Icon `ios_share`; flips to `podcasts` (filled) while a share is live. Tap when not sharing → `showJourneyShareSheet`. Tap when sharing → bottom sheet "You're sharing your journey" with **Stop sharing** / **Keep sharing**.

### 4.2 Map area (Stack)
- `GoogleMap` with `_markers` (destination + current, current marker snapped to route) and `_polylines` (segmented by mode: Driving solid blue, Walking dashed blue, Metro Line A green, Metro Line B purple — per the legend).
- **Legend overlay** top, translucent black, Wrap of `_LegendItem`s (line sample + label).
- **Loading spinner** center while `_isLoading` (building polylines).
- **GPS-out banner** (`_gpsEstimating`): deep-orange bottom banner "No GPS (tunnel) — estimating position from motion. Still counting down to <stop>." Triggered when no position for **12s** (`_gpsStaleAfter`), and the current-location marker recolors **orange** ("Estimating position (no GPS)"). Clears on next fix. **Reproduce in a tunnel or by cutting GPS.**
- **Route-switch snackbar**: "Switched route: A → B" on `routeSwitchStream`.

### 4.3 Info block (below map)
- ETA text (e.g. "12 min remaining"); while still "Calculating…" a `PulsingDots` shows beside it.
- Distance text ("X.XX km to destination" / "N m to destination"); PulsingDots until real value.
- Transfer notice (orange): "You'll have to switch routes in N min/sec" when a boundary/pending switch exists.

### 4.4 Alarm / control buttons (two states)
- **Normal state** (`!_finalAlarmActive`): Row of two — **STOP ALARM** (`notifications_off`, enabled only while `AlarmPlayer.isPlaying`, disabled grey otherwise) and **END TRACKING** (error-container red; `stop_circle_outlined`). END TRACKING → `_isEndingTracking`, `AlarmPlayer.stop()`, `completeEndTracking(navigateHome:false)`, `pushReplacementNamed('/')`.
- **Arrival state** (`_finalAlarmActive`, i.e. destination alarm firing and not "allow continue"): centered card "You've reached <dest>" + "Time to get off." + Row:
  - **SNOOZE** (`snooze` icon, secondary-container) — shown only if `!_snoozeUsed`. Silences alarm, keeps tracking, arms a **one-shot 60s** re-alert (`_maybeReAlert` fires the real notification alarm again if session still active), snackbar "Snoozed — we'll re-check in a minute…", then the button disappears (one-time only).
  - **END TRACKING** — stops alarm, `completeEndTracking`, fires `ArrivalHooks.fireArrived(...)` (post-arrival fan-out; consent-gated aggregate self-skips), then `pushReplacementNamed('/postArrival')`.
- Note the two END-TRACKING buttons route differently: normal → Home; arrival → PostArrival.

### 4.5 States to reproduce
loading (spinner), tracking (live ETA/dist updates), GPS-out (orange banner + marker), alarm-playing (STOP ALARM enabled), arrival (SNOOZE/END card), transfer pending (orange notice), route-switch (snackbar), missing args (error dialog "Destination information missing" → pops), dark/light, ad banner (free only). Hardware back = blocked.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Enter tracking | Map fits route bounds, ETA/distance populate (PulsingDots until ready) | |
| Move along route (or simulate) | Marker snaps to route, ETA/distance decrease, traveled polyline trims | |
| Enter a tunnel / cut GPS 12s+ | Orange "estimating" banner + orange marker; countdown continues | |
| GPS resumes | Banner clears, marker returns to default colour | |
| Tap Share (AppBar) not sharing | Share sheet opens; sharing → sheet offers Stop/Keep | |
| While sharing | AppBar icon shows filled `podcasts` state | |
| Alarm fires at threshold | STOP ALARM enables; if final, arrival card with SNOOZE/END | |
| Tap STOP ALARM | Sound + service vibration stop; tracking continues | |
| Tap SNOOZE (arrival) | Alarm silences, snackbar shows, button vanishes, re-alert after 60s if still onboard | |
| Tap END TRACKING (arrival) | Alarm stops, fan-out fires, lands on Post-Arrival screen | |
| Tap END TRACKING (pre-arrival) | Tracking ends, lands on Home | |
| Press hardware back | Nothing happens (PopScope blocks) | |
| Transfer approaching | Orange "switch routes in N" notice appears | |
| Launch map with missing args | Error dialog, pops back | |

---

## 5. PostArrivalScreen (`monetization/post_arrival_screen.dart`, route `/postArrival`)

**Purpose:** the moment after the wake alarm is dismissed. Reached ONLY via `pushReplacement` after teardown. Order: header · FREE share card · last-mile card · optional rewarded strip.

- **AppBar**: title "Arrived", action **"Done"** (`post_arrival_done`) → Home.
- **A. Header**: `check_circle` + card title ("You've arrived at <station> ✓" or "You've arrived") + "Arrived at h:mm" (frozen at first build).
- **B. FREE share card** (secondary-container): "Let them know you made it" + button **"I've arrived — share"** (`post_arrival_share`). Never gated. Flips active shares to arrived, opens OS share sheet. Spinner while `_sharing`; failure → snackbar "Couldn't open share just now".
- **C. Last-mile card** (`PostArrivalCardWidget`): primary/secondary actions built by `PostArrivalService`. Kinds: **ride-hailing** → bottom sheet chooser (Rapido / Namma Yatri / Uber / Ola — generic entry-point URLs, no affiliate ids, no coords) each opening external browser; **food** → Google Maps "restaurants near <station>"; **directions** → Maps search for station; **dismiss** → Home.
- **D. Rewarded strip** (`post_arrival_rewarded_strip`): only if not Pro, monetization ready, ad-cap allows, and policy offers it. "Try GeoWake Pro free / Watch a short video for a free day of Pro." **Watch** → rewarded ad → `grantRewardedDayPass` + snackbar "Pro unlocked for 24 hours ✓". **× dismiss** hides for the session. Reactive to tier — vanishes on unlock.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Arrive at destination + END TRACKING | Post-arrival screen shows with station name + arrival time | |
| Tap "I've arrived — share" | OS share sheet opens; active share flips to arrived | |
| Tap ride-hailing action | Provider bottom sheet (Rapido/Namma Yatri/Uber/Ola); each opens browser | |
| Tap food / directions | Opens Google Maps search in browser | |
| Rewarded strip (free user, cap allows) | Strip visible; Watch → rewarded ad → 24h Pro + snackbar | |
| Tap × on rewarded strip | Strip disappears for session | |
| As Pro user | No rewarded strip; no ads | |
| Tap Done | Returns Home | |
| Bad/empty station arg | Falls back to generic "You've arrived", no crash | |

---

## 6. SettingsDrawer (`settingsdrawer.dart`)

Opened from Home/Map AppBar hamburger. `ListView` of tiles:

1. **DrawerHeader** "Settings" (Pacifico, deep-purple bg).
2. **Dark/Light Mode** — icon+label flip; `toggleTheme()` + close drawer.
3. **Preboarding toggle** (`_PreboardingToggleTile`, SwitchListTile): title "Preboarding alarms" (or "Fire only destination alarm" in metro+time mode). Enabled only when `metroModeEnabled` (else subtitle "Enable Metro Mode to use this", disabled). Persists to `TrackingStateStore.setPreboardingEnabled` / `setDestinationOnlyMetroTimeEnabled`.
4. **Alarm Ringtones** — subtitle "Custom tones (the default alarm is free)". Trailing **ProBadge** unless Pro. `ProGate.run(customSound)` → RingtonesScreen (Pro) or paywall (free).
5. **Friends' rides** — pushes `FriendsRidesScreen`.
6. **Go Premium** — pushes `/paywall` (source drawer).
7. **Guardian mode** — trailing ProBadge unless Pro. `ProGate.run(guardian)` → `/guardian` or paywall.
8. **Anonymous data sharing** — pushes `/dataConsent` (NOT Pro-gated).
9. Divider.
10. **Report a problem** — pushes `ReportProblemScreen`.
11. **Buy me a coffee** — subtitle "Support GeoWake — keeps it ad-light". Opens `kBuyMeACoffeeUrl` externally. **Currently a placeholder `YOUR_HANDLE`** → shows snackbar "Set your Buy Me a Coffee link" instead of opening (deliberate guard). (Concrete finding: not a live link yet.)
12. **Close** — closes drawer.

**Concrete finding — orphaned widgets:** `WidgetSettingsTile` (the home-screen widget enable/disable Pro toggle) is **NOT referenced anywhere in the drawer or any screen** (grep of `lib/` finds no usage outside its own file). `GuardianSettingsSection` is likewise unused (drawer uses its own inline Guardian tile). So on-device **there is no in-app UI to enable/disable the home widget** — the widget's Pro gate + toggle exist in code but are unreachable. Verify against the widget placement work; if the widget is armed only from the launcher, note that arming-consume happens in `HomeScreen._consumeWidgetArm`.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Toggle Dark/Light | Theme flips app-wide, persists across restart | |
| Preboarding toggle (metro off) | Disabled, subtitle prompts to enable Metro Mode | |
| Preboarding toggle (metro on) | Toggles + persists | |
| Alarm Ringtones (free) | ProBadge shown; tap → paywall (source customSound) | |
| Alarm Ringtones (Pro) | Opens RingtonesScreen | |
| Friends' rides | Opens Friends' rides screen | |
| Go Premium | Opens paywall | |
| Guardian mode (free/Pro) | Paywall / Guardian setup respectively | |
| Anonymous data sharing | Opens consent screen (no gate) | |
| Report a problem | Opens report screen | |
| Buy me a coffee | Snackbar "Set your link" (placeholder handle) | |
| Look for a Home-widget toggle | NOT present in UI (orphaned `WidgetSettingsTile`) — confirm expected | |

---

## 7. RingtonesScreen (`ringtones_screen.dart`, Pro-gated)

**Purpose:** pick a custom alarm tone + test the real alarm.

- AppBar "Select Ringtone" (Montserrat).
- **FAB** `FloatingActionButton.extended`: "Test my alarm now" (`alarm`) → fires the **real** production alarm (`NotificationService.showWakeUpAlarm`, `playSound:true`, `allowContinueTracking:true`) + snackbar "Testing your alarm…" (5s, **STOP** action). Auto-stops after 5s. While testing, FAB becomes "Stop test" (`stop` icon). Leaving the screen cancels the alarm (dispose).
- **List** of 11 One-UI `.ogg` tones. Each `ListTile`: leading **Radio** (selection, `groupValue=_selectedRingtonePath`), title (bold when selected), trailing **play/pause** IconButton (preview via `audioplayers`; toggles `_currentlyPlayingPath`). Whole row tappable = select. Selection saved to `selected_ringtone` pref immediately. Selected row has faint primary tint bg.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Tap play on a tone | Preview plays; icon → pause; other previews stop | |
| Tap pause | Preview stops | |
| Tap a row / its radio | Selection moves, bolds, persists to prefs | |
| Tap "Test my alarm now" | REAL alarm fires (sound+vibration+notification), snackbar w/ STOP, auto-stop 5s | |
| Tap STOP in snackbar / "Stop test" FAB | Alarm stops immediately | |
| Leave screen mid-test | Alarm cancelled (no ringing after exit) | |
| Reopen screen | Previously selected tone still checked | |

---

## 8. FriendsRidesScreen (`friends_rides_screen.dart`)

**Purpose:** follower surface — rides you follow, route-relative status (never raw GPS).

- AppBar "Friends' rides". **FAB** "Follow" (`add_link`) → dialog "Follow a friend's ride" with paste field (autofocus). Invalid link → snackbar "That doesn't look like a GeoWake link". Valid → optional **nickname dialog** "Who is this? (optional)" (Skip/Save) → `follow(id, token, label)`.
- **Empty state**: `group_outlined`, "You're not following anyone yet", "Paste or open a friend's GeoWake link…".
- **List**: each ride = `ListTile`, leading `CircleAvatar` (nickname initial or `directions_walk`), title (nickname or route headline), subtitle (headline · N min away), trailing **× "Stop following"** IconButton → `unfollow`. Polls (`startPolling` + 30s repaint tick) so "N min away" stays current.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Open with no follows | Empty state shown | |
| Tap Follow, paste garbage | Snackbar "doesn't look like a GeoWake link" | |
| Tap Follow, paste valid link | Nickname prompt → ride appears with route-relative status | |
| Skip nickname | Ride shows route headline as title | |
| Wait 30s on list | "N min away" line refreshes | |
| Tap × on a ride | Stops following, row removed | |
| Open app via `…/j/{id}` deep link | Auto-follows + opens this screen (via main.dart) | |

---

## 9. GuardianSetupScreen (`guardian_setup_screen.dart`, route `/guardian`, Pro)

- AppBar "Guardian mode". Loading spinner while hydrating.
- Intro row (`shield_outlined` + explainer).
- **If not Pro** (self-guard even if reached directly): locked Card with ProBadge "Guardian mode is a GeoWake Pro feature" + **"Unlock GeoWake Pro"** → paywall.
- **If Pro**: "Guardian contact" — **Name** TextField (word-cap), **Phone** TextField (phone keyboard, filtered to `[0-9+ ]`), **SegmentedButton** SMS / WhatsApp, **"Save contact"** (validates non-empty → snackbar "Guardian contact saved"; `GuardianDenied` → paywall). Divider. **SwitchListTile "Auto-share every commute"** (subtitle "Shares a live link on arm and sends 'arrived safely' on wake") — disabled until a contact is saved (hint "Save a contact first"). Toggle failures: `GuardianDenied` → snackbar or paywall.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Reach as free user | Locked card + Unlock CTA → paywall | |
| Save with empty name/phone | Snackbar "Add a name and phone number" | |
| Phone field | Only digits/space/+ accepted | |
| Save valid contact | Snackbar "Guardian contact saved" | |
| Auto-share toggle before contact | Disabled + "Save a contact first" | |
| Auto-share toggle after contact | Enables; persists | |
| Arm a commute with Guardian on | (Cross-check §2.9) SMS/WhatsApp composer opens with live link | |

---

## 10. DataSharingConsentScreen (`mobility_data_consent_screen.dart`, route `/dataConsent`)

DPDP-style opt-in aggregate consent. AppBar "Anonymous trip stats".

- Sections (copy from `MobilityConsentCopy`): title, "What GeoWake shares", "Why", "Your guarantees", "How we protect it".
- **Age checkbox** (`CheckboxListTile`, leading) — required 18+ self-attestation; disabled once sharing is on or while busy or service unavailable.
- **Sharing SwitchListTile** — cannot turn on without age confirmed (snackbar prompts). `grant()`/`withdraw()` → snackbars. If service not ready, subtitle "GeoWake is still starting up…" and switch disabled.
- Grievance/DPB placeholder contacts at the bottom.
- **Default OFF.** Data pipeline is inert (zero egress) regardless — this only writes the consent record.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Open screen | All sections render; both controls OFF | |
| Toggle sharing without age check | Blocked; snackbar asks to confirm age | |
| Check age, then toggle on | `grant()` runs; enabled snackbar; age box locks | |
| Toggle off | `withdraw()` runs; withdrawn snackbar | |
| Service not ready | Switch disabled with "still starting up" subtitle | |

---

## 11. ReportProblemScreen (`report_problem_screen.dart`)

- AppBar "Report a problem". Explainer (attaches app version + device model + PII-free telemetry, no location/personal data, user chooses target).
- **Note TextField** (3–5 lines, sentence-cap, hint "e.g. the alarm didn't go off near my stop…").
- **"What gets sent"** preview — scrollable monospace `SelectableText` of the diagnostics block (starts "Gathering diagnostics…" then fills from `TelemetryReportBuilder.build`).
- **"Send report"** (`send` icon) → `Share.share(...)` (OS share sheet), subject "GeoWake diagnostics".
- Crash variant (`crashedLastSession:true`) framed as a crash report; reached from the next-launch crash dialog.

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Open screen | Diagnostics preview loads (PII-free), monospace | |
| Type a note | Text entered; note prepended at send time | |
| Tap Send report | OS share sheet opens with diagnostics text | |
| After a crash, relaunch | "GeoWake hit a problem" dialog → Report → this screen (crash-framed) | |

---

## 12. Paywall (`monetization/paywall_screen.dart`, route `/paywall`)

- AppBar "GeoWake Pro". If already Pro → `_AlreadyPro` (verified icon, "You're on GeoWake Pro", **Done**).
- Else: headline "Your commute on autopilot." · **trust strip** (always top): "Your never-late alarm is free forever. Pro adds convenience, not safety." · value rows (Guardian / Custom & escalating alarm / Home widget / Ad-free), the row matching `PaywallSource` **highlighted** (primary-container). · **Unlock forever — <price>** (price from billing or fallback; "Please wait…" while busy). · **"Watch a short video for a free day of Pro"** (rewarded → day-pass) · row of **Restore purchase · Terms · Privacy** (Terms/Privacy open `geowake.app/*` placeholder URLs; no-op if unopenable).
- Buy result → snackbar "Welcome to GeoWake Pro 🎉" (pop) or "Purchase didn't complete…". Restore → "Pro restored ✓" / "No previous purchase found." Rewarded → "Pro unlocked for 24 hours ✓".

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Open from a locked feature | That feature's row is highlighted | |
| Tap Unlock forever | Billing flow; success → welcome snackbar + pop | |
| Tap Watch video | Rewarded ad → 24h Pro snackbar | |
| Tap Restore | Restores or "No previous purchase found." | |
| Tap Terms / Privacy | Opens external URL (placeholder) or silently no-ops | |
| Open while already Pro | "You're on GeoWake Pro" + Done | |

---

## Global / regression checklist

| Interaction | Expected result | Pass/Fail |
|---|---|---|
| Dark ↔ Light across every screen | All screens recolour; no hard-coded unreadable text | |
| Pro vs free across every gated tile | ProBadge + paywall for free; direct access for Pro; no ads for Pro | |
| Ad banner on Home & Map (free, with fill) | Banner appears (a beat late); never overlaps Wake-Me or alarm controls | |
| Ad banner (Pro / no-fill / pre-init) | Zero height, no grey bar | |
| Kill app mid-trip, relaunch | Splash restores into Map Tracking | |
| Deep link `geowake://j/{id}` or `https://…/j/{id}` | Follows ride + opens Friends' rides | |
| Force a crash, relaunch | Crash-report dialog offered once | |
| Buy-me-a-coffee tile | Placeholder guard snackbar (until real handle set) | |
| Home-widget enable/disable | NO in-app control exists (orphaned tile) — confirm intended | |

**Section 01 length: ~350 lines.** Read alongside `docs/HANDOFF_TESTING.md` (device/entitlement setup) before driving.


<div style="page-break-before:always"></div>

---

# 02 — RELIABILITY CORE + NEVER-LATE

> The heart of the product. Everything else (widget, Guardian, share, data, Pro
> tiers) is a garnish on ONE promise: **GeoWake will never wake you late for your
> stop.** This document is the exhaustive, code-grounded map of how that promise
> is built, and — for the next agent with a physical phone — exactly how to try
> to break it, step by step, on **device** and on the **sim dashboard**.
>
> Ground rule for this section, and the whole handoff: **the CI/sim harness
> proves the MATH is never-late; it does NOT prove the PHONE wakes you.** The two
> are cleanly separated in §4. Never claim device proof from a green test run.

---

## 0. Where the code lives (read these, don't invent)

| Layer | File(s) |
|---|---|
| Physics never-late net (pure math) | `lib/core/reachability/reachability.dart` |
| EKF tight-track (GPS+IMU DR) | `lib/core/ekf/ekf_orchestrator.dart`, `ekf_pipeline.dart`, `zupt_detector.dart`, `motion_classifier.dart`, `station_association.dart`, `gps_degradation_detector.dart`, `degraded_mode.dart`, `tilt_filter.dart`, `route_geometry.dart` |
| Fire tunables | `lib/config/fire_decision_config.dart` |
| GPS ingest + accuracy gate | `lib/services/location_manager.dart` |
| Stream loop + dropout tick | `lib/services/tracking/location_stream_handler.dart` |
| Fire decision (all modes) | `lib/services/tracking/alarm_controller.dart` |
| Monotonic clock | `lib/core/clock/app_clock.dart` (`monotonicSeconds()`) |
| Background service / lifecycle / reboot | `lib/services/trackingservice.dart` |
| OS exact-alarm backstop (Android) | `lib/services/notification_service.dart` (`scheduleEtaBackstop`), `lib/services/tracking/notification_updater.dart` (`_maybeRearmEtaBackstop`) |
| iOS backstop planner | `lib/services/ios/ios_backstop_planner.dart` |
| Arm-time preflight | `lib/services/reliability/reliability_preflight_service.dart` |
| Manifest receivers | `android/app/src/main/AndroidManifest.xml` |
| Proof harness | `test/reachability/*`, `test/scale/*`, `test/ekf/replay_harness_test.dart` |

---

## 1. The full ARM → TRACK → ALARM → ARRIVAL lifecycle

This is the real control flow, step by step, as wired today.

### 1.1 ARM (user commits to a trip)
1. User picks a destination + alarm mode (`stops` / `time` / `distance`) and taps
   arm. The UI **should** run the arm-time reliability preflight
   (`ReliabilityPreflightService.check()`), which reads the OS states that decide
   whether this phone can physically wake the rider:
   - `notificationsEnabled` — OFF ⇒ **BLOCK** (the alarm literally cannot appear).
   - `exactAlarmAllowed`, `batteryOptExempt`, `preciseLocation`, DND-bypass,
     full-screen-intent — each maps to a WARN/ADVISORY with a plain-English fix and
     a deep-link action key. On an **aggressive OEM** (Xiaomi/Oppo/Vivo/Samsung/
     Transsion — see `aggressiveOemNeedles`) the battery + exact-alarm warnings are
     escalated. NOTE (`reliability_preflight_service.dart:353`): BACKLOG #20's
     "refuse to arm on aggressive OEM without battery exemption" is deliberately
     left at WARN behind a **one-line founder toggle**, not enforced.
   - **DEVICE-PENDING**: that the arming UI actually *calls* this service and
     surfaces/gates on the verdict. The service itself is pure + unit-tested; wiring
     it to the concrete `ReliabilityProbe` (permission_handler + device_info_plus)
     and to the arm button is an integration step to verify on the phone.
2. `TrackingService.startTracking()` spins up the Android foreground service
   (`_onStart`, `lib/services/trackingservice.dart:215`).
3. **Reachability anchor is seeded at arm time** so the physics net has an honest
   `t0` even for a rider who opens the app already underground with no GPS:
   `AlarmController.seedReachabilityAnchorAtArm()` → `_reach.seedColdStart(tSeconds,
   sMeters)` (alarm_controller.dart:301). This closes the cold-start hole (GAP
   #1/#2): `s_max = s0 + V_LINE·(t − t0)` starts growing on the wall clock the
   instant you arm.

### 1.2 TRACK (steady state, ~1 Hz)
`LocationStreamHandler.start()` (location_stream_handler.dart:185) opens
`LocationManager().positionStream` and starts a periodic **GPS-check timer**
(`_startGpsCheckTimer`). Two independent drivers now run:

- **On each real fix** (`_handlePositionUpdate`, :231): update `_lastGpsUpdate`,
  broadcast to the sim dashboard, feed the sensor-fusion/EKF manager
  (`_sensorFusionManager.updateGps`), compute ETA, ingest into the active-route
  manager, then call `onCheckAlarm` (the AlarmController). A **sequential guard**
  (`_isCheckingAlarm`) prevents overlapping evaluations.
- **On the periodic tick** (`_handleGpsCheckTick`, :451): process notification
  actions, re-post critical notifications, run `_checkGpsDropout`, and — crucially
  — `_maybeEvaluateAlarmDuringDropout` (:575), which drives alarm evaluation from
  the dead-reckoned EKF/physics **when the position stream is silent** (blackout or
  cold-start-underground). It synthesizes a `Position` with the sentinel accuracy
  `9999.0` (`FireDecisionConfig.deadReckonAccuracySentinel`) so downstream code
  refuses to treat it as a real fix, speed = EKF.v.

Every fix that enters `LocationManager._processPosition` (location_manager.dart:217)
passes through:
- **speed normalization** (derived distance/dt vs platform speed, jitter floor,
  spike guard, EMA α=0.2),
- the **accuracy gate** (G27, :311): a real fix worse than
  `accuracyGateMeters` (or the 100 m fallback) is **dropped** (not emitted) and
  `onGpsAccuracyRejected` fires; coarse 'approximate' fixes (> 500 m) are flagged.
  Dropped fixes become a GPS gap ⇒ the EKF/physics take over. **Simulated positions
  bypass the gate.**

### 1.3 ALARM (the fire decision — `AlarmController.checkAndTriggerAlarm`)
Per evaluation (alarm_controller.dart, from :561):
1. **Maintain the physics anchor** (:569–605). Seed cold-start if needed, then
   re-anchor **ONLY on an accepted real fix** (`acc` finite, > 0, and <
   sentinel). The anchor is stamped at the **fix's own acquisition time** (map
   wall-clock fix age into the monotonic frame: `fixTs = nowSec − age`) so a
   late-delivered fix can't shrink `dt` and cause a late fire (precondition iii).
   A dead-reckoned sentinel position **never** moves the anchor.
2. Branch by mode. There are four fire paths, **each independently fed the
   physics bound** so none can fire late:
   - **Distance (non-metro)** — remaining = total − `effProgress`, where
     `effProgress = max(progress, reachBound)` (:1148). Straight-line fallback if
     no route progress.
   - **Time (non-metro)** — fire when `ETA − k·σ_eta ≤ threshold` (critical
     fractile, k=2) **OR** the worst-case reachability ETA lower-bound
     `remaining/V_LINE ≤ threshold` (:1037–1063).
   - **Stops / metro** — `AlarmEvaluator.evaluateCoinciding(...,
     reachableProgressBoundMeters: reachBound)` (:1463), which fires when the
     **effective progress** (max of `deadReckoned + k·σ` and the physics bound)
     passes a stop.
   - **Cold-start-underground backstop** — when there is no dead-reckoned progress
     yet but an anchor exists and a transit leg is known,
     `_maybeFireColdStartReachBackstop` (:317) fires the whole-route worst-case
     bound to the final target.
3. **Blackout gate (FINDING 3):** the physics bound only *overrides* the
   statistical progress once the anchor is at least
   `FireDecisionConfig.reachBlackoutMinSeconds = 8.0 s` stale (a genuine blackout),
   **except** a fire-forcing `+inf` bound (T_max watchdog / corrupt anchor) always
   applies (:955, :1441). Below 8 s the EKF carries the gap and the physics net is
   inert, so a healthy ride does not fire ~`V_LINE·dt` early.
4. **Dispatch:** `triggerAlarmNotification` (:441) posts the full-screen alarm,
   marks the leg/destination fired (idempotent per route key so it can't
   double-fire), and starts the alarm-stop poll timer.

### 1.4 ARRIVAL (post-wake)
Only after the destination alarm has fired, been acknowledged, and
`completeEndTracking()` has torn down the session does the **arrival fan-out** run
(`ArrivalHooks.fireArrived`, arrival_hooks.dart). It is a synchronous, fully
try/caught, `unawaited` fan-out to opt-in data aggregate, Guardian "arrived safely"
multicast, and the ad-frequency counter — **it can never delay, reorder, or abort
the wake** (it runs strictly after it). The OS exact-alarm backstop is cancelled
here and on `_onStop` (`cancelEtaBackstop`, id 991).

---

## 2. The NEVER-LATE STACK — three layers, how they compose

The guarantee is defense-in-depth. Each layer is a **strictly weaker assumption**
than the one above it, so as conditions degrade the responsibility slides down to a
layer that still holds. **Firing is triggered by the layer that fires first** —
i.e. the alarm fires as soon as *any* upper bound reaches the target
(`Reachability.effectiveProgress` = `max(statistical, physics)`).

### Layer 1 — EKF tight-track (the TIGHT cone; best-effort, most assumptions)
Purpose: keep the alarm *tight* (fire close to the true stop, not stops early)
while GPS is healthy or only briefly interrupted. Files: `lib/core/ekf/*`,
`lib/services/sensor_fusion.dart` (deprecated shim wiring the orchestrator).

- **EKF pipeline** fuses GPS position fixes with IMU forward-acceleration
  (tilt-compensated: `tilt_filter.dart` rotates device→world, projects onto the
  route tangent — `_forwardAccel`, ekf_orchestrator.dart:789). State is 1-D
  arc-progress `s` along the route + velocity `v`, with honest σ growth.
- **ZUPT (zero-velocity update)** — `zupt_detector.dart`. When the IMU goes quiet
  the filter clamps velocity drift. Two paths:
  - normal: `imuQuiet (accelVar<1.0, gyroVar<0.40) && v<0.8` **or** motion-hint +
    low v;
  - **ultra-quiet degraded path** (:58, :71): during a GPS blackout the EKF's
    own velocity is untrustworthy (accel-bias drift), so ZUPT triggers on
    `accelVar<0.15 && gyroVar<0.05 && motionHint` **independent of velocity** —
    this is what stops unbounded drift at a station dwell underground.
- **Motion classifier** (`motion_classifier.dart`) — vehicle/stationary/human via
  IMU variance + FFT walk/train band energy. In degraded mode it **skips the
  velocity hard-gate** (velocity is unreliable) and instead breaks false-stationary
  when `recentMaxAFwd > 0.15 m/s²` (train clearly moving), preventing v from
  sticking at 0 during DR.
- **Station-snap** (`station_association.dart`) — on a confirmed ZUPT it snaps `s`
  to the nearest single station within an adaptive window (`3σ + margin`, margin
  shrinks as σ grows to avoid multi-candidate ambiguity). Gated (ekf_orchestrator
  :540): σ after snap ≤ 30 m (≤ 60 m degraded), single candidate, **monotonic**
  station index (never snap backward). This is the discriminator that lets the
  tight cone survive a long tunnel with intermediate stops.
- **GPS degradation detector** (`gps_degradation_detector.dart`) — declares
  `degraded` after 3 bad ticks (no fix ≥ 5 s, accuracy > 50 m, or innovation-σ >
  4.0), recovers after 3 good fixes held ≥ 10 s.
- **Degraded mode** (`degraded_mode.dart`) — trips on σ_s ≥ 150 m (metro override
  2000 m) or no-ZUPT-for-10-min.
- **Frozen-phantom rejection** (ekf_orchestrator `onGpsFixAuto`, :255): an
  off-route projected fix, or a stationary fix (moved < 2 m) while the filter says
  v > 2 m/s (the OS fused provider pinning a confident underground position — proven
  in the corpus: 120 s pinned at 3.79 m), is treated as GPS-unavailable rather than
  anchoring `s` to a lie (which would drive a late fire).

**Assumption set:** IMU is usable, GPS returns at least periodically, snapping
finds real stations. When these hold the alarm is tight. When they don't, Layer 1
gracefully *widens σ* and hands off to Layer 2.

### Layer 2 — Reachability physics net (the SAFETY FLOOR; almost no assumptions)
File: `reachability.dart`. This is the correctness core. It does **not** dead-reckon
through a tunnel. It computes a **worst-case reachable arc-position** from first
principles:

```
s_max(t) = s0_hi + V_LINE · (t − t0)
```
- `s0_hi` = arc-progress of the **last accepted real fix, overbounded forward by
  its accuracy** (`ReachabilityAnchor.sHi`).
- `V_LINE` = a per-line speed **ceiling** that overbounds true max speed
  (`VLineTable`: metro 28 m/s, express/suburban 39, RRTS/Namo Bharat 53, absolute
  56). A too-high ceiling only fires *earlier* (safe); too-low can fire late.
- `t − t0` = **monotonic** wall-clock elapsed since the last *true* fix, reset only
  by a gate-passing fix.

**If the alarm has not fired, the train provably has not reached the target.** No
IMU, gyro, or ZUPT required — holds on any line, even with zero GPS fixes ever
(cold-start anchor at arm). Cost: it fires *early*; the tighter Layer 1 dominates
while GPS is healthy, and the topology/tightening levers reduce "how early".

**Three preconditions** (each a tested load-bearing invariant; every conceivable
late fire violates exactly one):
1. `s0` is a REAL accepted fix, never a phantom (accuracy gate + EKF phantom
   rejection).
2. `V_LINE ≥ true max speed`.
3. `t` is wall-clock elapsed since the last true fix, reset ONLY by a gate-passing
   fix.

**Tightening levers** (reduce early-firing, never risk late):
- **Stop-count topology cap** (`_topologyCappedProgress`) — the train must
  physically pass and dwell (`dwellMinSeconds`) at each intermediate station.
  Safe iff dwell truly lower-bounds a stopping service; defaults to **0** (degrades
  to the unconditionally-safe free-run bound).
- **Fastest-feasible-train profile sweep** (`_fastestFeasibleProgress`,
  `RouteProfile`) — accel ceiling (adhesion 2.5 m/s²), terminal-braking envelope
  (3.5), curve ceiling (Menger curvature with a k·σ noise floor). **INERT by
  default** (`dynamicLeversEnabled=false`, `curveTrusted=false`) — bit-identical to
  free-run until a line's geometry is explicitly validated. Enablement needs
  per-line OSM rail geometry (see MEMORY: reachability-tightening).

**Fail-safe toward firing:** a non-finite anchor position/time/clock, V_LINE = 0/
NaN/negative, or the hard `hardTMaxSeconds` watchdog all return `sMaxMeters =
+infinity` ⇒ every stop counts as reached ⇒ **fire now**. Never-firing is the
cardinal sin; waking early is the safe state. `effectiveProgress` explicitly
propagates a `+inf` reach (a NaN reach — genuinely no info — is the only thing
dropped).

### Layer 3 — OS exact-alarm backstop (the APP-DEATH net; assumes the app is dead)
Assumption: the app process is gone (Doze, OEM kill, swipe-away) and neither Layer
1 nor 2 can run. So the fire time is **pre-scheduled with the OS** while the app is
still alive.

- **Android** (`notification_service.dart:891` `scheduleEtaBackstop` → plugin
  `zonedSchedule` with `AndroidScheduleMode.exactAllowWhileIdle`, id **991**,
  channel `geowake_backstop_channel_v1`). Re-armed on **every ~1 Hz state
  broadcast** (`notification_updater.dart:216 _maybeRearmEtaBackstop`) at
  `ETA − backstopLeadSeconds`, where the lead is derived per-mode and always
  overbounds the real lead (fire early). Cancelled the instant the real alarm fires
  (`cancelEtaBackstop`, and swept on the dead-process path :1685) so it can't
  double-fire.
- **iOS** (`ios_backstop_planner.dart`) — iOS can't run a foreground service, so it
  pre-schedules a local notification at `t_earliest = now + remaining/V_LINE`
  (never-late by physics, same V_LINE ceiling) **plus** two geofence rings
  (destination + N-stops-before) that reliably wake a suspended app on region
  entry. `arm()` isolates each schedule in its own try/catch so one failing net
  never blocks the others.

**Manifest wiring is load-bearing** (AndroidManifest.xml:102–117). `zonedSchedule`
posts via a broadcast the OS delivers to `ScheduledNotificationReceiver`; the
**boot receiver** (`BOOT_COMPLETED` / `MY_PACKAGE_REPLACED` / QUICKBOOT) re-arms
scheduled notifications after reboot; `ActionBroadcastReceiver` handles action
buttons. flutter_local_notifications v16+ **does not auto-declare these** — see
MEMORY: backstop-receivers-gotcha. If they are ever stripped, the backstop is
silently dead. **DEVICE-PENDING**: confirm all three receivers survive release
build + R8/proguard and actually deliver.

### How they compose (one sentence)
While GPS is healthy the **tight EKF cone** decides (physics net inert, < 8 s
anchor age); as GPS degrades the EKF widens σ and the **physics floor** takes over
on the wall clock; if the whole app dies, the **pre-scheduled OS/iOS backstop**
still fires — and every layer only ever fires *at or before* true arrival.

---

## 3. Reliability edge cases — EXACT test steps (device + sim)

For every case: **Sim** proves the logic/math deterministically; **Device** proves
the phone. Do BOTH. Sim = unified simulation dashboard (drives `SimulationClient` →
`LocationManager.injectPosition`, bypasses the accuracy gate). Device = ZN5225DML5,
`com.geowake.app`, adb at `$HOME/Android/Sdk/platform-tools/adb`.

> Pass criterion for ALL cases: the alarm fires **at or before** true arrival at the
> target stop (never after). "Early" is a pass; "late" or "never" is a fail.

### 3.1 GPS blackout / tunnel
- **Sim:** Load a metro route. Let it run healthy to mid-route, then in the
  dashboard stop emitting GPS (or mark tunnel) for a multi-minute segment past a
  couple of stations, then resume near/after the target. Watch the reachability
  cone (`reachabilityActivated` telemetry) grow and fire the stop on time.
- **Device:** Ride (or drive a GPS-spoof route through) a real tunnel, OR toggle
  airplane-mode/location off for 60–120 s mid-trip with screen off. Expect: EKF DR
  first (< 8 s), then physics cone; alarm at/before the stop.
- **Watch:** anchor must NOT reset during the gap (dead-reckon sentinel accuracy
  9999); `dt` grows on monotonic clock.

### 3.2 Doze / battery optimization
- **Sim:** N/A (logic-only). Confirm the exact-alarm backstop is armed each tick
  (`scheduleEtaBackstop` id 991) via logs.
- **Device:** `adb shell dumpsys deviceidle force-idle` to force Doze mid-trip with
  screen off; verify the foreground service survives and/or the exact-alarm
  backstop (id 991) still fires at ETA − lead. Then `adb shell dumpsys deviceidle
  unforce`. Repeat WITHOUT battery-opt exemption to see the aggressive-OEM risk.

### 3.3 Process death (force-stop)
- **Device only:** mid-trip, `adb shell am force-stop com.geowake.app`. The
  foreground service dies. **The exact-alarm backstop (OS-owned) must still fire**
  at its scheduled time — this is the entire point of Layer 3. Verify id-991
  notification appears. This is the acid test that the manifest receivers are live.
- **Also verify snapshot restore:** `TrackingStateStore.saveSnapshot` runs every
  30 s (location_stream_handler.dart:404); on relaunch, `_onStart` null-initialData
  branch (trackingservice.dart:387) restores from snapshot.

### 3.4 Reboot
- **Device only:** arm a trip, then `adb reboot`. On boot, `BOOT_COMPLETED`
  re-arms scheduled notifications (manifest receiver) and `MY_PACKAGE_REPLACED`
  covers app-update. G4: `onForeground=_onStart` re-runs the entrypoint so the
  snapshot-restore path can resume. Verify the backstop survives reboot and the
  journey notification is restored.

### 3.5 Aggressive OEM killers
- **Device:** the test phone's manufacturer — check
  `ReliabilityPreflightService.isAggressiveOem`. If it matches, verify the preflight
  raises the battery/exact-alarm warnings to WARN. Then reproduce a kill: remove
  battery-opt exemption, lock, leave 10+ min. Expect the OS backstop to still wake.
  This is inherently device- and ROM-specific and cannot be simulated.

### 3.6 No network
- **Sim/Device:** disable data + wifi (keep GPS). Directions can't refetch, but
  tracking/EKF/physics are all **offline** (route already loaded). Alarm must still
  fire. Verify no code path awaits a network call in the fire loop.

### 3.7 Transfers / interchanges
- **Sim:** multi-leg route (metro → walk interchange → metro). Confirm no spurious
  pre-boarding/mode-change alarm during the interchange walk (alarm_controller
  treats interchange walk between metro legs as metro context, :1280), and that the
  physics bound uses **max V_LINE over forward legs** (:1403) so a walk→train
  boarding as GPS drops can't under-bound and fire late.
- **Device:** ride an actual interchange; verify only the intended per-leg alarms.

### 3.8 Early arrival / overshoot
- **Sim:** run the train *faster* than schedule, and separately overshoot the
  target (miss the fire). Confirm the alarm still fires at/before the stop (early is
  fine) and idempotency: it fires exactly once per leg/destination
  (`firedLegIds`/`destinationAlarmFired` per route key).

### 3.9 Very short trip
- **Sim:** 1–2 stop trip. Confirm the time-alarm eligibility gate (100 m + 3 ETA
  samples + 30 s, location_stream_handler.dart:685) doesn't suppress a legitimately
  short metro trip — metro journeys bypass the non-metro eligibility gate
  (alarm_controller.dart:966). Verify the alarm still fires.

### 3.10 Permission denials
- **Device:** revoke precise location (approximate only), revoke notifications,
  revoke background location — each individually. Preflight should BLOCK on
  notifications-off and WARN on approximate-only. With approximate-only, real fixes
  > 500 m are flagged and > gate are dropped (accuracy gate), forcing DR/physics.

### 3.11 Accuracy gate + phantom rejection
- **Sim:** N/A (sim bypasses the gate). Unit-tested instead.
- **Device:** in a poor-signal urban canyon, confirm 1–3 km 'approximate' fixes are
  dropped (`onGpsAccuracyRejected` log) rather than snapping the rider wildly
  off-route, and that a frozen confident underground fix is rejected as a phantom
  (EKF `onGpsFixAuto`).

### 3.12 Stale-fix watchdog
- **Sim/Device:** hold GPS silent long enough to exceed any configured
  `hardTMaxSeconds` (currently the ReachabilityConfig used by the controller
  defaults dwell 0 and no hard T_max — the reachesTarget cone is the primary
  driver). Confirm the corrupt-input fail-safe (NaN anchor/clock ⇒ `+inf` ⇒ fire)
  by fault injection in a debug build. The 8 s `reachBlackoutMinSeconds` boundary
  is the handoff point EKF→physics; verify no dead-zone between them.

---

## 4. PROVEN (CI/sim harness) vs DEVICE-PENDING

### PROVEN — deterministic, headless, in CI
Run: `flutter test test/reachability/ test/scale/`. **Result observed this session:
All 63 tests pass; scale run `ran=15 fired=15 never-fired=0 LATE=0`.**

- **Core theorem** (`reachability_test.dart`): `s_max ≥ true progress` for thousands
  of bounded random trajectories; bound grows exactly linearly at V_LINE.
- **Three preconditions are load-bearing**: each is shown to CAUSE a late fire when
  violated (V_LINE too low, anchor planted behind, `t` reset on a non-true tick) —
  i.e. the guarantee is tight, not accidental.
- **Topology cap**: safe upper bound for stopping services, strictly tighter than
  free-run, UNDER-bounds an express that skips dwells (documented precondition;
  free-run with dwell=0 stays safe).
- **T_max watchdog + cold-start**: forces a fire regardless of geometry; the
  cold-start tracker fires with **zero real fixes** (closes GLMT-03).
- **Fire timing on concrete real-line geometry** is always at-or-before true
  arrival across a family of blackout start times/durations.
- **Edge-case battery** (`reachability_edgecases_test.dart`): negative/future/
  overflow/NaN `dt`; V_LINE 0/NaN/±inf → ceiling, monotone-increasing bound;
  accuracy sanitisation (`sHi ≥ sMeters` always); empty/dup/negative/unsorted
  topology; watchdog boundary; `effectiveProgress` never propagates NaN and never
  drops a `+inf` fire-forcing bound; **corrupt (NaN) anchor position now fails SAFE
  (fires), previously suppressed forever** — a fixed defect with a regression test.
- **Tightening** (`tightening_never_late_test.dart`, `tightening_guards_test.dart`):
  never-late on REAL Purple Line geometry with the dynamic levers ON; INERT by
  default is bit-identical to free-run; served-set correctness and curve `aLatEff`
  are load-bearing (a phantom served stop or a comfort-level lateral accel FAIL
  never-late — guard proven by deliberately breaking it).
- **Scale** (`reachability_scale_test.dart`): never-late on every generated route.
- **EKF replay** (`test/ekf/replay_harness_test.dart`): offline replay of recorded
  IMU+GPS corpora (see MEMORY: ekf-validation-harness). Proves the DR/ZUPT/snap
  pipeline behavior on recorded rides.

> NOTE: `test/scale/multi_target_scale_test.dart` is **deleted** in the working tree
> (git status `D`). Only `reachability_scale_test.dart` remains under `test/scale/`.
> If the multi-target scale coverage is wanted, it must be restored/rewritten.

### DEVICE-PENDING — NOT proven by any test; the next agent must verify on ZN5225DML5
The harness proves the **math** is never-late. It cannot prove any of the following,
all of which are physical/OS behaviors:
1. The alarm actually **sounds and shows full-screen over the lock screen** on this
   phone (channel, DND-bypass, full-screen-intent grant).
2. **Exact-alarm backstop (id 991) fires after `am force-stop`** and after `reboot`
   (manifest receivers survive release build + R8).
3. The foreground service **survives Doze** and the specific OEM's battery killer.
4. **Accuracy gate + phantom rejection** behave correctly on real degraded GPS
   (urban canyon, real tunnel) — not just synthetic corpora.
5. The **arm-time preflight is actually wired** to the arm button and the concrete
   probe, and blocks/warns as designed.
6. Real **IMU tilt/bias** on this device keeps the tight cone usable (the replay
   harness uses recorded corpora, not this handset's live sensors).
7. End-to-end **latency**: monotonic-clock behavior across real sleep/wake, and that
   the ~1 Hz re-arm keeps the backstop fresh without churn/battery drain.

---

## 5. Reliability test matrix

Legend: ✔ = covered/pass, ◐ = partial, ✖ = not covered / must-do. **P** = proven in
CI, **D** = device-pending.

| # | Scenario | Sim (P) | Device (D) | Primary layer under test | Pass = |
|---|---|:---:|:---:|---|---|
| 3.1 | GPS blackout / tunnel | ✔ P | ✖ D | EKF DR → physics cone | fire ≤ arrival |
| 3.2 | Doze / battery-opt | — | ✖ D | OS backstop + FGS survival | id-991 fires |
| 3.3 | Process death (`am force-stop`) | — | ✖ D | Layer 3 + manifest receivers | id-991 fires |
| 3.4 | Reboot | — | ✖ D | BOOT_COMPLETED re-arm + snapshot | backstop + restore |
| 3.5 | Aggressive OEM killer | — | ✖ D | preflight WARN + OS backstop | wakes anyway |
| 3.6 | No network | ✔ P | ✖ D | offline EKF/physics | fire ≤ arrival |
| 3.7 | Transfers / interchange | ✔ P | ✖ D | leg logic + max-V_LINE bound | only intended alarms |
| 3.8 | Early / overshoot | ✔ P | ◐ D | idempotency + effectiveProgress | once, ≤ arrival |
| 3.9 | Very short trip | ✔ P | ◐ D | eligibility-gate bypass (metro) | fires |
| 3.10 | Permission denials | ◐ P | ✖ D | preflight + accuracy gate | block/warn correct |
| 3.11 | Accuracy gate + phantom | ✔ P | ✖ D | gate + EKF phantom rejection | bad fix dropped |
| 3.12 | Stale-fix / corrupt-input | ✔ P | ✖ D | watchdog + fail-safe → +inf | fire, never freeze |

**Bottom line for the founder:** the never-late *mathematics* is proven exhaustively
and passes CI (63/63, zero late fires at scale). What remains before you can claim
"it wakes you" is the **device column** — every OS/physical behavior in §4
DEVICE-PENDING, driven end-to-end on ZN5225DML5. Until those are green on the phone,
the honest statement is: *"never-late is proven in principle and in the harness;
device wake-up is pending physical verification."*


<div style="page-break-before:always"></div>

---

# 03 · Monetization & Premium — device test handoff

> Scope: everything money-related in GeoWake — the entitlement model, the single
> Pro paywall choke point, ad policy/serving, and the exact FREE-vs-PRO feature
> matrix with a WORKS / STUB / GATED / DROPPED status per feature. Read this with
> the source open; every claim below cites the file. **Nothing here is device-proven
> — the unit layer is exhaustively tested headless, but real billing, real ad fill,
> and real widget/UPI flows can ONLY be validated on device ZN5225DML5.**

---

## 1. The entitlement model — two ways to become "Pro"

Source of truth: `lib/services/monetization/premium_service.dart`.

`PremiumService` holds entitlement state as two scalars and derives every gate as
a pure getter. It is dependency-injected (a `PurchaseBackend` + a load/save pair,
both defaulting to in-memory), so the whole thing is deterministically unit-testable
with no SDK and no device.

| Path to Pro | Field | How granted | Persistence |
|---|---|---|---|
| **One-time Pro unlock** (lead SKU for India — one-time preferred over subs) | `_proOwned` (bool) | `buyPro()` → `PurchaseBackend.buyOneTime('geowake_pro_onetime')`; or `applyOwnedProducts()`/`restorePurchases()` | permanent |
| **Rewarded "Pro for a day" pass** | `_dayPassExpiryMs` (epoch ms) | `grantRewardedDayPass()` after a rewarded video completes (default 24 h) | expires |

- **`isPro = _proOwned || hasActiveDayPass`** — the single source of truth. `hasActiveDayPass` is `_nowMs() < _dayPassExpiryMs`. Time is injected (`_nowMs`) so expiry is testable.
- `tier` → `EntitlementTier.pro | free`. Product id constant: `PremiumProducts.proOneTime = 'geowake_pro_onetime'`. Persist key: `'geowake_entitlement_v1'`.
- **Fail-closed persistence.** The blob is encoded as `"<0|1>;<expiryMs>"` (dart:core only, no dart:convert). `load()` is STRICT: the flag must be exactly `'0'`/`'1'` and the expiry must match `^-?\d+$` (guards against `int.tryParse(' 100')` resurrecting Pro from a tampered `"1; 100"`). Any malformed/corrupt/unreadable blob → user stays **free**, never throws into startup.
- **Late-purchase safety.** `applyOwnedProducts(owned)` is idempotent and grants Pro when the store delivers ownership asynchronously — the UPI/net-banking case where `buyOneTime` already timed out and returned false but the charge later clears. Without it a paying user is stuck on Free until a manual restore. Wired in `MonetizationService.init` via `_backend.onEntitlementChanged`.
- **THE INVARIANT:** reliability/safety is NEVER gated. `alwaysFreeCapabilities = {coreAlarm, basicReliability, singleActiveRoute, backstopAlarm}` and the getters `canUseCoreAlarm / canUseBasicReliability / canUseBackstopAlarm / canUseSingleActiveRoute` return `true` unconditionally. Gating the alarm would break the trust the product (and the data business) rests on.

### The facade — `MonetizationService` (singleton)
`lib/services/monetization/monetization_service.dart`. The app-level assembler. **UI MUST mutate entitlement through this facade, never `PremiumService` directly**, so the reactive notifier stays in sync.

- `init({backendOverride})` (called once, unawaited, from `lib/main.dart:101`): builds `IapPurchaseBackend`, wires `SharedPreferences` load/save, wires `onEntitlementChanged`, loads entitlement, loads the ride counter, then fires `AdService.instance.init()` unawaited (ad SDK is slow + non-essential — never blocks startup). On ANY exception it falls back to a `FakePurchaseBackend`-backed free premium so the app still runs.
- `tierListenable` (`ValueNotifier<EntitlementTier>`): UI wraps this in `ValueListenableBuilder` so a purchase / day-pass instantly hides ads + unlocks gates with no restart. Kept in sync by `_syncTier()` after every mutation.
- Mutations: `buyPro()`, `restorePurchases()`, `grantRewardedDayPass()`, plus `recordRide()` / `markAdShown()` for the ad frequency counter (persisted under `gw_rides_since_last_ad`).
- `proPriceOrFallback()`: queries store price, falls back to **`proPriceFallback = '₹199'`** so the paywall CTA never blanks.
- `premiumOrNull`: null until `init` completes — callers that mount at first paint (banner widget) use this and the retry loop below.

---

## 2. The paywall choke point — `ProGate` + every `PaywallSource`

Source: `lib/widgets/monetization/pro_gate.dart`. **`ProGate.run` is the SINGLE choke point for every Pro paywall.** A `grep "ProGate.run"` enumerates every gate in the app. The core alarm and basic share are never routed through here — they are free by construction.

```
ProGate.run(context, allowed: <entitlement read>, source: PaywallSource.x, onAllowed: ...)
  allowed == true  → onAllowed()          (feature runs)
  allowed == false → push '/paywall' (arg = source)   (paywall shows)
```

`allowed` is computed at the call site as `MonetizationService.instance.premiumOrNull?.canUseX ?? false` — so a null/loading/expired entitlement resolves to `false` ⇒ paywall shows, never a broken tap. The paywall route `/paywall` is registered in `lib/main.dart:353` → `GeoWakePaywallScreen`.

### Every `PaywallSource` and where it fires (verified call sites)

| `PaywallSource` | Trigger site | Gate read | Behaviour |
|---|---|---|---|
| `customSound` | `settingsdrawer.dart:106` — "Custom tones" tile (shows `ProBadge` when not Pro) | `canUseCustomAlarmSounds` | allowed → `RingtonesScreen`; else paywall |
| `guardian` | `settingsdrawer.dart:151` (drawer tile) + `guardian_settings_section.dart:43` + `guardian_setup_screen.dart:107` (self-guard) | `canUseGuardianMode` | allowed → `/guardian`; else paywall |
| `widget` | `widget_settings_tile.dart:66` + `widget_arm_handler.dart:183 & 208` (arm-from-widget) | `canUseWidget` | allowed → widget setup / arm; else paywall |
| `drawer` | `settingsdrawer.dart:137` — "Go Premium" tile | *(none — direct push)* | opens paywall directly |
| `postArrival` | **Declared in the enum but never triggered** — the post-arrival screen uses a *rewarded strip*, not `ProGate`. Reserved. |

`ProBadge` (a small "PRO" pill) is rendered on the customSound and guardian drawer tiles when `!isPro`.

### The paywall screen — `GeoWakePaywallScreen`
`lib/screens/monetization/paywall_screen.dart`. Reactive on `tierListenable`; if already Pro it renders the `_AlreadyPro` panel. Otherwise:

- **Trust strip ALWAYS at the top:** "Your never-late alarm is free forever. Pro adds convenience, not safety." (headline: "Your commute on autopilot.")
- **Value items** (`_kItems`, the highlighted row matches the incoming `source`):
  1. Guardian mode — "Auto-share your journey with family + an 'arrived safely' alert."
  2. Custom & escalating alarm — "Your own sounds, ramping volume…"
  3. Home widget — "One-tap arm from your home screen."
  4. Ad-free — "No ads, anywhere."
- **CTA:** `Unlock forever — <price>` → `buyPro()` (busy-guarded; success snack "Welcome to GeoWake Pro 🎉" + pop; failure snack, non-fatal).
- **Rewarded fallback:** "Watch a short video for a free day of Pro" → `AdService.showRewarded` → on reward `grantRewardedDayPass()`. Shown only while `isPro == false`.
- **Restore purchase** link → `restorePurchases()` (snack "Pro restored ✓" / "No previous purchase found.").
- **Terms / Privacy** links → `https://geowake.app/terms` and `/privacy` — **PLACEHOLDER URLs** (pages don't exist yet; buttons no-op gracefully if unopenable).

---

## 3. Ad policy — WHERE ads may appear, and where they NEVER can

Source: `lib/services/monetization/ad_policy.dart` — pure, stateless, zero-I/O decision function so the "never compromise the alarm" property is exhaustively unit-testable.

`AdPlacement` enum has 6 values in 2 classes:

| Placement | Class | Ad allowed? |
|---|---|---|
| `routeArming` | ad-eligible, **banner**, uncapped | free users: yes |
| `mapTracking` | ad-eligible, **banner**, uncapped | free users: yes |
| `postArrival` | ad-eligible, **interstitial/rewarded**, frequency-capped | free users: only when `ridesSinceLastAd >= frequencyCapRides` |
| `alarm` | **`alwaysForbiddenPlacements`** | **NEVER — anyone, Pro or free** |
| `wake` | **`alwaysForbiddenPlacements`** | **NEVER** |
| `lockScreen` | **`alwaysForbiddenPlacements`** | **NEVER** |

`canShow(placement, isPro, ridesSinceLastAd)` decision order (fail-closed):
1. `isPro` → **false** (Pro/day-pass removes every ad everywhere).
2. placement in `alwaysForbidden` → **false** (alarm/wake/lock — the reliability guardrail as data).
3. placement not in `adEligible` → **false** (default-deny).
4. capped placement (`postArrival`) → `ridesSinceLastAd >= frequencyCapRides` (`frequencyCapRides = 3`, MONETIZATION §1's "every 3 rides" floor).
5. otherwise (banners) → **true**.

`shouldOfferRewardedUnlock(isPro, dayPassActive)` → offer the opt-in "Pro for a day" only to free users without an active pass.

**Frequency counter wiring:** `recordRide()` bumps `ridesSinceLastAd` on every completed ride, called from `lib/services/tracking/arrival_hooks.dart:112` and `post_arrival_screen.dart:97` (`routeAfterDismiss`). `markAdShown()` resets it to 0 after a capped ad fires (e.g. the rewarded grant in `post_arrival_screen.dart:296`).

---

## 4. Ad serving — banner / interstitial / rewarded, test IDs, the init-race fix

Source: `lib/services/monetization/ad_service.dart` — the concrete `google_mobile_ads` adapter, GATED by `AdPolicy` + `PremiumService` so rules are enforced *by construction*. **Deliberately fail-open: every ad error is swallowed; ads NEVER block or delay the alarm.**

- **Test AdMob unit IDs (Google's official test ids, safe to ship until real ones land):**
  - banner `ca-app-pub-3940256099942544/6300978111`
  - interstitial `ca-app-pub-3940256099942544/1033173712`
  - rewarded `ca-app-pub-3940256099942544/5224354917`
  - **AndroidManifest AdMob APPLICATION_ID is ALSO a TEST id:** `ca-app-pub-3940256099942544~3347511713` (`android/app/src/main/AndroidManifest.xml:35`).
- `configure({banner, interstitial, rewarded})` swaps in real ids — **but `grep` confirms `AdService.configure()` is NEVER called anywhere in `lib/`. Real ad ids are not wired.** (Business value flag — see §7.)
- `init()`: skips non-mobile platforms (Linux/macOS/tests) to avoid an uncatchable `MissingPluginException` on a separate async path; sets `_initialized` only after `MobileAds.initialize()` succeeds.
- `_gate()`: returns false unless `_initialized && mobile-platform && policy.canShow(...)`.
- `createBanner()` → `BannerAd` or **null** (Pro / forbidden / not-init / no-fill). Fail-open: exceptions → null.
- `maybeShowInterstitial()` → post-arrival only, frequency-capped; returns false when forbidden; never throws (`_Once` guards racing callbacks).
- `showRewarded(onReward)` → early-returns if already Pro; invokes `onReward` exactly once on earned reward.

### The banner widget + the init-race retry fix
`lib/widgets/gated_banner_ad.dart`. Because the ad SDK inits **unawaited** at startup, at first paint `premiumOrNull` may be null and `AdService` may be uninitialized ⇒ `createBanner` returns null. The **old bug**: the widget asked exactly once in `initState`; if that was too early the banner stayed blank for the whole session (the reported "test ad disappeared on device"). **The fix:** bounded retry — `_maxAttempts = 6`, `_retryEvery = 2s` — re-attempts `_tryCreate` until the SDK is ready or a real no-fill occurs. Pro users keep getting null and the widget stays **collapsed to zero height** (`SizedBox.shrink()` until a real ad loads — this also fixed the old grey-bar-shown-to-Pro-users stub bug). Timer is cancelled in `dispose`.

**Banner mount points:** `homescreen.dart:1424` (`AdPlacement.routeArming`) and `maptracking.dart:1101` (`AdPlacement.mapTracking`).

### Billing adapter — `IapPurchaseBackend`
`lib/services/monetization/purchase_backend_impl.dart`. **FAIL-CLOSED:** a purchase is reported successful ONLY when the store delivers `purchased`/`restored` on the purchase stream — never on timeout/error/cancel/merely-started. `buyOneTime` waits on a `Completer` with a **5-minute** timeout → false. A long-lived `purchaseStream` listener captures late/pending/restored purchases and fires `onEntitlementChanged` even with no buy in flight (the UPI-clears-late path). Always calls `completePurchase` so the store finalises. `restore()` waits a 2 s beat for async stream delivery. `FakePurchaseBackend` (in `purchase_backend.dart`) drives all headless tests (`simulateLatePurchase`, `buyShouldSucceed`, `throwOnBuy`, etc.).

---

## 5. FREE vs PRO matrix — explicit status per feature

| Feature | Free? | Pro? | Gate getter / mechanism | **Status** |
|---|---|---|---|---|
| Core never-late alarm | ✅ | ✅ | `canUseCoreAlarm` (always true) | **WORKS — always free, never gated** |
| Basic reliability (FGS, exact-alarm backstop) | ✅ | ✅ | `canUseBasicReliability` (always true) | **WORKS — always free** |
| Audible backstop channel | ✅ | ✅ | `canUseBackstopAlarm` (always true) | **WORKS — always free** |
| Single active route | ✅ | ✅ | `canUseSingleActiveRoute` (always true) | **WORKS — always free** |
| Transfer/interchange alarms (multi-leg) | ✅ | ✅ | *(no gate — deliberately free)* | **WORKS — free by design (not a Pro split)** |
| One-off "I've arrived" share (viral loop) | ✅ | ✅ | *(no entitlement check anywhere)* | **WORKS — free by design** |
| **Ad-free** | ❌ | ✅ | `isAdFree = isPro`; `AdPolicy` also honours `isPro` | **WORKS — the one fully-functional Pro benefit** |
| **Custom / escalating alarm sounds** | ❌ | ✅ | `canUseCustomAlarmSounds` → `RingtonesScreen` | **GATED — now gated behind Pro** (was previously free) |
| **Guardian mode** (auto-share + "arrived safely") | ❌ | ✅ | `canUseGuardianMode`; `guardian_service.dart:61` self-gates every mutating call | **WORKS + GATED** (per current build; verify auto-share-on-arm + arrived-via-backend on device) |
| **Home-screen widget** | ❌ | ✅ | `canUseWidget`; `home_widget_bridge.dart` / `widget_render_state.dart` (locked state when not Pro) | **NATIVE-BUILT + GATED** (real native widget; placement/render must be device-verified) |
| Wear OS companion | — | — | *(no getter — comment explicitly forbids re-adding until it ships)* | **DROPPED — must NOT be advertised or gated (false-advertising guard)** |
| Family / shared alarms | — | — | *(no getter — same guard)* | **DROPPED — must NOT be advertised or gated** |
| Snooze | — | — | *(intentionally none)* | **N/A — a wake-before-stop alarm must never be delayable; re-alert-until-ack replaces it** |
| Saved routes / recurring auto-arm / offline packs | — | — | *(none)* | **N/A — position-dependent app; doesn't fit the product** |

Note the paywall advertises exactly the four working/built items (Guardian, Custom alarm, Widget, Ad-free) — it deliberately does NOT list Wear OS or family alarms. Keep it that way until those ship.

---

## 6. Monetization device-test checklist

Run on device ZN5225DML5 (`com.geowake.app`). The paywall test id makes charges free in sandbox; use a real Play sandbox tester account for the billing legs.

**A. Free user sees ads**
1. Fresh install (or clear data) → confirm `EntitlementTier.free`.
2. Arm a route → on the arming screen and map screen, a **test banner** should appear within ~12 s (6 retries × 2 s covers the init race). If it never appears, capture logs — the init-race window is the historical failure.
3. Complete 3 rides → on the 3rd post-arrival screen the **rewarded "free day of Pro" strip** should be eligible (frequency cap `>= 3`). Dismiss (X) hides it for that screen.
4. **NEGATIVE:** during the alarm ring / wake / lock-screen there must be **NO ad, ever** — verify visually and that no ad surface mounts.

**B. Buy Pro → ads vanish + gates unlock (no restart)**
5. Drawer → "Go Premium" → paywall (trust strip on top). Tap `Unlock forever — ₹199` → complete sandbox purchase.
6. Immediately (no restart): banners collapse to zero height on arming/map; paywall shows `_AlreadyPro`; drawer `ProBadge`s disappear; Custom tones → opens `RingtonesScreen` directly; Guardian → opens `/guardian` directly; Widget setup allowed.
7. Kill + relaunch → still Pro (persisted blob `geowake_entitlement_v1 = "1;0"`).

**C. Rewarded day-pass grants then expires**
8. As a free user, on the paywall or post-arrival strip tap "Watch…" → complete the rewarded video → snack "Pro unlocked for 24 hours ✓". Confirm ads gone + gates unlocked immediately.
9. `dayPassExpiryMs` is now +24 h. (Expiry can't be wall-clock-tested on device in one session — the headless test `premium_gates_wave0_test.dart` proves grant-then-expire deterministically via injected `nowMs`.)

**D. Restore purchases**
10. After buying Pro, uninstall + reinstall (or clear data) → open paywall → "Restore purchase" → snack "Pro restored ✓" and Pro re-granted.
11. **NEGATIVE:** on an account that never bought → "No previous purchase found."

**E. Late/pending (UPI) purchase** — *device-only, hard to reproduce*
12. If a sandbox pending/UPI purchase clears after the buy dialog closes, confirm Pro still unlocks via `onEntitlementChanged` → `applyOwnedProducts` (no manual restore needed). This is the highest-risk untested path in India.

---

## 7. Business values REQUIRED before shipping (all currently placeholders)

| What | Current value | Where to set |
|---|---|---|
| **Real AdMob app id** | Google TEST `ca-app-pub-3940256099942544~3347511713` | `android/app/src/main/AndroidManifest.xml:35` |
| **Real AdMob banner/interstitial/rewarded unit ids** | Google TEST ids, hardcoded | `ad_service.dart` `_testBanner/_testInterstitial/_testRewarded`; must call `AdService.configure(...)` (**never called today**) — decide remote-config vs build-time |
| **Real Pro price + Play Console SKU** | product id `geowake_pro_onetime`; fallback price hardcoded **₹199** | Play Console SKU list price must match `MonetizationService.proPriceFallback`; live price comes from `queryPrice` |
| **Privacy & Terms pages** | placeholder `https://geowake.app/privacy` and `/terms` (don't exist) | `paywall_screen.dart:18-19` |
| **Last-mile affiliate ids** (post-arrival ride-hailing CTA) | generic entry-point URLs only (Rapido / Namma Yatri / Uber / Ola), no affiliate ids | `post_arrival_screen.dart` `_showRideChooser` |

**Bottom line:** the monetization *logic* is complete, fail-safe, and heavily unit-tested (`test/monetization/*` — ad policy, frequency cap, decline/throw leak-no-entitlement, late-UPI grant, day-pass expiry, restore). The monetization *revenue* is inert until real AdMob ids, a real Play SKU price, and the affiliate/legal URLs are supplied, and until banner fill, the full billing flow, and the native widget are verified on device.


<div style="page-break-before:always"></div>

---

# 04 — Share / Social / Guardian

Exhaustive device-test handoff for GeoWake's sharing surfaces: the free viral
"Share ride status" loop, deep-link open (custom scheme + https App Link),
"Friends' rides" (the follower side), and Guardian mode (Pro). Every claim below
is traced to source. **Simulation never proves any of this — drive it on device
ZN5225DML5 (`com.geowake.app`).**

---

## 0. Architecture at a glance (read this first)

Two independent halves, both **completely off the arm → track → alarm spine** and
both **fail-safe** (every method swallows its own errors and returns a safe
default):

| Half | Service | Persists | Backend need |
|------|---------|----------|--------------|
| **Sharer** (I broadcast) | `JourneyShareService` (`lib/services/share/journey_share_service.dart`) | `gw_share_sessions` Hive box | Basic link works fully offline; live pings need HTTP backend |
| **Follower** (I watch a friend) | `FollowedRidesService` (`lib/services/share/followed_rides_service.dart`) | `gw_followed_rides` Hive box (id/token/**local nickname only**) | Needs `ShareStatusReader`; offline shows "Waiting…" |
| **Guardian** (Pro auto-share) | `GuardianService` (`lib/services/share/guardian_service.dart`) | `gw_guardian_contacts` + `gw_guardian_enabled` | Reuses sharer; arrived push via backend |

**Transport is pluggable** (`live_share_backend.dart`):
- `NoopShareBackend` — DEFAULT, `supportsLive == false`, everything offline.
- `HttpShareBackend` — maps onto the Railway server; also implements
  `ShareStatusReader` (the follower read side).

**Wiring** (`lib/main.dart`, all fire-and-forget in `main()` / `initState`):
- `ShareBackendConfig.configure()` (line ~124) sets the sharer backend + domain
  and attaches the follower reader, then `FollowedRidesService.init()`.
- `JourneyShareService.bindTracking<Position>(TrackingService().locationStream, …)`
  (line ~128) relays coarse position to any active live share. `ingestLocation`
  self-gates on an active share, so it is inert otherwise.
- `GuardianService.instance.init()` (line ~107) loads state + registers the
  post-alarm "arrived" observer.
- `_initShareDeepLinks()` (line ~190) subscribes to `app_links` and routes every
  inbound Uri through `_handleShareLink` → `FollowedRidesService.follow` → push
  `FriendsRidesScreen`.

### Backend config — current defaults (`share_backend_config.dart`)
- `GEOWAKE_SHARE_BASE_URL` default `https://geowake-share-production.up.railway.app`
  → **`isLiveConfigured` is TRUE by default**, so a stock build uses
  `HttpShareBackend`, not Noop. Live pings/follow are ON out of the box.
- `GEOWAKE_SHARE_TOKEN` default `''` → no bearer token in the app. **The
  deployed server currently accepts unauthenticated writes** (it warns
  `SHARE_AUTH_TOKEN is empty — /v1 write routes are OPEN` at startup if unset).
  Verify on device whether the server has a token set; if it does, the app (no
  token) will get 401 on every `/v1` call and the live path silently fails
  (basic share still works — it is client-only).
- `GEOWAKE_SHARE_DOMAIN` default = `ShareLinkBuilder.defaultDomain` (same Railway
  URL) → this is the host baked into the `/j/{id}` links AND the manifest App
  Link intent-filter host.

> Live probe (2026-07-19): `GET /` → `{"service":"geowake-share","status":"ok","active":0}`.
> The service is up. Note it runs with **app-sleeping / scale-to-zero on idle**
> (commit `fece976`) — the first request after idle incurs a cold-start delay
> ("peak-hour redeploy caveat" below). Warm it before timing tests.

---

## 1. Share ride status (FREE viral loop)

### Where it lives
- **Tracking screen AppBar action**: `ShareJourneyAction(destLabel: _destinationName)`
  at `lib/screens/maptracking.dart:1094`. Icon flips `Icons.ios_share` →
  `Icons.podcasts` while a share is live (bound to
  `JourneyShareService.instance.isSharing`).
- **Bottom sheet**: `showJourneyShareSheet` (`lib/widgets/share/share_sheet.dart`).
- **Post-arrival**: `_shareArrived` (`lib/screens/monetization/post_arrival_screen.dart:168`)
  builds an "arrived" message and calls `markArrived()`.

**No entitlement check anywhere on this path** (test-enforced:
`test/share/share_journey_action_widget_test.dart`). Any user, one tap.

### Message format — EXACT (test-enforced, `share_link_builder.dart:57`)
```
On my way[ to <destLabel>][ — arriving ~h:mm] · GeoWake
<url>
```
- No dest + no ETA → `On my way · GeoWake\n<url>`.
- "GeoWake" is ALWAYS present. **No PII** — no names, no coordinates; only the
  opaque session id in the URL.
- ETA is `h:mm` local (`formatEta`), e.g. `8:42`, `14:05`.
- Arrived message (`buildArrivedMessage`): `I've arrived safely[ at <dest>] · GeoWake`.

> ⚠️ Copy drift to verify on device: the in-sheet **preview** (`_statusPreview`
> in `share_sheet.dart`) hand-rolls the ETA as `${hour}:${minute}` — it does NOT
> pad the hour the way `formatEta` pads minutes, and it is a separate code path
> from the actual shared text. Preview vs. sent text can differ cosmetically;
> confirm the SENT message matches the spec above.

### The `/j/{id}` link (`share_link_builder.dart`)
- `buildShareUrl` → `https://<domain>/j/<uuid-v4>?t=<hmac>`.
- `?t=` is an **HMAC-SHA256(id) hex token** minted with a per-device secret
  (`gw_share_secret` in SharedPreferences, generated once). It makes the link
  tamper-evident but the server only verifies it **if `HMAC_SECRET` is set
  server-side AND aligned to the device secret** — which it is NOT in this
  client-first design, so `?t=` is currently opaque and the unguessable id is the
  real capability gate. Do not expect 403s on a mangled `?t=` today.
- Install fallback (`buildInstallFallbackUrl`) is a Play link with
  `referrer=share_<id>` — built but note the recipient page's "Get GeoWake" CTA
  is the actual install path the server renders.

### Device test — share
1. Arm any journey → tracking screen. Tap the **share icon** (top-right).
2. Sheet shows a status preview + "Share ride status". Tap it → **OS share sheet**
   opens (share_plus). Pick WhatsApp/SMS/Messages.
3. Confirm the sent text matches the format spec and carries a
   `https://geowake-share-production.up.railway.app/j/<id>?t=<hex>` link.
4. Back on the tracking screen the icon is now `Icons.podcasts` (filled/live).
   Tap again → "You're sharing your journey" sheet → **Stop sharing** calls
   `revokeAll()` and the icon reverts.
5. Open the `/j/<id>` link in a **plain browser** (recipient without app): the
   Railway server renders a self-contained status page ("On the way to …",
   "N min away" or "Waiting for the first location update…", coarse
   `lat,lng` to 5 dp with an "Open in Maps" link, and a "Get GeoWake" CTA).
   After arrival/expiry it renders the **410 "This journey link has ended"** page.

---

## 2. Deep-link open

Two intent-filters on `MainActivity` (AndroidManifest.xml), both parsed by
`ShareDeepLinkParser.parse` (`share_deep_link.dart`) into `{id, token}`:

| Form | Verification | Status |
|------|--------------|--------|
| `geowake://j/{id}?t=…` (custom scheme, host `j`) | none | **Works now** — the interim/testing entry point |
| `https://geowake-share-production.up.railway.app/j/{id}?t=…` (App Link, `autoVerify="true"`, `pathPrefix="/j"`) | needs assetlinks | **Currently will NOT verify — see below** |

Opening either → `_handleShareLink` (main.dart:201) → `FollowedRidesService.follow(id, token)`
→ pushes `FriendsRidesScreen`. Fail-safe: a non-GeoWake Uri returns null and is ignored.

### Exact adb test — custom scheme (works today)
```
$HOME/Android/Sdk/platform-tools/adb -s ZN5225DML5 shell am start -a android.intent.action.VIEW \
  -d "geowake://j/testride123?t=abc" com.geowake.app
```
Expected: app opens on **Friends' rides**, a row `testride123` appears with
"Waiting for updates…" (no backend record for that id, so it stays waiting — that
is correct fail-safe behavior). Try a real id from your own share (§4) to see a
live status.

To exercise the https path through the OS resolver (chooser may appear if
unverified):
```
$HOME/Android/Sdk/platform-tools/adb -s ZN5225DML5 shell am start -a android.intent.action.VIEW \
  -d "https://geowake-share-production.up.railway.app/j/testride123" com.geowake.app
```

### 🔴 App Links (https) verification state — BLOCKER to verify/fix
The manifest App Link host is `geowake-share-production.up.railway.app` and the
app package is **`com.geowake.app`**. But the **live** `/.well-known/assetlinks.json`
(probed 2026-07-19) returns:
```json
[{"relation":["delegate_permission/common.handle_all_urls"],
  "target":{"namespace":"android_app",
            "package_name":"com.example.geowake2",
            "sha256_cert_fingerprints":[]}}]
```
Two defects: (1) **wrong package** — `com.example.geowake2` (the old id), not
`com.geowake.app`; (2) **empty `sha256_cert_fingerprints`**. Android App Links
**cannot verify** against this, so tapped https `/j` links will show a chooser /
open in browser instead of launching the app directly. The **custom
`geowake://` scheme is the working path today.**

To fix (founder, server-side env → redeploy): set `ANDROID_PACKAGE=com.geowake.app`
and `ANDROID_CERT_SHA256=<this build's signing SHA-256, colon-hex>` on the Railway
service (the server templates assetlinks from these — `assetlinksJson`,
server.js:409). Get the fingerprint from the installed build:
```
$HOME/Android/Sdk/platform-tools/adb -s ZN5225DML5 shell dumpsys package com.geowake.app | grep -iA2 signing
# or from the keystore: keytool -list -v -keystore <ks> -alias <alias> | grep SHA256
```
Then re-verify on device:
```
$HOME/Android/Sdk/platform-tools/adb -s ZN5225DML5 shell pm verify-app-links --re-verify com.geowake.app
$HOME/Android/Sdk/platform-tools/adb -s ZN5225DML5 shell pm get-app-links com.geowake.app
# host should read "verified"
```
**Peak-hour redeploy caveat:** the service scale-to-zero sleeps on idle; the
Android verifier fetch (and your curl) can hit a cold start and time out,
recording the host as unverified. Warm the endpoint first
(`curl https://geowake-share-production.up.railway.app/.well-known/assetlinks.json`),
then re-verify. Also re-run `--re-verify` after any redeploy.

---

## 3. Friends' rides (follower)

### Where it lives
- Screen: `lib/screens/friends_rides_screen.dart`. Reached from the settings
  drawer ("Friends' rides", `settingsdrawer.dart:122`) and from any deep-link open.
- Service: `FollowedRidesService` (polls every **20 s**; screen also repaints
  every 30 s so the "N min away" line stays current).

### Add-by-link + optional LOCAL nickname
- FAB "Follow" → dialog "Paste a GeoWake link". Accepts `geowake://…` or
  `https://…/j/{id}` (parsed by `ShareDeepLinkParser`); a non-link shows
  "That doesn't look like a GeoWake link".
- Then an **optional** "Who is this? (optional)" nickname prompt (e.g. "Amma",
  "Rahul"). **The nickname is stored ONLY on this device** (`FollowedRide.label`,
  persisted in `gw_followed_rides`) and is **never sent to the backend** — the
  share model carries no identity. With a nickname the tile title is the name and
  the route status is the subtitle; without one the route-relative headline is the
  title.

### Route-relative status — NEVER raw GPS (privacy by construction)
`FollowedRideFormat` (pure) renders only:
- `Waiting for updates…` (followed, not yet polled)
- `On the way to <dest> — arriving ~8:42` / `On the way`
- `N min away` / `Arriving now` (sub-line, from ETA only)
- `Arrived safely at <dest>`
- `Link expired` (410/expired) / `Sharing stopped` (revoked)

Coarse `lat/lng` DO arrive in the `ShareStatusView` but are held **in memory
only, never persisted, never rendered** to the follower (models comment +
`followed_rides_service.dart` header). Only the record `{id, token, addedAtMs,
label?}` touches disk (`toRecordJson`).

### Device test — Friends' rides
1. Drawer → **Friends' rides**. Empty state: "You're not following anyone yet".
2. FAB **Follow** → paste a link from §1 → optional nickname → row appears.
3. Watch it move through "Waiting…" → "On the way to …" → "N min away" →
   "Arrived safely" as the sharer's journey progresses (needs a live backend
   record — see the self-follow walkthrough §5).
4. Swipe/tap the **✕** ("Stop following") → row removed (local unfollow only;
   nothing sent to backend).
5. Confirm **no coordinates ever appear** anywhere on this screen.

---

## 4. Guardian mode (Pro)

### Gating + entry
- Setup screen: `lib/screens/guardian_setup_screen.dart`, route `/guardian`.
- Entries: settings drawer "Guardian mode" (`settingsdrawer.dart:142`, ProBadge
  when not Pro) and `GuardianSettingsSection` widget — both go through the single
  `ProGate.run` choke point → paywall (`PaywallSource.guardian`) when not Pro.
- **Every mutating `GuardianService` call is Pro-gated underneath** (`_requirePro`
  → throws `GuardianDenied` → UI routes to paywall). Reads are always safe.
- Default state is **OPT-OUT**: `enabled == false`, no contact. A fresh Pro user
  shares nothing until they save a contact AND toggle "Auto-share every commute".
- Contact entry is **manual** (name + phone, SMS/WhatsApp segmented toggle) — no
  contacts permission/package required.

### Auto-share on ARM → composer at ARM only
- Hook: `GuardianService.onJourneyArmed(destLabel, eta)` called at
  `lib/screens/homescreen.dart:1049`, **fire-and-forget, AFTER `startTracking()`
  already returned** — it cannot delay/reorder/fail the spine. Self-gating:
  no-ops unless Pro + enabled + contact set (`isActiveGuard`).
- On arm it starts a `ShareMode.guardian` session (reusing
  `JourneyShareService.startBasicShare`) and calls `_notifyContact(message)`,
  which **composes the tracking link into the user's OWN SMS/WhatsApp app,
  pre-addressed to the saved contact — the USER taps send.** GeoWake never sends
  a message itself.
  - Composer URIs (`composeDeepLink`): WhatsApp → `https://wa.me/<digits>?text=…`;
    SMS (and the not-yet-built `app` channel) → `sms:<number>?body=…`. Manifest
    `<queries>` whitelists `sms`, `smsto`, `https` so `url_launcher` can resolve
    these on Android 11+.

### Arrived via backend `markArrived` — NO composer over the alarm
- The "arrived" trigger hangs off **`PostAlarmMulticast`** (registered in
  `init()` → `registerPostAlarm`), invoked on its own microtask **AFTER the wake
  is already raised**. It **never** hooks the synchronous pre-alarm
  `onDestinationAlarmFired` path, so a Guardian failure can never delay/abort the
  ring.
- `_deliverArrived` calls `_share.markArrived()` (which flips sessions to arrived
  and pushes the backend `POST /v1/share/{id}/arrived` for each — the server-side
  "arrived safely" signal the follower/recipient page sees). It **deliberately
  does NOT pop the user's SMS/WhatsApp composer at arrival** — that would surface
  OVER the just-fired wake alarm and Android 12+ background-launch limits would
  block it anyway. The backend status is the arrival signal.

### Auto-sender is INERT (business-gated)
- `GuardianAutoSender` (`autoDeliverySender`) is a config placeholder,
  **`null` by default** — GeoWake ships **no SMS gateway** (no Twilio/WhatsApp
  Business/FCM). Only if a founder wires it does delivery happen without user
  mediation (and it is the ONLY thing allowed to deliver at arrival). Until then:
  ARM composes into the user's own app; ARRIVAL is backend-status only.

### Device test — Guardian
1. Ensure the build is **Pro** (or use the debug entitlement path). Drawer →
   **Guardian mode**.
2. Non-Pro check first: on a free build the row shows a ProBadge and tapping
   lands on the paywall (`PaywallSource.guardian`); the setup screen itself shows
   the locked card if reached.
3. Pro: enter name + phone, pick **SMS** or **WhatsApp**, **Save contact**
   ("Guardian contact saved"). Toggle **Auto-share every commute** ON (blocked
   with "Pick a Guardian contact first" if no contact).
4. Arm a real journey. **At arm**, your own SMS/WhatsApp composer should open,
   pre-addressed to the contact, pre-filled with the `On my way … · GeoWake\n/j/…`
   message. **You tap send.** (If nothing opens, check `url_launcher` resolved the
   scheme — see manifest `<queries>`.)
5. Let the journey run to the wake alarm. Confirm **NO composer pops over the
   alarm**. The follower/recipient page for that share should flip to "Arrived
   safely" (backend `markArrived`).

---

## 5. Full "share to yourself and follow" walkthrough (single device)

This exercises the entire live loop end-to-end on one phone.

1. **Warm the backend** (avoid cold-start):
   `curl -s https://geowake-share-production.up.railway.app/ ` → expect
   `{"status":"ok"}`.
2. Arm a journey on device ZN5225DML5. On the tracking screen tap the **share
   icon** → **Share ride status** → in the OS share sheet pick **Messages/Notes**
   (anything that lets you copy the text). Copy the `/j/<id>?t=<hex>` link.
3. Confirm the share registered server-side: the recipient page should be live —
   `curl -s "https://geowake-share-production.up.railway.app/v1/share/<id>/status"`
   (add `-H "authorization: Bearer <token>"` **iff** the server has a token set;
   if you get 401, the server is token-gated and the stock app — no token — cannot
   read either). Expect JSON `{status:"enRoute", destLabel, etaEpochMs, lat, lng, atMs}`.
4. **Follow yourself:** drawer → **Friends' rides** → **Follow** → paste the copied
   link → optional nickname "Me". The row should leave "Waiting…" within ~20 s
   (poll interval) and show "On the way to <dest> — arriving ~h:mm" / "N min away".
   Coordinates must **not** appear.
5. As you move (or replay a route), confirm the row's ETA/"N min away" updates.
   The live pings come from `bindTracking` → `ingestLocation` (throttled to 15 s,
   coarse 5 dp).
6. Reach the wake alarm (or tap post-arrival **Share arrived**): the row flips to
   **"Arrived safely at <dest>"**. Let the share TTL lapse (default 6 h) or revoke
   via the live share sheet → the recipient page returns the **410 ended** page
   and the follower row shows **"Link expired"**.
7. Deep-link re-entry: send the `geowake://j/<id>` form to yourself and tap it
   (or use the adb command in §2) → app opens directly on Friends' rides with that
   ride.

---

## 6. Known gaps / caveats (do not re-discover these)

1. **App Links https verification is broken today** — deployed `assetlinks.json`
   has the wrong package (`com.example.geowake2`) and empty cert fingerprints
   (§2). Tapped https `/j` links won't auto-open the app; the `geowake://` custom
   scheme is the working path. Fix = server env `ANDROID_PACKAGE` +
   `ANDROID_CERT_SHA256`, redeploy, `pm verify-app-links --re-verify`.
2. **Guardian "arrived" only fires in the foreground isolate.** The trigger is
   `PostAlarmMulticast`, an in-process observer registered by
   `GuardianService.init()`. If the wake is delivered while the app's Dart isolate
   is dead (pure OS-scheduled backstop notification after process death), the
   in-app `markArrived`/arrived push may not run until the app is next opened.
   Verify behavior when the alarm fires cold. (The backend TTL still expires the
   share regardless.)
3. **Backend auth mismatch risk.** App default `GEOWAKE_SHARE_TOKEN` is empty. If
   the Railway service has `SHARE_AUTH_TOKEN` set, all `/v1` writes/reads from the
   stock app get 401 → live pings + follower reads silently fail (basic share, a
   client-only path, still works). Confirm the server's token state on device.
4. **`?t=` HMAC is not server-verified** in this client-first design (server
   `HMAC_SECRET` unset / not aligned to per-device secret). The unguessable share
   id is the real capability gate; do not expect tamper rejection today.
5. **Scale-to-zero cold starts** (commit `fece976`): first request after idle is
   slow — affects both the recipient page load and App-Links verifier fetches.
   Warm before timing/verifying.
6. **Preview vs. sent copy drift** in the share sheet (§1) — the in-sheet ETA
   preview is a separate, unpadded code path from `formatEta`; the SENT message is
   the spec-correct one.
7. **`app` Guardian channel** is declared (`GuardianChannel.app`) but has no
   in-app transport — it falls back to the SMS composer.

---

## 7. Source index (for the next agent)

- `lib/services/share/journey_share_service.dart` — sharer: sessions, start/revoke,
  `ingestLocation`, `bindTracking`, `markArrived`.
- `lib/services/share/journey_share_models.dart` — `ShareSession`, `ShareSnapshot`
  (5 dp, **no trajectory** — test-enforced), `ShareStatusView`, `GuardianContact`.
- `lib/services/share/share_link_builder.dart` — pure message/URL/HMAC builder
  (exact copy format).
- `lib/services/share/share_deep_link.dart` — pure Uri parser (both forms).
- `lib/services/share/live_share_backend.dart` — `ShareBackend` / `ShareStatusReader`,
  `NoopShareBackend`, `HttpShareBackend`.
- `lib/services/share/share_backend_config.dart` — the one wiring/config point.
- `lib/services/share/followed_rides_service.dart` — follower: `follow`/`unfollow`,
  polling, `FollowedRideFormat`.
- `lib/services/share/guardian_service.dart` — Pro gating, arm/arrived hooks,
  composer URIs, inert auto-sender.
- `lib/screens/friends_rides_screen.dart`, `lib/screens/guardian_setup_screen.dart`.
- `lib/widgets/share/share_journey_action.dart`, `share_sheet.dart`,
  `guardian_settings_section.dart`.
- `backend/share/server.js` — zero-dep Node service (latest-only, TTL hard-delete,
  coarse-on-read, bearer auth, rate limit, recipient page, assetlinks). Contract:
  `docs/share/BACKEND_CONTRACT.md`. Tests: `backend/share/server.test.js`,
  `test/share/*`.
- Wiring: `lib/main.dart` (~107 Guardian init, ~124 backend configure, ~128
  bindTracking, ~190 deep links); `lib/screens/homescreen.dart:1049` (Guardian
  onJourneyArmed); `lib/screens/maptracking.dart:1094` (share action);
  `lib/screens/monetization/post_arrival_screen.dart:174` (markArrived);
  `lib/screens/settingsdrawer.dart` (drawer entries).


<div style="page-break-before:always"></div>

---

# 05 — Data / Telemetry / Diagnostics

**Audience:** the next agent, driving the physical device (ZN5225DML5, `com.geowake.app`)
and reading the actual source. This section covers three separate, unrelated subsystems that
are frequently confused:

| Subsystem | What it is | Ships as | Egress today |
|---|---|---|---|
| **Mobility data asset** | Opt-in aggregate origin→destination travel-flow statistics (the future "sellable" surface) | **INERT**, consent default **OFF** | **ZERO bytes** — `NullEgressSink`, doubly gated |
| **Telemetry** | PII-free reliability funnels (did the alarm fire on time?) written to local JSONL | Local-only by default | **ZERO bytes** — no HTTP sink unless a `--dart-define` URL is supplied |
| **Report-a-problem / diagnostics** | User-initiated bug report + crash-on-next-launch prompt | Working | **User-initiated only** — via the OS share sheet, never silent |

> **Hard rule for this whole section:** never claim device proof from the simulation dashboard.
> Everything below has *deterministic unit-test proof* of inertness; the device steps below prove
> the *UI and capture wiring* work, not that "data was sold." Nothing is sold, nothing egresses.

---

## 1. The opt-in mobility data pipeline

### 1.1 Architecture (read the code, don't trust this diagram)

```
COMPLETED trip (END TRACKING tapped, alarm already fired + torn down)
   └─ maptracking.dart:1362  ArrivalHooks.fireArrived(originLat/Lng, destLat/Lng, …)
        └─ arrival_hooks.dart:90  unawaited(DataAssetPipeline.instance.onTripCompleted(...))
             │  (only if BOTH endpoints non-null)
             └─ data_asset_pipeline.dart
                  (1) if (!consent.isSharingEnabled) return;   ← LINE ONE, default OFF
                  (2) binner.bin(origin) / binner.bin(dest)    ← raw coords die as locals
                  (3) aggregator.recordTrip(...)               ← COUNTS ONLY into Hive
   ────────────────────────────────────────────────────────────────────────
   buildReleaseCandidate()  →  snapshot → k-anon suppress (k=100) → Laplace DP
        → ReleaseCandidateMatrix  (NEVER uploaded; no sink call in this method)
   ────────────────────────────────────────────────────────────────────────
   wiredSink = NullEgressSink()  ← the ONLY sink; imports no network library
```

Key source files:
- `lib/services/data_asset/data_asset_pipeline.dart` — orchestrator; the single integration
  point is `onTripCompleted`, called **unawaited + fail-open** off the alarm path.
- `lib/services/data_asset/aggregate_egress_sink.dart` — the egress **contract** + `NullEgressSink`.
  This file **imports no HTTP/socket library**, so egress is off *by construction*, not just by flag.
- `lib/services/data_asset/http_aggregate_egress_sink.dart` — the **INERT** future HTTP sink,
  written now only so the wire format is reviewable. Three independent locks (type, flag, config).
- `lib/services/data_asset/data_asset_config.dart` — the bright-line constants (single source of truth).
- `lib/services/data_asset/mobility_consent_service.dart` — DPDP Rule-3 consent, default OFF.
- `lib/screens/mobility_data_consent_screen.dart` — the consent UI (`DataSharingConsentScreen`, route `/dataConsent`).
- `lib/services/tracking/arrival_hooks.dart` — the fan-out that feeds coords in.
- Supporting: `station_binner.dart`, `od_cell.dart`, `od_aggregator.dart`, `k_anonymity_filter.dart`,
  `differential_privacy.dart`, `contribution_cap.dart`, `aggregate_schema.dart`.

### 1.2 Consent (default OFF) — the screen + toggle

`DataSharingConsentScreen` (`lib/screens/mobility_data_consent_screen.dart`) is reached from
**Settings drawer → "Anonymous data sharing"** (`settingsdrawer.dart:163`, route `/dataConsent`).
Note it is **NOT** a Pro feature — it is a separate, purpose-specific consent.

Behaviour to verify on-screen:
- Four explainer sections: *What GeoWake shares*, *Why*, *Your guarantees*, *How we protect it*
  (copy from `mobility_consent_copy.dart`; every user-facing string says **"GeoWake"**, never
  "geowake2"/"WakePoint").
- An **18+ self-attestation checkbox** that must be ticked *before* the toggle can be switched on.
  If you flip the switch without ticking it, `_onToggle` shows a snackbar and refuses (screen line 50).
- A `SwitchListTile` that is **OFF by default**. Subtitle reads
  *"Off by default. Turn on only if you are happy to help."*
- Grievance-officer + Data-Protection-Board placeholder contacts at the bottom (currently
  placeholder text — a **known gap**, see §4).

Consent state is persisted to SharedPreferences key `gw_mobility_consent_v1` — deliberately
**separate** from the entitlement blob and from any telemetry key. Guarantees enforced in
`MobilityConsentService`:
- **Default OFF**: `isSharingEnabled` is false until an explicit versioned `grant()`.
- **Fail-safe parse**: a missing/corrupt blob resolves to DISABLED, never ON. Only a strict
  boolean `true` counts (`enabled == true`).
- **Material-change re-consent**: `isSharingEnabled` also requires the stored `noticeVersion`
  to equal the current `kConsentNoticeVersion` (`mobility-consent-v1`). Bump the constant → every
  prior grant is treated as not-consented until re-granted.
- **One-tap withdrawal** (`withdraw()`): disables immediately, stamps `withdrawnAtMs`, persists,
  then runs the injected `onWithdraw` hook → `OdAggregator.wipeAndLogErasure` (erases on-device
  aggregate state + appends an auditable erasure record). Consent goes off **even if erasure throws**.
- `consentReceiptJson()` exports exportable proof of the specific consent (DPDP Rule-3 evidence).

### 1.3 Capture — coordinates ARE now wired into `fireArrived`

Previously the aggregate surface received nothing. It is now wired:
- `maptracking.dart` captures the origin at tracking start (`_originLat/_originLng` set from
  `args['userLat']/['userLng']`, line 313–314) and the destination (`_destinationLat/Lng`).
- On **END TRACKING** (`maptracking.dart:1362`), *after* `completeEndTracking()` has torn the
  session down, `ArrivalHooks.fireArrived(...)` is called with all four coords + mode.
- `ArrivalHooks` (line 84–100) only forwards to `onTripCompleted` when **all four coords are
  non-null**; otherwise the aggregate surface is silently skipped.

**Why this is core-safe:** `fireArrived` runs only in the post-alarm branch, is a synchronous
`void`, kicks each sink off `unawaited(...)` inside its own try/catch, and the whole body is
wrapped again. It performs zero alarm/reachability/tracking work. The wake is long since delivered.

### 1.4 The privacy pipeline (what happens to a captured trip when consent is ON)

1. **Consent short-circuit is line one** of `onTripCompleted` — with sharing OFF, **zero Hive
   writes**, and a coordinate is never even touched.
2. **Station binning** (`StationBinner.bin`): each raw lat/lng is snapped to the nearest catalogue
   station within `kStationSnapMaxRadiusMeters` (800 m). The raw coordinate lives only as a local
   inside `bin()`; beyond the radius the endpoint is un-aggregatable and the trip is dropped (safe).
3. **Counts only** (`OdAggregator.recordTrip`): stores an O→D *cell* count, never a trajectory.
4. **Contribution cap** (`contribution_cap.dart`): at most `kPerUserMaxCellsPerDay` = **4** distinct
   cells/day, per-cell indicator 0/1 (`kPerUserMaxCountPerCellPerDay` = 1) — this bounds DP L1
   sensitivity.
5. **Release candidate** (`buildReleaseCandidate`): snapshot → **k-anonymity** suppression
   (`kOdKAnonymityThreshold` = **100** contributing users, Google's "100 rule") → **Laplace DP**
   noise per surviving cell (`kEpsilonPerCell` = 0.44). Emits `ReleaseCandidateCell`s, **NOT**
   `ReleasedCell`s — and **never calls a sink**.

### 1.5 The INERT egress — how to PROVE zero data leaves

Egress is off through **three independent locks**, any one of which alone stops it:

1. **Type lock**: `AggregateEgressSink.upload` accepts only an `OdFlowMatrix` of `ReleasedCell`s.
   A `ReleasedCell` is constructable *only* by `ReleasedCell.fromSecureMerge`, which needs a
   `MergeBackendAuthority` token no on-device code can mint. No merge backend exists → no
   `OdFlowMatrix` of released cells can be produced on-device to hand to `upload()`.
2. **Flag lock**: `kDataAssetEgressEnabled == false` (`data_asset_config.dart:21`). The pipeline's
   `init()` **asserts** that only a `NullEgressSink` may be wired while the flag is false — passing
   any transmitting sink throws, is caught fail-open, and `wiredSink` stays `NullEgressSink`.
   `HttpAggregateEgressSink.upload` also hard-returns on this flag before constructing any request.
3. **Config lock**: `kDataAssetEgressEndpoint == ''` — even past the flag, an empty endpoint means
   there is nowhere to send.

On top of all three, the **default and only wired sink is `NullEgressSink`**, whose file imports
no network library — so the shipping build literally has no code path from an aggregate to a socket.

**Proof (run these — deterministic, no device):**
```bash
cd /home/raed/Projects/WakePoint
/home/raed/flutter/bin/flutter test test/data_asset/http_egress_sink_test.dart
/home/raed/flutter/bin/flutter test test/data_asset/pipeline_hive_test.dart
```
- `http_egress_sink_test.dart` asserts `kDataAssetEgressEnabled` is false, that `upload()` **never
  constructs an HTTP client** even with an endpoint set (injected client factory throws if touched;
  asserted 0 calls), and that `DataAssetPipeline.init(sink: HttpAggregateEgressSink())` leaves
  `wiredSink` a `NullEgressSink`.
- `pipeline_hive_test.dart` groups: *bright line / egress tripwires* (compile-time OFF, only wired
  sink is `NullEgressSink`), *pipeline OFF (default consent)* — **"onTripCompleted with consent OFF
  makes ZERO writes"**, *pipeline ON* (records one **capped** O-D count, cap = 4 cells/day, day
  rollover), *fail-open*, and *withdrawal erases + logs*.

**Device sanity check (proves nothing egresses, empirically):** with the app installed, open a
network monitor and drive a full trip with consent toggled ON — no request to any aggregate/merge
endpoint appears because there is no such endpoint and no transmitting sink. Concretely:
```bash
# capture app traffic while you drive END TRACKING with consent ON in the sim/device
$HOME/Android/Sdk/platform-tools/adb -s ZN5225DML5 shell dumpsys package com.geowake.app | grep -i INTERNET
# the app holds INTERNET (for Maps/share backend), but grep the traffic: no OD/aggregate POST exists.
```
The authoritative proof is the code + tests, not the packet capture — but the capture is a useful
belt-and-suspenders demo for the founder.

---

## 2. Telemetry — PII-free local JSONL

Source: `lib/services/telemetry/telemetry_service.dart` (facade + event model + funnels),
`file_telemetry_sink.dart` (durable JSONL), `http_telemetry_sink.dart` (INERT network sink),
`telemetry_report_builder.dart` (diagnostics blob).

### 2.1 What it captures (all PII-free by construction)

The typed funnels **never accept a lat/lng** — that is the enforcement, not a policy. Funnels:
- `sessionStart` (precise-location grant, notifications, exact-alarm, battery-opt exemption — booleans).
- `alarmArmed` (mode, value, optional city/line).
- `gpsLost` / `gpsReacquired` (coarse seconds + drift metres, rounded to 0.1).
- **`alarmOutcome`** — the north-star metric: `onTime` / `early` / `late` / `missed` / `dismissed`
  / `snoozed`, with `margin_s`, whether it fired via backstop or reachability. Positive lead = early
  (safe), negative = late (product death).
- `reliability` (FGS survived vs OS-killed, Doze entered, backstop fired).
- `reachabilityActivated`, `ekfHealth`.
- `recordError` (see §2.2).

Every event also carries a **non-PII device context** (`setDeviceContext`: OEM, model, Android SDK
int, app version, platform) so failures can be broken down by phone/OEM/version — the exact
breakdown a reliability app needs to learn which devices kill the FGS.

**Sinks (default):** an in-memory ring buffer (`InMemoryTelemetrySink`, bounded 2000 events) **plus**
a durable `FileTelemetrySink` writing `telemetry.jsonl` under `getApplicationSupportDirectory()`
(rotating at 512 KB to a single `.1` generation, fsync on append). Wired in `main.dart:88`
(`configureDefaultSinks`) fire-and-forget.

### 2.2 The three crash hooks (`main.dart:53–62`, `137–141`)

A reliability-critical app must never die silently. All three route to `TelemetryService.recordError`:
1. **`FlutterError.onError`** (line 53) — widget-tree / framework errors. `fatal: false`.
2. **`PlatformDispatcher.instance.onError`** (line 58) — otherwise-unhandled platform errors.
   `fatal: true`, sets the crash flag, returns `true` (handled → isolate does not crash).
3. **`runZonedGuarded`** outer handler (line 137) — uncaught async/zone errors. `fatal: true`,
   sets the crash flag.

`recordError` scrubs the error string + stack of absolute home paths (`/home/<user>` → `/~`,
regex in `telemetry_service.dart:322`) and truncates (300 / 1200 chars) so no username leaks.
Hooks 2 and 3 call `_markSessionCrashed()` → persists `gw_last_session_crashed = true` (drives §3.2).

### 2.3 The INERT HTTP telemetry sink

`HttpTelemetrySink` (`http_telemetry_sink.dart`) batches PII-free events as newline-delimited JSON
and POSTs them, but is **inert by default**:
- Endpoint/token come from `--dart-define GEOWAKE_TELEMETRY_URL` / `GEOWAKE_TELEMETRY_TOKEN`
  (`main.dart:42–45`), **default `''`**.
- An **empty (or whitespace-only) URL registers NO http sink at all** (`configureDefaultSinks`
  only adds it `if (telemetryUrl.trim().isNotEmpty)`), and even if constructed, an empty endpoint
  makes `add()`/`flush()` a hard no-op that never touches an `HttpClient`.
- It serialises nothing itself — it only forwards `event.toJsonLine()`, the same coordinate-free
  schema the file sink persists, so it **cannot add a lat/lng it never sees**.
- Batched (maxBatch 50), bounded backlog (4× batch), fail-open (5xx re-queues, 2xx/4xx drop,
  network error re-queues), never throws into the caller.

**Proof:** `test/telemetry/http_telemetry_sink_test.dart` — *"empty endpoint is a hard no-op:
no request is ever made"*, *"whitespace-only endpoint is also inert"*, and *"POST body is PII-free
(no home paths, no coordinates)"*.

---

## 3. Report-a-problem + crash-on-next-launch

### 3.1 The flow (user-initiated egress only)

Entry: **Settings drawer → "Report a problem"** (`settingsdrawer.dart:172`, `bug_report_outlined`).
Screen: `lib/screens/report_problem_screen.dart` (`ReportProblemScreen`).

Sequence:
1. **Description** — a `TextField` for "what went wrong."
2. **Preview** — a live, scrollable, monospace, **selectable** preview of the exact diagnostics
   block that will be sent, built by `TelemetryReportBuilder.build`:
   - `GeoWake — problem report` header,
   - the user's note (prepended at send time),
   - environment block: app name+version+build (`PackageInfo`), coarse device (`manufacturer model
     · Android <release> (SDK <int>)`),
   - up to 120 recent telemetry events, each `toJsonLine()` — **PII- and coordinate-free by
     construction** (the funnels never hold a lat/lng; error strings/stacks are scrubbed + truncated).
3. **Send** — `Share.share(...)` opens the **OS share sheet / email app**. The user picks the target
   and hits send. **Nothing is ever uploaded silently**; `telemetry_report_builder.dart` deliberately
   does not touch the network.

Screen copy states plainly: *"no location and no personal data … You choose where to send it;
nothing is sent automatically."*

### 3.2 Crash-on-next-launch prompt (`main.dart:217` `_maybeOfferCrashReport`)

If the previous session set `gw_last_session_crashed` (via hooks 2/3 above), the **next launch**
reads-and-clears the flag (so it prompts **at most once**) and shows an AlertDialog *"GeoWake hit a
problem"* offering **Report** / **Not now**. **Report** pushes
`ReportProblemScreen(crashedLastSession: true)`, which adds a
*"⚠ The app ran into an unexpected error last session."* marker to the report.

---

## 4. Test steps for the next agent (device + deterministic)

### 4.1 Consent ON → confirm still nothing egresses
1. Fresh install. Settings → **Anonymous data sharing**. Confirm switch is **OFF** and the
   subtitle says "Off by default." Confirm the toggle **cannot** be turned on until the 18+ checkbox
   is ticked (tap the switch first — expect a refusal snackbar).
2. Tick 18+, turn the switch ON → expect the "enabled" snackbar. Background/relaunch → confirm it
   stays ON (persisted to `gw_mobility_consent_v1`).
3. Drive a **complete** trip to arrival, tap **END TRACKING**. This calls `onTripCompleted` with
   real coords (consent ON → it bins + counts locally).
4. **Prove no egress**: run `flutter test test/data_asset/http_egress_sink_test.dart` and
   `flutter test test/data_asset/pipeline_hive_test.dart` (both green = code-level proof). Optionally
   capture app traffic during the trip and confirm there is **no OD/aggregate POST** (there is no
   endpoint and no transmitting sink).
5. Return to the consent screen, turn it **OFF** → expect the "withdrawn" snackbar; on-device
   aggregate state is wiped and an erasure record appended (`wipeAndLogErasure`).

### 4.2 Trigger a handled error → next launch offers a report
1. Cause a handled error that hits one of the crash hooks (e.g. an async throw caught by
   `runZonedGuarded`, or a `PlatformDispatcher` error). The hook sets `gw_last_session_crashed`.
   *(If you can't force a real one, set the pref directly for the UI test:
   `adb shell` is not enough — the flag is in SharedPreferences; easiest is to inject a throw in a
   debug build. Do not fake it in a way you'll then report as "real crash proof.")*
2. **Relaunch.** Expect the *"GeoWake hit a problem"* dialog **once**. Relaunch again → it must
   **not** reappear (flag was cleared).
3. Tap **Report** → `ReportProblemScreen` opens with the `⚠ … last session` marker in the preview.

### 4.3 Send a report → verify PII-free payload
1. Settings → **Report a problem**. Type a note. Read the **preview**.
2. **Inspect the preview for PII**: confirm there is **no lat/lng**, no home path
   (`/home/<user>` should appear as `/~` if any path is present), only app version + coarse device +
   `t/ts/props` JSONL events.
3. Tap **Send report** → the **OS share sheet** appears. Send to yourself (email/notes). Confirm the
   received text matches the preview and contains no coordinates or personal data.
4. Deterministic backup: `flutter test test/telemetry/http_telemetry_sink_test.dart` includes a
   *"POST body is PII-free"* assertion over the same `toJsonLine()` schema the report uses.

---

## 5. Known gaps / caveats (do not overstate)

- **Background-isolate telemetry egress.** The crash hooks and funnels above run in the **main
  isolate**. The tracking foreground service runs in its **own isolate**; errors there are not
  guaranteed to reach `TelemetryService` (separate isolate = separate error handlers + separate
  in-memory sink). The durable `FileTelemetrySink` mitigates loss on the main isolate only. Wiring
  the tracking isolate's errors/flush into the same durable sink is **open work** — the reliability
  funnel's most important measurement (FGS OS-kill) is exactly the case most at risk of not being
  recorded from the isolate that dies.
- **Consent screen legal placeholders.** Grievance-officer + Data-Protection-Board contacts on the
  consent screen are **placeholder strings** (`mobility_consent_copy.dart`). A real DPDP-compliant
  launch needs real contacts + a signed DPIA before egress could ever be flipped on.
- **Egress is doubly business-gated, not just code-gated.** `kDataAssetEgressEnabled` must never be
  flipped until a contracted buyer **and** an Indian DP-lawyer DPIA sign-off **and** a live
  secure-aggregation merge backend all exist. The `HttpAggregateEgressSink` is written but must stay
  unwired until then. Do **not** treat "the plumbing compiles" as "ready to sell data."
- **Telemetry is opt-out-less today.** It is local-only + PII-free, so there is no consent gate on
  it — acceptable while nothing egresses. The moment `GEOWAKE_TELEMETRY_URL` is supplied, that
  assumption needs a consent/notice review (currently there is no user-facing telemetry toggle).
- **No device proof of the data-asset value exists, and that is correct.** Nothing is sold, nothing
  egresses. The only honest claims are: capture is wired, aggregation/DP/k-anon run on-device, and
  egress is proven off by construction + tests.


<div style="page-break-before:always"></div>

---

# 06 — Infra / Build / Sim Dashboard / Config

**Audience:** the next agent, who has remote access to a physical phone and the
unified simulation dashboard and must drive + verify **everything** end-to-end.
This section is the operational runbook: how to build & install onto the phone,
how to stand up the unified simulation dashboard and drive routes / GPS-dropout
scenarios into it, how the Railway backends work, which CI gates protect the
never-late promise, and the **complete** table of every config placeholder /
`--dart-define` the founder must set before a real launch.

Everything below was read from source on the `sim-validation` branch. Nothing is
invented. Where a value is a device-only claim, it is marked **DEVICE-VERIFY**.

---

## 1. Phone / adb access + the exact build & install command

### Device + toolchain (from the task brief, confirmed against the repo)

| Thing | Value |
|---|---|
| Device serial | `ZN5225DML5` (physical phone, remote) |
| App package (`applicationId`) | `com.geowake.app` — `android/app/build.gradle:20` |
| Android **namespace** (NOT the package) | `com.example.geowake2` — `android/app/build.gradle:14` |
| adb | `$HOME/Android/Sdk/platform-tools/adb` |
| flutter | `/home/raed/flutter/bin/flutter` (verified present) |
| Flutter version pinned by CI | `3.44.6` stable (`.github/workflows/ci.yml:25`) |
| App version | `1.0.0+1` (`pubspec.yaml:4`) — see the versionCode note below |

> **Namespace vs applicationId gotcha.** The Java/Kotlin namespace is
> `com.example.geowake2` (so the widget provider class is
> `com.example.geowake2.GeoWakeWidgetProvider`, matching
> `AndroidManifest.xml:127` and `HomeWidgetBridge.androidQualifiedName`), but the
> **installed package id is `com.geowake.app`**. Always target
> `com.geowake.app` with adb (`adb shell am`, `pm`, uninstall, etc.). This split
> is intentional and load-bearing for App Links (§3).

### First, confirm the phone is attached

```bash
$HOME/Android/Sdk/platform-tools/adb devices
# expect:  ZN5225DML5   device
```

If more than one device/emulator is attached, pin every flutter/adb call to the
serial: `flutter run -d ZN5225DML5 …` and `adb -s ZN5225DML5 …`.

### The Maps key must exist before the build (or maps render blank)

The Google Maps key is injected as a manifest placeholder **only** from
`android/key.properties` (gitignored) — there is deliberately **no** hardcoded
fallback (`android/app/build.gradle:36-39`). An empty value fails loud (blank
map) rather than shipping a secret. Before building for the device, ensure
`android/key.properties` exists and contains:

```properties
googleMapsApiKey=AIza...            # a VALID, unrestricted-or-android-restricted key
# (release signing props also live here if you cut a release build)
```

`app_config.dart` notes the previously-leaked key `AIzaSyC0v...XHw0` must be
**rotated** — do not reuse it.

### Build + install for live journey-share (the exact command)

Debug is the fastest path to a working install with the simulation bridge
enabled (the bridge is auto-on in `kDebugMode`, see §2):

```bash
/home/raed/flutter/bin/flutter run -d ZN5225DML5 \
  --dart-define=GEOWAKE_SHARE_TOKEN=<bearer-token-matching-railway-SHARE_AUTH_TOKEN>
```

For a standalone install (release-shaped, still needs the token for live share):

```bash
/home/raed/flutter/bin/flutter build apk --release \
  --dart-define=GEOWAKE_SHARE_TOKEN=<bearer-token> \
  --dart-define=GEOWAKE_SHARE_BASE_URL=https://geowake-share-production.up.railway.app \
  --dart-define=GEOWAKE_SHARE_DOMAIN=https://geowake-share-production.up.railway.app

$HOME/Android/Sdk/platform-tools/adb -s ZN5225DML5 install -r \
  build/app/outputs/flutter-apk/app-release.apk
```

**Why the token matters:** `ShareBackendConfig` (`share_backend_config.dart`)
already defaults `baseUrl` and `appLinksDomain` to the deployed Railway service
(both are public, safe to commit). What it does **not** default is the bearer
token (`authToken`, line 35-38, `defaultValue: ''`). With **no** token:
- BASIC share still works end-to-end (the message + `/j/{id}` link via the OS
  share sheet) because that path needs no auth;
- the LIVE ping/follow path is **inert / fail-safe** — `HttpShareBackend` writes
  would 401 against a token-protected server, so it degrades to Noop rather than
  erroring.
So to exercise **live tracking / Guardian arrived-via-backend**, the
`GEOWAKE_SHARE_TOKEN` must equal the server's `SHARE_AUTH_TOKEN` (§3).

> **versionCode note (`build.gradle:22-29`):** `versionCode`/`versionName` now
> flow from pubspec `version: x.y.z+build` via the Flutter Gradle plugin. They
> were previously hardcoded to `1`/`"1.0"`, which silently rejected every Play
> upload after the first. To cut a new release, bump the `+N` build number in
> `pubspec.yaml`.

---

## 2. The Unified Simulation Dashboard (relay → dashboard → phone)

The dashboard is a **Chrome-hosted Flutter web app** that mirrors and drives the
real app over a WebSocket relay. Three processes must run together. Note the
`.agent/workflows/launch_simulation.md` file is **stale** — it names the old
`lib/main_dashboard.dart` and `dart tools/relay_server.dart` port text. The
current, correct entry point is `lib/main_unified_dashboard.dart` and the relay
is on **8081**.

### The three moving parts

1. **Relay server** — `tools/relay_server.dart`. A dependency-free Dart
   WebSocket hub on `ws://0.0.0.0:8081`. It broadcasts every message to all
   *other* connected clients (it does not interpret them, except swallowing
   `pong`). It heartbeats every 30 s and drops a client after 60 s of silence
   (`relay_server.dart:14-50`).
2. **Web dashboard** — `lib/main_unified_dashboard.dart` →
   `lib/dashboard/unified_dashboard.dart`. Connects to the relay from Chrome via
   `dart:html WebSocket`, visualizes route/position/ETA, and **sends**
   `simulation_update` messages (the driven GPS) plus route/control messages.
3. **The real GeoWake app on the phone** — its `SimulationClient`
   (`lib/services/simulation_client.dart`) connects to the same relay and injects
   received `simulation_update` points as if they were the device's GPS fixes.

### The bridge is gated (so release builds never touch localhost)

`PlaygroundBridgeConfig` (`lib/config/playground_bridge.dart`):
- `relayUrl` default `ws://127.0.0.1:8081`, override with
  `--dart-define=PLAYGROUND_RELAY_URL=…`.
- `enabled` is **true in `kDebugMode` or `kProfileMode`**, always **false**
  under `flutter test` (`FLUTTER_TEST=true`), and can be forced with
  `--dart-define=PLAYGROUND_BRIDGE_ENABLED=true` / disabled with
  `PLAYGROUND_BRIDGE_DISABLED=true`. So a normal **debug** run on the phone is
  already bridge-enabled — no extra flag needed to drive it from the dashboard.

### Launch sequence (do it in this order)

```bash
# Terminal 1 — relay (must be up FIRST)
/home/raed/flutter/bin/dart tools/relay_server.dart
#   -> "Relay Server listening on ws://localhost:8081"

# Terminal 2 — dashboard in Chrome
/home/raed/flutter/bin/flutter run -d chrome \
  -t lib/main_unified_dashboard.dart --web-port 3000

# Terminal 3 — the app on the phone, in debug (bridge auto-enabled)
/home/raed/flutter/bin/flutter run -d ZN5225DML5 \
  --dart-define=GEOWAKE_SHARE_TOKEN=<token>

# Bridge the phone's localhost:8081 to the workstation's relay
$HOME/Android/Sdk/platform-tools/adb -s ZN5225DML5 reverse tcp:8081 tcp:8081
```

`adb reverse tcp:8081 tcp:8081` makes the phone's `127.0.0.1:8081` resolve to the
relay on the workstation — this is what lets the on-device `SimulationClient`
reach the relay. Run it **after** the app is installed/running (it survives app
restarts but not device reboots; re-run if the socket goes quiet).

**Connection health check:** both the dashboard header and the app logs should
show "Connected". The dashboard reconnects with exponential backoff
(`unified_dashboard.dart:432`) and the client with 1→30 s backoff
(`simulation_client.dart:180`). If Chrome loads over `https:`, the dashboard
auto-upgrades `ws://` to `wss://` (`_resolveRelayUrl`, line 384); for local
`http` Chrome it stays `ws://`. You can override the relay per-load with
`?relay=ws://host:8081` in the dashboard URL.

### Driving a route + watching the EKF / reachability handoff

Message contract (what flows over the relay):

| Direction | `type` | Purpose | Source |
|---|---|---|---|
| dashboard → app | `simulation_update` | one driven GPS point `{lat,lng,heading,speedMps,virtualTime,warpFactor,timestamp}` | `unified_dashboard.dart:711` |
| dashboard → app | `switch_route` / `reset_alarm_state` | force a route or reset alarm state | handled `simulation_client.dart:326,337` |
| app → dashboard | `route_update` | the app's active route/segments/stops/legs | `simulation_client.broadcastRoute` |
| app → dashboard | `app_state` | ETA, distance, alarm mode/value/**fired**, remaining stops, debug | `simulation_client.broadcastState` |
| app → dashboard | `device_position` | the phone's **real** GPS (when not being driven) | `simulation_client.broadcastPosition` |
| both | `ping`/`pong` | relay heartbeat | relay + both clients |

**Time-warp correctness (important when reading ETA):** the dashboard stamps each
`simulation_update` with a **virtualTime** and an explicit **speedMps**. The
client deliberately prefers those over `DateTime.now()` / distance-derived speed,
because under time-warp the *update rate* changes and naive derivation would
inflate speed and collapse ETA (`simulation_client.dart:355-419`). If you see an
`ETA_DEBUG simClient RX:` log line, that is this path; `provided=` should be
populated when the dashboard is driving.

**GPS-dropout / tunnel / ZUPT scenarios.** These live in the dashboard's EKF test
panel (`lib/dashboard/ekf_test_panel.dart`) and drive the dashboard's **own**
offline EKF replay engine (`ekf_test_controller`), which is where you watch the
ZUPT markers and the dead-reckoning handoff render on the map
(`unified_dashboard.dart:973` draws `ZUPT #n` markers). The selectable modes
(`GpsDropoutMode`, `_dropoutLabel`, lines 611-654):

| Mode | Meaning |
|---|---|
| `normal` | continuous GPS |
| `tunnelSimulation` | **drops underground** — the tunnel dead-zone case; watch ZUPT + IMU-only dead-reckon + reachability cone hold |
| `intermittent` | random dropouts |
| `completeDropout` | no GPS at all — pure IMU |
| `accuracyDegraded` / `urbanCanyon` | (defined but not in the default picker list) |

In **Log Replay** mode the picker is hidden — GPS availability (dead-zone
tunnels included) is baked into the replay log itself (`ekf_test_panel.dart:626`,
info chip at line 640). The dropout mode is a **live** control: changing it
applies to the running engine and is picked up by the next load
(`ekf_test_panel.dart:691-697`). This is the surface to exercise the
**ZUPT + EKF/reachability handoff** the memory notes call out (underground
positioning study, reachability tightening).

> **Scope note — what the dashboard proves vs. the phone.** The GPS-dropout/ZUPT
> panel runs an EKF engine *inside the dashboard* over fixtures/logs. Driving the
> **phone** uses `simulation_update` → the on-device `SimulationClient` →
> `LocationManager` (`lib/services/location_manager.dart`), which feeds the real
> on-device EKF/alarm path. Use the dashboard panel to *see* the physics; use the
> driven-phone path to prove the **device** behaves. Never claim device proof
> from the dashboard engine alone.

---

## 3. Railway backends

There are **two** distinct Railway services in play — do not conflate them:

### 3a. Journey-share service — `geowake-share-production.up.railway.app`

Source: `backend/share/server.js` (zero-dependency Node HTTP), config
`backend/share/railway.json`, env template `backend/share/.env.example`, docs
`backend/share/README.md`. It implements `docs/share/BACKEND_CONTRACT.md` and is
the server half of `HttpShareBackend`.

**What it does / privacy invariants (enforced in code):** latest-only (one coarse
point per share id, a ping *overwrites*, no history), TTL + hard-delete sweeper
(30 s, `railway.json` note `sleepApplication:true` = scale-to-zero on idle),
coordinates rounded to 5 dp on ingest *and* read, bearer-auth on every `/v1`
route, locked-down CORS (never `*`), per-IP rate limit, 8 KB body cap, strict CSP
on the `/j/{id}` recipient page. The `arrived` hook (`onArrived`,
`server.js:430`) is the **only** side channel and carries **no coordinates** — it
is where the founder wires FCM/DLT-SMS.

**Endpoints:** `GET /` health; `POST /v1/share`, `POST /v1/share/{id}/ping`,
`POST /v1/share/{id}/arrived`, `GET /v1/share/{id}/status`, `DELETE
/v1/share/{id}` (all bearer); `GET /j/{id}` recipient HTML; `GET
/.well-known/assetlinks.json`.

**assetlinks / App Links.** `/.well-known/assetlinks.json` is served from
`assetlinksJson(cfg)` (`server.js:409`) using `ANDROID_PACKAGE` +
`ANDROID_CERT_SHA256`. For verified HTTPS App Links to work, the served
`package_name` must equal the installed **`com.geowake.app`** and the fingerprint
list must include this build's signing SHA-256. The manifest already declares the
verified intent-filter for host `geowake-share-production.up.railway.app` with
`android:autoVerify="true"` (`AndroidManifest.xml:66-74`), plus a always-works
custom-scheme fallback `geowake://j/{id}` (lines 75-80).

> **BUG TO FIX before shipping App Links:** `backend/share/.env.example:26` sets
> `ANDROID_PACKAGE=com.example.geowake2`, but the installed app is
> **`com.geowake.app`** (and `server.js:49` correctly defaults to
> `com.geowake.app`). If the founder copies `.env.example` verbatim into Railway,
> `assetlinks.json` will advertise the **wrong package** and Android App Link
> verification will silently fail (links open the chooser / browser instead of
> the app). Set `ANDROID_PACKAGE=com.geowake.app` in Railway.

**Deploy / redeploy.** From `backend/share/`: `railway init` (first time) →
`railway variables --set SHARE_AUTH_TOKEN=…` / `ANDROID_CERT_SHA256=…` →
`railway up` → `railway domain`. Generate the token with
`node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"`.

> **Peak-hour deploy block (from `docs/HANDOFF_TESTING.md:258-259` and
> `:132`).** Railway free-tier **blocks deploys during peak hours**. The
> `assetlinks.json` redeploy (needed to enable verified HTTPS App Links once the
> real signing SHA-256 is known) must be run **off-peak**: `cd backend/share &&
> railway up`. Until that off-peak redeploy lands, rely on the
> `geowake://j/{id}` custom scheme for testing deep links.

**HMAC `?t=` tokens.** Optional. Left empty (default), the server treats `?t=` as
opaque and the unguessable share id is the sole capability gate (the app mints
tokens with a per-device secret via `ShareLinkBuilder.mintToken`). To activate
cryptographic verification, set `HMAC_SECRET` **and** align the app's share
secret to it; `HMAC_REQUIRE=true` additionally rejects links with no `?t=`.

**Local test:** `cd backend/share && cp .env.example .env && node server.js`;
`npm test` runs the dependency-free `node:test` suite (`server.test.js`).

### 3b. Maps/API proxy service — `geowake-production.up.railway.app/api`

Source of truth `lib/config/app_config.dart`: `serverBaseUrl =
https://geowake-production.up.railway.app/api`. This is the **secure server**
that proxies Google Maps / Places calls so the raw Maps key is not embedded
(`ApiClient` uses this base URL). It is a *separate* backend from the share
service and its code is not in this repo (`geowake-server/…` per the comment). It
enforces `APP_BUNDLE_ID = com.geowake.app`. Note the app **still** needs a Maps
key in the manifest (`${googleMapsApiKey}`) to render the map tiles themselves —
the proxy only covers Directions/Places API calls.

---

## 4. CI / never-late gates (`.github/workflows/ci.yml`)

CI runs on push/PR to `sim-validation`, `stable-release-1`, `main`. The
never-late replay gate is the **load-bearing** check — it drives the real
`EkfOrchestrator + AlarmEvaluator + reachability` over committed ride fixtures
and **fails** (not skips, and fails on *empty* fixtures) if any ride would fire
late / never-fire / at the wrong place. Reproduce locally with:

```bash
FL=/home/raed/flutter/bin/flutter
$FL analyze lib/ --no-fatal-infos                                   # 0 errors/warnings
$FL test test/ekf/replay_harness_test.dart                         # NEVER-LATE replay gate
$FL test test/reachability/                                        # reachability physics proofs
$FL test test/scale/reachability_scale_test.dart                   # never-late at scale
$FL test test/dashboard/playground_reachability_e2e_test.dart      # never-late through the playground engine
$FL test test/core/clock/                                          # monotonic-clock backward-jump guard
$FL test test/metro_data_integrity_test.dart test/metro_vehicle_types_test.dart
$FL test                                                           # full suite (all pass)
```

> **Repo-state caveat:** the git status shows `test/scale/multi_target_scale_test.dart`
> **deleted** and several modified test files on this branch. CI references
> `test/scale/reachability_scale_test.dart` (present). Run the full suite
> (`flutter test`) after any change and before claiming green; do not trust a
> partial run. A second workflow, `qodana_code_quality.yml`, runs static code
> quality separately.

---

## 5. COMPLETE config-placeholder / `--dart-define` table

Everything the founder must set before a real (non-test) launch. "App" =
Flutter build-time `--dart-define`; "Server" = Railway env var; "Source" = a
value edited in source. Anything left at default is **fail-safe** (the app stays
on the offline/inert path) unless flagged.

| # | Placeholder | File:line | Default | Purpose / consequence if unset |
|---|---|---|---|---|
| 1 | **Google Maps key** (`googleMapsApiKey`) | `android/key.properties` (read at `android/app/build.gradle:37`) | **empty → blank map** | Renders map tiles. No hardcoded fallback by design. Previously-leaked key `AIzaSyC0v...XHw0` must be **rotated**. |
| 2 | `GEOWAKE_SHARE_TOKEN` (App) = `SHARE_AUTH_TOKEN` (Server) | app `share_backend_config.dart:35`; server `server.js:34` / `.env.example:7` | `''` both | Bearer auth for live share. Empty app token ⇒ live ping/follow inert (basic share still works). Empty server token ⇒ **/v1 write routes are OPEN** (server warns at startup, `server.js:447`). Must **match**. |
| 3 | `GEOWAKE_SHARE_BASE_URL` (App) | `share_backend_config.dart:29` | `https://geowake-share-production.up.railway.app` | Share backend URL. Public default is fine; override for a custom deploy. Empty ⇒ fully offline Noop backend. |
| 4 | `GEOWAKE_SHARE_DOMAIN` (App) | `share_backend_config.dart:44` → `ShareLinkBuilder.defaultDomain` (`share_link_builder.dart:23`) | `https://geowake-share-production.up.railway.app` | App-Links host that serves `/j/{id}` + `assetlinks.json`. If changed, also update the manifest App-Link host (`AndroidManifest.xml:72`). |
| 5 | `ANDROID_CERT_SHA256` (Server) | `server.js:47` / `.env.example:25` | `''` | Signing-cert SHA-256(s) for App Links verification. Empty ⇒ `assetlinks.json` lists no fingerprints ⇒ HTTPS App Links won't verify (custom scheme still works). From Play Console → App integrity. |
| 6 | `ANDROID_PACKAGE` (Server) | `server.js:49` (default OK) / `.env.example:26` (**WRONG**) | code `com.geowake.app`; `.env.example` `com.example.geowake2` | Package in `assetlinks.json`. **Must be `com.geowake.app`.** Do not copy the `.env.example` value verbatim (see §3a bug). |
| 7 | `HMAC_SECRET` (Server) | `server.js:41` / `.env.example:15` | `''` | Activates cryptographic `?t=` link verification. Empty ⇒ share id is the sole gate (fine for v1). Must align with the app's per-device secret to take effect. |
| 8 | `HMAC_REQUIRE` (Server) | `server.js:44` | `false` | If `true`, `/j/{id}` with no `?t=` is 403. Only meaningful once `HMAC_SECRET` is set. |
| 9 | `ALLOWED_ORIGIN` (Server) | `server.js:54` | `''` (locked down) | Only set to a single exact origin if a browser must call `/v1` cross-origin. `*` is intentionally unsupported. |
| 10 | `RATE_LIMIT_PER_MIN` (Server) | `server.js:57` | `120` | Per-IP fixed-window limit. |
| 11 | `GEOWAKE_TELEMETRY_URL` (App) | `main.dart:43` | `''` | INERT-by-default network egress for **PII-free** telemetry. Empty ⇒ **no HTTP sink registered**, telemetry stays local JSONL only (`http_telemetry_sink.dart` is a hard no-op when endpoint empty). |
| 12 | `GEOWAKE_TELEMETRY_TOKEN` (App) | `main.dart:45` | `''` | Optional bearer for the telemetry endpoint. Sent only if `GEOWAKE_TELEMETRY_URL` is set. |
| 13 | **Buy Me a Coffee handle** (`kBuyMeACoffeeUrl`) | `lib/screens/settingsdrawer.dart:19` | `https://www.buymeacoffee.com/YOUR_HANDLE` | Donation link in settings. Guarded: if it still contains `YOUR_HANDLE`, the button shows a "set your link" snackbar instead of opening (line 26). Replace `YOUR_HANDLE`. |
| 14 | **AdMob app id** | `AndroidManifest.xml:35` | `ca-app-pub-3940256099942544~3347511713` (**Google test app id**) | Real AdMob application id. Test id fills test ads only. |
| 15 | **AdMob unit ids** (banner/interstitial/rewarded) | `ad_service.dart:30-33`, injected via `AdService.configure(...)` at `:40` | Google **test** unit ids | Real ad unit ids for revenue. `AdService` is fail-open (ad errors never block the alarm); until real ids are supplied via `configure()`, only test ads render. **DEVICE-VERIFY** ad fill. |
| 16 | **Guardian auto-sender** (`GuardianAutoSender`) | `guardian_service.dart:45-51` (constructor `autoSender`) | `null` | Optional zero-tap SMS/WhatsApp/FCM backend (Twilio / WhatsApp Business / DLT-SMS). Null ⇒ Guardian composes into the user's **own** SMS/WhatsApp composer (user taps send). Wiring a sender enables unattended delivery. Business-gated, ships null. |
| 17 | **Data-asset egress kill-switch** (`kDataAssetEgressEnabled`) | `data_asset_config.dart:21` | `false` | HARD kill for all aggregate-data egress. Flip ONLY after a contracted buyer + Indian DP-lawyer DPIA + merge backend exist. While false, no non-null sink is constructed. |
| 18 | **Data-asset egress endpoint** (`kDataAssetEgressEndpoint`) | `data_asset_config.dart:29` | `''` | Future merge-backend ingestion URL. Never read while #17 is false. Documented no-op today. |
| 19 | **Maps/API proxy base URL** (`serverBaseUrl`) | `lib/config/app_config.dart` | `https://geowake-production.up.railway.app/api` | Secure Directions/Places proxy (separate Railway service, §3b). Change only if you redeploy that server. |
| 20 | `PLAYGROUND_RELAY_URL` (App, dev-only) | `playground_bridge.dart:28` | `ws://127.0.0.1:8081` | Sim-dashboard relay endpoint. Dev/test only; the bridge is off in release. |

**Minimum set to go live with working live-share + Guardian-via-backend:**
#1 (Maps key), #2 (matched share token), #5 + #6 (App Links cert + correct
package, redeployed **off-peak** per §3a). Everything else is safe at default and
fails to the offline/inert path.

---

## 6. Fast reference — one-screen cheat sheet

```bash
FL=/home/raed/flutter/bin/flutter
ADB=$HOME/Android/Sdk/platform-tools/adb

# --- install on the phone (live share) ---
$FL run -d ZN5225DML5 --dart-define=GEOWAKE_SHARE_TOKEN=<token>

# --- unified sim dashboard (3 terminals) ---
$FL bin dart tools/relay_server.dart                    # T1: relay :8081
$FL run -d chrome -t lib/main_unified_dashboard.dart --web-port 3000   # T2
$FL run -d ZN5225DML5 --dart-define=GEOWAKE_SHARE_TOKEN=<token>        # T3
$ADB -s ZN5225DML5 reverse tcp:8081 tcp:8081            # bridge phone -> relay

# --- share backend ---
cd backend/share && node server.js && npm test          # local
railway up                                              # deploy (OFF-PEAK for assetlinks)

# --- CI gate locally ---
$FL analyze lib/ --no-fatal-infos && $FL test
```

Correct the stale `.agent/workflows/launch_simulation.md` if you touch it: it
still points at `lib/main_dashboard.dart`; the live entry is
`lib/main_unified_dashboard.dart`.


<div style="page-break-before:always"></div>

---

# 07 · Business Decisions, Values & Accounts

> For the founder. This is the "money, credentials, and go/no-go" section of the
> handoff. It has three parts:
> **(A) Values to paste** — every secret/config value that must be set before
> release, where each one lives in code, and whether it blocks launch.
> **(B) Accounts to create** — the external accounts you must open, with the
> gotchas (esp. the new Play 20-tester rule).
> **(C) Strategic decisions** — a clear recommendation on each open business
> question: monetization model, Pro price, rewarded ads, the home widget, the
> mobility-data business go/no-go, legal, Play track, and the honest
> "business vs. good app" framing.
>
> Everything here is grounded in the actual code on branch `sim-validation`
> (paths cited inline) and in `docs/data_business/STRATEGY.md` and
> `docs/HANDOFF_TESTING.md`. Where those two disagree with current code, the code
> wins and the delta is flagged.

---

## Part A — VALUES TO PASTE

These are the concrete values the founder must supply. **"Where it goes"** is the
exact file / build-flag / gitignored config that reads the value today. **"Blocking?"**
means: does the app fail, mislead, or risk takedown at public launch if this is
left at its placeholder?

| # | Value | Where it goes (file / env / dart-define) | Purpose | Blocking? |
|---|---|---|---|---|
| A1 | **Buy Me a Coffee handle** | `lib/screens/settingsdrawer.dart` → `kBuyMeACoffeeUrl` (line 19), currently `https://www.buymeacoffee.com/YOUR_HANDLE`. Code detects the `YOUR_HANDLE` placeholder and shows a "Set your Buy Me a Coffee link" snackbar instead of opening a broken page. | Voluntary tip jar (the only "give money" path besides Pro). | **No** — degrades gracefully; button is inert until set. Set before release for the donation loop to work. |
| A2 | **Google Maps API key (rotated + restricted)** | `android/key.properties` (gitignored) → `googleMapsApiKey=...`. Injected into the manifest via `android/app/build.gradle` line 37 as `manifestPlaceholders.googleMapsApiKey` → `AndroidManifest.xml` `com.google.android.geo.API_KEY` (line 84). Empty fallback = maps render **blank** (fails loud, ships no secret). | Renders the map on the tracking/arming screens. | **YES.** The previously-committed key (`AIzaSyC0v…XHw0`, now scrubbed from source) **must be treated as leaked → rotate it.** Restrict the new key to Android apps: package `com.geowake.app` + the release signing SHA-1/SHA-256, and to **Maps SDK for Android** only. A blank map is a broken core screen. |
| A3 | **Real AdMob App ID** | `android/app/src/main/AndroidManifest.xml` line 34–35, `com.google.android.gms.ads.APPLICATION_ID`, currently Google's **test** app id `ca-app-pub-3940256099942544~3347511713`. | Identifies your AdMob app to the SDK. | **YES for revenue / policy.** Shipping the test app id to production is an AdMob policy violation and earns $0. Must be a real id before the public track. |
| A4 | **Real AdMob unit IDs** (banner, interstitial, rewarded) | `lib/services/monetization/ad_service.dart` — defaults are Google test units (`_testBanner` 6300978111, `_testInterstitial` 1033173712, `_testRewarded` 5224354917, lines 30–33). Override at runtime via `AdService.configure(banner:, interstitial:, rewarded:)` (line 40). **No caller wires real ids today** — you must either add a `--dart-define` read in `main.dart` and pass to `configure()`, or hardcode the real units. | The ad surfaces that earn money (banner + interstitial on the pre-trip/arming surface only; rewarded is optional — see C3). | **YES for revenue.** Test units serve test ads and pay nothing. Note: `AdPolicy` still forbids ads on any alarm/wake/lock surface — do not relax that. |
| A5 | **Pro price** | `lib/services/monetization/monetization_service.dart` → `proPriceFallback = '₹199'` (line 26). Real localized price is pulled live from Play via `proPriceOrFallback()` (line 126) once the SKU exists in Play Console. Product id: `lib/services/monetization/premium_service.dart` → `proOneTime = 'geowake_pro_onetime'` (line 28), a **one-time non-consumable**. | The Pro unlock price shown on the paywall CTA ("Unlock forever — ₹199"). | **YES to configure in Play** (the SKU `geowake_pro_onetime` must exist or purchases fail), but the **₹199 number itself is a founder decision** — see C2. The fallback string only shows if the store query fails; keep it matched to the real Play list price. |
| A6 | **Play App Signing SHA-256** | Play Console → *App integrity* (App Signing) provides the cert SHA-256 after you upload. Consumed in **two** places: (1) the Maps key restriction (A2); (2) the App Links proof file `backend/share/…/.well-known/assetlinks.json` served by the Railway share backend (must list the SHA-256 fingerprint for host `geowake-share-production.up.railway.app`, `AndroidManifest.xml` line 72, `autoVerify="true"`). | Enables verified HTTPS App Links (share links auto-open the app, no chooser) and locks the Maps key to your signed build. | **YES for the verified App-Link path.** Until the SHA-256 is in `assetlinks.json` and redeployed, share links fall back to the working custom scheme `geowake://j/{id}`. Not a launch blocker for the free viral loop, but needed for the polished HTTPS experience. |
| A7 | **Telemetry endpoint + token** | `lib/main.dart` lines 43 & 45: `--dart-define=GEOWAKE_TELEMETRY_URL=…` and `--dart-define=GEOWAKE_TELEMETRY_TOKEN=…`, passed to `TelemetryService.configureDefaultSinks()` (line 88) → `HttpTelemetrySink` (`lib/services/telemetry/http_telemetry_sink.dart`). **Empty endpoint = hard no-op** (inert by construction). | Optional: ship PII-free crash/funnel events to a founder-owned backend. | **No.** Optional and OFF by default. Only set if you stand up a telemetry backend (B4). Leaving it empty keeps telemetry local-only (the shipped, privacy-safe default). |
| A8 | **SMS-gateway creds (Guardian auto-push)** | `lib/services/share/guardian_service.dart` → `GuardianAutoSender` typedef (line 50) / `autoDeliverySender` field (line 103). **Null by default → no automatic send exists.** A founder must write a sender (Twilio/WhatsApp Business/FCM backend) and inject it via `GuardianService.init(autoSender:)`. | Would let Guardian mode deliver "journey started / arrived safely" **without** the user tapping the SMS/WhatsApp composer. | **No — and think twice before enabling (see C).** Guardian works **today** via the user-mediated composer (no gateway, $0 cost). A silent auto-sender adds real recurring cost + a DPDP/consent surface. Leave null unless there's demand. |
| A9 | **Custom App-Links domain** (optional upgrade) | Default is the Railway host, hardcoded in `lib/services/share/share_link_builder.dart` line 24 (`https://geowake-share-production.up.railway.app`) and `AndroidManifest.xml` line 72. Overridable at build via `--dart-define=GEOWAKE_SHARE_DOMAIN=…` / `GEOWAKE_SHARE_BASE_URL=…` (`lib/services/share/share_backend_config.dart` lines 29–44). | A branded share domain (e.g. `geo.wake` / `geowakeapp.com`) instead of a `railway.app` subdomain — nicer for the viral loop and not tied to the Railway free tier. | **No.** The Railway domain works today. Only worth it once the share loop has traction; requires re-hosting `assetlinks.json` on the new domain + re-verifying. |

### Build command that already bakes in the share token
From `docs/HANDOFF_TESTING.md` — the debug build wires the live-share bearer:
```
flutter build apk --debug \
  --dart-define=GEOWAKE_SHARE_TOKEN=<bearer>
```
The share **bearer token** (`GEOWAKE_SHARE_TOKEN`, read in `share_backend_config.dart`
line 35) is a **separate secret from A6's signing SHA** — it authenticates the app
to the Railway share backend. It already has a working value in the handoff; rotate
it if it was ever exposed publicly.

---

## Part B — ACCOUNTS TO CREATE

| # | Account | Cost | Why / notes | Priority |
|---|---|---|---|---|
| B1 | **Google Play Developer account** | **$25 one-time** | The publishing account. **New-account gotcha (do this early):** personal developer accounts created after Nov 2023 must run **closed testing with ≥12 testers for ≥14 continuous days** before you can apply for production access — commonly called the "20-tester rule" (Play asks you to recruit ~20 testers to be safe). This is a **hard, time-gated dependency**: you cannot ship to production on day one. Start recruiting testers and running an internal/closed track **now**, in parallel with everything else. Register under the correct entity — an **organization** account (needs D-U-N-S) vs personal changes the rule and your liability posture; for a data-selling future (Part C), an org entity is cleaner. | **First. Blocks launch and has a 2-week clock.** |
| B2 | **AdMob account** | Free | Provides the real App ID (A3) + unit ids (A4). Link it to the same Google account as Play. You'll declare the app, create banner/interstitial (and optionally rewarded) units, and complete the AdMob + Play **Data safety / ad-content** declarations. New apps often serve blank/low-fill for the first days — expected. | **High** (needed for ad revenue; not needed to publish a free build). |
| B3 | **Buy Me a Coffee** | Free | Provides the handle for A1. 30-second signup. Lowest-effort money path. | **Low / quick win.** |
| B4 | **Telemetry backend** (optional) | ~$0–5/mo | Only if you want remote crash/funnel visibility (A7). Could be a second small Railway/Node service mirroring `backend/share/server.js`. **Skip for v1** — local telemetry + the user-initiated "Report a problem" flow already covers your needs at zero cost and zero privacy risk. | **Optional / defer.** |
| B5 | **SMS / WhatsApp gateway** (optional) | Metered (Twilio ~$0.01+/SMS; WhatsApp Business per-conversation) | Only if you enable Guardian **auto**-delivery (A8). Recurring per-message cost + business verification (esp. WhatsApp). **Recommend NOT creating this for v1** — the composer path is free and works. | **Optional / defer, likely never.** |
| B6 | **Railway (share backend)** — already exists | Free tier (scale-to-zero) | The journey-share service is deployed at `geowake-share-production.up.railway.app` (already live). Note the **free-tier deploy window**: Railway blocks deploys 8am–8pm SGT, so the `assetlinks.json` redeploy (A6) must be run off-peak (`cd backend/share && railway up`). Consider a paid plan or the custom domain (A9) if the share loop scales. | **Exists; only needs the assetlinks redeploy.** |
| B7 | **Indian privacy counsel** (for the data business only) | Retainer | Not an "account," but a required engagement **before any data egress** — see C5. Not needed for the app itself. | **Deferred** (Phase A of the data business). |

---

## Part C — STRATEGIC DECISIONS (recommendation on each)

### C1 · Monetization model — one-time unlock vs subscription
**Recommendation: keep the shipped model — a single one-time non-consumable Pro
unlock (`geowake_pro_onetime`), no subscription.**
- The code already commits to this (`premium_service.dart` line 28: "one-time,
  non-consumable Pro unlock. Lead SKU for India"). Don't re-architect.
- **Why one-time for India:** subscription fatigue is high and trust is low for a
  small indie utility; a wake-alarm is a "set once, rely forever" tool, not a
  content service that justifies recurring billing. A cheap one-time unlock
  converts far better here and generates goodwill.
- **Trade-off to accept:** no recurring revenue — your income is (installs × Pro
  conversion × price) + ad revenue from free users. That's fine for a utility;
  it's the honest shape (see C8).
- The invariants hold this in place: **the never-late core alarm, backstop,
  basic reliability, and one active route are ALWAYS free** (`HANDOFF_TESTING.md`
  §1). Pro is *convenience*, never *reliability*. Never move the core behind the
  paywall — that's a P0 product-integrity bug, not a pricing lever.

### C2 · Pro price point
**Recommendation: launch at ₹149 (test ₹99 vs ₹199), one-time.**
- The code fallback is ₹199 (`monetization_service.dart` line 26). That's a
  defensible anchor, but for a **first-time indie app with a mostly-thin Pro tier
  today** (see C4 — only ad-free is a rock-solid benefit right now), ₹199 may
  over-ask.
- Concrete guidance: set the real Play SKU at **₹149** to start. It clears the
  psychological ₹200 barrier, still meaningfully above ₹99 "impulse" pricing, and
  is easy to A/B against ₹99 and ₹199 once you have install volume. Update
  `proPriceFallback` to match whatever you set in Play so the CTA never
  mismatches the store.
- **Raise to ₹199+ only after** Guardian mode and the home widget are verified
  real on-device (C4) — i.e., once Pro is worth more than ad removal.
- Regional pricing: Play lets you set India-specific pricing; keep the headline
  price INR-native (the CTA already renders `₹`).

### C3 · Rewarded-ad economics
**Recommendation: do NOT build a rewarded-ad loop for v1. Keep banner +
interstitial on the pre-trip surface only; leave the rewarded unit inert.**
- A rewarded unit id exists (`_testRewarded`) but wiring it means inventing a
  "watch an ad to unlock X" mechanic — and the two things worth unlocking (never
  fire late, core alarm) are **permanently free by invariant**. There's nothing
  ethical to gate behind a rewarded ad in a safety-adjacent wake alarm.
- Rewarded ARPU only matters at scale you don't have yet, and a "watch a 30s
  video to arm your trip" flow is exactly the kind of friction that breaks trust
  for a sleepy commuter. The eCPM upside is not worth the UX/trust cost.
- **If ever revisited:** the only defensible use is a *temporary* ad-free session
  or a cosmetic, never anything touching reliability. Park it.

### C4 · Build/keep the home widget (and the rest of the Pro tier)
**Recommendation: the Pro tier has been correctly trimmed — now VERIFY the three
survivors on-device before charging for them.**
- The paywall was trimmed (commit `9064b0e`) to **four** items only
  (`paywall_screen.dart` lines 33–43): **Guardian mode**, **Custom & escalating
  alarm**, **Home widget**, **Ad-free**. Wear OS and Family alarms — previously
  advertised and unbuilt — are **gone from the paywall.** Good: that closes the
  false-advertising / Play-policy risk flagged in `HANDOFF_TESTING.md` §5/§9.
- **Home widget — keep it, but prove placement.** A real native widget now
  exists (`GeoWakeWidgetProvider.kt`, `res/layout/`, `res/xml/`,
  `geowake_widget_*` drawables — all in the current git status as new files).
  The handoff's older "widget is a stub" line is **stale**; the native side
  landed. **Action for the next agent: place the widget on the real device home
  screen and confirm one-tap arm actually works.** Only then is it a legitimate
  paid benefit. If placement fails on-device, drop it from the paywall until
  fixed — do not charge for a widget a user can't place.
- **Guardian mode — keep; it works today** via the user-mediated SMS/WhatsApp
  composer (auto-share on arm, "arrived" via backend, no composer over the
  alarm). Do **not** rush the paid auto-sender (A8/B5) — the free composer path is
  a genuine benefit at $0 cost.
- **Custom & escalating alarm — keep, but confirm it's actually gated.** The
  handoff flagged that `RingtonesScreen` shipped free with `canUseCustomAlarmSounds`
  having zero callers; the memory says custom sounds are now Pro-gated. **Verify
  on-device that a free user cannot pick a custom tone / escalation** — if the
  gate still isn't wired, either wire it or remove the claim.
- **Net:** of the four advertised Pro items, **Ad-free is the only
  never-in-doubt benefit.** The other three are plausibly real now but each needs
  a device check before you take money. That is the single most important
  pre-launch integrity task: *do not sell Pro until every advertised Pro line is
  device-verified.*

### C5 · The mobility-data business — GO / NO-GO
**Recommendation: PURSUE-AFTER-SCALE. Keep egress OFF. Do nothing that costs
engineering time now. This is an optionality/acquirer asset, not a year-1 revenue
line.** (Full memo: `docs/data_business/STRATEGY.md`.)

Summary of the memo's verdict:
- **~$0 in year 1**; optimistically one pilot/per-study license **$5k–$30k by
  year 2–3**, and only if a single metro scales *and* a sympathetic buyer appears.
  The Indian buyer (metro corps, MoHUA/CMP consultants) procures household surveys
  and consultancy through slow, tender-driven, lowest-bidder cycles — **not**
  app-data subscriptions.
- **Hard cold-start wall:** the product is k-anonymous (k≥100 contributing users
  per cell) + differentially-private aggregate O-D counts. At launch density,
  essentially **every sellable cell fails the k=100 floor → nothing to sell.** A
  single device cannot even mint a transmittable cell by construction (this is why
  the pipeline is inert today: `kDataAssetEgressEnabled = false` in
  `data_asset_config.dart` line 21, empty endpoint line 29, `NullEgressSink`).
- **The four-part conjunctive trigger** before flipping egress (all must be true):
  **(1)** one metro at **~20–50k concentrated opt-in daily riders**; **(2)** a
  signed **DPIA + counsel opinion**; **(3)** a **named, contracted buyer**
  (per-study license, ~₹1–3 lakh — sell to *consultants* B2B2G, not metro
  procurement); **(4)** **Play-safe sale mechanics** (transfer only true
  aggregates as a data *product*, separate unbundled opt-in, precise Data-safety
  disclosure).
- **Why keep the option open:** the privacy guardrails are already shipped and
  cost ~nothing to maintain; the asset has value as a product-improvement input
  (better O-D models improve the wake-alarm itself) and as an acquisition story,
  and it's legally-by-construction differentiated from the dead cohort of raw-
  location brokers (SafeGraph Patterns discontinued, Near Intelligence Ch.11,
  Gravy/Venntel FTC-banned).
- **Founder Phase-A actions that are near-zero cost (optional, do only if you
  want the option live):** (a) publish an anonymization-methodology paper with an
  academic partner (IISc CiSTUP / WRI India); (b) secure 1–2 non-binding LOIs from
  CMP consultants; (c) draft the DPIA (skeleton in STRATEGY.md Appendix A). **None
  of this is engineering. None of it blocks the app.**
- **Bright line to never cross:** never store or sell an individual trajectory;
  only k≥100 + DP aggregates may ever egress (`HANDOFF_TESTING.md` §1.3). Today
  **zero data leaves the device** — keep it that way until all four gates trip.

### C6 · Legal (DPDP 2023, DPIA, counsel)
**Recommendation: for the *app*, ship with a precise Play Data-safety disclosure
and the default-OFF unbundled data-consent flow already built — no counsel gate.
For the *data business*, counsel is a hard, non-negotiable gate before any egress.**
- **DPDP Act 2023 (Rules notified 13 Nov 2025):** truly anonymized aggregate data
  is *outside* the Act, but India uses an unquantified "reasonable risk of
  re-identification" standard — defensibility is earned by **documented
  governance (DPIA), not the "anonymized" label.** The app's default-OFF,
  purpose-specific, unbundled opt-in already meets the DPDP consent standard for
  the collect+aggregate step.
- **Google Play is the harder gate than DPDP.** Play's User Data policy prohibits
  "selling personal/sensitive data," treats precise location as sensitive, and
  offers **no explicit safe-harbor for aggregated data.** So even fully
  DPDP-compliant, the app can be pulled if the sale *looks* like a data sale.
  Mitigation is structural: sell an aggregate **product**, not user data;
  separate unbundled opt-in; airtight Data-safety wording.
- **DPIA:** statutorily mandatory only for a Significant Data Fiduciary (you're
  unlikely to be one at launch), but **strongly advisable** as the best
  evidentiary shield for both re-identification and Play review. Voluntary now.
- **Counsel engagement (B7)** is required specifically for: the DPIA sign-off, a
  written opinion that the aggregate-product sale stays outside Play's "sale"
  definition, and the DPDP consent/notice review. **This opinion is the A→B gate
  of the data business and must precede any egress** — but it is **not** a blocker
  for shipping the app itself.

### C7 · Play publishing track choice
**Recommendation: Internal testing now → Closed testing (satisfy the 12-tester /
14-day rule) → Production.**
- **Internal testing** first: instant, up to 100 testers, no review delay — use it
  to iterate the device-verification pass (C4) with your own accounts.
- **Closed testing** next: this is the track that **satisfies the new personal-
  account requirement** (≥12 testers, ≥14 continuous days) that unlocks production
  access. **Start this the day the account is created (B1)** — the 14-day clock is
  the longest pole in the launch schedule.
- **Production** only after: the closed-testing requirement is met, every
  advertised Pro line is device-verified (C4), real AdMob ids are in (A3/A4), and
  the Maps key is rotated + restricted (A2).
- Skip open testing unless you specifically want a public beta for reviews.

### C8 · The honest frame — is this a business or a good app?
**Recommendation: treat GeoWake as a genuinely good app with a modest,
self-funding monetization tail — not a venture-scale business — and resource it
accordingly.**
- **The honest revenue picture:** a one-time ₹149 Pro unlock (thin tier today,
  mostly ad-removal) plus banner/interstitial ad revenue from free users plus a
  tip jar. That is **pocket-money-to-side-income economics**, not a startup P&L.
  The data business is **~$0 for the foreseeable future** and is explicitly an
  optionality/acquirer asset, not income (C5).
- **Where the real value is:** the product itself — a never-late transit wake
  alarm that survives GPS blackout underground. That's a legitimately useful,
  trust-critical tool with a clear promise. The moat is *reliability and
  privacy-by-construction*, not monetization cleverness.
- **The trap to avoid:** letting the data-business narrative or Pro-tier padding
  distract from the core. Every hour spent on a silent SMS gateway, a rewarded-ad
  loop, or a merge backend is an hour not spent making the alarm more reliable —
  and reliability is the entire product (risk R8 in STRATEGY.md).
- **So the frame is:** build the best free never-late alarm in India, monetize it
  lightly and honestly (ad-free Pro + a few verified conveniences + ads for free
  users), keep the data-asset guardrails warm as free optionality, and let scale —
  not roadmap dates — decide whether a business ever emerges. **Ship a great app
  first; the business, if any, follows the users.**

---

### Cross-references
- Full data-business memo, gates, DPIA skeleton: `docs/data_business/STRATEGY.md`
- What's real vs. hollow, invariants, test plan, known gaps: `docs/HANDOFF_TESTING.md`
- Pro price / product id: `lib/services/monetization/monetization_service.dart`,
  `lib/services/monetization/premium_service.dart`
- Ad ids / policy: `lib/services/monetization/ad_service.dart`
- Maps key injection: `android/app/build.gradle`, `android/key.properties` (gitignored)
- Share/App-Links config: `lib/services/share/share_backend_config.dart`,
  `lib/services/share/share_link_builder.dart`, `android/app/src/main/AndroidManifest.xml`
- Guardian auto-sender seam: `lib/services/share/guardian_service.dart`
- Data-egress flags: `lib/services/data_asset/data_asset_config.dart`
