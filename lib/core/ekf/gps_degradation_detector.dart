// GPS degradation detector (Stage D).

class GpsDegradationDetector {
  GpsDegradationDetector({
    this.noFixSeconds = 5,
    this.badAccuracyMeters = 50,
    this.badInnovationSigma = 4.0,
    this.badFixCount = 3,
    this.holdSeconds = 10,
    this.goodFixCount = 3,
  });

  final int noFixSeconds;
  final double badAccuracyMeters;
  final double badInnovationSigma;
  final int badFixCount;
  final int holdSeconds;
  final int goodFixCount;

  bool _degraded = false;
  int _badCount = 0;
  int _goodCount = 0;
  Duration? _lastFixTs;
  Duration? _degradedSince;

  bool get isDegraded => _degraded;

  void onGpsFix({
    required Duration timestamp,
    required bool hasFix,
    required double accuracyMeters,
    required double innovationSigma,
  }) {
    if (hasFix) {
      _lastFixTs = timestamp;
    }

    final noFixTooLong =
        _lastFixTs == null ||
        timestamp - _lastFixTs! >= Duration(seconds: noFixSeconds);

    final badAccuracy = accuracyMeters > badAccuracyMeters;
    final badInnovation = innovationSigma > badInnovationSigma;

    final isBad = !hasFix || noFixTooLong || badAccuracy || badInnovation;

    if (isBad) {
      _badCount += 1;
      _goodCount = 0;
    } else {
      _goodCount += 1;
      _badCount = 0;
    }

    if (!_degraded && _badCount >= badFixCount) {
      _degraded = true;
      _degradedSince = timestamp;
    }

    if (_degraded) {
      final heldLongEnough = _degradedSince == null
          ? false
          : timestamp - _degradedSince! >= Duration(seconds: holdSeconds);

      if (heldLongEnough && _goodCount >= goodFixCount) {
        _degraded = false;
        _degradedSince = null;
        _goodCount = 0;
        _badCount = 0;
      }
    }
  }
}
