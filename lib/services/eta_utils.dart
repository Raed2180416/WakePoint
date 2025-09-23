class EtaUtils {
  static double? etaRemainingSeconds({
    required double progressMeters,
    required List<double> stepBoundariesMeters,
    required List<double> stepDurationsSeconds,
  }) {
    if (stepBoundariesMeters.isEmpty ||
        stepDurationsSeconds.isEmpty ||
        stepBoundariesMeters.length != stepDurationsSeconds.length) {
      return null;
    }
    // Completed route
    if (progressMeters >= stepBoundariesMeters.last) return 0.0;

    // Find current step index where boundary > progress
    int idx = 0;
    while (idx < stepBoundariesMeters.length && stepBoundariesMeters[idx] <= progressMeters) {
      idx++;
    }
    if (idx >= stepBoundariesMeters.length) return 0.0;

    final prevBoundary = idx == 0 ? 0.0 : stepBoundariesMeters[idx - 1];
    final stepLen = (stepBoundariesMeters[idx] - prevBoundary).clamp(0.0, double.infinity);
    final withinStep = (progressMeters - prevBoundary).clamp(0.0, stepLen);
    final remainInStepMeters = (stepLen - withinStep).clamp(0.0, stepLen);
    final stepDur = stepDurationsSeconds[idx];
    final currStepRemain = stepLen > 0 ? (remainInStepMeters / stepLen) * stepDur : 0.0;

    double tail = 0.0;
    for (int j = idx + 1; j < stepDurationsSeconds.length; j++) {
      tail += stepDurationsSeconds[j];
    }
    return currStepRemain + tail;
  }
}
