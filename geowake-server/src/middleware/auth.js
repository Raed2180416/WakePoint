// src/middleware/auth.js
const jwt = require('jsonwebtoken');
const config = require('../config/config');

// Simple device-based authentication
// In production, you'd want more sophisticated user management
const authenticateDevice = (req, res, next) => {
  const authHeader = req.headers.authorization;
  
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({
      success: false,
      error: 'No token provided. Include Bearer token in Authorization header.'
    });
  }
  
  const token = authHeader.substring(7);
  
  try {
    const decoded = jwt.verify(token, config.jwtSecret);
    
    // Validate app bundle ID for additional security
    if (decoded.bundleId !== config.appBundleId) {
      return res.status(403).json({
        success: false,
        error: 'Invalid app credentials'
      });
    }
    
    req.device = {
      id: decoded.deviceId,
      bundleId: decoded.bundleId,
      appVersion: decoded.appVersion
    };
    
    next();
  } catch (error) {
    if (error.name === 'TokenExpiredError') {
      return res.status(401).json({
        success: false,
        error: 'Token expired. Please refresh.'
      });
    }
    
    if (error.name === 'JsonWebTokenError') {
      return res.status(401).json({
        success: false,
        error: 'Invalid token format.'
      });
    }
    
    return res.status(500).json({
      success: false,
      error: 'Authentication error'
    });
  }
};

// Generate a device token (call this from your app on first launch)
const generateDeviceToken = (deviceId, appVersion = '1.0.0') => {
  return jwt.sign(
    {
      deviceId,
      bundleId: config.appBundleId,
      appVersion,
      iat: Math.floor(Date.now() / 1000)
    },
    config.jwtSecret,
    { expiresIn: config.jwtExpiration }
  );
};

module.exports = {
  authenticateDevice,
  generateDeviceToken
};