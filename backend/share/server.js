// server.js — GeoWake journey-share backend (Railway).
//
// A tiny, ZERO-DEPENDENCY Node HTTP service implementing docs/share/BACKEND_CONTRACT.md.
// It is the server half of `HttpShareBackend` (lib/services/share/live_share_backend.dart).
//
// PRIVACY INVARIANTS — enforced in code, not just documented:
//   1. LATEST-ONLY. Exactly one record per share id; a ping OVERWRITES the single
//      coarse point. There is no array, no trajectory, no history — anywhere.
//   2. TTL + HARD DELETE. Every share carries `expiresAtMs`. A sweeper hard-deletes
//      expired records; DELETE hard-deletes on demand. Nothing is archived.
//   3. NEVER INTO A DATA PIPELINE. Share coordinates are transient delivery state.
//      They are never logged, never emitted to analytics, never aggregated. The
//      "arrived" hook below is the ONLY side channel and it carries no coordinates.
//   4. COARSE ONLY. Coordinates are rounded to 5 dp on ingest AND on read.
//   5. AUTH. Every /v1 route requires the founder's bearer token.
//
// Deploy: `railway up` (see README.md). In-memory store is fine for v1; swap the
// Store class for Redis at scale (README "Scale path").

'use strict';

const http = require('http');
const crypto = require('crypto');

// ---------------------------------------------------------------------------
// Config (all from env; overridable for tests via createServer(configOverride)).
// ---------------------------------------------------------------------------

function createConfigFromEnv(env = process.env) {
  return {
    port: parseInt(env.PORT, 10) || 8080,

    // Bearer token the app sends (HttpShareBackend.authToken). REQUIRED in prod.
    authToken: env.SHARE_AUTH_TOKEN || '',

    // HMAC secret for `?t=` link verification. When empty, `?t=` is treated as
    // opaque and the unguessable share id is the sole capability gate (this keeps
    // the client-first flow working, since the app mints tokens with a per-device
    // secret). Set this — and align the app's share secret to it — to activate
    // cryptographic verification. See README "Link tokens (?t=)".
    hmacSecret: env.HMAC_SECRET || '',
    // When 'true', a `/j/{id}` request with NO `?t=` is rejected (403). Only
    // meaningful once hmacSecret is set. Default off.
    hmacRequire: String(env.HMAC_REQUIRE || '').toLowerCase() === 'true',

    // Android App Links signing cert fingerprint(s) — SHA-256, colon-separated
    // hex, comma-separated for multiple. Founder-provided.
    androidCertSha256: env.ANDROID_CERT_SHA256 || '',
    androidPackage: env.ANDROID_PACKAGE || 'com.example.geowake2',

    // CORS: locked down by default (native app + top-level web nav need no CORS).
    // Set to a specific origin (e.g. https://geo.wake) only if a browser client
    // must call /v1 cross-origin. '*' is intentionally NOT supported.
    allowedOrigin: env.ALLOWED_ORIGIN || '',

    // Hard per-IP rate limit (fixed window).
    rateLimitPerMin: parseInt(env.RATE_LIMIT_PER_MIN, 10) || 120,

    // Guard rails.
    maxBodyBytes: parseInt(env.MAX_BODY_BYTES, 10) || 8 * 1024, // 8 KB
    maxTtlMs: parseInt(env.MAX_TTL_MS, 10) || 7 * 24 * 60 * 60 * 1000, // 7 days
    maxLabelLen: 120,
    maxIdLen: 200,

    // Sweeper cadence.
    sweepIntervalMs: parseInt(env.SWEEP_INTERVAL_MS, 10) || 30 * 1000,

    // Injectable clock (tests).
    now: () => Date.now(),
  };
}

// ---------------------------------------------------------------------------
// Coarse-coordinate rounding (5 dp ≈ 1.1 m). Mirrors ShareSnapshot._round5.
// ---------------------------------------------------------------------------

function roundCoord(v) {
  return Math.round(v * 1e5) / 1e5;
}

// ---------------------------------------------------------------------------
// HMAC token (matches ShareLinkBuilder.mintToken: lowercase hex HMAC-SHA256(id)).
// ---------------------------------------------------------------------------

function mintToken(id, secret) {
  return crypto.createHmac('sha256', secret).update(id, 'utf8').digest('hex');
}

function verifyToken(id, token, secret) {
  if (!secret || typeof token !== 'string' || token.length === 0) return false;
  const expected = Buffer.from(mintToken(id, secret), 'utf8');
  const got = Buffer.from(token, 'utf8');
  if (expected.length !== got.length) return false;
  return crypto.timingSafeEqual(expected, got);
}

function constantTimeEquals(a, b) {
  const ba = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

// ---------------------------------------------------------------------------
// Store — LATEST-ONLY in-memory map with hard TTL delete.
//
// The single record per id is the ONLY state that exists for a share. A ping
// mutates lat/lng/atMs in place; there is deliberately no list to append to.
// ---------------------------------------------------------------------------

class Store {
  constructor(now = () => Date.now()) {
    this._map = new Map();
    this._now = now;
  }

  create({ id, mode, destLabel, etaEpochMs, expiresAtMs }) {
    const now = this._now();
    const rec = {
      id,
      serverId: id, // contract: the client's own id IS accepted as the path id.
      mode: mode || 'basicLink',
      destLabel: destLabel || null,
      etaEpochMs: etaEpochMs != null ? etaEpochMs : null,
      expiresAtMs,
      createdAtMs: now,
      // --- the single latest coarse point (no history) ---
      lat: null,
      lng: null,
      atMs: null,
      snapshotEtaEpochMs: null,
      // --- lifecycle ---
      arrived: false,
      arrivedAtMs: null,
    };
    this._map.set(id, rec);
    return rec;
  }

  // Get a live (non-expired) record, hard-deleting it if it has expired.
  getLive(id) {
    const rec = this._map.get(id);
    if (!rec) return null;
    if (this._now() >= rec.expiresAtMs) {
      this._map.delete(rec.id); // hard delete on lazy read
      return null;
    }
    return rec;
  }

  // LATEST-ONLY: overwrite the single point. No append.
  ping(id, { lat, lng, etaEpochMs, atMs }) {
    const rec = this.getLive(id);
    if (!rec) return null;
    rec.lat = roundCoord(lat);
    rec.lng = roundCoord(lng);
    rec.atMs = typeof atMs === 'number' ? atMs : this._now();
    rec.snapshotEtaEpochMs = etaEpochMs != null ? etaEpochMs : rec.snapshotEtaEpochMs;
    return rec;
  }

  markArrived(id) {
    const rec = this.getLive(id);
    if (!rec) return null;
    rec.arrived = true;
    rec.arrivedAtMs = this._now();
    return rec;
  }

  // HARD DELETE (revoke). Returns true if something was removed.
  delete(id) {
    return this._map.delete(id);
  }

  // Sweep: hard-delete every expired record. No archival.
  sweep() {
    const now = this._now();
    let removed = 0;
    for (const [id, rec] of this._map) {
      if (now >= rec.expiresAtMs) {
        this._map.delete(id);
        removed++;
      }
    }
    return removed;
  }

  size() {
    return this._map.size;
  }
}

// ---------------------------------------------------------------------------
// Rate limiter — hard per-IP fixed window.
// ---------------------------------------------------------------------------

class RateLimiter {
  constructor(limitPerMin, now = () => Date.now()) {
    this._limit = limitPerMin;
    this._windowMs = 60 * 1000;
    this._now = now;
    this._buckets = new Map(); // ip -> { count, resetAt }
  }

  allow(ip) {
    const now = this._now();
    let b = this._buckets.get(ip);
    if (!b || now >= b.resetAt) {
      b = { count: 0, resetAt: now + this._windowMs };
      this._buckets.set(ip, b);
    }
    b.count++;
    return b.count <= this._limit;
  }

  sweep() {
    const now = this._now();
    for (const [ip, b] of this._buckets) {
      if (now >= b.resetAt) this._buckets.delete(ip);
    }
  }
}

// ---------------------------------------------------------------------------
// HTTP helpers.
// ---------------------------------------------------------------------------

function clientIp(req) {
  const xff = req.headers['x-forwarded-for'];
  if (typeof xff === 'string' && xff.length) {
    return xff.split(',')[0].trim();
  }
  return (req.socket && req.socket.remoteAddress) || 'unknown';
}

function sendJson(res, status, obj, extraHeaders) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
    ...extraHeaders,
  });
  res.end(body);
}

function sendStatus(res, status, extraHeaders) {
  res.writeHead(status, { 'cache-control': 'no-store', ...extraHeaders });
  res.end();
}

function sendHtml(res, status, html, extraHeaders) {
  res.writeHead(status, {
    'content-type': 'text/html; charset=utf-8',
    'content-length': Buffer.byteLength(html),
    'cache-control': 'no-store',
    'referrer-policy': 'no-referrer',
    'x-content-type-options': 'nosniff',
    // Fully self-contained page: block every external resource.
    'content-security-policy':
      "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
    ...extraHeaders,
  });
  res.end(html);
}

function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    let done = false;
    const finish = (fn, arg) => {
      if (done) return;
      done = true;
      fn(arg);
    };
    req.on('data', (c) => {
      size += c.length;
      if (size > maxBytes) {
        finish(reject, Object.assign(new Error('body too large'), { code: 'TOO_LARGE' }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => finish(resolve, Buffer.concat(chunks).toString('utf8')));
    req.on('error', (e) => finish(reject, e));
  });
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// ---------------------------------------------------------------------------
// Recipient page + assetlinks.
// ---------------------------------------------------------------------------

function playStoreUrl(cfg, id) {
  const referrer = encodeURIComponent('share_' + id);
  return (
    'https://play.google.com/store/apps/details?id=' +
    encodeURIComponent(cfg.androidPackage) +
    '&referrer=' +
    referrer
  );
}

function minutesAway(rec, now) {
  const eta = rec.snapshotEtaEpochMs != null ? rec.snapshotEtaEpochMs : rec.etaEpochMs;
  if (eta == null) return null;
  const mins = Math.ceil((eta - now) / 60000);
  return mins;
}

function renderGonePage() {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Journey ended · GeoWake</title>
<style>${pageCss()}</style></head>
<body><main class="card">
<div class="badge">GeoWake</div>
<h1>This journey link has ended</h1>
<p class="muted">Live sharing links expire for privacy. Nothing is stored after a journey ends.</p>
</main></body></html>`;
}

function renderJourneyPage(cfg, rec, now) {
  const dest = rec.destLabel ? escapeHtml(rec.destLabel) : null;
  const store = playStoreUrl(cfg, rec.id);

  let statusLine;
  let detail = '';

  if (rec.arrived) {
    statusLine = dest ? `Arrived safely at ${dest}` : 'Arrived safely';
    detail = `<p class="muted">The journey is complete.</p>`;
  } else {
    statusLine = dest ? `On the way to ${dest}` : 'On the way';
    const mins = minutesAway(rec, now);
    let eta = '';
    if (mins != null) {
      eta =
        mins <= 0
          ? `<div class="eta">Arriving now</div>`
          : `<div class="eta">${mins} min away</div>`;
    }
    let point = '';
    if (rec.lat != null && rec.lng != null) {
      const lat = roundCoord(rec.lat); // coarse on read too
      const lng = roundCoord(rec.lng);
      const q = encodeURIComponent(lat + ',' + lng);
      point =
        `<div class="point">Approx. location: ${lat.toFixed(5)}, ${lng.toFixed(5)}` +
        ` <a href="https://www.google.com/maps?q=${q}" rel="noreferrer noopener">Open in Maps</a></div>`;
    } else {
      point = `<div class="point muted">Waiting for the first location update…</div>`;
    }
    detail = eta + point;
  }

  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(statusLine)} · GeoWake</title>
<style>${pageCss()}</style></head>
<body><main class="card">
<div class="badge">GeoWake</div>
<h1>${escapeHtml(statusLine)}</h1>
${detail}
<a class="cta" href="${escapeHtml(store)}" rel="noreferrer noopener">Get GeoWake</a>
<p class="fineprint">Coarse location only, shown live and never stored after arrival.</p>
</main></body></html>`;
}

function pageCss() {
  return `
:root{color-scheme:light dark}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
padding:24px;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
background:#f4f5f7;color:#12141a}
.card{width:100%;max-width:420px;background:#fff;border-radius:20px;padding:32px 24px;
box-shadow:0 10px 40px rgba(0,0,0,.08);text-align:center}
.badge{display:inline-block;font-weight:700;letter-spacing:.04em;font-size:13px;
color:#3454ff;background:#eef1ff;padding:6px 12px;border-radius:999px;margin-bottom:20px}
h1{font-size:24px;line-height:1.25;margin:0 0 8px}
.eta{font-size:40px;font-weight:800;margin:16px 0 4px;color:#3454ff}
.point{font-size:14px;margin:8px 0 4px}
.point a{color:#3454ff}
.muted{color:#6b7280}
.cta{display:block;margin:24px auto 0;background:#3454ff;color:#fff;text-decoration:none;
font-weight:700;padding:14px 20px;border-radius:14px}
.fineprint{font-size:12px;color:#9aa1ad;margin:16px 0 0}
@media (prefers-color-scheme:dark){
body{background:#0c0e12;color:#e8eaee}
.card{background:#16191f;box-shadow:0 10px 40px rgba(0,0,0,.5)}
.badge{color:#9db0ff;background:#1c2440}
.eta,.point a{color:#8aa0ff}
.cta{background:#3454ff}
.muted{color:#9aa1ad}
}`;
}

function assetlinksJson(cfg) {
  const fps = cfg.androidCertSha256
    ? cfg.androidCertSha256.split(',').map((s) => s.trim()).filter(Boolean)
    : [];
  return [
    {
      relation: ['delegate_permission/common.handle_all_urls'],
      target: {
        namespace: 'android_app',
        package_name: cfg.androidPackage,
        sha256_cert_fingerprints: fps,
      },
    },
  ];
}

// ---------------------------------------------------------------------------
// Arrived hook — the ONLY side channel. Founder wires FCM / DLT-SMS here.
// It MUST NOT receive or forward coordinates, and MUST NOT feed analytics.
// ---------------------------------------------------------------------------

function onArrived(rec) {
  // Intentionally carries NO location. Only the opaque id + a label.
  // Replace this log with an FCM/SMS dispatch. Never add coords, never call
  // an analytics/aggregation sink here — that would break the privacy contract.
  console.log(`[arrived] share=${rec.id}`);
}

// ---------------------------------------------------------------------------
// Server.
// ---------------------------------------------------------------------------

function createServer(configOverride = {}) {
  const cfg = { ...createConfigFromEnv(), ...configOverride };
  const store = new Store(cfg.now);
  const limiter = new RateLimiter(cfg.rateLimitPerMin, cfg.now);

  if (!cfg.authToken) {
    console.warn('[warn] SHARE_AUTH_TOKEN is empty — /v1 write routes are OPEN. Set it before deploy.');
  }
  if (!cfg.hmacSecret) {
    console.warn('[warn] HMAC_SECRET is empty — `?t=` link tokens are not verified (share id is the gate).');
  }

  // CORS: only ever echo a single configured origin. Never '*'.
  function applyCors(req, res) {
    if (!cfg.allowedOrigin) return;
    const origin = req.headers.origin;
    if (origin && origin === cfg.allowedOrigin) {
      res.setHeader('access-control-allow-origin', cfg.allowedOrigin);
      res.setHeader('vary', 'Origin');
      res.setHeader('access-control-allow-headers', 'authorization, content-type');
      res.setHeader('access-control-allow-methods', 'GET, POST, DELETE, OPTIONS');
      res.setHeader('access-control-max-age', '600');
    }
  }

  function authOk(req) {
    if (!cfg.authToken) return true; // dev/local: warned at startup
    const h = req.headers['authorization'] || '';
    const m = /^Bearer\s+(.+)$/i.exec(h);
    if (!m) return false;
    return constantTimeEquals(m[1], cfg.authToken);
  }

  const server = http.createServer(async (req, res) => {
    try {
      const method = req.method || 'GET';
      const url = new URL(req.url, 'http://localhost');
      const path = url.pathname;

      // Preflight.
      if (method === 'OPTIONS') {
        applyCors(req, res);
        return sendStatus(res, 204);
      }

      // Hard per-IP rate limit on everything.
      if (!limiter.allow(clientIp(req))) {
        return sendJson(res, 429, { error: 'rate_limited' }, { 'retry-after': '60' });
      }

      applyCors(req, res);

      // --- Health ---
      if (method === 'GET' && path === '/') {
        return sendJson(res, 200, {
          service: 'geowake-share',
          status: 'ok',
          active: store.size(),
          time: cfg.now(),
        });
      }

      // --- Android App Links verification ---
      if (method === 'GET' && path === '/.well-known/assetlinks.json') {
        return sendJson(res, 200, assetlinksJson(cfg));
      }

      // --- Recipient page ---
      if (path.startsWith('/j/')) {
        if (method !== 'GET') return sendStatus(res, 405, { allow: 'GET' });
        const id = decodeURIComponent(path.slice('/j/'.length));
        if (!id) return sendHtml(res, 410, renderGonePage());

        // `?t=` HMAC verification (only when a server secret is configured).
        if (cfg.hmacSecret) {
          const t = url.searchParams.get('t');
          if (t) {
            if (!verifyToken(id, t, cfg.hmacSecret)) {
              return sendStatus(res, 403);
            }
          } else if (cfg.hmacRequire) {
            return sendStatus(res, 403);
          }
        }

        const rec = store.getLive(id);
        if (!rec) return sendHtml(res, 410, renderGonePage()); // missing or expired
        return sendHtml(res, 200, renderJourneyPage(cfg, rec, cfg.now()));
      }

      // --- /v1 API (bearer-auth) ---
      if (path === '/v1/share' || path.startsWith('/v1/share/')) {
        if (!authOk(req)) {
          return sendJson(res, 401, { error: 'unauthorized' }, {
            'www-authenticate': 'Bearer',
          });
        }

        // POST /v1/share  -> {serverId}
        if (path === '/v1/share') {
          if (method !== 'POST') return sendStatus(res, 405, { allow: 'POST' });
          let body;
          try {
            body = await parseJsonBody(req, cfg.maxBodyBytes);
          } catch (e) {
            if (e && e.code === 'TOO_LARGE') return sendStatus(res, 413);
            return sendJson(res, 400, { error: 'bad_json' });
          }
          const v = validateCreate(body, cfg);
          if (v.error) return sendJson(res, 400, { error: v.error });
          const rec = store.create(v.value);
          return sendJson(res, 200, { serverId: rec.serverId });
        }

        // /v1/share/{id}[/action]
        const rest = path.slice('/v1/share/'.length);
        const segs = rest.split('/').filter((s) => s.length);
        const id = segs.length ? decodeURIComponent(segs[0]) : '';
        const action = segs[1] || '';

        if (!id) return sendJson(res, 404, { error: 'not_found' });

        // POST /v1/share/{id}/ping -> 204
        if (action === 'ping') {
          if (method !== 'POST') return sendStatus(res, 405, { allow: 'POST' });
          let body;
          try {
            body = await parseJsonBody(req, cfg.maxBodyBytes);
          } catch (e) {
            if (e && e.code === 'TOO_LARGE') return sendStatus(res, 413);
            return sendJson(res, 400, { error: 'bad_json' });
          }
          const v = validatePing(body);
          if (v.error) return sendJson(res, 400, { error: v.error });
          const rec = store.ping(id, v.value);
          if (!rec) return sendStatus(res, 404); // unknown or expired -> hard gone
          return sendStatus(res, 204);
        }

        // POST /v1/share/{id}/arrived -> 204
        if (action === 'arrived') {
          if (method !== 'POST') return sendStatus(res, 405, { allow: 'POST' });
          const rec = store.markArrived(id);
          if (!rec) return sendStatus(res, 404);
          try {
            onArrived(rec);
          } catch (_) {
            /* the notification hook must never break the ack */
          }
          return sendStatus(res, 204);
        }

        // GET /v1/share/{id}/status -> 200 latest coarse snapshot (follower read).
        // The one read endpoint HttpShareBackend.getStatus depends on. Latest-only:
        // there is no history; an expired/unknown share is 410 Gone (the client
        // retires the row). Coordinates are re-rounded coarse on read.
        if (action === 'status') {
          if (method !== 'GET') return sendStatus(res, 405, { allow: 'GET' });
          const rec = store.getLive(id); // null if unknown or expired
          if (!rec) return sendJson(res, 410, { id, status: 'expired', gone: true });
          return sendJson(res, 200, {
            id: rec.serverId,
            status: rec.arrived ? 'arrived' : 'enRoute',
            destLabel: rec.destLabel,
            etaEpochMs: rec.snapshotEtaEpochMs != null
              ? rec.snapshotEtaEpochMs
              : rec.etaEpochMs,
            lat: rec.lat != null ? roundCoord(rec.lat) : null,
            lng: rec.lng != null ? roundCoord(rec.lng) : null,
            atMs: rec.atMs != null ? rec.atMs : null,
            gone: false,
          });
        }

        // DELETE /v1/share/{id} -> 204 (hard delete / revoke)
        if (action === '') {
          if (method !== 'DELETE') return sendStatus(res, 405, { allow: 'DELETE' });
          store.delete(id); // idempotent: 204 whether or not it existed
          return sendStatus(res, 204);
        }

        return sendJson(res, 404, { error: 'not_found' });
      }

      return sendJson(res, 404, { error: 'not_found' });
    } catch (e) {
      // Never leak internals; never log coordinates.
      console.error('[error]', e && e.message);
      if (!res.headersSent) sendJson(res, 500, { error: 'internal' });
    }
  });

  // Sweepers — hard-delete expired shares + prune rate buckets. No archival.
  const sweepTimer = setInterval(() => {
    try {
      store.sweep();
      limiter.sweep();
    } catch (_) {
      /* best effort */
    }
  }, cfg.sweepIntervalMs);
  if (sweepTimer.unref) sweepTimer.unref();

  // Expose internals for tests + a clean shutdown.
  server.__geowake = { cfg, store, limiter, sweepTimer };
  const origClose = server.close.bind(server);
  server.close = (cb) => {
    clearInterval(sweepTimer);
    return origClose(cb);
  };

  return server;
}

// ---------------------------------------------------------------------------
// Validation.
// ---------------------------------------------------------------------------

async function parseJsonBody(req, maxBytes) {
  const raw = await readBody(req, maxBytes);
  if (!raw || !raw.trim()) return {};
  return JSON.parse(raw);
}

function validateCreate(body, cfg) {
  if (typeof body !== 'object' || body === null) return { error: 'bad_body' };
  const id = body.id;
  if (typeof id !== 'string' || id.length === 0 || id.length > cfg.maxIdLen) {
    return { error: 'bad_id' };
  }
  // URL-safe-ish: no slashes / whitespace / control chars in a path segment.
  if (/[\/\s\x00-\x1f]/.test(id)) return { error: 'bad_id' };

  const now = cfg.now();
  let expiresAtMs = body.expiresAtMs;
  if (typeof expiresAtMs !== 'number' || !isFinite(expiresAtMs)) {
    return { error: 'bad_expiresAtMs' };
  }
  expiresAtMs = Math.floor(expiresAtMs);
  if (expiresAtMs <= now) return { error: 'already_expired' };
  // Clamp absurd TTLs — a share can never outlive the max window.
  if (expiresAtMs > now + cfg.maxTtlMs) expiresAtMs = now + cfg.maxTtlMs;

  let mode = body.mode;
  if (typeof mode !== 'string' || !['basicLink', 'live', 'guardian'].includes(mode)) {
    mode = 'basicLink';
  }

  let destLabel = null;
  if (typeof body.destLabel === 'string') {
    destLabel = body.destLabel.trim().slice(0, cfg.maxLabelLen);
    if (!destLabel) destLabel = null;
  }

  let etaEpochMs = null;
  if (typeof body.etaEpochMs === 'number' && isFinite(body.etaEpochMs)) {
    etaEpochMs = Math.floor(body.etaEpochMs);
  }

  return { value: { id, mode, destLabel, etaEpochMs, expiresAtMs } };
}

function validatePing(body) {
  if (typeof body !== 'object' || body === null) return { error: 'bad_body' };
  const { lat, lng } = body;
  if (typeof lat !== 'number' || !isFinite(lat) || lat < -90 || lat > 90) {
    return { error: 'bad_lat' };
  }
  if (typeof lng !== 'number' || !isFinite(lng) || lng < -180 || lng > 180) {
    return { error: 'bad_lng' };
  }
  let atMs = null;
  if (typeof body.atMs === 'number' && isFinite(body.atMs)) atMs = Math.floor(body.atMs);
  let etaEpochMs = null;
  if (typeof body.etaEpochMs === 'number' && isFinite(body.etaEpochMs)) {
    etaEpochMs = Math.floor(body.etaEpochMs);
  }
  return { value: { lat, lng, atMs, etaEpochMs } };
}

// ---------------------------------------------------------------------------
// Exports + entrypoint.
// ---------------------------------------------------------------------------

module.exports = {
  createServer,
  createConfigFromEnv,
  Store,
  RateLimiter,
  roundCoord,
  mintToken,
  verifyToken,
  assetlinksJson,
};

if (require.main === module) {
  const server = createServer();
  const port = server.__geowake.cfg.port;
  server.listen(port, () => {
    console.log(`geowake-share listening on :${port}`);
  });
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => server.close(() => process.exit(0)));
  }
}
