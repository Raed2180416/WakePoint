/// Deviation simulation controller.
///
/// Orchestrates GPS simulation with deviation pathfinding and time warp support.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../core/clock/app_clock.dart';
import '../services/testing/osm_graph.dart';
import '../services/testing/pathfinder.dart';
import 'constraint_logger.dart';
import 'simulation_state.dart';

/// Configuration for deviation simulation.
class DeviationSimulationConfig {
  const DeviationSimulationConfig({
    this.deviationDistanceM = 500,
    this.routeAvoidanceRadiusM = 100,
    this.routeAvoidancePenalty = 500,
    this.returnThresholdM = 30,
    this.defaultSpeedMps = 11.1, // 40 km/h
  });

  /// Target distance for deviation path.
  final double deviationDistanceM;

  /// Radius around route to penalize during deviation.
  final double routeAvoidanceRadiusM;

  /// Penalty applied to nodes near route.
  final double routeAvoidancePenalty;

  /// Distance threshold to consider "back on route".
  final double returnThresholdM;

  /// Default simulation speed in m/s.
  final double defaultSpeedMps;
}

/// Result of a simulation tick.
class SimulationTickResult {
  SimulationTickResult({
    required this.position,
    required this.heading,
    required this.speedMps,
    required this.virtualTime,
    required this.distanceFromRoute,
  });

  /// Current simulated position.
  final LatLng position;

  /// Current heading in degrees.
  final double heading;

  /// Current speed in m/s.
  final double speedMps;

  /// Virtual time (may be warped).
  final DateTime virtualTime;

  /// Distance from original route in meters.
  final double distanceFromRoute;
}

/// Controller for deviation simulation with time warp support.
class DeviationSimulationController {
  DeviationSimulationController({
    OsmGraph? graph,
    DeviationSimulationConfig config = const DeviationSimulationConfig(),
  }) : _config = config,
       _graph = graph {
    if (_graph case final g?) {
      _setGraphInternal(g);
    }
  }

  final DeviationSimulationConfig _config;
  OsmGraph? _graph;
  Pathfinder? _pathfinder;
  DeviationPathfinder? _deviationPathfinder;

  void _setGraphInternal(OsmGraph graph) {
    _graph = graph;
    _pathfinder = Pathfinder(graph);
    _deviationPathfinder = DeviationPathfinder(
      graph: graph,
      basePathfinder: _pathfinder!,
    );
  }

  final SimulationStateMachine _stateMachine = SimulationStateMachine();
  final _positionController =
      StreamController<SimulationTickResult>.broadcast();

  // Route data
  List<LatLng> _originalRoute = [];
  List<LatLng> _currentPath = [];
  int _pathIndex = 0;
  double _progressInSegment = 0.0;

  // Deviation tracking
  List<LatLng> _deviationPath = [];
  String? _originalRouteId;

  // Position state
  LatLng? _currentPosition;
  double _currentHeading = 0.0;
  double _speedMps = 11.1; // 40 km/h default

  // Timing
  DateTime? _lastTickTime;
  Timer? _simulationTimer;

  // ─────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────

  /// Stream of position updates.
  Stream<SimulationTickResult> get positionStream => _positionController.stream;

  /// Current simulation state.
  SimulationState get state => _stateMachine.state;

  /// Stream of state changes.
  Stream<SimulationState> get stateStream => _stateMachine.stateStream;

  /// Current position (may be null if not started).
  LatLng? get currentPosition => _currentPosition;

  /// Whether an OSM graph is loaded and pathfinding is available.
  bool get hasGraph => _graph != null && _deviationPathfinder != null;

  /// Replace the OSM graph used for pathfinding.
  ///
  /// Intended for lazy-loading a local windowed graph on-demand.
  void setGraph(OsmGraph graph) {
    _setGraphInternal(graph);

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'OSM Graph Updated',
        description: '${graph.nodeCount} nodes, ${graph.edgeCount} edges',
      ),
    );
  }

  /// Current heading in degrees.
  double get currentHeading => _currentHeading;

  /// Current speed in m/s.
  double get speedMps => _speedMps;

  /// Set simulation speed in m/s.
  set speedMps(double value) {
    _speedMps = value.clamp(0.3, 44.4); // 1-160 km/h
  }

  /// Current warp factor (delegates to AppClock).
  double get warpFactor => AppClock().warpFactor;

  /// Set warp factor.
  void setWarpFactor(double factor) {
    final oldFactor = AppClock().warpFactor;
    AppClock().setWarpFactor(factor);

    ConstraintLogger.instance.log(
      ConstraintEvent.warpFactorChange(
        timestamp: AppClock().now(),
        oldFactor: oldFactor,
        newFactor: factor,
      ),
    );
  }

  /// Original route being tracked.
  List<LatLng> get originalRoute => List.unmodifiable(_originalRoute);

  /// Original route ID (if provided during loadRoute).
  String? get originalRouteId => _originalRouteId;

  /// Current path being followed (may be deviation or return path).
  List<LatLng> get currentPath => List.unmodifiable(_currentPath);

  /// Deviation path if deviating.
  List<LatLng> get deviationPath => List.unmodifiable(_deviationPath);

  /// Progress along current path (0.0 to 1.0).
  double get progress {
    if (_currentPath.isEmpty) return 0.0;

    final totalSegments = _currentPath.length - 1;
    if (totalSegments <= 0) return 1.0;

    return ((_pathIndex + _progressInSegment) / totalSegments).clamp(0.0, 1.0);
  }

  /// Progress along original route (0.0 to 1.0) - for slider display.
  double get progressOnOriginalRoute {
    if (_originalRoute.isEmpty || _currentPosition == null) return 0.0;

    // If we're on the original route, use direct progress
    if (_stateMachine.isOnRoute && _currentPath == _originalRoute) {
      return progress;
    }

    // Otherwise, find nearest point on original route
    final (idx, segProgress) = _findNearestSegmentWithProgress(
      _currentPosition!,
      _originalRoute,
    );
    final totalSegments = _originalRoute.length - 1;
    if (totalSegments <= 0) return 1.0;
    return ((idx + segProgress) / totalSegments).clamp(0.0, 1.0);
  }

  /// Load a route to simulate.
  void loadRoute(List<LatLng> route, {String? routeId}) {
    _originalRoute = List.of(route);
    _originalRouteId = routeId;
    _currentPath = List.of(route);
    _pathIndex = 0;
    _progressInSegment = 0.0;
    _deviationPath = [];

    if (route.isNotEmpty) {
      _currentPosition = route.first;
      if (route.length > 1) {
        _currentHeading = _calculateHeading(route[0], route[1]);
      }
    }

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Route Loaded',
        description: '${route.length} points',
        details: {'routeId': routeId, 'pointCount': route.length},
      ),
    );
  }

  /// Start simulation.
  void start() {
    if (_originalRoute.isEmpty) return;

    AppClock().enableSimulation();
    _stateMachine.start();
    _lastTickTime = AppClock().now();

    _startSimulationLoop();

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Simulation Started',
      ),
    );
  }

  /// Stop simulation.
  void stop() {
    _stopSimulationLoop();
    AppClock().disableSimulation();
    _stateMachine.stop();

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Simulation Stopped',
      ),
    );
  }

  /// Start deviating from route.
  void startDeviation() {
    // Can only deviate when on route
    if (_stateMachine.state != SimulationState.onRoute) {
      ConstraintLogger.instance.log(
        ConstraintEvent.info(
          timestamp: AppClock().now(),
          title: 'Deviation Failed',
          description:
              'Can only deviate when on route (current: ${_stateMachine.state.name})',
        ),
      );
      return;
    }

    if (_currentPosition == null || _deviationPathfinder == null) {
      ConstraintLogger.instance.log(
        ConstraintEvent.info(
          timestamp: AppClock().now(),
          title: 'Deviation Failed',
          description:
              'No position or pathfinder available. '
              'graph=${_graph != null}, pathfinder=${_deviationPathfinder != null}',
        ),
      );
      return;
    }

    // Detailed diagnostic logging
    final pos = _currentPosition!;
    final graphBounds = _graph?.bounds;
    final graphStats = _graph?.stats;
    final inBounds = _graph?.containsPoint(pos) ?? false;

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Deviation Diagnostic',
        description:
            'Position: ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)} | '
            'In bounds: $inBounds | Nodes: ${graphStats?['nodeCount'] ?? 0}',
        details: {
          'position_lat': pos.latitude,
          'position_lon': pos.longitude,
          'graph_bounds': graphBounds?.toString() ?? 'null',
          'node_count': graphStats?['nodeCount'],
          'edge_count': graphStats?['edgeCount'],
          'in_bounds': inBounds,
        },
      ),
    );

    // Check if we have graph coverage for the current position
    final nearestNode = _graph?.nearestNode(
      pos,
      maxDistanceM: 2000, // Increased to 2km for diagnosis
    );

    if (nearestNode == null) {
      ConstraintLogger.instance.log(
        ConstraintEvent.info(
          timestamp: AppClock().now(),
          title: 'Deviation Failed',
          description:
              'No OSM roads within 2km. In bounds=$inBounds. '
              'Graph has ${graphStats?['nodeCount'] ?? 0} nodes.',
          details: {
            'position':
                '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}',
            'graph_bounds': graphBounds?.toString(),
            'in_bounds': inBounds,
          },
        ),
      );
      return;
    }

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Found nearest node',
        description:
            'Node ${nearestNode.index} at ${nearestNode.lat.toStringAsFixed(5)}, '
            '${nearestNode.lon.toStringAsFixed(5)}',
      ),
    );

    final result = _deviationPathfinder!.findDeviationPath(
      currentPosition: pos,
      route: _originalRoute,
      targetDistanceM: _config.deviationDistanceM,
      routeAvoidanceRadiusM: _config.routeAvoidanceRadiusM,
      routeAvoidancePenalty: _config.routeAvoidancePenalty,
    );

    if (result == null || !result.found) {
      ConstraintLogger.instance.log(
        ConstraintEvent.info(
          timestamp: AppClock().now(),
          title: 'Deviation Path Not Found',
          description:
              'Pathfinder could not find path away from route. '
              'Route has ${_originalRoute.length} points.',
        ),
      );
      return;
    }

    _deviationPath = result.path;
    _currentPath = result.path;
    _pathIndex = 0;
    _progressInSegment = 0.0;

    _stateMachine.startDeviation();

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Deviation Started',
        description:
            '${result.path.length} points, ${result.totalDistanceM.toStringAsFixed(0)}m',
        details: {
          'pathLength': result.path.length,
          'distanceM': result.totalDistanceM,
        },
      ),
    );
  }

  /// Stop deviation and return to following mode.
  void stopDeviation() {
    _stateMachine.stopDeviation();

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Deviation Stopped',
      ),
    );
  }

  /// Go back to the original route.
  void goBackToRoute() {
    if (_currentPosition == null || _deviationPathfinder == null) {
      return;
    }

    final result = _deviationPathfinder!.findReturnPath(
      currentPosition: _currentPosition!,
      route: _originalRoute,
    );

    if (result == null || !result.found) {
      ConstraintLogger.instance.log(
        ConstraintEvent.info(
          timestamp: AppClock().now(),
          title: 'Return Path Not Found',
          description: 'Could not find path back to route',
        ),
      );
      return;
    }

    _currentPath = result.path;
    _pathIndex = 0;
    _progressInSegment = 0.0;

    _stateMachine.goBackToRoute();

    ConstraintLogger.instance.log(
      ConstraintEvent(
        type: ConstraintEventType.returnToRoute,
        timestamp: AppClock().now(),
        title: 'Returning to Route',
        description:
            '${result.path.length} points, ${result.totalDistanceM.toStringAsFixed(0)}m',
        details: {
          'pathLength': result.path.length,
          'distanceM': result.totalDistanceM,
        },
      ),
    );
  }

  /// Pause simulation.
  void pause() {
    _stateMachine.pause();
    _stopSimulationLoop();

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Simulation Paused',
      ),
    );
  }

  /// Resume simulation.
  void resume() {
    _stateMachine.resume();
    _lastTickTime = AppClock().now();
    _startSimulationLoop();

    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Simulation Resumed',
      ),
    );
  }

  /// Seek to a position on the ORIGINAL route (0.0 to 1.0).
  /// This resets any deviation state and jumps to that point on the original route.
  void seek(double t) {
    if (_originalRoute.isEmpty) return;

    t = t.clamp(0.0, 1.0);
    final totalSegments = _originalRoute.length - 1;
    if (totalSegments <= 0) return;

    // Reset to original route if deviating
    if (_stateMachine.isDeviating || _stateMachine.isReturning) {
      _stateMachine.onReachedRoute();
      _deviationPath = [];
    }

    _currentPath = List.of(_originalRoute);
    final targetProgress = t * totalSegments;
    _pathIndex = targetProgress.floor().clamp(0, totalSegments - 1);
    _progressInSegment = targetProgress - _pathIndex;

    _updatePosition();
    _emitPositionUpdate();
  }

  /// Dispose resources.
  void dispose() {
    _stopSimulationLoop();
    _stateMachine.dispose();
    _positionController.close();
  }

  // ─────────────────────────────────────────────────────────────────────
  // Internal
  // ─────────────────────────────────────────────────────────────────────

  void _startSimulationLoop() {
    _simulationTimer?.cancel();
    // 30 FPS simulation loop
    _simulationTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _tick();
    });
  }

  void _stopSimulationLoop() {
    _simulationTimer?.cancel();
    _simulationTimer = null;
  }

  void _tick() {
    if (!_stateMachine.isActive || _stateMachine.isPaused) return;
    if (_currentPath.isEmpty) return;

    final now = AppClock().now();
    final realDt =
        _lastTickTime != null
            ? now.difference(_lastTickTime!).inMicroseconds / 1e6
            : 0.033;
    _lastTickTime = now;

    // Move along path
    _moveAlongPath(realDt);

    // Check for state transitions
    _checkStateTransitions();

    // Emit position update
    _emitPositionUpdate();
  }

  void _moveAlongPath(double dtSeconds) {
    if (_pathIndex >= _currentPath.length - 1) {
      // Already at end - stay there
      _currentPosition = _currentPath.last;
      _handlePathComplete();
      return;
    }

    final moveDistance = _speedMps * dtSeconds;
    final segmentStart = _currentPath[_pathIndex];
    final segmentEnd = _currentPath[_pathIndex + 1];
    final segmentLength = segmentStart.distanceTo(segmentEnd);

    if (segmentLength < 0.1) {
      // Skip very short segments
      _pathIndex++;
      return;
    }

    final progressDelta = moveDistance / segmentLength;
    _progressInSegment += progressDelta;

    while (_progressInSegment >= 1.0 && _pathIndex < _currentPath.length - 2) {
      _progressInSegment -= 1.0;
      _pathIndex++;
    }

    // If we've reached the end of the last segment, clamp and mark complete
    if (_pathIndex >= _currentPath.length - 2 && _progressInSegment >= 1.0) {
      _progressInSegment = 1.0;
      _currentPosition = _currentPath.last;
      _handlePathComplete();
      return;
    }

    _updatePosition();
  }

  void _updatePosition() {
    if (_pathIndex >= _currentPath.length - 1) {
      _currentPosition = _currentPath.last;
      return;
    }

    final segmentStart = _currentPath[_pathIndex];
    final segmentEnd = _currentPath[_pathIndex + 1];

    _currentPosition = _interpolate(
      segmentStart,
      segmentEnd,
      _progressInSegment,
    );
    _currentHeading = _calculateHeading(segmentStart, segmentEnd);
  }

  void _handlePathComplete() {
    if (_stateMachine.isReturning) {
      // Reached original route
      _stateMachine.onReachedRoute();
      _currentPath = _originalRoute;
      // Find nearest segment AND progress to avoid position jumping
      final (idx, progress) = _findNearestSegmentWithProgress(
        _currentPosition!,
        _originalRoute,
      );
      _pathIndex = idx;
      _progressInSegment = progress;
      _deviationPath = [];

      ConstraintLogger.instance.log(
        ConstraintEvent(
          type: ConstraintEventType.backOnRoute,
          timestamp: AppClock().now(),
          title: 'Back on Route',
        ),
      );
    } else if (_stateMachine.isDeviating) {
      // Continue deviation - find more path
      final continued = _deviationPathfinder?.findContinuedDeviationPath(
        currentPosition: _currentPosition!,
        route: _originalRoute,
        currentDeviationPath: _deviationPath,
      );

      if (continued != null && continued.found) {
        _deviationPath = [..._deviationPath, ...continued.path.skip(1)];
        _currentPath = continued.path;
        _pathIndex = 0;
        _progressInSegment = 0.0;
      }
    } else if (_stateMachine.isOnRoute) {
      // Reached destination
      stop();

      ConstraintLogger.instance.log(
        ConstraintEvent.info(
          timestamp: AppClock().now(),
          title: 'Destination Reached',
        ),
      );
    }
  }

  void _checkStateTransitions() {
    if (_currentPosition == null) return;

    if (_stateMachine.isReturning) {
      // Check if close enough to route
      final distanceToRoute = _minDistanceToRoute(
        _currentPosition!,
        _originalRoute,
      );
      if (distanceToRoute < _config.returnThresholdM) {
        _stateMachine.onReachedRoute();
        _currentPath = _originalRoute;
        // Find nearest segment AND progress to avoid position jumping
        final (idx, progress) = _findNearestSegmentWithProgress(
          _currentPosition!,
          _originalRoute,
        );
        _pathIndex = idx;
        _progressInSegment = progress;
        _deviationPath = [];

        ConstraintLogger.instance.log(
          ConstraintEvent(
            type: ConstraintEventType.backOnRoute,
            timestamp: AppClock().now(),
            title: 'Back on Route',
            description: 'Within ${distanceToRoute.toStringAsFixed(1)}m',
          ),
        );
      }
    }
  }

  void _emitPositionUpdate() {
    if (_currentPosition == null) return;

    final distanceFromRoute = _minDistanceToRoute(
      _currentPosition!,
      _originalRoute,
    );

    _positionController.add(
      SimulationTickResult(
        position: _currentPosition!,
        heading: _currentHeading,
        speedMps: _speedMps,
        virtualTime: AppClock().now(),
        distanceFromRoute: distanceFromRoute,
      ),
    );
  }

  LatLng _interpolate(LatLng a, LatLng b, double t) {
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  double _calculateHeading(LatLng from, LatLng to) {
    final dLon = to.longitude - from.longitude;
    final dLat = to.latitude - from.latitude;
    return (math.atan2(dLon, dLat) * 180 / math.pi + 360) % 360;
  }

  double _minDistanceToRoute(LatLng point, List<LatLng> route) {
    if (route.isEmpty) return double.infinity;
    if (route.length == 1) return point.distanceTo(route.first);

    double minDist = double.infinity;
    for (int i = 0; i < route.length - 1; i++) {
      final dist = _pointToSegmentDistance(point, route[i], route[i + 1]);
      minDist = math.min(minDist, dist);
    }
    return minDist;
  }

  double _pointToSegmentDistance(LatLng point, LatLng segStart, LatLng segEnd) {
    // Project point onto segment
    final dx = segEnd.longitude - segStart.longitude;
    final dy = segEnd.latitude - segStart.latitude;

    if (dx == 0 && dy == 0) {
      return point.distanceTo(segStart);
    }

    final t =
        ((point.longitude - segStart.longitude) * dx +
            (point.latitude - segStart.latitude) * dy) /
        (dx * dx + dy * dy);

    final clampedT = t.clamp(0.0, 1.0);
    final projected = LatLng(
      segStart.latitude + clampedT * dy,
      segStart.longitude + clampedT * dx,
    );

    return point.distanceTo(projected);
  }

  /// Find both the nearest segment index and the progress along that segment.
  /// Returns (segmentIndex, progressInSegment) where progressInSegment is 0.0-1.0.
  (int, double) _findNearestSegmentWithProgress(
    LatLng point,
    List<LatLng> path,
  ) {
    if (path.length < 2) return (0, 0.0);

    int nearestIndex = 0;
    double minDist = double.infinity;
    double nearestProgress = 0.0;

    for (int i = 0; i < path.length - 1; i++) {
      final segStart = path[i];
      final segEnd = path[i + 1];
      final (dist, progress) = _pointToSegmentDistanceWithProgress(
        point,
        segStart,
        segEnd,
      );
      if (dist < minDist) {
        minDist = dist;
        nearestIndex = i;
        nearestProgress = progress;
      }
    }

    return (nearestIndex, nearestProgress);
  }

  /// Calculate distance from point to segment AND the progress (0.0-1.0) along segment.
  (double, double) _pointToSegmentDistanceWithProgress(
    LatLng point,
    LatLng segStart,
    LatLng segEnd,
  ) {
    final dx = segEnd.longitude - segStart.longitude;
    final dy = segEnd.latitude - segStart.latitude;

    if (dx == 0 && dy == 0) {
      return (point.distanceTo(segStart), 0.0);
    }

    final t =
        ((point.longitude - segStart.longitude) * dx +
            (point.latitude - segStart.latitude) * dy) /
        (dx * dx + dy * dy);

    final clampedT = t.clamp(0.0, 1.0);
    final projected = LatLng(
      segStart.latitude + clampedT * dy,
      segStart.longitude + clampedT * dx,
    );

    return (point.distanceTo(projected), clampedT);
  }
}
