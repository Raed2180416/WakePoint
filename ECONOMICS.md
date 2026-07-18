# GeoWake — Unit Economics Model

> **⚠️ CORRECTED BY `SUSTAINABILITY.md` (2026-07-19).** Three numbers here are now pinned with cited 2026 data and are worse than modeled: **India Nearby Search = $9.60/1k** (not the $1.50 "optimistic"; ~60% of the bill), **Place Details on the shipped legacy code = $5.10/1k** (not $1.50), so the true fully-metered India cost at 100K MAU is **~$0.59/user/mo (2.2× the $0.27 headline below)**, ~$2.15 on the global sheet. "Flips green on cost alone" (§4.2) holds only after migrating Place Details to Places-New with a strict field mask AND excluding support/HA/legal fixed costs — see SUSTAINABILITY.md §3/§5. Use SUSTAINABILITY.md for the break-even model.

_Founder deliverable. Question being answered: **"At launch scale, do we lose money per active user, and what is the cheapest path to break-even?"**_

_Author: cost/revenue model built 2026-07-18 from the cited research files in `docs/research/raw/` + a read of the live code cost surface. FX: **₹83 = $1** (per brief). Note: the ad-research file cites the spot rate at **₹96.4/$** as of 2026-07-17 (https://www.exchangerates.org.uk/USD-INR-spot-exchange-rates-history-2026.html), so every ₹ figure here is ~14% conservative (understated) vs. spot. Every external number is cited inline with its `source_url`. Anything not in the research is tagged **ASSUMPTION** or **NEEDS DATA**._

---

## TL;DR verdict (one line)

**Yes — at 100K+ MAU on Google's metered pricing we lose money per user by a wide margin** (per-user API cost ≈ $0.26–1.46/mo vs. ad revenue ≈ $0.02–0.05/mo, a 5–70× gap). **The cheapest path to break-even is not squeezing eCPM — it is deleting the cost**: self-host routing (OSRM) + replace metro-station Nearby Search with local GTFS/OSM + self-host tiles/geocoding, which collapses the bill ~95–98%. Full reasoning and the bottom line are in §5.

---

## 0. Assumptions (all explicit — change these first)

### 0.1 Usage profile per active user

| Variable | Base ("moderate commuter") | Heavy ("committed commuter") | Basis |
|---|---|---|---|
| Arms (trips set)/user/month | **20** | 60 | ASSUMPTION. Base ≈ 5 commute-days/wk × ~1 armed trip/day; heavy = 2/day × 30, the figure MONETIZATION.md §1 uses. |
| New-destination lookups/arm | **0.7** | 0.7 | ASSUMPTION — ~30% of arms reuse a recent/saved route (recents + frequency are built; see MONETIZATION.md §B) and skip Autocomplete+Place Details. |
| Reroutes/arm | **~0.3 (folded into 2.0 Directions/arm)** | 0.3 | ASSUMPTION — deviation-triggered, 20 s cooldown (`reroute_policy.dart:22`), rare on a normal ride. |
| Impressions/arm (interstitial, every-3) | **0.33** | 0.33 | From MONETIZATION.md §1 "every 3 rides." |

### 0.2 Google Maps SKU calls per arm (metro mode, at scale — free tier already exhausted)

| SKU | Calls/arm | Evidence (file:line) & rationale |
|---|---|---|
| **Directions** (legacy Directions API) | **2.0** | `direction_service.dart:199` (primary) + `:227` (metro-closed fallback, fires in metro mode) + reroute `trackingservice.dart:1453` (`forceRefresh:true`, bypasses cache). 1 primary + occasional fallback + rare reroute ≈ 2.0. |
| **Place Details** | **0.7** | `places_service.dart:65` — one terminal Place Details per new-destination lookup; 30% of arms reuse recents → 0.7. |
| **Geocoding** | **2.2** | `homescreen.dart:271–274` — same-state validation reverse-geocodes **origin + dest = 2 per arm** + amortized country-code lookup `:215`. |
| **Nearby Search** (Places) | **2.0** | `homescreen.dart:749` → `metro_stop_service.dart:54` (validate dest) + `:127` (validate start) = 2 Places Nearby Search calls per metro arm. **Cost of this SKU is NEEDS DATA — see §1.4; it is the single biggest risk in the model.** |
| **Dynamic Maps** (Maps SDK map load) | **1.5** | Two `GoogleMap(` surfaces per ride: destination picker `homescreen.dart:1577` + live tracking `maptracking.dart:1089`. Google's per-session map-load counting is NEEDS DATA (research open question, maps_pricing.md caveats) → assume 1.5. |
| **Autocomplete session** | **$0** | Session-token model → session usage is **currently free**; you pay only the terminal Place Details. Code correctly uses session tokens (`places_service.dart:11–18,35,50`) + a 450 ms debounce (`homescreen.dart:335`). See §1.2. https://developers.google.com/maps/billing-and-pricing/pricing |

### 0.3 Pricing sheet used

**India pricing is assumed** (GeoWake is India-first). This requires the Google Cloud billing account to qualify as India-based (majority-India usage + INR billing) — **NEEDS DATA / confirm in Cloud Console**; if it does not qualify, every Google line below is ~2–3× higher (global sheet). https://developers.google.com/maps/billing-and-pricing/india

India per-1,000 rates and free tiers actually used (all [high]-confidence, as_of 2026-07-18):

| SKU (India Essentials) | Free/mo | First paid tier (per 1k) | 5M+ (per 1k) | source_url |
|---|---|---|---|---|
| Directions / Routes Compute Routes | 70,000 | $1.50 | $0.38 | https://developers.google.com/maps/billing-and-pricing/pricing-india |
| Place Details Essentials | 70,000 | $1.50 | $0.38 | https://developers.google.com/maps/billing-and-pricing/pricing-india |
| Geocoding | 70,000 | $1.50 | $0.38 | https://developers.google.com/maps/billing-and-pricing/pricing-india |
| Dynamic Maps (map load) | 70,000 | $2.10 | $0.53 | https://developers.google.com/maps/billing-and-pricing/pricing-india |
| Autocomplete Session Usage | ∞ | **$0 (currently free)** | $0 | https://developers.google.com/maps/billing-and-pricing/pricing |
| Autocomplete Per Request (no session) | 70,000 | $0.85 | $0.21 | https://developers.google.com/maps/billing-and-pricing/pricing-india |
| Nearby Search (Places) | NEEDS DATA | **NEEDS DATA** (see §1.4) | — | not in research |

> Free tiers are **per-SKU, per-month, consumed first each month** (maps_pricing.md key facts). This is why cost is ~$0 at 1K MAU and then falls off a cliff — see §3.

---

## 1. COST SIDE — cost per active user per month

### 1.1 Per-arm cost at metered (post-free-tier) India rates

Multiplying §0.2 call counts × §0.3 first-paid-tier rates:

| SKU | calls/arm | ₹/1k basis | $/arm |
|---|---|---|---|
| Directions | 2.0 | $1.50/1k | $0.00300 |
| Place Details | 0.7 | $1.50/1k | $0.00105 |
| Geocoding | 2.2 | $1.50/1k | $0.00330 |
| Dynamic Maps | 1.5 | $2.10/1k | $0.00315 |
| Autocomplete | (free) | $0 | $0.00000 |
| **Subtotal (excl. Nearby Search)** | | | **$0.01050/arm** |
| Nearby Search — **optimistic** ($1.50/1k proxy) | 2.0 | $1.50/1k | $0.00300 |
| Nearby Search — **pessimistic** ($32/1k, see §1.4) | 2.0 | $32/1k | $0.06400 |
| **Total per arm (optimistic Nearby)** | | | **$0.01350** |
| **Total per arm (pessimistic Nearby)** | | | **$0.07450** |

### 1.2 Autocomplete: is the per-keystroke cost bomb present? — **NO (already mitigated), but keep it that way**

The classic bug — billing an Autocomplete **Per Request** for every keystroke — is **not** present:

- **Session tokens are used.** `places_service.dart:11–18` mints a token and reuses it for both Autocomplete and the terminal Place Details (`:35, :50, :68`); the proxy forwards it as `sessiontoken` (`api_client.dart:386, :413`). Under the session model, Autocomplete Session Usage is **currently $0** and you pay only the terminal Place Details. https://developers.google.com/maps/documentation/places/web-service/usage-and-billing
- **Keystrokes are debounced 450 ms** before any network call (`homescreen.dart:335`), and empty queries short-circuit — so even the request count is small.

**Both scenarios modeled (per new-destination lookup, India rates):**

| Scenario | Autocomplete billing | Place Details | Cost/lookup |
|---|---|---|---|
| **Current (session token, correct)** | $0 (session usage free) | $1.50/1k | **$0.00150** |
| **Bug: no/broken session token** | ~5 requests × $0.85/1k = $0.00425 (ASSUMPTION: ~5 debounced billable keystrokes/session; ~11-char query, user pauses ~5×) | $1.50/1k | **$0.00575** (≈3.8×) |

**Quantified value of keeping session tokens** at 100K MAU (1.4M lookups/mo): the bug would add **~$5,950/mo (₹494K/mo)** in Autocomplete Per Request charges. *This is a real lever the code already captures — protect it in review (see §1.5 nits).*

### 1.3 Railway hosting (the proxy)

The app talks to Google **only** through `https://geowake-production.up.railway.app/api` (`api_client.dart:9`); every SKU above is proxied. Railway cost is **not in the research → ASSUMPTION / NEEDS DATA** (Railway 2026 usage-based pricing not fetched):

| Scale | Monthly requests through proxy (≈ arms × ~8 calls) | Railway estimate |
|---|---|---|
| 1K MAU | ~160K | ~$5–20/mo (Hobby/small) |
| 100K MAU | ~16M | ~$50–200/mo (1–2 small instances + egress) |
| 1M MAU | ~160M | ~$500–2,000/mo (autoscaled) |

Railway is a **rounding error** next to the Google bill at every scale — do not optimize it first.

### 1.4 ⚠️ Nearby Search is the model's biggest unknown — and possibly its biggest cost

The metro-validation path fires **2 Places Nearby Search calls per metro arm** (`metro_stop_service.dart:54, :127`). **This SKU is not covered by any research file (NEEDS DATA).** For context, Google's *global* Nearby Search (New) prices around **$32/1k (Pro)** to **~$35/1k (Enterprise)** — i.e. **~20× a Directions call**. If the proxy bills this SKU at anything near that (even India-discounted), Nearby Search **alone dominates the entire cost model** (see the pessimistic column in §3). **Action: confirm the exact SKU + India price the proxy triggers before trusting any total below.**

### 1.5 Code cost-surface nits found (low $, worth a cleanup)

- `places_service.dart:21` `endSession()` **is never called** (only `_ensureSessionToken`'s 3-min timer rotates the token). One token can therefore span multiple back-to-back searches within 3 min. Harmless while session usage is free, but it is not the canonical "one token per search, ended by Place Details" pattern — if Google ever starts charging Autocomplete Session Usage (research flags this is a **promotional "currently free" state**, maps_pricing.md caveat), this becomes a real over-billing. **Call `endSession()` in `_onSuggestionSelected` after Place Details.**
- Session token is `DateTime.now().millisecondsSinceEpoch.toString()` (`places_service.dart:15`), not a UUID v4 — accepted today but not to spec; low risk.
- The app is on the **legacy Directions API** and **legacy Places** (response shapes `routes/legs/steps/status==OK`, `predictions`, `result.geometry` — `direction_service.dart:207`, `api_client.dart:396,423`). Legacy SKUs were frozen 2025-03-01 and are **excluded from the expanded 5M+ volume discounts** and may be sunset. https://developers.google.com/maps/billing-and-pricing/faq — migrating to Routes API + Places API (New) is table stakes regardless of cost.

### 1.6 Per-user monthly cost (at scale, base = 20 arms/user)

| | Optimistic Nearby | Pessimistic Nearby |
|---|---|---|
| $/user/mo | 20 × $0.01350 = **$0.270** | 20 × $0.07450 = **$1.490** |
| ₹/user/mo (₹83) | **₹22.4** | **₹123.7** |

*(This is the fully-metered cost. At low MAU the free tiers zero it out — see §3.)*

---

## 2. REVENUE SIDE — ad revenue per user per month

Model = MONETIZATION.md §7 floor: interstitial/rewarded **every 3 rides**, plus an optional home/post-arrival banner. Grounded in India-specific eCPMs (NOT APAC averages — ecpm.md's single biggest trap is that APAC rewarded ~$8.20 overstates India ~4–8×).

### 2.1 India eCPM + fill assumptions

| Format | India eCPM used | Range (source) | Fill |
|---|---|---|---|
| Interstitial | **$1.50** | $1.00–2.50 India-Android (ecpm.md) https://www.monetizemore.com/blog/how-much-ad-revenue-can-apps-generate/ | 92% https://appdrift.co/blog/12-top-mobile-ad-networks |
| Banner | **$0.20** | $0.10–0.30 India-Android (ecpm.md) | 95% |
| Rewarded (opt-in) | **$3.00** | $1.50–4.00 India-Android, only format that grew in 2025 (ecpm.md) https://bidlogic.io/2025/07/25/ecpm-growth-in-mobile-apps-q1-q2-2025-analysis-and-insights/ | ~70% (thinner India rewarded demand) |

Blended India in-app eCPM sanity band: **$0.40–$1.50** (ecpm.md) https://www.monetizemore.com/blog/how-much-ad-revenue-can-apps-generate/ · India blended AdMob measured ~$0.34 https://www.thesrzone.com/2024/01/admob-ecpm-rates-by-country.html

### 2.2 Impressions/user/month and revenue

**Base user (20 arms/mo):**

| Format | Impr/mo | × fill × eCPM/1000 | $/user/mo | ₹/user/mo |
|---|---|---|---|---|
| Interstitial (every-3) | 6.7 | ×0.92×$1.50 | $0.0092 | ₹0.77 |
| Banner (ASSUMPTION ~30 loads/mo) | 30 | ×0.95×$0.20 | $0.0057 | ₹0.47 |
| Rewarded (ASSUMPTION ~2 opt-ins/mo) | 2 | ×0.70×$3.00 | $0.0042 | ₹0.35 |
| **Total base** | | | **≈$0.019** | **≈₹1.6** |

**Heavy user (60 arms/mo):** interstitial 20 imp, banner ~60, rewarded ~4 → **≈$0.048/user/mo ≈ ₹4.0** — consistent with MONETIZATION.md §1's own "~₹5/user/mo" estimate and with ecpm.md's derived "$0.02–$0.18 per **DAU**/month" (our per-MAU figure sits at/below the low end, as expected since not every MAU is a DAU).

> **Revenue reality:** **$0.02–0.05 per active user per month (₹1.6–4.0).** Revenue is **impression-bound, not eCPM-bound** — a wake-alarm is opened briefly ~1–2×/trip with the screen off during the valuable moment (MONETIZATION.md §0), so there is almost no attention to sell. eCPM tuning cannot fix this.

---

## 3. COST vs REVENUE at 1K / 100K / 1M MAU

Totals below apply India free tiers (70K/SKU/mo) and volume bands ($1.50/1k → $0.38/1k above 5M; Dynamic Maps $2.10 → $0.53). Base usage = 20 arms/user/mo. Revenue at $0.019/user (base) → shown as the mid case.

### 3.1 Monthly Google bill by SKU (optimistic Nearby = $1.50/1k)

| SKU | calls/mo @100K | $/mo @100K | calls/mo @1M | $/mo @1M |
|---|---|---|---|---|
| Directions (2/arm) | 4.0M | $5,895 | 40M | $20,695 |
| Place Details (0.7) | 1.4M | $1,995 | 14M | $10,815 |
| Geocoding (2.2) | 4.4M | $6,495 | 44M | $22,215 |
| Nearby Search (2, optimistic) | 4.0M | $5,895 | 40M | $20,695 |
| Dynamic Maps (1.5) | 3.0M | $6,153 | 30M | $23,603 |
| Autocomplete | — | $0 | — | $0 |
| **Google total (optimistic)** | | **$26,433** | | **$98,023** |

### 3.2 The headline table

| | **1K MAU** | **100K MAU** | **1M MAU** |
|---|---|---|---|
| Arms/mo | 20K | 2.0M | 20M |
| **Google bill — optimistic Nearby** | **~$0** (all SKUs < 70K free tier) | $26,433/mo | $98,023/mo |
| **Google bill — pessimistic Nearby ($32/1k)** | ~$0 | ~$146,300/mo | ~$1.36M/mo |
| Railway (ASSUMPTION) | ~$15 | ~$120 | ~$1,000 |
| **Total cost/user/mo (optimistic)** | **~$0.015** (₹1.2, mostly Railway) | **$0.266** (₹22.1) | **$0.099** (₹8.2) |
| **Total cost/user/mo (pessimistic)** | ~$0.015 | $1.464 (₹121.5) | $1.361 (₹113) |
| **Ad revenue/user/mo (base)** | $0.019 (₹1.6) | $0.019 (₹1.6) | $0.019 (₹1.6) |
| **Net/user/mo (optimistic Nearby)** | **+$0.004 🟢** | **−$0.247 🔴** | **−$0.080 🔴** |
| **Net/user/mo (pessimistic Nearby)** | +$0.004 🟢 | −$1.445 🔴 | −$1.342 🔴 |
| **Monthly P&L (optimistic)** | +$4 | **−$24,700** | **−$79,600** |
| **Monthly P&L (pessimistic)** | +$4 | −$144,700 | −$1.34M |

**Read this table as the whole story:**
1. **You are profitable at 1K MAU** — but only because every SKU sits inside the 70K/mo India free tier. This is a **free-tier mirage**, not real margin.
2. **At 100K MAU you fall off a cliff** — the free tiers are now noise and per-user cost jumps to $0.27 (optimistic) while revenue stays flat at $0.019. Ads cover **~7%** of cost.
3. **Per-user cost *drops* at 1M** ($0.10) because the 5M+ volume band ($0.38/1k) kicks in — but you're **still ~5× underwater** on ads alone.
4. **If Nearby Search bills at Pro rates, the company is uninvestable** on this architecture (−$1.3M/mo at 1M). Resolving §1.4 is priority #1.

### 3.3 Break-even eCPM / fill (the ads-only fantasy)

To cover the **$0.266/user/mo** (optimistic, 100K) with the base user's **6.7 interstitial impressions/mo at 92% fill**:

> **Break-even interstitial eCPM = $0.266 / (6.7 × 0.92) × 1000 = ~$43.**

India interstitial reality is **$1.00–2.50** (ecpm.md) — you need **~17–43× the achievable eCPM.** Even the heavy user (20 impr/mo) needs **~$14.5 eCPM (~6–14×)**. **Conclusion: no realistic eCPM or fill rate closes the gap. Ads are a floor, not the engine** — exactly MONETIZATION.md's thesis. Break-even must come from the **cost** side and/or **non-ad revenue** (one-time Pro unlock, last-mile affiliate — MONETIZATION.md §B/§C).

---

## 4. RANKED COST OPTIMIZATIONS

Modeled at 100K MAU, optimistic-Nearby baseline **$26,433/mo**. Ranked by $ saved.

| # | Lever | What it removes | $/mo saved @100K | ₹/mo saved | Effort |
|---|---|---|---|---|---|
| **1** | **Self-host routing (OSRM), delete Directions API** | All Directions calls → India OSM extract (1.6 GB) on one small VM; OSRM ~3–4 GB RAM. | **$5,895 → ~$90–300 total infra ⇒ ~$5,600–5,800 saved** (and Directions scales to $20,695/mo @1M) | ₹465K–481K | High (pipeline) |
| **2** | **Kill Nearby Search — validate metro stops from local GTFS/OSM** | Both `metro_stop_service` Nearby calls (`:54,:127`). Delhi DMRC GTFS is open; OSM rail geometry (already in-app) is the fallback. | **$5,895 saved (optimistic) → up to ~$125K/mo saved (pessimistic Pro rate)** | ₹489K → ₹10.4M | Medium |
| **3** | **Self-host tiles (Protomaps PMTiles + MapLibre), drop Dynamic Maps** | All map-load billing → single PMTiles file on Cloudflare R2 (zero egress) ≈ $0–5/mo. | **$6,153 → ~$5 ⇒ ~$6,148 saved** | ₹510K | Medium–High (replace `GoogleMap` widget) |
| **4** | **Self-host geocoding (Nominatim) + cut same-state check to 1 call** | Geocoding is the #1 line ($6,495). Nominatim on the same India VM is ~free; and same-state validation does **2** reverse-geocodes/arm (`homescreen.dart:271–274`) — cache origin's state per session (origin rarely changes) to halve it even before self-hosting. | Self-host: **~$6,495 saved.** Halving alone: **~$3,250 saved.** | ₹539K / ₹270K | Med / Low |
| **5** | **On-device route reuse / longer cache TTL** | Directions re-fetches. RouteCache TTL is only **5 min** (`route_cache.dart:86`) and reroute uses `forceRefresh:true`. Recents+frequency already exist (MONETIZATION §B) — reuse the cached polyline for re-arms of the same O-D and lengthen TTL to hours. | ~15–30% of remaining Directions/Nearby ⇒ **~$1,000–2,000 saved** (pre-self-host); reduces call volume that keeps you under free tiers longer. | ₹83K–166K | Low |
| **6** | **Guarantee India billing + migrate off legacy APIs** | Wrong (global) billing sheet is ~2–3× India. Confirm India-based Cloud billing (INR). Migrate Directions→Routes, Places→Places (New) to regain 5M+ volume discounts. | Up to **~50% of the entire bill (~$13,000)** if currently on global pricing. **NEEDS DATA: confirm account region.** | up to ₹1.08M | Low (config) |
| **7** | **Session tokens + debounce (already shipped — protect it)** | Per-keystroke Autocomplete billing. Already correct (§1.2); add `endSession()` + guard in review. | Prevents a **~$5,950/mo regression** | ₹494K | Trivial |
| **8** | **Static Maps instead of Dynamic for the picker** | If the home picker doesn't need pan/zoom, Static Maps is $0.60/1k vs Dynamic $2.10/1k (India). Partial version of #3. | ~$1,000–2,000 of the Dynamic line | ₹83K–166K | Low |

### 4.1 The self-hosted-routing lever, modeled explicitly (it is the biggest)

routing_alt.md is unambiguous for India scale:

- India OSM extract = **1.6 GB** (2.6% of planet) → OSRM car+foot fits **~3–4 GB RAM**, one small VM. https://download.geofabrik.de/asia/india.html
- Full self-host stack (OSRM + OTP2 for metro GTFS + Protomaps tiles): **~$90/mo (single AWS Lightsail Mumbai box) to ~$300/mo (HA pair)**. https://aws.amazon.com/lightsail/pricing/
- vs. Google routing at ~5M calls/mo: **~$7,395/mo India / ~$15,550/mo global.** https://developers.google.com/maps/billing-and-pricing/pricing-india
- = **95–98% infrastructure cost cut**; converts a **$90K–$187K/yr** recurring routing bill into **~$1K–$4K/yr infra + one-time engineering.** The binding cost is eng/ops (monthly OSM rebuilds, HA, on-call — routing_alt.md caveats), and the one real gap is **transit-data coverage** (Delhi DMRC GTFS is open; many metros aren't → OSM rail-geometry fallback, which GeoWake already uses).

### 4.2 Stacked effect

Applying #1+#2+#3+#4 (self-host routing, drop Nearby, self-host tiles, self-host geocoding) turns the **$26,433/mo (optimistic) / $146,300/mo (pessimistic)** Google bill at 100K MAU into roughly **$300–600/mo of self-hosted infra** — a **~$26K–146K/mo saving**, i.e. per-user cost from $0.26–1.46 down to **~$0.003–0.006**. **That is below the $0.019 ad revenue line — it flips the unit economics from red to green using cost alone, without touching eCPM or adding IAP.**

---

## 5. BOTTOM LINE

**Yes, GeoWake loses money per user at scale on Google-metered pricing, and it cannot be fixed with ads.** At 1K MAU the app is marginally profitable — but only because every Maps SKU hides inside India's 70K-call/month free tier; that is a mirage, not margin. The moment usage crosses the free tiers (~100K MAU), fully-metered cost jumps to **$0.27–1.46 per active user per month** while realistic India ad revenue is stuck at **$0.02–0.05** — a 5–70× hole that would require a **~$43 interstitial eCPM (17–43× India reality)** to close, which is impossible. The cost is dominated by five per-arm Google calls the code makes today (2× Directions, 2.2× Geocoding, 2× Nearby Search, 1.5× Dynamic Maps, 0.7× Place Details), and the scariest of them — **Nearby Search for metro-stop validation — is an unpriced SKU that, at Google's Pro rate, single-handedly makes the model catastrophic (−$1.3M/mo at 1M MAU); pinning its real price is priority #1.** The autocomplete "keystroke bomb" is **not** a problem — session tokens and a 450 ms debounce are already correctly in place and worth ~$5,950/mo at 100K; just wire up `endSession()`. **The cheapest path to break-even is to delete the cost, not chase eCPM:** self-host routing on OSRM (India OSM is only 1.6 GB → ~$90–300/mo vs. a $7K–15K/mo Google routing bill, a 95–98% cut), replace Nearby Search with local Delhi/OSM GTFS, and self-host tiles (Protomaps) and geocoding (Nominatim) on the same small Mumbai VM. Stacked, that collapses the 100K-MAU bill from ~$26K (optimistic) / ~$146K (pessimistic) per month to **~$300–600/mo total**, dropping per-user cost to ~$0.003–0.006 — **below the ad line, flipping the unit economics green on cost alone** — after which the MONETIZATION.md intent levers (one-time Pro unlock, last-mile affiliate) become pure upside rather than a survival requirement.

---

### Appendix — figures to confirm before trusting this (NEEDS DATA)

1. **Nearby Search SKU + India price** the Railway proxy actually triggers (§1.4) — swings the model by 20×.
2. **Is the Google Cloud billing account India-qualified?** (§0.3) — ~2–3× on everything.
3. **Dynamic Maps map-load counting** for the shipped Maps SDK version (per-session vs per-instance) — the 1.5/arm assumption.
4. **Railway 2026 pricing** (§1.3) — assumed, not fetched.
5. **Real arms/user/month + %-reuse-of-recents** from live telemetry — the whole model scales linearly on this.
6. **How long "Autocomplete Session Usage currently free" lasts** — no published end date (maps_pricing.md); stress-test a chargeable scenario.
</content>
</invoke>
