// EKF orchestrator - wires detectors and EKF core (not yet integrated into app).

import 'dart:math' as math;

import 'ekf_pipeline.dart';
import 'ekf_types.dart';
import 'gps_degradation_detector.dart';
import 'motion_classifier.dart';
import 'route_geometry.dart';
import 'tilt_filter.dart';
import 'station_association.dart';
import 'zupt_detector.dart';
import 'degraded_mode.dart';

/// Logging callback for diagnostic output.
typedef EkfOrchestratorLogCallback = void Function(String tag, String message, Map<String, dynamic>? data);

class EkfOrchestrator {
  EkfOrchestrator({
    required RouteGeometry route,
    EkfConfig? config,
    GpsDegradationDetector? gpsDetector,
    MotionClassifier? motionClassifier,
    ZuptDetector? zuptDetector,
    this.onLog,
    this.logVerbosity = 0,
  }) : _pipeline = EkfPipeline(
         config: config ?? const EkfConfig(),
         route: route,
       ),
       _route = route,
       _gpsDetector = gpsDetector ?? GpsDegradationDetector(),
       _motionClassifier = motionClassifier ?? MotionClassifier(),
       _zuptDetector = zuptDetector ?? ZuptDetector() {
    // Wire pipeline logging - always log pipeline messages at verbosity >= 1
    _pipeline.onLog = (msg) {
      if (logVerbosity >= 1) {
        _log('PIPELINE', msg, null);
      }
    };
  }

  /// Logging callback for external log collection.
  EkfOrchestratorLogCallback? onLog;
  
  /// Verbosity level: 0=minimal, 1=events, 2=all IMU ticks
  int logVerbosity;

  final EkfPipeline _pipeline;
  final RouteGeometry _route;
  final GpsDegradationDetector _gpsDetector;
  final MotionClassifier _motionClassifier;
  final MotionFeatureExtractor _featureExtractor = MotionFeatureExtractor();
  final ZuptDetector _zuptDetector;
  final TiltFilter _tiltFilter = TiltFilter();
  final StationAssociation _stationAssociation = StationAssociation();
  final DegradedMode _degradedMode = DegradedMode();

  final List<double> _accelVarWindow = [];
  final List<double> _gyroVarWindow = [];
  final List<double> _varTimes = [];

  final List<double> _accelFeatureWindow = [];
  final List<double> _gyroFeatureWindow = [];
  final List<double> _featureTimes = [];

  // Track recent aFwd for motion classification during GPS dropout
  final List<double> _recentAFwdWindow = [];
  static const int _aFwdWindowSize = 50; // ~0.5s at 100Hz

  Duration? _lastImuTs;
  Duration? _lastZuptTs;
  double _lastInnovationSigma = 0.0;
  double _innovationHighSeconds = 0.0;
  bool _fftEnabled = true;
  bool _predictionEnabled = false;
  bool _ekfInitialized = false; // Track if we ever got first GPS fix
  MotionState _motionState = MotionState.vehicle;
  bool _hasGpsFix = false;
  // Last accepted on-route fix, for frozen-phantom detection in onGpsFixAuto.
  double? _lastFixLat;
  double? _lastFixLng;
  MotionState? _pendingMotion;
  int _pendingMotionCount = 0;
  double? _lastMotionDecisionAt;
  static const double _motionStepSeconds = 1.28;

  // Static bias initialization: accumulate aFwd samples when stationary pre-GPS
  final List<double> _biasInitWindow = [];
  static const int _biasInitMinSamples = 100; // ~1s at 100Hz
  static const int _biasInitMaxSamples = 500; // ~5s at 100Hz
  bool _biasInitialized = false;
  double? _estimatedInitialBias;

  List<double> _stationMeters = const [];
  bool _isMetroLeg = false;
  int _lastSnappedStationIndex = -1;

  /// Callback for station snap confirmed events (§24.2 gated).
  void Function(StationSnapConfirmed)? onStationSnapConfirmed;

  bool get gpsDegraded => _gpsDetector.isDegraded;
  
  /// Expose prediction enabled state for debugging.
  bool get predictionEnabled => _predictionEnabled;
  
  /// Expose current motion state for debugging.
  MotionState get currentMotionState => _motionState;
  
  /// Expose current variance values for debugging.
  double get currentAccelVariance => _variance(_accelVarWindow);
  double get currentGyroVariance => _variance(_gyroVarWindow);

  EkfPublicState get publicState => _pipeline.publicState;

  void _log(String tag, String message, [Map<String, dynamic>? data]) {
    onLog?.call(tag, message, data);
  }

  void onImuSample(ImuSample sample) {
    _tiltFilter.setMotionState(_motionState);
    final tiltOutput = _tiltFilter.update(sample);
    final timestampSeconds = sample.timestamp.inMicroseconds / 1e6;

    _updateInnovationTimer(sample.timestamp);
    _pushVarianceSample(timestampSeconds, sample);
    _pushFeatureSample(timestampSeconds, sample);

    final accelVariance = _variance(_accelVarWindow);
    final gyroVariance = _variance(_gyroVarWindow);

    final features = _extractMotionFeatures();
    final motion = _classifyMotion(
      accelVariance: accelVariance,
      gyroVariance: gyroVariance,
      features: features,
      timestamp: sample.timestamp,
    );

    final oldMotion = _motionState;
    _motionState = _applyMotionDurationGate(motion, timestampSeconds);
    _pipeline.setMotionState(_motionState);
    _updateMode(sample.timestamp);
    
    // Log motion state changes
    if (_motionState != oldMotion && logVerbosity >= 1) {
      _log('MOTION', 'State changed', {
        'from': oldMotion.name,
        'to': _motionState.name,
        'accelVar': accelVariance.toStringAsExponential(2),
        'gyroVar': gyroVariance.toStringAsExponential(2),
      });
    }
    
    _maybeUpdateZupt(
      timestamp: sample.timestamp,
      motion: _motionState,
      accelVariance: accelVariance,
      gyroVariance: gyroVariance,
    );

    if (!_predictionEnabled) {
      // Log once per second that prediction is disabled
      if (logVerbosity >= 1 && (timestampSeconds * 10).round() % 10 == 0) {
        _log('IMU', 'Prediction DISABLED', {
          'timestamp': timestampSeconds.toStringAsFixed(1),
          'hasGpsFix': _hasGpsFix,
        });
      }
      return;
    }

    if (tiltOutput == null) {
      // Log that we're falling back to raw accel
      if (logVerbosity >= 1 && (timestampSeconds * 10).round() % 50 == 0) {
        _log('IMU', 'Tilt null - using raw ax', {
          'ax': sample.ax.toStringAsFixed(3),
          'timestamp': timestampSeconds.toStringAsFixed(1),
        });
      }
      _pipeline.onImuSample(sample);
      return;
    }

    final aFwd = _forwardAccel(sample, tiltOutput);
    _pipeline.onForwardAccel(sample.timestamp, aFwd);
    
    // Track recent aFwd for motion classification during GPS dropout
    _recentAFwdWindow.add(aFwd.abs());
    if (_recentAFwdWindow.length > _aFwdWindowSize) {
      _recentAFwdWindow.removeAt(0);
    }
    
    // Log IMU prediction with actual aFwd value
    if (logVerbosity >= 1 && (timestampSeconds * 10).round() % 100 == 0) {
      final state = _pipeline.publicState;
      final isDegraded = _gpsDetector.isDegraded || state.mode == EkfMode.degraded;
      _log('IMU', isDegraded ? '🔴 DR_TICK' : 'Prediction step', {
        'aFwd': aFwd.toStringAsFixed(4),
        's': state.s.toStringAsFixed(0),
        'v': state.v.toStringAsFixed(3),
        'mode': state.mode.name,
        'degraded': isDegraded,
        'σs': state.sigmaS.toStringAsFixed(1),
      });
    }
  }

  void onGpsFix(GpsFix fix, {required double innovationSigma}) {
    final wasPredictionEnabled = _predictionEnabled;
    if (innovationSigma.isFinite) {
      _lastInnovationSigma = innovationSigma;
    }
    _predictionEnabled = true;
    _ekfInitialized = true; // EKF is now initialized and can do DR
    _hasGpsFix = true;
    _gpsDetector.onGpsFix(
      timestamp: fix.timestamp,
      hasFix: true,
      accuracyMeters: fix.accuracyMeters,
      innovationSigma: innovationSigma,
    );
    _pipeline.onGpsFix(fix);
    
    if (logVerbosity >= 1) {
      final state = _pipeline.publicState;
      _log('GPS', 'Fix received', {
        'lat': fix.lat.toStringAsFixed(5),
        'lng': fix.lng.toStringAsFixed(5),
        'acc': fix.accuracyMeters.toStringAsFixed(1),
        'innov_σ': innovationSigma.toStringAsFixed(2),
        's_after': state.s.toStringAsFixed(1),
        'v_after': state.v.toStringAsFixed(2),
        'pred_enabled': wasPredictionEnabled ? 'already' : 'NOW',
      });
    }
  }

  void onGpsFixAuto(GpsFix fix) {
    final sGps = _route.projectLatLng(fix.lat, fix.lng);
    if (sGps.isNaN) {
      // Off-route fix (includes off-route phantoms — 138 of them on the real
      // Rajajinagar ride). Treat as GPS-unavailable so dead-reckoning engages,
      // instead of silently discarding the fix while the filter still believes
      // GPS is live and never enters degraded DR.
      onGpsUnavailable(fix.timestamp);
      return;
    }

    // Frozen-phantom rejection: the OS fused-location provider can emit a
    // stationary fix with confident accuracy while underground (proven in the
    // corpus: 120 s pinned at 3.79 m hAcc). If the position has not moved but the
    // filter says we ARE moving (v > 2 m/s), it is a phantom — degrade (keep DR)
    // rather than anchoring s to a lie and driving v→0 (a late fire). A genuine
    // station stop reads v≈0 and is NOT rejected here, so it still fuses.
    if (_lastFixLat != null && _pipeline.publicState.v.abs() > 2.0) {
      final movedMeters =
          _haversineMeters(_lastFixLat!, _lastFixLng!, fix.lat, fix.lng);
      if (movedMeters < 2.0) {
        onGpsUnavailable(fix.timestamp);
        return;
      }
    }
    _lastFixLat = fix.lat;
    _lastFixLng = fix.lng;

    final innovationSigma = _pipeline.innovationSigmaForS(sGps);
    onGpsFix(fix, innovationSigma: innovationSigma);
  }

  static double _haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLon = (lon2 - lon1) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
  
  /// Notify the orchestrator that GPS is unavailable for this tick.
  /// This allows the GPS degradation detector to track fix timeout.
  void onGpsUnavailable(Duration timestamp) {
    // Update degradation detector with no-fix status
    _gpsDetector.onGpsFix(
      timestamp: timestamp,
      hasFix: false,
      accuracyMeters: 999.0, // Indicate very poor accuracy
      innovationSigma: 999.0, // Indicate high innovation
    );
    
    // CRITICAL: Keep predictions enabled during GPS dropout if EKF was initialized!
    // This is essential for dead reckoning to continue tracking position.
    if (_ekfInitialized && !_predictionEnabled) {
      _predictionEnabled = true;
      _log('GPS', 'Enabling DR predictions (EKF initialized)', null);
    }
    
    // Update mode (may transition to degraded)
    _updateMode(timestamp);
    
    if (logVerbosity >= 2) {
      final ts = timestamp.inMicroseconds / 1e6;
      if ((ts * 10).round() % 50 == 0) {
        _log('GPS', 'Unavailable tick', {
          'degraded': _gpsDetector.isDegraded,
          'mode': publicState.mode.name,
          'predictionEnabled': _predictionEnabled,
          'ekfInitialized': _ekfInitialized,
        });
      }
    }
  }

  void setFftEnabled(bool enabled) {
    _fftEnabled = enabled;
  }

  /// G21: propagate a detected gyroscope-less device to the filter so it keeps
  /// reported position uncertainty honest (wider σs floor).
  void setNoGyro(bool noGyro) {
    _pipeline.setNoGyro(noGyro);
  }

  void setStationContext({
    required List<double> stationMeters,
    required bool isMetroLeg,
  }) {
    _stationMeters = stationMeters;
    _isMetroLeg = isMetroLeg;
    _pipeline.setAllowReverse(!isMetroLeg);
  }

  void reset() {
    _tiltFilter.reset();
    _accelVarWindow.clear();
    _gyroVarWindow.clear();
    _varTimes.clear();
    _accelFeatureWindow.clear();
    _gyroFeatureWindow.clear();
    _featureTimes.clear();
    _lastImuTs = null;
    _lastZuptTs = null;
    _lastInnovationSigma = 0.0;
    _innovationHighSeconds = 0.0;
    _fftEnabled = true;
    _predictionEnabled = false;
    _ekfInitialized = false;
    _motionState = MotionState.vehicle;
    _pendingMotion = null;
    _pendingMotionCount = 0;
    _lastMotionDecisionAt = null;
    _hasGpsFix = false;
    _lastFixLat = null;
    _lastFixLng = null;
    _lastSnappedStationIndex = -1;
    // Reset bias initialization state
    _biasInitWindow.clear();
    _biasInitialized = false;
    _estimatedInitialBias = null;
    _recentAFwdWindow.clear();
  }

  void onMotionFeatures({
    required double accelVariance,
    required double gyroVariance,
    required double fftWalkEnergy,
    required double fftTrainEnergy,
    required double innovationSigma,
    required bool recentZupt,
  }) {
    final state = _motionClassifier.classify(
      accelVariance: accelVariance,
      gyroVariance: gyroVariance,
      fftWalkEnergy: fftWalkEnergy,
      fftTrainEnergy: fftTrainEnergy,
      sigmaV: publicState.sigmaV,
      recentZupt: recentZupt,
      innovationSigma: innovationSigma,
      ekfWeight: 0.3,
    );

    // Motion state is not yet fed back into EKF; reserved for later stages.
    // This hook ensures wiring is in place per plan.
    if (state == MotionState.stationary) {
      // no-op for now
    }
  }

  void onZuptCandidate({
    required Duration timestamp,
    required MotionState motion,
    required double accelVariance,
    required double gyroVariance,
  }) {
    // Log ZUPT detection inputs periodically
    final ts = timestamp.inMicroseconds / 1e6;
    
    // Log every 2 seconds to track ZUPT conditions
    if (logVerbosity >= 1 && (ts * 10).round() % 20 == 0) {
      // Use relaxed thresholds matching ZuptDetector
      final meetsAccel = accelVariance < 0.1;   // Relaxed threshold 
      final meetsGyro = gyroVariance < 0.01;    // Relaxed threshold
      final imuQuiet = meetsAccel && meetsGyro;
      final meetsMotion = motion == MotionState.stationary;
      final meetsV = publicState.v.abs() < 2.0;  // Relaxed threshold
      final wouldMeet = imuQuiet || (meetsMotion && meetsV);
      _log('ZUPT', 'Check', {
        'motion': motion.name,
        'v': publicState.v.toStringAsFixed(2),
        'sigmaS': publicState.sigmaS.toStringAsFixed(1),  // Track covariance!
        'accelVar': accelVariance.toStringAsExponential(2),
        'gyroVar': gyroVariance.toStringAsExponential(2),
        'imuQuiet': imuQuiet,
        'meetsMotion': meetsMotion,
        'meetsV': meetsV,
        'wouldMeet': wouldMeet,
      });
    }
    
    final isDegraded = _gpsDetector.isDegraded || publicState.mode == EkfMode.degraded;
    final confirmed = _zuptDetector.update(
      timestamp: timestamp,
      motion: motion,
      velocityMps: publicState.v,
      accelVariance: accelVariance,
      gyroVariance: gyroVariance,
      isDegraded: isDegraded,  // Allow IMU-only ZUPT during GPS dropout
    );
    if (confirmed) {
      _handleZuptConfirmed(timestamp, source: 'detector');
    }
  }

  /// Manual ZUPT override for known stops (e.g., station dwell during GPS dropout).
  /// This reduces drift by applying bias correction and station association when
  /// the simulator indicates a hard stop.
  void forceZupt(Duration timestamp, {String source = 'manual'}) {
    if (_lastZuptTs != null &&
        (timestamp - _lastZuptTs!).inMilliseconds < 1000) {
      return;
    }
    _handleZuptConfirmed(timestamp, source: source);
  }

  void _handleZuptConfirmed(Duration timestamp, {required String source}) {
    final ts = timestamp.inMicroseconds / 1e6;
    final isDegraded =
        _gpsDetector.isDegraded || publicState.mode == EkfMode.degraded;
    _log('ZUPT', '*** CONFIRMED ***', {
      'timestamp': ts.toStringAsFixed(1),
      'v': publicState.v.toStringAsFixed(3),
      'source': source,
    });

    _lastZuptTs = timestamp;
    _degradedMode.onZupt(timestamp);
    _predictionEnabled = true;
    _tiltFilter.reset();
    _pipeline.onZuptConfirmed();

    final dwell = _zuptDetector.currentDwell(timestamp) ?? Duration.zero;
    final assoc = _stationAssociation.selectCandidate(
      stationMeters: _stationMeters,
      sEst: _pipeline.publicState.s,
      sigmaS: _pipeline.publicState.sigmaS,
      isMetroLeg: _isMetroLeg,
      zuptConfirmed: _zuptDetector.isConfirmed,
      zuptDwell: dwell,
      isDegraded: isDegraded,
    );

    // ALWAYS log station association diagnostics on ZUPT (critical for debugging)
    final diag = _stationAssociation.lastDiagnostics;
    if (diag != null) {
      _log('STATION', 'Association attempt', diag.toJson());
    }

    if (assoc != null) {
      _log('STATION', 'Association FOUND', {
        'stationIndex': assoc.stationIndex,
        'stationMeters': assoc.stationMeters.toStringAsFixed(0),
        'sEst': _pipeline.publicState.s.toStringAsFixed(0),
        'sigmaS': _pipeline.publicState.sigmaS.toStringAsFixed(1),
      });

      _pipeline.onStationCandidates([StationCandidate(assoc.stationMeters)]);

      // §24.2 confidence gate for ARM update:
      // - σ_s ≤ 30m after snap update (≤ 60m in degraded mode)
      // - Single candidate (enforced by StationAssociation)
      // - Monotonic station index
      final sigmaAfterSnap = _pipeline.publicState.sigmaS;
      final sigmaGate = isDegraded ? 60.0 : 30.0;
      final isMonotonic = assoc.stationIndex > _lastSnappedStationIndex;

      if (sigmaAfterSnap <= sigmaGate && isMonotonic) {
        _log('STATION', '*** SNAP CONFIRMED ***', {
          'stationIndex': assoc.stationIndex,
          'sigmaAfterSnap': sigmaAfterSnap.toStringAsFixed(1),
          'lastSnapped': _lastSnappedStationIndex,
        });

        _lastSnappedStationIndex = assoc.stationIndex;
        onStationSnapConfirmed?.call(
          StationSnapConfirmed(
            stationIndex: assoc.stationIndex,
            stationMeters: assoc.stationMeters,
            sigmaS: sigmaAfterSnap,
            timestamp: DateTime.now(),
          ),
        );
      } else {
        _log('STATION', 'Snap REJECTED (confidence gate)', {
          'sigmaAfterSnap': sigmaAfterSnap.toStringAsFixed(1),
          'gate': sigmaGate.toString(),
          'isMonotonic': isMonotonic.toString(),
          'lastSnappedIndex': _lastSnappedStationIndex,
        });
      }
    } else {
      _log('STATION', 'No association', {
        'reason': diag?.rejectReason ?? 'unknown',
        'sEst': _pipeline.publicState.s.toStringAsFixed(0),
        'sigmaS': _pipeline.publicState.sigmaS.toStringAsFixed(1),
        'numStations': _stationMeters.length,
      });
    }
  }

  void _updateMode(Duration timestamp) {
    final oldMode = _pipeline.publicState.mode;
    
    if (!_hasGpsFix) {
      _pipeline.setMode(EkfMode.degraded);
      if (logVerbosity >= 1 && oldMode != EkfMode.degraded) {
        _log('MODE', 'No GPS fix yet → DEGRADED', null);
      }
      return;
    }
    
    final sigmaS = publicState.sigmaS;
    final gpsDegraded = _gpsDetector.isDegraded;
    
    _degradedMode.update(
      timestamp: timestamp,
      sigmaS: sigmaS,
      gpsRecovered: !gpsDegraded,
      thresholdOverride: _isMetroLeg ? 2000.0 : null,
    );

    // CRITICAL FIX: Enter degraded mode if EITHER:
    // 1. GPS degradation detector says GPS is bad (no fix for 5s, bad accuracy, etc.)
    // 2. DegradedMode says sigmaS is too high or no ZUPT for too long
    // Previously only checked _degradedMode, which requires sigma to grow to 2000m for metro!
    if (gpsDegraded || _degradedMode.isDegraded) {
      _pipeline.setMode(EkfMode.degraded);
      if (logVerbosity >= 1 && oldMode != EkfMode.degraded) {
        _log('MODE', '🔴 Entering DEGRADED mode', {
          'sigmaS': sigmaS.toStringAsFixed(1),
          'gpsDegraded': gpsDegraded,
          'degradedModeActive': _degradedMode.isDegraded,
          'threshold': _isMetroLeg ? 2000.0 : 150.0,
        });
      }
      return;
    }

    final newMode = _isMetroLeg ? EkfMode.metro : EkfMode.surface;
    _pipeline.setMode(newMode);
    
    if (logVerbosity >= 1 && oldMode != newMode) {
      _log('MODE', '🟢 Exiting to ${newMode.name}', {
        'sigmaS': sigmaS.toStringAsFixed(1),
        'gpsDegraded': gpsDegraded,
      });
    }
  }

  void _updateInnovationTimer(Duration timestamp) {
    if (_lastImuTs == null) {
      _lastImuTs = timestamp;
      return;
    }
    final dt = (timestamp - _lastImuTs!).inMicroseconds / 1e6;
    _lastImuTs = timestamp;
    if (dt <= 0) return;
    if (_lastInnovationSigma > 3.0) {
      _innovationHighSeconds += dt;
    } else {
      _innovationHighSeconds = 0.0;
    }
  }

  void _pushVarianceSample(double timestampSeconds, ImuSample sample) {
    final accelMag = math.sqrt(
      sample.ax * sample.ax + sample.ay * sample.ay + sample.az * sample.az,
    );
    final gyroMag = math.sqrt(
      sample.gx * sample.gx + sample.gy * sample.gy + sample.gz * sample.gz,
    );
    _accelVarWindow.add(accelMag);
    _gyroVarWindow.add(gyroMag);
    _varTimes.add(timestampSeconds);
    _trimWindow(
      times: _varTimes,
      values: [_accelVarWindow, _gyroVarWindow],
      windowSeconds: 0.75,
    );
  }

  void _pushFeatureSample(double timestampSeconds, ImuSample sample) {
    final accelMag = math.sqrt(
      sample.ax * sample.ax + sample.ay * sample.ay + sample.az * sample.az,
    );
    final gyroMag = math.sqrt(
      sample.gx * sample.gx + sample.gy * sample.gy + sample.gz * sample.gz,
    );
    _accelFeatureWindow.add(accelMag);
    _gyroFeatureWindow.add(gyroMag);
    _featureTimes.add(timestampSeconds);
    _trimWindow(
      times: _featureTimes,
      values: [_accelFeatureWindow, _gyroFeatureWindow],
      windowSeconds: 2.56,
    );
  }

  MotionFeatures? _extractMotionFeatures() {
    if (_featureTimes.length < 8) return null;
    final duration = _featureTimes.last - _featureTimes.first;
    if (duration <= 0) return null;
    final sampleRateHz = (_featureTimes.length - 1) / duration;
    if (sampleRateHz.isNaN || sampleRateHz.isInfinite) return null;
    return _featureExtractor.extract(
      accelMagnitudes: List<double>.from(_accelFeatureWindow),
      gyroMagnitudes: List<double>.from(_gyroFeatureWindow),
      sampleRateHz: sampleRateHz,
    );
  }

  MotionState _classifyMotion({
    required double accelVariance,
    required double gyroVariance,
    required MotionFeatures? features,
    required Duration timestamp,
  }) {
    final recentZupt =
        _lastZuptTs != null &&
        (timestamp - _lastZuptTs!).inMilliseconds <= 5000;
    final fftEnabled = _fftEnabled && gpsDegraded && features != null;
    final fftWalkEnergy = features?.fftWalkEnergy ?? 0.0;
    final fftTrainEnergy = features?.fftTrainEnergy ?? 0.0;

    final isDegraded = _gpsDetector.isDegraded || publicState.mode == EkfMode.degraded;
    
    // Compute recent max aFwd for breaking false stationary during GPS dropout
    final recentMaxAFwd = _recentAFwdWindow.isEmpty 
        ? null 
        : _recentAFwdWindow.reduce((a, b) => a > b ? a : b);
    
    final result = _motionClassifier.classify(
      accelVariance: accelVariance,
      gyroVariance: gyroVariance,
      fftWalkEnergy: fftWalkEnergy,
      fftTrainEnergy: fftTrainEnergy,
      sigmaV: publicState.sigmaV,
      recentZupt: recentZupt,
      innovationSigma: _lastInnovationSigma,
      innovationHighSeconds: _innovationHighSeconds,
      ekfWeight: 0.3,
      fftEnabled: fftEnabled,
      ekfVelocity: publicState.v,  // Pass EKF velocity for hard gate
      isDegraded: isDegraded,  // Skip velocity gate when velocity is unreliable
      recentMaxAFwd: recentMaxAFwd,  // For detecting movement during GPS dropout
    );
    
    // Debug: log when motion classification happens during degraded mode
    if (isDegraded && logVerbosity >= 1) {
      _log('MOTION', 'Classification during GPS dropout', {
        'result': result.name,
        'recentMaxAFwd': recentMaxAFwd?.toStringAsFixed(3) ?? 'null',
        'accelVar': accelVariance.toStringAsFixed(4),
        'gyroVar': gyroVariance.toStringAsFixed(4),
        'v': publicState.v.toStringAsFixed(3),
      });
    }
    
    return result;
  }

  MotionState _applyMotionDurationGate(
    MotionState candidate,
    double timestampSeconds,
  ) {
    if (_lastMotionDecisionAt != null &&
        timestampSeconds - _lastMotionDecisionAt! < _motionStepSeconds) {
      return _motionState;
    }
    _lastMotionDecisionAt = timestampSeconds;

    if (candidate == _motionState) {
      _pendingMotion = null;
      _pendingMotionCount = 0;
      return _motionState;
    }

    if (_pendingMotion != candidate) {
      _pendingMotion = candidate;
      _pendingMotionCount = 1;
      return _motionState;
    }

    _pendingMotionCount += 1;
    if (_pendingMotionCount >= 2) {
      _pendingMotion = null;
      _pendingMotionCount = 0;
      return candidate;
    }

    return _motionState;
  }

  void _maybeUpdateZupt({
    required Duration timestamp,
    required MotionState motion,
    required double accelVariance,
    required double gyroVariance,
  }) {
    if (accelVariance.isInfinite || gyroVariance.isInfinite) return;
    onZuptCandidate(
      timestamp: timestamp,
      motion: motion,
      accelVariance: accelVariance,
      gyroVariance: gyroVariance,
    );
  }

  double _forwardAccel(ImuSample sample, TiltFilterOutput tiltOutput) {
    const gravity = 9.81;
    final g = tiltOutput.gravityDevice;
    final ax = sample.ax - g[0] * gravity;
    final ay = sample.ay - g[1] * gravity;
    final az = sample.az - g[2] * gravity;
    final world = _mul3x3Vec(tiltOutput.rDeviceToWorld, [ax, ay, az]);

    final s = publicState.s;
    final tangent = _route.tangentAt(s.isNaN ? 0.0 : s);
    final aFwd = world[0] * tangent[0] + world[1] * tangent[1];
    
    // Static bias initialization: collect aFwd samples when stationary pre-GPS.
    // This estimates the device's accelerometer bias before DR begins.
    // The bias is subtracted from future aFwd values during DR.
    if (!_ekfInitialized && !_biasInitialized) {
      // Only collect when IMU is quiet (likely stationary)
      final accelVar = _variance(_accelVarWindow);
      final gyroVar = _variance(_gyroVarWindow);
      if (accelVar < 0.5 && gyroVar < 0.1 && accelVar.isFinite) {
        _biasInitWindow.add(aFwd);
        if (_biasInitWindow.length > _biasInitMaxSamples) {
          _biasInitWindow.removeAt(0);
        }
        
        // Estimate bias when we have enough samples
        if (_biasInitWindow.length >= _biasInitMinSamples) {
          final mean = _biasInitWindow.reduce((a, b) => a + b) / _biasInitWindow.length;
          // Only accept bias if it's reasonable (< 0.5 m/s²)
          if (mean.abs() < 0.5) {
            _estimatedInitialBias = mean;
            _biasInitialized = true;
            _log('BIAS', 'Static bias estimated', {
              'bias': mean.toStringAsFixed(4),
              'samples': _biasInitWindow.length,
            });
          }
        }
      }
    }

    if (_pipeline.publicState.mode == EkfMode.degraded) {
       _log('PHYSICS', 'Degraded Accel Debug', {
         'raw': '[${sample.ax.toStringAsFixed(2)}, ${sample.ay.toStringAsFixed(2)}, ${sample.az.toStringAsFixed(2)}]',
         'g_dev': '[${g[0].toStringAsFixed(2)}, ${g[1].toStringAsFixed(2)}, ${g[2].toStringAsFixed(2)}]',
         'world': '[${world[0].toStringAsFixed(2)}, ${world[1].toStringAsFixed(2)}, ${world[2].toStringAsFixed(2)}]',
         'tangent': '[${tangent[0].toStringAsFixed(2)}, ${tangent[1].toStringAsFixed(2)}]',
         'aFwd': aFwd.toStringAsFixed(3),
         if (_estimatedInitialBias != null) 'initBias': _estimatedInitialBias!.toStringAsFixed(4),
       });
    }

    // Apply estimated initial bias correction during DR
    // This compensates for device-specific accelerometer offset
    if (_estimatedInitialBias != null && _pipeline.publicState.mode == EkfMode.degraded) {
      return aFwd - _estimatedInitialBias!;
    }

    return aFwd;
  }

  void _trimWindow({
    required List<double> times,
    required List<List<double>> values,
    required double windowSeconds,
  }) {
    if (times.isEmpty) return;
    final cutoff = times.last - windowSeconds;
    int removeCount = 0;
    while (removeCount < times.length && times[removeCount] < cutoff) {
      removeCount++;
    }
    if (removeCount == 0) return;
    times.removeRange(0, removeCount);
    for (final list in values) {
      list.removeRange(0, removeCount);
    }
  }

  double _variance(List<double> values) {
    final n = values.length;
    if (n <= 1) return double.infinity;
    final mean = values.reduce((a, b) => a + b) / n;
    double sum = 0.0;
    for (final v in values) {
      final d = v - mean;
      sum += d * d;
    }
    return sum / n;
  }

  List<double> _mul3x3Vec(List<List<double>> a, List<double> v) {
    return [
      a[0][0] * v[0] + a[0][1] * v[1] + a[0][2] * v[2],
      a[1][0] * v[0] + a[1][1] * v[1] + a[1][2] * v[2],
      a[2][0] * v[0] + a[2][1] * v[1] + a[2][2] * v[2],
    ];
  }
}
