/// OSM Graph data structures for deviation simulation.
///
/// Provides an in-memory road network graph built from preprocessed
/// OpenStreetMap data. Used by the pathfinding engine to find valid
/// deviation routes away from the user's planned route.
library;

import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Road type classification from OSM highway tags.
enum RoadType {
  unknown(0),
  motorway(1),
  motorwayLink(2),
  trunk(3),
  trunkLink(4),
  primary(5),
  primaryLink(6),
  secondary(7),
  secondaryLink(8),
  tertiary(9),
  tertiaryLink(10),
  residential(11),
  livingStreet(12),
  unclassified(13),
  service(14),
  road(15);

  const RoadType(this.value);
  final int value;

  static RoadType fromValue(int v) {
    return RoadType.values.firstWhere(
      (t) => t.value == v,
      orElse: () => RoadType.unknown,
    );
  }

  /// Default speed for this road type in m/s.
  double get defaultSpeedMps {
    const kmhToMps = 1000.0 / 3600.0;
    return switch (this) {
      RoadType.motorway => 100 * kmhToMps,
      RoadType.motorwayLink => 60 * kmhToMps,
      RoadType.trunk => 80 * kmhToMps,
      RoadType.trunkLink => 50 * kmhToMps,
      RoadType.primary => 60 * kmhToMps,
      RoadType.primaryLink => 40 * kmhToMps,
      RoadType.secondary => 50 * kmhToMps,
      RoadType.secondaryLink => 35 * kmhToMps,
      RoadType.tertiary => 40 * kmhToMps,
      RoadType.tertiaryLink => 30 * kmhToMps,
      RoadType.residential => 30 * kmhToMps,
      RoadType.livingStreet => 20 * kmhToMps,
      RoadType.unclassified => 30 * kmhToMps,
      RoadType.service => 20 * kmhToMps,
      RoadType.road => 30 * kmhToMps,
      RoadType.unknown => 25 * kmhToMps,
    };
  }
}

/// A node in the road network graph.
class OsmNode {
  OsmNode({
    required this.index,
    required this.osmId,
    required this.lat,
    required this.lon,
  });

  /// Index in the node array (for fast edge lookups).
  final int index;

  /// Original OSM node ID.
  final int osmId;

  /// Latitude in degrees.
  final double lat;

  /// Longitude in degrees.
  final double lon;

  /// Convert to LatLng for Google Maps.
  LatLng get latLng => LatLng(lat, lon);

  @override
  String toString() => 'OsmNode($index, osm:$osmId, $lat, $lon)';
}

/// A directed edge in the road network graph.
class OsmEdge {
  OsmEdge({
    required this.fromIndex,
    required this.toIndex,
    required this.distanceM,
    required this.roadType,
    required this.isOneway,
  });

  /// Source node index.
  final int fromIndex;

  /// Target node index.
  final int toIndex;

  /// Distance in meters.
  final double distanceM;

  /// Road type classification.
  final RoadType roadType;

  /// Whether this is a one-way edge.
  final bool isOneway;

  /// Estimated travel time in seconds at default speed.
  double get travelTimeSeconds => distanceM / roadType.defaultSpeedMps;

  @override
  String toString() =>
      'OsmEdge($fromIndex->$toIndex, ${distanceM.toStringAsFixed(1)}m, $roadType)';
}

/// In-memory road network graph.
///
/// Optimized for:
/// - Fast nearest-node lookup via spatial index
/// - Fast edge iteration from any node
/// - Memory efficiency for mobile devices
class OsmGraph {
  OsmGraph._({
    required this.nodes,
    required this.edges,
    required this.adjacencyList,
    required this.bounds,
  });

  /// All nodes in the graph.
  final List<OsmNode> nodes;

  /// All edges in the graph.
  final List<OsmEdge> edges;

  /// Adjacency list: nodeIndex -> list of edge indices.
  final List<List<int>> adjacencyList;

  /// Bounding box: (minLat, minLon, maxLat, maxLon).
  final (double, double, double, double) bounds;

  /// Spatial grid for fast nearest-node lookup.
  late final _SpatialGrid _spatialGrid = _SpatialGrid(this);

  /// Build graph from raw data.
  factory OsmGraph.build({
    required List<OsmNode> nodes,
    required List<OsmEdge> edges,
  }) {
    // Build adjacency list
    final adjacencyList = List.generate(nodes.length, (_) => <int>[]);
    for (int i = 0; i < edges.length; i++) {
      adjacencyList[edges[i].fromIndex].add(i);
    }

    // Calculate bounds
    if (nodes.isEmpty) {
      return OsmGraph._(
        nodes: nodes,
        edges: edges,
        adjacencyList: adjacencyList,
        bounds: (0, 0, 0, 0),
      );
    }

    double minLat = nodes[0].lat, maxLat = nodes[0].lat;
    double minLon = nodes[0].lon, maxLon = nodes[0].lon;
    for (final node in nodes) {
      minLat = math.min(minLat, node.lat);
      maxLat = math.max(maxLat, node.lat);
      minLon = math.min(minLon, node.lon);
      maxLon = math.max(maxLon, node.lon);
    }

    return OsmGraph._(
      nodes: nodes,
      edges: edges,
      adjacencyList: adjacencyList,
      bounds: (minLat, minLon, maxLat, maxLon),
    );
  }

  /// Create empty graph.
  factory OsmGraph.empty() => OsmGraph.build(nodes: [], edges: []);

  /// Number of nodes.
  int get nodeCount => nodes.length;

  /// Number of edges.
  int get edgeCount => edges.length;

  /// Check if graph is empty.
  bool get isEmpty => nodes.isEmpty;

  /// Get edges leaving a node.
  Iterable<OsmEdge> edgesFrom(int nodeIndex) sync* {
    if (nodeIndex < 0 || nodeIndex >= adjacencyList.length) return;
    for (final edgeIndex in adjacencyList[nodeIndex]) {
      yield edges[edgeIndex];
    }
  }

  /// Get neighbor node indices.
  Iterable<int> neighbors(int nodeIndex) sync* {
    for (final edge in edgesFrom(nodeIndex)) {
      yield edge.toIndex;
    }
  }

  /// Find nearest node to a point.
  ///
  /// Returns null if graph is empty or no node within [maxDistanceM].
  OsmNode? nearestNode(LatLng point, {double maxDistanceM = 500}) {
    return _spatialGrid.findNearest(point, maxDistanceM);
  }

  /// Find all nodes within distance of a point.
  List<OsmNode> nodesWithinRadius(LatLng point, double radiusM) {
    return _spatialGrid.findWithinRadius(point, radiusM);
  }

  /// Check if a point is within the graph bounds.
  bool containsPoint(LatLng point) {
    final (minLat, minLon, maxLat, maxLon) = bounds;
    return point.latitude >= minLat &&
        point.latitude <= maxLat &&
        point.longitude >= minLon &&
        point.longitude <= maxLon;
  }

  /// Get statistics about the graph.
  Map<String, dynamic> get stats => {
    'nodeCount': nodeCount,
    'edgeCount': edgeCount,
    'bounds': bounds,
    'avgDegree': edgeCount / math.max(1, nodeCount),
  };

  @override
  String toString() => 'OsmGraph(nodes: $nodeCount, edges: $edgeCount)';
}

/// Simple spatial grid for nearest-neighbor queries.
class _SpatialGrid {
  _SpatialGrid(this.graph) {
    _buildGrid();
  }

  final OsmGraph graph;

  // Grid parameters
  static const int _gridSize = 100; // 100x100 cells
  late final double _cellLatSize;
  late final double _cellLonSize;
  late final double _minLat;
  late final double _minLon;

  // Grid cells: cell index -> list of node indices
  final Map<int, List<int>> _cells = {};

  void _buildGrid() {
    if (graph.isEmpty) return;

    final (minLat, minLon, maxLat, maxLon) = graph.bounds;
    _minLat = minLat;
    _minLon = minLon;
    _cellLatSize = (maxLat - minLat) / _gridSize;
    _cellLonSize = (maxLon - minLon) / _gridSize;

    // Avoid division by zero
    if (_cellLatSize == 0 || _cellLonSize == 0) return;

    // Populate grid
    for (final node in graph.nodes) {
      final cellIndex = _getCellIndex(node.lat, node.lon);
      _cells.putIfAbsent(cellIndex, () => []).add(node.index);
    }
  }

  int _getCellIndex(double lat, double lon) {
    final row = ((lat - _minLat) / _cellLatSize).floor().clamp(
      0,
      _gridSize - 1,
    );
    final col = ((lon - _minLon) / _cellLonSize).floor().clamp(
      0,
      _gridSize - 1,
    );
    return row * _gridSize + col;
  }

  (int, int) _getCellRowCol(double lat, double lon) {
    final row = ((lat - _minLat) / _cellLatSize).floor().clamp(
      0,
      _gridSize - 1,
    );
    final col = ((lon - _minLon) / _cellLonSize).floor().clamp(
      0,
      _gridSize - 1,
    );
    return (row, col);
  }

  OsmNode? findNearest(LatLng point, double maxDistanceM) {
    if (graph.isEmpty) return null;

    final (row, col) = _getCellRowCol(point.latitude, point.longitude);

    // Search expanding rings of cells
    OsmNode? best;
    double bestDist = maxDistanceM;

    // Calculate how many cells to search based on max distance
    // Approximate: 1 degree lat ≈ 111km
    final cellsToSearch =
        (maxDistanceM / 111000 / math.max(_cellLatSize, _cellLonSize)).ceil() +
        1;

    for (int ring = 0; ring <= cellsToSearch; ring++) {
      for (int dr = -ring; dr <= ring; dr++) {
        for (int dc = -ring; dc <= ring; dc++) {
          // Only check cells on the ring perimeter (or center for ring 0)
          if (ring > 0 && dr.abs() != ring && dc.abs() != ring) continue;

          final r = row + dr;
          final c = col + dc;
          if (r < 0 || r >= _gridSize || c < 0 || c >= _gridSize) continue;

          final cellIndex = r * _gridSize + c;
          final nodeIndices = _cells[cellIndex];
          if (nodeIndices == null) continue;

          for (final nodeIndex in nodeIndices) {
            final node = graph.nodes[nodeIndex];
            final dist = _haversineDistance(
              point.latitude,
              point.longitude,
              node.lat,
              node.lon,
            );
            if (dist < bestDist) {
              bestDist = dist;
              best = node;
            }
          }
        }
      }

      // Early exit if we found something and next ring would be too far
      if (best != null) {
        final nextRingMinDist =
            (ring + 1) * math.min(_cellLatSize, _cellLonSize) * 111000;
        if (nextRingMinDist > bestDist * 1.5) break;
      }
    }

    return best;
  }

  List<OsmNode> findWithinRadius(LatLng point, double radiusM) {
    if (graph.isEmpty) return [];

    final results = <OsmNode>[];
    final (row, col) = _getCellRowCol(point.latitude, point.longitude);

    final cellsToSearch =
        (radiusM / 111000 / math.max(_cellLatSize, _cellLonSize)).ceil() + 1;

    for (int dr = -cellsToSearch; dr <= cellsToSearch; dr++) {
      for (int dc = -cellsToSearch; dc <= cellsToSearch; dc++) {
        final r = row + dr;
        final c = col + dc;
        if (r < 0 || r >= _gridSize || c < 0 || c >= _gridSize) continue;

        final cellIndex = r * _gridSize + c;
        final nodeIndices = _cells[cellIndex];
        if (nodeIndices == null) continue;

        for (final nodeIndex in nodeIndices) {
          final node = graph.nodes[nodeIndex];
          final dist = _haversineDistance(
            point.latitude,
            point.longitude,
            node.lat,
            node.lon,
          );
          if (dist <= radiusM) {
            results.add(node);
          }
        }
      }
    }

    return results;
  }

  static double _haversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const R = 6371000.0; // Earth radius in meters

    final phi1 = lat1 * math.pi / 180;
    final phi2 = lat2 * math.pi / 180;
    final deltaPhi = (lat2 - lat1) * math.pi / 180;
    final deltaLambda = (lon2 - lon1) * math.pi / 180;

    final a =
        math.sin(deltaPhi / 2) * math.sin(deltaPhi / 2) +
        math.cos(phi1) *
            math.cos(phi2) *
            math.sin(deltaLambda / 2) *
            math.sin(deltaLambda / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return R * c;
  }
}

/// Extension methods for distance calculations.
extension LatLngDistance on LatLng {
  /// Calculate distance to another point in meters.
  double distanceTo(LatLng other) {
    return _SpatialGrid._haversineDistance(
      latitude,
      longitude,
      other.latitude,
      other.longitude,
    );
  }
}
