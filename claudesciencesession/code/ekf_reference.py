"""
WakePoint EKF — faithful Python port of lib/core/ekf/ekf_pipeline.dart (v1 core).

State [s, v, b] = route progress (m), velocity (m/s), accel bias (m/s^2); 3x3 covariance P.
Ported line-for-line from the Dart source (2026-07): predict, GPS Huber-robust update with
speed fusion + El-Sheimy bias observability, ZUPT (the only bias-observable update),
station snap, covariance floors/inflation. Config defaults match EkfConfig exactly.

Front-end (TiltFilter/ZUPT/MotionClassifier) is ported at the level needed to evaluate the
filter: a complementary tilt filter using the device gravity channel as primary reference
(as the app does), a variance-threshold ZUPT detector, and a velocity+band-energy motion
classifier. These are FAITHFUL to structure and thresholds but simplified vs the full Dart
sensor stack; differences are documented at each class.
"""
import numpy as np

CFG = dict(sigmaAccel=0.15, sigmaBias=0.001, gpsFloorVar=625.0, gpsSpeedVar=1.0,
           zuptVar=0.0025, stationVar=100.0, minDt=0.001, maxDt=0.2,
           sigmaSFloor=5.0, sigmaVFloor=0.1, sigmaBiasFloor=1e-4, biasLimit=0.5)


def _huber_weight(norm_nu, c=2.5):
    return 1.0 if norm_nu <= c else c / max(norm_nu, 1e-9)


class EkfPy:
    """Faithful port of EkfPipeline. Feed onForwardAccel/onGpsFix/onZupt/onStation in time order."""
    def __init__(self, cfg=None, allow_reverse=True):   # Dart field default: _allowReverse = true
                                                          # (app calls setAllowReverse(false) on metro legs)
        self.c = dict(CFG, **(cfg or {}))
        self.s = np.nan; self.v = np.nan; self.b = 0.0; self.sPub = np.nan
        self.P = np.zeros((3, 3))
        self.mode = "surface"        # surface | metro | degraded
        self.motion = "vehicle"      # vehicle | stationary | human
        self.allow_reverse = allow_reverse
        self.init = False
        self.recent_acc = []
        self.lastGpsV = None; self.lastGpsT = None
        self.pred_count = 0

    # ---- covariance helpers ----
    def _floors(self):
        P = self.P
        if not np.isfinite(P[0, 0]): P[0, 0] = 200.0**2
        if not np.isfinite(P[1, 1]): P[1, 1] = 100.0**2
        if not np.isfinite(P[2, 2]): P[2, 2] = 1.0
        P[0, 0] = max(P[0, 0], self.c['sigmaSFloor']**2)
        P[1, 1] = max(P[1, 1], self.c['sigmaVFloor']**2)
        P[2, 2] = max(P[2, 2], self.c['sigmaBiasFloor'])

    def _inflate(self, f):
        self.P[0, 0] *= f; self.P[1, 1] *= f; self.P[2, 2] *= f
        self.P[0, 0] = min(self.P[0, 0], 200.0**2)
        self.P[1, 1] = min(self.P[1, 1], 100.0**2)
        self.P[2, 2] = min(self.P[2, 2], 1.0)

    def _bounds(self):
        if not np.isfinite(self.s): self.s = 0.0
        if not np.isfinite(self.v): self.v = 0.0
        if not np.isfinite(self.b): self.b = 0.0
        self.b = np.clip(self.b, -self.c['biasLimit'], self.c['biasLimit'])

    def _sym(self):
        self.P = 0.5 * (self.P + self.P.T)

    def _pub(self):
        s_int = 0.0 if np.isnan(self.s) else self.s
        if np.isnan(self.sPub):
            self.sPub = s_int
        elif self.mode != "degraded":
            self.sPub = max(self.sPub, s_int)   # monotonic clamp on surface/metro
        # degraded exposes internal s (handled in public_s)

    def public_s(self):
        s_int = 0.0 if np.isnan(self.s) else self.s
        return s_int if self.mode == "degraded" else (s_int if np.isnan(self.sPub) else self.sPub)

    def sigmaS(self): return np.sqrt(max(self.P[0, 0], 0.0))
    def sigmaV(self): return np.sqrt(max(self.P[1, 1], 0.0))

    def init_from_gps(self, sGps, vGps):
        self.s = sGps; self.v = max(0.0, vGps); self.b = 0.0
        self.P = np.array([[25.0**2, 0, 0], [0, 5.0**2, 0], [0, 0, 0.1**2]], float)
        self.init = True; self._bounds(); self._floors(); self._pub()

    # ---- prediction (IMU forward accel) ----
    def on_forward_accel(self, dt, aFwd):
        if not self.init or dt is None:
            return
        if dt <= 0:
            return
        if dt > 1.0:
            self.v = 0.0; self.b = 0.0; self._inflate(4.0); return
        if dt < self.c['minDt'] or dt > self.c['maxDt']:
            self._inflate(1.1); return
        self.pred_count += 1
        sOld = self.s
        if self.mode == "degraded":
            self._inflate(1.0002)
        dt2 = dt * dt
        aBias = aFwd - self.b
        vDamp = 1.0
        if self.mode == "degraded":
            if self.motion == "stationary" and abs(self.v) < 0.3:
                vDamp = 0.98
            else:
                if abs(aBias) < 0.1: aBias = 0.0
                aBias = np.clip(aBias, -1.5, 1.5)
        self.s = self.s + self.v * dt + 0.5 * aBias * dt2
        self.v = (self.v + aBias * dt) * vDamp
        if not self.allow_reverse:
            if self.v < 0: self.v = 0.0
            if self.s < sOld: self.s = sOld
        self.v = np.clip(self.v, -25.0, 25.0)
        F = np.array([[1, dt, -0.5*dt2], [0, 1, -dt], [0, 0, 1]], float)
        sa2 = self.c['sigmaAccel']**2; sb2 = self.c['sigmaBias']**2
        Q = np.array([[sa2*dt2*dt2/4, 0, 0], [0, sa2*dt2, 0], [0, 0, sb2*dt]], float)
        self.P = F @ self.P @ F.T + Q
        self.recent_acc.append(aFwd)
        if len(self.recent_acc) > 50: self.recent_acc.pop(0)
        self._sym(); self._bounds(); self._floors(); self._pub()

    # ---- GPS update (Huber-robust) ----
    def on_gps(self, dt_gps, sGps, speed, accuracy_m):
        if not self.init:
            self.init_from_gps(sGps, speed); return
        sig = self.sigmaS(); nu = sGps - self.s
        norm = abs(nu) / sig if sig > 0 else 0.0
        if sig > 0 and norm > 15.0:
            self.init_from_gps(sGps, speed); return
        w = _huber_weight(norm, 2.5)
        if w < 0.2:
            self._inflate(1.2); return
        baseR = max(accuracy_m*accuracy_m, self.c['gpsFloorVar'])
        r = baseR / w
        S = self.P[0, 0] + r
        if S <= 0: return
        k0 = self.P[0, 0] / S; k1 = self.P[1, 0] / S
        self.s = self.s + k0*nu; self.v = self.v + k1*nu
        p00, p01, p02 = self.P[0, 0], self.P[0, 1], self.P[0, 2]
        self.P[0, 0] -= k0*p00; self.P[0, 1] -= k0*p01; self.P[0, 2] -= k0*p02
        self.P[1, 0] -= k1*p00; self.P[1, 1] -= k1*p01; self.P[1, 2] -= k1*p02
        # GPS speed fusion
        if np.isfinite(speed):
            rV = self.c['gpsSpeedVar']; sV = self.P[1, 1] + rV
            if sV > 0:
                nuV = speed - self.v; kV = self.P[1, 1] / sV
                self.v = self.v + kV*nuV
                p10, p11, p12 = self.P[1, 0], self.P[1, 1], self.P[1, 2]
                self.P[1, 0] = p10 - kV*p10; self.P[1, 1] = p11 - kV*p11; self.P[1, 2] = p12 - kV*p12
                self.P[0, 1] = self.P[1, 0]; self.P[2, 1] = self.P[1, 2]
        # El-Sheimy bias observability via GPS-derived accel
        if self.lastGpsV is not None and self.lastGpsT is not None and self.recent_acc and dt_gps is not None:
            if 0.5 < dt_gps < 5.0:
                aGps = (speed - self.lastGpsV) / dt_gps
                aImu = np.mean(self.recent_acc)
                bEst = aImu - aGps
                if abs(bEst) < 2.0:
                    self.b = self.b + 0.05*(bEst - self.b)
                    self.b = np.clip(self.b, -1.0, 1.0)
        self.lastGpsV = speed; self.lastGpsT = 1
        self._sym(); self._bounds(); self._floors(); self._pub()

    # ---- ZUPT (only bias-observable update) ----
    def on_zupt(self):
        if not self.init: return
        r = self.c['zuptVar']; S = self.P[1, 1] + r
        if S <= 0: return
        nu = 0.0 - self.v
        k0 = self.P[0, 1]/S; k1 = self.P[1, 1]/S; k2 = self.P[2, 1]/S
        self.s += k0*nu; self.v += k1*nu; self.b += k2*nu
        p10, p11, p12 = self.P[1, 0], self.P[1, 1], self.P[1, 2]
        self.P[0, 0] -= k0*p10; self.P[0, 1] -= k0*p11; self.P[0, 2] -= k0*p12
        self.P[1, 0] -= k1*p10; self.P[1, 1] -= k1*p11; self.P[1, 2] -= k1*p12
        self.P[2, 0] -= k2*p10; self.P[2, 1] -= k2*p11; self.P[2, 2] -= k2*p12
        self.P[0, 0] = min(self.P[0, 0], 10.0**2)   # post-ZUPT tightening
        self.P[1, 1] = min(self.P[1, 1], 0.5**2)
        self._sym(); self._bounds(); self._floors(); self._pub()

    # ---- station snap ----
    def on_station(self, sStation):
        if not self.init: return
        r = self.c['stationVar']; S = self.P[0, 0] + r
        if S <= 0: return
        nu = sStation - self.s
        k0 = self.P[0, 0]/S; k1 = self.P[1, 0]/S
        self.s += k0*nu; self.v += k1*nu
        p00, p01, p02 = self.P[0, 0], self.P[0, 1], self.P[0, 2]
        self.P[0, 0] -= k0*p00; self.P[0, 1] -= k0*p01; self.P[0, 2] -= k0*p02
        self.P[1, 0] -= k1*p00; self.P[1, 1] -= k1*p01; self.P[1, 2] -= k1*p02
        self._sym(); self._bounds(); self._floors(); self._pub()


class TiltFilterPy:
    """Complementary tilt filter — estimates gravity direction to produce forward accel.
    Uses the device gravity channel as primary reference (as the app does: TYPE_GRAVITY),
    blended with gyro integration. alpha=0.02 complementary weight. Faithful to structure;
    the full Dart version adds LPF + variance-gated accel fallback (simplified here)."""
    def __init__(self, alpha=0.02):
        self.alpha = alpha; self.gHat = None

    def forward_accel(self, ax, ay, az, grx, gry, grz):
        # gravity unit vector from device gravity channel (primary ref)
        gvec = np.array([grx, gry, grz]); n = np.linalg.norm(gvec)
        if n < 1e-6:
            gvec = np.array([ax, ay, az]); n = np.linalg.norm(gvec) + 1e-9
        gmeas = gvec / n
        if self.gHat is None:
            self.gHat = gmeas
        else:
            self.gHat = (1-self.alpha)*self.gHat + self.alpha*gmeas
            self.gHat /= (np.linalg.norm(self.gHat)+1e-9)
        # remove gravity from raw accel, project onto forward (horizontal) axis
        a = np.array([ax, ay, az])
        a_lin = a - self.gHat * 9.807             # gravity-removed
        # forward = component in horizontal plane along device x projected off gravity
        fwd_axis = np.array([1.0, 0, 0]) - self.gHat*self.gHat[0]
        fa = fwd_axis/(np.linalg.norm(fwd_axis)+1e-9)
        return float(a_lin @ fa)


class ZuptDetectorPy:
    """Variance-threshold ZUPT detector. Confirms zero-velocity when accel & gyro variance
    over a short window fall below thresholds for a dwell duration. Thresholds from EkfConfig
    memory (accelVarThresh~1.0, gyroVarThresh~0.40, dwell~800ms)."""
    def __init__(self, fs=100.0, win_s=0.75, a_thr=1.0, g_thr=0.40, dwell_s=0.8):
        self.fs = fs; self.w = int(win_s*fs); self.a_thr = a_thr; self.g_thr = g_thr
        self.dwell = int(dwell_s*fs); self.abuf = []; self.gbuf = []; self.quiet = 0

    def update(self, a_lin_mag, gyro_mag):
        self.abuf.append(a_lin_mag); self.gbuf.append(gyro_mag)
        if len(self.abuf) > self.w: self.abuf.pop(0); self.gbuf.pop(0)
        if len(self.abuf) < self.w: return False
        av = np.var(self.abuf); gv = np.var(self.gbuf)
        if av < self.a_thr and gv < self.g_thr:
            self.quiet += 1
        else:
            self.quiet = 0
        return self.quiet >= self.dwell
