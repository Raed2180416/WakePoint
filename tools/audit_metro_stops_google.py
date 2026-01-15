#!/usr/bin/env python
"""Validate metro stop coordinates against Google Maps (Places API).

This script queries Google Places Text Search for each station name (with city bias)
and compares the returned geometry.location against the stored coordinates.

It reads the API key from an environment variable to avoid hardcoding secrets.

Env vars:
- WAKEPOINT_GOOGLE_MAPS_API_KEY: required

Outputs:
- build/reports/google_stop_audit_*.summary.json
- build/reports/google_stop_audit_*.deltas.csv

Notes / limitations:
- Google results are name-based and can be ambiguous (same station names across cities).
- This is a *best-effort* validation; the script includes basic confidence scoring.
- Respect Google Maps Platform Terms and your quota/billing limits.
"""

from __future__ import annotations

import argparse
import csv
import dataclasses
import datetime as dt
import difflib
import getpass
import json
import math
import os
import random
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Iterable, List, Optional, Tuple


@dataclasses.dataclass(frozen=True)
class Stop:
    key: str  # osm_type/osm_id
    city: str
    name: str
    lat: float
    lng: float


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dl / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return r * c


def _build_ssl_context() -> ssl.SSLContext:
    try:
        import certifi  # type: ignore

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def http_get_json(url: str, *, timeout_s: int = 30) -> Any:
    ctx = _build_ssl_context()
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "WakePointStopAudit/1.0 (local audit script)"},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=timeout_s, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


def load_stops(snapshot_json_path: str) -> List[Stop]:
    with open(snapshot_json_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    stops: List[Stop] = []
    for item in data:
        osm = item.get("osm") or {}
        osm_type = str(osm.get("type") or "")
        osm_id = osm.get("id")
        if osm_type not in ("node", "way", "relation"):
            continue
        if osm_id is None:
            continue
        try:
            osm_id_i = int(osm_id)
        except Exception:
            continue

        lat = item.get("lat")
        lng = item.get("lng")
        if lat is None or lng is None:
            continue

        tags = item.get("tags") or {}
        name = item.get("name") or tags.get("name") or "Unknown"

        # City assignment is best-effort; keep as blank if unknown.
        city = str(item.get("city") or "")

        stops.append(
            Stop(
                key=f"{osm_type}/{osm_id_i}",
                city=city,
                name=str(name),
                lat=float(lat),
                lng=float(lng),
            )
        )

    return stops


def normalize_name(s: str) -> str:
    return " ".join(s.lower().replace("metro station", "").replace("station", "").split())


def score_match(query_name: str, candidate_name: str) -> float:
    a = normalize_name(query_name)
    b = normalize_name(candidate_name)
    return difflib.SequenceMatcher(a=a, b=b).ratio()


def places_text_search(
    *,
    api_key: str,
    query: str,
    region: str = "in",
) -> Dict[str, Any]:
    # Text Search endpoint
    params = {
        "query": query,
        "key": api_key,
        "region": region,
    }
    url = "https://maps.googleapis.com/maps/api/place/textsearch/json?" + urllib.parse.urlencode(params)
    return http_get_json(url, timeout_s=30)


def cache_load(path: str) -> Dict[str, Any]:
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        try:
            return json.load(f)
        except Exception:
            return {}


def cache_save(path: str, cache: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp, path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--source",
        default="assets/india_metro/india_metro_osm_stations.json",
        help="Path to snapshot india_metro_osm_stations.json",
    )
    ap.add_argument("--city", default="", help="Optional city label to append to the query")
    ap.add_argument("--max", type=int, default=0, help="Max stops to validate (0=all)")
    ap.add_argument("--sleep", type=float, default=0.12, help="Sleep between API calls")
    ap.add_argument(
        "--progress_every",
        type=int,
        default=25,
        help="Print progress every N stops (0 disables)",
    )
    ap.add_argument(
        "--cache",
        default="tools/.cache/google_places_cache.json",
        help="Cache path for Google Places responses",
    )
    ap.add_argument("--out_dir", default="build/reports", help="Output directory")
    ap.add_argument(
        "--min_score",
        type=float,
        default=0.55,
        help="Minimum name similarity score to accept candidate",
    )
    args = ap.parse_args()

    api_key = os.environ.get("WAKEPOINT_GOOGLE_MAPS_API_KEY", "").strip()
    if not api_key:
        # Avoid putting secrets in command lines (history) or files.
        # If you pasted a key into chat previously, rotate/revoke it in GCP.
        api_key = getpass.getpass("Google Maps API key (input hidden): ").strip()
    if not api_key:
        raise SystemExit("API key is required.")

    # Masked confirmation only (never print full key)
    masked = f"{api_key[:6]}...{api_key[-4:]}" if len(api_key) >= 12 else "(too short to mask)"
    print(f"Using Google API key: {masked} (len={len(api_key)})")

    stops = load_stops(args.source)
    if args.max and args.max > 0:
        stops = stops[: args.max]

    cache = cache_load(args.cache)

    rows: List[Dict[str, Any]] = []
    counts = {
        "total": 0,
        "queried": 0,
        "no_results": 0,
        "rejected_low_score": 0,
        "api_errors": 0,
        ">10m": 0,
        ">50m": 0,
        ">200m": 0,
        ">1000m": 0,
    }

    thresholds = [10.0, 50.0, 200.0, 1000.0]

    total_n = len(stops)
    for idx, s in enumerate(stops):
        counts["total"] += 1

        if args.progress_every and idx % args.progress_every == 0:
            done = idx
            print(
                f"Progress: {done}/{total_n} | OK>{counts['>10m']}/{counts['>50m']}/{counts['>200m']}/{counts['>1000m']} "
                f"| no_results={counts['no_results']} rejected={counts['rejected_low_score']} api_errors={counts['api_errors']}"
            )

        query_city = (args.city or s.city).strip()
        q = s.name
        if query_city:
            q = f"{s.name} metro station {query_city} India"
        else:
            q = f"{s.name} metro station India"

        cache_key = f"textsearch:{q}"
        payload = cache.get(cache_key)

        # If the cache was populated with an invalid key (REQUEST_DENIED), don't reuse it.
        if payload is not None:
            cached_payload = payload.get("payload") if isinstance(payload, dict) else None
            cached_status = str((cached_payload or {}).get("status") or "")
            cached_err = str((cached_payload or {}).get("error_message") or "")
            if cached_status == "REQUEST_DENIED" and "invalid" in cached_err.lower():
                payload = None

        if payload is None:
            # Basic retry on OVER_QUERY_LIMIT
            for attempt in range(1, 6):
                try:
                    counts["queried"] += 1
                    payload = places_text_search(api_key=api_key, query=q)
                    cache[cache_key] = {
                        "payload": payload,
                        "fetchedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                    }
                    cache_save(args.cache, cache)

                    status = str(payload.get("status") or "")
                    if status == "OVER_QUERY_LIMIT":
                        wait = min(60.0, (2 ** (attempt - 1)) + random.random())
                        time.sleep(wait)
                        continue
                    break
                except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
                    counts["api_errors"] += 1
                    wait = min(60.0, (2 ** (attempt - 1)) + random.random())
                    time.sleep(wait)
                    if attempt == 5:
                        payload = {"status": "ERROR", "error": str(e)}
            time.sleep(args.sleep)
        else:
            payload = payload.get("payload")

        status = str((payload or {}).get("status") or "")
        results = (payload or {}).get("results") or []

        if status not in ("OK", "ZERO_RESULTS"):
            # Don't log key; store minimal status.
            rows.append(
                {
                    "key": s.key,
                    "name": s.name,
                    "query": q,
                    "stored_lat": s.lat,
                    "stored_lng": s.lng,
                    "google_name": "",
                    "google_lat": "",
                    "google_lng": "",
                    "delta_m": "",
                    "score": "",
                    "status": status,
                }
            )
            continue

        if not results:
            counts["no_results"] += 1
            rows.append(
                {
                    "key": s.key,
                    "name": s.name,
                    "query": q,
                    "stored_lat": s.lat,
                    "stored_lng": s.lng,
                    "google_name": "",
                    "google_lat": "",
                    "google_lng": "",
                    "delta_m": "",
                    "score": "",
                    "status": "ZERO_RESULTS",
                }
            )
            continue

        # Choose best candidate by name similarity.
        best = None
        best_score = -1.0
        for cand in results[:5]:
            cand_name = str(cand.get("name") or "")
            sc = score_match(s.name, cand_name)
            if sc > best_score:
                best_score = sc
                best = cand

        if best is None or best_score < args.min_score:
            counts["rejected_low_score"] += 1
            rows.append(
                {
                    "key": s.key,
                    "name": s.name,
                    "query": q,
                    "stored_lat": s.lat,
                    "stored_lng": s.lng,
                    "google_name": str((best or {}).get("name") or ""),
                    "google_lat": "",
                    "google_lng": "",
                    "delta_m": "",
                    "score": round(best_score, 3) if best is not None else "",
                    "status": "REJECTED_LOW_SCORE",
                }
            )
            continue

        geom = (best.get("geometry") or {}).get("location") or {}
        glat = geom.get("lat")
        glng = geom.get("lng")
        if glat is None or glng is None:
            rows.append(
                {
                    "key": s.key,
                    "name": s.name,
                    "query": q,
                    "stored_lat": s.lat,
                    "stored_lng": s.lng,
                    "google_name": str(best.get("name") or ""),
                    "google_lat": "",
                    "google_lng": "",
                    "delta_m": "",
                    "score": round(best_score, 3),
                    "status": "NO_GEOMETRY",
                }
            )
            continue

        delta_m = haversine_m(s.lat, s.lng, float(glat), float(glng))
        for t in thresholds:
            if delta_m > t:
                counts[f">{int(t)}m"] += 1

        rows.append(
            {
                "key": s.key,
                "name": s.name,
                "query": q,
                "stored_lat": s.lat,
                "stored_lng": s.lng,
                "google_name": str(best.get("name") or ""),
                "google_lat": float(glat),
                "google_lng": float(glng),
                "delta_m": round(delta_m, 3),
                "score": round(best_score, 3),
                "status": "OK",
            }
        )

    os.makedirs(args.out_dir, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d_%H%M%S")
    base = f"google_stop_audit_{stamp}"
    out_json = os.path.join(args.out_dir, base + ".summary.json")
    out_csv = os.path.join(args.out_dir, base + ".deltas.csv")

    summary = {
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "source": args.source,
        "total": counts["total"],
        "counts": counts,
        "thresholds_m": thresholds,
        "min_score": args.min_score,
        "notes": [
            "Google Places Text Search is name-based; ambiguous results are possible.",
            "This script does not store the API key; it reads it from WAKEPOINT_GOOGLE_MAPS_API_KEY.",
        ],
    }

    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2, sort_keys=True)

    with open(out_csv, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(
            f,
            fieldnames=[
                "key",
                "name",
                "query",
                "stored_lat",
                "stored_lng",
                "google_name",
                "google_lat",
                "google_lng",
                "delta_m",
                "score",
                "status",
            ],
        )
        w.writeheader()
        for r in rows:
            w.writerow(r)

    print(f"Wrote summary: {out_json}")
    print(f"Wrote deltas : {out_csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
