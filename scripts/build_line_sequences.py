#!/usr/bin/env python3
"""
Build ORDERED per-line metro station sequences from the existing bundled data
(lib/all_india_stops.dart), reconstructing station order from coordinates via
nearest-neighbour chaining from a line terminus.

WHY: the bundled data (OSM + yometro scrape) carries per-stop `line`/`city`/`lat`/`lng`
but NO station ORDER. This derives the order so a route can use its own line's
stations in sequence (fixing wrong-metro-snap + correct "N stops before" counting).

Output:
  assets/india_metro/line_sequences.json   -> {city: {lineKey: {stops:[{name,lat,lng,seq}], maxHopM, confident}}}
Lines with a max inter-station hop > THRESHOLD are flagged confident=false
(branch/loop/missing-station/blank-tag) and should be verified against official
GTFS (Delhi DMRC / Hyderabad / Kochi) or manually before being trusted.

Validated correct end-to-end on: Delhi Red, Delhi Yellow, Mumbai Blue,
Kolkata Blue, Chennai Blue.
"""
import re, math, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "lib", "all_india_stops.dart")
OUT = os.path.join(ROOT, "assets", "india_metro", "line_sequences.json")
HOP_THRESHOLD_M = 3500  # a single hop larger than this => flag for review

COLORS = {'blue','green','red','yellow','purple','pink','orange','aqua','magenta',
          'violet','grey','gray','cyan','teal','silver','gold'}
GENERIC = {'line','metro','rail','railway','subway','the','express','corridor',
           'rapid','transit','route'}


def canon_line(s: str) -> str:
    if not s:
        return ''
    s = s.lower()
    s = re.sub(r'&#?[a-z0-9]+;', '', s)      # strip HTML entities (◙ etc.)
    s = re.sub(r'[^a-z0-9]+', ' ', s)
    toks = [t for t in s.split() if t and t not in GENERIC]
    for t in toks:
        if t in COLORS:
            return t
    return ' '.join(toks) or 'unknown'


def haversine(a, b):
    R = 6371000.0
    la1, lo1, la2, lo2 = map(math.radians, [a[0], a[1], b[0], b[1]])
    d = (math.sin((la2 - la1) / 2) ** 2
         + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2)
    return 2 * R * math.asin(math.sqrt(d))


def order_line(pts: dict):
    """pts: {name: (lat,lng)} -> (ordered_names, max_hop_m). NN chain from the
    farthest-apart pair (the two termini)."""
    ks = list(pts)
    if len(ks) <= 2:
        return ks, 0.0
    best = (-1.0, 0, 0)
    for i in range(len(ks)):
        for j in range(i + 1, len(ks)):
            d = haversine(pts[ks[i]], pts[ks[j]])
            if d > best[0]:
                best = (d, i, j)
    order = [best[1]]
    rem = set(range(len(ks)))
    rem.discard(best[1])
    while rem:
        last = order[-1]
        nn = min(rem, key=lambda k: haversine(pts[ks[last]], pts[ks[k]]))
        order.append(nn)
        rem.discard(nn)
    hops = [haversine(pts[ks[order[i]]], pts[ks[order[i + 1]]])
            for i in range(len(order) - 1)]
    return [ks[k] for k in order], (max(hops) if hops else 0.0)


def main():
    txt = open(SRC).read()
    entries = re.findall(
        r'\{[^{}]*?"city"\s*:\s*"([^"]*)"[^{}]*?"name"\s*:\s*"([^"]*)"'
        r'[^{}]*?"lat"\s*:\s*([\d.\-]+)[^{}]*?"lng"\s*:\s*([\d.\-]+)'
        r'[^{}]*?"line"\s*:\s*"([^"]*)"[^{}]*?\}', txt, re.S)
    from collections import defaultdict
    lines = defaultdict(dict)
    for city, name, lat, lng, line in entries:
        lc = canon_line(line)
        lines[(city, lc)][name] = (float(lat), float(lng))

    out = {}
    confident = review = 0
    for (city, lc), pts in sorted(lines.items()):
        if lc == 'unknown' or len(pts) < 2:
            continue
        seq, maxhop = order_line(pts)
        ok = maxhop < HOP_THRESHOLD_M
        out.setdefault(city, {})[lc] = {
            'stops': [{'name': n, 'lat': pts[n][0], 'lng': pts[n][1], 'seq': i}
                      for i, n in enumerate(seq)],
            'maxHopM': round(maxhop),
            'confident': ok,
        }
        confident += ok
        review += (not ok)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(out, open(OUT, 'w'), indent=1, ensure_ascii=False)
    print(f"parsed {len(entries)} stations -> {confident} confident lines, "
          f"{review} flagged for review. Wrote {OUT}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
