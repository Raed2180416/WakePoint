# RouteRegistry (lib/services/route_registry.dart)

Purpose: Stores registered routes (RouteEntry), provides proximity and recency queries, and tracks per-route progress/snap indices.

Highlights:
- upsert(RouteEntry): adds/updates entries and computes bounds safely (handles empty/singleton, enforces SW/NE ordering)
- candidatesNear(LatLng, radiusMeters, maxCandidates): proximity-ordered list
- RouteEntry fields: key, mode, destinationName, points, bounds, lengthMeters, lastUsed, lastProgressMeters, lastSnapIndex
- Used by: ActiveRouteManager (active route), TrackingService (progress lookup for event/stops alarms)
