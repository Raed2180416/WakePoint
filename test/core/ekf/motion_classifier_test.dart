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

    test('classifies human when walk band dominates', () {
      final classifier = MotionClassifier();
      final state = classifier.classify(
        accelVariance: 1e-3,
        gyroVariance: 1e-3,
        fftWalkEnergy: 10.0,
        fftTrainEnergy: 1.0,
        sigmaV: 1.0,
        recentZupt: false,
        innovationSigma: 1.0,
        ekfWeight: 0.3,
      );

      expect(state, MotionState.human);
    });

    test('suppresses vehicle when innovation stays high', () {
      final classifier = MotionClassifier();
      final state = classifier.classify(
        accelVariance: 1e-3,
        gyroVariance: 1e-3,
        fftWalkEnergy: 0.1,
        fftTrainEnergy: 1.0,
        sigmaV: 1.0,
        recentZupt: false,
        innovationSigma: 4.0,
        innovationHighSeconds: 12.0,
        ekfWeight: 0.3,
      );

      expect(state, MotionState.human);
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
