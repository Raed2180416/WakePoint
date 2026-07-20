# GeoWake / WakePoint — Ranked Testing Findings Report

> Autonomous testing + hardening pass, 2026-07-20 (branch `sim-validation`).
> Source of truth: `docs/AGENT_TESTING_CHARTER.md`. Full log: `docs/testing/ISSUES.jsonl`.
> Session detail: `docs/testing/TESTING_SESSION_LOG.md`. Fix designs: `docs/testing/NEVERLATE_FIX_DESIGNS.md`.
> **Device-proof caveat (prime directive #2): every finding below is `sim` or `emulator`.**
> **No claim here is confirmed on a real underground ride.** Real-hardware re-verification of P0/P1 is outstanding.

## Executive summary

- **Never-late (the one promise) holds in SIMULATION on all 395 generated rides** (`test/scale/reachability_scale_test.dart`, LATE=0, never-fired=0) through the real reachability code. It has NOT been confirmed on real hardware.
- **Two-sided window gap (too-early):** on sustained GPS-blackout rides the shipped free-run bound over-fires up to **+10 stops / 859 s early** (egregious 22/395). Arming the proven dwell cap (validated, never-late-preserving) collapses it to max +7 / egregious 14 (−36%); the full fix set is designed + adversarially verified.
- **3 P0 NEVER-LATE holes found in production that the sim oracle cannot catch** (it injects certified line speeds): V_LINE line-name collision, the 8 s + 25 m/s blackout-onset window, and an ETA-based (not physics-based) process-death backstop — the last contradicting the sealed handoff doc (a docs-lie).
- **2 P0 TOO-EARLY:** multi-leg mode-max inflation, and the entire fastest-feasible tightening subsystem shipped **dormant/unwired**.
- Guardrails: core alarm is NOT gated; the wake/alarm surface itself is ad-free (a banner rides the *tracking* screen but collapses underground and is superseded by the full-screen wake); raw-location egress is user-initiated opt-in share only (aggregate surface is egress-OFF). No hard guardrail breach found.

### Severity histogram (145 findings)

| severity | count |
|---|---|
| P0-never-late | 3 |
| P0-too-early | 2 |
| P0 | 2 |
| P1 | 28 |
| P1-too-early | 1 |
| P2-subpar | 54 |
| P3-nit | 53 |
| complaint | 2 |

---

## P0 + P1 findings (ranked, full)

### GW-0062 · P0-never-late · [sim] · background
**Re-arm the OS ETA backstop from reachability, not a frozen ETA that postpones it forever during a blackout**
- kind: risk · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:bg-reliability
- actual: The OS backstop trusts a smoothedETA that freezes the moment GPS dies; it is continuously postponed while dark and, on process death mid-blackout, is the only wake left — anchored to a stale ETA. The reachability net that would cover this (alarm_controller) is in-process only and dies with the process.
- expected: The process-death survivor (OS setAlarmClock backstop) should be driven by the same never-late physics/reachability bound the in-process net uses, so it fires early regardless of GPS silence.
- evidence: sim/code-read (discovery bg-reliability): lib/services/tracking/notification_updater.dart:227 `etaSeconds = context.smoothedETA ?? context.apiEtaSeconds`; :237 `fireInSeconds = etaSeconds - leadSeconds`; :250 `scheduleEtaBackstop(fireAt: DateTime.now().add(Duration(seconds: fireInSeconds.round())))`. broadcastSimulationState calls _maybeRearmEtaBackstop every state broadcast (~1 Hz, :169). smoothedETA is only recomputed on a REAL GPS fix (location_stream_handler.dart:346 _computeEta, called only from _handlePositionUpdate); the dead-reckon tick (_maybeEvaluateAlarmDuringDropout) never updates 
- repro: 1. Arm with the rider far out (e.g. distance/time alarm, ETA ~15 min). 2. Enter a tunnel immediately so GPS goes dark; smoothedETA freezes at ~900s. 3. Each ~1s tick recomputes fireAt = now + (900 - lead); because 'now' advances but ETA stays 900, the scheduled setAlarmClock instant is pushed ~1s la

### GW-0076 · P0-never-late · [sim] · background
**Fix V_LINE under-bound from line-name collision (Airport Express as 'Orange Line', Mumbai suburban as 'Western Line') — a physics LATE fire**
- kind: too-early · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:bg-neverlate
- actual: A fast service whose Directions-reported name lacks the keyword resolves to 28 m/s. During a GPS blackout the free-run bound s_max=s0_hi+28*dt grows ~9.5 m/s slower than the real 37.5 m/s train; over a 5-min tunnel the bound lags true progress by ~2850 m (~2 stations) → alarm fires LATE. This is a true never-late violation, not the too-early GW-0005.
- expected: V_LINE >= the line's true max speed on every leg (precondition ii). A 135 km/h service must resolve to >=37.5 m/s.
- evidence: sim/code-read (discovery bg-neverlate): lib/core/reachability/reachability.dart:53 defaultMps=28 (100 km/h); :98-106 looksExpress only keyword-matches airport/express/rapid/suburban/local; :130-136 forLine falls to defaultMps when no keyword hits; :115-129 in-code 'KNOWN RESIDUAL' admits Delhi Airport Express reported as 'Orange Line' (135 km/h) and Mumbai Suburban reported as 'Western/Central Line' (~120 km/h) resolve to 28 m/s.  [REFUTE-VERIFIED CONF: Independently reproduced from source. reachability.dart:53 defaultMps=28 (100 km/h); :98-106 looksExpress keyword-matches only airport/express
- repro: 1. Route on Delhi Airport Express (Orange Line), name reported as 'Orange Line'. 2. forLine returns 28 m/s. 3. Enter 6-min tunnel at true 135 km/h from last fix at s0. 4. Feed nowSeconds advancing; observe Reachability.bound.sMaxMeters vs true arc-progress (37.5*dt). 5. sMax < true progress → reache

### GW-0079 · P0-never-late · [sim] · background
**Close the 8-second physics-blind window at blackout onset where a frozen dead-reckoner can fire late**
- kind: risk · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:bg-neverlate
- actual: For the first 8s the physics bound is inert and firing rests on deadReckoned + 2*clamp(sigma,300). The EKF only enters degraded-sigma mode ~3s in, so sigma may not reach the ~112 m (metro) / ~156 m (express) needed to cover the 224-312 m a train travels in 8s. If dead-reckon and sigma are momentarily frozen, a stop reached within 8s of the last fix can fire late.
- expected: The never-late net should cover the FULL blackout including the first 8s; the fallback statistical cushion must exceed the distance the train can cover in that window.
- evidence: sim/code-read (discovery bg-neverlate): lib/config/fire_decision_config.dart:51 reachBlackoutMinSeconds=8.0; :42 maxFractileSigmaMeters=300. lib/services/tracking/alarm_controller.dart:955-957 and :1441-1444 suppress the reach bound unless dtSeconds>=8s or +inf. lib/services/sensor_fusion.dart:189 EKF only told GPS-unavailable after _noFixDegradeThreshold=3s, so honest sigma growth starts late.  [REFUTE-VERIFIED CONF: All cited file:lines say what the finding claims. The physics reach bound is dropped for the first 8s of any blackout (alarm_controller.dart:955-957 and :1441-1444 require bb.dtS
- repro: 1. Last real fix at s0, then GPS silent. 2. Train at 39 m/s (express). 3. At t0+7s train has moved 273 m; reach bound still gated off. 4. If EKF sigma cushion < 273 m, effectiveProgress < true and a stop 250 m ahead is passed before firing.

### GW-0077 · P0-too-early · [sim] · background
**Cap multi-leg mode-max V_LINE to the reachable leg set — a downstream RRTS/express leg fires the current slow-metro blackout ~2x too early**
- kind: too-early · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:bg-neverlate
- actual: vMaxFwd adopts the fastest forward leg's ceiling (e.g. 53 m/s RRTS) for the CURRENT leg's blackout, so the free-run bound inflates ~2x and the alarm fires up to twice as early as physics on that leg requires. The stop-count cap that makes the 'could be on the faster leg' assumption unnecessary is dormant, so the safety margin is paid in full as too-early.
- expected: While the rider is provably still on a 28 m/s metro leg (they cannot reach the RRTS leg without passing intervening capped stations), the blackout bound should grow at ~28 m/s.
- evidence: sim/code-read (discovery bg-neverlate): lib/services/tracking/alarm_controller.dart:1403-1410 vMaxFwd = max V_LINE over ALL legs from currentLegIndex forward (incl. RRTS 53 m/s); :1419-1420 the topology cap that would forbid teleporting into that leg is built with dwellMinSeconds:0.0 (inert) and no profile.  [REFUTE-VERIFIED CONF: Independently reproduced from source. alarm_controller.dart:1406-1409 takes vMaxFwd = max V_LINE over ALL forward legs (incl. RRTS rrtsMps=53.0, reachability.dart:61) and applies it to the CURRENT leg's blackout. The compensating stop-count cap is provably inert: rea
- repro: 1. Multi-leg journey: leg0 = Blue Line metro (28 m/s), leg2 = Namo Bharat RRTS (53 m/s). 2. Blackout on leg0 for 4 min. 3. reachBoundMeters = s0 + 53*240 = +12.7 km vs +6.7 km at the true leg speed. 4. effectiveProgress crosses the fire target ~6 km / ~5 stops early.

### GW-0078 · P0-too-early · [sim] · background
**Wire the tightening levers — the too-early fix (GW-0011) is not merely OFF, it is UNWIRED and would silently no-op if flipped (refines GW-0011)**
- kind: missing · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:bg-neverlate
- actual: Even if an operator sets ReachabilityConfig.dynamicLeversEnabled=true, the production path passes topology.profile==null so the sweep is skipped and the cone stays free-run. And anyone arming a dwell via RouteTopology(dwellMinSeconds: X) gets ignored because bound() only consults config.dwellMinSeconds. The tightening is dead-wired: the biggest UX lever cannot engage from where the controller builds the topology.
- expected: The proven never-late tightening (stop-count dwell cap and/or the accel+brake+curve profile, all constants reach-maximizing) should be arm-able to cut the up-to-+10-stops early fire without any late risk.
- evidence: sim/code-read (discovery bg-neverlate): lib/services/tracking/alarm_controller.dart:1419-1420 production RouteTopology is built with NO `profile`, so RouteProfile.precompute is never called outside ekf_test_controller.dart; :136 _reach.config fixes dwellMinSeconds:0.0. lib/core/reachability/reachability.dart:519 the dynamic sweep requires topology.profile != null AND config.dynamicLeversEnabled; :534-547 the flat dwell cap reads config.dwellMinSeconds (NOT RouteTopology.dwellMinSeconds); RouteTopology.dwellMinSeconds (:178) is a dead field never read by bound().  [REFUTE-VERIFIED CONF: Every c
- repro: 1. Set _reach = ReachabilityTracker(config: ReachabilityConfig(dwellMinSeconds: 20, dynamicLeversEnabled: true)). 2. Run a blackout eval through _evaluateWithRoute. 3. reachTopo has no profile → dynamic sweep skipped; flat cap uses config dwell (works) but profile lever never runs; RouteTopology.dwe

### GW-0001 · P0 · [sim] · background
**Alarm can be SILENT — volume ramp is player-relative, not STREAM_ALARM**
- kind: bug · verified: single (research code-read) · status: open · found: reliability-research
- actual: Player-relative ramp cannot un-mute a 0 alarm stream.
- expected: A wake-alarm must be audible regardless of the app's own ramp; raise/check STREAM_ALARM at ring time or preflight-warn.
- evidence: sim/code-read: lib/services/alarm_player.dart ~23-30 ramps player volume 0.25->1.0 but does not touch AudioManager STREAM_ALARM; if the OS alarm-stream volume is 0 the wake makes no sound (vibration only).
- repro: Set alarm stream volume to 0 on a device; arm a trip; let the wake fire -> no audio.

### GW-0008 · P0 · [sim] · background
**OEM battery-killers defeat the live service (HyperOS autostart-off, Samsung sleep buckets)**
- kind: risk · verified: single (research) · status: open · found: reliability-research
- actual: No per-OEM onboarding gate; relies on the user.
- expected: Mandatory per-OEM onboarding (deep-link autostart/battery-unrestricted/lock-in-recents), verified programmatically + re-verified after boot.
- evidence: dontkillmyapp + OEM docs: Xiaomi HyperOS/MIUI Autostart OFF by default with no API; Samsung One UI ~3d 'sleeping' / ~16d 'deep sleep'; ColorOS/OxygenOS/Vivo similar. Without exemptions the OS won't launch the process to service the exact alarm.
- repro: On a Xiaomi with autostart off, arm + reboot/sleep -> backstop may not fire.

### GW-0002 · P1 · [sim] · background
**DND bypass is claimed but NOT implemented**
- kind: bug · verified: single (research code-read) · status: open · found: reliability-research
- actual: Claimed in comments; not wired.
- expected: Either wire real DND bypass via a native channel, or stop claiming the alarm bypasses DND.
- evidence: code-read: no setBypassDnd call anywhere; flutter_local_notifications channel doesn't expose it (upstream #1211); ACCESS_NOTIFICATION_POLICY declared in AndroidManifest.xml:25 but unused.
- repro: Enable DND 'Total silence' (or disable the Alarms exception); fire the wake -> silenced, only vibration.

### GW-0003 · P1 · [sim] · background
**Direct-Boot gap — backstop not re-armed until first unlock after reboot**
- kind: bug · verified: single (research code-read) · status: open · found: reliability-research
- actual: Backstop silently un-armed while locked post-reboot.
- expected: Re-arm the exact alarm in a direct-boot-aware receiver, or document the locked-reboot window.
- evidence: code-read: ScheduledNotificationBootReceiver (AndroidManifest ~105-114) is not directBootAware; on FBE devices BOOT_COMPLETED is withheld until first unlock.
- repro: Arm a trip; reboot the phone; leave it locked; the exact-alarm backstop is not re-scheduled until the user unlocks.

### GW-0004 · P1 · [sim] · security
**ACCESS_BACKGROUND_LOCATION declared but likely unnecessary (Play-rejection risk)**
- kind: risk · verified: single (research + manifest) · status: open · found: reliability-research
- actual: ABL declared -> unnecessary Play review + rejection risk.
- expected: Drop ABL if tracking is strictly user-initiated (app open at start); keep only FINE/COARSE + FOREGROUND_SERVICE_LOCATION.
- evidence: AndroidManifest.xml declares ACCESS_BACKGROUND_LOCATION; a location FGS started while foregrounded keeps while-in-use access after screen-off WITHOUT ABL. ABL triggers Play's prominent-disclosure review (common rejection path).
- repro: n/a (policy/config).

### GW-0006 · P1 · [sim] · background
**USE_EXACT_ALARM vs SCHEDULE_EXACT_ALARM — backstop permission is revocable**
- kind: risk · verified: single (research) · status: open · found: reliability-research
- actual: Relies on the revocable SCHEDULE_EXACT_ALARM path.
- expected: Ship as an alarm app on USE_EXACT_ALARM; complete Play exact-alarm + FSI declarations.
- evidence: SCHEDULE_EXACT_ALARM is denied-by-default on fresh installs targeting 13+, user- and system-revocable; on revoke the app is stopped and ALL future exact alarms are cancelled (silent total-backstop failure). USE_EXACT_ALARM is auto-granted + non-revocable and GeoWake qualifies as an alarm app.
- repro: Revoke 'Alarms & reminders' for the app -> backstop silently dies.

### GW-0007 · P1 · [sim] · background
**Full-screen-intent may be denied -> lock-screen wake silently degrades**
- kind: risk · verified: single (research) · status: open · found: reliability-research
- actual: Wake path may depend on the FSI activity launching.
- expected: Gate the FSI activity on canUseFullScreenIntent() and make the WAKE come from audio on a category=alarm channel so it wakes regardless.
- evidence: Since 2025-01-22 USE_FULL_SCREEN_INTENT is auto-granted only to calling/alarm apps; a 'transit' classification revokes it by default and the FSI activity won't auto-launch over lock.
- repro: With FSI not granted, fire the wake while locked -> heads-up notification, no full-screen takeover.

### GW-0010 · P1 · [sim] · security
**Share bearer token is a single shared secret compiled into the client (extractable)**
- kind: risk · verified: single (security research) · status: open · found: security-research
- actual: Global shared secret in the client.
- expected: Move to per-device/per-share capability tokens; enable HMAC link verification.
- evidence: --dart-define GEOWAKE_SHARE_TOKEN is baked into libapp.so (recoverable via reFlutter/Blutter); one token for all installs; backend authz assumes it's secret. HMAC link-token verification is OFF by default.
- repro: Dump libapp.so from the APK -> recover the bearer token -> call /v1 endpoints.

### GW-0011 · P1 · [sim] · background
**Fastest-feasible tightening subsystem is BUILT but DORMANT in production (dwellMin=0, dynamicLevers=off)**
- kind: subpar · verified: oracle (deterministic 395-ride sim gate, armed vs free-run) · status: confirmed · found: engine-source-read
- actual: Tightening dormant; users get the widest early-fire window on exactly the long-blackout rides where it matters most.
- expected: Arm the tightening on the shipping path where it is PROVABLY never-late (terminal-braking envelope + curve ceiling are unconditional physics; dwell cap needs per-served-station dwell lower bounds honoring express skips) so the too-early tail (GW-0005) collapses.
- evidence: sim/code-read 2026-07-20: production alarm path lib/services/tracking/alarm_controller.dart:135 constructs ReachabilityTracker(config: ReachabilityConfig(dwellMinSeconds:0.0)); the topology built at :1420 uses dwellMinSeconds:0.0; dynamicLeversEnabled is never set anywhere in lib/ (only in lib/core/ekf/ekf_test_controller.dart tests). With dwellMin=0 the topology cap _topologyCappedProgress equals free-run (pays 0 dwell), and with dynamicLevers=off the RouteProfile fastest-feasible sweep (accel+terminal-braking+curve ceiling) is skipped. So the shipped never-late bound is the loosest possible 
- repro: grep -rn 'dynamicLeversEnabled\|dwellMinSeconds' lib | grep -v reachability.dart -> only ekf_test_controller.dart sets them; alarm_controller.dart ships dwellMinSeconds:0.0.

### GW-0012 · P1 · [sim] · ux
**Stop silently aborting the arm when background location is denied**
- kind: bug · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:ux-firsttime
- actual: First-timer taps Wake Me, grants foreground location, then the separate 'all the time' prompt (which on Android 11+ is a Settings redirect) is refused; the flow silently returns to the home screen with the spinner cleared and zero feedback. The user has no idea why nothing happened.
- expected: If background/'all the time' is refused, show an explanatory dialog (why it's needed for screen-off, how to enable it in Settings) or offer a degraded foreground-only mode — never a no-op.
- evidence: sim/code-read (discovery ux-firsttime): permission_service.dart:95-116 _requestLocationPermission returns await _requestBackgroundLocation(); if the user does not grant 'Allow all the time' (line 114 status.isGranted), it returns false → requestEssentialPermissions() returns false. homescreen.dart:639-643 else-branch just resets loading with comment 'The service already showed the user a dialog' — but background denial shows NO dialog.  [REFUTE-VERIFIED CONF: Independently reproduced from source. permission_service.dart:97 chains foreground grant into _requestBackgroundLocation; lines 114-115 
- repro: 1. Fresh install on Android 11+. 2. Pick a destination, tap Wake Me!. 3. Grant location 'While using the app'. 4. On the background/all-the-time step, decline (or just back out of Settings). 5. Observe: no dialog, no error, arm silently aborts.

### GW-0013 · P1 · [sim] · ux
**Stop silently aborting the arm when notifications are merely denied (not permanently)**
- kind: bug · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:ux-firsttime
- actual: On the first 'Deny' of the notification prompt the whole arm returns false and the screen resets with no message — the rider believes they are armed for sleep when nothing was scheduled.
- expected: A denied wake-notification is fatal to the ONE promise, so refusing it should always explain the consequence and route to Settings, not silently drop the arm.
- evidence: sim/code-read (discovery ux-firsttime): permission_service.dart:118-134 _requestNotificationPermission only shows the settings dialog on status.isPermanentlyDenied (line 124); on a plain first denial it does status=request() (line 132) and returns status.isGranted with NO dialog. homescreen.dart:640-643 then just clears loading.  [REFUTE-VERIFIED CONF: Independently reproduced from source. permission_service.dart:124 gates the settings dialog on isPermanentlyDenied only; on a first plain 'Deny', line 132 calls request() and line 133 returns status.isGranted==false with NO dialog. requestEssent
- repro: 1. Fresh install Android 13+. 2. Pick destination, tap Wake Me!. 3. Grant location. 4. Tap Deny on the notifications prompt (first time = isDenied not permanent). 5. Observe silent abort, no dialog.

### GW-0014 · P1 · [sim] · ux
**Move the whole permission gauntlet out of the first Wake Me press**
- kind: subpar · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:ux-firsttime
- actual: The first arm becomes a multi-minute, multi-screen system-dialog marathon with no progress indicator; drop-off and mis-taps (permanent-deny) are highly likely, and every mis-tap poisons a later step.
- expected: Front-load a brief permission preamble/onboarding right after first launch (or at destination-select), so the user isn't hit with 6+ system dialogs and two Settings detours at the exact moment they wanted to put the phone down.
- evidence: sim/code-read (discovery ux-firsttime): homescreen.dart:602-644 _onWakeMePressed triggers permissionService.requestEssentialPermissions(), which (permission_service.dart:16-33) chains location rationale → location prompt → background rationale → background prompt/Settings → notification prompt → activity-recognition prompt → reliability rationale → battery-optimization Settings → OEM autostart Settings, all AFTER the user pressed a button that says they are ready to sleep.  [REFUTE-VERIFIED CONF: Every cited file:line checks out. homescreen.dart:602-644 _onWakeMePressed calls permissionService
- repro: 1. Fresh install. 2. Pick destination, tap Wake Me!. 3. Count the consecutive system dialogs / Settings redirects before tracking starts.

### GW-0015 · P1 · [sim] · background
**Background location hard-gates core arming with no foreground fallback**
- kind: risk · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:ux-firsttime
- actual: Users who only grant 'While using the app' (the common default) cannot arm at all, and get no explanation — the core wake feature is effectively unavailable to them.
- expected: Background is genuinely needed for screen-off reliability, but the app should degrade (arm foreground-only with a clear 'keep the app open' warning) rather than fully refuse the core function, which Android intentionally makes hard to grant.
- evidence: sim/code-read (discovery ux-firsttime): permission_service.dart:96-98 comment 'immediately ask for background location which is essential' and line 97 returns its result as the location gate; a refusal blocks requestEssentialPermissions entirely.  [REFUTE-VERIFIED CONF: Independently reproduced from source. permission_service.dart:97 returns _requestBackgroundLocation() as the location gate when foreground is granted (comment line 96 calls background 'essential'). _requestBackgroundLocation (lines 112, 115) returns false on rationale decline or OS refusal. requestEssentialPermissions:18-19 ('i
- repro: 1. Grant only 'While using the app'. 2. Try to arm. 3. Arm is blocked with no usable path.

### GW-0028 · P1 · [sim] · ux
**Add a confirmation before END TRACKING disarms the wake alarm mid-ride**
- kind: risk · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:ux-power-critic
- actual: A single accidental tap on the prominent red button silently kills tracking and the wake alarm with no guard.
- expected: Disarming the safety alarm mid-journey (the app's ONE promise) should require a confirm ('Stop tracking? You won't be woken at your stop.') or at least be undoable, since an accidental tap makes the rider sleep past their stop.
- evidence: sim/code-read (discovery ux-power-critic): lib/screens/maptracking.dart:1452-1472 — the mid-ride 'END TRACKING' ElevatedButton (red errorContainer, full-width) calls AlarmPlayer.stop() + TrackingService().completeEndTracking() immediately with NO confirmation dialog (the only AlertDialogs in the file are the args-missing error at :259). Contrast: the value/paywall flows do confirm.  [REFUTE-VERIFIED CONF: Independently reproduced from source. At lib/screens/maptracking.dart the layout branches on `if (_finalAlarmActive)` (:1272). In the else branch — normal mid-ride tracking, alarm NOT firing 
- repro: 1. Arm a trip and enter live tracking. 2. Fumble/accidentally tap the red END TRACKING button (thumb-sized, docked bottom). 3. Tracking ends instantly, snapshot cleared, service stopped — the never-late alarm is fully disarmed with no undo.

### GW-0048 · P1 · [sim] · a11y
**Label the ringtone play/pause preview button (icon-only, no tooltip) (refines GW-0009)**
- kind: missing · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:a11y-audit
- actual: Announced as a bare unnamed 'button'; the user cannot tell what it does or its play/pause state.
- expected: tooltip/semanticLabel like 'Preview {ringtone name}' / 'Stop preview', reflecting play vs pause state, so a blind user can audition the alarm sound they're about to rely on.
- evidence: sim/code-read (discovery a11y-audit): ringtones_screen.dart:251-258 `trailing: IconButton(icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill), iconSize:30, onPressed: _togglePreview)` — no tooltip, no semanticLabel (it is the only IconButton in the file with no tooltip).  [REFUTE-VERIFIED CONF: Independently reproduced from source. At lib/screens/ringtones_screen.dart:251-258 the trailing IconButton has icon/color/iconSize/onPressed only — no tooltip, no Semantics/semanticLabel. Icon toggles pause_circle_filled/play_circle_fill visually only, so a Flutter IconButton with
- repro: 1. TalkBack on. 2. Open Settings > alarm ringtone list. 3. Swipe to the trailing preview button on any ringtone row. 4. TalkBack announces only 'button' with no name or state.

### GW-0049 · P1 · [sim] · a11y
**Label + enlarge the low-battery alert button (icon-only InkWell, 40dp, no-op, unlabeled) (refines GW-0009)**
- kind: missing · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:a11y-audit
- actual: Unlabeled, 40dp, and inert — a blind user can neither perceive nor act on the battery-kill warning that threatens the never-late promise.
- expected: This warns the rider their battery may kill the wake (GW-0008 class). It needs a semanticLabel ('Low battery — tap for battery settings'), a real action, and a >=48dp touch target.
- evidence: sim/code-read (discovery a11y-audit): homescreen.dart:1793 `_buildAlertButton` = InkWell over a 40x40 Container with only Icon(Icons.battery_alert); called at :1702 with `onPressed: () {}` (empty). No Semantics/tooltip. 40x40 < 48dp min target.  [REFUTE-VERIFIED CONF: Every cited claim reproduces from source at /home/raed/Projects/WakePoint/lib/screens/homescreen.dart. Line 1793 `_buildAlertButton` builds an InkWell (line 1800) over a Container(width:40, height:40) (lines 1803-1805) whose sole child is Icon(icon, ...) with no semanticLabel (line 1807) — below the 48dp minimum target and invisi
- repro: 1. TalkBack on, low-battery condition (_lowBattery true). 2. Swipe to the red battery icon top-right. 3. TalkBack announces unnamed 'button'; double-tap does nothing (empty callback).

### GW-0050 · P1 · [sim] · a11y
**No Semantics/semanticLabel anywhere — quantified confirmation of GW-0009 (refines GW-0009)**
- kind: missing · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:a11y-audit
- actual: Ironically the developer debug panels are the best-labeled surface (tooltips), while production wake/alarm/home screens rely on incidental text; 4 of ~8 production icon-only controls are fully unlabeled.
- expected: Production screens should carry explicit Semantics for every non-text control; a11y coverage should not be lower than the debug panels'.
- evidence: sim/code-read (discovery a11y-audit): Whole-repo counts: `semanticLabel` = 0, `Semantics(` = 0, `ExcludeSemantics/MergeSemantics/liveRegion` = 0 across 171 dart files. Icon-bearing interactive controls: IconButton x10, GestureDetector x3, InkWell x2, FAB.extended x2. Only labeling mechanism present is `tooltip:` (11 uses), and 8 of those 11 are on debug/dashboard panels (constraint_drawer, deviation_dashboard, ekf_test_panel).  [REFUTE-VERIFIED CONF: Independently reproduced the census: grep across the Dart source returns 0 hits for `semanticLabel`, 0 for `Semantics(`, and 0 for `ExcludeSemant
- repro: n/a (static census).

### GW-0051 · P1 · [sim] · a11y
**Announce alarm arrival to the accessibility tree (zero live regions in entire app) (refines GW-0009)**
- kind: missing · verified: refute-verified PARTIAL (rescoped) · status: confirmed · found: discovery:a11y-audit
- actual: The arrival state is silent to the a11y tree. For a screen-reader user the ONE promise (be woken at the stop) depends entirely on the audio ringtone (which GW-0001 says isn't even on STREAM_ALARM) and an unannounced visual banner.
- expected: The single most important state change (alarm fired / 'time to get off') should fire SemanticsService.announce() or be wrapped in Semantics(liveRegion:true) so TalkBack speaks it the instant it appears, independent of visual focus.
- evidence: sim/code-read (discovery a11y-audit): Verified: `grep -rn "liveRegion|SemanticsService" lib/` returns nothing (0 matches). lib/screens/maptracking.dart:1289-1296 renders the arrival Text("You've reached ...") as a plain styled Text inside a Flexible/Row; :1301-1304 renders const Text('Time to get off.') — neither is wrapped in Semantics(liveRegion:true) nor preceded by SemanticsService.announce(). Note the cited line :1292 points at the TextStyle; the visible string is on :1290. The STOP ALARM/SNOOZE controls begin at :1306. Audible alarm (separate channel) remains the actual wake mechanism, s
- repro: 1. Enable TalkBack. 2. Start tracking a route. 3. Arrive at destination while the phone is in a pocket / screen not focused. 4. The visual banner + STOP ALARM/SNOOZE row appears but TalkBack makes NO programmatic announcement of the state change; a blind rider gets no spoken 'you've reached' event.

### GW-0063 · P1 · [sim] · background
**Make the last-resort backstop notification loop/insist — it currently sounds the alarm tone exactly once**
- kind: subpar · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:bg-reliability
- actual: The backstop is strictly weaker than the primary alarm: one alarm-tone ping, no loop, no insistent flag.
- expected: The path that exists specifically for total process death should be the LOUDEST/most persistent wake — insistent looping tone until dismissed.
- evidence: sim/code-read (discovery bg-reliability): lib/services/notification_service.dart:907-932 scheduleEtaBackstop builds AndroidNotificationDetails with playSound:true but NO additionalFlags (no FLAG_INSISTENT=4) and no ongoing/insistent behaviour; the channel sound (RingtoneManager alarm, MainActivity.kt:237) plays once on post. Contrast the primary alarm at :787 `additionalFlags: Int32List.fromList([4, 32])` (INSISTENT + NO_CLEAR) which loops until dismissed.  [REFUTE-VERIFIED CONF: Independently reproduced from source. scheduleEtaBackstop (notification_service.dart:907-920) constructs the backst
- repro: 1. Trigger the OS ETA backstop with the app process dead. 2. Observe the notification posts and the default alarm tone plays a single time then stops; a sleeping rider gets one ping, not a persistent alarm.

### GW-0064 · P1 · [sim] · background
**Post-reboot re-arm restarts a location-typed FGS from BOOT_COMPLETED, which Android 12+ restricts (refines GW-0003)**
- kind: risk · verified: refute-verified PARTIAL (rescoped) · status: confirmed · found: discovery:bg-reliability
- actual: Live tracking re-arm after reboot can fail silently due to FGS-while-in-use restrictions, leaving only the weak single-ping ETA backstop. (Materially beyond GW-0003 direct-boot: this is the normal-boot location-FGS restriction.)
- expected: Reboot re-arm should either use a permitted FGS-start path or fully rely on a robust OS backstop; live re-arm should not silently no-op.
- evidence: sim/code-read (discovery bg-reliability): AndroidManifest.xml:93 `foregroundServiceType="location|mediaPlayback"`; trackingservice.dart:213-226 configures AndroidConfiguration WITHOUT foregroundServiceTypes, with autoStartOnBoot:true (line 220); flutter_background_service_android-6.3.1 BootReceiver.java:24 startForegroundService from BOOT_COMPLETED; ForegroundTypeMapper.java:29 falls back to FOREGROUND_SERVICE_TYPE_MANIFEST (=location|mediaPlayback); BackgroundService.java:173-175 startForeground catches only SecurityException, not ForegroundServiceStartNotAllowedException. On targetSdk=35 (bu
- repro: 1. Arm a trip, reboot the phone mid-journey. 2. autoStartOnBoot tries to bring up the location FGS from the boot broadcast; on Android 12+/14 the location foreground-service start (or its location access) is blocked. 3. Live tracking/EKF never resumes; only the single stale ETA-backstop notification

### GW-0081 · P1 · [sim] · background
**Overbound the anchor by along-route projection/snap uncertainty, not only horizontal GPS accuracy**
- kind: risk · verified: refute-verified PARTIAL (rescoped) · status: confirmed · found: discovery:bg-neverlate
- actual: sHi adds only horizontal accuracyMeters. A real fix that projects onto the wrong (earlier) limb of a self-approaching route yields sMeters too low with a small acc, so sHi under-bounds true arc-progress → the free-run cone starts behind the train and can fire late. Precondition (i) 'real anchor' is asserted but the snap longitudinal error is not accounted for.
- expected: The forward overbound s0_hi must cover the worst-case along-route error of the anchor, which on a route that doubles back can be hundreds of meters even for a 10 m horizontal fix.
- evidence: sim/code-read (discovery bg-neverlate): reachability.dart:165-166 sHi overbounds by horizontal accuracyMeters only, adding zero longitudinal margin for snap/projection error; never-late precondition reachability.dart:468 depends on snap correctness. Real residual is on the DEFENSE-FREE snap paths, not general self-approaching routes: snap_to_route.dart:158/:171 gate connectivity+backward(+100) penalties behind previousResult!=null (cold fix has none), and :91 full-search fallback forces previousResult:null; :178 heading penalty applies only with valid heading (often absent underground). On tho
- repro: 1. Route where outbound and return limbs pass within 30 m. 2. Real fix (acc 12 m) projects to the outbound limb while the train is on the return limb, giving sMeters 800 m too low. 3. sHi = sMeters+12. 4. Bound trails true progress by ~788 m for the rest of the blackout.

### GW-0087 · P1 · [sim] · security
**Bind share write endpoints to the share owner — a recipient can spoof location, fake arrival, or revoke**
- kind: risk · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:sec-static
- actual: Any party with the app's bearer token (extractable from the APK) plus a share id (handed to every recipient) can POST /v1/share/{id}/ping with attacker-chosen lat/lng (the /j page then displays the fake location), POST /arrived to falsely fire a guardian 'arrived safely', or DELETE the share to kill a live journey — pure cross-user integrity/DoS.
- expected: A write to a share (ping coords, mark arrived, revoke) must require a capability the SHARE OWNER holds and a recipient does not (e.g. a per-share write secret the device keeps), so a link recipient cannot mutate the sender's journey.
- evidence: sim/code-read (discovery sec-static): backend/share/server.js authOk() gates /v1 only on the single shared founder bearer token; the ping/arrived/DELETE handlers ('if (action === "ping")', '/arrived', DELETE branch) do NO per-share ownership check. Combined with GW-0010 (token is baked into every APK) and the fact that every recipient legitimately holds the /j/{id} share id from the link.  [REFUTE-VERIFIED CONF: Independently reproduced from backend/share/server.js. authOk() (createServer, ~L468-474) gates /v1 solely on constantTimeEquals against the single cfg.authToken bearer; the ping ('if 
- repro: 1. Extract SHARE_AUTH_TOKEN from an APK (GW-0010). 2. Receive any /j/{id} link. 3. curl -X POST $BASE/v1/share/{id}/ping -H 'authorization: Bearer <token>' -H 'content-type: application/json' -d '{"lat":0,"lng":0}' → 204; reload /j/{id} and see the spoofed point. 4. curl -X DELETE $BASE/v1/share/{id

### GW-0088 · P1 · [sim] · security
**Take the trusted client IP from the proxy, not XFF[0] — rate limit is trivially bypassed**
- kind: risk · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:sec-static
- actual: An attacker sets 'X-Forwarded-For: <random>' on each request and lands in a fresh rate-limit bucket every time, defeating RateLimiter entirely — enabling share-id enumeration / brute force / write flooding against the endpoints above.
- expected: Behind a known proxy, derive the client IP from a trusted position (e.g. the right-most XFF hop the proxy set, or a proxy-provided header), so an attacker cannot forge their rate-limit identity.
- evidence: sim/code-read (discovery sec-static): backend/share/server.js clientIp(): 'const xff = req.headers["x-forwarded-for"]; if (...) return xff.split(",")[0].trim();' returns the FIRST, fully client-controlled XFF entry. Behind Railway's proxy the real client IP is appended, so the first element is whatever the attacker sends.  [REFUTE-VERIFIED CONF: Independently reproduced from source. backend/share/server.js:229-231 clientIp() returns xff.split(',')[0].trim() — the LEFTMOST X-Forwarded-For entry, which is fully client-controlled. Behind Railway's proxy the real client IP is APPENDED (rightmost i
- repro: 1. for i in $(seq 1 100000); do curl $BASE/ -H "X-Forwarded-For: 10.0.0.$((RANDOM))"; done. 2. Observe no 429 despite RATE_LIMIT_PER_MIN=120.

### GW-0089 · P1 · [sim] · background
**Reconcile the server HMAC secret with the client's per-device secret — setting HMAC_SECRET 403s every real link**
- kind: bug · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:sec-static
- actual: If the server is deployed with the .env.local HMAC_SECRET, every shared /j/{id}?t=... link fails verifyToken and returns 403 — the recipient page is dead for all users, even though the code path 'looks' more secure.
- expected: Either leave HMAC_SECRET empty (documented client-first default) OR have the client mint with the SAME server secret; the two token systems must agree.
- evidence: sim/code-read (discovery sec-static): backend/share/.env.local sets HMAC_SECRET=1dbe99...; server.js /j/ handler: 'if (t) { if (!verifyToken(id, t, cfg.hmacSecret)) return sendStatus(res,403) }'. But the client mints ?t= with a RANDOM per-install secret: journey_share_service.dart _randomSecret()/_secret() stored under 'gw_share_secret', and startBasicShare always appends token via ShareLinkBuilder.mintToken(id, secret). The server never knows that per-device secret.  [REFUTE-VERIFIED CONF: Every cited fact reproduces from source. server.js:41 reads hmacSecret from env.HMAC_SECRET; server.js:5
- repro: 1. Deploy server with HMAC_SECRET set. 2. Share a journey from the app (link carries ?t=<per-device token>). 3. Open the link → 403.

### GW-0102 · P1 · [sim] · security
**Stop free basic-link shares from silently streaming live position — the default backend is live and ingestLocation ignores ShareMode**
- kind: bug · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:sec-privacy
- actual: Because baseUrl is hardcoded to a live default, HttpShareBackend is the shipped default. Starting ANY share (including the free one-tap 'Track my journey' basic link, which carries no entitlement check) causes the moving device position to be POSTed to Railway every 15 s via /v1/share/{id}/ping, refuting the 'today nothing leaves' guardrail.
- expected: A ShareMode.basicLink share sends only a static link; live location pings require an explicit live/guardian session. With no backend token/endpoint provisioned the app stays on NoopShareBackend as the docs claim.
- evidence: sim/code-read (discovery sec-privacy): share_backend_config.dart:29-32 baseUrl defaults to non-empty 'https://geowake-share-production.up.railway.app'; :50 isLiveConfigured returns true; :53-59 buildBackend() therefore returns HttpShareBackend (supportsLive==true), NOT Noop. main.dart:124-132 calls ShareBackendConfig.configure() then bindTracking<Position>(TrackingService().locationStream,...) wiring the LIVE GPS stream into JourneyShareService. journey_share_service.dart:213-230 ingestLocation pushes ShareSnapshot(lat,lng) to backend.pushLocation for EVERY active session with NO check of s.mo
- repro: 1. Build with defaults (no --dart-define). 2. Confirm ShareBackendConfig.isLiveConfigured==true and JourneyShareService.instance.backend is HttpShareBackend. 3. Start a basic-link share via startBasicShare(mode: basicLink). 4. Feed positions through TrackingService locationStream. 5. Observe backend

### GW-0103 · P1 · [sim] · security
**Acknowledge that exact device coordinates DO leave the device on every route computation via the Maps proxy — the 'nothing leaves' guardrail is false**
- kind: risk · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:sec-privacy
- actual: Exact origin+destination (and periodic in-trip position as the origin updates) are sent to the first-party server, which proxies to Google. This is an unconsented, near-continuous coarse trajectory egress. It refutes the blanket 'today nothing leaves' claim (the k-anon/DP aggregate path is genuinely off, but the Maps proxy and share paths are not).
- expected: If 'raw individual location must NEVER leave the device' is a hard guardrail, exact O/D and in-trip origin samples should be gated behind explicit consent, or truncated/relayed in a privacy-preserving way.
- evidence: sim/code-read (discovery sec-privacy): direction_service.dart:199-204 getDirections sends origin: '$startLat,$startLng' (the device's exact current fix) and destination as exact lat/lng; api_client.dart:341-371 POSTs this to /maps/directions on the first-party Railway backend. direction_service.dart:23-25 farInterval/midInterval/nearInterval (15/7/3 min) re-fetch during tracking, so the moving origin is re-transmitted throughout the trip. No consent/notice gates this.  [REFUTE-VERIFIED CONF: All cited evidence reproduces exactly from source. direction_service.dart:200-201 sends the exact live 
- repro: 1. Enter a destination and arm a trip. 2. Watch ApiClient._makeRequest POST /maps/directions bodies (ApiClient.directionsBodiesHistory in testMode) — origin equals the live device fix. 3. Let tracking run and observe re-fetch at the tiered interval carrying the updated origin.

### GW-0115 · P1 · [sim] · background
**Wire the adaptive GPS power policy into LocationManager — battery-saving tiers are dead code**
- kind: subpar · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:perf-profiler
- actual: The FGS always samples full high-accuracy GPS with distanceFilter:0 (every fix, ~1Hz) regardless of battery level. The 'medium'/'low' battery tiers never take effect, so a long metro ride burns maximum GPS power — the exact drain that makes users add the app to OEM battery-kill lists (GW-0008), which then defeats the never-late promise.
- expected: On a low battery the FGS should drop to LocationAccuracy.low + distanceFilter 50m as the policy intends, cutting GPS radio duty cycle dramatically on the always-on transit journey.
- evidence: sim/code-read (discovery perf-profiler): lib/config/power_policy.dart:31-56 defines per-battery-tier accuracy (high/medium/low) and distanceFilterMeters (5/15/50), but lib/services/location_manager.dart:62-65 hardcodes `const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0)` and LocationManager.start() (called at location_stream_handler.dart:218) takes no policy. Only notificationTick/gpsDropoutBuffer from the policy are consumed (location_stream_handler.dart:210,443).  [REFUTE-VERIFIED CONF: Independently reproduced from source. power_policy.dart:31-56 defines per-battery-
- repro: 1. Read power_policy.dart and location_manager.dart. 2. Grep for any call passing a PowerPolicy's accuracy/distanceFilter into LocationSettings — none exists. 3. Runtime: run a journey at <20% battery and observe GPS still sampled at high accuracy / every fix.

### GW-0116 · P1 · [sim] · background
**Stop hammering disk every second in the always-on tick (3x consume + prefs.reload per second)**
- kind: subpar · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:perf-profiler
- actual: For the entire journey the FGS performs ~3 file existence checks + 3 SharedPreferences.reload() disk re-reads every single second, plus repeated notification platform calls — continuous disk I/O and CPU wakeups that drain battery on the very surface that must survive for hours.
- expected: Cross-isolate action flags should be delivered by an event/port push, or polled at a low cadence; prefs.reload() (a full native re-read of the prefs XML) should not run on a 1s loop for the whole journey.
- evidence: sim/code-read (discovery perf-profiler): location_stream_handler.dart:445 runs _handleGpsCheckTick every `policy.notificationTick` = 1s (power_policy.dart:35). Each tick calls _processNotificationActions (location_stream_handler.dart:486,497,506) → NotificationService.consumeStopAlarmRequest/consumeMuteJourneyRequest/consumeEndTrackingRequest, and each of those does a file read plus `SharedPreferences.getInstance(); await prefs.reload();` (notification_service.dart:130-135,148-153,166-171). _ensureCriticalNotificationsVisible also re-issues notification platform calls each tick (location_strea
- repro: 1. Trace _handleGpsCheckTick → _processNotificationActions → consume* → prefs.reload(). 2. Runtime: attach a file/IO tracer during a tracking session and count prefs reads per second.

### GW-0117 · P1 · [sim] · perf
**Kill the map screen's second GPS stream — it double-samples GPS on top of the FGS**
- kind: bug · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:perf-profiler
- actual: Whenever the tracking map is open, two concurrent high-accuracy GPS consumers run (FGS distanceFilter:0 + screen distanceFilter:5), and every fix triggers a full snap + marker rebuild + polyline rebuild twice — roughly double GPS radio use and double UI work exactly when the user is watching the screen.
- expected: The map should render from the single already-running FGS location feed; it should not open a second high-accuracy GPS sensor stream.
- evidence: sim/code-read (discovery perf-profiler): maptracking.dart:486-491 subscribes to TrackingService().locationStream (fed by the FGS via foreground_bridge, trackingservice.dart:182,207) and drives _handlePositionUpdate; separately maptracking.dart:752-767 opens its OWN `Geolocator.getPositionStream(accuracy: high, distanceFilter: 5)` which ALSO calls _handlePositionUpdate. Both run while the map is visible.  [REFUTE-VERIFIED CONF: All cited lines say exactly what the finding claims, and the redundancy is real. maptracking.dart:486-491 subscribes to TrackingService().locationStream and calls _handl
- repro: 1. Confirm both subscriptions call _handlePositionUpdate. 2. Runtime: open MapTracking and observe two active position streams (Geolocator + locationStream) and duplicate _handlePositionUpdate log lines per fix.

### GW-0140 · P1 · [sim] · background
**Fix the persisted-telemetry doc-lie: the north-star funnel evaporates in the background isolate**
- kind: risk · verified: oracle-adjacent refute-verified (≥2 agents) · status: confirmed · found: discovery:docs-vs-code
- actual: Those events are emitted in the background isolate, which never registers a FileTelemetrySink, so they land in a per-isolate 2000-cap RAM buffer and are lost on the exact process death the funnel exists to measure. The funnel denominator (alarmArmed, emitted UI-side in startTracking) may persist while the numerator never does — the funnel is structurally broken in production. test/telemetry/emit_sites_test.dart passes only because test mode runs _onStart in-process (trackingservice.dart:286) sha
- expected: alarmOutcome (the north-star numerator) and gpsLost/gpsReacquired (the never-late GPS-health funnel) are written to durable JSONL on disk in production, as the docs claim ('persisted', 'proven').
- evidence: sim/code-read (discovery docs-vs-code): VALIDATION_REPORT.md:66-67 claims FileTelemetrySink 'appends PII-free JSONL to disk' and that alarmOutcome/gpsLost/gpsReacquired emit sites are 'now wired and proven', with §6:152 asserting the app 'has a persisted place to measure itself'. But configureDefaultSinks() is called ONLY in the UI isolate: lib/main.dart:88 (inside main()). The emit sites that matter run in the flutter_background_service FGS isolate whose entrypoint is _onStart (lib/services/trackingservice.dart:1900, @pragma vm:entry-point): alarmOutcome at lib/services/tracking/alarm_control
- repro: 1. grep -n configureDefaultSinks lib/main.dart lib/services/trackingservice.dart → present only in main.dart. 2. Confirm alarmOutcome/gpsLost callers (alarm_controller:468, location_stream_handler:560) are driven by _onStart's loop (bg isolate). 3. On device: arm a ride, complete it, kill+relaunch, 

### GW-0005 · P1-too-early · [sim] · background
**Too-early fires on long GPS-blackout rides (up to +10 stops / 859s early at 395-scale)**
- kind: too-early · verified: oracle (deterministic 395-ride sim gate) · status: confirmed · found: two-sided-scale-gate
- actual: Firing up to 10 stops / ~14 min too early on sustained-blackout routes — a deal-breaker per prime-directive #1.
- expected: On a long blackout the physics free-run bound over-fires; the built fastest-feasible tightening (dwell cap + terminal-braking + curve ceiling) should collapse the tail WITHOUT ever risking a late fire.
- evidence: sim/oracle 2026-07-20 REPRODUCED at full scale: GEOWAKE_SCALE_DIR=/home/raed/geowake_imu_analysis/scale/rides flutter test test/scale/reachability_scale_test.dart -> ran=395 fired=395 never-fired=0 LATE=0; earliness stops median=1.0 p95=3.0 MAX=10.0 (seconds median=1 p95=312 MAX=859); egregious(>=3) 22/395 (5.6%) ALL long_blind/express_skip_long_blind (chennai__green__long_blind +7, ahmedabad__blue__long_blind +7, ahmedabad__red__long_blind +6). Root cause: production runs the PURE FREE-RUN bound sHi+V_LINE*dt with ALL tightening dormant (see GW-0011).
- repro: GEOWAKE_SCALE_DIR=/home/raed/geowake_imu_analysis/scale/rides flutter test test/scale/reachability_scale_test.dart (in-repo 15-ride subset without the env var: max=7, egregious 2/15).

---

## P2 / P3 / complaints (compact — full detail in ISSUES.jsonl)

| id | sev | front | title |
|---|---|---|---|
| GW-0009 | P2-subpar | a11y | No Semantics/semanticLabels — TalkBack a11y gap + black-box testability blocker |
| GW-0016 | P2-subpar | ux | Add a first-run onboarding / value + permission preamble |
| GW-0017 | P2-subpar | ux | Requesting notification permission cold at launch with no rationale (and duplicated) |
| GW-0019 | P2-subpar | ux | Time/Distance/Stops mode toggle has no clear active-state labeling |
| GW-0020 | P2-subpar | ux | Default alarm thresholds (5 km / 15 min) lean too-early for 'just before the stop' |
| GW-0029 | P2-subpar | ux | Low-battery indicator is a dead red button that does nothing |
| GW-0030 | P2-subpar | ux | Route legend is hardcoded — shows 'Metro Line A/B' on every route including plain driving  |
| GW-0031 | P2-subpar | ux | Route-switch snackbar leaks internal route keys to the user |
| GW-0032 | P2-subpar | ux | 'You'll have to switch routes in X' copy is ambiguous and can mislead the rider to act |
| GW-0033 | P2-subpar | ux | Back button on the tracking screen is swallowed with zero feedback |
| GW-0034 | P2-subpar | ux | Out-of-range alarm values are silently clamped; non-numeric input silently dismissed |
| GW-0035 | P2-subpar | ux | Time/Distance/Stops mode picker is an ambiguous bare Switch coupled to a separate Metro to |
| GW-0036 | P2-subpar | ux | Dragging the destination pin keeps the old place name in the label and confirmation sheet |
| GW-0037 | P2-subpar | ux | WidgetSettingsTile is dead code — the home-widget Pro toggle has no entry point in the app |
| GW-0038 | P2-subpar | ux | 'Buy me a coffee' ships with a placeholder handle and shows internal dev copy |
| GW-0039 | P2-subpar | security | Escalating alarm volume is Pro-gated while its own copy frames it as what stops you oversl |
| GW-0052 | P2-subpar | a11y | Label the wake-threshold value editor (core control is an unlabeled GestureDetector) (refi |
| GW-0053 | P2-subpar | a11y | Label + enlarge the remove-recent-location chip (24dp unlabeled GestureDetector) (refines  |
| GW-0054 | P2-subpar | a11y | Give the Time/Distance and Metro-Mode switches accessible labels |
| GW-0055 | P2-subpar | a11y | Elevate the 'Time to get off' arrival instruction (smallest text on the most important scr |
| GW-0060 | P2-subpar | a11y | TalkBack traversal order is unmanaged (no ordering/focus semantics) (refines GW-0009) |
| GW-0061 | P2-subpar | a11y | Tracking/GPS-degraded status changes are never announced to screen readers |
| GW-0065 | P2-subpar | background | Create the backstop notification channel in the background isolate too, not only in MainAc |
| GW-0066 | P2-subpar | background | Journey/FGS notification id collision makes the 'Ignore' mute fight the foreground-service |
| GW-0068 | P2-subpar | ux | Termination fires a full wake alarm then immediately silences it |
| GW-0069 | P2-subpar | background | RULE 3 'moving away' termination can end tracking on legitimate loop/branch transit or GPS |
| GW-0070 | P2-subpar | background | Unknown alarm-mode string falls back to a 60s backstop lead — a late-fire trap |
| GW-0071 | P2-subpar | ux | Non-critical wrong-direction nudge is posted on the DND-bypassing alarm channel |
| GW-0080 | P2-subpar | background | Fold out-of-order real fixes into a non-decreasing forward bound instead of dropping them  |
| GW-0082 | P2-subpar | background | Align the cold-start stops fire target with the evaluator's intermediate-only stop semanti |
| GW-0083 | P2-subpar | perf | Remove the legacy raw-accelerometer dead-reckoning that integrates device-frame accel as w |
| GW-0086 | P2-subpar | background | Snap-to-route permits backward jumps into wrong parallel/loop segments that directly move  |
| GW-0090 | P2-subpar | background | Fix the Android package identity so App Links can auto-verify — https share links currentl |
| GW-0091 | P2-subpar | security | Drop or verify the geowake:// custom scheme — any app can register it and hijack followed  |
| GW-0092 | P2-subpar | security | Do not require the shared bearer token to READ status — it is not the follower's; but also |
| GW-0093 | P2-subpar | security | Stop shipping 5-dp 'coarse' points — 1.1 m precision is effectively raw individual locatio |
| GW-0094 | P2-subpar | security | Default-empty SHARE_AUTH_TOKEN leaves /v1 write API fully open on a missed deploy step |
| GW-0095 | P2-subpar | security | Do not use the public bundleId as the sole auth credential for the maps proxy |
| GW-0096 | P2-subpar | security | Set android:allowBackup=false / dataExtractionRules — the API token and share secret are b |
| GW-0097 | P2-subpar | background | Persist live shares (or warn) — Railway sleepApplication + in-memory Store drops journeys  |
| GW-0104 | P2-subpar | security | Stop calling 5-decimal-place coordinates 'coarse, non-identifying' — 5 dp is ~1.1 m, i.e.  |
| GW-0105 | P2-subpar | security | Require auth on the live-share write/read endpoints — the ping/status paths are unauthenti |
| GW-0106 | P2-subpar | security | Gate reverse-geocode / nearby-search / autocomplete-bias, which transmit the raw device la |
| GW-0107 | P2-subpar | background | Cap or disable RouteLogger — it persists complete raw Directions responses (full polyline  |
| GW-0109 | P2-subpar | security | Store the API auth token and share HMAC secret in encrypted storage, not plaintext SharedP |
| GW-0110 | P2-subpar | ux | Add a privacy disclosure to the share flow — nothing tells the user that sharing transmits |
| GW-0118 | P2-subpar | perf | Remove the duplicate ingestPosition call per GPS fix in the background isolate |
| GW-0119 | P2-subpar | background | Bundle the Pacifico font — it is fetched over the network at first launch |
| GW-0120 | P2-subpar | perf | Drop the 20MB dev-only OSM graph (and ekf_test_routes) from the production bundle |
| GW-0121 | P2-subpar | perf | Remove unconditional print() from the map position/route hot path |
| GW-0122 | P2-subpar | ux | Drop the artificial 3-second splash delay once services are ready |
| GW-0130 | P2-subpar | background | Stop rendering an ad banner on the active tracking surface |
| GW-0131 | P2-subpar | ux | Recompute entitlement tier when the rewarded day-pass expires |
| GW-0132 | P2-subpar | ux | Stop marketing the free ramping-volume safety behavior as a Pro benefit |
| GW-0018 | P3-nit | ux | Battery-alert button is a dead control (empty onPressed) |
| GW-0021 | P3-nit | ux | 'Loading route...' spinner mislabels the permission-gathering phase |
| GW-0022 | P3-nit | ux | Activity-recognition permission requested cold mid-arm with no rationale |
| GW-0023 | P3-nit | perf | Fixed 3-second splash delay on every cold start |
| GW-0024 | P3-nit | ux | Disabled Wake Me button gives no reason why it's disabled |
| GW-0025 | P3-nit | ux | Map defaults to Bengaluru when current location isn't available |
| GW-0026 | P3-nit | perf | Same-state validation fires two geocode API calls per arm despite being only advisory now |
| GW-0027 | P3-nit | ux | Background-location rationale doesn't warn the user they'll be sent to Settings |
| GW-0040 | P3-nit | ux | Shared ride status never includes ETA because etaProvider is not wired at the call site |
| GW-0041 | P3-nit | ux | Share-status preview uses raw 24h, unpadded, non-localized time |
| GW-0042 | P3-nit | ux | Followed ride that has ended shows no 'arrived/ended' state — just a nameless stale row |
| GW-0043 | P3-nit | ux | A disabled STOP ALARM button occupies the control bar for the entire ride |
| GW-0044 | P3-nit | ux | Dark/Light-mode tile label is ambiguous about current vs target state |
| GW-0045 | P3-nit | ux | Inconsistent iconography for Guardian/sharing across surfaces |
| GW-0046 | P3-nit | ux | Recents only capture autocomplete picks — dropped pins and dragged targets are never remem |
| GW-0047 | P3-nit | ux | Single map tap has a ~280ms delay before the pin drops |
| GW-0056 | P3-nit | a11y | Mark decorative arrival/status icons as excluded from semantics (refines GW-0009) |
| GW-0057 | P3-nit | a11y | Light-mode input hint/prefix contrast fails WCAG AA (black54 on grey200 ≈ 4.4:1) |
| GW-0058 | P3-nit | a11y | No text-scaling guard or verification on fixed-fontSize alarm buttons |
| GW-0067 | P3-nit | background | Alarm channel ships at IMPORTANCE_HIGH, not the MAX the Dart code intends |
| GW-0072 | P3-nit | background | Wrong-direction throttle timestamp is static and never reset across trips |
| GW-0073 | P3-nit | perf | Re-arming setAlarmClock at ~1 Hz for the whole trip is excessive AlarmManager churn |
| GW-0074 | P3-nit | perf | Debug print() in the GPS/alarm hot path ships in production |
| GW-0075 | P3-nit | background | Duplicated _startForegroundHeartbeat() call on app resume |
| GW-0084 | P3-nit | perf | Strip per-tick print() debug spam from the alarm evaluation hot path |
| GW-0085 | P3-nit | background | GPS health silence detection uses wall-clock DateTime.now(), vulnerable to device clock ju |
| GW-0098 | P3-nit | security | Harden the exported home_widget background receiver/service against external triggers |
| GW-0099 | P3-nit | security | MainActivity is exported with showWhenLocked+turnScreenOn — any app can wake the screen an |
| GW-0100 | P3-nit | security | Stop returning active share count on the public health endpoint |
| GW-0101 | P3-nit | security | Replace the committed real-looking secrets in .env.local |
| GW-0108 | P3-nit | security | Rotate the leaked Maps key and remove its fragment from source — the build.gradle comment  |
| GW-0111 | P3-nit | security | Reduce coordinate logging in non-release builds — request URIs, response previews, and coo |
| GW-0112 | P3-nit | background | Telemetry alarmArmed carries city + line identifiers that would become re-identifying if t |
| GW-0113 | P3-nit | security | Note that the share `?t=` HMAC token cannot be verified by the backend, so it provides no  |
| GW-0114 | P3-nit | security | Positive: the k-anon + DP aggregate egress path is genuinely inert (triple-locked) — verif |
| GW-0123 | P3-nit | perf | Silence per-fix dev.log in the background location isolate |
| GW-0124 | P3-nit | perf | Lazily build/index allIndiaStops instead of a 13k-line eager Map list |
| GW-0125 | P3-nit | perf | Coalesce the two setState calls per position update on the map |
| GW-0126 | P3-nit | perf | Drive PulsingDots from an AnimationController, not a setState timer |
| GW-0127 | P3-nit | perf | Reduce the 1Hz foreground↔background heartbeat with a platform isRunning() call each tick |
| GW-0128 | P3-nit | perf | Downsize the 528KB splash/app-icon PNG |
| GW-0133 | P3-nit | security | Do not trust a purely client-side entitlement flag as proof of purchase |
| GW-0134 | P3-nit | background | Wire or delete the unused interstitial ad path |
| GW-0135 | P3-nit | background | Stop double-counting a ride against the ad frequency cap |
| GW-0136 | P3-nit | ux | Avoid showing a hardcoded price that can differ from the amount charged |
| GW-0137 | P3-nit | ux | Reconsider the persistent arming-screen banner during alarm configuration |
| GW-0138 | P3-nit | ux | GatedBannerAd gives up permanently after bounded retries and never re-evaluates entitlemen |
| GW-0139 | P3-nit | background | Reset the ad frequency-cap counter after the paywall's rewarded grant too |
| GW-0141 | P3-nit | background | Reconcile the #8 telemetry-emit contradiction between VALIDATION_REPORT and GAP_ANALYSIS |
| GW-0142 | P3-nit | background | Correct the stale '445 tests' count and Bengaluru-dashboard framing in README |
| GW-0143 | P3-nit | background | Fix VALIDATION.md's self-contradictory whole-suite test counts |
| GW-0144 | P3-nit | background | Purge the stale 'hardcoded live Maps key not addressed' claim now contradicted by build.gr |
| GW-0145 | P3-nit | background | Reconcile the exact-alarm probe comment claiming USE_EXACT_ALARM is declared against the r |
| GW-0059 | complaint | a11y | One-handed reach: primary destination confirm/CTA sits far from the thumb |
| GW-0129 | complaint | perf | Avoid re-parsing raw segment maps on every 5m of progress when trimming polylines |

---

## Never-late fix status (see NEVERLATE_FIX_DESIGNS.md)
- **P0-01 V_LINE collision** — APPLY: thread Directions `vehicle_type` onto the leg; `forLine` takes max(keyword, vehicle-class floor). Never-late proven (monotone raise). Adversarially verified; deterministic collision test specified.
- **P0-03 multi-leg piecewise V_LINE** — APPLIED by a concurrent session; strictly tightens too-early, 395-oracle byte-identical, never-late preserved.
- **P0-00 ETA backstop** — REWORK before applying: the physics fire time must be computed in WALL clock (monotonic freezes in Doze while the RTC alarm fires at wall time → LATE). All 3 refuters flagged this.
- **P0-02 8 s window** — HOLD: closes a narrow late window but risks healthy-GPS too-early on fast lines; needs rework.

## Outstanding (next)
1. Apply P0-01 + reworked P0-00 once single-writer (a concurrent session is editing the engine).
2. L1/L2 on the emulator: drive an armed trip + inject Doze/kill/reboot, read telemetry (needs a Gradle build).
3. Security Tier 1-2: install osv-scanner/mobsfscan; run semgrep; backend authz/IDOR/rate-limit matrix vs a non-prod instance.
4. **Real-hardware re-verification of every P0/P1 — the #1 outstanding objective. NEVER claim device proof from sim.**