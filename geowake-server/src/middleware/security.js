// src/middleware/security.js
const rateLimit = require('express-rate-limit');
const slowDown = require('express-slow-down');
const config = require('../config/config');

// A function to create a rate limiter with shared options
const createRateLimit = (options) => {
  return rateLimit({
    windowMs: options.windowMs,
    max: options.max,
    standardHeaders: 'draft-7', // Recommended standard for rate limit headers
    legacyHeaders: false, // Disable the old `X-RateLimit-*` headers
    keyGenerator: (req) => req.headers['x-forwarded-for']?.split(',')[0] || req.ip, // Use real IP from proxy
    handler: (req, res, next, options) => {
      res.status(options.statusCode).json({
        success: false,
        error: `Too many requests. Please try again after ${Math.ceil(options.windowMs / 60000)} minutes.`
      });
    },
    ...options
  });
};

// A function to create a speed limiter (slow down) with shared options
const createSlowDown = (options) => {
  return slowDown({
    windowMs: options.windowMs,
    delayAfter: options.delayAfter,
    delayMs: (hits) => hits * 100, // Increase delay by 100ms for every request after the limit
    keyGenerator: (req) => req.headers['x-forwarded-for']?.split(',')[0] || req.ip, // Use real IP from proxy
    ...options
  });
};

// Define specific rules for different parts of the API
const slowDownRules = {
  general: createSlowDown({
    windowMs: 60 * 1000, // 1 minute
    delayAfter: config.maxRequestsPerMinute / 2, // Start delaying after half the requests
  }),
  maps: createSlowDown({
    windowMs: 15 * 60 * 1000,
    delayAfter: 50
  })
};

const rateLimitRules = {
  general: createRateLimit({
    windowMs: 60 * 1000,
    max: config.maxRequestsPerMinute,
  }),
  auth: createRateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 20 // Stricter limit for token generation
  }),
  maps: createRateLimit({
    windowMs: 60 * 60 * 1000, // 1 hour
    max: config.maxRequestsPerHour
  })
};

// Custom error handler for rate limit exceeded errors
const handleRateLimitError = (err, req, res, next) => {
  if (err instanceof rateLimit.RateLimitExceeded) {
    return res.status(429).json({
      success: false,
      error: 'Rate limit exceeded. Please try again later.'
    });
  }
  next(err);
};

module.exports = {
  slowDownRules,
  rateLimitRules, // Ensure this name is consistent
  handleRateLimitError
};
