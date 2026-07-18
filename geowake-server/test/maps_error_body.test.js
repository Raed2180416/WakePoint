/**
 * Maps proxy — Google in-body error-status handling (BACKLOG #24)
 *
 * Google's Maps web-service APIs return HTTP 200 even when the request failed,
 * signalling the real outcome via an in-body `status` field
 * (OVER_QUERY_LIMIT / REQUEST_DENIED / INVALID_REQUEST / ...). axios does not
 * throw on those, so a naive proxy caches the error body and serves it to every
 * caller for the whole TTL — riders then get no route and cannot arm the alarm.
 *
 * These tests mock axios (no network) and drive the real controller + real
 * cache singleton to prove:
 *   - a 200 OVER_QUERY_LIMIT body is NOT cached and yields HTTP 429
 *   - a 200 REQUEST_DENIED body is NOT cached and yields HTTP 502
 *   - a 200 OK body IS cached and yields HTTP 200
 */

// Config validates env at require-time (process.exit(1) if missing), so these
// must be set before any src/* module is required.
process.env.GOOGLE_MAPS_API_KEY = process.env.GOOGLE_MAPS_API_KEY || 'test-maps-key';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test-jwt-secret-at-least-32-characters-long';
process.env.APP_BUNDLE_ID = process.env.APP_BUNDLE_ID || 'com.yourcompany.geowake2';

jest.mock('axios');
const axios = require('axios');

const cache = require('../src/utils/cache');
const { getDirections } = require('../src/controllers/mapsController');

// Minimal req/res doubles. `res.json`/`res.status().json()` both terminate the
// request; we resolve a promise on the first terminal call so tests can await
// the fire-and-forget async proxy the handler kicks off.
function makeReqRes(body) {
  const res = {
    statusCode: 200,
    body: undefined,
    _resolve: null,
    done: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(payload) {
      this.body = payload;
      if (this._resolve) this._resolve();
      return this;
    },
  };
  res.done = new Promise((resolve) => {
    res._resolve = resolve;
  });
  return { req: { body }, res };
}

async function callDirections(body) {
  const { req, res } = makeReqRes(body);
  getDirections(req, res); // handler does not return the inner async promise
  await res.done;
  return res;
}

describe('Maps proxy — Google in-body error statuses (BACKLOG #24)', () => {
  beforeEach(() => {
    cache.flush();
    axios.get.mockReset();
  });

  test('200 OVER_QUERY_LIMIT is NOT cached and returns 429', async () => {
    axios.get.mockResolvedValue({ status: 200, data: { status: 'OVER_QUERY_LIMIT' } });

    const params = { origin: 'A', destination: 'B', mode: 'driving' };
    const res = await callDirections(params);

    expect(res.statusCode).toBe(429);
    expect(res.body.success).toBe(false);
    expect(res.body.status).toBe('OVER_QUERY_LIMIT');
    // Error body must not have been cached.
    expect(cache.get('directions', params)).toBeUndefined();
  });

  test('200 REQUEST_DENIED is NOT cached and returns 502', async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: { status: 'REQUEST_DENIED', error_message: 'API key invalid' },
    });

    const params = { origin: 'C', destination: 'D', mode: 'driving' };
    const res = await callDirections(params);

    expect(res.statusCode).toBe(502);
    expect(res.body.success).toBe(false);
    expect(res.body.status).toBe('REQUEST_DENIED');
    expect(cache.get('directions', params)).toBeUndefined();
  });

  test('200 OK IS cached and returns 200', async () => {
    const okBody = { status: 'OK', routes: [{ summary: 'Main St' }] };
    axios.get.mockResolvedValue({ status: 200, data: okBody });

    const params = { origin: 'E', destination: 'F', mode: 'driving' };
    const res = await callDirections(params);

    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual(okBody);
    // Genuine result must be cached for reuse.
    expect(cache.get('directions', params)).toEqual(okBody);
  });

  test('second identical OK request is served from cache without a new upstream call', async () => {
    const okBody = { status: 'OK', routes: [{ summary: 'Second St' }] };
    axios.get.mockResolvedValue({ status: 200, data: okBody });

    const params = { origin: 'G', destination: 'H', mode: 'driving' };
    await callDirections(params);
    await callDirections(params);

    // First call hit upstream; second was a cache hit.
    expect(axios.get).toHaveBeenCalledTimes(1);
  });
});
