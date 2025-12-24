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
                      'line': {
                        'name': 'Green Line',
                        'vehicle': {'type': 'SUBWAY'},
                      },
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
                      'line': {
                        'name': 'Purple Line',
                        'vehicle': {'type': 'SUBWAY'},
                      }, // Different line name
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

  test(
    'TransferUtils should NOT emit spurious Start walking for interchange walks between metros',
    () {
      // Scenario: WALKING -> METRO A -> short WALKING (platform change) -> METRO B -> WALKING (final)
      // The short walking between Metro A and Metro B is an "interchange walk" and should
      // NOT produce a "Start walking" event - only the transfer event should appear.
      final mockDirections = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  // Step 0: Walk to station
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 800},
                    'start_location': {'lat': 12.0, 'lng': 77.0},
                  },
                  // Step 1: Metro Line A
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 4000},
                    'start_location': {'lat': 12.01, 'lng': 77.01},
                    'transit_details': {
                      'num_stops': 4,
                      'line': {
                        'name': 'Green Line',
                        'vehicle': {'type': 'SUBWAY'},
                      },
                      'arrival_stop': {
                        'name': 'Central Station',
                        'location': {'lat': 12.05, 'lng': 77.05},
                      },
                    },
                  },
                  // Step 2: SHORT interchange walk (platform change) - 300m
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 300},
                    'start_location': {'lat': 12.05, 'lng': 77.05},
                  },
                  // Step 3: Metro Line B
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 5000},
                    'start_location': {'lat': 12.052, 'lng': 77.052},
                    'transit_details': {
                      'num_stops': 5,
                      'line': {
                        'name': 'Purple Line',
                        'vehicle': {'type': 'SUBWAY'},
                      },
                      'arrival_stop': {
                        'name': 'End Station',
                        'location': {'lat': 12.10, 'lng': 77.10},
                      },
                    },
                  },
                  // Step 4: Final walk to destination
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 500},
                    'start_location': {'lat': 12.10, 'lng': 77.10},
                  },
                ],
              },
            ],
          },
        ],
      };

      final events = TransferUtils.buildRouteEvents(mockDirections);

      print('Interchange Walk Test - Generated Events:');
      for (var e in events) {
        print('${e.type} @ ${e.meters}m - ${e.label}');
      }

      // Expected events:
      // 1. Board transit @ 800m (WALKING -> METRO A)
      // 2. transfer @ 4800m (METRO A -> METRO B, at Central Station)
      // 3. Start walking @ 10100m (METRO B -> final WALKING)
      //
      // The "Start walking" at 4800m (metro -> interchange walk) should NOT appear.
      // The "Board transit" at 5100m (interchange walk -> metro) should NOT appear.

      // Count "Start walking" events - should be exactly 1 (at the end)
      final startWalkingEvents =
          events.where((e) => e.label == 'Start walking').toList();
      expect(
        startWalkingEvents.length,
        1,
        reason: 'Should have exactly 1 Start walking event (final walk only)',
      );
      expect(
        startWalkingEvents.first.meters,
        greaterThan(10000),
        reason:
            'Start walking should be at the end of the route, not in the middle',
      );

      // Count "Board transit" events - should be exactly 1 (initial boarding)
      final boardTransitEvents =
          events.where((e) => e.label == 'Board transit').toList();
      expect(
        boardTransitEvents.length,
        1,
        reason:
            'Should have exactly 1 Board transit event (initial boarding only)',
      );
      expect(
        boardTransitEvents.first.meters,
        800,
        reason: 'Board transit should be at the first metro boarding',
      );

      // There should be a transfer event
      final transferEvents = events.where((e) => e.type == 'transfer').toList();
      expect(
        transferEvents,
        isNotEmpty,
        reason: 'Should have a transfer event',
      );
    },
  );
}
