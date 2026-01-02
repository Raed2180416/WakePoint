import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  group('Dashboard Regression Check', () {
    test('TransferUtils.extractTransitLegStops safely handles data', () {
      // Mock directions with 1 transit step
      final directions = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 1000},
                    'polyline': {'points': ''}, // Empty polyline fallback
                    'transit_details': {
                      'num_stops': 3,
                      'line': {'name': 'Blue Line'},
                    },
                  },
                ],
              },
            ],
          },
        ],
      };

      try {
        final legs = TransferUtils.extractTransitLegStops(directions);
        expect(legs.length, 1);
        expect(legs.first.stopMeters.length, 3);
        // Verify stop meters are valid
        // Verify stop meters are valid
        expect(legs.first.stopMeters.any((m) => m.isNaN), isFalse);
      } catch (e) {
        fail('extractTransitLegStops threw exception: $e');
      }
    });

    test('Route parsing and serialization flow', () async {
      // Simulate what RouteSessionManager does
      final directions = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 1000},
                    'polyline': {'points': ''},
                    'transit_details': {
                      'num_stops': 3,
                      'line': {'name': 'Blue Line'},
                    },
                  },
                ],
              },
            ],
          },
        ],
      };

      final legs = TransferUtils.extractTransitLegStops(directions);

      // Simulate serialization in _maybeBroadcastCachedRoute
      try {
        final stopMeters =
            legs
                .expand((l) => l.stopMeters.map((m) => (m as num).toDouble()))
                .toList();
        final json = legs.map((l) => l.toJson()).toList();
        expect(stopMeters.length, 3);
        expect(json.isNotEmpty, isTrue);
      } catch (e) {
        fail('Serialization failed: $e');
      }
    });
  });
}
