// Degraded mode logic (Stage H).

class DegradedMode {
  DegradedMode({
    this.maxSigmaMeters = 150,
    this.maxZuptGap = const Duration(minutes: 10),
    this.recoveryCheckInterval = const Duration(seconds: 1),
  });

  final double maxSigmaMeters;
  final Duration maxZuptGap;
  final Duration recoveryCheckInterval;

  bool _degraded = false;
  Duration? _lastZupt;
  Duration? _lastRecoveryCheck;

  bool get isDegraded => _degraded;

  void onZupt(Duration timestamp) {
    _lastZupt = timestamp;
  }

  void update({
    required Duration timestamp,
    required double sigmaS,
    required bool gpsRecovered,
  }) {
    final noZuptTooLong = _lastZupt == null
        ? true
        : timestamp - _lastZupt! >= maxZuptGap;

    if (sigmaS >= maxSigmaMeters || noZuptTooLong) {
      _degraded = true;
    }

    if (!_degraded) return;

    final shouldCheck = _lastRecoveryCheck == null ||
        timestamp - _lastRecoveryCheck! >= recoveryCheckInterval;
    if (!shouldCheck) return;
    _lastRecoveryCheck = timestamp;

    if (gpsRecovered || !noZuptTooLong) {
      _degraded = false;
    }
  }
}
