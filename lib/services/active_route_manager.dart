import 'dart:async';
// no math imports needed currently
import 'package:google_maps_flutter/google_maps_flutter.dart';
// import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/snap_to_route.dart';

class RouteSwitchEvent {
  final String fromKey;
  final String toKey;
  final DateTime at;
  RouteSwitchEvent({required this.fromKey, required this.toKey, DateTime? at}) : at = at ?? DateTime.now();
}

class ActiveRouteState {
  final String activeKey;
  final LatLng snapped;
  final double offsetMeters;
  final double progressMeters;
  final double remainingMeters;
  final String? pendingSwitchToKey;
  final double? pendingSwitchInSeconds;
  const ActiveRouteState({
    required this.activeKey,
    required this.snapped,
    required this.offsetMeters,
    required this.progressMeters,
    required this.remainingMeters,
    this.pendingSwitchToKey,
    this.pendingSwitchInSeconds,
  });
}

class ActiveRouteManager {
  final RouteRegistry registry;
  final Duration sustainDuration;
  final double switchMarginMeters; // candidate must be this much better in offset
  final Duration postSwitchBlackout;

  String? _activeKey;
  // removed: wall-clock based candidate since
  String? _candidateKey;
  // removed: wall-clock based last switch time

  // Use monotonic timers to avoid wall-clock jumps affecting countdowns
  Stopwatch? _candidateTimer;
  Stopwatch? _blackoutTimer;

  final _stateCtrl = StreamController<ActiveRouteState>.broadcast();
  final _switchCtrl = StreamController<RouteSwitchEvent>.broadcast();

  Stream<ActiveRouteState> get stateStream => _stateCtrl.stream;
  Stream<RouteSwitchEvent> get switchStream => _switchCtrl.stream;

  ActiveRouteManager({
    required this.registry,
    this.sustainDuration = const Duration(seconds: 6),
    this.switchMarginMeters = 50,
    this.postSwitchBlackout = const Duration(seconds: 5),
  });

  void setActive(String key) {
    _activeKey = key;
    _candidateKey = null;
    // reset timers
    _candidateTimer?.stop();
    _candidateTimer = null;
    _blackoutTimer = Stopwatch()..start(); // start blackout immediately on activation
  }

  void ingestPosition(LatLng rawPosition) {
    if (_activeKey == null) return;
    final active = registry.entries.firstWhere((e) => e.key == _activeKey, orElse: () => registry.entries.isNotEmpty ? registry.entries.first : throw StateError('No routes'));

    // Snap to active route first
    final snapActive = _snapTo(active, rawPosition);
    registry.updateSessionState(active.key, lastSnapIndex: snapActive.segmentIndex, lastProgressMeters: snapActive.progressMeters);

    // Candidate search near current location
    final candidates = registry.candidatesNear(rawPosition, radiusMeters: 1200, maxCandidates: 3);
    String bestKey = active.key;
    double bestOffset = snapActive.lateralOffsetMeters;
    SnapResult bestSnap = snapActive;

    for (final c in candidates) {
      final s = c.key == active.key ? snapActive : _snapTo(c, rawPosition);
      if (s.lateralOffsetMeters + switchMarginMeters < bestOffset) {
        // Heading and progress consistency check (lightweight)
        final agree = _headingAgreement(c, s);
        if (agree > 0.3) { // require minimal agreement
          bestOffset = s.lateralOffsetMeters;
          bestSnap = s;
          bestKey = c.key;
        }
      }
    }

    // Handle candidate selection with sustain and blackout
    final now = DateTime.now();
    final inBlackout = _blackoutTimer != null && _blackoutTimer!.isRunning && _blackoutTimer!.elapsed < postSwitchBlackout;
    if (bestKey != active.key && !inBlackout) {
      if (_candidateKey != bestKey) {
        _candidateKey = bestKey;
        _candidateTimer?.stop();
        _candidateTimer = Stopwatch()..start();
      } else {
        final elapsedOk = _candidateTimer != null && _candidateTimer!.elapsed >= sustainDuration;
        if (elapsedOk) {
          // Switch routes
          final fromKey = active.key;
          _activeKey = bestKey;
          _candidateKey = null;
          _candidateTimer?.stop();
          _candidateTimer = null;
          _blackoutTimer = Stopwatch()..start();
          _switchCtrl.add(RouteSwitchEvent(fromKey: fromKey, toKey: bestKey, at: now));
        }
      }
    } else {
      _candidateKey = null;
      _candidateTimer?.stop();
      _candidateTimer = null;
    }

    final activeEntry = registry.entries.firstWhere((e) => e.key == _activeKey);
    final progress = bestKey == active.key ? snapActive.progressMeters : bestSnap.progressMeters;
    final remaining = (activeEntry.lengthMeters - progress).clamp(0.0, double.infinity);
    double? pendingSecs;
    String? pendingKey;
    final inBlackout2 = _blackoutTimer != null && _blackoutTimer!.isRunning && _blackoutTimer!.elapsed < postSwitchBlackout;
    if (_candidateKey != null && _candidateTimer != null && !inBlackout2) {
      final elapsed = _candidateTimer!.elapsed;
      final left = sustainDuration - elapsed;
      if (left > Duration.zero) {
        // Clamp to sustainDuration to avoid spikes from any anomalies
        final leftMs = left.inMilliseconds.clamp(0, sustainDuration.inMilliseconds);
        pendingSecs = leftMs / 1000.0;
        pendingKey = _candidateKey;
      }
    }
    _stateCtrl.add(ActiveRouteState(
      activeKey: _activeKey!,
      snapped: bestKey == active.key ? snapActive.snappedPoint : bestSnap.snappedPoint,
      offsetMeters: bestKey == active.key ? snapActive.lateralOffsetMeters : bestSnap.lateralOffsetMeters,
      progressMeters: progress,
      remainingMeters: remaining,
      pendingSwitchToKey: pendingKey,
      pendingSwitchInSeconds: pendingSecs,
    ));
  }

  SnapResult _snapTo(RouteEntry entry, LatLng p) {
    return SnapToRouteEngine.snap(
      point: p,
      polyline: entry.points,
      hintIndex: entry.lastSnapIndex,
      searchWindow: 30,
    );
  }

  double _headingAgreement(RouteEntry entry, SnapResult s) {
    // Estimate local segment heading at snapped segment
    final idx = s.segmentIndex;
    if (idx < 0 || idx >= entry.points.length - 1) return 0.0;
    // Without user heading history, approximate agreement by ensuring progress increases
    final last = entry.lastProgressMeters ?? 0.0;
    final progressOk = s.progressMeters >= last - 10; // allow small regression
    if (!progressOk) return 0.0;
    // Return nominal agreement (could be enhanced with gyro/compass later)
    return 0.5;
  }

  void dispose() {
    _stateCtrl.close();
    _switchCtrl.close();
  }
}
