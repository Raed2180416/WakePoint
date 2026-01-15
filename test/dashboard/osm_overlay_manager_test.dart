/// Tests for OSM overlay manager.
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/dashboard/osm_overlay_manager.dart';

void main() {
  group('OsmOverlayManager', () {
    late OsmOverlayManager manager;

    setUp(() {
      manager = OsmOverlayManager();
    });

    test('starts not loaded and visible', () {
      expect(manager.isLoaded, isFalse);
      expect(manager.isVisible, isTrue);
      expect(manager.polylineCount, 0);
    });

    test('loadFromJson parses valid JSON', () async {
      const json = '''
      [
        {
          "type": "residential",
          "points": [[12.9716, 77.5946], [12.9720, 77.5950]]
        },
        {
          "type": "primary",
          "points": [[12.9700, 77.5900], [12.9705, 77.5910], [12.9710, 77.5920]]
        }
      ]
      ''';

      await manager.loadFromJson(json);

      expect(manager.isLoaded, isTrue);
      expect(manager.polylineCount, 2);
    });

    test('loadFromJson skips polylines with less than 2 points', () async {
      const json = '''
      [
        {
          "type": "residential",
          "points": [[12.9716, 77.5946]]
        },
        {
          "type": "primary",
          "points": [[12.9700, 77.5900], [12.9705, 77.5910]]
        }
      ]
      ''';

      await manager.loadFromJson(json);

      expect(manager.polylineCount, 1);
    });

    test('loadSimplePolylines works', () async {
      final polylines = [
        [const LatLng(12.97, 77.59), const LatLng(12.98, 77.60)],
        [
          const LatLng(12.95, 77.58),
          const LatLng(12.96, 77.59),
          const LatLng(12.97, 77.60),
        ],
      ];

      await manager.loadSimplePolylines(polylines);

      expect(manager.isLoaded, isTrue);
      expect(manager.polylineCount, 2);
    });

    test('setVisible controls polyline output', () async {
      const json = '''
      [
        {
          "type": "residential",
          "points": [[12.9716, 77.5946], [12.9720, 77.5950]]
        }
      ]
      ''';

      await manager.loadFromJson(json);

      // Initially visible
      expect(manager.polylines.length, 1);

      // Hide
      manager.setVisible(false);
      expect(manager.polylines.length, 0);
      expect(manager.isVisible, isFalse);

      // Show again
      manager.setVisible(true);
      expect(manager.polylines.length, 1);
    });

    test('toggleVisible works', () async {
      expect(manager.isVisible, isTrue);
      manager.toggleVisible();
      expect(manager.isVisible, isFalse);
      manager.toggleVisible();
      expect(manager.isVisible, isTrue);
    });

    test('clear removes all data', () async {
      const json = '''
      [
        {
          "type": "residential",
          "points": [[12.9716, 77.5946], [12.9720, 77.5950]]
        }
      ]
      ''';

      await manager.loadFromJson(json);
      expect(manager.isLoaded, isTrue);
      expect(manager.polylineCount, 1);

      manager.clear();

      expect(manager.isLoaded, isFalse);
      expect(manager.polylineCount, 0);
    });

    test('different road types get different styles', () async {
      const json = '''
      [
        {"type": "motorway", "points": [[12.97, 77.59], [12.98, 77.60]]},
        {"type": "trunk", "points": [[12.97, 77.59], [12.98, 77.60]]},
        {"type": "primary", "points": [[12.97, 77.59], [12.98, 77.60]]},
        {"type": "secondary", "points": [[12.97, 77.59], [12.98, 77.60]]},
        {"type": "tertiary", "points": [[12.97, 77.59], [12.98, 77.60]]},
        {"type": "residential", "points": [[12.97, 77.59], [12.98, 77.60]]},
        {"type": "service", "points": [[12.97, 77.59], [12.98, 77.60]]}
      ]
      ''';

      await manager.loadFromJson(json);

      expect(manager.polylineCount, 7);

      // Each polyline should be unique
      final polylineIds =
          manager.polylines.map((p) => p.polylineId.value).toSet();
      expect(polylineIds.length, 7);
    });

    test('handles missing type gracefully', () async {
      const json = '''
      [
        {"points": [[12.97, 77.59], [12.98, 77.60]]}
      ]
      ''';

      await manager.loadFromJson(json);

      expect(manager.isLoaded, isTrue);
      expect(manager.polylineCount, 1);
    });
  });
}
