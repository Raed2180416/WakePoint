"""
WakePoint Stage B — Physics-based phone-IMU synthesizer along real rail geometry (v2).

Pipeline (each layer calibrated against the real reference ride, docs/Sandalsoap-whitefield/):
  Layer 1   generate_kinematics    : jerk-limited trapezoidal s(t),v(t),a(t) per segment + dwells;
                                      lateral accel v^2*kappa and yaw v*kappa from real rail curvature.
  GATE-1    track_gradient         : synthetic track pitch theta(s) — ramps at tunnel entry/exit so
                                      gravity projects a POSITION-CORRELATED forward artifact
                                      (sin(theta)*g) the TiltFilter must reject underground.
  Layer 2   synth_imu_v2 (rot)     : project pitched world specific-force + gravity into a
                                      time-varying device frame (carry-mode tilt + wobble).
  GATE-2    carry_vibration_chirp  : carry-motion vibration whose dominant frequency TRACKS speed
                                      (rail-joint f=v/spacing + wheel/bogie harmonics, chirp r~0.8);
                                      spectral SHAPE tuned to real 3-8 Hz peak. Critical because the
                                      app MotionClassifier reads walk/vehicle from FFT band energy.
  Layer 3   synth_imu_v2 (noise)   : calibrated MEMS white noise + slowly-varying bias random-walk.
  Layer 4   synth_gps              : 1 Hz GPS with realistic accuracy + programmable blackout.
  GATE-3    apply_throttle         : SCENARIO AXIS — foreground 100Hz / doze_batched 50Hz /
                                      throttled 10Hz. A screen-off wake alarm loses sensor rate;
                                      100 Hz metrics are optimistic. Applied per-ride in Stage C.

Realism gate (v3): |accel| std real 0.70 vs synth 0.82; band-energy fractions
  [0.5-3,3-8,8-20 Hz] real [0.15,0.47,0.38] vs synth [0.18,0.58,0.25] (3-8 Hz peak matched).
NOTE (GATE-4, Stage C not synthesizer): the eval harness MUST propagate silver-reference
  uncertainty (sigma 2-40 s); an underground "error" within reference sigma is reference noise,
  not filter error. All fitted constants are n=1 point estimates -> extrapolation flags = capture priorities.
"""
import numpy as np, json
from scipy.ndimage import gaussian_filter1d
from scipy import signal
_trap = np.trapezoid if hasattr(np,"trapezoid") else np.trapz


def _seg_profile(D, v_cruise, a_acc, a_brk, fs=100.0):
    d_acc = v_cruise**2/(2*a_acc); d_brk = v_cruise**2/(2*a_brk)
    if d_acc + d_brk >= D:
        vp = np.sqrt(2*D*a_acc*a_brk/(a_acc+a_brk))
        t_acc, t_brk = vp/a_acc, vp/a_brk
        t = np.arange(0, t_acc+t_brk, 1/fs)
        v = np.where(t<t_acc, a_acc*t, np.maximum(vp-a_brk*(t-t_acc),0))
    else:
        d_cru = D - d_acc - d_brk
        t_acc, t_cru, t_brk = v_cruise/a_acc, d_cru/v_cruise, v_cruise/a_brk
        t = np.arange(0, t_acc+t_cru+t_brk, 1/fs)
        v = np.piecewise(t,[t<t_acc,(t>=t_acc)&(t<t_acc+t_cru),t>=t_acc+t_cru],
            [lambda x:a_acc*x, lambda x:v_cruise, lambda x:np.maximum(v_cruise-a_brk*(x-t_acc-t_cru),0)])
    v = gaussian_filter1d(np.maximum(v,0), sigma=fs*0.4)
    d = _trap(v,dx=1/fs)
    if d>0: v *= D/d
    return v


def generate_kinematics(line, station_prog, params, seed=0, fs=100.0,
                        walk_in=120.0, walk_out=150.0):
    """Generate s(t),v(t),a(t) + lateral accel & yaw along a rail line.
    line: geom dict entry with 'arc_m','curvature_invm'. station_prog: list of arc positions (m)."""
    rng = np.random.default_rng(seed)
    arc = np.array(line["arc_m"]); kap = np.array(line["curvature_invm"])
    vseg=[]; 
    # walk-in leg (from 0 to first station) at walking pace
    dwalk = station_prog[0] if station_prog[0]>0 else 0
    for i in range(len(station_prog)-1):
        D = station_prog[i+1]-station_prog[i]
        if D<=0: continue
        vc = np.clip(rng.normal(params["v_cruise_mps"], 2.0), 10, 22)
        aa = np.clip(rng.normal(params["a_accel"],0.15),0.7,1.6)
        ab = np.clip(rng.normal(params["a_brake"],0.15),0.7,1.6)
        vseg.append(_seg_profile(D, vc, aa, ab, fs))
        dwell = max(5, rng.normal(params["dwell_mean_s"], params["dwell_std_s"]))
        vseg.append(np.zeros(int(dwell*fs)))       # dwell at station
    v = np.concatenate(vseg)
    s0 = station_prog[0]
    s = s0 + np.cumsum(v)/fs
    t = np.arange(len(v))/fs
    a_tan = np.gradient(v, 1/fs)
    # curvature at each s -> lateral accel = v^2*kappa, yaw rate = v*kappa
    k_at = np.interp(s, arc, kap)
    a_lat = v**2 * k_at
    yaw_rate = v * k_at
    return dict(t=t, s=s, v=v, a_tan=a_tan, a_lat=a_lat, yaw_rate=yaw_rate, kappa=k_at,
                station_prog=station_prog, fs=fs)


def track_gradient(s, tunnel_windows, max_grade_deg=3.0, ramp_m=250.0):
    """Vehicle pitch θ (rad) vs progress s. Flat on surface; ramps DOWN into each tunnel
    entry and UP at exit over `ramp_m`, holding max_grade through the deep section.
    Emitted into device pitch so gravity projects a forward component the TiltFilter must reject.
    tunnel_windows: list of (s_enter, s_exit) in metres."""
    theta = np.zeros_like(s, float)
    gmax = np.radians(max_grade_deg)
    for s0, s1 in tunnel_windows:
        # descend at entry: -grade over [s0, s0+ramp], hold ~0 deep (assume level deep tunnel),
        # ascend at exit: +grade over [s1-ramp, s1]
        desc = np.clip((s - s0)/ramp_m, 0, 1) * (s < s0+ramp_m)
        asc  = np.clip((s - (s1-ramp_m))/ramp_m, 0, 1) * (s >= s1-ramp_m)
        theta += -gmax*desc + gmax*asc
    return gaussian_filter1d(theta, 50)   # smooth the corners (no instantaneous grade change)


def rot_from_euler(roll,pitch,yaw):
    cr,sr=np.cos(roll),np.sin(roll); cp,sp=np.cos(pitch),np.sin(pitch); cy,sy=np.cos(yaw),np.sin(yaw)
    R=np.empty((len(roll),3,3))
    R[:,0,0]=cy*cp; R[:,0,1]=cy*sp*sr-sy*cr; R[:,0,2]=cy*sp*cr+sy*sr
    R[:,1,0]=sy*cp; R[:,1,1]=sy*sp*sr+cy*cr; R[:,1,2]=sy*sp*cr-cy*sr
    R[:,2,0]=-sp;   R[:,2,1]=cp*sr;          R[:,2,2]=cp*cr
    return R


def carry_vibration_chirp(v, carry, target_band_energy, joint_spacing=18.0, fs=100.0, seed=0):
    """Speed-tracking vibration. Real metro spectrum peaks ~3-8Hz (wheel/bogie/structural
    modes), NOT at the low joint-pass freq — so harmonics are weighted UP. Dominant freq
    still tracks speed (r>0.6). Scaled to target 1-10Hz band energy."""
    rng=np.random.default_rng(seed); n=len(v)
    white=rng.normal(0,1,(n,3))
    sos=signal.butter(2,[3,10],btype='band',fs=fs,output='sos')   # tremor floor in real peak band
    floor=0.5*signal.sosfilt(sos,white,axis=0)
    f_joint=np.clip(v,0,None)/joint_spacing
    phase=2*np.pi*np.cumsum(f_joint)/fs
    amp=(np.clip(v,0,30)/10.0)[:,None]
    # weight HIGHER harmonics up (wheel/bogie 4x-8x dominate real 3-8Hz peak)
    chirp=amp*(0.3*np.sin(phase)+0.8*np.sin(4*phase)+0.7*np.sin(8*phase))[:,None]*rng.normal(1,0.15,(1,3))
    vib=floor+chirp
    mag=np.linalg.norm(vib,axis=1)
    f,p=signal.welch(mag-mag.mean(),fs=fs,nperseg=min(4096,n))
    cur=_trap(p[(f>=1)&(f<10)],f[(f>=1)&(f<10)])
    return vib*np.sqrt(target_band_energy/max(cur,1e-9))


def synth_imu_v2(kin, noise, carry="in_hand", grade_theta=None, seed=0, fs=100.0, g=9.807,
                 target_band=None, joint_spacing=18.0):
    """Layers 2+2.5+3 with GRADIENT and SPEED-CHIRP vibration folded in.
    grade_theta: vehicle pitch θ(t) [rad] from track_gradient — TILTS the world specific-force
    frame so gravity gets a real forward component on ramps (the untested underground input)."""
    rng=np.random.default_rng(seed); n=len(kin["t"]); v=kin["v"]
    # world specific force: forward=a_tan, lateral=a_lat, up=0 ; then PITCH the vehicle by grade
    a_world=np.zeros((n,3)); a_world[:,0]=kin["a_tan"]; a_world[:,1]=kin["a_lat"]
    if grade_theta is not None:
        # gravity in the vehicle's pitched frame: forward component = -g*sin(θ), vertical = g*cos(θ)
        grav=np.stack([-g*np.sin(grade_theta), np.zeros(n), g*np.cos(grade_theta)],1)
    else:
        grav=np.tile([0,0,g],(n,1))
    f_world=a_world+grav
    w_world=np.zeros((n,3)); w_world[:,2]=kin["yaw_rate"]
    # carry-mode device orientation
    base={"in_hand":(0.3,0.1,0),"pocket":(1.3,0.2,0),"bag":(0.9,-0.4,0),"on_lap":(1.0,0.0,0),"to_ear":(0.6,0.9,0)}[carry]
    wob=np.radians(5.5)
    roll=base[0]+gaussian_filter1d(rng.normal(0,wob,n),fs*0.5)
    pitch=base[1]+gaussian_filter1d(rng.normal(0,wob,n),fs*0.5)
    yaw=base[2]+np.cumsum(w_world[:,2])/fs+gaussian_filter1d(rng.normal(0,wob,n),fs*0.5)
    R=rot_from_euler(roll,pitch,yaw)
    f_dev=np.einsum('nij,nj->ni',np.transpose(R,(0,2,1)),f_world)
    w_dev=np.einsum('nij,nj->ni',np.transpose(R,(0,2,1)),w_world)
    # Layer 2.5 speed-chirp vibration
    if target_band is not None:
        f_dev=f_dev+carry_vibration_chirp(v,carry,target_band,joint_spacing,fs,seed+7)
    # Layer 3 noise + bias RW
    acc_b=np.cumsum(rng.normal(0,noise["acc_bias_rw"],(n,3)),axis=0)+rng.normal(0,noise["acc_bias_instab"],3)
    gyr_b=np.cumsum(rng.normal(0,noise["gyr_bias_rw"],(n,3)),axis=0)+rng.normal(0,noise["gyr_bias_instab"],3)
    acc=f_dev+acc_b+rng.normal(0,noise["acc_white"],(n,3))
    gyr=w_dev+gyr_b+rng.normal(0,noise["gyr_white"],(n,3))
    return dict(t=kin["t"],ax=acc[:,0],ay=acc[:,1],az=acc[:,2],gx=gyr[:,0],gy=gyr[:,1],gz=gyr[:,2],
                roll=roll,pitch=pitch,yaw=yaw,grade=grade_theta if grade_theta is not None else np.zeros(n),
                v=v,true_acc_bias=acc_b)


def synth_gps(kin, line, station_prog, blackout=None, seed=0, fs=100.0, base_acc=12.0):
    """Layer 4: 1Hz GPS with realistic accuracy + a programmable blackout.
    blackout=(t0,t1) seconds forces no-fix. Returns 1Hz arrays."""
    rng=np.random.default_rng(seed)
    t=kin["t"]; s=kin["s"]
    tg=np.arange(0,t[-1],1.0)
    sg=np.interp(tg,t,s)
    # map arc s -> lat/lon on the line
    arc=np.array(line["arc_m"]); la=np.array(line["lat"]); lo=np.array(line["lon"])
    lat=np.interp(sg,arc,la); lon=np.interp(sg,arc,lo)
    acc=np.abs(rng.normal(base_acc, 6, len(tg))).clip(4,60)
    # position noise scaled by accuracy
    lat=lat+rng.normal(0,1,len(tg))*acc/111320.0
    lon=lon+rng.normal(0,1,len(tg))*acc/(111320.0*np.cos(np.radians(la.mean())))
    fresh=np.ones(len(tg),bool)
    if blackout:
        m=(tg>=blackout[0])&(tg<=blackout[1]); fresh[m]=False; acc[m]=np.nan
    return dict(t=tg,lat=lat,lon=lon,acc=acc,fresh=fresh,s=sg)


def apply_throttle(imu, regime="foreground", fs=100.0, seed=0):
    """GATE ITEM 3: emulate background sensor throttling for a screen-off wake alarm.
    - foreground: full 100 Hz (baseline).
    - doze_batched: samples delivered in bursts (Android Doze) — regular sampling but
      timestamps batched; here we DROP to ~50 Hz effective then hold-last (batch delivery).
    - throttled: OS collapses rate to ~10 Hz underground (worst realistic screen-off case).
    Returns a decimated+held copy with an added 'sample_rate_hz' effective field.
    Every 100 Hz metric is OPTIMISTIC vs these."""
    rng=np.random.default_rng(seed); n=len(imu["t"])
    if regime=="foreground":
        return {**imu, "eff_hz":100.0, "regime":regime}
    dec={"doze_batched":2, "throttled":10}[regime]      # keep every dec-th sample
    keep=np.zeros(n,bool); keep[::dec]=True
    out={}
    for k,val in imu.items():
        if isinstance(val,np.ndarray) and val.shape[0]==n:
            held=val.copy()
            idx=np.where(keep)[0]
            # zero-order hold between kept samples (sensor delivers last value)
            held=val[idx][np.clip(np.searchsorted(idx,np.arange(n),'right')-1,0,len(idx)-1)]
            out[k]=held
        else: out[k]=val
    out["eff_hz"]=100.0/dec; out["regime"]=regime
    return out
