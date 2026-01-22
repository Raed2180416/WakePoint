// Motion classifier (Stage E) - minimal scaffold.

import 'dart:math' as math;
import 'ekf_types.dart';

class MotionFeatures {
  final double accelVariance;
  final double gyroVariance;
  final double fftWalkEnergy;
  final double fftTrainEnergy;

  const MotionFeatures({
    required this.accelVariance,
    required this.gyroVariance,
    required this.fftWalkEnergy,
    required this.fftTrainEnergy,
  });
}

class MotionFeatureExtractor {
  MotionFeatures extract({
    required List<double> accelMagnitudes,
    required List<double> gyroMagnitudes,
    required double sampleRateHz,
  }) {
    final accelVariance = _variance(accelMagnitudes);
    final gyroVariance = _variance(gyroMagnitudes);

    final accelBandEnergy = _bandEnergy(
      accelMagnitudes,
      sampleRateHz,
      minHz: 0.5,
      maxHz: 2.0,
    );
    final trainBandEnergy = _bandEnergy(
      accelMagnitudes,
      sampleRateHz,
      minHz: 4.0,
      maxHz: 6.0,
    );

    return MotionFeatures(
      accelVariance: accelVariance,
      gyroVariance: gyroVariance,
      fftWalkEnergy: accelBandEnergy,
      fftTrainEnergy: trainBandEnergy,
    );
  }

  double _variance(List<double> values) {
    if (values.isEmpty) return double.infinity;
    final mean = values.reduce((a, b) => a + b) / values.length;
    double acc = 0.0;
    for (final v in values) {
      final d = v - mean;
      acc += d * d;
    }
    return acc / values.length;
  }

  double _bandEnergy(
    List<double> samples,
    double sampleRateHz, {
    required double minHz,
    required double maxHz,
  }) {
    if (samples.length < 8) return 0.0;

    final n = samples.length;
    final mean = samples.reduce((a, b) => a + b) / n;
    final windowed = List<double>.generate(n, (i) {
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
      return (samples[i] - mean) * w;
    });

    final freqResolution = sampleRateHz / n;
    double energy = 0.0;
    final maxK = n ~/ 2;
    for (int k = 1; k <= maxK; k++) {
      final freq = k * freqResolution;
      if (freq < minHz || freq > maxHz) continue;
      double real = 0.0;
      double imag = 0.0;
      for (int i = 0; i < n; i++) {
        final angle = 2 * math.pi * k * i / n;
        real += windowed[i] * math.cos(angle);
        imag -= windowed[i] * math.sin(angle);
      }
      energy += real * real + imag * imag;
    }
    return energy;
  }
}

class MotionClassifier {
  MotionState classify({
    required double accelVariance,
    required double gyroVariance,
    required double fftWalkEnergy,
    required double fftTrainEnergy,
    required double sigmaV,
    required bool recentZupt,
    required double innovationSigma,
    required double ekfWeight,
    double innovationHighSeconds = 0.0,
    bool fftEnabled = true,
    double? ekfVelocity,  // EKF velocity for hard gate
    bool isDegraded = false,  // GPS dropout mode - velocity may be wrong
    double? recentMaxAFwd,  // Max forward accel magnitude in recent window
  }) {
    // Velocity hard gate: if moving fast, cannot be stationary.
    // BUT: Lower the threshold to 1.0 m/s (3.6 km/h) to allow ZUPT detection
    // during station approach and initial stop. Station stops have decel phase
    // where velocity drops from cruising to zero.
    //
    // CRITICAL: During GPS dropout (degraded mode), velocity drifts due to accel bias.
    // Skip the velocity hard gate and rely on IMU variance instead.
    if (!isDegraded && ekfVelocity != null && ekfVelocity.abs() > 1.0) {
      // Moving at > 1 m/s = definitely not stationary (only in normal mode)
      return MotionState.vehicle;
    }
    
    // CRITICAL: During GPS dropout, if we see significant forward acceleration,
    // the train is clearly moving - do NOT classify as stationary!
    // This prevents velocity from getting stuck at 0 during DR.
    // Threshold: 0.15 m/s² is typical train vibration during cruising.
    if (isDegraded && recentMaxAFwd != null && recentMaxAFwd > 0.15) {
      // Seeing > 0.15 m/s² accel during GPS dropout = train is moving
      return MotionState.vehicle;
    }
    
    // Thresholds for stationary detection calibrated from real station stop data
    // Real station stops: accelVar 0.15-0.5 (train vibration, HVAC), gyroVar 0.03-0.1 (phone jitter)
    // Metro cruising: accelVar 0.5+, gyroVar 0.1+
    final imuStationary =
        accelVariance < 0.5 && gyroVariance < 0.10;
    // EKF stationary: low velocity uncertainty indicates we've been corrected to near-zero
    final ekfStationary = sigmaV < 0.5;
    final stationaryScore =
        0.7 * (imuStationary ? 1.0 : 0.0) + 0.3 * (ekfStationary ? 1.0 : 0.0);

    if (stationaryScore >= 0.5) {
      return MotionState.stationary;
    }

    if (!fftEnabled) {
      return MotionState.vehicle;
    }

    final walkDominant = fftWalkEnergy > fftTrainEnergy;
    if (walkDominant) {
      return MotionState.human;
    }

    if (innovationHighSeconds >= 10.0 || innovationSigma > 3.0) {
      return MotionState.human;
    }

    return MotionState.vehicle;
  }
}
