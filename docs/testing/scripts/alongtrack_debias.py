#!/usr/bin/env python3
"""
De-biasing / diagnostic pass for GW-0181 along-track error.

Concern: piecewise-linear station-anchor truth spreads DWELL + ACCEL/DECEL into a
constant-speed chord, which runs AHEAD of the real train mid-segment/during dwell,
inflating apparent BACKWARD error. We test this two ways on the 2 clean fixtures:

 (1) bin along_bwd by time-to-nearest-station-anchor (should be ~0 at anchors if the
     residual is truth-model artifact; a floor >0 at anchors = real GPS backward bias).
 (2) build a SPEED-INTEGRATED truth: integrate GPS Doppler speed to get the arc SHAPE,
     then affine-rescale each inter-anchor interval to hit the station arcs exactly.
     Position truth then comes from (Doppler speed + station anchors), independent of
     GPS *position* multipath -> removes the dwell/accel chord artifact.
"""
import json, math, statistics as st

FIX = "/home/raed/geowake_imu_analysis/fixtures"
GATE = 100.0
R = 6371000.0
def hav(a, b):
    la1, lo1, la2, lo2 = map(math.radians, [a[0], a[1], b[0], b[1]])
    d = math.sin((la2-la1)/2)**2 + math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2
    return 2*R*math.asin(min(1.0, math.sqrt(d)))
def arclengths(poly):
    cum=[0.0]
    for i in range(1,len(poly)): cum.append(cum[-1]+hav(poly[i-1],poly[i]))
    return cum
def project_point(poly, cum, pt):
    best=(None,1e18)
    for i in range(len(poly)-1):
        a,b=poly[i],poly[i+1]; latref=math.radians(a[0])
        bx=(b[1]-a[1])*math.cos(latref)*111320.0; by=(b[0]-a[0])*111320.0
        px=(pt[1]-a[1])*math.cos(latref)*111320.0; py=(pt[0]-a[0])*111320.0
        seglen2=bx*bx+by*by
        t=0.0 if seglen2==0 else max(0.0,min(1.0,(px*bx+py*by)/seglen2))
        perp=math.hypot(px-t*bx,py-t*by)
        if perp<best[1]: best=(cum[i]+t*math.sqrt(seglen2),perp)
    return best
def lin(xs, ys, x):
    if x<=xs[0]: return ys[0]
    if x>=xs[-1]: return ys[-1]
    for i in range(len(xs)-1):
        if xs[i]<=x<=xs[i+1]:
            f=(x-xs[i])/(xs[i+1]-xs[i]); return ys[i]+f*(ys[i+1]-ys[i])
    return ys[-1]
def pctl(xs,p):
    xs=sorted(xs); k=(len(xs)-1)*p; lo=int(k); hi=min(lo+1,len(xs)-1)
    return xs[lo]+(xs[hi]-xs[lo])*(k-lo)

RIDES=["fixture_Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32",
       "fixture_Nallur_to_Vijaynagar"]

pool_lin=[]; pool_spd=[]
for base in RIDES:
    d=json.load(open(f"{FIX}/{base}.json"))
    poly=[(p[0],p[1]) for p in d["oriented_polyline"]]; cum=arclengths(poly)
    z=sorted((s["arrival_t_s"],s["s_travel"]) for s in d["stations"])
    at=[a for a,_ in z]; aa=[b for _,b in z]
    fixes=[]
    with open(f"{FIX}/{d['gps_csv']}") as fh:
        fh.readline()
        for ln in fh:
            p=ln.strip().split(",")
            if len(p)<4: continue
            t=float(p[0]); lat=float(p[1]); lng=float(p[2])
            hacc=float(p[3]) if p[3]!="" else None
            spd=float(p[4]) if len(p)>4 and p[4]!="" else 0.0
            arc,perp=project_point(poly,cum,(lat,lng))
            fixes.append(dict(t=t,arc=arc,hacc=hacc,perp=perp,spd=spd))
    fixes.sort(key=lambda r:r["t"])
    # speed-integrated raw cumulative
    raw=[0.0]
    for i in range(1,len(fixes)):
        dt=fixes[i]["t"]-fixes[i-1]["t"]
        raw.append(raw[-1]+0.5*(fixes[i]["spd"]+fixes[i-1]["spd"])*dt)
    ts=[f["t"] for f in fixes]
    def raw_at(t): return lin(ts,raw,t)
    # speed truth: per inter-anchor interval rescale raw-shape to hit station arcs
    def speed_truth(t):
        if t<=at[0]: return aa[0]
        if t>=at[-1]: return aa[-1]
        for i in range(len(at)-1):
            if at[i]<=t<=at[i+1]:
                r0=raw_at(at[i]); r1=raw_at(at[i+1]); rt=raw_at(t)
                if r1-r0<1e-6:
                    f=(t-at[i])/(at[i+1]-at[i]); return aa[i]+f*(aa[i+1]-aa[i])
                return aa[i]+(aa[i+1]-aa[i])*(rt-r0)/(r1-r0)
        return aa[-1]
    ride_lin=[]; ride_spd=[]
    for f in fixes:
        trueL=lin(at,aa,f["t"]); trueS=speed_truth(f["t"])
        ttns=min(abs(f["t"]-a) for a in at)
        gate=(f["hacc"] is not None and math.isfinite(f["hacc"]) and f["hacc"]<=GATE)
        rec=dict(bwd_lin=trueL-f["arc"], bwd_spd=trueS-f["arc"], hacc=f["hacc"],
                 perp=f["perp"], ttns=ttns, gate=gate)
        ride_lin.append(rec); ride_spd.append(rec)
    pool_lin+=ride_lin; pool_spd+=ride_spd
    # per-ride ttns binning of LINEAR-truth backward error (gate-passing)
    print(f"\n=== {d['ride']}  (n={len(fixes)})")
    g=[r for r in ride_lin if r["gate"]]
    print("  along_bwd (LINEAR truth) binned by time-to-nearest-station:")
    for lo,hi in [(0,5),(5,15),(15,30),(30,60),(60,120),(120,9999)]:
        b=[r["bwd_lin"] for r in g if lo<=r["ttns"]<hi]
        if b: print(f"    ttns [{lo:>3},{hi:>4}) s: n={len(b):>4} median={st.median(b):>7.1f} p95={pctl(b,.95):>7.1f}")
    print("  along_bwd (SPEED-integrated truth) binned by time-to-nearest-station:")
    for lo,hi in [(0,5),(5,15),(15,30),(30,60),(60,120),(120,9999)]:
        b=[r["bwd_spd"] for r in g if lo<=r["ttns"]<hi]
        if b: print(f"    ttns [{lo:>3},{hi:>4}) s: n={len(b):>4} median={st.median(b):>7.1f} p95={pctl(b,.95):>7.1f}")

def viol_report(name, pool, key):
    g=[r for r in pool if r["gate"]]
    bwd=[r[key] for r in g if r[key]>0]
    viol=[r for r in g if r[key]>(r["hacc"] or 0)]
    margins=[r[key]-r["hacc"] for r in viol]
    print(f"\n[{name}] gate-pass n={len(g)}")
    print(f"   backward>0: n={len(bwd)} median={st.median(bwd):.1f} p90={pctl(bwd,.9):.1f} p95={pctl(bwd,.95):.1f} max={max(bwd):.1f}")
    print(f"   precondition(i) VIOLATIONS: {len(viol)}/{len(g)} = {100*len(viol)/len(g):.2f}%  worst margin={max(margins):.1f} m")
    # near-station-only (ttns<=15s, most reliable truth)
    gn=[r for r in g if r["ttns"]<=15]
    vn=[r for r in gn if r[key]>(r["hacc"] or 0)]
    print(f"   [near-station ttns<=15s] violations: {len(vn)}/{len(gn)} = {100*len(vn)/len(gn):.2f}%")

print("\n"+"="*70)
print("POOLED VIOLATION RATES: LINEAR truth vs SPEED-integrated truth")
print("="*70)
viol_report("LINEAR (piecewise-linear station chord)", pool_lin, "bwd_lin")
viol_report("SPEED (Doppler-integrated, station-anchored)", pool_spd, "bwd_spd")
