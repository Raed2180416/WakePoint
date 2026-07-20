# GeoWake Mobility-Data Business — Strategy & Build Plan

*Decision memo · 2026-07-19 · synthesizes market, legal/DPDP, secure-aggregation architecture, and GTM/product research.*

---

## 1. Bottom line up front

**Verdict: PURSUE AFTER SCALE — not now. Build the privacy guardrails today (they are nearly free and already shipped), pursue relationships and a non-binding LOI now, but do NOT stand up the merge backend, flip egress, or count on this in the P&L until four things co-exist: (a) one metro at ~20–50k concentrated opt-in daily riders, (b) a signed DPIA + counsel opinion, (c) a contracted buyer, and (d) Play-safe sale mechanics.**

Why this and not the two alternatives:

- **Not "pursue now as a revenue line."** All four inputs converge on a hard cold-start wall. The product is aggregate origin-destination (OD) counts gated at k≥100 contributing users per cell. At launch/low density essentially *every* sellable cell fails the k=100 floor, so there is literally nothing to sell — a single device cannot even mint a transmittable cell by construction. Realistic direct data revenue is **~$0 in year 1**, and optimistically **one pilot/grant in the $5k–$30k range by year 2–3** only if single-city scale *and* a sympathetic buyer both materialize. The India buyer (metro corporations, MoHUA/smart-city planners) procures household surveys and consultancy through slow, tender-driven, lowest-bidder cycles, not app-data subscriptions.
- **Not "don't ever."** The asset has real strategic value as (1) a *product-improvement* input (better OD/catchment models improve the wake-alarm itself), (2) an *acquisition/optionality* story, and (3) a *legal-by-construction* differentiator versus the dead cohort of raw-location brokers. The guardrails are already in code (`lib/services/data_asset/*`, egress hard-OFF), so keeping the option open costs almost nothing.

**One-line strategy: treat the k-anon/DP data surface as an optionality and acquirer asset, keep egress OFF, and let user scale + a named buyer + legal sign-off be the trigger — not a roadmap date.**

---

## 2. Market: who buys, comparables, realistic India demand

### Market size
The aggregated OD/location-intelligence platform market was **~$2.37B in 2024**, projected to **~$7.3B by 2033 at ~15.4% CAGR** (DataIntelo / GMInsights: https://www.gminsights.com/, https://dataintelo.com/). Real and growing — but consolidated and buyer-concentrated.

### Who buys (segments, best-fit first)
1. **Public-sector transport** — DOTs, MPOs, metro/transit agencies, city planners. *The natural fit for OD data.*
2. **Urban-planning & transport consultancies** — resell into #1 (B2B2G).
3. Real-estate & retail site-selection.
4. Out-of-home (OOH) advertising & retail-media.
5. CRE/REITs & investors.
6. Academia / econ research (credibility + coverage seeding, not revenue).

Placer.ai reports **4,300+ customers** concentrated in retail, CRE and civic.

### Comparables — ALIVE in 2026
| Company | What it actually sells | Signal |
|---|---|---|
| **StreetLight Data** (acquired by **Jacobs**) | OD studies to DOTs/MPOs — *closest transit-OD comparable* | The template to study |
| **Placer.ai** | Foot-traffic/visits SaaS; own panel; **~$1.5B valuation, ~$100M ARR** after a **$75M raise (Aug 2024)** | Sells venues/visits, *not* transit OD |
| **Replica** (ex-Sidewalk Labs) | Synthetic, privacy-aggregated OD for transport planning | Privacy-aggregate model to emulate |
| **Veraset** | Raw device-level pings | The *opposite* of GeoWake's stance |
| **Foursquare** | Places/POI + attribution (absorbed Cuebiq 2022) | Pivoted away from brokering |

### Comparables — DEAD / PIVOTED / DISGRACED (the 2021–2024 cull)
- **SafeGraph** discontinued flagship **Patterns / Weekly-Patterns / Neighborhood-Patterns** (start of 2023), retreated to Places/POI.
- **Cuebiq** → acquired by Foursquare (Mar 2022); ceased as independent broker.
- **Near Intelligence** → **Chapter 11 (Dec 2023)** — assets $50–100M vs liabilities $107.6M — months after a SPAC listing; assets sold to Blue Torch.
- **Gravy Analytics / Venntel** → **FTC-banned from selling sensitive location data (Dec 2024)** (https://www.ftc.gov/news-events), then a **mass location breach (Jan 2025)**.
- **Unacast** → merged with Gravy (2023), damaged by that breach.

**Why they died:** Apple's App Tracking Transparency (2021) choked ad-SDK supply; GDPR/FTC enforcement made raw location toxic; breaches destroyed trust; unit economics never worked. **The survivors own first-party/licensed *representative* panels and sell aggregated products to planners — not raw feeds to ad-tech.** GeoWake's privacy-by-construction posture is aligned with the survivors, but its panel is the problem (§7 coverage).

### India demand — real in theory, thin and slow in practice
- The buying vehicle is the **Comprehensive Mobility Plan (CMP)**; **MoHUA funds up to 80%** of DPR/study costs. But CMPs historically procure **household O-D surveys and roadside interviews** (Visakhapatnam CMP 2016–17; Chennai CUMTA citizen survey), *not* app-derived OD subscriptions.
- **DMRC / BMRCL** buy consultancy and systems (BMRCL Integrated Data Management System via DMRC; DMRC 10-year Corporate Plan RFP), *not* third-party rider-data licenses.
- Tailwinds: **ADB** is actively pushing anonymized mobile-phone OD data for Indian planning; **MoHUA DataSmart Cities** signals appetite (https://smartcities.gov.in/). But actual procurement of app-panel OD by Indian metros is **nascent-to-nonexistent, tender-driven, cash-constrained, lowest-bidder**.

### Realistic $ in years 1–3
- **Year 1: ~$0** direct data revenue.
- **Year 2–3: one pilot / per-study license, $5k–$30k**, conditional on single-city scale + a sympathetic buyer.
- **Ceiling** for single-city aggregated OD from one credible source: **~$10k–$50k/yr** (aggregated/DP data prices *below* raw device data; raw commands the premium, aggregated OD is a commoditized planning input).

---

## 3. Legal & privacy — is it defensible?

**Yes, conditionally defensible to ship and sell in India — but defensibility is earned by documented governance, not by the "anonymized" label.** The single hardest gate is **Google Play, not the DPDP Act.**

### DPDP Act 2023 scope (https://www.meity.gov.in/, DPDP Rules notified 13 Nov 2025)
- The Act governs **"personal data"** = data about an *identifiable* individual (GDPR-style identifiability test). **Truly/irreversibly anonymized data is outside the Act.**
- The catch: India uses a **"reasonable risk of re-identification"** standard that the statute **does not quantify** and the 2025 Rules do not bless any specific method. "Anonymized enough" is proven by governance, not by label.
- **Aggregation is "anonymized enough" when it defeats all three EDPB-style vectors:** *singling-out*, *linkage*, *inference*. k≥100 addresses singling-out/linkage; DP noise addresses inference. **Selling only cross-device-merged counts (never trajectories, never a single device's contribution)** is the correct posture.
- **Residual risk is genuine:** mobility data is notoriously re-identifiable (≈4 spatiotemporal points uniquely identify most people). So the defense is: coarse spatial/temporal bins, k≥100, documented ε budget, small-cell suppression, never a device-level or single-trip record — plus a written risk assessment a "reasonable person with reasonable means" test can be measured against.

### Consent — MEETS the DPDP standard as designed
- DPDP requires consent that is **Free, Specific, Informed, Unconditional, Unambiguous**, by clear affirmative action, backed by a standalone **Rule 3 notice** (itemized data, specific purpose, easy withdrawal, grievance route, 22 Eighth-Schedule languages on request).
- GeoWake's **default-OFF, explicit, purpose-specific, unbundled** opt-in meets this for the collect+aggregate step.
- **Two cautions:** (a) purpose-bound — "contribute anonymized aggregate mobility statistics" is a *distinct* purpose from the wake-alarm and cannot be bundled or pre-ticked; (b) even though the *output* is anonymized/outside DPDP, the *input* collection + on-device aggregation still process personal data, so consent + notice are required for that stage regardless.

### DPIA applicability
- A DPIA is **statutorily mandatory only for a Significant Data Fiduciary (SDF)** (government-notified by volume/sensitivity/risk; SDFs must also run 12-monthly audits, report to the Data Protection Board via independent auditor, and appoint a DPO).
- **GeoWake is unlikely to be an SDF at launch → DPIA not yet mandatory.** But it is **strongly advisable** and is the single best evidentiary shield for both the "anonymized enough" question and Play review. Conduct one voluntarily and keep it current. (Outline in Appendix A.)

### Google Play — the harder gate
- Play's **User Data policy** flatly prohibits **"selling personal and sensitive user data,"** treats **precise location as sensitive**, and publishes **no explicit safe-harbor for aggregated/de-identified data** (https://support.google.com/googleplay/android-developer/answer/10144311).
- **Consequence:** even with full DPDP compliance, the app can be removed if the sale mechanics look like a "sale" of user data. **Mitigation:** structure the monetization so only *true aggregates* (a GeoWake data *product*, not user-data brokering) leave the system; word the Data-safety disclosure precisely; run the sharing opt-in as a **separate flow** from any other permission.

### Net legal verdict
**Shippable with three hard mitigations:** (1) a documented re-identification risk assessment / DPIA; (2) a monetization structure that transfers only aggregates (product, not brokering); (3) airtight Play Data-safety disclosure + a separate, unbundled opt-in. None of these are blockers — but all three must be in place *before* egress is flipped.

---

## 4. Architecture — secure-aggregation merge backend + ingestion

**The load-bearing correction to the current scaffold:** `HttpAggregateEgressSink.upload(OdFlowMatrix)` takes an `OdFlowMatrix` of `ReleasedCell`, but a single device has `contributingUsers==1`, so client-side `KAnonymityFilter.suppress` (k=100) drops everything, and no device can ever mint a `ReleasedCell` anyway (`fromSecureMerge` needs `MergeBackendAuthority`, which no on-device code holds). **Devices must NOT upload ReleasedCells. They upload per-device *partial indicator aggregates* (raw, capped, un-noised). The SERVER does the cross-device merge — the sole place `contributingUsers>=100` is reached — adds Laplace noise ONCE at merge, and mints the `ReleasedCell` via `ReleasedCell.fromSecureMerge(MergeBackendAuthority.forSecureAggregationBackend, …)` as the final auditable gate.**

The key contract insight that makes cryptographic secure-aggregation compatible with k-anon: `ContributionCap` enforces exactly one 0/1 indicator per cell per epoch, so **the merged sum of indicators IS the distinct-contributing-user count** → "k≥100" becomes "merged sum ≥ 100". Cryptographic secure-agg (which sums but cannot count distinct users) then works directly.

### Device → server protocol
- **Payload** = per-epoch partial aggregate: a list of `(cellKeyString, 1)` indicators, where `cellKeyString == OdCellKey.toKeyString()` (`origin>dest|hour|dayType`) plus catchment partials (`StationArrivalCell.toKeyString()` = `stationId|hour|dayType`). Source = `OdAggregator.snapshot()` cells (`contributingUsers==1`), already bounded by `ContributionCap` (≤4 distinct cells/day, ≤1 per cell/day ⇒ L1 sensitivity ≤4).
- **CRITICAL — upload RAW indicators.** Not the Laplace-noised `ReleaseCandidateCell`, not after client k-anon: client k-anon suppresses 100%, and client noise would double-noise (the model is central — `DpModel.central`, `noiseAppliedAt:'merge'`). **No coordinate, no user id, no device id, no trajectory ever in the payload** (the coordinate-free type invariant already guarantees the payload is not trajectory-representable).
- **Auth + distinct-user counting:** reuse the `backend/share` bearer pattern (a `DATA_INGEST_TOKEN` app secret, constant-time compared like `SHARE_AUTH_TOKEN`) **plus Play Integrity / App Attest** attestation to prove a genuine app instance with no user identity (blocks poisoning). To count distinct devices per cell *without* a cross-day profile, each device derives a **per-epoch rotating pseudonym** (unlinkable across epochs, e.g. `HMAC(deviceSecret, epochId)` truncated). Server dedups within one epoch via `UNIQUE(epoch, cell_key, pseudonym)` — honest distinct-device count, no persistent identifier.
- **Batching/scheduling:** accumulate in existing Hive boxes; upload **once per epoch (daily)** via WorkManager/BGTaskScheduler, gated on charging + unmetered, **OFF the alarm/wake path, fail-open** (mirrors `DataAssetPipeline.onTripCompleted`'s unawaited try/catch). Retries idempotent via the UNIQUE constraint. **Upload path must re-check `MobilityConsentService.isSharingEnabled` as statement one**, and honor `kDataAssetEgressEnabled` + non-empty `kDataAssetEgressEndpoint` before doing anything.

### The merge — MVP (trusted-server sum + suppression)
At epoch close, per cell: `contributingUsers = COUNT(DISTINCT pseudonym)`; `count = SUM(indicator)`; **drop** every cell with `contributingUsers < kOdKAnonymityThreshold` (100); add **Laplace(scale = sensitivity/ε = 1/0.44 ≈ 2.27)** noise ONCE to survivors; clamp negatives to 0 (matches `LaplaceMechanism.noisyCount`).
**Honest labeling required:** in this MVP the server *does* see individual `(cell,1)` rows in the clear. "Secure" here = TLS + transient partials + rotating per-epoch pseudonym + hard-delete after merge + no persistent id — **NOT cryptography.** This is enough to ship real k≥100 DP releases once legal + contributors + a buyer exist.

### Build shape
A second **Railway Node service** mirroring `backend/share/server.js` + **Postgres** + a **scheduled merge job** + a thin **Dart mint/verify step** that runs the real `fromSecureMerge` as the final auditable gate.

### Cryptographic upgrade path
- **B.1 — Shuffler (ESA / Prochlo Encode-Shuffle-Analyze):** an independent shuffle tier in a *different trust domain* strips network metadata and shuffles submissions before the aggregator. Aggregator still sees `(cell,1)` rows but cannot attribute origin. **~1 week, big privacy win — recommended first upgrade.**
- **B.2 — Cryptographic secure aggregation (Prio3 / DAP, IETF PPM):** device secret-shares each indicator across ≥2 non-colluding aggregators (your Railway + an external helper, e.g. divviup.org / ISRG); each sums its shares; only the sum is reconstructed → no individual indicator ever in the clear to any single party. Prio3 SNIP proofs validate inputs are well-formed 0/1 **without seeing them** (poisoning-resistant). Because the indicator is strictly 1-per-cell-per-epoch, **Prio3's sum directly yields `contributingUsers`, so "k≥100" == "sum≥100"** — this is what makes true secure aggregation compatible with the k-anon contract.

### DP noise + budget
Noise is **server-side, on the merged cell, added exactly once** (central model — `DpParams.central`, `kEpsilonPerCell=0.44`, `dpDisclosure noiseAppliedAt:'merge'`). Per-user budget: ε ≤ 1.76/day, contribution capped at 4 distinct cells/day, each cell a 0/1 indicator ⇒ per-cell sensitivity = 1. **These are the shipped Google COVID-19 Community Mobility Report defaults** (https://www.google.com/covid19/mobility/) — not invented — and ε is disclosed *with* its model + sensitivity. In the Prio3 world, upgrade to **distributed noise generation** (each helper adds a noise share) so no single party can subtract the noise.

---

## 5. Product & pricing

### Datasheet (grounded in shipped code, `lib/services/data_asset/`)
- **Flagship SKU `od-v1` — Aggregate Transit O-D Flow Matrix.** Row grain (`OdCellKey`): `(origin_station_token, dest_station_token, hour_bin 0–23, day_type ∈ {weekday, weekend}) → noisy_count`. Each `ReleasedCell` carries only: the key, `noisyCount` (int, DP-noised, clamped ≥0), `contributingUsers` (≥k), and disclosure flags `kSuppressed=true` / `dpApplied=true` / `epsilon=0.44`. `OdFlowMatrix` envelope states `schemaVersion='od-v1'`, `dpEpsilon`, `kThreshold`, hour-bin range, machine-readable `dpDisclosure`.
- **Second SKU — Station-Catchment Report:** `(station_token, hour_bin, day_type) → noisy arrival count`, same k=100.
- **No raw data representable at the wire:** no device id, no user id, **no coordinate anywhere in the types**; station tokens from a fixed **805-station catalogue** (19 cities / 46 lines); geohashes banned by type (reversible → re-identifying). *Actual sellable coverage = only cells clearing k=100 (near-zero at launch).* Cadence: monthly aggregation window, hourly × day-type bins.

### Privacy guarantees stated to buyers (each is a tripwire-tested code constant — weakening fails the build)
1. **k≥100 contributing users per cell** (not trips) — "Google 100-rule"; sparser cells dropped.
2. **Central-model Laplace DP, ε=0.44/cell**, per-user daily ε≤1.76, ≤4 distinct cells/day, per-cell sensitivity=1 — disclosed *with* model + sensitivity.
3. **On-device-first:** raw trajectories never leave the phone; a `ReleasedCell` is constructable *only* by the secure-merge backend holding a `MergeBackendAuthority` token.
4. **Consented, default-OFF, unbundled, one-tap withdrawal**; wake-alarm works identically on/off (DPDP s.6(1) "unconditional").
5. **Bright line:** never a trajectory, never device-level, never a data broker, never sensitive inference, 18+ gated.
6. **Precedent cited to buyers:** US Census **OnTheMap** (first production DP, protects exactly an O-D matrix — https://onthemap.ces.census.gov/) + Google Mobility Reports (same k+DP guardrails).

### Value prop per segment
- **Transit authorities (BMRCL, DMRC, CMRL, BMTC):** labeled, near-real-time O-D matrix replacing stale one-off CMP surveys and withheld telco CDR — GeoWake holds **rider-DECLARED destinations**, eliminating the trip-end/purpose inference StreetLight/Replica/Placer must model.
- **CMP consultants (WRI India, AECOM, WSP):** cheaper, fresher, legally cleaner per-study O-D input; they resell into MoHUA CMPs (B2B2G).
- **DULT / Smart City ICCCs:** corridor demand + mode-split trends.
- **Academia / Data-for-Good (IISc CiSTUP, IITs, WRI Ross):** free tier that seeds coverage AND co-produces the anonymization-methodology paper that *is* the credibility proof.
- **Retail / QSR / OOH (LATER, catchment SKU):** station footfall/dwell — the Placer.ai lane, deferred (micro-targeting is creepier than serving planners).

### Pricing — anchor the ceiling on US comps, price the floor for Indian public procurement
- **US anchors:** StreetLight/Teton County WY = **$42,888/yr** (O-D-for-modeling line alone $19,600); Replica ≈ **0.15 × served population**; Placer.ai **$5k–30k/yr** band (Datarade: aggregated data ~$8,000/mo entry to ~$96,000/yr — https://datarade.ai/).
- **(a) Per-city annual subscription (flagship)** — re-priced to India at **₹5–25 lakh/city/yr ($6k–30k)** to a transit corp or CMP consultant; free/near-zero academic tier to seed.
- **(b) One-time per-study license** — a CMP is a one-off 5-stage study; sell a per-CMP O-D dataset at **₹3–10 lakh**, matching how consultants budget line-items. **Best first-money shape.**
- **(c) API/feed subscription (later)** — metered per station-report or tiered by #stations/metros, benchmarked to the Placer $5–30k band.
- **How to price a small-but-growing dataset:** price on **value & uniqueness** (labeled-intent O-D is a different product class), never on panel volume — you will lose a volume fight to Veraset's 10B pings/day. Land with a **paid pilot / per-study license (~₹1–3 lakh)**, not an annual sub you can't yet honor. Use **coverage-gated pricing:** publish a live "coverage map" of which corridors clear k=100, bill only for those. Run a **free public-trend dashboard** as loss-leader/credibility.

---

## 6. Go-to-market & first pilots

**Sequence relationships before revenue; revenue behind scale.**

1. **Now (pre-scale):** publish the **anonymization methodology** (co-authored with an academic partner — IISc CiSTUP / WRI India). This paper is the buyer AND regulator credibility artifact; it de-risks both the DPIA and Play review. Cost: near-zero, time only.
2. **Now:** pursue **non-binding LOIs / letters of interest** from 1–2 CMP consultants and one transit corporation. An LOI ("we would evaluate a labeled O-D dataset for corridor X at k≥100") is the go-signal for the build — and evidence of demand for any acquirer.
3. **First paid shape = per-study license, not a subscription.** The natural first buyer is a **CMP consultant** (WRI India / AECOM / WSP) mid-study who needs a fresh O-D input for a specific corridor — a **₹1–3 lakh per-CMP dataset** they line-item into an 80%-MoHUA-funded study. This is B2B2G: the consultant, not the metro's procurement, is your customer.
4. **Free academic/Data-for-Good tier** seeds coverage in the target metro and generates the corridor evidence that clears k=100.
5. **Defer** retail/QSR/OOH catchment entirely until planners validate the product and density exists.

**Beachhead pick:** one metro, all-in (per §7 the density math only closes city-by-city). Bengaluru (BMRCL ~7–8 lakh rides/day, IISc CiSTUP + DULT + WRI India ecosystem present) is the strongest single-city bet.

---

## 7. Phased roadmap with go/no-go gates

| Phase | What happens | Egress | Go/no-go GATE to advance |
|---|---|---|---|
| **0 — Now (shipped)** | Guardrails in code, egress hard-OFF; consent flow default-OFF, unbundled | OFF | *(baseline)* |
| **A — Optionality** | Publish methodology paper w/ academic partner; secure 1–2 LOIs; draft DPIA | OFF | **GATE A→B:** ≥1 written LOI from a consultant/transit buyer **AND** counsel confirms the sale structure can stay outside Play's "sale" definition |
| **B — Build merge backend (MVP)** | Stand up Railway ingestion + merge service + Postgres; device uploads raw partials; server mints `ReleasedCell` via `fromSecureMerge`; still egress-OFF, internal only | OFF (internal) | **GATE B→C — ALL of:** (1) beachhead metro at **~20–50k concentrated opt-in daily riders**; (2) a corridor coverage map showing real cells clearing **k=100**; (3) **signed DPIA + counsel opinion**; (4) a **contracted buyer** (paid pilot/per-study) |
| **C — First sale** | Flip egress for the contracted buyer only; deliver per-study `od-v1` dataset under contract (no re-identification / no re-sale clauses) | ON (scoped) | **GATE C→D:** buyer renews or a 2nd buyer signs; Play review survived; zero re-identification incidents |
| **D — Scale + crypto upgrade** | Add Shuffler (B.1, ~1 week), then Prio3/DAP (B.2) with distributed noise; add per-city subscription + catchment SKU | ON | *(ongoing)* |

**The gates are conjunctive on purpose:** density *and* legal *and* buyer must ALL be true before egress flips. Any single one missing = stay in the prior phase. Do not build Phase B on a roadmap date; build it when Gate A→B trips.

---

## 8. Risk register + mitigations

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| R1 | **Cold-start / coverage** — no cells clear k=100, nothing to sell | **High** | Gate C on concrete density (20–50k/metro); coverage-gated pricing; free academic tier to seed one metro; never promise a subscription you can't honor |
| R2 | **No buyer materializes** — India procurement is survey/consultancy, tender-driven | **High** | Sell to *consultants* (B2B2G per-study), not metro procurement; require an LOI before Phase B; keep asset as acquirer story if direct sales stall |
| R3 | **Google Play removal** — "sale of sensitive location" with no aggregate safe-harbor | **High** | Sell an aggregate *product* not user data; separate unbundled opt-in; precise Data-safety disclosure; counsel opinion on "sale" definition as Gate A→B |
| R4 | **Re-identification** — mobility data notoriously re-identifiable | **High** | k≥100 + central DP ε=0.44 + coarse bins + small-cell suppression; never device-level/trajectory; DPIA documents the singling-out/linkage/inference analysis; contractual no-re-id/no-resale |
| R5 | **"Secure" mislabeling in MVP** — server sees `(cell,1)` rows in clear | **Med** | Label honestly to buyers/counsel (TLS + transient + rotating pseudonym + hard-delete, NOT crypto); prioritize Shuffler (B.1) then Prio3 (B.2) upgrade |
| R6 | **Poisoning** — attacker injects fake partials to skew/de-anon cells | **Med** | Play Integrity/App Attest attestation; Prio3 SNIP input-validity proofs at Phase D |
| R7 | **Reputation / trust** — the entire broker cohort died on breaches | **Med** | Privacy-by-construction as the brand; published methodology; no raw feed ever; 18+ gate |
| R8 | **Distraction from core** — data line diverts effort from the wake-alarm | **Med** | Keep egress OFF and backend unbuilt until gates trip; Phase A is cheap (paper + LOIs), not engineering |
| R9 | **SDF designation** — if notified, DPIA + audit + DPO become mandatory | **Low** | Voluntary DPIA already current; appoint DPO/counsel reviewer if volume grows |
| R10 | **DPDP enforcement shift** — Rules effective ~May 2027; standard is unquantified | **Low-Med** | Conservative parameters now; counsel on retainer; document "reasonable person" defense |

---

## 9. What the founder must decide / provide

1. **Name the buyer.** Which specific first customer — a CMP consultant (WRI India / AECOM / WSP) or a transit corporation (BMRCL first)? The GTM and Phase B build are meaningless without a named target and an LOI. *Decision + owner needed.*
2. **Authorize (or decline) the methodology paper + academic partnership** (IISc CiSTUP / WRI India). This is the cheapest, highest-leverage Phase A action and the credibility keystone. *Go/no-go.*
3. **Engage Indian privacy counsel** for: (a) the DPIA sign-off, (b) a written opinion that the aggregate-product sale stays outside Google Play's "sale" definition, and (c) the DPDP consent/notice review. **This opinion is Gate A→B and is non-negotiable before any egress.** *Budget: retainer.*
4. **Own the DPIA.** Voluntary now, but it is the single best evidentiary shield. Assign an owner; use Appendix A as the skeleton; get senior sign-off + review cadence.
5. **Set the density trigger explicitly** — confirm ~20–50k concentrated opt-in daily riders in one metro as the Gate B→C threshold, and instrument a live coverage map so the trigger is observable, not guessed.
6. **Budget decision:** Phase A is near-zero (writing + relationships + counsel retainer). Phase B is a second Railway service + Postgres + a merge job + Dart mint step — modest, but do **not** fund it until Gate A→B trips. Phase D crypto (Prio3/DAP + external helper like divviup.org) is a later, larger spend.
7. **Confirm the strategic frame:** agree this is an **optionality/acquirer asset**, not a years-1–3 revenue line — so it is resourced accordingly and never allowed to distract from the core wake-alarm product.

---

## Appendix A — DPIA outline (6 sections)

1. **Description of processing** — purposes; data types (raw GPS on-device → derived OD counts); categories of data principals; full data-flow/lifecycle showing raw never leaves the device (payload = `(cellKeyString, 1)` indicators only).
2. **Necessity & proportionality** — why aggregation is the minimal processing for the monetization purpose; data-minimization justification (coordinate-free types, contribution cap ≤4 cells/day).
3. **Risk assessment** — harms to principals incl. re-identification; the singling-out / linkage / inference analysis with **k=100** and **ε=0.44** parameters, per-user budget ε≤1.76, and small-cell suppression.
4. **Mitigation measures** — on-device processing; secure cross-device merge; k≥100 threshold; central-model DP noise added once at merge; rotating per-epoch pseudonym (no persistent id); hard-delete of partials post-merge; encryption/TLS; access controls; Play Integrity attestation; contractual buyer restrictions (no re-identification / no re-sale); residual-risk statement + honest "MVP is not cryptographic" note.
5. **Data-principal rights** — consent (free/specific/informed/unconditional/unambiguous, default-OFF, unbundled); one-tap withdrawal (as easy as giving); access/correction; erasure; grievance redressal; nomination; Rule 3 notice in Eighth-Schedule languages on request.
6. **Governance sign-off** — DPO/counsel review; senior-management approval; review cadence (≥ every 12 months, and on any parameter/schema change); trigger to re-run on SDF designation.

---

## Appendix B — Sources cited inline
Market size: GMInsights (https://www.gminsights.com/), DataIntelo (https://dataintelo.com/). Pricing benchmarks: Datarade (https://datarade.ai/), StreetLight/Teton County subscription record, Placer.ai raise (Aug 2024). Broker cull: FTC actions (https://www.ftc.gov/news-events), Near Intelligence Chapter 11 (Dec 2023), SafeGraph Patterns discontinuation (2023). India: MoHUA CMP/DataSmart Cities (https://smartcities.gov.in/), ADB anonymized-OD guidance. Legal: DPDP Act 2023 + DPDP Rules 2025 (https://www.meity.gov.in/), Google Play User Data policy (https://support.google.com/googleplay/android-developer/answer/10144311), EDPB anonymization vectors. Privacy precedent: US Census OnTheMap (https://onthemap.ces.census.gov/), Google COVID-19 Community Mobility Reports (https://www.google.com/covid19/mobility/). *URLs are canonical domains for the named sources; confirm exact deep-links with counsel before external citation.*