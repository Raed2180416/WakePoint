import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  group('Switch Point Logic', () {
    test('Should ignore Walking <-> Driving transitions', () {
      final directions = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 100},
                    'start_location': {'lat': 0.0, 'lng': 0.0},
                  },
                  {
                    'travel_mode': 'DRIVING',
                    'distance': {'value': 100},
                    'start_location': {'lat': 0.001, 'lng': 0.001},
                  },
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 100},
                    'start_location': {'lat': 0.002, 'lng': 0.002},
                  },
                ],
              },
            ],
          },
        ],
      };

      final events = TransferUtils.buildRouteEvents(directions);

      // Should be empty because WALKING->DRIVING and DRIVING->WALKING are ignored
      expect(events.where((e) => e.type == 'mode_change'), isEmpty);
    });

    test('Should detect Walking -> Transit transitions', () {
      final directions = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 100},
                  },
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 500},
                    'transit_details': {
                      'line': {'short_name': 'L1'},
                      'arrival_stop': {
                        'name': 'Stop A',
                        'location': {'lat': 0.01, 'lng': 0.01},
                      },
                    },
                  },
                ],
              },
            ],
          },
        ],
      };

      final events = TransferUtils.buildRouteEvents(directions);
      expect(events.where((e) => e.type == 'mode_change'), isNotEmpty);
      expect(events.first.type, 'mode_change');
    });

    test('Should deduplicate events within 400m', () {
      final directions = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  // Event 1: Walking -> Transit at 100m
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 100},
                  },
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 200}, // Ends at 300m
                    'transit_details': {
                      'line': {'short_name': 'L1'},
                      'arrival_stop': {
                        'name': 'Transfer A',
                        'location': {'lat': 0.0, 'lng': 0.0},
                      },
                    },
                  },
                  // Event 2: Transit -> Transit (Transfer) at 300m (200m after first event)
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 500},
                    'transit_details': {
                      'line': {'short_name': 'L2'}, // Change of line
                      'arrival_stop': {
                        'name': 'End',
                        'location': {'lat': 0.1, 'lng': 0.1},
                      },
                    },
                  },
                ],
              },
            ],
          },
        ],
      };

      // Note: The mock above generates:
      // 1. mode_change at 100m (Walking -> Transit L1)
      // 2. transfer at 300m (L1 -> L2) (Because TransferUtils logic looks ahead)
      // The distance between them is 300 - 100 = 200m.
      // Expected: Only the first event (mode_change) should remain if dedupe radius is 400m.

      final events = TransferUtils.buildRouteEvents(directions);

      // If logic is correct, it should keep the first one
      expect(events.length, 1);
      expect(events.first.type, 'mode_change');
    });
  });
}
