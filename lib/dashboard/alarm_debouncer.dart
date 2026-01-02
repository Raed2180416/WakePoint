/// Utility for robust alarm state management (debounce & hold).
class AlarmDebouncer {
  bool _triggered = false;
  DateTime? _lastFired;
  final Duration holdDuration;

  AlarmDebouncer({this.holdDuration = const Duration(seconds: 2)});

  bool get isTriggered => _triggered;
  DateTime? get lastFired => _lastFired;

  /// Updates state based on server signal.
  /// Returns [true] if a *new* event should be logged (rising edge).
  bool update(bool serverFired, DateTime now) {
    bool shouldLog = false;

    if (serverFired) {
      if (!_triggered) {
        // Rising edge
        bool isNew = true;
        if (_lastFired != null && now.difference(_lastFired!) < holdDuration) {
          isNew = false;
        }

        if (isNew) {
          _lastFired = now;
          shouldLog = true;
        }
        _triggered = true;
      }
    } else {
      // Server says false. Hold visual state if within hold duration.
      if (_triggered &&
          _lastFired != null &&
          now.difference(_lastFired!) < holdDuration) {
        // Hold true
      } else {
        _triggered = false;
      }
    }
    return shouldLog;
  }

  void reset() {
    _triggered = false;
    // We keep _lastFired to prevent instant re-trigger if we scrub back into zone.
  }
}
