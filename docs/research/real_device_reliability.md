# Real-Device Reliability — will the wake-alarm actually work? (verified July 2026)

> Deep research against **today's** Android 14/15/16, Google Play policy, and the major OEM skins, for the behaviors that **cannot be proven in the simulator** and must work on real hardware. The question was blunt: *does our approach work, and what can duck it up?*

## Bottom line
**The architecture is correct.** A `FOREGROUND_SERVICE_LOCATION` service has no runtime timeout and can run a whole ride, and — critically — **`AlarmManager.setAlarmClock()` is the right authoritative backstop**: it is exempt from Doze and App-Standby and fires even if the app process was killed. The live location service is the *nice path*; the exact alarm is the *guarantee*. (This settles the earlier "is the backstop redundant?" question: **no — under Doze/OEM-kill the live service dies and the exact alarm is the only thing that fires.**)

**But it is `at-risk` on five fronts**, and there are **concrete code gaps** that would let a real device miss the wake. Close them before claiming "never miss."

---

## Concrete code issues found (log these; fix before device-proofing)
1. **Alarm can be SILENT.** `lib/services/alarm_player.dart` ramps *player-relative* volume, not the OS `STREAM_ALARM`. If the user's alarm-stream volume is 0, the alarm makes no sound — only vibration. **Fix:** at ring time read/raise `AudioManager` `STREAM_ALARM` (native), or at minimum preflight-warn if alarm volume is 0. The app-level ramp cannot fix a muted stream.
2. **DND bypass is claimed but NOT wired.** There is no `setBypassDnd` call anywhere; `flutter_local_notifications`' channel doesn't expose it (upstream #1211), and the manifest's `ACCESS_NOTIFICATION_POLICY` is **declared but unused**. So "bypasses DND" is currently false. **Fix:** wire it via a native channel/AudioManager, or stop claiming it. Under DND "Total silence" or a disabled Alarms exception, today only vibration survives.
3. **Direct-Boot re-arm gap.** `ScheduledNotificationBootReceiver` is not `directBootAware`. On FBE devices (14/15/16), `BOOT_COMPLETED` is withheld until first unlock — so **reboot-then-sleep-locked = the backstop is never re-armed.** **Fix:** make the boot re-arm direct-boot-aware, or accept the window and document it.
4. **`ACCESS_BACKGROUND_LOCATION` is declared but likely unnecessary** — and it's a real Play-rejection path (prominent-disclosure review + core-function justification + often a demo video). A location FGS **started while the app is foregrounded** keeps while-in-use access after screen-off *without* ABL. **Fix:** if tracking is strictly user-initiated (app open at start), drop ABL and skip that review entirely. Only keep ABL if you truly need auto-arm-from-closed-app.
5. **Boot receiver should re-schedule the EXACT ALARM, not restart the location service.** You cannot start a while-in-use/location FGS from the background without ABL, so re-arming *live tracking* on boot isn't reliable — but re-arming the `setAlarmClock` backstop is, and is the correct thing to do.

---

## The five `at-risk` fronts (verdict · top risks · what to do)

### 1. Foreground service + background location — `works (with caveats)`
No runtime timeout on the location FGS (the 6h cap is only `dataSync`/`mediaProcessing`). Runs the whole ride if the ongoing notification shows. **Risks:** ABL Play review (see #4); OEM Doze kills the live service (MIUI ~60% of kill events at ~20% share; Samsung more aggressive after 23:00 — the overnight rider); Android 16 throttles JobScheduler/WorkManager even under an FGS → **keep the ETA loop inside the service**, never offloaded. **Do:** ship FINE/COARSE + `FOREGROUND_SERVICE_LOCATION` only; treat the exact alarm as the guarantee.

### 2. Exact-alarm backstop — `at-risk`
`setAlarmClock()` is the strongest primitive (Doze/standby-exempt, survives process death). **Risks:** `SCHEDULE_EXACT_ALARM` is **denied-by-default** on fresh installs (targeting 13+), user- *and* system-revocable, and **on revoke the app is stopped and ALL future exact alarms are cancelled** — a silent total-backstop failure; also lost on backup-restore. **Decision (resolves the open "drop USE_EXACT_ALARM" note):** ship as an **alarm app** → use **`USE_EXACT_ALARM`** (auto-granted, non-revocable, GeoWake qualifies as a precise wake-alarm) instead of relying on the revocable `SCHEDULE_EXACT_ALARM`, and self-attest in the Play Console. Restricted bucket caps to **1 alarm/24h** and app-hibernation cancels alarms after months of non-use — handle occasional/traveler users explicitly.

### 3. Full-screen intent over lock — `at-risk`
Since Jan 22 2025, `USE_FULL_SCREEN_INTENT` is auto-granted only to **calling/alarm** apps; if a reviewer classifies GeoWake as "transit/navigation," it's revoked-by-default and the lock-screen takeover **silently degrades to a heads-up notification.** **Do:** complete the Play Console FSI declaration (position as an alarm app), **gate the lock-screen activity on `NotificationManager.canUseFullScreenIntent()`**, and — most important — **make the actual WAKE come from AUDIO on a `category=alarm` channel**, not from the FSI activity launching. The sound must wake the rider even when FSI is denied.

### 4. Doze / App-Standby — `at-risk`
`setAlarmClock` survives Doze; the live FGS may not. **Risks:** restricted standby bucket (1 alarm/24h), app hibernation (revokes exact alarms after ~months), `SCHEDULE_EXACT_ALARM` denied-by-default/revocable. **Do:** `USE_EXACT_ALARM` + keep the backstop on `setAlarmClock` (never Job/WorkManager) + per-OEM onboarding.

### 5. OEM battery-killers — `at-risk` (the biggest real-world risk)
- **Xiaomi HyperOS 2 / MIUI:** Autostart is OFF by default with **no API to grant it** — without it the OS won't even launch the process to service the exact alarm / FSI / boot re-arm.
- **Samsung One UI 7:** unused ~3 days → "sleeping" (alarms/jobs/FGS restricted); ~16 days → "deep sleep" (runs only when opened). A rider who doesn't open the app between trips can be silently sleeping.
- **Oppo/OnePlus/Realme ColorOS 15 / OxygenOS & Vivo Funtouch/OriginOS:** deep/adaptive optimization + sleep-standby (kills network during sleep → breaks live tracking/share; a local alarm may still fire) + require Autostart + unrestricted battery + lock-in-recents.
**Do:** ship behind a **mandatory, non-skippable, per-manufacturer onboarding gate** (detect OEM → deep-link to Autostart / battery-unrestricted / lock-in-recents), verify the exemption programmatically, re-verify after every boot, and follow **dontkillmyapp.com** guidance per OEM. This is make-or-break and lives entirely on real hardware.

---

## Before you claim "never miss" on a real device — checklist
- [ ] Ride survives deep Doze (`adb shell dumpsys deviceidle force-idle`) on a real phone, screen off, unplugged, app backgrounded.
- [ ] Backstop fires after `am force-stop` mid-ride, and after `adb reboot` (test **locked** reboot for the Direct-Boot gap).
- [ ] Alarm is audible with the alarm stream at 0 (fix #1) and under DND (fix #2).
- [ ] FSI degrades gracefully when `canUseFullScreenIntent()` is false (fix #3) — sound still wakes.
- [ ] On a Xiaomi + a Samsung: with autostart OFF / after 3 days idle, does the backstop still fire? Then with the onboarding exemptions applied?
- [ ] Decide `USE_EXACT_ALARM` vs `SCHEDULE_EXACT_ALARM` and complete the Play declarations (FGS-location, FSI-alarm, exact-alarm).

*(This doc pairs with `docs/AGENT_TESTING_CHARTER.md` §5 — the deterministic harness proves the physics; this is the real-hardware reality it can't.)*
