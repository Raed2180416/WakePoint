# MetroStopService (lib/services/metro_stop_service.dart)

Purpose: Retrieves nearby transit stops via backend and validates metro destination/start feasibility.

- `getNearbyTransitStops(location, radius=500m)`: line 10 — calls `ApiClient.getNearbyTransitStations`; maps to `TransitStop`.
- `validateDestination(destination, maxRadius=500m)`: line 37 — finds nearest stop and distance; returns `DestinationValidationResult`.
- `validateMetroRoute(startLocation, destination, maxRadius)`: line 86 — ensures start and destination stops differ; otherwise rejects route.

Tests: `metro_stops_prior_test.dart` (paired with TransferUtils for alerts).
