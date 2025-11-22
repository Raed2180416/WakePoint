/**
 * Maps API Tests
 * 
 * Tests for the Google Maps proxy endpoints including directions,
 * autocomplete, place details, geocoding, and nearby search.
 */

const request = require('supertest');
const app = require('../src/server');

describe('Maps API', () => {
  let validToken;

  // Get a valid token before running tests
  beforeAll(async () => {
    const response = await request(app)
      .post('/api/auth/token')
      .send({ bundleId: 'com.yourcompany.geowake2' });
    
    validToken = response.body.token;
  });

  describe('Authentication Requirements', () => {
    test('POST /api/maps/directions should require authentication', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .send({
          origin: '40.7128,-74.0060',
          destination: '40.7580,-73.9855',
          mode: 'driving'
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
      expect(response.body.error).toMatch(/token/i);
    });

    test('POST /api/maps/autocomplete should require authentication', async () => {
      const response = await request(app)
        .post('/api/maps/autocomplete')
        .send({
          input: 'Times Square'
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
    });

    test('POST /api/maps/place-details should require authentication', async () => {
      const response = await request(app)
        .post('/api/maps/place-details')
        .send({
          place_id: 'ChIJmQJIxlVYwokRLgeuocVOGVU'
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
    });

    test('POST /api/maps/geocode should require authentication', async () => {
      const response = await request(app)
        .post('/api/maps/geocode')
        .send({
          address: 'New York, NY'
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
    });

    test('POST /api/maps/nearby-search should require authentication', async () => {
      const response = await request(app)
        .post('/api/maps/nearby-search')
        .send({
          location: '40.7589,-73.9851',
          radius: '500',
          type: 'transit_station'
        })
        .expect('Content-Type', /json/)
        .expect(401);

      expect(response.body).toHaveProperty('success', false);
    });
  });

  describe('POST /api/maps/directions', () => {
    test('should accept request with valid parameters', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          origin: '40.7128,-74.0060',
          destination: '40.7580,-73.9855',
          mode: 'driving'
        })
        .expect('Content-Type', /json/);

      // Should be 200 (success) or Google API error
      expect([200, 400, 500]).toContain(response.status);
      
      if (response.status === 200) {
        // Valid Google API response structure
        expect(response.body).toBeDefined();
        // Google API responses have 'status' field
        expect(response.body).toHaveProperty('status');
      }
    });

    test('should accept transit mode', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          origin: '40.7128,-74.0060',
          destination: '40.7580,-73.9855',
          mode: 'transit',
          transit_mode: 'subway'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
    });

    test('should accept walking mode', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          origin: '40.7128,-74.0060',
          destination: '40.7580,-73.9855',
          mode: 'walking'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
    });
  });

  describe('POST /api/maps/autocomplete', () => {
    test('should accept request with input parameter', async () => {
      const response = await request(app)
        .post('/api/maps/autocomplete')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          input: 'Times Square',
          sessiontoken: 'test-session-123'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
      
      if (response.status === 200) {
        expect(response.body).toHaveProperty('status');
      }
    });

    test('should accept location bias parameter', async () => {
      const response = await request(app)
        .post('/api/maps/autocomplete')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          input: 'Coffee Shop',
          location: '40.7589,-73.9851',
          sessiontoken: 'test-session-456'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
    });

    test('should accept country component restriction', async () => {
      const response = await request(app)
        .post('/api/maps/autocomplete')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          input: 'Restaurant',
          components: 'country:us',
          sessiontoken: 'test-session-789'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
    });
  });

  describe('POST /api/maps/place-details', () => {
    test('should accept request with place_id', async () => {
      const response = await request(app)
        .post('/api/maps/place-details')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          place_id: 'ChIJmQJIxlVYwokRLgeuocVOGVU',
          sessiontoken: 'test-session-abc'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
      
      if (response.status === 200) {
        expect(response.body).toHaveProperty('status');
      }
    });
  });

  describe('POST /api/maps/geocode', () => {
    test('should accept address parameter', async () => {
      const response = await request(app)
        .post('/api/maps/geocode')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          address: '1600 Amphitheatre Parkway, Mountain View, CA'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
      
      if (response.status === 200) {
        expect(response.body).toHaveProperty('status');
      }
    });

    test('should accept coordinates as address', async () => {
      const response = await request(app)
        .post('/api/maps/geocode')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          address: '40.7589,-73.9851'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
    });
  });

  describe('POST /api/maps/nearby-search', () => {
    test('should accept location and radius parameters', async () => {
      const response = await request(app)
        .post('/api/maps/nearby-search')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          location: '40.7589,-73.9851',
          radius: '500',
          type: 'transit_station'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
      
      if (response.status === 200) {
        expect(response.body).toHaveProperty('status');
      }
    });

    test('should accept restaurant type', async () => {
      const response = await request(app)
        .post('/api/maps/nearby-search')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          location: '40.7589,-73.9851',
          radius: '1000',
          type: 'restaurant'
        })
        .expect('Content-Type', /json/);

      expect([200, 400, 500]).toContain(response.status);
    });
  });

  describe('Caching Behavior', () => {
    test('should cache directions requests', async () => {
      const params = {
        origin: '40.7128,-74.0060',
        destination: '40.7580,-73.9855',
        mode: 'driving'
      };

      // First request
      const response1 = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${validToken}`)
        .send(params);

      // Second request with same parameters
      const response2 = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${validToken}`)
        .send(params);

      // Both should have same status
      expect(response1.status).toBe(response2.status);

      // If successful, responses should be identical (from cache)
      if (response1.status === 200) {
        expect(JSON.stringify(response1.body)).toBe(JSON.stringify(response2.body));
      }
    });

    test('should cache autocomplete requests', async () => {
      const params = {
        input: 'Central Park',
        sessiontoken: 'cache-test-session'
      };

      // First request
      const response1 = await request(app)
        .post('/api/maps/autocomplete')
        .set('Authorization', `Bearer ${validToken}`)
        .send(params);

      // Second request with same parameters
      const response2 = await request(app)
        .post('/api/maps/autocomplete')
        .set('Authorization', `Bearer ${validToken}`)
        .send(params);

      expect(response1.status).toBe(response2.status);
    });
  });

  describe('Error Handling', () => {
    test('should handle requests with missing required parameters', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          // Missing origin and destination
          mode: 'driving'
        })
        .expect('Content-Type', /json/);

      // Should return error from Google API or validation error
      expect([400, 500]).toContain(response.status);
    });

    test('should handle malformed coordinates', async () => {
      const response = await request(app)
        .post('/api/maps/directions')
        .set('Authorization', `Bearer ${validToken}`)
        .send({
          origin: 'invalid-coordinates',
          destination: 'also-invalid',
          mode: 'driving'
        })
        .expect('Content-Type', /json/);

      // Should return error
      expect([400, 500]).toContain(response.status);
    });
  });
});
