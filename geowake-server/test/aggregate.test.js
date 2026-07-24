// geowake-server/test/aggregate.test.js
//
// Tests for the aggregate merge engine and API endpoints.

const request = require('supertest');
const express = require('express');
const mergeEngine = require('../src/utils/mergeEngine');

// Reset the singleton between tests
beforeEach(() => {
  mergeEngine._odCells.clear();
  mergeEngine._catchmentCells.clear();
  mergeEngine._deviceCount.clear();
  mergeEngine._lastIngestAt = null;
});

describe('MergeEngine', () => {
  test('ingests candidate cells and tracks device IDs', () => {
    const payload = {
      schemaVersion: 'od-v1',
      candidate: true,
      dpEpsilon: 0.44,
      kThreshold: 100,
      cells: [
        {
          key: 'OSM_123>OSM_456|8|weekday',
          candidateNoisyCount: 1,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        },
        {
          key: 'OSM_123>OSM_789|9|weekday',
          candidateNoisyCount: 1,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        },
      ],
    };

    mergeEngine.ingest(payload, 'device-A');
    mergeEngine.ingest(payload, 'device-B');

    const stats = mergeEngine.stats();
    expect(stats.totalDevices).toBe(2);
    expect(stats.totalOdCells).toBe(2);
  });

  test('suppresses cells below k-anonymity threshold', () => {
    const payload = {
      cells: [
        {
          key: 'OSM_1>OSM_2|8|weekday',
          candidateNoisyCount: 5,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        },
      ],
    };

    // Only 3 devices — below k=100
    mergeEngine.ingest(payload, 'd1');
    mergeEngine.ingest(payload, 'd2');
    mergeEngine.ingest(payload, 'd3');

    const matrix = mergeEngine.buildReleasedOdMatrix();
    expect(matrix.cells.length).toBe(0); // all suppressed
  });

  test('releases cells at or above k-anonymity threshold', () => {
    const payload = {
      cells: [
        {
          key: 'OSM_1>OSM_2|8|weekday',
          candidateNoisyCount: 1,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        },
      ],
    };

    // Add 100 devices
    for (let i = 0; i < 100; i++) {
      mergeEngine.ingest(payload, `device-${i}`);
    }

    const matrix = mergeEngine.buildReleasedOdMatrix();
    expect(matrix.cells.length).toBe(1);
    expect(matrix.cells[0].kSuppressed).toBe(true);
    expect(matrix.cells[0].dpApplied).toBe(true);
    expect(matrix.cells[0].contributingUsers).toBe(100);
    expect(matrix.cells[0].noisyCount).toBeGreaterThanOrEqual(0);
  });

  test('buildDashboardSummary returns structured overview', () => {
    const payload = {
      cells: [
        {
          key: 'OSM_1>OSM_2|8|weekday',
          candidateNoisyCount: 3,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        },
      ],
    };

    for (let i = 0; i < 100; i++) {
      mergeEngine.ingest(payload, `device-${i}`);
    }

    const summary = mergeEngine.buildDashboardSummary();
    expect(summary.overview).toBeDefined();
    expect(summary.overview.totalDevices).toBe(100);
    expect(summary.overview.releasedOdCells).toBe(1);
    expect(summary.hourlyDemand).toHaveLength(24);
    expect(summary.topFlows).toBeDefined();
    expect(summary.privacy).toBeDefined();
    expect(summary.privacy.mechanism).toBe('laplace');
  });

  test('catchment cells are tracked separately', () => {
    const payload = {
      cells: [
        {
          key: 'OSM_1>OSM_2|8|weekday',
          candidateNoisyCount: 1,
          localContributingUsers: 1,
          dpApplied: true,
          epsilon: 0.44,
        },
      ],
    };

    for (let i = 0; i < 100; i++) {
      mergeEngine.ingest(payload, `device-${i}`);
    }

    const catchment = mergeEngine.buildReleasedCatchment();
    expect(catchment.cells.length).toBe(1);
    expect(catchment.cells[0].stationId).toBe('OSM_2');
  });
});
