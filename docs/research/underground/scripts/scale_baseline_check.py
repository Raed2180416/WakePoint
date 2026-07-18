#!/usr/bin/env python3
"""Independent baseline: does the CURRENT free-run reachability cone fire
never-late across all 391 generated routes, and how early? (No stop-anchoring —
this is the baseline the gated anchoring must beat.)"""
import json, os
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
RIDES = os.path.join(HERE, "rides")

def true_s(t, ts, ss):
    return float(np.interp(t, ts, ss, left=ss[0], right=ss[-1]))

def sim_ride(d, N=2):
    st = d["stations"]
    ss = np.array([s["s_travel"] for s in st], float)
    ts = np.array([s["arrival_t_s"] for s in st], float)
    order = np.argsort(ts); ss, ts = ss[order], ts[order]
    V = float(d["vline_ceiling_mps"])
    bw = [tuple(w) for w in d.get("gps_blind_windows_s", [])]
    if len(ss) < 2:
        return None
    dest_s = ss[-1]; dest_t = ts[-1]
    # fire target: N stops before destination
    idx = max(0, len(ss) - 1 - N)
    s_target = ss[idx]
    def in_blind(t):
        return any(w0 <= t <= w1 for (w0, w1) in bw)
    # march time; anchor the cone to the true position whenever GPS is live
    dt = 1.0
    t = 0.0
    anchor_s = ss[0]; anchor_t = 0.0
    fire_t = None
    T_end = dest_t + 60
    while t <= T_end:
        if not in_blind(t):
            # GPS live: re-anchor to true position (overbounded forward by hacc ~ 10m)
            anchor_s = true_s(t, ts, ss) + 10.0
            anchor_t = t
        s_max = anchor_s + V * (t - anchor_t)
        if fire_t is None and s_max >= s_target:
            fire_t = t
            break
        t += dt
    if fire_t is None:
        return {"fired": False}
    # true arrival at the target station (temporal never-late = fire <= dest arrival)
    early_s = dest_t - fire_t   # seconds before destination arrival
    # spatial: true position at fire time
    s_at_fire = true_s(fire_t, ts, ss)
    early_m = s_target - s_at_fire  # meters before the target stop (>=0 = early/ok)
    late = fire_t > dest_t + 0.5
    return {"fired": True, "fire_t": fire_t, "dest_t": dest_t, "early_s": early_s,
            "early_m": early_m, "late": late, "scenario": d["scenario"],
            "vline": V, "longest_blind": d.get("gps_blind_total_s", 0)}

results = []
for rid in sorted(os.listdir(RIDES)):
    p = os.path.join(RIDES, rid, "base.json")
    if not os.path.exists(p): continue
    try:
        d = json.load(open(p))
        r = sim_ride(d)
        if r: r["ride"] = rid; results.append(r)
    except Exception as e:
        print("ERR", rid, e)

fired = [r for r in results if r.get("fired")]
late = [r for r in fired if r["late"]]
neverfired = [r for r in results if not r.get("fired")]
early_s = np.array([r["early_s"] for r in fired])
early_m = np.array([r["early_m"] for r in fired])
print(f"rides simulated: {len(results)}")
print(f"fired: {len(fired)}   never-fired: {len(neverfired)}   LATE fires: {len(late)}")
print(f"early-firing (seconds before dest arrival): median {np.median(early_s):.0f}s  p90 {np.percentile(early_s,90):.0f}s  max {early_s.max():.0f}s")
print(f"early-firing (meters before target stop):  median {np.median(early_m):.0f}m  p90 {np.percentile(early_m,90):.0f}m  max {early_m.max():.0f}m")
if late:
    print("\nLATE FIRES (never-late VIOLATIONS):")
    for r in late[:10]:
        print(f"  {r['ride']}: fire@{r['fire_t']:.0f}s vs dest@{r['dest_t']:.0f}s ({-r['early_s']:.0f}s LATE)")
# breakdown by scenario
import collections
byss = collections.defaultdict(list)
for r in fired: byss[r["scenario"]].append(r["early_s"])
print("\nearly-firing (median seconds) by scenario:")
for s in sorted(byss): print(f"  {s:28} n={len(byss[s]):3}  median {np.median(byss[s]):5.0f}s  max {np.max(byss[s]):5.0f}s")
if neverfired:
    print(f"\nNEVER-FIRED rides ({len(neverfired)}):", [r['ride'] for r in neverfired][:8])
