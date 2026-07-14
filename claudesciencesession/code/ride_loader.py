"""
WakePoint Phase 0 — Faithful ride loader for Sensor Logger exports.

Key correctness decisions (validated against docs/Sandalsoap-whitefield/ 2026-07):
  * The app feeds RAW accelerometer to the EKF and removes gravity internally
    (ekf_orchestrator.dart:695: ax = sample.ax - g*9.81). So replay must feed RAW.
  * Raw accel is reconstructed at the full 100 Hz as (Accelerometer[linear] + Gravity),
    NOT taken from TotalAcceleration.csv which logs at only 57 Hz.
    Reconstruction matches logged raw to ~0.08 m/s^2 median.
  * Gyroscope is only logged at ~57 Hz (irregular); it is resampled by nearest onto
    the master grid. dt-jitter is real and must be preserved in any synthesizer.
  * The first Accelerometer row (0,0,0) is a garbage sample and is dropped.
  * GPS (1 Hz) is forward-filled with a freshness flag; gps_fresh==0 marks GPS-denied
    segments (the labeled test regions). Max blackout in the ref ride = 388 s.

Usage:
    from ride_loader import load_ride
    df, meta = load_ride("docs/Sandalsoap-whitefield/")
"""
import os, numpy as np, pandas as pd


def load_ride(ride_dir, target_hz=100.0, reconstruct_raw=True):
    L = lambda f: pd.read_csv(os.path.join(ride_dir, f)).sort_values("seconds_elapsed")
    lin  = L("Accelerometer.csv").reset_index(drop=True)   # linear (gravity removed), 100 Hz
    grav = L("Gravity.csv")                                 # 100 Hz
    gyr  = L("Gyroscope.csv")                               # ~57 Hz irregular
    ori  = L("Orientation.csv")                             # fused quaternion, 100 Hz
    loc  = L("Location.csv")                                # 1 Hz

    # drop leading (0,0,0) garbage row(s)
    zero = (lin.x == 0) & (lin.y == 0) & (lin.z == 0)
    n_drop = int((zero & (lin.index < 5)).sum())
    lin = lin[~((lin.index < 5) & zero)].reset_index(drop=True)

    t0, t1 = lin.seconds_elapsed.iloc[0], lin.seconds_elapsed.iloc[-1]
    base = pd.DataFrame({"t": np.arange(t0, t1, 1.0 / target_hz)})

    def attach(df, cols, tol):
        d = df.rename(columns={"seconds_elapsed": "t"})[["t"] + cols].sort_values("t")
        return pd.merge_asof(base, d, on="t", direction="nearest", tolerance=tol)[cols]

    out = base.copy()
    lin_g = attach(lin,  ["x", "y", "z"], 1.5 / target_hz).rename(columns={"x": "lx", "y": "ly", "z": "lz"})
    grv_g = attach(grav, ["x", "y", "z"], 1.5 / target_hz).rename(columns={"x": "grx", "y": "gry", "z": "grz"})
    out[["lx", "ly", "lz"]]    = lin_g
    out[["grx", "gry", "grz"]] = grv_g
    if reconstruct_raw:                       # RAW = linear + gravity, full 100 Hz
        out["ax"] = out.lx + out.grx
        out["ay"] = out.ly + out.gry
        out["az"] = out.lz + out.grz
    out[["gx", "gy", "gz"]] = attach(gyr, ["x", "y", "z"], 2.0 / target_hz)  # gyro 57 Hz -> wider tol
    for q in ["qx", "qy", "qz", "qw", "yaw", "pitch", "roll"]:
        if q in ori.columns:
            out[q] = attach(ori, [q], 1.5 / target_hz)[q]

    g = loc[["seconds_elapsed", "latitude", "longitude", "speed", "horizontalAccuracy", "bearing"]] \
        .rename(columns={"seconds_elapsed": "t"})
    gm = pd.merge_asof(base, g.sort_values("t"), on="t", direction="backward")
    last = pd.merge_asof(base, loc[["seconds_elapsed"]].rename(columns={"seconds_elapsed": "t"})
                         .assign(fixt=loc.seconds_elapsed.values).sort_values("t"),
                         on="t", direction="backward")["fixt"]
    out["gps_lat"] = gm.latitude; out["gps_lon"] = gm.longitude; out["gps_speed"] = gm.speed
    out["gps_acc"] = gm.horizontalAccuracy; out["gps_age"] = out.t - last
    out["gps_fresh"] = (out.gps_age < 1.5).astype(int)

    meta = dict(ride=os.path.basename(ride_dir.rstrip("/")), target_hz=target_hz,
                raw_source="reconstructed(linear+gravity)" if reconstruct_raw else "TotalAcceleration",
                n_grid=len(out), dur_s=float(t1 - t0), garbage_rows_dropped=n_drop,
                gps_blackout_max_s=float(out.gps_age.max()),
                frac_gps_stale=float((out.gps_fresh == 0).mean()))
    return out, meta
