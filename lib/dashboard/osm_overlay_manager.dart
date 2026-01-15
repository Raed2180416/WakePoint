/// OSM street overlay manager for Google Maps.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Road type for visualization styling.
enum OsmRoadType {
  motorway,
  trunk,
  primary,
  secondary,
  tertiary,
  residential,
  service,
  other,
}

/// Manages OSM street overlay polylines on Google Maps.
class OsmOverlayManager {
  OsmOverlayManager();

  final _polylines = <Polyline>{};
  bool _visible = true;
  bool _loaded = false;

  /// Whether overlay data is loaded.
  bool get isLoaded => _loaded;

  /// Whether overlay is visible.
  bool get isVisible => _visible;

  /// Get polylines to display on map.
  Set<Polyline> get polylines => _visible ? _polylines : {};

  /// Number of polylines.
  int get polylineCount => _polylines.length;

  /// Load OSM visualization data from asset.
  ///
  /// Expected JSON format:
  /// ```json
  /// [
  ///   {
  ///     "type": "residential",
  ///     "points": [[lat1, lng1], [lat2, lng2], ...]
  ///   },
  ///   ...
  /// ]
  /// ```
  Future<void> loadFromAsset(String assetPath) async {
    try {
      final jsonString = await rootBundle.loadString(assetPath);
      await loadFromJson(jsonString);
    } catch (e) {
      // Asset not found - this is expected if OSM data hasn't been preprocessed
      _loaded = false;
    }
  }

  /// Load OSM visualization data from JSON string.
  Future<void> loadFromJson(String jsonString) async {
    final data = jsonDecode(jsonString) as List<dynamic>;

    _polylines.clear();

    for (int i = 0; i < data.length; i++) {
      final item = data[i] as Map<String, dynamic>;
      final typeStr = item['type'] as String? ?? 'other';
      final roadType = _parseRoadType(typeStr);
      final points =
          (item['points'] as List<dynamic>)
              .map((p) => LatLng((p as List)[0] as double, p[1] as double))
              .toList();

      if (points.length < 2) continue;

      final style = _getStyle(roadType);

      _polylines.add(
        Polyline(
          polylineId: PolylineId('osm_$i'),
          points: points,
          color: style.color,
          width: style.width,
          patterns: style.patterns,
        ),
      );
    }

    _loaded = true;
  }

  /// Load simple polyline list (array of point arrays).
  Future<void> loadSimplePolylines(List<List<LatLng>> polylinePoints) async {
    _polylines.clear();

    for (int i = 0; i < polylinePoints.length; i++) {
      final points = polylinePoints[i];
      if (points.length < 2) continue;

      _polylines.add(
        Polyline(
          polylineId: PolylineId('osm_$i'),
          points: points,
          color: _defaultStyle.color,
          width: _defaultStyle.width,
        ),
      );
    }

    _loaded = true;
  }

  /// Set visibility of the overlay.
  void setVisible(bool visible) {
    _visible = visible;
  }

  /// Toggle visibility.
  void toggleVisible() {
    _visible = !_visible;
  }

  /// Clear all loaded data.
  void clear() {
    _polylines.clear();
    _loaded = false;
  }

  /// Set polylines directly (for programmatic loading).
  void setPolylines(Set<Polyline> polylines) {
    _polylines.clear();
    _polylines.addAll(polylines);
    _loaded = polylines.isNotEmpty;
  }

  OsmRoadType _parseRoadType(String type) {
    return switch (type.toLowerCase()) {
      'motorway' || 'motorway_link' => OsmRoadType.motorway,
      'trunk' || 'trunk_link' => OsmRoadType.trunk,
      'primary' || 'primary_link' => OsmRoadType.primary,
      'secondary' || 'secondary_link' => OsmRoadType.secondary,
      'tertiary' || 'tertiary_link' => OsmRoadType.tertiary,
      'residential' || 'living_street' => OsmRoadType.residential,
      'service' || 'unclassified' => OsmRoadType.service,
      _ => OsmRoadType.other,
    };
  }

  _PolylineStyle _getStyle(OsmRoadType type) {
    return switch (type) {
      OsmRoadType.motorway => _PolylineStyle(
        color: const Color(0x804A90D9), // Blue with transparency
        width: 4,
      ),
      OsmRoadType.trunk => _PolylineStyle(
        color: const Color(0x806AA84F), // Green with transparency
        width: 3,
      ),
      OsmRoadType.primary => _PolylineStyle(
        color: const Color(0x80E9967A), // Orange with transparency
        width: 3,
      ),
      OsmRoadType.secondary => _PolylineStyle(
        color: const Color(0x80F0E68C), // Yellow with transparency
        width: 2,
      ),
      OsmRoadType.tertiary => _PolylineStyle(
        color: const Color(0x80FFFFFF), // White with transparency
        width: 2,
      ),
      OsmRoadType.residential => _PolylineStyle(
        color: const Color(0x60CCCCCC), // Light gray with transparency
        width: 1,
      ),
      OsmRoadType.service => _PolylineStyle(
        color: const Color(0x40AAAAAA), // Very light gray
        width: 1,
      ),
      OsmRoadType.other => _defaultStyle,
    };
  }

  static final _defaultStyle = _PolylineStyle(
    color: const Color(0x40888888),
    width: 1,
  );
}

class _PolylineStyle {
  _PolylineStyle({required this.color, required this.width});

  final Color color;
  final int width;

  /// Default patterns - empty (solid line).
  List<PatternItem> get patterns => const [];
}

/// Extension for Color to support hex notation.
extension on Color {
  // ignore: unused_element
  static Color fromHex(String hex) {
    hex = hex.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.parse(hex, radix: 16));
  }
}
