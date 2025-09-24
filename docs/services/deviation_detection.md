# Deviation Detection (lib/services/deviation_detection.dart)

Purpose: Simple closest-point and threshold-based deviation check against a route polyline.

- `findClosestPointOnRoute(currentLocation, route)`: line 25 — scans decoded polyline for nearest point; computes cumulative distance to that vertex.
- `determineThreshold(isOffline, currentLocation, route)`: line 50 — returns base threshold (600 m online, 1500 m offline); extendable.
- `isDeviationExceeded(currentLocation, activeRoute, isOffline)`: line 60 — compares distance to closest point vs threshold.

Notes: Superseded by `SnapToRouteEngine` + `DeviationMonitor` in core flows but remains useful for legacy code.

Tests: `deviation_decision_tree_test.dart` (via monitor), legacy-only here.
