import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  test(
    'TransferUtils should detect transfer between two TRANSIT steps even with missing line IDs',
    () {
      final mockDirections = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  // Step 0: Walk to station
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 1000},
                    'start_location': {'lat': 12.0, 'lng': 77.0},
                  },
                  // Step 1: Metro Line A
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 5000},
                    'start_location': {'lat': 12.01, 'lng': 77.01},
                    'transit_details': {
                      'num_stops': 5,
                      'line': {'name': 'Green Line'},
                      'arrival_stop': {
                        'name': 'Majestic',
                        'location': {'lat': 12.05, 'lng': 77.05},
                      },
                    },
                  },
                  // Step 2: Metro Line B (Transfer!)
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 5000},
                    'start_location': {
                      'lat': 12.05,
                      'lng': 77.05,
                    }, // Same location (interchange)
                    'transit_details': {
                      'num_stops': 4,
                      'line': {'name': 'Purple Line'}, // Different line name
                      // MISSING IDs to simulate worst case
                      'arrival_stop': {
                        'name': 'Whitefield',
                        'location': {'lat': 12.10, 'lng': 77.10},
                      },
                    },
                  },
                  // Step 3: Walk to destination
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 1000},
                    'start_location': {'lat': 12.10, 'lng': 77.10},
                  },
                ],
              },
            ],
          },
        ],
      };

      final events = TransferUtils.buildRouteEvents(mockDirections);

      print('Generated Events:');
      for (var e in events) {
        print('${e.type} @ ${e.meters}m - ${e.label}');
      }

      // Expectation:
      // 1. Walk start (0m) -> skipped? No, implicit.
      // 2. Board Transit (1000m) -> Mode Change 'Board transit'
      // 3. Transfer (6000m) -> 'transfer' at Majestic
      // 4. Start Walking (11000m) -> Mode Change 'Start walking'

      expect(events, isNotEmpty);

      // Check for Boarding
      final boardEvent = events.firstWhere(
        (e) => e.label == 'Board transit',
        orElse: () => throw 'Missing Boarding',
      );
      expect(boardEvent.meters, 1000);

      // Check for Transfer
      final transferEvent = events.firstWhere(
        (e) => e.type == 'transfer',
        orElse: () => throw 'Missing Transfer',
      );
      expect(transferEvent.label, 'Majestic');
      expect(transferEvent.meters, 6000); // 1000 walk + 5000 metro A

      // Check for Alighting
      final alightEvent = events.firstWhere(
        (e) => e.label == 'Start walking',
        orElse: () => throw 'Missing Alighting',
      );
      expect(alightEvent.meters, 11000); // 1000 + 5000 + 5000

      // Check for Destination? No, Destination is not an event in buildRouteEvents, it's implicit end.
    },
  );
}
