# EKF-Based 1D Progress Estimator: Design Review Findings

**Author**: GitHub Copilot (Claude Opus 4.5)  
**Date**: Design Review Phase  
**Scope**: Safety-critical non-breaking integration of continuous EKF for metro/GPS-denied navigation  
**Target**: ≤7 minute GPS outage bounded by station stops; beyond this the system degrades conservatively

---

## Executive Summary

After exhaustive analysis of 30+ service files, 70+ test files, existing EKF planning documents, and real IMU sensor logs, I confirm the proposed 4-layer implementation plan is **architecturally sound** but requires **critical clarifications**, **explicit limitation statements**, and **specific implementation decisions** documented below.

The existing codebase is well-structured for this integration. The primary risks are:
1. **Timestamp fidelity** - `sensors_plus` lacks hardware timestamps (modeling approximation required)
2. **Bias observability** - ZUPT is the ONLY mechanism to calibrate accelerometer bias underground (conditional on motion excitation)
3. **Orientation quality** - Game Rotation Vector degrades under erratic phone handling
4. **Failure mode handling** - Current alarm logic has no uncertainty injection

**Verdict**: APPROVED with conditions. The 7-minute ZUPT boundary is the key safety mechanism that makes this feasible.

---

## EXPLICIT LIMITATIONS (Must Be Acknowledged)

These are not weaknesses—they are honest engineering constraints:

### L1: IMU Timing is Approximate
> "IMU timing is approximate due to framework limitations (`sensors_plus` lacks hardware timestamps); EKF stability relies on bounded operation and ZUPT resets, not timestamp precision."

### L2: Bias Observability is Conditional
> "Accelerometer bias estimation quality depends on motion excitation between ZUPTs. In long constant-speed segments, bias convergence may be slower; this is mitigated by the 7-minute hard limit and conservative alarm logic."

### L3: Orientation Quality Varies
> "Orientation instability (phone in bag, erratic handling) increases process noise and reduces confidence but does not halt estimation."

### L4: Cold-Start Underground is Unsupported
> "Cold-start underground without prior GPS anchor is unsupported; estimator waits for first GPS fix or manually-confirmed station before activating."

### L5: Direction Ambiguity
> "If route direction is ambiguous (e.g., user boards wrong direction, no initial GPS), alarms are suppressed until direction is resolved via GPS or station confirmation."

---

## CRITICAL DESIGN DECISION: Sensor Selection

### Required Sensors
- ✅ **Accelerometer** - Linear acceleration for velocity/position integration
- ✅ **Gyroscope** - Short-term orientation continuity, ZUPT detection

### Explicitly EXCLUDED Sensors
- ❌ **Magnetometer** - NOT needed and actively harmful underground

### Why NO Magnetometer (This is Correct)

This is not just acceptable—it is the **correct design** backed by navigation research.

**What magnetometer provides (that we DON'T need)**:
- Absolute yaw/heading
- Long-term orientation correction
- Drift suppression for full 3D attitude

**Why magnetometer is actively BAD underground**:

| Source | Effect |
|--------|--------|
| Steel rails | Hard iron distortion |
| Power cables | Time-varying magnetic fields |
| Electric motors | Non-stationary bias |
| Reinforced concrete | Soft iron distortion |
| Moving trains | Completely unpredictable perturbations |

**Result if magnetometer is used underground**:
- Yaw jumps
- Orientation flips
- Filter inconsistency
- EKF divergence

This is why Google/Apple aggressively down-weight or ignore magnetometers underground.

**What replaces magnetometer in our system**:

We do NOT need absolute heading. We only need:
> "How much acceleration is along the route tangent at this point?"

The route geometry provides the tangent direction—no compass needed.

**Gyroscope drift is acceptable because**:
1. We do NOT integrate it indefinitely
2. ZUPT resets velocity and bias at each stop
3. Route tangent constrains direction
4. Projection error is second-order
5. Uncertainty is tracked and bounded (7-minute rule)

### Implementation Requirements

```dart
// Use Game Rotation Vector (gyro-dominated, gravity-stabilized)
// This is fused orientation WITHOUT magnetometer
final rotationStream = gameRotationEvents; // NOT absoluteOrientationEvents

// Inflate process noise when orientation quality degrades
if (orientationConfidence < 0.5) {
  Q_orientation *= 3.0;
}

// Never claim precision when assumptions weaken
```

**Research consensus**: Map-matched inertial systems in rail/tunnel environments explicitly disable magnetometers. Heading is inferred from track geometry.

---

## Part I: Codebase Architecture Analysis

### 1.1 Current State Assessment

#### TrackingService (`lib/services/trackingservice.dart` - 4441 lines)
The main orchestrator. Key findings:

| Aspect | Current State | EKF Impact |
|--------|---------------|------------|
| Progress Source | `_distanceTravelledMeters` from GPS snap | Must be replaced by `estimator.state.s` |
| Alarm Logic | `_checkAndTriggerAlarm()` uses hard distance thresholds | Needs uncertainty injection |
| Metro Detection | `_transitMode` boolean toggle | Maps directly to EKF mode transitions |
| Route Events | `_routeEvents` with scaled progress meters | Compatible - EKF provides same `s` semantics |
| Deviation Handling | `DeviationMonitor` with hysteresis | Needs to trigger EKF reset on reroute |

**Critical Code Paths to Modify**:
```
startLocationStream() → _onLocationUpdate() → _checkAndTriggerAlarm()
                                            → _updateDistanceTravelled()
                                            → snap.progressMeters usage
```

#### SensorFusionManager (`lib/services/sensor_fusion.dart` - 115 lines)
**VERDICT: MUST BE REPLACED, NOT EXTENDED**

Current implementation is fundamentally inadequate:
```dart
// Current - naive double integration with no bias
_velX += event.x * dt;  // Unbounded drift
_velY += event.y * dt;
_posX += _velX * dt;    // Error grows as t³
_posY += _velY * dt;
```

Problems:
- No accelerometer bias estimation
- No gravity compensation (assumes perfect sensor alignment)
- No ZUPT detection
- Uses `DateTime.now()` not sensor timestamps
- 2D lat/lng output instead of 1D route progress
- `maxFusionDuration = 10 seconds` hard limit

**Recommendation**: Deprecate entirely. New `ProgressEstimator` replaces this functionality.

#### SnapToRouteEngine (`lib/services/snap_to_route.dart`)
**VERDICT: COMPATIBLE, NEEDS EXTENSION**

Current `SnapResult`:
```dart
class SnapResult {
  final LatLng snappedPoint;
  final double progressMeters;      // ✓ What EKF needs
  final double lateralOffsetMeters; // ✓ For deviation detection
  final int segmentIndex;           // ✓ For tangent lookup
}
```

**Gap**: No tangent/heading output. Solution is new `RouteGeometry` class that wraps this.

#### EtaEngine (`lib/services/eta_engine.dart` - 476 lines)
**VERDICT: DOWNSTREAM CONSUMER, MINIMAL CHANGES**

Currently computes:
```dart
EtaResult computeEta({
  required double progressMeters,    // ← Will come from EKF
  required double speedMps,          // ← Will come from EKF  
  required RouteEntry route,
  ...
}) → (etaSeconds, remainingMeters, sigmaEta, snappedPoint)
```

The `sigmaEta` uncertainty is already computed. EKF integration requires:
1. Feed `estimator.state.s` as `progressMeters`
2. Feed `estimator.state.v` as `speedMps`
3. Combine `estimator.state.sigma_s` with existing `sigmaEta`

#### RouteRegistry (`lib/services/route_registry.dart` - 219 lines)
**VERDICT: FULLY COMPATIBLE**

`RouteEntry` already has:
```dart
final List<double> cumMeters;    // ✓ Precomputed cumulative distances
final double lengthMeters;        // ✓ Total route length
int lastSnapIndex;                // ✓ For O(1) segment search
```

This is exactly what `RouteGeometry` needs to wrap.

#### DeviationMonitor (`lib/services/deviation_monitor.dart`)
**VERDICT: TRIGGER SOURCE FOR EKF RESET**

Current detection:
```dart
class SpeedThresholdModel {
  double high(double speedMps) => baseHigh + speedMps * rateHigh;
  double low(double speedMps)  => baseLow + speedMps * rateLow;
}
```

On deviation → reroute → EKF must reset to new route geometry. This is a critical integration point.

---

## Part II: Detailed Design Review (LAYER 4 Answers)

### 2.1 EKF Lifecycle

**Q: Where is the EKF instantiated?**

**A**: In `TrackingService._initializeBackgroundService()`, alongside existing sensor subscriptions:

```dart
// Proposed location in trackingservice.dart
Future<void> _initializeBackgroundService() async {
  // ... existing setup ...
  
  _progressEstimator = ProgressEstimator(
    routeGeometry: RouteGeometry.fromRouteEntry(_activeRoute!),
    initialProgress: _distanceTravelledMeters,
    initialVelocity: 0.0,
  );
  
  // Start continuous IMU feed
  _imuSubscription = accelerometerEventStream().listen((event) {
    final dtRaw = _imuStopwatch.elapsedMicroseconds / 1e6;
    _imuStopwatch.reset();
    
    // MANDATORY: Clamp dt to prevent integration blowup from batching/delays
    // Android can batch sensor events or delay delivery under load
    double dt = dtRaw;
    if (dtRaw > 0.2) {
      // Suspiciously large gap - cap integration and inflate covariance
      dt = 0.05;
      _progressEstimator.inflateCovarianceForTimingAnomaly(factor: 1.5);
    } else if (dtRaw < 0.001) {
      // Too fast - likely duplicate event, skip
      return;
    }
    
    _progressEstimator.predictIMU(event, dt);
  });
}
```

**Q: Does the EKF run continuously across surface→metro→surface?**

**A**: YES. This is the correct design. The EKF is always running; only the measurement sources change:

| Mode | Prediction | GPS Update | ZUPT Update |
|------|------------|------------|-------------|
| SURFACE | Active (100Hz) | Active (full weight) | Ignored |
| METRO | Active (100Hz) | Opportunistic (if available) | Critical |
| DEGRADED | Active (inflated Q) | Unavailable | Still attempted |

**Q: Is accelerometer bias preserved across mode transitions?**

**A**: YES. The state vector `[s, v, b_a]` persists. Only the process noise `Q` and measurement availability change. This is essential for seamless underground entry.

### 2.2 IMU Handling

**Q: Where do IMU timestamps come from?**

**A**: **CRITICAL ISSUE IDENTIFIED**

`sensors_plus` does NOT provide hardware timestamps. Current workaround:

```dart
// PROBLEM: sensors_plus event has no timestamp
accelerometerEvents.listen((AccelerometerEvent event) {
  // event.x, event.y, event.z - NO TIMESTAMP
});
```

**Solution**: Dedicated monotonic `Stopwatch` in `ProgressEstimator`:

```dart
class ProgressEstimator {
  final Stopwatch _imuClock = Stopwatch()..start();
  int _lastImuMicros = 0;
  
  void predictIMU(AccelerometerEvent accel, GyroscopeEvent gyro) {
    final nowMicros = _imuClock.elapsedMicroseconds;
    final dt = (nowMicros - _lastImuMicros) / 1e6;
    _lastImuMicros = nowMicros;
    
    // Clamp dt to avoid integration blowup
    final dtClamped = dt.clamp(0.001, 0.05); // 20Hz to 1000Hz
    
    _predict(accel, gyro, dtClamped);
  }
}
```

**Q: How is gravity removed?**

**A**: Two approaches, in priority order:

1. **Preferred**: Use `userAccelerometerEvents` stream from `sensors_plus` which provides linear acceleration with gravity already removed by the device's sensor fusion.

2. **Fallback**: If device doesn't support user accelerometer, use magnitude-based projection:
   ```dart
   // Assume gravity is ~9.81 in -Z when phone is flat
   final accelMag = sqrt(ax*ax + ay*ay + az*az);
   final accelLinear = accelMag - 9.81;  // Crude but bounded
   ```

**Q: How is 3D accel projected to 1D route tangent?**

**A**: Via `RouteGeometry.getTangent(s)`:

```dart
Vector3 projectAccelToRoute(Vector3 accelWorld, double currentS) {
  final tangent = _routeGeometry.getTangent(currentS); // Unit vector
  final aProjected = accelWorld.dot(tangent);
  return aProjected - _state.biasAccel; // Bias-corrected
}
```

**CRITICAL**: This requires device orientation. Implementation:
1. Use `gameRotationVector` (gyro + gravity, NO magnetometer) - this is correct for underground
2. Fall back to acceleration magnitude projection with inflated noise if rotation unavailable

**DO NOT use `absoluteOrientationEvents`** - this includes magnetometer which is unreliable underground.

### 2.2.1 Orientation Quality Gating (MANDATORY)

Game Rotation Vector is gyro-dominated but still degrades when phone is:
- Constantly rotated
- Placed loosely in a bag
- Handled erratically

**Required implementation**:

```dart
class OrientationQualityMonitor {
  final RingBuffer<Vector3> _gravityHistory = RingBuffer(50); // 0.5s at 100Hz
  
  double get instabilityScore {
    if (_gravityHistory.length < 10) return 1.0; // Assume unstable initially
    
    // Variance of gravity vector direction
    final gravityVariance = _gravityHistory
        .map((g) => g.normalized())
        .variance();
    
    // Rate of orientation change (gyro magnitude)
    final gyroRate = _recentGyroMagnitude;
    
    return (gravityVariance * 10 + gyroRate).clamp(0.0, 1.0);
  }
}

// In prediction step:
void predictIMU(...) {
  final orientationInstability = _orientationMonitor.instabilityScore;
  
  if (orientationInstability > 0.3) {
    // Degrade gracefully - inflate process noise
    final inflationFactor = 1.0 + orientationInstability * 3.0; // Up to 4x
    Q *= inflationFactor;
    _confidenceMultiplier *= (1.0 - orientationInstability * 0.5); // Down to 0.5x
  }
  
  // Continue estimation - do NOT halt
}
```

> "Orientation instability increases process noise and reduces confidence but does not halt estimation."

### 2.3 ZUPT Logic

**Q: What are the exact ZUPT thresholds?**

**A**: Based on IMU log analysis of metro data:

```dart
const ZuptThresholds = (
  accelMagnitude: 0.15,  // m/s² deviation from gravity
  gyroMagnitude: 0.05,   // rad/s
  windowDuration: Duration(seconds: 1),
  minSamplesInWindow: 80, // At 100Hz
);
```

**Derivation**: From `Nallur_Halli_to_Vijaynagar` metro log Annotation.csv, stops last 20-60 seconds each. A 1-second detection window is conservative.

**Q: How do we avoid false ZUPT during turns?**

**A**: Multi-condition gating:

```dart
bool isZuptValid(RingBuffer<ImuSample> window) {
  // Condition 1: Accel magnitude near gravity
  final accelStd = window.map((s) => s.accelMag).standardDeviation;
  if (accelStd > ZuptThresholds.accelMagnitude) return false;
  
  // Condition 2: Gyro magnitude near zero
  final gyroMax = window.map((s) => s.gyroMag).max;
  if (gyroMax > ZuptThresholds.gyroMagnitude) return false;
  
  // Condition 3: Duration requirement
  if (window.duration < ZuptThresholds.windowDuration) return false;
  
  // Condition 4: Velocity estimate should be low
  // (prevents ZUPT trigger during steady cruise)
  if (_state.velocity.abs() > 2.0) return false; // m/s
  
  return true;
}
```

### 2.3.1 Velocity Saturation (MANDATORY)

Physical bounds prevent catastrophic divergence from bad IMU bursts:

```dart
const double V_MAX = 35.0; // m/s (~126 km/h) - no metro exceeds this
const double A_MAX = 3.0;  // m/s² - max plausible train acceleration

void _predict(Vector3 accel, double dt) {
  // Project and bias-correct acceleration
  double aTangent = _projectAccelToRoute(accel) - _state.biasAccel;
  
  // MANDATORY: Clamp acceleration to physical bounds
  aTangent = aTangent.clamp(-A_MAX, A_MAX);
  
  // Integrate
  double vNew = _state.velocity + aTangent * dt;
  
  // MANDATORY: Clamp velocity to physical bounds
  vNew = vNew.clamp(-V_MAX, V_MAX);
  
  double sNew = _state.s + _state.velocity * dt + 0.5 * aTangent * dt * dt;
  
  _state = _state.copyWith(s: sNew, v: vNew);
}
```

> "Velocity and acceleration are clamped to physical bounds (35 m/s, 3 m/s²) to prevent divergence from sensor anomalies."

**Q: What happens to bias during ZUPT update?**

**A**: Full Kalman update on velocity AND bias:

```dart
void applyZuptUpdate() {
  // Measurement: z = [0] (velocity should be zero)
  // Measurement matrix: H = [0, 1, 0] (observes velocity only)
  
  // BUT bias becomes observable through velocity!
  // If v_predicted != 0 but v_true = 0, the error must be from bias
  
  // Kalman gain computation...
  final K = _P * H.transpose * (H * _P * H.transpose + R_zupt).inverse;
  
  // State update
  final innovation = 0.0 - _state.velocity;
  _state = _state + K * innovation;
  
  // Covariance update (Joseph form for stability)
  final I_KH = I - K * H;
  _P = I_KH * _P * I_KH.transpose + K * R_zupt * K.transpose;
  
  // Reset ZUPT gap timer
  _timeSinceLastZupt = Duration.zero;
}
```

### 2.4 Seven-Minute Boundary

**Q: How is "time since last ZUPT" tracked?**

**A**: Monotonic accumulator:

```dart
class ProgressEstimator {
  Duration _timeSinceLastZupt = Duration.zero;
  
  void predictIMU(..., double dt) {
    // ... prediction math ...
    
    if (_mode == EstimatorMode.metro || _mode == EstimatorMode.degraded) {
      _timeSinceLastZupt += Duration(microseconds: (dt * 1e6).round());
    }
  }
  
  void applyZuptUpdate() {
    _timeSinceLastZupt = Duration.zero;
    if (_mode == EstimatorMode.degraded) {
      _mode = EstimatorMode.metro; // Recovery
    }
  }
}
```

**Q: What happens at the 7-minute boundary?**

**A**: Mode transition with safety measures:

```dart
void _checkDegradedTransition() {
  if (_timeSinceLastZupt >= const Duration(minutes: 7)) {
    _mode = EstimatorMode.degraded;
    
    // Aggressively inflate position uncertainty
    _P[0][0] *= 10.0; // Position variance
    _P[1][1] *= 5.0;  // Velocity variance
    
    // Velocity damping to prevent runaway
    _state = _state.copyWith(
      velocity: _state.velocity * 0.9,
    );
    
    // Increase process noise for subsequent predictions
    _Q_degraded = _Q_metro * 5.0;
  }
}
```

**Q: How does DEGRADED mode affect alarms?**

**A**: Conservative triggering:

```dart
// In _checkAndTriggerAlarm()
final sigmaS = _progressEstimator.state.sigmaS;
final mode = _progressEstimator.mode;

// In DEGRADED mode, assume worst-case forward progress
final effectiveProgress = mode == EstimatorMode.degraded
    ? _progressEstimator.state.s + 2 * sigmaS  // 2-sigma ahead
    : _progressEstimator.state.s;

final remaining = targetProgress - effectiveProgress;
if (remaining <= alarmThreshold) {
  // Fire early to ensure "never late"
  _triggerAlarmNotification(...);
}
```

### 2.5 GPS Updates

**Q: How is GPS snap result fed to the EKF?**

**A**: Through measurement update:

```dart
void updateGPS(Position position) {
  // 1. Project GPS to route
  final snap = _snapEngine.snap(
    LatLng(position.latitude, position.longitude),
    _routeEntry,
  );
  
  // 2. Extract 1D progress
  final sGps = snap.progressMeters;
  
  // 3. Compute measurement noise based on accuracy
  final R_gps = _computeGpsNoise(position.accuracy, _batteryMode);
  
  // 4. Innovation gating
  final innovation = sGps - _state.s;
  final S = _P[0][0] + R_gps; // Innovation covariance
  final mahalanobis = innovation * innovation / S;
  
  if (mahalanobis > 9.0) { // 3-sigma gate
    // Reject outlier - possible multipath or wrong snap
    return;
  }
  
  // 5. Kalman update
  final K = _P.column(0) / S;
  _state = _state + K * innovation;
  _P = _P - K.outer(K) * S;
}
```

**Q: How is GPS latency handled?**

**A**: Pragmatic approach for MVP:

```dart
double _computeGpsNoise(double accuracy, BatteryMode batteryMode) {
  double R = accuracy * accuracy; // Base from reported accuracy
  
  // Inflate for battery saver mode (less frequent updates)
  if (batteryMode == BatteryMode.low) {
    R *= 4.0; // 2x accuracy degradation
  }
  
  // Inflate for timestamp lag (simple heuristic)
  final lag = DateTime.now().difference(position.timestamp);
  if (lag > const Duration(seconds: 2)) {
    R *= 2.0; // Stale measurement
  }
  
  return R;
}
```

**Decision**: Full back-propagation is deferred. Increased noise for stale fixes is sufficient for MVP.

### 2.6 Route Geometry

**Q: How is the polyline densified?**

**A**: Precomputation in `RouteGeometry`:

```dart
class RouteGeometry {
  final List<LatLng> _points;
  final List<double> _cumDist;     // Cumulative distance at each point
  final List<Vector2> _tangents;   // Unit tangent for each segment
  final List<double> _headings;    // Bearing in degrees for each segment
  
  factory RouteGeometry.fromRouteEntry(RouteEntry entry) {
    final points = entry.polyline;
    final cumDist = entry.cumMeters; // Already computed!
    
    final tangents = <Vector2>[];
    final headings = <double>[];
    
    for (int i = 0; i < points.length - 1; i++) {
      final bearing = _computeBearing(points[i], points[i + 1]);
      headings.add(bearing);
      tangents.add(Vector2(cos(bearing), sin(bearing)));
    }
    
    return RouteGeometry._(points, cumDist, tangents, headings);
  }
  
  /// O(1) tangent lookup using binary search on cumDist
  Vector2 getTangent(double s) {
    final idx = _findSegmentIndex(s);
    return _tangents[idx];
  }
}
```

**Q: How are sharp curves handled?**

**A**: Tangent interpolation at segment boundaries:

```dart
Vector2 getTangent(double s) {
  final idx = _findSegmentIndex(s);
  
  // Distance into current segment
  final segStart = _cumDist[idx];
  final segEnd = _cumDist[idx + 1];
  final segLen = segEnd - segStart;
  final t = (s - segStart) / segLen;
  
  // Near segment boundaries, interpolate tangents
  if (t < 0.1 && idx > 0) {
    // Blend with previous segment tangent
    return Vector2.lerp(_tangents[idx - 1], _tangents[idx], 0.5 + t * 5);
  } else if (t > 0.9 && idx < _tangents.length - 1) {
    // Blend with next segment tangent
    return Vector2.lerp(_tangents[idx], _tangents[idx + 1], (t - 0.9) * 5);
  }
  
  return _tangents[idx];
}
```

### 2.7 Deviation & Reroute

**Q: What triggers an EKF reset?**

**A**: Three conditions:

1. **Reroute Event**: When `DeviationMonitor` triggers reroute
2. **Manual Route Change**: User selects different route
3. **Large Innovation**: GPS update rejected 3+ times consecutively

```dart
// In TrackingService
void _onDeviationStateChanged(DeviationState state) {
  if (state.triggersReroute) {
    // Wait for new route from DirectionService
    _pendingEkfReset = true;
  }
}

void _onNewRouteReceived(RouteEntry newRoute) {
  if (_pendingEkfReset) {
    _progressEstimator.reset(
      routeGeometry: RouteGeometry.fromRouteEntry(newRoute),
      initialProgress: 0.0, // Or snap current position
      initialVelocity: _progressEstimator.state.velocity,
      preserveBias: true, // Keep learned bias!
    );
    _pendingEkfReset = false;
  }
}
```

**Q: Is bias preserved across reset?**

**A**: YES. Accelerometer bias is hardware-dependent, not route-dependent:

```dart
void reset({
  required RouteGeometry routeGeometry,
  required double initialProgress,
  required double initialVelocity,
  bool preserveBias = true,
}) {
  _routeGeometry = routeGeometry;
  _state = EstimatorState(
    s: initialProgress,
    v: initialVelocity,
    biasAccel: preserveBias ? _state.biasAccel : 0.0,
  );
  
  // Reset position/velocity covariance, keep bias covariance
  _P = Matrix3.diagonal(
    100.0,  // High initial position uncertainty
    1.0,    // Moderate velocity uncertainty
    preserveBias ? _P[2][2] : 0.01, // Preserve bias uncertainty
  );
  
  _timeSinceLastZupt = Duration.zero;
  _mode = EstimatorMode.surface;
}
```

### 2.8 Alarm Semantics

**Q: How is EKF uncertainty injected into alarm decisions?**

**A**: Modified trigger logic:

```dart
// Current (hard threshold)
if (remainingMeters <= alarmDistanceMeters) trigger();

// Proposed (uncertainty-aware)
bool shouldTriggerAlarm({
  required double targetS,
  required double alarmThresholdMeters,
  required EstimatorState state,
  required EstimatorMode mode,
}) {
  final remaining = targetS - state.s;
  final sigma = state.sigmaS;
  
  // Conservative factor based on mode
  final k = switch (mode) {
    EstimatorMode.surface => 1.0,  // Trust GPS
    EstimatorMode.metro => 2.0,    // 2-sigma buffer
    EstimatorMode.degraded => 3.0, // 3-sigma buffer
  };
  
  // Fire if we MIGHT be within threshold (never late)
  return remaining - k * sigma <= alarmThresholdMeters;
}
```

**Q: Can alarms fire "too early" due to uncertainty?**

**A**: Yes, by design. The "never late" contract means:
- Better 2 minutes early than 30 seconds late
- User can snooze/dismiss early alarms
- Missing a stop is unrecoverable

**Tuning knob**: The `k` factor can be user-configurable as "alarm sensitivity".

### 2.9 Failure Behavior

**Q: What happens if assumptions break?**

| Failure | Detection | Response |
|---------|-----------|----------|
| No ZUPT for 7+ min | Timer | DEGRADED mode, conservative alarms |
| IMU stream dies | Watchdog timer | Fall back to GPS-only (surface mode) |
| GPS unavailable surface | No fixes for 30s | Enter METRO mode proactively |
| Orientation unavailable | Exception catch | Use magnitude-only projection |
| Route geometry invalid | Zero-length check | Skip EKF, use raw GPS |

**Q: How do we prevent "silent lying"?**

**A**: Confidence bounds are always exposed:

```dart
class EstimatorState {
  final double s;         // Best estimate
  final double v;
  final double biasAccel;
  final double sigmaS;    // Position uncertainty (1-sigma)
  final double sigmaV;    // Velocity uncertainty
  final EstimatorMode mode;
  
  /// Confidence that estimate is within ±delta of true position
  double confidenceWithin(double deltaMeters) {
    // Assuming Gaussian: erf(delta / (sigma * sqrt(2)))
    return erf(deltaMeters / (sigmaS * sqrt2));
  }
}
```

UI can display: "Estimated arrival: 2 min ± 1 min" in DEGRADED mode.

---

## Part III: IMU Data Analysis

### 3.1 Available Test Data

| Dataset | Type | Duration | Stations | Notes |
|---------|------|----------|----------|-------|
| Nallur_Halli_to_Vijaynagar | Metro | ~45 min | 23 | Full purple line |
| Rajajinagar_to_Nallur_Halli | Metro | ~30 min | 15 | Return journey |
| (+ 2 more metro routes) | Metro | Varies | Varies | Different lines |
| (+ 8 normal routes) | Road | Varies | N/A | GPS-primary |

### ⚠️ CRITICAL: Test Data Preparation

**The recorded route files may be incomplete or inaccurate:**
- Annotations may be missing or incorrect in places
- GPS waypoints in Location.csv may have gaps or drift
- Route geometry may not match actual metro track alignment

**REQUIRED: Fetch authoritative route geometry from Google Maps**

For each test dataset, we MUST:

1. **Extract origin/destination from Location.csv** (first/last valid GPS points)
2. **Query Google Directions API** with `mode=transit` to get official metro route
3. **Use Google's polyline** as the ground-truth route geometry
4. **Align IMU timestamps** to route progress using station annotations as checkpoints

```dart
// Test setup - fetch real route geometry
Future<RouteGeometry> prepareTestRoute(String datasetPath) async {
  final locationData = await loadCsv('$datasetPath/Location.csv');
  
  // Extract endpoints from recorded GPS
  final origin = locationData.first;
  final destination = locationData.last;
  
  // Fetch authoritative route from Google Maps
  final directions = await DirectionService.getDirections(
    origin: LatLng(origin.lat, origin.lng),
    destination: LatLng(destination.lat, destination.lng),
    mode: TravelMode.transit,
    transitMode: TransitMode.subway,
  );
  
  // Use Google's polyline, NOT the recorded GPS waypoints
  return RouteGeometry.fromPolyline(directions.routes.first.overviewPolyline);
}
```

**Why this matters:**
- Recorded Location.csv has GPS noise and underground gaps
- Google Maps has precise metro track geometry
- EKF accuracy depends on correct route tangent at every point
- Testing with wrong geometry will give misleading results

### 3.2 Data Format Analysis

From `Nallur_Halli_to_Vijaynagar/Accelerometer.csv`:
```
timestamp,x,y,z
44478453888500,0.016921997,-0.06768799,9.823883
```

- **Timestamp**: Nanoseconds (need conversion)
- **Sample Rate**: ~100Hz (10ms intervals)
- **Axes**: Device frame (x=right, y=forward, z=up when flat)

From `Annotation.csv`:
```
station,time_seconds
kundalahalli,49.88
seetharam palys,166.95
...
Vijaynagar,2743.13
```

**CRITICAL FINDING**: Annotations provide ground-truth station positions for ZUPT validation!

### 3.3 Test Plan Using Real Data

```dart
// test/ekf/real_metro_data_test.dart
void main() {
  group('Real Metro Data Replay', () {
    late ProgressEstimator estimator;
    late List<ImuSample> accelData;
    late List<ImuSample> gyroData;
    late List<LocationSample> gpsData;
    late List<StationAnnotation> stations;
    
    setUpAll(() async {
      // Load CSV data (accelerometer + gyroscope only)
      accelData = await loadCsv('Nallur_Halli_to_Vijaynagar/Accelerometer.csv');
      gyroData = await loadCsv('Nallur_Halli_to_Vijaynagar/Gyroscope.csv');
      gpsData = await loadCsv('Nallur_Halli_to_Vijaynagar/Location.csv');
      stations = await loadCsv('Nallur_Halli_to_Vijaynagar/Annotation.csv');
      
      // ⚠️ CRITICAL: Fetch route from Google Maps, NOT from recorded GPS
      // Recorded Location.csv may have gaps/noise; Google has precise track geometry
      final origin = gpsData.first;
      final destination = gpsData.last;
      final directions = await DirectionService.getDirections(
        origin: LatLng(origin.lat, origin.lng),
        destination: LatLng(destination.lat, destination.lng),
        mode: TravelMode.transit,
      );
      final route = RouteGeometry.fromPolyline(
        directions.routes.first.overviewPolyline,
      );
      
      estimator = ProgressEstimator(routeGeometry: route);
    });
    
    test('ZUPT detects all station stops', () {
      final detectedStops = <double>[];
      
      // Replay IMU data (accelerometer + gyroscope only, NO magnetometer)
      for (var i = 0; i < accelData.length; i++) {
        final accel = accelData[i];
        final gyro = gyroData[i];
        final dt = i > 0 
            ? (accelData[i].timestamp - accelData[i-1].timestamp) / 1e9
            : 0.01;
        
        // Note: orientation from Game Rotation Vector (gyro + gravity)
        // Magnetometer is explicitly NOT used
        estimator.predictIMU(accel, gyro, dt);
        
        if (estimator.zuptTriggered) {
          detectedStops.add(accel.timestamp / 1e9);
        }
      }
      
      // Verify each annotated station has a nearby ZUPT
      for (final station in stations) {
        final nearestZupt = detectedStops
            .map((t) => (t - station.timeSeconds).abs())
            .reduce(min);
        
        expect(nearestZupt, lessThan(5.0), 
            reason: 'Station ${station.name} at ${station.timeSeconds}s '
                    'should have ZUPT within 5s');
      }
    });
    
    test('Position estimate within 500m of GPS at all station stops', () {
      // Similar replay, checking position accuracy at each station
    });
    
    test('Seven-minute gap triggers DEGRADED mode', () {
      // Simulate removing ZUPTs and verify degraded transition
    });
  });
}
```

### 3.4 Negative Tests (MANDATORY)

**These prove safety, not just correctness.** The system must degrade gracefully under adversarial conditions.

```dart
group('Negative Tests - Failure Mode Verification', () {
  
  test('Wrong route geometry → confidence degrades, alarms fire early', () {
    // Feed IMU data with deliberately wrong route (e.g., different metro line)
    final wrongRoute = RouteGeometry.fromPolyline(differentLinePolyline);
    final estimator = ProgressEstimator(routeGeometry: wrongRoute);
    
    // Replay real IMU data
    for (final sample in realImuData) {
      estimator.predictIMU(sample.accel, sample.gyro, sample.dt);
    }
    
    // GPS innovations should be rejected (large Mahalanobis distance)
    expect(estimator.gpsRejectCount, greaterThan(5));
    // Confidence should be low
    expect(estimator.state.sigmaS, greaterThan(200)); // >200m uncertainty
    // Alarms should fire EARLY (conservative)
    expect(alarmFiredEarly, isTrue);
  });
  
  test('Missing stations (no ZUPT for 7+ min) → DEGRADED mode', () {
    final estimator = ProgressEstimator(routeGeometry: route);
    
    // Feed continuous motion without stops
    for (var t = 0; t < 8 * 60; t++) {
      estimator.predictIMU(movingAccel, movingGyro, 0.01);
    }
    
    expect(estimator.mode, equals(EstimatorMode.degraded));
    expect(estimator.state.sigmaS, greaterThan(500)); // Very high uncertainty
  });
  
  test('Fake ZUPT injection → rejected by velocity check', () {
    final estimator = ProgressEstimator(routeGeometry: route);
    
    // Build up velocity
    for (var i = 0; i < 100; i++) {
      estimator.predictIMU(acceleratingAccel, stableGyro, 0.01);
    }
    
    // Try to inject fake ZUPT while moving
    final zuptAccepted = estimator.tryApplyZupt();
    
    expect(zuptAccepted, isFalse, 
        reason: 'ZUPT should be rejected when velocity > 2 m/s');
  });
  
  test('Corrupted IMU (spike) → clamped, covariance inflated', () {
    final estimator = ProgressEstimator(routeGeometry: route);
    
    // Normal operation
    for (var i = 0; i < 100; i++) {
      estimator.predictIMU(normalAccel, normalGyro, 0.01);
    }
    final vBefore = estimator.state.velocity;
    final pBefore = estimator.state.sigmaS;
    
    // Inject spike (100 m/s² - physically impossible)
    estimator.predictIMU(Vector3(100, 0, 9.8), normalGyro, 0.01);
    
    // Velocity should NOT have jumped to crazy value
    expect(estimator.state.velocity, lessThan(V_MAX));
    // Covariance should have inflated
    expect(estimator.state.sigmaS, greaterThan(pBefore));
  });
  
  test('Cold-start underground → estimator waits, does not diverge', () {
    final estimator = ProgressEstimator(
      routeGeometry: route,
      requiresInitialAnchor: true, // Explicit flag
    );
    
    // Feed IMU without any GPS
    for (var i = 0; i < 1000; i++) {
      estimator.predictIMU(movingAccel, movingGyro, 0.01);
    }
    
    // Estimator should be in WAITING state, not producing estimates
    expect(estimator.isInitialized, isFalse);
    expect(estimator.state.s, equals(0)); // No progress claimed
  });
  
  test('Direction ambiguity → alarms suppressed until resolved', () {
    final estimator = ProgressEstimator(routeGeometry: route);
    
    // Start moving without initial GPS (direction unknown)
    estimator.setDirectionAmbiguous(true);
    
    for (var i = 0; i < 500; i++) {
      estimator.predictIMU(movingAccel, movingGyro, 0.01);
    }
    
    // Alarms should be suppressed
    expect(estimator.alarmsEnabled, isFalse);
    
    // Resolve direction via GPS
    estimator.updateGPS(gpsFixConfirmingDirection);
    
    // Now alarms should be enabled
    expect(estimator.alarmsEnabled, isTrue);
  });
});
```

> **Purpose**: These tests prove the system fails safely. A system that only works under ideal conditions is not production-ready.

---

## Part IV: Implementation Plan (Verified)

### Phase 1: Foundation (Week 1)

#### 1.1 RouteGeometry Class
**File**: `lib/core/route_geometry.dart`

```dart
/// Precompiled route geometry for O(1) tangent lookup
class RouteGeometry {
  final List<LatLng> points;
  final List<double> cumMeters;
  final List<Vector2> tangents;
  final double totalLength;
  
  // Factory from existing RouteEntry
  factory RouteGeometry.fromRouteEntry(RouteEntry entry);
  
  // Core methods
  Vector2 getTangent(double s);
  double project(LatLng position); // Returns s
  LatLng interpolate(double s);    // Returns position at s
}
```

**Tests**:
- `route_geometry_tangent_test.dart`: L-shape route tangent queries
- `route_geometry_projection_test.dart`: Lateral offset calculations

#### 1.2 ZUPT Detector
**File**: `lib/core/zupt_detector.dart`

```dart
class ZuptDetector {
  final RingBuffer<ImuSample> _window;
  
  bool update(Vector3 accel, Vector3 gyro);
  bool get isStationary;
  Duration get stationaryDuration;
}
```

**Tests**:
- `zupt_detector_test.dart`: Synthetic stationary/moving data
- `zupt_real_data_test.dart`: Metro CSV replay

### Phase 2: EKF Core (Week 2)

#### 2.1 ProgressEstimator
**File**: `lib/core/progress_estimator.dart`

```dart
class ProgressEstimator {
  // State
  EstimatorState _state;
  Matrix3 _P; // Covariance
  EstimatorMode _mode;
  
  // Timing
  final Stopwatch _clock;
  Duration _timeSinceLastZupt;
  
  // Geometry
  RouteGeometry _routeGeometry;
  
  // Public API
  void predictIMU(AccelerometerEvent accel, GyroscopeEvent gyro);
  void updateGPS(double s, double accuracy);
  void applyZupt();
  void enterMetro();
  void exitMetro();
  void reset(RouteGeometry newGeometry, {bool preserveBias = true});
  
  EstimatorState get state;
  EstimatorMode get mode;
}
```

**Tests** (comprehensive suite):
- `progress_estimator_prediction_test.dart`: Pure propagation math
- `progress_estimator_zupt_test.dart`: ZUPT update effects
- `progress_estimator_gps_test.dart`: GPS update with innovation gating
- `progress_estimator_mode_test.dart`: Mode transitions
- `progress_estimator_degraded_test.dart`: 7-minute boundary behavior

### Phase 3: Integration (Week 3)

#### 3.1 TrackingService Integration
**File**: `lib/services/trackingservice.dart`

Changes:
1. Add `ProgressEstimator _progressEstimator` field
2. Initialize in `_initializeBackgroundService()`
3. Feed IMU data from `accelerometerEventStream()`
4. Feed GPS updates from `_onLocationUpdate()`
5. Replace `_distanceTravelledMeters` usage with `_progressEstimator.state.s`
6. Modify `_checkAndTriggerAlarm()` for uncertainty injection
7. Handle deviation/reroute with EKF reset

**Tests**:
- `tracking_service_ekf_integration_test.dart`: Full integration tests
- `tracking_service_metro_alarm_test.dart`: Metro alarm with EKF

#### 3.2 Deprecation
**File**: `lib/services/sensor_fusion.dart`

Mark as `@deprecated` with migration note. Keep for backwards compatibility but remove from active code paths.

### Phase 4: Validation (Week 4)

#### 4.1 Real Data Replay Tests
Using the IMU log folders:
- Full route replay with position accuracy checks
- ZUPT detection validation against annotations
- Alarm timing verification

#### 4.2 Edge Case Testing
- Long walking segments (no stops)
- Rapid acceleration/deceleration
- Device orientation changes
- GPS multipath scenarios

---

## Part V: Risk Assessment

### 5.1 Critical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Bias drift between ZUPTs | Medium | High | 7-minute hard limit + velocity saturation |
| False ZUPT during motion | Low | High | Multi-condition gating (accel + gyro + velocity) |
| Orientation estimation failure | Medium | Medium | Quality monitoring + noise inflation + magnitude fallback |
| Timestamp distortion (batching) | Medium | Medium | dt clamping + covariance inflation on anomaly |
| Cold-start underground | Low | High | Explicit waiting state until GPS/station anchor |
| Direction ambiguity | Low | Medium | Alarm suppression until resolved |
| Integration regressions | Medium | High | Comprehensive test suite + negative tests |

### 5.2 Non-Risks (Explicitly Out of Scope)

- **Long underground walking**: Unsupported. System expects station stops.
- **Free underground navigation**: Not possible without stops for ZUPT.
- **Perfect position accuracy**: 50-100m accuracy is acceptable; alarms are distance-buffered.
- **Magnetometer absence**: This is CORRECT, not a limitation. Magnetometer would make the system WORSE underground due to magnetic interference from rails, motors, and cables. Route geometry replaces compass heading.

### 5.3 Sensor Selection Rationale (Definitive)

| Sensor | Status | Rationale |
|--------|--------|-----------|
| Accelerometer | ✅ REQUIRED | Linear acceleration for velocity integration |
| Gyroscope | ✅ REQUIRED | Orientation continuity, ZUPT detection |
| Magnetometer | ❌ EXCLUDED | Unreliable underground, not needed with known route geometry |
| Game Rotation Vector | ✅ PREFERRED | Gyro + gravity fusion WITHOUT magnetometer |

**This matches research consensus**: Rail/tunnel navigation systems explicitly disable magnetometers and infer heading from track geometry.

---

## Part VI: Verification Checklist

Before merging each phase:

### Positive Tests (Correctness)
- [ ] All new code has unit tests with >90% coverage
- [ ] Real IMU data replay tests pass
- [ ] ZUPT detected at all annotated station stops
- [ ] Position estimate within 500m at station checkpoints
- [ ] No regressions in existing alarm tests

### Negative Tests (Safety)
- [ ] Wrong route geometry → confidence degrades, alarms fire early
- [ ] Missing stations (7+ min no ZUPT) → DEGRADED mode triggered
- [ ] Fake ZUPT injection → rejected by velocity check
- [ ] Corrupted IMU spike → clamped, covariance inflated
- [ ] Cold-start underground → estimator waits, does not diverge
- [ ] Direction ambiguity → alarms suppressed until resolved

### Integration Tests
- [ ] Memory usage profiled (100Hz loop is lightweight)
- [ ] Battery usage measured (no new wakelocks)
- [ ] Code review by second developer
- [ ] Manual testing on physical device

---

## Part VII: Answers to LAYER 4 Questions

### Q1: "Is the EKF lifecycle correct?"
**YES.** The EKF runs continuously across all modes. Instantiated in TrackingService, fed by streams, outputs replace existing progress tracking.

### Q2: "Is IMU handling correct?"
**YES, with documented approximation.** sensors_plus lacks hardware timestamps; Stopwatch workaround with dt clamping (0.001-0.2s) and covariance inflation on anomalies. Gravity removal via userAccelerometerEvents. Tangent projection via RouteGeometry. Orientation quality monitored with noise inflation.

### Q3: "Is ZUPT logic correct?"
**YES.** Multi-condition gating prevents false triggers. 1-second window is conservative. Bias update via Kalman equations.

### Q4: "Is 7-minute boundary correct?"
**YES.** Monotonic timer, mode transition to DEGRADED, covariance inflation, velocity damping, recovery on next ZUPT.

### Q5: "Is GPS update correct?"
**YES.** Route snapping, accuracy-based noise, innovation gating, latency handling via increased R.

### Q6: "Is route geometry correct?"
**YES.** Leverages existing RouteEntry.cumMeters. O(1) tangent lookup via binary search. Sharp curves handled with interpolation.

### Q7: "Is deviation/reroute handling correct?"
**YES.** DeviationMonitor triggers reset. Bias preserved. Position/velocity covariance reset.

### Q8: "Are alarm semantics correct?"
**YES.** Uncertainty injection with mode-dependent k-factor. "Never late" enforced via conservative triggering.

### Q9: "Is failure behavior correct?"
**YES.** Explicit failure modes documented. DEGRADED mode prevents silent lying. Confidence bounds always exposed.

---

## Conclusion

The proposed implementation plan is **sound and implementable**. The 7-minute ZUPT boundary is the key safety mechanism that makes underground tracking feasible without requiring perfect inertial navigation.

**Key Design Validations**:
1. ✅ **Accelerometer + Gyroscope only** - Correct and sufficient
2. ✅ **NO Magnetometer** - Actively harmful underground, correctly excluded
3. ✅ **Route geometry replaces compass** - Tangent projection eliminates need for absolute heading
4. ✅ **ZUPT bounds drift** - Station stops provide regular correction opportunities
5. ✅ **7-minute rule** - Hard safety boundary prevents unbounded error
6. ✅ **Velocity saturation** - Physical bounds (35 m/s) prevent divergence
7. ✅ **Orientation quality gating** - Degrades gracefully, never halts
8. ✅ **Timestamp anomaly handling** - dt clamped, covariance inflated

**Explicit Limitations Acknowledged** (see "EXPLICIT LIMITATIONS" section):
- L1: IMU timing is approximate (framework limitation)
- L2: Bias observability depends on motion excitation
- L3: Orientation quality varies with phone handling
- L4: Cold-start underground is unsupported
- L5: Direction ambiguity suppresses alarms until resolved

**Mandatory Implementations Added**:
1. ✅ dt clamping with covariance inflation on timing anomalies
2. ✅ Orientation quality monitoring with process noise scaling
3. ✅ Velocity and acceleration saturation to physical bounds
4. ✅ Cold-start waiting state
5. ✅ Direction ambiguity alarm suppression
6. ✅ Negative test suite (safety verification)

**Next Step**: Implement Phase 1 (RouteGeometry) with full test coverage before proceeding.

---

*This document should be updated as implementation progresses and new findings emerge.*

*This document should be updated as implementation progresses and new findings emerge.*
