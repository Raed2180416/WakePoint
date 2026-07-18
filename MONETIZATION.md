# GeoWake — Monetization Deep-Dive

_2026-07-15. Reasoning material for the next agent, not a prescription. Numbers marked (verify) are informed estimates for India as of writing — re-check current rates/programs before committing. The point of this doc is to give you the economics and the strategic tensions so you can reason to your own portfolio, not follow a checklist._

---

## 0. The frame: what kind of thing are you monetizing?

Three properties of GeoWake dominate every monetization decision. Reason from these, not from "what do other apps do":

1. **Usage is passive and eyes-closed.** The core value happens with the screen off, often while the user sleeps. There is almost **no in-app attention to sell during the core flow.** Unlike a game or a feed, you cannot interrupt the valuable moment — the valuable moment is *the absence of interaction*.
2. **The two moments with attention are both time-pressured.** A "ride" is: **arm** (user is about to travel — often standing on a platform, in a hurry) → travel (dark) → **arrive/wake** (user is getting off a train, needs to move *now*). Both endpoints have attention but also urgency. An ad that adds friction at either can cost you the user.
3. **Trust is the asset and the constraint.** It's a safety app that knows when you sleep and where you commute. Aggressive or creepy monetization doesn't just annoy — it breaks the one thing (trust) that the biggest future revenue line (aggregate mobility data, see HANDOFF §4) is gated on. **Monetization that erodes trust has negative expected value even when it earns money.**

The synthesis these three force: **monetize the moments (intent), not the attention (impressions).** The arm moment signals "I'm about to travel"; the arrive moment signals "I need last-mile + I'm at a place." Those intents are worth far more than a video impression — and that's where this doc ends up.

---

## 1. Your proposal: 30s video, skippable at 15s, every 3 rides — analyzed

**Verdict: fine as a baseline revenue floor, wrong as the primary strategy, and the placement is the hard part.**

**Economics (verify eCPMs).** Assume a committed commuter: ~2 rides/day → ~60 rides/mo → ~20 video ads/mo at every-3.
- India skippable-video effective eCPM ≈ **$1.5–4** (advertisers pay less for skippable; non-skippable interstitial ≈ $2–7, rewarded ≈ $4–12). Take $3.
- 20 impressions × $3/1000 ≈ **$0.06/user/mo ≈ ₹5/user/mo.**
- 100K MAU → ~₹5L/mo; 1M MAU → ~₹50L/mo. **Real at scale, modest early, and this is the *optimistic* fill-and-rate case.**

**The placement problem (this is the crux).** A 30s forced video needs a screen with attention. Your only two candidates both fight urgency:
- **At arm-time:** the user wants to set the alarm and pocket the phone before their train comes. A forced 30s pre-roll here is friction at the worst moment → arm-abandonment, uninstalls. Avoid forced video here.
- **Post-arrival:** better *intent*, but the user is physically getting off a train — also time-pressured. A forced video the instant the alarm rings is dangerous (it competes with the alarm's job). It only works if deferred to a **post-arrival summary screen** the user opens *after* they're off — which most won't open.

**So the honest read:** the every-3-rides frequency cap is good; the *format* (forced video) is mediocre for a time-pressured utility. Two better shapes of the same idea:
- **Rewarded video instead of forced interstitial** — opt-in ("watch a 30s ad to unlock [X] for today / skip your next ad / support the app"). Higher eCPM ($4–12), zero forced friction, no churn, and it self-selects the ad-tolerant. For a utility with urgent moments, rewarded ≫ interstitial.
- If you *do* run a forced interstitial, put it on the **arm-confirmation screen only after the alarm is set** (so the safety action is never blocked), capped every-3-rides, skippable-at-5 not 15 (skippable-15 on a 30s ad barely earns more than skippable-5 and annoys more).

**One-line takeaway:** ship the frequency-capped video as a *floor*, but make it rewarded/opt-in, and understand it will earn ~₹5/user/mo — which the next section shows is 10–50× below what the same arrival moment is worth if you monetize *intent* instead of *impressions*.

---

## 2. The full option space (with honest India economics + when each fits)

### A. Display / video advertising — the floor, not the business
- **Formats & rough India eCPM (verify):** banner $0.2–1.5 · native $1–5 · interstitial $2–7 · rewarded video $4–12 · app-open $1–4.
- **Best placement by far: post-arrival, native, location-aware.** "You've arrived at Indiranagar" + a native card is contextual, not interruptive, and can be *sold as local inventory* (§C) rather than filled with generic AdMob at floor rates. This is where display becomes non-floor.
- **Strategic fit:** universal, instant, low-effort — turn it on for cash flow. But India eCPMs mean it's a **rounding error until you have millions of MAU**, and it taxes trust. Treat as supplementary.

### B. Freemium (one-time unlock ≫ subscription in India)
- **India reality:** 1–3% paid conversion (low end), strong preference for **one-time unlocks** over recurring. Price a "Pro" unlock ~₹299–499; offer a cheap annual (₹199–299) too for LTV.
- **What people pay for here:** ad-free, multi/recurring alarms, multi-leg journeys, offline maps + all cities, widget/Wear, custom sounds, family/shared alarms. (Recents/frequency is already built.)
- **Never paywall reliability** — the alarm working is the trust base and the free tier's reason to exist.
- **Math:** 1M MAU × 2% × ₹399 one-time = ₹80L (one-time, not recurring). Subscription = better LTV, lower conversion. **Fit:** launch-viable, steady, but capped by India WTP — it's a nice line, not a rocket.

### C. Contextual commerce / affiliate — **the asymmetric opportunity, and the reason this app is special**
This is the one to actually reason hard about. GeoWake owns the **last-mile-intent moment**: the user just exited transit and needs to get from the station to their real destination. That intent is worth *orders of magnitude* more than an impression.
- **Last-mile ride-hailing** (Rapido / Ola / Uber): "Book a ride from the station" at arrival. Referral/CPA programs pay per first-ride or per-booking (verify current terms; historically ₹20–100/CPA range). This is *aligned with the user's actual need*, not extractive.
- **Food / coffee** (Swiggy/Zomato + local merchants): "You're near X" deals at arrival.
- **Why it dominates display:** even pessimistically — 60 rides/mo, 5% book a last-mile ride via the app, ₹25 CPA → **₹75/user/mo.** That's ~15× the video-ad estimate. At 20% conversion it's ₹300+/user/mo. The arrival moment monetized as *intent* is 10–50× the same moment monetized as an *impression*.
- **Strategic fit:** the single highest-leverage monetization for GeoWake, non-creepy (it serves a real need), and it makes the "arrival ad" a *feature* users like rather than a tax. Needs partnership/affiliate integration (BD work), but the product surface (a post-arrival card) is trivial. **Reason hard about making this the centerpiece, not display.**
- **Emerging lever (verify):** ONDC (Open Network for Digital Commerce) is India's open commerce protocol — potentially lets a small app plug into local commerce/mobility without per-merchant deals. Worth investigating as it matures.

### D. Aggregate mobility data B2B — the moat, gated on trust (v2+)
- Covered in detail in HANDOFF §4 (DPDP Act, aggregation, k-anonymity, consent). **The big long-term line, but it requires trust + scale first, and the aggregates aren't even valuable until you have density.** Cleaner first buyer = transit authorities / urban planners (aggregate O-D flows), not restaurant micro-targeting. Do not touch until the core has trust; doing it wrong ends the company.

### E. Transit / ticketing integration (partnership-heavy, later)
- Metro card recharge, digital ticketing (some Indian metros + UPI/ONDC), possibly a cut of ticket sales if integrated. High-intent (you know their route), but partnership- and BD-heavy. A later, defensible expansion once you have relationships and volume.

### F. B2B licensing / SDK (long-term optionality)
- The **reachability never-late wake guarantee** is genuinely novel IP. License it as an SDK / white-label to transit-authority apps or as an "alarm-as-a-feature" for other apps. Not a near-term revenue line, but real optionality — the tech, not the consumer app, may be the more valuable asset to some acquirers/partners.

---

## 3. Strategic synthesis — how to reason about the portfolio

Don't pick one; sequence a portfolio, gated by the trust/scale you have at each stage. The logic:

- **The revenue hierarchy for THIS app is intent > convenience > attention > data.** Contextual commerce (intent) can out-earn display (attention) 10–50× per user; premium (convenience) is steady but WTP-capped; data (the biggest ceiling) is trust-gated and comes last. Reason from that ranking.
- **Launch (build trust + volume):** free reliable alarm + one-time Pro unlock + *rewarded/opt-in* video floor. Keep ads away from the alarm. Instrument everything (HANDOFF §3) — you can't optimize monetization you can't measure, and the ride telemetry is also your data-asset seed.
- **Early growth (monetize the moments):** build the **post-arrival contextual card** and wire the **last-mile ride-hailing affiliate** — this is likely your biggest per-user lever and it's aligned with the user's need, so it *strengthens* retention instead of taxing it. Layer local food/commerce.
- **Scale (unlock the ceiling):** with trust + density, stand up the **aggregate mobility data** line the right way (consent, aggregation, DP), starting with transit-authority/urban-planning buyers. Explore ticketing/ONDC integration and SDK licensing as optionality.

The trap to avoid: over-indexing on ads because they're the easy default. For a passive, trust-critical utility with time-pressured moments and Indian eCPMs, display ads are a floor you turn on, not a strategy you build on. The building happens on **intent (contextual commerce)** and, eventually, **the data moat** — both of which *require* the trust that aggressive ad monetization would spend.

---

## 4. Open questions for you (the next agent) to reason about

These are genuinely unresolved — reason them out with current data, don't assume my framing is right:
- What's the *real* churn cost of the forced-vs-rewarded video at the arm/arrival moments? A/B it; the ~₹5/user/mo isn't worth even a small uninstall bump.
- What are the *actual current* CPA terms and integration effort for Rapido/Ola/Uber/Swiggy affiliate in 2026, and does ONDC shortcut the partnership cost? This determines whether §C is a ₹75 or a ₹300 per-user line — decisive for the whole strategy.
- At what MAU does aggregate mobility data cross from "worthless (sparse cells fail k-anonymity)" to "valuable"? That sets when §D is worth the legal build.
- Does the reachability IP have more value as a licensed SDK than as a consumer app for your specific goals/exit? Worth a deliberate think, not a default.
- India WTP: is a one-time unlock or a cheap annual sub the better LTV given your CAC and retention curve? Depends on numbers you'll have that I don't.

The meta-point: I've given you the economics and the tensions. The portfolio is a reasoning problem over *your* CAC, retention, trust, and BD bandwidth — which you'll know better than this doc. Optimize for the intent moments, protect the trust, and treat display ads as the floor they are.
