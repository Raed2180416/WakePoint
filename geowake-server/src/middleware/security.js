// src/middleware/security.js
const rateLimit = require('express-rate-limit');
const slowDown = require('express-slow-down');
const config = require('../config/config');

// ================================
// RATE LIMITER
// ================================
const createRateLimit = (options) => {
  return rateLimit({
    windowMs: options.windowMs,
    max: options.max,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    keyGenerator: (req) => req.headers['x-forwarded-for']?.split(',')[0] || req.ip,
    handler: (req, res, next, options) => {
      res.status(options.statusCode).json({
        success: false,
        error: `Too many requests. Please try again after ${Math.ceil(options.windowMs / 60000)} minutes.`
      });
    },
    ...options
  });
};

// ================================
// SLOW DOWN
// ================================
const createSlowDown = (options) => {
  return slowDown({
    windowMs: options.windowMs,
    delayAfter: options.delayAfter,
    delayMs: (hits) => hits * 100, // Increase delay by 100ms for every request after the limit
    keyGenerator: (req) => req.headers['x-forwarded-for']?.split(',')[0] || req.ip,
    ...options
  });
};


// ================================
// RULES
// ================================
const slowDownRules = {
  general: createSlowDown({
    windowMs: 60 * 1000, // 1 minute
    delayAfter: config.maxRequestsPerMinute / 2, // Start delaying after half the requests
  }),
  maps: createSlowDown({
    windowMs: 15 * 60 * 1000, // 15 minutes
    delayAfter: 50
  })
};

const rateLimitRules = {
  general: createRateLimit({
    windowMs: 60 * 1000,
    max: config.maxRequestsPerMinute,
  }),
  auth: createRateLimit({
    windowMs: 15 * 60 * 1000,
    max: 20
  }),
  maps: createRateLimit({
    windowMs: 60 * 60 * 1000,
    max: config.maxRequestsPerHour
  })
};


// ================================
// ERROR HANDLER
// ================================
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
  rateLimitRules,
  handleRateLimitError
};
