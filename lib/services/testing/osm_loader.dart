/// OSM binary file loader for WakePoint.
///
/// Loads preprocessed .wkp files created by tools/osm_preprocessor.py
/// into an [OsmGraph] for pathfinding operations.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import 'osm_graph.dart';

/// Loader for preprocessed OSM binary files (.wkp format).
///
/// Supports loading from:
/// - Flutter assets (bundled with app)
/// - File system (downloaded or cached)
/// - Raw bytes (for testing)
class OsmLoader {
  OsmLoader._();

  /// Magic bytes for file format validation.
  static const _magic = 'WKP1';

  /// Current supported version.
  static const _supportedVersion = 1;

  static Future<Uint8List> _loadAssetBytes(String assetPath) async {
    if (kIsWeb) {
      // On web, try rootBundle first, then HTTP fallbacks.
      try {
        final data = await rootBundle.load(assetPath);
        final bytes = data.buffer.asUint8List();
        if (bytes.length >= 16) return bytes;
      } catch (_) {
        // fall through
      }

      final pathsToTry = <String>[
        assetPath,
        '/$assetPath',
        assetPath.replaceFirst('assets/', ''),
      ];

      http.Response? lastResponse;
      Object? lastError;

      for (final path in pathsToTry) {
        try {
          final response = await http.get(Uri.parse(path));
          lastResponse = response;
          if (response.statusCode == 200 && response.bodyBytes.length >= 16) {
            return response.bodyBytes;
          }
        } catch (e) {
          lastError = e;
        }
      }

      throw OsmLoadException(
        'Failed to load asset bytes for $assetPath on web. '
        'Tried: $pathsToTry. '
        'Last HTTP: ${lastResponse?.statusCode} (${lastResponse?.bodyBytes.length ?? 0} bytes). '
        'Last error: ${lastError ?? "none"}',
      );
    }

    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List();
  }

  /// Load graph from a Flutter asset.
  ///
  /// On web, uses HTTP to load large binary files since rootBundle
  /// can fail silently for files >10MB.
  ///
  /// Example: `OsmLoader.loadAsset('assets/osm/bengaluru.wkp')`
  static Future<OsmGraph> loadAsset(String assetPath) async {
    final bytes = await _loadAssetBytes(assetPath);
    return loadBytes(bytes);
  }

  /// Load a *windowed* graph from a Flutter asset.
  ///
  /// This keeps pathfinding fast by loading only a small area around the
  /// centers (e.g., simulated position + nearest route point).
  static Future<OsmGraph> loadAssetWindowed(
    String assetPath, {
    required List<LatLng> centers,
    double radiusM = 3000,
  }) async {
    final bytes = await _loadAssetBytes(assetPath);
    return loadBytesWindowed(bytes, centers: centers, radiusM: radiusM);
  }

  /// Load a *windowed* graph from raw bytes.
  ///
  /// Implementation scans the file but only materializes nodes/edges within a
  /// bounding box derived from centers+radius, drastically reducing graph size.
  static Future<OsmGraph> loadBytesWindowed(
    Uint8List bytes, {
    required List<LatLng> centers,
    double radiusM = 3000,
  }) async {
    if (centers.isEmpty) {
      throw OsmLoadException('centers cannot be empty');
    }
    if (bytes.length < 16) {
      throw OsmLoadException('File too small: ${bytes.length} bytes');
    }

    // Derive a bounding box around centers.
    final latPad = radiusM / 111000.0;
    double minLat = centers.first.latitude - latPad;
    double maxLat = centers.first.latitude + latPad;

    double maxLonPad = 0;
    for (final c in centers) {
      minLat = math.min(minLat, c.latitude - latPad);
      maxLat = math.max(maxLat, c.latitude + latPad);
      final cosLat = math
          .cos(c.latitude * math.pi / 180.0)
          .abs()
          .clamp(0.2, 1.0);
      final lonPad = radiusM / (111000.0 * cosLat);
      maxLonPad = math.max(maxLonPad, lonPad);
    }

    double minLon = centers.first.longitude - maxLonPad;
    double maxLon = centers.first.longitude + maxLonPad;
    for (final c in centers) {
      minLon = math.min(minLon, c.longitude - maxLonPad);
      maxLon = math.max(maxLon, c.longitude + maxLonPad);
    }

    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    int offset = 0;

    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    if (magic != _magic) {
      throw OsmLoadException('Invalid magic: $magic (expected $_magic)');
    }
    offset += 4;

    final version = data.getUint16(offset, Endian.little);
    if (version != _supportedVersion) {
      throw OsmLoadException(
        'Unsupported version: $version (expected $_supportedVersion)',
      );
    }
    offset += 2;

    final nodeCount = data.getUint32(offset, Endian.little);
    offset += 4;

    final edgeCount = data.getUint32(offset, Endian.little);
    offset += 4;

    // Skip reserved bytes
    offset += 2;

    // Validate minimum size
    final expectedMinSize = 16 + (nodeCount * 16);
    if (bytes.length < expectedMinSize) {
      throw OsmLoadException(
        'File truncated: ${bytes.length} bytes (expected >= $expectedMinSize)',
      );
    }

    final oldToNew = Int32List(nodeCount);
    for (int i = 0; i < nodeCount; i++) {
      oldToNew[i] = -1;
    }

    final nodes = <OsmNode>[];
    for (int i = 0; i < nodeCount; i++) {
      final lat = data.getFloat32(offset, Endian.little);
      offset += 4;
      final lon = data.getFloat32(offset, Endian.little);
      offset += 4;
      final osmId = data.getUint64(offset, Endian.little);
      offset += 8;

      if (lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon) {
        final newIndex = nodes.length;
        oldToNew[i] = newIndex;
        nodes.add(OsmNode(index: newIndex, osmId: osmId, lat: lat, lon: lon));
      }

      if (i % 50000 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    // Edges start after nodes.
    final edgesOffset = 16 + (nodeCount * 16);
    if (bytes.length < edgesOffset) {
      throw OsmLoadException('File truncated before edges section');
    }
    offset = edgesOffset;

    final edges = <OsmEdge>[];
    for (int i = 0; i < edgeCount; i++) {
      final fromOld = data.getUint32(offset, Endian.little);
      offset += 4;
      final toOld = data.getUint32(offset, Endian.little);
      offset += 4;
      final distanceM = data.getFloat32(offset, Endian.little);
      offset += 4;
      final roadTypeValue = data.getUint8(offset);
      offset += 1;
      final oneway = data.getUint8(offset) == 1;
      offset += 1;
      offset += 2; // padding

      if (fromOld >= nodeCount || toOld >= nodeCount) {
        continue;
      }
      final fromNew = oldToNew[fromOld];
      final toNew = oldToNew[toOld];
      if (fromNew < 0 || toNew < 0) continue;

      edges.add(
        OsmEdge(
          fromIndex: fromNew,
          toIndex: toNew,
          distanceM: distanceM,
          roadType: RoadType.fromValue(roadTypeValue),
          isOneway: oneway,
        ),
      );

      if (i % 100000 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    return OsmGraph.build(nodes: nodes, edges: edges);
  }

  /// Load graph from raw bytes.
  ///
  /// This is the core loading function used by other methods.
  static OsmGraph loadBytes(Uint8List bytes) {
    if (bytes.length < 16) {
      throw OsmLoadException('File too small: ${bytes.length} bytes');
    }

    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    int offset = 0;

    // Read header
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    if (magic != _magic) {
      throw OsmLoadException('Invalid magic: $magic (expected $_magic)');
    }
    offset += 4;

    final version = data.getUint16(offset, Endian.little);
    if (version != _supportedVersion) {
      throw OsmLoadException(
        'Unsupported version: $version (expected $_supportedVersion)',
      );
    }
    offset += 2;

    final nodeCount = data.getUint32(offset, Endian.little);
    offset += 4;

    final edgeCount = data.getUint32(offset, Endian.little);
    offset += 4;

    // Skip reserved bytes
    offset += 2;

    // Validate file size
    final expectedSize = 16 + (nodeCount * 16) + (edgeCount * 16);
    if (bytes.length < expectedSize) {
      throw OsmLoadException(
        'File truncated: ${bytes.length} bytes (expected $expectedSize)',
      );
    }

    // Read nodes
    final nodes = <OsmNode>[];
    for (int i = 0; i < nodeCount; i++) {
      final lat = data.getFloat32(offset, Endian.little);
      offset += 4;
      final lon = data.getFloat32(offset, Endian.little);
      offset += 4;
      final osmId = data.getUint64(offset, Endian.little);
      offset += 8;

      nodes.add(OsmNode(index: i, osmId: osmId, lat: lat, lon: lon));
    }

    // Read edges
    final edges = <OsmEdge>[];
    for (int i = 0; i < edgeCount; i++) {
      final fromIndex = data.getUint32(offset, Endian.little);
      offset += 4;
      final toIndex = data.getUint32(offset, Endian.little);
      offset += 4;
      final distanceM = data.getFloat32(offset, Endian.little);
      offset += 4;
      final roadTypeValue = data.getUint8(offset);
      offset += 1;
      final oneway = data.getUint8(offset) == 1;
      offset += 1;
      // Skip padding
      offset += 2;

      edges.add(
        OsmEdge(
          fromIndex: fromIndex,
          toIndex: toIndex,
          distanceM: distanceM,
          roadType: RoadType.fromValue(roadTypeValue),
          isOneway: oneway,
        ),
      );
    }

    return OsmGraph.build(nodes: nodes, edges: edges);
  }

  /// Create a local test graph around a center.
  ///
  /// Used only as a fallback when the real .wkp asset cannot be loaded.
  /// Keeps the dashboard responsive by staying small (default ~3km radius).
  static OsmGraph createTestGraph({
    double centerLat = 12.9716,
    double centerLon = 77.5946,
    int? gridSize,
    double radiusM = 3000,
    double spacingMeters = 150,
  }) {
    final nodes = <OsmNode>[];
    final edges = <OsmEdge>[];

    // Convert meters to approximate degrees
    final latDelta = spacingMeters / 111000;
    final lonDelta = spacingMeters / (111000 * _cos(centerLat));

    final effectiveGridSize =
        gridSize ?? (((radiusM * 2) / spacingMeters).ceil() + 1);

    // Create grid of nodes around center.
    int nodeIndex = 0;
    for (int row = 0; row < effectiveGridSize; row++) {
      for (int col = 0; col < effectiveGridSize; col++) {
        final lat = centerLat + (row - effectiveGridSize ~/ 2) * latDelta;
        final lon = centerLon + (col - effectiveGridSize ~/ 2) * lonDelta;
        nodes.add(
          OsmNode(
            index: nodeIndex,
            osmId: nodeIndex + 1000000,
            lat: lat,
            lon: lon,
          ),
        );
        nodeIndex++;
      }
    }

    // Create edges (4-connected grid, bidirectional)
    for (int row = 0; row < effectiveGridSize; row++) {
      for (int col = 0; col < effectiveGridSize; col++) {
        final fromIdx = row * effectiveGridSize + col;

        // Right neighbor
        if (col < effectiveGridSize - 1) {
          final toIdx = row * effectiveGridSize + col + 1;
          edges.add(
            OsmEdge(
              fromIndex: fromIdx,
              toIndex: toIdx,
              distanceM: spacingMeters,
              roadType: RoadType.residential,
              isOneway: false,
            ),
          );
          edges.add(
            OsmEdge(
              fromIndex: toIdx,
              toIndex: fromIdx,
              distanceM: spacingMeters,
              roadType: RoadType.residential,
              isOneway: false,
            ),
          );
        }

        // Bottom neighbor
        if (row < effectiveGridSize - 1) {
          final toIdx = (row + 1) * effectiveGridSize + col;
          edges.add(
            OsmEdge(
              fromIndex: fromIdx,
              toIndex: toIdx,
              distanceM: spacingMeters,
              roadType: RoadType.residential,
              isOneway: false,
            ),
          );
          edges.add(
            OsmEdge(
              fromIndex: toIdx,
              toIndex: fromIdx,
              distanceM: spacingMeters,
              roadType: RoadType.residential,
              isOneway: false,
            ),
          );
        }
      }
    }

    return OsmGraph.build(nodes: nodes, edges: edges);
  }

  static double _cos(double degrees) {
    return _cosDegrees(degrees);
  }

  static double _cosDegrees(double degrees) {
    return _cosRadians(degrees * 3.14159265359 / 180);
  }

  static double _cosRadians(double radians) {
    // Simple cosine approximation
    return 1 -
        (radians * radians) / 2 +
        (radians * radians * radians * radians) / 24;
  }
}

/// Exception thrown when loading OSM data fails.
class OsmLoadException implements Exception {
  OsmLoadException(this.message);
  final String message;

  @override
  String toString() => 'OsmLoadException: $message';
}
