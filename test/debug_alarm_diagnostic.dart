// test/debug_alarm_diagnostic.dart
// Diagnostic test to trace exactly what's happening with alarm evaluation

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

String encodePolyline(List<LatLng> points) {
  var str = StringBuffer();
  var lastLat = 0;
  var lastLng = 0;
  for (final point in points) {
    int lat = (point.latitude * 1e5).round();
    int lng = (point.longitude * 1e5).round();
    int dLat = lat - lastLat;
    int dLng = lng - lastLng;
    _encode(dLat, str);
    _encode(dLng, str);
    lastLat = lat;
    lastLng = lng;
  }
  return str.toString();
}

void _encode(int v, StringBuffer str) {
  v = v < 0 ? ~(v << 1) : v << 1;
  while (v >= 0x20) {
    str.writeCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  str.writeCharCode(v + 63);
}

// Realistic route: Walk (fragmented) -> Green Metro -> Walk interchange -> Purple Metro -> Walk final
Map<String, dynamic> problemRoute() {
  return {
    'routes': [
      {
        'legs': [
          {
            'steps': [
              // 3 fragmented walking steps (should coalesce to 1 leg)
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 100},
                'polyline': {
                  'points': encodePolyline([
                    const LatLng(0.0, 0.0),
                    const LatLng(0.0007, 0.0007),
                  ]),
                },
              },
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 100},
                'polyline': {
                  'points': encodePolyline([
                    const LatLng(0.0007, 0.0007),
                    const LatLng(0.0014, 0.0014),
                  ]),
                },
              },
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 100},
                'polyline': {
                  'points': encodePolyline([
                    const LatLng(0.0014, 0.0014),
                    const LatLng(0.002, 0.002),
                  ]),
                },
              },
              // Green Line Metro (5 stops)
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 1500},
                'polyline': {
                  'points': encodePolyline([
                    const LatLng(0.002, 0.002),
                    const LatLng(0.015, 0.015),
                  ]),
                },
                'transit_details': {
                  'line': {
                    'short_name': 'Green Line',
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 5,
                  'departure_stop': {
                    'name': 'Peenya',
                    'location': {'lat': 0.002, 'lng': 0.002},
                  },
                  'arrival_stop': {
                    'name': 'Majestic',
                    'location': {'lat': 0.015, 'lng': 0.015},
                  },
                },
              },
              // Interchange walk (should coalesce with nothing before it since prev was metro)
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 200},
                'polyline': {
                  'points': encodePolyline([
                    const LatLng(0.015, 0.015),
                    const LatLng(0.017, 0.017),
                  ]),
                },
              },
              // Purple Line Metro (6 stops)
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 2000},
                'polyline': {
                  'points': encodePolyline([
                    const LatLng(0.017, 0.017),
                    const LatLng(0.035, 0.035),
                  ]),
                },
                'transit_details': {
                  'line': {
                    'short_name': 'Purple Line',
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 6,
                  'departure_stop': {
                    'name': 'Majestic',
                    'location': {'lat': 0.017, 'lng': 0.017},
                  },
                  'arrival_stop': {
                    'name': 'Whitefield',
                    'location': {'lat': 0.035, 'lng': 0.035},
                  },
                },
              },
              // Final walk
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 400},
                'polyline': {
                  'points': encodePolyline([
                    const LatLng(0.035, 0.035),
                    const LatLng(0.038, 0.038),
                  ]),
                },
              },
            ],
          },
        ],
      },
    ],
  };
}

void main() {
  test('Diagnostic: Log exact leg structure and event indices', () {
    final dir = problemRoute();

    // Extract legs
    final legs = TransferUtils.extractTransitLegStops(dir);

    print(
      '║                    TRANSIT LEG STOPS ANALYSIS                     ║',
    );
    print(
      '╠═══════════════════════════════════════════════════════════════════╣',
    );
    print('║ Total Legs: ${legs.length}');
    print(
      '╠═══════════════════════════════════════════════════════════════════╣',
    );

    for (int i = 0; i < legs.length; i++) {
      final leg = legs[i];
      print('║ Leg[$i]: ${leg.lineName}');
      print('║   isMetro: ${leg.isMetro}');
      print(
        '║   range: ${leg.legStartMeters.toStringAsFixed(0)}-${leg.legEndMeters.toStringAsFixed(0)}m',
      );
      print('║   numStops: ${leg.numStops}');
      print(
        '║   stopMeters: ${leg.stopMeters.map((m) => m.toStringAsFixed(0)).toList()}',
      );
      print(
        '╟───────────────────────────────────────────────────────────────────╢',
      );
    }
    print(
      '╚═══════════════════════════════════════════════════════════════════╝',
    );

    // Extract events
    final events = TransferUtils.buildRouteEvents(dir);

    print('');
    print(
      '╔═══════════════════════════════════════════════════════════════════╗',
    );
    print(
      '║                    ROUTE EVENTS ANALYSIS                          ║',
    );
    print(
      '╠═══════════════════════════════════════════════════════════════════╣',
    );
    print('║ Total Events: ${events.length}');
    print(
      '╠═══════════════════════════════════════════════════════════════════╣',
    );

    for (int i = 0; i < events.length; i++) {
      final e = events[i];
      print('║ Event[$i]: ${e.type}');
      print('║   meters: ${e.meters.toStringAsFixed(0)}m');
      print('║   label: ${e.label}');
      print('║   associatedLegIndex: ${e.associatedLegIndex}');
      print(
        '╟───────────────────────────────────────────────────────────────────╢',
      );
    }
    print(
      '╚═══════════════════════════════════════════════════════════════════╝',
    );

    // Verify index alignment
    print('');
    print(
      '╔═══════════════════════════════════════════════════════════════════╗',
    );
    print(
      '║                    INDEX ALIGNMENT CHECK                          ║',
    );
    print(
      '╠═══════════════════════════════════════════════════════════════════╣',
    );

    for (final e in events) {
      if (e.associatedLegIndex != null) {
        final legIdx = e.associatedLegIndex!;
        if (legIdx >= 0 && legIdx < legs.length) {
          final leg = legs[legIdx];
          print('║ Event "${e.type}" @ ${e.meters.toStringAsFixed(0)}m');
          print(
            '║   -> Points to Leg[$legIdx]: ${leg.lineName} (${leg.legStartMeters.toStringAsFixed(0)}-${leg.legEndMeters.toStringAsFixed(0)}m)',
          );

          // Check if event meters is in the right leg's range
          final inRange =
              e.meters >= leg.legStartMeters * 0.9 &&
              e.meters <= leg.legEndMeters * 1.1;
          if (!inRange) {
            print(
              '║   ⚠️ MISMATCH: Event meters ${e.meters.toStringAsFixed(0)} not in leg range!',
            );
          } else {
            print('║   ✅ Event is in correct leg range');
          }
        } else {
          print(
            '║ Event "${e.type}" has INVALID legIndex: $legIdx (max: ${legs.length - 1})',
          );
        }
        print(
          '╟───────────────────────────────────────────────────────────────────╢',
        );
      }
    }
    print(
      '╚═══════════════════════════════════════════════════════════════════╝',
    );

    // Test alarm evaluation for different progress points
    print('');
    print(
      '╔═══════════════════════════════════════════════════════════════════╗',
    );
    print(
      '║                    ALARM EVALUATION SIMULATION                    ║',
    );
    print(
      '╠═══════════════════════════════════════════════════════════════════╣',
    );

    final firedLegIds = <String>{};
    final testProgressPoints = [
      100.0, // Early in walk
      200.0, // Should trigger preboard (40% of ~350m walk)
      500.0, // Early in Green Line
      1500.0, // Mid Green Line
      2500.0, // ~75% of Green Line - should trigger transfer
    ];

    for (final progress in testProgressPoints) {
      // Find current leg
      int currentLegIndex = -1;
      bool isFinalLeg = false;

      for (int i = 0; i < legs.length; i++) {
        if (progress >= legs[i].legStartMeters &&
            progress <= legs[i].legEndMeters) {
          currentLegIndex = i;
          break;
        }
      }
      if (currentLegIndex == -1 && progress > legs.last.legEndMeters) {
        currentLegIndex = legs.length - 1;
      }
      if (currentLegIndex == -1) currentLegIndex = 0;
      isFinalLeg = currentLegIndex == legs.length - 1;

      print(
        '║ Progress: ${progress.toStringAsFixed(0)}m -> Leg[$currentLegIndex]: ${legs[currentLegIndex].lineName}',
      );

      final trigger = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 2.0,
        progressMeters: progress,
        allEvents: events,
        firedEventIndexes: <int>{},
        firedLegIds: firedLegIds,
        isMetroLeg: legs[currentLegIndex].isMetro,
        transitLegs: legs,
        currentLegIndex: currentLegIndex,
        isFinalLeg: isFinalLeg,
      );

      if (trigger != null) {
        print('║   🔔 ALARM: ${trigger.eventType} - ${trigger.message}');
        firedLegIds.add(legs[currentLegIndex].legId);
      } else {
        print('║   (no alarm)');
      }
      print(
        '╟───────────────────────────────────────────────────────────────────╢',
      );
    }

    print('║ Final firedLegIds: $firedLegIds');
    print(
      '╚═══════════════════════════════════════════════════════════════════╝',
    );

    // Verify expectations
    expect(legs.length, 5, reason: 'Should have 5 coalesced legs');
    expect(legs[0].lineName, 'Walk', reason: 'Leg 0 should be coalesced Walk');
    expect(
      legs[1].lineName,
      'Green Line',
      reason: 'Leg 1 should be Green Line',
    );
    expect(
      legs[2].lineName,
      'Walk',
      reason: 'Leg 2 should be interchange Walk',
    );
    expect(
      legs[3].lineName,
      'Purple Line',
      reason: 'Leg 3 should be Purple Line',
    );
    expect(legs[4].lineName, 'Walk', reason: 'Leg 4 should be final Walk');
  });
}
