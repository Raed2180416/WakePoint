// src/routes/aggregate.js
//
// GeoWake — aggregate data routes.
//
// Ingest requires device auth; dashboard endpoints are public (aggregate-only,
// no PII, k-anon + DP applied).

const express = require('express');
const {
  ingest,
  getSummary,
  getFlows,
  getCatchment,
  getStats,
} = require('../controllers/aggregateController');
const { authenticateDevice } = require('../middleware/auth');

const router = express.Router();

// Device → server: candidate matrix upload (auth required)
router.post('/ingest', authenticateDevice, ingest);

// Dashboard / buyer-facing: released aggregate data (public)
router.get('/summary', getSummary);
router.get('/flows', getFlows);
router.get('/catchment', getCatchment);
router.get('/stats', getStats);

module.exports = router;
