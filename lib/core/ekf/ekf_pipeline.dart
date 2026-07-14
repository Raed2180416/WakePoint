// EKF pipeline API (v1 core).

import 'ekf_types.dart';
import 'route_geometry.dart';
import 'dart:math' as math;

/// Logging callback for diagnostic output.
typedef EkfPipelineLogCallback = void Function(String message);

class EkfPipeline {
  EkfPipeline({
    required EkfConfig config,
    required RouteGeometry route,
    this.onLog,
  }) : _config = config,
       _route = route;

  final EkfConfig _config;
  final RouteGeometry _route;

  /// Optional logging callback for diagnostics.
  EkfPipelineLogCallback? onLog;

  int _predictionCount = 0;

  bool _initialized = false;
  EkfMode _mode = EkfMode.surface;
  MotionState _motion = MotionState.vehicle;
  bool _allowReverse = true;
  // G21: set when the device has no gyroscope (common on budget phones). A
  // missing gyro reads as "perfectly quiet", so we raise the σs floor to keep
  // reported uncertainty honest (→ the critical-fractile fires earlier = safe).
  bool _noGyro = false;

  double _s = double.nan;
  double _v = double.nan;
  double _b = 0.0;
  double _sPub = double.nan;

  List<List<double>> _p = _zeros3();
  Duration? _lastImuTs;

  // Bias observability via GPS-derived acceleration
  // Reference: El-Sheimy et al. (2004) "Observability Analysis of GPS/INS Integration"
  double? _lastGpsV;
  Duration? _lastGpsTick;
  final List<double> _recentAccels = [];
  static const int _maxAccelBufferSize = 50; // ~1s at 50Hz

  EkfPublicState get publicState {
    final sInternal = _s.isNaN ? 0.0 : _s;
    final sMonotonic = _sPub.isNaN ? sInternal : _sPub;
    // In degraded mode, expose internal state to avoid monotonic clamp freezing DR.
    final sOut = _mode == EkfMode.degraded ? sInternal : sMonotonic;
    return EkfPublicState(
      s: sOut,
      v: _v.isNaN ? 0.0 : _v,
      sigmaS: _sigmaS(),
      sigmaV: _sigmaV(),
      biasA: _b,
      mode: _mode,
      motion: _motion,
    );
  }

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

  void setAllowReverse(bool allow) {
    _allowReverse = allow;
  }

  /// G21: mark the device as gyroscope-less (raises the σs floor for honesty).
  void setNoGyro(bool noGyro) {
    _noGyro = noGyro;
  }

  void onImuSample(ImuSample sample) {
    onForwardAccel(sample.timestamp, sample.ax);
  }

  void onForwardAccel(Duration timestamp, double aFwd) {
    if (!_initialized) {
      onLog?.call('PIPELINE: Not initialized, skipping IMU');
      return;
    }
    if (_lastImuTs == null) {
      _lastImuTs = timestamp;
      onLog?.call('PIPELINE: First IMU tick at ${timestamp.inMicroseconds}us');
      return;
    }

    final dt = (timestamp - _lastImuTs!).inMicroseconds / 1e6;

    // Log dt periodically for debugging
    if (_predictionCount % 500 == 0) {
      onLog?.call(
        '🕐 dt check: ts=${timestamp.inMicroseconds}us last=${_lastImuTs!.inMicroseconds}us dt=${dt.toStringAsFixed(6)}',
      );
    }

    _lastImuTs = timestamp;

    // STRICT dt bounds checking per Brown & Hwang (1997):
    // - dt ≤ 0: Impossible, timestamp regression (skip entirely)
    // - dt > 1s: IMU integration error O(t²), reset velocity/bias
    // - Normal range: proceed with Kalman predict
    if (dt <= 0) {
      onLog?.call(
        'PIPELINE: Negative/zero dt=$dt (timestamp regression?), skipping',
      );
      return;
    }
    if (dt > 1.0) {
      // Large gap (Doze / OEM sensor-batching in a tunnel — exactly the target
      // scenario). Do NOT zero velocity: freezing under-progresses and fires
      // LATE (measured: a 300 s gap lost 2.85 km of progress). Instead COAST
      // forward at the last velocity (constant-velocity model; the acceleration
      // term is unreliable over a long gap) and inflate covariance to reflect
      // the unmodelled interval. Failing forward = early = the safe direction.
      onLog?.call('PIPELINE: Large dt=$dt > 1s, coasting at last velocity');
      _v = _v.clamp(-25.0, 25.0); // never coast forward on a runaway velocity
      final sBeforeGap = _s;
      // Coast forward, but CAP the coasted distance at ~one inter-station span.
      // A genuine Doze/batching gap is seconds; a much larger dt is a timestamp
      // glitch in the sensor stream (seen in real data: a ~20000 s jump), and an
      // uncapped v·dt fabricated a 500 km spike that fired the alarm on garbage.
      // Freezing would under-progress (late); a bounded coast fails slightly
      // early (safe). Covariance still inflates with the full gap (honest).
      final coastDist = (_v * dt).clamp(-1500.0, 1500.0);
      _s = _s + coastDist;
      if (!_allowReverse && _s < sBeforeGap) _s = sBeforeGap;
      final grow = 1.0 + dt.clamp(0.0, 60.0); // σ grows with the gap length
      _inflateCovariance(grow * grow);
      return;
    }
    if (dt < _config.minDt || dt > _config.maxDt) {
      _inflateCovariance(1.1);
      onLog?.call(
        'PIPELINE: Marginal dt=$dt (limits: ${_config.minDt}-${_config.maxDt}), inflating covariance',
      );
      return;
    }

    _predictionCount++;

    final sOld = _s;
    final vOld = _v;

    // CRITICAL DEBUG: Log every prediction in degraded mode
    final shouldLogDegraded =
        _mode == EkfMode.degraded && _predictionCount % 100 == 0;

    if (_mode == EkfMode.degraded) {
      // Allow dead reckoning to continue (v != 0), but inflate covariance gently.
      // This enables tunnel navigation while keeping σs bounded for station association.
      //
      // TUNING: 1.0002 grows σs by ~1% per second at 50Hz:
      //   1.0002^50 ≈ 1.01 after 1s
      //   1.0002^500 ≈ 1.11 after 10s
      //   1.0002^5000 ≈ 2.72 after 100s (from 10m → 27m)
      //
      // This keeps σs under 100m for ~3 minutes of degraded mode,
      // allowing station snaps to still work.
      //
      // Previous: 1.02 → σs hit 10km cap within seconds, breaking snaps!
      _inflateCovariance(1.0002);
      // Continue to integration below
    }

    final dt2 = dt * dt;
    double aBias = aFwd - _b;

    // Apply velocity damping in degraded mode ONLY when stationary.
    //
    // CRITICAL: During GPS dropout while moving, we must preserve velocity for DR!
    // - If motion=vehicle: NO damping - let IMU integration drive position
    // - If motion=stationary: Strong damping - prepare for ZUPT
    //
    // The motion classifier has a velocity hard gate (v > 2 m/s → vehicle)
    // so it correctly identifies motion during cruising.
    double vDamping = 1.0;
    if (_mode == EkfMode.degraded) {
      if (_motion == MotionState.stationary && _v.abs() < 0.3) {
        // Only damp when actually near-stopped AND velocity is near-zero.
        // tau ~1s at 50Hz: 0.98^50 ≈ 0.36 after 1 second
        vDamping = 0.98;
      } else {
        // NO damping during active motion - let velocity persist for DR!
        // The accelerometer should handle velocity changes via integration.
        vDamping = 1.0;

        // Log pre-clamp values
        final aBiasRaw = aBias;

        // Reduced deadband to allow small accelerations through.
        // Only zero out very small noise (<0.1 m/s²).
        if (aBias.abs() < 0.1) {
          aBias = 0.0;
        }
        aBias = aBias.clamp(-1.5, 1.5);

        if (_predictionCount % 10 == 0) {
          onLog?.call(
            'DR_PHYSICS: v=${_v.toStringAsFixed(3)} aBiasRaw=${aBiasRaw.toStringAsFixed(3)} aBiasCloud=${aBias.toStringAsFixed(3)}',
          );
        }
      }
    }

    // Clamp velocity to physically-possible metro speed BEFORE integrating
    // position. Non-predict update paths (GPS-speed fusion, station snap, ZUPT)
    // set _v without re-clamping, so a bad GPS speed could leave _v far above
    // the limit; integrating that produced a 242 km / 10x-route blow-up on real
    // data. Clamping here guarantees s never advances faster than a real train.
    _v = _v.clamp(-25.0, 25.0);
    _s = _s + _v * dt + 0.5 * aBias * dt2;
    _v = (_v + aBias * dt) * vDamping;

    // Prevent reverse motion when not allowed (e.g., metro legs).
    if (!_allowReverse) {
      if (_v < 0) _v = 0;
      if (_s < sOld) _s = sOld;
    }

    // Clamp velocity to reasonable metro speeds (max 90 km/h = 25 m/s)
    _v = _v.clamp(-25.0, 25.0);

    // Log detailed prediction info in degraded mode
    if (shouldLogDegraded) {
      final deltaS = _s - sOld;
      final deltaV = _v - vOld;
      onLog?.call(
        '🔴 DR pred#$_predictionCount: dt=${dt.toStringAsFixed(4)} aFwd=${aFwd.toStringAsFixed(4)} bias=${_b.toStringAsFixed(4)} aBias=${aBias.toStringAsFixed(4)} | v: ${vOld.toStringAsFixed(3)}→${_v.toStringAsFixed(3)} (Δ${deltaV.toStringAsFixed(4)}) | s: ${sOld.toStringAsFixed(0)}→${_s.toStringAsFixed(0)} (Δ${deltaS.toStringAsFixed(2)})',
      );
    }

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

    // Track recent forward accelerations for bias observability
    // Reference: El-Sheimy et al. (2004) "Observability Analysis of GPS/INS Integration"
    _recentAccels.add(aFwd);
    while (_recentAccels.length > _maxAccelBufferSize) {
      _recentAccels.removeAt(0);
    }

    _sanitizeCovariance();
    _enforceSymmetry();
    _applyStateBounds();
    _applyCovarianceFloors();
    _updatePublicProgress();
  }

  /// Handle GPS fix with robust innovation gating using Huber M-estimator:
  /// - |nu| > 15σ → hard reset (genuinely bad fix or teleport)
  /// - 2.5σ < |nu| ≤ 15σ → Huber down-weighted update (handles multipath)
  /// - |nu| ≤ 2.5σ → normal Kalman update
  ///
  /// Scientific basis:
  /// - GPS multipath produces heavy-tailed (non-Gaussian) errors
  /// - Hard gates assume Gaussian; Huber M-estimator handles outliers
  /// - Reference: Huber (1964), Chang (2014) "Robust Kalman filtering"
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
    final normalizedInnovation = sigmaS > 0 ? nu.abs() / sigmaS : 0.0;

    // Hard gate: only full reset for extreme outliers (>15σ)
    // This represents teleportation or complete GPS failure, not multipath
    if (sigmaS > 0 && normalizedInnovation > 15.0) {
      onLog?.call(
        'GPS: Extreme outlier (${normalizedInnovation.toStringAsFixed(1)}σ), hard reset',
      );
      _initializeFromGps(sGps, fix.speedMps);
      return;
    }

    // Huber robust weighting for innovation
    // - ≤2.5σ: weight = 1.0 (full trust)
    // - >2.5σ: weight = 2.5/|norm_nu| (down-weighted)
    final weight = _huberWeight(normalizedInnovation, c: 2.5);

    if (weight < 0.2) {
      // Innovation 12.5-15σ range, very low weight - soft reject
      onLog?.call(
        'GPS: High innovation (${normalizedInnovation.toStringAsFixed(1)}σ), soft reject',
      );
      _inflateCovariance(1.2);
      return;
    }

    // Apply weighted measurement noise (inflate R inversely with weight)
    final baseR = math.max(
      fix.accuracyMeters * fix.accuracyMeters,
      _config.gpsFloorVar,
    );
    final r = baseR / weight; // Inflate R for outliers

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

    // Optional: Fuse GPS speed as a direct velocity measurement.
    // This keeps velocity realistic when GPS is available and prevents
    // near-zero v from freezing DR when GPS drops out.
    if (fix.speedMps.isFinite) {
      final rV = _config.gpsSpeedVar;
      final sV = _p[1][1] + rV;
      if (sV > 0) {
        final nuV = fix.speedMps - _v;
        final kV = _p[1][1] / sV;
        _v = _v + kV * nuV;

        final p10v = _p[1][0];
        final p11v = _p[1][1];
        final p12v = _p[1][2];

        _p[1][0] = p10v - kV * p10v;
        _p[1][1] = p11v - kV * p11v;
        _p[1][2] = p12v - kV * p12v;
        _p[0][1] = _p[1][0];
        _p[2][1] = _p[1][2];
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Bias Observability via GPS-Derived Acceleration
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Scientific basis:
    // - In constant-velocity model, bias is unobservable from position/velocity alone
    // - BUT with consecutive GPS fixes, we can infer acceleration: a_GPS = Δv/Δt
    // - Compare with IMU average: bias_estimate = aIMU - aGPS
    //
    // Reference: El-Sheimy et al. (2004) "Observability Analysis of GPS/INS Integration"
    //
    // Constraints:
    // - Δt must be in [0.5s, 5.0s] for meaningful acceleration inference
    // - Need sufficient IMU samples in buffer for averaging
    // - Use low gain (0.05) since GPS-derived accel is noisy
    // ─────────────────────────────────────────────────────────────────────────
    if (_lastGpsV != null &&
        _lastGpsTick != null &&
        _recentAccels.isNotEmpty) {
      final dtGps = (fix.timestamp - _lastGpsTick!).inMicroseconds / 1e6;
      if (dtGps > 0.5 && dtGps < 5.0) {
        // GPS-derived acceleration
        final aGps = (fix.speedMps - _lastGpsV!) / dtGps;

        // Average recent IMU accelerations
        final aImuAvg =
            _recentAccels.reduce((a, b) => a + b) / _recentAccels.length;

        // Bias estimate: aIMU - b ≈ aGPS → b ≈ aIMU - aGPS
        final biasEstimate = aImuAvg - aGps;

        // Weak update to bias (low gain because GPS accel is noisy)
        // 0.05 gain means ~5% blend per update
        const biasGain = 0.05;

        // Only apply update if estimate is reasonable (within ±2 m/s²)
        if (biasEstimate.abs() < 2.0) {
          final biasDelta = biasGain * (biasEstimate - _b);
          _b = _b + biasDelta;

          // Clamp bias to reasonable bounds
          _b = _b.clamp(-1.0, 1.0);

          if (_predictionCount % 50 == 0) {
            onLog?.call(
              'BIAS_OBS: aGps=${aGps.toStringAsFixed(3)} aImu=${aImuAvg.toStringAsFixed(3)} biasEst=${biasEstimate.toStringAsFixed(3)} b=${_b.toStringAsFixed(4)}',
            );
          }
        }
      }
    }

    _lastGpsV = fix.speedMps;
    _lastGpsTick = fix.timestamp;

    _enforceSymmetry();
    _applyStateBounds();
    _applyCovarianceFloors();
    _updatePublicProgress();
  }

  /// ZUPT (Zero-velocity Update) handler.
  ///
  /// Scientific basis:
  /// - When vehicle is stationary, v = 0 is a strong measurement
  /// - This is the ONLY time accelerometer bias is observable
  /// - ZUPT enables aggressive bias correction during station dwell
  ///
  /// References:
  /// - Skog et al. (2010). "Zero-Velocity Detection—An Algorithm Evaluation"
  /// - Ramanandan et al. (2011). "Inertial Navigation Aiding by Stationary Updates"
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

    // Post-ZUPT covariance tightening (VELOCITY ONLY) — A1/G20.
    // A ZUPT is a velocity measurement (v ≈ 0), NOT a position measurement: a
    // confirmed stop in a tunnel does NOT tell us WHICH station we are at, so
    // forcing σs ≤ 10m fabricated position certainty and produced wrong
    // geometric station snaps. Position certainty must come ONLY from a real
    // station snap (onStationCandidates). Keep the velocity tightening.
    //
    // Max σv = 0.5 m/s (near-zero velocity confidence)
    _p[1][1] = math.min(_p[1][1], 0.5 * 0.5); // σv ≤ 0.5 m/s

    _enforceSymmetry();
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

    _enforceSymmetry();
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
    // Fix NaN states
    if (_s.isNaN || _s.isInfinite) _s = 0.0;
    if (_v.isNaN || _v.isInfinite) _v = 0.0;
    if (_b.isNaN || _b.isInfinite) _b = 0.0;

    // Velocity can only be a physically-possible train speed. The non-predict
    // update paths (GPS-speed fusion, station snap, ZUPT) set _v without
    // re-clamping — on real data a transient blew _v to ~1091 m/s, producing a
    // spurious ~518 km position spike that fired the alarm on a glitch. This is
    // the shared post-update guard, so clamp velocity here for every path.
    _v = _v.clamp(-25.0, 25.0);

    if (_b.abs() > _config.biasLimit) {
      _b = _b.clamp(-_config.biasLimit, _config.biasLimit);
    }
  }

  void _applyCovarianceFloors() {
    // Fix NaN covariances first (use 200m max, matching _inflateCovariance)
    if (_p[0][0].isNaN || _p[0][0].isInfinite) _p[0][0] = 200.0 * 200.0;
    if (_p[1][1].isNaN || _p[1][1].isInfinite) _p[1][1] = 100.0 * 100.0;
    if (_p[2][2].isNaN || _p[2][2].isInfinite) _p[2][2] = 1.0;

    // G21: no-gyro devices carry a wider honest position floor (20m vs 5m).
    final sFloor =
        _noGyro ? math.max(_config.sigmaSFloor, 20.0) : _config.sigmaSFloor;
    _p[0][0] = math.max(_p[0][0], sFloor * sFloor);
    _p[1][1] = math.max(_p[1][1], _config.sigmaVFloor * _config.sigmaVFloor);
    _p[2][2] = math.max(_p[2][2], _config.sigmaBiasFloor);
  }

  void _inflateCovariance(double factor) {
    _p[0][0] *= factor;
    _p[1][1] *= factor;
    _p[2][2] *= factor;
    // Clamp to prevent infinity/NaN
    //
    // TUNING: maxSigmaS = 200m keeps station association viable:
    //   Window = 3*200 + 100 = 700m, enough to disambiguate most stations
    // Previous 10km cap made ALL stations candidates → MULTIPLE_CANDIDATES
    // A1/G20: 3000m lets σs grow HONESTLY during long tunnel dead-reckoning
    // instead of being clamped to a falsely-confident 200m (which produced a
    // too-small critical-fractile margin, firing close to late). The geometric
    // 3σ station-association window is only trusted on the surface (small σs);
    // underground the association falls back to nearest-ahead / dwell-ordinal,
    // which does not widen with σs. Fits under _sanitizeCovariance (P00≤1e8).
    const maxSigmaS = 3000.0; // 3km max position uncertainty (honest DR growth)
    const maxSigmaV = 100.0; // 100 m/s max velocity uncertainty
    const maxSigmaB = 1.0; // 1 m/s² max bias uncertainty
    _p[0][0] =
        (_p[0][0].isNaN || _p[0][0].isInfinite)
            ? maxSigmaS * maxSigmaS
            : _p[0][0].clamp(0, maxSigmaS * maxSigmaS);
    _p[1][1] =
        (_p[1][1].isNaN || _p[1][1].isInfinite)
            ? maxSigmaV * maxSigmaV
            : _p[1][1].clamp(0, maxSigmaV * maxSigmaV);
    _p[2][2] =
        (_p[2][2].isNaN || _p[2][2].isInfinite)
            ? maxSigmaB * maxSigmaB
            : _p[2][2].clamp(0, maxSigmaB * maxSigmaB);
  }

  double _sigmaS() => math.sqrt(_p[0][0].abs());
  double _sigmaV() => math.sqrt(_p[1][1].abs());

  void _updatePublicProgress() {
    if (_s.isNaN) return;
    if (_sPub.isNaN) {
      _sPub = _s;
    } else {
      // Monotonic forward progress, but RATE-LIMITED so a single-tick internal
      // _s glitch (a transient spike to hundreds of km was seen on real data)
      // cannot latch into published progress and fire the alarm on garbage. The
      // 1600 m headroom admits the legitimate dt>1s coast (capped at 1500 m)
      // while bounding any single-update jump to something physically plausible.
      final target = math.max(_sPub, _s);
      _sPub = math.min(target, _sPub + 1600.0);
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
        r[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
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

  /// Sanitize entire covariance matrix to prevent NaN/Infinity propagation.
  void _sanitizeCovariance() {
    const maxP = [
      [
        100000000.0,
        100000.0,
        1000.0,
      ], // sigmaS^2 max, sigmaS*sigmaV max, sigmaS*sigmaB max
      [
        100000.0,
        10000.0,
        100.0,
      ], // sigmaV*sigmaS max, sigmaV^2 max, sigmaV*sigmaB max
      [
        1000.0,
        100.0,
        1.0,
      ], // sigmaB*sigmaS max, sigmaB*sigmaV max, sigmaB^2 max
    ];
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        if (_p[i][j].isNaN || _p[i][j].isInfinite) {
          _p[i][j] = maxP[i][j];
        } else if (_p[i][j].abs() > maxP[i][j]) {
          _p[i][j] = _p[i][j].sign * maxP[i][j];
        }
      }
    }
  }

  /// Enforce covariance matrix symmetry.
  /// After Kalman updates, floating-point errors accumulate causing P ≠ P'.
  /// This enforces P = (P + P') / 2 per Brown & Hwang (1997).
  ///
  /// Scientific basis:
  /// - Kalman (1960) proved optimal estimator requires symmetric positive-definite P
  /// - Numerical drift causes asymmetry over many iterations
  /// - Asymmetry leads to inconsistent error ellipsoids and filter divergence
  void _enforceSymmetry() {
    for (var i = 0; i < 3; i++) {
      for (var j = i + 1; j < 3; j++) {
        final avg = (_p[i][j] + _p[j][i]) / 2.0;
        _p[i][j] = avg;
        _p[j][i] = avg;
      }
    }
  }

  /// Huber robust weight function for innovation gating.
  /// Reduces sensitivity to GPS multipath outliers.
  ///
  /// - |x| ≤ c: weight = 1.0 (normal Kalman update)
  /// - |x| > c: weight = c / |x| (down-weighted update)
  ///
  /// Reference: Huber, P.J. (1964). "Robust Estimation of a Location Parameter."
  double _huberWeight(double normalizedInnovation, {double c = 2.5}) {
    final absX = normalizedInnovation.abs();
    if (absX <= c) return 1.0;
    return c / absX;
  }
}
