// EKF pipeline API (v1 core).

import 'ekf_types.dart';
import 'route_geometry.dart';
import 'dart:math' as math;

class EkfPipeline {
  EkfPipeline({
    required EkfConfig config,
    required RouteGeometry route,
  })  : _config = config,
        _route = route;

  final EkfConfig _config;
  final RouteGeometry _route;

  bool _initialized = false;
  EkfMode _mode = EkfMode.surface;
  MotionState _motion = MotionState.vehicle;

  double _s = double.nan;
  double _v = double.nan;
  double _b = 0.0;
  double _sPub = double.nan;

  List<List<double>> _p = _zeros3();
  Duration? _lastImuTs;

  EkfPublicState get publicState => EkfPublicState(
    s: _sPub.isNaN ? (_s.isNaN ? 0.0 : _s) : _sPub,
    v: _v.isNaN ? 0.0 : _v,
    sigmaS: _sigmaS(),
    sigmaV: _sigmaV(),
    biasA: _b,
    mode: _mode,
    motion: _motion,
  );

  double innovationSigmaForS(double sGps) {
    if (_s.isNaN) return 0.0;
    final sigmaS = _sigmaS();
    if (sigmaS <= 0) return 0.0;
    final nu = sGps - _s;
    return nu.abs() / sigmaS;
  }

  void setMode(EkfMode mode) {
    _mode = mode;
  }

  void setMotionState(MotionState motion) {
    _motion = motion;
  }

  void onImuSample(ImuSample sample) {
    onForwardAccel(sample.timestamp, sample.ax);
  }

  void onForwardAccel(Duration timestamp, double aFwd) {
    if (!_initialized) return;
    if (_lastImuTs == null) {
      _lastImuTs = timestamp;
      return;
    }

    final dt = (timestamp - _lastImuTs!).inMicroseconds / 1e6;
    _lastImuTs = timestamp;

    if (dt < _config.minDt || dt > _config.maxDt) {
      _inflateCovariance(1.1);
      return;
    }

    if (_mode == EkfMode.degraded) {
      _v = 0.0;
      _inflateCovariance(1.02);
      _applyCovarianceFloors();
      _updatePublicProgress();
      return;
    }

    final dt2 = dt * dt;
    _s = _s + _v * dt + 0.5 * (aFwd - _b) * dt2;
    _v = _v + (aFwd - _b) * dt;

    final f = [
      [1.0, dt, -0.5 * dt2],
      [0.0, 1.0, -dt],
      [0.0, 0.0, 1.0],
    ];

    final q = [
      [_config.sigmaAccel * _config.sigmaAccel * dt2 * dt2 / 4, 0.0, 0.0],
      [0.0, _config.sigmaAccel * _config.sigmaAccel * dt2, 0.0],
      [0.0, 0.0, _config.sigmaBias * _config.sigmaBias * dt],
    ];

    _p = _add3(_mul3(_mul3(f, _p), _transpose3(f)), q);

    _applyStateBounds();
    _applyCovarianceFloors();
    _updatePublicProgress();
  }

  /// Handle GPS fix with innovation gating per §22.13 and §29.1:
  /// - |nu| > 5σ → hard reset (reinitialize EKF from GPS)
  /// - 3σ < |nu| ≤ 5σ → soft reject (inflate covariance, preserve state)
  /// - |nu| ≤ 3σ → normal Kalman update
  ///
  /// Note: GPS updates and station snaps are separate triggers:
  /// GPS updates happen immediately on fix; station snaps happen on ZUPT
  /// confirmation (via IMU tick). They cannot collide in the same tick.
  void onGpsFix(GpsFix fix) {
    final sGps = _route.projectLatLng(fix.lat, fix.lng);
    if (sGps.isNaN) return;

    if (!_initialized) {
      _initializeFromGps(sGps, fix.speedMps);
      return;
    }

    final sigmaS = _sigmaS();
    final nu = sGps - _s;
    if (sigmaS > 0 && nu.abs() > _config.hardGateSigma * sigmaS) {
      _initializeFromGps(sGps, fix.speedMps);
      return;
    }
    if (sigmaS > 0 && nu.abs() > _config.softGateSigma * sigmaS) {
      _inflateCovariance(1.1);
      return;
    }

    final r = math.max(fix.accuracyMeters * fix.accuracyMeters, _config.gpsFloorVar);
    final s = _p[0][0] + r;
    if (s <= 0) return;

    final k0 = _p[0][0] / s;
    final k1 = _p[1][0] / s;
    // k2 = 0: Bias observable only during ZUPT (bias update intentionally suppressed)

    _s = _s + k0 * nu;
    _v = _v + k1 * nu;

    final p00 = _p[0][0];
    final p01 = _p[0][1];
    final p02 = _p[0][2];

    _p[0][0] = _p[0][0] - k0 * p00;
    _p[0][1] = _p[0][1] - k0 * p01;
    _p[0][2] = _p[0][2] - k0 * p02;

    _p[1][0] = _p[1][0] - k1 * p00;
    _p[1][1] = _p[1][1] - k1 * p01;
    _p[1][2] = _p[1][2] - k1 * p02;

    // Bias covariance update intentionally suppressed (k2 = 0).

    _applyStateBounds();
    _applyCovarianceFloors();
    _updatePublicProgress();
  }

  void onZuptConfirmed() {
    if (!_initialized) return;

    final r = _config.zuptVar;
    final s = _p[1][1] + r;
    if (s <= 0) return;

    final nu = 0.0 - _v;
    final k0 = _p[0][1] / s;
    final k1 = _p[1][1] / s;
    final k2 = _p[2][1] / s;

    _s = _s + k0 * nu;
    _v = _v + k1 * nu;
    _b = _b + k2 * nu;

    final p10 = _p[1][0];
    final p11 = _p[1][1];
    final p12 = _p[1][2];

    _p[0][0] = _p[0][0] - k0 * p10;
    _p[0][1] = _p[0][1] - k0 * p11;
    _p[0][2] = _p[0][2] - k0 * p12;

    _p[1][0] = _p[1][0] - k1 * p10;
    _p[1][1] = _p[1][1] - k1 * p11;
    _p[1][2] = _p[1][2] - k1 * p12;

    _p[2][0] = _p[2][0] - k2 * p10;
    _p[2][1] = _p[2][1] - k2 * p11;
    _p[2][2] = _p[2][2] - k2 * p12;

    _applyStateBounds();
    _applyCovarianceFloors();
    _updatePublicProgress();
  }

  void onStationCandidates(List<StationCandidate> candidates) {
    if (!_initialized) return;
    if (candidates.length != 1) return;

    final sStation = candidates.first.sStation;
    final r = _config.stationVar;
    final s = _p[0][0] + r;
    if (s <= 0) return;

    final nu = sStation - _s;
    final k0 = _p[0][0] / s;
    final k1 = _p[1][0] / s;
    // k2 = 0: Bias observable only during ZUPT (bias update intentionally suppressed)

    _s = _s + k0 * nu;
    _v = _v + k1 * nu;

    final p00 = _p[0][0];
    final p01 = _p[0][1];
    final p02 = _p[0][2];

    _p[0][0] = _p[0][0] - k0 * p00;
    _p[0][1] = _p[0][1] - k0 * p01;
    _p[0][2] = _p[0][2] - k0 * p02;

    _p[1][0] = _p[1][0] - k1 * p00;
    _p[1][1] = _p[1][1] - k1 * p01;
    _p[1][2] = _p[1][2] - k1 * p02;

    // Bias covariance update intentionally suppressed (k2 = 0).

    _applyStateBounds();
    _applyCovarianceFloors();
    _updatePublicProgress();
  }

  void _initializeFromGps(double sGps, double vGps) {
    _s = sGps;
    _v = math.max(0.0, vGps);
    _b = 0.0;
    _p = [
      [25.0 * 25.0, 0.0, 0.0],
      [0.0, 5.0 * 5.0, 0.0],
      [0.0, 0.0, 0.1 * 0.1],
    ];
    _initialized = true;
    _applyStateBounds();
    _applyCovarianceFloors();
    _updatePublicProgress();
  }

  void _applyStateBounds() {
    if (_b.abs() > _config.biasLimit) {
      _b = _b.clamp(-_config.biasLimit, _config.biasLimit);
    }
  }

  void _applyCovarianceFloors() {
    _p[0][0] = math.max(_p[0][0], _config.sigmaSFloor * _config.sigmaSFloor);
    _p[1][1] = math.max(_p[1][1], _config.sigmaVFloor * _config.sigmaVFloor);
    _p[2][2] = math.max(_p[2][2], _config.sigmaBiasFloor);
  }

  void _inflateCovariance(double factor) {
    _p[0][0] *= factor;
    _p[1][1] *= factor;
    _p[2][2] *= factor;
  }

  double _sigmaS() => math.sqrt(_p[0][0].abs());
  double _sigmaV() => math.sqrt(_p[1][1].abs());

  void _updatePublicProgress() {
    if (_s.isNaN) return;
    if (_sPub.isNaN) {
      _sPub = _s;
    } else {
      _sPub = math.max(_sPub, _s);
    }
  }

  static List<List<double>> _zeros3() => [
    [0.0, 0.0, 0.0],
    [0.0, 0.0, 0.0],
    [0.0, 0.0, 0.0],
  ];

  static List<List<double>> _transpose3(List<List<double>> a) => [
    [a[0][0], a[1][0], a[2][0]],
    [a[0][1], a[1][1], a[2][1]],
    [a[0][2], a[1][2], a[2][2]],
  ];

  static List<List<double>> _mul3(List<List<double>> a, List<List<double>> b) {
    final r = _zeros3();
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        r[i][j] =
            a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
      }
    }
    return r;
  }

  static List<List<double>> _add3(List<List<double>> a, List<List<double>> b) {
    final r = _zeros3();
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        r[i][j] = a[i][j] + b[i][j];
      }
    }
    return r;
  }
}
