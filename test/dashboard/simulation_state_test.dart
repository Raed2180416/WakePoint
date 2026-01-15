/// Tests for simulation state machine.
import 'package:flutter_test/flutter_test.dart';

import 'package:geowake2/dashboard/simulation_state.dart';

void main() {
  group('SimulationStateMachine', () {
    late SimulationStateMachine machine;

    setUp(() {
      machine = SimulationStateMachine();
    });

    tearDown(() {
      machine.dispose();
    });

    test('starts in idle state', () {
      expect(machine.state, SimulationState.idle);
      expect(machine.isActive, isFalse);
    });

    group('state transitions', () {
      test('idle -> onRoute via start()', () {
        machine.start();
        expect(machine.state, SimulationState.onRoute);
        expect(machine.isActive, isTrue);
        expect(machine.isOnRoute, isTrue);
      });

      test('onRoute -> deviating via startDeviation()', () {
        machine.start();
        machine.startDeviation();
        expect(machine.state, SimulationState.deviating);
        expect(machine.isDeviating, isTrue);
      });

      test('deviating -> returning via goBackToRoute()', () {
        machine.start();
        machine.startDeviation();
        machine.goBackToRoute();
        expect(machine.state, SimulationState.returning);
        expect(machine.isReturning, isTrue);
      });

      test('returning -> onRoute via onReachedRoute()', () {
        machine.start();
        machine.startDeviation();
        machine.goBackToRoute();
        machine.onReachedRoute();
        expect(machine.state, SimulationState.onRoute);
      });

      test('deviating -> onRoute via stopDeviation()', () {
        machine.start();
        machine.startDeviation();
        machine.stopDeviation();
        expect(machine.state, SimulationState.onRoute);
      });

      test('onRoute -> paused via pause()', () {
        machine.start();
        machine.pause();
        expect(machine.state, SimulationState.paused);
        expect(machine.isPaused, isTrue);
      });

      test('paused -> onRoute via resume()', () {
        machine.start();
        machine.pause();
        machine.resume();
        expect(machine.state, SimulationState.onRoute);
      });

      test('any state -> idle via stop()', () {
        machine.start();
        machine.startDeviation();
        machine.stop();
        expect(machine.state, SimulationState.idle);
      });
    });

    group('invalid transitions', () {
      test('throws on idle -> deviating', () {
        expect(() => machine.startDeviation(), throwsA(isA<StateError>()));
      });

      test('throws on idle -> returning', () {
        expect(() => machine.goBackToRoute(), throwsA(isA<StateError>()));
      });

      test('throws on idle -> paused', () {
        expect(() => machine.pause(), throwsA(isA<StateError>()));
      });
    });

    group('stream', () {
      test('emits state changes', () async {
        final states = <SimulationState>[];
        final sub = machine.stateStream.listen(states.add);

        machine.start();
        machine.startDeviation();
        machine.stop();

        await Future.delayed(Duration.zero);

        expect(states, [
          SimulationState.onRoute,
          SimulationState.deviating,
          SimulationState.idle,
        ]);

        await sub.cancel();
      });
    });

    test('reset() returns to idle', () {
      machine.start();
      machine.startDeviation();
      machine.reset();
      expect(machine.state, SimulationState.idle);
    });
  });
}
