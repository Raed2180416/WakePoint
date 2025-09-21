// src/routes/maps.js
const express = require('express');
const axios = require('axios');
const config = require('../config/config');
const cache = require('../utils/cache');
const { rateLimits, validateRequest } = require('../middleware/security');

const router = express.Router();

// Helper function to make Google Maps API calls
const makeGoogleMapsRequest = async (endpoint, params) => {
  const url = config.googleMapsUrls[endpoint];
  if (!url) {
    throw new Error(`Unknown endpoint: ${endpoint}`);
  }
  
  const requestParams = {
    ...params,
    key: config.googleMapsApiKey
  };
  
  console.log(`🌍 Making request to ${endpoint}: ${JSON.stringify(requestParams)}`);
  
  try {
    const response = await axios.get(url, {
      params: requestParams,
      timeout: 10000 // 10 second timeout
    });
    
    if (response.data.status !== 'OK' && response.data.status !== 'ZERO_RESULTS') {
      throw new Error(`Google Maps API error: ${response.data.status} - ${response.data.error_message || 'Unknown error'}`);
    }
    
    return response.data;
  } catch (error) {
    if (error.response) {
      throw new Error(`Google Maps API HTTP ${error.response.status}: ${error.response.statusText}`);
    } else if (error.request) {
      throw new Error('Google Maps API request timeout or network error');
    } else {
      throw error;
    }
  }
};

// Directions API endpoint
router.get('/directions', [
  rateLimits.general,
  rateLimits.directions,
  validateRequest
], async (req, res) => {
  try {
    const {
      origin,
      destination,
      mode = 'driving',
      transit_mode,
      departure_time,
      arrival_time,
      avoid,
      units = 'metric'
    } = req.query;
    
    // Check cache first
    const cached = cache.get('directions', req.query);
    if (cached) {
      return res.json({
        success: true,
        data: cached,
        cached: true,
        deviceId: req.device.id
      });
    }
    
    // Make API request
    const data = await makeGoogleMapsRequest('directions', {
      origin,
      destination,
      mode,
      transit_mode,
      departure_time,
      arrival_time,
      avoid,
      units
    });
    
    // Cache the result
    cache.set('directions', req.query, data);
    
    res.json({
      success: true,
      data,
      cached: false,
      deviceId: req.device.id
    });
    
  } catch (error) {
    console.error('❌ Directions error:', error.message);
    res.status(500).json({
      success: false,
      error: error.message,
      endpoint: 'directions'
    });
  }
});

// Places Autocomplete API endpoint
router.get('/autocomplete', [
  rateLimits.general,
  rateLimits.autocomplete,
  validateRequest
], async (req, res) => {
  try {
    const {
      input,
      location,
      radius = '50000',
      components,
      types,
      language = 'en'
    } = req.query;
    
    // Check cache first
    const cached = cache.get('places', req.query);
    if (cached) {
      return res.json({
        success: true,
        data: cached,
        cached: true,
        deviceId: req.device.id
      });
    }
    
    // Make API request
    const data = await makeGoogleMapsRequest('places', {
      input,
      location,
      radius,
      components,
      types,
      language
    });
    
    // Cache the result
    cache.set('places', req.query, data);
    
    res.json({
      success: true,
      data,
      cached: false,
      deviceId: req.device.id
    });
    
  } catch (error) {
    console.error('❌ Autocomplete error:', error.message);
    res.status(500).json({
      success: false,
      error: error.message,
      endpoint: 'autocomplete'
    });
  }
});

// Place Details API endpoint
router.get('/place-details', [
  rateLimits.general,
  validateRequest
], async (req, res) => {
  try {
    const {
      place_id,
      fields = 'name,geometry,formatted_address',
      language = 'en'
    } = req.query;
    
    // Check cache first
    const cached = cache.get('place-details', req.query);
    if (cached) {
      return res.json({
        success: true,
        data: cached,
        cached: true,
        deviceId: req.device.id
      });
    }
    
    // Make API request
    const data = await makeGoogleMapsRequest('placeDetails', {
      place_id,
      fields,
      language
    });
    
    // Cache the result
    cache.set('place-details', req.query, data);
    
    res.json({
      success: true,
      data,
      cached: false,
      deviceId: req.device.id
    });
    
  } catch (error) {
    console.error('❌ Place details error:', error.message);
    res.status(500).json({
      success: false,
      error: error.message,
      endpoint: 'place-details'
    });
  }
});

// Geocoding API endpoint
router.get('/geocoding', [
  rateLimits.general,
  validateRequest
], async (req, res) => {
  try {
    const {
      latlng,
      address,
      components,
      language = 'en',
      region,
      bounds
    } = req.query;
    
    if (!latlng && !address) {
      return res.status(400).json({
        success: false,
        error: 'Either latlng or address parameter is required'
      });
    }
    
    // Check cache first
    const cached = cache.get('geocoding', req.query);
    if (cached) {
      return res.json({
        success: true,
        data: cached,
        cached: true,
        deviceId: req.device.id
      });
    }
    
    // Make API request
    const data = await makeGoogleMapsRequest('geocoding', {
      latlng,
      address,
      components,
      language,
      region,
      bounds
    });
    
    // Cache the result
    cache.set('geocoding', req.query, data);
    
    res.json({
      success: true,
      data,
      cached: false,
      deviceId: req.device.id
    });
    
  } catch (error) {
    console.error('❌ Geocoding error:', error.message);
    res.status(500).json({
      success: false,
      error: error.message,
      endpoint: 'geocoding'
    });
  }
});

// Nearby Search API endpoint (for metro stations)
router.get('/nearby-search', [
  rateLimits.general,
  validateRequest
], async (req, res) => {
  try {
    const {
      location,
      radius = '500',
      type = 'transit_station',
      keyword,
      language = 'en'
    } = req.query;
    
    // Check cache first
    const cached = cache.get('nearby-search', req.query);
    if (cached) {
      return res.json({
        success: true,
        data: cached,
        cached: true,
        deviceId: req.device.id
      });
    }
    
    // Make API request
    const data = await makeGoogleMapsRequest('nearbySearch', {
      location,
      radius,
      type,
      keyword,
      language
    });
    
    // Cache the result
    cache.set('nearby-search', req.query, data);
    
    res.json({
      success: true,
      data,
      cached: false,
      deviceId: req.device.id
    });
    
  } catch (error) {
    console.error('❌ Nearby search error:', error.message);
    res.status(500).json({
      success: false,
      error: error.message,
      endpoint: 'nearby-search'
    });
  }
});

module.exports = router;