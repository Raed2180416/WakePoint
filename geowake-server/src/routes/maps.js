// src/routes/maps.js
const express = require('express');
const { getDirections, getAutocomplete, getPlaceDetails, getGeocoding, getNearbySearch } = require('../controllers/mapsController');
const { rateLimitRules } = require('../middleware/security'); // Corrected import variable name
const { familyQuotaGuard } = require('../middleware/mapsGuard');

const router = express.Router();

// Apply specific rate limiting to the maps routes
router.use(rateLimitRules.maps); // Corrected variable name

// Route for getting directions (Directions API family daily budget)
router.post('/directions', familyQuotaGuard('directions'), getDirections);

// Route for place autocomplete (Places API family daily budget)
router.post('/autocomplete', familyQuotaGuard('places'), getAutocomplete);

// Route for getting place details (Places API family daily budget)
router.post('/place-details', familyQuotaGuard('places'), getPlaceDetails);

// Route for geocoding (Geocoding API family daily budget)
router.post('/geocode', familyQuotaGuard('geocoding'), getGeocoding);

// Route for nearby search (Nearby Search API family daily budget)
router.post('/nearby-search', familyQuotaGuard('nearby'), getNearbySearch);

module.exports = router;
