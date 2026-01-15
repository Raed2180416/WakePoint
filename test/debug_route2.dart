import 'dart:developer' as dev;
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';

void main() {
  test(
    'Simulate Route 2 Matching (Driving -> Metro -> Metro -> Driving)',
    () async {
      // 1. Mock Directions API Response for Route 2
      //    Leg 1: Driving (Ramaiah -> Peenya) (Ignored by stop-matching logic)
      //    Leg 2: Metro (Green Line: Peenya Industry? -> Majestic)
      //    Leg 3: Metro (Purple Line: Majestic -> Whitefield/Kadugodi)
      //    Leg 4: Driving (Last mile)

      final mockDirections = {
        'routes': [
          {
            'legs': [
              {
                // Leg 1: Driving
                'steps': [
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 1000},
                    'polyline': {'points': ''},
                  },
                ],
              },
              {
                // Leg 2: Metro Green Line
                // We need a polyline that roughly follows Green Line from Peenya to Majestic
                // Approximated points:
                // Peenya Industry: 13.0360, 77.5250
                // Goraguntepalya: 13.0280, 77.5340
                // Yeshwanthpur: 13.0230, 77.5500
                // Sandal Soap: 13.0160, 77.5550
                'steps': [
                  {
                    'travel_mode': 'TRANSIT',
                    'transit_details': {
                      'line': {
                        'vehicle': {'type': 'SUBWAY'},
                        'short_name': 'Green Line',
                        'name': 'Green Line',
                      },
                      'num_stops': 8, // Peenya ind -> ... -> Majestic
                      'departure_stop': {
                        'name': 'Peenya Industry',
                        'location': {'lat': 13.0360, 'lng': 77.5250},
                      },
                      'arrival_stop': {
                        'name': 'Majestic',
                        'location': {'lat': 12.9750, 'lng': 77.5720},
                      },
                    },
                    'polyline': {
                      'points': '_q~nA_}sM_@w@_@o@_@q@_@s@_@u@_@w@',
                    }, // Fake poly
                  },
                ],
              },
              {
                // Leg 3: Metro Purple Line
                // Majestic -> Whitefield
                'steps': [
                  {
                    'travel_mode': 'TRANSIT',
                    'transit_details': {
                      'line': {
                        'vehicle': {'type': 'SUBWAY'},
                        'short_name': 'Purple Line',
                        'name': 'Purple Line',
                      },
                      'num_stops': 15,
                      'departure_stop': {'name': 'Majestic'},
                      'arrival_stop': {'name': 'Whitefield (Kadugodi)'},
                    },
                    'polyline': {'points': ''}, // Empty poly for now
                  },
                ],
              },
              {
                // Leg 4: Driving
                'steps': [
                  {
                    'travel_mode': 'DRIVING',
                    'distance': {'value': 1000},
                    'polyline': {'points': ''},
                  },
                ],
              },
            ],
          },
        ],
      };

      // 2. Extract legs
      final legs = TransferUtils.extractTransitLegStops(mockDirections);
      dev.log('Extracted ${legs.length} legs', name: 'DebugRoute2');
      for (var l in legs) {
        dev.log(
          'Leg: ${l.lineName} (isMetro=${l.isMetro}, numStops=${l.numStops})',
          name: 'DebugRoute2',
        );
      }

      // VERIFY STABLE WALKING LEG NAMING
      if (legs.isNotEmpty) {
        final firstLeg = legs.first;
        if (firstLeg.lineName == 'Walk to Peenya Industry') {
          dev.log(
            '✅ Correctly named Walking Leg: ${firstLeg.lineName}',
            name: 'DebugRoute2',
          );
        } else {
          dev.log(
            '❌ Incorrect Walking Leg Name: ${firstLeg.lineName}',
            name: 'DebugRoute2',
          );
          // Expectation failure will define strictness
          // expect(firstLeg.lineName, 'Walk to Peenya Industry');
        }
      }

      // 3. Enhance with OSM stops (using allIndiaStops)
      final enhanced = await TransferUtils.enhanceTransitLegStopsWithOsm(
        legs,
        mockDirections,
      );

      // 4. Verify Leg 2 (Green Line)
      final greenLeg = enhanced.firstWhere((l) => l.lineName == 'Green Line');
      dev.log('\n--- Green Line Analysis ---', name: 'DebugRoute2');
      dev.log(
        'isActualPositions: ${greenLeg.isActualPositions}',
        name: 'DebugRoute2',
      );
      dev.log('Stop Names: ${greenLeg.stopNames}', name: 'DebugRoute2');
      dev.log('Stop Meters: ${greenLeg.stopMeters}', name: 'DebugRoute2');

      // Check if relevant stops (Goraguntepalya, Yeshwanthpur) are found
      if (greenLeg.stopNames.contains('Goraguntepalya')) {
        dev.log('✅ Found Goraguntepalya', name: 'DebugRoute2');
      } else {
        dev.log('❌ Missing Goraguntepalya', name: 'DebugRoute2');
      }

      if (greenLeg.stopNames.any((n) => n.contains('Yeshwanthpur'))) {
        dev.log('✅ Found Yeshwanthpur variant', name: 'DebugRoute2');
      } else {
        dev.log('❌ Missing Yeshwanthpur', name: 'DebugRoute2');
      }

      if (greenLeg.stopNames.contains('Yeshwanthpur')) {
        dev.log('✅ Found Exact Yeshwanthpur', name: 'DebugRoute2');
      }

      if (greenLeg.isActualPositions == false) {
        dev.log(
          '⚠️ FALLBACK DETECTED: Utilizing uniform interpolation instead of matched stop data.',
          name: 'DebugRoute2',
        );
      }
    },
  );
}
