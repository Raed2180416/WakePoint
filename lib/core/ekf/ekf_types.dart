// Public EKF types (v1 API skeleton).

enum EkfMode { surface, metro, degraded }

enum MotionState { human, vehicle, stationary }

class EkfPublicState {
  final double s; // progress meters (monotonic public)
  final double v; // velocity m/s
  final double sigmaS; // position std dev meters
  final double sigmaV; // velocity std dev m/s
  final double biasA; // accel bias m/s^2
  final EkfMode mode;
  final MotionState motion;

  const EkfPublicState({
    required this.s,
    required this.v,
    required this.sigmaS,
    required this.sigmaV,
    required this.biasA,
    required this.mode,
    required this.motion,
  });
}

class ImuSample {
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final Duration timestamp;

  const ImuSample({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.timestamp,
  });
}

/// Gravity sensor sample (Android TYPE_GRAVITY).
/// Pre-filtered gravity vector in device frame, m/s².
/// More reliable than raw accelerometer during motion.
class GravitySample {
  final double x;
  final double y;
  final double z;
  final Duration timestamp;

  const GravitySample({
    required this.x,
    required this.y,
    required this.z,
    required this.timestamp,
  });
}

/// Orientation sensor sample (Android TYPE_ORIENTATION).
/// Device orientation relative to Earth frame.
class OrientationSample {
  final double azimuth; // Compass heading (degrees, 0=North)
  final double pitch; // Device tilt forward/back (degrees)
  final double roll; // Device tilt left/right (degrees)
  final Duration timestamp;

  const OrientationSample({
    required this.azimuth,
    required this.pitch,
    required this.roll,
    required this.timestamp,
  });
}

class GpsFix {
  final double lat;
  final double lng;
  final double accuracyMeters;
  final double speedMps;
  final Duration timestamp;

  const GpsFix({
    required this.lat,
    required this.lng,
    required this.accuracyMeters,
    required this.speedMps,
    required this.timestamp,
  });
}

class StationCandidate {
  final double sStation;
  const StationCandidate(this.sStation);
}

/// Event emitted when a station snap is confirmed with high confidence.
/// Per §24.2: Only emitted when σ ≤ 30m, single candidate, monotonic index.
class StationSnapConfirmed {
  final int stationIndex;
  final double stationMeters;
  final double sigmaS;
  final DateTime timestamp;

  const StationSnapConfirmed({
    required this.stationIndex,
    required this.stationMeters,
    required this.sigmaS,
    required this.timestamp,
  });
}

class EkfConfig {
  const EkfConfig({
    this.sigmaAccel = 0.15,
    this.sigmaBias = 0.001,
    this.gpsFloorVar = 625.0,
    this.gpsSpeedVar = 1.0, // (1.0 m/s)^2 speed measurement variance
    this.zuptVar = 0.0025, // (0.05 m/s)^2
    this.stationVar = 100.0, // (10 m)^2
    this.minDt = 0.001,
    this.maxDt = 0.2,
    this.sigmaSFloor = 5.0,
    this.sigmaVFloor = 0.1,
    this.sigmaBiasFloor = 1e-4,
    this.biasLimit = 0.5,
    this.softGateSigma = 3.0,
    this.hardGateSigma = 5.0,
    this.stationSnapSigmaGate = 30.0,
  });

  final double sigmaAccel;
  final double sigmaBias;
  final double gpsFloorVar;
  final double gpsSpeedVar;
  final double zuptVar;
  final double stationVar;
  final double minDt;
  final double maxDt;
  final double sigmaSFloor;
  final double sigmaVFloor;
  final double sigmaBiasFloor;
  final double biasLimit;
  final double softGateSigma;
  final double hardGateSigma;
  final double stationSnapSigmaGate;
}
