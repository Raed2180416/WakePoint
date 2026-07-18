# GeoWake — Grounding Notes (Citation Backbone)

> **Grounding note.** Every fact below was fetched live from primary sources during a single research session and passed through an adversarial verification pass. Treat this file as the citation backbone for `ECONOMICS.md` / monetization, `DATA_STRATEGY.md`, the Android hardening work, and the V_LINE never-late speed model. **Session `as_of` = 2026-07-18** for all topics unless a fact carries its own date. Facts are keyed to `targetSdk` API levels where behavior is version-gated (API 31 / 33 / 34 / 35 / 36 = Android 12 / 13 / 14 / 15 / 16). Historical milestone dates appear inside individual facts; the *source-retrieval* date for all of them is 2026-07-18.
>
> **This file is the COMPLETE extraction from the research journal (`journal.jsonl`).** An earlier scribe pass truncated its input inside the `flutter_local_notifications` topic and wrongly reported that V_LINE line speeds, Google Maps pricing, and the DPDP verdict were "not delivered." **All three ARE in the journal and are fully documented below.** 17 research topics + their 17 adversarial-verify passes are covered. The single genuinely-empty topic is `plugin_fbs_geo` (flutter_background_service + geolocator), which exists only as a plumbing *probe* placeholder in the journal — its real payload was never sent (see §17).

---

## DECISION-CRITICAL FACTS (read first)

### (1) Fastest Indian rail line → V_LINE overbound

**FASTEST LINE = Namo Bharat / Delhi–Meerut RRTS: design (max) 180 km/h, operational 160 km/h.** This is the single line that breaks the metro speed envelope; it is India's fastest rapid transit and is now live end-to-end (full 82.15 km corridor to Sarai Kale Khan + Modipuram as of 2026-02-22). Any uniform metro-tier bound (e.g. 100 km/h) WILL be violated on RRTS and on the Airport Express.

**Recommended never-late V_LINE overbounds (verifier: "physically defensible"):**
- **Conventional Indian metros → 100 km/h** (covers the canonical 90-design/80-operational envelope with 10+ km/h margin)
- **Delhi Airport Express + Mumbai Suburban → 140 km/h**
- **RRTS / Namo Bharat corridors → 190 km/h**
- Overbound **direction rule:** to never be late by physics, V_LINE must be ≥ the true top achievable (DESIGN speed / top-rake capability), never the operational cap or the average.

**Per-line speed table** (design = max/overbound target; operational = in-service cap; see §15 for full sourcing & confidence):

| Line / system | Design (km/h) | Operational max (km/h) | Note |
|---|---|---|---|
| Namo Bharat / Delhi–Meerut RRTS | **180** | 160 | Fastest; envelope-breaker |
| Delhi Airport Express (Orange) | 135 *(unconfirmed vs cited src)* | 120 | Fastest conventional line; ignore the "350 km/h" signalling figure |
| Delhi Metro regular lines | ~90 (inferred) | ~80 | Network "top 120" = Airport Express; avg 45 |
| Mumbai Suburban EMUs | — | ~110–120 (rake-dep.) | Medha/Bombardier 120, Siemens 100, ICF/BHEL 85; rated 110 |
| Mumbai Metro | ~90 | 80 | |
| Namma Metro (Bengaluru) Purple/Green/Yellow | ~90 (inferred) | 80 | Driverless Yellow still capped 80 |
| Hyderabad Metro | ~90 (inferred) | 80 | |
| Chennai Metro | **90 (OFFICIAL)** | **80 (OFFICIAL)** | Operator-site verbatim; anchors the 90/80 norm |
| Kolkata Metro (Blue + E–W Green) | ~90 (inferred) | 80 | Underground has no separate limit |
| Kochi Metro | 90 | 80 | RDSO-cleared |
| Ahmedabad Metro | 90 | 80 | DPR |
| Pune Metro L1/L2 | ~90 | 80 | |
| Pune Metro L3 (PPP) | ~95 | 85 (CMRS-approved) | "120 kmph" press claim unverified; use 120 for zero-risk |
| Nagpur Metro (standard-gauge) | ~90 | ~90 | Separate *planned* BG regional metro = design 200 / op 160 (RRTS tier) |
| Lucknow Metro | ~90 (inferred) | 80 | |
| Noida–Greater Noida Aqua | up to ~95 | 80 | |
| Rapid Metro Gurugram | ~90 | 80 | |

> Do **NOT** use the Airport Express "350 km/h" figure as a physical speed — it is a RHEDA-2000 track/signalling theoretical figure ("nearly three times the actual maximum speed of current trains"), not the trainset's capability.

### (2) Google Maps pricing per 1,000 calls (2026)

The flat $200/mo credit was **removed 2025-03-01** and replaced by per-SKU monthly free allotments. India has a **separate, cheaper price list with 7× larger free tiers** (Essentials 70,000 / Pro 35,000 / Enterprise 7,000 free calls per SKU per month vs global 10,000 / 5,000 / 1,000). GeoWake is India-first — **use India numbers if the billing account qualifies** (billing + majority of usage in India; INR billing is *mandatory* for a new India account).

**Directions / Routes (Compute Routes), per 1,000:**
- **Essentials:** Global $5.00 (0–100K) → $4.00 → $3.00 → $1.50 (1M–5M) → $0.38 (5M+). **India:** 70K free, then **$1.50** up to 5M, then $0.38.
- **Pro (traffic-aware):** Global $10.00 → … → $3.00 (1M–5M) → $0.75. **India:** 35K free, then **$3.00**, then $0.75.
- Directions API is now **LEGACY** (since 2025-03-01, replaced by Routes API); legacy SKUs are capped at the 100K+ discount threshold.

**Places Autocomplete (session-token model), per 1,000:**
- **Autocomplete Session Usage (per-session, SKU EEA3-417B-DBA1) = $0 / unlimited** ("currently free" on Google's pricing list — the $0 is confirmed, but Google does NOT publicly commit to permanence; model conservatively). When a session ends in a Place Details (New) request you effectively pay only that terminal Place Details.
- **Autocomplete Requests (per-request, SKU 4EF4-B17C-B31A — billed when NO session token or an abandoned session):** Global 10K free → **$2.83** (10K–100K) → … → $0.21 (5M+) *(the $2.83 first-band and the ~$3,250/mo aggregate-free-value figure are **unverified-this-session**, blog/derived, not pricing-list-confirmed).* **India:** 70K free, then **$0.85**, then $0.21.
- **Terminal Place Details Essentials:** Global $5.00/1k; **India $1.50/1k**. Place Details Pro: Global $17.00/1k; India $5.10/1k.

**Other SKUs a mobile app hits:** Dynamic Maps (Maps-SDK map load) Global $7.00/1k / **India $2.10/1k**; Static Maps Global $2.00 / **India $0.60**; Geocoding Global $5.00 / **India $1.50**.

### (3) USE_EXACT_ALARM for a transit wake-alarm — GRAY, not a guaranteed yes

Google Play's restricted-permission policy limits `USE_EXACT_ALARM` (verbatim) to apps whose core function is **"an alarm or timer app"** or **"a calendar app that shows event notifications."** A location-triggered transit wake-alarm is a **defensible-but-gray, case-by-case Play-review judgment** — no policy line explicitly blesses location-triggered alarms.

- **Recommendation: use `setAlarmClock()`** as the never-late backstop — it is the *only* alarm method fully Doze-exempt, with **no 9-minute quota** and delivery time never adjusted (`setExactAndAllowWhileIdle()` is capped ~once/9 min in Doze and is unsuitable as the primary guarantee).
- **Declare ONLY `SCHEDULE_EXACT_ALARM`, not both.** Play enforces the `USE_EXACT_ALARM` policy on the *mere presence* of the permission in the manifest, so GeoWake's current manifest (declares **both**) is fully exposed to that policy while gaining nothing. With `SCHEDULE_EXACT_ALARM` only: gate every schedule on `AlarmManager.canScheduleExactAlarms()`, deep-link via `ACTION_REQUEST_SCHEDULE_EXACT_ALARM` when false, and re-arm on `ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED` + `BOOT_COMPLETED` (denied-by-default on Android 14+ for API 33+ targets).

### (4) DPDP verdict on aggregate/anonymized data + k-anon/DP requirement

- The **DPDP Act 2023 regulates only "personal data"** = data about an *identifiable* individual (s.2(t)). The Act **does NOT define "anonymisation"** and provides **no statutory safe-harbour**. Genuinely anonymised/aggregate data (no individual identifiable) therefore falls **outside the Act — but this is a defensible-but-interpretive position, not a settled exemption**, and the burden is on GeoWake to prove non-identifiability. Location trajectories are notoriously re-identifiable, so **on-device-only aggregation is the safest architecture.**
- **Section 17(2)(b)** additionally exempts research/archiving/statistical processing not used to make decisions about a specific person — **but its "prescribed standards" are not yet notified (as of 2026)**, so it cannot be fully relied on operationally yet.
- **k-anonymity ALONE is legally & technically insufficient for mobility data.** Per EU Art.29 WP216 Table 6, k-anonymity stops "singling out" but NOT linkability or inference; per de Montjoye, 4 spatio-temporal points re-identify 95% of people. **Requirement: k-suppression as a floor UNDER differential-privacy-noised, non-trajectory aggregate counts — never release trips/paths.** Copyable recipe (Google COVID Mobility Reports): cap each user's contribution (ε ≤ 1.76/day total, ε=0.44/metric), suppress any cell with a DP contributing-user count < 100, publish nothing below 3 km². Never release "anonymised" trajectories.
- **DPDP Rules 2025 are FINAL** (Gazette G.S.R. 846(E), notified 2025-11-13). Phased: Board/definitions live now; Consent Manager 2026-11-13; core operational obligations (notice, consent, security, SDF duties, Data Principal rights) bind **2027-05-13**. Penalties reach **₹250 crore** (security-safeguards failure). "Child" = under 18 → verifiable parental consent + absolute ban on behavioural tracking/targeted ads (gate to 18+ is materially simpler to defend).

### (5) India in-app ad eCPM ranges (2026, Android-first)

**Blended India in-app eCPM ≈ $0.40–$1.50** (vs US $5–12) — an order of magnitude below tier-1. Per-format India-Android reality:

| Format | India-Android eCPM | Notes |
|---|---|---|
| Rewarded video | **~$1.50–$4.00** (occ. $5–6 w/ strong mediation) | Only Android format that *grew* in 2025 (+3.6%); poor fit for a brief-session wake-alarm |
| Interstitial | **~$1.00–$2.50** | Best realistic fit at natural transitions (frequency-capped) |
| Banner | **~$0.10–$0.30** | India banner eCPM fell −31.75% Q1→Q2 2025 |
| Native | **~$0.50–$1.50** | |

> Do **NOT** plug APAC regional averages (e.g. rewarded ~$8.20 Android) into an India model — they are inflated ~4–8× by Japan/Korea/Australia. Derived break-even: ≈ **$0.02–$0.18 ad revenue per DAU/month** in India → break-even is **DAU-driven, not eCPM-driven**. Every India per-format number here is from vendor/aggregator blogs; the only authoritative figure is your own live AdMob dashboard.

---

# TOPIC SECTIONS

Order below: Android platform (§1–5), Flutter plugins (§6–8), economics (§9–11), legal/privacy (§12–14), rail data (§15–16), OEM survival (§17). Each verifier verdict is one of `SOLID` / `MOSTLY-SOLID` / `SHAKY`.

---

## §1. Android foreground services (API 34/35/36) — types + runtime timeout
**Verifier verdict: SOLID**

### Executive summary
For a transit wake-alarm, continuous background positioning must run under the `location` foregroundServiceType (manifest `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION`; runtime `ACCESS_FINE/COARSE_LOCATION`; plus `ACCESS_BACKGROUND_LOCATION` to start/run when backgrounded). Central fact: `location` and `mediaPlayback` are **NOT** subject to any runtime cap — only `dataSync`, `mediaProcessing` (6h/24h, API 35+) and `shortService` (~3 min) are time-limited. **Do NOT model long tracking as `dataSync`.** A single service can declare `location|mediaPlayback`, but you must hold the permission for every type passed to `startForeground()` or get a `SecurityException`; because `location` is "while-in-use", the combined service can't be started from the background without `ACCESS_BACKGROUND_LOCATION`. Android 16 adds no new FGS timeouts.

### Key facts
- **Location FGS declaration** — `foregroundServiceType="location"`; manifest `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION`; runtime `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION`; cannot be created while backgrounded unless `ACCESS_BACKGROUND_LOCATION` granted. — https://developer.android.com/develop/background-work/services/fgs/service-types — *as_of 2026-07-18 (API 34/35/36)*
- **`location` has NO runtime time limit** — location = uncapped; dataSync/mediaProcessing = 6h/24h; shortService = ~3 min. Why a multi-hour wake-alarm must use `location`, not `dataSync`. — https://developer.android.com/develop/background-work/services/fgs/timeout — *as_of 2026-07-18 (Android 15+)*
- **6-hour cap scope** — 6h per rolling 24h, **per type**, shared across all the app's services of that type, applies to apps targeting **API 35+**; timer resets on foreground. — https://developer.android.com/about/versions/15/behavior-changes-15 — *as_of 2026-07-18 (API 35)*
- **Cap-exhaustion behavior** — at cap the system calls `Service.onTimeout(int,int)`; else fatal `android.app.RemoteServiceException`; restart → `ForegroundServiceStartNotAllowedException` ("Time limit already exhausted…"). — https://developer.android.com/about/versions/15/behavior-changes-15 — *as_of 2026-07-18 (API 35)*
- **Alarm-sound FGS** — `foregroundServiceType="mediaPlayback"` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK`; no runtime timeout. — https://developer.android.com/develop/background-work/services/fgs/service-types — *as_of 2026-07-18 (API 34+)*
- **Combined types** — `android:foregroundServiceType="location|mediaPlayback"`; at runtime pass the bitwise-OR of types currently in use; must hold the permission for every type passed. — https://developer.android.com/develop/background-work/services/fgs/launch — *as_of 2026-07-18 (API 34+)*
- **Missing-perm & while-in-use gate** — missing any type permission → `SecurityException`; `location` while-in-use gate still applies to a combined service (mediaPlayback does not relax it). Practical pattern: promote with only the `mediaPlayback` bit when firing from background. — https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start — *as_of 2026-07-18 (API 34+)*
- **Background-start exception class** — `android.app.ForegroundServiceStartNotAllowedException` (API 31+); sibling `BackgroundServiceStartNotAllowedException` for plain `startService()`; both extend `ServiceStartNotAllowedException`. — https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start — *as_of 2026-07-18 (API 31+)*
- **Background-start exemptions** — visible/transitioning activity; exact-alarm completing a user action; high-priority FCM (`PRIORITY_HIGH`); user tapping notification/bubble/widget; geofence/activity-recognition transition; `SYSTEM_ALERT_WINDOW` (A15+ needs visible overlay); Companion Device Manager; battery-optimizations-off. — https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start — *as_of 2026-07-18 (API 31+)*
- **Android 14 while-in-use enforcement** — creating an FGS of type location/camera/microphone/body-sensors from background throws `SecurityException`; `PermissionChecker.checkSelfPermission()` still returns GRANTED so it does NOT guard against this. — https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start — *as_of 2026-07-18 (API 34)*
- **Android 15 BOOT_COMPLETED block** — API 35+ cannot launch `dataSync`/`camera`/`mediaPlayback`/`phoneCall`/`mediaProjection` FGS from `BOOT_COMPLETED` (`microphone` since API 34); `location` is **not** on the block list → re-arm the alarm-sound FGS via AlarmManager/geofence/WorkManager, not at boot. — https://developer.android.com/about/versions/15/changes/foreground-service-types — *as_of 2026-07-18 (API 35)*
- **shortService** — needs only `FOREGROUND_SERVICE`; ~3 min; should implement `Service.onTimeout()` (see correction); not START_STICKY; cannot start other FGS. — https://developer.android.com/develop/background-work/services/fgs/service-types — *as_of 2026-07-18 (API 34+)*
- **Android 16 (API 36)** — NO new FGS timeout/type restrictions. Only adjacent change: jobs running concurrently with an FGS now obey JobScheduler runtime quotas. Test: `adb ... am compat enable OVERRIDE_QUOTA_ENFORCEMENT_TO_FGS_JOBS <pkg>`. — https://developer.android.com/about/versions/16/behavior-changes-all — *as_of 2026-07-18 (API 36)*
- **Test flag** — enable the dataSync/mediaProcessing timeout on a pre-API-35 app on Android 15: `adb shell am compat enable FGS_INTRODUCE_TIME_LIMITS <pkg>` (tune with `device_config put activity_manager data_sync_fgs_timeout_duration <ms>`). — https://developer.android.com/develop/background-work/services/fgs/timeout — *as_of 2026-07-18*

### Disputed / corrections
- **`shortService` "must implement onTimeout()"** — *minor over-statement.* Doc describes it as strongly-recommended best practice, not a hard requirement (and `Service.onTimeout()` doesn't exist on Android 13-). Overrunning still triggers a failure/ANR. **Correction:** "should (strongly recommended) implement `onTimeout()` and stop within ~3 min." — https://developer.android.com/develop/background-work/services/fgs/service-types

### Open questions
- `MissingForegroundServiceTypeException` full reference wording not retrievable this session.
- Whether GeoWake's `lib/services/trackingservice.dart` declares `foregroundServiceType="location"` (uncapped) vs anything like `dataSync` — highest-leverage never-late check.
- Play-review outcome for declaring the alarm-sound as `mediaPlayback` vs `specialUse` (specialUse + written justification is the documented fallback).
- **OEM caveat:** OEM battery managers can still kill an uncapped `location` FGS; AOSP timeout-exemption ≠ protection from OEM app-kill. Pair with `oem_autostart_service.dart` (see §17).

---

## §2. Exact alarms + `setAlarmClock()` + Doze
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
`setAlarmClock()` is the correct never-late API: the only method fully Doze-exempt, no rate quota, never time-adjusted, forces the device out of low-power mode shortly before firing. `setExactAndAllowWhileIdle()` is only partially Doze-exempt and rate-limited → unsuitable as the primary guarantee. On API 31+, `setAlarmClock()` still requires an "Alarms & reminders" permission. The real decision is **which permission**: GeoWake currently declares **both** and targets API 35; `USE_EXACT_ALARM` opts into Play's restricted-permission policy (alarm/timer or calendar-event apps only). A location-triggered transit alarm is defensible-but-gray. Lower-risk: declare **only** `SCHEDULE_EXACT_ALARM`, gate on `canScheduleExactAlarms()`, deep-link when false, re-arm on the permission-state-changed + BOOT_COMPLETED broadcasts.

### Key facts
- **Two permissions** — `SCHEDULE_EXACT_ALARM` (API 31, user-granted, revocable by user *and* system, not pre-granted to fresh installs targeting API 33+) vs `USE_EXACT_ALARM` (API 33, auto-granted at install, NOT user-revocable). Declare one, not both by necessity. — https://developer.android.com/develop/background-work/services/alarms/schedule — *as_of 2026-07-18*
- **`setAlarmClock()` fully Doze-exempt** — verbatim: "Alarms set with `setAlarmClock()` continue to fire normally. The system exits Doze shortly before those alarms fire." No 9-min quota; never time-adjusted. — https://developer.android.com/training/monitoring-device-state/doze-standby — *as_of 2026-07-18*
- **`setExactAndAllowWhileIdle()` rate-limited** — verbatim: "Neither `setAndAllowWhileIdle()` nor `setExactAndAllowWhileIdle()` can fire alarms more than once per nine minutes, per app." — https://developer.android.com/training/monitoring-device-state/doze-standby — *as_of 2026-07-18*
- **Permission required on API 31+ for all three** — `setExact()`, `setExactAndAllowWhileIdle()`, AND `setAlarmClock()` need the permission or throw `SecurityException`. Only exemption: `setExact()` OnAlarmListener overload (no PendingIntent) — doesn't apply to a process-death backstop. — https://developer.android.com/develop/background-work/services/alarms/schedule — *as_of 2026-07-18*
- **Play `USE_EXACT_ALARM` policy (verbatim)** — acceptable use only when core user-facing function requires precisely-timed actions "such as: The app is an alarm or timer app. The app is a calendar app that shows event notifications." Directs other cases to `SCHEDULE_EXACT_ALARM`; non-qualifying apps disallowed from publishing. — https://support.google.com/googleplay/android-developer/answer/9888170?hl=en — *as_of 2026-07-18*
- **GeoWake fit = GRAY** *(confidence: medium)* — plausible "alarm app" claim, but the exact alarm is only an ETA/process-death backstop; no policy line blesses location-triggered alarms → case-by-case review. — https://support.google.com/googleplay/android-developer/answer/9888170?hl=en — *as_of 2026-07-18*
- **`SCHEDULE_EXACT_ALARM` denied-by-default on Android 14+** — for fresh installs targeting API 33+. Auto-allowed exemptions: platform-signed, privileged, power-allowlist (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`), `SYSTEM_WELLBEING`. OS upgrade preserves an existing grant; backup-and-restore leaves it denied. — https://developer.android.com/about/versions/14/changes/schedule-exact-alarms — *as_of 2026-07-18*
- **Runtime flow** — `canScheduleExactAlarms()` before every schedule; if false, fall back or deep-link `Intent(ACTION_REQUEST_SCHEDULE_EXACT_ALARM)`. Register `ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`; on revocation the app is stopped and future exact alarms cancelled, so re-check + reschedule there and on `BOOT_COMPLETED`. — https://developer.android.com/develop/background-work/services/alarms/schedule — *as_of 2026-07-18*
- **`USE_EXACT_ALARM` ⇒ `canScheduleExactAlarms()` always true** *(confidence: medium)* — no runtime gate, but subject to Play review. Declaring **both** doesn't remove the Play obligation (Play enforces on mere manifest presence); GeoWake's current manifest is fully exposed while gaining nothing. — https://developer.android.com/develop/background-work/services/alarms/schedule — *as_of 2026-07-18*

### Disputed / corrections
- **"Compliance deadline 31 July 2023" attributed to answer/9888170** — *citation defect.* The verifier fetched that URL; it contains **no** deadline date. The date is genuine (Google's July 2022 announcement) but is only corroborated by secondary sources. **Correction:** keep as historical context only; the live verifiable constraint is Android 14+ denied-by-default. — https://support.google.com/googleplay/android-developer/answer/9888170?hl=en
- **Sourcing nuance** — "never time-adjusts" + "no quota" lives in the `AlarmManager` reference, not the Doze page; cite both. The Android 14 doc says "no longer pre-granted to **most** newly installed apps" — "denied by default" is accurate for GeoWake specifically (not platform-signed/privileged/SYSTEM_WELLBEING). — https://developer.android.com/reference/android/app/AlarmManager

### Open questions
- Commit to ONE permission (not both). If staying on `SCHEDULE_EXACT_ALARM`: confirm the `ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED` + `BOOT_COMPLETED` re-arm receivers exist (a silent revocation would permanently disable the backstop — memory flags a prior dead-backstop bug).
- Define degraded-mode "never late" behavior when exact-alarm permission is denied on Android 14+ devices.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is already declared → power-allowlist apps are auto-allowed exact alarms (a secondary guaranteed-delivery path).

---

## §3. Full-screen intent + DND bypass + POST_NOTIFICATIONS (visible + audible wake)
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
A modern wake alarm needs **three independent, non-automatic grants**: (1) `POST_NOTIFICATIONS` runtime permission (API 33+) or nothing can be posted; (2) `USE_FULL_SCREEN_INTENT`, which since Android 14 is a special-access, user-revocable permission auto-granted ONLY to alarm/calling apps — GeoWake qualifies but must still submit the Play Console FSI declaration and code a `canUseFullScreenIntent()==false` fallback via the `ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` deep-link; (3) DND bypass, requiring the special-access `ACCESS_NOTIFICATION_POLICY` grant BEFORE `setBypassDnd(true)` has any effect. **Load-bearing design fact:** an FSI only launches its full-screen activity when the device is LOCKED; unlocked, it degrades to a heads-up notification — so the audible ring must come from a foreground service + IMPORTANCE_HIGH channel with an alarm sound / STREAM_ALARM, never from the FSI activity alone. Play FSI enforcement live since 2025-01-22; declaration required since 2024-05-31.

### Key facts
- **FSI restricted to calling/alarm apps (Android 14+)** — manifest `android.permission.USE_FULL_SCREEN_INTENT`; special-access, user-revocable; auto-granted only to apps providing calling + alarm functionality. GeoWake (alarm) is eligible. — https://developer.android.com/about/versions/14/behavior-changes-14 — *as_of 2026-07-18 (API 34+)*
- **Platform-level (not just Play) restriction** — AOSP: default FSI grant only to calling/alarm apps; check `NotificationManager#canUseFullScreenIntent()`; user manages under Special app access > Manage full screen intents. — https://source.android.com/docs/core/permissions/fsi-limits — *as_of 2026-07-18*
- **`canUseFullScreenIntent()` added API 34** — if false, launch the settings deep-link; required fallback even for alarm apps (user can revoke; new installs may default off). — https://developer.android.com/about/versions/14/behavior-changes-14 — *as_of 2026-07-18 (API 34)*
- **FSI grant deep-link** — `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` (string `android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT`, API 34); data URI MUST be `package:<pkg>`. — https://learn.microsoft.com/en-us/dotnet/api/android.provider.settings.actionmanageappusefullscreenintent?view=net-android-34.0 — *as_of 2026-07-18 (API 34)*
- **CRITICAL: locked → full activity; unlocked → heads-up only** — so GeoWake must NOT rely on the FSI activity for sound; drive the ring independently. — https://developer.android.com/develop/ui/views/notifications/build-notification — *as_of 2026-07-18*
- **Launching the FSI activity** — hold `USE_FULL_SCREEN_INTENT` (required since target API 29) + `setFullScreenIntent(pi, true)` with a high-importance channel. — https://developer.android.com/develop/ui/views/notifications/build-notification — *as_of 2026-07-18*
- **Play FSI declaration** — required for any app using `USE_FULL_SCREEN_INTENT` targeting Android 14+; only alarm/calling core-function apps auto-granted; all others must prompt + gracefully degrade. — https://support.google.com/googleplay/android-developer/answer/13392821?hl=en — *as_of 2026-07-18*
- **Play FSI timeline (18-mo flag)** — declaration required from **2024-05-31**; enforcement from **2025-01-22** (only calling/alarm apps have it enabled by default). — https://support.google.com/googleplay/android-developer/answer/13392821?hl=en — *as_of 2026-07-18*
- **POST_NOTIFICATIONS** — runtime permission on Android 13+ (`android.permission.POST_NOTIFICATIONS`); OFF by default on fresh install; must be granted before any notification (incl. FGS notifications) shows. — https://developer.android.com/develop/ui/views/notifications/notification-permission — *as_of 2026-07-18 (API 33)*
- **POST_NOTIFICATIONS flow** — with targetSdk 33+ the app controls timing via `ActivityResultContracts.RequestPermission()`; "Don't allow" blocks all channels; media-session + self-managed CallStyle apps exempt. — https://developer.android.com/develop/ui/views/notifications/notification-permission — *as_of 2026-07-18 (API 33)*
- **DND bypass needs policy access** — AOSP `setBypassDnd` javadoc: works only with DND policy access (`isNotificationPolicyAccessGranted()`) AND only if the channel hasn't been user-modified since creation; otherwise `setBypassDnd(true)` silently no-ops. — https://android.googlesource.com/platform/frameworks/base/+/master/core/java/android/app/NotificationChannel.java — *as_of 2026-07-18*
- **DND policy-access grant** *(confidence: medium; see correction)* — manifest `ACCESS_NOTIFICATION_POLICY` + user grant; check `isNotificationPolicyAccessGranted()`; deep-link `Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS`. — https://developer.android.com/about/versions/14/behavior-changes-14 — *as_of 2026-07-18*
- **DND deep-link string values** — `ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS` = `android.settings.NOTIFICATION_POLICY_ACCESS_SETTINGS` (no extras); `ACTION_APP_NOTIFICATION_SETTINGS` = `android.settings.APP_NOTIFICATION_SETTINGS` (+`EXTRA_APP_PACKAGE`). — https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/provider/Settings.java — *as_of 2026-07-18*

### Disputed / corrections
- **DND mechanism sourced to behavior-changes-14** — *mis-attribution.* The `ACCESS_NOTIFICATION_POLICY` / `isNotificationPolicyAccessGranted()` / `ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS` mechanism is NOT on the Android 14 behavior-changes page (that page covers FSI). **Correction:** cite the `NotificationManager` API reference + the `setBypassDnd` javadoc instead. — https://developer.android.com/reference/android/app/NotificationManager#isNotificationPolicyAccessGranted()
- **Exact literal string constant VALUES not byte-verified** — the constant NAMES, API levels (FSI=34), and package-URI requirement ARE confirmed; the literal string VALUES could not be primary-confirmed this session. **Correction:** reference the `Settings.*` constants in code rather than hardcoding the strings. — https://learn.microsoft.com/en-us/dotnet/api/android.provider.settings.actionmanageappusefullscreenintent?view=net-android-35.0

### Open questions
- Does GeoWake's Play "App content" FSI declaration claim the alarm core-functionality qualifier? If not, new-install users on Android 14+ get `canUseFullScreenIntent()==false`.
- Is the alarm channel created `IMPORTANCE_HIGH` + explicit alarm sound + `setBypassDnd(true)` called only AFTER `isNotificationPolicyAccessGranted()==true` (else silently ignored and, once the user touches the channel, permanently locked out)?
- Does onboarding sequence all three grants (`POST_NOTIFICATIONS` → `USE_FULL_SCREEN_INTENT` → `ACCESS_NOTIFICATION_POLICY`) with re-check + deep-link fallback each?
- (Verifier add) A 4th gate matters: `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` governs whether the alarm fires on time (see §2).

---

## §4. Surviving reboot + Doze/App-Standby + background location (Android 14/15/16)
**Verifier verdict: SOLID**

### Executive summary
You CAN start a `location` FGS from a `BOOT_COMPLETED` receiver — `location` is NOT on the list banned from BOOT_COMPLETED (that list is dataSync/camera/mediaPlayback/mediaProjection/phoneCall on 15, + microphone on 14). The real blocker is the **while-in-use rule**: because BOOT_COMPLETED runs "in the background," a location FGS started there throws `ForegroundServiceStartNotAllowedException` **UNLESS `ACCESS_BACKGROUND_LOCATION` is already granted**. So the reboot-restart path is viable only with "Allow all the time" background location (settings-only on Android 11+, requested separately, gated by a Play Permissions Declaration review). For never-miss timing under Doze the durable primitive is `setAlarmClock()`. A battery-optimization exemption grants network + partial wakelocks in Doze but does NOT exempt deferred jobs. Android 16 tightens JobScheduler standby-bucket quotas.

### Key facts
- **BOOT_COMPLETED / LOCKED_BOOT_COMPLETED / MY_PACKAGE_REPLACED** are documented background-start exemptions (subject to per-type restrictions). — https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start — *as_of 2026-07-18 (Android 12–16)*
- **A15 BOOT_COMPLETED FGS-type ban** — banned: dataSync, camera, mediaPlayback, mediaProjection, phoneCall (A15) + microphone (A14+); `location` NOT banned. Violation → `ForegroundServiceStartNotAllowedException`. adb test flag `FGS_BOOT_COMPLETED_RESTRICTIONS`. — https://developer.android.com/about/versions/15/behavior-changes-15 — *as_of Android 15 (API 35)*
- **Still allowed from BOOT_COMPLETED (A15)** — location, connectedDevice, health, remoteMessaging, specialUse, systemExempted, shortService. — https://developer.android.com/about/versions/15/behavior-changes-15 — *as_of Android 15 (API 35)*
- **THE load-bearing gotcha** — a `location` FGS cannot be created while backgrounded (incl. from BOOT_COMPLETED) unless `ACCESS_BACKGROUND_LOCATION` is granted, else `ForegroundServiceStartNotAllowedException`. — https://developer.android.com/develop/background-work/services/fgs/service-types — *as_of 2026-07-18 (Android 14–16)*
- **Location FGS perms** — `FOREGROUND_SERVICE_LOCATION` + `foregroundServiceType="location"` + `ACCESS_FINE/COARSE_LOCATION`; missing type perm → `SecurityException`. — https://developer.android.com/develop/background-work/services/fgs/service-types — *as_of Android 14+*
- **Doze defers** — network, wakelocks (ignored), standard alarms, jobs/WorkManager, syncs, Wi-Fi scans (batched into maintenance windows). — https://developer.android.com/training/monitoring-device-state/doze-standby — *as_of 2026-07-18*
- **`setAlarmClock()` = most reliable Doze-surviving primitive** — leaves low-power modes, delivery never adjusted; needs `SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` (OnAlarmListener path exempt). — https://developer.android.com/develop/background-work/services/alarms/schedule — *as_of 2026-07-18 (Android 12+)*
- **allow-while-idle alarms rate-limited** *(confidence: medium)* — ~1 per 9 min per app in Doze (power table phrases it "7 per hour"). — https://developer.android.com/training/monitoring-device-state/doze-standby — *as_of 2026-07-18*
- **High-priority FCM penetrates Doze** — grants temporary network + partial wakelock; since A13 quota no longer tied to standby buckets; senders downgraded if messages don't produce notifications. — https://developer.android.com/topic/performance/power/power-details — *as_of Android 13+*
- **Battery-opt exemption** (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; check `PowerManager.isIgnoringBatteryOptimizations()`) — grants network + partial wakelocks in Doze/Standby; does NOT exempt deferred jobs/syncs. — https://developer.android.com/training/monitoring-device-state/doze-standby — *as_of 2026-07-18*
- **App Standby bucket limits** — ACTIVE 20m/60m, no alarm limit; WORKING_SET 10m/4h + 10 alarms/h; FREQUENT 10m/12h + 2/h; RARE 10m/24h + 1/h (network off in Doze); RESTRICTED 10m once/day + 1 alarm/day (network off). — https://developer.android.com/topic/performance/power/power-details — *as_of 2026-07-18*
- **RESTRICTED trigger** — 8 days no interaction on A13+ (down from 45 on A12), or excessive broadcasts/bindings; applies even while charging. — https://developer.android.com/topic/performance/appstandby — *as_of Android 13+*
- **Play Device & Network Abuse policy** — apps not eligible for allowlisting may not bypass system power management; direct Doze-exemption request only when core function is adversely affected. — https://support.google.com/googleplay/android-developer/answer/16559646 — *as_of 2026-07-18*
- **Acceptable direct-allowlist use cases (narrow)** — non-FCM messaging/calling, enterprise VOIP, safety apps, task automation, persistent peripheral companion; FCM-solvable cases are "not acceptable." — https://developer.android.com/training/monitoring-device-state/doze-standby — *as_of 2026-07-18*
- **ACCESS_BACKGROUND_LOCATION** — manifest-declared (Android 10+) + requested at runtime SEPARATELY and AFTER foreground. — https://developer.android.com/develop/sensors-and-location/location/permissions — *as_of Android 10+*
- **A11+ background-location = Settings-only** — "Allow all the time"; a simultaneous fine+background request is ignored and grants neither. — https://developer.android.com/about/versions/11/privacy/location — *as_of Android 11+*
- **Play Permissions Declaration for ACCESS_BACKGROUND_LOCATION** — App content > Sensitive app permissions > Location permissions; core-functionality benefit + prominent in-app disclosure + one background feature; no ads/analytics. — https://support.google.com/googleplay/android-developer/answer/9799150 — *as_of 2026-07-18*
- **Play FGS-location policy** — must be a continuation of an in-app user-initiated action, terminated immediately after — a tension with keeping a location FGS running through reboot. — https://support.google.com/googleplay/android-developer/answer/16558241 — *as_of 2026-07-18*
- **Exact-alarm perms recap** — `SCHEDULE_EXACT_ALARM` denied-by-default (target A13+; `canScheduleExactAlarms()`, `ACTION_REQUEST_SCHEDULE_EXACT_ALARM`); `USE_EXACT_ALARM` auto-granted but Play-restricted. — https://developer.android.com/about/versions/14/changes/schedule-exact-alarms — *as_of Android 13/14*
- **A16 JobScheduler tightening** — FGS-concurrent jobs + top-started jobs continuing after invisible now quota-bound; ACTIVE bucket capped 20m/60m; `setImportantWhileForeground()` deprecated. Test flags `OVERRIDE_QUOTA_ENFORCEMENT_TO_FGS_JOBS`, `OVERRIDE_QUOTA_ENFORCEMENT_TO_TOP_STARTED_JOBS`. — https://developer.android.com/about/versions/16/behavior-changes-all — *as_of Android 16*
- **A16 broadcast priority per-process only** — cross-process `android:priority` no longer respected globally; app values clamped. Relevant if GeoWake relies on broadcast ordering for boot/alarm receivers. — https://developer.android.com/about/versions/16/behavior-changes-all — *as_of Android 16*
- **A12+ location precision** — coarse-only grant caps accuracy ~3 km²; fine (~50 m) needs a separate upgrade-to-precise request. A transit alarm needs fine. — https://developer.android.com/develop/sensors-and-location/location/permissions — *as_of Android 12+*
- **A15 dataSync 6h cap** — `Service.onTimeout()`, else `RemoteServiceException`; restart → `ForegroundServiceStartNotAllowedException`; timer resets on foreground; makes dataSync unsuitable for long-lived location/timing. — https://developer.android.com/about/versions/15/changes/foreground-service-types — *as_of Android 15*

### Disputed / corrections
- **allow-while-idle "~1 per 9 minutes"** — *minor over-precision / legacy figure.* The current power-limits table says "7 per hour" (≈ one per 8.5 min). Conclusion unchanged: use `setAlarmClock()` for minute-accuracy. — https://developer.android.com/topic/performance/power/power-details

### Open questions
- Does GeoWake qualify for `USE_EXACT_ALARM` as an "alarm app" (Play-review judgment)?
- Will Play accept "never-miss transit wake alarm" as core functionality for `ACCESS_BACKGROUND_LOCATION` (needs a crafted declaration + demo video)?
- Reboot design choice: keep a location FGS across reboot (needs background location) vs persist pending trips + rearm via `setAlarmClock`/geofence (lighter footprint)?
- Per-OEM battery-killer behavior (see §17); confirm `FOREGROUND_SERVICE_LOCATION` + type declared and the BOOT_COMPLETED receiver is manifest-declared.

---

## §5. Google Play 2026 technical requirements (targetSdk, edge-to-edge, 16 KB pages, versionCode)
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
Today a new/updated app must target ≥ Android 15 / API 35, changing to **Android 16 / API 36 on 2026-08-31** for all new apps AND updates — so GeoWake's `targetSdkVersion 35` is a short-lived pass; since `compileSdk` is already 36, bump targetSdk to 36 now. Targeting API 35 already forces edge-to-edge on Android 15; API 36 removes the opt-out entirely and turns on predictive-back by default. The **16 KB page-size requirement has been mandatory since 2025-11-01 for any app targeting API 35+** (already applies): NDK r28+ aligns its own + Flutter-engine libs, but every bundled third-party `.so` must be verified. Finally, the research flagged a hardcoded `versionCode 1` ship-blocker — **already fixed in the working tree** (`versionCode flutter.versionCode`).

### Key facts
- **API 36 required from 2026-08-31** for new apps AND updates; lower targets rejected. GeoWake's targetSdk 35 passes only until then. — https://developer.android.com/google/play/requirements/target-sdk — *as_of 2026-07-18*
- **API 35 required since 2025-08-31** (why targetSdk 35 is accepted today). — https://support.google.com/googleplay/android-developer/answer/11926878?hl=en — *as_of 2026-07-18*
- **Platform exceptions** — Wear OS/Automotive = API 35+; TV/XR = API 34+. Standard phone app → API 36 applies. — https://developer.android.com/google/play/requirements/target-sdk — *as_of 2026-07-18*
- **Undiscoverable-for-new-users rule + extension** — apps targeting API 34- become uninstallable for new users on newer-OS devices; extension available to **2026-11-01**. — https://developer.android.com/google/play/requirements/target-sdk — *as_of 2026-07-18*
- **Edge-to-edge default at targetSdk 35** — content draws behind status/nav bars unless WindowInsets applied. — https://developer.android.com/about/versions/15/behavior-changes-15 — *as_of 2026-07-18*
- **targetSdk 35 disabled color APIs** — `setStatusBarColor`, `setNavigationBarColor` (gesture nav), `setNavigationBarDividerColor`, `setDecorFitsSystemWindows`, and the R.attr equivalents — no effect. — https://developer.android.com/about/versions/15/behavior-changes-15 — *as_of 2026-07-18*
- **targetSdk 36: no edge-to-edge opt-out** — `windowOptOutEdgeToEdgeEnforcement` deprecated & disabled → insets mandatory in map/tracking UI. — https://developer.android.com/about/versions/16/behavior-changes-16 — *as_of 2026-07-18*
- **targetSdk 36: predictive back on by default** — `onBackPressed()` not called, `KEYCODE_BACK` not dispatched; stopgap `android:enableOnBackInvokedCallback="false"`. — https://developer.android.com/about/versions/16/behavior-changes-16 — *as_of 2026-07-18*
- **16 KB mandatory since 2025-11-01** for new apps/updates targeting API 35+ on 64-bit devices → already applies to GeoWake. — https://developer.android.com/guide/practices/page-sizes — *as_of 2026-07-18*
- **16 KB bites only native `.so`** — pure Dart/Kotlin/Java already compatible; a Flutter app ships `libflutter.so`/`libapp.so` + plugin native code → all must be 16 KB-aligned. — https://developer.android.com/guide/practices/page-sizes — *as_of 2026-07-18*
- **Toolchain: NDK r28+ (aligns by default) + AGP 8.5.1+** — GeoWake sets `ndkVersion 28.2.13676358` (r28+); AGP must be 8.5.1+ (verified 8.9.2, see correction). r27- needs `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`. — https://developer.android.com/guide/practices/page-sizes — *as_of 2026-07-18*
- **Verify alignment** — `zipalign -c -P 16 -v 4 app.apk` ("Verification successful") or APK Analyzer LOAD segments at `align 2**14`. Prebuilt third-party libs (google_mobile_ads, maps, geolocator) are the real risk. — https://developer.android.com/guide/practices/page-sizes — *as_of 2026-07-18*
- **Framework readiness** — React Native 0.77+, Flutter, Unity ship 16 KB-compatible versions; Play bundle explorer flags gaps. — https://android-developers.googleblog.com/2025/05/prepare-play-apps-for-devices-with-16kb-page-size.html — *as_of 2026-07-18*
- **versionCode rules** — positive int, must strictly increase, no reuse, max 2,100,000,000. — https://developer.android.com/studio/publish/versioning — *as_of 2026-07-18*

### Disputed / corrections
- **"build.gradle hardcodes versionCode 1 → blocks 2nd upload"** — *STALE / already fixed.* The working tree now reads `versionCode flutter.versionCode` / `versionName flutter.versionName` (build.gradle is in the modified set). **Not an open ship-blocker;** to release, bump the `+N` in pubspec (`version: 1.0.0+1`). — https://developer.android.com/studio/publish/versioning
- **"AGP version unknown"** — *over-stated.* AGP resolves to **8.9.2** (`android/settings.gradle`: `com.android.application` version `8.9.2`), satisfying the 8.5.1+ requirement. Question closed. — https://developer.android.com/guide/practices/page-sizes

### Open questions
- Whether the release AAB's third-party `.so` (google_mobile_ads 6.0.0 / GMA native, google_maps_flutter 2.2.5, geolocator 14.0.0, libflutter.so) are actually 16 KB-aligned — requires `zipalign -c -P 16` on the built artifact; NDK r28 does NOT retroactively fix prebuilt AAR libs.
- Installed Flutter engine version (pubspec comment references 3.44.6) — confirm 16 KB-aligned libflutter.so + predictive back before targeting API 36.
- Android 16 local-network access permission — check if GeoWake uses mDNS/SSDP.

---

## §6. `flutter_local_notifications` — version, mandatory receivers, backstop config, upgrade breaks
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
GeoWake resolves to **19.4.2** (pinned `^19.0.0`); latest is **22.0.1** (~mid-June 2026). Since v16.0.0 the plugin declares only the bare minimum in its own manifest, so the **app must declare the three receivers itself — and GeoWake already does so correctly and verbatim to the README** (`ScheduledNotificationReceiver`, `ScheduledNotificationBootReceiver` with full BOOT/MY_PACKAGE_REPLACED/QUICKBOOT filter, `ActionBroadcastReceiver`), so the `AndroidScheduleMode.alarmClock` process-death backstop at `notification_service.dart:924` is wired correctly for the 19.x line. **Biggest risk is the upgrade path, not a current bug:** v20.0.0 converted `zonedSchedule()` (and show/initialize/cancel/periodicallyShow) from positional to named parameters, and GeoWake calls it positionally → any bump to ≥20 is a hard compile break. v21.0.0 raises floors to Flutter 3.38.1 / Dart 3.10.0 / AGP 8.11.1. **No action required to keep the backstop working today.**

### Key facts
- **Latest = 22.0.1** (published ~33 days before 2026-07-18). — https://pub.dev/packages/flutter_local_notifications — *as_of 2026-07-18*
- **GeoWake locked = 19.4.2**, pin `^19.0.0`, timezone 0.10.1. — https://pub.dev/packages/flutter_local_notifications/versions — *as_of 2026-07-18*
- **v16.0.0 breaking** — plugin declares only bare minimum; app must add scheduled/boot/action receivers + permissions or scheduled + process-death notifications are never delivered. — https://pub.dev/packages/flutter_local_notifications/changelog — *as_of 2026-07-18*
- **Exact receiver XML (GeoWake matches verbatim)** — `ScheduledNotificationReceiver` (exported=false); `ScheduledNotificationBootReceiver` (exported=false) with intent-filter BOOT_COMPLETED + MY_PACKAGE_REPLACED + QUICKBOOT_POWERON + `com.htc.intent.action.QUICKBOOT_POWERON`; `ActionBroadcastReceiver` (exported=false). — https://raw.githubusercontent.com/MaikuB/flutter_local_notifications/master/flutter_local_notifications/README.md — *as_of 2026-07-18*
- **GeoWake manifest already declares all three correctly** (matches README) → backstop wired for 19.x. — https://raw.githubusercontent.com/MaikuB/flutter_local_notifications/master/flutter_local_notifications/README.md — *as_of 2026-07-18*
- **Required perms** — `RECEIVE_BOOT_COMPLETED` + `SCHEDULE_EXACT_ALARM` (or `USE_EXACT_ALARM`, Play-approval-subject). GeoWake declares all of RECEIVE_BOOT_COMPLETED, SCHEDULE_EXACT_ALARM, USE_EXACT_ALARM. — https://raw.githubusercontent.com/MaikuB/flutter_local_notifications/master/flutter_local_notifications/README.md — *as_of 2026-07-18*
- **AndroidScheduleMode** — `exact` (needs exact-alarm perm, active only); `exactAllowWhileIdle` (Doze, needs perm); `alarmClock` (uses `AlarmManager.setAlarmClock`, fires through Doze) — the mode GeoWake uses. — https://raw.githubusercontent.com/MaikuB/flutter_local_notifications/master/flutter_local_notifications/README.md — *as_of 2026-07-18*
- **Full-screen intent config** — `AndroidNotificationDetails(fullScreenIntent: true)`, `USE_FULL_SCREEN_INTENT` perm, runtime `requestFullScreenIntentPermission()` (v17.2.0), activity `showWhenLocked`/`turnScreenOn`. GeoWake does all. — https://raw.githubusercontent.com/MaikuB/flutter_local_notifications/master/flutter_local_notifications/README.md — *as_of 2026-07-18*
- **DND bypass** — `bypassDnd` on channels/details since v19.2.0 + `requestNotificationPolicyAccess()`/`hasNotificationPolicyAccess()`; needs `ACCESS_NOTIFICATION_POLICY` (GeoWake declares). — https://pub.dev/packages/flutter_local_notifications/changelog — *as_of 2026-07-18*
- **BREAKING v20.0.0** — `initialize()`, `show()`, `periodicallyShow()`, `periodicallyShowWithDuration()`, `cancel()`, `zonedSchedule()` converted positional→named. GeoWake calls `zonedSchedule` positionally (`notification_service.dart:924`) → ≥20 is a hard compile break. — https://raw.githubusercontent.com/MaikuB/flutter_local_notifications/master/flutter_local_notifications/CHANGELOG.md — *as_of 2026-07-18*
- **BREAKING v21.0.0** — Flutter ≥3.38.1, Dart ≥3.10.0, minSdk 24, iOS 13, macOS 10.15, compileSdk 36, AGP 8.11.1. — https://raw.githubusercontent.com/MaikuB/flutter_local_notifications/master/flutter_local_notifications/CHANGELOG.md — *as_of 2026-07-18*
- **v22 requirements** — Flutter ≥3.38.1; compileSdk ≥35 (36 recommended); AGP ≥8.11.1; Java 17; core library desugaring (desugar_jdk_libs 2.1.4). v22.0.0 added web; v22.0.1 Windows warning fix. — https://pub.dev/packages/flutter_local_notifications — *as_of 2026-07-18*
- **GeoWake Android config already satisfies v21/v22 floors** — compileSdk 36, minSdk 24, targetSdk 35, desugaring on, desugar_jdk_libs 2.1.4. Only Dart/Flutter SDK + code migration would block an upgrade. — https://raw.githubusercontent.com/MaikuB/flutter_local_notifications/master/flutter_local_notifications/CHANGELOG.md — *as_of 2026-07-18*
- **Runtime methods present in 19.4.2** — `requestFullScreenIntentPermission()` (v17.2.0), `requestExactAlarmsPermission()` (v16.0.0). — https://pub.dev/packages/flutter_local_notifications/changelog — *as_of 2026-07-18*

### Disputed / corrections
- **"resolves to 19.4.2" as ceiling of `^19.0.0`** — *nuance.* 19.4.2 is the locked version, not the top of the range: **19.5.0 exists** within `^19.0.0` and is a no-code-change bump (stays on the positional API, avoiding the v20 break) — a low-risk update path. — https://pub.dev/packages/flutter_local_notifications/versions
- **compileSdk minimum for v22** — README says "35 minimum" but the pub.dev page says **36**. Treat 36 as the safe minimum (GeoWake already sets 36). — https://pub.dev/packages/flutter_local_notifications

### Open questions
- Stay on 19.4.2 (backstop already correct) or migrate to 22.x? Migration needs: rewrite the positional `zonedSchedule` at `notification_service.dart:924` (+ any other positional `show()`/`initialize()`/`cancel()` calls) to named args; bump Flutter ≥3.38.1 / Dart ≥3.10.0.
- Repo-wide grep for other positional call sites before any v20 bump.
- Add explicit `bypassDnd:true` on the backstop channel (available since 19.2.0; `ACCESS_NOTIFICATION_POLICY` already declared) so a killed-process alarm still sounds under DND (current code at `notification_service.dart:907` sets category alarm + audioAttributesUsage alarm but not bypassDnd).
- **Note:** this topic's verify pass was truncated in an earlier scribe run but IS present and complete in the journal (verdict MOSTLY-SOLID). Real-world backstop reliability on India OEMs is a device problem, not a plugin-config problem (see §17).

---

## §7. `permission_handler` / `google_mobile_ads` / `in_app_purchase` versions + setup gotchas
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
Current versions: `permission_handler` 12.0.3 (pulls permission_handler_android 13.x → forces compileSdk 35 + Java 17), `google_mobile_ads` 9.0.0 (bundles GMA Android SDK 25.3.0 / iOS 13.3.0 / UMP 4.0.0-Android; needs Flutter ≥3.38.1 / Dart ≥3.10.0), `in_app_purchase` 3.3.0 (pulls in_app_purchase_android 0.5.1 → Google Play Billing Library 8.0.0). **Single most time-sensitive item: Google Play turns down Billing Library 7 on 2026-08-31** — every new app AND update must ship Billing 8+ after that; being on in_app_purchase ≥3.x satisfies this. For ads, the AndroidManifest `APPLICATION_ID` meta-data and iOS `GADApplicationIdentifier` are mandatory (app crashes at launch if missing). UMP: call `requestConsentInfoUpdate()` every launch + gate on `canRequestAds()`; contractually required for EEA/UK/Switzerland, no India-specific mandate today.

### Key facts
- **permission_handler 12.0.3** (deps permission_handler_android ^13.0.0, permission_handler_apple ^9.4.6, platform_interface ^4.3.0). — https://pub.dev/packages/permission_handler — *as_of 2026-07-18*
- **permission_handler_android 13.0.0 BREAKING** — requires compileSdkVersion 35 + Java/Kotlin JVM 17 + Gradle 8.x. — https://pub.dev/packages/permission_handler_android/changelog — *as_of 2026-07-18*
- **permission_handler flows** — notifications = `Permission.notification` (Android 13+ POST_NOTIFICATIONS); background location: grant `locationWhenInUse` first, THEN `locationAlways`; exact alarms = `Permission.scheduleExactAlarm`; iOS needs Podfile `PERMISSION_*` macros (unused = 0). — https://pub.dev/packages/permission_handler — *as_of 2026-07-18*
- **google_mobile_ads 9.0.0** (bundles GMA Android 25.3.0, GMA iOS 13.3.0, UMP Android 4.0.0 / iOS 3.1.0, Next-Gen 1.1.0). — https://pub.dev/packages/google_mobile_ads/changelog — *as_of 2026-07-18*
- **google_mobile_ads toolchain** — Flutter ≥3.38.1, Dart ≥3.10.0 (raised in v8, see correction). v8 added SPM + UISceneDelegate migration. — https://developers.google.com/admob/flutter/quick-start — *as_of 2026-07-18*
- **MANDATORY Android manifest (crash if missing)** — `<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="ca-app-pub-…~…"/>`. Test app ID `ca-app-pub-3940256099942544~3347511713`. — https://developers.google.com/admob/flutter/quick-start — *as_of 2026-07-18*
- **MANDATORY iOS Info.plist (crash if missing)** — `GADApplicationIdentifier`; same test app ID. — https://developers.google.com/admob/flutter/quick-start — *as_of 2026-07-18*
- **UMP flow** — `requestConsentInfoUpdate()` every launch → `loadAndShowConsentFormIfRequired()` → gate ad loads behind `canRequestAds()`. Ships inside google_mobile_ads. Contractually required (certified CMP) for EEA/UK (since 2024-01-16) + Switzerland (since 2024-07-31). — https://developers.google.com/admob/flutter/privacy — *as_of 2026-07-18*
- **India consent** *(confidence: medium)* — NO India-specific AdMob/UMP mandate today; DPDP phases in separately (~2026-11-13 consent-manager, ~2027-05-13 substantive). — https://www.india-briefing.com/news/india-dpdp-compliance-timeline-enforcement-2026-27-44740.html/ — *as_of 2026-07-18*
- **iOS ATT** — `NSUserTrackingUsageDescription` + AppTrackingTransparency; `requestTrackingAuthorization` one-time; add `SKAdNetworkItems`. Ads still serve if denied (IDFA omitted). — https://developers.google.com/admob/flutter/privacy/idfa — *as_of 2026-07-18*
- **Android test ad unit IDs** — App Open `…/9257395921`, Adaptive Banner `…/9214589741`, Fixed Banner `…/6300978111`, Interstitial `…/1033173712`, Rewarded `…/5224354917`, Rewarded Interstitial `…/5354046379`, Native `…/2247696110`, Native Video `…/1044960115` (publisher ca-app-pub-3940256099942544). Never ship real IDs while testing. — https://developers.google.com/admob/android/test-ads — *as_of 2026-07-18*
- **iOS test ad unit IDs** — App Open `…/5575463023`, Banner `…/2435281174`, Interstitial `…/4411468910`, Rewarded `…/1712485313`, Rewarded Interstitial `…/6978759866`, Native Advanced `…/3986624511`. — https://developers.google.com/admob/ios/test-ads — *as_of 2026-07-18*
- **in_app_purchase 3.3.0** (deps in_app_purchase_android ^0.5.0, in_app_purchase_storekit ^0.4.0, platform_interface ^1.4.0; min Android 24 / iOS 13 / macOS 10.15). — https://pub.dev/packages/in_app_purchase — *as_of 2026-07-18*
- **in_app_purchase_android 0.5.1 → Billing Library 8.0.0** (0.4.x=7.1.1; 0.3.x=6.x). Do NOT add `com.android.billingclient:billing` yourself. — https://pub.dev/packages/in_app_purchase_android/changelog — *as_of 2026-07-18*
- **CRITICAL DEADLINE** — Play turns down Billing Library 7 on **2026-08-31** (ext. 2026-11-01); new apps/updates need Billing 8+. in_app_purchase 3.3.0 (Billing 8.0.0) satisfies this; older pins (Billing 6/7) must upgrade. — https://developer.android.com/google/play/billing/deprecation-faq — *as_of 2026-07-18*
- **in_app_purchase StoreKit 2 default (3.x)** — force StoreKit 1 via `InAppPurchaseStoreKit1Platform.enableStoreKit1()`. Must call `completePurchase()` after verification or Android auto-refunds within 3 days. — https://pub.dev/packages/in_app_purchase — *as_of 2026-07-18*

### Disputed / corrections
- **google_mobile_ads 9.0.0 "requires Flutter ≥3.38.1 / Dart ≥3.10.0"** — the mins are documented in the **v8.x** changelog, not restated for 9.0.0; a reasonable inference but not v9-verified. **Correction:** verify the 9.0.0 pubspec `environment` block before pinning CI. — https://pub.dev/packages/google_mobile_ads/changelog
- **India DPDP dates** — weakest-sourced (secondary aggregator, not primary MeitY/Gazette). Don't treat the exact 2026-11-13 / 2027-05-13 dates as authoritative without the primary notification. (See §12 for the primary-sourced dates.) — https://www.india-briefing.com/news/india-dpdp-compliance-timeline-enforcement-2026-27-44740.html/
- **(Note)** Google's deprecation FAQ also lists Billing Library 9 (new-app deadline 2028-08-31); "Billing 8+" remains correct.

### Open questions
- Exact google_mobile_ads 9.0.0 Android compileSdk/minSdk/AGP floor (GMA 25.x generally wants compileSdk 35/36).
- Whether GeoWake serves personalized ads to EEA/UK at all (simplifies UMP form logic).
- Confirm the pinned in_app_purchase version is ≥3.x (Billing 8) ahead of 2026-08-31.

---

## §8. `flutter_background_service` + `geolocator` — PROBE PLACEHOLDER ONLY
**Verifier verdict: SHAKY (probe)**

### Status: NOT FOUND IN RESEARCH (real payload never sent)
This topic exists in the journal only as a **plumbing probe** to test whether the `keyFacts` array parameter registered before sending the full payload. The probe carried `topic: "probe"`, one placeholder claim ("probe claim") pointing at https://pub.dev/packages/geolocator, and **no substantive content**. The paired verify pass confirmed: "This is a placeholder probe payload, not a verifiable factual claim… The real payload was never sent."

- **No real facts** for flutter_background_service or geolocator (versions, Android permission strings, foreground-service types, Play policy dates) were ever delivered. — https://pub.dev/packages/geolocator — *as_of 2026-07-18*

### Open questions
- The substantive `flutter_background_service` + `geolocator` research (exact versions, permission strings, FGS types, Play policy dates) must be re-run — it was never captured. Related FGS/permission facts are covered indirectly in §1 and §4.

---

## §9. Google Maps Platform pricing 2026 (global + India)
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
As of 2025-03-01 the flat $200/mo credit was replaced by **per-SKU monthly free allotments**: global Essentials 10,000 / Pro 5,000 / Enterprise 1,000 (Map Tiles 100,000). **India is substantially cheaper with 7× larger free tiers** (70,000 / 35,000 / 7,000) and per-1000 rates ~60–70% below global. Legacy Directions API → Routes API Compute Routes Essentials ($5.00 global / $1.50 India). For Places, the session-token model means Autocomplete keystrokes are currently FREE when the session ends in a Place Details (New) request — you pay only the terminal Place Details. Dynamic Maps (Maps SDK map load) = $7.00 global / $2.10 India; Static Maps = $2.00 / $0.60. All USD per 1,000 billable events. **GeoWake is India-first → use India numbers if the billing account qualifies** (this changes every number ~60–70% and free tiers 7×).

### Key facts
- **$200 credit removed 2025-03-01**, replaced by per-SKU free allotments. — https://developers.google.com/maps/billing-and-pricing/faq — *as_of 2026-07-18*
- **Global free tiers** — Essentials 10,000; Pro 5,000; Enterprise 1,000 per SKU/month (Map Tiles 100,000); up to ~$3,250/mo total value (blog/derived — see correction). — https://mapsplatform.google.com/resources/blog/start-building-today-with-up-to-10-000-monthly-free-calls-per-product/ — *as_of 2026-07-18*
- **India free tiers** — Essentials 70,000; Pro 35,000; Enterprise 7,000 per SKU/month. — https://developers.google.com/maps/billing-and-pricing/pricing-india — *as_of 2026-07-18*
- **Directions API (LEGACY) GLOBAL** — 0–100K $5.00; 100K+ $4.00 per 1,000. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **Directions Advanced (LEGACY Pro) GLOBAL** — 0–100K $10.00; 100K+ $8.00. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **Routes Compute Routes ESSENTIALS GLOBAL** — $5.00 (0–100K); $4.00 (100K–500K); $3.00 (500K–1M); $1.50 (1M–5M); $0.38 (5M+). — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **Routes Compute Routes PRO GLOBAL** — $10.00; $8.00; $6.00; $3.00; $0.75. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **INDIA Routes/Directions ESSENTIALS** — 70K free; $1.50 (70K–5M); $0.38 (5M+). — https://developers.google.com/maps/billing-and-pricing/pricing-india — *as_of 2026-07-18*
- **INDIA Routes/Directions PRO** — 35K free; then $3.00 per 1,000. — https://developers.google.com/maps/billing-and-pricing/pricing-india — *as_of 2026-07-18*
- **Autocomplete = two SKUs** — Autocomplete Requests (per-request) + Autocomplete Session Usage (per-session); session token bundles keystrokes with the terminal request. — https://developers.google.com/maps/documentation/places/web-service/usage-and-billing — *as_of 2026-07-18*
- **Autocomplete Session Usage (per-session, SKU EEA3-417B-DBA1) = $0 / unlimited** — pay only the terminal Place Details when a session ends in a Place Details (New)/Address Validation request. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **Autocomplete Requests (per-request, SKU 4EF4-B17C-B31A) GLOBAL** — 10K free; $2.83 (10K–100K); $2.27; $1.70; $0.85; $0.21 (5M+). Billed when no session token / abandoned session. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **INDIA Autocomplete Requests** — 70K free; $0.85 (70K–5M); $0.21 (5M+). — https://developers.google.com/maps/billing-and-pricing/pricing-india — *as_of 2026-07-18*
- **Place Details ESSENTIALS GLOBAL (SKU 6E05-E1C3-8D85)** — 10K free; $5.00; $4.00; $3.00; $1.50; $0.38. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **Place Details PRO GLOBAL (SKU 4ED6-464A-2AFC)** — 5K free; $17.00; $13.60; $10.20; $5.10; $1.28. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **Place Details ENTERPRISE (2D9A-3DE0-3766) / IDs-Only (5C36-E272-E88F)** — Enterprise 1K free then $20.00 (5M+ $1.51); IDs-Only $0. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **INDIA Place Details** — Essentials 70K free then $1.50; Pro 35K free then $5.10 (5M+ $1.28). — https://developers.google.com/maps/billing-and-pricing/pricing-india — *as_of 2026-07-18*
- **Dynamic Maps (Maps SDK map load, Essentials) GLOBAL** — 10K free; $7.00; $5.60; $4.20; $2.10; $0.53. **INDIA** — 70K free; $2.10; $0.53. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **Static Maps GLOBAL** — 10K free; $2.00; $1.60; $1.20; $0.60; $0.15. **INDIA** — 70K free then $0.60. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **Geocoding (Essentials)** — Global 10K free, $5.00 first band … $0.38 (5M+). India 70K free then $1.50. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-18*
- **Legacy status since 2025-03-01** — classic Places, Directions, Distance Matrix are LEGACY; volume discounts now scale to 5M+ (legacy capped at 100K+). — https://developers.google.com/maps/billing-and-pricing/faq — *as_of 2026-07-18*
- **India eligibility** — billing + large majority of usage in India; INR billing; up to ~70% lower than global. — https://developers.google.com/maps/billing-and-pricing/india — *as_of 2026-07-18*

### Disputed / corrections
- **"Autocomplete Session Usage is promotional/currently-free"** — the **$0 price is confirmed**, but Google does NOT label it "promotional" or commit to permanence. **Correction:** state "currently $0 per the pricing list; Google does not publicly commit to permanence — model conservatively" without attributing a "promotional" label to Google. — https://developers.google.com/maps/documentation/places/web-service/usage-and-billing
- **"India can be paid in INR (optional)"** — *over-generalization.* A NEW India-based account (which GeoWake would be) **must** pay in INR — mandatory, not optional. — https://developers.google.com/maps/billing-and-pricing/india
- **$2.83/1k Autocomplete-Requests + ~$3,250/mo aggregate free value** — **unverified-this-session** (JS-rendered pages; the $3,250 is from a marketing blog). Treat as lower-confidence, not high-confidence pricing-list facts. — https://developers.google.com/maps/billing-and-pricing/pricing

### Open questions
- Does GeoWake's billing account actually qualify for India pricing? (Changes every number ~60–70%, free tiers 7×.)
- Exact Maps-SDK-for-Android map-load counting (per app-session vs per-map-instance) — needed to convert Dynamic Maps $/1k → $/user/month.
- Does GeoWake need Routes Pro (traffic-aware, ~2× Essentials, half the free tier) or does Essentials suffice?
- How long the "$0 Autocomplete Session Usage" state lasts (no published end date).
- Can GeoWake avoid paid Google APIs (cached/offline routing, GTFS) to stay under India free tiers at low DAU? (See §11.)
- Which Place Details tier (Essentials $5/$1.50 vs Pro $17/$5.10) GeoWake's field mask lands on — the single biggest unit-economics lever.

---

## §10. India in-app ad monetization 2026 (eCPM, fill, mediation)
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
Realistic **blended India in-app eCPM ≈ $0.40–$1.50** (vs US $5–12) — an order of magnitude below tier-1. Per-format India-Android: banner ~$0.10–0.30, native ~$0.50–1.50, interstitial ~$1.00–2.50, rewarded ~$1.50–4.00 (occ. $5–6 w/ strong mediation). Do NOT use APAC regional averages (inflated by JP/KR/AU). India eCPMs broadly DECLINED through 2025 (Android banner −31.75% Q1→Q2); Android rewarded was the only format that grew. Rewarded pays ~2–4× interstitial per impression but is a poor fit for a brief-session wake-alarm → interstitial at natural transitions is more realistic. Net: ≈ **$0.02–$0.18 ad revenue per DAU/month** → break-even is DAU-driven, not eCPM-driven. Mediation mainly protects fill rate (~90–98% banner/interstitial), not India eCPM.

### Key facts
- **Blended India eCPM $0.40–$1.50** vs US $5–12, UK $4.50–10. — https://www.monetizemore.com/blog/how-much-ad-revenue-can-apps-generate/ — *as_of 2026-01-20*
- **Global (not India) Android per-format** — rewarded $5–20, interstitial $1.50–5.00, banner $0.25–1.50, native $2.50–3.80; India at/below the LOW end of each. — https://www.monetizemore.com/blog/how-much-ad-revenue-can-apps-generate/ — *as_of 2026-01-20*
- **India blended AdMob ≈ $0.34** *(confidence: medium; see correction — actually 2024 data)* vs US $1.62, Brazil $0.53, Pakistan $0.29, Indonesia $0.20. — https://www.thesrzone.com/2024/01/admob-ecpm-rates-by-country.html — *as_of 2025 (mislabeled)*
- **India AdMob CPM ₹50–₹300** (~$0.52–$3.11 at ₹96.4) by format/engagement. — https://www.themediaant.com/blog/top-10-in-app-advertising-platforms/ — *as_of 2026-03-17*
- **APAC regional (do NOT use as India proxy)** — rewarded $8.20/$7.50, interstitial $8.20/$7.50, banner $0.15/$0.10 (Android/iOS); inflated by JP/KR/AU. — https://business.mistplay.com/resources/mobile-ads-ecpm/ — *as_of Q4 2024 (article 2026-03-13)*
- **India eCPMs declined through 2025** — Android banner −31.75% Q1→Q2, iOS rewarded −19.53%, interstitial ~flat (−0.34%); Android rewarded the ONLY grower (+3.60%). — https://bidlogic.io/2025/07/25/ecpm-growth-in-mobile-apps-q1-q2-2025-analysis-and-insights/ — *as_of 2025-07-25*
- **Rewarded highest but India tier-2/3 ~$3–$10** (vs $15–40 tier-1); India Android rewarded realistically ~$1.50–$4. — https://coinis.com/glossary/rewarded-video — *as_of 2025–2026*
- **Global format averages** — banner $0.20–0.80, interstitial $2.50–5.00, rewarded $8–18; tier-1 banner $0.50–1.50, interstitial $5–8, rewarded $15–30. — https://www.playwire.com/blog/admob-ecpm-benchmarks-what-publishers-should-expect — *as_of 2025-09-17*
- **Rewarded ~40–75% > interstitial per impression** — US Android rewarded $16.49 vs interstitial $14.08 (see correction: $14.08 is interstitial-video; plain interstitial $10.45). — https://www.monetizemore.com/blog/how-much-ad-revenue-can-apps-generate/ — *as_of 2026-01-20*
- **Quick-interaction utilities poor fit for rewarded** — 15–30s opt-in disrupts a brief session; interstitial at transitions fits better (frequency-capped). — https://www.playwire.com/blog/admob-ecpm-benchmarks-what-publishers-should-expect — *as_of 2025*
- **Gaming ~20–30% > non-gaming** for interruptive formats; discount gaming benchmarks for GeoWake. — https://www.monetizemore.com/blog/how-much-ad-revenue-can-apps-generate/ — *as_of 2026-01-20*
- **Fill rate protected by mediation** — Unity 90–98%; AdMob-led multi-bidder 90–98% banner/interstitial; rewarded thinner in India. — https://appdrift.co/blog/12-top-mobile-ad-networks — *as_of 2026-07-12*
- **AdMob bidding stack** (AdMob + AppLovin + Unity + Meta Audience Network + InMobi) is standard 2026; claimed +40–100% eCPM lift is directional, smaller in India. *(confidence: low)* — https://www.adnimation.com/mobile-optimization-in-2025-turning-every-tap-into-revenue/ — *as_of 2025*
- **Meta Audience Network** — mobile-web shut 2020; for apps now consumed mainly as a bidding source; ~20–30% below Meta in-feed CPM. — https://bir.ch/blog/facebook-audience-network — *as_of 2025-11-05*
- **InMobi** (India-HQ) — India-relevant fill/demand add (see correction on tier-2/3 attribution). — https://www.themediaant.com/blog/top-10-in-app-advertising-platforms/ — *as_of 2026-03-17*
- **Model on Android** — India Android dominates; iOS gap narrowed but persists; ignore India iOS for a break-even floor. — https://adreact.com/blog/app-ad-revenue-benchmarks-2026/ — *as_of 2026*
- **USD/INR ≈ 96.4** (mid-July 2026). — https://www.exchangerates.org.uk/USD-INR-spot-exchange-rates-history-2026.html — *as_of 2026-07-17*
- **2024 global averages (sanity check)** — banner $2.80, native $3.30, interstitial $4.80, in-stream video $6.50, rewarded $10.50 (global, not India). — https://liftoff.ai/blog/in-app-advertising-in-2026-a-complete-guide-for-mobile-marketers/ — *as_of 2024*

### Disputed / corrections
- **India blended AdMob ~$0.34 "as_of 2025"** — *stale/mislabeled.* Source page is dated **2024-01-01**, from a low-authority blog. **Correction:** relabel as_of 2024-01-01, drop to low confidence; directional only, do not anchor a 2026 revenue line. — https://www.thesrzone.com/2024/01/admob-ecpm-rates-by-country.html
- **US Android rewarded $16.49 vs interstitial $14.08** — *mislabeled format.* $14.08 is interstitial-**video**; plain US Android interstitial is **$10.45** → rewarded premium is ~58% (vs plain), only ~17% vs interstitial-video. **Correction:** state rewarded $16.49 vs plain interstitial $10.45. — https://www.monetizemore.com/blog/how-much-ad-revenue-can-apps-generate/
- **InMobi "tier-2/3 India specialization, 1.5B devices"** — *over-attribution.* The 1.5B is **global**; the tier-2/3 specialization on that page belongs to **Vserv**, not InMobi. — https://www.themediaant.com/blog/top-10-in-app-advertising-platforms/

### Open questions
- GeoWake's realistic impressions-per-DAU (app opened briefly ~1–2×/trip, runs mostly backgrounded) — dominates the revenue line, unknown from external data.
- Is there a genuine rewarded value-exchange (unlock premium tones / offline route packs / remove-ads-for-a-day)? Without one, rewarded's higher eCPM is unrealizable.
- What DAU breaks even at $0.02–$0.18/DAU/month vs server/Maps/Play/OEM costs? A subscription/one-time-unlock IAP may be mathematically necessary.
- Live fill + eCPM in the actual mediation stack (only measurable post-integration).
- Does the DPDP/UMP consent posture require a flow that suppresses eCPM?

---

## §11. Self-hosted OSM routing (OSRM/Valhalla/OTP) vs Google, at India / 100K-MAU scale
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
India is the game-changer: the Geofabrik India OSM extract is only **1.6 GB**, so GeoWake never needs planet-scale hardware. India car+foot OSRM fits in ~3–4 GB RAM on a small VM (linear extrapolation — validate). A production stack (OSRM car/foot + OpenTripPlanner 2 for metro GTFS + Protomaps PMTiles basemap) costs ~$90/mo minimal to $300/mo HA, vs a Google routing bill of ~$7,400/mo (India pricing) or ~$9,550/mo (global, corrected) at 100K MAU / ~5M routing calls/month — a large infra cost cut, with cost shifting to one-time engineering. Two near-zero-effort levers: (1) ensure India-based Google billing (INR, ~70% lower); (2) migrate off Legacy Directions to Routes API. All OSS pieces are free for commercial use; the only binding obligation is **ODbL attribution** ("OpenStreetMap" + link to openstreetmap.org/copyright). Biggest gap: transit-data coverage — Delhi publishes DMRC GTFS but GTFS is patchy elsewhere.

### Key facts
- **Google March 2025 changes** — Directions/Places/Distance Matrix = Legacy; Routes API successor; $200 credit → per-SKU quotas; discounts scale to 5M+. Effective 2025-03-01. — https://developers.google.com/maps/billing-and-pricing/march-2025 — *as_of 2026-07-15*
- **Google Routes global Compute Routes Essentials** — $5.00/$4.00/$3.00 (band-tiered; see correction for deep tiers), 10K free/mo. — https://developers.google.com/maps/billing-and-pricing/pricing — *as_of 2026-07-15*
- **Google India Routes Essentials** — $1.50/1k up to 5M then $0.38, 70K free/mo; Legacy Directions India identical. ~$7,395/mo at 5M calls. — https://developers.google.com/maps/billing-and-pricing/pricing-india — *as_of 2026-07-15*
- **India OSM extract = 1.6 GB PBF** (~2.6% of the ~61 GB planet). — https://download.geofabrik.de/asia/india.html — *as_of 2026-07-15*
- **OSRM planet car serve ~123 GiB RAM** (CH, v5.26 on 61 GiB PBF) → India ~3–4 GB RAM (linear extrapolation, 8 GB VM). *(confidence: medium)* — https://github.com/Project-OSRM/osrm-backend/wiki/Disk-and-Memory-Requirements — *as_of 2021-11 (extrapolation 2026)*
- **Engine throughput (2026 benchmark)** — OSRM ~5–10k qps / 5–10 ms; Valhalla ~2–4k qps (10–30 ms); GraphHopper ~1–3k qps. OSRM fastest for car; Valhalla unifies car+foot+bike+transit costing (MIT). *(confidence: medium)* — https://www.pistack.xyz/posts/2026-04-25-graphhopper-vs-osrm-vs-valhalla-self-hosted-routing-engines-guide-2026/ — *as_of 2026-04-25*
- **OTP2 memory** — <1 GB to 100+ GB (Germany 95 GB, Finland ~10 GB); metro-only India graph ≈ low single-digit GB; can split graph-build from serving. — https://docs.opentripplanner.org/en/latest/Basic-Tutorial/ — *as_of 2026*
- **Delhi Open Transit Data** — real DMRC metro + bus GTFS + GTFS-realtime (API-key). Coverage uneven: Kochi first Indian GTFS (2020); many metros lack feeds → fall back to OSM rail geometry. — https://otd.delhi.gov.in/documentation/ — *as_of 2026-07*
- **AWS Lightsail Mumbai** — 4 GB/2vCPU $24, 8 GB $44, 16 GB/4vCPU $84/mo (same base price as elsewhere; half bundled transfer). HA pair + LB + backups ≈ $200–300/mo. — https://aws.amazon.com/lightsail/pricing/ — *as_of 2026-07*
- **Hetzner CX32** — 4 vCPU/8 GB/80 GB €6.80/mo (no India DC, nearest Singapore); CCX raised 2.1–2.7× on 2026-06-15 (see correction — unverified). — https://www.hetzner.com/pressroom/new-cx-plans/ — *as_of 2026-06-15*
- **Protomaps PMTiles** — whole India basemap as a single file via HTTP range from object storage; on Cloudflare R2 (zero egress) ~$0–5/mo; hosted commercial ~$14/mo. *(confidence: medium)* — https://protomaps.com/ — *as_of 2026-07*
- **Stadia Maps (hosted alt, uses Valhalla)** — Free 200k credits (non-commercial), Starter $20/1M, Standard $80/7.5M, Pro $250/25M; tile=1 credit, route=20 credits. — https://stadiamaps.com/pricing/ — *as_of 2026-07*
- **Licensing** — OSM=ODbL; OSRM BSD-2, Valhalla MIT, OTP + Protomaps OSS, all free commercial. Only binding obligation: display "OpenStreetMap" + link to openstreetmap.org/copyright (may be collapsible). — https://osmfoundation.org/wiki/Licence/Attribution_Guidelines — *as_of 2026-07*
- **Bottom-line at 5M calls/mo** *(confidence: medium)* — Google India ≈ $7,395; Google global ≈ $15,550 (corrected to ~$9,550, see below); self-host ≈ $90 (single box) to $300 (HA). — https://developers.google.com/maps/billing-and-pricing/pricing-india — *as_of 2026-07*

### Disputed / corrections
- **Google global at 5M ≈ $15,550/mo** — *material overstatement.* The finding omitted the deep global tiers ($3.00 500K–1M, $1.50 1M–5M, $0.38 5M+, same as India). Recomputed: 10k free + 90k×$5 + 400k×$4 + 500k×$3 + 4M×$1.50 = **~$9,550/mo**, not ~$15,550. India ($7,395) vs global (~$9,550) is only **~23% cheaper at 5M scale, NOT "roughly half."** The self-host thesis still holds. — https://developers.google.com/maps/billing-and-pricing/pricing
- **ODbL "must display '© OpenStreetMap contributors'"** — *slight over-precision.* Required: credit "OpenStreetMap" + link to openstreetmap.org/copyright; "© OpenStreetMap contributors" is an acceptable historical form, not mandated wording. — https://osmfoundation.org/wiki/Licence/Attribution_Guidelines
- **Hetzner €6.80 / CCX 2.1–2.7× hike** — could not be primary-confirmed this session; treat as unverified. Datacenter facts (no India, nearest Singapore) confirmed. — https://www.hetzner.com/cloud/

### Open questions
- GeoWake's actual Directions/Routes calls per user per month — decides whether self-hosting pays back in weeks or is premature.
- Is the Google billing account India-registered (fastest ~50% cut with zero engineering)?
- Which cities at launch and do their metros publish GTFS (Delhi yes; many no → OSM rail-geometry fallback)?
- Does GeoWake need turn-by-turn, or only polyline + ETA + station geometry (then OSRM `/route` or precomputed OSM geometry may suffice, OTP optional)?
- One unified engine (Valhalla) vs best-of-breed (OSRM + OTP2)?
- Latency: AWS Mumbai vs Hetzner Singapore/EU for the trip-start route call.
- **(Verifier add)** For a map app the larger Google bill is often Maps SDK dynamic-map loads + Geocoding, not Directions — evaluate tiles (Protomaps) + geocoding (self-hosted Nominatim/Pelias) in the same exercise.

---

## §12. India DPDP Act 2023 + DPDP Rules 2025 — compliance for a mobility-data product
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
**CRITICAL STATUS CHANGE: the "2025 Draft Rules" are FINAL** — notified as Gazette G.S.R. 846(E) on **2025-11-13**. Phased commencement: Board/definitions live now; Consent Manager registration (Rule 4) from **2026-11-13**; core operational obligations (notice, consent, security, retention, SDF duties, Data Principal rights) from **2027-05-13**. Load-bearing for GeoWake: (1) consent must be free/specific/informed/unconditional/unambiguous, purpose-limited, data-minimised — monetising aggregate mobility data needs a **separate, opt-in, unbundled commercial-purpose consent that is NOT a precondition of the alarm**; (2) the Act regulates only "personal data" (identifiable individual) and does NOT define "anonymisation" — genuinely anonymised/aggregate data sits outside, but the bar is high and trajectories are re-identifiable → on-device-only aggregation safest; (3) penalties reach **₹250 crore**; (4) Significant Data Fiduciary status is NOT automatic (Government-notified only), but if notified you owe an India-based DPO + annual DPIA/audit + algorithmic due-diligence + possible localisation. Children = under 18 → verifiable parental consent + ban on behavioural tracking/targeted ads (gate to 18+ is simpler).

### Key facts
- **Rules FINAL** — Gazette G.S.R. 846(E), notified 2025-11-13 (published 2025-11-14). — https://www.ey.com/en_in/insights/cybersecurity/transforming-data-privacy-digital-personal-data-protection-rules-2025 — *as_of 2025-11-13*
- **Phased commencement** — Rules 1,2,17–21 from 2025-11-13; Rule 4 (Consent Manager) from 2026-11-13; Rules 3, 5–16, 22–23 from **2027-05-13**. — https://ssrana.in/articles/meity-notifies-final-digital-personal-data-protection-rules-2025/ — *as_of 2026-07-18*
- **Consent standard s.6(1)** — "free, specific, informed, unconditional and unambiguous with a clear affirmative action," limited to data "necessary for such specified purpose" (purpose limitation + minimisation baked in). — https://www.dpdpact2023.com/chapter-2 — *as_of 2023-08-11*
- **Separate commercial-purpose consent** — selling aggregate mobility data is a distinct purpose from the alarm → own opt-in, unbundled, not a precondition of core service. — https://www.dpdpact2023.com/chapter-2 — *as_of 2023-08-11*
- **Right to withdraw s.6(4)–(6)** — withdraw "at any time" with comparable ease; cease processing "within a reasonable time"; prior processing stays lawful. — https://www.dpdpact2023.com/chapter-2 — *as_of 2023-08-11*
- **"Personal data" s.2(t)** — "any data about an individual who is identifiable by or in relation to such data" (identifiability trigger, GDPR-like). — https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html — *as_of 2023-08-11*
- **No "anonymisation" definition** — term absent from s.2; anonymised/aggregate data falls OUTSIDE the Act, but NO statutory safe-harbour/standard → burden on GeoWake to prove non-identifiability. — https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html — *as_of 2023-08-11*
- **Anonymisation bar is high & mobility-specific** *(confidence: medium)* — must defeat singling-out, linkability, inference (EDPB-style); if re-identification "reasonably possible," data stays personal; pseudonymised stays in-scope. — https://amlegals.com/edpbs-new-anonymisation-guidelines-what-they-mean-for-indian-businesses-under-the-dpdp-act/ — *as_of 2026-07-18*
- **General Data Fiduciary duties s.8** — accountable regardless of processor; valid-contract processors; accuracy where data drives decisions; "reasonable security safeguards"; breach notice to Board + principals; ERASE on withdrawal/purpose-completion; publish DPO/contact; grievance redressal. — https://www.dpdpact2023.com/chapter-2 — *as_of 2023-08-11*
- **Breach reporting Rule 7** — intimate the Board within 72 hours (full particulars) + notify affected Data Principals without delay (see correction on the two-stage nuance). — https://www.ey.com/en_in/insights/cybersecurity/transforming-data-privacy-digital-personal-data-protection-rules-2025 — *as_of 2025-11-13*
- **SDF status NOT automatic** — s.2(z)/s.10; class "as may be notified by the Central Government" (volume/sensitivity, risk to rights, sovereignty, electoral democracy, State security, public order). Niche transit alarm unlikely unless large scale. — https://fpf.org/blog/the-digital-personal-data-protection-act-of-india-explained/ — *as_of 2023-08-11*
- **SDF duties (s.10(2) + Rule 12)** — India-based DPO; independent data auditor; annual DPIA + audit; algorithmic due diligence; possible localisation (Rule 13(4) traffic-data). — https://ssrana.in/articles/meity-notifies-final-digital-personal-data-protection-rules-2025/ — *as_of 2025-11-13*
- **DPO nuance** — India-based DPO = SDF only (s.10(2)(a)); a non-SDF like GeoWake must still publish a contact-point (s.8(9)) + grievance redressal (s.8(10)). — https://fpf.org/blog/the-digital-personal-data-protection-act-of-india-explained/ — *as_of 2023-08-11*
- **Penalty Schedule (verbatim)** — security-safeguards s.8(5) up to **₹250 cr**; breach-notice s.8(6) up to ₹200 cr; children s.9 up to ₹200 cr; SDF s.10 up to ₹150 cr; Data Principal duties s.15 up to ₹10,000; voluntary undertaking s.32 up to applicable; other up to ₹50 cr. — https://www.dpdpa.com/theschedule.html — *as_of 2023-08-11*
- **Penalties per-contravention / can stack** *(see correction — interpretation)* — single breach could trigger ₹250 cr + ₹200 cr + ₹50 cr; s.33(2) factors weighed within each ceiling. — https://www.dpdpa.com/theschedule.html — *as_of 2023-08-11*
- **Correction & erasure s.12** — Data Principal may request erasure; distinct from + additional to s.8(7). — https://www.dpdpact2023.com/chapter-3 — *as_of 2023-08-11*
- **Fixed 3-yr auto-erasure does NOT apply to GeoWake** — Rule 8 Third Schedule applies only to e-commerce ≥2 cr users, online gaming ≥50 lakh, social media ≥2 cr; a transit alarm follows the general erase-on-purpose/withdrawal (s.8(7)); 48-hr pre-erasure notice. — https://www.seclore.com/fundamentals/dpdp-rules-2025-compliance-guide/ — *as_of 2025-11-13*
- **Children** — "child" = under 18 (s.2(d)/(f)); verifiable parental consent (s.9(1), Rule 10); no detrimental processing (s.9(2)); BARRED from tracking/behavioural monitoring/targeted ads (s.9(3)). — https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html — *as_of 2023-08-11*
- **Rule 3 notice** — standalone, understandable independently; itemised data + specified purpose + link/means to withdraw, exercise rights, complain to the Board. — https://www.dpdpa.in/dpdpa_rules_2025/Rule_3.htm — *as_of 2025-11-13*
- **Consent Manager (optional)** *(confidence: medium)* — Board-registered, India-incorporated; Rule 4 registration (from 2026-11-13) requires net worth ≥ ₹2 crore. — https://www.dpdpa.in/dpdpa_rules_2025/Rule_4.htm — *as_of 2025-11-13*

### Disputed / corrections
- **Penalties "STACK automatically"** — *interpretation presented as certainty.* The Schedule lists separate per-contravention ceilings and s.33(2) applies within each, but nothing states one breach automatically stacks multiple ceilings. **Correction:** the Board MAY impose under more than one entry, but stacking is discretionary, subject to proportionality — not automatic. — https://www.dpdpa.com/theschedule.html
- **72-hour breach report** — *precision nuance.* Rule 7(2) needs TWO Board intimations: an initial description "without delay" and the detailed/full-particulars report within 72 hours. **Correction:** initial intimation to Board + affected principals is "without delay"; the full report follows within 72 hours. — https://www.dpdpa.com/dpdparules/rule7.html
- **"Rules final" cited to EY/S.S. Rana secondary sources** — the claim is independently confirmed (Gazette ID CG-DL-E-14112025-267650) but should cite the primary MeitY notification. — https://www.meity.gov.in/documents/act-and-policies/digital-personal-data-protection-rules-2025-gDOxUjMtQWa

### Open questions
- Exact aggregation/anonymisation technique on trajectories (spatial/temporal binning, k-threshold, DP epsilon, min cohort) — determines in/out of scope (see §14).
- Does the on-device pipeline guarantee raw per-user trajectories NEVER leave the handset?
- Gate to 18+ (self-declaration + no child-directed design) or build verifiable parental consent? (18+ far simpler given the s.9(3) tracking ban.)
- Concrete deletion trigger tied to purpose-completion + consent withdrawal, auditable erasure log (s.8(7)/s.12)?
- Named grievance-contact/DPO + in-app withdrawal as easy as opt-in, incl. a separate revocable toggle for the commercial purpose?
- Realistic path to being NOTIFIED as an SDF at scale? (Pre-provision India DPO, DPIA/audit, algorithmic due-diligence.)
- **(Verifier adds)** Consent Manager framework (Rule 4), Rule 3/First Schedule notice content, and Rule 14 cross-border transfer (offshore buyers/processors) are relevant and under-covered.

> **Not legal advice.** Before monetising mobility data, obtain an Indian data-protection lawyer's sign-off on the anonymisation methodology + re-identification risk assessment and the consent architecture (ideally a formal DPIA).

---

## §13. Commercial aggregate O-D / footfall data market
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
Two buyer markets: (1) a commercial "location intelligence" market (~$24–25B in 2025, 13–16%/yr) where Placer.ai, Advan (ex-SafeGraph Patterns), Unacast/Gravy, Veraset, Cuebiq sell footfall / catchment / device-level GPS — almost all from SDKs embedded in third-party apps, sold to retail/real-estate/hedge-funds/advertisers; (2) a transportation-planning market where StreetLight (Jacobs) and Replica sell modeled O-D matrices to DOTs/MPOs/transit agencies — a real US public-agency O-D subscription runs ~$20k–45k/yr. In India, buyers are city development authorities + transit corporations procuring Comprehensive Mobility Plans through consultants, historically on expensive one-off surveys; telco CDR is the incumbent big-data source but operators resist sharing. GeoWake's differentiator — a device actually travelling AND carrying a rider-declared destination label — removes the trip-end/purpose inference raw GPS panels must model, but its tiny panel, DPDP, and slow price-sensitive public procurement make this a **slow B2B2G/research play, not fast ad-tech**, and only aggregate O-D above k-anonymity thresholds should ever be sold.

### Key facts
- **Placer.ai** *(confidence: medium)* — tiered SaaS, est. ~$5,000–30,000/yr. — https://softwarefinder.com/analytics-software/placer-ai — *as_of 2025*
- **Placer.ai scale** — ~$100M ARR, $75M Series D at ~$1.5B; tens of millions of US SDK devices; US-only. — https://techcrunch.com/2024/08/05/placer-ai-boosts-valuation-to-1-5b-after-quietly-raising-another-75m/ — *as_of Aug 2024*
- **SafeGraph** — now sells only static POI (custom annual license ~$0.10–30,000/yr); EXITED foot-traffic (sold Patterns to Advan, effective Jan 2023). — https://www.safegraph.com/pricing/ — *as_of 2025*
- **Advan** — SafeGraph Patterns → Advan Weekly Patterns+ via Dewey Data (real-estate/hedge-fund). — https://advanresearch.com/advan-news/advan-acquires-safegraphs-patterns-business-expanding-leadership-in-location-intelligence-and-foot-traffic-analytics — *as_of 2023*
- **Veraset** — raw pseudonymised device-level GPS "Movement" (device id, lat/long, timestamp); ~10B+ daily pings, 300M+ devices, 200+ countries incl. India. — https://veraset.com/datasets/movement — *as_of 2025*
- **Veraset cautionary tale** — gave bulk device-level GPS to the DC government, drawing EFF criticism → the risk of selling anything below aggregate O-D. — https://www.eff.org/deeplinks/2021/11/data-broker-veraset-gave-bulk-device-level-gps-data-dc-government — *as_of 2021*
- **Unacast/Gravy** — merged 2023-11-29; cites ~$22B market; $28M from Vector Capital Dec 2025 (see correction: direct credit, not equity). — https://www.prnewswire.com/news-releases/gravy-analytics-and-unacast-merge-to-become-leader-in-location-data-and-insights-302000184.html — *as_of Dec 2025*
- **Cuebiq** *(confidence: medium)* — footfall/attribution + audiences + de-identified "Data for Good" research feed (the India-research channel). — https://cuebiq.com/ — *as_of 2025*
- **StreetLight (Jacobs, 2022-02-07)** — O-D/trip-matrix/AADT via StreetLight InSight SaaS to DOTs/MPOs/transit/consultants. — https://www.jacobs.com/newsroom/press-release/jacobs-acquires-mobility-analytics-leader-streetlight-data-inc — *as_of Feb 2022*
- **Teton County WY anchor** — 1-yr StreetLight InSight $42,888 (10 seats, 79 TAZs, All-Vehicles O-D + Zone Activity + Segment + Turning Movement + AADT). "O-D component $19,600" is WRONG — see correction. — https://tetoncountywy.gov/DocumentCenter/View/25060/03213-Streetlight-data-for-Location-Based-Services-Data-Subscription — *as_of FY2023*
- **Replica** *(confidence: medium)* — synthetic activity-based travel-demand model (~1.2B trips / 329M people, 48 states) to Caltrans/TxDOT/MTA + Waymo/AECOM/Arup/WSP; pricing ~0.15 × served population per added agency. — https://www.replicahq.com/pricing — *as_of 2025*
- **India CMPs** — MoHUA ToR, five-stage, consultant-led, survey-dependent, "outdated and incomplete data" — the gap passive data fills. — https://www.orfonline.org/research/comprehensive-mobility-planning-in-indian-cities-challenges-gaps-and-the-way-forward — *as_of 2024*
- **NITI Aayog "Data-Driven Mobility"** *(confidence: medium)* — CDR incumbent but operators withhold; endorses data-driven mobility. — https://www.niti.gov.in/sites/default/files/2023-02/Mobility-data.pdf — *as_of 2023*
- **DPDP framing** — Rules notified 2025-11-13, broad compliance ~mid-2027; irreversibly anonymised data outside core obligations but bar undefined; consent required to collect → only aggregate/anonymised O-D above safe thresholds defensibly sellable. — https://www.ey.com/en_in/insights/cybersecurity/decoding-the-digital-personal-data-protection-act-2023 — *as_of Nov 2025*
- **Market size** *(confidence: medium)* — ~$24–25B (2025), 13–16% CAGR (Grand View $24.2B/15.5%; Mordor $25.1B/13.45%). — https://www.grandviewresearch.com/industry-analysis/location-intelligence-market — *as_of 2025*
- **GeoWake edge** *(confidence: medium)* — pairs revealed travel with a rider-DECLARED destination → eliminates trip-end/purpose inference raw panels must model. — https://tfresource.org/topics/Stated_preference_surveys.html — *as_of 2025*

### Disputed / corrections
- **"Teton O-D line item = $19,600"** — *misattribution.* The $19,600 line is "StreetLight InSight Metrics (SOW)," NOT O-D. O-D is bundled in the "Solution Package – All Vehicles" at $33,269 gross (net $23,288). **No isolable O-D price exists;** the concrete public-agency benchmark is the ~$42,888 total contract. — https://tetoncountywy.gov/DocumentCenter/View/25060/03213-Streetlight-data-for-Location-Based-Services-Data-Subscription
- **Unacast "$28M raise Dec 2025" cited to 2023 merger URL** — *source mismatch + debt-vs-equity.* Number/date correct (2025-12-03) but it's direct-credit financing (Vector Velocity), not equity, and must cite the actual Dec-2025 announcement. — https://www.businesswire.com/news/home/20251203203311/en/Unacast-Secures-$28M-Financing-from-Vector-Capital-to-Accelerate-Next-Phase-of-Growth
- **Veraset DC data "sold"** — per EFF it was a free trial, not a paid sale; "gave" is accurate, "sold" is not. — https://www.eff.org/deeplinks/2021/11/data-broker-veraset-gave-bulk-device-level-gps-data-dc-government

### Open questions
- k-anonymized sellable coverage at GeoWake's panel size — how many station-pair O-D cells clear a min-count threshold in Bengaluru/Delhi/Mumbai before commercially meaningful?
- First paying India buyer: transit corp (BMRCL/DMRC/BMTC), CMP consultant, Smart Cities ICCC, academic Data-for-Good, or retail/real-estate footfall — and INR price?
- Does the current (alarm) consent cover secondary sale of aggregated destination data under DPDP, or need a separate unbundled notice?
- Live Indian public tenders (GeM/Smart Cities/state DOT) revealing real INR price points?
- Can the destination-intent label be a genuinely differentiated product (labeled O-D matrices, modal-intent splits) that StreetLight/Replica inference can't replicate?

---

## §14. Legal-by-construction privacy tech for aggregate mobility (k-anon + DP + on-device)
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
"Legal-by-construction" means building so raw trajectories never leave the phone and only differentially-private, k-suppressed aggregate counts are released — because releasing "anonymised" trajectories is legally and mathematically indefensible. de Montjoye (Nature 2013): 4 spatio-temporal points re-identify 95% of 1.5M people (2 points >50%), and this is cited in the EU's own WP216 to show pseudonymised location data is not anonymous. WP216 Table 6 is the design keystone: **k-anonymity alone defeats "singling out" but still permits linkability and inference; differential privacy can address all three** → k-anon is a necessary floor, not a sufficient control. Real deployments converge on a copyable recipe: on-device/federated aggregation with secure aggregation, suppression of sparse cells (Google discards cells <100 users, publishes nothing <3 km²), and Laplace/Gaussian noise with a bounded per-user daily epsilon (Google capped each user so each metric had ε=0.44, ≤1.76/day). For India, DPDP applies only to identifiable-individual data; Section 17(2)(b) exempts statistical/research processing not used for decisions about a person. **Catch: epsilon is NOT comparable across systems** (Apple local ε=2–8; 2020 US Census central ε=19.61) — "we use differential privacy" is meaningless without stating model + epsilon + per-user bound.

### Key facts
- **de Montjoye "Unique in the Crowd"** — 4 points → 95% unique; 2 points → >50%; N=1.5M over 15 months. — https://www.nature.com/articles/srep01376 — *as_of 2013-03-25*
- **Uniqueness decays ~resolution^(−0.1)** — coarsening the grid/time barely adds anonymity → aggregation of trajectory microdata cannot rescue anonymity alone. — https://www.nature.com/articles/srep01376 — *as_of 2013-03-25*
- **EU Art.29 WP216 cites de Montjoye** — restates the 95%/4-point, >50%/2-point result to conclude pseudonymised location data is not anonymised. — https://iapp.org/media/pdf/resource_center/wp216_Anonymisation-Techniques_04-2014.pdf — *as_of 2014-04-10*
- **WP216 Table 6 (design rule)** — Aggregation/K-anonymity: singling-out=No, linkability=Yes, inference=Yes. Differential privacy: all three "May not." Pseudonymisation: Yes/Yes/Yes. → k-anon is a necessary floor; DP required to also blunt linkability + inference. — https://iapp.org/media/pdf/resource_center/wp216_Anonymisation-Techniques_04-2014.pdf — *as_of 2014-04-10*
- **WP216 k-anon guidance** — avoid k≤2; prefer k>10; no fixed statutory k; practitioners target k in the tens-to-hundreds for sparse spatio-temporal cells. — https://iapp.org/media/pdf/resource_center/wp216_Anonymisation-Techniques_04-2014.pdf — *as_of 2014-04-10*
- **Google COVID Mobility DP** — Laplace noise; per-user contribution capped to 4 (category,location) pairs/day/geo-level; each place-visit metric ε=0.44; total ≤1.76/day. Per-granularity: level 0/1 scale 1/0.11 (ε=0.11), level 2 scale 1/0.22 (ε=0.22). Copyable per-user-bound pattern. — https://arxiv.org/pdf/2004.04145v2 — *as_of 2020-04-09*
- **Google COVID hard suppression** — discard any metric whose DP contributing-user count <100; publish nothing for any region <3 km² (merge to clear the floor). A real k≈100 + min-cell-area rule for station×hour flow suppression. — https://arxiv.org/pdf/2004.04145v2 — *as_of 2020-04-09*
- **Google Federated Analytics** — only aggregated results made available ("never any data from a particular device"); Secure Aggregation masks each device so the server decrypts only the combined tally. In production in Gboard, Messages smart-reply, Now Playing. — https://research.google/blog/federated-analytics-collaborative-data-science-without-data-collection/ — *as_of 2020-05-27*
- **Apple LOCAL DP** — noise on-device before leaving (Count Mean Sketch); no identifier, IP dropped, ≤3-month retention. Budgets: emoji ε=4 (1/day), Lookup Hints ε=4 (2/day), QuickType ε=8 (2/day), Health ε=2 (1/day), Safari ε=4/8. Local model uses larger epsilon than central. — https://www.apple.com/privacy/docs/Differential_Privacy_Overview.pdf — *as_of 2017 (current published version)*
- **US Census 2020 DAS (largest central-model DP)** — redistricting privacy-loss budget ε=19.61 (persons 17.14 + housing 2.47), announced 2021-06-09 (zCDP rho / discrete Gaussian — see correction). Illustrates epsilon values are NOT comparable across deployments/models. — https://www.census.gov/newsroom/press-releases/2021/2020-census-key-parameters.html — *as_of 2021-06-09*
- **OnTheMap (LEHD)** *(confidence: medium)* — first production formal-DP deployment; protects an O-D commuting matrix by releasing noise-protected block-level flows (Machanavajjhala et al., ICDE 2008). Precedent that a legally-defensible O-D product is achievable via DP synthesis rather than releasing trips. — https://lehd.ces.census.gov/doc/help/ICDE08_conference_0768.pdf — *as_of 2008*
- **GDPR Recital 26** — data-protection principles don't apply to anonymous info; identifiability must account for "all means reasonably likely to be used, such as singling out." Since singling-out of trajectories is cheap, only DP-aggregated non-trajectory outputs clear this bar. — https://gdpr-info.eu/recitals/no-26/ — *as_of GDPR in force 2018-05-25*
- **India DPDP scope + s.17(2)(b)** *(confidence: medium)* — applies only to "digital personal data" (identifiable); irreversibly anonymised aggregates fall outside; s.17(2)(b) exempts research/archiving/statistical processing not used for decisions about a person (per prescribed standards). — https://fpf.org/blog/the-digital-personal-data-protection-act-of-india-explained/ — *as_of Act No.22 of 2023*
- **"Unique in the Shopping Mall" (Science 2015)** *(confidence: medium)* — 4 points → 90% re-identified in 1.1M people (3 mo credit-card metadata); price adds ~22%. Confirms the 4-point result generalizes to any timestamped-location stream incl. transit tap/GPS. — https://www.science.org/doi/abs/10.1126/science.1256297 — *as_of 2015-01-30*

### Disputed / corrections
- **US Census "zCDP rho=3.65; discrete Gaussian" cited to the key-parameters press release** — *mis-sourced.* That page contains ONLY the epsilon figures + date; it does NOT mention zCDP, rho, or discrete Gaussian. **Correction:** epsilon numbers are correct/sourced; re-cite the DAS technical docs for the mechanism, and treat rho=3.65 as UNVERIFIED. — https://www.census.gov/newsroom/press-releases/2021/2020-census-key-parameters.html
- **"India anonymised aggregates fall outside DPDP" as a settled basis** — *over-generalization.* DPDP has NO explicit anonymisation recital/definition/carve-out (unlike GDPR Recital 26); the conclusion is inferred from "identifiable individual," and s.17(2)(b)'s prescribed standards remain UNPUBLISHED. **Correction:** frame as a defensible-but-interpretive argument; legal-by-construction (raw trajectories never leave the phone; only DP-suppressed aggregates released) is the right posture precisely because the statutory scope argument isn't airtight. — https://www.dpdpa.com/dpdpa2023/chapter-4/section17.html

### Open questions
- What exact (ε, k, contribution-cap, min-cell-area) for a station×hour×flow O-D product? Google's shipped defaults (ε≤1.76/day, suppress <100 users, no cell <3 km²) are a strong copyable start; tune to India transit density.
- Have the DPDP Rules 2025 statistical-exemption "prescribed standards" (s.17(2)(b)) actually been notified? (Not as of 2026.)
- **Does GeoWake need to EXPORT any aggregate data at all?** If not, the entire re-identification/DP surface disappears — "no personal data leaves the phone" is the strongest posture; the DP tech is only needed if a data product/B2B feed is a real goal.
- Confirm the exact OnTheMap/LEHD epsilon + mechanism from the primary ICDE 2008 PDF before citing to an investor/partner.

---

## §15. India metro/RRTS line top speeds (V_LINE overbound)
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
Indian urban/regional rail splits into three speed tiers. **TIER 1 (regional): Namo Bharat / Delhi–Meerut RRTS — design 180 km/h, operational 160 km/h — the single line that breaks the metro envelope** (safe V_LINE 180, use ~190 for margin). **TIER 2:** Delhi Airport Express (design 135 / operational 120 since Sep 2023 — ignore the "350 km/h" signalling claim) and Mumbai Suburban EMUs (~120 km/h top rake, system ~110). **TIER 3:** essentially EVERY conventional Indian metro runs a max operational 80 km/h on a ~90 km/h design — Chennai is officially "design 90, operational 80," the canonical Indian standard-gauge envelope. Practical overbounds: 100 covers every conventional metro; 140 covers Airport Express + Mumbai suburban; 190 required only on RRTS. Overbound direction: use DESIGN speed / top-rake capability, never the operational cap or average.

### Key facts (per line)
- **Namo Bharat / Delhi–Meerut RRTS** — design 180 km/h, operational 160 km/h; India's fastest; V_LINE must overbound 180 on any RRTS corridor. — https://en.wikipedia.org/wiki/Delhi%E2%80%93Meerut_Regional_Rapid_Transit_System — *as_of 2026-07-18* — confidence high
- **Delhi Airport Express (Orange)** — CAF trainset design 135 km/h; operational raised to 120 km/h on 2023-09-17 (from 110). The "350 km/h" is a RHEDA-2000 track/signalling figure, NOT a train speed. — https://en.wikipedia.org/wiki/Airport_Express_Line_(Delhi_Metro) — *as_of 2023-09-17 / 2026-07-18* — confidence high
- **Airport Express operational 120 km/h** = fastest of any conventional metro line in India. — https://www.business-standard.com/india-news/ahead-of-pm-visit-delhi-airport-metro-to-now-operate-at-120-km-h-123091600930_1.html — *as_of 2023-09-16* — confidence high
- **Delhi Metro regular lines** — avg 45 km/h; network top 120 (=Airport Express); regular Phase I/II/III lines run max ~80 in service. — https://en.wikipedia.org/wiki/Delhi_Metro — *as_of 2026-07-18* — confidence medium
- **Mumbai Suburban EMUs** — newest Medha/Bombardier 12-car rakes ~120 km/h, system rated ~110; Siemens 100; older BHEL/ICF 85. Overbound at 120. — https://en.wikipedia.org/wiki/Mumbai_Suburban_Railway — *as_of 2026-07-18* — confidence high
- **Mumbai Metro** — operational max 80 km/h, design ~90. — https://en.wikipedia.org/wiki/Mumbai_Metro — *as_of 2026-07-18* — confidence high
- **Namma Metro (Bengaluru) Purple/Green/Yellow** — top 80 km/h, avg 35, design ~90; driverless Yellow still capped 80. — https://en.wikipedia.org/wiki/Namma_Metro — *as_of 2026-07-18* — confidence high
- **Hyderabad Metro** — operational max 80 km/h (post signalling upgrade), avg 35–40, design ~90. — https://www.thehansindia.com/news/cities/hyderabad/hyderabad-metro-rail-speed-increased-736306 — *as_of 2022–2026* — confidence medium
- **Chennai Metro (OFFICIAL)** — "maximum design speed 90 kmph, maximum operational speed 80 kmph" — canonical Indian SG-metro envelope. — https://chennaimetrorail.org/technology/rolling-stock/ — *as_of 2026-07-18* — confidence high
- **Kolkata Metro** — max 80 km/h, design ~90; underground no separate limit. — https://en.wikipedia.org/wiki/Kolkata_Metro — *as_of 2026-07-18* — confidence medium
- **Kochi Metro** — design 90, operational 80 (RDSO-cleared), avg 35, 50 near stations. — https://www.railway-technology.com/projects/kochi-metro/ — *as_of 2016-12-08 / current* — confidence high
- **Ahmedabad Metro** — design 90, operating 80, avg ~33. — https://en.wikipedia.org/wiki/Ahmedabad_Metro — *as_of 2019 DPR + current* — confidence high
- **Pune Metro L1/L2 & L3** — L1/L2 max 80 (DPR sectional 80); L3 (Hinjawadi–Shivajinagar PPP) operational 85, design ~95 (one source claims 120 design — unconfirmed; CMRS approved 85). — https://en.wikipedia.org/wiki/Pune_Metro — *as_of 2025-06* — confidence medium
- **Nagpur Metro** — SG metro max ~90, avg 33; separate PLANNED Nagpur Broad-Gauge regional metro = design 200 / operating 160 (RRTS tier, not the running metro). — https://en.wikipedia.org/wiki/Nagpur_Metro — *as_of 2026-07-18* — confidence medium
- **Lucknow Metro** — max 80, design ~90, avg ~34, fully automated. — https://en.wikipedia.org/wiki/Lucknow_Metro — *as_of 2026-07-18* — confidence medium
- **Noida–Greater Noida Aqua** — max 80, avg ~37.5; one source cites 95 design max → overbound ~95. — https://en.wikipedia.org/wiki/Noida_Metro — *as_of 2026-07-18* — confidence medium
- **Rapid Metro Gurugram** — max 80, avg 35–40, design ~90; SG, 3-car. — https://en.wikipedia.org/wiki/Rapid_Metro_Gurgaon — *as_of 2026-07-18* — confidence medium

### Disputed / corrections
- **"Pune L3 opened Jun 2025 at 85 km/h operational"** — the **85 km/h (CMRS-approved) is confirmed and safe for V_LINE**; but the opening date is contradicted — commercial launch was still awaiting final CMRS safety clearance in the sourced reporting. **Correction:** don't assert a confirmed Jun-2025 revenue-service opening; the 85 number stands regardless. — https://www.pmrda.gov.in/en/pune-metro-line-3/
- **"Airport Express train design speed 135 km/h"** — operational 120 is firmly confirmed; the specific 135 DESIGN figure was NOT on the cited Wikipedia page (only secondary sources). Non-load-bearing: any value 120–180 lands Airport Express safely in tier 2 (140 overbound unaffected). **Correction:** cite operational 120 as confirmed; treat 135 design as unconfirmed against the cited source. — https://en.wikipedia.org/wiki/Airport_Express_Line_(Delhi_Metro)

### Open questions
- Per-line operator DESIGN-speed datasheets for Hyderabad, Kolkata E–W, Namma Yellow, Lucknow, Noida, Delhi Phase III/IV are unpublished — the "~90 design" is inferred (the recommended 100 overbound absorbs this with 10+ km/h margin).
- Reconcile Pune L3's 85 CMRS-approved vs unverified 120 press claim vs ~95 DPR figure.
- Whether any Delhi conventional line is cleared above 80 operational (disambiguate the network "120 top" from Airport Express).
- Confirm Airport Express is still 120 (no 2024–2026 upgrade to its 135 ceiling).

---

## §16. Ordered station sequences — Delhi/NCR + Gurugram metro lines
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
Ordered terminus-to-terminus sequences were compiled and cross-checked (English Wikipedia line articles + YoMetro + DMRC/news). Order is stable for Blue, Yellow, Red, Violet, Green. **Material recent changes affecting sequences/names:** (1) **Pink Line ring closure** — Majlis Park↔Maujpur-Babarpur arc opened 2026-03-08, making it India's first ring/circular metro (~46 stations incl. Shiv Vihar branch; Soorghat built but bypassed); (2) **Magenta western terminus extended** to Krishna Park Extension (2025-01-05); (3) **Udyog Bhawan → Seva Teerth** (Feb 2026); (4) **HUDA City Centre → Millennium City Centre Gurugram** (2023). The verifier flagged a 5th change the research MISSED (see below). Under-construction Phase-4 interchanges are NOT live transfers and must not be encoded as active.

### Key facts (full ordered lists in source; condensed here)
- **Blue Line MAIN (Line 3)** — Dwarka Sector 21 → Noida Electronic City, **50 stations**; branch junction at Yamuna Bank (stn 34); stn 32 "Supreme Court" (ex-Pragati Maidan). — https://en.wikipedia.org/wiki/Blue_Line_(Delhi_Metro) — *as_of 2026-07-18* — confidence high
- **Blue Line BRANCH (Line 4)** — Yamuna Bank → Laxmi Nagar → Nirman Vihar → Preet Vihar → Karkarduma → Anand Vihar → Kaushambi → Vaishali (7 after junction). — https://en.wikipedia.org/wiki/Blue_Line_(Delhi_Metro) — *as_of 2026-07-18* — confidence high
- **Yellow Line** — Samaypur Badli → Millennium City Centre Gurugram, **37 stations**; stn 19 "Seva Teerth" (ex-Udyog Bhawan); stn 20 "Lok Kalyan Marg" (ex-Race Course). — https://en.wikipedia.org/wiki/Yellow_Line_(Delhi_Metro) — *as_of 2026-07-18* — confidence high
- **Red Line** — Rithala → Shaheed Sthal (New Bus Adda, Ghaziabad), **29 stations** (canonical order Rithala→Rohini West→Rohini East→Pitampura→Kohat Enclave; a WebFetch misread was flagged but the verifier confirmed the order is correct). — https://en.wikipedia.org/wiki/Red_Line_(Delhi_Metro) — *as_of 2026-07-18* — confidence medium
- **Violet Line** — Kashmere Gate → Raja Nahar Singh (Ballabhgarh), **34 stations**. — https://en.wikipedia.org/wiki/Violet_Line_(Delhi_Metro) — *as_of 2026-07-18* — confidence high
- **Green Line** — MAIN Inderlok → Brigadier Hoshiyar Singh (Bahadurgarh), 22 stations, branch junction at Ashok Park Main → Satguru Ram Singh Marg → Kirti Nagar. — https://en.wikipedia.org/wiki/Green_Line_(Delhi_Metro) — *as_of 2026-07-18* — confidence high
- **Magenta Line** — Krishna Park Extension (new terminus 2025-01-05) → Janakpuri West → Botanical Garden, 26 stations; "IIT" now "IIT Delhi". — https://en.wikipedia.org/wiki/Magenta_Line_(Delhi_Metro) — *as_of 2026-07-18* — confidence medium
- **Pink Line = CLOSED RING + Shiv Vihar branch** — one-direction ring from Majlis Park; ring closes between Burari and Majlis Park; Soorghat built but bypassed (DDA land issue). — https://yometro.com/delhi-metro-pink-main-line-1109 — *as_of 2026-07-18* — confidence medium
- **Pink Line ring closure opened 2026-03-08** — India's first ring metro; ~46 stations (43 ring + 3 Shiv Vihar, Maujpur-Babarpur shared); ~73.5 km, India's longest single metro line. New stations (Burari, Jharoda Majra, Jagatpur/Wazirabad, Soorghat, Sonia Vihar, Khajuri Khas, Bhajanpura, Yamuna Vihar) are the ones GeoWake most likely lacked. — https://en.wikipedia.org/wiki/Pink_Line_(Delhi_Metro) — *as_of 2026-03-08* — confidence medium
- **Magenta Krishna Park Extension opened 2025-01-05** — 2.8 km beyond Janakpuri West, initially a separate shuttle. — https://x.com/OfficialDMRC/status/1875539681137586510 — *as_of 2025-01-05* — confidence high
- **Udyog Bhawan → Seva Teerth (Yellow, Feb 2026)** — any string still saying "Udyog Bhawan" is stale. — https://ddnews.gov.in/en/delhi-udyog-bhawan-metro-station-renamed-seva-teerth/ — *as_of 2026-02-14* — confidence high
- **HUDA City Centre → Millennium City Centre Gurugram (Yellow terminus, 2023)** — any stale string. — https://en.wikipedia.org/wiki/Yellow_Line_(Delhi_Metro) — *as_of 2026-07-18* — confidence high
- **Rapid Metro Gurgaon** — 11-station horseshoe interchanging Yellow at Sikanderpur; north of Sikanderpur is a ONE-DIRECTIONAL Cyber City loop, south is double-track; ~12.85 km. — https://en.wikipedia.org/wiki/Rapid_Metro_Gurgaon — *as_of 2026-07-18* — confidence medium

### Disputed / corrections
- **Magenta "26 stations, only 4 material changes"** — *STALE / UNDERCOUNTED.* As of 2026-03-08 the Magenta Line has **33 operational stations (~50.18 km)**: a 7-station Phase-IV arc **Deepali Chowk↔Majlis Park opened 2026-03-08** (same day as the Pink ring). Magenta now runs as **TWO physically disconnected operational sections** (Majlis Park↔Deepali Chowk island + Krishna Park Ext↔Botanical Garden trunk; change at Janakpuri West, gap under construction to ~Dec 2027). **Correction:** add the 7-station Deepali Chowk↔Majlis Park corridor as a SEPARATE sequence island; do NOT model a continuous Krishna Park Ext→Majlis Park run; bump "four changes" to five. — https://en.wikipedia.org/wiki/Magenta_Line_(Delhi_Metro)
- **Rapid Metro Gurgaon (11 stations, one-way loop)** — NOT independently verified this pass; verify station count + loop directionality against a current DMRC/official source before ingest. — https://en.wikipedia.org/wiki/Rapid_Metro_Gurgaon

### Open questions
- Confirm operator spellings for the 8 new Pink Line ring stations + Red Line stns 2–4 against the official DMRC site before writing the seed.
- Confirm Magenta service pattern — single train Krishna Park Ext↔Botanical Garden vs still a shuttle stub, plus the new northern island.
- Confirm whether Rapid Metro Gurgaon is being renumbered/rebranded under the new Gurugram Metro (GMRL) expansion (separate line, don't merge).
- Verify New Ashok Nagar ↔ Namo Bharat RRTS interchange operational status + walking transfer.
- Do NOT encode UC Phase-4 interchanges as active (Magenta at Haiderpur Badli Mor/Azadpur/RK Ashram/Pulbangash/Delhi Gate/Indraprastha; Golden Line at Chhatarpur/Lajpat Nagar/Tughlakabad).

---

## §17. Aggressive OEM background-process killing (India-market Android) + autostart deep-links
**Verifier verdict: MOSTLY-SOLID**

### Executive summary
On the OEM skins dominating India (Xiaomi HyperOS/MIUI, ColorOS = Oppo/Realme/OnePlus, Vivo/iQOO Funtouch/OriginOS), a correct foreground location service + a Doze whitelist (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) is **NOT sufficient**. These OEMs run a second proprietary "Autostart" + battery-saver layer, independent of Android's standard whitelist, with no public API — without the user manually enabling Autostart the service is killed on screen-off, on memory pressure, and permanently after reboot. Highest-leverage action: get the user to toggle **Autostart ON**, set battery to **No restrictions / Unrestricted**, and **lock the app in Recents**. You can deep-link to the exact OEM screen via known (unexported, undocumented) ComponentNames, wrapped in try/catch with a fallback. **Samsung One UI is the bright spot:** since One UI 6.0 (July 2024) Samsung guarantees FGS of Android-14-target apps work as intended → the fix reduces to "Never sleeping apps" + disabling Adaptive Battery.

### Key facts
- **Xiaomi Autostart is a SEPARATE proprietary system** — `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` does NOT cover MIUI's autostart whitelist; "no APIs and no documentation." Autostart must be enabled manually. — https://dontkillmyapp.com/xiaomi — *as_of 2026-07* — confidence high
- **Xiaomi Autostart deep-link** — `com.miui.securitycenter` / `com.miui.permcenter.autostart.AutoStartManagementActivity` (MIUI 10–14 + HyperOS). — https://raw.githubusercontent.com/judemanutd/AutoStarter/master/autostarter/src/main/java/com/judemanutd/autostarter/AutoStartPermissionHelper.kt — *as_of 2026-07* — confidence high
- **Xiaomi battery "No restrictions" (PowerKeeper)** *(confidence: medium)* — `com.miui.powerkeeper` / `com.miui.powerkeeper.ui.HiddenAppsConfigActivity` + extras `package_name`, `package_label`. — https://github.com/YangXueQingZZ/KeepLiveSample/blob/master/app/src/main/java/mrkang/keeplivesample/IntentWrapper.java — *as_of 2026-07*
- **HyperOS user path** — Settings > Apps > [app] > App permissions > Background autostart; Battery saver > No restrictions; lock in Recents (drag down) survives "clear all." — https://dontkillmyapp.com/xiaomi — *as_of 2026-07* — confidence high
- **MIUI/HyperOS resets toggles after OTA/reboot** — no permanent programmatic guarantee; locking in Recents best survives. — https://dontkillmyapp.com/xiaomi — *as_of 2026-07* — confidence high
- **Oppo/ColorOS Autostart deep-links** (also Realme UI, legacy OnePlus) — `com.coloros.safecenter/com.coloros.safecenter.startupapp.StartupAppListActivity`; `.../com.coloros.safecenter.permission.startup.StartupAppListActivity`; legacy `com.oppo.safe/com.oppo.safe.permission.startup.StartupAppListActivity`. — https://raw.githubusercontent.com/judemanutd/AutoStarter/master/autostarter/src/main/java/com/judemanutd/autostarter/AutoStartPermissionHelper.kt — *as_of 2026-07* — confidence high
- **Realme UI user path** — Settings > Battery > Power saving > App battery management > [app]: Allow auto-launch + background + foreground activity; disable Sleep standby optimization. "No known solution on dev end yet." — https://dontkillmyapp.com/realme — *as_of 2026-07* — confidence high
- **Vivo/iQOO Autostart deep-links** — `com.iqoo.secure/com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity`; `com.vivo.permissionmanager/com.vivo.permissionmanager.activity.BgStartUpManagerActivity`; `com.iqoo.secure/...BgStartUpManager`. Also set "High background power consumption" + "Unrestricted" battery on A13+. — https://raw.githubusercontent.com/judemanutd/AutoStarter/master/autostarter/src/main/java/com/judemanutd/autostarter/AutoStartPermissionHelper.kt — *as_of 2026-07* — confidence high
- **OnePlus (legacy OxygenOS) deep-link** *(confidence: medium)* — `com.oneplus.security/com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity` or action `com.android.settings.action.BACKGROUND_OPTIMIZE`; newer OnePlus (OxygenOS 12+) uses ColorOS/`com.oplus.*`; disable Deep optimization/Adaptive Battery + Sleep standby optimization. — https://dontkillmyapp.com/oneplus — *as_of 2026-07*
- **Samsung One UI 6.0 guarantee** — since One UI 6.0, FGS of apps targeting Android 14 "will be guaranteed to work as intended" if built per Android's FGS API policy (announced 07/2024, w/ Google). Fix = add to "Never sleeping apps" (NOT "Sleeping/Deep sleeping"), disable Adaptive Battery / "Put unused apps to sleep." Battery deep-link `com.samsung.android.lool/com.samsung.android.sm.battery.ui.BatteryActivity`. — https://dontkillmyapp.com/samsung — *as_of 2024-07 announcement, page current 2026-07* — confidence high
- **Standard battery-opt intents (fallback)** — `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` (list, any app, no justification) vs `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (direct dialog, Play-restricted); check `PowerManager.isIgnoringBatteryOptimizations()`. — https://developer.android.com/training/monitoring-device-state/doze-standby — *as_of 2026-07* — confidence high
- **Play direct-dialog exemption categories** *(confidence: medium; see correction)* — messaging/calling that can't use FCM, enterprise VOIP, Safety apps, task-automation. A transit alarm plausibly maps to Safety/task-automation, but the low-risk choice is the non-restricted list screen. — https://developer.android.com/training/monitoring-device-state/doze-standby — *as_of 2026-07*
- **A14 location FGS requirement** — `FOREGROUND_SERVICE_LOCATION` + `ACCESS_FINE/COARSE_LOCATION` + `foregroundServiceType="location"`; missing → throws at `startForeground()`. — https://developer.android.com/develop/background-work/services/fgs/service-types — *as_of 2026-07* — confidence high
- **dontkillmyapp worst offenders** *(confidence: medium)* — Huawei, Xiaomi, OnePlus, Samsung, Oppo/Vivo/Realme (all high-share in India); stock/Nokia/Motorola "good." — https://dontkillmyapp.com/ — *as_of 2026-07*

### Disputed / corrections
- **"A15+ CANNOT start a location FGS from BOOT_COMPLETED"** — *WRONG on the highest-stakes claim.* `location` is NOT on the Android 15 BOOT_COMPLETED ban list (banned: dataSync, camera, mediaPlayback, phoneCall, mediaProjection, + microphone since A14). **Correction:** GeoWake CAN start a location FGS from BOOT_COMPLETED on Android 15, provided `ACCESS_BACKGROUND_LOCATION` is granted (BOOT_COMPLETED runs backgrounded → the while-in-use gate applies). The real A15 gotcha: if the service is typed **`dataSync`** it IS blocked from boot — type it `location`. Do NOT re-architect on the false premise. — https://developer.android.com/about/versions/15/behavior-changes-15
- **"ACCESS_BACKGROUND_LOCATION requirement is an A15 change"** — *mislabeled.* The while-in-use restriction predates Android 15 (general foreground-service-types rule). Keep the requirement, don't gate it on "targeting API 35." — https://developer.android.com/develop/background-work/services/fgs/service-types
- **Play exemption category list** — 'enterprise VOIP' is not a distinct category (VoIP is under messaging/calling); the omitted 4th official category is **"Peripheral device companion app."** The four are: (1) messaging/chat/calling that can't use FCM, (2) Safety app, (3) Task automation app, (4) Peripheral device companion app. Overall risk guidance (prefer the non-restricted list screen) still sound. — https://developer.android.com/training/monitoring-device-state/doze-standby

### Open questions
- Exact `com.oplus.*` ComponentNames for App-battery-management/auto-launch on current ColorOS 15 / OxygenOS 15 (needs on-device dumpsys).
- Whether HyperOS 2 exposes a stable intent to the per-app "Background autostart" screen distinct from the legacy `AutoStartManagementActivity`.
- Whether a transit alarm can safely use `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (direct dialog) under current Play review as "Safety"/"task-automation" vs staying on the safer list screen.
- Current dontkillmyapp per-OEM kill scores for HyperOS 2 / ColorOS 15 / Funtouch 15 / One UI 7.
- Production pattern: wrap OEM ComponentNames in try/catch, resolve via `queryIntentActivities` first (Android 11+ package visibility `<queries>` may be needed), fall back to `ACTION_APPLICATION_DETAILS_SETTINGS`. No reliable programmatic way to read OEM autostart state (design onboarding as a guided checklist + health-check that infers failure).

---

## Provenance & coverage note

- **Source:** `~/.claude/projects/-home-raed-Projects-WakePoint/<session>/subagents/workflows/wf_1d6eab33-1ee/journal.jsonl` — 17 research result objects (each with `topic`/`summary`/`keyFacts`) + 17 adversarial `verify` objects (each with `verdict`/`confirmedClaims`/`disputed`/`missingCriticalInfo`), paired by topic. Session `as_of` = 2026-07-18.
- **Every `source_url` above is reproduced verbatim from the journal.** Where a fact was flagged unverified / mis-sourced / stale by the adversarial pass, that is carried into the "Disputed / corrections" subsection rather than silently dropped.
- **Only genuinely-missing topic:** `plugin_fbs_geo` (flutter_background_service + geolocator), which the journal contains only as a probe placeholder — its substantive payload was never sent (§8).
- A prior scribe run's closing note wrongly listed V_LINE speeds (§15), Maps pricing (§9), and the DPDP verdict (§12) as "not delivered" — that was an input-truncation artifact of that run; all three are present in the journal and fully documented here.
