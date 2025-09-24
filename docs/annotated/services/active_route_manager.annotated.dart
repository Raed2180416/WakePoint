// Annotated copy of lib/services/active_route_manager.dart
// Purpose: Explain local route switching with sustain window, blackout, and snapping.

import 'dart:async'; // Streams for state and events
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng type for GPS
import 'package:geowake2/services/route_registry.dart'; // Route entries and state
import 'package:geowake2/services/snap_to_route.dart'; // Snapping engine and result

// Event published when the active route changes locally (not a network reroute).
class RouteSwitchEvent {
  final String fromKey; // Previously active route key
  final String toKey;   // Newly active route key
  final DateTime at;    // Switch timestamp
  RouteSwitchEvent({required this.fromKey, required this.toKey, DateTime? at}) : at = at ?? DateTime.now();
}

// Snapshot of active routing context for the UI/observers.
class ActiveRouteState {
  final String activeKey;            // Key of the active route
  final LatLng snapped;              // Snapped position on the active polyline
  final double offsetMeters;         // Lateral distance from raw position to polyline
  final double progressMeters;       // Traveled distance along the active route
  final double remainingMeters;      // Remaining distance on the active route
  final String? pendingSwitchToKey;  // Candidate route we're counting down to
  final double? pendingSwitchInSeconds; // Seconds left before switch (sustain window)
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
  final RouteRegistry registry;               // Source of candidate routes and session hints
  final Duration sustainDuration;             // Required time a better route must remain better
  final double switchMarginMeters;            // How much better (offset) a candidate must be
  final Duration postSwitchBlackout;          // Ignore switching for this time after a switch

  String? _activeKey;                         // Current active route key
  String? _candidateKey;                      // Current candidate route key

  // Monotonic timers avoid issues with wall-clock changes (e.g., device time adjustments)
  Stopwatch? _candidateTimer;                 // Counts how long the candidate stayed better
  Stopwatch? _blackoutTimer;                  // Counts time since last switch to enforce blackout

  final _stateCtrl = StreamController<ActiveRouteState>.broadcast();
  final _switchCtrl = StreamController<RouteSwitchEvent>.broadcast();

  Stream<ActiveRouteState> get stateStream => _stateCtrl.stream; // For UI/state observers
  Stream<RouteSwitchEvent> get switchStream => _switchCtrl.stream; // For analytics/logging

  ActiveRouteManager({
    required this.registry,
    this.sustainDuration = const Duration(seconds: 6),
    this.switchMarginMeters = 50,
    this.postSwitchBlackout = const Duration(seconds: 5),
  });

  // Explicitly set the active route (e.g., at start or after network reroute)
  void setActive(String key) {
    _activeKey = key;
    _candidateKey = null;
    _candidateTimer?.stop();
    _candidateTimer = null;
    _blackoutTimer = Stopwatch()..start(); // Start blackout immediately to prevent oscillation
  }

  // Main entry: feed raw GPS positions; emits state and possibly switch events
  void ingestPosition(LatLng rawPosition) {
    if (_activeKey == null) return; // No active route yet
    final active = registry.entries.firstWhere(
      (e) => e.key == _activeKey,
      orElse: () => registry.entries.isNotEmpty ? registry.entries.first : (throw StateError('No routes')),
    );

    // 1) Snap current position to the active route
    final snapActive = _snapTo(active, rawPosition);
    registry.updateSessionState(active.key, lastSnapIndex: snapActive.segmentIndex, lastProgressMeters: snapActive.progressMeters);

    // 2) Look for nearby route candidates and evaluate offset advantage
    final candidates = registry.candidatesNear(rawPosition, radiusMeters: 1200, maxCandidates: 3);
    String bestKey = active.key;
    double bestOffset = snapActive.lateralOffsetMeters;
    SnapResult bestSnap = snapActive;

    for (final c in candidates) {
      final s = c.key == active.key ? snapActive : _snapTo(c, rawPosition);
      if (s.lateralOffsetMeters + switchMarginMeters < bestOffset) {
        // Lightweight heading/progress agreement gate to avoid backwards switches
        final agree = _headingAgreement(c, s);
        if (agree > 0.3) {
          bestOffset = s.lateralOffsetMeters;
          bestSnap = s;
          bestKey = c.key;
        }
      }
    }

    // 3) Sustain window and post-switch blackout handling
    final now = DateTime.now();
    final inBlackout = _blackoutTimer != null && _blackoutTimer!.isRunning && _blackoutTimer!.elapsed < postSwitchBlackout;
    if (bestKey != active.key && !inBlackout) {
      if (_candidateKey != bestKey) {
        // New candidate: start counting
        _candidateKey = bestKey;
        _candidateTimer?.stop();
        _candidateTimer = Stopwatch()..start();
      } else {
        final elapsedOk = _candidateTimer != null && _candidateTimer!.elapsed >= sustainDuration;
        if (elapsedOk) {
          // Perform the switch
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
      // Candidate lost or still in blackout: clear countdown
      _candidateKey = null;
      _candidateTimer?.stop();
      _candidateTimer = null;
    }

    // 4) Emit state snapshot with pending-switch countdown (if any)
    final activeEntry = registry.entries.firstWhere((e) => e.key == _activeKey);
    final progress = bestKey == active.key ? snapActive.progressMeters : bestSnap.progressMeters;
    final remaining = (activeEntry.lengthMeters - progress).clamp(0.0, double.infinity);
    double? pendingSecs;
    String? pendingKey;
    final inBlackout2 = _blackoutTimer != null && _blackoutTimer!.isRunning && _blackoutTimer!.elapsed < postSwitchBlackout;
    if (_candidateKey != null && _candidateTimer != null && !inBlackout2) {
      final left = sustainDuration - _candidateTimer!.elapsed;
      if (left > Duration.zero) {
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

  // Helper: snap a point to an entry's polyline, using session hint index to speed up
  SnapResult _snapTo(RouteEntry entry, LatLng p) {
    return SnapToRouteEngine.snap(
      point: p,
      polyline: entry.points,
      // P1: Use precomputed cumulative distances to compute progress cheaply
      precomputedCumMeters: entry.cumMeters,
      hintIndex: entry.lastSnapIndex,
      searchWindow: 30,
    );
  }

  // Minimal agreement heuristic: ensure progress isn't regressing badly
  double _headingAgreement(RouteEntry entry, SnapResult s) {
    final idx = s.segmentIndex;
    if (idx < 0 || idx >= entry.points.length - 1) return 0.0;
    final last = entry.lastProgressMeters ?? 0.0;
    final progressOk = s.progressMeters >= last - 10; // allow small regression for noise
    if (!progressOk) return 0.0;
    return 0.5; // nominal agreement
  }

  void dispose() {
    _stateCtrl.close();
    _switchCtrl.close();
  }
}

/*
File summary: ActiveRouteManager maintains the current route, evaluates nearby alternatives
by comparing lateral offsets after snapping, gates switches with a sustain window and a
post-switch blackout to avoid oscillation, and emits state snapshots plus switch events.
The headingAgreement check is intentionally lightweight, relying on progress monotonicity.
P1 note: We now pass precomputed cumulative distances (cumMeters) from RouteRegistry into the snapping engine. This
reduces repeated per-call cumulative summations while preserving identical output values (behavior remains unchanged).
*/
