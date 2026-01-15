# Security & Privacy Audit

## Scope

- Location data handling (storage, transit, logging)
- Crash logs / analytics
- geowake-server proxy usage, auth, assumptions
- Key protection (API keys, secrets)
- Debug servers exposed on device/network
- Release build flags, environment switching

## Findings

### Finding template

- **Severity**: STOP_SHIP | HIGH | MEDIUM | LOW
- **Evidence**:
- **Impact**:
- **Repro/Trigger**:
- **Fix**:
- **Confidence**:

## Data inventory (sensitive)

- **Precise location (lat/lng)**
	- **Where used**: throughout tracking + directions
	- **Where persisted**:
		- `TrackingStateStore` snapshot (`tracking_snapshot_v1`) includes destination lat/lng and last user lat/lng; may include minimized directions.
		- `TrackingStateStore` transit legs (`tracking_transit_leg_stops_v5`) persists stop/station locations per route key.
		- `RouteCache` (Hive `route_cache_v1`) persists raw directions payloads (origin/destination/steps).
	- **Where transmitted**: to geowake-server `/api/maps/*` endpoints via `ApiClient` requests
	- **Evidence**: `lib/services/tracking_state_store.dart`; `lib/services/route_cache.dart`; `lib/services/api_client.dart`
	- **Confidence**: CERTAIN

- **Server auth token (proxy access)**
	- **Where persisted**: SharedPreferences `geowake_api_token` (+ `_exp`)
	- **Evidence**: `lib/services/api_client.dart`
	- **Confidence**: CERTAIN

## Server proxy security

- **Endpoints**:
	- `/api/auth/token` issues JWT
	- `/api/maps/directions`, `/api/maps/autocomplete`, `/api/maps/place-details`, `/api/maps/geocode`, `/api/maps/nearby-search` proxy to Google APIs
	- **Evidence**: `geowake-server/src/routes/auth.js`, `geowake-server/src/routes/maps.js`, `geowake-server/src/controllers/mapsController.js`

### Finding

- **Severity**: STOP_SHIP
	- **Evidence**:
		- Token issuance requires only `bundleId` matching config: `geowake-server/src/controllers/authController.js` `generateToken`
		- CORS default allows `*`: `geowake-server/src/config/config.js` `allowedOrigins` includes `'*'`
	- **Impact**: Any third party who knows the bundle ID can obtain a valid JWT and abuse the proxy endpoints, consuming Google Maps API quota/billing and causing service outages for real users.
	- **Repro/Trigger**:
		- POST `/api/auth/token` with body `{ "bundleId": "com.geowake.app" }` → receive token
		- Use token to call `/api/maps/*` at scale
	- **Fix**:
		- Require a non-forgeable device attestation signal (e.g., Play Integrity API), or a per-install secret provisioned out-of-band.
		- Remove `'*'` from allowed origins by default (even if mobile has no Origin, web should not be implicitly allowed).
		- Bind tokens to a device identifier and rotate/revoke.
	- **Confidence**: CERTAIN

### Finding

- **Severity**: MEDIUM
	- **Evidence**: `geowake-server/src/utils/cache.js` logs cache keys and hit/miss for requests; keys embed `origin`, `destination`, and query `input`.
	- **Impact**: Server logs can contain sensitive location/address queries (privacy risk) and can be used to reconstruct user trips.
	- **Repro/Trigger**: Any proxied request; log lines include structured key strings.
	- **Fix**: Redact/normalize cache logs (hash params) and restrict log verbosity in production.
	- **Confidence**: CERTAIN

## Secrets handling

### Finding

- **Severity**: HIGH
	- **Evidence**: `android/app/build.gradle` sets a fallback `googleMapsApiKey` to a hardcoded `AIza...` string if `key.properties` is missing.
	- **Impact**: A real API key may be embedded into debug/release builds and leaked via APK inspection; can lead to quota theft/billing and violates “server-only key” intent.
	- **Repro/Trigger**: Build without `android/key.properties` present.
	- **Fix**: Remove the fallback key; fail the build if `googleMapsApiKey` is missing; enforce key restriction by package name + SHA-1 in Google Cloud Console.
	- **Confidence**: CERTAIN

### Finding

- **Severity**: LOW
	- **Evidence**: `android/app/src/main/AndroidManifest.xml` sets `com.google.android.gms.ads.APPLICATION_ID` to the Google test app id (`ca-app-pub-3940256099942544~3347511713`).
	- **Impact**: Release builds may unintentionally use test ads configuration; could violate ad policy or fail monetization expectations.
	- **Repro/Trigger**: Any build using this manifest value.
	- **Fix**: Use build variants or manifest placeholders to inject the correct AdMob app id for release.
	- **Confidence**: CERTAIN
