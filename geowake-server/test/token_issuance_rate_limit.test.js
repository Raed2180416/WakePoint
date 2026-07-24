/**
 * Token-issuance rate limit shape (server-cost-security audit finding):
 * bundleId is public, so the number of tokens an IP can mint per hour is the
 * real lever bounding how many independent per-token quota buckets (see
 * middleware/mapsGuard.js) an attacker can spin up. middleware/security.js
 * tightens POST /api/auth/token to config.authTokenRateLimitPerHour
 * (env AUTH_TOKEN_RATE_LIMIT_PER_HOUR, default 10/hour) and only counts
 * successful mints (skipFailedRequests) — a rejected 401 attempt grants no
 * capability, so it shouldn't burn down the budget.
 *
 * The limit is set very low here (env, read once at config.js require time)
 * so the test can exhaust it without dozens of requests.
 */

process.env.GOOGLE_MAPS_API_KEY = process.env.GOOGLE_MAPS_API_KEY || 'test-maps-key';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test-jwt-secret-at-least-32-characters-long';
process.env.APP_BUNDLE_ID = process.env.APP_BUNDLE_ID || 'com.yourcompany.geowake2';
process.env.AUTH_TOKEN_RATE_LIMIT_PER_HOUR = '3';

const request = require('supertest');
const app = require('../src/server');

describe('Token issuance rate limit (tightened per server-cost-security)', () => {
  test('failed mint attempts (invalid bundleId) do not count against the limit', async () => {
    for (let i = 0; i < 5; i++) {
      const res = await request(app)
        .post('/api/auth/token')
        .send({ bundleId: 'not-the-real-bundle-id' });
      expect(res.status).toBe(401);
    }

    // Budget (3/hour) is still fully available since only failures happened.
    const res = await request(app)
      .post('/api/auth/token')
      .send({ bundleId: 'com.yourcompany.geowake2' });
    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
  });

  test('successful mints beyond the hourly cap return 429 with a clear error body', async () => {
    // First mint already consumed 1 unit in the previous test (same
    // module/process-wide limiter store); use up to the remaining budget.
    let sawLimitHit = false;
    let lastRes;
    for (let i = 0; i < 5; i++) {
      lastRes = await request(app)
        .post('/api/auth/token')
        .send({ bundleId: 'com.yourcompany.geowake2' });
      if (lastRes.status === 429) {
        sawLimitHit = true;
        break;
      }
      expect(lastRes.status).toBe(200);
    }

    expect(sawLimitHit).toBe(true);
    expect(lastRes.body.success).toBe(false);
    expect(lastRes.body.error).toMatch(/too many requests/i);
  });
});
