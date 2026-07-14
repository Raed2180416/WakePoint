"""WakePoint multi-leg journey composer + edge overlays.
Chains walk/road/metro legs into ONE continuous timeline with monotonic s(t) (no position
jump at transitions), per-sample leg/mode/moving/gps ground truth, transition instants,
and station events. Depends on wakepoint_legs (walk/road) + synthesizer.py (metro).
"""
import numpy as np

def metro_leg_kin(line_key, n_stations, seed):
    line=rail[line_key]; arc=np.array(line["arc_m"])
    base=snaps if line_key=="purple" else list(np.linspace(0,arc.max(),14))
    i0=int(np.random.default_rng(seed).integers(0,max(1,len(base)-n_stations)))
    sp=[float(x) for x in base[i0:i0+n_stations]]; sp=[p-sp[0] for p in sp]
    k=synth.generate_kinematics(line,sp,calib,seed=seed)
    k["leg_type"]="metro"; k["moving"]=k["v"]>0.3; k["station_prog"]=sp; k["line_key"]=line_key
    return k

def compose_journey(legs_spec, seed=0, fs=100.0):
    """legs_spec: list of dicts describing each leg in order.
       Each: {'type':'walk'|'road'|'metro', ...params, 'gps':'clean'|'degraded'|'blackout'}"""
    rng=np.random.default_rng(seed)
    T=[]; S=[]; V=[]; MOV=[]; LEG=[]; MODE=[]; GPS=[]; IMU={k:[] for k in
        ["ax","ay","az","gx","gy","gz","roll","pitch","yaw","grx","gry","grz"]}
    transitions=[]; station_events=[]  # (time, arc) of metro station arrivals
    t_off=0.0; s_off=0.0
    for li,spec in enumerate(legs_spec):
        typ=spec["type"]; sd=seed*100+li
        if typ=="walk": kin=walk_kinematics(spec.get("dist",600),seed=sd,n_stops=spec.get("stops"))
        elif typ=="road": kin=road_kinematics(spec.get("dist",3000),seed=sd,n_stops=spec.get("stops"))
        else: kin=metro_leg_kin(spec.get("line","purple"),spec.get("n_stations",6),sd)
        imu=synth_imu_leg(kin,noise,carry=spec.get("carry","in_hand"),seed=sd) if typ!="metro" \
            else synth.synth_imu_v2(kin,noise,carry=spec.get("carry","in_hand"),seed=sd,target_band=vibcal["k_scale"]*0.37)
        n=len(kin["t"])
        # metro imu lacks grx/gry/grz -> reconstruct from roll/pitch
        if typ=="metro":
            roll=imu["roll"]; pitch=imu["pitch"]
            imu["grx"]=-np.sin(pitch)*9.807; imu["gry"]=np.sin(roll)*np.cos(pitch)*9.807; imu["grz"]=np.cos(roll)*np.cos(pitch)*9.807
        # append with offsets (s continuous!)
        T.append(kin["t"]+t_off); S.append(kin["s"]+s_off); V.append(kin["v"]); MOV.append(kin["moving"])
        LEG.append(np.full(n,li)); MODE.append(np.array([typ]*n))
        # GPS availability per leg
        gmode=spec.get("gps","clean")
        if typ=="metro" and gmode!="clean":  # metro: blackout underground
            g=np.ones(n,bool); 
            if "blackout" in spec: b0,b1=spec["blackout"]; g[(kin["t"]>=b0)&(kin["t"]<=b1)]=False
            else: g[:]=True
        elif gmode=="blackout": g=np.zeros(n,bool)
        elif gmode=="degraded": g=rng.random(n)<0.4   # sparse/intermittent fixes
        else: g=np.ones(n,bool)
        GPS.append(g)
        for kk in IMU: IMU[kk].append(imu[kk])
        # transition marker at leg boundary
        if li>0: transitions.append(dict(t=t_off, from_leg=legs_spec[li-1]["type"], to_leg=typ, arc=s_off))
        # metro station events
        if typ=="metro":
            for sp_arc in kin["station_prog"]:
                ti=np.interp(sp_arc,kin["s"],kin["t"])
                station_events.append(dict(t=ti+t_off, arc=sp_arc+s_off, line=kin.get("line_key")))
        t_off=T[-1][-1]+1/fs; s_off=S[-1][-1]
    J=dict(t=np.concatenate(T),s=np.concatenate(S),v=np.concatenate(V),moving=np.concatenate(MOV),
           leg=np.concatenate(LEG),mode=np.concatenate(MODE),gps=np.concatenate(GPS),
           transitions=transitions,station_events=station_events,fs=fs,
           imu={k:np.concatenate(v) for k,v in IMU.items()})
    return J

def overlay_excessive_motion(J, intensity=1.0, seed=0):
    """Add fidget/jostle: bursts of high-freq accel+gyro noise DECORRELATED from actual motion.
       This is the adversary for ZUPT (looks like motion when standing) and dwell detection."""
    rng=np.random.default_rng(seed); n=len(J["t"]); imu=dict(J["imu"])
    # random burst windows (standing but fidgeting, or crowd jostle)
    n_bursts=rng.integers(3,8); burst=np.zeros(n,bool)
    for _ in range(n_bursts):
        c=rng.integers(0,n); w=int(rng.uniform(3,15)*J["fs"]); burst[max(0,c-w):c+w]=True
    amp=intensity*rng.uniform(1.5,3.5)
    for ax in ["ax","ay","az"]: imu[ax]=imu[ax]+np.where(burst,rng.normal(0,amp,n),0)
    for gx in ["gx","gy","gz"]: imu[gx]=imu[gx]+np.where(burst,rng.normal(0,amp*0.3,n),0)
    Jn=dict(J); Jn["imu"]=imu; Jn["fidget_mask"]=burst
    return Jn

def overlay_gps_degraded(J, seed=0):
    """Urban-canyon multipath: fixes that are PRESENT but biased (not just sparse).
       Adds along/cross-track bias to the GPS-available samples. The map-aided cross-track
       gate should reject the worst; per-fix adaptive R should down-weight the rest."""
    rng=np.random.default_rng(seed); n=len(J["t"])
    # multipath bias: correlated random walk of tens of metres on a fraction of fixes
    bias=np.cumsum(rng.normal(0,2,n))*0.3
    nlos=rng.random(n)<0.3   # 30% of fixes are NLOS/biased
    gps_bias=np.where(nlos, bias+rng.normal(0,25,n), rng.normal(0,8,n))
    Jn=dict(J); Jn["gps_bias_m"]=gps_bias; Jn["nlos_mask"]=nlos
    return Jn
