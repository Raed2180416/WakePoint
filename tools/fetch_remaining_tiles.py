#!/usr/bin/env python3
"""Fetch remaining Bengaluru tiles one by one with delays to avoid rate limiting."""

import json
import sys
import time
import ssl
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CACHE_DIR = Path(__file__).parent / "osm_data"
TILES = 5  # 5x5 = 25 tiles

# Bengaluru bbox
MIN_LAT, MIN_LON, MAX_LAT, MAX_LON = 12.85, 77.45, 13.10, 77.75

ENDPOINTS = [
    "http://overpass-api.de/api/interpreter",  # HTTP to avoid SSL issues
    "http://overpass.kumi.systems/api/interpreter",
    "http://overpass.nchc.org.tw/api/interpreter",
]

HIGHWAY_REGEX = "motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|residential|living_street|unclassified"


def tile_bboxes():
    lat_step = (MAX_LAT - MIN_LAT) / TILES
    lon_step = (MAX_LON - MIN_LON) / TILES
    out = []
    for r in range(TILES):
        for c in range(TILES):
            a = MIN_LAT + r * lat_step
            b = MIN_LON + c * lon_step
            c_lat = MIN_LAT + (r + 1) * lat_step
            c_lon = MIN_LON + (c + 1) * lon_step
            out.append((a, b, c_lat, c_lon))
    return out


def cache_path(tile_idx: int) -> Path:
    return CACHE_DIR / f"bengaluru_overpass_tile{tile_idx:02d}.json"


def build_query(bbox):
    min_lat, min_lon, max_lat, max_lon = bbox
    bbox_str = f"{min_lat},{min_lon},{max_lat},{max_lon}"
    return (
        "[out:json][timeout:300];"
        f'(way["highway"~"{HIGHWAY_REGEX}"]({bbox_str}););'
        "out body;"
        ">;"
        "out skel qt;"
    )


def fetch(endpoint: str, query: str, timeout: int = 300) -> dict:
    encoded = urllib.parse.urlencode({"data": query}).encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=encoded,
        headers={
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
            "User-Agent": "WakePoint-Overpass/1.0",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_with_retry(query: str, max_attempts: int = 5) -> dict:
    for attempt in range(1, max_attempts + 1):
        for ep in ENDPOINTS:
            try:
                print(f"    Trying {ep}...", flush=True)
                data = fetch(ep, query)
                return data
            except urllib.error.HTTPError as e:
                if e.code in (429, 504, 503):
                    wait = 60 * attempt
                    print(f"    HTTP {e.code} - waiting {wait}s before retry...", flush=True)
                    time.sleep(wait)
                else:
                    print(f"    HTTP {e.code} error", flush=True)
            except Exception as e:
                print(f"    Error: {e}", flush=True)
                time.sleep(10)
    raise RuntimeError("All attempts failed")


def main():
    tiles = tile_bboxes()
    missing = []
    
    for i in range(len(tiles)):
        if not cache_path(i).exists():
            missing.append(i)
    
    print(f"Total tiles: {len(tiles)}")
    print(f"Cached: {len(tiles) - len(missing)}")
    print(f"Missing: {len(missing)} -> {missing}")
    print()
    
    if not missing:
        print("All tiles cached!")
        return
    
    for idx, tile_idx in enumerate(missing):
        bbox = tiles[tile_idx]
        out_path = cache_path(tile_idx)
        
        print(f"[{idx+1}/{len(missing)}] Fetching tile {tile_idx} bbox={bbox}", flush=True)
        
        query = build_query(bbox)
        
        try:
            data = fetch_with_retry(query)
            out_path.write_text(json.dumps(data), encoding="utf-8")
            elem_count = len(data.get("elements", []))
            print(f"  -> Saved {out_path.name} ({elem_count} elements)", flush=True)
        except Exception as e:
            print(f"  -> FAILED: {e}", flush=True)
            continue
        
        # Wait between requests to be nice to Overpass
        if idx < len(missing) - 1:
            wait = 45
            print(f"  Waiting {wait}s before next tile...", flush=True)
            time.sleep(wait)
    
    # Check final status
    still_missing = [i for i in range(len(tiles)) if not cache_path(i).exists()]
    print()
    print(f"Done! Missing tiles: {len(still_missing)}")
    if still_missing:
        print(f"  Still need: {still_missing}")


if __name__ == "__main__":
    main()
