import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  test('Non-transit steps should coalesce into one leg', () {
    // Route: Drive -> Drive -> Metro -> Metro -> Drive
    // Expected: 4 legs [Drive, Metro1, Metro2, Drive]
    // Bug: Could create 5+ legs if not coalescing

    final directions = {
      'routes': [
        {
          'legs': [
            {
              'steps': [
                // First driving segment (fragmented into 2 steps)
                {
                  'travel_mode': 'DRIVING',
                  'distance': {'value': 500},
                  'polyline': {'points': ''},
                },
                {
                  'travel_mode': 'DRIVING',
                  'distance': {'value': 500},
                  'polyline': {'points': ''},
                },
                // Metro leg 1
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 3000},
                  'polyline': {'points': ''},
                  'transit_details': {
                    'line': {
                      'vehicle': {'type': 'SUBWAY'},
                      'short_name': 'Green Line',
                    },
                    'num_stops': 5,
                    'departure_stop': {'name': 'Station A'},
                    'arrival_stop': {'name': 'Station B'},
                  },
                },
                // Metro leg 2
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 4000},
                  'polyline': {'points': ''},
                  'transit_details': {
                    'line': {
                      'vehicle': {'type': 'SUBWAY'},
                      'short_name': 'Purple Line',
                    },
                    'num_stops': 8,
                    'departure_stop': {'name': 'Station B'},
                    'arrival_stop': {'name': 'Station C'},
                  },
                },
                // Final driving segment (fragmented into 3 steps)
                {
                  'travel_mode': 'DRIVING',
                  'distance': {'value': 300},
                  'polyline': {'points': ''},
                },
                {
                  'travel_mode': 'DRIVING',
                  'distance': {'value': 400},
                  'polyline': {'points': ''},
                },
                {
                  'travel_mode': 'DRIVING',
                  'distance': {'value': 300},
                  'polyline': {'points': ''},
                },
              ],
            },
          ],
        },
      ],
    };

    final legs = TransferUtils.extractTransitLegStops(directions);

    print('\n--- Extracted Legs ---');
    for (int i = 0; i < legs.length; i++) {
      final leg = legs[i];
      print(
        'Leg $i: ${leg.lineName} (isMetro=${leg.isMetro}, legId=${leg.legId})',
      );
    }

    // Should have 4 legs: Drive (coalesced), Green Line, Purple Line, Drive (coalesced)
    expect(
      legs.length,
      equals(4),
      reason: 'Should coalesce consecutive driving steps into one leg',
    );

    // First leg should be a coalesced Drive leg with proper bounds
    expect(legs[0].lineName, equals('Drive'));
    expect(legs[0].isMetro, isFalse);
    expect(legs[0].legEndMeters, equals(1000)); // 500 + 500

    // Last leg should also be a coalesced Drive leg
    expect(legs[3].lineName, equals('Drive'));
    expect(legs[3].isMetro, isFalse);
  });
}
