// src/routes/auth.js
const express = require('express');
const { generateDeviceToken } = require('../middleware/auth');
const config = require('../config/config');

const router = express.Router();

// Register a new device and get JWT token
router.post('/register-device', async (req, res) => {
  try {
    const { deviceId, appVersion, bundleId } = req.body;
    
    // Validate required fields
    if (!deviceId) {
      return res.status(400).json({
        success: false,
        error: 'Device ID is required'
      });
    }
    
    // Validate bundle ID matches expected
    if (bundleId && bundleId !== config.appBundleId) {
      return res.status(403).json({
        success: false,
        error: 'Invalid app credentials'
      });
    }
    
    // Generate JWT token
    const token = generateDeviceToken(deviceId, appVersion || '1.0.0');
    
    console.log(`✅ Device registered: ${deviceId} (v${appVersion || '1.0.0'})`);
    
    res.json({
      success: true,
      token,
      deviceId,
      expiresIn: config.jwtExpiration,
      serverVersion: '1.0.0'
    });
    
  } catch (error) {
    console.error('❌ Device registration error:', error.message);
    res.status(500).json({
      success: false,
      error: 'Registration failed'
    });
  }
});

// Refresh an existing token
router.post('/refresh-token', async (req, res) => {
  try {
    const { deviceId, appVersion } = req.body;
    
    if (!deviceId) {
      return res.status(400).json({
        success: false,
        error: 'Device ID is required for token refresh'
      });
    }
    
    // Generate new token
    const token = generateDeviceToken(deviceId, appVersion || '1.0.0');
    
    console.log(`🔄 Token refreshed for device: ${deviceId}`);
    
    res.json({
      success: true,
      token,
      deviceId,
      expiresIn: config.jwtExpiration,
      serverVersion: '1.0.0'
    });
    
  } catch (error) {
    console.error('❌ Token refresh error:', error.message);
    res.status(500).json({
      success: false,
      error: 'Token refresh failed'
    });
  }
});

// Health check endpoint (no auth required)
router.get('/health', (req, res) => {
  res.json({
    success: true,
    status: 'healthy',
    serverTime: new Date().toISOString(),
    environment: config.nodeEnv,
    version: '1.0.0'
  });
});

module.exports = router;