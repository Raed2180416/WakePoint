import argparse
import csv
import json
import os
import sys
from typing import Optional
import urllib.request
import zipfile


def _read_stops_from_gtfs_dir(gtfs_dir: str):
    stops_path = os.path.join(gtfs_dir, "stops.txt")
    if not os.path.exists(stops_path):
        raise FileNotFoundError(f"stops.txt not found in {gtfs_dir}")

    stops = []
    with open(stops_path, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            stop_id = (row.get("stop_id") or "").strip()
            stop_name = (row.get("stop_name") or "").strip()
            lat = (row.get("stop_lat") or "").strip()
            lon = (row.get("stop_lon") or "").strip()
            location_type = (row.get("location_type") or "").strip()

            if not stop_id or not stop_name or not lat or not lon:
                continue

            # GTFS: location_type=0 (or empty) = stop/platform; 1 = station.
            # Many feeds put station centroids in type=1; for metro, we generally want stations.
            # So we KEEP both 0 and 1, and let the app dedupe/snap.
            if location_type not in ("", "0", "1"):
                continue

            try:
                stop_lat = float(lat)
                stop_lon = float(lon)
            except ValueError:
                continue

            stops.append(
                {
                    "id": stop_id,
                    "name": stop_name,
                    "lat": stop_lat,
                    "lng": stop_lon,
                }
            )

    return stops


def _extract_zip_to_temp(zip_path: str):
    import tempfile

    tmp = tempfile.mkdtemp(prefix="gtfs_")
    with zipfile.ZipFile(zip_path, "r") as z:
        z.extractall(tmp)
    return tmp


def _download_to_temp(url: str):
    import tempfile

    fd, tmp_path = tempfile.mkstemp(prefix="gtfs_", suffix=".zip")
    os.close(fd)
    try:
        with urllib.request.urlopen(url) as resp, open(tmp_path, "wb") as out:
            out.write(resp.read())
    except Exception:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise
    return tmp_path


def _load_manifest(path: str):
    if not os.path.exists(path):
        return {"schemaVersion": 1, "generatedAt": "", "packs": []}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _upsert_manifest_pack(
    manifest: dict,
    *,
    city_id: str,
    stops_path: str,
    stops_count: int,
    source_name: Optional[str],
    source_url: Optional[str],
    license_name: Optional[str],
    license_url: Optional[str],
    retrieved_at: Optional[str],
):
    packs = manifest.get("packs")
    if not isinstance(packs, list):
        packs = []
        manifest["packs"] = packs

    existing = None
    for p in packs:
        if isinstance(p, dict) and p.get("cityId") == city_id:
            existing = p
            break

    if existing is None:
        existing = {"cityId": city_id}
        packs.append(existing)

    existing["stopsPath"] = stops_path
    existing["stopsCount"] = int(stops_count)
    existing["source"] = {
        "name": source_name or "",
        "url": source_url or "",
        "license": license_name or "",
        "licenseUrl": license_url or "",
        "retrievedAt": retrieved_at or "",
    }



def main():
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--gtfs-zip", help="Path to a GTFS zip")
    src.add_argument("--gtfs-dir", help="Path to an extracted GTFS folder")
    src.add_argument("--gtfs-url", help="URL to a GTFS zip")
    ap.add_argument("--city-id", required=True, help="City id (e.g. bengaluru)")
    ap.add_argument("--out-dir", required=True, help="Output directory")
    ap.add_argument(
        "--manifest-path",
        help="Optional path to docs/gtfs_data/manifest.json to update",
    )
    ap.add_argument("--source-name", help="Feed source name")
    ap.add_argument("--source-url", help="Feed source URL")
    ap.add_argument("--license", help="License name")
    ap.add_argument("--license-url", help="License URL")
    ap.add_argument(
        "--retrieved-at",
        help="ISO timestamp for when the GTFS was retrieved (optional)",
    )

    args = ap.parse_args()

    gtfs_dir = args.gtfs_dir
    if args.gtfs_url:
        zip_path = _download_to_temp(args.gtfs_url)
        gtfs_dir = _extract_zip_to_temp(zip_path)
    elif args.gtfs_zip:
        if not os.path.exists(args.gtfs_zip):
            print(f"GTFS zip not found: {args.gtfs_zip}", file=sys.stderr)
            return 2
        gtfs_dir = _extract_zip_to_temp(args.gtfs_zip)

    stops = _read_stops_from_gtfs_dir(gtfs_dir)
    os.makedirs(args.out_dir, exist_ok=True)

    out_path = os.path.join(args.out_dir, "stops.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"stops": stops}, f, ensure_ascii=False)

    print(f"Wrote {len(stops)} stops -> {out_path}")

    if args.manifest_path:
        manifest = _load_manifest(args.manifest_path)
        # Write a repo-relative path (suitable for GitHub Pages URLs).
        stops_rel = os.path.relpath(out_path, os.path.dirname(args.manifest_path))
        stops_rel = stops_rel.replace("\\", "/")
        _upsert_manifest_pack(
            manifest,
            city_id=args.city_id,
            stops_path=stops_rel,
            stops_count=len(stops),
            source_name=args.source_name,
            source_url=args.source_url,
            license_name=args.license,
            license_url=args.license_url,
            retrieved_at=args.retrieved_at,
        )
        # Only set generatedAt if caller didn't provide; keep manual control.
        manifest.setdefault("generatedAt", "")
        with open(args.manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
        print(f"Updated manifest -> {args.manifest_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
