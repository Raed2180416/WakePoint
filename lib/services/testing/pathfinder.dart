/// A* Pathfinding engine for OSM graphs.
///
/// Provides efficient pathfinding for deviation simulation, including:
/// - Standard A* shortest path
/// - Deviation pathfinding (away from a route)
/// - Return pathfinding (back to original route)
library;

import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'osm_graph.dart';

/// Result of a pathfinding operation.
class PathResult {
  PathResult({
    required this.path,
    required this.nodes,
    required this.totalDistanceM,
    required this.nodesExplored,
  });

  /// The path as a list of LatLng points.
  final List<LatLng> path;

  /// The node indices along the path.
  final List<int> nodes;

  /// Total path distance in meters.
  final double totalDistanceM;

  /// Number of nodes explored during search (for debugging).
  final int nodesExplored;

  /// Whether a path was found.
  bool get found => path.isNotEmpty;

  /// Estimated travel time at given speed (m/s).
  Duration estimatedTime(double speedMps) {
    if (speedMps <= 0) return Duration.zero;
    return Duration(seconds: (totalDistanceM / speedMps).round());
  }

  @override
  String toString() =>
      'PathResult(${path.length} points, ${totalDistanceM.toStringAsFixed(0)}m, $nodesExplored explored)';
}

/// A* pathfinding engine.
class Pathfinder {
  Pathfinder(this.graph);

  final OsmGraph graph;

  /// Find shortest path between two points.
  ///
  /// Returns null if no path exists or points are too far from graph.
  PathResult? findPath(
    LatLng start,
    LatLng end, {
    double maxSearchDistanceM = 1000, // Increased from 500 to 1000
    double Function(OsmNode node)? costModifier,
  }) {
    // Find nearest graph nodes
    final startNode = graph.nearestNode(
      start,
      maxDistanceM: maxSearchDistanceM,
    );
    final endNode = graph.nearestNode(end, maxDistanceM: maxSearchDistanceM);

    if (startNode == null || endNode == null) {
      return null;
    }

    return findPathBetweenNodes(
      startNode.index,
      endNode.index,
      costModifier: costModifier,
    );
  }

  /// Find path between two node indices.
  PathResult? findPathBetweenNodes(
    int startIndex,
    int endIndex, {
    double Function(OsmNode node)? costModifier,
  }) {
    if (startIndex < 0 ||
        startIndex >= graph.nodeCount ||
        endIndex < 0 ||
        endIndex >= graph.nodeCount) {
      return null;
    }

    if (startIndex == endIndex) {
      final node = graph.nodes[startIndex];
      return PathResult(
        path: [node.latLng],
        nodes: [startIndex],
        totalDistanceM: 0,
        nodesExplored: 1,
      );
    }

    final endNode = graph.nodes[endIndex];

    // A* data structures
    final openSet = _PriorityQueue<_AStarEntry>();
    final cameFrom = <int, int>{};
    final gScore = <int, double>{startIndex: 0.0};
    final inOpenSet = <int>{startIndex};

    openSet.add(
      _AStarEntry(
        nodeIndex: startIndex,
        fScore: _heuristic(graph.nodes[startIndex], endNode),
      ),
    );

    int nodesExplored = 0;
    const maxIterations = 100000; // Safety limit

    while (openSet.isNotEmpty && nodesExplored < maxIterations) {
      final current = openSet.removeFirst();
      inOpenSet.remove(current.nodeIndex);
      nodesExplored++;

      if (current.nodeIndex == endIndex) {
        // Reconstruct path
        return _reconstructPath(
          cameFrom,
          endIndex,
          gScore[endIndex]!,
          nodesExplored,
        );
      }

      for (final edge in graph.edgesFrom(current.nodeIndex)) {
        final neighborIndex = edge.toIndex;
        final neighborNode = graph.nodes[neighborIndex];

        // Calculate movement cost
        double moveCost = edge.distanceM;
        if (costModifier != null) {
          moveCost += costModifier(neighborNode);
        }

        final tentativeG = gScore[current.nodeIndex]! + moveCost;

        if (tentativeG < (gScore[neighborIndex] ?? double.infinity)) {
          cameFrom[neighborIndex] = current.nodeIndex;
          gScore[neighborIndex] = tentativeG;

          final fScore = tentativeG + _heuristic(neighborNode, endNode);

          if (!inOpenSet.contains(neighborIndex)) {
            openSet.add(_AStarEntry(nodeIndex: neighborIndex, fScore: fScore));
            inOpenSet.add(neighborIndex);
          }
        }
      }
    }

    // No path found
    return null;
  }

  /// Heuristic: straight-line distance (admissible for A*).
  double _heuristic(OsmNode from, OsmNode to) {
    return from.latLng.distanceTo(to.latLng);
  }

  /// Reconstruct path from A* results.
  PathResult _reconstructPath(
    Map<int, int> cameFrom,
    int endIndex,
    double totalDistance,
    int nodesExplored,
  ) {
    final nodes = <int>[];
    int current = endIndex;

    while (cameFrom.containsKey(current)) {
      nodes.add(current);
      current = cameFrom[current]!;
    }
    nodes.add(current); // Add start node
    nodes.reversed;

    final reversedNodes = nodes.reversed.toList();
    final path = reversedNodes.map((i) => graph.nodes[i].latLng).toList();

    return PathResult(
      path: path,
      nodes: reversedNodes,
      totalDistanceM: totalDistance,
      nodesExplored: nodesExplored,
    );
  }
}

/// Deviation pathfinder - finds paths that lead away from a route.
class DeviationPathfinder {
  DeviationPathfinder({required this.graph, required this.basePathfinder});

  final OsmGraph graph;
  final Pathfinder basePathfinder;

  /// Find a path that deviates from the given route.
  ///
  /// Strategy:
  /// 1. Compute perpendicular direction from route at current position
  /// 2. Find target point ~[targetDistanceM] in that direction
  /// 3. A* with cost penalty for nodes near the route
  PathResult? findDeviationPath({
    required LatLng currentPosition,
    required List<LatLng> route,
    double targetDistanceM = 500,
    double routeAvoidanceRadiusM = 100,
    double routeAvoidancePenalty = 500,
  }) {
    if (route.length < 2) return null;

    // Find nearest point on route and perpendicular direction
    final (nearestPoint, segmentIndex) = _findNearestPointOnRoute(
      currentPosition,
      route,
    );
    final perpDirection = _computePerpendicularDirection(route, segmentIndex);

    // Find target point in perpendicular direction
    final targetLat =
        currentPosition.latitude +
        perpDirection.$1 * (targetDistanceM / 111000);
    final targetLon =
        currentPosition.longitude +
        perpDirection.$2 *
            (targetDistanceM / (111000 * _cosLat(currentPosition.latitude)));
    final targetPoint = LatLng(targetLat, targetLon);

    // Find path with route avoidance
    return basePathfinder.findPath(
      currentPosition,
      targetPoint,
      costModifier: (node) {
        final distToRoute = _distanceToRoute(node.latLng, route);
        if (distToRoute < routeAvoidanceRadiusM) {
          // Penalize nodes near the route
          return routeAvoidancePenalty *
              (1 - distToRoute / routeAvoidanceRadiusM);
        }
        return 0;
      },
    );
  }

  /// Find a path back to the original route.
  ///
  /// Finds the nearest point on the route and paths to it.
  PathResult? findReturnPath({
    required LatLng currentPosition,
    required List<LatLng> route,
  }) {
    if (route.isEmpty) return null;

    // Find nearest point on route
    final (nearestPoint, _) = _findNearestPointOnRoute(currentPosition, route);

    return basePathfinder.findPath(currentPosition, nearestPoint);
  }

  /// Find path to continue deviation (further away from route).
  PathResult? findContinuedDeviationPath({
    required LatLng currentPosition,
    required List<LatLng> route,
    required List<LatLng> currentDeviationPath,
    double additionalDistanceM = 300,
  }) {
    if (currentDeviationPath.length < 2) {
      return findDeviationPath(
        currentPosition: currentPosition,
        route: route,
        targetDistanceM: additionalDistanceM,
      );
    }

    // Continue in the same general direction as deviation
    final lastPoint = currentDeviationPath.last;
    final secondLastPoint =
        currentDeviationPath[currentDeviationPath.length - 2];

    final dirLat = lastPoint.latitude - secondLastPoint.latitude;
    final dirLon = lastPoint.longitude - secondLastPoint.longitude;
    final mag = math.sqrt(dirLat * dirLat + dirLon * dirLon);

    if (mag < 1e-10) {
      return findDeviationPath(
        currentPosition: currentPosition,
        route: route,
        targetDistanceM: additionalDistanceM,
      );
    }

    final normLat = dirLat / mag;
    final normLon = dirLon / mag;

    final targetLat =
        currentPosition.latitude + normLat * (additionalDistanceM / 111000);
    final targetLon =
        currentPosition.longitude +
        normLon *
            (additionalDistanceM /
                (111000 * _cosLat(currentPosition.latitude)));
    final targetPoint = LatLng(targetLat, targetLon);

    return basePathfinder.findPath(
      currentPosition,
      targetPoint,
      costModifier: (node) {
        final distToRoute = _distanceToRoute(node.latLng, route);
        if (distToRoute < 100) {
          return 500 * (1 - distToRoute / 100);
        }
        return 0;
      },
    );
  }

  /// Find nearest point on a route polyline.
  (LatLng, int) _findNearestPointOnRoute(LatLng point, List<LatLng> route) {
    if (route.isEmpty) return (point, 0);
    if (route.length == 1) return (route[0], 0);

    double minDist = double.infinity;
    LatLng nearest = route[0];
    int segmentIndex = 0;

    for (int i = 0; i < route.length - 1; i++) {
      final projected = _projectPointOnSegment(point, route[i], route[i + 1]);
      final dist = point.distanceTo(projected);
      if (dist < minDist) {
        minDist = dist;
        nearest = projected;
        segmentIndex = i;
      }
    }

    return (nearest, segmentIndex);
  }

  /// Project a point onto a line segment.
  LatLng _projectPointOnSegment(LatLng point, LatLng segStart, LatLng segEnd) {
    final dx = segEnd.longitude - segStart.longitude;
    final dy = segEnd.latitude - segStart.latitude;

    if (dx == 0 && dy == 0) return segStart;

    final t =
        ((point.longitude - segStart.longitude) * dx +
            (point.latitude - segStart.latitude) * dy) /
        (dx * dx + dy * dy);

    final clampedT = t.clamp(0.0, 1.0);

    return LatLng(
      segStart.latitude + clampedT * dy,
      segStart.longitude + clampedT * dx,
    );
  }

  /// Compute perpendicular direction from route at segment.
  (double, double) _computePerpendicularDirection(
    List<LatLng> route,
    int segmentIndex,
  ) {
    if (route.length < 2) return (1, 0);

    final segStart = route[segmentIndex];
    final segEnd = route[math.min(segmentIndex + 1, route.length - 1)];

    // Route direction
    final dx = segEnd.longitude - segStart.longitude;
    final dy = segEnd.latitude - segStart.latitude;
    final mag = math.sqrt(dx * dx + dy * dy);

    if (mag < 1e-10) return (1, 0);

    // Perpendicular (rotate 90 degrees) - choose right side
    return (-dy / mag, dx / mag);
  }

  /// Calculate minimum distance from point to route.
  double _distanceToRoute(LatLng point, List<LatLng> route) {
    if (route.isEmpty) return double.infinity;
    if (route.length == 1) return point.distanceTo(route[0]);

    double minDist = double.infinity;
    for (int i = 0; i < route.length - 1; i++) {
      final projected = _projectPointOnSegment(point, route[i], route[i + 1]);
      final dist = point.distanceTo(projected);
      minDist = math.min(minDist, dist);
    }
    return minDist;
  }

  double _cosLat(double lat) {
    return math.cos(lat * math.pi / 180);
  }
}

/// Priority queue entry for A*.
class _AStarEntry implements Comparable<_AStarEntry> {
  _AStarEntry({required this.nodeIndex, required this.fScore});

  final int nodeIndex;
  final double fScore;

  @override
  int compareTo(_AStarEntry other) => fScore.compareTo(other.fScore);
}

/// Simple priority queue using a sorted list.
class _PriorityQueue<T extends Comparable<T>> {
  final _items = <T>[];

  bool get isNotEmpty => _items.isNotEmpty;
  bool get isEmpty => _items.isEmpty;

  void add(T item) {
    // Binary search for insertion point
    int low = 0;
    int high = _items.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_items[mid].compareTo(item) <= 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    _items.insert(low, item);
  }

  T removeFirst() => _items.removeAt(0);
}
