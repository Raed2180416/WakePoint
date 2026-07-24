# Zero-Budget Marketing Playbook — GeoWake (India Transit Wake-Up Alarm), 2026

**Scope note on method:** Live Reddit fetching was blocked in this environment (`reddit.com` and `old.reddit.com` both return fetch errors), so exact current rule text for r/bangalore, r/india, r/delhi, r/mumbai could not be quoted verbatim. Recommendations for those subreddits are marked **[ESTIMATE — verify live before posting]** and are based on well-documented general Reddit norms plus secondary reporting on these specific communities. Everything else is sourced to primary docs (Google, Android Developers) or named secondary sources with dates where available.

---

## PART 1 — ASO: What actually moves ranking/conversion in 2026

### Verified facts (Google primary sources)
- **Title cap: 30 characters. Short description cap: 80 characters.** Enforced by the Play Console field itself. — [Play Console Help: Store listing best practices](https://support.google.com/googleplay/android-developer/answer/13393723?hl=en)
- Title and short description **may not** contain promotional terms ("Free", "No Ads"), ranking claims ("#1", "Best of Play"), pricing, or emojis/ALL CAPS abuse. — same source.
- **In-App Review API**: quota-limited (roughly ~1/month per user, undocumented exact value, "subject to change"), must not gate the prompt on prior satisfaction ("Would you rate us 5 stars?" is explicitly banned), must not be manually triggered by a button — should fire after a genuine positive moment (e.g., successfully woken up in time). — [Android Developers: In-App Review API](https://developer.android.com/guide/playcore/in-app-review)
- **Incentivizing ratings/reviews/installs is banned outright** ("offering money, goods, or equivalent in exchange for a rating/review/install" — policy violation, can trigger account-level enforcement). Non-incentivized in-app prompts, timed appropriately, are fine. — [Play Console Help: User Ratings, Reviews, and Installs](https://support.google.com/googleplay/android-developer/answer/9898684?hl=en)
- Google's anti-spam systems blocked **160 million spam ratings/reviews** in 2025 using GenAI detection — meaning fake-review schemes (buy-a-review Telegram groups, click-farms) are higher-risk than ever, not just against policy but increasingly *caught*. — same source area, corroborated by [TechRadar, "Google rejected nearly two million Android apps...2025"](https://www.techradar.com/pro/security/google-rejected-nearly-two-million-android-apps-and-blocked-more-than-80-000-developer-accounts-from-google-play-in-2025).
- **Custom store listings**: up to 50 per app, each with its own creative + unique deep link + analytics — usable to build a listing variant per city (e.g., "GeoWake for Bangalore Metro") for paid or organic campaign attribution without any spend. — [MobileAction: Custom store listings 2026 guide](https://www.mobileaction.co/blog/custom-store-listings-on-google-play/)
- **Promotional content (formerly "LiveOps")**: content types are Offer, Time-Limited Event, Major Update, Pre-Registration; during Google's closed beta, participating apps averaged **+5% active users and +4% revenue** vs. non-participants. Requires a 1024×500 feature graphic. This is a free, built-in surface — GeoWake should use "Major Update" cards every release and consider a "Time-Limited Event" around exam season / monsoon (commute disruption spikes). — [Google Play Console: Promotional content](https://play.google.com/console/about/programs/promotionalcontent/), [ApptWeak LiveOps best practices](https://www.apptweak.com/en/aso-blog/what-are-google-play-liveops-best-practices-examples)
- **Featuring**: Google Play has a "Featuring Nomination" form for newly-launched apps, plus a monthly editorial "New apps we love" India-specific banner. Free to submit; no guarantee. — [ApptWeak: How to get featured 2026](https://www.apptweak.com/en/aso-blog/how-to-get-your-app-featured-on-the-app-store)
- **Localization**: Play Console supports store listings in up to 12 Indian languages. 60% of Indians are not Hindi-first speakers, so a Hindi-only localization undersells the South/East. — [ApptWeak: How to Localize Your App for India](https://www.apptweak.com/en/aso-blog/how-to-localize-your-app-in-india)
- India Android penetration: **~95%** of the smartphone base — validates Android-first, and means near-zero opportunity cost skipping iOS for now. — [Statista via search aggregation, 2024–2026 figures](https://www.statista.com/statistics/262157/market-share-held-by-mobile-operating-systems-in-india/)

### Estimates / secondary-source claims (flag as such)
- "Keyword relevance in title/short description remains the strongest indexing signal, roughly one exact-match keyword per 250 characters in the long description before it reads as stuffing" — **[ESTIMATE, ASO-vendor blogs, not Google-confirmed]**: [ApptWeak: Play Store keyword research 2026](https://www.apptweak.com/en/aso-blog/play-store-keyword-research), [MobileAction: Google Play ranking factors](https://www.mobileaction.co/blog/google-play-store-ranking-factors/).
- Ranking also weighs **conversion rate, retention, Android Vitals (crash rate/ANR)** — directionally credible (matches Google's public stance on quality signals) but exact weighting is proprietary/estimated by vendors. **[ESTIMATE]**

### ASO action items for GeoWake
1. Title: pick ONE primary keyword combo that fits 30 chars — e.g. `GeoWake: Metro & Bus Alarm` (~26 chars) rather than a brand-only title. Brand name alone wastes the highest-weight field.
2. Short description (80 chars): lead with the outcome, not the feature — e.g. `Never miss your metro stop again. Wakes you before you're late.` (66 chars).
3. Localize store listing into Hindi + at minimum the launch city's regional language (Kannada if Bangalore-first, given Namma Metro).
4. Wire the in-app review prompt to fire only after a *successful wake* event, never after install or a skipped/failed one.
5. Submit for Featuring Nomination at launch; also submit "Major Update" promotional content on every meaningful release.
6. Build 2–3 custom store listings (one per target metro city) with unique deep links so you get free per-city install attribution without any ad spend.

---

## PART 2 — Organic community channels

### Reddit — realistic assessment
- General platform norm across virtually all subreddits: the **"90/10 rule"** — no more than ~10% of a user's total activity should be self-promotional, and posting only your own links reads as spam regardless of content quality. Cross-posting identical promo copy to multiple subs is treated as coordinated spam. — [multiple 2026 vendor guides citing Reddit's Content Policy Rule 2](https://redship.io/blog/reddit-self-promotion-rules), [Reddit Content Policy framing via secondary source](https://www.wisp.blog/blog/the-anti-spam-playbook-how-to-promote-your-business-on-reddit-without-getting-nuked)
- r/bangalore is reported as one of the **oldest and largest India city subreddits** (~8.9 lakh / 890k members as of the article), active since ~2008 — high-value community if you can post as a genuine solved-my-own-problem story rather than an ad. — [Deccan Herald: "r/bangalore reddit forum enters its 17th year"](https://www.deccanherald.com/india/karnataka/bengaluru/r-bangalore-reddit-forum-enters-its-17th-year-3425307)
- **[ESTIMATE — verify live before posting]**: r/india, r/bangalore, r/mumbai, r/delhi, r/chennai, r/pune, r/hyderabad, r/kolkata each maintain their own rules pages (`reddit.com/r/<sub>/about/rules`) that must be checked immediately before any post — city subs vary widely, some ban "advertising" outright, others tolerate genuinely useful local tools especially with a `[Self-Promo]` or similar flair and prior karma in the community. Do not mass cross-post identical text.
- Practical, policy-safe approach: post as a **redditor solving their own problem** ("Built a free app that wakes me up before my metro stop because I kept overshooting — sharing in case useful to others here"), disclose you're the developer, engage in comments for days afterward, and only do this once per subreddit per major milestone (launch, then maybe one update months later). Never use multiple accounts.
- Best target subs by city (metro-relevant): r/bangalore (Namma Metro), r/delhi + r/Delhi_Ig (Delhi Metro), r/mumbai (Mumbai Local), r/chennai, r/pune, r/hyderabad, r/india (national, hardest to break into, largest reach). **[ESTIMATE on exact subreddit names/rules — confirm each before posting]**

### X/Twitter
- Official metro accounts (@OfficialDMRC, @nammametro) and fan/community accounts (@delhimetrofan, @NammaMetro_) run active hashtag ecosystems — **#DelhiMetro**, **#NammaMetro**, **#BengaluruMetro** are used by commuters for real-time updates and complaints, which is exactly the moment-of-pain audience for GeoWake. — [X search results for hashtags](https://x.com/hashtag/delhimetro), [@NammaMetro_](https://x.com/NammaMetro_), [@OfficialDMRC](https://x.com/officialdmrc?lang=en)
- Tactic: reply helpfully (not promotionally) to delay/complaint threads under these hashtags with genuine commiseration, occasionally with a soft mention once you have credibility; quote-tweet your own launch thread tagged with the hashtag once.
- Note: #NammaMetroHindiBeda shows these hashtag communities can be politically charged (language politics) — steer clear of anything adjacent; stay strictly transit-utility framed. — [Wikipedia: Anti-Hindi agitations of Karnataka](https://en.wikipedia.org/wiki/Anti-Hindi_agitations_of_Karnataka)

### Telegram / WhatsApp commuter groups
- Precedent exists: Bengaluru commuters started an unofficial **Telegram group "Friends of BMTC"** for bus-route info with ~2,000 active users, itself fed by a WhatsApp group with BMTC officials — proof this kind of grassroots, transit-specific group exists and is receptive to genuinely useful tools. — [Deccan Herald: "Bengalureans start Telegram group for bus route enquiries"](https://www.deccanherald.com/amp/story/india%2Fkarnataka%2Fbengaluru%2Fb-lureans-start-telegram-group-for-bus-route-enquiries-1230324.html)
- **WhatsApp Channels** (Meta's one-way broadcast feature, launched 2023, still free for businesses as of 2025–26 sources) is a zero-cost way to build a direct-push audience — post short "just landed" or "new city added" updates. — [Sinch: WhatsApp Channels for businesses](https://sinch.com/blog/whatsapp-channels-marketing-companies/), [CampaignMitra 2026 guide](https://campaignmitra.com/blog/low-cost-whatsapp-marketing-india-2026/)
- Action: find and join city-specific commuter Telegram/WhatsApp groups (BMTC/Namma Metro, Delhi Metro, Mumbai Local groups) as a genuine member first; only mention the app when directly relevant to a thread about missing stops/oversleeping.

### Instagram Reels / YouTube Shorts — what converts
- 2026 hook-format data (from a 50M-ad retention study, cited by a marketing vendor) ranks **Specific-Outcome hooks (45%)**, **POV-Realism (42%)**, and **Unpopular-Opinion (38%)** as top-converting hook types — each pairs a pattern-interrupt visual with an emotional trigger line. **[secondary-source claim, vendor-reported, treat as estimate]** — [OpusClip: 50+ Instagram hooks 2026](https://www.opus.pro/research/best-video-hooks-instagram)
- The format winning in 2026 is explicitly **not** high-production/sales-hook style — it's described as "a friend showing you something cool on their phone," i.e. raw screen-recording style demos outperform polished ads for app marketing. — [same aggregated search synthesis, multiple 2026 vendor sources]
- Reels sweet spot: 15–30s for hook-driven content; Shorts now tolerate up to 90–180s after a Dec 2025 cap change to 3 minutes. — [PostEverywhere: Shorts vs Reels 2026](https://posteverywhere.ai/blog/youtube-shorts-vs-instagram-reels)
- Concrete Reel/Short scripts for GeoWake (POV-realism format, screen-recording style):
  1. "POV: you fell asleep on the metro and your phone woke you up exactly 2 stops before yours" — show the actual alarm firing on a real ride.
  2. "I built this because I kept missing my stop on [metro line]" — founder-story hook (Specific Outcome + authenticity).
  3. "Unpopular opinion: your phone's default alarm is useless for commutes" — Unpopular-Opinion hook leading into the GPS-denied-tunnel problem.
- Thumb-stop / hook-rate benchmark: a Reel opening under ~20% hook rate (viewers staying past first 2–3s) is not salvageable by later edits — front-load the payoff. **[vendor-estimate]** — [Opus/CaptionStudio synthesis](https://captionstudio.in/blog/instagram-reel-hooks-2026.html)

### College ambassador programs
- Structurally these exist at scale in India (MyGov, Naukri Campus Squad, Microsoft Learn Student Ambassador, Gemini Student Ambassador) — pattern is unpaid/goodie-and-certificate compensated, 4–6 hrs/week, remote-friendly. — [Naukri: Top Student Ambassador Programs](https://www.naukri.com/campus/career-guidance/student-ambassador-programs-sap), [GUESSS India Campus Ambassador](https://guesssindia.in/campus-ambassador-program/)
- For GeoWake at zero budget: recruit 3–5 students per metro city (commuting students are a core user segment — late for early lectures) via a lightweight "Campus Ambassador" post in college WhatsApp/Telegram groups, offering a certificate + shoutout + (if funds allow later) Pro unlock codes, not cash. This is the *cheapest* channel structurally but slow to execute solo — needs a simple one-page sign-up form and a referral-code system to track it.

### PR outlets covering Indian startups for free
- **YourStory**: free to submit via "Submit Your Story" form or email `editorial@yourstory.com` (subject: "Story Request"). Eligibility bar: registered entity, ~4–6 months old, some market validation/MVP+early users — not idea-stage. — [YourStory submission guidance, aggregated](https://newsweekindia.in/where-to-submit-your-startup-story-in-india-a/)
- **Inc42**: data/metrics-driven pitch (funding, user growth numbers) via inc42.com. — [Inc42](https://inc42.com/)
- **MediaNama**: send tips/company updates to press contact; serious pitches to founder Nikhil Pahwa directly. MediaNama's beat is internet governance/privacy/data — a strong angle for GeoWake given its DP-protected opt-in mobility data pipeline (zero egress currently) is genuinely on-topic for them. — [MediaNama Contact Us](https://www.medianama.com/contact-us/)
- **OfficeChai**: workplace/startup-culture angle; best pitched with a human-interest/founder-story frame rather than a feature list. — [OfficeChai](https://officechai.com/)
- None of these charge for standard editorial coverage; all favor **traction + a clear human story** over a cold feature-list pitch. Realistic expectation: low hit-rate, but each hit is a durable, high-trust backlink (also helps SEO/AI-search citation of the app).

### Product Hunt
- **Verified-ish benchmarks (vendor-reported)**: PH gets 4.5–8.3M monthly visitors; only ~10% of launches get "Featured" status now (down from 60–98% featured in 2020–2023); Featured vs non-Featured determines ~70% of a launch's outcome; blended CPA ~$3–5 on launch day vs $15+ paid social. For every 1,000 visitors, expect only 10–30 actual signups. 50% of founders in one survey saw only a temporary spike; 16% saw no lift at all. — [ShNo: Product Hunt Launch Statistics 2026](https://www.shno.co/marketing-statistics/product-hunt-launch-statistics), [Awesome Directories: PH Guide 2025](https://awesome-directories.com/blog/product-hunt-launch-guide-2025-algorithm-changes/)
- No India-specific PH data was found. Given GeoWake's audience is Indian commuters (not the PH userbase, which skews global tech/indie-hacker), PH is **low-priority for direct installs** but reasonable for a one-time credibility/backlink/SEO play — do it once, don't over-invest.

---

## PART 3 — Guerrilla / physical tactics (legal reality)

- Putting up posters/QR stickers on public property (metro station walls, poles, bus stops) **without prior written permission from the relevant municipal/transit authority is illegal** across Indian states under local Prevention of Defacement of Property Acts. Example: Delhi's Prevention of Defacement of Property Act (violations cognisable, up to 6 months imprisonment or ₹1,000 fine or both); Maharashtra's 1995 Act (up to 3 months or ₹2,000 fine or both). — [Delhi SEC: Prevention of Defacement of Property Act](https://sec.delhi.gov.in/sec/prevention-defacement-property-act), [Maharashtra Prevention of Defacement of Property Act, 1995](https://www.indianemployees.com/acts-rules/details/maharashtra-prevention-of-defacement-of-property-act-1995)
- Metro systems specifically (BMRCL, DMRC) have their own strict no-unauthorized-advertising enforcement inside stations/trains — this is a harder no than generic municipal walls.
- **Legal alternative**: BMRCL/DMRC/other metro corporations sell official station/train advertising space commercially — real money, not zero-budget, so out of scope here, but worth knowing as a future paid channel.
- **Policy-safe "guerrilla" substitute**: distribute physical QR-code cards/stickers only on **private property with owner consent** — e.g. partner with cafés, PGs/hostels, and co-working spaces near metro stations; or hand out flyers *outside* station premises (public footpath, not station property) where local law is more permissive — verify locally, this still varies by city/state.
- Do not stick QR posters inside metro coaches/stations or on public poles — the legal risk (fine + imprisonment exposure, however rarely enforced) is asymmetric for a solo dev with a Play Store listing to protect.

---

## PART 4 — Review-velocity, policy-safe

- Confirmed banned: any money/goods/service exchange for a rating, review, or install. — [Play Console Help](https://support.google.com/googleplay/android-developer/answer/9898684?hl=en)
- Confirmed allowed: **non-deceptive, non-gated prompts** — i.e., asking every user (not just happy ones) to rate, via the official In-App Review API, timed after a real positive moment (successful wake-up), max ~1x/month due to Google's own quota. — [Android Developers: In-App Review API](https://developer.android.com/guide/playcore/in-app-review)
- Policy-safe review-velocity levers that are NOT incentivization:
  1. Fire the review prompt precisely after the "never-late" moment lands (alarm woke them, they made their stop) — self-selects for a satisfied moment without asking a leading question.
  2. Never gate with "Are you enjoying the app?" pre-filter — Google explicitly calls this out as a violation risk.
  3. Ask happy users organically in community posts/DMs to leave a review "if it helped you" — fine, since no consideration is offered; just don't do it at scale via a bot or bulk DM campaign (that risks looking like manipulation even without payment).
  4. Respond to every review (especially negative ones) — doesn't directly juice velocity but is a ranking-adjacent quality signal Google has publicly emphasized, and it's free.

---

## PART 5 — Viral loop: journey-share links

- **General app referral benchmarks (secondary/vendor-reported, no GeoWake-specific data exists yet)**:
  - Sustainable K-factor: 0.15–0.25 "good", 0.4 "great", ~0.7 "outstanding"; K>1.0 is self-sustaining exponential growth (rare).
  - Fintech/payments/lending apps (closest comparable vertical with public benchmarks): K-factor 0.4–0.8, invite-to-install conversion 12–20%, share rate (% of users who ever share) 8–15%.
  — [LaunchList: Viral Coefficient & K-Factor Guide 2026](https://getlaunchlist.com/blog/viral-coefficient-k-factor-guide), [Viral Loops: 5 metrics for referral campaigns](https://viral-loops.com/blog/5-metrics-for-your-referral-campaign/)
- **[ESTIMATE, not GeoWake-verified]** applying these ranges: if GeoWake builds a "share your journey/wake-up" link (e.g., "I set a GeoWake alarm for my 7:42 metro — try it"), a realistic target is an **8–15% share rate among active users** and **12–20% invite-to-install conversion**, i.e. each 100 active users who share might yield roughly 1–3 new installs per sharing cycle — useful compounding but not a standalone growth engine at GeoWake's current scale. Treat any specific K-factor claim for GeoWake as unverified until real data exists.
- Design implication: make the share action a **natural byproduct of the core action** (setting the alarm / seeing the "never late" proof), not a bolted-on "invite friends" screen — proximity to the aha-moment is what the fintech comparables' higher share-rates correlate with in vendor literature.

---

## 90-DAY PRIORITIZED PLAYBOOK

Effort: S (a few hours) / M (a day or two) / L (ongoing, week+)
Impact: rated for a solo India-first pre-launch/launch utility app, zero budget.

### Days 1–14 — Foundation (must happen before any push)
| Action | Effort | Impact | Notes |
|---|---|---|---|
| Optimize title + 80-char short description per Part 1 | S | High | One-time, compounds everything else |
| Localize store listing (Hindi + launch-city language) | M | Med-High | Especially valuable outside Delhi/Bangalore anglophone-heavy metros |
| Wire in-app review prompt to fire post-successful-wake only | S | High | Policy-safe review velocity, free |
| Submit Google Play Featuring Nomination | S | Low-Med (lottery) | Free, no downside |
| Set up 1 custom store listing per launch city w/ unique deep link | M | Med | Enables free per-channel attribution |
| Draft 3 Reel/Short scripts (POV-realism format from Part 2) and film them | M | High | This is the highest-leverage zero-cost channel per 2026 hook data |

### Days 15–35 — Soft launch + community seeding
| Action | Effort | Impact | Notes |
|---|---|---|---|
| Post founder-story launch thread in r/bangalore (or launch city sub) — **verify current rules live first** | S | High (if not removed) | Genuine "I built this because I kept missing my stop" framing, disclose dev status |
| Join 2–3 city commuter Telegram/WhatsApp groups (BMTC-style) as a real participant | M | Med | Slow-burn trust-building, not a broadcast channel |
| Launch a WhatsApp Channel for GeoWake updates | S | Low-Med | Free, compounds over time as a retained-audience asset |
| Reply helpfully under #NammaMetro / #DelhiMetro / #BengaluruMetro complaint threads on X, 2–3x/week | M (ongoing) | Med | Avoid anything touching language politics |
| Pitch MediaNama (privacy/data angle), YourStory, Inc42, OfficeChai — 4 tailored pitches, not 1 mass email | M | Med (low hit-rate, high value per hit) | MediaNama fit is strongest given the DP-protected data pipeline story |
| Post first Reels/Shorts batch (3 scripts from Part 1) | M | High | Iterate weekly on hook rate |

### Days 36–60 — Scale what worked
| Action | Effort | Impact | Notes |
|---|---|---|---|
| Recruit 3–5 campus ambassadors in launch city via college WhatsApp/Telegram groups | M | Med (slow ramp) | Certificate + Pro-unlock comp, not cash |
| Expand Reddit presence to r/delhi, r/mumbai, r/india (1 post each, spaced out, rules-checked each time) | S per post | Med-High | Never cross-post identical copy |
| Build & ship the journey-share link feature if not already live | L | Med-High (compounding) | Tie share action directly to the "never-late" proof moment |
| Second promotional-content push on Play Console (Major Update card) | S | Low-Med | Free, ~5%/4% lift per Google's beta data |
| One-time Product Hunt launch | M | Low (direct installs), Med (backlink/credibility) | Don't over-invest; India audience isn't PH's core base |

### Days 61–90 — Compound + review
| Action | Effort | Impact | Notes |
|---|---|---|---|
| Analyze which city subreddit / Reel format / channel drove the custom-listing deep-link installs; double down | S | High | Data-driven reallocation |
| Second Reels/Shorts batch based on what got real hook-rate data | M | High | Iterate, don't guess twice |
| Follow up with any PR outlet that didn't respond (one polite follow-up per outlet, per their own norm) | S | Low-Med | |
| Expand campus ambassador program to 1–2 more cities if first city showed traction | M | Med | |
| Re-localize store listing into a 3rd Indian language if 2nd city launch is confirmed | M | Med | |

### What NOT to do (policy/legal risk, low ROI for a solo dev)
- Any paid or unpaid review-exchange scheme (Telegram "rate-for-rate" groups) — explicitly banned, actively detected via GenAI at scale in 2025.
- Unauthorized QR posters on metro/station property or public poles — real fine + imprisonment exposure under state Defacement Acts.
- Mass identical cross-posting across Indian city subreddits — reads as coordinated spam, risks a ban that forecloses the channel permanently.
- Over-investing in Product Hunt — low signal for an India-commuter audience, useful once as a credibility artifact only.

---

## Key uncertainties / what to verify yourself before acting
1. **Exact current rules of r/bangalore, r/india, r/delhi, r/mumbai** — could not be fetched live in this session; check each subreddit's rules/wiki page immediately before posting.
2. **GeoWake-specific viral K-factor / share-link conversion** — no GeoWake data exists yet; the fintech-vertical benchmarks cited are a reference point, not a prediction.
3. **Google's exact keyword-weighting algorithm** — all "how ASO ranking works" claims beyond the primary Play Console policy page are vendor estimates, not confirmed by Google.
4. **Product Hunt India-specific conversion data** — none found; the cited benchmarks are global/vendor-aggregated.


## KEY FACTS
- [verified] Google Play title cap is 30 characters and short description cap is 80 characters, enforced by the Play Console field itself (https://support.google.com/googleplay/android-developer/answer/13393723?hl=en)
- [verified] Incentivizing ratings, reviews, or installs (offering money/goods/equivalent) is explicitly banned by Google Play policy (https://support.google.com/googleplay/android-developer/answer/9898684?hl=en)
- [verified] The Android In-App Review API must not be gated on prior satisfaction (e.g. 'would you rate us 5 stars?' is banned) and is quota-limited to roughly once per month per user (https://developer.android.com/guide/playcore/in-app-review)
- [likely] Google's anti-spam systems blocked 160 million spam ratings/reviews in 2025 using GenAI detection (aggregated from Play Console policy area + https://www.techradar.com/pro/security/google-rejected-nearly-two-million-android-apps-and-blocked-more-than-80-000-developer-accounts-from-google-play-in-2025)
- [likely] Custom store listings on Google Play support up to 50 variants per app, each with unique creative and a unique deep link for free attribution (https://www.mobileaction.co/blog/custom-store-listings-on-google-play/)
- [likely] Apps using Google's promotional content (LiveOps) beta averaged +5% active users and +4% revenue vs non-participants (https://play.google.com/console/about/programs/promotionalcontent/)
- [verified] Unauthorized posters on public property in India (including near metro stations) are illegal under state-level Prevention of Defacement of Property Acts, e.g. Delhi (up to 6 months/₹1,000 fine) and Maharashtra (up to 3 months/₹2,000 fine) (https://sec.delhi.gov.in/sec/prevention-defacement-property-act)
- [likely] India Android penetration is roughly 95% of the smartphone base (aggregated Statista/industry figures via search, 2024-2026)
- [verified] A Bengaluru community-run Telegram group 'Friends of BMTC' for bus-route info exists with ~2,000 active users, proving grassroots transit-info groups are receptive audiences (https://www.deccanherald.com/amp/story/india%2Fkarnataka%2Fbengaluru%2Fb-lureans-start-telegram-group-for-bus-route-enquiries-1230324.html)
- [likely] WhatsApp Channels (Meta's one-way broadcast feature) remain free for businesses as of 2025-2026 sources (https://sinch.com/blog/whatsapp-channels-marketing-companies/)
- [estimate] Product Hunt: only ~10% of launches now get 'Featured' status (down from 60-98% in 2020-2023), and Featured status accounts for ~70% of a launch's traffic/success (https://awesome-directories.com/blog/product-hunt-launch-guide-2025-algorithm-changes/)
- [estimate] Fintech/payments app referral benchmarks: K-factor 0.4-0.8, invite-to-install conversion 12-20%, share rate 8-15% (closest public comparable vertical; no GeoWake-specific data exists) (https://getlaunchlist.com/blog/viral-coefficient-k-factor-guide)
