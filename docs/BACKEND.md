# GeoWake — Backend API Reference

> Express.js server in `geowake-server/`. Deployed on Railway.

## Setup

```bash
cd geowake-server
npm install
npm start          # production
npm run dev        # nodemon hot-reload
```

### Environment Variables

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `GOOGLE_MAPS_API_KEY` | Yes | — | Google Maps API key |
| `JWT_SECRET` | Yes | — | JWT signing secret (min 32 chars) |
| `APP_BUNDLE_ID` | No | `com.geowake.app` | App bundle ID for JWT validation |
| `PORT` | No | `3000` | Server port |
| `NODE_ENV` | No | `development` | Environment |
| `ALLOWED_ORIGINS` | No | Railway URL | CORS allowed origins (comma-separated) |
| `MAX_REQUESTS_PER_HOUR` | No | `1000` | Maps rate limit per hour |
| `MAX_REQUESTS_PER_MINUTE` | No | `100` | General rate limit per minute |

Server exits on startup if `GOOGLE_MAPS_API_KEY` or `JWT_SECRET` (min 32 chars) is missing.

---

## Middleware

| Middleware | Scope | Purpose |
|-----------|-------|---------|
| `helmet` | Global | Security headers |
| `compression` | Global | gzip responses |
| `cors` | Global | CORS (mobile apps pass via no-origin) |
| `express.json` | Global | Body parsing (10mb limit) |
| `express.urlencoded` | Global | URL-encoded parsing |
| `morgan` | Global | Request logging |
| `slowDownRules.general` | Global | Progressive delay after 50 req/min |
| `rateLimitRules.auth` | `/api/auth` | 20 req / 15 min |
| `rateLimitRules.maps` | `/api/maps` | `MAX_REQUESTS_PER_HOUR` req / hour |
| `authenticateDevice` | `/api/maps`, `/api/aggregate/ingest` | JWT verification |

Rate limiter uses `x-forwarded-for` header (first IP) or `req.ip` for keying.

---

## Endpoints

### Health

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/` | No | Server info (version, uptime) |
| GET | `/api/health` | No | Health check |

### Auth

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/auth/token` | No | Generate JWT token |

**POST `/api/auth/token`**
```json
// Request
{ "bundleId": "com.geowake.app" }

// Response 200
{ "success": true, "token": "eyJ...", "expiresIn": "24h" }

// Response 401
{ "success": false, "error": "Unauthorized: Invalid application identifier." }
```

JWT payload: `{ bundleId, iss: "GeoWake-Server" }`, expires in 24h.

### Maps (requires auth)

All maps endpoints proxy to Google Maps API with server-side API key injection and response caching.

| Method | Path | Cache TTL | Description |
|--------|------|-----------|-------------|
| POST | `/api/maps/directions` | 5 min | Google Directions API |
| POST | `/api/maps/autocomplete` | 10 min | Google Places Autocomplete |
| POST | `/api/maps/place-details` | 10 min | Google Place Details (fields: name,geometry,formatted_address) |
| POST | `/api/maps/geocode` | 15 min | Google Geocoding |
| POST | `/api/maps/nearby-search` | 15 min | Google Nearby Search |

**POST `/api/maps/directions`**
```json
// Request
{ "origin": "12.9716,77.5946", "destination": "12.9352,77.6245", "mode": "transit", "transit_mode": "rail", "departure_time": 1700000000 }

// Response (Google Directions API response, cached)
```

**POST `/api/maps/autocomplete`**
```json
{ "input": "Majestic", "sessiontoken": "uuid", "location": "12.9716,77.5946", "components": "country:in" }
```

**POST `/api/maps/place-details`**
```json
{ "place_id": "ChIJ...", "sessiontoken": "uuid" }
```

**POST `/api/maps/geocode`**
```json
{ "address": "MG Road, Bangalore" }
```

**POST `/api/maps/nearby-search`**
```json
{ "location": "12.9716,77.5946", "radius": 1000, "type": "transit_station" }
```

Cache keys are structured by type + params. Only `OK` and `ZERO_RESULTS` responses are cached; error responses (`OVER_QUERY_LIMIT`, `REQUEST_DENIED`) return non-2xx and are not cached.

### Aggregate Data

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/aggregate/ingest` | Yes | Device uploads ReleaseCandidateMatrix |
| GET | `/api/aggregate/summary` | No | Dashboard summary (KPIs) |
| GET | `/api/aggregate/flows` | No | Released O-D flow matrix |
| GET | `/api/aggregate/catchment` | No | Released catchment report |
| GET | `/api/aggregate/stats` | No | Merge engine stats (counts only) |

**POST `/api/aggregate/ingest`**
```json
// Request (auth: Bearer token)
{
  "cells": [
    { "originStationId": "BLR-MJR", "destStationId": "BLR-WTF", "count": 3, "epsilon": 0.5 },
    ...
  ]
}

// Response 200
{ "success": true, "message": "Candidate matrix ingested", "cellsReceived": 42 }
```

**GET `/api/aggregate/summary`**
```json
{
  "success": true,
  "data": {
    "totalContributions": 1500,
    "uniqueDevices": 320,
    "releasedCells": 45,
    "suppressedCells": 12,
    "hourlyDemand": [...],
    "topFlows": [...]
  }
}
```

**GET `/api/aggregate/flows`**
```json
{
  "success": true,
  "data": [
    { "origin": "BLR-MJR", "destination": "BLR-WTF", "count": 42, "noise": 0.5 },
    ...
  ]
}
```

Dashboard endpoints are public — they return only aggregate, k-anonymous, DP-noised data with no PII.

---

## Merge Engine

**`geowake-server/src/utils/mergeEngine.js`**

In-memory merge engine that:
1. Accepts `ReleaseCandidateMatrix` uploads from devices
2. Merges cells across devices (summing counts)
3. Applies k-anonymity threshold (suppresses cells with < k contributions)
4. Builds dashboard summary, flow matrix, and catchment reports
5. Tracks stats (contribution count, device count, suppressed count)

Data is in-memory only (no persistent storage). Resets on server restart.

---

## Error Handling

- **404:** `{ "success": false, "error": "Endpoint not found" }`
- **429:** Rate limit exceeded — `{ "success": false, "error": "Too many requests..." }`
- **500:** `{ "success": false, "error": "Internal server error" }` (production hides details)
- **502:** Google Maps upstream error — `{ "success": false, "error": "...", "status": "OVER_QUERY_LIMIT" }`

Development mode includes `details` and `stack` fields in error responses.

---

## Graceful Shutdown

Server handles `SIGINT` and `SIGTERM` — closes connections and exits cleanly.
