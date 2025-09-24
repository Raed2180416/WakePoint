# PlacesService (lib/services/places_service.dart)

Purpose: Wraps `ApiClient` for Places autocomplete and details with session token handling for query billing affinity.

- Session token: lines 4–22 — `_ensureSessionToken()` rotates after ~3 minutes; `endSession()` clears.
- `fetchAutocompleteResults(query, countryCode?, lat?, lng?)`: line 28 — builds `location`/`components`; calls `ApiClient.getAutocompleteSuggestions` with `sessionToken`; maps fields.
- `fetchPlaceDetails(placeId)`: line 65 — calls `ApiClient.getPlaceDetails`; returns description and lat/lng.

Tests: `places_session_token_test.dart`.
