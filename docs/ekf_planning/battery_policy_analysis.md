# Battery Policy & Robustness Analysis

## 1. Current Policy Review
The application relies on `PowerPolicy` to configure `Geolocator`.

| Battery Level | Accuracy | Distance Filter | Implied Max Latency (walking 1m/s) |
| :--- | :--- | :--- | :--- |
| **> 50%** | High | 5 meters | ~5 seconds |
| **20% - 50%** | Medium | 15 meters | ~15 seconds |
| **< 20%** | Low | **50 meters** | **~50 seconds** |

## 2. Failure Scenarios

### Scenario A: The "Low Battery Walk" (Critical Risk)
**Context**: User has 15% battery, walking to station. `distanceFilter` is 50m.
**Behavior**:
1.  User walks. GPS update received at $t=0$.
2.  User walks 49 meters. No GPS updates for ~50 seconds (assuming 1m/s).
3.  **EKF State**: EKF must propagate position using IMU for 50s.
4.  **Error Analysis**:
    *   Double integration of accelerometer bias ($\epsilon$).
    *   Position Error $\approx \frac{1}{2} \epsilon t^2$.
    *   Typical phone uncalibrated bias $\epsilon \approx 0.1 m/s^2$.
    *   Error @ 50s $= 0.5 \cdot 0.1 \cdot 2500 = 125$ meters.
**Result**: The user's estimated position jumps wildly between GPS fixes. The "smooth" EKF path will diverge significantly, potentially triggering false alarms (backwards or forwards).

### Scenario B: The "Platform Wait" (Drift Risk)
**Context**: User waits for train. GPS signal is bouncy or lost (underground/roof).
**Behavior**:
1.  User is stationary.
2.  GPS is filtered (user moves < filter distance).
3.  EKF runs on IMU.
4.  **Risk**: Without ZUPT (Zero Velocity Update), the EKF continues to integrate noise. Even small noise ($0.01 m/s^2$) over 5 minutes (300s) = catastrophic drift ($450$m).
**Mitigation**: Robust ZUPT is mandatory.

### Scenario C: The "Metro Ride" (Manageable)
**Context**: User is on train. Speed ~15-20 m/s.
**Behavior**:
1.  Train moves 50m in ~3 seconds.
2.  GPS (if available) updates every 3s.
3.  **GPS Loss**: If GPS is lost, EKF propagates.
4.  **Impact**: 3s gaps are fine for EKF. 
5.  **Risk**: If GPS is constrained by *time* (not just distance) in logic I haven't seen? No, `Geolocator` with `distanceFilter` sends updates as fast as they happen once distance is crossed.

## 3. Required EKF Design Mitigations

To survive **Scenario A**, the EKF **CANNOT** rely on pure double integration of acceleration for walking speeds over long periods.

**Proposed Solution: Activity-Based Gating**
1.  **Detect Activity**: Use `ActivityRecognition` (if available) or simple IMU spectral analysis (step frequency).
2.  **Pedestrian Mode**: If "Walking" is detected:
    *   Do **not** double integrate acceleration for distance.
    *   Use **Step Counting** (Pedometer) $\times$ Average Stride Length (approx 0.7m) to update $s$.
    *   This limits error to linear growth ($\approx 10\%$) rather than quadratic growth.
    *   Error @ 50m walking $\approx 5$m. **Acceptable**.
3.  **Vehicle Mode**: If "Vehicle/Metro" detected (smooth vibration, no steps):
    *   Use double integration (EKF).
    *   System is likely moving fast (Scenario C) so long unchecked integration times are rare (unless stopped).

## 4. Updates to Implementation Plan
*   **Add Step Detection**: The `ProgressEstimator` must listen to `Pedometer` steps or implement a simple step counter.
*   **Modify Prediction**:
    *   `if (isWalking)`: $s_{k+1} = s_k + \text{steps} \cdot \text{stride}$.
    *   `else`: Unscented/Extended KF propagation.

## 5. Constraint Verification
*   **Robustness**: This hybrid approach (Pedometer for slow, Inertial for fast) solves the Low Battery Walking risk.
*   **Battery**: Counting steps is cheap (hardware sensor).
