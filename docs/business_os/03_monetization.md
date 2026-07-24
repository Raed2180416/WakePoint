# Business OS — Monetization

> This chapter tracks a decision that is **yours** (Raed's), not the audit's.
> Two developed plans exist; this file lays out the honest tradeoff and records
> which one is active. It does NOT overrule `PASS_PRICING_ANALYSIS.md` — that is
> the detailed spec for the pass model and stays the source of truth for it.

## 0. The open decision (pick one; drives IAP product setup + paywall UX)

**Plan A — Prepaid pass ladder** (your plan, `PASS_PRICING_ANALYSIS.md`):
₹7 daily · ₹35 weekly · ₹99 monthly · ₹899 yearly, all **prepaid** (not
auto-renewing, so no RBI e-mandate friction), each unlocking full Pro for its
duration, coexisting with the rewarded day-pass. Optional ₹1,950/₹2,400 lifetime
in v2.

**Plan B — ₹199 one-time Pro** (what the code ships today):
single one-time unlock + rewarded day-pass. `monetization_service.dart:28`
(`proPriceFallback = '₹199'`), `premium_service.dart` (`proOneTime`).

**DECISION (2026-07-24, Raed): Plan A — the full prepaid pass ladder.**
₹7 daily · ₹35 weekly · ₹99 monthly · ₹899 yearly, all prepaid, each unlocking
full Pro for its duration, coexisting with the free rewarded day-pass. Lifetime
(₹1,950/₹2,400) held for v2. `PASS_PRICING_ANALYSIS.md` is the build spec (§7 =
implementation path, §8 = paywall UX). Plan B (₹199 one-time) is what the code
ships *today* and is the fallback if the ladder proves too heavy — but the
target is the ladder.

Implementation state: **BUILT** (2026-07-24). `premium_service.dart` now defines
the 4 SKUs (`proDaily/Weekly/Monthly/Yearly` + `passLadder`), `buyPass()`
(consumable, grants time-based Pro via the shared expiry field — extends, never
shortens), `passDurationFor()`; the billing seam has `buyConsumable`
(auto-consume, so passes re-buy each period); `monetization_service.buyPass()`
+ `priceOrFallback()` facade; and the paywall renders the selectable ladder
(Monthly pre-selected, per-SKU store prices with ₹7/35/99/899 fallbacks, UPI
pending handling, rewarded day-pass + restore kept). 9 pass-ladder tests green.
The legacy one-time (`proOneTime`) is retained + restorable so no existing
purchaser loses Pro. **Remaining (user action): create the 4 consumable SKUs in
Play Console** — see `01_launch_readiness.md`.

> Historical note: an earlier draft of this file wrongly "committed" to Plan B
> and dismissed A citing Citymapper. That was an overreach and the Citymapper
> point was weak (§2). Kept below for the honest tradeoff record.

## 1. The honest tradeoff (fact-checked, `research/monetization_benchmarks.md`)

| | Plan A — Prepaid passes | Plan B — ₹199 one-time |
|---|---|---|
| India payment fit | ✅ Each pass is a **one-time UPI** charge — no card wall, no auto-renew mandate | ✅ Same — one-time UPI |
| Recurring revenue | ✅ Yes (repurchase) — higher LTV | ❌ One-time per user forever |
| Conversion | Higher (₹7 entry vs ₹199) — est. 3–5% vs ~1% | Lower entry-to-pay |
| Modelled Y1 (their projection) | ₹2.8–3.6L realistic / ₹77–85L optimistic | ₹1.8–2.6L / ₹22–30L |
| Complexity | 4 SKUs + prepaid-expiry logic + paywall ladder UX | Already built, simplest |
| Main risk | Repurchase friction (prepaid churn); ₹7 "cheap" signal; 15% cut thin on ₹7 | Leaves recurring revenue on the table |
| Google 15% cut | Applies per purchase (₹5.95 net on ₹7) | ₹169 net on ₹199 |

### Where my numbers were wrong before
- **Citymapper does NOT kill Plan A.** What failed (2023) was an *auto-renewing
  MaaS subscription bundle* — a different animal from a prepaid impulse-pass
  ladder. Its post-acquisition "pay to remove ads" survivor supports *keeping a
  free core*, which BOTH plans do. It is not evidence against prepaid passes.
- **The card-penetration argument doesn't favour B over A.** Prepaid passes are
  also one-time UPI charges, so they clear India's ~8% card wall just as well.
  UPI is the reason A is even viable.

### What the research genuinely does say
- One-time/lifetime plans are a *growing* minority (6.4%→10.3% of plan types
  '23→'25) and suit utility apps — B is defensible, not wrong.
- No India-specific, utility-category conversion benchmark exists for either —
  both projections are estimates; treat the pass-mix ratios as assumptions.
- The pass model's real enemy is **prepaid repurchase churn** (the user must
  actively re-buy) — the monthly/yearly tiers are what make it compound, so the
  ladder only wins if it funnels daily→monthly.

## 2. My recommendation (a recommendation, not a decision)

**Ship Plan A (prepaid ladder), but launch a reduced 2-SKU version of it** to
avoid decision-paralysis and SKU overhead at v1:
- **₹99 monthly** (the anchor / core revenue driver) + **₹899 yearly** (LTV
  capture), both prepaid, both unlock full Pro.
- Keep the **rewarded day-pass** as the free on-ramp (replaces the ₹7 daily's
  funnel job without a paid micro-SKU whose 15% cut is brutal).
- Add **₹7 daily / ₹35 weekly** in a fast-follow once the monthly funnel is
  proven, and consider ₹199 one-time or ₹1,950 lifetime as a "lifer" SKU later.

This gets the recurring-revenue upside of your plan with less launch risk than
the full 4-SKU ladder, and it's a strict superset of what's coded (add SKUs,
don't remove the one-time path). But if you want the full ladder at launch, or
prefer to keep it dead-simple with just ₹199, both are legitimate — **your
call.** Whatever you pick, I'll wire the SKUs, paywall, and prepaid-expiry
logic (`PASS_PRICING_ANALYSIS.md §7` has the implementation path).

## 3. What's NOT in question (both plans keep these)

- Free core forever (invariant #1).
- Rewarded day-pass as the conversion nudge.
- Ads on free tier, never on the tracking/alarm screen; real AdMob IDs needed
  (test IDs ship ₹0 — user action).
- B2B mobility-data licensing is **dead for planning** (no India buyer market;
  govt builds free open-data; DPDP compliance cost) — keep the pipeline opt-in,
  dormant, zero-egress. Corporate commute-safety B2B is deferred-plausible,
  needs a named pilot.

## 4. Positioning that sells any paid tier (`research/competitors_2026.md`)

**"Actually wakes you — through silent mode, Do Not Disturb, even underground
where GPS dies."** No competitor pairs a DND-breaking wake alarm with
tunnel-proof positioning. Moovit's verified top complaint is aggressive ads →
"no full-screen ads while you sleep." A 377-upvote BMRCL review has begged for
this feature since 2020. Guardian/anti-theft are the India-specific safety wedge.

## 5. KPIs (post-launch weekly autopilot report)

installs, D1/D7/D30 retention, rides/user/week, **successful-wake rate** (the
product KPI), pay conversion (by SKU if Plan A), repurchase rate (Plan A),
ARPDAU, refund rate, share-link→install (viral K), rating trend.
