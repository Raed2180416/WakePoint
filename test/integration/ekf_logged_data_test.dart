import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_orchestrator.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/core/ekf/imu_replay_engine_v2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EKF Replay Tests (Synthetic Data)', () {
    late ImuReplayEngineV2 engine;
    late EkfOrchestrator ekf;
    StreamSubscription? tickSub;
    StreamSubscription? gpsSub;
    StreamSubscription? accelSub;
    StreamSubscription? gyroSub;

    setUp(() {
      engine = ImuReplayEngineV2();
    });

    tearDown(() {
      engine.dispose();
      tickSub?.cancel();
      gpsSub?.cancel();
      accelSub?.cancel();
      gyroSub?.cancel();
    });

    test(
      'Majestic -> Nallur Halli (Metro Mode)',
      () async {
        try {
          await engine.loadTestRoute(TestRouteId.majesticToNallurHalli);
        } catch (e) {
          // Asset may be unavailable in test environment.
          return;
        }

        final route = RouteGeometry.fromPoints(engine.route!.fullPolyline);
        ekf = EkfOrchestrator(route: route);

        double lastAx = 0, lastAy = 0, lastAz = 0;
        double lastGx = 0, lastGy = 0, lastGz = 0;

        // Helper to generate Duration from engine's elapsed time (un-warping time)
        Duration getSimTime() {
          return Duration(
            microseconds: (engine.elapsedSeconds * 1000000).round(),
          );
        }

        gpsSub = engine.gpsStream.listen((pos) {
          ekf.onGpsFixAuto(
            GpsFix(
              lat: pos.latitude,
              lng: pos.longitude,
              accuracyMeters: pos.accuracy,
              speedMps: pos.speed,
              timestamp: getSimTime(), // CRITICAL: Use sim time
            ),
          );
        });

        void emitImu() {
          ekf.onImuSample(
            ImuSample(
              ax: lastAx,
              ay: lastAy,
              az: lastAz,
              gx: lastGx,
              gy: lastGy,
              gz: lastGz,
              timestamp: getSimTime(), // CRITICAL: Use sim time
            ),
          );
        }

        accelSub = engine.accelerometerStream.listen((e) {
          lastAx = e.x;
          lastAy = e.y;
          lastAz = e.z;
          emitImu();
        });

        gyroSub = engine.gyroscopeStream.listen((e) {
          lastGx = e.x;
          lastGy = e.y;
          lastGz = e.z;
          emitImu();
        });

        final errors = <double>[];
        final maxErrorThreshold = 200.0;

        tickSub = engine.tickStream.listen((tick) {
          final est = ekf.publicState;
          final groundTruth = tick.progressMeters;

          if (est.s > 0) {
            final error = (est.s - groundTruth).abs();
            errors.add(error);

            if (tick.elapsedSeconds % 120 < 1.0) {
              // Log every 2 mins
              print(
                'T=${tick.elapsedSeconds.toStringAsFixed(0)}s | '
                'GT=${groundTruth.toStringAsFixed(1)}m | '
                'EST=${est.s.toStringAsFixed(1)}m | '
                'Err=${error.toStringAsFixed(1)}m | '
                'Sigma=${est.sigmaS.toStringAsFixed(1)}',
              );
            }
          }
        });

        engine.warpFactor = 50.0;
        engine.play();

        await Future.doWhile(() async {
          await Future.delayed(const Duration(milliseconds: 100));
          return engine.isPlaying;
        });

        if (errors.isEmpty) fail("No EKF states recorded");

        final avgError = errors.reduce((a, b) => a + b) / errors.length;
        final maxError = errors.reduce((a, b) => a > b ? a : b);

        print(
          'RESULT: Avg Error: ${avgError.toStringAsFixed(2)}m, Max Error: ${maxError.toStringAsFixed(2)}m',
        );

        expect(avgError, lessThan(50.0), reason: "Average error too high");
        expect(
          maxError,
          lessThan(maxErrorThreshold),
          reason: "Max error exceeded threshold",
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
