# GeoWake Journey-Share — Backend Contract (Railway)

Client-first. The app ships with `NoopShareBackend` (offline; `supportsLive == false`)
so **basic share works with zero backend**. Live tracking + the Guardian "arrived
safely" push require the founder's Railway server implementing the contract below.
The client already speaks it via `HttpShareBackend` (`lib/services/share/live_share_backend.dart`).

## Invariants the server MUST honour

- **Latest-only.** Store only the most recent `ShareSnapshot` per share id. Never
  persist a trajectory/history. The client never sends one.
- **TTL + hard delete.** Every share has `expiresAtMs`; after it (or on `revoke`)
  the server hard-deletes all state. No archival.
- **Never into the data pipeline.** Share coordinates are transient delivery state,
  not analytics. They must never be routed to any aggregation / data product.
- **Coarse only.** Coordinates arrive rounded to 5 dp; do not attempt to refine.
- **Auth.** Bearer token provisioned by the founder (`HttpShareBackend.authToken`).

## Endpoints

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/v1/share` | `{id, mode, destLabel, etaEpochMs, expiresAtMs}` | `{serverId}` |
| POST | `/v1/share/{id}/ping` | `{lat, lng, etaEpochMs, atMs}` | `204` |
| POST | `/v1/share/{id}/arrived` | — | `204` |
| DELETE | `/v1/share/{id}` | — | `204` |

- `createShare` → `{serverId}` is stored by the client as `ShareSession.backendId`
  and used for subsequent calls; if the client's own id is used, the server MUST
  accept it as the path id.
- `arrived` is the trigger the server turns into the recipient notification
  (FCM for app users, optional DLT-registered SMS / WhatsApp for others).

## Recipient surface (founder)

- App-Links domain with `/.well-known/assetlinks.json` (verifies `com.example.geowake2`).
- A lightweight page at `/j/{id}` showing the latest coarse point + ETA, honouring
  `?t=` HMAC verification and TTL/revproke (410 Gone after expiry).
- Play Store install referrer (`?referrer=share_<id>`) for attribution.

All of the above are **optional for the client-first ship** — the Noop backend
covers basic share end-to-end.
