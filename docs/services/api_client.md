# ApiClient (lib/services/api_client.dart)

Purpose: Authenticated wrapper to your backend for Maps-like endpoints. Supports token auth with auto-refresh, test mode with canned responses, and multiple endpoints.

- Class: line 8 — config constants; testMode flags (`testMode`, `last*Body`, `directionsCallCount`).
- `initialize()`: line 28 — load creds; authenticate if missing/expired; test `/health`.
- `_makeRequest(method, endpoint, body, query)`: line 148 — core HTTP with test-mode short-circuits; handles 401 by re-auth; logs.
- Endpoints:
  - `getDirections(...)`: line 280 — POST `/maps/directions` with mode/transit_mode; returns full result.
  - `getAutocompleteSuggestions(...)`: line 300 — POST `/maps/autocomplete`; returns `predictions` list.
  - `getPlaceDetails(...)`: line 327 — POST `/maps/place-details`; returns `result`.
  - `getNearbyTransitStations(...)`: line 345 — POST `/maps/nearby-search`; returns `results` list.
  - `geocode(...)`: line 369 — POST `/maps/geocode`; returns first result.

Tests: `places_session_token_test.dart`, `direction_service_*`, `tracking_service_*` (via dependency).
