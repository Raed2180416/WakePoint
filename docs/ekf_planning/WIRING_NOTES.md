# EKF Wiring Notes

**Date:** 2026-01-16

Record exact integration points in the codebase.

## IMU Ingestion
- File: lib/services/sensor_fusion.dart
- Class: SensorFusionManager (deprecated placeholder)
- Timestamp source: Stopwatch-based monotonic timestamps for EKF IMU samples

Notes:
- Accelerometer stream is consumed; gyroscope stream now supported for tests.
- LocationStreamHandler injects test accel/gyro streams when in test mode.
- EKF IMU samples use latest gyro reading alongside accel for tilt filter.

## Sensor Fusion Manager
- File: lib/services/sensor_fusion.dart
- Constructor args: initialPosition (LatLng), accelerometerStream (optional)
- Update entry points: startFusion(), stopFusion(), reset(), fusedPositionStream

Notes:
- EKF snapshot stream available via ekfStateStream (no alarm logic changes yet).

## Tilt Filter
- File: lib/core/ekf/tilt_filter.dart
- Stage A complementary filter (pitch/roll, gravity unit vector, rotation matrix)

## EKF Orchestrator (Tilt + Motion Features)
- File: lib/core/ekf/ekf_orchestrator.dart
- IMU path: TiltFilter → gravity removal → device→world rotation → route tangent projection → EKF `onForwardAccel()`
- Motion features: 2.56s FFT window with 50% overlap + 0.75s variance window; classifier uses FFT only when GPS degraded (and FFT enabled)
- ZUPT uses variance window + motion state; recent ZUPT timestamp retained for classifier bias

## Location Stream Handler
- File: lib/services/tracking/location_stream_handler.dart
- GPS update path: LocationManager.positionStream → _handlePositionUpdate()
- Route update path: ActiveRouteManager.ingestPosition() invoked in _handlePositionUpdate() and _trackMovement()

GPS dropout handling:
- _checkGpsDropout() starts SensorFusionManager after gpsDropoutBuffer
- Sensor fusion is stopped when GPS resumes

Continuous EKF fusion:
- SensorFusionManager is now created on first GPS fix and kept running.
- GPS updates are forwarded to EKF via SensorFusionManager (auto innovation sigma).
- Innovation sigma computed from EKF internal state (raw s, σ_s).

Telemetry:
- TrackingService debug_info includes ekf_motion (MotionState).

Route change handling:
- TrackingService listens to routeSwitchStream and calls LocationStreamHandler.updateRouteGeometryForKey().
- SensorFusionManager resets EKF orchestrator when route geometry updates.

Station association:
- LocationStreamContext provides transitLegStopsByKey + fallback list.
- LocationStreamHandler passes current leg stops to SensorFusionManager.
- SensorFusionManager sets station context on GPS updates; EkfOrchestrator applies station snap on ZUPT confirmed.
- Station snap → ARM gating (§24.2): EkfOrchestrator emits StationSnapConfirmed event when σ≤30m, single candidate, monotonic index. Event flows through SensorFusionManager → LocationStreamHandler → ActiveRouteManager.onStationSnapConfirmed().
- ARM applies additional monotonic gate and emits to stationSnapStream for UI/telemetry.

GPS recovery ordering (§22.13, §29.1):
- GPS updates and station snaps are separate triggers: GPS via onGpsFix(), station snap via ZUPT confirmation on IMU tick.
- They cannot collide in the same tick—GPS is processed immediately on arrival, station snaps are triggered by IMU-driven ZUPT.
- Gating: >5σ = hard reset, 3-5σ = soft reject (inflate covariance only), <3σ = normal Kalman update.

Degraded mode:
- EkfOrchestrator updates DegradedMode each IMU tick and sets EkfMode (surface/metro/degraded).
- EkfPipeline freezes progress in degraded mode while covariance inflates.

ZUPT handling:
- On confirmed ZUPT, EkfOrchestrator resets TiltFilter to reinitialize gravity from accelerometer.

Two-phase init:
- EkfOrchestrator gates IMU prediction until first GPS fix or confirmed ZUPT.
- EkfOrchestrator reports EkfMode.degraded until first GPS fix after reset/route change.

Measurement gating:
- GPS updates hard-reset at >5σ, soft-reject at >3σ (inflate covariance only).
- Bias updates only occur during ZUPT (GPS/station snaps do not update bias).

Motion classification:
- Motion state changes require 2 consecutive windows (2.56s window, 50% overlap = 1.28s step).

Battery policy:
- FFT disabled when battery < 20% by passing `setFftEnabled(false)` to SensorFusionManager → EkfOrchestrator

EKF snapshot wiring:
- Optional onEkfUpdate callback receives EkfPublicState when available.

## Alarm Logic
- File: lib/services/stop_logic_engine.dart
- EKF snapshot usage: none yet; consumes progressMeters from caller

Alarm evaluation snapshot:
- File: lib/services/trackingservice.dart
- Captures EKF snapshot at alarm evaluation tick into `_lastEkfAlarmSnapshot` (telemetry only).
 - Progress selection: uses EKF progress for metro legs or when EKF is degraded (alarm thresholds unchanged).

## Persistence
- File: lib/services/tracking_state_store.dart
- Fields persisted: TrackingSnapshot (destination info, alarm config, userLat/userLng, directions), tracking flags
 - EKF snapshot persistence: ekfS, ekfSigmaS, ekfMode stored with snapshot (telemetry only; no alarm logic changes)

## Logged IMU/GPS Data (for later tests)
- Dataset root: GeoWake IMU  (File responses)/
- CSVs: Accelerometer.csv, Gyroscope.csv, Location.csv, Annotation.csv, Metadata.csv
- Planned wiring: create a test-only replay adapter to emit accel/gyro streams with monotonic timestamps and GPS updates to LocationStreamHandler/SensorFusionManager.
- Use Annotation.csv for station/stop markers if present; otherwise derive from GPS dwell.
