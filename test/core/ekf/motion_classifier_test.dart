import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/motion_classifier.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'dart:math' as math;

void main() {
  group('MotionClassifier', () {
    test('biases to stationary on low variance and recent ZUPT', () {
      final classifier = MotionClassifier();
      final state = classifier.classify(
        accelVariance: 1e-4,
        gyroVariance: 1e-5,
        fftWalkEnergy: 0.1,
        fftTrainEnergy: 0.1,
        sigmaV: 0.1,
        recentZupt: true,
        innovationSigma: 1.0,
        ekfWeight: 0.3,
      );

      expect(state, MotionState.stationary);
    });

    test('classifies human when walk band dominates and not stationary', () {
      final classifier = MotionClassifier();
      // Use higher variances to avoid stationary detection
      final state = classifier.classify(
        accelVariance: 0.8,  // Above 0.5 threshold
        gyroVariance: 0.15,  // Above 0.10 threshold
        fftWalkEnergy: 10.0,
        fftTrainEnergy: 1.0,
        sigmaV: 2.0,  // Above 0.5 threshold
        recentZupt: false,
        innovationSigma: 1.0,
        ekfWeight: 0.3,
        fftEnabled: true,
      );

      expect(state, MotionState.human);
    });

    test('suppresses vehicle when innovation stays high', () {
      final classifier = MotionClassifier();
      // Use higher variances to avoid stationary detection
      final state = classifier.classify(
        accelVariance: 0.8,  // Above stationary threshold
        gyroVariance: 0.15,  // Above stationary threshold
        fftWalkEnergy: 0.1,
        fftTrainEnergy: 1.0,
        sigmaV: 2.0,  // High uncertainty
        recentZupt: false,
        innovationSigma: 4.0,
        innovationHighSeconds: 12.0,
        ekfWeight: 0.3,
        fftEnabled: true,
      );

      expect(state, MotionState.human);
    });
    
    test('velocity hard gate returns vehicle when moving fast', () {
      final classifier = MotionClassifier();
      final state = classifier.classify(
        accelVariance: 0.1,  // Low variance (would be stationary)
        gyroVariance: 0.05,
        fftWalkEnergy: 0.1,
        fftTrainEnergy: 0.1,
        sigmaV: 0.1,
        recentZupt: false,
        innovationSigma: 1.0,
        ekfWeight: 0.3,
        ekfVelocity: 5.0,  // Moving fast
        isDegraded: false,
      );

      expect(state, MotionState.vehicle);
    });
    
    test('skips velocity hard gate during degraded mode', () {
      final classifier = MotionClassifier();
      final state = classifier.classify(
        accelVariance: 0.1,  // Low variance
        gyroVariance: 0.05,
        fftWalkEnergy: 0.1,
        fftTrainEnergy: 0.1,
        sigmaV: 0.3,
        recentZupt: false,
        innovationSigma: 1.0,
        ekfWeight: 0.3,
        ekfVelocity: 5.0,  // Moving fast (would trigger hard gate normally)
        isDegraded: true,  // But degraded mode skips velocity gate
        recentMaxAFwd: 0.05,  // No recent acceleration
      );

      // Should be stationary despite high velocity (velocity is drifted in DR)
      expect(state, MotionState.stationary);
    });
    
    test('uses aFwd to detect movement during degraded mode', () {
      final classifier = MotionClassifier();
      final state = classifier.classify(
        accelVariance: 0.1,  // Low variance
        gyroVariance: 0.05,
        fftWalkEnergy: 0.1,
        fftTrainEnergy: 0.1,
        sigmaV: 0.3,
        recentZupt: false,
        innovationSigma: 1.0,
        ekfWeight: 0.3,
        ekfVelocity: 0.0,  // Velocity stuck at 0
        isDegraded: true,
        recentMaxAFwd: 0.5,  // But significant forward accel observed
      );

      // Should be vehicle because aFwd indicates movement
      expect(state, MotionState.vehicle);
    });
  });

  group('MotionFeatureExtractor', () {
    test('walk band energy dominates for 1 Hz signal', () {
      final extractor = MotionFeatureExtractor();
      final sampleRate = 100.0;
      final samples = List<double>.generate(256, (i) {
        final t = i / sampleRate;
        return math.sin(2 * math.pi * 1.0 * t);
      });
      final gyro = List<double>.filled(256, 0.01);

      final features = extractor.extract(
        accelMagnitudes: samples,
        gyroMagnitudes: gyro,
        sampleRateHz: sampleRate,
      );

      expect(features.fftWalkEnergy, greaterThan(features.fftTrainEnergy));
    });

    test('train band energy dominates for 5 Hz signal', () {
      final extractor = MotionFeatureExtractor();
      final sampleRate = 100.0;
      final samples = List<double>.generate(256, (i) {
        final t = i / sampleRate;
        return math.sin(2 * math.pi * 5.0 * t);
      });
      final gyro = List<double>.filled(256, 0.01);

      final features = extractor.extract(
        accelMagnitudes: samples,
        gyroMagnitudes: gyro,
        sampleRateHz: sampleRate,
      );

      expect(features.fftTrainEnergy, greaterThan(features.fftWalkEnergy));
    });
  });
}
