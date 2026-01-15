/// Tests for OSM graph data structures and loader.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/services/testing/osm_graph.dart';
import 'package:geowake2/services/testing/osm_loader.dart';

void main() {
  group('RoadType', () {
    test('fromValue returns correct types', () {
      expect(RoadType.fromValue(1), RoadType.motorway);
      expect(RoadType.fromValue(5), RoadType.primary);
      expect(RoadType.fromValue(11), RoadType.residential);
      expect(RoadType.fromValue(999), RoadType.unknown);
    });

    test('defaultSpeedMps returns reasonable values', () {
      // Motorway should be fastest
      expect(RoadType.motorway.defaultSpeedMps, greaterThan(20)); // > 72 km/h

      // Residential should be slower
      expect(RoadType.residential.defaultSpeedMps, lessThan(15)); // < 54 km/h

      // All types should have positive speed
      for (final type in RoadType.values) {
        expect(type.defaultSpeedMps, greaterThan(0));
      }
    });
  });

  group('OsmNode', () {
    test('latLng conversion', () {
      final node = OsmNode(index: 0, osmId: 12345, lat: 12.9716, lon: 77.5946);

      expect(node.latLng.latitude, 12.9716);
      expect(node.latLng.longitude, 77.5946);
    });

    test('toString includes relevant info', () {
      final node = OsmNode(index: 5, osmId: 99999, lat: 12.0, lon: 77.0);
      final str = node.toString();
      expect(str, contains('5'));
      expect(str, contains('99999'));
    });
  });

  group('OsmEdge', () {
    test('travelTimeSeconds calculation', () {
      final edge = OsmEdge(
        fromIndex: 0,
        toIndex: 1,
        distanceM: 1000, // 1km
        roadType: RoadType.residential, // 30 km/h = 8.33 m/s
        isOneway: false,
      );

      // 1000m at 8.33 m/s ≈ 120 seconds
      expect(edge.travelTimeSeconds, closeTo(120, 5));
    });

    test('motorway travel time is faster', () {
      final motorwayEdge = OsmEdge(
        fromIndex: 0,
        toIndex: 1,
        distanceM: 1000,
        roadType: RoadType.motorway,
        isOneway: true,
      );

      final residentialEdge = OsmEdge(
        fromIndex: 0,
        toIndex: 1,
        distanceM: 1000,
        roadType: RoadType.residential,
        isOneway: false,
      );

      expect(
        motorwayEdge.travelTimeSeconds,
        lessThan(residentialEdge.travelTimeSeconds),
      );
    });
  });

  group('OsmGraph', () {
    late OsmGraph graph;

    setUp(() {
      // Create a simple test graph
      graph = OsmLoader.createTestGraph(
        centerLat: 12.9716,
        centerLon: 77.5946,
        gridSize: 3, // 3x3 = 9 nodes
        spacingMeters: 100,
      );
    });

    test('createTestGraph produces valid graph', () {
      expect(graph.nodeCount, 9); // 3x3 grid
      expect(graph.edgeCount, greaterThan(0));
      expect(graph.isEmpty, isFalse);
    });

    test('bounds are calculated correctly', () {
      final (minLat, minLon, maxLat, maxLon) = graph.bounds;
      expect(minLat, lessThan(maxLat));
      expect(minLon, lessThan(maxLon));

      // Center should be within bounds
      expect(12.9716, greaterThanOrEqualTo(minLat));
      expect(12.9716, lessThanOrEqualTo(maxLat));
    });

    test('edgesFrom returns edges for valid node', () {
      final edges = graph.edgesFrom(4).toList(); // Center node of 3x3
      expect(edges.length, greaterThan(0));

      // All edges should originate from node 4
      for (final edge in edges) {
        expect(edge.fromIndex, 4);
      }
    });

    test('edgesFrom returns empty for invalid node', () {
      expect(graph.edgesFrom(-1).toList(), isEmpty);
      expect(graph.edgesFrom(999).toList(), isEmpty);
    });

    test('neighbors returns correct neighbors', () {
      final neighbors = graph.neighbors(4).toList(); // Center node
      expect(neighbors.length, 4); // 4-connected grid, center has 4 neighbors
    });

    test('nearestNode finds node within range', () {
      const center = LatLng(12.9716, 77.5946);
      final nearest = graph.nearestNode(center, maxDistanceM: 200);

      expect(nearest, isNotNull);
      expect(nearest!.lat, closeTo(12.9716, 0.01));
      expect(nearest.lon, closeTo(77.5946, 0.01));
    });

    test('nearestNode returns null when too far', () {
      const farPoint = LatLng(13.5, 78.0); // Far from graph
      final nearest = graph.nearestNode(farPoint, maxDistanceM: 100);

      expect(nearest, isNull);
    });

    test('nodesWithinRadius returns multiple nodes', () {
      const center = LatLng(12.9716, 77.5946);
      final nodes = graph.nodesWithinRadius(center, 200);

      expect(nodes.length, greaterThan(1));
    });

    test('containsPoint works correctly', () {
      // Point at center should be contained
      expect(graph.containsPoint(const LatLng(12.9716, 77.5946)), isTrue);

      // Far point should not be contained
      expect(graph.containsPoint(const LatLng(0, 0)), isFalse);
    });

    test('stats returns useful information', () {
      final stats = graph.stats;

      expect(stats['nodeCount'], 9);
      expect(stats['edgeCount'], greaterThan(0));
      expect(stats['avgDegree'], greaterThan(0));
    });

    test('empty graph is handled correctly', () {
      final empty = OsmGraph.empty();

      expect(empty.isEmpty, isTrue);
      expect(empty.nodeCount, 0);
      expect(empty.edgeCount, 0);
      expect(empty.nearestNode(const LatLng(0, 0)), isNull);
      expect(empty.nodesWithinRadius(const LatLng(0, 0), 1000), isEmpty);
    });
  });

  group('OsmLoader', () {
    test('loadBytes parses valid binary', () {
      // Create minimal valid binary
      final bytes = _createMinimalWkpFile();
      final graph = OsmLoader.loadBytes(bytes);

      expect(graph.nodeCount, 2);
      expect(graph.edgeCount, 1);
    });

    test('loadBytes throws on invalid magic', () {
      final bytes = Uint8List.fromList([
        0x42,
        0x41,
        0x44,
        0x21, // "BAD!"
        ...List.filled(12, 0),
      ]);

      expect(
        () => OsmLoader.loadBytes(bytes),
        throwsA(isA<OsmLoadException>()),
      );
    });

    test('loadBytes throws on unsupported version', () {
      final bytes = Uint8List(16);
      bytes.setRange(0, 4, 'WKP1'.codeUnits);
      // Set version to 99
      bytes[4] = 99;
      bytes[5] = 0;

      expect(
        () => OsmLoader.loadBytes(bytes),
        throwsA(isA<OsmLoadException>()),
      );
    });

    test('loadBytes throws on truncated file', () {
      final bytes = Uint8List(10); // Too small

      expect(
        () => OsmLoader.loadBytes(bytes),
        throwsA(isA<OsmLoadException>()),
      );
    });

    test('createTestGraph creates connected graph', () {
      final graph = OsmLoader.createTestGraph(gridSize: 4);

      // 4x4 = 16 nodes
      expect(graph.nodeCount, 16);

      // Check connectivity - should be able to traverse
      final visited = <int>{};
      final queue = [0];
      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        if (visited.contains(current)) continue;
        visited.add(current);
        queue.addAll(graph.neighbors(current));
      }

      // All nodes should be reachable from node 0
      expect(visited.length, 16);
    });

    test('createTestGraph with custom parameters', () {
      final graph = OsmLoader.createTestGraph(
        centerLat: 13.0,
        centerLon: 78.0,
        gridSize: 2,
        spacingMeters: 50,
      );

      expect(graph.nodeCount, 4); // 2x2
      expect(graph.containsPoint(const LatLng(13.0, 78.0)), isTrue);
    });
  });

  group('LatLngDistance extension', () {
    test('distanceTo calculates correct distance', () {
      const p1 = LatLng(12.9716, 77.5946);
      const p2 = LatLng(12.9816, 77.5946); // ~1.1km north

      final distance = p1.distanceTo(p2);
      expect(distance, closeTo(1110, 50)); // ~1.1km with tolerance
    });

    test('distanceTo same point is zero', () {
      const p = LatLng(12.9716, 77.5946);
      expect(p.distanceTo(p), 0);
    });

    test('distanceTo is symmetric', () {
      const p1 = LatLng(12.9716, 77.5946);
      const p2 = LatLng(13.0, 77.6);

      expect(p1.distanceTo(p2), closeTo(p2.distanceTo(p1), 0.01));
    });
  });
}

/// Create a minimal valid .wkp file for testing.
Uint8List _createMinimalWkpFile() {
  // Header: 16 bytes
  // Nodes: 2 nodes × 16 bytes = 32 bytes
  // Edges: 1 edge × 16 bytes = 16 bytes
  // Total: 64 bytes

  final bytes = ByteData(64);
  int offset = 0;

  // Magic: "WKP1"
  bytes.setUint8(offset++, 0x57); // W
  bytes.setUint8(offset++, 0x4B); // K
  bytes.setUint8(offset++, 0x50); // P
  bytes.setUint8(offset++, 0x31); // 1

  // Version: 1
  bytes.setUint16(offset, 1, Endian.little);
  offset += 2;

  // Node count: 2
  bytes.setUint32(offset, 2, Endian.little);
  offset += 4;

  // Edge count: 1
  bytes.setUint32(offset, 1, Endian.little);
  offset += 4;

  // Reserved
  bytes.setUint16(offset, 0, Endian.little);
  offset += 2;

  // Node 0: lat=12.97, lon=77.59, id=1000
  bytes.setFloat32(offset, 12.97, Endian.little);
  offset += 4;
  bytes.setFloat32(offset, 77.59, Endian.little);
  offset += 4;
  bytes.setUint64(offset, 1000, Endian.little);
  offset += 8;

  // Node 1: lat=12.98, lon=77.60, id=1001
  bytes.setFloat32(offset, 12.98, Endian.little);
  offset += 4;
  bytes.setFloat32(offset, 77.60, Endian.little);
  offset += 4;
  bytes.setUint64(offset, 1001, Endian.little);
  offset += 8;

  // Edge: from=0, to=1, distance=1500m, roadType=11 (residential), oneway=0
  bytes.setUint32(offset, 0, Endian.little);
  offset += 4;
  bytes.setUint32(offset, 1, Endian.little);
  offset += 4;
  bytes.setFloat32(offset, 1500.0, Endian.little);
  offset += 4;
  bytes.setUint8(offset++, 11); // residential
  bytes.setUint8(offset++, 0); // not oneway
  bytes.setUint16(offset, 0, Endian.little); // padding

  return bytes.buffer.asUint8List();
}
