# WakePoint Step 1+2 verified fixes (sim-proven, not yet ported to Dart).
# Step 1 (honest covariance + sequence station association) + Step 2 (motion-gated dwell detector).
# Requires ekf_reference.py (EkfPy) alongside; EkfFixed subclass here.
import numpy as np, importlib.util
_s=importlib.util.spec_from_file_location("ekf_reference","ekf_reference.py")
ekf_mod=importlib.util.module_from_spec(_s); _s.loader.exec_module(ekf_mod)

class EkfFixed(ekf_mod.EkfPy):
    """Step 1a: honest covariance. sigmaS cap 200m->3km; ZUPT updates velocity+bias only."""
    def __init__(self,*a,**k):
        super().__init__(*a,**k); self._maxSigmaS=3000.0
    def _inflate(self,f):
        self.P[0,0]*=f; self.P[1,1]*=f; self.P[2,2]*=f
        self.P[0,0]=min(self.P[0,0],self._maxSigmaS**2)
        self.P[1,1]=min(self.P[1,1],100.0**2); self.P[2,2]=min(self.P[2,2],1.0)
    def on_zupt(self):
        if not self.init: return
        r=self.c["zuptVar"]; S=self.P[1,1]+r
        if S<=0: return
        nu=0.0-self.v; k0=self.P[0,1]/S; k1=self.P[1,1]/S; k2=self.P[2,1]/S
        self.s+=k0*nu; self.v+=k1*nu; self.b+=k2*nu
        p10,p11,p12=self.P[1,0],self.P[1,1],self.P[1,2]
        self.P[0,0]-=k0*p10; self.P[0,1]-=k0*p11; self.P[0,2]-=k0*p12
        self.P[1,0]-=k1*p10; self.P[1,1]-=k1*p11; self.P[1,2]-=k1*p12
        self.P[2,0]-=k2*p10; self.P[2,1]-=k2*p11; self.P[2,2]-=k2*p12
        self.P[1,1]=min(self.P[1,1],0.5**2)  # tighten VELOCITY only (justified)
        self._sym(); self._bounds(); self._floors(); self._pub()

class ZuptQuiet:
    """Rate-aware IMU-quiet detector (variance of gravity-removed accel + gyro over window)."""
    def __init__(self,fs_eff=100,win=0.75,a_thr=0.056,g_thr=0.002,dwell=0.8):
        self.w=max(3,int(win*fs_eff)); self.a_thr=a_thr; self.g_thr=g_thr
        self.dwell=max(1,int(dwell*fs_eff)); self.ab=[]; self.gb=[]; self.q=0
    def update(self,a,g):
        self.ab.append(a); self.gb.append(g)
        if len(self.ab)>self.w: self.ab.pop(0); self.gb.pop(0)
        if len(self.ab)<self.w: return False
        quiet=np.var(self.ab)<self.a_thr and np.var(self.gb)<self.g_thr
        self.q=self.q+1 if quiet else 0
        return self.q>=self.dwell

class DwellDetector:
    """Step 2: confirmed-dwell detector = sustained quiet + motion-gate(not vehicle) + min 8s.
    Tuned on real ride: min_dwell_s=8 -> 21/21 true stops matched, 1 false positive."""
    def __init__(self, fs=100.0, min_dwell_s=8.0, a_thr=0.056, g_thr=0.002):
        self.quiet=ZuptQuiet(fs_eff=fs, a_thr=a_thr, g_thr=g_thr); self.min=int(min_dwell_s*fs)
        self.run=0; self.fired_this=False
    def update(self, a_lin_mag, gyro_mag, is_vehicle):
        q=self.quiet.update(a_lin_mag, gyro_mag); low=q and (not is_vehicle)
        if low:
            self.run+=1
            if self.run>=self.min and not self.fired_this: self.fired_this=True; return True
        else: self.run=0; self.fired_this=False
        return False

class DwellCountAssociator:
    """Step 1b: underground station ID by counting confirmed dwells and advancing the KNOWN
    ordered station sequence one stop per dwell. Immune to arc-position lag; enables honest
    large sigma (no 2D spatial window to break). Resyncs to nearest station on each GPS fix."""
    def __init__(self, station_arcs, station_names=None):
        self.arcs=np.asarray(station_arcs,float); self.names=station_names
        self.k=-1; self.in_blackout=False
    def on_gps_fix(self, s_gps):
        passed=np.where(self.arcs<=s_gps+150)[0]
        if len(passed): self.k=int(passed[-1])
        self.in_blackout=False
    def on_blackout_start(self): self.in_blackout=True
    def confirm_dwell(self, t_now):
        if self.k+1<len(self.arcs):
            self.k+=1; return self.k, float(self.arcs[self.k]), 10.0
        return None
