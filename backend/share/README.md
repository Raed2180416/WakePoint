# geowake-share

The Railway backend for **GeoWake journey sharing** — a tiny, zero-dependency
Node service that relays a **single coarse location point** to a recipient web
page and fires an "arrived safely" hook, then hard-deletes everything on expiry.

It is the server half of `HttpShareBackend`
(`lib/services/share/live_share_backend.dart`) and implements
[`docs/share/BACKEND_CONTRACT.md`](../../docs/share/BACKEND_CONTRACT.md) exactly.

## Privacy invariants (enforced in code)

| Invariant | How it's enforced |
|---|---|
| **Latest-only** | One record per id; a ping **overwrites** the single point. No array/history exists anywhere. |
| **TTL + hard delete** | Every share has `expiresAtMs`; a 30 s sweeper + lazy-read hard-delete expired records. `DELETE` hard-deletes on demand. No archival. |
| **Never into a data pipeline** | Coordinates are never logged or emitted to analytics. The `arrived` hook is the only side channel and carries **no coordinates**. |
| **Coarse only** | Coordinates rounded to 5 dp on ingest **and** on read. |
| **Auth** | Every `/v1` route requires the founder's bearer token (constant-time compared). |

Also hardened: locked-down CORS (never `*`), a hard per-IP rate limit, an 8 KB
body cap, TTL clamping, and a strict CSP on the recipient page (fully
self-contained, zero external requests).

## Endpoints

| Method | Path | Auth | Body | Response |
|---|---|---|---|---|
| GET | `/` | — | — | `200 {status:"ok"}` (healthcheck) |
| POST | `/v1/share` | Bearer | `{id, mode, destLabel, etaEpochMs, expiresAtMs}` | `200 {serverId}` |
| POST | `/v1/share/{id}/ping` | Bearer | `{lat, lng, etaEpochMs, atMs}` | `204` |
| POST | `/v1/share/{id}/arrived` | Bearer | — | `204` |
| DELETE | `/v1/share/{id}` | Bearer | — | `204` |
| GET | `/j/{id}` | public | — | `200` HTML · `410 Gone` after expiry · `403` bad `?t=` |
| GET | `/.well-known/assetlinks.json` | public | — | `200` App-Links JSON |

`serverId` is the client's own id (the contract accepts it as the path id).

## Local run

```bash
cd backend/share
cp .env.example .env          # fill SHARE_AUTH_TOKEN at minimum
node server.js                # or: npm start
npm test                      # node:test suite (no deps)
```

Smoke test:

```bash
TOKEN=dev-token SHARE_AUTH_TOKEN=$TOKEN node server.js &
curl -s localhost:8080/                                   # {"status":"ok",...}
curl -s -XPOST localhost:8080/v1/share -H "authorization: Bearer $TOKEN" \
  -H content-type:application/json \
  -d '{"id":"demo1","mode":"live","destLabel":"Central","expiresAtMs":'$(( ($(date +%s)+3600)*1000 ))'}'
curl -s -XPOST localhost:8080/v1/share/demo1/ping -H "authorization: Bearer $TOKEN" \
  -H content-type:application/json -d '{"lat":12.34567,"lng":77.11111,"atMs":0}'
open http://localhost:8080/j/demo1
```

## Deploy to Railway

Prereqs: a Railway account and the CLI (`npm i -g @railway/cli`, then
`railway login`).

```bash
cd backend/share

# 1. Create (or link) a Railway project for this service.
railway init            # first time — creates the project
# railway link          # or link an existing project/service

# 2. Set the service variables (or paste them in the Railway dashboard).
railway variables --set SHARE_AUTH_TOKEN="$(node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))")"
railway variables --set ANDROID_CERT_SHA256="AA:BB:CC:...:FF"   # from Play Console > App integrity
# optional:
# railway variables --set HMAC_SECRET="$(node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))")"
# railway variables --set ALLOWED_ORIGIN="https://geo.wake"

# 3. Ship it.
railway up

# 4. Give the service a public domain, then point your App-Links domain at it.
railway domain
```

Railway injects `PORT`; `railway.json` sets the start command (`npm start`) and
uses `/` as the healthcheck. Nixpacks auto-detects Node from `package.json`
(`engines.node >= 18`).

Put the app's `SHARE_AUTH_TOKEN` into the mobile build config so
`HttpShareBackend.authToken` matches, and set the app's share domain to the
Railway (or custom App-Links) domain so `/j/{id}` and `assetlinks.json` resolve.

## Environment

See `.env.example`. Required for production: `SHARE_AUTH_TOKEN`,
`ANDROID_CERT_SHA256`. Optional: `HMAC_SECRET`, `HMAC_REQUIRE`, `ALLOWED_ORIGIN`,
`RATE_LIMIT_PER_MIN`, `ANDROID_PACKAGE`, `PORT`.

## Link tokens (`?t=`)

The app appends `?t=<HMAC-SHA256(id)>` to each `/j/{id}` link
(`ShareLinkBuilder.mintToken`). In the **client-first default**, the app mints
that token with a **per-device** secret the server does not know, so the server
treats `?t=` as opaque and relies on the unguessable UUID `id` as the capability
gate — set nothing and this Just Works.

To activate cryptographic verification: set `HMAC_SECRET` here **and** align the
app's share secret to the same value (so the app and server derive identical
tokens). With `HMAC_SECRET` set, a present-but-tampered `?t=` returns `403`; set
`HMAC_REQUIRE=true` to additionally reject links that omit `?t=`.

## Scale path (Redis)

The `Store` class is an in-memory `Map` with TTL semantics — perfect for v1 and
a single instance. To scale horizontally, swap it for Redis: `SET id <json> PX
<ttlRemaining>` gives you latest-only + native TTL hard-delete for free, and a
ping is a single `SET` (still no history). Nothing else in `server.js` changes.
```
