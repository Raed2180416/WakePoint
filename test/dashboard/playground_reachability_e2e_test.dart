// END-TO-END through the SIMULATION PLAYGROUND ENGINE.
//
// This drives the REAL playground engine the web dashboard uses —
// EkfTestController + ImuReplayEngineV2 + EkfOrchestrator — over the synthetic
// curated metro routes (18–23 stations, ~20–23 km, built from
// all_india_stops.dart) under tunnel-style and complete GPS dropout, and
// asserts the NEVER-LATE reachability cone fires at/before the true arrival on
// every run. It also reports how EARLY the provable cone fires (the margin the
// tightening work shrinks) and contrasts it with the EKF point-estimate alarm.
//
// Why synthetic routes: the captured real-IMU replay logs (~285 MB) are
// deliberately NOT bundled in the repo (APK-size), so the engine's log-replay
// path can't load them in CI. The synthetic routes are self-contained (no
// assets), so this runs anywhere and gates the playground path in CI. The
// captured-log path is exercised separately on the founder machine.
//
// deterministicReplay=true (engine default) makes every tick advance a fixed
// sim delta, so the RESULT is wall-clock independent; warpFactor only controls
// how fast it completes in real time.
//
// Run: flutter test test/dashboard/playground_reachability_e2e_test.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/ekf/ekf_test_controller.dart';
import 'package:geowake2/core/ekf/imu_replay_engine_v2.dart';

class _Run {
  final TestRouteId route;
  final GpsDropoutMode dropout;
  final EkfReachResult? reach;
  final EkfAlarmResult? alarm;
  final double routeMeters;
  final double routeDurSeconds;

  /// Sim time when GROUND TRUTH reached the wake target (the never-late deadline
  /// for this run). Null if truth never reached the target during playback.
  final double? trueTargetArrivalSeconds;

  _Run(this.route, this.dropout, this.reach, this.alarm, this.routeMeters,
      this.routeDurSeconds, this.trueTargetArrivalSeconds);

  /// Seconds the cone fired BEFORE ground truth reached the wake target.
  /// >= 0 <=> never-late. This is the honest "how early" for the wake alarm.
  double? get earlySecondsVsTarget {
    final r = reach;
    final t = trueTargetArrivalSeconds;
    if (r == null || t == null) return null;
    return t - r.fireElapsedSeconds;
  }
}

Future<_Run> _drive(TestRouteId route, GpsDropoutMode dropout) async {
  final c = EkfTestController();
  c.logVerbosity = 0; // keep the test output clean
  c.injectImu = false; // no external TrackingService listener in this harness
  c.injectGps = false;
  c.gpsDropoutMode = dropout;
  c.warpFactor = 200.0; // applied to the engine inside loadRoute
  c.reachWakeStopsBeforeDestination = 2; // wake before the stop (as the app does)

  EkfReachResult? reach;
  EkfAlarmResult? alarm;
  final done = Completer<void>();

  c.onReach = (r) => reach ??= r;
  c.onAlarm = (a) => alarm ??= a;
  c.onFinished = () {
    if (!done.isCompleted) done.complete();
  };

  await c.loadRoute(route);
  final r = c.route!;
  c.play();

  try {
    await done.future.timeout(const Duration(seconds: 120));
  } on TimeoutException {
    // fall through — assertions below surface a null/late reach
  } finally {
    c.pause();
  }

  final out = _Run(route, dropout, reach, alarm, r.totalMeters,
      r.totalDurationSeconds, c.reachTrueTargetArrivalSeconds);
  c.dispose();
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Real Bengaluru Purple Line metro routes (curved polylines + station
  // arc-lengths + timing, rebuilt from ride ground truth into
  // assets/ekf_test_routes/bengaluru_metro_routes.json). These are the actual
  // GPS-dark underground scenario the never-late cone exists for.
  const routes = [
    TestRouteId.majesticToNallurHalli, // Purple, ~21 km, 13 stations
    TestRouteId.nallurHalliToVijayanagar, // Purple, ~24 km, 16 stations
  ];
  // tunnelSimulation: GPS only near stations (re-anchors mid-ride).
  // completeDropout: GPS dead after the first fix (pure cold-start cone) —
  // the extreme early-firing case.
  const dropouts = [
    GpsDropoutMode.tunnelSimulation,
    GpsDropoutMode.completeDropout,
  ];

  test(
    'PLAYGROUND E2E — never-late reachability cone through the real replay engine',
    () async {
      final runs = <_Run>[];
      for (final route in routes) {
        for (final dropout in dropouts) {
          runs.add(await _drive(route, dropout));
        }
      }

      // Report table. "earlyVsTarget" = seconds the cone fired before ground
      // truth reached the WAKE target (the honest never-late margin).
      // "earlyMeters" = how far the provable cone was ahead of true progress at
      // fire (the tightness the SOTA tightening work shrinks).
      stdout.writeln('\nPLAYGROUND reachability (real engine, real Bengaluru Purple Line):');
      stdout.writeln('route/dropout                             | reachFire '
          '| earlyVsTarget    | earlyMeters | ekfAlarmLead');
      for (final r in runs) {
        final tag = '${r.route.name}/${r.dropout.name}'.padRight(41);
        final reach = r.reach;
        final fire = reach == null
            ? 'NEVER'
            : '${reach.fireElapsedSeconds.toStringAsFixed(0)}s';
        final es = r.earlySecondsVsTarget;
        final early = es == null
            ? '   -   '
            : '${es.toStringAsFixed(0)}s (${(es / 60).toStringAsFixed(1)}min)';
        final earlyM = reach == null
            ? '   -   '
            : (reach.earlyMeters.isFinite
                ? '${reach.earlyMeters.toStringAsFixed(0)}m'
                : 'inf');
        final ekf = r.alarm == null
            ? 'never'
            : '${r.alarm!.leadSeconds.toStringAsFixed(0)}s';
        stdout.writeln('$tag | ${fire.padRight(9)} | ${early.padRight(16)} '
            '| ${earlyM.padRight(11)} | $ekf');
      }
      stdout.writeln('');

      // Assertions: on EVERY run the never-late cone must (a) fire, and (b) fire
      // at or before GROUND TRUTH reached the wake target (earlySecondsVsTarget
      // >= 0). This is the safety guarantee, proven through the playground's own
      // engine on real replayed routes.
      for (final r in runs) {
        final label = '${r.route.name}/${r.dropout.name}';
        expect(r.reach, isNotNull,
            reason: 'reachability never fired for $label — the never-late '
                'safety net did not engage');
        expect(r.trueTargetArrivalSeconds, isNotNull,
            reason: 'ground truth never reached the wake target for $label');
        final early = r.earlySecondsVsTarget!;
        // 2s epsilon absorbs fixed-tick quantization at warp 200.
        expect(early, greaterThanOrEqualTo(-2.0),
            reason: 'LATE fire for $label: cone fired '
                '${r.reach!.fireElapsedSeconds.toStringAsFixed(0)}s but truth '
                'reached the target at '
                '${r.trueTargetArrivalSeconds!.toStringAsFixed(0)}s');
        // The bound must be a real, finite target crossing (sMax >= target).
        expect(r.reach!.sMaxMeters, greaterThanOrEqualTo(r.reach!.targetMeters),
            reason: 'cone fired below target for $label');
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
