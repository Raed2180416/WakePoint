import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/zupt_detector.dart';

void main() {
  group('ZuptDetector', () {
    test('confirms only after dwell duration', () {
      final detector = ZuptDetector();

      // Need to accumulate dwell time. dwellDuration is 800ms.
      // Feed samples at 100ms intervals to reach 800ms dwell.
      bool confirmed = false;
      for (var i = 0; i <= 10; i++) {
        confirmed = detector.update(
          timestamp: Duration(milliseconds: i * 100),
          motion: MotionState.stationary,
          velocityMps: 0.05,  // Below vThresh=0.8
          accelVariance: 0.5,  // Below accelVarThresh=1.0
          gyroVariance: 0.2,   // Below gyroVarThresh=0.40
        );
        if (confirmed) break;
      }

      expect(confirmed, isTrue);
    });

    test('does not confirm when motion is vehicle and velocity high', () {
      final detector = ZuptDetector();
      final confirmed = detector.update(
        timestamp: const Duration(seconds: 10),
        motion: MotionState.vehicle,
        velocityMps: 10.0,  // High velocity
        accelVariance: 0.5,
        gyroVariance: 0.2,
      );

      expect(confirmed, isFalse);
    });
    
    group('velocity gate during degraded mode (ultra-quiet fix)', () {
      test('fires ZUPT when ultra-quiet during degraded mode even with high velocity', () {
        final detector = ZuptDetector();
        
        // Simulate GPS dropout scenario where EKF velocity has drifted to 2 m/s
        // but the train is actually stopped (ultra-quiet IMU)
        bool confirmed = false;
        for (var i = 0; i <= 10; i++) {
          confirmed = detector.update(
            timestamp: Duration(milliseconds: i * 100),
            motion: MotionState.stationary,  // Motion classifier says stopped
            velocityMps: 2.0,  // EKF velocity has drifted (would fail normal vThresh=0.8)
            accelVariance: 0.1,  // Ultra-quiet: < 0.15 threshold
            gyroVariance: 0.03,  // Ultra-quiet: < 0.05 threshold
            isDegraded: true,  // GPS dropout
          );
          if (confirmed) break;
        }
        
        // Should fire because ultra-quiet path doesn't require velocity gate
        expect(confirmed, isTrue, 
            reason: 'Ultra-quiet IMU during degraded mode should trigger ZUPT regardless of velocity');
      });
      
      test('does NOT fire ZUPT during smooth cruising in degraded mode', () {
        final detector = ZuptDetector();
        
        // Simulate smooth cruising during GPS dropout
        // IMU is quiet but NOT ultra-quiet (train vibration present)
        bool confirmed = false;
        for (var i = 0; i <= 10; i++) {
          confirmed = detector.update(
            timestamp: Duration(milliseconds: i * 100),
            motion: MotionState.vehicle,  // Motion classifier says moving
            velocityMps: 15.0,  // High velocity
            accelVariance: 0.3,  // Quiet but NOT ultra-quiet (> 0.15)
            gyroVariance: 0.08,  // Quiet but NOT ultra-quiet (> 0.05)
            isDegraded: true,  // GPS dropout
          );
        }
        
        // Should NOT fire because:
        // 1. Normal path fails: velocity > 0.8
        // 2. Ultra-quiet path fails: variances > ultra-quiet thresholds
        // 3. Motion classifier says vehicle
        expect(confirmed, isFalse,
            reason: 'Smooth cruising during degraded mode should NOT trigger ZUPT');
      });
      
      test('fires ZUPT with normal velocity gate when not degraded', () {
        final detector = ZuptDetector();
        
        // Normal mode with low velocity
        bool confirmed = false;
        for (var i = 0; i <= 10; i++) {
          confirmed = detector.update(
            timestamp: Duration(milliseconds: i * 100),
            motion: MotionState.stationary,
            velocityMps: 0.3,  // Below vThresh
            accelVariance: 0.5,  // Meets normal threshold but NOT ultra-quiet
            gyroVariance: 0.2,  // Meets normal threshold but NOT ultra-quiet
            isDegraded: false,
          );
          if (confirmed) break;
        }
        
        expect(confirmed, isTrue,
            reason: 'Normal ZUPT path should work with low velocity');
      });
      
      test('does NOT fire ZUPT with high velocity when not degraded', () {
        final detector = ZuptDetector();
        
        // Normal mode but high velocity
        bool confirmed = false;
        for (var i = 0; i <= 10; i++) {
          confirmed = detector.update(
            timestamp: Duration(milliseconds: i * 100),
            motion: MotionState.stationary,
            velocityMps: 2.0,  // Above vThresh=0.8
            accelVariance: 0.1,  // Ultra-quiet
            gyroVariance: 0.03,  // Ultra-quiet
            isDegraded: false,  // NOT degraded - ultra-quiet path doesn't apply
          );
        }
        
        expect(confirmed, isFalse,
            reason: 'High velocity should prevent ZUPT in normal mode');
      });
      
      test('ultra-quiet path requires motion classifier to agree', () {
        final detector = ZuptDetector();
        
        // Ultra-quiet IMU during degraded mode, but motion classifier says vehicle
        bool confirmed = false;
        for (var i = 0; i <= 10; i++) {
          confirmed = detector.update(
            timestamp: Duration(milliseconds: i * 100),
            motion: MotionState.vehicle,  // Motion classifier disagrees
            velocityMps: 2.0,
            accelVariance: 0.1,  // Ultra-quiet
            gyroVariance: 0.03,  // Ultra-quiet
            isDegraded: true,
          );
        }
        
        // Should NOT fire because ultra-quiet path requires motionHint
        expect(confirmed, isFalse,
            reason: 'Ultra-quiet path requires motion classifier to say stationary');
      });
    });
    
    group('isCandidate timing', () {
      test('isCandidate true after zuptDuration but before confirmation', () {
        final detector = ZuptDetector();
        
        // First update starts the timer
        detector.update(
          timestamp: const Duration(milliseconds: 0),
          motion: MotionState.stationary,
          velocityMps: 0.1,
          accelVariance: 0.5,
          gyroVariance: 0.2,
        );
        
        // After 500ms (> 300ms zuptDuration but < 800ms dwellDuration)
        detector.update(
          timestamp: const Duration(milliseconds: 500),
          motion: MotionState.stationary,
          velocityMps: 0.1,
          accelVariance: 0.5,
          gyroVariance: 0.2,
        );
        
        expect(detector.isCandidate(const Duration(milliseconds: 500)), isTrue);
        expect(detector.isConfirmed, isFalse);
      });
    });
    
    group('dwell tracking', () {
      test('currentDwell returns elapsed time since condition start', () {
        final detector = ZuptDetector();
        
        detector.update(
          timestamp: const Duration(milliseconds: 0),
          motion: MotionState.stationary,
          velocityMps: 0.1,
          accelVariance: 0.5,
          gyroVariance: 0.2,
        );
        
        detector.update(
          timestamp: const Duration(milliseconds: 500),
          motion: MotionState.stationary,
          velocityMps: 0.1,
          accelVariance: 0.5,
          gyroVariance: 0.2,
        );
        
        final dwell = detector.currentDwell(const Duration(milliseconds: 500));
        expect(dwell, equals(const Duration(milliseconds: 500)));
      });
      
      test('currentDwell resets when conditions not met', () {
        final detector = ZuptDetector();
        
        detector.update(
          timestamp: const Duration(milliseconds: 0),
          motion: MotionState.stationary,
          velocityMps: 0.1,
          accelVariance: 0.5,
          gyroVariance: 0.2,
        );
        
        // Break conditions
        detector.update(
          timestamp: const Duration(milliseconds: 500),
          motion: MotionState.vehicle,
          velocityMps: 10.0,
          accelVariance: 5.0,
          gyroVariance: 1.0,
        );
        
        expect(detector.currentDwell(const Duration(milliseconds: 500)), isNull);
      });
    });
  });
}
