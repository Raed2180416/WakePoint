import 'dart:async';
// no math imports needed currently
import 'package:google_maps_flutter/google_maps_flutter.dart';
// import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/snap_to_route.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';

class RouteSwitchEvent {
  final String fromKey;
  final String toKey;
  final DateTime at;
  final List<LatLng>? geometry;
  final List<List<LatLng>>? inactivePolylines;

  RouteSwitchEvent({
    required this.fromKey,
    required this.toKey,
    DateTime? at,
    this.geometry,
    this.inactivePolylines,
  }) : at = at ?? DateTime.now();
}

/// Emitted when the rider is confidently snapped on-route yet net along-route
/// progress regresses (moves toward the origin, i.e. wrong direction / wrong
/// train) for a sustained window. Works on metro legs because it relies on the
/// sign of delta-progress (velocity projected onto the route tangent toward the
/// destination), NOT on lateral deviation.
class WrongDirectionAlert {
  final String activeKey;
  final double netRegressionMeters;
  final Duration sustainedFor;
  final bool isMetro;
  final DateTime at;

  WrongDirectionAlert({
    required this.activeKey,
    required this.netRegressionMeters,
    required this.sustainedFor,
    required this.isMetro,
    DateTime? at,
  }) : at = at ?? DateTime.now();
}

class ActiveRouteState {
  final String activeKey;
  final LatLng snapped;
  final double offsetMeters;
  final double progressMeters;
  final double remainingMeters;
  final String? pendingSwitchToKey;
  final double? pendingSwitchInSeconds;
  final bool isFinalAlarm;
  const ActiveRouteState({
    required this.activeKey,
    required this.snapped,
    required this.offsetMeters,
    required this.progressMeters,
    required this.remainingMeters,
    this.pendingSwitchToKey,
    this.pendingSwitchInSeconds,
    this.isFinalAlarm = false,
  });

  Map<String, dynamic> toJson() => {
    'activeKey': activeKey,
    'snapped': {'lat': snapped.latitude, 'lng': snapped.longitude},
    'offsetMeters': offsetMeters,
    'progressMeters': progressMeters,
    'remainingMeters': remainingMeters,
    'pendingSwitchToKey': pendingSwitchToKey,
    'pendingSwitchInSeconds': pendingSwitchInSeconds,
    'isFinalAlarm': isFinalAlarm,
  };

  factory ActiveRouteState.fromJson(Map<String, dynamic> json) {
    final s = json['snapped'] as Map<String, dynamic>;
    return ActiveRouteState(
      activeKey: json['activeKey'] as String,
      snapped: LatLng(s['lat'] as double, s['lng'] as double),
      offsetMeters: (json['offsetMeters'] as num).toDouble(),
      progressMeters: (json['progressMeters'] as num).toDouble(),
      remainingMeters: (json['remainingMeters'] as num).toDouble(),
      pendingSwitchToKey: json['pendingSwitchToKey'] as String?,
      pendingSwitchInSeconds:
          (json['pendingSwitchInSeconds'] as num?)?.toDouble(),
      isFinalAlarm: json['isFinalAlarm'] as bool? ?? false,
    );
  }
}

class ActiveRouteManager {
  final RouteRegistry registry;
  final Duration sustainDuration;
  final double
  switchMarginMeters; // candidate must be this much better in offset
  final Duration postSwitchBlackout;

  String? _activeKey;
  String? _candidateKey;

  // Use monotonic timers to avoid wall-clock jumps affecting countdowns
  Stopwatch? _candidateTimer;
  Stopwatch? _blackoutTimer;

  final _stateCtrl = StreamController<ActiveRouteState>.broadcast();
  final _switchCtrl = StreamController<RouteSwitchEvent>.broadcast();
  final _stationSnapCtrl = StreamController<StationSnapConfirmed>.broadcast();
  final _wrongDirCtrl = StreamController<WrongDirectionAlert>.broadcast();

  Stream<ActiveRouteState> get stateStream => _stateCtrl.stream;
  Stream<RouteSwitchEvent> get switchStream => _switchCtrl.stream;
  Stream<StationSnapConfirmed> get stationSnapStream => _stationSnapCtrl.stream;
  Stream<WrongDirectionAlert> get wrongDirectionStream => _wrongDirCtrl.stream;

  /// Per-sample delta-progress noise floor (m). Below this magnitude a progress
  /// change is treated as GPS jitter and neither accumulates nor resets state.
  static const double _dirNoiseEpsilonMeters = 5.0;

  String? get activeKey => _activeKey;

  /// Last station index that was snapped via EKF (for monotonic gating).
  int _lastEkfSnapIndex = -1;

  // --- G14/G15 wrong-direction detection config ---
  /// Minimum time of sustained backward motion before alerting.
  final Duration wrongDirectionSustain;
  /// Minimum net backward distance (m) accumulated during the sustain window.
  final double wrongDirectionMinNetRegressionMeters;
  /// Max lateral offset (m) for which we consider the rider "snapped on-route".
  /// Above this the snap/progress is ambiguous and we do not accuse the rider.
  final double onRouteMaxOffsetMeters;

  // --- G14/G15 wrong-direction detection state ---
  String? _dirKey;
  double? _dirLastProgress;
  double _dirNetRegression = 0.0;
  Stopwatch? _wrongDirTimer;
  bool _wrongDirActive = false;

  ActiveRouteManager({
    required this.registry,
    this.sustainDuration = const Duration(seconds: 6),
    this.switchMarginMeters = 50,
    this.postSwitchBlackout = const Duration(seconds: 5),
    this.wrongDirectionSustain = const Duration(seconds: 12),
    this.wrongDirectionMinNetRegressionMeters = 60.0,
    this.onRouteMaxOffsetMeters = 80.0,
  });

  void setActive(String key) {
    _activeKey = key;
    _candidateKey = null;
    // reset timers
    _candidateTimer?.stop();
    _candidateTimer = null;
    _blackoutTimer =
        Stopwatch()..start(); // start blackout immediately on activation

    // G14/G15: reset wrong-direction tracking on any (re)activation/switch so a
    // route change never carries a stale regression accumulator across routes.
    _dirKey = null;
    _dirLastProgress = null;
    _dirNetRegression = 0.0;
    _wrongDirTimer = null;
    _wrongDirActive = false;
  }

  void ingestPosition(LatLng rawPosition, {bool isFinalAlarm = false}) {
    if (_activeKey == null || registry.entries.isEmpty) return;
    final active = registry.entries.firstWhere(
      (e) => e.key == _activeKey,
      orElse:
          () =>
              registry.entries.isNotEmpty
                  ? registry.entries.first
                  : throw StateError('No routes'),
    );

    // Snap to active route first
    final snapActive = _snapTo(active, rawPosition);
    registry.updateSessionState(
      active.key,
      lastSnapIndex: snapActive.segmentIndex,
      lastProgressMeters: snapActive.progressMeters,
    );

    // Candidate search near current location
    final candidates = registry.candidatesNear(
      rawPosition,
      radiusMeters: 1200,
      maxCandidates: 3,
    );
    String bestKey = active.key;
    double bestOffset = snapActive.lateralOffsetMeters;
    SnapResult bestSnap = snapActive;

    for (final c in candidates) {
      final s = c.key == active.key ? snapActive : _snapTo(c, rawPosition);
      if (s.lateralOffsetMeters + switchMarginMeters < bestOffset) {
        // Heading and progress consistency check (lightweight)
        final agree = _headingAgreement(c, s);
        if (agree > 0.3) {
          // require minimal agreement
          bestOffset = s.lateralOffsetMeters;
          bestSnap = s;
          bestKey = c.key;
        }
      }
    }

    // Handle candidate selection with sustain and blackout
    final now = DateTime.now();
    final inBlackout =
        _blackoutTimer != null &&
        _blackoutTimer!.isRunning &&
        _blackoutTimer!.elapsed < postSwitchBlackout;
    if (bestKey != active.key && !inBlackout) {
      if (_candidateKey != bestKey) {
        _candidateKey = bestKey;
        _candidateTimer?.stop();
        _candidateTimer = Stopwatch()..start();
      } else {
        final elapsedOk =
            _candidateTimer != null &&
            _candidateTimer!.elapsed >= sustainDuration;
        if (elapsedOk) {
          // Switch routes
          final fromKey = active.key;
          _activeKey = bestKey;
          _candidateKey = null;
          _candidateTimer?.stop();
          _candidateTimer = null;
          _blackoutTimer = Stopwatch()..start();

          // Fetch geometry for the event
          List<LatLng>? points;
          try {
            final entry = registry.entries.firstWhere((e) => e.key == bestKey);
            points = entry.points;
          } catch (_) {}

          _switchCtrl.add(
            RouteSwitchEvent(
              fromKey: fromKey,
              toKey: bestKey,
              at: now,
              geometry: points,
            ),
          );
        }
      }
    } else {
      _candidateKey = null;
      _candidateTimer?.stop();
      _candidateTimer = null;
    }

    // IMPORTANT: Do not mix candidate snap/progress with the active route metrics.
    // Only use the candidate snap values after an actual switch has occurred.
    final currentActiveKey = _activeKey!;
    final activeEntry = registry.entries.firstWhere(
      (e) => e.key == currentActiveKey,
    );

    final SnapResult snapForState;
    if (currentActiveKey == active.key) {
      snapForState = snapActive;
    } else if (currentActiveKey == bestKey) {
      // We just switched to the bestKey candidate.
      snapForState = bestSnap;
    } else {
      // Fallback: recompute snap for whichever key is active.
      snapForState = _snapTo(activeEntry, rawPosition);
    }

    final progress = snapForState.progressMeters;
    final remaining = (activeEntry.lengthMeters - progress).clamp(
      0.0,
      double.infinity,
    );
    double? pendingSecs;
    String? pendingKey;
    final inBlackout2 =
        _blackoutTimer != null &&
        _blackoutTimer!.isRunning &&
        _blackoutTimer!.elapsed < postSwitchBlackout;
    if (_candidateKey != null && _candidateTimer != null && !inBlackout2) {
      final elapsed = _candidateTimer!.elapsed;
      final left = sustainDuration - elapsed;
      if (left > Duration.zero) {
        // Clamp to sustainDuration to avoid spikes from any anomalies
        final leftMs = left.inMilliseconds.clamp(
          0,
          sustainDuration.inMilliseconds,
        );
        pendingSecs = leftMs / 1000.0;
        pendingKey = _candidateKey;
      }
    }

    // G14/G15: signed along-route direction / wrong-train detection. `now`,
    // `progress`, `snapForState` and `activeEntry` are already in scope above.
    _updateDirection(
      currentActiveKey,
      progress,
      snapForState.lateralOffsetMeters,
      activeEntry.mode == 'transit',
      now,
    );

    _stateCtrl.add(
      ActiveRouteState(
        activeKey: currentActiveKey,
        snapped: snapForState.snappedPoint,
        offsetMeters: snapForState.lateralOffsetMeters,
        progressMeters: progress,
        remainingMeters: remaining,
        pendingSwitchToKey: pendingKey,
        pendingSwitchInSeconds: pendingSecs,
        isFinalAlarm: isFinalAlarm,
      ),
    );
  }

  SnapResult _snapTo(RouteEntry entry, LatLng p) {
    return SnapToRouteEngine.snap(
      point: p,
      polyline: entry.points,
      precomputedCumMeters: entry.cumMeters,
      hintIndex: entry.lastSnapIndex,
      searchWindow: 30,
    );
  }

  double _headingAgreement(RouteEntry entry, SnapResult s) {
    // Estimate agreement from the sign of delta-progress on the candidate route
    // (delta-progress is velocity projected onto the route tangent toward the
    // destination). No gyro/compass needed.
    final idx = s.segmentIndex;
    if (idx < 0 || idx >= entry.points.length - 1) return 0.0;
    final last = entry.lastProgressMeters;
    if (last == null) {
      // No history yet on this candidate: neutral acceptance (legacy behavior).
      return 0.5;
    }
    final delta = s.progressMeters - last;
    if (delta < -_dirNoiseEpsilonMeters) return 0.0; // moving backward on it
    if (delta > _dirNoiseEpsilonMeters) return 1.0; // clear forward motion
    return 0.5; // near-stationary / within noise
  }

  /// G14/G15: signed along-route direction check for the ACTIVE route.
  /// Uses the sign of delta-progress; works on metro legs because it does not
  /// rely on lateral deviation. Emits a WrongDirectionAlert when the rider is
  /// snapped on-route yet net progress regresses (toward origin) for a sustained
  /// window. Forward motion resets the accumulator.
  void _updateDirection(
    String activeKey,
    double progress,
    double offsetMeters,
    bool isMetro,
    DateTime now,
  ) {
    // Reset whenever the active route changes (progress domain changes).
    if (_dirKey != activeKey) {
      _dirKey = activeKey;
      _dirLastProgress = progress;
      _dirNetRegression = 0.0;
      _wrongDirTimer = null;
      _wrongDirActive = false;
      return;
    }

    final last = _dirLastProgress;
    _dirLastProgress = progress;
    if (last == null) return;

    final delta = progress - last; // + toward destination, - toward origin

    // Only evaluate while confidently snapped on-route.
    if (offsetMeters > onRouteMaxOffsetMeters) {
      _dirNetRegression = 0.0;
      _wrongDirTimer = null;
      _wrongDirActive = false;
      return;
    }

    if (delta > _dirNoiseEpsilonMeters) {
      // Clear forward motion -> reset any accumulating wrong-direction state.
      _dirNetRegression = 0.0;
      _wrongDirTimer = null;
      _wrongDirActive = false;
    } else if (delta < -_dirNoiseEpsilonMeters) {
      // Backward motion beyond noise: accumulate and start the sustain timer.
      _dirNetRegression += -delta;
      _wrongDirTimer ??= (Stopwatch()..start());

      final sustainedLongEnough =
          _wrongDirTimer!.elapsed >= wrongDirectionSustain;
      final regressedFarEnough =
          _dirNetRegression >= wrongDirectionMinNetRegressionMeters;

      if (sustainedLongEnough && regressedFarEnough && !_wrongDirActive) {
        _wrongDirActive = true; // latch: emit once per sustained episode
        _wrongDirCtrl.add(
          WrongDirectionAlert(
            activeKey: activeKey,
            netRegressionMeters: _dirNetRegression,
            sustainedFor: _wrongDirTimer!.elapsed,
            isMetro: isMetro,
            at: now,
          ),
        );
      }
    }
    // |delta| within noise: hold state (neither reset nor accumulate).
  }

  /// Handle a confirmed station snap from EKF per §24.2.
  /// The event has already passed the EKF-side confidence gates (σ≤30m, single
  /// candidate, monotonic within EKF). This method applies the ARM-side gate
  /// (monotonic station index relative to ARM state) and emits for UI/telemetry.
  void onStationSnapConfirmed(StationSnapConfirmed event) {
    // §24.2 ARM-side monotonic gate: station index >= last snapped index
    if (event.stationIndex <= _lastEkfSnapIndex) return;

    _lastEkfSnapIndex = event.stationIndex;
    _stationSnapCtrl.add(event);

    // Update session state if active route exists
    if (_activeKey != null) {
      try {
        final entry = registry.entries.firstWhere((e) => e.key == _activeKey);
        registry.updateSessionState(
          entry.key,
          lastProgressMeters: event.stationMeters,
        );
      } catch (_) {
        // Route not found, ignore
      }
    }
  }

  /// Reset the EKF snap index (call on route change or session start).
  void resetStationSnapIndex() {
    _lastEkfSnapIndex = -1;
  }

  void dispose() {
    _stateCtrl.close();
    _switchCtrl.close();
    _stationSnapCtrl.close();
    _wrongDirCtrl.close();
  }
}
