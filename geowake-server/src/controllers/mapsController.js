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

    // Google returns HTTP 200 even when the request failed, signalling the real
    // outcome via response.data.status (e.g. OVER_QUERY_LIMIT, REQUEST_DENIED,
    // INVALID_REQUEST). axios does not throw on these, so we must inspect the
    // body: only OK / ZERO_RESULTS are genuine results that are safe to cache and
    // serve. Anything else must NOT be cached — otherwise the error body would be
    // served to every caller for the whole TTL, leaving riders with no route —
    // and must surface as a non-2xx so the client knows to retry.
    const apiStatus = response.data && response.data.status;
    if (apiStatus === 'OK' || apiStatus === 'ZERO_RESULTS') {
      // Cache the successful response under type+params (TTL by type)
      cache.set(type, params, response.data);
      return res.json(response.data);
    }

    const httpStatus = apiStatus === 'OVER_QUERY_LIMIT' ? 429 : 502;
    console.error(`❌ Google Maps API returned non-success status at ${url}: ${apiStatus}`);
    return res.status(httpStatus).json({
      success: false,
      error: 'An error occurred while fetching data from Google Maps API.',
      status: apiStatus || 'UNKNOWN_ERROR',
      details: response.data?.error_message || 'Upstream Google Maps API returned a non-success status.'
    });
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
  const { origin, destination, mode, transit_mode, departure_time } = req.body;
  const params = { origin, destination, mode, transit_mode };
  if (departure_time !== undefined && departure_time !== null) {
    params.departure_time = departure_time;
  }
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