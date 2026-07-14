# Metro data — handoff for Claude-Science

Everything you need for pan-India metro stops + **ordered per-line sequences**. Use the ONE consolidated file first; the rest are sources/provenance.

## ⭐ Use this first
**`assets/india_metro/metro_dataset.json`** — the single authoritative dataset (schema `wakepoint.metro.v1`).
Shape:
```
{ "cities": { "<city>": {
    "ordered_lines_confident": ["purple","green",...],
    "ordered_lines_flagged":   ["blue","pink",...],   // NOT trustworthy — see §Flagged
    "stations_ordered": 84, "inventory_stations": 84, "audit_target": 85,
    "lines": { "<lineKey>": {
        "stops": [ {"name":"Challaghatta","lat":..,"lng":..,"seq":0}, ... ],  // seq = along-line order
        "maxHopM": 1830, "confident": true } } } } }
```
- `lineKey` is a canonical line token (color word like `purple`/`blue`, or `m1`, or a numeric like `7`). Colors are kept distinct (Delhi Magenta ≠ Pink, Violet ≠ Purple).
- `seq` gives the station ORDER along the line (0 = one terminus). This is the piece that did NOT exist before — reconstructed from coordinates (nearest-neighbour chain from the farthest-apart terminus pair).
- **Coverage:** 19 cities · 46 lines (**37 confident**, 9 flagged) · **805 stations ordered**.

## Provenance / raw sources (if you need to rebuild or cross-check)
| File | What it is |
|---|---|
| `lib/all_india_stops.dart` | The station INVENTORY the app ships (~858 stops): `city, name, line, lat, lng, network, status, lineColor`. Merged OSM + yometro, <150 m spatial dedup. **Line-tagged but originally UNORDERED.** |
| `assets/india_metro/india_metro_osm_stations.json` | Raw OSM/Overpass pull, 869 stations (nodes only, no route relations → no order). ODbL, 2025-12-25. `+ .meta.json` has the Overpass query + provenance. |
| `scripts/scraped_metro_data.json` | yometro scrape: 494 stations, 5 cities (Delhi/Mumbai/Chennai/Kolkata/NaviMumbai): `city, name, line, lineColor, lat, lng, url`. Line-tagged, unordered. |
| `docs/india-metro-data/docs/detailed_metro_audit_assessment.md` | Manual AUDIT: authoritative operational station COUNTS for 28 cities with official source URLs (DMRC/BMRCL/HMRL/etc.). Use as the coverage target. |
| `scripts/build_line_sequences.py` | The ORDERING generator (reproducible). Run it to regenerate `line_sequences.json` after any data update. |
| `lib/metro_color_map.dart` | Line color mapping. |
| `claudesciencesession/data/ride_station_sequence.json` | The ONE real logged ride's true station sequence (Bengaluru Purple, Rajajinagar→Whitefield) — your ground-truth anchor. |

## ⚠️ Flagged lines (9) — DO NOT trust the order; needs official GTFS or manual fix
`confident:false` (a single reconstructed hop > 3.5 km ⇒ a branch, ring, or blank tag):
- **Delhi:** `blue` (branched — Yamuna Bank branch to Vaishali/Noida), `magenta`, `orange` (Airport Express, long hops), `pink` (partial RING — nearest-neighbour can't order a loop).
- **Bengaluru:** `''` (blank line-tag stations — data-quality gap in your audit), `green`.
- **Ahmedabad** `yellow`, **Mumbai** `red`, **Nagpur** `orange`.

**How to fix these (Tier-1 official GTFS with true `stop_times` order):**
- Delhi — DMRC static GTFS: `otd.delhi.gov.in/data/staticDMRC/` (262 stations, 36 routes; use `stops.txt`+`stop_times.txt`).
- Hyderabad — HMRL GTFS: `data.telangana.gov.in` / Transitland `f-hmrl~hyderabad`.
- Kochi — KMRL GTFS: Transitland `f-t9y3-kochimetro`.
- Bengaluru — community/semi-official: `github.com/geohacker/namma-metro`, `data.opencity.in` (BMRCL); fix blank line tags first.
- For branched lines (Delhi Blue) split into main + branch sequences; for ring lines (Delhi Pink) store as an ordered ring with wrap-around.

## What this data is FOR (why you need it)
Per `CLAUDE_SCIENCE_HANDOFF_GPS_OUT.md`, the GPS-out research needs, per route: the ordered station list (arc-length anchors for the EKF), the line geometry (P3 curvature anchor), and the boarding station (P4 cold-start-underground). `metro_dataset.json[city][line].stops[].{lat,lng,seq}` gives all three. Cross-check any derived order against the audit counts and, for the 9 flagged lines, against GTFS before trusting it in an experiment.

## Regenerate
```
python3 scripts/build_line_sequences.py   # -> assets/india_metro/line_sequences.json
# then re-run the consolidation cell to refresh assets/india_metro/metro_dataset.json
```
