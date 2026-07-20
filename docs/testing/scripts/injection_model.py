#!/usr/bin/env python3
"""Extract a never-late stress-test injection model from the DE-BIASED
(Doppler-speed-integrated, station-anchored) along-track error, on gate-passing
fixes. Splits on-route (perp<=50m, genuine along-track error) from off-route
(perp>50m, phantom/multipath) so the injection model has two components."""
import json, math, statistics as st
FIX="/home/raed/geowake_imu_analysis/fixtures"; GATE=100.0; R=6371000.0
def hav(a,b):
    la1,lo1,la2,lo2=map(math.radians,[a[0],a[1],b[0],b[1]])
    d=math.sin((la2-la1)/2)**2+math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2
    return 2*R*math.asin(min(1.0,math.sqrt(d)))
def arcl(poly):
    c=[0.0]
    for i in range(1,len(poly)): c.append(c[-1]+hav(poly[i-1],poly[i]))
    return c
def proj(poly,cum,pt):
    best=(None,1e18)
    for i in range(len(poly)-1):
        a,b=poly[i],poly[i+1]; lr=math.radians(a[0])
        bx=(b[1]-a[1])*math.cos(lr)*111320.0; by=(b[0]-a[0])*111320.0
        px=(pt[1]-a[1])*math.cos(lr)*111320.0; py=(pt[0]-a[0])*111320.0
        s2=bx*bx+by*by; t=0 if s2==0 else max(0,min(1,(px*bx+py*by)/s2))
        perp=math.hypot(px-t*bx,py-t*by)
        if perp<best[1]: best=(cum[i]+t*math.sqrt(s2),perp)
    return best
def lin(xs,ys,x):
    if x<=xs[0]: return ys[0]
    if x>=xs[-1]: return ys[-1]
    for i in range(len(xs)-1):
        if xs[i]<=x<=xs[i+1]:
            f=(x-xs[i])/(xs[i+1]-xs[i]); return ys[i]+f*(ys[i+1]-ys[i])
    return ys[-1]
def pctl(xs,p):
    if not xs: return float('nan')
    xs=sorted(xs); k=(len(xs)-1)*p; lo=int(k); hi=min(lo+1,len(xs)-1)
    return xs[lo]+(xs[hi]-xs[lo])*(k-lo)
recs=[]
for base in ["fixture_Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32","fixture_Nallur_to_Vijaynagar"]:
    d=json.load(open(f"{FIX}/{base}.json")); poly=[(p[0],p[1]) for p in d["oriented_polyline"]]; cum=arcl(poly)
    z=sorted((s["arrival_t_s"],s["s_travel"]) for s in d["stations"]); at=[a for a,_ in z]; aa=[b for _,b in z]
    fixes=[]
    with open(f"{FIX}/{d['gps_csv']}") as fh:
        fh.readline()
        for ln in fh:
            p=ln.strip().split(",")
            if len(p)<4: continue
            t=float(p[0]); arc,perp=proj(poly,cum,(float(p[1]),float(p[2])))
            hacc=float(p[3]) if p[3]!="" else None; spd=float(p[4]) if len(p)>4 and p[4]!="" else 0.0
            fixes.append(dict(t=t,arc=arc,hacc=hacc,perp=perp,spd=spd))
    fixes.sort(key=lambda r:r["t"]); raw=[0.0]
    for i in range(1,len(fixes)): raw.append(raw[-1]+0.5*(fixes[i]["spd"]+fixes[i-1]["spd"])*(fixes[i]["t"]-fixes[i-1]["t"]))
    ts=[f["t"] for f in fixes]
    def rat(t): return lin(ts,raw,t)
    def struth(t):
        if t<=at[0]: return aa[0]
        if t>=at[-1]: return aa[-1]
        for i in range(len(at)-1):
            if at[i]<=t<=at[i+1]:
                r0=rat(at[i]); r1=rat(at[i+1])
                if r1-r0<1e-6: f=(t-at[i])/(at[i+1]-at[i]); return aa[i]+f*(aa[i+1]-aa[i])
                return aa[i]+(aa[i+1]-aa[i])*(rat(t)-r0)/(r1-r0)
        return aa[-1]
    for f in fixes:
        if not(f["hacc"] is not None and math.isfinite(f["hacc"]) and f["hacc"]<=GATE): continue
        bwd=struth(f["t"])-f["arc"]
        recs.append(dict(bwd=bwd,hacc=f["hacc"],perp=f["perp"]))

onr=[r for r in recs if r["perp"]<=50]
off=[r for r in recs if r["perp"]>50]
print(f"gate-passing total={len(recs)}  on-route(perp<=50)={len(onr)}  off-route(perp>50)={len(off)}")
for name,pool in [("ON-ROUTE (perp<=50m)",onr),("OFF-ROUTE (perp>50m)",off),("ALL",recs)]:
    bwd=[r["bwd"] for r in pool]; posb=[b for b in bwd if b>0]
    viol=[r for r in pool if r["bwd"]>r["hacc"]]
    # understatement factor = backward_error / reported_accuracy (for backward fixes)
    uf=[r["bwd"]/r["hacc"] for r in pool if r["bwd"]>0 and r["hacc"]>0]
    print(f"\n[{name}] n={len(pool)}")
    print(f"  backward error (>0): n={len(posb)}  "
          f"median={st.median(posb) if posb else 0:.1f} p50-all={pctl(bwd,.5):.1f} "
          f"p90={pctl(bwd,.9):.1f} p95={pctl(bwd,.95):.1f} p99={pctl(bwd,.99):.1f} max={max(bwd):.1f}")
    print(f"  reported hacc: median={st.median([r['hacc'] for r in pool]):.1f} p95={pctl([r['hacc'] for r in pool],.95):.1f}")
    print(f"  VIOLATIONS (bwd>hacc): {len(viol)}/{len(pool)} = {100*len(viol)/len(pool):.2f}%")
    if uf:
        print(f"  understatement factor (bwd/hacc, backward fixes): median={st.median(uf):.2f} "
              f"p90={pctl(uf,.9):.2f} p95={pctl(uf,.95):.2f} max={max(uf):.2f}")
    if viol:
        vm=[r["bwd"]-r["hacc"] for r in viol]
        print(f"  among violations: bwd median={st.median([r['bwd'] for r in viol]):.1f} "
              f"margin(bwd-hacc) median={st.median(vm):.1f} p95={pctl(vm,.95):.1f} worst={max(vm):.1f}")
