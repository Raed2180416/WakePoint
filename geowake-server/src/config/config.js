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
  appBundleId: process.env.APP_BUNDLE_ID || 'com.yourcompany.geowake2',
  allowedOrigins: process.env.ALLOWED_ORIGINS?.split(',') || [
    'https://geowake-production.up.railway.app',
    '*'
  ],
  
  // Rate Limiting
  maxRequestsPerHour: parseInt(process.env.MAX_REQUESTS_PER_HOUR) || 1000,
  maxRequestsPerMinute: parseInt(process.env.MAX_REQUESTS_PER_MINUTE) || 100,
  
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