# State and Persistence Inventory

## Inventory targets

- SharedPreferences
- Hive
- SQLite / files
- Plugin-managed persistence (e.g., notifications, background service)
- Caches (in-memory and disk)

## Required fields per persisted state

- **Storage mechanism**:
- **Location (file + symbol)**:
- **Schema / keys**:
- **Owner (source of truth)**:
- **Write points**:
- **Read/restore points**:
- **Invalidation / migrations**:
- **Corruption handling**:
- **Privacy sensitivity**:
- **Failure modes**:
- **Confidence**:

## Persisted state map

### SharedPreferences

- **Theme preference**
	- **Storage mechanism**: SharedPreferences
	- **Location**: `lib/main.dart` `MyAppState._themePrefKey = 'gw_dark_mode'`
	- **Write points**: `MyAppState._persistThemePreference()`
	- **Read points**: `MyAppState._restoreThemePreference()`
	- **Evidence**: `lib/main.dart` [L27-L111]
	- **Confidence**: CERTAIN

- **Tracking session snapshot + flags (TrackingStateStore)**
	- **Storage mechanism**: SharedPreferences (`TrackingStateStore` caches `SharedPreferences.getInstance()`)
	- **Location (file + symbol)**: `lib/services/tracking_state_store.dart` `class TrackingStateStore`
	- **Schema / keys**:
		- `tracking_active_v1` (bool)
		- `tracking_paused_v1` (bool)
		- `tracking_alarm_fired_v1` (bool)
		- `tracking_notifications_muted_v1` (bool; key is removed when unmuted)
		- `tracking_snapshot_v1` (String JSON; minimized)
		- `gw_progress_payload_v1` (String JSON)
		- `gw_preboarding_enabled_v1` (bool; default true)
		- `gw_destination_only_metro_time_v1` (bool; default false)
		- `tracking_transit_leg_stops_v5` (String JSON map: `routeKey` → `List<TransitLegStopsJson>`)
	- **Owner (source of truth)**: Flutter app (`TrackingService`, `HomeScreen`, `NotificationService`, `RouteSessionManager`)
	- **Write points (examples, not exhaustive)**:
		- `HomeScreen` sets `active=true` and persists `TrackingSnapshot(... directions ...)` before starting tracking.
		- `TrackingService.startTracking()` best-effort sets `active=true`, `paused=false`, `alarmFired=false`, `notificationsMuted=false`.
		- Background `_handleBackgroundStartTracking()` sets `active=true`, `paused=false`, `alarmFired=false`.
		- `HeartbeatMonitor` sets `paused=true` on heartbeat timeout.
		- `RouteSessionManager` persists transit legs by route key (`saveTransitLegStops`) and restores them (`loadTransitLegStops`).
	- **Read/restore points (examples, not exhaustive)**:
		- `SplashScreen` checks `alarmFired` and `active`, loads snapshot for UI restore.
		- `TrackingService.resumeFromNotification()` loads snapshot/progress payload.
		- `NotificationService` reads `active`, `paused`, `notificationsMuted`, progress payload.
	- **Invalidation / migrations**:
		- Transit legs key is versioned (`tracking_transit_leg_stops_v5`) with inline version history comments.
		- Transit legs can be selectively cleared per-route key or fully cleared.
	- **Corruption handling**:
		- `loadSnapshot()`/`loadProgressPayload()` return null on JSON decode failure.
		- `saveSnapshot()` logs and rethrows on failure (common: payload too large).
		- `saveSnapshot()` merges directions: background refreshes may omit directions; existing directions are preserved (best-effort).
	- **Cross-isolate freshness**:
		- Several getters call `prefs.reload()` (`notificationsMuted`, `preboardingEnabled`, `destinationOnlyMetroTimeEnabled`) to reduce isolate-staleness.
		- A test helper `resetCacheForTests()` exists to avoid cross-test contamination.
	- **Privacy sensitivity**: HIGH (location, destination, route directions, transit stops)
	- **Evidence**:
		- `lib/services/tracking_state_store.dart` (`TrackingStateStore`, `TrackingSnapshot`, snapshot minimization + compute)
		- `lib/services/trackingservice.dart` (`startTracking`, `_handleBackgroundStartTracking`, `resumeFromNotification`)
		- `lib/services/tracking/heartbeat_monitor.dart` (paused flag set on heartbeat timeout)
		- `lib/services/route_session_manager.dart` (transit legs restore/persist)
	- **Confidence**: CERTAIN (schema) / HIGH (end-to-end restore semantics)

- **Pending alarm recovery keys**
	- **Storage mechanism**: SharedPreferences
	- **Keys**: `pending_alarm_flag`, `pending_alarm_title`, `pending_alarm_body`, `pending_alarm_allow`
	- **Write points**: `NotificationService.showWakeUpAlarm()`
	- **Read points**: `NotificationService.ensureAlarmNotificationVisible()`
	- **Evidence**: `lib/services/notification_service.dart` [L678-L699] and [L808-L860]
	- **Confidence**: CERTAIN

- **Cross-isolate action request flags (backup)**

- **API client auth token + expiration**
	- **Storage mechanism**: SharedPreferences
	- **Keys**: `geowake_api_token`, `geowake_api_token_exp`
	- **Owner (source of truth)**: `ApiClient`
	- **Write points**: `ApiClient._saveCredentials()` after `_authenticate()`
	- **Read points**: `ApiClient._loadStoredCredentials()` during `ApiClient.initialize()`
	- **Invalidation**: `_isTokenExpired()` considers token expired if within 5 minutes of `_tokenExpiration`; 401 triggers re-auth and retry.
	- **Evidence**: `lib/services/api_client.dart` (`_tokenKey`, `_loadStoredCredentials`, `_saveCredentials`, `_isTokenExpired`)
	- **Privacy sensitivity**: token grants access to server proxy endpoints
	- **Confidence**: CERTAIN

- **API client device id (currently unused in auth flow)**
	- **Storage mechanism**: SharedPreferences
	- **Key**: `geowake_device_id`
	- **Owner**: `ApiClient`
	- **Write points**: `ApiClient._saveCredentials()` (only if `_deviceId != null`)
	- **Read points**: `ApiClient._loadStoredCredentials()`
	- **Evidence**: `lib/services/api_client.dart` (`_deviceIdKey`, `_loadStoredCredentials`, `_saveCredentials`)
	- **Confidence**: CERTAIN

- **Cross-isolate action request flags (backup)**
	- **Storage mechanism**: SharedPreferences
	- **Keys**:
		- `gw_stop_alarm_request_v1`
		- `gw_end_tracking_request_v1`
		- `gw_mute_journey_request_v1`
	- **Write points**: `NotificationService.requestStopAlarmForService()` etc.
	- **Read/consume points**: `NotificationService.consumeStopAlarmRequest()` etc.
	- **Evidence**: `lib/services/notification_service.dart` [L24-L175]
	- **Confidence**: CERTAIN

### File-based flags (cross-isolate)

- **Storage mechanism**: app documents directory files
- **Files**:
	- `.gw_stop_alarm_flag`
	- `.gw_end_tracking_flag`
	- `.gw_mute_journey_flag`
- **Write points**: `NotificationService._writeFlag()` called by `request*ForService()`
- **Consume points**: `NotificationService._consumeFlag()` called by `consume*Request()`
- **Why it exists**: explicit comment: “more reliable across isolates than SharedPreferences”.
- **Evidence**: `lib/services/notification_service.dart` [L34-L86]
- **Confidence**: CERTAIN

### Hive

- **Recent locations**

- **RouteCache (Directions API responses)**
	- **Storage mechanism**: Hive (box of JSON strings)
	- **Location (file + symbol)**: `lib/services/route_cache.dart` `class RouteCache`
	- **Schema / keys**:
		- Box name: `route_cache_v1`
		- Key: JSON string containing rounded origin/destination lat/lng (~5 decimals), `mode` (`driving`/`transit`), optional `transitVariant` and `departureTime`.
		- Value: JSON string encoding `RouteCacheEntry` with `directions`, `timestamp`, `origin`, `destination`, `mode`, optional `scp`.
	- **Read points**: `RouteCache.get(...)` (used by `OfflineCoordinator` when offline)
	- **Write points**: `RouteCache.put(...)` (actual call sites TBD; `DirectionService` also claims internal caching)
	- **Invalidation / TTL**:
		- TTL default 5 minutes; stale entries are evicted on read.
		- Additional invalidation: origin deviation >= 300m evicts the entry.
		- Decode failure deletes the key.
	- **Corruption handling**: deletes entry on JSON decode error.
	- **Failure modes**:
		- If opening the box fails, the code deletes the box from disk and recreates it (data loss).
	- **Privacy sensitivity**: HIGH (raw directions payload includes origin/destination, step/stop details)
	- **Evidence**: `lib/services/route_cache.dart`
	- **Confidence**: CERTAIN

- **Recent locations**
	- **Storage mechanism**: Hive (box)
	- **Write points**: `RecentLocationsService.saveRecentLocations(...)` (invoked by HomeScreen add/remove recent location)
	- **Flush points**: on `AppLifecycleState.paused`, `Hive.box(...).flush()`
	- **Evidence**: `lib/main.dart` [L47-L73]; `lib/screens/homescreen.dart` [L420-L441]
	- **Confidence**: HIGH (box schema/name confirmation pending `RecentLocationsService` read)

## Restore after kill

- **Storage mechanism**: SharedPreferences (via `TrackingStateStore`)
- **Restore gate logic**:
	- If `TrackingStateStore.isAlarmFired()` is true on startup: cleanup and navigate home.
	- Else if `TrackingStateStore.isActive()` is true: load snapshot and require `snapshot.directions != null` before restoring UI.
- **Evidence**: `lib/screens/splash_screen.dart` `_checkStateAndNavigate()`
- **Confidence**: HIGH (restore gate) / CERTAIN (keys)

## Unknowns (must be in Certainty Matrix)

- TBD
