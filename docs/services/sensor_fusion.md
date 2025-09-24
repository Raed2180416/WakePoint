# SensorFusionManager (lib/services/sensor_fusion.dart)

Purpose: Emits fused positions during GPS dropouts using accelerometer-based dead reckoning with damping and periodic reset to limit drift.

- Class: line 9 — fields for initial lat/lon, displacement/velocity components, timestamps.
- Config: lines 15–24 — `maxFusionDuration=10s` resets integration; `accelerationDecayFactor=0.9` damping.
- Streams: lines 26–31 — `fusedPositionStream` broadcast controller.
- Ctor: lines 35–44 — initialize with initial position; push initial sample.
- `startFusion()`: line 49 — subscribe to accelerometer; integrate per `dt`; apply decay; compute `dLat/dLon`; emit fused `LatLng`. Reset accumulators when exceeding `maxFusionDuration`.
- `stopFusion()`: line 81 — cancel subscription.
- `reset(initialPosition)`: line 90 — rebase and zero state; emit.
- `dispose()`: lines 98–103 — stop + close stream.

Tests: `sensor_fusion_test.dart`.
