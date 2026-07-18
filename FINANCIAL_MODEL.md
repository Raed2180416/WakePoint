# GeoWake / WakePoint — Complete Financial Model (India, metro-first)

_2026-07-15. Assumes the `COST_LEAKS.md` fixes are shipped (capped key, persistent commute cache, no retry-multiplication, UUID session tokens). Builds the full picture: per-user cost incl. worst-case reroutes, the starting-position amplifier, ad + subscription break-even, India market sizing city-by-city, and a 5-year P&L. **Every external number is marked (verify); all figures are illustrative — the value is the structure, flex the assumptions.** FX: ₹84 = $1._

---

## PART A — What a user actually costs (post-fix)

### A.1 Cost is only ever four Google SKUs
| SKU | Rate (verify) | When it fires |
|---|---|---|
| Directions | **$5.00 / 1k** = $0.005/call | Each *new/changed* route fetch + each reroute |
| Autocomplete (per session) | ~$17 / 1k = $0.017/search | A destination search that ends in a selection |
| Place Details | (bundled in session) | Resolving the picked place |
| Geocoding | $5 / 1k = $0.005 | Reverse-geocode station names (cache for days) |

Mobile map display, compute, and Firebase are **free/fixed** — not per-user.

### A.2 Per-arm cost, post-fix
| Scenario | Directions | Search | Cost |
|---|---|---|---|
| **Saved/recent route, good GPS** (the daily commute) | 0 (persistent-cache hit) | 0 (taps recent) | **~$0.000** |
| **New route, good GPS, 0 reroute** | 1 | 1 session | **~$0.022** |
| **New route + N reroutes** | 1 + N | 1 | $0.022 + N×$0.005 |

The daily commuter's repeat trip is **effectively free** once the persistent cache is in — the fix in `COST_LEAKS.md §2` is what makes this line ~$0 instead of ~$0.005 every morning.

### A.3 Worst-case reroutes — and why they can't blow up the bill
Reroute mechanics from source: fires on **>150 m deviation sustained 6 s** (`deviation_config.dart:31,50`), then a **cooldown** — default **10 s** (`:58`), 2 s in the high-accuracy power tier (`power_policy.dart:23`), 20–30 s on low battery. **Failed reroutes self-terminate tracking after 3** (`trackingservice.dart:1483,1543`); *successful* reroutes are uncapped but each needs a fresh sustained re-deviation.

So the ceiling is `trip_time ÷ (6 s sustain + cooldown)`, and each reroute is only **$0.005**:

| Trip | Reroute ceiling (10 s cooldown) | Worst-case reroute cost |
|---|---|---|
| 30 min | ~110 | **~$0.56** |
| 60 min | ~225 | **~$1.13** |
| Realistic "messy" multimodal trip | 5–15 | **~$0.03–0.08** |

Two things bound this in practice: (1) **reroutes need GPS + network, so they don't happen in the metro tunnel** — the core metro trip reroutes ≈ 0; reroutes are an above-ground driving/multimodal phenomenon. (2) Even the pathological ceiling is **~$1/trip** because Directions is half a cent. **Reroutes are not a cost risk** — the global daily spend cap (`COST_LEAKS §1`) catches any true anomaly.

### A.4 ⚠️ The real cost amplifier: starting position
This app is **unusually dependent on the user's starting position**, and it hits both cost and correctness:

**Cost:** the route cache invalidates on **origin deviation ≥ 300 m** (`route_cache.dart:196`). A rider whose GPS-reported start varies day-to-day — platform vs. entrance vs. street, or a cold-start GPS error of 100–300 m (routine indoors / near a station) — registers as a **different origin → cache miss → full refetch**, defeating the §2 fix. Worse, a wrong origin makes the fetched route slightly wrong → **immediate apparent deviation at trip start → spurious reroutes**. A bad start therefore triggers *both* a re-bill *and* extra reroutes — the compounding worst case.

**Correctness (the bigger deal):** the reachability never-late anchor is seeded at the route origin / first real fix (`GAP_ANALYSIS` cold-start gap). A bad or missing start position (e.g., arming already underground with no GPS) anchors the physics guarantee in the wrong place → fires at the wrong station or distance. **The product's core promise assumes the user arms with a decent GPS fix at a known start.** This is a genuine product constraint, not just a cost note.

**Mitigations:** snap the arm-origin to the nearest known station when GPS is coarse (you have the 805-station dataset — free, and it *stabilizes* the cache key); widen the cache origin-tolerance to "same nearest station" instead of 300 m raw; refuse/soft-warn on arming with a low-accuracy fix; seed the anchor from the first *on-route* fix, not raw origin.

### A.5 Per-user monthly cost tiers (post-fix)
| Tier | Who | $/user/mo |
|---|---|---|
| Best | Daily metro commuter, saved route, good GPS, in-tunnel (no reroute) | **~$0.00–0.02** |
| **Typical** | Mixed use, a few new routes, occasional reroute | **~$0.03–0.08** |
| Worst (fixable) | Variable start defeats cache every arm + reroute-prone above-ground trips | **~$0.30–0.60** |
| Pathological (not a real user; capped) | Daily 100-reroute trips | ~$15–30 → **caught by the daily spend cap** |

**Design number for the model: ~$0.05/MAU/month.** The worst case is a *cost-side* problem (starting-position → cache) solved by §A.4, not something you out-earn with ads.

---

## PART B — Ad + subscription break-even (India rates)

### B.1 India eCPMs (2026, verify)
Rewarded **~$4.2** · Interstitial **~$3.6** · Banner **~$1.6** · Native **~$0.9** (≈ ₹350 / ₹300 / ₹133 / ₹75 RPM). Per impression: rewarded $0.0042, interstitial $0.0036.

### B.2 Ad inventory without being annoying
The alarm moment is sacred (never touch it). Usable, low-friction placements: **rewarded/opt-in** ("skip your ads today / support the app" — highest eCPM, self-selects the tolerant), **post-arrival native card** (user's done, not time-pressured — also the affiliate surface), and an **arming-screen native** while the route loads. Frequency-capped **every 3 rides** (already built in `AdPolicy`). A committed commuter (~60 rides/mo) sees ~**20 ad opportunities/mo**; a blended MAU ~**8**.

### B.3 Break-even math (per free MAU/month)
| Line | Assumption | $/MAU/mo |
|---|---|---|
| Ad ARPU | ~8 blended impressions × ~$3 eCPM | **~$0.024–0.05** |
| Subscription | 2% × ₹399 one-time ÷ 12 mo (Pro users see no ads) | **~$0.006–0.008** |
| **Pre-affiliate revenue** | ads + subs | **~$0.03–0.06** |
| **Cost** | §A.5 typical | **~$0.05** |
| **Pre-affiliate margin** | | **~ –$0.01 to +$0.01 → break-even** |

**Verdict on "at the very least break even": yes — ads + subs land right at break-even at India rates**, with margin thin and sensitive to the starting-position cache issue (§A.4). It is *not* a profit engine by itself. Two levers move it clearly positive:
- **Rewarded-forward ad mix** (push opt-in rewarded over banners) lifts ad ARPU toward $0.06–0.08 → a real small margin.
- **The subscription's job isn't per-user-month cash** (one-time unlocks amortize tiny) — it's (a) ad-free for the ~2% who'd pay, and (b) it converts your **heaviest commuters** (who cost the most in Maps and value saved-routes/multi-leg most) into payers. That's the unit-economics lock, not the revenue.

### B.4 The line that turns break-even into a business: last-mile affiliate
Post-arrival ride-hailing CPA (₹25/booking, verify): blended MAU ~25 arrivals/mo × **2% attach** × ₹25 = **~₹12.5 ≈ $0.15/MAU/mo** — **3× the entire ads+subs stack**, and it *strengthens* retention. At 5% attach it's ~$0.37/MAU. This is the profit layer; ads+subs are the break-even floor beneath it.

**Blended ARPU used in the model:** pre-affiliate **$0.05** (break-even), post-affiliate **~$0.20** (base) / **$0.35** (optimistic).

---

## PART C — India market sizing (metro travelers, covered cities)

### C.1 Daily metro ridership by city (2025, verify)
| City | Daily riders (trips) | In app dataset? |
|---|---|---|
| Delhi (+NCR) | ~4.6–6.5 M | ✅ |
| Bengaluru (Namma) | ~1.0 M (crossed 10 lakh, Aug 2025) | ✅ |
| Mumbai (all lines) | ~0.7 M | ✅ |
| Kolkata | ~0.6 M | ✅ |
| Hyderabad | ~0.47 M | ✅ |
| Chennai | ~0.32 M | ✅ |
| Pune, Ahmedabad, Nagpur, Lucknow, Jaipur, Kochi, Kanpur, Nagpur… | ~0.05–0.15 M each | ✅ (19 cities / 805 stations total) |
| **India total** | **~11.2 M/day** | — |

### C.2 TAM → SAM → SOM funnel (the honest narrowing)
| Layer | Definition | Size (verify) |
|---|---|---|
| **Trips/day** | Metro entries nationwide | ~11.2 M/day |
| **Monthly metro riders (humans)** | Unique people riding in a month | **~25–30 M** (TAM) |
| In covered 19 cities | ~90% of ridership | ~23–27 M |
| Android smartphone owners | ~80% × ~95% Android | ~18–20 M |
| **Would value a dedicated commute alarm** | vs. a phone timer / nothing; skews long-commute, nappers, new-to-city, night-shift | **~4–6 M (SAM)** |
| **Realistically obtainable (solo, organic, crowded free category)** | 1–20% of SAM over 5 yrs | **~50 k – 1 M MAU (SOM)** |

The brutal honesty: the alarm is a *tail-value* feature (it matters the day you'd miss your stop), the category is crowded with free apps + Google Maps' built-in alert, and you have no paid-UA budget. So most of the 25–30 M never convert. **SAM ~5 M; realistic SOM is 1–5% (base) to ~20% (optimistic) of that over five years.**

### C.3 Beachhead logic
Win **one city to density first — Bengaluru** (tech-savvy, ~1 M/day, your validated test corridor, English-friendly ASO). One city at 10% beats twenty cities at 0.5% for retention proof, word-of-mouth, and any acquisition conversation. Then Delhi (5× the volume) and Hyderabad.

---

## PART D — 5-year financial model

### D.1 Capture scenarios (MAU, organic, solo)
| End of | Conservative | Base | Optimistic |
|---|---|---|---|
| Year 1 (Bengaluru) | 3 k | 8 k | 20 k |
| Year 2 (+Delhi/Hyd) | 15 k | 40 k | 120 k |
| Year 3 (multi-city) | 40 k | 150 k | 400 k |
| Year 5 | 120 k | 500 k | 1.2 M |
| % of ~5 M SAM @ Y5 | ~2.4% | ~10% | ~24% |

### D.2 P&L per scenario (annualized, ₹84=$1)
Using ARPU $0.05/MAU/mo **pre-affiliate** (break-even) and **$0.20/MAU/mo post-affiliate** (base attach); cost ~$0.05/MAU/mo; fixed server ~$240/yr.

| | Conservative Y5 (120k) | Base Y3 (150k) | Base Y5 (500k) | Optimistic Y5 (1.2M) |
|---|---|---|---|---|
| **Pre-affiliate annual revenue** | ~$72 k | ~$90 k | ~$300 k | ~$720 k |
| Pre-affiliate profit | ~**$0** (break-even) | ~$0 | ~$0 | ~$0 |
| **Post-affiliate annual revenue** | ~$288 k | ~$360 k | ~$1.2 M | ~$2.9 M |
| Post-affiliate annual **profit** | ~**$216 k** | ~$270 k | ~**$900 k** | ~**$2.2 M** |

(Post-affiliate margin ≈ $0.15/MAU/mo after the ~$0.05 cost.)

### D.3 Break-even MAU
- **Ads + subs only:** break-even is ~immediate per-user (margin ≈ $0), so the only true fixed cost to cover is the **server (~$20/mo)** → break-even at **~400–800 MAU**. Effectively you break even almost as soon as you launch — which is exactly the "worst case: lose no money" mandate.
- **With affiliate:** every MAU contributes ~$0.15/mo → 150k MAU ≈ **$270k/yr profit**.

### D.4 What this says
1. **Break-even is trivially achievable** (a few hundred MAU) — the mandate's floor is safe.
2. **Ads + subs alone are a break-even hobby, not a business** at India WTP — consistent with Moovit/Citymapper (huge usage, poor consumer monetization).
3. **The business is the affiliate/intent layer.** It's 3–5× the ad+sub stack and it's the difference between "$0 profit" and "$0.9–2.2 M/yr."
4. **Even the optimistic case is a ~$1–3 M/yr revenue business** — a strong *solo* outcome and consistent with the strategic-exit valuation ranges in `STANDOUT_AND_VALUATION.md`, **not** a venture rocket. The larger value remains strategic (surface + data + IP), not the standalone P&L.
5. **Cost is never the binding constraint** (bounded, fixable, ~$0.05/MAU); **India willingness-to-pay is.** Optimize the affiliate attach rate and retention, not ad volume.

---

## PART E — Honest verdict

- **Can it break even? Yes, almost trivially** — ads + subs cover the tiny per-user Maps cost, so you're profitable past a few hundred MAU and the "lose no money" floor holds.
- **Is break-even the goal? No** — at India rates ads+subs is a wash. The last-mile **affiliate is the actual business**, and it also happens to be the strategic story (`STANDOUT_AND_VALUATION.md`).
- **The market is real but the obtainable slice is small and slow:** ~5 M SAM, ~50k–1M MAU over 5 years solo/organic. Plan for the base case (~150k MAU / ~$270k/yr with affiliate by Y3), hope for the optimistic.
- **The two numbers that decide everything:** (1) **retention** (does the promise actually work on a real commute → word-of-mouth in a crowded free category), and (2) **affiliate attach rate** (2% vs 5% is the difference between $0.9M and $2M+/yr at scale). Cost, reroutes, and ad eCPM are all second-order.
- **Fix the starting-position cache/anchor issue (§A.4) early** — it's the one thing that simultaneously raises cost, degrades the core promise, and hurts retention.

_Verify before betting: India metro ridership by city; smartphone/Android penetration among riders; Google Maps SKU rates; India eCPMs; last-mile CPA terms. Sources logged in `STANDOUT_AND_VALUATION.md` + this session's searches._
