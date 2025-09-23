import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  test('buildRouteEvents emits transfer and mode_change boundaries', () {
    final directions = {
      'routes': [
        {
          'legs': [
            {
              'steps': [
                {
                  'travel_mode': 'WALKING',
                  'distance': {'value': 300},
                },
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 800},
                  'transit_details': {
                    'line': {'short_name': 'A'},
                    'arrival_stop': {'name': 'Majestic'}
                  }
                },
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 1200},
                  'transit_details': {
                    'line': {'short_name': 'B'},
                    'arrival_stop': {'name': 'Central'}
                  }
                },
                {
                  'travel_mode': 'DRIVING',
                  'distance': {'value': 500},
                },
              ]
            }
          ]
        }
      ]
    };

    final events = TransferUtils.buildRouteEvents(directions);
    expect(events.length, 3);
    expect(events[0].type, 'mode_change');
    expect(events[0].meters, 300);
    expect(events[1].type, 'transfer');
    expect(events[1].meters, 300 + 800); // end of first transit step (A)
  expect(events[1].label, 'Majestic');
    expect(events[2].type, 'mode_change');
    expect(events[2].meters, 300 + 800 + 1200);
  });
}
