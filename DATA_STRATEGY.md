# GeoWake — Data Strategy: The Legal-by-Construction Mobility-Data Asset

_2026-07-18. The affirmative playbook for GeoWake's aggregate mobility-data product — the founder's path to a durable, defensible company asset and a credible acquisition story. This is not a warning memo. It is "here is the legal value we can create, and the exact architecture that makes it both sellable and lawful." Every legal and market claim below is cited inline._

App name is **GeoWake** (never "WakePoint"/"geowake2" in user-facing strings). Android-first, India-first transit wake-alarm. The company's asset is not the alarm — it's what the alarm uniquely knows: **a rider's real, declared, intended transit destination.**

---

## 0. The one-sentence thesis

GeoWake is the only consumer app in India that, for each trip, holds a rider's **origin → destination *intent* at station granularity** — the stop they deliberately set — which is strictly higher-signal than the raw GPS pings the entire location-intelligence industry is built on, and we can turn that into a **legal-by-construction aggregate origin-destination (O-D) data product** whose flagship buyer is the transit-authority / urban-planning market that today pays for exactly this and can't get it cleanly.

The rest of this document is: why the intent data wins (§1), the three legal products (§2), the architecture that makes them lawful *by design* (§3), the single shared PII-free schema that serves both reliability and the data asset (§4), the bright line we never cross (§5), the DPDP compliance checklist (§6), and honest sequencing (§7).

---

## 1. Why GeoWake's intent data beats ping data — the pitch to buyers

The location-intelligence market is real and large: **~USD 24–25B in 2025, growing 13–16%/yr** (Grand View ~USD 24.2B / 15.5% CAGR; Mordor ~USD 25.1B / 13.45% CAGR) — https://www.grandviewresearch.com/industry-analysis/location-intelligence-market. Every incumbent in it sells a *reconstruction* of where people went, inferred from noisy signals. That inference is exactly the weakness GeoWake doesn't have.

**How the incumbents source their data — and why it's lower-signal:**

- **Placer.ai** — foot-traffic analytics from an SDK embedded in tens of millions of third-party apps, then "debiased and aggregated," US-only; reached ~USD 100M ARR at a ~USD 1.5B valuation — https://techcrunch.com/2024/08/05/placer-ai-boosts-valuation-to-1-5b-after-quietly-raising-another-75m/.
- **Veraset** — raw pseudonymised device-level GPS (device id, lat/long, timestamp), ~10B+ daily observations across 300M+ devices in 200+ countries including India, sourced from thousands of third-party app SDKs — https://veraset.com/datasets/movement.
- **Advan** (ex-SafeGraph Patterns) — weekly visitor volumes and trade areas from mobile location data, sold to real estate and hedge funds — https://advanresearch.com/advan-news/advan-acquires-safegraphs-patterns-business-expanding-leadership-in-location-intelligence-and-foot-traffic-analytics.
- **StreetLight** (acquired by Jacobs, Feb 2022) and **Replica** (ex-Alphabet/Sidewalk Labs) — the transport-planning O-D vendors — build **modeled/synthetic** origin-destination matrices from de-identified mobile data — https://www.jacobs.com/newsroom/press-release/jacobs-acquires-mobility-analytics-leader-streetlight-data-inc and https://www.replicahq.com/pricing.

Notice what every one of them must *do*: infer trip ends and trip purpose from a stream of dots. A ping panel sees a device pause near a station and has to *guess* whether that's the trip's destination, a transfer, or noise. The academic consensus is that passively-collected GPS avoids the bias of stated-preference surveys because it captures *revealed* behaviour — but it still has to model the trip ends and purpose that raw pings never state — https://tfresource.org/topics/Stated_preference_surveys.html.

**GeoWake's structural edge:** we don't infer the destination — the rider *declares* it. When someone sets a wake-alarm for "Indiranagar," we hold a ground-truth label pairing an actual, in-progress transit trip with its true intended endpoint. Our edge is therefore **not** "stated beats GPS." It is that we uniquely pair **revealed travel with a rider-declared destination**, eliminating the trip-end and trip-purpose inference that Placer/Veraset/Advan/StreetLight must all model — https://tfresource.org/topics/Stated_preference_surveys.html. A labeled O-D matrix is a *different, higher-signal product class* than an inferred one — the kind StreetLight/Replica's inference stack cannot replicate, which is what justifies a premium rather than competing on panel volume (mobility_market.md, open questions).

**The India gap this fills:** city O-D demand in India is procured through **Comprehensive Mobility Plans (CMPs)** — MoHUA issues the Terms of Reference and a five-stage methodology, plans are prepared by development authorities and municipal corporations (usually via consultants), and they rely heavily on one-off household and intercept O-D surveys and "outdated and incomplete data" — https://www.orfonline.org/research/comprehensive-mobility-planning-in-indian-cities-challenges-gaps-and-the-way-forward. NITI Aayog's official "Data-Driven Mobility" framing recognises mobility data as key to efficient passenger transport, but the main big-data source (telco CDR from mobile operators) is hampered by operators' strong historical reluctance to share — https://www.niti.gov.in/sites/default/files/2023-02/Mobility-data.pdf. **That withheld-CDR + stale-survey gap is the exact hole a consented, aggregate, station-labeled O-D feed fills.**

The one honest counterweight (carried forward from §7): our edge is real, but **scale is the whole game**. Every incumbent rests on tens of millions of devices or billions of daily pings (mobility_market.md, caveats). A wake-alarm's smaller panel means many station-pair cells fall below the k-anonymity threshold and are simply un-sellable until density arrives — which is why this is a v2 asset built on trust and users, not a launch feature (§7).

---

## 2. The three legal value products

Three distinct products, ranked by cleanliness of the buyer and defensibility of the legal position. All three sell **aggregate cells only** — never a person, never a trajectory (§5). They differ in geography-of-buyer and packaging.

### 2(a) — FLAGSHIP: Station × hourly-bin O-D flow matrices

**What it is:** a matrix of `(origin_station, destination_station, hour_bin, day_type) → rider_count`, released only for cells clearing the k-anonymity floor with differential-privacy noise applied (§3). "~500 riders/day travelled Majestic → Indiranagar, weekday 18:00–20:00" — never a person, never a path.

**Buyers:** transit authorities, metro/bus corporations (BMRCL, DMRC, BMTC-type), city development authorities, Smart Cities ICCCs, MoHUA CMP consultants (WRI India, AECOM, WSP), and academic "Data for Good" partners. This is a **B2B2G / research play**, not ad-tech.

**Why it's legal:** the DPDP Act 2023 regulates only "personal data" = "any data about an individual who is identifiable by or in relation to such data" (s.2(t)) — https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html. The Act does **not** define "anonymisation," so genuinely anonymised aggregates where no individual is identifiable fall **outside** the Act — https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html. Section 17(2)(b) additionally exempts processing for research/archiving/statistical purposes provided it is not used to make a decision about a specific data principal — https://fpf.org/blog/the-digital-personal-data-protection-act-of-india-explained/. An aggregate O-D matrix at station×hour with k-suppression + DP noise is neither about an identifiable individual nor used to decide anything about one — it is the textbook out-of-scope statistical product. Critically, this is **not a novel legal theory**: the US Census LEHD **OnTheMap** was the first production differential-privacy deployment and it protects *exactly* an origin-destination commuting matrix, releasing noise-protected block-level flows so individual home locations are never disclosed — https://lehd.ces.census.gov/doc/help/ICDE08_conference_0768.pdf. A legally-defensible O-D flow product via DP synthesis is established precedent, not an experiment.

**Pricing / packaging sketch:** a SaaS-style annual subscription or per-plan license, priced to Indian public procurement (which is slow, consultant-mediated and price-sensitive — mobility_market.md caveats), not to US anchors. US reference points to anchor the *ceiling*, not the Indian price: Teton County, WY paid **USD 42,888/yr** for a StreetLight InSight subscription (the O-D-for-modeling line item alone was **USD 19,600**) — https://tetoncountywy.gov/DocumentCenter/View/25060/03213-Streetlight-data-for-Location-Based-Services-Data-Subscription; Replica prices at roughly **0.15 × served population** per added agency — https://www.replicahq.com/pricing. Realistic India packaging: a per-city annual data license to the transit corporation / CMP consultant at a fraction of US rates, plus a free/low-cost academic tier that seeds credibility and coverage.

### 2(b) — Station catchment / footfall / dwell-demand

**What it is:** aggregate arrival volumes and time-of-day demand curves at each station — "how many riders arrive at station X, when" — as catchment/trade-area intelligence. Same k-suppressed, DP-noised cells; destination-side only.

**Buyers:** retail, QSR chains, real-estate siting, out-of-home advertising — the classic Placer.ai / Advan lane, but for transit-station catchment specifically. This is the more commercial lane and, per HANDOFF §4, the *later* one because micro-targeting a location's customers is inherently more sensitive than serving planners.

**Why it's legal:** identical basis to 2(a) — aggregate counts of arrivals at a public station, k-suppressed and DP-noised, are not "about an identifiable individual" (s.2(t)) — https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html — and fall outside the Act when genuinely non-identifiable. The mechanism that makes footfall lawful is the same as Google's shipped COVID-19 Community Mobility Reports: DP noise on counts plus **hard suppression of any cell below ~100 contributing users and no region smaller than 3 km²** — https://arxiv.org/pdf/2004.04145v2. Same product shape, same guardrails, established at Google scale.

**Pricing / packaging sketch:** subscription tiers by number of stations / metros, benchmarked against Placer.ai's ~USD 5,000–30,000/yr band — https://softwarefinder.com/analytics-software/placer-ai — and SafeGraph's row×attribute×usage licensing model — https://www.safegraph.com/pricing/ — but again re-priced for India. Package as "station catchment reports" (per-station demand curves) rather than raw feeds; this keeps the product at aggregate altitude and away from anything device-level.

### 2(c) — Aggregate mode-split / demand-trend dashboards

**What it is:** the highest-altitude, lowest-risk product — dashboards of aggregate transit-mode splits, corridor demand trends over time, and route popularity, with no station-pair granularity fine enough to threaten k-anonymity. "Metro corridor A demand up 12% QoQ; mode-split shifting bus→metro on the east corridor."

**Buyers:** urban planners, transit agencies, policy/research bodies, NITI-Aayog-adjacent programs, and press/公共 reporting. The cleanest possible buyer relationship and the natural on-ramp product.

**Why it's legal:** it is aggregation of aggregates — trends and splits carry the least re-identification surface of the three, sit furthest inside the s.2(t) out-of-scope zone — https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html — and squarely inside the s.17(2)(b) statistical/research exemption — https://fpf.org/blog/the-digital-personal-data-protection-act-of-india-explained/. There is effectively no individual to single out in a corridor-level trend line.

**Pricing / packaging sketch:** a low-cost dashboard subscription or an insights-report retainer; also the ideal **loss-leader / trust-builder** — publish selected trend dashboards publicly to establish GeoWake as a credible mobility-data source before selling the granular 2(a) product. Doubles as marketing for the flagship.

---

## 3. Legal-by-construction architecture — why each guardrail *is* the product

The guardrails below are not compliance bolt-ons added to a data pipeline. They **are** the pipeline. Each one is simultaneously the thing that makes the data lawful and the thing that makes it sellable, because a buyer of transit-authority-grade data wants a dataset that is defensible on exactly these axes. Build them as the architecture, and the product is legal because it *cannot* emit anything else.

The load-bearing legal fact behind all four layers: releasing an "anonymised trajectory" is legally and mathematically indefensible. de Montjoye et al. (Nature, 2013) showed **four spatio-temporal points re-identify 95% of 1.5M people; two points single out >50%** — https://www.nature.com/articles/srep01376 — and the EU's own Article 29 Working Party guidance (WP216) cites this exact study to conclude pseudonymised location data is *not* anonymised — https://iapp.org/media/pdf/resource_center/wp216_Anonymisation-Techniques_04-2014.pdf. So the architecture must never even *hold* a per-user trajectory in a releasable place. It doesn't.

### Layer 1 — On-device aggregation: raw trajectories NEVER leave the phone

Aggregation happens **on the handset**. The device computes its own contribution to aggregate counts locally; only pre-aggregated, noised outputs are ever transmitted. Raw per-user trajectories never touch a server.

**Why this is the product, not a bolt-on:** this is the reference pattern from Google Federated Analytics — "only the user has a copy of their data," and only aggregated results ("never any data from a particular device") are made available, with Secure Aggregation cryptographically masking each device's values so the server decrypts only the combined tally "and nothing else" — https://research.google/blog/federated-analytics-collaborative-data-science-without-data-collection/. Apple's local-DP model likewise injects noise on-device *before* data leaves the phone, drops identifiers and IP addresses — https://www.apple.com/privacy/docs/Differential_Privacy_Overview.pdf. Legally, this is decisive: if any raw location touches a server, full Data Fiduciary obligations attach to that flow regardless of downstream aggregation (dpdp.md, open questions). Keeping raw trajectories on the device by construction means the re-identification surface for the released product **does not exist**. GeoWake is already on-device by design — the alarm runs locally — so this layer extends an existing architecture rather than inventing one.

### Layer 2 — k-anonymity: k ≥ 50–100, drop sparse cells

Before any cell is eligible for release, it must have at least **k contributing users (k ≥ 50–100)**; sparse cells are dropped entirely.

**Why it's necessary but not sufficient:** WP216's Table 6 is the design keystone — k-anonymity/aggregation defeats **singling out** (No), but still permits **linkability** (Yes) and **inference** (Yes) — https://iapp.org/media/pdf/resource_center/wp216_Anonymisation-Techniques_04-2014.pdf. So k-anonymity is a **necessary floor, not a sufficient control** for mobility data; it must sit *under* differential privacy (Layer 3). WP216 gives concrete guidance: avoid k≤2, prefer k>10, with no fixed statutory number — parameters chosen case-by-case, which is why practitioners target k in the tens-to-hundreds for sparse spatio-temporal cells — https://iapp.org/media/pdf/resource_center/wp216_Anonymisation-Techniques_04-2014.pdf. Our concrete target (k ≥ ~100, no cell below a minimum spatial area) mirrors Google's shipped rule: **suppress any metric whose DP count of contributing users is below 100, and publish nothing for a region smaller than 3 km²** — https://arxiv.org/pdf/2004.04145v2. This is also *why the sparse-cell problem forces v2 sequencing*: at low panel density most station-pair cells fail k-anon and are un-sellable anyway (§7).

### Layer 3 — Differential privacy: calibrated noise, stated epsilon

DP noise (Laplace/Gaussian) is added to released counts, with a **bounded per-user contribution** and a **stated epsilon**.

**Why it's the layer that closes linkability and inference:** per WP216 Table 6, differential privacy is the only technique that can address all three risks — singling out, linkability, inference ("may not" be a risk if properly applied) — https://iapp.org/media/pdf/resource_center/wp216_Anonymisation-Techniques_04-2014.pdf. The copyable, shipped pattern is Google's COVID-19 Community Mobility Reports: each user's contribution is **capped** (to 4 place/category pairs per day), each daily place-visit metric is protected with **ε = 0.44**, and each user's total daily contribution is at most **ε ≤ 1.76** — https://arxiv.org/pdf/2004.04145v2. These are strong copyable defaults for a station×hour O-D/flow aggregate.

**Epsilon is not a slogan — it must be stated with its model and contribution bound.** ε values are *not comparable across systems*: Google Mobility uses ε = 0.44 per metric in the **central** model; Apple uses ε = 2–8 per donation in the **local** model (weaker per-unit, but data never leaves the device in cleartext) — https://www.apple.com/privacy/docs/Differential_Privacy_Overview.pdf; the 2020 US Census set **ε = 19.61** total in the central model — https://www.census.gov/newsroom/press-releases/2021/2020-census-key-parameters.html. So "we use differential privacy" is meaningless unless GeoWake states the **model (local vs central), the epsilon, and the per-user contribution cap**. Our starting posture: local-model noise on-device (Layer 1) plus a central-style per-cell budget, with a per-user daily cap (ε ≤ ~1.76/day) as the copyable Google default — to be finalised with the anonymisation methodology sign-off (§6). This exact discipline — stated model + epsilon + contribution bound — is itself part of what makes the dataset credible to a transit-authority buyer.

### Layer 4 — Separate, purpose-specific, default-OFF opt-in consent with one-tap withdrawal

The data-sharing consent is a **distinct, unbundled, default-OFF opt-in**, independent of the alarm consent, with withdrawal as easy as opt-in.

**Why this is mandated and why it's the product:** DPDP s.6(1) requires consent that is "free, specific, informed, unconditional and unambiguous with a clear affirmative action" and "limited to such personal data as is necessary for such specified purpose" — purpose limitation and data minimisation are baked into the consent definition itself — https://www.dpdpact2023.com/chapter-2. Because consent must be "specific" and "unconditional," selling aggregate mobility data is a **distinct purpose** from delivering the alarm: it needs its own opt-in, must not be bundled with the alarm consent, and **cannot be a precondition of the core service** — https://www.dpdpact2023.com/chapter-2. The Rule 3 notice must be standalone ("understandable independently of any other information"), itemising the data collected, the specified purpose, and the means to withdraw and to complain to the Board — https://www.dpdpa.in/dpdpa_rules_2025/Rule_3.htm. Withdrawal must be available "at any time," with "the ease of doing so being comparable to the ease with which such consent was given" (s.6(4)–(6)) — https://www.dpdpact2023.com/chapter-2. Making this a clean, one-tap, default-OFF toggle isn't a concession — it is the trust feature that lets GeoWake tell users (and buyers, and regulators) that participation is genuinely voluntary and the core alarm is untouched by it.

**The four layers compose into a single invariant:** the only thing that can ever leave a consenting user's phone toward the data product is a DP-noised contribution to a k-suppressed aggregate cell. No raw trajectory exists server-side to leak, subpoena, or mis-sell. That invariant is the asset.

---

## 4. One shared PII-free schema for BOTH reliability telemetry AND the data asset

GeoWake does not build two data pipelines. The **existing** reliability-telemetry schema — `lib/services/telemetry/telemetry_service.dart` — is already designed to double as the aggregate-data feed, and the data asset must reuse it rather than fork it.

The schema is **PII-free by construction**, and this is enforced in the type system, not by policy: its file header states events "carry station/zone-granular identifiers and coarse durations only, so the same schema doubles as the k-anonymous crowdsourced-calibration feed … without ever holding a trajectory … enforced by construction: the typed helpers below never accept a lat/lng." Concretely:

- `TelemetryEvent` carries a short string `type`, a `timestampMs`, and a `props` map — no coordinate fields.
- The typed funnel entrypoints — `alarmArmed({mode, value, city, line})`, `alarmOutcome(...)`, `reachabilityActivated(...)`, `gpsLost/gpsReacquired(...)` — accept **city/line/station-granular** identifiers and **coarse durations**, never a lat/lng. There is no code path to pass a raw position.
- `setDeviceContext({manufacturer, model, androidSdkInt, appVersion, platform})` attaches only non-PII device context (the OEM/model/version breakdown reliability needs).
- Values are rounded (`_round` to one decimal) and error strings are scrubbed of home paths (`_scrub` strips `/home/<user>` and `/Users/<user>`), so even diagnostics can't leak a username.
- It is **fail-open**: every method swallows its own errors so telemetry can never throw into the alarm path.

**Why one schema serves both:** the reliability funnel HANDOFF §3 requires — armed → tracking → GPS-lost → fired {on-time/early/late/missed}, broken down by device/OEM/Android version — is *already* a stream of station/line-granular, PII-free events. The aggregate data asset (§2) needs the **same** station/line-granular, PII-free events, differing only in which fields are aggregated. So the data product is built by **adding an aggregation sink** behind the existing `TelemetrySink` interface (the codebase already anticipates "a network/Crashlytics/PostHog sink can be added later behind the same interface without touching call sites"), applying the §3 k-suppression + DP layers to the same event stream. HANDOFF §3 states this explicitly: "the same ride traces that diagnose reliability also crowdsource each line's real speed profile / dwell / drift" and "design the telemetry schema so it doubles as the crowdsourced-calibration feed." One schema, two consented purposes, zero PII in either.

**The consent consequence:** because reliability telemetry (making the alarm work) and the commercial data asset (selling aggregates) are **different purposes** under s.6(1) — https://www.dpdpact2023.com/chapter-2 — they need **separate consents** even though they share a schema. Reliability telemetry can ride the core-service consent (it is necessary to deliver a working alarm); the commercial aggregate egress needs the separate, default-OFF opt-in of §3 Layer 4. Same events, same schema — different consent gate on the network sink.

---

## 5. The line we never cross

This is the bright line. It is grounded in the DPDP identifiability standard and in de Montjoye. Crossing it is a company-ending event; staying inside it is what makes everything in §2 possible.

- **Never store, upload, or sell an individual trajectory.** "Anonymised trajectory" is a legal fiction: **four spatio-temporal points re-identify 95% of individuals; two points >50%** (de Montjoye, Nature 2013) — https://www.nature.com/articles/srep01376 — and coarsening the grid barely helps, since trajectory uniqueness decays only as ~the 1/10 power of resolution — https://www.nature.com/articles/srep01376. This generalises beyond phone GPS: 4 points re-identify 90% of people in credit-card metadata too — https://www.science.org/doi/abs/10.1126/science.1256297. A pseudonymised trajectory is still personal data and fully in-scope under DPDP s.2(t) — https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html. We release only DP-noised counts of k-suppressed aggregate cells — never a path, k-anonymised or not (privacy_tech.md caveats).
- **Never sell to data brokers, and never sell anything device-level.** Veraset is the cautionary tale: it gave bulk device-level GPS data to the DC government and drew EFF criticism — https://www.eff.org/deeplinks/2021/11/data-broker-veraset-gave-bulk-device-level-gps-data-dc-government. For a consumer safety app that knows when you sleep and where you commute, a single "GeoWake sold your movements" headline is fatal (HANDOFF §4; MONETIZATION §0). Device-level is the landmine; we never step on it.
- **Never infer or sell sensitive attributes** — no health, religion, or other sensitive inference from mobility. And GeoWake will gate to **18+** (or build verifiable parental consent), because s.9(3) bars behavioural tracking and targeted advertising directed at children (anyone under 18), and an 18+ gate is materially simpler to defend for a location app — https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html.
- **The core alarm works fully with sharing OFF.** This is the non-negotiable design invariant and the legal foundation of the s.6(1) "unconditional" consent — https://www.dpdpact2023.com/chapter-2. Data-sharing is default-OFF and severable; the product a user paid nothing for and the product a planner pays for are cleanly separated.

The line is also the moat: done inside it, the aggregation is defensible and the trust compounds; done outside it, it ends the company (HANDOFF §4: "done right it's a moat; done wrong it's the end").

---

## 6. DPDP compliance checklist

Status: the **DPDP Rules 2025 are FINAL** — notified in the Gazette as **G.S.R. 846(E) on 13 November 2025** — https://www.ey.com/en_in/insights/cybersecurity/transforming-data-privacy-digital-personal-data-protection-rules-2025. Commencement is phased: Board/definitions live from 13 Nov 2025; Consent Manager registration from 13 Nov 2026; **core operational obligations (notice, consent, security, retention, SDF duties, data-principal rights) bind from 13 May 2027** — https://ssrana.in/articles/meity-notifies-final-digital-personal-data-protection-rules-2025/. Obligations are deferred; the correct posture is to **build for them now**.

| # | Requirement | What GeoWake must do | Source |
|---|---|---|---|
| 1 | **Separate, unbundled consent** for the data purpose | Default-OFF opt-in for aggregate data-sharing, distinct from alarm consent; "free, specific, informed, unconditional, unambiguous," data-minimised, not a precondition of the alarm (s.6(1)) | https://www.dpdpact2023.com/chapter-2 |
| 2 | **Rule 3 standalone notice** | A standalone consent notice itemising data collected, the specified purpose, and links to withdraw / exercise rights / complain to the Board | https://www.dpdpa.in/dpdpa_rules_2025/Rule_3.htm |
| 3 | **One-tap withdrawal** | In-app toggle as easy to switch off as on (s.6(4)–(6)); cease processing within a reasonable time on withdrawal | https://www.dpdpact2023.com/chapter-2 |
| 4 | **Purpose limitation & minimisation** | The commercial aggregate purpose is separate from reliability telemetry (same schema, different consent gate — §4); collect only what the purpose needs | https://www.dpdpact2023.com/chapter-2 |
| 5 | **Erasure on withdrawal / purpose-completion** | Erase raw location once the purpose is served or consent withdrawn (s.8(7)); honour erasure requests (s.12) with an auditable erasure log. (The fixed 3-year Third-Schedule auto-erasure does **not** apply — GeoWake is not an e-commerce/gaming/social-media giant) | https://www.dpdpact2023.com/chapter-2 · https://www.dpdpact2023.com/chapter-3 · https://www.seclore.com/fundamentals/dpdp-rules-2025-compliance-guide/ |
| 6 | **Grievance contact / DPO** | Publish a named grievance-contact / DPO able to answer processing questions (s.8(9)–(10)). Note: a **formal India-based DPO** is an **SDF-only** trigger (s.10(2)(a)) — a non-SDF like GeoWake needs only the published contact point | https://fpf.org/blog/the-digital-personal-data-protection-act-of-india-explained/ |
| 7 | **SDF threshold — watch, don't assume** | SDF status is **not automatic** — it applies only if the Central Government notifies you, based on data volume/sensitivity and risk (s.10) — https://fpf.org/blog/the-digital-personal-data-protection-act-of-india-explained/. A niche transit-alarm is unlikely to be notified until large scale. **If** notified: India-based DPO, annual DPIA + independent audit, algorithmic due diligence, possible data-localisation (Rule 12) | https://ssrana.in/articles/meity-notifies-final-digital-personal-data-protection-rules-2025/ |
| 8 | **Security safeguards + breach reporting** | "Reasonable security safeguards" (s.8(5)); on a personal-data breach, notify the Board with full particulars within **72 hours** (Rule 7) and affected principals without delay | https://www.ey.com/en_in/insights/cybersecurity/transforming-data-privacy-digital-personal-data-protection-rules-2025 |
| 9 | **Children** | Gate to 18+ (or verifiable parental consent); no behavioural tracking or targeted ads to under-18s (s.9(3)) | https://www.dpdpa.com/dpdpa2023/chapter-1/section2.html |
| 10 | **Anonymisation methodology sign-off** | Get an Indian data-protection lawyer's sign-off on (a) the anonymisation method + re-identification risk assessment and (b) the consent architecture, documented as a DPIA even if not an SDF — the out-of-scope status is defensible-but-unadjudicated and rests on proving genuine non-identifiability | https://amlegals.com/edpbs-new-anonymisation-guidelines-what-they-mean-for-indian-businesses-under-the-dpdp-act/ |

**The penalty exposure that makes this checklist non-optional:** the DPDP Schedule sets **up to ₹250 crore** for a failure of reasonable security safeguards (s.8(5)), **up to ₹200 crore** for failure to give breach notice (s.8(6)), **up to ₹200 crore** for breach of children obligations (s.9), **up to ₹150 crore** for SDF-obligation breaches, and **up to ₹50 crore** residual — https://www.dpdpa.com/theschedule.html. Penalties are **per-contravention and stack**: one breach event can trigger the ₹250 cr security entry *plus* the ₹200 cr notification entry *plus* the ₹50 cr residual simultaneously — https://www.dpdpa.com/theschedule.html. This is precisely why the legal-by-construction architecture (§3) matters: **a weak aggregation pipeline that pulls the data back in-scope puts a ₹250 cr-tier exposure on a single breach** (dpdp.md caveats). The architecture is the risk control.

**Consent Manager (optional, later):** a Board-registered, India-incorporated intermediary (Rule 4, effective 13 Nov 2026, min net worth ₹2 crore). GeoWake does not need to *be* one but may later integrate with registered Consent Managers — https://www.dpdpa.in/dpdpa_rules_2025/Rule_4.htm.

---

## 7. Honest sequencing — why live collection is v2, and what to scaffold now

**Live collection is a v2 revenue stream, not a launch feature — and the reasons are structural, not timidity:**

1. **Sparse cells fail k-anonymity anyway.** At low panel density, most station-pair O-D cells fall below the k ≥ 50–100 floor and are dropped, so the dataset is commercially meaningless until density arrives — a hard cold-start problem for a wake-alarm app (mobility_market.md caveats). The k-suppression that makes the data *legal* (§3 Layer 2) also makes it *worthless when sparse*. You cannot sell what you must suppress. HANDOFF §4 makes the same point: "with few users the aggregates aren't valuable anyway (k-anonymity kills sparse cells)."
2. **Trust must be banked first.** The data asset is gated on trust, and a location safety app spends trust it hasn't earned if it monetises movement before proving the alarm works (MONETIZATION §D; HANDOFF §4).
3. **It's a real legal + engineering project** that would distract from getting the alarm right — which is the whole company (HANDOFF §4).

The right first buyer is the **cleaner** one — transit authorities / urban planners want aggregate O-D flows and it is far less creepy than retail micro-targeting (§2a before §2b); the restaurant/catchment play comes later once defensible aggregation exists (HANDOFF §4; MONETIZATION §D).

**What to scaffold NOW (so v2 is a switch-on, not a rebuild) — with zero risk today:**

- **The separate, default-OFF consent flow** (§3 Layer 4 / §6 items 1–3) — build the Rule 3 standalone notice and the one-tap toggle as UI scaffolding, defaulted OFF, wired to nothing. No data moves.
- **The on-device aggregation module behind a default-OFF flag, with NO network egress** — compute k-suppressed, DP-noised aggregate cells locally over the **existing telemetry schema** (§4), gated behind a build/feature flag that has no network sink attached. This proves the pipeline and lets the anonymisation methodology be reviewed and lawyer-signed (§6 item 10) long before a single byte is ever transmitted.
- **Keep the schema PII-free by construction** (it already is — §4) so reliability telemetry today *is* the data-asset seed tomorrow, needing only a consented aggregation sink added behind the existing `TelemetrySink` interface.

The sequencing discipline in one line: **build the guardrails now while they're free, collect nothing until density + trust make the aggregates both valuable and safe, and keep the on-device aggregator flag-gated with no egress until an Indian data-protection lawyer signs off the methodology and the DPIA.** That way the data asset is a capability GeoWake *already has the architecture for* the day it makes sense to turn on — which is exactly the story an acquirer wants to hear.

---

_Cited research: `docs/research/raw/dpdp.md`, `docs/research/raw/mobility_market.md`, `docs/research/raw/privacy_tech.md`. Context: `HANDOFF.md` §3–4, `MONETIZATION.md` §2D/§3, `lib/services/telemetry/telemetry_service.dart`. This is market and regulatory intelligence, not legal advice — the anonymisation methodology and consent architecture require Indian data-protection counsel sign-off before any data is sold (§6 item 10)._
