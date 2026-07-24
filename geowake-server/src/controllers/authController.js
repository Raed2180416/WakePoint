const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const config = require('../config/config');

/**
 * Generates a JWT for a device that provides a valid bundle ID.
 * This is a simple way to verify that the request is likely coming from your app.
 *
 * NOTE (server-cost-security): bundleId is NOT a secret — it's the public Play
 * Store package id, also visible in android/app/build.gradle. This endpoint
 * alone cannot stop an outsider from minting a valid token; it is only one
 * layer of the cost-protection stack (see middleware/mapsGuard.js for the
 * daily-quota/kill-switch layers and middleware/security.js for the tightened
 * per-IP issuance rate limit). Real device attestation (e.g. Play Integrity
 * API) would close this gap properly but is a larger, separate fast-follow.
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

    // A random per-token jti gives every issued token its own identity, so
    // middleware/mapsGuard.js can rate-limit Maps requests PER TOKEN (not just
    // per IP) — minting a fresh token doesn't reset the caller's quota, since
    // each token's own jti bucket only reflects that token's own usage.
    const token = jwt.sign(payload, config.jwtSecret, {
      expiresIn: config.jwtExpiration,
      jwtid: crypto.randomUUID()
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