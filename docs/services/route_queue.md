# RouteQueue (lib/services/route_queue.dart)

Purpose: Maintains a small FIFO queue of routes with a single active index; updates `isActive` flags.

- Class: line 5 — singleton with `maxSize=8`, `_routes`, `activeRouteIndex`.
- `addRoute(route)`: line 14 — evicts oldest if full; adjusts `activeRouteIndex`; sets new as active; updates flags.
- `getActiveRoute()`: line 27 — returns active or null.
- `setActiveRoute(index)`: line 34 — bounds check; updates flags.
- `_setActiveFlags()`: line 39 — toggles `isActive` by index.
- `routes`: line 46 — unmodifiable list.

Tests: covered indirectly via ActiveRouteManager and integration tests.
