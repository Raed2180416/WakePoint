# SnapToRoute (lib/services/snap_to_route.dart)

Purpose: Projects a point onto a polyline to get lateral offset, progress (meters), and segment index.

- `SnapToRouteEngine.snap(point, polyline, hintIndex?, searchWindow=20)`: lines 20–73 —
	- Precompute cumulative distances; search around `hintIndex±window` if provided to reduce cost.
	- For each segment, project onto segment in equirectangular meters; choose minimal distance.
	- Return best snapped point, lateral offset, cumulative progress, and segment index.
- `_projectPointOnSegment(...)`: lines 82–114 — equirectangular projection with clamping and back-conversion.
- `_dist(...)`: line 78 — haversine via Geolocator.
- Used to feed `ActiveRouteManager`/`DeviationMonitor` and for candidate route comparison.
