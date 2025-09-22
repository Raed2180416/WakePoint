const axios = require('axios');
const config = require('../config/config');
const cache = require('../utils/cache');

/**
 * A generic function to proxy requests to the Google Maps API.
 * It handles caching and adds the API key securely on the server-side.
 */
const googleApiProxy = async (req, res, { url, params, type }) => {
  // Check cache first using structured type+params
  const cachedData = cache.get(type, params);
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

    // Cache the successful response under type+params (TTL by type)
    cache.set(type, params, response.data);

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
  const { origin, destination, mode, transit_mode } = req.body;
  const params = { origin, destination, mode, transit_mode };
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.directions,
    params,
    type: 'directions'
  });
};

// Handler for Autocomplete API
const getAutocomplete = (req, res) => {
  const { input, sessiontoken, location, components } = req.body;
  const params = { input, sessiontoken, location, components };
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.places,
    params,
    type: 'places'
  });
};

// Handler for Place Details API
const getPlaceDetails = (req, res) => {
  const { place_id, sessiontoken } = req.body;
  const params = { place_id, sessiontoken, fields: 'name,geometry,formatted_address' };
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.placeDetails,
    params,
    type: 'place-details'
  });
};

// Handler for Geocoding API
const getGeocoding = (req, res) => {
  const { address } = req.body;
  const params = { address };
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.geocoding,
    params,
    type: 'geocoding'
  });
};

// Handler for Nearby Search API
const getNearbySearch = (req, res) => {
  const { location, radius, type } = req.body; // location should be "lat,lng"
  const params = { location, radius, type };
  googleApiProxy(req, res, {
    url: config.googleMapsUrls.nearbySearch,
    params,
    type: 'nearby-search'
  });
};

module.exports = {
  getDirections,
  getAutocomplete,
  getPlaceDetails,
  getGeocoding,
  getNearbySearch
};