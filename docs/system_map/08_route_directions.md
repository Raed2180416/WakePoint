## Route Fetch, Directions Proxy, Caching & Snapping

**Role in the core promise:** This subsystem is the part of GeoWake that answers the question *"what is the path from where the rider is to where they want to get off, and where am I on it right now?"* Everything downstream — the alarm engine, the ETA countdown, the "you're 2 stops away" logic, the reroute decisions — depends on a trustworthy route geometry and a trustworthy *progress-along-that-geometry* number. If this layer hands back a wrong polyline, a stale route, or a snapped position that is off by 300 m, the rider gets woken at the wrong place or not at all. The subsystem must also survive the hostile conditions in the core promise: a flaky mobile network in India (so it fetches through a proxy, caches aggressively, and has an explicit offline path), and GPS dropouts underground (so the snapping must relocate the rider globally after a gap, and the route must persist through the trip). It does **not** own the alarm decision or the EKF — it owns the *map data plumbing* those decisions run on.

**Files:**

| Path | What it does |
|---|---|
| `lib/services/api_client.dart` | Singleton HTTP client to the GeoWake proxy server (Railway). Owns bearer-token auth, timeouts, 401-retry, and the `testMode` canned-response harness. Exposes `getDirections`, autocomplete, place-details, nearby-search, geocode. |
| `lib/services/direction_service.dart` | The orchestrator. Turns a start/end into a Google Directions payload via `ApiClient`, applies the metro-preferring route selection, runs the 2-tier cache (in-memory L1 + Hive L2 `RouteCache`), simplifies/compresses the overview polyline, and builds render/segment geometry. |
| `lib/services/route_cache.dart` | Hive-backed persistent (L2) cache of raw Directions responses, keyed by rounded origin+destination+mode. Enforces TTL, schema-version, planned-arrival, and origin-deviation freshness guards. |
| `lib/services/route_registry.dart` | In-memory, session-scoped registry of active/recent routes (`RouteEntry`), capacity 8, LRU eviction. Precomputes bbox, geodesic length, and cumulative-distance arrays for fast snapping/progress. Provides `candidatesNear` for multi-route switching. |
| `lib/services/route_queue.dart` | **Dead code.** A legacy singleton FIFO queue of `RouteModel`. No references anywhere in `lib/` or `test/`. Superseded by `RouteRegistry` + `ActiveRouteManager`. |
| `lib/services/route_session_manager.dart` | The heavy per-trip orchestrator. Parses a Directions payload into registry geometry + step boundaries + transit legs + route events + segments + boarding/alighting switch points, wires up `ActiveRouteManager`/`DeviationMonitor`/`ReroutePolicy`, and ingests positions to drive route switching and deviation. |
| `lib/services/active_route_manager.dart` | The state machine that, per position sample, snaps to the active route, decides whether to switch to a nearby candidate route (sustain + blackout gated), computes progress/remaining, and runs the G14/G15 wrong-direction / wrong-train detector. |
| `lib/services/offline_coordinator.dart` | Thin online/offline gate over directions fetching. Online → delegates to `DirectionService`; offline → returns a cached route only (or throws). Singleton wired to connectivity. |
| `lib/services/polyline_decoder.dart` | Google encoded-polyline decoder + geometry helpers (haversine length, point-along-polyline, stop-position estimation, a **second** point-to-polyline snapper). |
| `lib/services/polyline_simplifier.dart` | Ramer–Douglas–Peucker simplification + gzip/base64 compress/decompress of a polyline for compact caching/transport. |
| `lib/services/snap_to_route.dart` | The **production** point-to-route snapper (`SnapToRouteEngine`): weighted scoring (lateral distance + continuity + heading), equirectangular projection, optional full-route fallback. Distinct from the helper in `polyline_decoder.dart`. |
| `lib/services/route_metadata.dart` | Per-route metadata model + manager: which alarm events/legs have fired, initial constraints, line colors. **Referenced only by tests, not wired into the live pipeline.** |
| `lib/services/route_logger.dart` | Debug/telemetry: writes the **full raw** Directions response + metadata to a JSON file on disk on every successful fetch. Enabled by default. |

---

### How it works, step by step: the atomic walkthrough

#### A. A route fetch, end to end

**Entry point:** `OfflineCoordinator.getRoute(...)` (offline_coordinator.dart:153) is the front door used by both `HomeScreen` (homescreen.dart:1341) and the in-trip reroute path in `TrackingService` (trackingservice.dart:1446).

1. **Offline gate** (offline_coordinator.dart:165). It computes `mode = transitMode ? 'transit' : 'driving'` and `variant = transitMode ? 'rail' : null`.
   - **If offline:** it calls `RouteCache.get(origin, destination, mode, transitVariant)` directly. If nothing is cached it **throws `StateError('Offline and no cached route available')`**; otherwise it returns `OfflineRouteResult(source: RouteSource.cache)`. Note: it passes **no** `departureTime` and drops `forceRefresh`/`preferMetroEvenIfClosed`.
   - **If online:** it delegates to `DirectionService.getDirections(...)` (via `DefaultDirectionsProvider`) and returns `source: RouteSource.network`.

2. **`DirectionService.getDirections`** (direction_service.dart:46) is the real orchestrator. In order:
   - **L2 cache probe** (line 140): unless `forceRefresh`, it calls `RouteCache.get(origin, dest, mode, transitVariant: transitMode ? 'rail' : null)`. A hit populates the in-memory `_cachedDirections` / `_lastFetchTime` but does **not** early-return here — it just seeds the fast path.
   - **Tiered refresh interval** (line 154): it computes the straight-line distance with `Geolocator.distanceBetween`. In distance-mode, if `straightDistance > 5×threshold_m` → `farInterval` (15 min); `> 2×threshold_m` → `midInterval` (7 min); else `nearInterval` (3 min). In any non-distance mode → always `nearInterval` (3 min). These constants live at direction_service.dart:23-25.
   - **L1 in-memory fast path** (line 183): if not `forceRefresh` and the cached payload's key equals the freshly computed `requestKey` **and** `elapsed < updateInterval`, it returns `_cachedDirections` immediately — no network. The key is `RouteCache.makeKey(origin, dest, mode, transitVariant)`.
   - **Primary network request** (line 199): `ApiClient.getDirections(origin: '$lat,$lng', destination: ..., mode: transit?'transit':'driving', transitMode: 'rail'|null)`.
   - **Metro promotion** (line 211): if transit and the payload is OK, it scans routes with `pickFastestRouteIndex(requireMetroLeg: true)` — the fastest route that contains a `SUBWAY / HEAVY_RAIL / RAIL / METRO_RAIL / MONORAIL` step (`routeContainsMetroLeg`, line 62) — and `promoteRouteToFront` moves it to index 0.
   - **Closed-metro fallback** (line 223): only if `preferMetroEvenIfClosed` and the primary had no feasible/metro route. It re-requests with `transitMode: 'subway'` and `departure_time` = `nextServiceAnchorDepartureEpochSeconds()` — the next **09:00 local** (today if still ahead, else tomorrow) (line 130). It then promotes the fastest metro route, or the fastest of *any* route if still none.
   - **Hard failure** (line 265): if status ≠ `OK` or no routes, it throws `"No feasible route found: ..."`.
   - **Polyline simplify + compress** (line 272): for `routes[0].overview_polyline.points`, it does `_decodeAndProcessCached(encoded, 10.0)` → decode + RDP simplify at **10 m tolerance** → `PolylineSimplifier.compressPolyline` (JSON → gzip → base64) → writes it back as `route['simplified_polyline']`.
   - **Commit caches** (line 295): sets `_cachedDirections`, `_lastFetchTime = now`, and `_cachedDirectionsKey` keyed by the **actual** params used (including any fallback `transitVariant`/`departureTime`), then persists an L2 `RouteCache.put(...)` with `plannedDepartureEpoch`/`plannedArrivalEpoch` extracted by `_extractPlannedWindowEpochs` (line 666).
   - **Disk log** (line 340): `RouteLogger.instance.logRoute(...)` writes the whole payload to a file.
   - **Failure/retry** (line 357): any exception → if not already `forceRefresh`, it recurses once with `forceRefresh: true`; a second failure throws `"Failed to fetch directions"`.

3. **`ApiClient.getDirections` → `_makeRequest('POST', '/maps/directions', body)`** (api_client.dart:341, 179). The body is `{origin, destination, mode, transit_mode?, departure_time?}`. `_makeRequest`:
   - If `testMode`, returns canned payloads and records the request body (used by tests).
   - Ensures a token: if `_authToken` is null or `_isTokenExpired()` (5-min safety margin, line 88), it calls `_authenticate()` (POST `/auth/token` with `{bundleId: 'com.geowake.app'}`, stores token with a **23 h** local expiry even though the server says 24 h, line 137).
   - Sends the POST with a **15 s timeout** and `Authorization: Bearer <token>`.
   - On **401**, re-authenticates and retries the request **once** — but the retry call has **no `.timeout(...)`** (line 312/315).
   - On 200 returns the decoded JSON map; otherwise throws `HTTP <code>`.

#### B. Turning a payload into a trackable route (`RouteSessionManager.registerRouteFromDirections`, route_session_manager.dart:130)

Called by `HomeScreen` (homescreen.dart:1080) and `TrackingService` (trackingservice.dart:1509) after a successful fetch. It builds the trip's canonical geometry and metadata under a single `key = RouteCache.makeKey(...)`:

1. **Point extraction with a 4-level fallback ladder** (line 254):
   - **PREFERRED — step polylines** (line 255): concatenate every `leg.steps[].polyline.points` decoded via `decodePolyline`, skipping a duplicated junction vertex when the last point and the next step's first point are `< 10 m` apart.
   - **FALLBACK — overview polyline** (line 293): if step parsing yielded `< 2` points, decode `route.overview_polyline.points`.
   - **LAST RESORT — simplified polyline** (line 303): decompress `route.simplified_polyline`. Explicitly *not preferred* for snapping because it is intentionally over-straightened.
   - **PLAUSIBILITY REBUILD** (line 321): if the decoded points don't start/end within `5000 m` of origin/destination (`looksPlausible`, line 165 — common with placeholder polylines in tests), rebuild from step `start_location`/`end_location` points (`buildFallbackFromSteps`), or as a last resort `[origin, destination]`. A `usedFallbackPolyline` flag is set so later scaling is skipped.
   - `polylineMeters = _polylineLengthMeters(points)` (geodesic).
2. **Step boundaries & stop cumulative distances** (line 346): `TransferUtils.buildStepBoundariesAndStops(directions)` yields per-step bound meters, stop distances, and durations. A `scale = polylineMeters / stepLen` correction is applied **only** when not on a fallback polyline and the two lengths differ by `> 10 m`, to reconcile the API's stated distances with the decoded geometry's actual length.
3. **Transit legs** (line 388): tries to restore OSM-enhanced legs from `TrackingStateStore.loadTransitLegStops(key)`; invalidates them if a generic `"Walk"` leg immediately precedes a metro leg (unstable leg IDs → duplicate preboarding alarms, line 401); otherwise extracts fresh via `TransferUtils.extractTransitLegStops` and (metro-mode only) enhances with OSM. A separate `legScale` correction is applied to leg meters — but **never** the step `scale`, because leg meters are already in the polyline domain (comment at line 474).
4. **Route events** (line 536): `TransferUtils.buildRouteEvents` scaled by `eventScale = polylineMeters/stepLen`; then a `final_station` event (last metro arrival stop) and a `destination` event are appended and the list is sorted by meters.
5. **First boarding point** (line 638): first metro step's `departure_stop.location`, else that step's decoded first point, else an event of type boarding/transfer, else `points[1]`.
6. **Segments & switch points** (line 700): `DirectionService().buildRawSegments` for render styling; boarding/alighting stops for metro steps, deduped within `200 m` and dropped if within `200 m` of the destination.
7. **Handoff to `registerRoute`** (line 771): builds `cachedRoutePayload`, upserts a `RouteEntry` into the `RouteRegistry`, lazily constructs `ActiveRouteManager` / `DeviationMonitor` / `ReroutePolicy` (with **test-vs-prod timings**: sustain 300 ms vs 6 s, switch margin 20 m vs 50 m, blackout 300 ms vs 5 s), sets the active key, and broadcasts to the dashboard via `LocationManager.broadcastRoute`.

#### C. Where am I on the route? (per-position snapping)

`RouteSessionManager.ingestPosition(Position)` (line 1194) forwards to `ActiveRouteManager.ingestPosition(LatLng)` (active_route_manager.dart:170) and feeds `DeviationMonitor` with `offsetMeters` + `speed`.

`ActiveRouteManager.ingestPosition` per sample:
1. Snaps to the active route: `_snapTo(active, rawPosition)` → `SnapToRouteEngine.snap(point, polyline, precomputedCumMeters: entry.cumMeters, hintIndex: entry.lastSnapIndex, searchWindow: 30)` (line 327).
2. Persists `lastSnapIndex` / `lastProgressMeters` back onto the `RouteEntry` (line 183).
3. Finds nearby candidate routes with `registry.candidatesNear(rawPosition, radiusMeters: 1200, maxCandidates: 3)` and considers a switch only if a candidate's lateral offset is `+switchMargin` better **and** `_headingAgreement(...) > 0.3` (delta-progress sign; no compass).
4. Gates the switch with a **sustain** timer (6 s prod) and a post-switch **blackout** (5 s prod), both `Stopwatch`-based (monotonic, immune to wall-clock jumps).
5. Emits `ActiveRouteState{ snapped, offsetMeters, progressMeters, remainingMeters, pendingSwitch... }`.
6. Runs `_updateDirection(...)` (line 359) — the G14/G15 wrong-direction detector: while snapped (`offset ≤ 80 m`), if along-route progress regresses beyond a `5 m` noise floor, it accumulates net regression and starts a timer; when sustained `≥ 12 s` **and** net regression `≥ 60 m`, it emits a single latched `WrongDirectionAlert` (works on metro legs because it uses the *sign of progress*, not lateral deviation).

**`SnapToRouteEngine.snap`** (snap_to_route.dart:43): computes/uses a cumulative-distance array, runs `_snapInRange` scoring each segment as `lateralDistance + continuityBonus/penalty + headingPenalty`:
- Continuity: `−10 m` bonus for staying on the same/next segment, `+5 m` per index jumped, `+100 m` for going back more than 3 indices (line 171).
- Heading: only if a heading is supplied — `+ (diff/180)×20` for `>45°`, `+50` for `>120°`.
- Projection uses equirectangular scaling `kx = 111320·cos(lat)`, `ky = 110540` (line 235) — the correct short-segment approximation.
- A full-route fallback runs only if the windowed offset `> 500 m` **and** a `previousResult` was supplied.

---

### Key types & functions

- **`ApiClient`** (singleton, `ApiClient.instance`) — proxy HTTP client.
  - `Future<void> initialize()` — load creds, auth if needed, health-check.
  - `Future<Map<String,dynamic>> getDirections({origin, destination, mode, transitMode, departureTime})` — POST `/maps/directions`.
  - `getAutocompleteSuggestions`, `getPlaceDetails`, `getNearbyTransitStations`, `geocode` — the other proxied Maps endpoints.
  - `Future<Map<String,dynamic>> _makeRequest(method, endpoint, {body, queryParams})` — auth + timeout + 401-retry + testMode short-circuit.
- **`DirectionService`** — fetch orchestrator + geometry builder.
  - `getDirections(startLat, startLng, endLat, endLng, {isDistanceMode, threshold, transitMode, preferMetroEvenIfClosed, forceRefresh})` — the tiered fetch described above.
  - `buildRawSegments(directions, transitMode, {simplify})` — groups steps into `{mode, points, transit_line, vehicle_type}` render segments.
  - `buildSegmentedPolylines(...)` / `buildSegmentedPolylinesFromRawSegments(...)` — `Polyline` objects for the map (walking dashed, transit colored by line).
  - `_decodeAndProcessCached(encoded, toleranceMeters)` — md5-keyed in-memory decode+simplify cache.
  - `_extractPlannedWindowEpochs(directions)` — `(departureEpoch?, arrivalEpoch?)` for cache freshness.
- **`RouteCacheEntry` / `RouteCache`** (route_cache.dart) — L2 persistent cache.
  - `static String makeKey({origin, destination, mode, transitVariant, departureTime})` — canonical JSON key rounded to 5 decimals (~1.1 m).
  - `static Future<RouteCacheEntry?> get({..., ttl = 5min, originDeviationMeters = 300})` — freshness-guarded read.
  - `static Future<void> put(entry)` / `clear()`.
- **`RouteEntry` / `RouteRegistry`** (route_registry.dart) — session geometry store.
  - `RouteEntry` precomputes `bbox`, `lengthMeters`, `cumMeters`, and carries session-only `lastSnapIndex` / `lastProgressMeters`.
  - `bool isNear(LatLng, radiusMeters)` — bbox prefilter + `distanceToCenter ≤ radius × 2.5`.
  - `RouteRegistry.upsert(entry)`, `markUsed(key)`, `updateSessionState(key, {lastSnapIndex, lastProgressMeters})`, `candidatesNear(p, {radiusMeters=1200, maxCandidates=3})`, capacity-8 LRU `_evictIfNeeded()`.
- **`RouteSessionManager`** — per-trip parse + wiring + ingestion (streams: `routeStateStream`, `routeSwitchStream`, `rerouteStream`, `deviationStateStream`, `wrongDirectionStream`).
  - `registerRouteFromDirections({directions, origin, destination, transitMode, destinationName, activateRoute})`.
  - `ingestPosition(Position)`, `switchToRoute(key)`, `clearSession()`, `dispose()`.
- **`ActiveRouteManager`** — snapping + switching + wrong-direction state machine.
  - `setActive(key)`, `ingestPosition(LatLng, {isFinalAlarm})`, `onStationSnapConfirmed(event)` (EKF station snap with monotonic gate), `resetStationSnapIndex()`.
  - `ActiveRouteState` (progress/remaining/offset/pending switch) and `WrongDirectionAlert` value types.
- **`OfflineCoordinator`** — `getRoute({origin, destination, isDistanceMode, threshold, transitMode, preferMetroEvenIfClosed, forceRefresh})` → `OfflineRouteResult{directions, source}`; `setOffline(bool)`; `bool isOffline`; `Stream<bool> offlineStream`. Testability seams `DirectionsProvider` / `RouteCachePort`.
- **`SnapToRouteEngine.snap({point, polyline, heading, previousResult, precomputedCumMeters, hintIndex, searchWindow})`** → `SnapResult{snappedPoint, lateralOffsetMeters, progressMeters, segmentIndex, matchScore}`.
- **`decodePolyline(encoded)`** and helpers `haversineDistance`, `polylineLength`, `pointAlongPolyline`, `estimateStopPositions(polyline, numStops)`, `stopDistancesAlongPolyline`, `snapPointToPolyline` (a *second*, simpler snapper).
- **`PolylineSimplifier.simplifyPolyline(points, toleranceMeters)`**, `compressPolyline`, `decompressPolyline`.
- **`RouteMetadata` / `RouteMetadataManager`** — alarm-fired dedup + constraints model (tests-only in current wiring).
- **`RouteLogger.instance.logRoute({...})`** — disk capture of raw payloads.
- **`RouteQueue`** — legacy FIFO (dead).

---

### Design decisions (the WHY)

1. **Route through a proxy server, never call Google directly.** `ApiClient` points at `https://geowake-production.up.railway.app/api` (api_client.dart:9) and authenticates with the app's bundle ID to receive a bearer token.
   - *Why:* the Google Maps API key must not ship inside the APK — anyone can decompile an Android app and steal an embedded key, then run up the founder's Google bill. The proxy holds the key server-side and hands the app short-lived tokens.
   - *Trade-off / rejected alternative:* shipping the key with Android app-restrictions was rejected (weak, and the same key is reused across Directions/Places). The cost is an **extra network hop and a hard dependency on the founder's Railway box** — if Railway is down, *every* route fetch fails even when Google is up.
   - *Flaw:* the server is a **single point of failure** with no documented fallback, and the free-tier Railway host can cold-start slowly, adding latency on the first fetch of a session — exactly when the rider is trying to start tracking.

2. **Bearer token cached with a 23 h local expiry and a 5-min pre-expiry margin.** (api_client.dart:88, 137)
   - *Why:* avoid re-authenticating on every request; refresh proactively before the server would reject a stale token.
   - *Trade-off:* the client **hard-codes** 23 h rather than reading the server's `expiresIn`. If the server ever shortens token life, the client will keep sending dead tokens until it eats a 401.
   - *Flaw:* the 401-retry path (api_client.dart:301) is the only safety net, and its retried request is sent **without a timeout** — on a flaky Indian network a hung retry can block the fetch indefinitely, defeating the 15 s budget on the first attempt.

3. **Two-tier cache: in-memory L1 (per-`DirectionService`) + Hive L2 (`RouteCache`).** (direction_service.dart:183, route_cache.dart)
   - *Why:* cut network calls and battery. L1 returns instantly within the tiered interval; L2 survives an app restart and feeds the offline path.
   - *Trade-off:* two caches with **different keys and lifetimes**. L1 is keyed by the exact request (including fallback `departureTime`); L2 by rounded coordinates. They can disagree.
   - *Flaw:* `DirectionService` is instantiated *per call site* (`DirectionService()` appears in maptracking, dashboards, `RouteSessionManager`), so the L1 cache and `_polylineSimplifyCache` are **not shared** — each instance re-fetches/re-simplifies. Only L2 is truly global.

4. **L2 freshness is guarded four ways: 5-min TTL, schema version, planned-arrival, and 300 m origin deviation.** (route_cache.dart:158-203)
   - *Why:* a route is only valid near where and when it was planned. Evicting on origin drift (≥300 m) stops a stale route from being reused after the rider has clearly moved; the planned-arrival guard evicts a transit route whose service window has passed (last-service boundary); the schema guard protects against reading records written by an older app.
   - *Trade-off:* aggressive eviction favors correctness over hit-rate.
   - *Flaw (serious, vs the core promise):* the **5-min TTL also applies on the offline path.** `OfflineCoordinator.getRoute` (offline_coordinator.dart:166) calls `RouteCache.get` with the default TTL, so a route cached more than 5 minutes ago is **deleted on read even while offline**, and `getRoute` then throws `"Offline and no cached route available"`. The one moment offline caching matters most — a long tunnel or dead network mid-trip when the app wants to re-plan — is exactly when the cache is most likely to be older than 5 minutes and get discarded. (The *active* trip geometry survives because it lives in `RouteRegistry`/`TrackingStateStore`, but any **offline reroute** is impossible after 5 min.)

5. **Tiered refresh intervals scaled to distance-from-destination.** far 15 min / mid 7 min / near 3 min (direction_service.dart:23-25, 163).
   - *Why:* a rider 50 km out doesn't need a fresh route every 3 minutes; a rider close to the stop does. Fewer calls when far = less battery and less proxy load.
   - *Trade-off:* non-distance modes (stops/time) are pinned to the 3-min `nearInterval` regardless of distance — safe but chattier.
   - *Flaw:* the tiers are driven by **straight-line** distance, which underestimates real transit distance on a winding metro; a rider who is 3 km straight-line but 12 km along the line may be refreshed more often than necessary.

6. **Metro-preferring route selection: pick the fastest route that actually contains a rail leg, and promote it to `routes[0]`.** (direction_service.dart:106-128, 211)
   - *Why:* Google's default "best" route for a transit query is often a bus or a walk; a metro-mode user wants the train. Selecting the fastest *rail-containing* route matches user intent and the app's metro-centric alarm logic.
   - *Trade-off:* only index 0 is used downstream (`RouteSessionManager` reads `routes.first`). Google's genuine *alternatives* are discarded, so multi-route local switching is fed **one** route per fetch, not a real alternative set.
   - *Flaw (inconsistency):* the "is this metro?" test is **not the same in two places.** `routeContainsMetroLeg` / `_isMetroStep` accept `SUBWAY, HEAVY_RAIL, RAIL, METRO_RAIL, MONORAIL` (direction_service.dart:78, route_session_manager.dart:1221), but `buildRawSegments`'s `getModeInfo` treats only `SUBWAY, HEAVY_RAIL, RAIL` as metro (direction_service.dart:415). A `MONORAIL`/`METRO_RAIL` route can therefore be *selected* as the metro route yet *rendered and grouped as non-transit*, mis-coloring the line and mis-labeling the transit segment.

7. **Closed-metro fallback re-requests with `departure_time` anchored to the next 09:00 local.** (direction_service.dart:130, 223)
   - *Why:* when a rider opens the app late at night, Google returns "no transit route" because the metro is closed; anchoring the query to 09:00 forces Google to return the route the rider will actually take in the morning, so the map/plan isn't empty.
   - *Trade-off:* the returned schedule (ETA, planned arrival) is for **tomorrow morning**, not now.
   - *Flaw:* the cached `plannedArrivalEpoch` becomes a future time, and any ETA/"never late" reasoning built on that window is meaningless for the current moment. The 09:00 constant is a hard-coded guess that ignores line-specific first-train times.

8. **Overview polyline is RDP-simplified at 10 m and gzip+base64 compressed for caching (`simplified_polyline`), but is the *last-resort* geometry for tracking.** (direction_service.dart:281, route_session_manager.dart:300)
   - *Why:* the compact polyline is cheap to store and transmit; but simplification straightens curves, which would corrupt snapping/progress. So the parser prefers step polylines → overview → simplified, in that order.
   - *Trade-off:* storage/robustness over fidelity for the cached copy.
   - *Flaw:* the compression format is JSON-of-doubles → gzip → base64, which is far larger than Google's own encoded-polyline format; it round-trips safely but wastes cache space.

9. **`RouteRegistry` is a capacity-8, in-memory, LRU store with precomputed geometry.** (route_registry.dart:141)
   - *Why:* snapping runs on every GPS sample; precomputing `cumMeters` and `bbox` at insert time makes each snap and progress lookup cheap. Capping at 8 bounds memory on cheap phones.
   - *Trade-off:* precompute is O(n) `Geolocator.distanceBetween` per vertex at insert — a one-time cost paid up front.
   - *Flaw:* `isNear` uses **distance to the bbox *center* × 2.5** (route_registry.dart:72, 107), not distance to the route. For a long metro line the centroid can be many kilometers from a point that is genuinely *on* the route near an endpoint, so `candidatesNear` (radius 1200 m) can **fail to surface a valid candidate route** for switching on long routes. The `2.5` factor is an admitted, untuned heuristic (`TODO(telemetry)`).

10. **Route switching is double-gated: a "sustain" duration and a post-switch "blackout", both on monotonic `Stopwatch`s.** (active_route_manager.dart:142-168, 213)
    - *Why:* GPS noise near parallel routes would otherwise flip the active route back and forth, thrashing the alarm/ETA. Requiring a candidate to be better *for 6 continuous seconds*, and refusing any switch for 5 s after one, damps that. `Stopwatch` (monotonic) means a phone clock jump (NTP correction, timezone change) can't corrupt the countdown.
    - *Trade-off:* latency — a genuine route change takes ≥6 s to register.
    - *Flaw:* the switch requires the candidate to be `switchMargin` (50 m) better in lateral offset. Two metro lines running <50 m apart (common in dense corridors) will **never** trigger a switch, so a rider on the wrong-but-parallel line keeps being tracked against the original — the wrong-direction detector (G14/G15) is the only backstop.

11. **Wrong-direction / wrong-train detection uses the *sign of along-route progress*, not lateral deviation.** (active_route_manager.dart:359)
    - *Why:* a rider who boards a train in the wrong direction stays perfectly *on* the polyline — lateral offset is ~0 — so a deviation-based check can't catch it. Watching whether cumulative progress *decreases* (toward the origin) does, and it needs no compass/gyro.
    - *Trade-off:* it only fires while confidently snapped (`offset ≤ 80 m`), sustained `≥ 12 s`, and net regression `≥ 60 m` — conservative to avoid false accusations.
    - *Flaw:* the *progress* number it consumes comes from `SnapToRouteEngine`, whose scoring includes a `+100 m` penalty for moving backward more than 3 indices (snap_to_route.dart:171). On the `TrackingService` snap path (which passes `previousResult`), that penalty actively **resists** letting progress go backward, which can blunt the very signal this detector relies on. (On the `ActiveRouteManager` path the penalty is inert — see finding 14.)

12. **`OfflineCoordinator` is a singleton, defaults to *online*, and is the single choke point for online/offline behavior.** (offline_coordinator.dart:98, 145)
    - *Why:* one shared instance means `HomeScreen`'s connectivity listener and `TrackingService`'s reroute logic see the same offline flag; abstract `DirectionsProvider`/`RouteCachePort` seams keep it unit-testable.
    - *Trade-off:* defaulting to online means that at cold start, before connectivity is probed, a fetch will attempt the network.
    - *Flaw:* the offline path throws `StateError` on a cache miss rather than returning a "keep the current route" signal, pushing all graceful-degradation responsibility onto every caller; and it silently drops `preferMetroEvenIfClosed`/`forceRefresh`, so an offline metro user can get a non-metro cached route.

13. **Two separate point-to-polyline snappers exist** — `SnapToRouteEngine` (snap_to_route.dart) for tracking, and `snapPointToPolyline` (polyline_decoder.dart:180) as a helper used by stop/segment math.
    - *Why:* the tracking snapper needs continuity/heading scoring and equirectangular projection; the helper is a plain nearest-point for one-shot stop distance calculations.
    - *Trade-off / flaw:* the helper's `_projectPointOnSegment` (polyline_decoder.dart:227) projects in **raw degree space with no `cos(lat)` correction**, so away from the equator its perpendicular foot is biased east-west. For Bengaluru (~13°N) the longitudinal error is ~2.6%; over short segments it's small but it means the two snappers can disagree, and stop-distance math is very slightly skewed.

14. **`SnapToRouteEngine.snap` accepts a `hintIndex` parameter but never uses it.** (snap_to_route.dart:43-111 — the window in `_snapInRange` is driven only by `previousResult?.segmentIndex`.)
    - *What actually happens (verified against all call sites):* `ActiveRouteManager._snapTo` and both `maptracking.dart` calls pass `hintIndex` (from `lastSnapIndex`) but **no** `previousResult`, so the "windowed" search silently degrades to a **full O(n) linear scan of the whole polyline on every sample**, and the continuity/backward-motion scoring (which requires `previousResult`) is **inert** on those paths. Only `TrackingService` (trackingservice.dart:1125) passes `previousResult`, so only *its* snap path gets the window + scoring.
    - *Why it's arguably tolerable:* a full scan is robust — after a long GPS outage underground the rider is relocated *globally* with no window to get "stuck" in, which is good for the core promise. And with scoring inert, progress can freely decrease, so the wrong-direction detector (finding 11) is *not* blunted on the ARM path.
    - *Flaw:* it's still a **dead parameter and a real CPU cost** — on a long metro polyline (thousands of vertices), scanning every vertex for up to 3 candidate routes on every 1 Hz sample is meaningful battery/CPU load on the exact cheap Android phones the promise targets. The `> 500 m` full-route "escape hatch" (line 84) is also dead for the ARM path because it requires `previousResult != null`.

15. **`RouteLogger` writes the full raw Directions payload to disk on every successful fetch, enabled by default.** (route_logger.dart:24, direction_service.dart:340)
    - *Why:* captured payloads let the team reconstruct real routes for the replay/simulation harness and for `bengaluru_metro_routes.json` fixtures — invaluable for debugging a subsystem whose failures are hard to reproduce.
    - *Trade-off:* debuggability vs privacy/storage.
    - *Flaw:* it's on **in production**, with **no rotation, no size cap, and no cleanup**. Every trip appends a pretty-printed JSON file containing the rider's exact origin and destination — a growing store of location history (a privacy exposure) that also slowly fills the device.

16. **`RouteQueue` (route_queue.dart) and `RouteMetadata`/`RouteMetadataManager` (route_metadata.dart) are effectively orphaned.**
    - `RouteQueue` has **zero references** anywhere in `lib/` or `test/` — it is dead code superseded by `RouteRegistry` + `ActiveRouteManager`.
    - `RouteMetadata` is referenced **only by tests** (`route_metadata_test.dart`, `reroute_chain_integration_test.dart`) — the live tracking pipeline does not use it.
    - *Why it matters:* `RouteMetadata` models exactly the "which alarm events / legs have already fired" and "destination alarm fired" state that is load-bearing for *never-fire-twice* and *never-miss* behavior. Because it isn't wired in, a reader can mistake it for the source of truth for alarm de-duplication when the real mechanism lives elsewhere (`tracking/alarm_controller.dart`). This is stale scaffolding that should be either wired in or deleted to avoid misleading future work.

17. **Fragile step/stop scaling with unresolved comments left in production.** (route_session_manager.dart:362-380, 539-543)
    - *Why:* Google reports per-step *distances*, but the decoded polyline has its own measured length; the two must be reconciled into one meter-domain or stop-based alarms drift. Scaling bounds/legs/events by `polylineMeters/stepLen` is the reconciliation.
    - *Trade-off:* it's a heuristic correction, not a first-principles fix.
    - *Flaw:* `_buildCumulativeStops` is **called twice back-to-back** (the first result is immediately overwritten, lines 362 & 371) surrounded by a block of `// Wait, ... ?` self-doubt comments — a sign the stop-scaling correctness was never fully settled. Worse, **event scaling is applied even on the fallback polyline** (line 541 has no `!usedFallbackPolyline` guard, unlike the bounds scale at line 351): when geometry falls back to `[origin, destination]`, `polylineMeters` (straight-line) and `stepLen` (summed API distances) diverge wildly, so event/alarm positions get mis-scaled. Fallback mostly triggers in tests, but a partial real-world fallback would place events at the wrong meters.

---

### Invariants

- **Route identity:** a route is identified end-to-end by `RouteCache.makeKey(origin, destination, mode, transitVariant, departureTime)`. The same physical trip must produce the same key across `DirectionService`, `RouteCache`, `RouteRegistry`, and `RouteSessionManager` (coordinates rounded to 5 decimals for stability).
- **Meter domain consistency:** for a given route key, `RouteEntry.cumMeters`, `stepBoundsMetersByKey`, `stepStopsCumulativeByKey`, `transitLegStopsByKey.stopMeters`, and `routeEventsByKey.meters` must all live in the **same** meter domain (the decoded polyline length). All the scaling logic exists to preserve this; violating it desynchronizes stops/events from snapped progress and mis-times alarms.
- **Progress monotonic-ish along the active route:** `progressMeters ∈ [0, lengthMeters]`; `remainingMeters = clamp(lengthMeters − progress, 0, ∞)`.
- **Registry bounds:** `RouteRegistry` never exceeds `capacity` (8); the active key must always correspond to a live entry when `ingestPosition` runs.
- **Switch safety:** no route switch occurs during the post-switch blackout, and only after the sustain window; `EKF station snap index` and `_lastEkfSnapIndex` are monotonically non-decreasing per route.
- **Cache freshness:** any `RouteCacheEntry` returned by `RouteCache.get` is within TTL, matches the current `schemaVersion`, has a planned arrival in the future (if any), and was fetched within 300 m of the requested origin.
- **Points floor:** a registered route's `points` list always has ≥2 entries (falls back to `[origin, destination]`).

### Interfaces

- **Consumes:**
  - **The GeoWake proxy server** (Railway) for all Google Maps data via `ApiClient` — Directions, Places autocomplete/details, nearby-search, geocode.
  - **`Geolocator`** for geodesic distance/bearing throughout.
  - **`Hive`** for L2 persistence (`route_cache_v1` box); **`SharedPreferences`** for the auth token/device id; **`path_provider`** for `RouteLogger`'s directory.
  - **`TransferUtils`** (subsystem: transit legs/steps) for `buildStepBoundariesAndStops`, `extractTransitLegStops`, `enhanceTransitLegStopsWithOsm`, `buildRouteEvents`.
  - **`TrackingStateStore`** for persisted transit-leg restoration.
  - **`metro_color_map.dart`** (`metroLineColors`) for line coloring.
  - **`DeviationMonitor`, `ReroutePolicy`, `SoftLockManager`** (subsystem: deviation/reroute) — constructed and driven by `RouteSessionManager`.
- **Exposes:**
  - **To `TrackingService` / `HomeScreen`:** `OfflineCoordinator.getRoute` (fetch), `RouteSessionManager.registerRouteFromDirections` / `ingestPosition` / stream set (`routeStateStream`, `routeSwitchStream`, `rerouteStream`, `deviationStateStream`, `wrongDirectionStream`).
  - **To the alarm/ETA subsystem:** `ActiveRouteState` (progress/remaining/offset), `WrongDirectionAlert`, `StationSnapConfirmed` handling, and the per-key maps (`routeEventsByKey`, `stepStopsCumulativeByKey`, `transitLegStopsByKey`, `firstTransitBoardingByKey`).
  - **To the map UI / dashboards:** `DirectionService.buildSegmentedPolylines(...)`, `LocationManager.broadcastRoute(...)`, `RouteEntry` geometry.
  - **To the EKF / snapping consumers:** `SnapToRouteEngine.snap` and the `RouteEntry.cumMeters`/`bbox` precomputes.

### Gaps & flaws vs the core promise

- **Offline reroute dies after 5 minutes (highest risk).** The offline path reuses `RouteCache.get`'s 5-min TTL, so a cached route older than 5 minutes is *deleted on read* while offline and `getRoute` throws. For "GPS dies underground / network is dead," the app cannot re-plan from cache after the first few minutes. The active trip's *geometry* survives in memory, so a straightforward trip still alarms; but any mid-trip reroute while offline is impossible, and if the app/isolate is restarted offline (OS kill on a cheap phone), there is no ≥5-min-old route to restore from this cache.
- **Single proxy = single point of failure.** Every route fetch depends on one Railway host with no fallback provider and possible cold-start latency at session start. If it's down, tracking cannot start at all, even with Google fully available.
- **401-retry has no timeout.** A hung re-auth retry on a flaky Indian network can block a fetch indefinitely, undermining the 15 s budget precisely in the target environment.
- **CPU cost from the dead `hintIndex`.** Because the window hint is ignored on the `ActiveRouteManager`/`maptracking` snap paths, snapping is a full O(n) scan per candidate per sample — heavy on long metro polylines on low-end phones (battery/thermal). Correctness is fine; efficiency is not.
- **Long-route candidate discovery is weak.** `isNear`'s bbox-center × 2.5 heuristic can hide valid alternative routes on long lines, so multi-route local switching (a never-wrong-place safeguard) is least reliable exactly where routes are longest.
- **Parallel-line blind spot.** The 50 m switch margin means a rider on a wrong parallel line (or opposite platform) is never switched; only the conservative G14/G15 wrong-direction detector (≥12 s, ≥60 m regression) can catch it — a real delay before the "you're going the wrong way" signal.
- **Closed-metro fallback distorts timing.** Anchoring to 09:00 produces a next-morning schedule whose planned arrival/ETA is not valid "now," so any never-late reasoning off that window is unsound until a real fetch replaces it.
- **Metro-classification inconsistency** (`MONORAIL`/`METRO_RAIL` selected-but-not-rendered-as-metro) can mislabel/mis-color a leg, and — because segment grouping feeds boarding/alighting detection — risks missing switch/boarding events on those vehicle types.
- **Fallback event mis-scaling** (unguarded `eventScale` on fallback geometry) can place events/alarms at wrong meters when geometry degrades to origin→destination.
- **Privacy/storage leak.** `RouteLogger` persists origin/destination for every trip forever, unrotated — a location-history exposure and slow disk fill on-device.
- **Orphaned alarm-dedup model.** `RouteMetadata` (fired-events/destination-fired state) is not wired into production, so it is not the mechanism guaranteeing "never alarm twice / never miss" — a maintenance hazard and a place a future contributor could wrongly rely on. `RouteQueue` is outright dead code.
- **Unsettled stop scaling.** The duplicated `_buildCumulativeStops` call and the "Wait…?" comments indicate the step-stop meter reconciliation was never conclusively verified, which directly affects stops-mode alarm accuracy ("wake me 2 stops before").
