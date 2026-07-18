# GeoWake — Sustainability Plan

_Founder deliverable. Question: **"What is the minimum recipe that makes GeoWake not lose money, and at what MAU does it break even?"**_

_Builds ON `ECONOMICS.md` (the unit-economics model), `COST_LEAKS.md` (the drainable-key tail), `MONETIZATION.md` (revenue levers), and `DATA_STRATEGY.md` (the data moat). This doc does **not** re-derive those models — it (a) resolves the `NEEDS-DATA` items ECONOMICS.md left open with cited 2026 values, (b) corrects three numbers those docs got wrong, and (c) turns the whole thing into an ordered, dollar-quantified recipe._

_FX: **₹86 = $1** (per brief). **Reality flag:** actual spot on 2026-07-17 was **₹96.4/$** (https://www.exchangerates.org.uk/USD-INR-spot-exchange-rates-history-2026.html, as-of 2026-07-17) — costs are USD-denominated, revenue is INR-denominated, so the real hole is **~12–14% wider** than every ₹-figure here. All external numbers carry an inline `source_url` + as-of date; see the Sources appendix._

---

## 1. TL;DR

**The one-sentence minimum recipe:**
> Cap the drainable `/auth/token` key today (free), **delete the two Nearby Search calls/arm** using the shipped 805-station dataset (free, removes ~60% of the Google bill), **self-host routing + tiles + local point-in-polygon geocoding** once past ~5–10K MAU (keeping only Google Places for destination text-search), grow **100% organically** (paid installs are unrecoverable), and treat affiliate as a floor until a **recurring** ride-hail deal (direct CPS or ONDC) lands as the real margin engine.

**Break-even MAU (honest):**

| Revenue mix | Break-even MAU | Why |
|---|---|---|
| **Ads only, today's architecture** | **Never** | Metered cost $0.59–2.15/user/mo vs ad revenue ~$0.017; needs a ~$104–200+ interstitial eCPM (India reality is $1–2.50). |
| **Ads only, after full cost-deletion** | **~150–250K MAU** | Serving cost falls to ~$0.02–0.03/user, ≈ the ad line — but front-loaded fixed costs (support, HA infra, DPDP legal, the mandatory Places-New migration) only amortize below the ad line at scale. Requires migrating Place Details off legacy. |
| **Ads + off-the-shelf affiliate** | **~150–250K MAU** | Public affiliate pays a **one-time** new-user bounty (~$0.001–0.004/user/mo amortized), the same order as ads — it does **not** meaningfully move break-even. |
| **Ads + recurring intent deal (direct CPS or ONDC)** | **~10–50K MAU** | A ~₹40+/user/mo (2 last-mile rides) recurring share (~$0.15–0.40/user/mo) is the only lever that clears fixed costs at modest scale and turns the model comfortably green. |

**Bottom line:** GeoWake *can* reach "does not lose money," but only via **cost-deletion first** (which gets it to ≈break-even), and it only becomes a *business* if a **recurring** last-mile revenue share materializes. Ads and public affiliate bounties are floors, not engines. Do not bank the ₹75–300/user affiliate line in MONETIZATION.md §C — it is an error (see §2).

---

## 2. Resolved unknowns

Each `NEEDS-DATA` / open item from ECONOMICS.md → the 2026 value, source, and dollar impact. **The headline: Nearby Search is now pinned, and it lands between the doc's optimistic and pessimistic columns — closer to catastrophic than benign.**

| # | Unknown (ECONOMICS.md ref) | Resolved 2026 value | source_url (as-of) | $ impact |
|---|---|---|---|---|
| **1** | **Nearby Search SKU + India price** (§1.4, "priority #1", swings model 20×) | **India Nearby Search Pro = $9.60/1k** (Cap–5M), **$2.40/1k** (5M+), **free tier 35,000/mo** — the Legacy Places SKU the app uses and the New "Pro" SKU price identically. **Global = $32/1k, 5,000 free.** | https://developers.google.com/maps/billing-and-pricing/pricing-india (2026-07-19); global https://developers.google.com/maps/billing-and-pricing/pricing (2026-07-19) | 2 calls/arm × 20 arms = **$0.384/user/mo India** = **$38,400/mo @100K MAU** = **~60% of the India Google bill**. Global: $1.28/user = $128K/mo. ECONOMICS.md's "$1.50 optimistic" was **6.4× too low**; its "$32 pessimistic" was the **global** sheet. |
| **2** | **Is the Cloud account India-qualified?** (§0.3, ~2–3× on everything) | India pricing = **billing-in-India + a large majority of usage in India**; **applied automatically**, no opt-in; **INR billing NOT required** (USD customers may stay USD); no India legal-entity requirement stated; **Google monitors and may disqualify**. Effective 2024-08-01. | https://developers.google.com/maps/billing-and-pricing/india (2026-07-19) | **The single largest lever in the model.** India ($0.64/user) vs global ($2.15/user) = **~$1.50/user/mo = ~$150K/mo @100K MAU**. **Conditional and revocable** → plan the **global** sheet as base case until confirmed in Cloud Console. |
| **3** | **Autocomplete Session Usage — still free in 2026?** (§1.2, §Appendix #6) | **YES — still $0, unlimited, no announced end date.** India SKU 4764-9FA0-0FC0 "Unlimited free cap." Global SKU $0. | https://developers.google.com/maps/billing-and-pricing/pricing-india (2026-07-19) | Confirms the keystroke-bomb is avoided. **Protect it:** wire `endSession()` — a chargeable regression (Per Request $0.85/1k India) would add **~$5,950/mo @100K MAU**. |
| **4** | **Self-host real cost** (§4.1, "~$90–300/mo" assumed) | **Lightsail Mumbai: 4GB=$24, 8GB=$44, 16GB=$84, 32GB=$164/mo** (same instance price as US regions). **Cloudflare R2: $0 egress, $0.015/GB-mo, 10GB free.** India OSM extract = **1.6GB** (fits an 8GB box). | https://aws.amazon.com/lightsail/pricing/ (2026-07-19); https://developers.cloudflare.com/r2/pricing/ (2026-07-19); https://download.geofabrik.de/asia/india.html (2026-07) | Cash infra: **~$60–80/mo @100K, ~$400–550/mo @1M** (HA pair). Sub-linear. **But** the honest TCO adds eng/ops: one-time MapLibre migration **~2–4 eng-months / $10–20K**, ongoing ops ~0.2 FTE **~$220–300/mo**. |
| **5** | **Affiliate CPA terms + is it recurring?** (MONETIZATION §C: "₹75–300/user/mo") | **WRONG by ~50–500×.** Every off-the-shelf program is a **ONE-TIME new-user acquisition bounty**, not a per-ride commission: Rapido ₹30, Uber ~₹60/$5, Ola ₹24, Swiggy ₹54, Zomato ₹70. §C modeled "60 rides × 5% × ₹25" as if paid every ride. | Rapido https://inrdeals.com/campaigns/rapido-affiliate-program (2026-07-19); Uber https://developer.uber.com/docs/riders/affiliate-program/introduction ($5, 2026-07-19); Ola/Swiggy https://www.cuelinks.com/campaigns/ (2026-04); Zomato https://inrdeals.com/campaigns/zomato-affiliate-program (2026-07-19) | Realistic off-the-shelf affiliate = **~₹0.5–1.5/user/mo ($0.006–0.017)**, amortized, and only on the minority of users **new** to that app. **Same order as ads, not 10–50×.** Recurring intent revenue needs ONDC or a BD'd CPS deal. |
| **6** | **ONDC — does it shortcut per-merchant BD?** (MONETIZATION §C) | **Yes — the only off-the-shelf recurring path.** ONDC mobility (spec TRV10-2.0.1 / Beckn) is live; one network integration reaches Namma Yatri + other seller apps; self-service onboarding. Revenue = **Buyer App Finder Fee (BAF), ~3%** (Paytm charged 3%); ONDC levies no central commission. | https://github.com/ONDC-Official/mobility-specification (2026-07-19); https://www.business-standard.com/companies/news/paytm-to-forego-3-commission... (2023-05, model still current) | 3% BAF on ₹80 avg × 5 rides/mo = **~₹12/user/mo recurring ($0.14)** — the §C "dream," BD-free. **But** it is a real Beckn build + becoming a booking/checkout/payment surface (regulated Network Participant). **v2, not launch.** BAF pricing power is weak (competitors waive it). |
| **7** | **Place Details SKU on the shipped code** (§0.2 assumed $1.50 Essentials) | **App is on LEGACY Places → terminal call is Place Details (Legacy) = $5.10/1k India** (Pro-equiv), **not** Essentials $1.50. Even after migrating to Places-New, a single Pro field in the mask reclassifies the whole call to Pro $5.10/1k. | https://developers.google.com/maps/billing-and-pricing/pricing-india (2026-07-19); field-mask rules https://developers.google.com/maps/documentation/places/web-service/usage-and-billing (2026-07-19) | The residual "keep Google Places" line is **~$0.05–0.07/user/mo on today's code**, not the $0.021 ECONOMICS.md implied. Migrate to Places-New **and** pin the field mask to `location,formattedAddress` to reach $1.50/1k. This is the one Google SKU the plan keeps — the residual cost floor. |
| **8** | **Nearby Search free-tier cliff** (§3, modeled "70K/SKU") | Nearby is a **Pro** SKU → **35,000 free/mo** in India (5,000 global), **half** the 70K Essentials tier. | https://developers.google.com/maps/billing-and-pricing/pricing-india (2026-07-19) | The cost cliff on the dominant line arrives at **~875 MAU** (35,000 ÷ 40 calls/user), **earlier** than the ~1,590 MAU Geocoding cliff. The "free-tier mirage" breaks sooner than ECONOMICS.md §3 modeled — do **not** defer the Nearby deletion. |
| **9** | **Legacy sunset** (§1.5) | Places/Directions/Distance Matrix → **Legacy 2025-03-01. No decommission date; ≥12-month notice promised.** Still billable at first-tier India price, but **excluded from the 5M+ volume discounts** (only scales to the 100K+ tier). | https://developers.google.com/maps/billing-and-pricing/faq (2026-07-19) | No per-call penalty today at <5M scale, but the ECONOMICS.md "$0.10/user at 1M" projection (which assumed the $0.38/1k volume band) is **unreachable on legacy** — stays at first-tier until a forced migration. Budget the Routes-API + Places-New migration as funded eng. |
| **10** | **Data-moat B2B line — near-term sustainability lever?** (DATA_STRATEGY.md) | **NO.** Realistic near-term data revenue **~₹30–75 lakh/yr ($35–90K)** at 3–5 cities = **~$0.006–0.015/user/mo @500K MAU = ~1–5% of the cost hole.** Sellable only at **~100K+ MAU concentrated on ONE metro** (k≥100 anonymity needs geographic density, not raw national MAU). | US ceiling anchors only; k-anon = Google COVID Mobility rule; DPDP Rules final (Gazette G.S.R. 846(E), 2025-11-13, bind 2027-05-13) | **Risk-adjusted near-term value = $0.** Incremental DPDP/methodology cost ~₹4–7 lakh/yr with **no offsetting revenue until scale**, plus a **₹250-crore stackable** breach tail and a company-ending "GeoWake sold your movements" headline. **Build the free guardrails now, book $0, monetize at v3/acquisition.** |

---

## 3. The break-even model

**Basis:** 20 arms/user/mo (ECONOMICS.md §0.1, un-telemetered ASSUMPTION — everything scales linearly on this). "Today" = shipped code on India-qualified Google metered pricing with the corrected Nearby ($9.60/1k) and legacy Place Details ($5.10/1k). "Min-viable-sustainability" = caps + delete Nearby + de-multiply Directions + self-host routing/tiles + local geocoding + **Places-New-migrated** Place Details (0.7/arm) + self-host fixed infra.

### 3.1 Cost per user per month

| MAU | **TODAY** (India-qualified, corrected) | **TODAY** (global, unqualified) | **MIN-VIABLE** (hybrid, migrated) |
|---|---|---|---|
| 1K | ~$0.015 (free tiers + Railway) | ~$0.015 | ~$0.010 (Railway only) |
| 10K | ~$0.52 (Nearby cliff crossed at ~875 MAU) | ~$1.7 | ~$0.025 ($150/mo self-host + Place Details) |
| 100K | **~$0.59** (Nearby $0.384 = 65%) | **~$2.15** | **~$0.025** ($0.021 Place Details + ~$0.004 infra) |
| 1M | ~$0.21 (partial volume bands) | ~$1.5 | ~$0.006 (Places-New 5M+ band $0.38/1k + infra) |

> **Correction to ECONOMICS.md §1.6/§3:** the true fully-metered India cost at 100K MAU is **~$0.59/user/mo (2.2× the doc's $0.27 optimistic headline)**, because Nearby is $9.60/1k (not $1.50) and Place Details is legacy $5.10/1k (not $1.50). Any downstream doc quoting $0.27 as "the" cost understates the hole ~2.2×. On the **global** sheet it is ~$2.15/user/mo.

### 3.2 Revenue per user per month

| Line | Research headline | **Verifier-corrected (use this)** | Note |
|---|---|---|---|
| Ads | $0.019 | **~$0.010–0.017** | Halve impression assumptions for a zero-attention wake-alarm (no ads on alarm/lock surfaces); ~12% off for ₹96.4 FX. |
| Off-the-shelf affiliate (one-time bounty, amortized) | $0.008 | **~$0.001–0.004** | Only the minority new to that app convert; most transit riders already have Rapido/Uber. |
| Pro unlock (reprice ₹149–249, 1–2%) | $0.004 | **~$0.002–0.003** | India D30 retention ~2.8% shrinks the amortization cohort. |
| **Blended launch (realistic)** | ~$0.028–0.032 | **~$0.016–0.020** | Research overstated by ~40–50%. |
| **Recurring intent (direct CPS / ONDC BAF)** | — | **~$0.15–0.40** | The only line that changes the verdict; BD/build-gated, unproven. |

### 3.3 Net per user per month (min-viable config)

| MAU | Cost | Revenue (ads + one-time affiliate + Pro) | **Net** | With recurring CPS/ONDC |
|---|---|---|---|---|
| 1K | ~$0.010 | ~$0.018 | **+$0.008** 🟢 (thin; free-tier-driven) | strongly + |
| 10K | ~$0.025 | ~$0.018 | **−$0.007** 🔴 (self-host fixed not amortized) | + |
| 100K | ~$0.025 | ~$0.018 | **−$0.007** 🔴 (Place Details floor ≈ ad line) | **+$0.13–0.38** 🟢 |
| 1M | ~$0.006 | ~$0.018 | **+$0.012** 🟢 | strongly + |

> **The honest read:** on ads + *public* (one-time) affiliate, the min-viable config is **knife-edge to mildly red across the 10K–1M scaling tiers** — the deleted Nearby/Directions/Dynamic-Maps lines get you *to* break-even, but the residual Place Details floor plus un-amortized fixed costs sit right at the thin ad+bounty revenue line. **Genuinely-positive economics require the recurring intent deal.** ECONOMICS.md §4.2's "flips green on cost alone" is true only if you also (a) migrate Place Details to Places-New with a strict field mask and (b) never load support/HA/legal fixed costs — which §5 shows you must.

---

## 4. The prioritized recipe

In order. Each step lists **$ protected/saved @100K MAU (India-qualified)** and effort. Steps 0–1 are free and non-optional; do them this week.

### Step 0 — Existential caps: bound the drainable-key tail _(free, settings + small code, TODAY)_
The `/auth/token` endpoint mints a 24h Maps-capable JWT to anyone who POSTs the public bundle ID (no attestation, CORS `*`), and the only brake — a per-IP rate limit — keys on the **client-controllable leftmost `X-Forwarded-For`** (`security.js:14,31`), so it is **spoof-bypassable from a single machine**. With no per-API quota cap, worst-case burn is effectively **unbounded**: one VM @100 req/s against Nearby Search = **~$276K/day** (global) / against Directions **~$43K/day global, ~$13K/day India**. One drain weekend can exceed **14+ months** of total ad revenue at 100K MAU.

- **GCP per-API daily quota cap** on Directions/Geocoding/Places/Nearby (Cloud Console → APIs → Quotas → requests-per-day ≈ 1.5–2× real volume). This is the **only** control that hard-caps (returns a limit-exceeded error). https://docs.cloud.google.com/apis/docs/capping-api-usage (2026-07-19)
- **Budget → Pub/Sub → Cloud Function that disables billing** as a project-wide $ kill switch. A **budget alert does NOT cap spend** — Google's own docs. https://docs.cloud.google.com/billing/docs/how-to/budgets (2026-07-19); https://docs.cloud.google.com/billing/docs/how-to/disable-billing-with-notifications (2026-07-19)
- **Play Integrity attestation on `/auth/token`** — **free ≤10,000 checks/day**. **Correction:** that maps to **~10–40K MAU**, not the ~300K COST_LEAKS implied (10K is per-*day*, ~1 check per daily-active user via the 24h JWT). **File the 4-business-day quota-increase request pre-launch.** https://developer.android.com/google/play/integrity (2026-07-19)
- **Fix the XFF rate-limit key** (`trust proxy` with Railway's hop count, or rate-limit per-JWT-device). Until then the 1000/hr/IP limit is ~zero protection.

> **$ protected: unbounded → ≤ ~$1,000/day.** Does not change unit economics; prevents a company-ending loss event. **Must be first.**

### Step 1 — Delete the 10× cost-multiplier drip _(free, code-only, cuts cost/user ~4×)_
Highest ROI per engineering hour. Zero new infrastructure.

- **1a. DELETE the 2 Nearby Search calls/arm** (`metro_stop_service.dart:54,127`) → validate metro stops against the **shipped 805-station dataset + OSM rail geometry**. Removes **~$38,400/mo @100K MAU (₹33/user), ~60% of the Google bill**, and neutralizes the India-vs-global and Pro-tier risk on the priciest SKU. **Do this before anything else.**
- **1b. De-multiply Directions 2.0→1.0/arm** — no retry on `ZERO_RESULTS`/OK-with-no-routes (`direction_service.dart:363–375`), negative-result cache, lock the arm button during in-flight fetch, gate metro fallback behind a real error. Saves **~$3,000/mo India** and removes a retry-storm an attacker/bug can amplify.
- **1c. Kill the 5-min cache re-buy** (`route_cache.dart:86`, server `cache.js` stdTTL 300) — persist each saved/recent commute's Directions long-TTL keyed to `RouteMemoryService`; move server cache to Redis so it survives Railway restarts. Drops per-user Maps cost ~10× (a committed rider re-buys the same route ~20–40×/mo instead of ~1). **~$19–24K/mo @100K.**
- **1d. Halve same-state geocoding 2.2→1.1/arm** — cache origin state per session; or replace with **point-in-polygon vs a local India admin-boundary GeoJSON** (zero Google **and** no Nominatim to self-host).

> **$ saved: ~$22–34K/mo recurring @100K.** Moves per-user cost from ~$0.59 toward ~$0.15 with zero infra.

### Step 2 — Cost-deletion: self-host _(~$150–550/mo fixed; pull the trigger ~5–10K MAU)_
Sequence by the free-tier cliff: below ~5K MAU stay on Google (free tiers cover you); begin the cutover approaching **~5–10K MAU** where metered billing exceeds the ~$600/mo self-host floor. Cash break-even vs Google is **~3,000–5,000 MAU**; the one-time build pays back in **<1 month of 100K-MAU operation**.

- **Self-host OSRM routing** (India 1.6GB car+foot extract on one 8GB Lightsail Mumbai box, $44/mo; HA pair + LB ~$350–450/mo past ~5K MAU). Delete Directions/Routes API. **The alarm is unaffected by an outage** — firing is on-device reachability physics; a routing outage only affects *new-arm route compute*, which degrades to the shipped `OsmGraph`/`Pathfinder`.
- **Self-host Protomaps PMTiles + MapLibre GL**, drop Dynamic Maps. India basemap on Cloudflare R2 behind a Worker cache (~$5–50/mo at any scale). Biggest client-side effort (replace the `GoogleMap` Flutter widget) — budget **~2–4 eng-months / $10–20K one-time**. Stage behind a flag; keep the Google Maps SDK as rollback.
- **Skip Nominatim** — the geocoding calls are same-state validation, already replaced by point-in-polygon in Step 1d. This drops the heaviest self-host ops component entirely.

> **$ saved: collapses the residual ~$50K/mo (Directions + Dynamic Maps) @100K to ~$400–550/mo fixed infra.** Per-user cost → ~$0.02–0.03.

### Step 3 — Intent revenue: the margin engine _(BD/build, the only lever that makes it a business)_
- **Floor (ship now, zero BD):** station-arrival deep-link cards to Rapido/Uber/Ola/Swiggy via Cuelinks/EarnKaro/INRDeals. Book the revenue as a **one-time new-user bounty amortized (~₹0.7/user/mo)**, NOT per-ride. Correct MONETIZATION.md §C's ₹75–300 claim.
- **Engine (the real bet):** a **direct ride-hail CPS / revenue-share** deal OR an **ONDC mobility (TRV10) buyer-app** build. Either gives the recurring ~₹40+/user/mo (~$0.15–0.40) that flips the model comfortably green from ~10–50K MAU. ONDC is BD-free but is a real Beckn integration + a regulated booking/checkout surface (weeks–months eng) — validate that GeoWake users will complete last-mile booking **in-app** vs opening their habitual Uber before building it. **This is the precondition for any positive-margin claim.**

### Step 4 — Premium unlock _(steady floor, not engine)_
Reprice Pro **down to ₹149–249 one-time** (₹299–499 is above India mass-market WTP; a 50% cut lifted Tier-3 conversion 0.79%→1.37%, https://www.revenuecat.com/state-of-subscription-apps-2025, 2025). Expect 1–2% ≈ **₹0.2–0.5/user/mo**. Use India CCI alternative billing to cut the Play fee 4% (15%→11%). Never paywall reliability — it breaches the hard constraint and kills the trust asset.

### Step 5 — Data moat _(v3 / acquisition asset — honest timeline)_
Build the **free guardrails now** (default-OFF consent UI, flag-gated on-device k-anon aggregator with **no egress**), **book $0** in the model, and **defer all incremental spend** (DPIA, counsel sign-off, methodology maintenance) until a buyer is contracted. Sellable only at **~100K+ MAU concentrated on one metro**; realistic contribution **~$0.006–0.015/user/mo (~1–5% of the hole)**. Never bend the never-store-trajectories bright line — the downside (₹250-crore stackable penalty, company-ending headline) is asymmetric to the modest upside.

---

## 5. Adversarial — costs the rosy plan misses

From the verifiers. These do not overturn the recipe, but they move break-even and must be on the cost side of any solvency model.

1. **CAC dwarfs the entire API-cost problem — and no cost-deletion touches it.** India Android utility **CPI ≈ $0.30–0.90** (Tier-1 metros — GeoWake's exact launch cities — run 30–60% higher), vs blended **LTV ~$0.15–0.40** even after cost-deletion. **Every paid install loses money.** Growth must be **~100% organic/ASO/referral** until the recurring intent line is proven. This is the biggest omission in ECONOMICS/COST_LEAKS/MONETIZATION — they optimize a $0.59→$0.02 serving cost that is *smaller than the acquisition cost they never mention*. https://gurob.in/blog-app-install-cost-india-vertical (2026); https://www.businessofapps.com/ads/cpi/research/cost-per-install/ (2025)
2. **Front-loaded fixed costs push the true ads-only break-even to ~150–250K MAU.** After cost-deletion, per-user net margin is only ~$0.06–0.17/**year**; support (1–2 heads, ~₹2.5–6L/yr each), the HA infra pair (~$4–7K/yr), the DPDP legal build (₹1.5–10L up-front), and the **mandatory** legacy→Routes/Places-New migration eng do not amortize below the ad line until ~150–250K MAU. All three docs model these as $0.
3. **Google Play cut on the IAP lifeline.** 2026 fee: **15% effective** (10% service under $1M + processing; ~11% with India alternative billing). A ₹399 Pro unlock nets **~₹340, not ₹399** — cut MONETIZATION.md's IAP projections ~15%. **But** affiliate/ONDC revenue settles **outside** Play IAP → **no Play cut** (correction in GeoWake's favor). https://support.google.com/googleplay/android-developer/answer/16954621 (2026-07-19)
4. **Reliability-vs-cost tension imports risk into the CAC-sensitive flow.** The self-host plan trades Google's 99.9% SLA for a single-VM SPOF in **route-fetch-at-arm**; an outage breaks the never-late promise → churn → the ~$0.40 CAC on that user is wasted. **Mitigation:** HA pair + monitoring + on-call (already in the ~$400–550/mo figure) **and** keep a Google-API fallback for new-arm route compute. The alarm itself is safe (on-device physics), but new arms during an outage are not.
5. **Refunds are reliability-coupled and hit exactly when cash is tightest.** Google deducts **all** refunds (even past 48h) from payouts; "I missed my stop" is a refund trigger; excessive chargebacks risk account suspension (tied to the founder's Google identity). Model a 2–5% refund drag on IAP. https://support.google.com/googleplay/answer/15574908 (2026)
6. **Legacy sunset is on Google's clock, not yours** — forces the Routes/Places-New migration and blocks the 5M+ volume discounts the 1M-MAU projection assumes. Scope it as funded eng now (#9 in §2).
7. **FX is a structural ~12–14% headwind** — costs USD, revenue INR, rupee at ₹96.4 not the ₹86 modeled. Prefer INR-billed Indian infra (Lightsail Mumbai is USD; a domestic provider partially hedges).
8. **FCM push is genuinely free** (good news — one worry removed). But BigQuery/Firestore telemetry export bills separately (~$50–500/mo at scale) if the data-asset pipeline writes there. https://firebase.google.com/pricing (2026)

**Net effect on break-even:** the ads-only and ads+public-affiliate cases land at **~150–250K MAU** (not the ~1K the rosy blend implied), and paid UA is **categorically off the table** pre-recurring-revenue.

---

## 6. Sensitivity — the 3 numbers that decide the outcome

1. **India billing qualification (×2–3 on the entire cost side).** India ($0.64/user) vs global ($2.15/user) = ~$1.50/user/mo = ~$150K/mo @100K MAU. **One Cloud Console check.** Plan the global sheet as base case until confirmed; it is conditional and revocable. *Deleting Nearby (Step 1a) and self-hosting (Step 2) neutralize most of this — which is why they are non-optional.*
2. **Affiliate structure: one-time bounty vs recurring CPS/ONDC (×15–50 on revenue).** $0.001–0.004/user (public bounties) → $0.15–0.40/user (recurring). This single choice decides whether break-even is ~150–250K MAU or ~10–50K MAU. **Do not bank the recurring number until a deal is signed.**
3. **Arms/user/mo (assumed 20, un-telemetered) and Place Details/arm (the post-self-host floor, assumed 0.7).** The whole cost side scales linearly on arms; 2× usage doubles it. Place Details is the one Google SKU the plan keeps — on legacy it's $5.10/1k ($0.07/user), migrated + field-masked it's $1.50/1k ($0.021/user). **Instrument arms, D1/D7/D30 retention, IAP conversion, and refund rate before any growth spend** — the solvency case currently rests on un-measured assumptions.

---

## Sources appendix (all as-of 2026-07-19 unless noted)

- Google Maps India pricing (Nearby $9.60/1k, Essentials $1.50/1k, Dynamic Maps $2.10/1k, Autocomplete Session $0, Place Details Legacy $5.10/1k): https://developers.google.com/maps/billing-and-pricing/pricing-india
- Google Maps global pricing (Nearby $32/1k, Geocoding/Directions $5/1k): https://developers.google.com/maps/billing-and-pricing/pricing
- India pricing eligibility (automatic, billing-in-India + majority-India-usage, revocable, eff. 2024-08-01): https://developers.google.com/maps/billing-and-pricing/india
- Free-tier model + legacy sunset (per-SKU caps replaced $200 credit 2025-03-01; ≥12-mo notice; excluded from 5M+ discounts): https://developers.google.com/maps/billing-and-pricing/faq
- Places field-mask / SKU tiering: https://developers.google.com/maps/documentation/places/web-service/usage-and-billing
- GCP quota cap (hard-enforces): https://docs.cloud.google.com/apis/docs/capping-api-usage — budgets do NOT cap: https://docs.cloud.google.com/billing/docs/how-to/budgets — kill switch: https://docs.cloud.google.com/billing/docs/how-to/disable-billing-with-notifications
- Play Integrity (free 10K/day): https://developer.android.com/google/play/integrity
- Lightsail Mumbai pricing: https://aws.amazon.com/lightsail/pricing/ — Cloudflare R2 ($0 egress): https://developers.cloudflare.com/r2/pricing/ — India OSM 1.6GB: https://download.geofabrik.de/asia/india.html
- Affiliate CPA (one-time bounties): Rapido https://inrdeals.com/campaigns/rapido-affiliate-program · Uber $5 https://developer.uber.com/docs/riders/affiliate-program/introduction · Ola/Swiggy https://www.cuelinks.com/campaigns/ · Zomato https://inrdeals.com/campaigns/zomato-affiliate-program
- ONDC mobility (TRV10 / Beckn, 3% BAF): https://github.com/ONDC-Official/mobility-specification · https://www.business-standard.com/companies/news/paytm-to-forego-3-commission-it-charges-as-buyer-app-on-ondc-report-123051200213_1.html (2023-05, model current)
- India eCPM (low, declining): https://bidlogic.io/2025/07/25/ecpm-growth-in-mobile-apps-q1-q2-2025-analysis-and-insights/ (2025-07) · https://www.thesrzone.com/2024/01/admob-ecpm-rates-by-country.html
- Pro-unlock WTP / conversion: https://www.revenuecat.com/state-of-subscription-apps-2025 (2025)
- Play service fee + India alt billing (−4%): https://support.google.com/googleplay/android-developer/answer/16954621 · https://support.google.com/googleplay/android-developer/answer/112622
- Play refunds deducted from payouts: https://support.google.com/googleplay/answer/15574908
- FCM free / Firebase pricing: https://firebase.google.com/pricing
- India Android CPI: https://gurob.in/blog-app-install-cost-india-vertical (2026) · https://www.businessofapps.com/ads/cpi/research/cost-per-install/ (2025)
- App retention (India D30 ~2.8%): https://www.businessofapps.com/data/app-retention-rates (2026)
- USD/INR spot ₹96.43 (2026-07-17): https://www.exchangerates.org.uk/USD-INR-spot-exchange-rates-history-2026.html
