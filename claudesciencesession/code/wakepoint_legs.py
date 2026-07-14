"""WakePoint multi-leg journey synthesizer: walk + road leg generators and leg-aware IMU.
Composes with the metro synthesizer (synthesizer.py generate_kinematics/synth_imu_v2).
"""
import numpy as np
from scipy.ndimage import uniform_filter1d

def walk_kinematics(distance_m, seed=0, fs=100.0, walk_speed=1.35, n_stops=None):
    """Pedestrian leg with SMOOTH decel/accel into stops (real ~0.8s ramps, no gradient spikes)."""
    rng=np.random.default_rng(seed)
    v_walk=max(0.8,rng.normal(walk_speed,0.15))
    if n_stops is None: n_stops=int(rng.integers(0,3))
    dur_move=distance_m/v_walk
    t=np.arange(0,dur_move+n_stops*14+2,1/fs); v=np.full(len(t),v_walk)
    stops=[]
    if n_stops>0:
        stop_times=sorted(rng.uniform(0.15,0.85,n_stops)*dur_move)
        for st in stop_times:
            dwell=rng.uniform(5,20); i0=int(st*fs); i1=i0+int(dwell*fs)
            v[i0:i1]=0.0; stops.append((t[i0],t[min(i1,len(t)-1)]))
    # smooth the velocity profile: 0.8s moving-average => realistic ramps, kills gradient spikes
    v=uniform_filter1d(v,size=int(0.8*fs))
    s=np.cumsum(v)/fs
    if s[-1]>0: s=s/s[-1]*distance_m
    a_tan=np.gradient(v,1/fs); moving=v>0.15
    return dict(t=t,s=s,v=v,a_tan=a_tan,a_lat=np.zeros_like(t),yaw_rate=np.zeros_like(t),
                kappa=np.zeros_like(t),fs=fs,moving=moving,leg_type="walk",stops=stops,cadence_hz=rng.uniform(1.7,2.1))

def road_kinematics(distance_m, seed=0, fs=100.0, v_cruise=12.0, n_stops=None):
    """Vehicle road leg: 8-15 m/s cruise, traffic-light stops (real vehicle ZUPTs),
       gentler accel than metro. No rail curvature but road curves via yaw."""
    rng=np.random.default_rng(seed)
    vc=max(6,rng.normal(v_cruise,2.5)); a=rng.uniform(1.2,2.2)
    if n_stops is None: n_stops=rng.integers(1,5)  # traffic lights
    # trapezoidal with stops
    seg_d=distance_m/(n_stops+1)
    ts=[0.0]; vs=[0.0]; ss=[0.0]
    def push(dur,vfun):
        for _ in range(int(dur*fs)):
            ts.append(ts[-1]+1/fs)
    t=[0.0]; v=[0.0]; s=[0.0]
    for seg in range(n_stops+1):
        # accelerate to vc, cruise, decelerate to 0 (except maybe last)
        t_acc=vc/a; 
        while v[-1]<vc:
            v.append(min(vc,v[-1]+a/fs)); s.append(s[-1]+v[-1]/fs); t.append(t[-1]+1/fs)
        d_cruise=max(0,seg_d-2*(0.5*vc*t_acc))
        for _ in range(int((d_cruise/vc)*fs)):
            v.append(vc); s.append(s[-1]+vc/fs); t.append(t[-1]+1/fs)
        while v[-1]>0.05:
            v.append(max(0,v[-1]-a/fs)); s.append(s[-1]+v[-1]/fs); t.append(t[-1]+1/fs)
        if seg<n_stops:  # stop at light
            dwell=rng.uniform(8,30)
            for _ in range(int(dwell*fs)):
                v.append(0.0); s.append(s[-1]); t.append(t[-1]+1/fs)
    t=np.array(t); v=np.array(v); s=np.array(s)
    if s[-1]>0: s=s/s[-1]*distance_m
    a_tan=np.gradient(v,1/fs); moving=v>0.1
    # road yaw: gentle random curves
    kappa=np.zeros_like(t); yaw_rate=v*kappa
    return dict(t=t,s=s,v=v,a_tan=a_tan,a_lat=v**2*kappa,yaw_rate=yaw_rate,kappa=kappa,
                fs=fs,moving=moving,leg_type="road",stops=[],v_cruise=vc)

def synth_imu_leg(kin, noise, carry="in_hand", seed=0, fs=100.0, g=9.807):
    rng=np.random.default_rng(seed); n=len(kin["t"]); t=kin["t"]; v=kin["v"]; moving=kin["moving"]
    tilt={"in_hand":(0.10,0.05),"pocket":(1.3,0.2),"bag":(0.7,0.3),"on_lap":(0.5,0.1),"to_ear":(1.1,0.15)}[carry]
    roll=rng.normal(tilt[0],0.10,n)+np.deg2rad(5.5)*np.sin(2*np.pi*0.3*t+rng.uniform(0,6))
    pitch=rng.normal(tilt[1],0.10,n); yaw=np.cumsum(kin["yaw_rate"])/fs
    grx=-np.sin(pitch)*g; gry=np.sin(roll)*np.cos(pitch)*g; grz=np.cos(roll)*np.cos(pitch)*g
    aF=kin["a_tan"].copy(); lt=kin["leg_type"]
    aw=noise["acc_white"][0] if isinstance(noise["acc_white"],(list,np.ndarray)) else 0.05
    gw=noise["gyr_white"][0] if isinstance(noise["gyr_white"],(list,np.ndarray)) else 0.01
    if lt=="walk":
        cad=kin.get("cadence_hz",2.0); phase=2*np.pi*cad*t
        mv=moving.astype(float)  # 1.0 moving, 0.0 stopped -> vibration gated hard
        step_v=(1.8*np.sin(phase)+0.6*np.sin(2*phase))*mv
        step_f=0.9*np.abs(np.sin(phase))*mv
        ax=aF+step_f+rng.normal(0,aw,n)
        ay=rng.normal(0,0.05,n)+0.4*np.sin(phase+1)*mv
        az=step_v+rng.normal(0,0.05,n)
    elif lt=="road":
        mv=moving.astype(float)
        amp=(0.15+0.02*v)*mv + 0.03*(1-mv)  # vibration scales with speed, near-zero at stop
        vib=amp*rng.standard_normal(n)
        ax=aF+vib; ay=rng.normal(0,0.06,n)+0.3*kin["a_lat"]; az=rng.normal(0,0.08,n)*(0.3+0.7*mv)
    else:
        ax=aF+rng.normal(0,0.05,n); ay=rng.normal(0,0.1,n); az=rng.normal(0,0.1,n)
    ax_dev=ax+grx; ay_dev=ay+gry; az_dev=az+grz
    gx=rng.normal(0,gw,n); gy=rng.normal(0,0.01,n); gz=kin["yaw_rate"]+rng.normal(0,0.02,n)
    if lt=="walk": gx+=0.3*np.sin(2*np.pi*kin.get("cadence_hz",2.0)*t)*moving.astype(float)
    return dict(t=t,ax=ax_dev,ay=ay_dev,az=az_dev,gx=gx,gy=gy,gz=gz,
                roll=roll,pitch=pitch,yaw=yaw,grx=grx,gry=gry,grz=grz,v=v,moving=moving)
