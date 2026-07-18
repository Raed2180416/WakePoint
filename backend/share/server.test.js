// server.test.js — node:test suite for the GeoWake share backend.
// Run with:  npm test   (node --test)
//
// Covers the privacy-critical invariants from docs/share/BACKEND_CONTRACT.md:
//   create -> ping -> latest-only, TTL 410, revoke hard-delete, auth rejects,
//   coord rounding, plus assetlinks + HMAC `?t=` verification.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { createServer, mintToken } = require('./server');

const AUTH = 'test-bearer-token';
const HMAC = 'test-hmac-secret';

// A test harness: a server with an injectable clock, started on an ephemeral port.
async function withServer(run, extra = {}) {
  let clock = 1_000_000_000_000; // fixed wall-clock start
  const server = createServer({
    authToken: AUTH,
    hmacSecret: '', // default: `?t=` opaque unless a test overrides
    rateLimitPerMin: 100000, // don't let the limiter interfere
    sweepIntervalMs: 1_000_000, // effectively disable the background sweeper
    now: () => clock,
    ...extra,
  });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const ctx = {
    base,
    server,
    store: server.__geowake.store,
    advance: (ms) => {
      clock += ms;
    },
    setClock: (t) => {
      clock = t;
    },
    now: () => clock,
  };
  try {
    await run(ctx);
  } finally {
    await new Promise((r) => server.close(r));
  }
}

function authHeaders(extra = {}) {
  return { authorization: `Bearer ${AUTH}`, 'content-type': 'application/json', ...extra };
}

async function createShare(base, overrides = {}) {
  const body = {
    id: 'share-abc-123',
    mode: 'live',
    destLabel: 'Central Station',
    etaEpochMs: null,
    expiresAtMs: 1_000_000_000_000 + 60 * 60 * 1000, // +1h from the fixed clock
    ...overrides,
  };
  const res = await fetch(`${base}/v1/share`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(body),
  });
  return res;
}

// ---------------------------------------------------------------------------

test('health endpoint is open and reports ok', async () => {
  await withServer(async ({ base }) => {
    const res = await fetch(`${base}/`);
    assert.equal(res.status, 200);
    const j = await res.json();
    assert.equal(j.status, 'ok');
    assert.equal(j.service, 'geowake-share');
  });
});

test('create -> ping -> ping keeps ONLY the latest coarse point (no history)', async () => {
  await withServer(async ({ base, store }) => {
    const c = await createShare(base);
    assert.equal(c.status, 200);
    const { serverId } = await c.json();
    assert.equal(serverId, 'share-abc-123'); // client id accepted as path id

    // first ping
    let p = await fetch(`${base}/v1/share/${serverId}/ping`, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({ lat: 12.34567, lng: 77.11111, atMs: 1_000_000_000_001 }),
    });
    assert.equal(p.status, 204);

    // second ping overwrites
    p = await fetch(`${base}/v1/share/${serverId}/ping`, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({ lat: 12.99999, lng: 77.88888, atMs: 1_000_000_000_002 }),
    });
    assert.equal(p.status, 204);

    // The stored record holds a SINGLE point equal to the latest ping — and no
    // array/history field of any kind exists on it.
    const rec = store.getLive(serverId);
    assert.equal(rec.lat, 12.99999);
    assert.equal(rec.lng, 77.88888);
    for (const [k, v] of Object.entries(rec)) {
      assert.ok(!Array.isArray(v), `record field "${k}" must not be an array (no trajectory)`);
    }

    // The recipient page shows the latest point.
    const page = await fetch(`${base}/j/${serverId}`);
    assert.equal(page.status, 200);
    const html = await page.text();
    assert.ok(html.includes('12.99999'), 'page shows latest lat');
    assert.ok(html.includes('77.88888'), 'page shows latest lng');
    assert.ok(!html.includes('12.34567'), 'page must not show the superseded point');
    assert.ok(html.includes('Central Station'));
  });
});

test('coordinates are rounded to 5 dp on ingest and on read', async () => {
  await withServer(async ({ base, store }) => {
    const { serverId } = await (await createShare(base)).json();
    const p = await fetch(`${base}/v1/share/${serverId}/ping`, {
      method: 'POST',
      headers: authHeaders(),
      // deliberately high precision
      body: JSON.stringify({ lat: 12.3456789, lng: 77.9876543, atMs: 1_000_000_000_003 }),
    });
    assert.equal(p.status, 204);
    const rec = store.getLive(serverId);
    assert.equal(rec.lat, 12.34568); // rounded to 5 dp
    assert.equal(rec.lng, 77.98765);

    const html = await (await fetch(`${base}/j/${serverId}`)).text();
    assert.ok(html.includes('12.34568'));
    assert.ok(html.includes('77.98765'));
    assert.ok(!html.includes('12.3456789'));
  });
});

test('TTL: expired shares are hard-deleted and /j returns 410 Gone', async () => {
  await withServer(async ({ base, store, advance }) => {
    const { serverId } = await (
      await createShare(base, { expiresAtMs: 1_000_000_000_000 + 5_000 })
    ).json();

    // before expiry: live
    assert.equal((await fetch(`${base}/j/${serverId}`)).status, 200);

    // advance past expiry
    advance(6_000);

    const page = await fetch(`${base}/j/${serverId}`);
    assert.equal(page.status, 410);
    assert.ok((await page.text()).includes('ended'));

    // lazy read hard-deleted it — nothing archived
    assert.equal(store.size(), 0);

    // pings after expiry are gone too
    const p = await fetch(`${base}/v1/share/${serverId}/ping`, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({ lat: 1, lng: 2, atMs: 1_000_000_006_001 }),
    });
    assert.equal(p.status, 404);
  });
});

test('revoke (DELETE) hard-deletes state; page then 410; delete is idempotent', async () => {
  await withServer(async ({ base, store }) => {
    const { serverId } = await (await createShare(base)).json();
    assert.equal(store.size(), 1);

    const del = await fetch(`${base}/v1/share/${serverId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    assert.equal(del.status, 204);
    assert.equal(store.size(), 0);

    assert.equal((await fetch(`${base}/j/${serverId}`)).status, 410);

    // idempotent: deleting again still 204
    const del2 = await fetch(`${base}/v1/share/${serverId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    assert.equal(del2.status, 204);
  });
});

test('arrived marks the share and acks 204; page shows arrived state', async () => {
  await withServer(async ({ base }) => {
    const { serverId } = await (await createShare(base)).json();
    const a = await fetch(`${base}/v1/share/${serverId}/arrived`, {
      method: 'POST',
      headers: authHeaders(),
    });
    assert.equal(a.status, 204);
    const html = await (await fetch(`${base}/j/${serverId}`)).text();
    assert.ok(/Arrived safely/.test(html));
  });
});

test('auth: /v1 rejects missing or wrong bearer token with 401', async () => {
  await withServer(async ({ base }) => {
    // no header
    let res = await fetch(`${base}/v1/share`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ id: 'x', expiresAtMs: 1_000_000_000_000 + 1000 }),
    });
    assert.equal(res.status, 401);

    // wrong token
    res = await fetch(`${base}/v1/share`, {
      method: 'POST',
      headers: { authorization: 'Bearer nope', 'content-type': 'application/json' },
      body: JSON.stringify({ id: 'x', expiresAtMs: 1_000_000_000_000 + 1000 }),
    });
    assert.equal(res.status, 401);

    // ping without auth
    res = await fetch(`${base}/v1/share/whatever/ping`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ lat: 1, lng: 2 }),
    });
    assert.equal(res.status, 401);
  });
});

test('create validation: bad id and already-expired TTL are rejected', async () => {
  await withServer(async ({ base }) => {
    // id with a slash (would break path routing)
    let res = await createShare(base, { id: 'bad/id' });
    assert.equal(res.status, 400);

    // expiry in the past
    res = await createShare(base, { id: 'ok-id', expiresAtMs: 1_000_000_000_000 - 1 });
    assert.equal(res.status, 400);
  });
});

test('ping validation: out-of-range coordinates are rejected', async () => {
  await withServer(async ({ base }) => {
    const { serverId } = await (await createShare(base)).json();
    const res = await fetch(`${base}/v1/share/${serverId}/ping`, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({ lat: 999, lng: 0 }),
    });
    assert.equal(res.status, 400);
  });
});

test('assetlinks.json exposes the configured package + fingerprint', async () => {
  await withServer(
    async ({ base }) => {
      const res = await fetch(`${base}/.well-known/assetlinks.json`);
      assert.equal(res.status, 200);
      const j = await res.json();
      assert.equal(j[0].target.package_name, 'com.example.geowake2');
      assert.deepEqual(j[0].target.sha256_cert_fingerprints, ['AA:BB:CC']);
      assert.deepEqual(j[0].relation, ['delegate_permission/common.handle_all_urls']);
    },
    { androidCertSha256: 'AA:BB:CC' }
  );
});

test('HMAC `?t=`: valid token passes, tampered token 403 (when secret set)', async () => {
  await withServer(
    async ({ base }) => {
      const { serverId } = await (await createShare(base)).json();
      const good = mintToken(serverId, HMAC);

      // valid token
      let res = await fetch(`${base}/j/${serverId}?t=${good}`);
      assert.equal(res.status, 200);

      // tampered token
      res = await fetch(`${base}/j/${serverId}?t=${good.slice(0, -1)}0`);
      assert.equal(res.status, 403);
    },
    { hmacSecret: HMAC }
  );
});

test('HMAC require: missing `?t=` is 403 only when HMAC_REQUIRE is on', async () => {
  await withServer(
    async ({ base }) => {
      const { serverId } = await (await createShare(base)).json();
      const res = await fetch(`${base}/j/${serverId}`); // no ?t=
      assert.equal(res.status, 403);
    },
    { hmacSecret: HMAC, hmacRequire: true }
  );
});

test('latest-only body: a payload carrying a history array is not persisted as history', async () => {
  await withServer(async ({ base, store }) => {
    const { serverId } = await (await createShare(base)).json();
    // Even if a malicious client tries to sneak an array in, the server reads
    // only lat/lng/atMs/etaEpochMs — nothing array-shaped is stored.
    await fetch(`${base}/v1/share/${serverId}/ping`, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({
        lat: 1.23456,
        lng: 2.34567,
        atMs: 1_000_000_000_005,
        history: [{ lat: 9, lng: 9 }, { lat: 8, lng: 8 }],
        trajectory: [1, 2, 3],
      }),
    });
    const rec = store.getLive(serverId);
    assert.ok(!('history' in rec));
    assert.ok(!('trajectory' in rec));
    for (const v of Object.values(rec)) assert.ok(!Array.isArray(v));
  });
});
