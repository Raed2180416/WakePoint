## GeoWake zero-cost Google Maps replacement — July 2026 refresh

### Big picture correction to the plan
The single biggest change since the last version of this plan isn't in the routing/tiles stack — it's that **the Oracle free-tier ARM box the plan was resting on got cut in half with zero warning.** Oracle silently reduced Always Free Ampere A1 from 4 OCPU/24GB RAM to **2 OCPU/12GB RAM**, effective **June 15, 2026**, discovered by users only when instances were shut down — no blog post, no changelog entry ([InfoQ, reporting July 2026](https://www.infoq.com/news/2026/07/oracle-cloud-free-tier-limits/); [Linuxiac](https://linuxiac.com/oracle-quietly-cuts-free-tier-ampere-a1-resources-in-half/)). There's a murky exception: support agents reportedly told some PAYG (not pure free-tier) accounts they could still provision 4/24, but this may not survive instance termination. **Treat "24GB free forever" as dead; plan for 12GB, with a contingency budget for a small paid VM.** This matters because it's tighter than what GraphHopper/OSRM typically want for import/build (see below) — the fix is to build the graph on a temporary bigger machine (or locally on your dev box) and ship only the finished tiles/graph files to the 12GB serving VM.

### 1. GraphHopper — VERIFIED, still solid
- Latest stable: **GraphHopper 11.0, released Oct 14, 2025** ([official blog](https://www.graphhopper.com/blog/2025/10/14/graphhopper-routing-engine-11-0-released/), [GitHub releases](https://github.com/graphhopper/graphhopper/releases)) — a minor 10.2 bugfix landed Jan 20, 2025 in between. Actively maintained, Java/JVM-based.
- **No official ARM Docker image** from the GraphHopper project itself. Community multi-arch images exist (e.g. `mouhamedtec/graphhopper`, IsraelHikingMap's build pipeline which explicitly had to patch a Maven/JDK base image because it "wasn't published for ARM64") — workable but adds a supply-chain dependency you don't control ([GitHub PR](https://github.com/IsraelHikingMap/graphhopper-docker-image-push/pull/27)). Building your own multi-arch image via `docker buildx` from GraphHopper's Dockerfile is the safer path.
- RAM: independent 2026 comparison (pistack.xyz, Apr 25 2026) cites 40–60GB **JVM heap for planet-scale**; for a 1.6GB India-only extract (see §3 below) this scales down a lot — plan for 8–16GB heap during import, comfortably serving-only afterward. No India-specific benchmark was found; treat the India RAM number as an **estimate**, not verified.
- India OSM routing quality vs Google: no dedicated 2026 benchmark/study surfaced in this pass — this specific claim from the earlier plan remains **unverified**; don't cite a quality delta without a real head-to-head test.

### 2. OpenTripPlanner 2.x — mostly moot for GeoWake's use case
- Confirmed current release lineage includes **v2.7.0** (dated changelog exists at docs.opentripplanner.org); could not verify a specific 2.8 release date in this pass — treat "latest OTP2 version" as **v2.7.x confirmed, possibly newer, unverified beyond that**.
- The real finding is about **India GTFS coverage, not OTP itself**: India has GTFS for roughly "23 cities / 47+ agencies" per aggregator commentary, and it's overwhelmingly **bus data, not metro**. Delhi has an Open Transit Data portal serving GTFS (mainly DTC/cluster buses; Delhi Metro/DMRC coverage is inconsistent) ([otd.delhi.gov.in](https://otd.delhi.gov.in/documentation/)). Bengaluru's BMTC was only reported to be *opening* GTFS data around mid-2026, with **Namma Metro's own real-time/GTFS data not yet public** at the time of that reporting ([Construction World, 2026](https://www.constructionworld.in/policy-updates-and-economic-news/real-time-transit-data-opens/57062)). **No usable, well-maintained official GTFS feed was found for any Indian metro system as a first-class product** — this directly validates the earlier instinct to not chase OTP+GTFS for the core metro alarm feature.

### 3. Valhalla and OSRM — architecture reality check
- **OSRM: official Docker image (`osrm/osrm-backend:latest`) is amd64-only, verified directly on Docker Hub** ("OS/ARCH: linux/amd64"). A 2021 GitHub issue asking for arm64 images is still effectively unresolved upstream; community forks (`peterevans/osrm-backend`, `monogramm/docker-osrm-backend`) fill the gap but aren't official. **This kills "just docker-pull OSRM onto the Oracle ARM box" as a plan A** — you'd need to build your own arm64 image via buildx, or run OSRM on an x86 box instead and reserve ARM for GraphHopper/Valhalla, which do have crude ARM stories.
- Valhalla: tile-based, disk-heavy (~100GB disk for planet) but comparatively RAM-light — official guidance says planet builds run fine on 16GB RAM + SSD; country-scale (India ≈ 1.6GB OSM PBF, see below) should need meaningfully less. No explicit ARM Docker guidance found either way; Valhalla's own Docker docs don't call out architecture, so multi-arch support is **unverified, treat as "probably needs your own buildx image too."**
- **India OSM extract size (verified, primary source): `india-latest.osm.pbf` = 1.6GB** as of the 2026-07-19 snapshot ([Geofabrik](https://download.geofabrik.de/asia/india.html)) — about 5x Germany's ~300MB extract, which the pistack.xyz 2026 comparison used as its country-scale benchmark (OSRM ~5min build, GraphHopper 8–12min, Valhalla 15–20min for Germany). Scaling roughly linearly, expect India builds in the tens-of-minutes range on modest hardware, not hours — this is well within a 12GB Oracle box for a one-off overnight build, especially if you swap to a temporary larger instance just for the build step.

### 4. Transit routing without GTFS — the core strategic call
Given the GTFS coverage gap in §2, **the self-built static metro-line-graph approach (GeoWake's existing 869-station + line-sequence dataset) is the right call for the core alarm feature, not a compromise.** A general GTFS/OTP pipeline would need feeds that don't reliably exist for the systems GeoWake actually serves (metros), and would add a whole ingestion/refresh-monitoring subsystem for coverage that's still weaker than what you already have hand-curated. Reserve GTFS/OTP as a *future* nice-to-have for city bus legs, not a blocker for launch. Google's Directions API's transit mode remains functional in India (Routes API confirms transit routing prefs still supported), so the honest framing is: **you're not "replacing" Google Transit, you're routing around needing it** by scoping the product to metro station-graph navigation, which is cheaper, more reliable, and already built.

### 5. Map tiles: flutter_map + PMTiles/Protomaps on Cloudflare R2 — VERIFIED pricing, cheap at every tier
Cloudflare R2 pricing, confirmed directly from [developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/):
- Standard storage: **$0.015/GB-month**
- Class A ops (writes/lists): **$4.50/million**
- Class B ops (reads): **$0.36/million**
- **Egress: $0, unconditionally** (R2's headline feature)
- Free tier: 10GB-month storage, 1M Class A ops/month, 10M Class B ops/month

A country-scoped PMTiles archive (India + city insets) is a few GB, not the ~120GB global file ([Protomaps docs](https://docs.protomaps.com/pmtiles/)), so storage cost is negligible (~$0.05–0.10/mo, likely fully inside the free 10GB tier). The variable cost driver is Class B range-read requests per map session. **Modeled (not directly sourced) at ~100 range reads/session:**

| DAU | Class B reads/mo | Over free tier | R2 tile cost/mo |
|---|---|---|---|
| 1,000 | 3M | 0 | **$0** |
| 10,000 | 30M | 20M | **~$7.20** |
| 100,000 | 300M | 290M | **~$104** |

### 6. MapLibre Native Flutter — VERIFIED, production-viable but pick carefully
Two competing packages exist on pub.dev:
- **`maplibre_gl`** (fork of flutter-mapbox-gl): latest **v0.26.2**, actively maintained — recent changelog entries include a v0.25.0 Android SDK bump (Jan 7, 2026) and v0.26.x fixes for Android crashes and a WASM-compiled web target. This is the mature, battle-tested option.
- **`maplibre`** (ground-up FFI/JNI rewrite): newer, at **v0.3.5**, explicitly positioned as the future direction but far less battle-tested.
**Recommendation: ship on `maplibre_gl` now; treat `maplibre` as a 2027 migration candidate**, not a launch dependency.

### 7. Google Maps Platform India pricing — VERIFIED, confirms the ~70K free tier is real and current
Directly from Google's own India billing docs and pricing page:
- **Essentials SKUs (Dynamic Maps, Static Maps, Geocoding, Directions, Distance Matrix, Autocomplete): 70,000 free events/month each**, India-specific ([developers.google.com/maps/billing-and-pricing/india](https://developers.google.com/maps/billing-and-pricing/india))
- Pro SKUs: 35,000 free/month; Enterprise SKUs: 7,000 free/month; Map Tiles API (2D/Street View): 700,000 free/month
- India-eligible accounts get **up to 70% off Core Services** vs global rates, effective **Aug 1, 2024**, with a credit-structure change **March 1, 2025**
- Post-free-tier India pricing for Dynamic Maps: **~$2.10/1,000 calls up to 5M/month, $0.53/1,000 above 5M** (consistent with global Essentials tier of $7/1,000 for 10K–100K minus the ~70% India discount — the two figures cross-checked independently and align).

This confirms the earlier plan's "~70K free calls" claim is still accurate as of July 2026, but each SKU has its own separate 70K pool — don't conflate them.

### 8. Places Autocomplete alternatives for India — mixed verification
- **Photon (komoot)**: self-hostable, OSM-data-based, strong for free-text/typo-tolerant search; Nominatim has the edge on structured address matching ([Geoapify comparison](https://www.geoapify.com/nominatim-vs-photon-geocoder/)). No India-specific POI-density study found — OSM's India POI coverage is generally understood to lag proprietary India providers, but this is a **qualitative caveat, not a sourced benchmark**.
- **Ola Maps API**: official pricing page (fetched directly) confirms **500,000 free API requests/month across all APIs**, plus a **first-year-completely-free** promotion, and a **1-year-free offer for 10M+ calls/month commitments** ([maps.olakrutrim.com/pricing](https://maps.olakrutrim.com/pricing)). Older press (Feb 2025) mentioned a 5M/month free tier at launch — the current live page shows 500K, so **the free tier appears to have been tightened since launch; use 500K/month as the current number.**
- **Mappls (MapmyIndia)**: pricing is **not published**; the developer marketing page has no rate card, funneling everyone to a console/sales conversation. Third-party estimates (Datarade, unverified) suggest paid plans starting around **$300/month for 10,000 calls** — this is a low-confidence estimate, not a primary-source figure. Free tier appears to exist only for the consumer app, not confirmed for the API.

### Corrected cost curve at 1K / 10K / 100K DAU
Assumption for the Google baseline: ~1 map load + 1 directions call + 1 autocomplete session per DAU per day (conservative; real usage is likely higher), each hitting its own 70K-free India SKU pool.

| | **1,000 DAU** | **10,000 DAU** | **100,000 DAU** |
|---|---|---|---|
| Google Maps (Dynamic Maps SKU alone, India pricing) | $0 (30K calls, under 70K free) | ~$483/mo (230K over-free × $2.10/1K) | ~$6,153/mo (2.93M over-free × $2.10/1K) |
| *...plus Directions + Autocomplete SKUs, same shape* | ~$0 | roughly **$1,000–1,500/mo total** (estimate, sum of 3 SKUs) | roughly **$13,000–18,000/mo total** (estimate) |
| **Zero-cost stack: R2 tiles** | $0 | ~$7.20/mo | ~$104/mo |
| **Zero-cost stack: self-hosted routing (GraphHopper/Valhalla, own VM)** | $0 (Oracle free 2 OCPU/12GB, post-June-2026 cut) | $0–small (same box likely handles it) | small paid VM likely needed (~$10–40/mo estimate) |
| **Zero-cost stack: metro graph (GeoWake's own 869-station data)** | $0 | $0 | $0 |
| **Zero-cost stack: Photon/self-hosted autocomplete** | $0 | $0 | small paid VM share (estimate) |
| **Total zero-cost stack (estimate)** | **~$0/mo** | **~$10–50/mo** | **~$150–300/mo** |

The order-of-magnitude gap (hundreds of dollars vs tens of thousands at 100K DAU) is the headline number, and it strengthens rather than weakens with the July 2026 refresh — Google's India free tier didn't shrink, but it was never going to scale past a few thousand DAU for free either.

### What changed vs. the prior version of this plan
1. **Oracle free ARM is now 12GB, not 24GB** — the single most important correction; re-plan VM sizing and consider building graphs off-box.
2. **OSRM has no official ARM Docker image** — verified directly, not previously confirmed; budget for a custom buildx image or x86 hosting for OSRM specifically.
3. **India OSM extract is a known, verified 1.6GB** — de-risks RAM/build-time estimates for GraphHopper/Valhalla.
4. **No Indian metro system has a solid public GTFS feed** — confirms self-built station-graph routing is the correct architecture, not a stopgap.
5. **Google's India 70K-free-tier is confirmed still live and unchanged** in structure as of July 2026 — no expiry risk found, but it's per-SKU, not pooled, so real usage will burn through it faster than a single "70K total" mental model suggests.
6. **Ola Maps' free tier reads as 500K/month now**, down from an earlier-announced 5M/month figure — don't rely on the higher number if quoting Ola as a Places fallback.
7. **Mappls pricing remains opaque** — don't build a cost model around it without a direct sales quote.

### Suggested next actions
- Re-size the Oracle VM plan around 12GB RAM; test a GraphHopper + India extract import on that box directly rather than assuming it fits.
- Build (don't pull) an arm64 OSRM/Valhalla Docker image via `buildx` if staying on Oracle ARM, or park OSRM on a cheap x86 box (e.g., a small Hetzner/DO instance) instead.
- Do a real side-by-side quality check of GraphHopper-on-India-OSM vs Google Directions for a handful of real GeoWake commute routes before trusting routing quality parity — this claim is still unverified either way.
- Get a direct Mappls sales quote before including it in any cost model; don't publish estimated pricing as fact.

## KEY FACTS
- [verified] Oracle Cloud silently halved Always Free Ampere A1 ARM allocation from 4 OCPU/24GB RAM to 2 OCPU/12GB RAM, effective June 15, 2026, with no official announcement (InfoQ (July 2026), Linuxiac)
- [verified] Official osrm/osrm-backend Docker image on Docker Hub is linux/amd64 only; no official ARM64 image exists (Docker Hub direct fetch)
- [verified] India OSM extract (india-latest.osm.pbf) is 1.6GB as of the 2026-07-19 snapshot (Geofabrik download server)
- [verified] GraphHopper 11.0 is the latest stable release, dated October 14, 2025; no official ARM Docker image is published by the GraphHopper project (graphhopper.com blog, GitHub releases)
- [verified] Google Maps Platform India: Essentials SKUs (Dynamic Maps, Static Maps, Geocoding, Directions, Distance Matrix, Autocomplete) each get 70,000 free events/month, per-SKU not pooled, effective per Aug 2024 discount and March 2025 restructuring (developers.google.com/maps/billing-and-pricing/india)
- [verified] India Dynamic Maps post-free-tier pricing is approximately $2.10/1,000 calls up to 5M/month, $0.53/1,000 above that (cross-checked via Google Maps India pricing search results, consistent with global $7/1000 minus ~70% India discount)
- [verified] Cloudflare R2: $0.015/GB-month standard storage, $4.50/M Class A ops, $0.36/M Class B ops, $0 egress, free tier of 10GB storage + 1M Class A + 10M Class B ops/month (developers.cloudflare.com/r2/pricing)
- [likely] No Indian metro system was found with a solid, well-maintained public GTFS feed; Delhi's Open Transit Data portal skews toward bus data, and Bengaluru's BMTC/Namma Metro GTFS was still being opened up as of 2026 reporting (otd.delhi.gov.in, Construction World 2026 article)
- [verified] Ola Maps API's current official pricing page shows 500,000 free API requests/month across all APIs plus a first-year-free promotion, down from an earlier-announced 5M/month figure at launch (maps.olakrutrim.com/pricing direct fetch)
- [estimate] Mappls (MapmyIndia) API pricing is not publicly published; third-party estimates of ~$300/month for 10,000 calls are low-confidence, not primary-sourced (Datarade third-party listing)
- [verified] maplibre_gl Flutter package (v0.26.2) is the mature, actively-maintained MapLibre binding; a newer ground-up rewrite 'maplibre' package (v0.3.5) exists but is far less battle-tested (pub.dev changelog direct fetch)
- [estimate] Modeled zero-cost replacement stack cost is roughly $0/$10-50/$150-300 per month at 1K/10K/100K DAU, versus an estimated $0/$1,000-1,500/$13,000-18,000 per month for Google Maps Platform India at the same tiers (derived from verified R2 and Google Maps India pricing, with modeled usage assumptions)
