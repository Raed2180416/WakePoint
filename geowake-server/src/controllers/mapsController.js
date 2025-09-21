const axios = require('axios');
const config = require('../config/config');
const cache = require('../utils/cache');

/**
 * A generic function to proxy requests to the Google Maps API.
 * It handles caching and adds the API key securely on the server-side.
 */
const googleApiProxy = async (req, res, { url, params, cacheKey, cacheTimeout }) => {
  // Check cache first
  const cachedData = cache.get(cacheKey);
  if (cachedData) {
    return res.json(cachedData);
  }

  try {
    const response = await axios.get(url, {
      params: {
        ...params,
        key: config.googleMapsApiKey
      }
    });

    // Cache the successful response
    cache.set(cacheKey, response.data, cacheTimeout);

    res.json(response.data);
  } catch (error) {
    console.error(`❌ Google Maps API Error at ${url}:`, error.response ? error.response.data : error.message);
    res.status(error.response?.status || 500).json({
      success: false,
      error: 'An error occurred while fetching data from Google Maps API.',
      details: error.response?.data?.error_message || 'Internal server error.'
    });
  }
};

// Handler for Directions API
const getDirections = (req, res) => {
  const { origin, destination, mode } = req.body;
  const cacheKey = `directions:${origin}-${destination}-${mode || 'driving'}`;
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.directions,
    params: { origin, destination, mode },
    cacheKey,
    cacheTimeout: config.cacheTimeouts.directions
  });
};

// Handler for Autocomplete API
const getAutocomplete = (req, res) => {
  const { input, sessiontoken } = req.body;
  const cacheKey = `autocomplete:${input}`;
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.places,
    params: { input, sessiontoken },
    cacheKey,
    cacheTimeout: config.cacheTimeouts.places
  });
};

// Handler for Place Details API
const getPlaceDetails = (req, res) => {
  const { place_id, sessiontoken } = req.body;
  const cacheKey = `placedetails:${place_id}`;
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.placeDetails,
    params: { place_id, sessiontoken, fields: 'name,geometry,formatted_address' },
    cacheKey,
    cacheTimeout: config.cacheTimeouts.places
  });
};

// Handler for Geocoding API
const getGeocoding = (req, res) => {
  const { address } = req.body;
  const cacheKey = `geocode:${address}`;
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.geocoding,
    params: { address },
    cacheKey,
    cacheTimeout: config.cacheTimeouts.geocoding
  });
};

// Handler for Nearby Search API
const getNearbySearch = (req, res) => {
  const { location, radius, type } = req.body; // location should be "lat,lng"
  const cacheKey = `nearby:${location}-${radius}-${type}`;
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.nearbySearch,
    params: { location, radius, type },
    cacheKey,
    cacheTimeout: config.cacheTimeouts.places
  });
};

module.exports = {
  getDirections,
  getAutocomplete,
  getPlaceDetails,
  getGeocoding,
  getNearbySearch
};