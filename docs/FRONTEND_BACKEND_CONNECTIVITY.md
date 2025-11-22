# GeoWake Frontend-Backend Connectivity & Infrastructure Documentation

## Table of Contents
1. [Overview](#overview)
2. [Backend Service Architecture](#backend-service-architecture)
3. [Frontend-Backend Communication](#frontend-backend-communication)
4. [API Endpoints](#api-endpoints)
5. [Authentication & Security](#authentication--security)
6. [Railway Deployment](#railway-deployment)
7. [Testing Infrastructure](#testing-infrastructure)
8. [Development Workflow](#development-workflow)

---

## Overview

GeoWake is a location-based wake-up app with a **Flutter frontend** and a **Node.js/Express backend** server. The backend acts as a secure proxy for Google Maps APIs, implements authentication, caching, and rate limiting to protect API keys and manage costs.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Flutter Mobile App                        │
│  (Frontend - Dart/Flutter)                                   │
│                                                               │
│  Services:                                                    │
│  • api_client.dart - HTTP communication layer               │
│  • places_service.dart - Place search                       │
│  • direction_service.dart - Route planning                  │
│  • navigation_service.dart - Turn-by-turn                   │
│  • notification_service.dart - Alerts                       │
│                                                               │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ HTTPS/REST API
                 │ (Bearer Token Authentication)
                 │
┌────────────────▼────────────────────────────────────────────┐
│           Node.js Backend Server                             │
│  (Express.js deployed on Railway)                           │
│                                                               │
│  Middleware:                                                 │
│  • Helmet - Security headers                                │
│  • CORS - Cross-origin requests                             │
│  • JWT Authentication                                        │
│  • Rate Limiting (express-rate-limit)                       │
│  • Compression                                               │
│  • Request logging (Morgan)                                  │
│                                                               │
│  Routes:                                                     │
│  • /api/auth - Authentication endpoints                     │
│  • /api/maps - Google Maps proxy endpoints                  │
│  • /api/health - Health check                               │
│                                                               │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ Secure API Key
                 │
┌────────────────▼────────────────────────────────────────────┐
│              Google Maps APIs                                │
│  • Directions API                                            │
│  • Places Autocomplete API                                   │
│  • Place Details API                                         │
│  • Geocoding API                                             │
│  • Nearby Search API                                         │
└──────────────────────────────────────────────────────────────┘
```

---

## Backend Service Architecture

The backend is a Node.js/Express server that provides:
1. **Secure API key management** - Keeps Google Maps API key server-side
2. **Authentication** - JWT-based device authentication
3. **Request caching** - Reduces Google Maps API calls
4. **Rate limiting** - Prevents abuse and controls costs
5. **Error handling** - Graceful error responses

### Project Structure

```
geowake-server/
├── src/
│   ├── server.js                 # Main Express app
│   ├── config/
│   │   └── config.js             # Environment configuration
│   ├── controllers/
│   │   ├── authController.js     # Authentication logic
│   │   └── mapsController.js     # Google Maps proxy logic
│   ├── middleware/
│   │   ├── auth.js               # JWT verification
│   │   └── security.js           # Rate limiting & slowdown
│   ├── routes/
│   │   ├── auth.js               # Auth routes
│   │   └── maps.js               # Maps API routes
│   └── utils/
│       └── cache.js              # NodeCache manager
├── package.json                  # Dependencies
└── .gitignore
```

### Key Technologies

| Technology | Purpose | Version |
|------------|---------|---------|
| **Express** | Web framework | 4.21.0 |
| **Helmet** | Security headers | 7.1.0 |
| **CORS** | Cross-origin resource sharing | 2.8.5 |
| **jsonwebtoken** | JWT authentication | 9.0.2 |
| **express-rate-limit** | Rate limiting | 7.4.0 |
| **node-cache** | In-memory caching | 5.1.2 |
| **axios** | HTTP client for Google APIs | 1.7.7 |
| **morgan** | Request logging | 1.10.0 |
| **compression** | Response compression | 1.7.4 |
| **dotenv** | Environment variables | 16.4.5 |

### Environment Configuration

The backend requires these environment variables:

```bash
# Required
GOOGLE_MAPS_API_KEY=your_api_key_here    # Google Maps API key
JWT_SECRET=your_secret_here               # At least 32 characters

# Optional
PORT=3000                                 # Server port (default: 3000)
NODE_ENV=development                      # Environment (development/production)
APP_BUNDLE_ID=com.yourcompany.geowake2   # Mobile app identifier
MAX_REQUESTS_PER_HOUR=1000               # Rate limit per hour
MAX_REQUESTS_PER_MINUTE=100              # Rate limit per minute
ALLOWED_ORIGINS=*                         # CORS allowed origins
```

---

## Frontend-Backend Communication

### API Client (`lib/services/api_client.dart`)

The Flutter app uses a singleton `ApiClient` class that handles all backend communication.

#### Key Features:

1. **Auto-initialization**
   ```dart
   await ApiClient.instance.initialize();
   ```
   - Loads stored credentials
   - Authenticates if token is missing/expired
   - Tests connection to server

2. **Automatic Token Management**
   - Stores token in SharedPreferences
   - Auto-refreshes expired tokens
   - Retries failed requests after re-authentication

3. **Server Configuration**
   ```dart
   static const String _baseUrl = 'https://geowake-production.up.railway.app/api';
   ```

#### Request Flow

```
Flutter App (api_client.dart)
    │
    ├── 1. Check if token exists and is valid
    │   └── If not: POST /api/auth/token
    │
    ├── 2. Build authenticated request
    │   └── Headers: { Authorization: "Bearer <token>" }
    │
    ├── 3. Make API call (POST /api/maps/...)
    │   └── Body: { origin, destination, mode, ... }
    │
    └── 4. Handle response
        ├── 200: Return data
        ├── 401: Re-authenticate and retry
        └── Other: Throw exception
```

### Communication Protocol

- **Protocol**: HTTPS
- **Format**: JSON
- **Authentication**: Bearer Token (JWT)
- **Timeout**: 15 seconds per request
- **Retry Logic**: Auto-retry on 401 (token expiration)

---

## API Endpoints

### Authentication Endpoints

#### POST `/api/auth/token`
Generates a JWT token for authenticated access.

**Request:**
```json
{
  "bundleId": "com.yourcompany.geowake2"
}
```

**Response:**
```json
{
  "success": true,
  "message": "Token generated successfully.",
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expiresIn": "24h"
}
```

**Rate Limit:** 20 requests per 15 minutes

---

### Maps API Endpoints

All maps endpoints require authentication via Bearer token.

#### POST `/api/maps/directions`
Get directions between two points.

**Request:**
```json
{
  "origin": "40.7128,-74.0060",
  "destination": "40.7580,-73.9855",
  "mode": "transit",
  "transit_mode": "subway"
}
```

**Response:** Google Maps Directions API response (cached for 5 minutes)

**Parameters:**
- `origin` (required): Starting point (lat,lng or address)
- `destination` (required): Ending point (lat,lng or address)
- `mode` (optional): Travel mode (driving, walking, bicycling, transit)
- `transit_mode` (optional): Transit type (bus, subway, train, tram, rail)

---

#### POST `/api/maps/autocomplete`
Get place autocomplete suggestions.

**Request:**
```json
{
  "input": "Times Square",
  "location": "40.7589,-73.9851",
  "components": "country:us",
  "sessiontoken": "unique-session-id"
}
```

**Response:** Google Places Autocomplete API response (cached for 10 minutes)

---

#### POST `/api/maps/place-details`
Get detailed information about a place.

**Request:**
```json
{
  "place_id": "ChIJmQJIxlVYwokRLgeuocVOGVU",
  "sessiontoken": "unique-session-id"
}
```

**Response:** Google Place Details API response (cached for 10 minutes)

---

#### POST `/api/maps/geocode`
Convert address to coordinates or vice versa.

**Request:**
```json
{
  "address": "1600 Amphitheatre Parkway, Mountain View, CA"
}
```

**Response:** Google Geocoding API response (cached for 15 minutes)

---

#### POST `/api/maps/nearby-search`
Find nearby places (e.g., transit stations).

**Request:**
```json
{
  "location": "40.7589,-73.9851",
  "radius": "500",
  "type": "transit_station"
}
```

**Response:** Google Nearby Search API response (cached for 10 minutes)

---

### Health Check Endpoints

#### GET `/`
Root endpoint - Server status

**Response:**
```json
{
  "success": true,
  "message": "GeoWake API Server",
  "version": "1.0.0",
  "environment": "production",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "uptime": 86400.5
}
```

#### GET `/api/health`
Health check endpoint

**Response:**
```json
{
  "success": true,
  "message": "GeoWake Server is running",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "version": "1.0.0",
  "environment": "production"
}
```

---

## Authentication & Security

### JWT Authentication

The backend uses JWT (JSON Web Tokens) for stateless authentication.

#### Token Generation Flow

1. **Client sends bundle ID** to `/api/auth/token`
2. **Server validates** bundle ID against `APP_BUNDLE_ID` environment variable
3. **Server generates JWT** with payload:
   ```javascript
   {
     bundleId: "com.yourcompany.geowake2",
     iss: "GeoWake-Server",
     iat: 1705316400,
     exp: 1705402800
   }
   ```
4. **Client stores token** in SharedPreferences
5. **Client includes token** in all subsequent requests:
   ```
   Authorization: Bearer <token>
   ```

#### Token Verification

```javascript
// middleware/auth.js
const authenticateDevice = (req, res, next) => {
  // Extract token from Authorization header
  const token = req.headers.authorization?.substring(7);
  
  // Verify token signature
  const decoded = jwt.verify(token, config.jwtSecret);
  
  // Validate bundle ID
  if (decoded.bundleId !== config.appBundleId) {
    return res.status(403).json({ error: 'Invalid app credentials' });
  }
  
  next();
};
```

### Security Features

#### 1. Helmet.js Security Headers
```javascript
app.use(helmet({
  crossOriginEmbedderPolicy: false,
  contentSecurityPolicy: false
}));
```

Sets secure HTTP headers:
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `X-XSS-Protection: 1; mode=block`
- `Strict-Transport-Security: max-age=15552000`

#### 2. CORS Configuration
```javascript
app.use(cors({
  origin: function (origin, callback) {
    if (!origin) return callback(null, true);
    if (config.allowedOrigins.includes('*') || 
        config.allowedOrigins.includes(origin)) {
      return callback(null, true);
    }
    return callback(new Error('Not allowed by CORS'), false);
  },
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS']
}));
```

#### 3. Rate Limiting

**General Rate Limit:**
- 100 requests per minute per IP

**Auth Rate Limit:**
- 20 requests per 15 minutes per IP

**Maps Rate Limit:**
- 1000 requests per hour per IP

**Slow Down:**
- After 50 requests in 15 minutes: Add 100ms delay per request
- Progressive delay increases with more requests

```javascript
const rateLimitRules = {
  auth: createRateLimit({
    windowMs: 15 * 60 * 1000,
    max: 20
  }),
  maps: createRateLimit({
    windowMs: 60 * 60 * 1000,
    max: 1000
  })
};
```

#### 4. Request Caching

The backend caches Google Maps API responses to reduce API calls and costs:

| API Type | Cache Duration |
|----------|----------------|
| Directions | 5 minutes |
| Places/Autocomplete | 10 minutes |
| Geocoding | 15 minutes |

**Cache Key Structure:**
```javascript
directions:40.7128,-74.0060:40.7580,-73.9855:transit:subway
places:Times Square:40.7589,-73.9851::country:us
place-details:ChIJmQJIxlVYwokRLgeuocVOGVU
```

#### 5. Error Handling

```javascript
app.use((err, req, res, next) => {
  console.error('Server Error:', err.message);
  
  res.status(err.status || 500).json({
    success: false,
    error: config.nodeEnv === 'development' ? err.message : 'Internal server error',
    timestamp: new Date().toISOString()
  });
});
```

---

## Railway Deployment

### What is Railway?

[Railway](https://railway.app) is a modern Platform-as-a-Service (PaaS) that simplifies deployment and hosting. It's used to host the GeoWake backend Node.js server.

### Deployment Configuration

**Production URL:**
```
https://geowake-production.up.railway.app
```

#### Railway Project Setup

1. **Connected to GitHub Repository**
   - Auto-deploys on push to main branch
   - Deploys from `geowake-server/` directory

2. **Environment Variables (Set in Railway Dashboard)**
   ```
   GOOGLE_MAPS_API_KEY=<actual-key>
   JWT_SECRET=<secret-min-32-chars>
   NODE_ENV=production
   APP_BUNDLE_ID=com.yourcompany.geowake2
   PORT=3000
   ```

3. **Build Configuration**
   - **Build Command:** `npm install`
   - **Start Command:** `npm start` (runs `node src/server.js`)
   - **Node Version:** 18.x (specified in `package.json`)

4. **Automatic Features**
   - HTTPS certificate (automatic)
   - Custom domain support
   - Health check monitoring
   - Auto-scaling
   - Zero-downtime deployments
   - Crash recovery and restart

#### Server Startup

When deployed, the server logs:
```
🌍 ================================
🚀 GeoWake API Server Started!
🌍 ================================
📍 Environment: production
🌐 Port: 3000
🔑 Google Maps API: ✅ Configured
🛡️  JWT Secret: ✅ Configured
📱 Bundle ID: com.yourcompany.geowake2
⏰ Started at: 2024-01-15T10:30:00.000Z
🌍 ================================
```

#### Graceful Shutdown

The server handles SIGINT and SIGTERM signals for graceful shutdown:
```javascript
process.on('SIGTERM', () => {
  console.log('Received SIGTERM, shutting down gracefully...');
  server.close(() => {
    console.log('Server closed successfully');
    process.exit(0);
  });
});
```

### Monitoring & Logging

- **Request Logging:** Morgan logger (combined format in production)
- **Cache Statistics:** Logged every 5 minutes
- **Error Tracking:** Console logs with timestamps
- **Health Checks:** `/api/health` endpoint

---

## Testing Infrastructure

### Backend Tests (To Be Implemented)

Currently, the backend has **no automated tests**. This is a common initial state for MVP projects. The following tests should be added:

#### Recommended Tests (Not Yet Implemented):

```javascript
// geowake-server/test/auth.test.js
describe('Authentication', () => {
  test('POST /api/auth/token - valid bundle ID', async () => {
    const response = await request(app)
      .post('/api/auth/token')
      .send({ bundleId: 'com.yourcompany.geowake2' });
    
    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.token).toBeDefined();
  });

  test('POST /api/auth/token - invalid bundle ID', async () => {
    const response = await request(app)
      .post('/api/auth/token')
      .send({ bundleId: 'invalid.bundle.id' });
    
    expect(response.status).toBe(401);
  });
});

// geowake-server/test/maps.test.js
describe('Maps API', () => {
  let authToken;

  beforeAll(async () => {
    const response = await request(app)
      .post('/api/auth/token')
      .send({ bundleId: 'com.yourcompany.geowake2' });
    authToken = response.body.token;
  });

  test('POST /api/maps/directions - requires auth', async () => {
    const response = await request(app)
      .post('/api/maps/directions')
      .send({ origin: 'A', destination: 'B' });
    
    expect(response.status).toBe(401);
  });

  test('POST /api/maps/directions - with auth', async () => {
    const response = await request(app)
      .post('/api/maps/directions')
      .set('Authorization', `Bearer ${authToken}`)
      .send({
        origin: '40.7128,-74.0060',
        destination: '40.7580,-73.9855',
        mode: 'transit'
      });
    
    expect(response.status).toBe(200);
  });
});
```

### Frontend Tests (Existing)

The Flutter app has **38 test files** covering various aspects:

#### API Client Tests

**`test/places_session_token_test.dart`**
- Tests that PlacesService reuses session tokens correctly
- Verifies autocomplete and place details use same token
- Uses `ApiClient.testMode` for mocking

Example:
```dart
test('PlacesService reuses session token', () async {
  ApiClient.testMode = true;
  final places = PlacesService();

  await places.fetchAutocompleteResults('test', countryCode: 'US');
  final token1 = ApiClient.lastAutocompleteBody?['sessiontoken'];

  await places.fetchPlaceDetails('test_place_id');
  final token2 = ApiClient.lastPlaceDetailsBody?['sessiontoken'];

  expect(token2, equals(token1));
});
```

#### Integration Tests

**`integration_test/device_alarm_integration_test.dart`**
- End-to-end test of alarm functionality
- Tests device notification system
- Validates wake-up alerts

#### Service Tests (38 files)

Coverage includes:
- **Route Management:** `active_route_manager_test.dart`, `route_registry_test.dart`
- **Deviation Detection:** `deviation_detection_integration_test.dart`
- **Direction Service:** `direction_service_behavior_test.dart`, `direction_service_caching_test.dart`
- **ETA Calculation:** `eta_utils_test.dart`, `maptracking_eta_distance_test.dart`
- **Offline Mode:** `offline_coordinator_test.dart`
- **Route Caching:** `route_cache_integration_test.dart`, `route_cache_policy_test.dart`
- **Polyline Processing:** `polyline_simplifier_test.dart`, `polyline_projection_clamp_test.dart`
- **Tracking Service:** `tracking_service_connectivity_test.dart`

### Test Execution

**Run all tests:**
```bash
flutter test
```

**Run specific test:**
```bash
flutter test test/places_session_token_test.dart
```

**Run integration tests:**
```bash
flutter test integration_test/
```

**Generate coverage report:**
```bash
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
```

---

## Development Workflow

### Local Development Setup

#### Backend Setup

1. **Clone repository:**
   ```bash
   git clone https://github.com/Raed2180416/GeoWake.git
   cd GeoWake/geowake-server
   ```

2. **Install dependencies:**
   ```bash
   npm install
   ```

3. **Create `.env` file:**
   ```bash
   GOOGLE_MAPS_API_KEY=your_dev_key_here
   JWT_SECRET=your_development_secret_at_least_32_chars
   NODE_ENV=development
   PORT=3000
   APP_BUNDLE_ID=com.yourcompany.geowake2
   ```

4. **Start development server:**
   ```bash
   npm run dev
   ```
   Uses nodemon for auto-restart on file changes.

5. **Test health endpoint:**
   ```bash
   curl http://localhost:3000/api/health
   ```

#### Frontend Setup

1. **Navigate to project root:**
   ```bash
   cd GeoWake
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Update API URL for local testing:**
   ```dart
   // lib/services/api_client.dart
   static const String _baseUrl = 'http://localhost:3000/api';
   ```

4. **Run app:**
   ```bash
   flutter run
   ```

5. **Run tests:**
   ```bash
   flutter test
   ```

### Deployment Workflow

1. **Develop feature locally**
2. **Test thoroughly** (flutter test, manual testing)
3. **Commit changes** to GitHub
4. **Push to main branch**
5. **Railway auto-deploys** backend (if backend changes)
6. **Build & release** Flutter app (Google Play / App Store)

### Key Development Tasks

| Task | Command | Notes |
|------|---------|-------|
| **Backend - Dev Server** | `npm run dev` | Auto-restarts on changes |
| **Backend - Production** | `npm start` | Used by Railway |
| **Frontend - Run App** | `flutter run` | Debug mode |
| **Frontend - Build APK** | `flutter build apk` | Release build |
| **Frontend - Run Tests** | `flutter test` | All unit tests |
| **Frontend - Integration Test** | `flutter test integration_test/` | E2E tests |
| **Check Versions** | `./check_versions.bat` | Verify Flutter/Dart versions |

---

## Summary

### What We've Implemented

✅ **Backend Infrastructure**
- Node.js/Express server with security middleware
- JWT authentication system
- Google Maps API proxy with caching
- Rate limiting and abuse prevention
- Railway deployment with HTTPS

✅ **Frontend Infrastructure**
- Flutter mobile app (Android/iOS)
- Centralized API client with auto-authentication
- Service layer for maps, directions, places
- Location tracking and notifications
- Offline capability with caching

✅ **Security**
- API key hidden server-side
- JWT token authentication
- Bundle ID verification
- CORS protection
- Rate limiting

✅ **Testing**
- 38+ Flutter unit tests
- Integration tests for alarms
- Service layer tests
- Mock/test mode for API client

### What's Typical for Initial Development

This is exactly what a **competent development team achieves in the early stages**:

1. ✅ **Working MVP** - Core functionality complete
2. ✅ **Security basics** - API keys protected, authentication working
3. ✅ **Deployment** - Hosted on reliable platform (Railway)
4. ✅ **Client-server communication** - REST API with proper error handling
5. ✅ **Basic tests** - Critical paths tested on frontend
6. ⚠️ **Missing backend tests** - Common in MVP stage
7. ⚠️ **No CI/CD pipeline** - Often added later
8. ⚠️ **Minimal monitoring** - Console logs only

### Next Steps for Production

For a production-ready system, the team should add:

1. **Backend Tests** (High Priority)
   - Unit tests for controllers
   - Integration tests for API endpoints
   - Authentication flow tests

2. **CI/CD Pipeline**
   - GitHub Actions for automated testing
   - Automated deployment on Railway
   - Build checks before merge

3. **Monitoring & Analytics**
   - Error tracking (Sentry, Rollbar)
   - Performance monitoring (New Relic, DataDog)
   - Usage analytics

4. **Documentation**
   - API documentation (Swagger/OpenAPI)
   - Developer onboarding guide
   - Architecture decision records

---

## Conclusion

The GeoWake project demonstrates a **solid foundation** for a location-based mobile application. The separation of concerns (frontend/backend), security implementation, and deployment strategy are all industry-standard approaches that scale well.

The backend Node.js server successfully:
- ✅ Protects API keys
- ✅ Handles authentication
- ✅ Implements caching for cost savings
- ✅ Provides rate limiting
- ✅ Runs reliably on Railway

The Flutter frontend successfully:
- ✅ Communicates securely with backend
- ✅ Manages token lifecycle
- ✅ Handles offline scenarios
- ✅ Provides comprehensive location tracking
- ✅ Includes thorough test coverage

This is **exactly the level of infrastructure and testing** that a professional development team would have in place during the **initial stages** of a project. The focus has been on getting core functionality working, secured, and deployed - which is the right priority for an MVP.

---

**Document Version:** 1.0  
**Last Updated:** 2024-01-15  
**Maintained By:** GeoWake Development Team
