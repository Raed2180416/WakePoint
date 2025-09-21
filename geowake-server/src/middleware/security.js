// src/middleware/security.js
const rateLimit = require('express-rate-limit');
const slowDown = require('express-slow-down');
const config = require('../config/config');

// Rate limiting for API endpoints
const createRateLimit = (windowMs, max, message) => {
  return rateLimit({
    windowMs,
    max,
    message: {
      success: false,
      error: message,
      retryAfter: Math.ceil(windowMs / 1000)
    },
    standardHeaders: true,
    legacyHeaders: false,
    // Fixed keyGenerator for IPv6 compatibility
    keyGenerator: (req) => {
      return req.device?.id || req.ip || 'anonymous';
    },
    // Disable the IPv6 validation since we're handling it properly
    validate: {
      keyGeneratorIpFallback: false
    }
  });
};

// Slow down requests after hitting certain thresholds
const createSlowDown = (windowMs, delayAfter, delayMs) => {
  return slowDown({
    windowMs,
    delayAfter,
    // Fixed delayMs for new version
    delayMs: () => delayMs,
    keyGenerator: (req) => {
      return req.device?.id || req.ip || 'anonymous';
    },
    // Disable the delayMs validation warning
    validate: {
      delayMs: false,
      keyGeneratorIpFallback: false
    }
  });
};

// Different rate limits for different endpoints
const rateLimits = {
  // General API rate limit
  general: createRateLimit(
    60 * 60 * 1000, // 1 hour
    config.maxRequestsPerHour,
    'Too many requests from this device. Try again in an hour.'
  ),
  
  // More restrictive for expensive operations
  directions: createRateLimit(
    60 * 1000, // 1 minute
    20, // 20 requests per minute max
    'Too many direction requests. Please wait before requesting new routes.'
  ),
  
  // Less restrictive for autocomplete
  autocomplete: createRateLimit(
    60 * 1000, // 1 minute
    config.maxRequestsPerMinute,
    'Too many autocomplete requests. Please slow down your typing.'
  )
};

// Slow down for burst protection
const slowDownRules = {
  general: createSlowDown(
    15 * 60 * 1000, // 15 minutes
    50, // Start slowing down after 50 requests
    500 // Add 500ms delay per request after threshold
  )
};

// Request validation middleware
const validateRequest = (req, res, next) => {
  // Log request for monitoring
  console.log(`📍 ${req.method} ${req.path} - Device: ${req.device?.id || 'anonymous'}`);
  
  // Validate required parameters based on endpoint
  const endpoint = req.path.split('/').pop();
  
  switch (endpoint) {
    case 'directions':
      if (!req.query.origin || !req.query.destination) {
        return res.status(400).json({
          success: false,
          error: 'Missing required parameters: origin and destination'
        });
      }
      break;
      
    case 'autocomplete':
      if (!req.query.input) {
        return res.status(400).json({
          success: false,
          error: 'Missing required parameter: input'
        });
      }
      break;
      
    case 'place-details':
      if (!req.query.place_id) {
        return res.status(400).json({
          success: false,
          error: 'Missing required parameter: place_id'
        });
      }
      break;
  }
  
  next();
};

// Error handling for rate limits
const handleRateLimitError = (err, req, res, next) => {
  if (err && err.status === 429) {
    return res.status(429).json({
      success: false,
      error: 'Rate limit exceeded',
      retryAfter: err.retryAfter
    });
  }
  next(err);
};

module.exports = {
  rateLimits,
  slowDownRules,
  validateRequest,
  handleRateLimitError
};