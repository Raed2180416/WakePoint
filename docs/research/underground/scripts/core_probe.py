#!/usr/bin/env python3
"""Core hands-on probe: how close is a stop-anchored estimate to true position
when GPS is dark, on the REAL Bengaluru rides? Independent check of the workflow."""
import json, math, sys
import numpy as np

FIX = "/home/raed/geowake_imu_analysis/fixtures"

def load(base):
    d = json.load(open(f"{FIX}/{base}.json"))
    imu = np.genfromtxt(f"{FIX}/{base}_imu.csv", delimiter=",", names=True)
    t = imu["t_s"].astype(float)
    acc = np.vstack([imu["ax"], imu["ay"], imu["az"]]).T.astype(float)
    gyr = np.vstack([imu["gx"], imu["gy"], imu["gz"]]).T.astype(float)
    st = d["stations"]
    s_st = np.array([s["s_travel"] for s in st], float)
    t_st = np.array([s["arrival_t_s"] for s in st], float)
    bw = np.array(d.get("gps_blind_windows_s", []), float).reshape(-1, 2)
    return d, t, acc, gyr, s_st, t_st, bw

def mahony(t, acc, gyr, kp=1.0, ki=0.02):
    """Minimal Mahony complementary filter -> gravity direction in body frame.
    Returns g_body unit vectors per sample (the estimated 'down' direction)."""
    n = len(t)
    q = np.array([1.0, 0, 0, 0])  # w,x,y,z
    eint = np.zeros(3)
    gdir = np.zeros((n, 3))
    def qmul(a, b):
        w1, x1, y1, z1 = a; w2, x2, y2, z2 = b
        return np.array([w1*w2-x1*x2-y1*y2-z1*z2,
                         w1*x2+x1*w2+y1*z2-z1*y2,
                         w1*y2-x1*z2+y1*w2+z1*x2,
                         w1*z2+x1*y2-y1*x2+z1*w2])
    for i in range(n):
        dt = t[i]-t[i-1] if i > 0 else 0.02
        if not (0 < dt < 0.5): dt = 0.02
        a = acc[i].copy()
        na = np.linalg.norm(a)
        w = gyr[i].copy()
        if na > 1e-6:
            a /= na
            # estimated gravity dir from current quaternion (body frame)
            w0, x, y, z = q
            v = np.array([2*(x*z - w0*y), 2*(w0*x + y*z), w0*w0 - x*x - y*y + z*z])
            e = np.cross(a, v)  # error between measured & estimated gravity
            # only trust accel as gravity when specific force ~ g (low horizontal accel)
            trust = math.exp(-((na-9.81)/2.0)**2)
            eint += ki*e*dt*trust
            w = w + kp*e*trust + eint
        # integrate quaternion
        qdot = 0.5*qmul(q, np.array([0.0, w[0], w[1], w[2]]))
        q = q + qdot*dt
        q /= np.linalg.norm(q)
        w0, x, y, z = q
        gdir[i] = np.array([2*(x*z - w0*y), 2*(w0*x + y*z), w0*w0 - x*x - y*y + z*z])
    return gdir

def ground_truth_s(tq, t_st, s_st):
    return np.interp(tq, t_st, s_st, left=s_st[0], right=s_st[-1])

def analyze(base):
    d, t, acc, gyr, s_st, t_st, bw = load(base)
    n = len(t); fs = n/(t[-1]-t[0])
    gdir = mahony(t, acc, gyr)
    # horizontal specific force = accel minus gravity component (in body frame,
    # projected off the gravity direction). |accel| includes g; subtract g*gdir.
    grav = 9.81*gdir
    sf = acc - grav                     # specific force (motion accel) body frame
    a_par = np.sum(sf*gdir, axis=1)     # vertical component (along gravity)
    horiz = sf - a_par[:, None]*gdir    # horizontal specific force vector (body)
    hmag = np.linalg.norm(horiz, axis=1)
    # longitudinal axis via PCA of horizontal force over the whole ride (dominant
    # track direction in the yaw-free body-level frame). Signed a_long.
    H = horiz - horiz.mean(axis=0)
    u, s_, vt = np.linalg.svd(H, full_matrices=False)
    axis = vt[0]
    a_long = H @ axis                   # signed longitudinal specific force
    # 6s smoothing (sustained brake/launch)
    win = int(6*fs) | 1
    kern = np.ones(win)/win
    a_long_s = np.convolve(a_long, kern, mode="same")
    hmag_s = np.convolve(hmag, kern, mode="same")

    # brake-SNR at true stations
    def near_station(ti):
        return min(abs(t_st - ti)) <= 12
    stop_mask = np.array([near_station(ti) for ti in t])
    cruise_med = np.median(hmag_s[~stop_mask])
    stop_med = np.median(hmag_s[stop_mask])

    # crude stop detector: a "station event" = a sustained-|a_long| peak that
    # exceeds 1.6x cruise within +-15s of... we DON'T know stations, so detect
    # local maxima of hmag_s separated by >=40s above 1.6x cruise.
    thr = 1.6*cruise_med
    cand = []
    i = 0
    while i < n:
        if hmag_s[i] > thr:
            j = i
            while j < n and hmag_s[j] > thr: j += 1
            peak = i + int(np.argmax(hmag_s[i:j]))
            cand.append(t[peak]); i = j
        else:
            i += 1
    # merge events within 25s
    ev = []
    for c in cand:
        if not ev or c-ev[-1] > 25: ev.append(c)
    # match detected events to true stations (within 15s)
    matched = sum(1 for ts in t_st if any(abs(e-ts) <= 15 for e in ev))
    print(f"\n=== {base[:40]} ===  fs~{fs:.0f}Hz  {len(t_st)} stations  {len(bw)} blind-windows")
    print(f"  horizontal specific force: cruise med={cruise_med:.3f}  station med={stop_med:.3f}  ratio={stop_med/max(1e-6,cruise_med):.2f}x")
    print(f"  brake-event detector: {len(ev)} events, matched {matched}/{len(t_st)} true stations (recall {matched/len(t_st)*100:.0f}%)")

    # POSITION THROUGH BLIND WINDOWS: compare estimators vs ground truth
    V_LINE = 28.0
    errs_naive, errs_cone, errs_anchor = [], [], []
    for (w0, w1) in bw:
        if w1-w0 < 3: continue
        s0 = ground_truth_s(w0, t_st, s_st)      # true s at window start (had a fix)
        s1_true = ground_truth_s(w1, t_st, s_st) # true s at window end
        # velocity just before window from ground truth slope
        dtv = 5.0
        v0 = (ground_truth_s(w0, t_st, s_st)-ground_truth_s(w0-dtv, t_st, s_st))/dtv
        v0 = max(0.0, v0)
        dur = w1-w0
        # A) naive constant-velocity DR
        s_naive = s0 + v0*dur
        # B) reachability cone TOP (upper bound; over-estimate = how early)
        s_cone = s0 + V_LINE*dur
        # C) stop-anchored: if a detected brake event falls in the window, snap to
        #    the nearest station's s_travel; else fall back to naive.
        evin = [e for e in ev if w0 <= e <= w1]
        if evin:
            # nearest station to the last event in window
            e = evin[-1]
            k = int(np.argmin(abs(t_st - e)))
            s_anchor = s_st[k] + max(0.0, (w1-e))*v0*0.3  # small coast after stop
        else:
            s_anchor = s_naive
        errs_naive.append(abs(s_naive - s1_true))
        errs_cone.append(s_cone - s1_true)  # signed: how far above true (early)
        errs_anchor.append(abs(s_anchor - s1_true))
    def med(x): return float(np.median(x)) if x else float('nan')
    def mx(x): return float(np.max(x)) if x else float('nan')
    print(f"  BLIND-WINDOW position error vs ground truth ({len(errs_naive)} windows):")
    print(f"    (A) naive const-vel DR : median {med(errs_naive):6.0f} m   max {mx(errs_naive):6.0f} m")
    print(f"    (B) reachability cone  : median over-est {med(errs_cone):6.0f} m   max {mx(errs_cone):6.0f} m  (this is the 'fires early' gap)")
    print(f"    (C) stop-anchored      : median {med(errs_anchor):6.0f} m   max {mx(errs_anchor):6.0f} m")

for base in ["fixture_Nallur_to_Vijaynagar",
             "fixture_Nadaprabhu_Kempegowda_Metro_Station_Majestic-2025-12-21_07-35-32"]:
    analyze(base)
