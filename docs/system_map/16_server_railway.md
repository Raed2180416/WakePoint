## 16. Railway Server (API-key protection, Maps proxy, device auth)

**Role in the core promise:** The core promise — *wake a rider before their stop, never late, never at the wrong place, even when GPS dies underground on a cheap Android phone in India* — is fulfilled **on the phone**, not on this server. This Node/Express service is a **trip-*planning*-time dependency only**: it is the app's sole gateway to Google Maps (directions, place autocomplete, place details, geocoding, nearby search) and it exists so the Google Maps API key is **never shipped inside the APK** (where anyone could decompile and steal it). During the actual ride — the moment that matters for the promise — the app does *not* talk to this server: the wake decision, EKF dead-reckoning, and alarm firing are all local. So the server's contribution to the promise is indirect but real: **if this server is down or slow, the rider cannot search for a destination or fetch a route, and therefore can never arm the alarm in the first place.** It is a single point of failure at *setup*, sitting between a flaky Indian mobile network and a US/EU-hosted API. Once the trip is armed, it drops out of the loop entirely.

**Files:**

| Path | What it does |
|---|---|
| `geowake-server/src/server.js` | Express app bootstrap: security headers, CORS, body parsing, logging, global slow-down, route mounting (`/api/auth`, `/api/maps`), health checks (`/`, `/api/health`), 404 + error handlers, `app.listen`, graceful SIGINT/SIGTERM shutdown. |
| `geowake-server/src/config/config.js` | Central config from env vars (port, `GOOGLE_MAPS_API_KEY`, `JWT_SECRET`, `APP_BUNDLE_ID`, allowed origins, rate-limit caps, cache TTLs, Google Maps endpoint URLs). Hard-exits process if the API key or a ≥32-char JWT secret is missing. |
| `geowake-server/src/controllers/authController.js` | `generateToken`: issues a 24h JWT to any caller who POSTs the correct `bundleId` string. |
| `geowake-server/src/controllers/mapsController.js` | `googleApiProxy` generic proxy (cache-check → axios GET to Google with server-side key → cache-set → return) plus five typed handlers: directions, autocomplete, place-details, geocoding, nearby-search. |
| `geowake-server/src/middleware/auth.js` | `authenticateDevice`: verifies the Bearer JWT and checks the embedded bundle ID. `generateDeviceToken` helper (exported but **unused** by any route). |
| `geowake-server/src/middleware/security.js` | Factory functions for `express-rate-limit` (hard 429 caps) and `express-slow-down` (progressive delay). Exports `slowDownRules`, `rateLimitRules`, and `handleRateLimitError`. |
| `geowake-server/src/routes/auth.js` | Mounts `POST /api/auth/token` behind the strict auth rate-limiter. |
| `geowake-server/src/routes/maps.js` | Mounts the five `POST /api/maps/*` proxy routes behind the maps rate-limiter (auth applied at the parent mount in `server.js`). |
| `geowake-server/src/utils/cache.js` | `CacheManager` singleton wrapping `node-cache`: builds structured cache keys per request type, get/set with per-type TTL, periodic stats logging. |
| `geowake-server/package.json` | Node 18.x, Express 4.21, deps (axios, jwt, helmet, cors, compression, morgan, rate-limit, slow-down, node-cache, dotenv, **bcryptjs — unused**). Scripts: `start`, `dev` (nodemon), `test`/`jest`. |

---

### How it works, step by step

There are exactly **two** things the app ever asks this server to do: (1) get a token, then (2) proxy a Maps call using that token. Everything else is plumbing.

#### A. Server boot (`server.js` + `config.js`)
1. `require('./config/config')` runs first. `dotenv` loads `.env`, then `config.js` validates: if `GOOGLE_MAPS_API_KEY` is falsy → `console.error` + `process.exit(1)` (`config.js:49-52`). If `JWT_SECRET` is missing **or** shorter than 32 chars → `process.exit(1)` (`config.js:54-57`). So a misconfigured deploy **refuses to start** rather than run insecurely — good fail-closed behavior.
2. `server.js` builds the Express app and installs middleware **in this exact order** (order matters):
   - `helmet(...)` security headers, but with `crossOriginEmbedderPolicy:false` and `contentSecurityPolicy:false` (`server.js:23-26`).
   - `compression()` (gzip responses).
   - `cors(...)` with a function origin-checker (`server.js:32-48`): **no-origin requests (mobile apps, curl) are always allowed**; browser origins are allowed only if in `config.allowedOrigins` — but that list defaults to `['https://geowake-production.up.railway.app', '*']`, and the `'*'` entry means *every* origin passes (`server.js:38`).
   - `express.json({limit:'10mb'})` + `express.urlencoded(...)` — 10 MB body cap.
   - `morgan` request logging (emoji dev format vs `combined` in prod, `server.js:55-59`).
   - `app.use(slowDownRules.general)` — **global** progressive slow-down (`server.js:62`).
3. Routes mount: health checks (`/`, `/api/health`, no auth), then `app.use('/api/auth', authRoutes)` (no auth), then `app.use('/api/maps', authenticateDevice, mapsRoutes)` — **auth middleware is applied here, at the mount**, so every `/api/maps/*` route is protected (`server.js:69-95`).
4. Tail middleware: a catch-all 404 JSON responder (`server.js:103-109`), then `handleRateLimitError`, then the global error handler that hides stack traces unless `nodeEnv==='development'` (`server.js:114-127`).
5. `app.listen(config.port)` prints a banner and registers SIGINT/SIGTERM handlers that call `server.close()` for graceful shutdown (`server.js:133-161`).

#### B. Token issuance (`POST /api/auth/token`)
1. Request hits `rateLimitRules.auth` first: **max 20 requests per 15-minute window per IP** (`security.js:52-55`). Over that → 429.
2. `generateToken` (`authController.js:8`) reads `req.body.bundleId`. If missing or `!== config.appBundleId` → **401** `"Unauthorized: Invalid application identifier."` (`authController.js:12-17`).
3. On match, it signs a JWT with payload `{ bundleId, iss:'GeoWake-Server' }`, secret `config.jwtSecret`, `expiresIn:'24h'` (`authController.js:21-28`) and returns `{success, token, expiresIn:'24h'}`.
   - **Note the payload contains only `bundleId` + `iss`** — no `deviceId`, no `appVersion`. (The unused `generateDeviceToken` helper in `auth.js:60` *does* add those, but no route calls it.)

#### C. Authenticated Maps proxy (`POST /api/maps/*`)
1. `authenticateDevice` (`auth.js:7`) runs (mounted in `server.js:95`). Requires header `Authorization: Bearer <jwt>`; missing/malformed → **401** (`auth.js:10-15`). Strips `"Bearer "`, `jwt.verify(token, config.jwtSecret)`.
2. If verify throws: `TokenExpiredError` → 401 "Token expired. Please refresh." ; `JsonWebTokenError` → 401 "Invalid token format." ; **anything else → 500** (`auth.js:38-55`).
3. On success it checks `decoded.bundleId !== config.appBundleId` → **403** "Invalid app credentials" (`auth.js:23-28`), then sets `req.device = {id: decoded.deviceId, bundleId, appVersion:decoded.appVersion}` — **`id` and `appVersion` are `undefined`** for real tokens (see B). `next()`.
4. Router-level `rateLimitRules.maps`: **max `MAX_REQUESTS_PER_HOUR` (default 1000) per hour per IP** (`security.js:56-59`, `maps.js:9`).
5. The typed handler (e.g. `getDirections`, `mapsController.js:39`) pulls the relevant fields out of `req.body`, assembles a `params` object, and calls `googleApiProxy(req, res, {url, params, type})`.
6. `googleApiProxy` (`mapsController.js:9`):
   - **Cache check:** `cache.get(type, params)`. On hit → `res.json(cachedData)` immediately, no Google call (`mapsController.js:11-14`).
   - **Miss:** `axios.get(url, {params:{...params, key: config.googleMapsApiKey}})` — the API key is injected *here*, server-side only (`mapsController.js:17-22`).
   - **Success:** `cache.set(type, params, response.data)` then `res.json(response.data)` — the raw Google body is passed straight through (`mapsController.js:24-27`).
   - **Failure:** logs, then `res.status(error.response?.status || 500)` with a generic error + `error_message` detail (`mapsController.js:28-35`).

#### D. Caching (`cache.js`)
- `node-cache` config: `stdTTL:300` (5 min default), `checkperiod:120`, `useClones:false` (`cache.js:7-11`).
- `generateKey(type, params)` (`cache.js:21`) builds a deterministic string key per type — e.g. directions keys on `origin:destination:mode:transit_mode:departure_time`; places on `input:location:radius:components`; place-details only on `place_id`; geocoding on `latlng||address`; nearby on `location:radius:type`.
- `set` picks TTL from `config.cacheTimeouts[type]` → directions **300 s**, places **600 s**, geocoding **900 s**; **any type not in that map (e.g. `place-details`, `nearby-search`) falls back to 300 s** (`cache.js:60`, `config.js:32-36`).
- Every 5 min a `setInterval` logs `Keys/Hits/Misses` (`cache.js:14-17`).

#### E. Rate-limiting & slow-down (`security.js`)
- **Slow-down** (adds latency, never rejects): `general` = after `maxRequestsPerMinute/2` (default 50) requests/min, add `hits*100 ms` delay; applied globally (`security.js:37-40`, `server.js:62`). A `maps` slow-down rule (`delayAfter:50`, 15-min window) is **defined but never mounted**.
- **Hard limits** (429): `auth` 20/15min, `maps` `MAX_REQUESTS_PER_HOUR`/hour. A `general` hard limit (`maxRequestsPerMinute`/min) is **defined but never applied anywhere** — see flaws.
- Both factories key on `req.headers['x-forwarded-for']?.split(',')[0] || req.ip` to get the caller's real IP behind Railway's proxy (`security.js:13,30`).

---

### Key types & functions

- **`config`** (`config.js`) — plain object, validated at load. Exposes `port`, `googleMapsApiKey`, `jwtSecret`, `jwtExpiration:'24h'`, `appBundleId`, `allowedOrigins[]`, `maxRequestsPerHour/Minute`, `cacheTimeouts{}`, `googleMapsUrls{}`.
- **`generateToken(req, res)`** (`authController.js:8`) — bundle-ID gate → 24h JWT. Responsibility: mint the app's session credential.
- **`authenticateDevice(req, res, next)`** (`auth.js:7`) — Bearer-JWT verifier + bundle-ID re-check; gate for all `/api/maps/*`.
- **`generateDeviceToken(deviceId, appVersion='1.0.0')`** (`auth.js:60`) — helper that mints a richer token; **dead code** (exported, never called).
- **`googleApiProxy(req, res, {url, params, type})`** (`mapsController.js:9`) — the one function that ever holds the API key; cache-through proxy.
- **`getDirections / getAutocomplete / getPlaceDetails / getGeocoding / getNearbySearch(req, res)`** (`mapsController.js:39-94`) — thin body-parsers → `googleApiProxy`.
- **`createRateLimit(options)` / `createSlowDown(options)`** (`security.js:7,25`) — factories returning configured middleware.
- **`handleRateLimitError(err, req, res, next)`** (`security.js:63`) — Express error middleware that maps `RateLimitExceeded` → 429; in practice rarely reached because the limiters' own `handler` already responds.
- **`CacheManager`** (`cache.js:5`) — singleton: `generateKey`, `get`, `set`, `clearType`, `getStats`, `flush`.

---

### Design decisions (the WHY)

1. **Proxy Google Maps through a server instead of calling it from the app.**
   *Why:* An API key shipped in an Android APK is trivially extractable (decompile → read strings). A stolen key lets attackers rack up Google billing on your account. Keeping the key only in Railway env vars (`config.googleMapsApiKey`, injected at `mapsController.js:21`) means the APK never contains it.
   *Trade-off:* Adds a network hop and a single point of failure to *every* trip-planning action. A rider in India now depends on round-tripping to a US/EU Railway region before they can even pick a destination. Alternative rejected: Android app-restriction + SHA-1 key restrictions on the Google key (keeps calls direct but is weaker and still exposes the key string).
   *Flaw:* The protection is only as strong as the auth in front of the proxy — which is weak (see #2).

2. **"Auth" = knowing the public bundle-ID string.**
   *Why:* `generateToken` issues a valid 24h JWT to *anyone* who POSTs `bundleId === 'com.geowake.app'` (`authController.js:12`). It's a lightweight "is this probably our app" check with no user accounts, no device attestation.
   *Trade-off:* Zero user-management complexity; no login friction.
   *FLAW (the big one):* The bundle ID is **not a secret** — it's a public constant baked into the APK (`lib/config/app_config.dart:23`, `lib/services/api_client.dart:114`) and visible in the Play Store listing. Any attacker can `curl POST /api/auth/token {"bundleId":"com.geowake.app"}`, get a token, and drain your Google Maps quota/billing through `/api/maps/*`. So the server's *entire reason to exist* (protect the key from abuse) is only weakly met: the key is hidden, but the quota is not protected. The only real backstops are the IP rate limits (#6) and Google's own quota caps. No request signing, no Play Integrity / DeviceCheck attestation, no per-device secret.

3. **Fail-closed config validation with `process.exit(1)`.**
   *Why:* Better to crash on boot than to silently run with no API key or a weak JWT secret (`config.js:49-57`). The ≥32-char JWT rule prevents a trivially brute-forceable secret.
   *Trade-off:* A single missing env var takes the whole service down (and with it, all trip planning). On Railway a bad deploy = crash-loop until fixed.
   *Flaw:* No graceful degradation and no startup health signal distinguishing "misconfigured" from "crashed."

4. **In-memory `node-cache`, TTL by request type.**
   *Why:* Identical Maps queries (same route, same place) are common; caching cuts Google calls (cost) and latency. TTLs reflect volatility: directions 5 min, autocomplete 10 min, geocoding 15 min (`config.js:32-36`).
   *Trade-off:* Simplicity — no Redis to run.
   *FLAWS:* (a) The cache lives in **one process's memory**. A Railway restart, redeploy, or any horizontal scaling wipes/splits it → cache is effectively cold much of the time and never shared across instances. (b) `useClones:false` (`cache.js:10`) returns the *same object reference* to every caller — if any downstream code mutated a cached response it would corrupt the cache for everyone (currently safe only because handlers just `res.json` it). (c) **Error responses are cached too** — see #5.

5. **Pass Google's response straight through and cache it on HTTP 200.**
   *Why:* Simple, transparent proxy; the app parses Google's native JSON shape.
   *FLAW vs the core promise:* Google returns **HTTP 200 with an error body** for `OVER_QUERY_LIMIT`, `REQUEST_DENIED`, and `ZERO_RESULTS`. `googleApiProxy` only branches on axios throwing (non-2xx); a 200-with-error-status body sails through the success path and gets `cache.set` (`mapsController.js:24`). So if the key momentarily hits quota, an `OVER_QUERY_LIMIT` body can be **cached for 5–15 minutes** and served to every rider for that key+params — meaning riders may be unable to plan a trip for the whole TTL window even after quota recovers. There is no inspection of `response.data.status`.

6. **IP-based rate limiting keyed on `X-Forwarded-For[0]`.**
   *Why:* Behind Railway's reverse proxy `req.ip` is the proxy's IP, so the code reads the client IP from the forwarded header (`security.js:13,30`). Limits: auth 20/15min, maps 1000/hour.
   *Trade-offs / FLAWS:*
   - **`app.set('trust proxy', ...)` is never called** (confirmed: no `app.set` anywhere). `express-rate-limit` v7 ships a validation check that throws/warns (`ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`) when an `X-Forwarded-For` header is present but trust proxy is unset — the custom `keyGenerator` reads the header manually but the validator may still fire; at minimum the config is fragile and version-sensitive.
   - **Spoofable:** since the app trusts the client-supplied `X-Forwarded-For` first token, an attacker can rotate that header to dodge the per-IP limit entirely.
   - **CGNAT collateral damage (India-specific):** Indian mobile carriers put huge numbers of subscribers behind carrier-grade NAT, so many *legitimate* riders can share one public IP. A single busy IP could exhaust the 1000/hour maps cap and start 429-ing real users trying to plan trips — directly undermining "let the rider arm the alarm."

7. **Global slow-down applied, but the global *hard* limit and the maps *slow-down* are left unmounted.**
   *Why (intended):* Progressive latency (`slowDownRules.general`) discourages bursts without hard rejects.
   *FLAW:* `rateLimitRules.general` (the per-minute hard cap of `maxRequestsPerMinute`, default 100) is **defined but never `app.use`d** anywhere — the per-minute ceiling is not actually enforced globally; only auth (per-15min) and maps (per-hour) hard caps exist. Symmetrically, `slowDownRules.maps` is defined and unused. This is dead/half-wired config that makes the intended protection weaker than it looks on paper.

8. **CORS allows no-origin requests and defaults to `'*'`.**
   *Why:* Mobile apps and `curl` send no `Origin`; they must be allowed (`server.js:35`). The `'*'` fallback in `allowedOrigins` (`config.js:22-25`) keeps things working before env is tuned.
   *Trade-off:* Convenience during development.
   *Flaw:* With `'*'` present, the origin checker approves every browser origin (`server.js:38`) while `credentials:true` is set — effectively an open CORS policy. Low real risk (there are no cookies/sessions; auth is a Bearer token the browser wouldn't have), but it defeats the point of the allowlist.

9. **Helmet with CSP and COEP disabled.**
   *Why:* This is a JSON API for a mobile client, not a web page; CSP/COEP would add no protection and could interfere with embedding (`server.js:24-25`).
   *Trade-off:* Fine for a pure API; would be wrong if any HTML were ever served.

10. **24-hour token lifetime, no refresh endpoint.**
    *Why:* Long enough that a rider rarely re-auths mid-day; short enough to bound a leaked token's usefulness (`config.js:13`).
    *Trade-off:* No revocation — a leaked token is valid for up to 24h with no way to kill it (stateless JWT, no denylist). The app must silently re-request a token on 401 "Token expired."

11. **Everything is `POST` with a JSON body (even reads like geocoding/autocomplete).**
    *Why:* Uniform handler shape; keeps query params out of URLs/logs.
    *Trade-off:* Non-RESTful and un-cacheable by HTTP intermediaries, but irrelevant here since caching is internal.

12. **`bcryptjs` dependency, `generateDeviceToken` helper — both dead.**
    *Why:* Leftovers from an intended richer auth (device IDs, hashed secrets) that was never built.
    *Flaw:* Dead weight and a misleading signal that device-level auth exists when it does not. `req.device.id`/`appVersion` are always `undefined` because the live token (`authController.js:21`) never sets them.

---

### Invariants

- **The Google Maps API key exists only in Railway env (`config.googleMapsApiKey`) and is injected only inside `googleApiProxy` (`mapsController.js:21`).** It must never appear in a response body, log line, or the APK.
- **The process does not start** unless `GOOGLE_MAPS_API_KEY` is set and `JWT_SECRET` is ≥32 chars (`config.js:49-57`).
- **Every `/api/maps/*` request carries a valid, unexpired JWT whose `bundleId === config.appBundleId`** before any Google call happens (`server.js:95`, `auth.js:20-28`).
- **The JWT-signing/verifying secret is the same `config.jwtSecret`** on both paths (`authController.js:26`, `auth.js:20`).
- **A cache key is a pure function of `(type, params)`** (`cache.js:21`) — the same logical query always maps to the same slot.
- **Health endpoints `/` and `/api/health` never require auth** (Railway liveness).

---

### Interfaces

**Consumes:**
- **Google Maps Platform** (Directions, Place Autocomplete, Place Details, Geocoding, Nearby Search) over HTTPS via axios (`config.googleMapsUrls`).
- **Environment / Railway platform:** env vars (`PORT`, `NODE_ENV`, `GOOGLE_MAPS_API_KEY`, `JWT_SECRET`, `APP_BUNDLE_ID`, `ALLOWED_ORIGINS`, `MAX_REQUESTS_PER_*`); TLS termination and the `X-Forwarded-For` header; SIGTERM on redeploy.

**Exposes (to the Flutter app — subsystem *Route/Directions* and *Search/Geocoding*):**
- `POST /api/auth/token` — body `{bundleId}` → `{token, expiresIn}`.
- `POST /api/maps/directions` — `{origin, destination, mode, transit_mode, departure_time?}`.
- `POST /api/maps/autocomplete` — `{input, sessiontoken, location, components}`.
- `POST /api/maps/place-details` — `{place_id, sessiontoken}` (server forces `fields=name,geometry,formatted_address`).
- `POST /api/maps/geocode` — `{address}`.
- `POST /api/maps/nearby-search` — `{location, radius, type}`.
- `GET /` and `GET /api/health` — liveness JSON.

**Named client counterparts:** `lib/services/api_client.dart` (base URL `https://geowake-production.up.railway.app/api`, mints token at `/auth/token` with `bundleId:'com.geowake.app'`, line 114/118) and `lib/config/app_config.dart` (`appBundleId='com.geowake.app'`, base URL line 17). These feed the app's route-planning and destination-search subsystems (see sections 08 Route/Directions and the metro/stop data flow), which in turn set up the on-device tracking + alarm that actually deliver the promise.

**Config-drift risk to flag:** `config.appBundleId` defaults to `'com.geowake.app'` and the client sends `'com.geowake.app'`, but the checked-in tests (`test/auth.test.js`, `test/maps.test.js`) send `'com.yourcompany.geowake2'`. Unless `APP_BUNDLE_ID` is overridden to that value in the test env, the auth tests would receive 401 and fail — the token gate is a single hard-coded string that three sources spell differently.

---

### Gaps & flaws vs the core promise

- **The server is a hard, un-fallbacked dependency for *starting* a trip.** No route can be fetched, no destination geocoded, and no metro stop resolved via Google without it. If Railway is down, slow, or the region is far from the rider (India → US/EU), the rider may be unable to arm the alarm at all. There is **no offline/last-known-route fallback in this layer** — any resilience must live in the app. For "never miss the stop," the most dangerous failure is *not being able to set up monitoring in the first place*, and that failure mode is fully exposed here.
- **Quota abuse is wide open.** Because auth is just a public bundle-ID string (#2), an attacker can mint tokens and exhaust the Google key's quota/billing. If quota is exhausted, legitimate riders get `OVER_QUERY_LIMIT` — and worse, that error can be **cached and served for up to 15 minutes** (#5). Both directly block trip setup.
- **Rate limiting is both spoofable and prone to false positives** (#6): trivially bypassed by header spoofing, yet capable of 429-ing whole blocks of CGNAT-shared Indian mobile users off the maps endpoint. `trust proxy` is unset, so the limiter's own correctness is version-fragile.
- **Cache is single-instance and volatile** (#4): no shared cache, wiped on every deploy/restart, so real-world hit rates are lower than the TTLs suggest → more Google calls, more latency, more exposure to quota limits on flaky networks.
- **No input validation.** Handlers forward `req.body` fields verbatim; a missing `origin`/`destination` just produces a Google error that's proxied back (and possibly cached). No schema, no sanitization, no useful client-facing error mapping.
- **No observability beyond `console.log`.** Cache stats and errors go to stdout; there is no metrics/alerting to notice a quota outage or a spike of 429s — exactly the conditions that would silently prevent riders from arming alarms.
- **No reverse-geocoding path.** `getGeocoding` only sends `address` (`mapsController.js:75`); the cache key even anticipates `latlng` (`cache.js:33`) but nothing populates it — so "what stop am I near, by coordinates?" cannot be answered through this proxy, only forward address lookup.
- **Dead/half-wired code** (`generateDeviceToken`, `bcryptjs`, `rateLimitRules.general`, `slowDownRules.maps`) overstates the security posture and should be either wired up or removed.
