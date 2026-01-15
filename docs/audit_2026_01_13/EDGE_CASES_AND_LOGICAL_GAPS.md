# Edge Cases & Logical Gaps Matrix

## Required coverage

- Permissions missing/partial/revoked mid-run
- Invalid/empty directions response
- Route mismatch / wrong direction / reroute loops
- GPS stale timestamps / teleports / spikes / jitter
- Very short vs very long routes
- Threshold met immediately
- Debug/test/time-warp modes leaking into production

## Format (each item)

- **Severity**: STOP_SHIP | HIGH | MEDIUM | LOW
- **Repro/Trigger**:
- **Expected**:
- **Actual (evidence)**:
- **Code evidence**:
- **Fix**:
- **Confidence**:

## Matrix

### Missing `key.properties` during build embeds fallback Maps key

- **Severity**: HIGH
- **Repro/Trigger**: Build APK without `android/key.properties` present.
- **Expected**: Build fails or injects a non-production key safely restricted.
- **Actual (evidence)**: `android/app/build.gradle` falls back to a hardcoded `AIza...` key.
- **Code evidence**: `android/app/build.gradle` `manifestPlaceholders.googleMapsApiKey = keystoreProperties[...] ?: 'AIza...'`
- **Fix**: Remove fallback key; fail build when missing; enforce key restrictions.
- **Confidence**: CERTAIN

### Splash restore can proceed without services fully initialized

- **Severity**: MEDIUM
- **Repro/Trigger**: Slow startup/network; `_initFuture` exceeds 8 seconds.
- **Expected**: Restore should ensure Tracking/Notifications/API are ready (or show explicit degraded-mode UI).
- **Actual (evidence)**: `_checkStateAndNavigate()` waits `timeout(const Duration(seconds: 8))` then continues even on timeout.
- **Code evidence**: `lib/screens/splash_screen.dart` `_checkStateAndNavigate()`
- **Fix**: Make restore path explicitly await minimum-required init (at least `TrackingService.initializeService()` and notification channel creation), or block restore with a user-visible “initializing” screen.
- **Confidence**: CERTAIN

### Offline mode depends on short TTL + origin drift constraints

- **Severity**: MEDIUM
- **Repro/Trigger**: Start tracking (online) then go offline for >5 minutes, or move >300m from cached origin; attempt a fresh directions fetch while still offline.
- **Expected**: Offline mode should either (a) use a clearly-stated offline cache policy that works for the intended duration, or (b) fail with explicit user guidance.
- **Actual (evidence)**:
	- `OfflineCoordinator` throws if offline and no cache hit.
	- `RouteCache` evicts entries if older than 5 minutes, or origin deviates >= 300m.
- **Code evidence**: `lib/services/offline_coordinator.dart` `getRoute()`; `lib/services/route_cache.dart` `RouteCache.get()`
- **Fix**: Define an offline policy (separate TTL for offline; larger origin tolerance; or UI messaging + explicit “offline route unavailable”).
- **Confidence**: CERTAIN

### Route cache can be deleted on open failure (data loss)

- **Severity**: LOW
- **Repro/Trigger**: Hive box open fails (corruption, schema mismatch, disk errors).
- **Expected**: Attempt recovery without silently discarding all cached routes (or at least log and keep state consistent).
- **Actual (evidence)**: `RouteCache._ensureOpen()` deletes the box from disk and recreates it.
- **Code evidence**: `lib/services/route_cache.dart` `_ensureOpen()`
- **Fix**: Consider a safer recovery strategy (backup/rename box, metrics + user-visible “cache reset” in debug).
- **Confidence**: CERTAIN

### Snapshot persistence failure can cause “restore ends tracking” after kill

- **Severity**: HIGH
- **Repro/Trigger**: `TrackingStateStore.saveSnapshot()` throws (common stated mode: payload too large) during start, then app process is killed and restarted.
- **Expected**: Tracking should either persist enough minimal state to safely restore, or show a clear recovery path explaining that safe restore is not possible.
- **Actual (evidence)**:
	- HomeScreen catches snapshot persistence failure and still starts tracking.
	- Splash restore requires `snapshot.directions != null` to restore; otherwise it force-ends tracking.
- **Code evidence**: `lib/screens/homescreen.dart` `_proceedWithDirections()` try/catch around `saveSnapshot`; `lib/services/tracking_state_store.dart` `saveSnapshot()` rethrows on failure; `lib/screens/splash_screen.dart` `_checkStateAndNavigate()` restore gate
- **Fix**: Make snapshot persistence robust/atomic (size-limited minimal snapshot, version/checksum), and surface a user-visible recovery prompt.
- **Confidence**: HIGH

### Server auth token can be obtained by bundleId only

- **Severity**: STOP_SHIP
- **Repro/Trigger**: POST `/api/auth/token` with `{bundleId:"com.geowake.app"}` from any client.
- **Expected**: Only legitimate installs can obtain proxy access.
- **Actual (evidence)**: Server checks only `bundleId` equality before issuing JWT.
- **Code evidence**: `geowake-server/src/controllers/authController.js` `generateToken`
- **Fix**: Require Play Integrity/device attestation or per-install secret; tighten rate limits; consider removing CORS wildcard.
- **Confidence**: CERTAIN
