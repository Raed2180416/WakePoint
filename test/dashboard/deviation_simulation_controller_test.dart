/// Tests for deviation simulation controller.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/dashboard/constraint_logger.dart';
import 'package:geowake2/dashboard/deviation_simulation_controller.dart';
import 'package:geowake2/dashboard/simulation_state.dart';
import 'package:geowake2/services/testing/osm_loader.dart';

void main() {
  group('DeviationSimulationController', () {
    late DeviationSimulationController controller;

    setUp(() {
      AppClock.reset();
      ConstraintLogger.resetForTesting();
    });

    tearDown(() {
      controller.dispose();
      AppClock.reset();
    });

    group('without OSM graph', () {
      setUp(() {
        controller = DeviationSimulationController();
      });

      test('starts in idle state', () {
        expect(controller.state, SimulationState.idle);
      });

      test('loadRoute sets initial position and path', () {
        final route = [
          const LatLng(12.9716, 77.5946),
          const LatLng(12.9720, 77.5950),
          const LatLng(12.9725, 77.5955),
        ];

        controller.loadRoute(route, routeId: 'test-route');

        expect(controller.originalRoute, route);
        expect(controller.currentPath, route);
        expect(controller.currentPosition, route.first);
      });

      test('start() enables simulation mode and transitions to onRoute', () {
        controller.loadRoute([
          const LatLng(12.9716, 77.5946),
          const LatLng(12.9720, 77.5950),
        ]);

        controller.start();

        expect(controller.state, SimulationState.onRoute);
        expect(AppClock().isSimulating, isTrue);
      });

      test('stop() disables simulation mode and transitions to idle', () {
        controller.loadRoute([
          const LatLng(12.9716, 77.5946),
          const LatLng(12.9720, 77.5950),
        ]);

        controller.start();
        controller.stop();

        expect(controller.state, SimulationState.idle);
        expect(AppClock().isSimulating, isFalse);
      });

      test('pause() and resume() work correctly', () {
        controller.loadRoute([
          const LatLng(12.9716, 77.5946),
          const LatLng(12.9720, 77.5950),
        ]);

        controller.start();
        expect(controller.state, SimulationState.onRoute);

        controller.pause();
        expect(controller.state, SimulationState.paused);

        controller.resume();
        expect(controller.state, SimulationState.onRoute);
      });

      test('seek() updates position along path', () {
        controller.loadRoute([
          const LatLng(12.9700, 77.5900),
          const LatLng(12.9800, 77.6000),
        ]);

        controller.seek(0.5);

        expect(controller.progress, closeTo(0.5, 0.01));
        expect(controller.currentPosition!.latitude, closeTo(12.975, 0.001));
      });

      test('speedMps setter clamps to valid range', () {
        controller.speedMps = 0.1;
        expect(controller.speedMps, 0.3); // Min 1 km/h

        controller.speedMps = 100.0;
        expect(controller.speedMps, 44.4); // Max 160 km/h

        controller.speedMps = 20.0;
        expect(controller.speedMps, 20.0);
      });

      test('setWarpFactor updates AppClock and logs event', () {
        controller.setWarpFactor(100.0);

        expect(controller.warpFactor, 100.0);
        expect(AppClock().warpFactor, 100.0);

        final events = ConstraintLogger.instance.eventsOfType(
          ConstraintEventType.warpFactorChange,
        );
        expect(events.length, 1);
        expect(events.first.details['newFactor'], 100.0);
      });

      test('startDeviation fails without graph', () {
        controller.loadRoute([
          const LatLng(12.9716, 77.5946),
          const LatLng(12.9720, 77.5950),
        ]);
        controller.start();

        controller.startDeviation();

        // Should still be onRoute since deviation failed
        expect(controller.state, SimulationState.onRoute);
      });
    });

    group('with OSM graph', () {
      setUp(() {
        final graph = OsmLoader.createTestGraph(
          centerLat: 12.9716,
          centerLon: 77.5946,
          gridSize: 10,
          spacingMeters: 50,
        );
        controller = DeviationSimulationController(graph: graph);
      });

      test('startDeviation transitions to deviating state', () {
        // Create a route that passes through the graph
        final route = [
          const LatLng(12.9710, 77.5946),
          const LatLng(12.9716, 77.5946),
          const LatLng(12.9722, 77.5946),
        ];

        controller.loadRoute(route);
        controller.start();

        controller.startDeviation();

        expect(controller.state, SimulationState.deviating);
        expect(controller.deviationPath.isNotEmpty, isTrue);
      });

      test('goBackToRoute transitions to returning state', () {
        final route = [
          const LatLng(12.9710, 77.5946),
          const LatLng(12.9722, 77.5946),
        ];

        controller.loadRoute(route);
        controller.start();
        controller.startDeviation();

        controller.goBackToRoute();

        expect(controller.state, SimulationState.returning);
      });

      test('stopDeviation returns to onRoute state', () {
        final route = [
          const LatLng(12.9710, 77.5946),
          const LatLng(12.9722, 77.5946),
        ];

        controller.loadRoute(route);
        controller.start();
        controller.startDeviation();

        controller.stopDeviation();

        expect(controller.state, SimulationState.onRoute);
      });
    });

    group('position stream', () {
      setUp(() {
        controller = DeviationSimulationController();
      });

      test('emits position updates when running', () async {
        controller.loadRoute([
          const LatLng(12.9700, 77.5900),
          const LatLng(12.9800, 77.6000),
        ]);

        final positions = <SimulationTickResult>[];
        final sub = controller.positionStream.listen(positions.add);

        controller.start();

        // Wait for some ticks
        await Future.delayed(const Duration(milliseconds: 100));

        controller.stop();
        await sub.cancel();

        expect(positions.isNotEmpty, isTrue);
        expect(positions.first.position, isNotNull);
        expect(positions.first.virtualTime, isNotNull);
      });
    });

    group('state stream', () {
      setUp(() {
        controller = DeviationSimulationController();
      });

      test('emits state changes', () async {
        controller.loadRoute([
          const LatLng(12.9700, 77.5900),
          const LatLng(12.9800, 77.6000),
        ]);

        final states = <SimulationState>[];
        final sub = controller.stateStream.listen(states.add);

        controller.start();
        controller.pause();
        controller.resume();
        controller.stop();

        await Future.delayed(Duration.zero);
        await sub.cancel();

        expect(states, [
          SimulationState.onRoute,
          SimulationState.paused,
          SimulationState.onRoute,
          SimulationState.idle,
        ]);
      });
    });

    group('constraint logging', () {
      setUp(() {
        controller = DeviationSimulationController();
        ConstraintLogger.resetForTesting();
      });

      test('logs route loaded event', () {
        controller.loadRoute([
          const LatLng(12.9716, 77.5946),
          const LatLng(12.9720, 77.5950),
        ]);

        final events = ConstraintLogger.instance.events;
        expect(events.any((e) => e.title == 'Route Loaded'), isTrue);
      });

      test('logs simulation start/stop events', () {
        controller.loadRoute([
          const LatLng(12.9716, 77.5946),
          const LatLng(12.9720, 77.5950),
        ]);

        controller.start();
        controller.stop();

        final events = ConstraintLogger.instance.events;
        expect(events.any((e) => e.title == 'Simulation Started'), isTrue);
        expect(events.any((e) => e.title == 'Simulation Stopped'), isTrue);
      });
    });
  });

  group('DeviationSimulationConfig', () {
    test('has sensible defaults', () {
      const config = DeviationSimulationConfig();

      expect(config.deviationDistanceM, 500);
      expect(config.routeAvoidanceRadiusM, 100);
      expect(config.returnThresholdM, 30);
      expect(config.defaultSpeedMps, closeTo(11.1, 0.1)); // 40 km/h
    });
  });

  group('SimulationTickResult', () {
    test('contains all required fields', () {
      final result = SimulationTickResult(
        position: const LatLng(12.9716, 77.5946),
        heading: 45.0,
        speedMps: 10.0,
        virtualTime: DateTime.now(),
        distanceFromRoute: 50.0,
      );

      expect(result.position.latitude, 12.9716);
      expect(result.heading, 45.0);
      expect(result.speedMps, 10.0);
      expect(result.distanceFromRoute, 50.0);
    });
  });
}
