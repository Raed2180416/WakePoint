import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/gtfs_stop_matcher.dart';

void main() {
  group('GtfsStopMatcher', () {
    test('filters stops by radius and orders by meters along polyline', () {
      // Straight-ish eastbound polyline around Bengaluru-ish latitude.
      final polyline = <LatLng>[
        const LatLng(12.9700, 77.5600),
        const LatLng(12.9700, 77.5700),
        const LatLng(12.9700, 77.5800),
      ];

      final stops = <GtfsStop>[
        // Near the start.
        const GtfsStop(
          id: 'A',
          name: 'Alpha Metro Station',
          location: LatLng(12.9703, 77.5610),
        ),
        // Near the middle.
        const GtfsStop(
          id: 'B',
          name: 'Bravo',
          location: LatLng(12.9697, 77.5710),
        ),
        // Near the end.
        const GtfsStop(
          id: 'C',
          name: 'Charlie',
          location: LatLng(12.9702, 77.5790),
        ),
        // Far away (should be filtered out).
        const GtfsStop(
          id: 'X',
          name: 'Xray',
          location: LatLng(12.9850, 77.6500),
        ),
      ];

      final matched = GtfsStopMatcher.matchStopsToPolyline(
        polyline: polyline,
        stops: stops,
        radiusMeters: 150.0,
      );

      expect(matched.map((m) => m.stop.id).toList(), ['A', 'B', 'C']);

      // Should be increasing along the route.
      expect(
        matched[0].metersAlongPolyline,
        lessThan(matched[1].metersAlongPolyline),
      );
      expect(
        matched[1].metersAlongPolyline,
        lessThan(matched[2].metersAlongPolyline),
      );

      // Snapped point should be close to the stop and lie on the same latitude line.
      for (final m in matched) {
        expect(m.distanceToPolylineMeters, lessThanOrEqualTo(150.0));
        expect((m.snapped.latitude - 12.9700).abs(), lessThan(1e-4));
      }
    });

    test('dedupes nearby same-name stops (platform duplicates)', () {
      final polyline = <LatLng>[
        const LatLng(12.9700, 77.5600),
        const LatLng(12.9700, 77.5800),
      ];

      final stops = <GtfsStop>[
        const GtfsStop(
          id: 'P1',
          name: 'Majestic Metro Station',
          location: LatLng(12.9702, 77.5701),
        ),
        const GtfsStop(
          id: 'P2',
          name: 'Majestic',
          location: LatLng(12.9702, 77.5702),
        ),
      ];

      final matched = GtfsStopMatcher.matchStopsToPolyline(
        polyline: polyline,
        stops: stops,
        radiusMeters: 150.0,
        dedupeMeters: 80.0,
      );

      expect(matched.length, 1);
      expect(
        matched.first.stop.name.toLowerCase().contains('majestic'),
        isTrue,
      );
    });
  });
}
