// src/config/config.js
require('dotenv').config();

const config = {
  port: process.env.PORT || 3000,
  nodeEnv: process.env.NODE_ENV || 'development',
  
  // Google Maps API
  googleMapsApiKey: process.env.GOOGLE_MAPS_API_KEY,
  
  // JWT Configuration
  jwtSecret: process.env.JWT_SECRET,
  jwtExpiration: '24h',
  
  // Security
  // IMPORTANT: This must match the bundle ID in:
  // - android/app/build.gradle
  // - android/app/build.gradle.kts
  // - lib/config/app_config.dart
  // - lib/services/api_client.dart
  appBundleId: process.env.APP_BUNDLE_ID || 'com.geowake.app',
  // SECURITY: never include '*' — only the production frontend URL is allowed.
  // Mobile apps send no Origin header and are always accepted by the CORS
  // middleware (origin === undefined → callback(null, true)).
  allowedOrigins: process.env.ALLOWED_ORIGINS?.split(',') || [
    'https://geowake-production.up.railway.app'
  ],
  
  // Rate Limiting
  maxRequestsPerHour: parseInt(process.env.MAX_REQUESTS_PER_HOUR) || 1000,
  maxRequestsPerMinute: parseInt(process.env.MAX_REQUESTS_PER_MINUTE) || 100,
  // Tightened /api/auth/token issuance limit (per IP, successful mints only —
  // see middleware/security.js `auth` rule + skipFailedRequests). A self-minted
  // token is the capability an attacker needs to start burning Maps quota, so
  // capping how many can be minted per hour matters more than IP-limiting the
  // maps calls themselves (already covered by rateLimitRules.maps below).
  authTokenRateLimitPerHour: parseInt(process.env.AUTH_TOKEN_RATE_LIMIT_PER_HOUR) || 10,

  // ============================================================
  // WALLET PROTECTION (server-cost-security audit finding):
  // geowake-server proxies billed Google Maps APIs. bundleId alone is public
  // (it's the Play Store package id) so anyone can mint a token via
  // POST /api/auth/token and start calling /api/maps/*. These settings bound
  // the resulting financial exposure independently of device attestation
  // (which is a separate, larger fast-follow — see authController.js comment).
  // ============================================================
  //
  // Global daily request budget per Google API family, enforced in
  // middleware/mapsGuard.js BEFORE any outbound Google Maps call.
  // LIMITATION: counters are tracked in-memory per process (see
  // utils/quotaTracker.js). A multi-instance/horizontally-scaled deployment
  // needs shared storage (Redis, a DB row, etc.) for a true global cap —
  // today each replica enforces its own independent copy of these limits.
  dailyQuotas: {
    directions: parseInt(process.env.DAILY_QUOTA_DIRECTIONS) || 2000,
    places: parseInt(process.env.DAILY_QUOTA_PLACES) || 2000,
    geocoding: parseInt(process.env.DAILY_QUOTA_GEOCODING) || 2000,
    nearby: parseInt(process.env.DAILY_QUOTA_NEARBY) || 2000
  },
  // Per-device (JWT jti) daily cap, so a single self-minted token can't alone
  // exhaust the global family budget above.
  dailyQuotaPerToken: parseInt(process.env.DAILY_QUOTA_PER_TOKEN) || 200,
  // Kill switch: set MAPS_PROXY_DISABLED=true (e.g. via a Railway env var
  // change) to make every /api/maps/* route return 503 immediately — a
  // runaway bill can be stopped without a deploy.
  mapsProxyDisabled: process.env.MAPS_PROXY_DISABLED === 'true',

  // Cache Settings
  cacheTimeouts: {
    directions: 5 * 60, // 5 minutes
    places: 10 * 60,    // 10 minutes
    geocoding: 15 * 60  // 15 minutes
  },
  
  // Google Maps API URLs
  googleMapsUrls: {
    directions: 'https://maps.googleapis.com/maps/api/directions/json',
    places: 'https://maps.googleapis.com/maps/api/place/autocomplete/json',
    placeDetails: 'https://maps.googleapis.com/maps/api/place/details/json',
    geocoding: 'https://maps.googleapis.com/maps/api/geocode/json',
    nearbySearch: 'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
  }
};

// Validation
if (!config.googleMapsApiKey) {
  console.error('❌ GOOGLE_MAPS_API_KEY is required in environment variables');
  process.exit(1);
}

if (!config.jwtSecret || config.jwtSecret.length < 32) {
  console.error('❌ JWT_SECRET must be at least 32 characters long');
  process.exit(1);
}

module.exports = config;