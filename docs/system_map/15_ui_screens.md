## 15. UI: Screens, Widgets, Theme, Arming & Tracking Flow

**Role in the core promise:** This is the *entire human surface* of GeoWake — the screens where a rider picks a destination, tells the app "wake me N km / N minutes / N stops before my stop," confirms they're about to sleep, and then watches (or ignores) a live map until the alarm fires. Nothing in this subsystem *decides* whether the alarm goes off — that is the background tracking/notification stack (subsystems 07/09/12). What this subsystem *does* own is: (1) capturing the rider's intent correctly and un-ambiguously, (2) validating the request enough that a person is willing to fall asleep on the strength of it, (3) persisting the armed session so a phone that gets killed underground can restore it, (4) giving honest, non-panic feedback when GPS dies in a tunnel, and (5) staying out of the way (the map, the Wake-Me button, and the wake alarm must never be covered by an ad). If the UI captures the wrong threshold, silently drops the request, or lets a rider *think* they're armed when they aren't, the core promise is broken before the physics engine ever runs. So the UI's job against the promise is mostly **truthfulness and durability**, not cleverness.

---

### Files

| Path | What it does |
| --- | --- |
| `lib/screens/homescreen.dart` (1920 lines) | The arming screen. Search/autocomplete, map-tap destination, recent-trip chips, mode/threshold controls, permission + validation gauntlet, pre-arm confirmation, snapshot persistence, and hand-off to the tracking screen. The single most important file in this subsystem. |
| `lib/screens/maptracking.dart` (1534 lines) | The live tracking screen. Draws the route, snaps the user marker, shows ETA/distance/transfer notices, a "no-GPS, estimating from motion" banner, and the alarm-time UI (STOP / SNOOZE / END TRACKING). |
| `lib/screens/splash_screen.dart` (211 lines) | First screen on launch. Initializes core services, detects a zombie/firing alarm state, and restores an in-progress tracking session (or goes home). |
| `lib/screens/otherimpservices/preload_map_screen.dart` (87 lines) | A throwaway "warm the Google Map engine" screen inserted between arming and tracking to avoid a janky first map paint. |
| `lib/screens/otherimpservices/recent_locations_service.dart` (85 lines) | Hive-backed persistence for the raw "recent locations" list (distinct from the higher-level RouteMemory). Corruption self-heals. |
| `lib/screens/ringtones_screen.dart` (264 lines) | Ringtone catalog + preview + "Test my alarm now" (fires the *real* alarm path so the rider can prove it wakes them). |
| `lib/screens/settingsdrawer.dart` (162 lines) | The hamburger drawer: theme toggle, preboarding/destination-only alarm toggle, ringtones, an unimplemented "Go Premium" item, close. |
| `lib/widgets/gated_banner_ad.dart` (70 lines) | A banner ad that renders *nothing* unless a real ad is loaded and policy permits. Collapses to zero height for Pro / no-fill. |
| `lib/widgets/post_arrival_card.dart` (91 lines) | Presentational card for the post-arrival "last-mile" offer (ride/food/directions). Pure view; host wires the actions. |
| `lib/widgets/pulsing_dots.dart` (47 lines) | A three-dot "still calculating" animation shown next to ETA/distance until real numbers arrive. |
| `lib/themes/appthemes.dart` (51 lines) | Light/dark `ThemeData` (Material 3, deepPurple swatch, Montserrat body font). |

Two collaborators outside the assigned set but load-bearing for this subsystem: `lib/main.dart` (registers the four named routes and owns `MyAppState.toggleTheme` / `isDarkMode`, which the drawer reaches up into) and the many `services/*` classes consumed below.

---

### How it works, step by step

#### A. Launch → route restore (`splash_screen.dart`)

1. `main.dart` sets `initialRoute: '/splash'` and picks `AppThemes.darkTheme` or `lightTheme` from `MyAppState.isDarkMode` (`main.dart:159`).
2. `SplashScreen.initState` (`splash_screen.dart:29`) kicks off two things in parallel: cosmetic animations (a pulsing logo + a fade/slide "GeoWake" wordmark), and `_initFuture = _initializeServices()` (`:50`).
3. `_initializeServices` (`:54`) awaits, in order, `ApiClient.instance.initialize()` (secures API calls first), `NotificationService().initialize()`, then `TrackingService().initializeService()`. Each is individually try/caught so one failure doesn't abort the others.
4. `_checkStateAndNavigate` (`:82`) runs the restore logic:
   - **Zombie alarm check:** if `TrackingStateStore.isAlarmFired()` is true (the app was killed while the alarm was ringing), it calls `TrackingService().completeEndTracking(navigateHome:false)` to tear everything down and goes to `'/'`. (`:84–91`)
   - It waits on `_initFuture` with an **8-second timeout** (`:96`) — if services hang, it continues anyway.
   - **Session restore:** if `TrackingStateStore.isActive()` is true, it loads the snapshot. If the snapshot is null *or* `snapshot.directions == null`, it treats the session as corrupt, tears down, and goes home (`:112–121`). Otherwise it `pushReplacementNamed('/mapTracking', …)` passing lat/lng/name/directions/metroMode/userLat/userLng/mode/value (`:125–138`).
   - **Normal path:** a 3-second timer, then `pushReplacementNamed('/')` — deliberately going *straight home* rather than flashing a map (`:141–145`).

#### B. Arming a trip (`homescreen.dart`) — the critical path

State that encodes the rider's intent (`homescreen.dart:49–57`): `_useDistanceMode` (default `true`), `_metroMode` (default `false`), and three sliders — `_distanceSliderValue = 5.0` km, `_timeSliderValue = 15.0` min, `_stopsSliderValue = 2.0` stops. Plus flags `_isTracking`, `_isLoading`, `_noConnectivity`, `_lowBattery`.

1. **initState** (`:78`): loads recent locations, loads RouteMemory (saved-trip chips), starts battery monitoring, subscribes to connectivity, fetches current location and drops a marker, and wires a search-focus listener that shows the top-3 recents when the empty search box is focused.
   - **Connectivity semantics** (`:86–102`): the device is treated as offline **only when every** reported interface is `ConnectivityResult.none` (some phones report multiple interfaces). On change it calls `_offline.setOffline(...)` and `TrackingService().setOnline(...)` so the reroute logic downstream knows.
   - **Battery** (`:201`): `_lowBattery` is set when level `< 25`. It re-samples on every battery-state change.
2. **Choosing a destination** — three input paths, all funnel into `_setSelectedLocation` (`:406`), which sets `_selectedLocation = {description, lat, lng}`, writes the search field, drops a *draggable* marker (dragging updates lat/lng), and animates the camera to zoom 14.
   - **Search/autocomplete** (`_onSearchChanged`, `:333`): 450 ms debounce; merges local recent-location substring matches with `PlacesService.fetchAutocompleteResults(...)` (biased by country code + current lat/lng), de-duplicated by `place_id`. Selecting one (`_onSuggestionSelected`, `:378`) fetches place details and records it into recents.
   - **Map tap** (`_handleMapTap`, `:164`): a hand-rolled tap disambiguator. A second tap within **300 ms** *and* within **40 m** (`Geolocator.distanceBetween`) is treated as a double-tap → zoom in and cancel the pending single-tap. Otherwise a single tap is debounced **280 ms** then `_setDestinationFromLatLng` runs. That setter (`:132`) sets the label to "Dropped pin" *immediately* (responsive even offline), then reverse-geocodes via `ApiClient.geocode` and upgrades the label only if the rider hasn't moved the pin since.
   - **Recent-trip chip** (`_armSavedRoute`, `:518`): one tap re-applies the saved alarm mode/value onto the same state fields the Wake-Me flow reads, sets the destination, and calls `_onWakeMePressed()` directly.
3. **Threshold entry**: a `Slider` (`:1651`) whose min/max/divisions switch by mode — distance `0.5–10` km (19 divisions), stops `1–10` (9 divisions, rounded to integers), time `1–60` min (59 divisions). Tapping the value label opens `_EnterValueDialog` (`:1843`) for exact numeric entry, then re-clamps to the same ranges.
4. **Wake Me!** (`_onWakeMePressed`, `:642`):
   - Guards on `_selectedLocation == null` (error dialog, abort).
   - Sets `_isLoading = true`, then `PermissionService(context).requestEssentialPermissions()`. If denied, resets loading and stops (the permission service already showed its own dialog).
   - On grant: `_maybeShowReliabilityDisclaimer()` (G24 — a **one-time** "please keep a backup alarm" dialog, gated by the `reliability_disclaimer_shown` pref so it never nags again), then `_isTracking = true`, then `_proceedWithDirections(stopwatch)`.
5. **`_proceedWithDirections`** (`:686`) — the long validation gauntlet:
   - **Position:** reuse `_currentPosition` if `_lastPositionTime` is `< 30 s` old (synthesizing a `Position` with a hardcoded `accuracy: 10`), else `Geolocator.getCurrentPosition()`. Null → "Location Error", abort. (`:693–732`)
   - **Same-state validation** started early as a parallel future (`_validateSameState`, `:263`): reverse-geocodes origin and destination, compares `administrative_area_level_1` short_names case-insensitively. **Fails *open*** (returns true) if either state is undeterminable or the call throws.
   - **Metro validation** (if `_metroMode`): `MetroStopService.validateMetroRoute(...)`; on failure shows "Metro Route Unavailable" and aborts, else snaps the destination to the closest metro stop.
   - **Directions:** `_fetchDirections` (`:1330`) → `OfflineCoordinator.getRoute(...)` (which can serve a cached route offline).
   - **Await same-state result;** if different states → "Route Not Available … cross state boundaries are not supported" and abort. (`:791–801`)
   - **Sanity ceiling** (G18, `:812–830`): total planned duration across *all* legs (`TransferUtils.totalPlannedDurationSeconds`) is only rejected above `24*3600 = 86400 s`. Long sleeper journeys are *intentionally not capped*; only >24 h (assumed corrupt/looping data) is refused.
   - **Compute alarm mode/value** (`:835–843`): `'distance'` or `'time'`; the special case `_metroMode && _useDistanceMode` becomes `'stops'` with value `_stopsSliderValue`.
   - **Stops-mode validation** (`:846–969`): builds step boundaries + cumulative stop counts (`TransferUtils.buildStepBoundariesAndStops`, `metroOnly:_metroMode`) and route events, appends a synthetic `destination` event if missing, then runs `StopLogicEngine.validateThreshold(...)` (rejects a threshold larger than the first segment can support) **and** `validateThresholdAgainstMetroLegs(...)` (rejects `n ≥ min(stops)` across metro legs). Either failure → "Invalid Stops Threshold" and abort.
   - **Pre-arm confirmation** (`_showPreArmConfirmation`, `:1191`): clears the spinner, then shows a dismissible bottom sheet titled "Ready to sleep?" that resolves the abstract setting into a concrete sentence — e.g. "We'll wake you 2 stops before Majestic," "…3.0 km before …," "…15 min before …" — plus the ETA ("Arriving … in ~2.5 hr"). Returns true only on explicit "Wake me"; "Not yet" aborts arming cleanly.
   - **Persist snapshot BEFORE starting** (`:999–1031`): in parallel `TrackingStateStore.setActive(true)`, `setAlarmFired(false)`, `setNotificationsMuted(false)`, then `saveSnapshot(TrackingSnapshot(... directions ...))`. This is what Splash restores. Wrapped in try/catch so a persistence failure doesn't kill arming.
   - **Reliability preflight** (`:1038–1043`): `ReliabilityPreflightRunner.run()`; if not OK, `showReliabilityPreflightDialog(context, preflight)`. Entirely fail-open and non-blocking — the comment is explicit that reliability is *never* gated (`PremiumService.canUseCoreAlarm`).
   - **Start tracking** (`:1045`): `trackingService.startTracking(destination, destinationName, alarmMode, alarmValue, transitMode:_metroMode)`.
   - **Fire-and-forget side effects:** `_recordRouteMemory(...)` (recents/frequency, origin captured for cache reuse), `registerRouteFromDirections(...)`, and `FlutterBackgroundService().invoke("updateRouteData", {initialETA})`.
   - **Navigate:** builds `mapArgs` (destination, mode, value, metroMode, directions, userLat/Lng, dest lat/lng) and `pushReplacementNamed('/preloadMap', arguments: mapArgs)`. (`:1102–1130`)
6. **build** (`:1370`): `Scaffold` with a `SettingsDrawer`, an app bar (Pacifico "GeoWake" title + a Metro-Mode `Switch` disabled while tracking), a `bottomNavigationBar` of `GatedBannerAd(AdPlacement.routeArming)`, and a scrollable body wrapped in `AbsorbPointer(absorbing:_isTracking)` (freezes input once arming begins). Body order: offline banner (amber) → search field → autocomplete list → recent-trip chips → a `GoogleMap` (30% screen height, default camera **Bengaluru 12.9716,77.5946 @ z12**) → Time↔Distance/Stops switch → threshold label+slider → the **Wake Me!** button (enabled only when a destination is selected, the field is non-empty, and not loading/tracking) → a decorative low-battery button.

#### C. Live tracking (`maptracking.dart`)

Entry is via `PreloadMapScreen` (`preload_map_screen.dart`): it builds a bare `GoogleMap` at the destination, waits for `onMapCreated`, then a fixed **300 ms** timer `pushReplacementNamed`s to `/mapTracking` with the same args — a deliberate hack to warm the native map so the tracking screen's first paint isn't janky.

1. **didChangeDependencies** (`maptracking.dart:230`): reads `ModalRoute.settings.arguments`. If `lat`/`lng`/`destination`/`directions` are missing → post-frame error dialog + pop (`:246–266`). Otherwise sets destination + `_metroMode`, derives `_isMetroTimeMode` (`_metroMode && mode == 'time'`), seeds markers, and builds polylines:
   - **Metro** (`:331–364`): `DirectionService.buildRawSegments(directions, true, simplify:false)` for physics, `buildSegmentedPolylinesFromRawSegments(...)` for display; flattens raw high-res points into `_routePoints` for snapping; then computes route length, transfer boundaries, step boundaries/durations, initial metrics, and fits the camera.
   - **Non-metro** (`:365–444`): same, `simplify` default; falls back to decoding+simplifying the `overview_polyline` if step segmentation is empty.
   - Then `_startLocationUpdates()` and four stream subscriptions: route-switch banner, **simulated** positions (`locationStream`), authoritative **ETA** (`etaSecondsStream`, from the background EtaEngine), and **active-route state** (`activeRouteStateStream`, for remaining distance + pending transfer).
2. **Foreground GPS** (`_startLocationUpdates`, `:731`): `Geolocator.getPositionStream` at `LocationAccuracy.high`, `distanceFilter: 5 m`; each fix runs `_handlePositionUpdate` and is broadcast via `LocationManager().broadcastPosition(...)` for the dashboard.
3. **`_handlePositionUpdate`** (`:569`): stamps `_lastPositionAt` (resets the GPS-stale clock), updates a speed EMA (`0.8*old + 0.2*new`), snaps the point onto `_routePoints` (`SnapToRouteEngine.snap`, `searchWindow: 30`, hint index for continuity), computes remaining meters, and derives an ETA by **blending** step-duration ETA with speed ETA: speed ETA gets a `speedSafetyFactor = 1.20`, and step ETA is capped at `maxStepInflationVsSpeed = 1.50×` the buffered speed ETA (so a stale schedule can't wildly over-estimate). It recomputes the "switch routes in N min" transfer notice, rebuilds the "remaining route" polylines (throttled — only when progress moves ≥ 5 m), and repaints the current-location marker.
4. **GPS-out reassurance** (`:84–147`, `:1157–1194`): a `Timer.periodic(3 s)` (`_evaluateGpsFreshness`) flips `_gpsEstimating` true once no fix has arrived for `_gpsStaleAfter = 12 s`. That recolors the user marker orange ("Estimating position (no GPS)") and shows a deep-orange banner: "No GPS (tunnel) — estimating position from motion. Still counting down to <stop>." It only engages after at least one real fix, so it never shows on cold start.
5. **Alarm-time UI** (`_refreshFinalAlarmState`, `:153`; build `:1252+`): driven by `AlarmPlayer.isPlaying` (a `ValueListenable`). `_finalAlarmActive` becomes true only when the alarm is playing *and* `TrackingStateStore.pendingAlarmAllowContinue()` is false (i.e. this is the terminal destination alarm, not a preboarding leg alarm). In that state the screen shows "You've reached <stop> — Time to get off." with two buttons:
   - **SNOOZE** (`_onSnoozePressed`, `:179`) — one-shot only (`_snoozeUsed`): stops the current alarm, keeps the session alive, and arms a **60 s** `_maybeReAlert` timer that re-fires the *real* alarm via `NotificationService().showWakeUpAlarm(...)` — but only if `TrackingStateStore.isActive()` is still true. Deliberately one-time so it can never loop-suppress a needed alarm.
   - **END TRACKING** — `AlarmPlayer.stop()`, `TrackingService().completeEndTracking(navigateHome:false)`, then `pushReplacementNamed('/')`.
   When the alarm is *not* the terminal one, the layout instead shows a **STOP ALARM** button (enabled only while `AlarmPlayer.isPlaying`) next to END TRACKING.
6. **Back button** (`:1041`): `PopScope(canPop:false)` — the rider *cannot* leave tracking with the system back gesture; they must press END TRACKING. (The invalid-args error path at `:1027` is a plain Scaffold *without* PopScope, so it's escapable.)

#### D. Supporting screens/widgets

- **Ringtones** (`ringtones_screen.dart`): a hardcoded catalog of 11 One-UI `.ogg` files (`:42–54`); tap-to-select persists to the `selected_ringtone` pref; a play/pause preview uses `audioplayers`. The FAB "Test my alarm now" (`:114`) fires the **production** alarm path (`NotificationService().showWakeUpAlarm(... playSound:true)`), auto-stops after 5 s, and is stoppable from the SnackBar — so a rider can *prove* the alarm wakes them before betting a trip on it.
- **SettingsDrawer** (`settingsdrawer.dart`): reaches up with `context.findAncestorStateOfType<MyAppState>()` to read `isDarkMode` and call `toggleTheme()`. `_PreboardingToggleTile` reads/writes either `TrackingStateStore.preboardingEnabled()` (normal metro) or `destinationOnlyMetroTimeEnabled()` (metro+time mode), and is disabled unless `metroModeEnabled`. "Go Premium" has an **empty onTap** (unimplemented).
- **GatedBannerAd** (`gated_banner_ad.dart`): in `initState`, if `MonetizationService.instance.premiumOrNull == null` (monetization not ready) it does nothing; else `AdService.instance.createBanner(...)`. `build` returns `SizedBox.shrink()` unless `_ad != null && _loaded`. All "should we show" logic lives in AdService/AdPolicy; this widget only trusts the null contract.
- **PostArrivalCardWidget** (`post_arrival_card.dart`): pure presentational card; splits `card.actions` into primary (`FilledButton`) and secondary (`OutlinedButton`), maps `kind` → icon, and calls `onAction(kind)`. The host wires that to affiliate deep-links or dismiss.
- **PulsingDots** (`pulsing_dots.dart`): a `Timer.periodic(period/3)` cycling which of three dots is enlarged — shown beside ETA/distance until the text contains "remaining"/"to destination".
- **AppThemes** (`appthemes.dart`): Material 3, `primarySwatch: Colors.deepPurple`, Montserrat body text; dark scaffold `0xFF303030`.
- **RecentLocationsService** (`recent_locations_service.dart`): Hive box `recent_locations`, single-flight open with **corruption self-heal** (on open failure it `deleteBoxFromDisk` + reopen), dedupe by `placeId ?? place_id ?? "lat,lng"`, cap `_maxItems = 15`.

---

### Key types & functions

| Type / function | Responsibility & signature |
| --- | --- |
| `HomeScreenState` (`homescreen.dart:36`) | Owns all arming state and the whole validation gauntlet. |
| `_onWakeMePressed()` → `Future<void>` (`:642`) | Entry to arming: permissions → disclaimer → proceed. |
| `_proceedWithDirections(Stopwatch)` → `Future<void>` (`:686`) | The gauntlet: position, same-state, metro, directions, sanity, stops validation, confirm, persist, preflight, start, navigate. |
| `_validateSameState({originLat,originLng,destLat,destLng})` → `Future<bool>` (`:263`) | Cross-state guard; fails open on ambiguity/error. |
| `_showPreArmConfirmation({destinationName,alarmMode,alarmValue,totalEtaSeconds,directions})` → `Future<bool?>` (`:1191`) | "Ready to sleep?" concrete-terms confirmation sheet. |
| `_maybeShowReliabilityDisclaimer()` → `Future<void>` (`:613`) | One-time "keep a backup alarm" dialog (pref-gated). |
| `_armSavedRoute(RouteMemory)` / `_recordRouteMemory(...)` (`:518` / `:485`) | One-tap re-arm and silent trip memory. |
| `_fetchDirections(...)` → `Future<Map>` (`:1330`) | Routes through `OfflineCoordinator.getRoute` (cache-capable). |
| `_EnterValueDialog` (`:1843`) | Manual numeric threshold entry, re-clamped by caller. |
| `_MapTrackingScreenState` (`maptracking.dart:35`) | Owns live tracking, snapping, ETA display, alarm UI. |
| `_handlePositionUpdate(Position)` → `void` (`:569`) | Snap + speed EMA + blended ETA + polyline trim + marker. |
| `_evaluateGpsFreshness()` / `_applyEstimatingToMarker(bool)` (`:114` / `:128`) | Tunnel/"no-GPS" indicator state machine (12 s threshold). |
| `_refreshFinalAlarmState()` → `Future<void>` (`:153`) | Decides terminal-alarm UI from `AlarmPlayer.isPlaying` + `pendingAlarmAllowContinue`. |
| `_onSnoozePressed()` / `_maybeReAlert()` (`:179` / `:206`) | One-shot snooze + guarded 60 s re-alert. |
| `SplashScreen` `_checkStateAndNavigate()` (`splash_screen.dart:82`) | Zombie-alarm cleanup + session restore. |
| `PreloadMapScreen` (`preload_map_screen.dart:6`) | Map warm-up + 300 ms handoff. |
| `GatedBannerAd` (`gated_banner_ad.dart:16`) | Zero-height-unless-real-ad banner. |
| `RingtonesScreen` `_testAlarmNow()` (`ringtones_screen.dart:114`) | Fires the real alarm to let the rider verify it. |
| `RecentLocationsService` (`recent_locations_service.dart:4`) | Hive recents with corruption recovery. |

---

### Design decisions (the WHY)

1. **Persist the tracking snapshot *before* starting the service, and restore it on launch.** *Why:* the flagship trip is a 6–10 h sleeper where the OS may kill the app mid-journey; if we started tracking first and crashed before persisting, a restart would have no idea a trip was armed and the rider would sleep past their stop. Writing `setActive(true)` + `saveSnapshot(... directions ...)` first (`homescreen.dart:999–1024`) means Splash can always rebuild the session (`splash_screen.dart:105–138`). *Trade-off:* a snapshot can go stale/corrupt; the code defends by treating `directions == null` as "clean up and go home." *Flaw:* the snapshot stores the *initial* origin and a full directions blob but the UI-layer restore doesn't re-validate freshness — a very old restored session just resumes.

2. **Reliability preflight and the backup-alarm disclaimer NEVER block arming (fail-open).** *Why:* the app's whole reason to exist is to fire an alarm; refusing to arm because we *couldn't confirm* the OS will cooperate would defeat the purpose and punish the rider for their phone's aggressive battery manager. So both the disclaimer (`:613`) and preflight (`:1038–1043`) are advisory only, wrapped in `try/catch {}`. *Trade-off:* a rider on a hostile OEM can arm a trip that the OS will later silence, and we merely warned them. *Flaw/risk:* this is the single biggest exposure to "alarm didn't fire" — the UI's mitigation is words (disclaimer + "Test my alarm now"), not enforcement.

3. **A concrete-terms pre-arm confirmation ("We'll wake you 2 stops before Majestic").** *Why:* a rider will only *sleep* if they trust the setting; an abstract slider value ("2") isn't trustworthy. Resolving it into a sentence with the real alighting-stop name and the ETA (`_showPreArmConfirmation`, `:1191`) converts intent into something a half-asleep person can sanity-check. *Trade-off:* one extra tap on every arm. *Flaw:* the stop name comes from `_lastAlightingStopName` best-effort parsing (`:1167`); if directions lack `transit_details.arrival_stop`, it silently falls back to the destination name, so the confirmation can be less specific than it looks.

4. **Cross-state routes are refused (`_validateSameState`).** *Why (as coded):* the metro/stop datasets and some routing assumptions are scoped per-state, so a cross-state route could be under-served. *Trade-off / SEVERE FLAW:* this directly contradicts the flagship use case. A 6–10 h Indian sleeper (e.g. Bengaluru→Chennai) crosses Karnataka→Tamil Nadu and would be **blocked** with "Routes that cross state boundaries are not supported," even though G18 (`:812`) explicitly calls long single-stop sleepers the flagship. The guard only fails *open* when a state can't be determined, so within-India inter-state trips that *do* resolve both states are actively refused. This is a headline contradiction against the core promise.

5. **Long journeys are intentionally *not* time-capped; only >24 h is refused (G18).** *Why:* capping at, say, 2 h would break the sleeper use case. Rejecting only `> 86400 s` (`:819`) treats absurd durations as corrupt route data, not real trips, and measures across *all* legs so a multi-leg trip isn't undercounted. *Trade-off:* a genuinely-corrupt 23 h route slips through. Reasonable.

6. **Map tap uses a hand-rolled single/double-tap disambiguator (300 ms + 40 m, 280 ms debounce).** *Why:* Google Maps' `onTap` fires per tap; to let a double-tap zoom *without* also dropping a destination pin, the code cancels the pending single-tap when a quick, nearby second tap arrives (`_handleMapTap`, `:164`). *Trade-off:* every real single-tap incurs a 280 ms delay before the destination is set. *Flaw:* the 40 m "same spot" test uses geographic distance, so at low zoom two intentionally-different taps can be misread as a double-tap and only zoom.

7. **Destination is set optimistically ("Dropped pin") before reverse-geocoding.** *Why:* offline or on a slow server call, the rider still gets an immediate, armable destination; the human-readable label upgrades later *only if* they haven't moved the pin (`_setDestinationFromLatLng`, `:132`). *Trade-off:* the rider may arm against "Dropped pin" with no name — acceptable since coordinates, not the label, drive the alarm.

8. **`AbsorbPointer(absorbing:_isTracking)` freezes the whole home UI during arming.** *Why:* prevents double-arming / changing the destination mid-arm. *Trade-off:* if `_proceedWithDirections` hangs on a slow network call, the screen is unresponsive with only a spinner. It *is* reset on every abort path, so it's not permanently stuck — but there's no cancel button during the fetch.

9. **The live-tracking screen cannot be dismissed with the back button (`PopScope canPop:false`).** *Why:* an accidental back-swipe must not silently kill a safety-critical session; ending requires the explicit END TRACKING button. *Trade-off:* if the screen ever wedged with valid args, the only exits are END TRACKING or killing the app. The empty `onPopInvokedWithResult` (`:1044`) also means no confirmation dialog — back simply does nothing.

10. **GPS-out is shown as reassurance, not as failure.** *Why:* in a tunnel the marker would otherwise freeze and the rider would panic and assume the app died. Recoloring the marker orange + a "still counting down" banner after 12 s of silence (`:1157`) keeps trust. *Trade-off:* it's purely cosmetic — the UI has no dead-reckoning of its own; the "still counting down" claim is only true if the *background* engine is actually dead-reckoning. If it isn't, the banner over-promises. *Flaw:* the 12 s threshold is UI-local and unrelated to the background alarm logic.

11. **Snooze is strictly one-shot with a live-session guard.** *Why:* a rider who's still on the train after the alarm needs one more nudge, but a snooze that could loop or fire after they've left is worse than none. `_snoozeUsed` + the `isActive()` check in `_maybeReAlert` (`:206`) bound it to exactly one re-alert while tracking. *Trade-off:* only *one* re-alert — a rider who snoozes and stays on for several more stops gets no further prompts.

12. **`GatedBannerAd` collapses to zero height and never reserves space.** *Why:* the old stub showed a grey bar even to paying Pro users and (worse) risked visually crowding the map/Wake-Me control. The null-contract design (`gated_banner_ad.dart:59–68`) guarantees Pro/no-fill see *nothing*. *Trade-off / flaw:* if `premiumOrNull` is null at first paint (monetization still initializing) the widget *never retries* — a cold-start race can suppress ads for a free user for the life of that screen (lost revenue, not a safety issue).

13. **Banner ads are allowed on the map-tracking screen (`AdPlacement.mapTracking`).** *Why:* above-ground tracking is a long dwell surface and AdPolicy forbids ads only on the alarm/wake surfaces; the full-screen wake alarm supersedes the small banner anyway (`maptracking.dart:1077–1082`). *Trade-off / risk:* it places a monetization surface inside a live safety session; the mitigation is entirely policy-side (AdService returning null on forbidden surfaces), which this widget trusts blindly.

14. **Reach up to `MyAppState` via `findAncestorStateOfType` for theming.** *Why:* a quick, dependency-free way for the drawer to flip the app-wide theme. *Trade-off / flaw:* it couples the drawer to a specific ancestor State type and to `main.dart`; there's no provider/inherited-widget indirection, so this breaks silently if the widget tree is restructured.

15. **"Test my alarm now" fires the real production alarm.** *Why:* the only honest way to let a rider verify the alarm will actually wake them (given decision 2's fail-open reliability) is to fire the genuine `NotificationService` path, not a fake preview (`ringtones_screen.dart:114`). *Trade-off:* a jarring full alarm during casual settings browsing; mitigated by a 5 s auto-stop and a STOP action.

16. **Three different code paths write `_etaText` on the tracking screen.** *Why:* the authoritative background EtaEngine (`etaSecondsStream`), the route-state stream, and the local snap-based `_handlePositionUpdate` each produce an ETA, and the screen wants to show *something* as soon as any of them ticks. *Trade-off / flaw:* they can disagree and the last writer wins, so the ETA can visibly bounce; `_handlePositionUpdate` writes its own local ETA even when a more-authoritative service value exists in `_lastEtaSecondsFromService`. Cosmetic, but it undercuts the "trust the number" goal.

17. **Inconsistent fallback speeds for initial vs live ETA.** `_computeInitialMetrics` uses a `12.0 m/s` (~43 km/h) fallback (`maptracking.dart:777,798`) while `_handlePositionUpdate` uses a conservative `2.8 m/s` (~10 km/h) (`:618`). *Why:* two authors/eras. *Flaw:* the first ETA a rider sees can be optimistically short, then jump longer once real motion data arrives — again undercutting trust, though never the alarm itself.

18. **Recents exist in two layers with two different caps (UI list capped at 10, Hive service at 15).** *Why:* `_addToRecentLocations` (`homescreen.dart:450`) keeps a short in-memory display list; `RecentLocationsService` (`:76`) is the durable store. *Trade-off:* mild redundancy and a key-name mismatch (`place_id` written by the screen, `placeId ?? place_id` read by the service) that works only because the service checks both.

---

### Invariants

- **Wake Me! is enabled iff** `_selectedLocation != null && _searchController.text.isNotEmpty && !_isLoading && !_isTracking` (`homescreen.dart:1684`).
- **A snapshot is persisted before `startTracking` is invoked** (`:1010` precedes `:1045`), so any post-arm crash is recoverable by Splash.
- **Reliability preflight and the disclaimer can never abort arming** — both are `try/catch`-swallowed and advisory.
- **The alarm-firing decision is never made in the UI.** Screens only *reflect* `AlarmPlayer.isPlaying` and can `stop()`/snooze/end; they cannot cause a needed alarm to be skipped.
- **The tracking screen is only escapable via END TRACKING** while args are valid (`PopScope canPop:false`).
- **`GatedBannerAd` occupies zero pixels unless a real ad is loaded and policy-permitted** — Pro/no-fill/forbidden-surface all render `SizedBox.shrink()`.
- **Snooze re-alerts at most once per session** (`_snoozeUsed`) and only while `isActive()`.
- **The GPS-estimating indicator only appears after ≥1 real fix** and after ≥12 s of silence.
- **MapTracking requires `lat`, `lng`, `destination`, and `directions` in its route args**, else it refuses to render the tracking UI.

---

### Interfaces

**Consumes (services / other subsystems):**
- **Permissions/reliability:** `PermissionService`, `ReliabilityPreflightRunner` + `showReliabilityPreflightDialog` (subsystem 14).
- **Routing/geo:** `OfflineCoordinator` (07/09), `ApiClient.geocode`, `PlacesService`, `MetroStopService`, `StopLogicEngine`, `TransferUtils` (02), `DirectionService`, `SnapToRouteEngine` (07), `EtaUtils`, `PolylineSimplifier`/`decodePolyline`.
- **Tracking/state:** `TrackingService` (`startTracking`, `registerRouteFromDirections`, `completeEndTracking`, `setOnline`, and the `routeSwitchStream`/`locationStream`/`etaSecondsStream`/`activeRouteStateStream` streams), `TrackingStateStore` (`setActive`/`saveSnapshot`/`loadSnapshot`/`isActive`/`isAlarmFired`/`pendingAlarmAllowContinue`/`preboardingEnabled`/`destinationOnlyMetroTimeEnabled`), `FlutterBackgroundService`, `LocationManager.broadcastPosition`.
- **Alarm:** `AlarmPlayer.isPlaying`/`stop`, `NotificationService.showWakeUpAlarm`/`cancelAlarm` (12).
- **Memory/persistence:** `RouteMemoryService`/`RouteMemory` (`SavedRoute`), `RecentLocationsService` (Hive), `SharedPreferences`.
- **Monetization:** `MonetizationService`, `AdService`, `AdPolicy`/`AdPlacement`, `PostArrivalService`/`PostArrivalCard`.
- **Platform plugins:** `Geolocator`, `google_maps_flutter`, `connectivity_plus`, `battery_plus`, `audioplayers`, `google_fonts`.

**Exposes:**
- The four named routes registered in `main.dart` — `/splash`, `/`, `/preloadMap`, `/mapTracking` — and the **map-args contract** (`destination, mode, value, metroMode, directions, userLat, userLng, lat, lng`) that flows HomeScreen → PreloadMap → MapTracking and is also reconstructed by Splash from the snapshot.
- `SettingsDrawer(metroModeEnabled, isMetroTimeMode)` reused by both HomeScreen and MapTracking.
- `AppThemes.lightTheme` / `darkTheme` consumed by `MyAppState`, and the theme toggle contract via `MyAppState.toggleTheme()` / `isDarkMode`.
- Reusable presentational widgets: `GatedBannerAd`, `PostArrivalCardWidget`, `PulsingDots`.

---

### Gaps & flaws vs the core promise

- **BLOCKER-level contradiction — cross-state routes are refused (`_validateSameState`, `homescreen.dart:263,791`).** The stated flagship trip is a 6–10 h Indian sleeper, but most such journeys cross a state line and would be actively blocked when both states resolve. The "never at the wrong place" promise is moot if the rider can't arm the trip at all. This deserves an explicit product decision; right now the code both claims (G18) and forbids (same-state guard) the flagship.
- **Reliability is warned about, never enforced (decision 2).** The largest "alarm didn't fire" exposure — aggressive OEM battery managers, DND, deep sleep on a cheap Android — is handled by a one-time disclaimer + an optional "test your alarm" button, both dismissible and fail-open. The UI cannot guarantee, and doesn't hard-gate on, the very OS cooperation the promise depends on.
- **The low-battery affordance is dead UI.** `_lowBattery` (`< 25%`) renders a red battery button whose `onPressed: () {}` does nothing (`homescreen.dart:1727`). On a cheap phone about to die mid-trip, this is exactly where a "keep charging / disable battery optimization" nudge belongs, and it's a no-op.
- **Arming is network-dependent in several places.** Autocomplete, country/state reverse-geocoding, and metro validation all need connectivity; offline they degrade (same-state fails open, "Dropped pin" persists) but the rider gets a thinner, less-validated arm. Directions themselves can come from `OfflineCoordinator` cache, so a *previously-cached* route can still arm offline — undocumented in the UI beyond the amber "using cached routes only" banner.
- **ETA shown to the rider is untrustworthy in the small.** Three writers race for `_etaText`, and initial vs live fallback speeds differ 4×+ (43 vs 10 km/h). None of this affects the alarm, but a visibly-jumping "time remaining" erodes the trust the pre-arm sheet works to build.
- **The GPS-out banner over-promises.** "Still counting down…" is shown purely from UI-side position-freshness (12 s); it asserts continued countdown without any UI-side proof that the background engine is dead-reckoning through the tunnel. If the background engine has *also* stalled, the banner is reassuring the rider about a countdown that isn't happening.
- **"Go Premium" is an empty menu item (`settingsdrawer.dart:77`)** despite a full MonetizationService existing — a monetization gap, not a safety one, but a visible dead end.
- **`GatedBannerAd` never retries after a cold-start race** where monetization wasn't ready at first paint — free-tier ads silently vanish for that screen instance.
- **Snapshot restore doesn't check staleness.** Splash will resume any `isActive` session with non-null directions regardless of age; a session armed hours ago and abandoned could resurrect on next launch straight into the tracking screen.
