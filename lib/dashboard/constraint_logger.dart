/// Constraint event logging for simulation dashboard.
library;

import 'dart:async';

/// Types of constraint events.
enum ConstraintEventType {
  /// Deviation from route detected.
  deviationDetected,

  /// Deviation sustained for threshold duration.
  deviationSustained,

  /// Reroute triggered.
  rerouteTriggered,

  /// Reroute succeeded.
  rerouteSuccess,

  /// Reroute failed.
  rerouteFailed,

  /// Reroute skipped (cooldown active).
  rerouteSkipped,

  /// Termination policy check.
  terminationCheck,

  /// Returning to original route.
  returnToRoute,

  /// Back on route after return.
  backOnRoute,

  /// Alarm triggered.
  alarmTriggered,

  /// Alarm stopped.
  alarmStopped,

  /// Speed change.
  speedChange,

  /// Time warp factor change.
  warpFactorChange,

  /// Generic info event.
  info,

  /// Warning event.
  warning,

  /// Error event.
  error,
}

/// A single constraint event.
class ConstraintEvent {
  ConstraintEvent({
    required this.type,
    required this.timestamp,
    required this.title,
    this.details = const {},
    this.description,
  });

  /// Event type.
  final ConstraintEventType type;

  /// When the event occurred (virtual time if warped).
  final DateTime timestamp;

  /// Short title for display.
  final String title;

  /// Detailed data for the event.
  final Map<String, dynamic> details;

  /// Optional longer description.
  final String? description;

  /// Create a deviation detected event.
  factory ConstraintEvent.deviationDetected({
    required DateTime timestamp,
    required double offsetMeters,
    required double thresholdMeters,
  }) {
    return ConstraintEvent(
      type: ConstraintEventType.deviationDetected,
      timestamp: timestamp,
      title: 'Deviation Detected',
      details: {
        'offsetMeters': offsetMeters,
        'thresholdMeters': thresholdMeters,
      },
      description:
          'Off route by ${offsetMeters.toStringAsFixed(1)}m (threshold: ${thresholdMeters.toStringAsFixed(0)}m)',
    );
  }

  /// Create a deviation sustained event.
  factory ConstraintEvent.deviationSustained({
    required DateTime timestamp,
    required Duration duration,
    required double offsetMeters,
  }) {
    return ConstraintEvent(
      type: ConstraintEventType.deviationSustained,
      timestamp: timestamp,
      title: 'Deviation Sustained',
      details: {
        'durationMs': duration.inMilliseconds,
        'offsetMeters': offsetMeters,
      },
      description:
          'Sustained for ${duration.inSeconds}s at ${offsetMeters.toStringAsFixed(1)}m off route',
    );
  }

  /// Create a reroute triggered event.
  factory ConstraintEvent.rerouteTriggered({
    required DateTime timestamp,
    String? reason,
  }) {
    return ConstraintEvent(
      type: ConstraintEventType.rerouteTriggered,
      timestamp: timestamp,
      title: 'Reroute Triggered',
      details: {'reason': reason},
      description: reason ?? 'Reroute calculation started',
    );
  }

  /// Create a reroute success event.
  factory ConstraintEvent.rerouteSuccess({
    required DateTime timestamp,
    required int newRoutePoints,
  }) {
    return ConstraintEvent(
      type: ConstraintEventType.rerouteSuccess,
      timestamp: timestamp,
      title: 'Reroute Success',
      details: {'newRoutePoints': newRoutePoints},
      description: 'New route calculated with $newRoutePoints points',
    );
  }

  /// Create a reroute failed event.
  factory ConstraintEvent.rerouteFailed({
    required DateTime timestamp,
    required String error,
  }) {
    return ConstraintEvent(
      type: ConstraintEventType.rerouteFailed,
      timestamp: timestamp,
      title: 'Reroute Failed',
      details: {'error': error},
      description: error,
    );
  }

  /// Create a reroute skipped event.
  factory ConstraintEvent.rerouteSkipped({
    required DateTime timestamp,
    required String reason,
    Duration? cooldownRemaining,
  }) {
    return ConstraintEvent(
      type: ConstraintEventType.rerouteSkipped,
      timestamp: timestamp,
      title: 'Reroute Skipped',
      details: {
        'reason': reason,
        if (cooldownRemaining != null)
          'cooldownRemainingMs': cooldownRemaining.inMilliseconds,
      },
      description: reason,
    );
  }

  /// Create a termination check event.
  factory ConstraintEvent.terminationCheck({
    required DateTime timestamp,
    required bool shouldTerminate,
    required String reason,
  }) {
    return ConstraintEvent(
      type: ConstraintEventType.terminationCheck,
      timestamp: timestamp,
      title: shouldTerminate ? 'Termination: YES' : 'Termination: NO',
      details: {'shouldTerminate': shouldTerminate, 'reason': reason},
      description: reason,
    );
  }

  /// Create an info event.
  factory ConstraintEvent.info({
    required DateTime timestamp,
    required String title,
    String? description,
    Map<String, dynamic> details = const {},
  }) {
    return ConstraintEvent(
      type: ConstraintEventType.info,
      timestamp: timestamp,
      title: title,
      details: details,
      description: description,
    );
  }

  /// Create a warp factor change event.
  factory ConstraintEvent.warpFactorChange({
    required DateTime timestamp,
    required double oldFactor,
    required double newFactor,
  }) {
    return ConstraintEvent(
      type: ConstraintEventType.warpFactorChange,
      timestamp: timestamp,
      title: 'Warp: ${newFactor.toStringAsFixed(0)}x',
      details: {'oldFactor': oldFactor, 'newFactor': newFactor},
      description:
          'Time warp changed from ${oldFactor.toStringAsFixed(0)}x to ${newFactor.toStringAsFixed(0)}x',
    );
  }

  @override
  String toString() => 'ConstraintEvent($type, $title, $timestamp)';
}

/// Logger for constraint events during simulation.
class ConstraintLogger {
  ConstraintLogger._();

  static final ConstraintLogger _instance = ConstraintLogger._();

  /// Singleton instance.
  static ConstraintLogger get instance => _instance;

  final _events = <ConstraintEvent>[];
  final _eventController = StreamController<ConstraintEvent>.broadcast();

  /// Stream of new events.
  Stream<ConstraintEvent> get eventStream => _eventController.stream;

  /// All logged events.
  List<ConstraintEvent> get events => List.unmodifiable(_events);

  /// Number of events.
  int get eventCount => _events.length;

  /// Log an event.
  void log(ConstraintEvent event) {
    _events.add(event);
    _eventController.add(event);
  }

  /// Clear all events.
  void clear() {
    _events.clear();
  }

  /// Get events of a specific type.
  List<ConstraintEvent> eventsOfType(ConstraintEventType type) {
    return _events.where((e) => e.type == type).toList();
  }

  /// Get events since a timestamp.
  List<ConstraintEvent> eventsSince(DateTime since) {
    return _events.where((e) => e.timestamp.isAfter(since)).toList();
  }

  /// Get the last N events.
  List<ConstraintEvent> lastEvents(int count) {
    if (count >= _events.length) return List.of(_events);
    return _events.sublist(_events.length - count);
  }

  /// Dispose resources.
  void dispose() {
    _eventController.close();
  }

  /// Reset for testing.
  static void resetForTesting() {
    _instance._events.clear();
  }
}
