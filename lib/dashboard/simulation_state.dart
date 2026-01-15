/// Simulation state machine for deviation testing.
library;

import 'dart:async';

/// Possible simulation states.
enum SimulationState {
  /// Not simulating - normal app behavior.
  idle,

  /// Simulating movement along the active route.
  onRoute,

  /// Actively deviating away from route.
  deviating,

  /// Returning to original route after deviation.
  returning,

  /// Paused (simulation frozen but state preserved).
  paused,
}

/// State machine for simulation control.
class SimulationStateMachine {
  SimulationState _state = SimulationState.idle;
  final _stateController = StreamController<SimulationState>.broadcast();

  /// Stream of state changes.
  Stream<SimulationState> get stateStream => _stateController.stream;

  /// Current state.
  SimulationState get state => _state;

  /// Whether simulation is active (not idle).
  bool get isActive => _state != SimulationState.idle;

  /// Whether currently on route.
  bool get isOnRoute => _state == SimulationState.onRoute;

  /// Whether currently deviating.
  bool get isDeviating => _state == SimulationState.deviating;

  /// Whether currently returning to route.
  bool get isReturning => _state == SimulationState.returning;

  /// Whether paused.
  bool get isPaused => _state == SimulationState.paused;

  void _transition(SimulationState newState) {
    if (_state == newState) return;

    if (!_isValidTransition(_state, newState)) {
      throw StateError('Invalid transition: $_state -> $newState');
    }

    _state = newState;
    _stateController.add(_state);
  }

  bool _isValidTransition(SimulationState from, SimulationState to) {
    return switch ((from, to)) {
      (SimulationState.idle, SimulationState.onRoute) => true,
      (SimulationState.onRoute, SimulationState.deviating) => true,
      (SimulationState.onRoute, SimulationState.paused) => true,
      (SimulationState.deviating, SimulationState.returning) => true,
      (SimulationState.deviating, SimulationState.paused) => true,
      (SimulationState.deviating, SimulationState.onRoute) =>
        true, // Stop deviation
      (SimulationState.returning, SimulationState.onRoute) => true,
      (SimulationState.returning, SimulationState.paused) => true,
      (SimulationState.paused, SimulationState.onRoute) => true,
      (SimulationState.paused, SimulationState.deviating) => true,
      (SimulationState.paused, SimulationState.returning) => true,
      (_, SimulationState.idle) => true, // Can always stop
      _ => false,
    };
  }

  // ─────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────

  /// Start simulation on route.
  void start() => _transition(SimulationState.onRoute);

  /// Begin deviating from route.
  void startDeviation() => _transition(SimulationState.deviating);

  /// Stop deviation and return to on-route state.
  void stopDeviation() => _transition(SimulationState.onRoute);

  /// Begin returning to original route.
  void goBackToRoute() => _transition(SimulationState.returning);

  /// Called when simulation reaches original route.
  void onReachedRoute() => _transition(SimulationState.onRoute);

  /// Pause simulation.
  void pause() => _transition(SimulationState.paused);

  /// Resume from paused state.
  void resume() {
    if (_state != SimulationState.paused) return;
    // Resume to onRoute by default
    _transition(SimulationState.onRoute);
  }

  /// Stop simulation completely.
  void stop() => _transition(SimulationState.idle);

  /// Reset to initial state.
  void reset() {
    _state = SimulationState.idle;
    _stateController.add(_state);
  }

  /// Dispose resources.
  void dispose() {
    _stateController.close();
  }
}
