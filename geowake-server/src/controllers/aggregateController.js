// src/controllers/aggregateController.js
//
// GeoWake — aggregate data API controllers.
//
// POST /api/aggregate/ingest  — device uploads ReleaseCandidateMatrix (auth required)
// GET  /api/aggregate/summary — dashboard summary (public, aggregate-only)
// GET  /api/aggregate/flows   — released O-D flow matrix (public, aggregate-only)
// GET  /api/aggregate/catchment — released catchment report (public, aggregate-only)
// GET  /api/aggregate/stats   — raw merge stats for debugging (public, counts only)

const mergeEngine = require('../utils/mergeEngine');

exports.ingest = (req, res) => {
  try {
    const payload = req.body;
    if (!payload || !Array.isArray(payload.cells)) {
      return res.status(400).json({
        success: false,
        error: 'Invalid payload: expected { cells: [...] }',
      });
    }

    const deviceId = req.device?.id || 'unknown';
    mergeEngine.ingest(payload, deviceId);

    return res.json({
      success: true,
      message: 'Candidate matrix ingested',
      cellsReceived: payload.cells.length,
    });
  } catch (err) {
    console.error('ingest error:', err.message);
    return res.status(500).json({
      success: false,
      error: 'Ingestion failed',
    });
  }
};

exports.getSummary = (req, res) => {
  try {
    const summary = mergeEngine.buildDashboardSummary();
    return res.json({ success: true, data: summary });
  } catch (err) {
    console.error('summary error:', err.message);
    return res.status(500).json({
      success: false,
      error: 'Failed to build summary',
    });
  }
};

exports.getFlows = (req, res) => {
  try {
    const matrix = mergeEngine.buildReleasedOdMatrix();
    return res.json({ success: true, data: matrix });
  } catch (err) {
    console.error('flows error:', err.message);
    return res.status(500).json({
      success: false,
      error: 'Failed to build flow matrix',
    });
  }
};

exports.getCatchment = (req, res) => {
  try {
    const report = mergeEngine.buildReleasedCatchment();
    return res.json({ success: true, data: report });
  } catch (err) {
    console.error('catchment error:', err.message);
    return res.status(500).json({
      success: false,
      error: 'Failed to build catchment report',
    });
  }
};

exports.getStats = (req, res) => {
  try {
    const stats = mergeEngine.stats();
    return res.json({ success: true, data: stats });
  } catch (err) {
    console.error('stats error:', err.message);
    return res.status(500).json({
      success: false,
      error: 'Failed to get stats',
    });
  }
};
