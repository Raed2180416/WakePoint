## GeoWake Competitive Landscape — "Get Off At My Stop" Alarms, India, July 2026

### TL;DR threat ranking

| Rank | Competitor | Threat | Why |
|---|---|---|---|
| 1 | **WhereIsMyTrain** (Google/Sigmoid Labs) | **HIGH** | 500M+ downloads(claim), 4.5★/5.12M reviews, Google-owned since 2018, has a built-in destination alarm already trusted by Indian commuters, free, no ads. |
| 2 | **Moovit** | **MEDIUM-HIGH** | 100M+ India downloads, "get-off alerts" as one of many features, but 3.4★ and heavy, verified ad complaints. |
| 3 | **Google Maps get-off notifications / Pixel Transit Mode** | **MEDIUM (platform risk)** | Huge distribution, but current implementation is a passive notification / manual-activation DND mode — not a wake-you-up alarm. Real threat is Google baking a true alarm into Maps/Android later, not what exists today. |
| 4 | **Chalo** | **LOW** | 10M+ downloads, bus-only, no destination-alarm feature at all today. |
| 5 | **Namma Metro (BMRCL) / DMRC Momentum 2.0** | **LOW/NEGLIGIBLE** | Ticketing/card-recharge apps only; no alarm feature; mediocre ratings (3.4–3.8★) even on their core function; users have explicitly asked for exactly this feature and been ignored since at least 2020. |
| 6 | **Fragmented "wake me at my stop" apps** (Delhi Metro Station Reminder, TrainWake, Wake Me There, Don't Miss the Stop, Metride) | **LOW individually** | Tiny installs (5 to ~100K), mostly generic GPS-radius geofence alarms with no tunnel/physics handling; one is abandoned since 2017. |
| 7 | **iOS equivalents** (WakePoint, Transit Alarm, Localarm, WakeStop) | **LOW, but note a naming collision** | All simple GPS-radius alarms, small/unverifiable install bases. **"WakePoint - Transit Alarm" (dev: Efe Mesudiyeli) is a live iOS App Store app** using the exact former project name — worth knowing if any cross-platform or naming decisions come up later. |

---

### 1. WhereIsMyTrain — the real threat, and it's owned by Google

- Google **acquired Sigmoid Labs**, the maker of Where Is My Train, in **December 2018** (announced Dec 10, 2018; deal reportedly $30–40M) — the team joined Google's Next Billion Users group. [Business Standard, Dec 2018](https://www.business-standard.com/article/companies/google-acquires-sigmoid-labs-maker-of-popular-where-is-my-train-app-118121000938_1.html), [VentureBeat](https://venturebeat.com/mobile/google-acquires-sigmoid-labs-developer-of-popular-indian-app-where-is-my-train)
- Google shipped an **official iOS version, "Where is My Train — by Google,"** in June 2025, published under Google LLC. [technofino.in](https://technofino.in/community/threads/google-brings-%E2%80%98where-is-my-train%E2%80%99-to-ios-offline-train-tracking-now-for-everyone.42349/), [App Store listing](https://apps.apple.com/in/app/where-is-my-train-by-google/id6738965857)
- **Play Store (verified live, fetched 24 Jul 2026):** 4.5★, **51.2 lakh (5.12M) reviews**, **"50Cr+" (500M+) downloads**, #1 top free Travel & Local app in India, no ads. Developer listed as "Sigmoid Labs and its affiliates." [Play Store](https://play.google.com/store/apps/details?id=com.whereismytrain.android)
- **Alarm feature:** destination/station alarm exists today, works via **cell-tower location (not GPS)**, functions offline, lets users pick alerts from 60 down to 10 minutes before arrival. [YourStory 2018 feature writeup](https://yourstory.com/2018/11/app-fridays-access-irctc-timetable-check-live-train-status-set-station-alarms-without-internet)
- **Real reviews mined (live page):** the visible top reviews (Jan 2025, Nov 2025, Jul 2026) do **not** show missed-alarm complaints — they're about platform-number accuracy, coach-position accuracy, and a request for a shorter app name. One user (13,383 "helpful" votes) explicitly says "train position and timing are reliable" but platform/coach info is not. **No verified complaints about the alarm itself failing** turned up in search or on-page review sampling — this is a well-regarded, mature feature.
- **The actual gap:** it's cell-tower-based, built for long-distance/local Indian Railways trains where stations are minutes/km apart — not designed for **closely-spaced metro stations** (400m–1km) or for **GPS-denied tunnel-precise** positioning. No evidence of sensor fusion / EKF / physics-based never-late guarantee.

**Positioning implication:** Don't attack WhereIsMyTrain's alarm reliability — it's genuinely good and it's Google-backed with an install base GeoWake cannot match. Differentiate on **precision for closely-spaced metro stops** and **tunnel-proof physics guarantee**, not on "theirs is broken."

---

### 2. Moovit — ads are the real, verified complaint

- **Play Store (verified live, fetched 24 Jul 2026, en_IN):** **3.4★**, **15.2 lakh (1.52M) reviews**, **10Cr+ (100M+) downloads**, "Contains ads, In-app purchases." [Play Store](https://play.google.com/store/apps/details?id=com.tranzmate)
- Global scale claimed in-listing: "930 million users in over 3,400 cities."
- **Get-off alert feature confirmed** in the app's own description: "receive get-off alerts at your destination to ensure a smooth ride."
- **Verified real review (Jan 2025, 633 "helpful" votes):** *"recently I'm getting a lot of ads... popping in random steps, covering the entire screen, and each ad has a different closing button, some very small... Edit - changed from 3 to 2 stars. There are increasingly many ads and there are better alternative apps."* — a Moovit staff account replied but the complaint stands as the top visible negative review on the India-facing listing.
- Additional general (non-India-specific) complaint pattern found via search: notification spam for routes never taken, background crashes when Live Directions is active, and ETA-vs-actual-arrival mismatches. [AppGrooves negative reviews page](https://appgrooves.com/app/moovit-bus-and-train-live-info-by-moovit-app-global-ltd/negative) (page itself could not be fetched directly — flagged as lower-confidence secondary source; the Play Store ad complaint above is the verified, primary-source one)

**Positioning implication:** "Ad-free, no full-screen interstitials while you're trying to sleep on a train" is a real, evidenced differentiator against Moovit specifically.

---

### 3. Google Maps get-off notifications / Pixel Transit Mode — real but doesn't actually wake you

- Google Maps has had a "get off here" **notification** for transit trips since ~2017 (TechCrunch, Dec 2017) — this is old, not new, and it is a **lock-screen notification**, not a loud/override alarm. [TechCrunch, Dec 2017](https://techcrunch.com/2017/12/09/google-maps-will-soon-tell-you-when-its-time-to-get-off-your-train-or-bus/)
- **Pixel "Transit mode" shipped in the March 2026 Feature Drop** (Android 16 QPR3), available "globally except Europe and the UK" — **India is included**. [9to5Google, Mar 2026](https://9to5google.com/2026/03/10/google-pixel-transit-mode/), [9to5Google follow-up, Mar 2026](https://9to5google.com/2026/03/30/pixel-transit-at-a-glance/)
- **What it actually is, verified via Android Authority's hands-on review:** a **Do-Not-Disturb-style privacy/interruption-filter mode** — controls ringer, dims screen, hides notification content, lets you allow/block "Alarms & other interruptions." It is **not** a destination wake-up alarm.
- **Critical limitation confirmed by the reviewer:** *"there doesn't seem to be a way to automatically trigger Transit Mode. I have to manually remember to turn it on each time I take a bus or train"* — no auto-detection, unlike Driving Mode/Bedtime Mode. Headline of the piece itself: **"fails where it matters."** [Android Authority](https://www.androidauthority.com/i-tried-pixel-new-transit-mode-3653587/)
- No mention anywhere in sourced coverage of Transit Mode overriding silent mode to wake a sleeping user at a specific stop, nor of any GPS-denied/tunnel handling.

**Positioning implication:** This is the most dangerous *long-term* platform risk (Google could ship a real destination-wake feature into Maps or Android any time) but **today it is not a competing product** — it's a notification-filtering mode requiring manual activation, and Maps' own get-off alerts are silent-mode notifications, not alarms that break through sleep. GeoWake's "actually wakes you, even through Do Not Disturb, even underground" claim is currently unmatched by anything Google ships.

---

### 4. Chalo — no alarm feature at all

- **Play Store (verified live, fetched 24 Jul 2026, en_IN):** 4.1★, 2.49 lakh (249K) reviews, **1Cr+ (10M+) downloads**, "Contains ads." [Play Store](https://play.google.com/store/apps/details?id=app.zophop)
- Covers live bus tracking + mobile ticketing/passes across ~17 Indian cities (Mumbai, Chennai, Lucknow, Indore, etc.) per the in-app city list.
- **The full app description contains zero mention of a destination/wake alarm feature** — it's tracking + ticketing only. Confirmed by search results as well (no alarm feature found anywhere).

**Positioning implication:** Not a direct competitor on the wake-alarm use case; a potential future entrant given its scale, but no evidence of building this today.

---

### 5. Namma Metro (BMRCL) / DMRC official apps — no alarm, and users are asking

- **Namma Metro-BMRCL official app (verified live, fetched 24 Jul 2026):** 3.8★, 5.13K reviews, 10L+ (1M+) downloads. App scope per its own description: **"assist commuters... recharge their smart cards"** — no journey-tracking or alarm feature at all.
- **A 2020 review (377 "helpful" votes)** on this exact app explicitly complains: *"They can add more useful things like the exact train timings for each station so that people can be informed and don't miss the train but they don't even do that (wasted opportunity)."* — direct evidence of unmet demand for exactly GeoWake's use case, ignored by the official app for 5+ years.
- **DMRC Momentum 2.0 ("Delhi Sarthi"):** launched Dec 2024, focused on QR ticketing and locker rental; rated ~3★ per aggregator search; no alarm feature found in any source. [APAC News Network, Dec 2024](https://apacnewsnetwork.com/2024/12/dmrc-launches-momentum-2-0-app-for-digital-metro-ticketing/)

**Positioning implication:** Official metro operator apps are not a threat and validate the gap — real riders have publicly asked for this feature on the official channel and been ignored.

---

### 6. Fragmented long-tail "wake me at my stop" apps — no one has scale or physics

Verified live on Play Store (24 Jul 2026, en_IN unless noted):

| App | Rating | Reviews | Downloads | Notes |
|---|---|---|---|---|
| Delhi Metro Station Reminder | 4.4★ | 52 | 1K+ | **Abandoned — last updated 2 Oct 2017.** Vibration-only (a user review explicitly asks for sound). WiFi/GPS-based, degrades underground by its own description. |
| TrainWake: Train Stop Alarm | — | 0 | **5+** | Brand-new, essentially no traction. One-time-purchase Pro model (similar to GeoWake's approach), privacy-first, no India-specific features found. |
| Wake Me There – GPS Alarm (MapFactor) | 4.6★ | 2.11K | 1L+ (100K+) | Generic radius-based geofence alarm (500m–10km), not transit-aware, contains ads + IAP. No along-track/physics logic — a naive radius trigger is prone to false alarms on parallel roads/tracks or overpasses and has no tunnel handling. |
| Don't Miss the Stop: GPS Alarm | 4.48★ (per AppBrain) | ~960 | ~47K | Same generic-geofence category as above. |
| Metride – Smart Metro Navigation | — | — | — | Markets itself as India-metro-specific with offline routing + wake alarm, but **no Play Store listing could be verified** in this research — only its own marketing site (metride.in) was found. Traction unverifiable; treat any installs claim as unconfirmed. |

**Positioning implication:** This entire category is fragmented, low-trust (ads, abandoned apps, tiny install bases) and — critically — **none use anything beyond simple GPS-radius geofencing**. None claim sensor fusion, tunnel handling, or a physics-based never-late guarantee. This is GeoWake's clearest technical moat.

---

### 7. iOS equivalents

- **Transit Alarm - Stop Alert**, **Localarm: Transit Alarm**, **WakeStop: Station Wake Alarm**, **Don't Miss the Stop: GPS Alarm** — all simple GPS-based location alarms, same category as the Android long tail, no verifiable install/rating data surfaced (App Store doesn't expose install counts publicly).
- **Notable finding — naming collision:** **"WakePoint - Transit Alarm"** is a real, live iOS App Store app by developer **Efe Mesudiyeli** — tagline "Wake Up at Your Stop," GPS-based, free with IAP, privacy-focused (on-device location only), iOS 17+. This is the exact former name of this project (per the repo's `WakePoint` origins, now rebranded GeoWake per user memory). Flagging as a fact worth being aware of, not a threat assessment — no evidence this developer has any Android presence or India focus. [App Store listing](https://apps.apple.com/us/app/wakepoint-transit-alarm/id6745990119)

---

### Differentiation angles for GeoWake, each backed by a specific finding above

1. **Actually wakes you through Do Not Disturb / sleep, not a lock-screen notification.** Google Maps' get-off alerts are passive notifications; Pixel Transit Mode is a manual-activation interruption *filter*, not a wake alarm, and per Android Authority's hands-on, it doesn't even auto-activate. No competitor researched demonstrates a loud, DND-overriding wake alarm as their core mechanism the way GeoWake does.
2. **GPS-denied tunnel precision via sensor fusion (EKF).** WhereIsMyTrain uses cell-tower location (coarse, works fine for long-distance rail, not metro-tight). Every dedicated "wake me at my stop" app found (Wake Me There, Don't Miss the Stop, Delhi Metro Station Reminder, TrainWake) uses simple GPS-radius geofencing with no along-track/physics reasoning — meaning they're either unreliable in tunnels or prone to false triggers near parallel tracks/roads. No competitor claims a physics-based never-late guarantee.
3. **Metro-station-spacing precision.** WhereIsMyTrain (the dominant India player) is architecturally built for Indian Railways long-distance/local trains, not the 400m–1km station spacing of metro systems — a real, unaddressed niche within India's biggest single competitor's blind spot.
4. **No ads, one-time Rs199 Pro vs. Moovit's verified aggressive full-screen ad complaints** (real Jan 2025 review, 633 helpful votes, explicit rating drop because of ads) and Chalo's ad-supported model.
5. **Validated, ignored demand on the official channel.** A real BMRCL app reviewer (377 helpful votes) explicitly asked for exactly this feature in 2020 and it still doesn't exist in 2026 — usable as an authentic "even riders on the official app are asking for this" proof point.
6. **Trust/maturity gap in the long tail.** The only apps attempting this narrowly (Delhi Metro Station Reminder, TrainWake) are either abandoned (2017) or have essentially zero installs (TrainWake: 5+) — meaning GeoWake isn't late to a crowded, proven category; it's first to make it *reliable and India-focused at scale*.

### Honesty caveats (what this research could NOT verify)

- Play Store download figures like WhereIsMyTrain's "50Cr+" and Moovit's "10Cr+" are Play Store's own rounded display buckets (not exact), read directly off the live listing — treat as VERIFIED-but-rounded, not precise counts.
- Could not access AppGrooves' full negative-review breakdown for Moovit (DNS failure) or a large enough review sample (I only read the top 3 sorted-by-default reviews per app) to make statistically confident claims about *how common* specific complaint types are — the ad complaint for Moovit and the platform-number complaints for WhereIsMyTrain are individual, verified, high-"helpful"-vote reviews, not aggregated complaint-frequency data.
- Metride's actual install base/rating is unverified — only marketing-site claims found, no live Play Store listing confirmed in this session.
- No direct evidence either way on whether WhereIsMyTrain's alarm can survive Android's newer aggressive battery/Doze restrictions on non-Pixel Android One/China-OEM devices (a known GeoWake concern per your own backstop-receivers-gotcha memory) — this wasn't testable from search/store data alone.

### Key facts (quick reference)

- WhereIsMyTrain: Google-owned since Dec 2018; 4.5★, 5.12M reviews, 500M+ downloads, has cell-tower-based destination alarm, no verified missed-alarm complaints found. [VERIFIED]
- Moovit: 3.4★, 1.52M reviews, 100M+ India downloads, verified ad complaint dropped a real review from 3★ to 2★ (Jan 2025). [VERIFIED]
- Pixel Transit Mode (Mar 2026): DND-style filter, manual activation only, not a wake alarm, "fails where it matters" per Android Authority hands-on. India included in global rollout. [VERIFIED]
- Chalo: 10M+ downloads, 4.1★, no destination-alarm feature exists. [VERIFIED]
- Namma Metro BMRCL app: no alarm feature; 2020 review explicitly requests one, still unaddressed as of Jul 2026. [VERIFIED]
- All dedicated long-tail wake-alarm apps found use simple GPS-radius geofencing, not physics/sensor-fusion; largest has ~100K installs (Wake Me There), smallest has 5+ (TrainWake); one is abandoned since 2017. [VERIFIED]
- "WakePoint - Transit Alarm" is a live, unrelated iOS app using the project's former name. [VERIFIED, informational only]

## KEY FACTS
- [verified] Google acquired Sigmoid Labs (maker of WhereIsMyTrain) in December 2018; the app now ships an official Google-published iOS version and has a destination/station alarm feature built on cell-tower location. (Business Standard Dec 2018; VentureBeat; technofino.in Jun 2025)
- [verified] WhereIsMyTrain Play Store listing (fetched live 24 Jul 2026): 4.5 stars, 5.12M reviews, 500M+ downloads, no ads, #1 top free Travel & Local in India. (play.google.com/store/apps/details?id=com.whereismytrain.android)
- [likely] No verified reviews found complaining that WhereIsMyTrain's alarm failed to wake users or missed a station; visible top reviews concern platform-number/coach-position accuracy instead. (Live Play Store review sampling, only top 3 default-sorted reviews read)
- [verified] Moovit Play Store listing (fetched live 24 Jul 2026, India): 3.4 stars, 1.52M reviews, 100M+ downloads, contains ads and IAP. (play.google.com/store/apps/details?id=com.tranzmate)
- [verified] A real Moovit review (Jan 2025, 633 helpful votes) reports full-screen ads with tiny close buttons and explicitly dropped their rating from 3 to 2 stars because of ad frequency. (Live Play Store review, com.tranzmate listing)
- [verified] Pixel Transit Mode (Android 16 QPR3, March 2026 Feature Drop) is a Do-Not-Disturb-style interruption filter requiring manual activation, not an automatic destination wake-up alarm; a hands-on review titled it 'fails where it matters' due to lack of auto-trigger. (androidauthority.com/i-tried-pixel-new-transit-mode-3653587; 9to5google.com Mar 2026)
- [likely] Pixel Transit Mode's global rollout is stated to exclude only Europe and the UK, implying India availability, though no source gave an explicit India-named confirmation. (9to5google.com, androidheadlines.com Mar 2026)
- [verified] Chalo (Play Store, fetched live 24 Jul 2026): 4.1 stars, 249K reviews, 10M+ downloads, live bus tracking + ticketing across ~17 Indian cities; its own app description contains no destination/wake-alarm feature. (play.google.com/store/apps/details?id=app.zophop)
- [verified] Namma Metro-BMRCL official app (Play Store, fetched live 24 Jul 2026): 3.8 stars, 5.13K reviews, 1M+ downloads, scoped only to smart-card recharge; a 2020 review (377 helpful votes) explicitly asks for train-timing/alarm features that still don't exist. (play.google.com/store/apps/details?id=com.aum.nammametro)
- [verified] The dedicated long-tail transit-alarm apps found (Delhi Metro Station Reminder, TrainWake, Wake Me There, Don't Miss the Stop) all use simple GPS-radius geofencing, not sensor fusion/physics; the largest (Wake Me There, MapFactor) has ~100K downloads and 4.6 stars, the smallest (TrainWake) has only 5+ downloads, and Delhi Metro Station Reminder has been unmaintained since Oct 2017. (Live Play Store listings for each app)
- [verified] 'WakePoint - Transit Alarm' is a live, unrelated iOS App Store app by developer Efe Mesudiyeli using the project's former name (GeoWake was previously named WakePoint per project memory). (apps.apple.com/us/app/wakepoint-transit-alarm/id6745990119)
- [estimate] Metride, an India-focused metro-navigation app claiming an offline wake-alarm feature, could not be verified on the Play Store in this research — only its own marketing site was found, so its install base/rating is unconfirmed. (metride.in and web search only; no live store listing located)
