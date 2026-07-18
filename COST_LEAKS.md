# GeoWake / WakePoint — Cost-Leak Audit (where the app actually loses money)

_2026-07-15. Source-grounded audit of every place real money is (or can be) spent. Every claim is tied to `file:line` verified this session. Severity: **CRITICAL** = unbounded / someone else spends your money; **HIGH** = you overpay on normal usage; **MED** = wasteful or masks a leak; **LOW** = watch. Dollar figures are illustrative (verify against your GCP SKU rates)._

---

## 0. TL;DR — the money map

**Only one thing in this whole system costs variable money: the Google Maps API.** Map *display* on mobile is free; compute is free/fixed; Firebase is free-tier. So every rupee at risk flows through four SKUs: **Directions ($5/1k), Autocomplete (per session), Place Details, Geocoding**, all proxied by your Railway server.

There are exactly **two kinds of leak**, and they're different problems:

- **(A) The catastrophic tail — someone else spends your money.** Your token endpoint hands a 24-hour Maps-capable JWT to anyone who knows your (public) bundle ID, with only per-IP rate limits and no global spend ceiling. This is the one that produces a shock bill. **Unbounded until capped.**
- **(B) The structural drip — you overpay on normal usage.** You re-buy the *same commute route* every day (5-minute cache), and a single "Wake Me!" can fire **2–4 Directions calls** because of a metro-fallback fetch plus a retry that deliberately bypasses the cache. Roughly **~10× the Directions spend you actually need.**

Fix (A) first (it's existential), then (B) (it's the recurring bill). Both are cheap fixes.

| # | Sev | Leak | Where | ~Impact |
|---|---|---|---|---|
| 1 | **CRITICAL** | Drainable key: 24h token to anyone with the public bundle ID; no attestation; per-IP limits only; no global spend cap; CORS `*` | `authController.js:8-17`, `auth.js:20-28`, `api_client.dart:114`, `security.js:13,47-60`, `config.js:22-29` | Unbounded $ — an abuser drains your Maps quota |
| 2 | **HIGH** | Re-buys the same commute daily: client + server caches both expire in 5 min | `route_cache.dart:86,158-162`, `cache.js:7-8`, `config.js:32-36` | ~10× Directions on repeat commuters |
| 3 | **HIGH** | One arm = 2–4 Directions calls: metro-fallback refetch + catch-all retry that bypasses cache & fires on ZERO_RESULTS | `direction_service.dart:199,223-233,265-269,363-375` | 2–4× per arm; foot-gun on repeat taps |
| 4 | **MED** | Proxy is blind to Google's `200 + status:ERROR`; caches ZERO_RESULTS / OVER_QUERY_LIMIT as "success" | `mapsController.js:9-36` | Masks quota drain; feeds the #3 retry storm |
| 5 | **MED** | Autocomplete session token is a timestamp, not a UUID → may bill per-request, not per-session | `places_service.dart:11-19` | Possible 5–10× on search cost |
| 6 | **LOW** | Nearby Search (post-arrival "stations near you") is one of the priciest SKUs (~$32/1k) | `api_client.dart:427-457` | Expensive if wired to the arrival card at scale |
| 7 | **LOW** | Railway server = the only true fixed cost | infra | ~$5–20/mo flat |

---

## 1. 🔴 CRITICAL — the drainable key (this is how you get a $10k surprise)

**The vector, end to end:**
- The app authenticates by POSTing a **hardcoded, public bundle ID** — `com.geowake.app` (`api_client.dart:114`) — to `/auth/token`.
- The server issues a signed 24-hour JWT to **anyone** who sends that string: `generateToken` only checks `bundleId === config.appBundleId` (`authController.js:8-17`). The gate on every Maps call is the same single check (`auth.js:20-28`).
- The bundle ID is **not a secret** — it's in every decompiled APK, in this repo, and in `config.js:21`. So anyone can mint a token and call `/maps/directions` ($5/1k) as much as they like.
- The only brake is **per-IP** rate limiting (`security.js:13,30` key on `x-forwarded-for`) at **1,000 requests/hour/IP** (`config.js:28`). That's **~$5/hour per IP** of Directions — and a rotating-proxy or botnet sidesteps per-IP limits entirely. `allowedOrigins` also includes `'*'` (`config.js:24`).
- **There is no global daily spend ceiling** anywhere in the code (`grep quota` → 0). Nothing caps total burn.

**Why it matters:** every other cost here scales with your users. This one scales with *an attacker's motivation*. It's the single biggest financial risk in the codebase, and it's already flagged as `GAP_ANALYSIS` G28.

**Fixes (in order):**
1. **Put a hard daily cap on the Google key in the GCP console** (per-API quota + a billing budget alert). This is the backstop that bounds the worst case no matter what the app does. Do this today — it's a settings change, not code.
2. **Attest the device before issuing a token:** Play Integrity API (Android) / App Attest (iOS) on `/auth/token`, so only genuine app installs get a token — not anyone with a curl command.
3. **Add a server-side global spend counter** that hard-stops proxying at $X/day and alerts you.
4. **Rate-limit per authenticated device, not per IP**, and drop the `'*'` origin.

---

## 2. 🟠 HIGH — you re-buy the same commute every single day

A commuter takes the *same* route daily; its geometry and stop sequence are stable for weeks. But **both cache layers throw it away after 5 minutes:**
- Client L2 (Hive) `RouteCache`: `defaultTtl = 5 min` (`route_cache.dart:86`), and it **evicts on read** the moment it's stale (`:158-162`) — plus on schema mismatch, passed planned-arrival, and origin deviation ≥300 m (`:165-203`).
- Server (node-cache): `stdTTL: 300` (`cache.js:7-8`), Directions TTL 5 min (`config.js:33`).

Consequences:
- **Tomorrow's identical arm is a full-price refetch.** The `RouteMemoryService` remembers recents for the *UI*, but the actual Directions payload isn't persisted for cost reuse. So a daily rider pays for the same route ~20–40×/month instead of ~once.
- **The server cache is in-memory** → wiped on every Railway restart/sleep/redeploy (no Redis/persistence), so its real hit-rate is far below what the logs imply.
- **The server Directions key uses the raw origin `lat,lng`** (`cache.js:24`) — transit riders almost never stand on the exact same coordinate, so cross-user reuse is ~nil. The server cache barely helps the transit case.
- The in-memory L1 in `DirectionService` is per-instance, and `DirectionService()` is `new`'d in several places (`maptracking.dart:333,367`, dashboards), so L1 rarely survives across the flows that matter — everything leans on the 5-minute L2.

**Fix:** persist each *saved/recent* commute's directions long-term (days–weeks) keyed to the `RouteMemoryService` route, and only refetch on a real change (origin moved > threshold, or the planned service window rolled over). The reachability design *helps you here*: you fetch the route once at arm and physics carries the never-late guarantee through the tunnel — you do **not** need fresh routing mid-trip. Move the server cache to Redis (Railway add-on) so it survives restarts. This is the single biggest cut to the recurring bill (~10× on committed users).

---

## 3. 🟠 HIGH — one "Wake Me!" can fire 2–4 Directions calls

`DirectionService.getDirections` (`direction_service.dart:46`) is a tiered fetch, and on a cache miss it can multiply:
1. **Primary** Directions call (`:199`).
2. **Metro fallback:** in metro mode, if the primary route has no metro leg (common late-night or in cities where Google won't return transit), it fires a **second** Directions call with a forced future `departure_time` (`:223-233`).
3. **Catch-all retry:** the `catch` block retries the whole thing with `forceRefresh: true` (`:363-375`) — which **bypasses both caches** (`:140,183`). Critically, it retries on **every** exception, *including the legitimate "No feasible route found"* thrown at `:265-269` when Google returns `ZERO_RESULTS`.

So an **unroutable or edge destination bills up to ~4 calls** (primary + fallback, then force-refreshed primary + fallback) — all of which fail — and then throws. If the user taps "Wake Me!" again, that's another 4. A normal metro arm where Google returns no metro leg **always doubles**.

**Fixes:**
- **Don't retry on `ZERO_RESULTS` / OK-with-no-routes.** Only retry on network/5xx, with backoff and a hard cap of 1.
- **Negative-result cache:** remember "this origin/dest has no route" for a few minutes so repeat taps don't re-bill.
- **Gate the metro fallback** behind "primary genuinely errored," not merely "no metro leg found," and never let `forceRefresh` skip the negative cache.
- **Lock the arm button** while a fetch is in flight (prevents tap-storms).

---

## 4. 🟡 MED — the proxy can't see Google's in-body errors

`googleApiProxy` treats **any HTTP 200 as success**: it caches `response.data` and returns it (`mapsController.js:17-27`). But Google returns **HTTP 200 with `status: "ZERO_RESULTS" | "OVER_QUERY_LIMIT" | "REQUEST_DENIED" | "INVALID_REQUEST"`** in the body. So:
- An `OVER_QUERY_LIMIT` (you're being drained) gets **cached as if it were a valid answer** for 5 minutes — hiding the very event you need to see.
- A `REQUEST_DENIED` (bad/blocked key) returns "successfully" to the app, which then hits the #3 retry path → a retry storm of billable calls.

**Fix:** inspect `response.data.status`; cache and return only `OK` (with routes); surface `OVER_QUERY_LIMIT`/`REQUEST_DENIED` as real errors (and alert yourself); short-cache `ZERO_RESULTS` as a *negative* result so repeats don't re-bill.

---

## 5. 🟡 MED — the Autocomplete session token probably isn't a real session

Google's cheap **Autocomplete "Per Session"** billing requires a valid **UUID** session token that groups the keystrokes + the final Place Details into one charge. Here the token is `DateTime.now().millisecondsSinceEpoch.toString()` (`places_service.dart:15`), rotated every 3 min (`:14`). If Google doesn't recognize a bare timestamp as a session token, each debounced keystroke bills as **Autocomplete Per Request** *plus* a separate **Place Details** — a **5–10× markup on every search**.

Good news: search **is** debounced 450 ms (`homescreen.dart:335`), so you're not billing per keystroke — but you may still be billing per *request* instead of per *session*.

**Fix:** generate a real UUID v4 per session, reuse it for autocomplete + the Place Details call, and reset via the existing `endSession()` after selection. Then confirm in GCP billing that the **Per Session** SKU is what's charged.

---

## 6. 🟢 LOW / watch list

- **Nearby Search is expensive.** `getNearbyTransitStations` (`api_client.dart:427-457`) uses Places **Nearby Search** (~$32/1k — one of the priciest SKUs). If the future post-arrival card calls it per arrival to show "stations/among near you," that scales badly. Serve "nearby station" from your own **805-station dataset** for free; reserve paid Nearby Search for genuinely monetizable commerce lookups.
- **Geocoding cache is only 15 min** (`config.js:35`) for station coordinates that never move — cache for days.
- **Railway server** is the only true fixed cost (~$5–20/mo). Fine — but it's where you'd add Redis and the global spend cap.
- **`testConnection()` health GET every launch** (`api_client.dart:63-85`) — not a Maps call; negligible.
- **`RouteLogger` writes the full Directions payload to disk** every fetch (`route_logger.dart`) — a privacy/disk issue, not a dollar one, but it's default-on.

---

## 7. Fix priority (most $ protected first)

1. **Bound the catastrophic case:** GCP daily quota cap + budget alert on the key **(today)**; Play-Integrity/App-Attest on `/auth/token`; server-side global daily spend ceiling. → kills the unbounded drain (#1, #4).
2. **Stop re-buying commutes:** long-TTL persistent route cache tied to saved/recent routes; Redis on the server. → ~10× cut on recurring Directions (#2).
3. **De-multiply the arm:** no retry on `ZERO_RESULTS`, negative-result cache, arm-button lock, fallback only on real error. → 2–4× → ~1× (#3).
4. **UUID session tokens** + verify the SKU. → up to 5–10× on search (#5).
5. **At scale, decouple cost from growth:** self-host **OSRM/Valhalla** on your existing OSM pipeline (`tools/osm_preprocessor.py`, `OsmGraph`, `Pathfinder`) and serve transit geometry from your own dataset → Directions cost flattens toward fixed. This is the structural answer to "prices go crazy as we scale."

---

## 8. Rough per-user model (illustrative — verify against your SKU rates)

| | Directions calls/mo (committed daily rider) | ~Maps cost/user/mo |
|---|---|---|
| **Today** (5-min cache + 2–4× per arm) | ~40 arms × ~1.8 avg ≈ **70** + searches | **~$0.40–0.90** |
| **After #2 + #3** (persist commute, de-multiply) | ~3–5 refetches + occasional search | **~$0.03–0.08** |
| **After #5** (self-host routing at scale) | routing ≈ flat infra, Maps only for search | **≈ fixed, sub-linear** |

The drip (#2/#3/#5) is a ~10× efficiency gain and fully in your control. The tail (#1) is **unbounded until you cap it** — which is why it, not the per-call price, is the real "where we lose money."

_Verify: current Google Maps SKU rates (Directions $5/1k, Autocomplete session vs request, Nearby Search ~$32/1k) and your GCP key's quota settings, before acting on the dollar figures._
