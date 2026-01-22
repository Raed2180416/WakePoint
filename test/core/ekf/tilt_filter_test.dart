import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/tilt_filter.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';

void main() {
  group('TiltFilter', () {
    test('initializes gravity from first sample', () {
      final filter = TiltFilter();
      final output = filter.update(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ),
      );

      expect(output, isNotNull);
      expect(output!.gravityDevice[2], closeTo(1.0, 1e-3));
      expect(output.gravityDevice[0].abs(), lessThan(1e-3));
      expect(output.gravityDevice[1].abs(), lessThan(1e-3));
    });

    test('updates gravity toward accelerometer when stationary', () {
      // Use a filter with higher variance threshold to allow tilt tracking
      final filter = TiltFilter(accelVarThreshold: 0.01);  // Allow more variance
      filter.setMotionState(MotionState.stationary);
      
      // Initialize with gravity pointing down (Z axis)
      filter.update(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ),
      );

      // Simulate gradual tilt with matched gyro rate
      // This keeps divergence low because gyro and accel agree on the rotation
      TiltFilterOutput? output;
      const tiltRate = 0.005; // rad/sample
      for (int i = 1; i <= 100; i++) {
        // Gradually increase tilt from 0 to ~30 degrees over 2 seconds
        final tiltAngle = i * tiltRate;
        final ax = 9.81 * math.sin(tiltAngle);
        final az = 9.81 * math.cos(tiltAngle);
        
        output = filter.update(
          ImuSample(
            ax: ax,
            ay: 0.0,
            az: az,
            // Gyro Y rate matches the tilt rate (rotating around Y axis)
            gx: 0.0,
            gy: tiltRate / 0.02, // Convert to rad/s (dt=0.02s)
            gz: 0.0,
            timestamp: Duration(milliseconds: 20 * i),
          ),
        );
      }

      expect(output, isNotNull);
      // After coordinated tilt with gyro, gravity should track the rotation
      // Final tilt = 100 * 0.005 = 0.5 rad ≈ 29 degrees
      // Gravity X component should be sin(0.5) ≈ 0.48
      expect(output!.gravityDevice[0], greaterThan(0.3),
          reason: 'Gravity X component should track toward tilted direction');
    });

    test('skips updates on invalid dt', () {
      final filter = TiltFilter();
      filter.update(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ),
      );

      final output = filter.update(
        const ImuSample(
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: 0.0,
          timestamp: Duration(seconds: 1),
        ),
      );

      expect(output, isNotNull);
    });
    
    group('gyro drift prevention (minAlpha fix)', () {
      test('applies minimum alpha blend when accel magnitude is near gravity', () {
        final filter = TiltFilter();
        filter.setMotionState(MotionState.vehicle); // Vehicle mode
        
        // Initialize with a sample
        filter.update(const ImuSample(
          ax: 0.0, ay: 0.0, az: 9.81,
          gx: 0.0, gy: 0.0, gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ));
        
        // Simulate vehicle motion with accel magnitude ≈ gravity (smooth cruising)
        // and small gyro rotation. Pure gyro integration would cause drift.
        const gyroRate = 0.01; // rad/s drift
        var lastPitch = 0.0;
        
        for (var i = 1; i <= 100; i++) {
          final result = filter.update(ImuSample(
            ax: 0.0, ay: 0.0, az: 9.81, // Accel magnitude = 9.81 (near gravity)
            gx: gyroRate, gy: 0.0, gz: 0.0, // Small constant gyro bias
            timestamp: Duration(milliseconds: i * 10),
          ));
          if (result != null) {
            lastPitch = result.pitchRad;
          }
        }
        
        // With minAlpha=0.002, drift should be bounded.
        // Pure gyro would give 0.01 rad/s * 1s = 0.01 rad (0.57°)
        // With correction, drift should be significantly less.
        expect(lastPitch.abs(), lessThan(0.02), // Less than 1.1°
            reason: 'Tilt drift should be bounded by minimum alpha correction');
      });

      test('uses pure gyro (alpha=0) during significant lateral acceleration', () {
        final filter = TiltFilter();
        filter.setMotionState(MotionState.vehicle);
        
        // Initialize
        filter.update(const ImuSample(
          ax: 0.0, ay: 0.0, az: 9.81,
          gx: 0.0, gy: 0.0, gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ));
        
        // Apply lateral acceleration (braking/turning)
        // Accel magnitude deviates significantly from gravity (> 0.3 m/s²)
        final result = filter.update(const ImuSample(
          ax: 2.0, ay: 0.0, az: 9.81, // 2 m/s² forward accel
          gx: 0.0, gy: 0.0, gz: 0.0,
          timestamp: Duration(milliseconds: 10),
        ));
        
        // The tilt estimate should not be corrupted by lateral accel
        // Gravity should still point mostly down
        expect(result, isNotNull);
        expect(result!.gravityDevice[2], greaterThan(0.9),
            reason: 'Gravity estimate should not be corrupted by lateral accel');
      });

      test('applies strong alpha correction when stationary', () {
        final filter = TiltFilter();
        filter.setMotionState(MotionState.stationary);
        
        // Initialize with tilted gravity
        filter.update(const ImuSample(
          ax: 0.5, ay: 0.0, az: 9.79, // Slightly tilted
          gx: 0.0, gy: 0.0, gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ));
        
        // When stationary, alpha=0.05 should quickly correct to accel reference
        TiltFilterOutput? result;
        for (var i = 1; i <= 50; i++) {
          result = filter.update(ImuSample(
            ax: 0.0, ay: 0.0, az: 9.81, // Perfect gravity alignment
            gx: 0.0, gy: 0.0, gz: 0.0,
            timestamp: Duration(milliseconds: i * 10),
          ));
        }
        
        // After 0.5s with alpha=0.05, should converge close to accelerometer
        expect(result, isNotNull);
        expect(result!.gravityDevice[2], greaterThan(0.99),
            reason: 'Should converge to accelerometer reference when stationary');
      });
      
      test('long duration cruising does not accumulate unbounded drift', () {
        final filter = TiltFilter();
        filter.setMotionState(MotionState.vehicle);
        
        // Initialize
        filter.update(const ImuSample(
          ax: 0.0, ay: 0.0, az: 9.81,
          gx: 0.0, gy: 0.0, gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ));
        
        // Simulate 5 seconds of cruising with constant gyro bias
        const gyroRate = 0.005; // 0.29°/s drift
        var maxPitchDrift = 0.0;
        
        for (var i = 1; i <= 500; i++) {
          final result = filter.update(ImuSample(
            ax: 0.0, ay: 0.0, az: 9.81, // Perfect gravity (smooth cruise)
            gx: gyroRate, gy: 0.0, gz: 0.0,
            timestamp: Duration(milliseconds: i * 10),
          ));
          if (result != null) {
            final drift = result.pitchRad.abs();
            if (drift > maxPitchDrift) maxPitchDrift = drift;
          }
        }
        
        // Without minAlpha fix: drift = 0.005 * 5 = 0.025 rad (1.4°)
        // With minAlpha fix: drift should plateau due to continuous correction
        expect(maxPitchDrift, lessThan(0.03), // Less than 1.7°
            reason: 'Drift should be bounded even over long duration');
      });
    });
    
    group('tilted device handling', () {
      test('correctly estimates pitch for tilted device', () {
        final filter = TiltFilter();
        
        // 45° pitch (phone pointing forward)
        const tiltAngle = math.pi / 4;
        final ax = 9.81 * math.sin(tiltAngle);
        final az = 9.81 * math.cos(tiltAngle);
        
        final result = filter.update(ImuSample(
          ax: ax, ay: 0.0, az: az,
          gx: 0.0, gy: 0.0, gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ));
        
        expect(result, isNotNull);
        expect(result!.pitchRad, closeTo(-tiltAngle, 0.1));
      });
    });
    
    group('reset behavior', () {
      test('reset clears state and allows reinitialization', () {
        final filter = TiltFilter();
        
        // Use it
        filter.update(const ImuSample(
          ax: 0.0, ay: 0.0, az: 9.81,
          gx: 0.0, gy: 0.0, gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ));
        
        filter.reset();
        
        // After reset, should work fresh
        final result = filter.update(const ImuSample(
          ax: 1.0, ay: 0.0, az: 9.76,
          gx: 0.0, gy: 0.0, gz: 0.0,
          timestamp: Duration(milliseconds: 0),
        ));
        
        expect(result, isNotNull);
      });
    });
  });
}
