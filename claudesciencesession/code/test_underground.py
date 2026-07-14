# Completely-underground trip: NO GPS ever. Cold-start seed from KNOWN route origin (s=0,v=0)
# with honest large sigma, then dead-reckon the WHOLE trip on IMU + dwell-count + learned velocity.
import importlib.util,sys,numpy as np,json,pickle
def L(n,p):
    s=importlib.util.spec_from_file_location(n,p);m=importlib.util.module_from_spec(s);sys.modules[n]=m;s.loader.exec_module(m);return m
ekf_ref=L("ekf_reference","ekf_reference.py");step12=L("wakepoint_step12","wakepoint_step12.py")
step34=L("wakepoint_step34","wakepoint_step34.py");AM=L("wakepoint_alarm_modes","wakepoint_alarm_modes.py")
synth=L("synthesizer","synthesizer.py");H=L("wakepoint_gpsout_harness","wakepoint_gpsout_harness.py")
EkfPy=ekf_ref.EkfPy;EkfFixed=step12.EkfFixed;DwellDetector=step12.DwellDetector
DwellCountAssociator=step12.DwellCountAssociator;ZuptQuiet=step12.ZuptQuiet
EkfVel=step34.make_EkfVel(EkfFixed);learned_velocity_series=step34.learned_velocity_series
velreg=pickle.load(open("velreg_model.pkl","rb"))
calib=json.load(open("synth_calibration.json"));noise=json.load(open("synth_noise.json"));CARRY=step34.CARRY_MODES
from scipy import signal as spsig
dist=json.load(open("handoff/topo_distribution.json"))
import inspect
src=inspect.getsource(synth.synth_imu_v2)
src=src.replace("f_dev=np.einsum('nij,nj->ni',np.transpose(R,(0,2,1)),f_world)","f_dev=np.einsum('nij,nj->ni',np.transpose(R,(0,2,1)),f_world)\n    g_dev=np.einsum('nij,nj->ni',np.transpose(R,(0,2,1)),grav)")
src=src.replace("roll=roll,pitch=pitch,yaw=yaw,","roll=roll,pitch=pitch,yaw=yaw,grx=g_dev[:,0],gry=g_dev[:,1],grz=g_dev[:,2],")
exec(compile(src,"<p>","exec"),synth.__dict__)
def mpl(length_m,tight,seed=0,ds=5.0):
    rng=np.random.default_rng(seed);n=int(length_m/ds);arc=np.arange(n)*ds;kappa=np.zeros(n)
    for _ in range(max(1,int(tight*n/40))):
        c=rng.integers(20,n-20);w=rng.integers(15,40);kappa[max(0,c-w):min(n,c+w)]+=rng.choice([-1,1])/rng.uniform(80,300)
    kappa+=np.cumsum(rng.normal(0,1e-5,n))*0.1;heading=np.cumsum(kappa*ds)
    x=np.cumsum(np.cos(heading)*ds);y=np.cumsum(np.sin(heading)*ds)
    return dict(arc_m=arc,lat=13+y/111000,lon=77.5+x/(111000*np.cos(np.radians(13))),heading_rad=heading,curvature_invm=kappa,length_m=float(arc[-1]),n_vertices=n)
def sample(dist,seed):
    rng=np.random.default_rng(seed);sp=np.array(dist["spacing_m"]);st=np.array(dist["n_stops"]);tf=np.array(dist["tight_frac"])
    i=rng.integers(len(sp));ns=int(np.clip(round(st[i]+rng.normal(0,1)),3,40));spc=float(np.clip(sp[i]*rng.uniform(.85,1.15),700,9000))
    arcs=np.cumsum([0]+[spc*rng.uniform(.85,1.15) for _ in range(ns-1)]);return ns,spc,float(np.clip(tf[i],0,.6)),arcs
def ride(dist,seed):
    rng=np.random.default_rng(seed);ns,spc,tg,arcs=sample(dist,seed);line=mpl(arcs[-1],tg,seed)
    kin=synth.generate_kinematics(line,arcs,dict(calib),seed=seed,fs=100.0);t=kin["t"];s=kin["s"]-kin["s"][0];dur=t[-1]
    blk=(0.0,dur)  # ENTIRE TRIP underground
    grade=synth.track_gradient(s,[blk],max_grade_deg=3.0);carry=rng.choice(CARRY)
    imu=synth.synth_imu_v2(kin,noise,carry=carry,grade_theta=grade,seed=seed,fs=100.0,target_band=0.382)
    return dict(arcs=arcs,kin=kin,t=t,s_true=s,dur=dur,blk=blk,imu=imu,ns=ns,spc=spc)
def veh(imu,fs=100.0):
    ax=imu["ax"];n=len(ax);f,tt,Z=spsig.stft(ax,fs=fs,nperseg=int(fs*2),noverlap=int(fs));band=(f>=3)&(f<=8)
    e=np.interp(np.arange(n)/fs,tt,np.abs(Z[band]).mean(0));return e>np.percentile(e,40)
def run_underground(rd,cold_seed=True,fs=100.0,seed=0):
    imu=rd["imu"];t=rd["t"];s_true=rd["s_true"];arcs=rd["arcs"];kin=rd["kin"]
    vl=learned_velocity_series(imu,velreg,fs);isv=veh(imu,fs)
    ek=EkfVel(allow_reverse=False);tf=H.TiltFilterApp();dd=DwellDetector(fs=fs);dca=DwellCountAssociator(arcs)
    # COLD START from route origin: s=0 (boarding station), v=0, HONEST large sigma
    ek.init_from_gps(0.0,0.0)
    if cold_seed:
        ek.P[0,0]=max(ek.P[0,0], (rd["spc"]*0.5)**2)  # sigma_s ~ half a station spacing (honest)
        ek.mode="degraded"
    dca.k=-1  # no station passed yet (boarding at origin)
    est=np.empty(len(t));sig=np.empty(len(t));pt=None
    for i in range(len(t)):
        dt=None if pt is None else t[i]-pt;pt=t[i]
        aF=tf.forward_accel(imu["ax"][i],imu["ay"][i],imu["az"][i],imu["grx"][i],imu["gry"][i],imu["grz"][i])
        a_lin=np.linalg.norm(np.array([imu["ax"][i],imu["ay"][i],imu["az"][i]])-tf.gHat*9.807)
        gm=np.sqrt(imu["gx"][i]**2+imu["gy"][i]**2+imu["gz"][i]**2)
        ek.on_forward_accel(dt,aF);ek.mode="degraded"
        if i%50==0: ek.on_velocity(float(vl[i]),4.0)
        if dd.update(a_lin,gm,isv[i]):
            ek.on_zupt();r=dca.confirm_dwell(t[i])
            if r is not None: ek.on_station(r[1])
        est[i]=ek.public_s();sig[i]=ek.sigmaS()
    return est,sig
res=[]
for s in range(6):
    rd=ride(dist,seed=2000+s)
    est,sig=run_underground(rd,cold_seed=True)
    # target: a station ~70% through
    ti=max(1,int(0.7*len(rd["arcs"])));tgt=rd["arcs"][ti]
    t=rd["t"];s_true=rd["s_true"]
    # stops-mode alarm: fire 1 stop before target
    gap=rd["arcs"][ti]-rd["arcs"][ti-1];fa=tgt-gap
    fi=np.argmax(est>=fa) if (est>=fa).any() else -1
    ii=np.argmax(s_true>=fa) if (s_true>=fa).any() else -1
    lead=float(t[fi]-t[ii]) if(fi>=0 and ii>=0) else None
    be=len(t)-1
    res.append(dict(seed=2000+s,ns=rd["ns"],spc=round(rd["spc"]),dur=round(rd["dur"]),
                    final_err=round(abs(est[be]-s_true[be])),final_sig=round(sig[be]),
                    stops_lead_s=round(lead,1) if lead is not None else None,
                    stops_hit=bool(lead is not None and abs(lead)<=30)))
json.dump(res,open("handoff/underground_test.json","w"))
for r in res: print(r)
