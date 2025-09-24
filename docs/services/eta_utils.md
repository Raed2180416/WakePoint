# EtaUtils (lib/services/eta_utils.dart)

Purpose: Computes remaining ETA given `progressMeters`, cumulative `stepBoundariesMeters`, and `stepDurationsSeconds`.

- Function: lines 1–21 — `etaRemainingSeconds(...)`
  - Validates arrays; returns null on mismatch.
  - If `progress >= lastBoundary` → 0.
  - Finds current step index where boundary > progress.
  - Computes within-step remaining by linear proportion of step distance.
  - Adds tail durations for remaining steps.

Tests: `eta_utils_test.dart`.
