## Notifications, Backstop & Android Native Reliability

**Role in the core promise:** This subsystem is the *last mile* of "wake the rider, never late, never at the wrong place." Everything upstream (GPS, EKF, reachability, the alarm decision) is worthless if the phone stays silent or the button the rider mashes at their stop does nothing. This layer owns: (1) turning "fire the alarm now" into an actual loud sound + escalating vibration + a lock-screen, un-dismissable notification; (2) a **process-death safety net** — an OS-owned exact alarm (`AlarmManager.setAlarmClock`) that sounds *even if the whole app has been killed*, which is the single most important reliability feature for a cheap Android phone that aggressively kills background apps; (3) the cross-isolate plumbing that lets a notification button tapped while the app is dead reach the tracking logic; (4) the permissions and OEM-specific "autostart / don't-kill-me" persuasion flow that keeps the tracking service alive on Xiaomi/Oppo/Vivo/etc. ROMs that dominate the India market. If this layer is weak, the app fails exactly the users it promises to serve.

**Files:**

| Path | What it does |
|---|---|
| `lib/services/notification_service.dart` | The heart of the Dart side. Shows/cancels the wake alarm, the ongoing progress notification, the "paused/running in background" notification, and the wrong-direction heads-up. Schedules and cancels the OS exact-alarm ETA **backstop**. Owns the cross-isolate request flags (file + SharedPreferences) and the `@pragma('vm:entry-point')` background tap handler `notificationTapBackground`. |
| `android/app/src/main/kotlin/com/example/geowake2/MainActivity.kt` | Native Android host. Creates the notification **channels** (alarm, tracking, **backstop**) before Dart ever posts, so channel-level settings (silent alarm channel, DND bypass, alarm audio usage, backstop's own system tone) are authoritative. Drives the native **escalating vibration waveform** (`geowake/alarm_haptics`). Bridges `ACTION_AUDIO_BECOMING_NOISY` (headset unplug) to Dart (`geowake/alarm_audio`). |
| `packages/wakepoint_native/android/.../WakepointNativePlugin.kt` | Tiny native plugin on channel `geowake/native`. Holds a **process-static PARTIAL_WAKE_LOCK** (CPU awake, screen off) for the whole tracking session, and answers `canUseFullScreenIntent()` (Android 14+ gate). |
| `lib/services/oem_autostart_service.dart` | Deep-links the user into each OEM's hidden "autostart / background allowlist" screen (MIUI, ColorOS/HyperOS, Funtouch, EMUI, OxygenOS, One UI) and requests Doze/battery-optimization exemption. |
| `lib/services/permission_service.dart` | The one-time onboarding permission funnel: location → background location → notifications → activity recognition → reliability setup (battery + autostart). |
| `android/app/src/main/AndroidManifest.xml` | Declares every permission (wake lock, exact alarm, full-screen intent, boot-completed, notification-policy) and — critically — **re-declares the flutter_local_notifications receivers** that v16+ no longer auto-adds, without which the exact-alarm backstop is never delivered. |
| `android/app/src/main/java/com/example/geowake2/AlarmReceiver.kt` | **EMPTY (0 bytes).** An orphaned/placeholder file. Not registered in the manifest, imported by nothing. See Gaps §G. |

---

### How it works, step by step

#### A. The wake alarm (the moment that matters)

The alarm decision is made upstream (`alarm_controller.dart`, `trackingservice.dart`, `foreground_bridge.dart`), which calls `NotificationService().showWakeUpAlarm(title, body, allowContinueTracking, playSound)` (`notification_service.dart:693`). Concrete flow:

1. **Duplicate guard** (`:728`). If `_alarmCurrentlyShowing` is already true and this is a *continue-tracking* (non-destination) alarm, it returns — no double overlay. But if `allowContinueTracking == false` (the final **destination** alarm), it *force-cancels* the existing alarm (`cancelAlarm(restoreJourney:false)`) and falls through — destination alarm always wins. Then `_alarmCurrentlyShowing = true`.
2. **Crash-recovery breadcrumb** (`:748–756`). Sets `TrackingStateStore.setAlarmFired(true)` and writes `pending_alarm_flag/title/body/allow` into SharedPreferences so the alarm can be re-posted (`ensureAlarmNotificationVisible`) if Android silently drops the notification.
3. **Build `AndroidNotificationDetails`** on channel `geowake_alarm_channel_v4` (`:761`):
   - `importance: max`, `priority: max`, `category: alarm`, `audioAttributesUsage: alarm`, `visibility: public` (shows on lock screen).
   - `playSound: false` and `enableVibration: false` — **the notification itself is intentionally silent.** Audio is driven by `AlarmPlayer` and vibration by `AlarmHaptics`/`MainActivity`, so the two stay in sync. (See Design §3.)
   - `fullScreenIntent: await WakepointNative.canUseFullScreenIntent()` (`:773`) — only requests the full-screen (lock-screen takeover) intent when the OS will actually honor it (Design §5).
   - `ongoing: true`, `autoCancel: false`, `additionalFlags: [4, 32]` = `FLAG_INSISTENT | FLAG_NO_CLEAR` — together with periodic re-posting, this makes the alarm effectively un-dismissable except via its buttons.
   - **Actions**: if `allowContinueTracking` → `[STOP_ALARM, END_TRACKING]`; else (destination) → `[END_TRACKING]` only. All actions set `showsUserInterface: true` (Design §4).
4. **Fire everything in parallel for sync** (`:838–870`): `AlarmPlayer.playSelected()` (or, if `playSound==false`, `AlarmPlayer.markAsPlaying()` because the background isolate owns audio), `_startAlarmVibrationLoop()`, and `_notificationsPlugin.show(id=0, …, payload:'open_alarm:1|0')`, all awaited via `Future.wait`.
5. **Vibration** (`_startAlarmVibrationLoop`, `:455`): prefers native (`AlarmHaptics.start` → `geowake/alarm_haptics` → `MainActivity.startAlarmVibration`). The native path builds an **escalating waveform** `timings=[0,400,200,700,200,1000,250,1400,300,1400,300]`, `amplitudes=[0,110,0,160,0,205,0,255,0,255,0]`, `repeatIndex=5` — starts soft, ramps to full strength, then loops the strong tail forever (`MainActivity.kt:38–42, 122–172`). If the motor lacks amplitude control it uses the timing-only waveform. If the native channel is unavailable, Dart falls back to the `vibration` plugin with a self-resyncing `Timer.periodic` every `4600ms` (`:441, :467`).

**Notification IDs (never collide):** alarm=`0`, progress=`888`, paused=`889`, wrong-direction=`890`, ETA backstop=`991` (`:408–413, :884`).

#### B. The ETA backstop — surviving TOTAL process death

This is the reliability crown jewel. On every ~1 Hz state broadcast, `notification_updater.dart:_maybeRearmEtaBackstop` (`:173`) recomputes when the rider should be woken and (re)schedules an **OS-owned** alarm so the wake happens *even if the Flutter process is dead*:

1. If the real alarm already fired (`alarmFired || destinationAlarmFired`) → `cancelEtaBackstop()` (id 991) so it can't double-fire (`:179`).
2. Else compute `leadSeconds`: time/minutes mode → `alarmValue * 60`; distance-before / stops-before → a hard-coded **60 s floor** (`:191–200`, Design §7 flaw).
3. `fireInSeconds = etaSeconds − leadSeconds`. If ≤ 0, arm ~immediately (`now + 2s`); else arm at `now + fireInSeconds` (`:202–218`).
4. `NotificationService().scheduleEtaBackstop(fireAt, title, body)` (`:891`): builds a `TZDateTime` in **UTC** (no local-zone lookup needed since it's `now + Duration`), and calls `_notificationsPlugin.zonedSchedule(id=991, …, androidScheduleMode: AndroidScheduleMode.alarmClock)`. `alarmClock` maps to `AlarmManager.setAlarmClock`, the highest-priority alarm class that **fires through Doze**.
5. **The backstop posts on its OWN channel** `geowake_backstop_channel_v1` with `playSound: true`. That channel is created natively in `MainActivity.createNotificationChannel` (`:231–252`) with the **system default ALARM ringtone**, `enableVibration(true)`, pattern `[0,600,300,600,300,600]`, `bypassDnd(true)`. This is the key asymmetry: the *live* alarm channel is silent (its audio comes from a running isolate — useless when the process is dead), so the backstop needs a channel that the **OS itself** will sound with no app code running.
6. For this to work at all, the manifest re-declares `ScheduledNotificationReceiver`, `ScheduledNotificationBootReceiver` (BOOT_COMPLETED / MY_PACKAGE_REPLACED / QUICKBOOT), and `ActionBroadcastReceiver` (`AndroidManifest.xml:75–90`). flutter_local_notifications v16+ dropped these; without them AlarmManager fires but nobody catches the intent.

#### C. Notification buttons from a dead/background process (cross-isolate plumbing)

When the app is backgrounded or killed, a tapped notification **action** is delivered to the flutter_local_notifications *background* isolate, which runs the top-level `@pragma('vm:entry-point') notificationTapBackground` (`:1531`). That isolate cannot reliably reach the running tracking isolate directly, so the design uses **two redundant channels**:

- **File flags** in `getApplicationDocumentsDirectory()`: `.gw_stop_alarm_flag`, `.gw_end_tracking_flag`, `.gw_mute_journey_flag`. `_writeFlag` creates the file; `_consumeFlag` does an atomic exists→delete→return (`:52–84`). Files are used because they're more reliable across isolates than SharedPreferences (which caches per-isolate).
- **SharedPreferences** mirror (`gw_stop_alarm_request_v1` etc. + `_ts`) as a backup, read with `prefs.reload()` for cross-isolate freshness (`:86–180`).

`notificationTapBackground` (`:1531–1749`) branches by `actionId`:
- `STOP_ALARM` → `requestStopAlarmForService()` (persist), then immediate best-effort: cancel notif 0, `Vibration.cancel()` ×2, `FlutterBackgroundService().invoke('stopAlarm')`, `AlarmPlayer.stop()`.
- `IGNORE` → journey payload: `requestMuteJourneyForService()` **and** immediately `TrackingStateStore.setNotificationsMuted(true)` + cancel 888. Alarm payload: same as a mild stop.
- `END_TRACKING` → `requestEndTrackingForService()`, `invoke('stopTracking',{stopSelf:true})`, cancel 0/888/889. **(Does NOT cancel backstop 991 — see Gap §A.)**
- `RESUME_TRACKING` → `setPaused(false)`, cancel 889, reload snapshot, `invoke('startTracking', {...})`.

The **live tracking isolate** drains those flags from two poll sites: `alarm_controller.dart:1486/1506/1522` (the `_alarmStopPollTimer`) and `location_stream_handler.dart:469/480/489` (per-fix). When it sees the flag it runs the *real* cleanup (`cancelAlarm`, `setNotificationsMuted`, `cancelAllNotifications`, `stopTracking`). So the button gives instant best-effort feedback *and* durable intent that survives until the tracking isolate can act.

**Foreground taps** (app alive): `initialize()` registers `onDidReceiveNotificationResponse` → `handleNotificationResponse` (`:215`) → `classifyAction` (`:182`) → `_handleNotificationAction` (`:246`), which calls `TrackingService` / `cancelAlarm` directly and can navigate to `/mapTracking` (rehydrating from `TrackingStateStore.loadSnapshot()`).

#### D. Wake lock, audio route, DND

- **Wake lock**: `TrackingService` calls `WakepointNative.acquireWakeLock()` at session start (`trackingservice.dart:2212`) and `releaseWakeLock()` at stop (`:923`). Native holds a **process-static, non-ref-counted** `PARTIAL_WAKE_LOCK` with a **6-hour safety ceiling** so a leaked lock can't drain the battery forever (`WakepointNativePlugin.kt:56–76`). Process-static means it survives the UI FlutterEngine being torn down on app-swipe, as long as the OS process lives.
- **Headset unplug**: `MainActivity` registers a `BroadcastReceiver` for `ACTION_AUDIO_BECOMING_NOISY` and forwards `audioBecomingNoisy` over `geowake/alarm_audio` (`MainActivity.kt:44–52, 84–98`). `AlarmPlayer._onAudioBecomingNoisy` (`alarm_player.dart:187`) re-asserts alarm audio attributes and re-applies volume so the alarm doesn't stay pinned to a now-dead Bluetooth route. Vibration keeps running independently as the tactile fallback.
- **DND / silent**: both the alarm channel and backstop channel call `setBypassDnd(true)` (`MainActivity.kt:219, 247`), a no-op unless the user has granted `ACCESS_NOTIFICATION_POLICY` (manifest `:25`). The app never explicitly walks the user to grant it (Gap §D).

#### E. Permissions & OEM persuasion (onboarding)

`PermissionService.requestEssentialPermissions` (`:16`) runs a strict funnel: `_requestLocationPermission` → (if granted) `_requestBackgroundLocation` ("Allow all the time") → `_requestNotificationPermission` → `_requestActivityRecognitionPermission` (non-critical) → `_runReliabilitySetup`. Location and background-location are **hard gates** (return `false` aborts). `_runReliabilitySetup` (`:39`) runs once (guarded by `reliability_setup_done`), asks permission via a rationale dialog, calls `OemAutostartService.requestIgnoreBatteryOptimizations(pkg)`, and — if `isAggressiveOem()` — deep-links into the OEM autostart screen. `OemAutostartService` (`oem_autostart_service.dart`) maps manufacturer → `[package, componentName]`, probes each with `canResolveActivity()` (needs the manifest `<queries>` entries, `:107–116`), launches the first that resolves, else falls back to the generic battery-optimization settings page.

---

### Key types & functions

- `NotificationService` (singleton, `:360`). Core methods:
  - `initialize()` `:575` — init tz db, register foreground+background response handlers, request POST_NOTIFICATIONS/exact-alarm/full-screen-intent perms, create the three Dart-side channels.
  - `showWakeUpAlarm({title, body, allowContinueTracking, playSound})` `:693` — the alarm.
  - `scheduleEtaBackstop({fireAt, title, body})` `:891` / `cancelEtaBackstop()` `:940` — OS safety net (id 991).
  - `showJourneyProgress({title, subtitle, progress0to1, isTracking})` `:1180` — swipe-able ongoing progress (id 888), suppressed if paused or muted.
  - `showTrackingPaused({destinationName})` `:1319` / `cancelTrackingPaused()` `:1427` — "Running in background" notification (id 889) after app-swipe.
  - `ensureAlarmNotificationVisible()` `:1035` / `ensureTrackingPausedNotificationVisible()` `:1117` — periodic re-post (rate-limited 2 s / 5 s) to defeat Android 16 ongoing-dismissal.
  - `showWrongDirectionAlert({destinationName, minInterval=2min})` `:957` — silent heads-up nudge (id 890), throttled.
  - `cancelAlarm({restoreJourney})` `:548`, `stopVibration()` `:503`, `cancelAllNotifications()` `:1466`, `restoreJourneyProgressIfActive()` `:514`.
  - Static cross-isolate: `requestStopAlarmForService/consumeStopAlarmRequest` (+ EndTracking, MuteJourney) `:86–180`.
  - `classifyAction(actionId, payload) → NotificationActionOutcome` `:182` (pure, `@visibleForTesting`).
  - Test seams: `isTestMode`, `testOnShowWakeUpAlarm`, `testRecordedNotifications`, etc.
- `notificationTapBackground(response)` `:1531` — top-level `vm:entry-point` background isolate handler.
- `MainActivity` (Kotlin): `createNotificationChannel()`, `startAlarmVibration()`/`stopAlarmVibration()`/`buildAlarmEffect()`, `becomingNoisyReceiver`.
- `WakepointNativePlugin` (Kotlin): `acquireWakeLock()`/`releaseWakeLock()`/`isWakeLockHeld`/`canUseFullScreenIntent()` on `geowake/native`.
- `OemAutostartService`: `manufacturer()`, `isAggressiveOem()`, `openAutoStartSettings()`, `requestIgnoreBatteryOptimizations(pkg)`.
- `PermissionService(context)`: `requestEssentialPermissions()` and private per-permission helpers.

---

### Design decisions (the WHY)

1. **Two separate alarm channels — a silent "live" channel and a self-sounding "backstop" channel.** *Decided:* `geowake_alarm_channel_v4` has `setSound(null)` / `enableVibration(false)`; `geowake_backstop_channel_v1` carries the system ALARM ringtone + vibration. *Why:* the live alarm's audio and escalating vibration are driven by app code (`AlarmPlayer`, `AlarmHaptics`) so they can be custom, loud, ramping, and stay in sync — but that only works while a process is alive. When the process is *dead*, no app code runs, so the backstop must ask the **OS** to make the noise. *Trade-off / rejected:* a single channel with a built-in sound would double up (channel sound + AlarmPlayer) and desync. *Flaw:* if the live channel is silent and the AlarmPlayer isolate fails to start (audio focus denied, plugin crash), the *live* alarm produces no sound — only vibration + a silent banner — until the backstop's own fire time. The two mechanisms are complementary, not redundant, for the same instant.

2. **Channels created natively in `MainActivity` before Dart's `initialize()`.** *Decided:* create v4 alarm, tracking, and backstop channels in `configureFlutterEngine`. *Why:* Android **freezes** a channel's importance/sound/vibration/DND settings the first time it's created; later edits are ignored. Creating them natively first locks in alarm-usage audio attributes, silence, and DND bypass authoritatively (`MainActivity.kt:191–196`). *Trade-off:* channel IDs are now versioned (`v4`, `v1`) — every settings change needs a new suffix and orphans the old channel in system settings. *Flaw:* users who upgrade accumulate stale channels (`_v2`, `_v3` history) in the app's notification settings list; cosmetic but confusing.

3. **Notification is silent; audio+vibration are app-driven and fired in parallel.** *Why:* precise sync between the ramping sound and the escalating buzz, and the ability to loop insistently regardless of the user's ringer mode (alarm stream). *Trade-off:* more moving parts and more failure surface than "let the channel play a sound." *Flaw:* `additionalFlags:[4,32]` includes `FLAG_INSISTENT (4)`, whose whole purpose is to loop the *notification's* sound/vibration — but there is none at the notification level, so INSISTENT is effectively a no-op here. The persistence actually comes from `ongoing:true` + `FLAG_NO_CLEAR (32)` + periodic re-posting. The code comment overstates INSISTENT's role.

4. **All notification actions use `showsUserInterface: true`.** *Why:* `STOP_ALARM` must stop audio that was started by the *foreground* isolate (via the `triggerAlarm` bridge), which requires waking that same isolate; and it reduces the "button does nothing" feeling by bringing the app forward. *Trade-off:* tapping a button flashes the app open instead of acting purely in the background — slightly jarring, and on a locked phone it can surface UI. *Flaw:* the "start audio in foreground, must stop in foreground" coupling is fragile; the cross-isolate flags exist precisely because this coupling can't always be honored.

5. **Full-screen intent is gated behind `canUseFullScreenIntent()`.** *Decided:* below API 34 always true; on 34+ ask `NotificationManager.canUseFullScreenIntent()` (`WakepointNativePlugin.kt:78–83`). *Why:* Android 14 restricted the lock-screen-takeover full-screen intent to apps the user/Play classifies as alarm-or-calendar; requesting it when it won't be honored just gets the notification demoted. Gating lets the app fall back to a max-importance heads-up banner. *Trade-off / Flaw:* **GeoWake is not categorized as an alarm-clock app**, so on Android 14+ `canUseFullScreenIntent()` will typically return `false`, and the wake alarm will NOT take over the lock screen — it becomes a heads-up banner behind the AlarmPlayer sound. On a phone in a pocket with the screen off, a banner is less certain to rouse a sleeping rider than a full-screen takeover. This is a real dilution of the "never miss it" promise on the newest Android.

6. **Cross-isolate intent via file flags first, SharedPreferences second, plus immediate best-effort side-effects.** *Why:* a notification button tapped after process death lands in the plugin background isolate, which can't call into the tracking isolate. Files survive isolate boundaries better than SharedPreferences' per-isolate cache; doing both plus an immediate `invoke()`/`cancel()` maximizes the chance the rider's tap "does something." *Trade-off:* three redundant mechanisms are hard to reason about and can act twice. *Flaw:* **two independent consumers** drain the same flags — `alarm_controller` poll timer and `location_stream_handler` per-fix (`:469/1486` etc.). `_consumeFlag` deletes on read, so whichever runs first wins and the other silently no-ops. They happen to trigger equivalent actions, so it's benign today, but it's an accidental race, not a designed hand-off.

7. **Backstop lead time is exact only for time/minutes mode; distance- and stops-before use a flat 60 s floor.** *Why:* the primary alarm already handles distance/stops precisely; the backstop just needs to guarantee *a* wake near arrival without ever firing *before* the real alarm. *Trade-off / Flaw:* for a distance-before or stops-before alarm, the backstop fires at `rawETA − 60s`, which has **no relationship to the configured distance/stop threshold**. If the rider set "wake me 3 stops before" (which might be 4 minutes of lead), the dead-process backstop could fire far too late (only 60 s before raw arrival) — i.e. it can wake them essentially *at* the stop, not before. For those modes the backstop weakens the "never late" guarantee precisely when it matters most (process is dead = primary alarm gone). The inline comment even says "tune on-device," i.e. unvalidated.

8. **Process-static, non-ref-counted wake lock with a 6-hour ceiling.** *Why:* keep the CPU alive so GPS/EKF keep running with the screen off, across UI-engine teardown on app-swipe; the ceiling prevents a leaked lock from killing the battery. *Trade-off:* 6 h is arbitrary — a genuine >6 h journey would lose the CPU-awake guarantee mid-trip (the timeout releases it). Non-ref-counted means a double-release or double-acquire is idempotent but also that a stray `releaseWakeLock` from any isolate drops it for everyone.

9. **OEM autostart deep-linking with a per-manufacturer component table.** *Why:* Chinese/other OEM ROMs kill background services regardless of the standard Android battery-optimization exemption; the only fix is the OEM's own hidden allowlist screen, which has a different `ComponentName` per brand and per ROM generation. *Trade-off / Flaw:* these component names are **undocumented and version-fragile** — they change between ColorOS/HyperOS/EMUI releases and can vanish, so `canResolveActivity()` often fails and the code silently falls back to the generic battery page, which does NOT actually add the autostart allowlist entry. There's no telemetry on whether the deep link succeeded, and no verification that the user actually toggled the switch. This is the single biggest *soft* reliability risk for the India core-promise market and it's fundamentally best-effort.

10. **"Running in background" copy instead of "Tracking paused".** *Decided:* after the app is swiped away, the paused notification says "Running in background — still watching your trip" (`:1337`). *Why (G3):* alarm evaluation genuinely CONTINUES in the background isolate; the old "Tracking paused — Resume to continue" copy falsely implied the wake alarm had stopped, which is terrifying for a sleeping rider. *Trade-off:* the underlying *state* is still `paused==true`, so there's a mismatch between the reassuring copy and the internal paused flag (which suppresses progress updates). A reader of the code can be misled that tracking is fully live when the state machine still calls it paused.

11. **Wrong-direction alert reuses the alarm channel but stays silent.** *Why:* surface it as a high-priority heads-up banner (piggybacking the loud channel's importance) without sounding the wake alarm, since it's a nudge, throttled to every 2 min. *Flaw:* because the channel is silent and this notification sets `playSound:false`/`enableVibration:false`, a **half-asleep rider gets a silent banner** — exactly the audience least likely to see a silent banner. The most valuable moment (rider boarded the opposite train) is signalled the most weakly.

12. **Requesting background location inline in the onboarding funnel and treating it as a hard gate.** *Why:* background location is genuinely essential to the promise. *Trade-off / Flaw:* on Android 11+ `Permission.locationAlways.request()` cannot grant "Allow all the time" in-dialog — it routes to Settings, and a user who taps "Continue" but doesn't flip the settings toggle causes `requestEssentialPermissions` to return `false`, which upstream may treat as a blanket permission failure. The two-step OS reality isn't reflected in the single rationale dialog.

---

### Invariants

- **Notification IDs are globally unique and fixed**: alarm=0, progress=888, paused=889, wrong-direction=890, backstop=991 (+ legacy 8888 swept in `cancelAllNotifications`). Nothing else may reuse these.
- **At most one live wake alarm**: `_alarmCurrentlyShowing` gates duplicates; a destination alarm (`allowContinueTracking==false`) may pre-empt a continue alarm, never the reverse.
- **Backstop and live alarm are mutually exclusive in time**: once `alarmFired`/`destinationAlarmFired`, `cancelEtaBackstop()` runs (`notification_updater.dart:179`) so the OS backstop can't double-fire after the real alarm.
- **The live alarm channel is always silent; the backstop channel always self-sounds.** These channel identities must not be swapped.
- **Channels must be created natively before any Dart post** (importance/DND/sound freeze on first creation).
- **Cross-isolate flags are single-consume**: a flag file is deleted the first time any consumer reads it.
- **Wake lock is released on every stop path** (`stopTracking` → `:923`), bounded by the 6 h ceiling regardless.

### Interfaces

- **Consumes from:** `TrackingStateStore` (paused/active/muted/alarmFired flags, progress payload, journey snapshot); `AlarmPlayer` (`playSelected`, `stop`, `markAsPlaying`, and the shared `geowake/alarm_audio` channel); `AlarmHaptics` (`geowake/alarm_haptics` → `MainActivity`); `WakepointNative` (`geowake/native` → wake lock + `canUseFullScreenIntent`); `FlutterBackgroundService.invoke` (`stopAlarm`/`stopTracking`/`startTracking`); `NavigationService.navigatorKey`; `timezone` db.
- **Exposes to:** `alarm_controller.dart` & `foreground_bridge.dart` & `trackingservice.dart` & `maptracking.dart` (call `showWakeUpAlarm`, `showWrongDirectionAlert`); `notification_updater.dart` (calls `scheduleEtaBackstop`/`cancelEtaBackstop`); `location_stream_handler.dart` (calls `ensureAlarmNotificationVisible`/`ensureTrackingPausedNotificationVisible` and drains the request flags); the poll timer in `alarm_controller.dart` (drains flags). `PermissionService` is called by app onboarding; `OemAutostartService` by `PermissionService`.
- **Native surface:** channels `geowake/alarm_haptics`, `geowake/alarm_audio`, `geowake/native`; the FLN receivers declared in the manifest.

---

### Gaps & flaws vs the core promise (brutally honest)

**A. End Tracking from a dead process can leave a live backstop → spurious wake ("wrong place / wrong time").** `notificationTapBackground`'s `END_TRACKING` branch (`:1663`) cancels notifications 0/888/889 but **not** the backstop (991), and `cancelAllNotifications` (`:1466`) also does not call `cancelEtaBackstop`. Backstop cancellation only happens inside the foreground `stopTracking` path (`trackingservice.dart:925`). So if the user taps "End Tracking" while the tracking isolate is dead, the flag is written but never consumed, `stopTracking` never runs, and the OS backstop (991) remains scheduled — it will fire later and blare the alarm ringtone after the user thought they ended the trip. Directly violates "never at the wrong place." *Severity: high.*

**B. Android 14+ almost certainly loses the full-screen lock-screen alarm.** Because the app isn't classified as an alarm-clock app, `canUseFullScreenIntent()` returns false on 14+, degrading the wake to a heads-up banner behind the AlarmPlayer sound (Design §5). If audio focus is contested or the device is silenced without notification-policy access, the pocket-phone rider may get neither takeover nor sound. *Severity: high on newest Android.*

**C. Backstop timing is wrong for distance/stops-before modes.** The flat 60 s lead (Design §7) means the process-death safety net can wake a stops-before rider essentially at their stop instead of the configured number of stops early — the "never late" guarantee is weakest exactly when the primary alarm is gone. *Severity: high for those modes.*

**D. DND / silent mode not actually handled end-to-end.** `setBypassDnd(true)` is a no-op without `ACCESS_NOTIFICATION_POLICY`, and nothing in `PermissionService` requests or guides the user to grant notification-policy access. A rider who sleeps with the phone on Do-Not-Disturb (extremely common) may get a suppressed alarm. *Severity: high.*

**E. Reboot mid-journey does not resume live tracking.** The manifest comment (`:21`) claims "G4: re-arm background service + backstop after device reboot," but the only boot receiver present is FLN's `ScheduledNotificationBootReceiver`, which re-arms *scheduled notifications* (the backstop) only. There is **no receiver that restarts `flutter_background_service`** after boot. So after a reboot the live EKF/GPS tracking is dead and the app relies solely on whatever the *last-scheduled* backstop value was — which is frozen at the pre-reboot ETA and won't adapt if the train is delayed. The doc/claim overstates what's implemented. *Severity: medium–high.*

**F. OEM autostart is best-effort and unverifiable.** Undocumented, version-fragile component names; silent fallback to a battery page that doesn't add the allowlist entry; no telemetry, no confirmation the user toggled anything (Design §9). On the exact devices the core promise targets, background survival can't be guaranteed. *Severity: high (soft/probabilistic).*

**G. `AlarmReceiver.kt` is a 0-byte orphan.** Assigned to this subsystem but completely empty, unregistered in the manifest, referenced by nothing. Either dead scaffolding to delete or an intended native alarm receiver that was never implemented — worth clarifying, since a native `BroadcastReceiver` catching the AlarmManager intent would be a stronger backstop than routing through flutter_local_notifications. *Severity: low (hygiene), but symptomatic.*

**H. Exact-alarm permission can be revoked and isn't monitored.** `SCHEDULE_EXACT_ALARM` (Android 13) is revocable in Settings and only requested best-effort in `initialize()` with the result ignored. If revoked, `setAlarmClock` degrades to an inexact alarm that Doze can defer — silently weakening the backstop with no user warning. *Severity: medium.*

**I. Double-consumer flag race.** Two independent isolate loops drain the same single-consume flags (Design §6). Benign today only because both do equivalent work; any future divergence in their handlers becomes a nondeterministic bug. *Severity: low now, latent.*

**J. Paused-state vs. "Running in background" copy mismatch.** The reassuring copy coexists with an internal `paused==true` that suppresses progress updates (Design §10). Not user-visible harm, but a maintenance trap. *Severity: low.*
