/**
 * Wallet-protection tests (server-cost-security audit finding): global
 * per-API-family daily budgets and per-device (JWT jti) daily caps.
 *
 * bundleId is not a secret (it's the public Play Store package id), so
 * anyone can POST /api/auth/token and start calling the billed Google Maps
 * proxy endpoints. middleware/mapsGuard.js bounds the resulting exposure
 * with two independent layers:
 *   - familyQuotaGuard: a global daily request budget per Google API family
 *   - perTokenQuotaGuard: a daily cap per issued token (jti), so minting a
 *     fresh token doesn't reset an attacker's usage allowance
 *
 * Quota env vars are set very low here (read once at config.js require
 * time) so both limits can be exhausted without hundreds of requests.
 * axios is mocked — no real, billed Google Maps calls happen.
 */

process.env.GOOGLE_MAPS_API_KEY = process.env.GOOGLE_MAPS_API_KEY || 'test-maps-key';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test-jwt-secret-at-least-32-characters-long';
process.env.APP_BUNDLE_ID = process.env.APP_BUNDLE_ID || 'com.yourcompany.geowake2';
// Family budget kept above the per-token budget so the per-token tests below
// can isolate the per-token cap without tripping the family budget first.
// Kept small (rather than realistic thousands) so this file's request count
// stays well under middleware/security.js's slowDownRules.general
// delayAfter threshold — otherwise the artificial per-request delay it adds
// beyond that threshold would make these tests time out.
process.env.DAILY_QUOTA_DIRECTIONS = '5';
process.env.DAILY_QUOTA_PLACES = '5';
process.env.DAILY_QUOTA_GEOCODING = '5';
process.env.DAILY_QUOTA_NEARBY = '5';
process.env.DAILY_QUOTA_PER_TOKEN = '2';
process.env.MAPS_PROXY_DISABLED = 'false';
// This file mints several tokens to isolate the family-quota guard from the
// per-token guard (a fresh jti per request keeps each token's own usage
// low). Raise the token-issuance rate limit above that so it doesn't
// interfere — the issuance limit itself is covered separately in
// token_issuance_rate_limit.test.js.
process.env.AUTH_TOKEN_RATE_LIMIT_PER_HOUR = '100';

jest.mock('axios');
const axios = require('axios');
const request = require('supertest');
const app = require('../src/server');
const quotaTracker = require('../src/utils/quotaTracker');

async function mintToken() {
  const res = await request(app)
    .post('/api/auth/token')
    .send({ bundleId: 'com.yourcompany.geowake2' });
  return res.body.token;
}

describe('Wallet protection — daily quotas', () => {
  beforeEach(() => {
    axios.get.mockReset();
    axios.get.mockResolvedValue({ status: 200, data: { status: 'OK' } });
    // Fresh counters per test so tests don't bleed into each other.
    quotaTracker.resetAll();
  });

  test('per-token (jti) daily cap returns 429 once exceeded, with a clear error body', async () => {
    const token = await mintToken();

    // DAILY_QUOTA_PER_TOKEN=2: first 2 requests on this token succeed.
    for (let i = 0; i < 2; i++) {
      const res = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${token}`)
        .send({ origin: `o${i}`, destination: `d${i}`, mode: 'driving' });
      expect(res.status).not.toBe(429);
    }

    // 3rd request on the SAME token is over its per-token budget.
    const res = await request(app)
      .post('/api/maps/directions')
      .set('Authorization', `Bearer ${token}`)
      .send({ origin: 'over', destination: 'budget', mode: 'driving' });

    expect(res.status).toBe(429);
    expect(res.body).toMatchObject({ success: false, limit: 2 });
    expect(res.body.error).toMatch(/device token/i);
  });

  test('a fresh token has its own independent per-token budget', async () => {
    const tokenA = await mintToken();
    const tokenB = await mintToken();

    // Exhaust tokenA's budget (2/day).
    for (let i = 0; i < 2; i++) {
      await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${tokenA}`)
        .send({ origin: `a${i}`, destination: `b${i}`, mode: 'driving' });
    }
    const exhausted = await request(app)
      .post('/api/maps/directions')
      .set('Authorization', `Bearer ${tokenA}`)
      .send({ origin: 'a-over', destination: 'b-over', mode: 'driving' });
    expect(exhausted.status).toBe(429);

    // tokenB is unaffected — different jti, own bucket.
    const stillOk = await request(app)
      .post('/api/maps/directions')
      .set('Authorization', `Bearer ${tokenB}`)
      .send({ origin: 'c', destination: 'd', mode: 'driving' });
    expect(stillOk.status).not.toBe(429);
  });

  test('per-family daily quota returns 429 once exceeded, independent of which token is used', async () => {
    // Use a fresh token per call so the per-token cap (2/day) never trips —
    // this isolates the family-level budget (5/day here).
    for (let i = 0; i < 5; i++) {
      const token = await mintToken();
      const res = await request(app)
        .post('/api/maps/geocode')
        .set('Authorization', `Bearer ${token}`)
        .send({ address: `address-${i}` });
      expect(res.status).not.toBe(429);
    }

    const token = await mintToken();
    const res = await request(app)
      .post('/api/maps/geocode')
      .set('Authorization', `Bearer ${token}`)
      .send({ address: 'one-too-many' });

    expect(res.status).toBe(429);
    expect(res.body).toMatchObject({ success: false, family: 'geocoding', limit: 5 });
    expect(res.body.error).toMatch(/budget/i);
  });

  test('quota families are independent — exhausting directions does not block geocoding', async () => {
    // Blow through the (low, test-only) directions family budget using
    // distinct tokens so the per-token cap doesn't interfere.
    for (let i = 0; i < 5; i++) {
      const token = await mintToken();
      await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${token}`)
        .send({ origin: `x${i}`, destination: `y${i}`, mode: 'driving' });
    }
    const token = await mintToken();
    const blocked = await request(app)
      .post('/api/maps/directions')
      .set('Authorization', `Bearer ${token}`)
      .send({ origin: 'blocked', destination: 'blocked', mode: 'driving' });
    expect(blocked.status).toBe(429);

    // A different family (geocoding) on a fresh token is unaffected.
    const freshToken = await mintToken();
    const geoRes = await request(app)
      .post('/api/maps/geocode')
      .set('Authorization', `Bearer ${freshToken}`)
      .send({ address: 'still works' });
    expect(geoRes.status).not.toBe(429);
  });
});
