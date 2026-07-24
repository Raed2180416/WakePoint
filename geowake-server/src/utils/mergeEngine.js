// src/utils/mergeEngine.js
//
// GeoWake — cross-device aggregate merge engine (DATA_SURFACE_SPEC §6).
//
// Receives ReleaseCandidateMatrix payloads from devices, merges counts per
// O-D cell key across devices, tracks contributing users (device IDs), and
// produces released cells via k-anonymity suppression + Laplace DP noise.
//
// In-memory store (no DB dependency). Suitable for single-instance deployment.
// For multi-instance, replace with Redis/Postgres.

const EPSILON = 0.44;
const K_THRESHOLD = 100;
const SENSITIVITY = 1;

class MergeEngine {
  constructor() {
    // cellKey -> { count, deviceIds: Set<string>, hourBin, dayType, origin, dest }
    this._odCells = new Map();
    // stationId|hourBin|dayType -> { count, deviceIds: Set<string> }
    this._catchmentCells = new Map();
    this._deviceCount = new Set();
    this._lastIngestAt = null;
  }

  /**
   * Ingest a ReleaseCandidateMatrix from a device.
   * @param {Object} payload - The candidate matrix JSON
   * @param {string} deviceId - Authenticated device ID
   */
  ingest(payload, deviceId) {
    if (!payload || !Array.isArray(payload.cells)) return;

    this._deviceCount.add(deviceId);
    this._lastIngestAt = new Date().toISOString();

    for (const cell of payload.cells) {
      const keyStr = cell.key;
      if (!keyStr) continue;

      const parsed = this._parseCellKey(keyStr);
      if (!parsed) continue;

      // O-D cell
      const existing = this._odCells.get(keyStr) || {
        count: 0,
        deviceIds: new Set(),
        ...parsed,
      };
      existing.count += cell.candidateNoisyCount || 0;
      if (deviceId) existing.deviceIds.add(deviceId);
      this._odCells.set(keyStr, existing);

      // Catchment cell (destination station arrival)
      const catchKey = `${parsed.dest}|${parsed.hourBin}|${parsed.dayType}`;
      const catchExisting = this._catchmentCells.get(catchKey) || {
        stationId: parsed.dest,
        hourBin: parsed.hourBin,
        dayType: parsed.dayType,
        count: 0,
        deviceIds: new Set(),
      };
      catchExisting.count += 1;
      if (deviceId) catchExisting.deviceIds.add(deviceId);
      this._catchmentCells.set(catchKey, catchExisting);
    }
  }

  /**
   * Build the released O-D flow matrix: k-anon suppress + Laplace noise.
   * Only cells with >= K_THRESHOLD contributing devices are released.
   */
  buildReleasedOdMatrix() {
    const released = [];

    for (const [keyStr, cell] of this._odCells.entries()) {
      const contributingUsers = cell.deviceIds.size;
      if (contributingUsers < K_THRESHOLD) continue; // k-anon suppress

      const noisyCount = this._laplaceNoise(cell.count);
      released.push({
        key: keyStr,
        originStationId: cell.origin,
        destStationId: cell.dest,
        hourBin: cell.hourBin,
        dayType: cell.dayType,
        noisyCount: Math.max(0, noisyCount),
        contributingUsers,
        kSuppressed: true,
        dpApplied: true,
        epsilon: EPSILON,
      });
    }

    return {
      schemaVersion: 'od-v1',
      dpEpsilon: EPSILON,
      kThreshold: K_THRESHOLD,
      dpDisclosure: this._dpDisclosure(),
      totalDevices: this._deviceCount.size,
      totalCells: this._odCells.size,
      releasedCells: released.length,
      lastIngestAt: this._lastIngestAt,
      cells: released,
    };
  }

  /**
   * Build the released catchment report: k-anon suppress + Laplace noise.
   */
  buildReleasedCatchment() {
    const released = [];

    for (const [keyStr, cell] of this._catchmentCells.entries()) {
      const contributingUsers = cell.deviceIds.size;
      if (contributingUsers < K_THRESHOLD) continue;

      const noisyCount = this._laplaceNoise(cell.count);
      released.push({
        stationId: cell.stationId,
        hourBin: cell.hourBin,
        dayType: cell.dayType,
        noisyCount: Math.max(0, noisyCount),
        contributingUsers,
      });
    }

    return {
      schemaVersion: 'od-v1',
      dpEpsilon: EPSILON,
      kThreshold: K_THRESHOLD,
      cells: released,
    };
  }

  /**
   * Build a summary dashboard view: top flows, demand by hour, trends.
   */
  buildDashboardSummary() {
    const odMatrix = this.buildReleasedOdMatrix();
    const catchment = this.buildReleasedCatchment();

    // Top O-D flows by noisyCount
    const topFlows = [...odMatrix.cells]
      .sort((a, b) => b.noisyCount - a.noisyCount)
      .slice(0, 50);

    // Demand by hour (aggregate across all released cells)
    const hourlyDemand = new Array(24).fill(0);
    for (const cell of odMatrix.cells) {
      hourlyDemand[cell.hourBin] += cell.noisyCount;
    }

    // Demand by day type
    const weekdayDemand = odMatrix.cells
      .filter((c) => c.dayType === 'weekday')
      .reduce((sum, c) => sum + c.noisyCount, 0);
    const weekendDemand = odMatrix.cells
      .filter((c) => c.dayType === 'weekend')
      .reduce((sum, c) => sum + c.noisyCount, 0);

    // Top stations by catchment
    const stationCatchment = new Map();
    for (const cell of catchment.cells) {
      const existing = stationCatchment.get(cell.stationId) || 0;
      stationCatchment.set(cell.stationId, existing + cell.noisyCount);
    }
    const topStations = [...stationCatchment.entries()]
      .map(([stationId, total]) => ({ stationId, totalArrivals: total }))
      .sort((a, b) => b.totalArrivals - a.totalArrivals)
      .slice(0, 50);

    // Unique origin/destination stations in released data
    const origins = new Set(odMatrix.cells.map((c) => c.originStationId));
    const destinations = new Set(odMatrix.cells.map((c) => c.destStationId));

    return {
      overview: {
        totalDevices: this._deviceCount.size,
        totalOdCells: this._odCells.size,
        releasedOdCells: odMatrix.releasedCells,
        releasedCatchmentCells: catchment.cells.length,
        weekdayDemand,
        weekendDemand,
        uniqueOriginStations: origins.size,
        uniqueDestStations: destinations.size,
        lastIngestAt: this._lastIngestAt,
      },
      privacy: this._dpDisclosure(),
      hourlyDemand: hourlyDemand.map((count, hour) => ({ hour, count })),
      topFlows,
      topStations,
      flows: odMatrix.cells,
      catchment: catchment.cells,
    };
  }

  /**
   * Get raw stats for debugging (no PII — just counts).
   */
  stats() {
    return {
      totalDevices: this._deviceCount.size,
      totalOdCells: this._odCells.size,
      totalCatchmentCells: this._catchmentCells.size,
      lastIngestAt: this._lastIngestAt,
      kThreshold: K_THRESHOLD,
      epsilon: EPSILON,
    };
  }

  _parseCellKey(keyStr) {
    // Format: origin>dest|hourBin|dayType
    const barParts = keyStr.split('|');
    if (barParts.length !== 3) return null;
    const od = barParts[0].split('>');
    if (od.length !== 2) return null;
    const hourBin = parseInt(barParts[1], 10);
    if (isNaN(hourBin) || hourBin < 0 || hourBin > 23) return null;
    return {
      origin: od[0],
      dest: od[1],
      hourBin,
      dayType: barParts[2],
    };
  }

  _laplaceNoise(trueCount) {
    const scale = SENSITIVITY / EPSILON;
    const u = Math.random() - 0.5;
    const sign = u < 0 ? -1 : 1;
    const mag = 1 - 2 * Math.abs(u);
    const safeMag = mag <= 0 ? 1e-12 : mag;
    const noise = -scale * sign * Math.log(safeMag);
    return Math.round(trueCount + noise);
  }

  _dpDisclosure() {
    return {
      mechanism: 'laplace',
      model: 'central',
      epsilonPerCell: EPSILON,
      sensitivity: SENSITIVITY,
      kAnonymityThreshold: K_THRESHOLD,
      noiseAppliedAt: 'merge',
    };
  }
}

// Singleton
const mergeEngine = new MergeEngine();

module.exports = mergeEngine;
