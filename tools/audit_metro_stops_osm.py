#!/usr/bin/env python
"""Audit metro stop coordinates against live OpenStreetMap data.

Reads the snapshot in assets/india_metro/india_metro_osm_stations.json and re-fetches
current element coordinates from Overpass (out center) in batches.

Outputs:
- JSON summary (counts, thresholds)
- CSV of per-stop deltas

This checks *coordinate drift vs OSM*, not real-world correctness.
"""

from __future__ import annotations

import argparse
import csv
import dataclasses
import datetime as dt
import hashlib
import json
import math
import os
import random
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from typing import Any, Dict, Iterable, List, Optional, Tuple


CITY_MAPPINGS: Dict[str, List[str]] = {
    "bengaluru": ["Namma Metro", "Bangalore Metro"],
    "chennai": ["Chennai Metro"],
    "delhi_ncr": [
        "Delhi Metro",
        "Delhi Metro Rail",
        "Delhi Metro Rail Corporation",
        "DMRC",
        "Rapid Metro",
        "Noida Metro",
        "Gurugram Metro",
        "Gurgaon Metro",
        "Airport Express",
        "Magenta Line",
        "Red Line",
        "Blue Line",
        "Yellow Line",
        "Violet Line",
        "Green Line",
        "Pink Line",
        "Orange Line",
        "Grey Line",
        "Aqua Line",
        # NOTE: intentionally NOT including very-generic tokens like "NR"
        # which can cause many false-positive city classifications.
    ],
    "mumbai": ["Mumbai Metro", "Maha Mumbai Metro", "MMRDA"],
    "kolkata": ["Kolkata Metro"],
    "hyderabad": ["Hyderabad Metro"],
    "ahmedabad": ["Ahmedabad Metro", "Gujarat Metro", "GMRC"],
    "kochi": ["Kochi Metro"],
    "jaipur": ["Jaipur Metro"],
    "lucknow": ["Lucknow Metro"],
    "nagpur": ["Nagpur Metro"],
    "noida": ["Noida Metro"],
    "pune": ["Pune Metro", "Maha Metro"],
    "kanpur": ["Kanpur Metro"],
}


# Optional manual fallbacks if Nominatim is unavailable.
# Format: (south, west, north, east)
CITY_BBOX_FALLBACKS: Dict[str, Tuple[float, float, float, float]] = {
    "bengaluru": (12.75, 77.35, 13.20, 77.85),
    "chennai": (12.80, 80.05, 13.25, 80.35),
    "delhi_ncr": (28.40, 76.80, 28.90, 77.50),
    "mumbai": (18.85, 72.75, 19.35, 73.10),
    "kolkata": (22.40, 88.20, 22.75, 88.50),
    "hyderabad": (17.20, 78.25, 17.60, 78.65),
    "ahmedabad": (22.85, 72.45, 23.15, 72.75),
    "kochi": (9.85, 76.15, 10.10, 76.40),
    "jaipur": (26.80, 75.65, 27.05, 75.95),
    "lucknow": (26.72, 80.80, 27.05, 81.10),
    "nagpur": (21.00, 78.90, 21.25, 79.20),
    "noida": (28.45, 77.25, 28.75, 77.55),
    "pune": (18.35, 73.65, 18.70, 74.05),
    "kanpur": (26.35, 80.15, 26.55, 80.45),
}


@dataclasses.dataclass(frozen=True)
class Stop:
    city: str
    osm_type: str
    osm_id: int
    name: str
    stored_lat: float
    stored_lng: float
    network: str
    operator: str
    line: str
    ref: str
    tags: Dict[str, Any]


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)

    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dl / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return r * c


def classify_city(item: Dict[str, Any]) -> Optional[str]:
    network = str(item.get("network") or "")
    operator = str(item.get("operator") or "")
    line = str(item.get("line") or "")
    ref = str(item.get("ref") or "")
    name = str(item.get("name") or "")
    tags = item.get("tags") or {}
    combined = f"{network} {operator} {line} {ref} {name} {tags}".lower()

    for city, keywords in CITY_MAPPINGS.items():
        for kw in keywords:
            if kw.lower() in combined:
                return city
    return None


def classify_city_by_bbox(lat: float, lng: float) -> Optional[str]:
    # Order matters for overlapping areas (e.g., noida within delhi_ncr)
    priority = [
        "noida",
        "delhi_ncr",
        "bengaluru",
        "chennai",
        "mumbai",
        "kolkata",
        "hyderabad",
        "ahmedabad",
        "kochi",
        "jaipur",
        "lucknow",
        "nagpur",
        "pune",
        "kanpur",
    ]

    for city in priority:
        bbox = CITY_BBOX_FALLBACKS.get(city)
        if not bbox:
            continue
        south, west, north, east = bbox
        if south <= lat <= north and west <= lng <= east:
            return city
    return None


def load_stops(path: str) -> List[Stop]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    stops: List[Stop] = []
    for item in data:
        osm = item.get("osm") or {}
        osm_type = str(osm.get("type") or "")
        osm_id_raw = osm.get("id")
        if osm_type not in ("node", "way", "relation"):
            continue
        if not isinstance(osm_id_raw, int):
            try:
                osm_id_raw = int(osm_id_raw)
            except Exception:
                continue

        lat = item.get("lat")
        lng = item.get("lng")
        if lat is None or lng is None:
            continue

        lat_f = float(lat)
        lng_f = float(lng)

        city = classify_city_by_bbox(lat_f, lng_f) or classify_city(item) or "unclassified"

        tags = item.get("tags") or {}
        name = item.get("name")
        if not name:
            name = tags.get("name") or "Unknown"

        stops.append(
            Stop(
                city=city,
                osm_type=osm_type,
                osm_id=osm_id_raw,
                name=str(name),
                stored_lat=lat_f,
                stored_lng=lng_f,
                network=str(item.get("network") or ""),
                operator=str(item.get("operator") or ""),
                line=str(item.get("line") or ""),
                ref=str(item.get("ref") or ""),
                tags=tags,
            )
        )

    return stops


def cache_load(cache_path: str) -> Dict[str, Any]:
    if not os.path.exists(cache_path):
        return {}
    with open(cache_path, "r", encoding="utf-8") as f:
        try:
            return json.load(f)
        except Exception:
            return {}


def cache_save(cache_path: str, cache: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
    tmp = cache_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp, cache_path)


def http_get_json(url: str, *, insecure: bool, timeout_s: int = 30) -> Any:
    ssl_context = _build_ssl_context(insecure=insecure)
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "WakePointStopAudit/1.0 (local audit script)"},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=timeout_s, context=ssl_context) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_city_bbox(
    city_key: str,
    *,
    insecure: bool,
    cache: Dict[str, Any],
    cache_key_prefix: str = "nominatim_bbox",
) -> Optional[Tuple[float, float, float, float]]:
    """Return (south, west, north, east) bbox for a city.

    Uses cached Nominatim lookup when available; otherwise falls back to
    CITY_BBOX_FALLBACKS.
    """

    ck = f"{cache_key_prefix}:{city_key}"
    hit = cache.get(ck)
    if isinstance(hit, dict) and "bbox" in hit:
        b = hit.get("bbox")
        if isinstance(b, list) and len(b) == 4:
            return float(b[0]), float(b[1]), float(b[2]), float(b[3])

    if city_key in CITY_BBOX_FALLBACKS:
        return CITY_BBOX_FALLBACKS[city_key]
    return None


def fetch_city_bbox_from_nominatim(
    city_key: str,
    *,
    city_label: str,
    insecure: bool,
    cache: Dict[str, Any],
    cache_path: str,
    sleep_s: float = 1.1,
) -> Optional[Tuple[float, float, float, float]]:
    ck = f"nominatim_bbox:{city_key}"
    hit = cache.get(ck)
    if isinstance(hit, dict) and "bbox" in hit:
        b = hit.get("bbox")
        if isinstance(b, list) and len(b) == 4:
            return float(b[0]), float(b[1]), float(b[2]), float(b[3])

    # Nominatim usage policy expects low request volume + a valid UA.
    url = (
        "https://nominatim.openstreetmap.org/search?"
        + urllib.parse.urlencode(
            {
                "q": city_label,
                "format": "json",
                "limit": 1,
            }
        )
    )
    try:
        data = http_get_json(url, insecure=insecure, timeout_s=30)
        if isinstance(data, list) and data:
            bb = data[0].get("boundingbox")
            if isinstance(bb, list) and len(bb) == 4:
                south, north, west, east = map(float, bb)
                # Nominatim gives [south, north, west, east]
                bbox = (south, west, north, east)
                cache[ck] = {"bbox": list(bbox), "fetchedAt": dt.datetime.now(dt.timezone.utc).isoformat()}
                cache_save(cache_path, cache)
                time.sleep(sleep_s)
                return bbox
    except Exception:
        return None
    return None


def overpass_query_bbox(
    *,
    endpoint: str,
    bbox: Tuple[float, float, float, float],
    insecure: bool,
    timeout_s: int = 180,
) -> Dict[str, Dict[str, Any]]:
    """Fetch metro/light_rail stations within bbox.

    Returns mapping "type/id" -> {lat,lng,name,tags}
    """

    south, west, north, east = bbox
    # Keep query conservative; we can broaden if needed.
    query = (
        f"[out:json][timeout:{timeout_s}];"
        f"(nwr[public_transport=station][station~\"^(subway|metro|light_rail)$\"]({south},{west},{north},{east});"
        f"nwr[railway=station][station~\"^(subway|metro|light_rail)$\"]({south},{west},{north},{east});"
        f");out center tags;"
    )

    data = query.encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "User-Agent": "WakePointStopAudit/1.0 (local audit script)",
        },
        method="POST",
    )

    ssl_context = _build_ssl_context(insecure=insecure)
    with urllib.request.urlopen(req, timeout=timeout_s + 30, context=ssl_context) as resp:
        payload = json.loads(resp.read().decode("utf-8"))

    out: Dict[str, Dict[str, Any]] = {}
    for el in payload.get("elements", []):
        t = el.get("type")
        i = el.get("id")
        if t not in ("node", "way", "relation") or i is None:
            continue

        if t == "node":
            lat = el.get("lat")
            lon = el.get("lon")
        else:
            center = el.get("center") or {}
            lat = center.get("lat")
            lon = center.get("lon")
        if lat is None or lon is None:
            continue

        tags = el.get("tags") or {}
        name = tags.get("name") or ""
        out[f"{t}/{i}"] = {
            "lat": float(lat),
            "lng": float(lon),
            "name": str(name),
            "tags": tags,
        }
    return out


def _build_ssl_context(*, insecure: bool) -> ssl.SSLContext:
    if insecure:
        return ssl._create_unverified_context()  # noqa: SLF001

    try:
        import certifi  # type: ignore

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def overpass_query(
    elements: List[Tuple[str, int]],
    endpoint: str,
    *,
    insecure: bool,
    timeout_s: int = 180,
) -> Dict[str, Tuple[float, float]]:
    """Return mapping key "type/id" -> (lat, lng) from Overpass out center."""

    nodes = [str(i) for t, i in elements if t == "node"]
    ways = [str(i) for t, i in elements if t == "way"]
    rels = [str(i) for t, i in elements if t == "relation"]

    parts: List[str] = []
    if nodes:
        parts.append(f"node(id:{','.join(nodes)});")
    if ways:
        parts.append(f"way(id:{','.join(ways)});")
    if rels:
        parts.append(f"relation(id:{','.join(rels)});")

    query = f"[out:json][timeout:{timeout_s}];({''.join(parts)});out center;"

    data = query.encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "User-Agent": "WakePointStopAudit/1.0 (local audit script)",
        },
        method="POST",
    )

    ssl_context = _build_ssl_context(insecure=insecure)
    with urllib.request.urlopen(req, timeout=timeout_s + 30, context=ssl_context) as resp:
        raw = resp.read()

    payload = json.loads(raw.decode("utf-8"))
    out: Dict[str, Tuple[float, float]] = {}
    for el in payload.get("elements", []):
        t = el.get("type")
        i = el.get("id")
        if t not in ("node", "way", "relation") or i is None:
            continue

        if t == "node":
            lat = el.get("lat")
            lon = el.get("lon")
        else:
            center = el.get("center") or {}
            lat = center.get("lat")
            lon = center.get("lon")

        if lat is None or lon is None:
            continue
        out[f"{t}/{i}"] = (float(lat), float(lon))

    return out


def call_overpass_with_fallback(
    call,
    *,
    endpoints: List[str],
    attempts_per_endpoint: int,
    base_backoff_s: float = 1.0,
):
    last_err: Optional[Exception] = None
    for endpoint in endpoints:
        for attempt in range(1, attempts_per_endpoint + 1):
            try:
                return call(endpoint)
            except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
                last_err = e
                wait = min(60.0, base_backoff_s * (2 ** (attempt - 1)) + random.random())
                print(f"Overpass call failed via {endpoint} (attempt {attempt}/{attempts_per_endpoint}): {e} ; sleeping {wait:.1f}s")
                time.sleep(wait)
                continue
    if last_err is not None:
        raise last_err
    raise RuntimeError("Overpass call failed")


def batched(it: List[Tuple[str, int]], batch_size: int) -> Iterable[List[Tuple[str, int]]]:
    for idx in range(0, len(it), batch_size):
        yield it[idx : idx + batch_size]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--source",
        default="assets/india_metro/india_metro_osm_stations.json",
        help="Path to india_metro_osm_stations.json",
    )
    ap.add_argument(
        "--overpass",
        default="https://overpass-api.de/api/interpreter",
        help="Overpass interpreter endpoint",
    )
    ap.add_argument(
        "--overpass_fallbacks",
        default="https://overpass-api.de/api/interpreter,https://overpass.kumi.systems/api/interpreter,https://overpass.nchc.org.tw/api/interpreter",
        help="Comma-separated Overpass endpoints to try (primary first)",
    )
    ap.add_argument(
        "--insecure",
        action="store_true",
        help="Disable TLS cert verification (use only if needed)",
    )
    ap.add_argument(
        "--audit_live_bbox",
        action="store_true",
        help="Also compare snapshot vs live Overpass stations in a city bounding box",
    )
    ap.add_argument(
        "--use_nominatim",
        action="store_true",
        help="Fetch city bbox from Nominatim (cached). Otherwise uses fallback bboxes.",
    )
    ap.add_argument("--batch", type=int, default=75, help="Elements per Overpass request")
    ap.add_argument("--sleep", type=float, default=1.0, help="Seconds to sleep between batches")
    ap.add_argument("--max", type=int, default=0, help="Max stops to audit (0=all)")
    ap.add_argument("--city", default="", help="Restrict to a single city key (e.g., chennai)")
    ap.add_argument(
        "--cache",
        default="tools/.cache/osm_stop_coord_cache.json",
        help="Cache path for fetched live coordinates",
    )
    ap.add_argument(
        "--out_dir",
        default="build/reports",
        help="Output directory for reports",
    )
    args = ap.parse_args()

    stops = load_stops(args.source)
    if args.city:
        stops = [s for s in stops if s.city == args.city]

    if args.max and args.max > 0:
        stops = stops[: args.max]

    if not stops:
        print("No stops matched selection.")
        return 2

    cache = cache_load(args.cache)
    now_iso = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    endpoints = [e.strip() for e in str(args.overpass_fallbacks).split(",") if e.strip()]
    if not endpoints:
        endpoints = [args.overpass]

    # Build list of elements to fetch
    needed: List[Tuple[str, int]] = []
    for s in stops:
        key = f"{s.osm_type}/{s.osm_id}"
        hit = cache.get(key)
        if not hit or not isinstance(hit, dict) or "lat" not in hit or "lng" not in hit:
            needed.append((s.osm_type, s.osm_id))

    # Fetch in batches with retry/backoff
    if needed:
        print(f"Fetching {len(needed)} live coordinates from Overpass...")

    for batch in batched(needed, args.batch):
        for attempt in range(1, 6):
            try:
                def _call(ep: str):
                    return overpass_query(batch, endpoint=ep, insecure=args.insecure)

                result = call_overpass_with_fallback(
                    _call,
                    endpoints=endpoints,
                    attempts_per_endpoint=1,
                    base_backoff_s=1.0,
                )
                for key, (lat, lng) in result.items():
                    cache[key] = {"lat": lat, "lng": lng, "fetchedAt": now_iso}

                # Mark any missing elements explicitly (deleted or filtered)
                requested = {f"{t}/{i}" for t, i in batch}
                missing = requested.difference(result.keys())
                for key in missing:
                    cache.setdefault(key, {"missing": True, "fetchedAt": now_iso})

                cache_save(args.cache, cache)
                break
            except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
                wait = min(60.0, (2 ** (attempt - 1)) + random.random())
                print(f"Overpass batch failed (attempt {attempt}/5): {e} ; sleeping {wait:.1f}s")
                time.sleep(wait)
        time.sleep(args.sleep)

    # Compute deltas
    thresholds = [10.0, 50.0, 200.0, 1000.0]
    counts_by_city = defaultdict(lambda: {"total": 0, "missing": 0, **{f">{int(t)}m": 0 for t in thresholds}})

    rows: List[Dict[str, Any]] = []
    for s in stops:
        k = f"{s.osm_type}/{s.osm_id}"
        counts_by_city[s.city]["total"] += 1
        hit = cache.get(k) or {}
        if hit.get("missing") is True:
            counts_by_city[s.city]["missing"] += 1
            rows.append(
                {
                    "city": s.city,
                    "osm_type": s.osm_type,
                    "osm_id": s.osm_id,
                    "name": s.name,
                    "stored_lat": s.stored_lat,
                    "stored_lng": s.stored_lng,
                    "live_lat": "",
                    "live_lng": "",
                    "delta_m": "",
                    "network": s.network,
                    "operator": s.operator,
                    "line": s.line,
                    "ref": s.ref,
                }
            )
            continue

        live_lat = hit.get("lat")
        live_lng = hit.get("lng")
        if live_lat is None or live_lng is None:
            counts_by_city[s.city]["missing"] += 1
            continue

        delta_m = haversine_m(s.stored_lat, s.stored_lng, float(live_lat), float(live_lng))
        for t in thresholds:
            if delta_m > t:
                counts_by_city[s.city][f">{int(t)}m"] += 1

        rows.append(
            {
                "city": s.city,
                "osm_type": s.osm_type,
                "osm_id": s.osm_id,
                "name": s.name,
                "stored_lat": s.stored_lat,
                "stored_lng": s.stored_lng,
                "live_lat": float(live_lat),
                "live_lng": float(live_lng),
                "delta_m": round(delta_m, 3),
                "network": s.network,
                "operator": s.operator,
                "line": s.line,
                "ref": s.ref,
            }
        )

    os.makedirs(args.out_dir, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d_%H%M%S")
    base = f"metro_stop_audit_{stamp}"

    out_json = os.path.join(args.out_dir, base + ".summary.json")
    out_csv = os.path.join(args.out_dir, base + ".deltas.csv")

    summary: Dict[str, Any] = {
        "generatedAt": now_iso,
        "source": args.source,
        "overpass": args.overpass,
        "stopCount": len(stops),
        "cities": dict(counts_by_city),
        "thresholds_m": thresholds,
        "notes": [
            "This compares stored snapshot coordinates to current OSM element coordinates.",
            "It does not validate real-world correctness beyond OSM.",
        ],
    }

    if args.audit_live_bbox:
        # Compare snapshot stops vs live stops returned by bbox query.
        city_labels = {
            "bengaluru": "Bengaluru, India",
            "chennai": "Chennai, India",
            "delhi_ncr": "Delhi, India",
            "mumbai": "Mumbai, India",
            "kolkata": "Kolkata, India",
            "hyderabad": "Hyderabad, India",
            "ahmedabad": "Ahmedabad, India",
            "kochi": "Kochi, India",
            "jaipur": "Jaipur, India",
            "lucknow": "Lucknow, India",
            "nagpur": "Nagpur, India",
            "noida": "Noida, India",
            "pune": "Pune, India",
            "kanpur": "Kanpur, India",
        }

        cities = sorted({s.city for s in stops})
        if args.city:
            cities = [args.city]

        live_bbox_report: Dict[str, Any] = {}
        for c in cities:
            bbox = None
            if args.use_nominatim and c in city_labels:
                bbox = fetch_city_bbox_from_nominatim(
                    c,
                    city_label=city_labels[c],
                    insecure=args.insecure,
                    cache=cache,
                    cache_path=args.cache,
                )
            if bbox is None:
                bbox = get_city_bbox(c, insecure=args.insecure, cache=cache)
            if bbox is None:
                continue

            try:
                def _call_bbox(ep: str):
                    return overpass_query_bbox(endpoint=ep, bbox=bbox, insecure=args.insecure)

                live = call_overpass_with_fallback(
                    _call_bbox,
                    endpoints=endpoints,
                    attempts_per_endpoint=2,
                    base_backoff_s=1.0,
                )
            except Exception as e:
                live_bbox_report[c] = {
                    "bbox": list(bbox),
                    "error": str(e),
                }
                continue
            snapshot_ids = {f"{s.osm_type}/{s.osm_id}" for s in stops if s.city == c}
            live_ids = set(live.keys())

            missing = sorted(live_ids - snapshot_ids)
            extra = sorted(snapshot_ids - live_ids)

            live_bbox_report[c] = {
                "bbox": list(bbox),
                "snapshotCount": len(snapshot_ids),
                "liveCount": len(live_ids),
                "missingInSnapshot": len(missing),
                "extraInSnapshot": len(extra),
            }

            # Write detailed CSVs per city for missing/extra
            missing_csv = os.path.join(args.out_dir, f"{base}.{c}.missing_in_snapshot.csv")
            extra_csv = os.path.join(args.out_dir, f"{base}.{c}.extra_in_snapshot.csv")

            with open(missing_csv, "w", encoding="utf-8", newline="") as f:
                w = csv.DictWriter(f, fieldnames=["key", "name", "lat", "lng"])
                w.writeheader()
                for k in missing:
                    w.writerow({"key": k, **{x: live[k].get(x, "") for x in ("name", "lat", "lng")}})

            with open(extra_csv, "w", encoding="utf-8", newline="") as f:
                w = csv.DictWriter(f, fieldnames=["key", "name", "stored_lat", "stored_lng"])
                w.writeheader()
                for k in extra:
                    t, sid = k.split("/")
                    sid_i = int(sid)
                    s_match = next((s for s in stops if s.city == c and s.osm_type == t and s.osm_id == sid_i), None)
                    if s_match is None:
                        continue
                    w.writerow(
                        {
                            "key": k,
                            "name": s_match.name,
                            "stored_lat": s_match.stored_lat,
                            "stored_lng": s_match.stored_lng,
                        }
                    )

        summary["live_bbox_compare"] = live_bbox_report

    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2, sort_keys=True)

    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "city",
                "osm_type",
                "osm_id",
                "name",
                "stored_lat",
                "stored_lng",
                "live_lat",
                "live_lng",
                "delta_m",
                "network",
                "operator",
                "line",
                "ref",
            ],
        )
        writer.writeheader()
        for r in rows:
            writer.writerow(r)

    print(f"Wrote summary: {out_json}")
    print(f"Wrote deltas : {out_csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
