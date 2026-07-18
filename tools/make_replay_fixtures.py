#!/usr/bin/env python3
"""Build a COMPACT, COMMITTED replay-fixture set for the never-late CI gate.

The full-rate ride fixtures live outside the repo
(``/home/raed/geowake_imu_analysis/fixtures``) and their IMU CSVs are 1.6-19 MB
each — too large to commit and unnecessary for a deterministic never-late gate.

This tool copies a curated subset into ``test/fixtures/replay/`` with the IMU
stream *decimated* to at most ``MAX_IMU_ROWS`` rows (keeping dt honest by
striding uniformly), while the GPS trace and the JSON header (polyline,
stations, alarm target, blind windows) are copied verbatim so ground truth is
unchanged. The reachability never-late guarantee is wall-clock based and does
not depend on IMU density, so decimation is safe for the gate; it only makes the
EKF's dead-reckoning slightly coarser (which the reachability net covers).

Deterministic: given the same inputs it always produces byte-identical outputs.

Run:  python3 tools/make_replay_fixtures.py
"""
from __future__ import annotations

import os
import sys

SRC_DIR = "/home/raed/geowake_imu_analysis/fixtures"
DST_DIR = os.path.join(os.path.dirname(__file__), "..", "test", "fixtures", "replay")

# Curated subset: broad never-late coverage at a committable size.
#   allunderground_20min — the flagship "GPS dead the whole ride" underground case
#   express_skip         — express service that skips stations (stop-count edge)
#   short_2stop          — a short 2-stop leg (small, fast gate)
#   short_1stop          — minimal leg (loader edge)
# NOTE: fixture_short_1stop is intentionally excluded — a single-station leg is
# degenerate for a "N stops before destination" alarm (no first+last pair) and
# the gate cannot meaningfully score it.
FIXTURES = [
    "fixture_allunderground_20min",
    "fixture_express_skip",
    "fixture_short_2stop",
]

# Cap the committed IMU size. 20k rows @ ~35 bytes ≈ 700 KB worst case.
MAX_IMU_ROWS = 20000


def decimate_imu(src: str, dst: str) -> tuple[int, int]:
    with open(src, "r") as f:
        lines = f.read().splitlines()
    if not lines:
        raise SystemExit(f"empty IMU file: {src}")
    header, body = lines[0], [ln for ln in lines[1:] if ln]
    n = len(body)
    stride = max(1, (n + MAX_IMU_ROWS - 1) // MAX_IMU_ROWS)
    kept = body[::stride]
    # Always keep the last row so the ride's end time is preserved.
    if kept and kept[-1] != body[-1]:
        kept.append(body[-1])
    with open(dst, "w") as f:
        f.write(header + "\n")
        f.write("\n".join(kept) + "\n")
    return n, len(kept)


def copy_verbatim(src: str, dst: str) -> None:
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        fo.write(fi.read())


def main() -> int:
    os.makedirs(DST_DIR, exist_ok=True)
    total_bytes = 0
    manifest = []
    for base in FIXTURES:
        sj = os.path.join(SRC_DIR, f"{base}.json")
        si = os.path.join(SRC_DIR, f"{base}_imu.csv")
        sg = os.path.join(SRC_DIR, f"{base}_gps.csv")
        if not (os.path.exists(sj) and os.path.exists(si) and os.path.exists(sg)):
            print(f"SKIP {base}: incomplete triple in {SRC_DIR}", file=sys.stderr)
            continue
        dj = os.path.join(DST_DIR, f"{base}.json")
        di = os.path.join(DST_DIR, f"{base}_imu.csv")
        dg = os.path.join(DST_DIR, f"{base}_gps.csv")
        copy_verbatim(sj, dj)
        copy_verbatim(sg, dg)
        n_in, n_out = decimate_imu(si, di)
        for p in (dj, di, dg):
            total_bytes += os.path.getsize(p)
        manifest.append((base, n_in, n_out))
        print(f"OK {base}: imu {n_in} -> {n_out} rows")
    print(f"\nCommitted {len(manifest)} fixtures -> {DST_DIR}")
    print(f"Total size: {total_bytes/1024:.0f} KiB")
    if not manifest:
        print("ERROR: no fixtures produced — external source dir missing?", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
