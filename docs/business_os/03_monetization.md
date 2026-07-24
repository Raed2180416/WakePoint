# Business OS — Monetization Decisions

Decisions here override the older MONETIZATION_ANALYSIS.md / PASS_PRICING_ANALYSIS.md
where they conflict — those explored options; this file commits, based on
fact-checked July-2026 research (`research/monetization_benchmarks.md`).

## 1. The committed model at launch

| Tier | Price | Contains |
|---|---|---|
| Free | ₹0 | Core alarm, never-late + EKF, transfers, single route, journey share, ads (banner + capped interstitial) |
| Pro | **₹199 one-time** | Ad-free, custom sounds + escalating volume, widget, Guardian, anti-theft |
| Day pass | rewarded ad | 24h of Pro — as a **conversion nudge**, not a revenue line |

Why this and not the subscription/pass-ladder ideas from the July 23 docs:

- **Citymapper precedent (verified):** the most prominent transit app in the
  world tried a paid bundle subscription, killed it (June 2023), got acquired
  in a fire sale, and the surviving paid feature is exactly "remove ads."
  Simple survives in this category.
- **India mechanics (verified):** UPI is first-class on Play for one-time
  purchases; card penetration ~8% makes card-gated trials (the global
  high-conversion pattern) inapplicable. One-time ₹199 via UPI nets **~₹169**
  (15% fee, unchanged for India until Sept 30, 2027).
- **Subscriptions for safety features later, not now:** recurring Guardian
  pricing is plausible but adds RBI e-mandate friction and support burden; do
  it only after Pro conversion data exists (decision gate: ≥25k installs AND
  ≥1% conversion, revisit then).
- Planning number for conversion: **<2%** free→Pro (no India benchmark exists;
  budget pessimistically, celebrate upside).

## 2. Revenue tracks — real vs deferred vs dead (fact-checked)

| Track | Status | Rationale |
|---|---|---|
| ₹199 Pro (UPI) | **REAL — the business** | Defensible, precedented, low-friction in India |
| Free-tier ads | **REAL but marginal** | India eCPM 5–15× below Tier-1; GeoWake is screen-off-during-use — impression volume is structurally low. Needs real AdMob IDs (user action). |
| Rewarded day pass | **REAL as funnel** | Fractions of ₹ per view; value = demonstrating Pro before asking ₹199 |
| Corporate commute-safety B2B | **DEFERRED — plausible** | Global comp $2–15/seat/mo exists; needs one named pilot before it's a track. Revisit at 50k installs. |
| B2B mobility-data licensing | **DEAD for planning** | No Indian buyer market found; MoHUA/IUDX/Parivahan are building FREE open-data infra that competes; DPDP raises the compliance bar. Keep the pipeline opt-in, dormant, zero-egress. Never in projections without a named buyer. |
| Acquisition | **Not a plan, an outcome** | WhereIsMyTrain monetized via Google acquisition; being the best metro-precision alarm is the only way that door opens. |

## 3. Positioning that sells Pro (from `research/competitors_2026.md`)

The claim no competitor can make, verbatim for store + paywall:
**"Actually wakes you — through silent mode, through Do Not Disturb, even
underground where GPS dies."**

- WhereIsMyTrain (500M installs, Google-owned): cell-tower alarm built for
  long-distance rail — not metro station spacing, not tunnels. Don't attack
  its reliability; own the metro niche it structurally can't serve.
- Moovit (3.4★): verified top complaint is aggressive full-screen ads →
  "no full-screen ads while you sleep" is evidenced differentiation.
- Pixel Transit Mode (Mar 2026): a manual DND filter, not a wake alarm
  ("fails where it matters" — Android Authority). Google-ships-it risk is
  real but today nothing from Google wakes a sleeping rider.
- Official metro apps: no alarm at all; a 377-upvote BMRCL review has begged
  for this since 2020. Use that as social proof.
- Guardian/anti-theft: the India-specific emotional wedge (family safety,
  phone snatching) — the paywall hero after ad-free.

## 4. Ad implementation guardrails

- Real AdMob account + unit IDs = launch-blocking user action (test IDs ship
  zero revenue). IDs must come from build config, not hardcoded.
- Never: ads on the tracking/alarm screen, lockscreen ads, interstitials
  during arming flow → both Play-policy risk and product-trust poison.
  Interstitial cap: on route completion, ≥3 rides apart (the audited
  "every 3 rides" logic must actually be wired — see audit findings).
- Ads OFF for Pro and day-pass holders, verified by test.

## 5. KPIs the autopilot watches (post-launch weekly report)

installs, D1/D7/D30 retention, rides tracked/user/week, successful-wake rate
(the product KPI), free→Pro conversion, ARPDAU (ads), refund rate,
share-links sent → installs (viral K), review rating trend.

Kill criteria / pivots: if conversion <0.3% at 50k installs → paywall UX work
before price experiments. If successful-wake rate <99% on any device cohort →
engineering sprint beats all growth work (the product IS the wake rate).
