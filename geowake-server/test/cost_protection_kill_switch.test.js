/**
 * Kill-switch test (server-cost-security audit finding): MAPS_PROXY_DISABLED
 * must make every /api/maps/* route return 503 immediately, with no Google
 * call attempted, so a runaway bill can be stopped via a Railway env var
 * change alone — no deploy required.
 *
 * MAPS_PROXY_DISABLED is read once at config.js require time, so it must be
 * set before requiring the app; this lives in its own file so it doesn't
 * disable maps routes for any other test suite.
 */

process.env.GOOGLE_MAPS_API_KEY = process.env.GOOGLE_MAPS_API_KEY || 'test-maps-key';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test-jwt-secret-at-least-32-characters-long';
process.env.APP_BUNDLE_ID = process.env.APP_BUNDLE_ID || 'com.yourcompany.geowake2';
process.env.MAPS_PROXY_DISABLED = 'true';

jest.mock('axios');
const axios = require('axios');
const request = require('supertest');
const app = require('../src/server');

describe('Kill switch — MAPS_PROXY_DISABLED=true', () => {
  let validToken;

  beforeAll(async () => {
    const res = await request(app)
      .post('/api/auth/token')
      .send({ bundleId: 'com.yourcompany.geowake2' });
    validToken = res.body.token;
  });

  beforeEach(() => {
    axios.get.mockReset();
    axios.get.mockResolvedValue({ status: 200, data: { status: 'OK' } });
  });

  test('POST /api/maps/directions returns 503 without calling Google', async () => {
    const res = await request(app)
      .post('/api/maps/directions')
      .set('Authorization', `Bearer ${validToken}`)
      .send({ origin: 'A', destination: 'B', mode: 'driving' })
      .expect('Content-Type', /json/)
      .expect(503);

    expect(res.body.success).toBe(false);
    expect(axios.get).not.toHaveBeenCalled();
  });

  test('POST /api/maps/autocomplete returns 503', async () => {
    const res = await request(app)
      .post('/api/maps/autocomplete')
      .set('Authorization', `Bearer ${validToken}`)
      .send({ input: 'Times Square' })
      .expect(503);
    expect(res.body.success).toBe(false);
  });

  test('POST /api/maps/place-details returns 503', async () => {
    const res = await request(app)
      .post('/api/maps/place-details')
      .set('Authorization', `Bearer ${validToken}`)
      .send({ place_id: 'abc123' })
      .expect(503);
    expect(res.body.success).toBe(false);
  });

  test('POST /api/maps/geocode returns 503', async () => {
    const res = await request(app)
      .post('/api/maps/geocode')
      .set('Authorization', `Bearer ${validToken}`)
      .send({ address: 'New York, NY' })
      .expect(503);
    expect(res.body.success).toBe(false);
  });

  test('POST /api/maps/nearby-search returns 503', async () => {
    const res = await request(app)
      .post('/api/maps/nearby-search')
      .set('Authorization', `Bearer ${validToken}`)
      .send({ location: '40.7,-73.9', radius: '500' })
      .expect(503);
    expect(res.body.success).toBe(false);
  });

  test('kill switch fires even without a valid token (fails closed before auth)', async () => {
    // The kill switch is mounted ahead of authenticateDevice, so a completely
    // unauthenticated request is still short-circuited with 503, not 401 —
    // when the switch is flipped, nothing about /api/maps should reach
    // Google, regardless of who is asking.
    const res = await request(app)
      .post('/api/maps/directions')
      .send({ origin: 'A', destination: 'B' })
      .expect(503);
    expect(res.body.success).toBe(false);
  });

  test('token issuance (/api/auth/token) is unaffected by the maps kill switch', async () => {
    const res = await request(app)
      .post('/api/auth/token')
      .send({ bundleId: 'com.yourcompany.geowake2' })
      .expect(200);
    expect(res.body.success).toBe(true);
  });
});
