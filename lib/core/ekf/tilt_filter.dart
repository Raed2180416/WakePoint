// Tilt filter (Stage A) - complementary filter for pitch/roll.

import 'dart:math' as math;
import 'ekf_types.dart';

class TiltFilterOutput {
  final List<double> gravityDevice; // unit vector
  final List<List<double>> rDeviceToWorld; // 3x3 rotation matrix
  final double pitchRad;
  final double rollRad;
  final Duration timestamp;

  const TiltFilterOutput({
    required this.gravityDevice,
    required this.rDeviceToWorld,
    required this.pitchRad,
    required this.rollRad,
    required this.timestamp,
  });
}

class TiltFilter {
  TiltFilter({
    this.alpha = 0.02,
    this.lpfCutoffHz = 0.8,
    this.varianceWindowSec = 0.75,
    this.accelVarThreshold = 4e-4,
    this.gravityNormTol = 0.2,
  });

  final double alpha;
  final double lpfCutoffHz;
  final double varianceWindowSec;
  final double accelVarThreshold;
  final double gravityNormTol;

  Duration? _lastTs;
  List<double>? _gHat; // unit gravity in device frame
  List<double>? _accelLpf; // low-pass filtered accel
  final List<double> _accelMagWindow = [];
  double _accelMagSum = 0.0;
  double _accelMagSumSq = 0.0;

  TiltFilterOutput? update(ImuSample sample) {
    if (_lastTs != null && sample.timestamp <= _lastTs!) {
      return _lastOutput(sample.timestamp);
    }

    final dt =
        _lastTs == null
            ? null
            : (sample.timestamp - _lastTs!).inMicroseconds / 1e6;

    _lastTs = sample.timestamp;

    if (dt != null && (dt < 0.001 || dt > 0.2)) {
      return _lastOutput(sample.timestamp);
    }

    final ax = sample.ax;
    final ay = sample.ay;
    final az = sample.az;

    _accelLpf = _updateLowPass(_accelLpf, ax, ay, az, dt ?? 0.01);

    final accelMag = math.sqrt(ax * ax + ay * ay + az * az);
    _pushAccelMag(accelMag, dt ?? 0.01);

    final gMeas =
        _accelLpf != null ? _normalize(_accelLpf!) : _normalize([ax, ay, az]);

    if (_gHat == null) {
      _gHat = gMeas;
    } else if (dt != null) {
      final gPred = _integrateGyro(_gHat!, sample.gx, sample.gy, sample.gz, dt);

      // Divergence Check:
      // Even if variance is low (smooth ride), if Accel vector disagrees with Gyro vector
      // by more than a small margin, it's likely Lateral/Longitudinal Acceleration, not Tilt drift.
      // 0.5 m/s² ~ 0.05 rad. We set threshold to 0.01 rad (~0.6 deg or ~0.1 m/s²).
      final dot =
          gPred[0] * gMeas[0] + gPred[1] * gMeas[1] + gPred[2] * gMeas[2];
      // clamp for acos safety
      final clampedDot = dot.clamp(-1.0, 1.0);
      final divergence = math.acos(clampedDot);

      // Motion-Gated Gravity Reference:
      // - Stationary (Variance Low AND Low Divergence): Trust accelerometer (alpha = 0.05)
      // - Vehicle (High Divergence OR High Variance): Mostly trust gyro (alpha = minAlpha)
      //
      // CRITICAL FIX: Pure gyro integration (alpha=0.0) causes 1-3°/min drift.
      // This translates to ~0.26 m/s² error after 5 min → 468m position error after 60s.
      // Solution: Always blend a tiny amount of accel reference when |a| ≈ g (±0.3 m/s²).
      // The minAlpha=0.002 corrects ~0.12°/s drift with negligible lateral accel leak.

      // Note: We override _motionState if divergence is high.
      final isDivergent = divergence > 0.01;
      final effectiveStationary =
          _motionState == MotionState.stationary &&
          _accelVariance() <= accelVarThreshold &&
          !isDivergent;

      // Check if accel magnitude is close to gravity (9.81 ± 0.3 m/s²)
      // This indicates no significant lateral/longitudinal acceleration,
      // so we can safely blend in a small amount of accel reference.
      final accelMag = _accelLpf != null ? _norm(_accelLpf!) : _norm([ax, ay, az]);
      const gravityMag = 9.81;
      const gravityTol = 0.3; // Allow ±0.3 m/s² deviation
      final accelNearGravity = (accelMag - gravityMag).abs() <= gravityTol;
      
      // Minimum alpha when accel magnitude ≈ gravity (even during vehicle motion)
      // This prevents pure gyro integration drift while being safe from lateral accel
      const minAlpha = 0.002;
      
      double currentAlpha;
      if (effectiveStationary) {
        currentAlpha = 0.05; // Strong correction when stationary
      } else if (accelNearGravity && !isDivergent) {
        currentAlpha = minAlpha; // Tiny correction during smooth vehicle motion
      } else {
        currentAlpha = 0.0; // Pure gyro during acceleration/braking
      }

      if (currentAlpha > 0) {
        _gHat = _normalize(_blend(gPred, gMeas, currentAlpha));
      } else {
        _gHat = _normalize(gPred);
      }
    }

    if (_gHat == null) return null;

    final norm = _norm(_gHat!);
    if ((norm - 1.0).abs() > gravityNormTol) {
      _gHat = gMeas;
    }

    final pitch = math.atan2(
      -_gHat![0],
      math.sqrt(_gHat![1] * _gHat![1] + _gHat![2] * _gHat![2]),
    );
    final roll = math.atan2(_gHat![1], _gHat![2]);
    final r = _rotationFromPitchRoll(pitch, roll);

    return TiltFilterOutput(
      gravityDevice: _gHat!,
      rDeviceToWorld: r,
      pitchRad: pitch,
      rollRad: roll,
      timestamp: sample.timestamp,
    );
  }

  void setMotionState(MotionState state) {
    _motionState = state;
  }

  MotionState _motionState = MotionState.vehicle;

  void reset() {
    _lastTs = null;
    _gHat = null;
    _accelLpf = null;
    _accelMagWindow.clear();
    _accelMagSum = 0.0;
    _accelMagSumSq = 0.0;
    _motionState = MotionState.vehicle;
  }

  TiltFilterOutput? _lastOutput(Duration ts) {
    if (_gHat == null) return null;
    final pitch = math.atan2(
      -_gHat![0],
      math.sqrt(_gHat![1] * _gHat![1] + _gHat![2] * _gHat![2]),
    );
    final roll = math.atan2(_gHat![1], _gHat![2]);
    return TiltFilterOutput(
      gravityDevice: _gHat!,
      rDeviceToWorld: _rotationFromPitchRoll(pitch, roll),
      pitchRad: pitch,
      rollRad: roll,
      timestamp: ts,
    );
  }

  List<double> _updateLowPass(
    List<double>? prev,
    double ax,
    double ay,
    double az,
    double dt,
  ) {
    final rc = 1.0 / (2 * math.pi * lpfCutoffHz);
    final k = dt <= 0 ? 1.0 : dt / (rc + dt);
    if (prev == null) {
      return [ax, ay, az];
    }
    return [
      prev[0] + k * (ax - prev[0]),
      prev[1] + k * (ay - prev[1]),
      prev[2] + k * (az - prev[2]),
    ];
  }

  void _pushAccelMag(double mag, double dt) {
    _accelMagWindow.add(mag);
    _accelMagSum += mag;
    _accelMagSumSq += mag * mag;

    final maxCount = math.max(1, (varianceWindowSec / dt).round());
    while (_accelMagWindow.length > maxCount) {
      final removed = _accelMagWindow.removeAt(0);
      _accelMagSum -= removed;
      _accelMagSumSq -= removed * removed;
    }
  }

  double _accelVariance() {
    final n = _accelMagWindow.length;
    if (n <= 1) return double.infinity;
    final mean = _accelMagSum / n;
    final meanSq = _accelMagSumSq / n;
    return (meanSq - mean * mean).abs();
  }

  List<double> _integrateGyro(
    List<double> g,
    double gx,
    double gy,
    double gz,
    double dt,
  ) {
    final cross = [
      gy * g[2] - gz * g[1],
      gz * g[0] - gx * g[2],
      gx * g[1] - gy * g[0],
    ];
    return [g[0] + cross[0] * dt, g[1] + cross[1] * dt, g[2] + cross[2] * dt];
  }

  List<double> _blend(List<double> a, List<double> b, double t) {
    return [
      (1 - t) * a[0] + t * b[0],
      (1 - t) * a[1] + t * b[1],
      (1 - t) * a[2] + t * b[2],
    ];
  }

  List<double> _normalize(List<double> v) {
    final n = _norm(v);
    if (n == 0) return [0, 0, 1];
    return [v[0] / n, v[1] / n, v[2] / n];
  }

  double _norm(List<double> v) =>
      math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);

  List<List<double>> _rotationFromPitchRoll(double pitch, double roll) {
    final cp = math.cos(pitch);
    final sp = math.sin(pitch);
    final cr = math.cos(roll);
    final sr = math.sin(roll);

    // R = R_y(pitch) * R_x(roll)
    return [
      [cp, sp * sr, sp * cr],
      [0.0, cr, -sr],
      [-sp, cp * sr, cp * cr],
    ];
  }
}
