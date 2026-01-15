/// Smart tracking termination policy using multiple behavioral signals.
///
/// Instead of terminating based on distance alone (which fails for highway
/// detours, metro line mistakes, etc.), this policy uses a combination of:
/// - Distance from original route
/// - Duration of deviation
/// - User movement speed/direction
/// - Failed reroute attempts
///
/// This reduces false positives while still catching genuine route abandonment.
library;

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/config/deviation_config.dart';

/// Tracks deviation state for termination decisions.
class DeviationTrackingState {
  /// Position when deviation was first detected
  final LatLng deviationStartPosition;

  /// Time when deviation started
  final DateTime deviationStartTime;

  /// Number of failed reroute attempts
  int failedRerouteAttempts;

  /// Last known position
  LatLng? lastPosition;

  /// Distance to destination when deviation started (meters)
  final double? initialDistanceToDestination;

  DeviationTrackingState({
    required this.deviationStartPosition,
    required this.deviationStartTime,
    this.failedRerouteAttempts = 0,
    this.lastPosition,
    this.initialDistanceToDestination,
  });
}

/// Result of termination check with user-facing message.
class TerminationDecision {
  final bool shouldTerminate;
  final String? reason;
  final String? userMessage;

  const TerminationDecision.continue_()
    : shouldTerminate = false,
      reason = null,
      userMessage = null;

  const TerminationDecision.terminate({
    required this.reason,
    required this.userMessage,
  }) : shouldTerminate = true;
}

/// Evaluates whether tracking should terminate based on behavioral signals.
class TrackingTerminationPolicy {
  /// Current deviation tracking state (null if on-route)
  DeviationTrackingState? _deviationState;

  /// The user's intended destination
  LatLng? _destination;

  /// Whether user was moving away from destination on last check
  bool _wasMovingAway = false;
  int _consecutiveMovingAwayCount = 0;

  /// Initialize with destination for direction analysis.
  void setDestination(LatLng destination) {
    _destination = destination;
  }

  /// Called when deviation is first detected.
  void onDeviationStart({required LatLng position, required DateTime at}) {
    double? distToDestination;
    if (_destination != null) {
      distToDestination = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        _destination!.latitude,
        _destination!.longitude,
      );
    }

    _deviationState = DeviationTrackingState(
      deviationStartPosition: position,
      deviationStartTime: at,
      lastPosition: position,
      initialDistanceToDestination: distToDestination,
    );
    _wasMovingAway = false;
    _consecutiveMovingAwayCount = 0;
  }

  /// Called when user returns to route.
  void onReturnToRoute() {
    _deviationState = null;
    _wasMovingAway = false;
    _consecutiveMovingAwayCount = 0;
  }

  /// Called when a reroute attempt fails.
  void onRerouteFailed() {
    _deviationState?.failedRerouteAttempts++;
  }

  /// Called when a reroute succeeds (resets state).
  void onRerouteSuccess() {
    _deviationState = null;
    _wasMovingAway = false;
    _consecutiveMovingAwayCount = 0;
  }

  /// Check if tracking should terminate.
  ///
  /// Uses multiple signals to avoid false positives:
  /// - RULE 1: Extreme distance (5km+) AND stopped/slow moving
  /// - RULE 2: Moderate distance (2km+) AND long duration (10min+) AND failed reroutes
  /// - RULE 3: Moving consistently away from destination while deviated
  TerminationDecision shouldTerminate({
    required LatLng currentPosition,
    required double speedMps,
    DateTime? at,
  }) {
    final state = _deviationState;
    if (state == null) {
      return const TerminationDecision.continue_();
    }

    final now = at ?? DateTime.now();
    state.lastPosition = currentPosition;

    // Calculate deviation distance from where we started deviating
    final deviationDistanceKm =
        Geolocator.distanceBetween(
          state.deviationStartPosition.latitude,
          state.deviationStartPosition.longitude,
          currentPosition.latitude,
          currentPosition.longitude,
        ) /
        1000.0;

    final deviationDuration = now.difference(state.deviationStartTime);

    // RULE 1: Extreme distance (5km+) AND stopped/slow moving
    // User has walked/driven far away and stopped - likely gave up
    if (deviationDistanceKm >= DeviationConfig.extremeDeviationKm &&
        speedMps < DeviationConfig.stoppedSpeedThresholdMps) {
      return TerminationDecision.terminate(
        reason:
            'Extreme deviation (${deviationDistanceKm.toStringAsFixed(1)}km) while stopped',
        userMessage:
            'Tracking ended: You appear to have stopped ${deviationDistanceKm.toStringAsFixed(1)}km from your route',
      );
    }

    // RULE 2: Moderate distance (2km+) AND long duration (10min+) AND failed reroutes
    // Multiple reroute failures + sustained deviation = routing impossible
    if (deviationDistanceKm >= DeviationConfig.moderateDeviationKm &&
        deviationDuration >= DeviationConfig.moderateDeviationDuration &&
        state.failedRerouteAttempts >=
            DeviationConfig.minFailedReroutesForTermination) {
      return TerminationDecision.terminate(
        reason:
            'Sustained deviation (${deviationDistanceKm.toStringAsFixed(1)}km, ${deviationDuration.inMinutes}min) with ${state.failedRerouteAttempts} failed reroutes',
        userMessage:
            'Tracking ended: Unable to find an alternate route after ${deviationDuration.inMinutes} minutes',
      );
    }

    // RULE 3: Moving consistently away from destination
    // If user is clearly heading the wrong way for extended period
    if (_destination != null &&
        deviationDistanceKm >= DeviationConfig.movingAwayDeviationKm) {
      final currentDistToDestination = Geolocator.distanceBetween(
        currentPosition.latitude,
        currentPosition.longitude,
        _destination!.latitude,
        _destination!.longitude,
      );

      final initialDist = state.initialDistanceToDestination;
      if (initialDist != null) {
        final isMovingAway =
            currentDistToDestination > initialDist + 500; // 500m buffer

        if (isMovingAway) {
          if (_wasMovingAway) {
            _consecutiveMovingAwayCount++;
          } else {
            _consecutiveMovingAwayCount = 1;
          }
          _wasMovingAway = true;

          // Terminate if consistently moving away (5 consecutive checks)
          if (_consecutiveMovingAwayCount >= 5 && speedMps > 1.0) {
            final extraDistanceKm =
                (currentDistToDestination - initialDist) / 1000.0;
            return TerminationDecision.terminate(
              reason:
                  'Moving away from destination (${extraDistanceKm.toStringAsFixed(1)}km further)',
              userMessage:
                  'Tracking ended: You appear to be heading away from your destination',
            );
          }
        } else {
          _wasMovingAway = false;
          _consecutiveMovingAwayCount = 0;
        }
      }
    }

    return const TerminationDecision.continue_();
  }

  /// Reset all state (for new tracking session).
  void reset() {
    _deviationState = null;
    _destination = null;
    _wasMovingAway = false;
    _consecutiveMovingAwayCount = 0;
  }

  /// Get current deviation duration (for UI display).
  Duration? get currentDeviationDuration {
    final state = _deviationState;
    if (state == null) return null;
    return AppClock().now().difference(state.deviationStartTime);
  }

  /// Get current deviation distance in km (for UI display).
  double? getDeviationDistanceKm(LatLng currentPosition) {
    final state = _deviationState;
    if (state == null) return null;
    return Geolocator.distanceBetween(
          state.deviationStartPosition.latitude,
          state.deviationStartPosition.longitude,
          currentPosition.latitude,
          currentPosition.longitude,
        ) /
        1000.0;
  }

  /// Whether currently in deviation state.
  bool get isDeviating => _deviationState != null;

  /// Number of failed reroute attempts.
  int get failedRerouteAttempts => _deviationState?.failedRerouteAttempts ?? 0;
}
