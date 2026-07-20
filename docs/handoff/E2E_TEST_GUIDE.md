# GeoWake — End-to-End Testing & Discovery Guide

> **Read this as a map, not a report.** It tells you what every feature is, where the bodies are already buried (the `GW-####` findings), and where to dig next. The prior work proved the *math* in simulation. It barely touched a *real phone*. **Real-device E2E is the gap — it's yours to own.**

---

## 0. How to think about testing this app

GeoWake has exactly one job, and it is a *two-sided* promise:

> **Never wake the rider late. Never wake the rider too early.**

Everything — the map, the search, the EKF, the foreground service, the OS alarm backstop — exists to keep that promise on a real phone, in a real pocket, in a real tunnel, for an hour, with the screen off. When you test, you are not testing "does the button work." You are testing **"if I were actually asleep on this train, would this thing wake me at the right stop?"** Hold that frame the whole time.

### The two-sided guarantee, concretely
- **Late is death.** Waking after the stop means the user missed it. This is the P0 category. The whole never-late engine (a physics reachability bound, §Never-late core) is built to make late a *physical impossibility* — but only on some code paths, and only proven in sim.
- **Too-early is a UX failure, not a safety failure.** The engine deliberately leans early ("early is safe"). But firing 10 stops early (real: GW-0005, +859 s) makes the app useless. Both sides need eyes.
- **When in doubt, the design fires early.** So when you're hunting for *late* fires you are hunting for the rare, catastrophic case. When you're hunting for *too-early* you'll find lots — judge how bad the UX is.

### Why background reliability is the hard part
The alarm decision is easy. **Delivering** it after Android has frozen, Doze'd, or outright killed your process is the hard part, and it's where GeoWake lives or dies:
- The wake sound is played by **app code** (AlarmPlayer + native vibration). If the process is dead, that code can't run — so there's a **separate OS-owned exact alarm** (`setAlarmClock`, id 991) that self-sounds the system ALARM ringtone. That backstop is the real safety net, and it has the least real-device proof.
- A metro trip can run 60+ minutes with the screen off. Every one of those minutes, Android is looking for an excuse to suspend your sensors, defer your alarm, or reap your process.

### Why real devices matter (emulator/sim will lie to you)
- **Audio, vibration, and DND are not emulator-faithful.** A silent-alarm bug (GW-0001) or a DND-suppressed wake only shows on hardware.
- **Doze, App Standby buckets, and OEM battery-killers** behave nothing like a stock emulator. Xiaomi/HyperOS ships autostart *off*; Samsung deep-sleeps apps after days. The emulator never does this.
- **GPS/IMU dead-reckoning** was tuned on a *specific corpus of Bengaluru rides*. A different phone's accelerometer noise floor, a different mounting position, a gyroless budget phone — none of that is in the sim.
- **The never-late math is deterministically proven in the oracle** (0 violations). But the oracle historically re-anchored to *true* position, so the dominant real hazard — a noisy GPS fix that anchors *behind* the train (GW-0186, ~18% of real fixes) — was un-generatable. The margin absorbs it in sim; nobody has watched it on a phone near line speed.

### The OEM / Doze / DND minefield (where you'll find the scariest bugs)
This is the richest hunting ground. Keep these live at all times:
- **Doze / App Standby:** `adb shell dumpsys deviceidle force-idle`, `adb shell am set-standby-bucket`.
- **DND + alarm-stream volume:** set the *alarm* stream to 0, enable DND *without* granting notification-policy access.
- **OEM battery killers:** test on a real Xiaomi/Oppo/Vivo/Samsung, not a Pixel/emulator. Reference DontKillMyApp for per-OEM behavior.
- **Exact-alarm posture differs by API level:** `SCHEDULE_EXACT_ALARM` is auto-granted on API 33 but **not** API 34 (GW-0190). Full-screen-intent degrades on API 34+ for non-alarm apps (GW-0007).
- **Reboot / Direct Boot:** reboot mid-trip and leave the phone *locked* — BOOT_COMPLETED is withheld on FBE devices until first unlock (GW-0003).

### Two operational gotchas before you run a single adb command
1. **Package name split — this WILL waste your afternoon.** The *installed* app id is **`com.geowake.app`** (`applicationId`). The *internal* namespace is `com.example.geowake2` (scaffold leftover). **Every `adb` command that targets the running app — `am force-stop`, `pm revoke`, `appops`, `am kill`, `dumpsys ... | grep` — must use `com.geowake.app`.** Some scenario notes in older docs say `com.example.geowake2` for force-stop; that targets nothing. When a repro "does nothing," check the package name first.
2. **Debug builds lie about performance.** `flutter run` / debug APK = ~300 MB installed, JIT-interpreted, laggy cold start, ANR risk (GW-0194). That is **not** the shipping app. Judge speed/size only on `--release` (see `README.md` quickstart — and note the release APK comes out *unsigned*, GW-0196, so you'll hand-sign it).

---

## 1. Complete feature inventory (honest status)

Status legend: **works** = does what it says on real code paths · **partial** = works but with real gaps/caveats · **stub** = wired but non-functional / dead entry point · **advertised-but-missing** = surfaced or implied but not deliverable today.

| # | Feature | Subsystem | Status | Honest notes |
|---|---------|-----------|--------|--------------|
| **App shell & core flow** |
| 1 | Pick destination — search autocomplete | Shell / Search | works | but see search-vs-selection desync (GW-0153) |
| 2 | Pick destination — tap/drag map pin | Shell / Search | partial | drag doesn't re-label/re-geocode (GW-0036); not saved to recents (GW-0046); deletes your own location marker (GW-0154) |
| 3 | Recent destinations | Search | partial | only autocomplete picks are saved; no clear-all |
| 4 | Alarm mode: Time / Distance / Stops + Metro | Shell | works | derived from **two** switches, not one enum — subtle |
| 5 | Set "how early" (slider / typed value) | Shell | partial | out-of-range silently clamped, non-numeric silently dismissed (GW-0034) |
| 6 | Arm the alarm ("Wake Me!") | Shell | works | but the first-launch no-autocomplete → disabled-button trap is the flagship bug (see Start Here) |
| 7 | Live trip screen (map, ETA, tunnel banner) | Shell | works | cosmetic only — never runs the never-late physics |
| 8 | Stop alarm / Snooze / End tracking | Shell | partial | END TRACKING has no confirm (GW-0028); Back swallowed silently (GW-0033); STOP ALARM sits disabled all ride (GW-0043) |
| 9 | Session recovery after OS kill | Shell | partial | resume works after force-stop/swipe; **reboot-resume documented broken on Android 14+** (GW-0064) |
| 10 | Settings drawer | Shell | works | Buy-me-a-coffee is placeholder `YOUR_HANDLE` (GW-0038) |
| 11 | Home-widget one-tap re-arm | Shell / Pro | partial | bridge works; no in-app enable toggle (GW-0037) |
| 12 | Deep-link share follow | Shell / Share | partial | single link auto-follows arbitrary id (GW-0150); scheme hijackable (GW-0091/0149) |
| **Search / routing / transfers** |
| 13 | Autocomplete (Places, biased) | Search | works | no request-generation guard — slow old response can stomp newer (GW-scenario) |
| 14 | Metro-mode routing + snap-to-station | Routing | works | forces a metro plan even when metro closed (future 09:00 departure) |
| 15 | Transit routing w/ transfers + N-stops-before | Routing | works | OSM stop enhancement metro-only; conservative on count divergence |
| 16 | Interstate / sleeper (cross-state) | Routing | works | flagship; only >24h totals refused |
| 17 | Offline / cached-route arming | Routing | works | pinned active route survives TTL/offline |
| 18 | Search feedback (empty/no-result/error/loading) | Search | **advertised-but-missing** | failed/empty lookups are **silent** (GW-0155) |
| **Never-late core** |
| 19 | Never-late tunnel wake (metro-stops / metro-time) | Reachability | works (sim-proven) | the headline promise; **only** path with a real guarantee |
| 20 | Cold-start-underground wake | Reachability | works (sim) | seeds anchor at route origin — wrong if you board mid-line (see edge case) |
| 21 | Process-death / Doze survival wake | Reliability | partial | OS backstop exists; **backward-wall-clock P0 open** (GW-0147); rings once, no INSISTENT (GW-0063) |
| 22 | Fast-line correctness (RRTS/Airport Express) | Reachability | works | vehicle-type V_LINE floor (GW-0076 fixed) |
| 23 | Never-late on **distance mode** | Reachability | **partial** | DOES consult the reach bound, but the bound caps speed at 100 km/h → faster car/highway trips under-bounded (untested); GW-0161 covers only the non-metro STOPS leg |
| 24 | Never-late on **non-metro STOPS** final leg | Reachability | **advertised-but-missing** | evaluator non-metro STOPS branch ignores reach bound (GW-0161) |
| **Alarm delivery & reliability** |
| 25 | Wake alarm (sound + haptics + lock-screen notif) | Delivery | partial | can be **silent** if alarm stream = 0 (GW-0001, P0) |
| 26 | Process-death safety net (OS exact alarm) | Delivery | partial | rings **once** (GW-0063); wall-clock RTC (GW-0147) |
| 27 | Ongoing progress / "running in background" notif | Delivery | works | shares id 888 with FGS notif → mute fights FGS (GW-0066) |
| 28 | Wrong-direction heads-up | Delivery | partial | posted on DND-bypassing alarm channel (GW-0071) |
| 29 | Notification buttons from a dead app | Delivery | works | file+prefs flags; verify End-Tracking cancels backstop 991 |
| 30 | Stay-alive plumbing (wake lock, OEM autostart) | Delivery | partial | OEM deep-links undocumented/version-fragile (GW-0008) |
| 31 | Full-screen lock-screen takeover | Delivery | partial | degrades to heads-up banner on Android 14+ non-alarm apps (GW-0007) |
| **Location / sensors / EKF** |
| 32 | Wake-me-underground (EKF dead-reckoning) | EKF | works (sim on Bengaluru corpus) | cross-device behavior **not** proven |
| 33 | Station-snap progress correction | EKF | works (sim) | corpus-fit ZUPT thresholds — device tuning risk |
| 34 | GPS-degraded status | EKF | partial | not announced to screen readers (GW-0061) |
| 35 | Robust speed/ETA smoothing | EKF | works | |
| 36 | Bad-GPS accuracy gate | EKF | **partial/bug** | gate hardcoded at 100 m — coarse-only ride **never fires** (GW-0162, P1) |
| **Premium / ads / data** |
| 37 | GeoWake Pro (one-time IAP) | Monetization | works | fail-closed grant; **no revoke** → refund keeps Pro (GW-0164) |
| 38 | Rewarded "Pro for a day" | Monetization | partial | expiry not recomputed reactively (GW-0131) |
| 39 | Ads (free tier, banners only) | Ads | works | TEST ad IDs — **zero revenue** until real IDs wired; ad renders on in-ride surface (GW-0130) |
| 40 | Post-arrival last-mile card | Monetization | works | generic provider links, no affiliate IDs |
| 41 | Guardian mode (Pro) | Share | partial | gated + real, but **auto SMS/WhatsApp is a stub** — opens *your* composer |
| 42 | Home-screen widget (Pro) | Widget | partial | works but no Settings toggle (GW-0037), zero a11y (GW-0166) |
| 43 | Anonymous trip-stats consent | Data | works (inert) | default OFF; egress **triple-locked**, zero bytes leave (GW-0114) |
| 44 | Report a problem | Telemetry | partial | claims "no location" but embeds city+line (GW-0165) |
| 45 | Wear OS / family alarm | — | **not present** | deliberately removed from paywall; ignore stale memory notes claiming it's advertised |
| **Build / release / backends** |
| 46 | Maps rendering + proxied search | Build/Backend | works | every origin/dest transits founder proxy (GW-0103) |
| 47 | Journey sharing / follow-a-ride | Share/Backend | partial | share bearer token compiled into APK, `strings`-extractable (GW-0178); basic-link may still stream position (GW-0102) |
| 48 | Shippable signed release artifact | Build | **missing** | release build is **unsigned/uninstallable** (GW-0196) |

---

## 2. START HERE — the 8–10 highest-signal tests

If you only have a day, run these. They're the ones most likely to expose a real, shippable-blocking problem. Each links to its full playbook below.

1. **First-launch arming trap (the flagship UX bug).** Fresh install → type a destination → does autocomplete appear? Is "Wake Me!" enabled? A first-time user reportedly *cannot complete the core task* because no suggestions render and the button stays disabled. This is the single most important thing to reproduce and characterize. → §3.1, §3.13
2. **Never-late on a real underground ride.** Arm metro-STOPS (wake 1 stop before), board, get a clean fix, descend into the tunnel, and **time how early/late it fires.** The whole product is this test. → §3.19
3. **Backstop survives TOTAL process death.** Arm a short trip, kill the app (`am force-stop com.geowake.app`, and separately swipe-from-recents), wait for the fire instant, confirm the OS ALARM ringtone rings with **no process alive.** → §3.26
4. **Silent alarm / DND.** Set the alarm stream to 0; separately enable DND without policy access. Fire both live alarm and killed-process backstop. Does it actually make noise? (GW-0001 says maybe not.) → §3.25
5. **Coarse/Approximate location → never fires.** Grant *Approximate* location only (or ride a >100 m-accuracy corridor). Does the alarm *ever* fire? The 100 m gate is hardcoded (GW-0162) — a surface ride may silently never fire. Catastrophic + easy to reproduce. → §3.36
6. **Exact-alarm across API 33 vs 34.** Same trip on API-33 and API-34 emulators/devices. `SCHEDULE_EXACT_ALARM` auto-granted on 33, not 34 (GW-0190) — confirm the backstop still fires on 34. → §3.26
7. **Backward wall-clock step during a killed blackout (open P0).** Fast line, enter blackout, kill the isolate, step device time backward (mimic NTP). Does the RTC backstop fire late? (GW-0147 — the top open P0, sim-only so far.) → §3.26
8. **OEM battery-killer survival.** Real Xiaomi/Samsung, battery optimization ON, force a deep standby bucket, confirm the exact alarm still fires. → §3.30
9. **Reboot mid-trip + Direct Boot.** Reboot mid-trip, leave locked several minutes. Does tracking resume? Does the backstop re-arm before first unlock? (GW-0064 / GW-0003.) → §3.9, §3.26
10. **Search-vs-selection desync.** Pick a suggestion, then type a *different* place without picking it, arm. Which coordinates actually arm? (GW-0153 says the OLD one.) → §3.12

---

## 3. Per-feature E2E playbook

Each subsection: **Verify** (what "correct" means) · **Drive it** (concrete steps as a user) · **Nasty edges** (where to break it) · **Tooling** · **Known landmines** (GW-#### already logged here — don't re-find them, dig *past* them).

> **Format of every playbook:** the landmines list is your "already found — go deeper" pointer. If your repro matches a known GW-####, confirm it fast and spend your time on the *un-logged* neighbors.

### App shell & core user flow

#### 3.1 Pick a destination (search / recents / pin)
- **Verify:** the destination that arms is the one the user *believes* they picked; the map shows the rider relative to the target.
- **Drive it:** search + tap a suggestion; separately tap the map to drop a pin; separately drag the marker ~2 km.
- **Nasty edges:** drop a pin then drag it — does the confirmation sheet still show the old name? Drag into the ocean / across a state line. Reopen the app — do pins/drags show in recents (they shouldn't, and that's a bug)?
- **Tooling:** manual + Maestro (`persona_firsttime.yaml`); `adb` UI drag / `adb emu geo fix` for mock pins.
- **Landmines:** GW-0036 (drag keeps stale name), GW-0046 (pins/drags never in recents), GW-0154 (selecting a dest deletes the current-location marker), GW-0155 (empty/failed search is silent).

#### 3.2 Alarm mode (Time / Distance / Stops + Metro)
- **Verify:** the four combinations of Metro × Time/Distance resolve to the right label ('Stops' vs 'Distance') and the right pre-arm copy; the armed mode string ('time'/'distance'/'stops') matches.
- **Drive it:** cycle all four combinations, read the label and the "we'll wake you N before X" sheet each time.
- **Nasty edges:** the mode is **not one enum** — it's derived from `_metroMode` (AppBar) + `_useDistanceMode` (body). 'stops' only exists when BOTH are on. Confirm downstream reads the derived string, not the booleans.
- **Tooling:** manual + Maestro.
- **Landmines:** GW-0019/0035/0054 (ambiguous two-switch model; a11y labels since added).

#### 3.3 Set how early (slider / typed value)
- **Verify:** ranges (0.5–10 km, 1–10 stops, 1–60 min) and defaults (5 km / 2 stops / 15 min) hold; bad input is rejected *with feedback*.
- **Drive it:** open the value dialog, enter `0`, `-3`, `1000`, `5.5.5`, `abc`, and empty.
- **Nasty edges:** stops-threshold larger than the stops available on the first metro leg should raise a clear error. A disabled Wake-Me should say *why*.
- **Landmines:** GW-0034 (out-of-range silently clamped, non-numeric silently dismissed), GW-0024 (disabled Wake-Me gives no reason).

#### 3.4 Arm the alarm ("Wake Me!")
- **Verify:** the full pipeline runs in order — permissions → disclaimer → position → (metro snap) → directions → validations → confirm sheet → **snapshot persisted BEFORE service start** → preflight → startTracking.
- **Drive it:** arm a normal trip and watch it land on the tracking map.
- **Nasty edges:** background/foreground and rotate the device *during* arming — mounted-guards must hold so you can't get a half-armed state. Kill the app right after the confirm sheet — does the snapshot let it resume?
- **Tooling:** manual + Maestro `persona_arm.yaml`; `adb` rotation.
- **Landmines:** the snapshot-before-start ordering is load-bearing for recovery — don't "fix" it. See §3.13 for the permission-gauntlet abort bugs.

#### 3.5 Live trip screen
- **Verify:** route polylines draw, position snaps, ETA/distance update, the "no GPS (tunnel), still counting down" banner appears after ~12 s of no fix.
- **Drive it:** ride (or replay) and watch the banner flip when you enter a tunnel.
- **Nasty edges:** the map screen is **cosmetic** — it never runs the never-late physics. Don't judge the guarantee here.
- **Landmines:** GW-0117 (map opens a *second* GPS stream on top of the FGS — battery), GW-0157/0125 (three ~1 Hz streams cause duplicate full-screen rebuilds), GW-0030 (hardcoded route legend on every trip), GW-0130 (ad banner on the in-ride surface).

#### 3.6 Stop alarm / Snooze / End tracking
- **Verify:** SNOOZE is one-shot (exactly one 60 s re-alert, then it hides); END TRACKING tears down the session and lands on post-arrival.
- **Drive it:** drive/replay to arrival, tap SNOOZE, wait 60 s, confirm one re-alert; then END TRACKING.
- **Nasty edges:** END TRACKING during the 60 s window must cancel the pending re-alert. Snooze must never loop.
- **Landmines:** GW-0028 (END TRACKING disarms instantly, **no confirmation** — fat-finger kills the safety net), GW-0033 (Back swallowed silently), GW-0043 (STOP ALARM disabled the whole ride), GW-0055 ('Time to get off' is the smallest text on the most important screen).

#### 3.7 Session recovery after OS kill
- **Verify:** after force-stop or swipe-from-recents, next launch resumes straight into `/mapTracking` from the snapshot; a corrupt snapshot cleans up and lands home.
- **Drive it:** arm → reach tracking → `adb shell am force-stop com.geowake.app` → relaunch. Repeat with swipe-from-recents. Repeat with a mid-fire alarm (kill *while ringing* — splash should detect alarmFired and clean up).
- **Nasty edges:** **reboot** the device mid-trip and check if it resumes at all.
- **Tooling:** `adb` (am force-stop, reboot), emulator matrix API 24/29/33/35.
- **Landmines:** GW-0064 (reboot-resume broken on Android 14+ — autoStartOnBoot can't restart a location-typed FGS), GW-0003 (Direct-Boot: backstop not re-armed until first unlock on FBE devices).

#### 3.8 Settings drawer
- **Verify:** theme toggle persists, metro preboarding/destination-only toggle persists, Pro-gated items deep-link to the paywall.
- **Landmines:** GW-0038 (Buy-me-a-coffee ships `YOUR_HANDLE` + dev-copy snackbar), GW-0018/0029 (low-battery red button is a dead control).

#### 3.9 Home-widget re-arm & share deep links
- **Verify:** a widget can relaunch and re-arm a remembered route; a `geowake://` / App-Link share follows a friend's ride.
- **Drive it:** `adb shell am start -a android.intent.action.VIEW -d 'geowake://j/SOMEID'`. Also `persona_redteam_deeplink.yaml` for malformed/path-traversal ids.
- **Nasty edges:** does a single inbound link *silently* auto-follow an arbitrary id? Can any app fire the custom scheme?
- **Landmines:** GW-0150 (single link auto-follows + persists an arbitrary share id), GW-0091/0149 (custom scheme hijackable).

### Search / routing / transfers

#### 3.12 Search-vs-selection desync
- **Verify:** the armed coordinates equal the picked suggestion, even after further typing.
- **Drive it:** tap a suggestion (marker drops) → type a *different* place without picking → Wake Me → check the coords on the tracking map / logs.
- **Nasty edges:** select → clear field → Wake Me (gate should disable); select → backspace a few chars → Wake Me.
- **Tooling:** manual + `adb logcat` (grep the dest lat/lng / 'Same-state').
- **Landmines:** GW-0153 (arms the OLD location while the field shows NEW text — `_onSearchChanged` never clears `_selectedLocation`).

#### 3.13 First-launch autocomplete / disabled Wake-Me (FLAGSHIP)
- **Verify:** on a *fresh install*, typing a destination surfaces actionable suggestions and enables "Wake Me!".
- **Drive it:** clear state / fresh install → open app → tap "Enter your destination" → type "Indiranagar"/"MG Road" → is there a tappable suggestion row? Is "Wake Me!" enabled? Does tapping it do anything?
- **Nasty edges:** try with permissions granted vs denied; with network on vs off; first launch (no recents) vs after one successful arm. Isolate *why* — is it a missing autocomplete render, a permission precondition, or a genuinely disabled CTA with no reason shown?
- **Tooling:** Maestro `persona_arm.yaml` / `persona_firsttime.yaml` (they screenshot exactly this), then manual to root-cause.
- **Landmines:** README day-one item #3 flags this as the highest-signal bug; GW-0024 (disabled Wake-Me gives no reason). **This is under-characterized — own it.**

#### 3.14 Metro destination not near a station
- **Verify:** a far-from-metro destination raises "Metro Route Unavailable"; a ~200 m-from-station destination snaps correctly.
- **Nasty edges:** destination whose nearest station is under-construction (`_isActiveStop` must exclude it); a destination between two stations of *different lines* ~150 m apart (line-filter must not snap to the wrong line).
- **Tooling:** manual + emulator mock location.

#### 3.15 Multi-line transfer route
- **Verify:** the transfer alert fires N stops before the **right interchange** (not a reroute).
- **Drive it:** route a line-change journey (e.g. Delhi Yellow→Violet at Central Secretariat) and ride it in replay; watch when/where the transfer fires.
- **Nasty edges:** color-family collisions (Magenta vs Pink, Violet vs Purple) must not collapse in `_canonLine`; metro→WALK→metro must not leak the next line's boarding station into this leg.
- **Tooling:** EkfTestController / `harness_runner` replay, or Maestro on emulator.
- **Landmines:** GW-0032 (copy conflates internal reroute with a real transfer).

#### 3.16 OSM stop-count divergence (never-late fallback)
- **Verify:** when bundled OSM matches *fewer* stops than Google `num_stops`, the app keeps the **conservative uniform API count** and marks `stopCountConfidence=0.5` — never adopts the smaller count (that would fire late).
- **Drive it:** route a metro leg on a sparse-OSM line, grep logs for the divergence fallback.
- **Nasty edges:** confirm the uniform estimates (off true arc-position by up to ~1079 m, GW-0193) are **not** fed to the dwell cap.
- **Tooling:** `adb logcat` (grep 'divergence' / 'OSM ENHANCEMENT') + replay harness.
- **Landmines:** GW-0193/0148 (even-spacing late-trap — see §3.24d).

#### 3.17 Interstate sleeper vs corrupt route
- **Verify:** genuine cross-state journeys (Delhi→Jaipur, Mumbai→Ahmedabad) arm with **no block**; only >24 h totals are refused.
- **Nasty edges:** duration must be summed across ALL legs, not leg 0. The advisory same-state check must only log, never block (don't re-add the old cross-state block).
- **Landmines:** GW-0026 (same-state still fires two geocode calls despite being advisory).

#### 3.18 Offline / connectivity flapping
- **Verify:** arming online then re-arming the same O/D offline serves the pinned cache; no-cache-offline gives a clean "offline, no cached route" error.
- **Drive it:** arm online → airplane mode → re-arm same O/D. Toggle connectivity mid-search.
- **Nasty edges:** mid-search network failure shows **nothing** (GW-0155). Cache TTL: same O/D within 3 min hits memory; past 5 min L2 evicts.
- **Tooling:** manual + `adb` airplane toggle; mitmproxy to watch `/maps/autocomplete`.

### Never-late core (the headline promise)

> **Read the mental model first.** The bound is pure arithmetic: while GPS is lost, the train cannot be further than `s_max(t) = s0_hi + V_LINE·(t − t0)`. Three preconditions carry the whole proof — (i) anchor is a *real* fix, (ii) V_LINE ≥ true max speed, (iii) t is elapsed-since-last-*true*-fix. Every late fire violates exactly one. Your job on a phone is to attack those three.

#### 3.19 Never-late metro tunnel wake
- **Verify:** on a real underground line, the alarm fires **before** the target platform, and you can measure *how early*.
- **Drive it:** arm metro-STOPS (wake 1 stop before), board, get a clean fix, descend so GPS is fully lost for the leg. Repeat walking a parallel *surface* route slower than the train to confirm the bound over-bounds.
- **Nasty edges:** very long blackout (5–10 min) should fire minutes early, never late. Anchor set at a platform with a fix whose reported accuracy *understates* the true along-track-backward error (GW-0186: ~18% anchor behind true progress, worst 1650 m) — watch a train running **near V_LINE**, where the margin is thinnest.
- **Tooling:** manual on real metro (Namma/Delhi); `persona_arm.yaml` to script the arm; `adb logcat` for `reachabilityActivated`.
- **Landmines:** GW-0186/0187 (margin absorbs backward anchor in sim; residual = train near V_LINE, unmeasured on hardware), GW-0160 (metro anchor seeded from rate-limited `_sPub`, can start below true progress).

#### 3.20 Cold-start-underground (wrong-origin)
- **Verify:** a rider who opens the app already underground still gets woken (anchor seeded at route origin at arm time).
- **Drive it:** force-start with **no prior GPS fix** while already inside a station that is **not** the first stop, then ride.
- **Nasty edges:** cold-start seeds `s=0` at the route **origin**. If you boarded km into the route, DR is anchored km behind reality → late/wrong-place fire. **No honest σ fixes a wrong anchor.**
- **Tooling:** manual on real metro; airplane-mode-then-enable to withhold first fix.

#### 3.23 Never-late on distance mode (partial — the real gap is the speed cap)
- **Verify / falsify:** arm distance-mode (wake 1 km before) on a **fast highway car trip (>100 km/h)**, degrade GPS near the end. Does it fire late?
- **Why:** distance mode **does** consult the controller physics bound (`reachBoundModes`, `alarm_controller.dart:1248-1251`) — the earlier claim that it has *no* backstop was wrong. But that bound floors max speed at `VLineTable.defaultMps` = 28 m/s (100 km/h), raised only by transit legs. So a car/highway trip faster than 100 km/h is **under-bounded → can fire late**, and **no test gates it.** (Time mode consumes the same bound at `1138-1158`.)
- **Tooling:** manual on a real highway car ride, or `EkfTestController.loadFromPolyline` with a >100 km/h leg + a blackout on the final stretch.

#### 3.24 Never-late on non-metro STOPS + dwell-cap regression
- **3.24a Non-metro final leg (GW-0161):** STOPS mode with a bus/drive/walk final leg through a GPS-poor corridor — the non-metro evaluator branch ignores the reach bound → late fire. Confirm and document.
- **3.24b Multi-leg slow→fast (piecewise V_LINE):** arm walk→metro→RRTS, blackout while the anchor is on the slow leg. The bound must grow at the **current** leg's V_LINE up to the boundary, only adopting the faster ceiling past it — not fire ~2× early. Compare against old flat-max.
- **3.24c First-tick anchor honesty (GW-0160):** inspect the anchor on the first few ticks — seeded from raw route-snap or from rate-limited `_sPub`? Feed a fix delivered several seconds late; confirm age-mapping keeps `t` honest and the monotonic guard doesn't drop the first real fix.
- **3.24d dwellMinSeconds>0 regression guard (GW-0148/0193):** **negative test** — confirm production keeps `dwellMinSeconds=0.0`. If anyone sets it >0, production feeds the dwell cap *evenly-spaced estimated* station positions (off true arc-position by up to 1079 m) → under-bounds ~1 km → **late fire.** Keep the cap inert until real per-line geometry is wired (`wakepoint-rail-geometry` skill).

### Alarm delivery & background reliability

#### 3.25 Silent alarm / DND
- **Verify:** the wake actually makes audible noise on the alarm stream, and isn't suppressed by DND.
- **Drive it:** set the device **alarm stream volume to 0**, fire the live alarm — is it vibration-only silence? Separately, enable DND *without* granting notification-policy access; fire both live and killed-process backstop.
- **Nasty edges:** `AlarmPlayer` ramps *player-relative* volume, not `AudioManager` STREAM_ALARM. `setBypassDnd(true)` is a no-op without ACCESS_NOTIFICATION_POLICY, which nothing ever requests.
- **Tooling:** **physical phone only** (audio/DND not emulator-faithful).
- **Landmines:** GW-0001 (P0 silent alarm), GW-0002 (DND probes exist, no user-grant flow), GW-0067 (channel importance frozen at HIGH not MAX).

#### 3.26 Process-death backstop (the safety net) + all the OS traps
This is one feature with several brutal edges — run them as a matrix.
- **Verify:** an OS-owned exact alarm (system ALARM ringtone) fires at `min(ETA, physics)` **with no app process alive**, and is cancelled the instant the live alarm fires.
- **Drive it:** arm a short trip, simulate a tunnel (airplane/GPS off), `adb shell am force-stop com.geowake.app` (and separately swipe-from-recents), wait for the fire instant. Confirm `adb shell dumpsys alarm | grep geowake` shows the scheduled `setAlarmClock`.
- **Nasty edges & sub-tests:**
  - **Rings once? (GW-0063):** no FLAG_INSISTENT — a deep sleeper may not wake. Time a single ping vs a looping alarm.
  - **Backward wall-clock (GW-0147, open P0):** fast line → blackout → kill isolate → step device time backward (NTP mimic) → does id 991 fire late? The fire instant is monotonic but converted to an **absolute RTC** wall instant.
  - **API 33 vs 34 (GW-0190):** SCHEDULE_EXACT_ALARM auto-granted on 33, not 34 — confirm posture on both.
  - **Doze / standby:** `adb shell dumpsys deviceidle force-idle`, `am set-standby-bucket` — does it still fire?
  - **Reboot / Direct Boot (GW-0064/0003):** reboot mid-trip, leave locked — backstop re-armed before unlock?
  - **End-Tracking from a dead process:** confirm it cancels backstop 991 (`dumpsys alarm`) so there's no spurious post-trip wake.
  - **Manifest receivers:** the 3 re-declared flutter_local_notifications receivers are load-bearing — without them AlarmManager fires but nobody catches it. Don't let a dependency bump drop them.
- **Tooling:** `adb` + emulator matrix API 24/29/33/35 + real OEM device; `integration_test/patrol_alarm_test.dart`; `integration_test/backstop_doze_ondevice_test.dart`; logcat.
- **Landmines:** GW-0147, GW-0063, GW-0064, GW-0003, GW-0006 (SCHEDULE_EXACT_ALARM revocable, result ignored), GW-0070 (unknown mode → 60 s flat lead), GW-0065 (backstop channel only created in MainActivity).

#### 3.30 OEM battery-killer survival
- **Verify:** on an aggressive OEM, the OS still launches the process to service the exact alarm after deep standby.
- **Drive it:** real Xiaomi/HyperOS (autostart OFF by default) and Samsung One UI — arm, force the deep-sleep bucket (`am set-standby-bucket`, `dumpsys deviceidle force-idle`), confirm the backstop fires. Verify the onboarding deep-link actually lands on the OEM autostart screen (not a generic battery page that doesn't add the allowlist entry).
- **Tooling:** **physical Xiaomi/Oppo/Vivo/Samsung**; DontKillMyApp as reference.
- **Landmines:** GW-0008 (P0, needs-device — the single biggest un-verified reliability risk).

#### 3.31 Full-screen lock-screen takeover & headset unplug
- **Verify:** on a locked screen-off phone the wake takes over the lock screen (Android 13); confirm it degrades to a heads-up banner on Android 14+ (GW-0007) and judge whether a pocketed banner still rouses a sleeper.
- **Headset:** fire the alarm to a BT/wired headset, disconnect mid-alarm — audio should reroute to the loudspeaker.
- **Landmines:** GW-0007, GW-0068 (deviation-termination fires a full alarm then instantly silences it — audible blip).

### Location / sensors / EKF

#### 3.36 Coarse / Approximate location → never fires (P1, top real-device bug)
- **Verify / falsify:** grant **Approximate** location only (or ride a consistently >100 m corridor), start a normal **surface** ride — does the alarm *ever* fire?
- **Why:** the accuracy gate is effectively a hardcoded 100 m (`accuracyGateMeters` declared but never assigned, GW-0162). Every coarse fix is dropped, the EKF never bootstraps, and a surface ride can **silently never fire.** Test both metro (has cold-start backstop) and distance mode (does not).
- **Tooling:** manual + `adb shell appops set com.geowake.app COARSE_LOCATION allow` / `FINE_LOCATION ignore`.

#### 3.37 Aggressive-OEM Doze during a tunnel (dt>1 s coast)
- **Verify:** on a multi-second IMU gap, the EKF **coasts** at last velocity (capped ±1500 m) rather than freezing.
- **Drive it:** battery-optimization ON, lock the phone, ride a long tunnel so the OS batches/suspends sensors.
- **Nasty edges:** if the train actually *stopped* during the gap it over-progresses → wrong-station snap. Confirm the 1500 m coast cap + 1600 m/tick monotonic clamp hold (this is the class of bug that produced the 518 km / 242 km spikes).
- **Tooling:** manual + `adb shell dumpsys deviceidle force-idle`; inspect `ekf_s` telemetry.

#### 3.38 Frozen-phantom GPS at a tunnel mouth
- **Verify:** a confident-but-stuck fix (real corpus: 120 s pinned at 3.79 m accuracy) is rejected.
- **Nasty edges:** rejection only triggers if the filter already believes v>2 m/s AND moved <2 m. If DR drift already pulled v below 2, the phantom is **accepted** → v→0 → late fire. The **first** fix can never be phantom-checked.
- **Tooling:** manual; or replay a captured stuck-fix log.

#### 3.39 Parallel line / wrong train / reroute
- **Verify:** understand that the EKF is **1-D along the planned route only.** Off-route fixes (>75 m lateral → NaN) are treated as "GPS unavailable," so it confidently dead-reckons down the route you already **left**.
- **Drive it:** board a parallel line or trigger a mid-journey reroute; watch the alarm fire relative to the OLD route.
- **Tooling:** manual on a network with parallel lines; GPX injection via mock location.

#### 3.40 Express-skip long blind run (unbounded bias drift)
- **Verify:** with no platform stops (no ZUPT), accel bias never corrects → drift. Expect **too-early** fires (GW-0005: up to +10 stops / 859 s). Confirm it never fires **late**; judge how bad the earliness UX is.

#### 3.41 Fast rail >90 km/h (clamp under-integration)
- **Verify:** `v` is hard-clamped ±25 m/s everywhere `s` integrates. Genuine >90 km/h travel is silently under-integrated during DR → progress lags → **late-fire risk** on fast legs. Fine for metro, latent for mainline.
- **Tooling:** manual on airport express / RRTS, or synthesize a fast-leg fixture.

#### 3.42 Phone mounting / orientation / gyroless
- **Verify:** repeat the same underground ride pocket vs hand vs mount, across 2–3 phone models; on a gyroless budget phone, confirm `setNoGyro` widens σ (fires earlier) and doesn't freeze progress or false-ZUPT.
- **Nasty edges:** ZUPT/motion thresholds are **corpus-fit** — a noisier accelerometer can false-ZUPT (wrong-station snap) or miss real stops. None of this is proven off the Bengaluru corpus.
- **Tooling:** manual A/B across devices + mounts; log `ekf_s`/`ekf_mode`/`ekf_motion`; emulator Go profile + one real gyroless device.

### Premium / ads / data (safety must never be gated)

> **The invariant to defend:** never gate, delay, or block the alarm for monetization/data. Always-free getters return true unconditionally; ads hard-deny alarm/wake/lockScreen; Guardian/data/recordRide run fire-and-forget **after** wake+teardown. Your job here is to *attack* that invariant and confirm it holds.

#### 3.44 Pro purchase / late-UPI / restore / refund
- **Verify:** buying Pro removes ads and unlocks Guardian/widget with no restart; a late/pending UPI purchase still grants via the stream; restore works after reinstall.
- **Nasty edges:** kill the app during the buy dialog; deny the charge (must stay free); corrupt the `geowake_entitlement_v1` pref (must fail-closed to free, never resurrect Pro); refund in Play then reopen — **grant-only means Pro stays** (GW-0164).
- **Tooling:** Play sandbox/license-tester; `adb` to corrupt shared_prefs.
- **Landmines:** GW-0131 (day-pass expiry not reactive), GW-0133 (client-side flag, tamperable), GW-0164.

#### 3.45 Ad never touches the alarm/lock path
- **Verify:** as a free user, fire the wake on the lock screen — **no** banner/interstitial on alarm/wake/lock. Banners only on home + map.
- **Nasty edges:** fire the wake while a banner is mid-load; Pro user must see zero-height (no grey bar); no-fill must collapse to zero height.
- **Landmines:** GW-0130 (banner on in-ride surface — is that "map" or too close to the alarm? judge it), GW-0138 (banner gives up permanently after retries).

#### 3.46 Guardian mode delivery + core-safety
- **Verify:** as Pro, arming opens *your own* composer pre-filled with a tracking link; the "arrived safely" signal fires **without** a composer popping over the just-fired alarm.
- **Nasty edges:** non-Pro `setContact`/`setEnabled` must hit the paywall; enable with no contact must refuse; a Guardian hang must **never** delay the wake (it hangs off PostAlarmMulticast, post-teardown — confirm).
- **Tooling:** real phone with WhatsApp; Maestro.

#### 3.48 Egress is genuinely OFF vs Maps-proxy leak
- **Verify:** run a full session through an intercepting proxy. Confirm **zero** bytes from the telemetry HTTP sink and the data-asset sink (even after opting into data sharing). **Then** observe that exact origin/dest coordinates **do** leave on every route computation via the Maps proxy — the "nothing leaves the device" claim is true only for telemetry/data-asset, not routing.
- **Nasty edges:** egress is **time-dependent** — a launch-only capture shows zero (GW-0191); the leaks start once you *create a share* (GW-0102) or *search* (GW-0103/0172). Flutter ignores the system proxy, so TLS-unpin (reFlutter/Frida) or tcpdump.
- **Tooling:** mitmproxy + reFlutter/Frida BoringSSL unpin, or emulator iptables redirect; jadx to confirm no other sinks.
- **Landmines:** GW-0114 (aggregate egress genuinely inert — verify it *stays* that way), GW-0103/0172 (coordinates leave via proxy), GW-0165 (report-a-problem embeds city+line despite "no location" claim).

### Build / release / backends

#### 3.49 Produce a shippable, installable release artifact
- **Verify:** `flutter build apk --release` (and `appbundle`) yields an installable, signed artifact.
- **Drive it:** clean checkout → build → `adb install`.
- **Nasty edges:** confirmed GW-0196 — install fails `INSTALL_PARSE_FAILED_NO_CERTIFICATES` (no signingConfig). Check whether a real upload keystore gets wired, the App-Links assetlinks SHA-256 matches the signing cert, and a second AAB gets a strictly higher versionCode from pubspec `+N`.
- **Tooling:** `flutter build`, `adb install`, `apksigner verify`.

#### 3.50 Compiled-in secret extraction & release-mode wake path
- **Secret extraction:** build with `--dart-define=GEOWAKE_SHARE_TOKEN=CANARY123`, unzip, `strings -n 6 lib/arm64-v8a/libapp.so | grep CANARY123`. Token appears verbatim in all 3 ABIs (GW-0178) — a single shared secret for all installs. Worse because the share server leaves `/v1` write routes open when SHARE_AUTH_TOKEN is unset and its rate limiter is XFF-spoofable.
- **Release-mode wake path (critical):** install a **real release build** (not debug), arm, force-stop to trigger the exact-alarm backstop, confirm it fires. R8 keep-rules are hand-curated and non-exhaustive; a stripped reflective MethodChannel breaks the wake path **only in release, only on the alarm path** — the worst place. No release-mode on-device smoke test exists. Test on aggressive-OEM devices.
- **Data-at-rest:** `adb backup -f out.ab com.geowake.app` — `allowBackup` is unset (defaults true), so the share secret, entitlement blob, consent, and guardian contacts come out in cleartext (GW-0175).
- **Tooling:** unzip/apktool, strings, jadx, `adb backup` + android-backup-extractor; real OEM device.

---

## 4. Toolchain already in the repo (reuse it)

You are **not** starting from zero. Here's what exists and where it lives.

| Layer | Where | What it does / how to run |
|-------|-------|---------------------------|
| **Deterministic never-late oracle** | `test/scale/reachability_scale_test.dart`, `test/scale/multi_target_scale_test.dart`, `test/scale/never_late_gps_error_stress_test.dart` | Proves never-late / not-too-early across thousands of simulated rides. `flutter test test/scale/`. Start here to understand the guarantee. |
| **Reachability unit + edge proofs** | `test/reachability/*` — incl. `never_late_along_track_gps_test.dart`, `multileg_piecewise_vline_test.dart`, `dwell_cap_even_spacing_late_trap_test.dart`, `vline_vehicle_type_test.dart`, `tightening_*_test.dart` | Pure-math proofs of the PL (V_LINE tiers, piecewise, along-track error, dwell-cap trap). `flutter test test/reachability/`. |
| **EKF replay harness** | `lib/testing/harness_runner.dart` + `lib/core/ekf/` | Feed a GPS/IMU polyline through fusion + arming, read metrics. Use `EkfTestController.loadFromPolyline` to inject blackout windows. |
| **EKF replay gate (fixture-based)** | `test/ekf/replay_harness_test.dart` | The load-bearing never-late CI gate — runs over **9 committed in-repo fixtures under `test/fixtures/replay/`** and **fails on empty** (wired in `.github/workflows/ci.yml`). CI-safe and reproducible. An external `/home/raed/…` path is only an optional extra-coverage fallback on the founder machine. |
| **Maestro semantic UI flows** | `test/maestro/*.yaml` | Drive the real app by label. `maestro test test/maestro/persona_arm.yaml`. `persona_firsttime` (first-time walkthrough), `persona_arm` (the disabled-Wake-Me probe), `persona_critic_tour`, `persona_redteam_deeplink` (malformed/path-traversal deep links). |
| **Patrol native E2E** | `integration_test/patrol_alarm_test.dart` | Grants OS permissions + drives the alarm chain on device/emulator. |
| **On-device integration tests** | `integration_test/alarm_chain_ondevice_test.dart`, `backstop_doze_ondevice_test.dart`, `device_alarm_integration_test.dart` | Run against a real device/emulator (`flutter test integration_test/... -d <device>`). |
| **Real rail geometry** | `wakepoint-rail-geometry` skill | Fetches real OSM metro/rail geometry + station nodes, computes true arc-length progress. Use to build ground-truth for never-late checks and to quantify the GW-0193 even-spacing error. |
| **Findings log** | `docs/testing/ISSUES.jsonl` (196 entries) | The shared memory. One JSON object per line. **Append to it as you discover things** (schema below). |
| **Testing charter** | `docs/AGENT_TESTING_CHARTER.md` | The original mandate — three fronts: UX, background reliability, security. |

**adb cheat-sheet (installed package = `com.geowake.app`):**
```bash
adb shell am force-stop com.geowake.app            # kill the app (session-recovery test)
adb shell am kill com.geowake.app                  # softer kill (backstop test)
adb shell pm revoke com.geowake.app android.permission.ACCESS_BACKGROUND_LOCATION
adb shell appops set com.geowake.app COARSE_LOCATION allow   # force coarse (GW-0162)
adb shell dumpsys deviceidle force-idle            # force Doze
adb shell am set-standby-bucket com.geowake.app restricted   # deep standby
adb shell dumpsys alarm | grep -i geowake          # confirm setAlarmClock id 991
adb shell am start -a android.intent.action.VIEW -d 'geowake://j/SOMEID'   # deep link
```

---

## 5. What's proven vs. what needs real-device proof

Be ruthless about this distinction. **Never claim device-proof from a simulation** — if you proved it in a test/emulator, say so.

### ✅ Proven in simulation (deterministic, reproducible)
- **The never-late *math*** — `s_max = s0_hi + V_LINE·Δt` — is deterministically proven with 0 violations on the oracle/harness across thousands of simulated rides.
- **Piecewise multi-leg V_LINE**, vehicle-type ceiling floor (GW-0076), and the along-track-error injection (post GW-0181) all pass their reachability tests.
- **Pure logic:** entitlement/AdPolicy/post-arrival PII guard/consent state-machine/DP-k-anon math — headless unit-tested.
- **Spike defenses** (±25 m/s clamp, Cauchy-Schwarz repair, 1500 m coast cap, 1600 m/tick rate limit) each provably prevented a real multi-hundred-km position spike.

### ⚠️ Proven only in sim, with a known *un-generatable* real hazard
- The oracle historically re-anchored to **true** position, so the dominant real LATE hazard — a noisy GPS fix that anchors *behind* the train (GW-0186, ~18% of real fixes, worst 1650 m) — was un-testable. The V_LINE margin *absorbs* it on the 395-case matrix (LATE=0), but the residual (a train running **near V_LINE**, where the margin is thin) is **argued, not measured on hardware.**

### ❌ NOT proven — needs a real phone (your job)
- **Silent alarm / DND suppression** (GW-0001, GW-0002) — audio behavior is not emulator-faithful.
- **Backward-wall-clock backstop** (GW-0147, open P0) — sim-only; needs a real killed-process repro with a device time step.
- **Coarse-location never-fire** (GW-0162) — the 100 m gate hasn't been watched drop every fix on a real coarse ride.
- **OEM battery-killer survival** (GW-0008) — HyperOS autostart-off, Samsung sleep buckets. The single biggest un-verified reliability risk.
- **Reboot / Direct-Boot resume** (GW-0064, GW-0003) — documented broken on Android 14+, unconfirmed on hardware.
- **Full-screen-intent degradation** (GW-0007) on Android 14+ — banner vs takeover, does it rouse a pocketed sleeper?
- **Release-mode wake path after R8** (GW-0196 blocks even building it) — a stripped reflective channel breaks only in release, only on the alarm path; no smoke test exists.
- **Cross-device EKF dead-reckoning** — the entire fusion stack is tuned on a Bengaluru corpus. A different accelerometer, mounting, or gyroless phone is unproven (§3.42).
- **Metro anchor from `_sPub`** (GW-0160), **double-GPS battery cost** (GW-0117), **IAP pending/UPI/restore-across-devices**, **egress-is-off under proxy** — all need device/sandbox/proxy verification, not green unit tests.

**Bottom line:** what's proven is *"never fires late on a handful of Bengaluru metro rides, in simulation."* The phone-in-a-pocket-in-a-tunnel behavior is the open frontier. That's the whole point of your role.

---

## 6. How to log what you find

Every bug, subpar feature, or complaint → a new `GW-####` line in `docs/testing/ISSUES.jsonl` (currently 196 entries; next id follows the max). One JSON object per line:

```json
{"id":"GW-0197","title":"…","severity":"P0|P1|P2-subpar|P3-nit","front":"ux|reliability|security|…","evidence":"file:line or device log","repro":"exact steps / adb command","expected":"…","actual":"…","status":"open"}
```

Ground every claim in evidence — a `file:line`, a repro command, or a device log. And when you prove something on a **real device**, say **real device** — that's a different, higher category of truth than the sim, and it's exactly the category this project is missing.

Now go break it. The map ends here; the digging is yours.
