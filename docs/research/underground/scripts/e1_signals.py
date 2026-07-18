#!/usr/bin/env python3
"""
TASK E1: produce CLEAN longitudinal specific force for each REAL ride.

Pipeline:
 (1) load IMU (t,ax,ay,az,gx,gy,gz ~50Hz), body frame, accel INCLUDES gravity.
 (2) attitude/gravity via a gravity-vector COMPLEMENTARY (Mahony-style) filter:
       - propagate gravity direction in the body frame with the gyro (Rodrigues),
       - correct toward the accelerometer ONLY during low-jerk / near-1g / low-spin
         windows (so a sustained brake force is NOT leaked into the gravity estimate,
         which is exactly what a naive low-pass does wrong).
 (3) remove gravity -> linear specific force; split vertical / horizontal in a level frame.
 (4) longitudinal axis = principal direction of horizontal specific force over a rolling
       window (PCA), sign-anchored to GPS d(speed)/dt -> SIGNED a_long (+fwd, -brake), a_lat.
 (5) high-freq vibration energy + gyro yaw-rate (about gravity).
 (6) save <base>_signals.npz and report brake-event SNR + gravity cleanliness.
"""
import json, os, sys
import numpy as np

FIX = "/home/raed/geowake_imu_analysis/fixtures"
WORK = "/home/raed/geowake_imu_analysis/work"
G0 = 9.81
RIDES = [
    "fixture_Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32",
    "fixture_Nallur_to_Vijaynagar",
]

# ---------------- helpers ----------------
def haversine(lat1, lon1, lat2, lon2):
    R = 6371000.0
    p1 = np.radians(lat1); p2 = np.radians(lat2)
    dphi = np.radians(lat2 - lat1); dl = np.radians(lon2 - lon1)
    a = np.sin(dphi/2)**2 + np.cos(p1)*np.cos(p2)*np.sin(dl/2)**2
    return 2*R*np.arcsin(np.sqrt(np.clip(a, 0, 1)))

def rodrigues_rotate(v, axis_unit, theta):
    """Rotate vectors v (...,3) about axis_unit (...,3) by angle theta (...)."""
    ct = np.cos(theta)[..., None]; st = np.sin(theta)[..., None]
    dot = np.sum(v*axis_unit, axis=-1, keepdims=True)
    return v*ct + np.cross(axis_unit, v)*st + axis_unit*dot*(1-ct)

def butter_highpass_rms(x, fs, fc=4.0, win_s=1.0):
    from scipy.signal import butter, filtfilt
    b, a = butter(2, fc/(fs/2.0), btype='high')
    hp = filtfilt(b, a, x)
    w = max(3, int(round(win_s*fs)))
    kern = np.ones(w)/w
    return np.sqrt(np.convolve(hp*hp, kern, mode='same'))

# ---------------- gravity / attitude filter ----------------
def estimate_gravity(t, acc, gyro):
    """Gravity-vector complementary filter in the body frame.
    Returns g_body (N,3) and gmag (N,)."""
    N = len(t)
    dt = np.diff(t, prepend=t[0])
    dt = np.clip(dt, 1e-3, 0.1)
    # jerk (accel time-derivative magnitude) and spin rate for gating
    jerk = np.zeros(N)
    jerk[1:] = np.linalg.norm(np.diff(acc, axis=0), axis=1)/dt[1:]
    accmag = np.linalg.norm(acc, axis=1)
    spin = np.linalg.norm(gyro, axis=1)
    # thresholds: near-1g, low jerk, low spin -> trust accel as gravity
    JERK_TH = 3.0      # m/s^3 (per-sample scaled) -- tuned below via percentile too
    # use a data-adaptive jerk threshold (40th pct) but capped
    JERK_TH = min(JERK_TH, np.percentile(jerk, 40))
    SPIN_TH = 0.35     # rad/s
    MAG_TOL = 0.6      # m/s^2 around G0
    K = 0.04           # correction gain when gated open

    g = np.zeros((N, 3))
    # init from a low-jerk median over first 3s
    m = (t < t[0] + 3.0)
    g_cur = np.median(acc[m], axis=0).astype(float)
    if np.linalg.norm(g_cur) < 1e-3:
        g_cur = np.array([0, 0, G0])
    g[0] = g_cur
    for i in range(1, N):
        w = gyro[i]
        wn = np.linalg.norm(w)
        # propagate gravity in body frame: it rotates by -omega*dt
        if wn > 1e-8:
            g_pred = rodrigues_rotate(g_cur[None, :], (w/wn)[None, :],
                                      np.array([-wn*dt[i]]))[0]
        else:
            g_pred = g_cur.copy()
        gated = (abs(accmag[i]-G0) < MAG_TOL) and (jerk[i] < JERK_TH) and (spin[i] < SPIN_TH)
        if gated:
            g_cur = (1-K)*g_pred + K*acc[i]
        else:
            g_cur = g_pred
        g[i] = g_cur
    gmag = np.linalg.norm(g, axis=1)
    return g, gmag

# ---------------- longitudinal projection via rolling PCA ----------------
def longitudinal_axis(t, h_vec, ghat, hop_s=0.5, win_s=3.0):
    """Rolling-window PCA of horizontal specific force -> per-sample unit long-axis u
    (3D, in body frame, in the level plane). Sign made continuous."""
    N = len(t)
    fs = (N-1)/(t[-1]-t[0])
    hop = max(1, int(round(hop_s*fs)))
    half = max(2, int(round(0.5*win_s*fs)))
    centers = np.arange(0, N, hop)
    axes = np.zeros((len(centers), 3))
    prev = None
    for k, c in enumerate(centers):
        lo = max(0, c-half); hi = min(N, c+half)
        H = h_vec[lo:hi]
        # weight by magnitude so dominant force events define the axis
        Hc = H - H.mean(axis=0)
        C = Hc.T @ Hc
        wv, V = np.linalg.eigh(C)
        u = V[:, -1]
        # force into level plane (perp to local gravity)
        gc = ghat[c]
        u = u - np.dot(u, gc)*gc
        n = np.linalg.norm(u)
        u = u/n if n > 1e-9 else (prev if prev is not None else np.array([1.0,0,0]))
        if prev is not None and np.dot(u, prev) < 0:
            u = -u
        axes[k] = u; prev = u
    # interpolate axis to every sample (nearest center, then renormalize)
    idx = np.clip(np.searchsorted(centers, np.arange(N)), 0, len(centers)-1)
    U = axes[idx]
    U = U / (np.linalg.norm(U, axis=1, keepdims=True)+1e-12)
    return U

# ---------------- GPS load ----------------
def load_gps(base):
    p = os.path.join(FIX, base+"_gps.csv")
    import csv
    t=[];lat=[];lng=[];spd=[]
    with open(p) as f:
        r=csv.DictReader(f)
        for row in r:
            t.append(float(row['t_s'])); lat.append(float(row['lat'])); lng.append(float(row['lng']))
            s=row.get('speed','')
            spd.append(float(s) if s not in (None,'','nan') else np.nan)
    t=np.array(t);lat=np.array(lat);lng=np.array(lng);spd=np.array(spd)
    # fill speed from positions where missing
    v=spd.copy()
    if np.all(np.isnan(v)) or np.isnan(v).any():
        d=haversine(lat[:-1],lng[:-1],lat[1:],lng[1:])
        dt=np.diff(t); vpos=np.concatenate([[0],d/np.clip(dt,1e-3,None)])
        v=np.where(np.isnan(v),vpos,v)
    return t,lat,lng,v

# ---------------- main per-ride ----------------
def process(base):
    print(f"\n{'='*70}\nRIDE: {base}\n{'='*70}")
    meta=json.load(open(os.path.join(FIX,base+".json")))
    imu=np.loadtxt(os.path.join(FIX,base+"_imu.csv"),delimiter=',',skiprows=1)
    t=imu[:,0]; acc=imu[:,1:4]; gyro=imu[:,4:7]
    N=len(t); fs=(N-1)/(t[-1]-t[0])
    print(f"IMU: {N} samples, {t[0]:.2f}..{t[-1]:.2f}s, fs~{fs:.2f} Hz")

    # (2) gravity
    g_body,gmag=estimate_gravity(t,acc,gyro)
    ghat=g_body/gmag[:,None]

    # (3) remove gravity
    resid=acc-g_body                      # linear specific force, body frame
    vert=np.sum(resid*ghat,axis=1)        # signed vertical
    h_vec=resid-vert[:,None]*ghat         # horizontal specific force, body frame

    # Isolate the SUSTAINED horizontal force (train brake/launch lasts ~5-15s),
    # rejecting zero-mean handheld jitter which is higher-frequency. This is the
    # physically-correct band for a train longitudinal force. Vibration energy is
    # captured separately (see vib) so nothing is lost.
    from scipy.signal import butter, filtfilt
    bl,al=butter(2,0.15/(fs/2.0),btype='low')
    h_lp=np.column_stack([filtfilt(bl,al,h_vec[:,k]) for k in range(3)])

    # (4) longitudinal axis via rolling PCA on the SUSTAINED horizontal force
    U=longitudinal_axis(t,h_lp,ghat)
    a_long=np.sum(h_lp*U,axis=1)
    lat_axis=np.cross(ghat,U); lat_axis/= (np.linalg.norm(lat_axis,axis=1,keepdims=True)+1e-12)
    a_lat=np.sum(h_lp*lat_axis,axis=1)

    # sign anchor to GPS d(speed)/dt (outside blind windows)
    gt,glat,glng,gv=load_gps(base)
    blind=np.array(meta['gps_blind_windows_s']) if meta['gps_blind_windows_s'] else np.zeros((0,2))
    # gps speed interp to imu time
    v_imu=np.interp(t,gt,gv)
    dv=np.gradient(v_imu,t)
    good=np.ones(N,bool)
    for b0,b1 in blind:
        good&=~((t>=b0)&(t<=b1))
    # smooth a_long to compare trends
    from scipy.ndimage import uniform_filter1d
    al_s=uniform_filter1d(a_long,int(round(2*fs)))
    dv_s=uniform_filter1d(dv,int(round(2*fs)))
    # Restrict the sign check to samples where the train is genuinely accel/braking
    # per GPS (|dv/dt|>0.25 m/s^2). Over the whole ride both signals are ~0 (cruise),
    # so a full-ride correlation is meaningless; the informative samples are the events.
    evt=good & (np.abs(dv_s)>0.25) & np.isfinite(dv_s)
    corr=np.corrcoef(al_s[evt],dv_s[evt])[0,1] if evt.sum()>20 else 0.0
    if corr<0:
        a_long=-a_long; a_lat=-a_lat; U=-U; corr=-corr
        print(f"sign flip applied -> corr(a_long,dv/dt | train accel events, n={evt.sum()})={corr:.3f}")
    else:
        print(f"sign kept -> corr(a_long,dv/dt | train accel events, n={evt.sum()})={corr:.3f}")

    # (5) vibration + yaw
    vib=butter_highpass_rms(np.linalg.norm(acc,axis=1),fs,fc=4.0,win_s=1.0)
    gyro_yaw=np.sum(gyro*ghat,axis=1)

    # ground truth arrays
    stations=meta['stations']
    station_s=np.array([s['s_travel'] for s in stations])
    station_t=np.array([s['arrival_t_s'] for s in stations])
    poly=np.array(meta['oriented_polyline']); poly_lat=poly[:,0]; poly_lng=poly[:,1]
    seg=haversine(poly_lat[:-1],poly_lng[:-1],poly_lat[1:],poly_lng[1:])
    poly_s=np.concatenate([[0],np.cumsum(seg)])

    out=os.path.join(WORK,base+"_signals.npz")
    np.savez_compressed(out,t=t,a_long=a_long,a_lat=a_lat,vib=vib,gyro_yaw=gyro_yaw,
        gravity_mag=gmag,vert=vert,
        station_s=station_s,station_t=station_t,blind_windows=blind,
        poly_lat=poly_lat,poly_lng=poly_lng,poly_s=poly_s)
    print(f"saved -> {out}")

    # ---------- REPORT ----------
    # gravity cleanliness overall + during station-approach windows
    print(f"\n[gravity] mean={gmag.mean():.3f}  median={np.median(gmag):.3f}  "
          f"std={gmag.std():.3f}  min={gmag.min():.3f}  max={gmag.max():.3f}")
    # cruise median: samples NOT within +-15s of any station and not in blind
    near_st=np.zeros(N,bool)
    for st in station_t:
        near_st|=(np.abs(t-st)<=15)
    cruise=~near_st
    cruise_med=np.median(np.abs(a_long[cruise]))
    print(f"[cruise] ride-wide median |a_long| (excl +-15s of stations) = {cruise_med:.4f} m/s^2")

    print(f"\n[brake-event SNR]  window=+-12s   cruise_med={cruise_med:.4f}")
    snrs=[]; grav_dips=[]; psnrs=[]
    # sustained |a_long| = 4s-smoothed, to measure the multi-second brake, not jitter
    al_sust=uniform_filter1d(np.abs(a_long),int(round(4*fs)))
    cruise_sust=np.median(al_sust[cruise])
    for i,(st_t,st_s) in enumerate(zip(station_t,station_s)):
        w=(np.abs(t-st_t)<=12)
        if w.sum()<5: continue
        med_al=np.median(np.abs(a_long[w]))
        gmin=gmag[w].min(); gmean=gmag[w].mean()
        snr=med_al/cruise_med
        # supplementary: peak sustained brake force in approach->launch window
        wapp=(t>=st_t-15)&(t<=st_t+8)
        peak=al_sust[wapp].max() if wapp.sum() else np.nan
        psnr=peak/cruise_sust
        snrs.append(snr); grav_dips.append(gmin); psnrs.append(psnr)
        print(f"  st{i:2d} t={st_t:7.1f}s s={st_s:8.1f}m  med|a_long|={med_al:.4f}  "
              f"SNR={snr:5.2f}x  peakSust={peak:.3f}({psnr:4.1f}x)  grav[min={gmin:.3f} mean={gmean:.3f}]")
    snrs=np.array(snrs); psnrs=np.array(psnrs)
    print(f"  [supplementary] peak-sustained |a_long| SNR: median={np.median(psnrs):.2f}x "
          f"mean={psnrs.mean():.2f}x min={psnrs.min():.2f}x max={psnrs.max():.2f}x "
          f"(#>2x: {(psnrs>2).sum()}/{len(psnrs)})  cruise_sust={cruise_sust:.4f}")
    print(f"\n  SNR summary: median={np.median(snrs):.2f}x  mean={snrs.mean():.2f}x  "
          f"min={snrs.min():.2f}x  max={snrs.max():.2f}x  "
          f"(#stations with SNR>1.5: {(snrs>1.5).sum()}/{len(snrs)})")
    print(f"  gravity during station approaches: min-over-all={min(grav_dips):.3f} "
          f"(clean if ~{G0}, NOT dipping toward 8-9 which would signal brake leak)")
    return dict(base=base,t=t,a_long=a_long,gmag=gmag,station_t=station_t,station_s=station_s,
                cruise_med=cruise_med,snrs=snrs,blind=blind,vib=vib,gyro_yaw=gyro_yaw,fs=fs)

if __name__=="__main__":
    res=[process(b) for b in RIDES]
    # plots
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    for r in res:
        fig,ax=plt.subplots(3,1,figsize=(14,9),sharex=True)
        t=r['t']
        ax[0].plot(t,r['a_long'],lw=0.4,color='tab:blue'); ax[0].set_ylabel('a_long m/s^2')
        ax[0].axhline(0,color='k',lw=0.3)
        for st in r['station_t']: ax[0].axvline(st,color='r',alpha=0.35,lw=0.8)
        ax[0].set_title(f"{r['base']}  (red=true station arrivals)")
        ax[1].plot(t,r['gmag'],lw=0.5,color='tab:green'); ax[1].axhline(G0,color='k',lw=0.4,ls='--')
        ax[1].set_ylabel('gravity |g| m/s^2'); ax[1].set_ylim(9.0,10.6)
        for st in r['station_t']: ax[1].axvline(st,color='r',alpha=0.35,lw=0.8)
        ax[2].plot(t,r['vib'],lw=0.4,color='tab:purple'); ax[2].set_ylabel('vib RMS')
        for b0,b1 in r['blind']: ax[2].axvspan(b0,b1,color='orange',alpha=0.2)
        ax[2].set_xlabel('t (s)')
        fig.tight_layout()
        png=os.path.join(WORK,r['base']+"_signals.png")
        fig.savefig(png,dpi=90); print("plot ->",png)
