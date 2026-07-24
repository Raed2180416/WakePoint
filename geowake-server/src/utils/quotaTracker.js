// src/utils/quotaTracker.js
//
// In-memory daily request counters backing the cost-protection guards in
// middleware/mapsGuard.js (global per-API-family budgets and per-token/jti
// caps — see the server-cost-security audit finding these were added for).
// Counts reset automatically the first time a bucket is touched after the
// UTC calendar date rolls over.
//
// LIMITATION: this state lives in a single Node process's memory. If
// geowake-server is ever scaled to multiple instances (Railway replicas,
// etc.), each instance tracks its own counters independently, so the
// effective global budget becomes (perInstanceLimit * instanceCount), not a
// true global cap. For a real cross-instance cap this needs shared storage
// (Redis, a DB row, etc.) instead of an in-process Map. Documented here
// deliberately — do not assume this bounds spend across a horizontally
// scaled deployment.

class QuotaTracker {
  constructor() {
    this._counts = new Map(); // bucket string -> count for the current UTC date
    this._dateKey = this._utcDateKey();
  }

  _utcDateKey() {
    return new Date().toISOString().slice(0, 10); // YYYY-MM-DD in UTC
  }

  _rollIfNeeded() {
    const today = this._utcDateKey();
    if (today !== this._dateKey) {
      this._counts.clear();
      this._dateKey = today;
    }
  }

  /** Current count for a bucket today (UTC), without consuming from it. */
  get(bucket) {
    this._rollIfNeeded();
    return this._counts.get(bucket) || 0;
  }

  /**
   * Attempts to consume one unit of `bucket`'s daily budget.
   * Returns true (and increments) if still under `limit`; returns false
   * (no increment) once the bucket has reached `limit` for the current UTC day.
   */
  tryConsume(bucket, limit) {
    this._rollIfNeeded();
    const current = this._counts.get(bucket) || 0;
    if (current >= limit) {
      return false;
    }
    this._counts.set(bucket, current + 1);
    return true;
  }

  /** Test/debug helper: wipe all counters and re-anchor to "today" immediately. */
  resetAll() {
    this._counts.clear();
    this._dateKey = this._utcDateKey();
  }
}

// Export singleton instance (mirrors utils/cache.js's pattern).
module.exports = new QuotaTracker();
