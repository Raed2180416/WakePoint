# Performance & Battery Bottlenecks

## What this file covers

- Hot loops (location stream handlers, timers)
- Heavy computations (route snap, polylines, ETA)
- Excess allocations / repeated parsing
- Excess I/O and logging
- UI jank risks (maps, rebuild storms)
- Battery drain risks

## Required fields per bottleneck

- **Severity**: STOP_SHIP | HIGH | MEDIUM | LOW
- **Evidence**: (file + symbol + why it’s hot)
- **Why it’s a bottleneck**:
- **How to measure**: (specific profiler/log counters)
- **Fix**: (concrete)
- **Confidence**:

## Bottlenecks list

### Alarm-action polling timer (200ms)

- **Severity**: MEDIUM
- **Evidence**: `lib/services/tracking/alarm_controller.dart` `startAlarmStopPollTimer()` (200ms periodic timer)
- **Why it’s a bottleneck**: Forces frequent wakeups/CPU work while alarm-active; can amplify battery drain especially if combined with other periodic work.
- **How to measure**: Android Studio profiler (CPU wakeups), log timer ticks count per minute during alarm-active.
- **Fix**: Gate timer strictly to alarm-visible state; stop immediately on stop/end; add exponential backoff when no flags present.
- **Confidence**: HIGH

### Foreground → background heartbeat (1s)

- **Severity**: LOW
- **Evidence**: `lib/services/tracking/foreground_bridge.dart` `startHeartbeat()` uses `Timer.periodic(const Duration(seconds: 1), ...)`
- **Why it’s a bottleneck**: Adds a steady periodic workload while service runs (even when user not interacting).
- **How to measure**: Count heartbeat invokes per hour; measure CPU wakeups with/without heartbeat.
- **Fix**: Reduce frequency when stable (e.g., 5–15s), or use event-based liveness (only when needed for watchdog behavior).
- **Confidence**: CERTAIN

### Directions processing (polyline decode + simplify + metro route scanning)

- **Severity**: MEDIUM
- **Evidence**: `lib/services/direction_service.dart` `getDirections(...)` contains per-route scanning for metro legs and per-request decode/simplify with caching
- **Why it’s a bottleneck**: JSON parsing, polyline decoding, simplification, and route scanning can be expensive when refetching frequently (near interval ~3 minutes).
- **How to measure**: Add timers around decode/simplify; use Dart DevTools CPU profiler during repeated direction refresh.
- **Fix**: Persist simplified polylines in RouteCache; cap routes processed; avoid repeated JSON traversal by normalizing once.
- **Confidence**: MEDIUM

### Snapshot encoding/minimization during startup and background refresh

- **Severity**: LOW
- **Evidence**: `lib/services/tracking_state_store.dart` `saveSnapshot()` uses `compute(_encodeSnapshotInBackground, json)` which also minimizes `directions` payload.
- **Why it’s a bottleneck**: JSON minimization + encoding can be heavy for large directions payloads; it also risks failure if payload is still too large.
- **How to measure**: Add timing logs around `saveSnapshot()` calls; measure startup time contributions (already logging `[StartupPerf] Heavy Snapshot Saved` in HomeScreen).
- **Fix**: Persist only minimal route representation required for restore/alarm context (IDs + polylines + essential steps), keep full directions in a separate store if needed.
- **Confidence**: HIGH

### RouteCache JSON decode + TTL/origin checks on reads

- **Severity**: LOW
- **Evidence**: `lib/services/route_cache.dart` `RouteCache.get()` decodes JSON, parses timestamp, computes deviation distance and may evict.
- **Why it’s a bottleneck**: Small per-read overhead; becomes noticeable only if called frequently (e.g., aggressive reroute refresh).
- **How to measure**: Count cache reads and measure time per call; profile in reroute-heavy scenarios.
- **Fix**: Keep a small in-memory LRU for recent entries; avoid repeated JSON decode when reusing same key.
- **Confidence**: HIGH
