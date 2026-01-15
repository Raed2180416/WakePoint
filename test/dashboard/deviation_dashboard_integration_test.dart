import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/dashboard/constraint_logger.dart';
import 'package:geowake2/dashboard/deviation_simulation_controller.dart';
import 'package:geowake2/dashboard/simulation_state.dart';
import 'package:geowake2/services/testing/osm_graph.dart';
import 'package:geowake2/services/testing/osm_loader.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('DeviationSimulationController WebSocket integration', () {
    late DeviationSimulationController controller;
    late OsmGraph graph;

    setUp(() {
      AppClock.reset();
      ConstraintLogger.instance.clear();
      graph = OsmLoader.createTestGraph();
      controller = DeviationSimulationController(
        graph: graph,
        config: const DeviationSimulationConfig(
          deviationDistanceM: 300,
          routeAvoidanceRadiusM: 50,
          returnThresholdM: 25,
        ),
      );
    });

    tearDown(() {
      controller.dispose();
      ConstraintLogger.instance.clear();
      AppClock.reset();
    });

    test('loadRoute initializes state correctly', () {
      final route = [
        const LatLng(12.97, 77.59),
        const LatLng(12.98, 77.60),
        const LatLng(12.99, 77.61),
      ];

      controller.loadRoute(route, routeId: 'test_route');

      expect(controller.originalRoute, route);
      expect(controller.currentPosition, route.first);
      expect(controller.state, SimulationState.idle);
    });

    test('start transitions to onRoute state', () {
      final route = [const LatLng(12.97, 77.59), const LatLng(12.98, 77.60)];

      controller.loadRoute(route);
      controller.start();

      expect(controller.state, SimulationState.onRoute);
    });

    test('stop transitions back to idle state', () {
      final route = [const LatLng(12.97, 77.59), const LatLng(12.98, 77.60)];

      controller.loadRoute(route);
      controller.start();
      controller.stop();

      expect(controller.state, SimulationState.idle);
    });

    test('setWarpFactor updates AppClock and logs event', () async {
      final events = <ConstraintEvent>[];
      final sub = ConstraintLogger.instance.eventStream.listen(events.add);

      controller.setWarpFactor(50);
      await Future.delayed(const Duration(milliseconds: 10));

      expect(AppClock().warpFactor, 50);
      expect(
        events.any((e) => e.type == ConstraintEventType.warpFactorChange),
        isTrue,
      );

      await sub.cancel();
    });

    test('speedMps setter clamps to valid range', () {
      controller.speedMps = 0.1; // Below min
      expect(controller.speedMps, 0.3);

      controller.speedMps = 100; // Above max (44.4 m/s = 160 km/h)
      expect(controller.speedMps, 44.4);

      controller.speedMps = 11.1; // Normal
      expect(controller.speedMps, 11.1);
    });

    test('positionStream emits updates when running', () async {
      final route = [
        const LatLng(12.97, 77.59),
        const LatLng(12.98, 77.60),
        const LatLng(12.99, 77.61),
      ];

      controller.loadRoute(route);

      final updates = <SimulationTickResult>[];
      final sub = controller.positionStream.listen(updates.add);

      controller.start();

      // Wait for a few ticks (30 FPS = 33ms per tick)
      await Future.delayed(const Duration(milliseconds: 100));

      controller.stop();

      expect(updates.isNotEmpty, isTrue);
      expect(updates.first.position, isNotNull);
      expect(updates.first.virtualTime, isNotNull);

      await sub.cancel();
    });

    test('stateStream emits state changes', () async {
      final route = [const LatLng(12.97, 77.59), const LatLng(12.98, 77.60)];

      controller.loadRoute(route);

      final states = <SimulationState>[];
      final sub = controller.stateStream.listen(states.add);

      controller.start();
      await Future.delayed(const Duration(milliseconds: 10));

      controller.pause();
      await Future.delayed(const Duration(milliseconds: 10));

      controller.resume();
      await Future.delayed(const Duration(milliseconds: 10));

      controller.stop();
      await Future.delayed(const Duration(milliseconds: 10));

      expect(states, contains(SimulationState.onRoute));
      expect(states, contains(SimulationState.paused));
      expect(states, contains(SimulationState.idle));

      await sub.cancel();
    });
  });

  group('DeviationSimulationController with time warp', () {
    late DeviationSimulationController controller;

    setUp(() {
      AppClock.reset();
      ConstraintLogger.instance.clear();
      controller = DeviationSimulationController(
        config: const DeviationSimulationConfig(),
      );
    });

    tearDown(() {
      controller.dispose();
      ConstraintLogger.instance.clear();
      AppClock.reset();
    });

    test('time warp affects virtual time in tick results', () async {
      final route = [
        const LatLng(12.97, 77.59),
        const LatLng(12.98, 77.60),
        const LatLng(12.99, 77.61),
      ];

      controller.loadRoute(route);
      controller.setWarpFactor(100); // 100x warp
      controller.start();

      final updates = <SimulationTickResult>[];
      final sub = controller.positionStream.listen(updates.add);

      // Wait 50ms real time = 5 seconds virtual at 100x
      await Future.delayed(const Duration(milliseconds: 50));

      controller.stop();

      expect(updates.isNotEmpty, isTrue);

      // Check that virtual time advanced faster than real time
      if (updates.length >= 2) {
        final first = updates.first.virtualTime;
        final last = updates.last.virtualTime;
        final virtualElapsed = last.difference(first);

        // At 100x warp, even 30-50ms real should give >1s virtual
        expect(virtualElapsed.inMilliseconds, greaterThan(500));
      }

      await sub.cancel();
    });
  });

  group('Simulation control message handling', () {
    test('simulation control actions follow state machine rules', () {
      AppClock.reset();
      final controller = DeviationSimulationController();

      final route = [const LatLng(12.97, 77.59), const LatLng(12.98, 77.60)];
      controller.loadRoute(route);

      // Start simulation
      controller.start();
      expect(controller.state, SimulationState.onRoute);

      // Start again is a no-op (same state transition is ignored)
      controller.start();
      expect(controller.state, SimulationState.onRoute); // Still onRoute

      // Stop should work
      controller.stop();
      expect(controller.state, SimulationState.idle);

      // Stop again should work (always valid to stop)
      controller.stop();
      expect(controller.state, SimulationState.idle);

      controller.dispose();
      AppClock.reset();
    });

    test('deviation control requires running simulation', () {
      AppClock.reset();
      ConstraintLogger.instance.clear();

      final graph = OsmLoader.createTestGraph();
      final controller = DeviationSimulationController(graph: graph);

      final route = [const LatLng(12.97, 77.59), const LatLng(12.98, 77.60)];
      controller.loadRoute(route);

      // Cannot deviate when idle - returns early without throwing
      controller.startDeviation();
      expect(controller.state, SimulationState.idle); // Should stay idle

      controller.start();
      expect(controller.state, SimulationState.onRoute);

      // Now deviation should attempt (may fail if no path found)
      // but it shouldn't throw
      controller.startDeviation();

      controller.dispose();
      ConstraintLogger.instance.clear();
      AppClock.reset();
    });
  });
}
