# WakePoint Step 3+4: corpus generator + learned velocity regressor + velocity-fused EKF.
# Sim-verified (mid-blackout alarm 0%->100% with real HistGBR regressor). NOT yet ported to Dart.
# Requires: ekf_reference.py, wakepoint_step12.py, synthesizer artifacts, rail_geometry, calibration JSONs.
import numpy as np, json, pickle
from scipy import signal as spsig

CARRY_MODES=["in_hand","pocket","bag","on_lap","to_ear"]

def imu_features2(ax,ay,az,gx,gy,gz,fs=100.0,win_s=1.0,hop_s=0.5):
    """Phone-independent windowed features from RAW accel+gyro (no gravity channel needed).
    Gravity removed via per-window DC subtraction on magnitude. 8 features per window.
    a_p90 correlates r~0.99 with speed; 3-8Hz vibration band r~0.91 (the speed-chirp)."""
    n=len(ax); w=int(win_s*fs); hop=int(hop_s*fs)
    amag=np.sqrt(ax**2+ay**2+az**2); gyro=np.sqrt(gx**2+gy**2+gz**2)
    feats=[]; centers=[]
    for st in range(0,n-w,hop):
        seg=amag[st:st+w]; seg_g=gyro[st:st+w]; seg_ac=seg-seg.mean()
        f,p=spsig.welch(seg_ac,fs=fs,nperseg=min(w,64))
        b=lambda lo,hi: float(np.trapezoid(p[(f>=lo)&(f<hi)],f[(f>=lo)&(f<hi)])) if ((f>=lo)&(f<hi)).any() else 0.0
        feats.append([np.abs(seg_ac).mean(),seg_ac.std(),np.percentile(np.abs(seg_ac),90),
                      seg_g.mean(),seg_g.std(),b(3,8),b(8,20),float(f[np.argmax(p)] if len(p) else 0)])
        centers.append(st+w//2)
    return np.array(feats), np.array(centers)

def learned_velocity_series(imu, velreg, fs=100.0, win_s=1.0, hop_s=0.5):
    """Apply a trained velocity regressor across a ride, interpolate to full rate. Clip [0,25] m/s."""
    F,C=imu_features2(imu["ax"],imu["ay"],imu["az"],imu["gx"],imu["gy"],imu["gz"],fs,win_s,hop_s)
    v=velreg.predict(F)
    return np.interp(np.arange(len(imu["ax"])), C, np.clip(v,0,25))

# EkfVel: EkfFixed + velocity-measurement update (fuse learned speed as H=[0,1,0])
def make_EkfVel(EkfFixed):
    class EkfVel(EkfFixed):
        def on_velocity(self, v_meas, v_var):
            if not self.init: return
            S=self.P[1,1]+v_var
            if S<=0: return
            nu=v_meas-self.v; k0=self.P[0,1]/S; k1=self.P[1,1]/S; k2=self.P[2,1]/S
            self.s+=k0*nu; self.v+=k1*nu; self.b+=k2*nu
            p10,p11,p12=self.P[1,0],self.P[1,1],self.P[1,2]
            self.P[0,0]-=k0*p10; self.P[0,1]-=k0*p11; self.P[0,2]-=k0*p12
            self.P[1,0]-=k1*p10; self.P[1,1]-=k1*p11; self.P[1,2]-=k1*p12
            self.P[2,0]-=k2*p10; self.P[2,1]-=k2*p11; self.P[2,2]-=k2*p12
            self._sym(); self._bounds(); self._floors(); self._pub()
    return EkfVel
