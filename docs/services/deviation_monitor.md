# DeviationMonitor (lib/services/deviation_monitor.dart)

Purpose: Consumes offset/speed samples and emits deviation states with sustain timing.

- Types: lines 3–17 — `DeviationState` fields; `SpeedThresholdModel` with dynamic high/low thresholds and hysteresis ratio.
- Class: line 29 — sustain window (`sustainDuration`, default 5s) and threshold model.
- Stream: line 33 — broadcast of `DeviationState`.
- `ingest(offsetMeters, speedMps, at?)`: lines 45–79 —
	- If not offroute and offset > T_high(speed) → mark deviating and start timer.
	- If offroute and offset < T_low(speed) → clear deviation; else if duration >= sustain → mark sustained.
	- Always emit current state.
- `reset()`: line 81 — clears flags/timers.
- `dispose()`: line 86 — closes stream.

Used by TrackingService to drive `ReroutePolicy` and UI diagnostics.
