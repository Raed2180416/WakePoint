# RouteCache (lib/services/route_cache.dart)
Caches directions responses by key (origin/destination/mode) with TTL and origin deviation invalidation.

- `RouteCacheEntry`: lines 9–51 — key, raw `directions`, `timestamp`, origin/destination, `mode`, optional simplified polyline (`scp`).
- Box: line 53 — Hive box storing JSON strings; `_ensureOpen()` recreates box on corruption.
- `makeKey(...)`: lines 77–92 — rounds lat/lng to 5 decimals; includes mode and transit variant; JSON string key.
- `get(...)`: lines 94–141 — retrieves and validates entry:
	- TTL: default 5 minutes; evicts stale.
	- Origin deviation: invalidate if current origin deviates ≥300 m from stored origin.
	- On decode failure: delete and return null.
- `put(entry)`: lines 143–149 — persist and flush.
- `clear()`: lines 151–156 — clear and flush.

Used by: `DirectionService` and `OfflineCoordinator`.
