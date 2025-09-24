// Annotated copy of lib/services/eta_utils.dart
// Purpose: Explain ETA remaining interpolation across step boundaries.

class EtaUtils {
  // Compute remaining seconds given progress in meters and per-step boundaries/durations.
  // Returns null when inputs are inconsistent; 0 when route is complete.
  static double? etaRemainingSeconds({
    required double progressMeters,
    required List<double> stepBoundariesMeters,
    required List<double> stepDurationsSeconds,
  }) {
    // Validate lengths and non-emptiness
    if (stepBoundariesMeters.isEmpty ||
        stepDurationsSeconds.isEmpty ||
        stepBoundariesMeters.length != stepDurationsSeconds.length) {
      return null;
    }
    // Completed route
    if (progressMeters >= stepBoundariesMeters.last) return 0.0;

    // Find first boundary greater than progress
    int idx = 0;
    while (idx < stepBoundariesMeters.length && stepBoundariesMeters[idx] <= progressMeters) {
      idx++;
    }
    if (idx >= stepBoundariesMeters.length) return 0.0;

    // Interpolate remaining within current step
    final prevBoundary = idx == 0 ? 0.0 : stepBoundariesMeters[idx - 1];
    final stepLen = (stepBoundariesMeters[idx] - prevBoundary).clamp(0.0, double.infinity);
    final withinStep = (progressMeters - prevBoundary).clamp(0.0, stepLen);
    final remainInStepMeters = (stepLen - withinStep).clamp(0.0, stepLen);
    final stepDur = stepDurationsSeconds[idx];
    final currStepRemain = stepLen > 0 ? (remainInStepMeters / stepLen) * stepDur : 0.0;

    // Sum durations of the remaining tail steps
    double tail = 0.0;
    for (int j = idx + 1; j < stepDurationsSeconds.length; j++) {
      tail += stepDurationsSeconds[j];
    }
    return currStepRemain + tail;
  }
}
