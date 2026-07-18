#!/usr/bin/env python3
"""Deterministic integrity audit of the shipped India metro dataset.

Validates assets/india_metro/metro_dataset.json against hard invariants the
reachability topology + "N stops away" UX depend on. Exit code != 0 on any
hard failure so it can gate CI. Report-only warnings (e.g. suspicious hops on
flagged lines) are printed but do not fail the build.
"""
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATASET = ROOT / "assets/india_metro/metro_dataset.json"

# India bounding box (generous), for coordinate sanity.
LAT_MIN, LAT_MAX = 6.0, 37.5
LNG_MIN, LNG_MAX = 68.0, 98.0

# A metro inter-station hop this large almost certainly means broken ordering
# (NN reconstruction jumping across the network). Report-only signal.
SUSPICIOUS_HOP_M = 6000.0
# Two "distinct" stations closer than this are likely duplicates.
DUP_STATION_M = 40.0

# The 9 flagged lines the handoff says have untrustworthy NN-reconstructed order.
EXPECTED_FLAGGED = {
    ("delhi", "blue"), ("delhi", "magenta"), ("delhi", "orange"), ("delhi", "pink"),
    ("bengaluru", ""), ("bengaluru", "green"),
    ("ahmedabad", "yellow"),
    ("mumbai", "red"),
    ("nagpur", "orange"),
}


def haversine_m(a, b):
    lat1, lng1 = a
    lat2, lng2 = b
    R = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(x)))


def main():
    errors = []          # hard failures (exit 1)
    warnings = []        # report-only
    stats = {"cities": 0, "lines": 0, "stations": 0, "confident_lines": 0, "flagged_lines": 0}

    d = json.loads(DATASET.read_text())
    assert d.get("schema") == "wakepoint.metro.v1", f"unexpected schema {d.get('schema')}"
    cities = d["cities"]

    flagged_seen = set()

    for city_key, city in sorted(cities.items()):
        stats["cities"] += 1
        confident = set(city.get("ordered_lines_confident", []))
        flagged = set(city.get("ordered_lines_flagged", []))
        stats["confident_lines"] += len(confident)
        stats["flagged_lines"] += len(flagged)
        for lk in flagged:
            flagged_seen.add((city_key, lk))

        lines = city.get("lines", {})
        for line_key, line in sorted(lines.items()):
            stats["lines"] += 1
            stops = line.get("stops", [])
            is_flagged = line_key in flagged
            tag = f"{city_key}/{line_key or '(unnamed)'}"

            # 1) Non-empty line.
            if len(stops) < 2:
                errors.append(f"{tag}: only {len(stops)} stop(s) — a line needs >=2")
                continue

            # 2) seq contiguity 0..n-1, unique.
            seqs = [s.get("seq") for s in stops]
            if sorted(seqs) != list(range(len(stops))):
                errors.append(f"{tag}: seq not contiguous 0..{len(stops)-1}: {seqs}")

            # 3) coordinate sanity + names.
            coords = []
            names = []
            for s in stops:
                stats["stations"] += 1
                lat, lng = s.get("lat"), s.get("lng")
                nm = (s.get("name") or "").strip()
                if not nm:
                    errors.append(f"{tag}: stop seq={s.get('seq')} has empty name")
                names.append(nm)
                if lat is None or lng is None:
                    errors.append(f"{tag}: {nm} missing coords")
                    continue
                if not (LAT_MIN <= lat <= LAT_MAX and LNG_MIN <= lng <= LNG_MAX):
                    errors.append(f"{tag}: {nm} coords out of India bbox ({lat},{lng})")
                coords.append((lat, lng))

            # 4) duplicate station names within a line.
            if len(set(names)) != len(names):
                dupes = sorted({n for n in names if names.count(n) > 1})
                errors.append(f"{tag}: duplicate station names within line: {dupes}")

            # 5) ordered by seq; inspect inter-station hops.
            ordered = [c for _, c in sorted(zip(seqs, coords))] if len(coords) == len(stops) else coords
            hops = [haversine_m(ordered[i], ordered[i + 1]) for i in range(len(ordered) - 1)]
            if hops:
                mx = max(hops)
                # near-zero hop => likely duplicate points
                zero_hops = [i for i, h in enumerate(hops) if h < DUP_STATION_M]
                for i in zero_hops:
                    warnings.append(f"{tag}: hop {i}->{i+1} is {hops[i]:.0f}m (<{DUP_STATION_M:.0f}m, likely dup)")
                if mx > SUSPICIOUS_HOP_M:
                    lvl = "warn" if is_flagged else "WARN(confident!)"
                    warnings.append(f"{tag}: max hop {mx:.0f}m > {SUSPICIOUS_HOP_M:.0f}m [{lvl}] "
                                    f"(flagged={is_flagged})")

            # 6) monotonic maxHopM sanity vs recomputed.
            recomputed_max = max(hops) if hops else 0.0
            declared = line.get("maxHopM", None)
            if declared is not None and declared > 0 and recomputed_max > 0:
                if abs(declared - recomputed_max) > max(200.0, 0.25 * recomputed_max):
                    warnings.append(f"{tag}: declared maxHopM={declared:.0f} vs recomputed {recomputed_max:.0f}")

            # 7) confident/flagged flag consistency.
            declared_conf = line.get("confident", None)
            if declared_conf is True and is_flagged:
                errors.append(f"{tag}: marked confident=True but is in flagged list")
            if declared_conf is False and line_key in confident:
                errors.append(f"{tag}: marked confident=False but is in confident list")

    # 8) The handoff's 9 flagged lines should all be present in the data.
    missing_flagged = EXPECTED_FLAGGED - flagged_seen
    extra_flagged = flagged_seen - EXPECTED_FLAGGED
    if missing_flagged:
        warnings.append(f"handoff flagged lines NOT flagged in data: {sorted(missing_flagged)}")
    if extra_flagged:
        warnings.append(f"data flags lines not in handoff's 9: {sorted(extra_flagged)}")

    print("=" * 70)
    print("INDIA METRO DATASET — INTEGRITY AUDIT")
    print("=" * 70)
    for k, v in stats.items():
        print(f"  {k:20s}: {v}")
    print(f"  flagged lines seen  : {sorted(flagged_seen)}")
    print("-" * 70)
    print(f"WARNINGS ({len(warnings)}):")
    for w in warnings:
        print(f"  ⚠ {w}")
    print("-" * 70)
    print(f"HARD ERRORS ({len(errors)}):")
    for e in errors:
        print(f"  ✗ {e}")
    print("=" * 70)
    if errors:
        print(f"RESULT: FAIL ({len(errors)} hard errors)")
        return 1
    print(f"RESULT: PASS (0 hard errors, {len(warnings)} report-only warnings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
