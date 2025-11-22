/**
 * Authentication API Tests
 * 
 * Tests for the authentication endpoints including token generation,
 * validation, and error handling.
 */

const request = require('supertest');
const app = require('../src/server');

describe('Authentication API', () => {
  describe('POST /api/auth/token', () => {
    test('should generate token with valid bundle ID', async () => {
      const response = await request(app)
        .post('/api/auth/token')
        .send({
          bundleId: 'com.yourcompany.geowake2'
        })
        .expect('Content-Type', /json/)
        .expect(200);

      expect(response.body).toHaveProperty('success', true);
      expect(response.body).toHaveProperty('message', 'Token generated successfully.');
      expect(response.body).toHaveProperty('token');
      expect(response.body).toHaveProperty('expiresIn', '24h');
      expect(typeof response.body.token).toBe('string');
      expect(response.body.token.length).toBeGreaterThan(0);
    });

    test('should reject request with invalid bundle ID', async () => {
      const response = await request(app)
        .post('/api/auth/token')
        .send({
          bundleId: 'invalid.bundle.id'
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
      expect(response.body).toHaveProperty('error', 'Unauthorized: Invalid application identifier.');
    });

    test('should reject request with missing bundle ID', async () => {
      const response = await request(app)
        .post('/api/auth/token')
        .send({})
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
      expect(response.body).toHaveProperty('error', 'Unauthorized: Invalid application identifier.');
    });

    test('should reject request with empty bundle ID', async () => {
      const response = await request(app)
        .post('/api/auth/token')
        .send({
          bundleId: ''
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
      expect(response.body).toHaveProperty('error', 'Unauthorized: Invalid application identifier.');
    });

    test('should handle rapid successive requests (rate limiting)', async () => {
      // Make multiple rapid requests
      const requests = Array(5).fill(null).map(() =>
        request(app)
          .post('/api/auth/token')
          .send({ bundleId: 'com.yourcompany.geowake2' })
      );

      const responses = await Promise.all(requests);
      
      // All should succeed (within rate limit)
      responses.forEach(response => {
        expect(response.status).toBe(200);
        expect(response.body.success).toBe(true);
      });
    });
  });

  describe('Token Validation', () => {
    let validToken;

    beforeAll(async () => {
      const response = await request(app)
        .post('/api/auth/token')
        .send({ bundleId: 'com.yourcompany.geowake2' });
      
      validToken = response.body.token;
    });

    test('should accept requests with valid token', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          origin: '40.7128,-74.0060',
          destination: '40.7580,-73.9855',
          mode: 'transit'
        });

      // Should not be 401 (unauthorized)
      expect(response.status).not.toBe(401);
    });

    test('should reject requests without token', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .send({
          origin: '40.7128,-74.0060',
          destination: '40.7580,-73.9855'
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
      expect(response.body.error).toMatch(/token/i);
    });

    test('should reject requests with malformed token', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', 'Bearer invalid_token_format')
        .send({
          origin: '40.7128,-74.0060',
          destination: '40.7580,-73.9855'
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
      expect(response.body.error).toMatch(/token/i);
    });

    test('should reject requests with missing Bearer prefix', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', validToken)
        .send({
          origin: '40.7128,-74.0060',
          destination: '40.7580,-73.9855'
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
      expect(response.body.error).toMatch(/token/i);
    });
  });

  describe('Health Check Endpoints', () => {
    test('GET / should return server status', async () => {
      const response = await request(app)
        .get('/')
        .expect('Content-Type', /json/)
        .expect(200);

      expect(response.body).toHaveProperty('success', true);
      expect(response.body).toHaveProperty('message', 'GeoWake API Server');
      expect(response.body).toHaveProperty('version', '1.0.0');
      expect(response.body).toHaveProperty('environment');
      expect(response.body).toHaveProperty('timestamp');
      expect(response.body).toHaveProperty('uptime');
    });

    test('GET /api/health should return health status', async () => {
      const response = await request(app)
        .get('/api/health')
        .expect('Content-Type', /json/)
        .expect(200);

      expect(response.body).toHaveProperty('success', true);
      expect(response.body).toHaveProperty('message', 'GeoWake Server is running');
      expect(response.body).toHaveProperty('timestamp');
      expect(response.body).toHaveProperty('version', '1.0.0');
      expect(response.body).toHaveProperty('environment');
    });
  });

  describe('404 Handler', () => {
    test('should return 404 for non-existent routes', async () => {
      const response = await request(app)
        .get('/api/nonexistent')
        .expect('Content-Type', /json/)
        .expect(404);

      expect(response.body).toHaveProperty('success', false);
      expect(response.body).toHaveProperty('error', 'Endpoint not found');
      expect(response.body).toHaveProperty('path', '/api/nonexistent');
    });

    test('should return 404 for non-existent POST routes', async () => {
      const response = await request(app)
        .post('/api/invalid/endpoint')
        .send({ data: 'test' })
        .expect('Content-Type', /json/)
        .expect(404);

      expect(response.body).toHaveProperty('success', false);
      expect(response.body).toHaveProperty('error', 'Endpoint not found');
    });
  });
});
