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
    while (idx < stepBoundariesMeters.length &&
        stepBoundariesMeters[idx] <= progressMeters) {
      idx++;
    }
    if (idx >= stepBoundariesMeters.length) return 0.0;

    final prevBoundary = idx == 0 ? 0.0 : stepBoundariesMeters[idx - 1];
    final stepLen = (stepBoundariesMeters[idx] - prevBoundary).clamp(
      0.0,
      double.infinity,
    );
    final withinStep = (progressMeters - prevBoundary).clamp(0.0, stepLen);
    final remainInStepMeters = (stepLen - withinStep).clamp(0.0, stepLen);
    final stepDur = stepDurationsSeconds[idx];
    final currStepRemain =
        stepLen > 0 ? (remainInStepMeters / stepLen) * stepDur : 0.0;

    double tail = 0.0;
    for (int j = idx + 1; j < stepDurationsSeconds.length; j++) {
      tail += stepDurationsSeconds[j];
    }
    return currStepRemain + tail;
  }

  /// Estimate ETA (seconds) from [progressMeters] to an intermediate [targetMeters]
  /// along the same route, using step boundaries + step durations.
  ///
  /// Returns null if step metadata is missing or inconsistent.
  static double? etaToTargetSeconds({
    required double progressMeters,
    required double targetMeters,
    required List<double> stepBoundariesMeters,
    required List<double> stepDurationsSeconds,
  }) {
    if (stepBoundariesMeters.isEmpty ||
        stepDurationsSeconds.isEmpty ||
        stepBoundariesMeters.length != stepDurationsSeconds.length) {
      return null;
    }

    final total = stepBoundariesMeters.last;
    final p = progressMeters.clamp(0.0, total);
    final t = targetMeters.clamp(0.0, total);
    if (t <= p) return 0.0;

    int stepIndexAt(double meters) {
      int idx = 0;
      while (idx < stepBoundariesMeters.length &&
          stepBoundariesMeters[idx] <= meters) {
        idx++;
      }
      if (idx >= stepBoundariesMeters.length) {
        return stepBoundariesMeters.length - 1;
      }
      return idx;
    }

    double prevBoundary(int idx) =>
        idx == 0 ? 0.0 : stepBoundariesMeters[idx - 1];

    double partialStepSeconds({
      required int idx,
      required double fromMeters,
      required double toMeters,
    }) {
      final start = prevBoundary(idx);
      final end = stepBoundariesMeters[idx];
      final len = (end - start).clamp(0.0, double.infinity);
      if (len <= 0) return 0.0;
      final from = fromMeters.clamp(start, end);
      final to = toMeters.clamp(start, end);
      final metersIn = (to - from).clamp(0.0, len);
      final frac = metersIn / len;
      final dur = stepDurationsSeconds[idx].clamp(0.0, double.infinity);
      return dur * frac;
    }

    final startIdx = stepIndexAt(p);
    final endIdx = stepIndexAt(t);

    double eta = 0.0;
    if (startIdx == endIdx) {
      eta += partialStepSeconds(idx: startIdx, fromMeters: p, toMeters: t);
    } else {
      eta += partialStepSeconds(
        idx: startIdx,
        fromMeters: p,
        toMeters: stepBoundariesMeters[startIdx],
      );
      for (int i = startIdx + 1; i < endIdx; i++) {
        eta += stepDurationsSeconds[i].clamp(0.0, double.infinity);
      }
      eta += partialStepSeconds(
        idx: endIdx,
        fromMeters: prevBoundary(endIdx),
        toMeters: t,
      );
    }

    return eta.isFinite && eta >= 0 ? eta : null;
  }
}
