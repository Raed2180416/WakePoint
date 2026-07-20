#!/usr/bin/env python3
"""
GW-0181 measurement: distribution of ALONG-TRACK GPS position error vs REPORTED
accuracy on GeoWake's real recorded metro ride corpus.

Never-late precondition (i):  sHi = fixArc + reportedAccuracy  must be >= trueArc.
  => never-late requires  reportedAccuracy >= (trueArc - fixArc)  measured IN THE
     DIRECTION OF TRAVEL (positive = fix is BEHIND true = the dangerous case).
  => VIOLATION when a gate-passing fix (hacc<=100m) has along_track_backward_error > hacc.

Two independent computations:
  METHOD A  (gold): fixtures/ -- full raw GPS CSV, OUR OWN haversine snapping onto
            the ride's oriented_polyline; trueArc from station (arrival_t_s, s_travel).
  METHOD B  (breadth): ground_truth/gt_*.json -- pipeline-snapped arc_m for each
            fix (OSM line polyline) + station_anchors arc_m for trueArc. Decimated <=600.

Travel direction is derived per-ride (arc may DECREASE with travel on the full line).
"""
import json, math, glob, os, statistics as st

FIX = "/home/raed/geowake_imu_analysis/fixtures"
GT  = "/home/raed/geowake_imu_analysis/ground_truth"
GATE = 100.0  # FireDecisionConfig.defaultAccuracyGateMeters; fix accepted iff hacc<=GATE & finite

R = 6371000.0
def hav(a, b):
    la1, lo1, la2, lo2 = map(math.radians, [a[0], a[1], b[0], b[1]])
    d = math.sin((la2-la1)/2)**2 + math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2
    return 2*R*math.asin(min(1.0, math.sqrt(d)))

def arclengths(poly):
    cum = [0.0]
    for i in range(1, len(poly)):
        cum.append(cum[-1] + hav(poly[i-1], poly[i]))
    return cum

def project_point(poly, cum, pt):
    """(arc_m, perp_m) of pt projected onto polyline. Local equirectangular per seg."""
    best = (None, 1e18)
    for i in range(len(poly)-1):
        a, b = poly[i], poly[i+1]
        latref = math.radians(a[0])
        bx = (b[1]-a[1])*math.cos(latref)*111320.0
        by = (b[0]-a[0])*111320.0
        px = (pt[1]-a[1])*math.cos(latref)*111320.0
        py = (pt[0]-a[0])*111320.0
        seglen2 = bx*bx + by*by
        t = 0.0 if seglen2 == 0 else max(0.0, min(1.0, (px*bx+py*by)/seglen2))
        projx, projy = t*bx, t*by
        perp = math.hypot(px-projx, py-projy)
        if perp < best[1]:
            arc = cum[i] + t*math.sqrt(seglen2)
            best = (arc, perp)
    return best

def interp_true(anchors_t, anchors_arc, t):
    """Piecewise-linear trueArc(t); clamp outside anchor range (train dwelling at end stations)."""
    if t <= anchors_t[0]:
        return anchors_arc[0]
    if t >= anchors_t[-1]:
        return anchors_arc[-1]
    for i in range(len(anchors_t)-1):
        if anchors_t[i] <= t <= anchors_t[i+1]:
            f = (t-anchors_t[i])/(anchors_t[i+1]-anchors_t[i])
            return anchors_arc[i] + f*(anchors_arc[i+1]-anchors_arc[i])
    return anchors_arc[-1]

def pctl(xs, p):
    if not xs: return float('nan')
    xs = sorted(xs); k = (len(xs)-1)*p
    lo = int(math.floor(k)); hi = int(math.ceil(k))
    if lo == hi: return xs[lo]
    return xs[lo] + (xs[hi]-xs[lo])*(k-lo)

def summarize(name, xs):
    if not xs:
        print(f"  {name}: (none)"); return
    print(f"  {name}: n={len(xs)} median={st.median(xs):.1f} p90={pctl(xs,.9):.1f} "
          f"p95={pctl(xs,.95):.1f} p99={pctl(xs,.99):.1f} max={max(xs):.1f} min={min(xs):.1f}")

# --------------------------------------------------------------------------
# Build per-fix records for a ride.
# record = dict(t, fixArc, hacc, perp, trueArc, along_bwd, gate, blind, ttns, cold)
# along_bwd (backward, +=fix behind true in travel dir) = dir*(trueArc - fixArc)
# --------------------------------------------------------------------------
def records(fixes, anchors_t, anchors_arc, blind=None):
    direction = 1.0 if anchors_arc[-1] >= anchors_arc[0] else -1.0
    t0 = anchors_t[0]
    recs = []
    for (t, fixArc, hacc, perp) in fixes:
        trueArc = interp_true(anchors_t, anchors_arc, t)
        along_bwd = direction*(trueArc - fixArc)  # + = fix behind true = dangerous
        # nearest station anchor time distance
        ttns = min(abs(t-at) for at in anchors_t)
        inblind = False
        if blind:
            inblind = any(w[0] <= t <= w[1] for w in blind)
        gate = (hacc is not None) and math.isfinite(hacc) and hacc <= GATE
        recs.append(dict(t=t, fixArc=fixArc, hacc=hacc, perp=perp, trueArc=trueArc,
                         along_bwd=along_bwd, gate=gate, blind=inblind,
                         ttns=ttns, cold=(t - t0) <= 60.0, direction=direction))
    return recs

# ============================ METHOD A (fixtures) =========================
def load_method_A():
    out = {}
    for base in ["fixture_Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32",
                 "fixture_Nallur_to_Vijaynagar"]:
        d = json.load(open(f"{FIX}/{base}.json"))
        poly = [(p[0], p[1]) for p in d["oriented_polyline"]]
        cum = arclengths(poly)
        stns = d["stations"]
        anchors_t = [s["arrival_t_s"] for s in stns]
        anchors_arc = [s["s_travel"] for s in stns]
        # ensure sorted by t
        z = sorted(zip(anchors_t, anchors_arc))
        anchors_t = [a for a,_ in z]; anchors_arc = [b for _,b in z]
        blind = d.get("gps_blind_windows_s", [])
        fixes = []
        with open(f"{FIX}/{d['gps_csv']}") as fh:
            hdr = fh.readline()
            for line in fh:
                parts = line.strip().split(",")
                if len(parts) < 4: continue
                t = float(parts[0]); lat = float(parts[1]); lng = float(parts[2])
                hacc = float(parts[3]) if parts[3] != "" else None
                arc, perp = project_point(poly, cum, (lat, lng))
                fixes.append((t, arc, hacc, perp))
        out[d["ride"]] = records(fixes, anchors_t, anchors_arc, blind)
    return out

# ============================ METHOD B (gt) ===============================
def load_method_B():
    out = {}
    for f in sorted(glob.glob(f"{GT}/gt_*.json")):
        d = json.load(open(f))
        if d.get("gps_coverage") != "present":
            continue
        series = d["gps_arclength_series"]
        sa = d["station_anchors"]
        if not series or not sa:
            continue
        z = sorted((a["t_s"], a["arc_m"]) for a in sa)
        anchors_t = [a for a,_ in z]; anchors_arc = [b for _,b in z]
        fixes = [(g["t_s"], g["arc_m"], g.get("hacc"), g.get("perp_m")) for g in series]
        out[d["ride"]] = records(fixes, anchors_t, anchors_arc, None)
    return out

# ============================ REPORT ======================================
def report(method, data):
    print("\n" + "="*78)
    print(f"METHOD {method}")
    print("="*78)
    all_recs = [r for rs in data.values() for r in rs]
    for ride, rs in data.items():
        direction = rs[0]['direction'] if rs else 0
        print(f"\n--- {ride}  (travel dir on arc: {'+' if direction>0 else '-'}, n_fix={len(rs)})")
        gate = [r for r in rs if r['gate']]
        print(f"    gate-passing (hacc<=100): {len(gate)}/{len(rs)}")
        summarize("along_bwd ALL", [r['along_bwd'] for r in rs])
        summarize("hacc  ALL", [r['hacc'] for r in rs if r['hacc'] is not None])
    print("\n----- POOLED -----")
    gate = [r for r in all_recs if r['gate']]
    fwd = [r['along_bwd'] for r in all_recs if r['along_bwd'] < 0]   # forward (safe dir)
    bwd = [r['along_bwd'] for r in all_recs if r['along_bwd'] > 0]   # backward (dangerous)
    print(f"  total fixes={len(all_recs)}  gate-passing={len(gate)}  "
          f"({100*len(gate)/len(all_recs):.1f}%)")
    summarize("along_bwd  BACKWARD (>0, dangerous)", bwd)
    summarize("along_bwd  FORWARD  magnitude", [-x for x in fwd])
    summarize("reported hacc  ALL fixes", [r['hacc'] for r in all_recs if r['hacc'] is not None])
    summarize("reported hacc  GATE-PASSING", [r['hacc'] for r in gate])

    # CRITICAL: precondition-(i) violations among gate-passing fixes
    print("\n  *** NEVER-LATE PRECONDITION (i) VIOLATIONS (gate-passing only) ***")
    for perp_cap, label in [(1e18, "ALL gate-passing"), (200.0, "on-route perp<=200m"),
                            (50.0, "tight on-route perp<=50m")]:
        pool = [r for r in gate if (r['perp'] is None or r['perp'] <= perp_cap)]
        viol = [r for r in pool if r['along_bwd'] > (r['hacc'] if r['hacc'] else 0)]
        margins = [r['along_bwd'] - r['hacc'] for r in viol]
        frac = (len(viol)/len(pool)) if pool else float('nan')
        wm = max(margins) if margins else float('nan')
        print(f"    [{label}] pool={len(pool)}  violations={len(viol)}  "
              f"fraction={frac:.4f} ({100*frac:.2f}%)  worst(bwd-hacc)margin={wm:.1f} m")
    # clustering of the ALL-gate-passing violations
    pool = gate
    viol = [r for r in pool if r['along_bwd'] > (r['hacc'] if r['hacc'] else 0)]
    if viol:
        print("\n  Violation clustering (ALL gate-passing violations):")
        print(f"    n_viol={len(viol)}")
        print(f"    in blind window:        {sum(1 for r in viol if r['blind'])}")
        print(f"    cold start (<=60s):     {sum(1 for r in viol if r['cold'])}")
        print(f"    off-route perp>200m:    {sum(1 for r in viol if r['perp'] and r['perp']>200)}")
        print(f"    off-route perp>50m:     {sum(1 for r in viol if r['perp'] and r['perp']>50)}")
        print(f"    near station (<=30s):   {sum(1 for r in viol if r['ttns']<=30)}")
        print(f"    ttns  median={st.median([r['ttns'] for r in viol]):.0f}s "
              f"max={max(r['ttns'] for r in viol):.0f}s")
        print(f"    perp  median={st.median([r['perp'] for r in viol if r['perp'] is not None]):.0f}m "
              f"max={max((r['perp'] for r in viol if r['perp'] is not None), default=0):.0f}m")
        print(f"    hacc  median={st.median([r['hacc'] for r in viol]):.0f}m")
        print(f"    along_bwd median={st.median([r['along_bwd'] for r in viol]):.0f}m "
              f"max={max(r['along_bwd'] for r in viol):.0f}m")
    return all_recs

A = load_method_A()
B = load_method_B()
recsA = report("A (fixtures, own snapping, full raw GPS)", A)
recsB = report("B (gt pipeline arc, 4 rides, decimated)", B)

# Cross-validation on overlapping rides
print("\n" + "="*78)
print("CROSS-VALIDATION A vs B on overlapping rides (pooled gate-passing along_bwd)")
print("="*78)
for key_a, key_b in [("Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32",
                      "Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32"),
                     ("Nallur_to_Vijaynagar","Nallur_to_Vijaynagar")]:
    ra = A.get(key_a); rb = B.get(key_b)
    if ra and rb:
        ba = [r['along_bwd'] for r in ra if r['gate']]
        bb = [r['along_bwd'] for r in rb if r['gate']]
        print(f"  {key_a[:40]}:")
        print(f"    A along_bwd median={st.median(ba):.1f} p95={pctl(ba,.95):.1f}")
        print(f"    B along_bwd median={st.median(bb):.1f} p95={pctl(bb,.95):.1f}")
