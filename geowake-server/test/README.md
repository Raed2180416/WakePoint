# GeoWake Backend Test Suite

This directory contains the test suite for the GeoWake backend API server.

## Overview

The test suite covers:
- **Authentication API** - Token generation and validation
- **Maps API** - Google Maps proxy endpoints
- **Security** - Rate limiting, CORS, authentication middleware
- **Error Handling** - 404s, validation errors, malformed requests
- **Caching** - Response caching behavior

## Test Files

| File | Description | Tests |
|------|-------------|-------|
| `auth.test.js` | Authentication endpoints and token validation | 13 tests |
| `maps.test.js` | Google Maps proxy endpoints and caching | 25 tests |

## Running Tests

### Prerequisites

```bash
# Install dependencies
npm install

# Install test dependencies
npm install --save-dev jest supertest
```

### Run All Tests

```bash
npm test
```

### Run Specific Test File

```bash
npm test auth.test.js
npm test maps.test.js
```

### Run with Coverage

```bash
npm test -- --coverage
```

### Watch Mode (Auto-rerun on changes)

```bash
npm test -- --watch
```

## Test Structure

### Authentication Tests (`auth.test.js`)

Tests cover:
- ✅ Valid bundle ID authentication
- ✅ Invalid bundle ID rejection
- ✅ Missing bundle ID rejection
- ✅ Empty bundle ID rejection
- ✅ Rate limiting on auth endpoint
- ✅ Token validation on protected routes
- ✅ Malformed token rejection
- ✅ Missing Bearer prefix rejection
- ✅ Health check endpoints
- ✅ 404 handling

### Maps API Tests (`maps.test.js`)

Tests cover:
- ✅ Authentication requirements for all endpoints
- ✅ Directions API (driving, transit, walking modes)
- ✅ Autocomplete API (with location bias, country restrictions)
- ✅ Place Details API
- ✅ Geocoding API
- ✅ Nearby Search API
- ✅ Caching behavior
- ✅ Error handling for invalid parameters

## Test Configuration

Tests use:
- **Jest** - Test framework
- **Supertest** - HTTP assertions
- **Node.js** 18.x

### Jest Configuration

The `package.json` includes:

```json
{
  "scripts": {
    "test": "jest",
    "test:watch": "jest --watch",
    "test:coverage": "jest --coverage"
  },
  "jest": {
    "testEnvironment": "node",
    "coveragePathIgnorePatterns": [
      "/node_modules/"
    ],
    "testMatch": [
      "**/test/**/*.test.js"
    ]
  }
}
```

## Environment Setup for Testing

Tests require these environment variables:

```bash
# Required
GOOGLE_MAPS_API_KEY=your_test_api_key
JWT_SECRET=test_secret_at_least_32_characters_long

# Optional
APP_BUNDLE_ID=com.yourcompany.geowake2
NODE_ENV=test
```

Create a `.env.test` file with test credentials:

```bash
GOOGLE_MAPS_API_KEY=test_key_here
JWT_SECRET=test_jwt_secret_for_testing_purposes_only_min_32_chars
APP_BUNDLE_ID=com.yourcompany.geowake2
NODE_ENV=test
```

## Test Output

### Successful Test Run

```
 PASS  test/auth.test.js
  Authentication API
    POST /api/auth/token
      ✓ should generate token with valid bundle ID (45ms)
      ✓ should reject request with invalid bundle ID (12ms)
      ✓ should reject request with missing bundle ID (10ms)
      ✓ should reject request with empty bundle ID (11ms)
      ✓ should handle rapid successive requests (rate limiting) (89ms)
    Token Validation
      ✓ should accept requests with valid token (25ms)
      ✓ should reject requests without token (15ms)
      ✓ should reject requests with malformed token (18ms)
      ✓ should reject requests with missing Bearer prefix (16ms)
    Health Check Endpoints
      ✓ GET / should return server status (8ms)
      ✓ GET /api/health should return health status (7ms)
    404 Handler
      ✓ should return 404 for non-existent routes (9ms)
      ✓ should return 404 for non-existent POST routes (10ms)

 PASS  test/maps.test.js
  Maps API
    Authentication Requirements
      ✓ POST /api/maps/directions should require authentication (15ms)
      ✓ POST /api/maps/autocomplete should require authentication (12ms)
      ✓ POST /api/maps/place-details should require authentication (11ms)
      ✓ POST /api/maps/geocode should require authentication (10ms)
      ✓ POST /api/maps/nearby-search should require authentication (11ms)
    POST /api/maps/directions
      ✓ should accept request with valid parameters (120ms)
      ✓ should accept transit mode (115ms)
      ✓ should accept walking mode (110ms)
    ...

Test Suites: 2 passed, 2 total
Tests:       38 passed, 38 total
Snapshots:   0 total
Time:        3.456s
```

## Writing New Tests

### Template for New Test File

```javascript
const request = require('supertest');
const app = require('../src/server');

describe('Feature Name', () => {
  let validToken;

  // Get auth token before tests
  beforeAll(async () => {
    const response = await request(app)
      .post('/api/auth/token')
      .send({ bundleId: 'com.yourcompany.geowake2' });
    validToken = response.body.token;
  });

  describe('Endpoint Name', () => {
    test('should do something', async () => {
      const response = await request(app)
        .post('/api/endpoint')
        .set('Authorization', `Bearer ${validToken}`)
        .send({ data: 'value' })
        .expect(200);

      expect(response.body).toHaveProperty('success', true);
    });
  });
});
```

## Coverage Goals

Target coverage:
- **Lines:** >80%
- **Functions:** >80%
- **Branches:** >70%
- **Statements:** >80%

Current coverage status:
- To be measured after test suite is run

## Continuous Integration

### GitHub Actions (Recommended)

Create `.github/workflows/test.yml`:

```yaml
name: Test Backend

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
      
      - name: Install dependencies
        working-directory: ./geowake-server
        run: npm install
      
      - name: Run tests
        working-directory: ./geowake-server
        env:
          GOOGLE_MAPS_API_KEY: ${{ secrets.GOOGLE_MAPS_API_KEY }}
          JWT_SECRET: ${{ secrets.JWT_SECRET }}
        run: npm test
```

## Troubleshooting

### Common Issues

**Problem:** Tests fail with "JWT_SECRET must be at least 32 characters"
**Solution:** Set a valid JWT_SECRET in your `.env.test` file

**Problem:** Tests fail with "GOOGLE_MAPS_API_KEY is required"
**Solution:** Set GOOGLE_MAPS_API_KEY in your `.env.test` file

**Problem:** Tests timeout
**Solution:** Increase Jest timeout in test file:
```javascript
jest.setTimeout(10000); // 10 seconds
```

**Problem:** Port already in use
**Solution:** The tests use supertest which doesn't require a listening server. If you're running the dev server simultaneously, it won't conflict.

## Next Steps

1. **Add Integration Tests**
   - Test full request/response cycles with real Google API
   - Test cache expiration and refresh

2. **Add Load Tests**
   - Test rate limiting under load
   - Test concurrent request handling

3. **Add Security Tests**
   - Test SQL injection prevention (if DB added)
   - Test XSS prevention
   - Test CSRF protection

4. **Add Mocking**
   - Mock Google Maps API responses
   - Test error scenarios without hitting real API

5. **Add E2E Tests**
   - Test Flutter app with backend
   - Test authentication flow end-to-end

---

**Last Updated:** 2024-01-15  
**Maintained By:** GeoWake Development Team
