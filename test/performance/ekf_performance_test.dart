import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_orchestrator.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:flutter/foundation.dart';

void main() {
  group('EKF Performance Tests', () {
    late EkfOrchestrator orchestrator;
    late RouteGeometry route;

    setUp(() {
      // Create a 10km straight route
      final points = <LatLng>[
        const LatLng(0, 0),
        const LatLng(0.09, 0), // ~10km North
      ];
      route = RouteGeometry.fromPoints(points);
      orchestrator = EkfOrchestrator(route: route);
    });

    test('Throughput Benchmark: 1 hour of data at 100Hz', () {
      // 1 hour * 3600 sec/hr * 100 Hz = 360,000 samples
      const durationSeconds = 3600;
      const sampleRateHz = 100;
      const totalSamples = durationSeconds * sampleRateHz;

      // Pre-generate samples to avoid measuring generation time
      // Use steady walking motion: 1 step/sec, +/- 0.3g
      final samples = <ImuSample>[];
      var timestamp = Duration.zero;
      final dt = const Duration(milliseconds: 10);

      for (int i = 0; i < totalSamples; i++) {
        timestamp += dt;
        // Simple vertical oscillation
        final az = 9.81 + 0.3 * (i % 100 < 50 ? 1.0 : -1.0);
        samples.add(
          ImuSample(
            ax: 0.1, // Slight forward accel
            ay: 0.0,
            az: az,
            gx: 0.0,
            gy: 0.0,
            gz: 0.0,
            timestamp: timestamp,
          ),
        );
      }

      final stopwatch = Stopwatch()..start();

      for (final sample in samples) {
        orchestrator.onImuSample(sample);
      }

      stopwatch.stop();
      final elapsedMs = stopwatch.elapsedMilliseconds;
      // Protect against division by zero if it runs too fast (unlikely but possible)
      final safeElapsedMs = elapsedMs < 1 ? 1 : elapsedMs;
      final samplesPerSec = totalSamples / (safeElapsedMs / 1000.0);
      final speedupFactor = (durationSeconds * 1000) / safeElapsedMs;

      debugPrint('Processed $totalSamples samples in ${safeElapsedMs}ms');
      debugPrint('Throughput: ${samplesPerSec.toStringAsFixed(1)} samples/sec');
      debugPrint('Real-time Max Speedup: ${speedupFactor.toStringAsFixed(1)}x');

      // Assertions
      // 1. Throughput should be safely above real-time (100 Hz)
      // We aim for >20x speedup on typical dev machine.
      expect(
        speedupFactor,
        greaterThan(20.0),
        reason: "EKF processing is too slow!",
      );

      // 2. Numeric stability check
      // After 1 hour of dead reckoning (even with bias), numbers shouldn't explode to Infinity/NaN
      final state = orchestrator.publicState;
      expect(state.s.isFinite, isTrue);
      expect(state.v.isFinite, isTrue);
      expect(state.sigmaS.isFinite, isTrue);
    });

    test('Memory Stability: 10k GPS updates', () {
      // Verify no memory leaks or unbounded list growth in circular buffers
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < 10000; i++) {
        orchestrator.onGpsFixAuto(
          GpsFix(
            lat: 0.0001 * i,
            lng: 0,
            accuracyMeters: 10.0,
            speedMps: 0.0,
            timestamp: Duration(seconds: i),
          ),
        );

        // Interleave some IMU to trigger prediction/update cycles
        orchestrator.onImuSample(
          ImuSample(
            ax: 0,
            ay: 0,
            az: 9.81,
            gx: 0,
            gy: 0,
            gz: 0,
            timestamp: Duration(seconds: i, milliseconds: 500),
          ),
        );
      }

      stopwatch.stop();
      debugPrint(
        'Processed 10k GPS updates in ${stopwatch.elapsedMilliseconds}ms',
      );

      // Just ensuring it finishes without OOM or extreme slowness
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(5000),
      ); // < 0.5ms per update
    });
  });
}
