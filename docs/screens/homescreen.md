# homescreen.dart

Responsibilities:
- Destination search and selection (autocomplete + recent locations + map taps)
- Mode selection: distance/time or metro+stops
- Connectivity + battery awareness
- Kick off directions fetch and start tracking

Key logic:
- Search:
  - Debounced query merges local recent matches with remote Places results (dedupe by place_id)
  - Selection fetches details -> sets marker and saves recents (unique by place_id)
  - Map tap: double-tap zoom detection vs single-tap reverse geocode to destination
- Battery: monitors and updates `_lowBattery` for UI (policy enforced in TrackingService)
- Connectivity: updates OfflineCoordinator and informs TrackingService for reroute online gating
- Proceed flow:
  - Requests essential permissions via PermissionService
  - For metro mode: validates via MetroStopService; may snap dest to closest stop
  - Fetches directions via OfflineCoordinator (online/cache)
  - Registers route with TrackingService (for snapping/switching/events)
  - Computes alarm mode/value (distance/time or stops) and calls TrackingService.startTracking
  - Navigates to PreloadMapScreen with arguments

Nuances:
- Recents are capped (10), uniquely keyed by place_id, and persisted via RecentLocationsService
- Tap handling uses time + spatial proximity to infer double-tap
- Connectivity changes set `_noConnectivity` and propagate to OfflineCoordinator & TrackingService

# HomeScreen (line-by-line)

Purpose: Destination search, map selection, recents management, mode selection, and starting tracking.

State/init:
- Controllers/nodes for search + debounce.
- Lists: `_recentLocations`, `_autocompleteResults`; `_selectedLocation` map.
- Flags: `_useDistanceMode`, `_metroMode`, sliders for distance/time/stops; loading/tracking/connectivity/battery flags.
- Completer for GoogleMap; markers set; double-tap detection state.
- `initState()`:
  - Instantiate `PlacesService`, load recents, start battery monitoring, create `OfflineCoordinator`.
  - Subscribe to connectivity changes; set `_noConnectivity`, update `_offline` and `TrackingService.setOnline()`.
  - Fetch current location → set marker → fetch `_currentCountryCode` via `ApiClient.geocode()`.
  - Search focus listener toggles top recents vs clear results.

Reverse geocode map tap:
- `_handleMapTap()` distinguishes double-tap (zoom) vs single-tap (reverse geocode) via time and distance window; calls `_setDestinationFromLatLng()`.
- `_setDestinationFromLatLng()` uses `ApiClient.geocode()`; falls back to "Dropped pin" on error.

Battery monitoring:
- Reads initial level; sets `_lowBattery` <25%; listens to changes.

Country code lookup:
- Extracts `country` component for Places biasing.

Recents:
- `_loadRecentLocations()` loads from Hive.
- `_showTopRecentLocations()` uses first three.
- `_addToRecentLocations()` de-duplicates by `place_id`, caps at 10, saves.
- `_removeRecentLocation()` removes from both lists and persists.

Search flow:
- `_onSearchChanged()` debounces; merges local recents substring matches with remote Places results, avoiding duplicates.
- `_onSuggestionSelected()` fetches place details, sets selected marker, saves to recents, updates UI.

Wake Me / proceed:
- `_onWakeMePressed()` checks destination; requests permissions via `PermissionService` and on success calls `_proceedWithDirections()`.
- `_proceedWithDirections()`:
  - Gets current position, handles metro validation via `MetroStopService.validateMetroRoute()` (sets destination to closest stop or errors).
  - Fetches directions via server; computes initial ETA; registers route with `TrackingService.registerRouteFromDirections()` for snapping/deviation pipelines.
  - Navigates to `/preloadMap` (warm-up) then to `/mapTracking` with args: `lat,lng,destination,metroMode,directions,userLat,userLng,eta,distance`.
