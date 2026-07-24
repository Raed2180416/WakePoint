# Business OS — Google Maps Cost Elimination

Goal (from the brief): launch on Google Maps as-is; then, in the background,
make the whole stack behave **identically** — same route fetching, direction
fetching, core logic — while running for essentially free. Grounded in
`research/maps_replacement_2026.md` (fact-checked July 2026).

## 1. Why this is the only cost that matters

Google Maps is the one line item that scales into real money. India pricing
(verified — each Essentials SKU has its OWN 70k free events/month, not pooled):

| DAU | Google Maps (India, all SKUs) | Zero-cost stack | Gap |
|---|---|---|---|
| 1,000 | ~$0 (under free tier) | ~$0 | — |
| 10,000 | ~$1,000–1,500/mo (est) | ~$10–50/mo | ~30–100× |
| 100,000 | ~$13,000–18,000/mo (est) | ~$150–300/mo | ~50–100× |

So: **stay on Google below a few thousand DAU (it's free there), and have the
replacement ready before the curve bites.** Migrate piece by piece, each with
zero behavior change, verified against Google output before flipping.

## 2. The architecture that makes "no behavior change" possible

The app already talks to the Node backend (`ApiClient`), which proxies Google.
The client doesn't know what routing engine sits behind the proxy. So every
migration is a **backend response-adapter** swap — the client's `LatLng` data
types and core logic never change. This is the key de-risking fact: we are not
touching the 18+ files that use `google_maps_flutter.LatLng` as a data type.

## 3. Migration order (lowest risk first, each behavior-verified)

1. **Nearby metro stops → already-bundled data.** `all_india_stops.dart` +
   869-station OSM dataset already ship in the app. Local Haversine search
   replaces Google Nearby Search with **zero quality loss** and zero calls.
   *(Easiest, do first.)*
2. **Metro transit routing → self-built station graph.** Verified finding: **no
   Indian metro has a solid public GTFS feed** (Delhi stale since 2023,
   Hyderabad monthly, Bengaluru none). So a general GTFS/OTP pipeline is the
   wrong tool. GeoWake already has station sequences + line geometry — build the
   metro route graph from that. This is the CORE use case and it becomes fully
   self-owned, more reliable than any third-party transit API for metros.
3. **Reverse geocoding → public Nominatim (cosmetic).** Low volume, app already
   falls back to "Dropped pin". 1 req/s public endpoint is fine; self-host later.
4. **Car/driving directions → GraphHopper 11 (self-hosted).** Java, runs on the
   Oracle ARM box. Build the graph off-box (India OSM = verified 1.6GB; build
   needs 8–16GB, serving less) and ship the finished graph to the 12GB VM.
   Response-adapter: GraphHopper JSON → the Google Directions shape the client
   expects. **Verify parity on real commute routes before flipping** (routing
   quality-vs-Google is unverified — test it, don't assume).
5. **Places autocomplete → keep Google (free tier) OR Ola Maps.** Within 70k
   free/mo at low DAU. Ola Maps API is a real India fallback (verified 500k free
   req/mo across APIs, first year free). Photon self-host needs 16–32GB — defer.
6. **Map tile rendering → keep Google, or flutter_map + PMTiles on R2.** Verified
   R2: $0 egress, ~$0/$7/$104 per mo at 1k/10k/100k DAU. `maplibre_gl` v0.26.2
   is the mature Flutter binding. This is the LAST thing to touch (client-side,
   highest-effort) — Dynamic Maps cost only bites at high DAU.

## 4. Infra reality (corrected July 2026)

- **Oracle Always-Free ARM was silently halved to 2 OCPU / 12GB** (June 15
  2026). Plan for 12GB; build graphs off-box; keep a small-paid-VM contingency.
- **OSRM has no official ARM Docker image** — GraphHopper (or Valhalla) is the
  ARM-friendly choice; don't plan on `docker pull osrm`.
- Configs already scaffolded in `deploy/oracle-vm/` (docker-compose, Caddy,
  graphhopper-config, setup.sh).

## 5. What "done" looks like

The backend serves directions/places/geocoding/nearby with Google entirely
behind a feature flag per-SKU, each independently switchable, each verified to
produce client-identical behavior. Google stays wired as the fallback on any
self-hosted failure (defense in depth). The user never notices; the bill drops
by ~50–100×. This is background autopilot work (task source: a milestone in
`02`), gated on real DAU growth so effort tracks need.
