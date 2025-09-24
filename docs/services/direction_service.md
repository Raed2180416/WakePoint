# DirectionService (lib/services/direction_service.dart)

Purpose: Fetch directions via `ApiClient`, apply tiered refresh intervals, simplify/compress overview polyline, persist to `RouteCache`, and build segmented polylines with transit-aware styling.

- Imports: lines 1–9 — Flutter/Maps/Geolocator, polyline helpers, `ApiClient`, `RouteCache`, `dart:developer`.
- Fields: lines 11–16 — `_apiClient`, `_cachedDirections`, `_lastFetchTime`.
- Intervals: lines 19–22 — `far=15m`, `mid=7m`, `near=3m`.
- Ctor: line 24.
- `getDirections(...)`: lines 26–179
  - L2 cache read: lines 36–49 — `RouteCache.get` by origin/destination/mode/`transitVariant=rail`; hydrates in-memory cache.
  - Distance banding: lines 51–64 — choose `updateInterval` by straight distance vs threshold (distance mode) or `nearInterval` (time mode).
  - In-memory TTL: lines 66–69 — return if `elapsed < updateInterval`.
  - API call: lines 71–96 — `ApiClient.getDirections`; require `status=='OK'` and non-empty routes.
  - Simplify/compress: lines 99–138 — decode → simplify(10 m) → gzip+base64 compress; attach `simplified_polyline`.
  - Persist cache: lines 140–173 — write `RouteCacheEntry` with metadata; log on failure.
  - Errors: lines 175–179 — log+throw.
- `buildSegmentedPolylines(directions, transitMode)`: line 140 → EOF
  - Groups contiguous steps by type: `non_transit` (DRIVING/WALKING; dashed walking) vs `transit` (by line id).
  - Deterministic colors for transit lines (green/purple). Transit zIndex > non-transit.

Used by: Home screen fetch; `TrackingService.registerRouteFromDirections` for visuals and snapping.

Tests: `direction_service_behavior_test.dart`, `direction_service_caching_test.dart`, `simplified_polyline_present_test.dart`.
