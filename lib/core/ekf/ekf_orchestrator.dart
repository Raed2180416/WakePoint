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

class EkfOrchestrator {
  EkfOrchestrator({
    required RouteGeometry route,
    EkfConfig? config,
    GpsDegradationDetector? gpsDetector,
    MotionClassifier? motionClassifier,
    ZuptDetector? zuptDetector,
  })  : _pipeline = EkfPipeline(config: config ?? const EkfConfig(), route: route),
        _route = route,
        _gpsDetector = gpsDetector ?? GpsDegradationDetector(),
        _motionClassifier = motionClassifier ?? MotionClassifier(),
        _zuptDetector = zuptDetector ?? ZuptDetector();

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

  Duration? _lastImuTs;
  Duration? _lastZuptTs;
  double _lastInnovationSigma = 0.0;
  double _innovationHighSeconds = 0.0;
  bool _fftEnabled = true;
  bool _predictionEnabled = false;
  MotionState _motionState = MotionState.vehicle;
  bool _hasGpsFix = false;
  MotionState? _pendingMotion;
  int _pendingMotionCount = 0;
  double? _lastMotionDecisionAt;
  static const double _motionStepSeconds = 1.28;

  List<double> _stationMeters = const [];
  bool _isMetroLeg = false;
  int _lastSnappedStationIndex = -1;

  /// Callback for station snap confirmed events (§24.2 gated).
  void Function(StationSnapConfirmed)? onStationSnapConfirmed;

  bool get gpsDegraded => _gpsDetector.isDegraded;

  EkfPublicState get publicState => _pipeline.publicState;

  void onImuSample(ImuSample sample) {
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

    _motionState = _applyMotionDurationGate(
      motion,
      timestampSeconds,
    );
    _pipeline.setMotionState(_motionState);
    _updateMode(sample.timestamp);
    _maybeUpdateZupt(
      timestamp: sample.timestamp,
      motion: _motionState,
      accelVariance: accelVariance,
      gyroVariance: gyroVariance,
    );

    if (!_predictionEnabled) {
      return;
    }

    if (tiltOutput == null) {
      _pipeline.onImuSample(sample);
      return;
    }

    final aFwd = _forwardAccel(sample, tiltOutput);
    _pipeline.onForwardAccel(sample.timestamp, aFwd);
  }

  void onGpsFix(GpsFix fix, {required double innovationSigma}) {
    if (innovationSigma.isFinite) {
      _lastInnovationSigma = innovationSigma;
    }
    _predictionEnabled = true;
    _hasGpsFix = true;
    _gpsDetector.onGpsFix(
      timestamp: fix.timestamp,
      hasFix: true,
      accuracyMeters: fix.accuracyMeters,
      innovationSigma: innovationSigma,
    );
    _pipeline.onGpsFix(fix);
  }

  void onGpsFixAuto(GpsFix fix) {
    final sGps = _route.projectLatLng(fix.lat, fix.lng);
    if (sGps.isNaN) return;

    final innovationSigma = _pipeline.innovationSigmaForS(sGps);
    onGpsFix(fix, innovationSigma: innovationSigma);
  }

  void setFftEnabled(bool enabled) {
    _fftEnabled = enabled;
  }

  void setStationContext({required List<double> stationMeters, required bool isMetroLeg}) {
    _stationMeters = stationMeters;
    _isMetroLeg = isMetroLeg;
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
    _motionState = MotionState.vehicle;
    _pendingMotion = null;
    _pendingMotionCount = 0;
    _lastMotionDecisionAt = null;
    _hasGpsFix = false;
    _lastSnappedStationIndex = -1;
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
    final confirmed = _zuptDetector.update(
      timestamp: timestamp,
      motion: motion,
      velocityMps: publicState.v,
      accelVariance: accelVariance,
      gyroVariance: gyroVariance,
    );
    if (confirmed) {
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
      );
      if (assoc != null) {
        _pipeline.onStationCandidates([
          StationCandidate(assoc.stationMeters),
        ]);

        // §24.2 confidence gate for ARM update:
        // - σ_s ≤ 30m after snap update
        // - Single candidate (enforced by StationAssociation)
        // - Monotonic station index
        final sigmaAfterSnap = _pipeline.publicState.sigmaS;
        const sigmaGate = 30.0;
        final isMonotonic = assoc.stationIndex > _lastSnappedStationIndex;

        if (sigmaAfterSnap <= sigmaGate && isMonotonic) {
          _lastSnappedStationIndex = assoc.stationIndex;
          onStationSnapConfirmed?.call(
            StationSnapConfirmed(
              stationIndex: assoc.stationIndex,
              stationMeters: assoc.stationMeters,
              sigmaS: sigmaAfterSnap,
              timestamp: DateTime.now(),
            ),
          );
        }
      }
    }
  }

  void _updateMode(Duration timestamp) {
    if (!_hasGpsFix) {
      _pipeline.setMode(EkfMode.degraded);
      return;
    }
    _degradedMode.update(
      timestamp: timestamp,
      sigmaS: publicState.sigmaS,
      gpsRecovered: !_gpsDetector.isDegraded,
    );

    if (_degradedMode.isDegraded) {
      _pipeline.setMode(EkfMode.degraded);
      return;
    }

    _pipeline.setMode(_isMetroLeg ? EkfMode.metro : EkfMode.surface);
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
        _lastZuptTs != null && (timestamp - _lastZuptTs!).inMilliseconds <= 5000;
    final fftEnabled = _fftEnabled && gpsDegraded && features != null;
    final fftWalkEnergy = features?.fftWalkEnergy ?? 0.0;
    final fftTrainEnergy = features?.fftTrainEnergy ?? 0.0;

    return _motionClassifier.classify(
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
    );
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
    final world = _mul3x3Vec(
      tiltOutput.rDeviceToWorld,
      [ax, ay, az],
    );

    final s = publicState.s;
    final tangent = _route.tangentAt(s.isNaN ? 0.0 : s);
    return world[0] * tangent[0] + world[1] * tangent[1];
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
