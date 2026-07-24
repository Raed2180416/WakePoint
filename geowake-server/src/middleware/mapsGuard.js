// src/middleware/mapsGuard.js
//
// Cost-protection middleware for the Google Maps proxy routes (server-cost-
// security audit finding: bundleId is public, so anyone can mint a JWT via
// POST /api/auth/token and drain the billed Google Maps quota). Three layers:
//
//   - killSwitch: env-driven kill switch (MAPS_PROXY_DISABLED=true) so a
//     runaway bill can be stopped via a Railway config change, no deploy.
//   - familyQuotaGuard(family): a global per-API-family daily request budget,
//     enforced BEFORE any outbound Google Maps call.
//   - perTokenQuotaGuard: a per-device (JWT jti) daily request cap, so a
//     single self-minted token cannot alone exhaust the family budget above.
//
// See utils/quotaTracker.js for the in-memory counter implementation and its
// multi-instance limitation.

const config = require('../config/config');
const quotaTracker = require('../utils/quotaTracker');

const killSwitch = (req, res, next) => {
  if (config.mapsProxyDisabled) {
    return res.status(503).json({
      success: false,
      error: 'Maps proxy is temporarily disabled. Please try again later.'
    });
  }
  next();
};

// One middleware instance per family, built once at route-registration time.
const familyQuotaGuard = (family) => {
  const limit = config.dailyQuotas[family];
  const bucket = `family:${family}`;
  return (req, res, next) => {
    if (!quotaTracker.tryConsume(bucket, limit)) {
      return res.status(429).json({
        success: false,
        error: `Daily request budget for the "${family}" Maps API exceeded. Please try again after the daily reset (00:00 UTC).`,
        family,
        limit
      });
    }
    next();
  };
};

// Must run after authenticateDevice (needs req.device.jti). Tokens minted
// before the jti claim existed have no jti; those share a single fallback
// bucket rather than bypassing the cap entirely.
const perTokenQuotaGuard = (req, res, next) => {
  const jti = (req.device && req.device.jti) || 'legacy-token';
  const limit = config.dailyQuotaPerToken;
  const bucket = `token:${jti}`;
  if (!quotaTracker.tryConsume(bucket, limit)) {
    return res.status(429).json({
      success: false,
      error: 'Daily Maps request limit for this device token exceeded. Please try again after the daily reset (00:00 UTC).',
      limit
    });
  }
  next();
};

module.exports = {
  killSwitch,
  familyQuotaGuard,
  perTokenQuotaGuard
};
