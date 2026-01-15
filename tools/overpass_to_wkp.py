#!/usr/bin/env python3
"""Overpass → WKP graph builder for WakePoint.

This is an alternative to processing huge regional .osm.pbf extracts.
It downloads routable road ways (highway=*) from Overpass for a bbox and
writes the same .wkp binary format used by the deviation dashboard.

Usage:
  python tools/overpass_to_wkp.py assets/osm/bengaluru.wkp --bbox=12.85,77.45,13.10,77.75

Optional:
  --cache=tools/osm_data/bengaluru_overpass.json   (reuse cached response)
  --endpoint=https://overpass-api.de/api/interpreter

Notes:
- Overpass has rate limits; large bboxes may be slow or rejected.
- Prefer the smallest bbox that covers your test routes.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import time
import ssl
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


ROAD_TYPES: Dict[str, int] = {
    "motorway": 1,
    "motorway_link": 2,
    "trunk": 3,
    "trunk_link": 4,
    "primary": 5,
    "primary_link": 6,
    "secondary": 7,
    "secondary_link": 8,
    "tertiary": 9,
    "tertiary_link": 10,
    "residential": 11,
    "living_street": 12,
    "unclassified": 13,
    "service": 14,
    "road": 15,
}


@dataclass
class Node:
    id: int
    lat: float
    lon: float


@dataclass
class Edge:
    from_id: int
    to_id: int
    distance_m: float
    road_type: int
    oneway: bool


def haversine_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    import math

    r = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)

    a = (
        math.sin(dphi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    )
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return r * c


def write_binary(output_path: Path, nodes: Dict[int, Node], edges: List[Edge]) -> Tuple[int, int]:
    node_list = list(nodes.values())
    node_id_to_idx = {n.id: i for i, n in enumerate(node_list)}

    valid_edges = [
        e for e in edges if e.from_id in node_id_to_idx and e.to_id in node_id_to_idx
    ]

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("wb") as f:
        f.write(b"WKP1")
        f.write(struct.pack("<H", 1))
        f.write(struct.pack("<I", len(node_list)))
        f.write(struct.pack("<I", len(valid_edges)))
        f.write(struct.pack("<H", 0))

        for node in node_list:
            f.write(struct.pack("<ffQ", float(node.lat), float(node.lon), int(node.id)))

        for edge in valid_edges:
            f.write(
                struct.pack(
                    "<IIfBBH",
                    node_id_to_idx[edge.from_id],
                    node_id_to_idx[edge.to_id],
                    float(edge.distance_m),
                    int(edge.road_type),
                    1 if edge.oneway else 0,
                    0,
                )
            )

    return len(node_list), len(valid_edges)


def parse_bbox(bbox_str: str) -> Tuple[float, float, float, float]:
    parts = [float(x.strip()) for x in bbox_str.split(",")]
    if len(parts) != 4:
        raise ValueError("Bounding box must have 4 values: lat1,lon1,lat2,lon2")
    # Expect minLat,minLon,maxLat,maxLon
    return parts[0], parts[1], parts[2], parts[3]


def build_overpass_query(
    bbox: Tuple[float, float, float, float],
    highway_regex: Optional[str] = None,
) -> str:
    min_lat, min_lon, max_lat, max_lon = bbox
    bbox_str = f"{min_lat},{min_lon},{max_lat},{max_lon}"

    # Grab highway ways in bbox (optionally filtered by regex); then fetch all referenced nodes.
    # out body gives way nodes list; > expands to nodes; out skel qt returns nodes quickly.
    way_filter = 'way["highway"]'
    if highway_regex:
        way_filter = f'way["highway"~"{highway_regex}"]'

    return (
        "[out:json][timeout:240];"
        f"({way_filter}({bbox_str}););"
        "out body;"
        ">;"
        "out skel qt;"
    )


def tile_bboxes(bbox: Tuple[float, float, float, float], tiles: int) -> List[Tuple[float, float, float, float]]:
    if tiles <= 1:
        return [bbox]
    min_lat, min_lon, max_lat, max_lon = bbox
    lat_step = (max_lat - min_lat) / tiles
    lon_step = (max_lon - min_lon) / tiles
    out: List[Tuple[float, float, float, float]] = []
    for r in range(tiles):
        for c in range(tiles):
            a = min_lat + r * lat_step
            b = min_lon + c * lon_step
            c_lat = min_lat + (r + 1) * lat_step
            c_lon = min_lon + (c + 1) * lon_step
            out.append((a, b, c_lat, c_lon))
    return out


def _looks_like_cert_verify_failure(err: BaseException) -> bool:
    # Windows/MSYS Python often lacks a proper CA bundle; urllib surfaces this as a URLError
    # wrapping an SSLCertVerificationError.
    if isinstance(err, ssl.SSLCertVerificationError):
        return True
    msg = str(err)
    return "CERTIFICATE_VERIFY_FAILED" in msg or "certificate verify failed" in msg


def _https_to_http(endpoint: str) -> str:
    if endpoint.startswith("https://"):
        return "http://" + endpoint[len("https://") :]
    return endpoint


def fetch_overpass_json(endpoint: str, query: str, attempts: int = 3) -> dict:
    encoded = urllib.parse.urlencode({"data": query}).encode("utf-8")

    http_fallback_tried = False

    for attempt in range(1, attempts + 1):
        try:
            req = urllib.request.Request(
                endpoint,
                data=encoded,
                headers={
                    "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                    "User-Agent": "WakePoint-Overpass/1.0 (tools/overpass_to_wkp.py)",
                },
                method="POST",
            )

            with urllib.request.urlopen(req, timeout=240) as resp:
                body = resp.read()
            return json.loads(body.decode("utf-8"))
        except urllib.error.HTTPError as e:
            # Common Overpass behavior: 429/504 etc.
            wait_s = min(30 * attempt, 90)
            print(f"HTTP error from Overpass ({e.code}). Retrying in {wait_s}s...", flush=True)
            time.sleep(wait_s)
        except urllib.error.URLError as e:
            # SSL verification issues are common on some Python builds.
            if (
                endpoint.startswith("https://")
                and not http_fallback_tried
                and _looks_like_cert_verify_failure(getattr(e, "reason", e))
            ):
                http_fallback_tried = True
                endpoint = _https_to_http(endpoint)
                print(
                    f"SSL verification failed; retrying via HTTP endpoint: {endpoint}",
                    flush=True,
                )
                continue

            wait_s = min(10 * attempt, 30)
            print(f"Error talking to Overpass ({e}). Retrying in {wait_s}s...", flush=True)
            time.sleep(wait_s)
        except Exception as e:
            wait_s = min(10 * attempt, 30)
            print(f"Error talking to Overpass ({e}). Retrying in {wait_s}s...", flush=True)
            time.sleep(wait_s)

    raise RuntimeError("Failed to fetch data from Overpass after retries")


def fetch_overpass_json_from_endpoints(endpoints: List[str], query: str) -> dict:
    last_err: Optional[BaseException] = None
    for ep in endpoints:
        try:
            return fetch_overpass_json(ep, query, attempts=3)
        except BaseException as e:
            last_err = e
            print(f"Endpoint failed: {ep} ({e})", flush=True)
            continue
    raise RuntimeError(f"All Overpass endpoints failed. Last error: {last_err}")


def merge_overpass_json(into: dict, part: dict) -> None:
    into_elements = into.setdefault("elements", [])
    seen = into.setdefault("_seen", {})
    for el in part.get("elements", []):
        key = f"{el.get('type')}:{el.get('id')}"
        if key in seen:
            continue
        seen[key] = True
        into_elements.append(el)


def overpass_to_graph(data: dict) -> Tuple[Dict[int, Node], List[Edge]]:
    elements = data.get("elements", [])

    nodes: Dict[int, Node] = {}
    ways: List[dict] = []

    for el in elements:
        t = el.get("type")
        if t == "node":
            nid = int(el["id"])
            nodes[nid] = Node(id=nid, lat=float(el["lat"]), lon=float(el["lon"]))
        elif t == "way":
            ways.append(el)

    print(f"Parsed {len(nodes):,} nodes and {len(ways):,} ways", flush=True)

    edges: List[Edge] = []
    routable = 0

    for idx, w in enumerate(ways, start=1):
        tags = w.get("tags", {})
        highway = tags.get("highway")
        if highway not in ROAD_TYPES:
            continue

        routable += 1
        if routable % 25_000 == 0:
            print(
                f"  ... routable ways {routable:,}, edges {len(edges):,}",
                flush=True,
            )

        road_type = ROAD_TYPES[highway]

        oneway_tag = tags.get("oneway", "no")
        oneway = oneway_tag in ("yes", "1", "true")
        if highway in ("motorway", "motorway_link") and oneway_tag != "no":
            oneway = True

        refs = w.get("nodes", [])
        node_ids = [int(r) for r in refs if int(r) in nodes]
        if len(node_ids) < 2:
            continue

        for i in range(len(node_ids) - 1):
            from_id, to_id = node_ids[i], node_ids[i + 1]
            a = nodes[from_id]
            b = nodes[to_id]
            d = haversine_distance(a.lat, a.lon, b.lat, b.lon)

            edges.append(
                Edge(
                    from_id=from_id,
                    to_id=to_id,
                    distance_m=d,
                    road_type=road_type,
                    oneway=oneway,
                )
            )
            if not oneway:
                edges.append(
                    Edge(
                        from_id=to_id,
                        to_id=from_id,
                        distance_m=d,
                        road_type=road_type,
                        oneway=False,
                    )
                )

    print(f"Routable ways: {routable:,}")
    print(f"Edges built: {len(edges):,}")

    return nodes, edges


def main() -> None:
    parser = argparse.ArgumentParser(description="Download OSM highways via Overpass and write .wkp")
    parser.add_argument("output", type=Path, help="Output .wkp path")
    parser.add_argument("--bbox", required=True, help="minLat,minLon,maxLat,maxLon")
    parser.add_argument(
        "--endpoint",
        action="append",
        default=None,
        help="Overpass interpreter endpoint (repeatable). If omitted, uses a small default pool.",
    )
    parser.add_argument(
        "--tiles",
        type=int,
        default=1,
        help="Split bbox into NxN tiles to avoid Overpass timeouts (e.g. 3 -> 9 requests)",
    )
    parser.add_argument(
        "--highway-regex",
        default=None,
        help=(
            "Optional regex for the 'highway' tag to reduce data size "
            "(e.g. 'motorway|trunk|primary|secondary|tertiary|residential|unclassified')"
        ),
    )
    parser.add_argument(
        "--cache",
        type=Path,
        default=None,
        help="Optional path to cache Overpass JSON response",
    )
    parser.add_argument(
        "--use-cache-only",
        action="store_true",
        help="Do not hit network; require --cache file",
    )

    args = parser.parse_args()

    bbox = parse_bbox(args.bbox)
    endpoints = args.endpoint
    if not endpoints:
        endpoints = [
            "https://overpass-api.de/api/interpreter",
            "https://overpass.kumi.systems/api/interpreter",
            "https://overpass.nchc.org.tw/api/interpreter",
        ]

    tile_list = tile_bboxes(bbox, int(args.tiles))

    merged: dict = {"elements": []}

    def cache_path_for_tile(tile_index: int) -> Optional[Path]:
        if not args.cache:
            return None
        if len(tile_list) == 1:
            return args.cache
        # For multi-tile runs, write multiple cache files derived from the base name.
        base = args.cache
        if base.suffix.lower() == ".json":
            return base.with_name(f"{base.stem}_tile{tile_index:02d}{base.suffix}")
        return Path(str(base) + f"_tile{tile_index:02d}.json")

    for i, tile_bbox in enumerate(tile_list):
        query = build_overpass_query(tile_bbox, highway_regex=args.highway_regex)
        tile_cache = cache_path_for_tile(i)
        if args.use_cache_only:
            if not tile_cache or not tile_cache.exists():
                print(f"Skipping tile {i+1}/{len(tile_list)} (no cache): {tile_cache}", flush=True)
                continue
            print(f"Loading cached Overpass data: {tile_cache}", flush=True)
            part = json.loads(tile_cache.read_text(encoding="utf-8"))
            merge_overpass_json(merged, part)
            continue

        if tile_cache and tile_cache.exists():
            print(f"Loading cached Overpass data: {tile_cache}", flush=True)
            part = json.loads(tile_cache.read_text(encoding="utf-8"))
            merge_overpass_json(merged, part)
            continue

        print("Fetching data from Overpass...", flush=True)
        print(f"  Endpoints: {', '.join(endpoints)}", flush=True)
        if len(tile_list) == 1:
            print(f"  Bbox     : {args.bbox}", flush=True)
        else:
            print(f"  Tile {i+1}/{len(tile_list)} bbox: {tile_bbox}", flush=True)

        part = fetch_overpass_json_from_endpoints(endpoints, query)
        if tile_cache:
            tile_cache.parent.mkdir(parents=True, exist_ok=True)
            tile_cache.write_text(json.dumps(part), encoding="utf-8")
            print(f"Saved cache: {tile_cache}", flush=True)
        merge_overpass_json(merged, part)

    # Clean internal merge bookkeeping
    merged.pop("_seen", None)

    data = merged

    nodes, edges = overpass_to_graph(data)

    print("Writing .wkp...", flush=True)
    node_count, edge_count = write_binary(args.output, nodes, edges)
    size = args.output.stat().st_size

    print("Done!")
    print(f"  Nodes: {node_count:,}")
    print(f"  Edges: {edge_count:,}")
    print(f"  File : {args.output} ({size/1024/1024:.2f} MB)")


if __name__ == "__main__":
    main()
