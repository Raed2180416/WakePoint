# EKF Mathematical Specification

**Date:** 2026-01-16  
**Status:** Locked - Complete mathematical formalization

---

## Purpose

This document provides explicit mathematical specification for all EKF operations. The implementation plan describes procedures; this document provides the mathematical foundation.

---

## Units & Conventions

- Acceleration: m/s²
- Acceleration variance: (m/s²)²
- Gyroscope: rad/s
- Gyroscope variance: (rad/s)²
- Distance: meters
- Velocity: m/s
- Time: seconds

---

## State Vector

$$x = \begin{bmatrix} s \\ v \\ b_a \end{bmatrix}$$

Where:
- $s$ = distance along route (meters)
- $v$ = velocity along route (m/s)
- $b_a$ = accelerometer bias (m/s²)

---

## Process Model (Prediction)

### State Transition

$$x_{k+1} = f(x_k, u_k, dt) = \begin{bmatrix}
s_k + v_k dt + 0.5(a_{fwd} - b_{a,k})dt^2 \\
v_k + (a_{fwd} - b_{a,k})dt \\
b_{a,k}
\end{bmatrix}$$

Where:
- $a_{fwd} = \text{dot}(a_{world}, t(s_k))$ (acceleration projected onto route tangent)
- $a_{world} = R_{device \rightarrow world} \cdot a_{device} - g$ (gravity-removed, world-frame accel)
- $t(s_k)$ = route tangent unit vector at position $s_k$ (interpolated at boundaries per §3.4)

### Process Noise Covariance

$$Q = \begin{bmatrix}
Q_s & 0 & 0 \\
0 & Q_v & 0 \\
0 & 0 & Q_{bias}
\end{bmatrix}$$

Where:
- $Q_s = \sigma_{accel}^2 dt^4 / 4$ (position noise)
- $Q_v = \sigma_{accel}^2 dt^2$ (velocity noise)
- $Q_{bias} = \sigma_{bias}^2 dt$ (bias random walk)

Dynamic scaling:
- GPS degraded: $Q \leftarrow Q \times 1.5$
- HUMAN motion: $Q_v \leftarrow Q_v \times 0.1$ (freeze velocity)
- ZUPT overdue: $Q_{bias} \leftarrow Q_{bias} \times 2.0$

### Covariance Prediction

$$P_{k+1} = F P_k F^T + Q$$

Where $F$ is the Jacobian of $f$:

$$F = \begin{bmatrix}
1 & dt & -0.5 dt^2 \\
0 & 1 & -dt \\
0 & 0 & 1
\end{bmatrix}$$

---

## Measurement Models

### GPS Update

**Measurement:**
$$z_{gps} = [s_{gps}]$$

**Measurement Matrix:**
$$H_{gps} = \begin{bmatrix} 1 & 0 & 0 \end{bmatrix}$$

**Innovation:**
$$\nu = s_{gps} - s_{est}$$

**Innovation Covariance:**
$$S = H_{gps} P H_{gps}^T + R_{gps}$$

Where $R_{gps} = \max(accuracy^2, 25^2)$ m²

**Kalman Gain:**
$$K = P H_{gps}^T S^{-1}$$

**State Update:**
$$x = x + K \nu$$

**Covariance Update:**
$$P = (I - K H_{gps}) P$$

**Innovation Gate:**
- Reject if $|\nu| > 3\sigma_s$ (soft rejection)
- Hard reset if $|\nu| > 5\sigma_s$ (reinitialize state)

---

### ZUPT Velocity Update

**Measurement:**
$$z_{zupt} = [0]$$ (zero velocity)

**Measurement Matrix:**
$$H_{zupt} = \begin{bmatrix} 0 & 1 & 0 \end{bmatrix}$$

**Innovation:**
$$\nu = 0 - v_{est}$$

**Innovation Covariance:**
$$S = H_{zupt} P H_{zupt}^T + R_{v,zupt}$$

Where $R_{v,zupt} = (0.05 \text{ m/s})^2$

**Kalman Gain:**
$$K = P H_{zupt}^T S^{-1}$$

**State Update:**
$$x = x + K \nu$$

This updates:
- $v$ directly (via $K[1]$)
- $b_a$ indirectly (via cross-covariance $P[2,1]$)

**Covariance Update:**
$$P = (I - K H_{zupt}) P$$

---

### Station Snap Update

**Measurement:**
$$z_{station} = [s_{station}]$$

**Measurement Matrix:**
$$H_{station} = \begin{bmatrix} 1 & 0 & 0 \end{bmatrix}$$

**Innovation:**
$$\nu = s_{station} - s_{est}$$

**Innovation Covariance:**
$$S = H_{station} P H_{station}^T + R_{station}$$

Where $R_{station} = (10 \text{ m})^2$

**Kalman Gain:**
$$K = P H_{station}^T S^{-1}$$

**State Update:**
$$x = x + K \nu$$ (soft update, not hard reset)

**Covariance Update:**
$$P = (I - K H_{station}) P$$

**Preconditions:**
- Single candidate within $3\sigma_s + 50$ m
- ZUPT dwell ≥ 20 s
- Metro leg active

---

## State Bounds

### Position Bounds
- $s \ge s_{prev}$ (monotonic clamping: $s_{pub} = \max(s_{prev}, s_{est})$)
- Exception: Allow backward if GPS confirms reverse motion

### Velocity Bounds
- $-5 \text{ m/s} \le v \le 50 \text{ m/s}$ (reasonable range)
- Clamp on update if exceeded

### Bias Bounds (Locked)
- $|b_a| \le 0.5$ m/s² (hard saturation)
- Clamp on update if exceeded

---

## Covariance Bounds

### Floors
- $\sigma_s \ge 5$ m
- $\sigma_v \ge 0.1$ m/s
- $\sigma_{bias} \ge 1 \times 10^{-4}$ (m/s²)²

### Ceilings
- If $\sigma_s > 300$ m → force DEGRADED mode
- If $\sigma_v > 10$ m/s → inflate covariance

### Enforcement
- Apply floors/ceilings after each update
- Log violations for diagnostics

---

## Initialization

### With GPS
$$x_0 = \begin{bmatrix}
s_{gps} \\
\max(v_{gps\_proj}, 0) \\
0
\end{bmatrix}$$

$$P_0 = \begin{bmatrix}
25^2 & 0 & 0 \\
0 & 5^2 & 0 \\
0 & 0 & 0.1^2
\end{bmatrix}$$

### Without GPS
- $x_0$ = invalid (NaN)
- $P_0$ = inflated (diag(1000², 100², 1²))
- Prediction disabled until first GPS or ZUPT

---

## Route Tangent Interpolation

At segment boundaries where $|s - s_{boundary}| < \Delta s$ (default $\Delta s = 7.5$ m):

$$t(s) = w_1 t_{left}(s) + w_2 t_{right}(s)$$

Where:
- $w_1 = 1 - \frac{|s - s_{boundary}|}{\Delta s}$
- $w_2 = 1 - w_1$
- Weights clamped to [0, 1]

This ensures smooth $a_{fwd} = \text{dot}(a_{world}, t(s))$ projection.

---

## Motion Classifier Feedback

EKF confidence biases motion classifier:

**STATIONARY bias:**
- If $\sigma_v < 0.15$ m/s AND recent ZUPT (within 5 s) → bias weight = 0.3

**VEHICLE suppression:**
- If innovation consistently high (> 3σ) for > 10 s → suppress VEHICLE classification

**Implementation:**
- Classifier uses: $0.7 \times \text{IMU features} + 0.3 \times \text{EKF confidence}$
- Does not override IMU, only biases

---

## Alarm Logic Timing

Alarm evaluation samples $(s_{pub}, \sigma_s)$ at **alarm evaluation tick** (not IMU tick).

**Trigger:**
$$s_{pub} + k \sigma_s \ge s_{target}$$

Where:
- $k = 2.0$ (normal mode)
- $k = 3.0$ (degraded mode)
- $k = 4.0$ (hard degraded mode)

**Sampling:**
- EKF maintains public state updated at IMU rate
- Alarm logic reads snapshot at evaluation time
- Ensures $s_{pub}$ and $\sigma_s$ are consistent

---

## Summary

This specification provides:
1. ✅ Explicit measurement models (GPS, ZUPT, station snap)
2. ✅ Tangent continuity rule (interpolation at boundaries)
3. ✅ Bidirectional EKF ↔ Motion classifier feedback
4. ✅ Bias bounds (magnitude and covariance floors)
5. ✅ Alarm logic timing specification
6. ✅ Complete mathematical formalization

**Status:** Locked and ready for implementation
