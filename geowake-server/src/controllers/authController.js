const jwt = require('jsonwebtoken');
const config = require('../config/config');

/**
 * Generates a JWT for a device that provides a valid bundle ID.
 * This is a simple way to verify that the request is likely coming from your app.
 */
const generateToken = (req, res) => {
  const { bundleId } = req.body;

  // Validate that the bundle ID from the app matches the one in our config
  if (!bundleId || bundleId !== config.appBundleId) {
    return res.status(401).json({
      success: false,
      error: 'Unauthorized: Invalid application identifier.'
    });
  }

  try {
    // If valid, sign a new JWT token
    const payload = {
      bundleId: bundleId,
      iss: 'GeoWake-Server' // Issuer
    };

    const token = jwt.sign(payload, config.jwtSecret, {
      expiresIn: config.jwtExpiration
    });

    res.json({
      success: true,
      message: 'Token generated successfully.',
      token: token,
      expiresIn: config.jwtExpiration
    });

  } catch (error) {
    console.error('❌ Error generating JWT token:', error);
    res.status(500).json({
      success: false,
      error: 'Failed to generate authentication token.'
    });
  }
};

module.exports = {
  generateToken
};