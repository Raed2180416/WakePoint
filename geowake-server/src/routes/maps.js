// src/routes/maps.js
const express = require('express');
const { getDirections, getAutocomplete, getPlaceDetails, getGeocoding, getNearbySearch } = require('../controllers/mapsController');
const { rateLimitRules } = require('../middleware/security'); // Corrected import

const router = express.Router();

// Apply specific rate limiting to the maps routes
router.use(rateLimitRules.maps);

// Route for getting directions
router.post('/directions', getDirections);

// Route for place autocomplete
router.post('/autocomplete', getAutocomplete);

// Route for getting place details
router.post('/place-details', getPlaceDetails);

// Route for geocoding
router.post('/geocode', getGeocoding);

// Route for nearby search
router.post('/nearby-search', getNearbySearch);

module.exports = router;
