import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'dart:io';

/// Reproduction test: Mumbai Metro Transfer Alarm Issue
/// Problem: Alarm fires 2 stops prior to Andheri (Leg 2 start)
/// Expected: Alarm fires 2 stops prior to DN Nagar (Leg 0 end)

void main() {
  test('Mumbai Transfer - Trace alarm trigger point', () async {
    final logFile = File('repro_mumbai_alarm_trace.txt');
    if (await logFile.exists()) await logFile.delete();

    void log(String s) {
      print(s);
      logFile.writeAsStringSync('$s\n', mode: FileMode.append);
    }

    // Mumbai Route: Metro -> Walk -> Metro
    // Leg 0: Metro Line 1 to DN Nagar (0-2000m, 3 intermediate stops)
    // Leg 1: Walk to Andheri West (2000-2300m, no stops)
    // Leg 2: Metro Line 2A from Andheri West (2300-7300m, 5 intermediate stops)

    final mockDirections = {
      'routes': [
        {
          'legs': [
            {
              'steps': [
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 2000},
                  'duration': {'value': 300},
                  'polyline': {'points': ''},
                  'transit_details': {
                    'num_stops': 3,
                    'line': {
                      'name': 'Metro Line 1',
                      'vehicle': {'type': 'SUBWAY'},
                    },
                    'arrival_stop': {
                      'name': 'DN Nagar',
                      'location': {'lat': 19.1241, 'lng': 72.8316},
                    },
                    'departure_stop': {
                      'name': 'Versova',
                      'location': {'lat': 19.1300, 'lng': 72.8100},
                    },
                  },
                },
                {
                  'travel_mode': 'WALKING',
                  'distance': {'value': 300},
                  'duration': {'value': 240},
                  'polyline': {'points': ''},
                },
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 5000},
                  'duration': {'value': 600},
                  'polyline': {'points': ''},
                  'transit_details': {
                    'num_stops': 5,
                    'line': {
                      'name': 'Metro Line 2A',
                      'vehicle': {'type': 'SUBWAY'},
                    },
                    'departure_stop': {
                      'name': 'Andheri West',
                      'location': {'lat': 19.1250, 'lng': 72.8330},
                    },
                    'arrival_stop': {
                      'name': 'Lower Oshiwara',
                      'location': {'lat': 19.1400, 'lng': 72.8300},
                    },
                  },
                },
              ],
            },
          ],
        },
      ],
    };

    log('=== EXTRACTING LEGS ===');
    final legs = TransferUtils.extractTransitLegStops(mockDirections);
    for (var i = 0; i < legs.length; i++) {
      final leg = legs[i];
      log('Leg $i: ${leg.lineName}');
      log('  isMetro: ${leg.isMetro}');
      log('  Range: ${leg.legStartMeters}m - ${leg.legEndMeters}m');
      log('  numStops: ${leg.numStops}');
      log('  stopMeters: ${leg.stopMeters}');
    }

    log('\n=== BUILDING ROUTE EVENTS ===');
    final events = TransferUtils.buildRouteEvents(mockDirections);
    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      log('Event $i: ${e.type} @ ${e.meters}m');
      log('  Label: ${e.label}');
      log('  LegIdx: ${e.associatedLegIndex}');
    }

    // Manually add stop meters for Leg 0 (TransferUtils may not populate for mock data)
    final leg0 = legs[0];
    final leg0Meters = leg0.legEndMeters - leg0.legStartMeters;
    final leg0Stops = <double>[];
    for (int j = 1; j <= leg0.numStops; j++) {
      leg0Stops.add(
        leg0.legStartMeters + (leg0Meters * (j / (leg0.numStops + 1))),
      );
    }
    log('\n=== LEG 0 COMPUTED STOP METERS ===');
    log('Leg 0 stops: $leg0Stops');
    // e.g., for 3 stops, 2000m leg: [500, 1000, 1500]
    // Alighting at 2000m means:
    // - At 1500m: 1 intermediate stops remaining + 1 alighting = 2 stops remaining

    final leg0WithStops = leg0.copyWith(stopMeters: leg0Stops);
    final modifiedLegs = [leg0WithStops, legs[1], legs[2]];

    log('\n=== TRACING ALARM TRIGGERS AT VARIOUS PROGRESS POINTS ===');

    // Test at different progress points on Leg 0
    final testProgressPoints = [
      500.0, // Just before 1st stop
      600.0, // Just after 1st stop
      1000.0, // At 2nd stop
      1100.0, // Just after 2nd stop
      1400.0, // Near 3rd stop (1500m)
      1500.0, // At 3rd stop
      1600.0, // After 3rd stop (1 stop to DN Nagar)
      1900.0, // Very close to DN Nagar
    ];

    for (final progress in testProgressPoints) {
      log('\n--- Progress: ${progress}m ---');

      // Determine which leg user is on
      int currentLegIndex = 0;
      for (int i = 0; i < modifiedLegs.length; i++) {
        final leg = modifiedLegs[i];
        if (progress >= leg.legStartMeters && progress < leg.legEndMeters) {
          currentLegIndex = i;
          break;
        }
      }
      log(
        'Current Leg: $currentLegIndex (${modifiedLegs[currentLegIndex].lineName})',
      );

      final isFinalLeg = currentLegIndex == modifiedLegs.length - 1;

      final trigger = AlarmEvaluator.evaluateCoinciding(
        mode: AlarmMode.stops,
        userValue: 2.0, // 2 stops prior
        progressMeters: progress,
        allEvents: events,
        firedEventIndexes: {},
        firedLegIds: {},
        isMetroLeg: modifiedLegs[currentLegIndex].isMetro,
        transitLegs: modifiedLegs,
        currentLegIndex: currentLegIndex,
        isFinalLeg: isFinalLeg,
      );

      if (trigger != null) {
        log('🔔 ALARM TRIGGERED!');
        log('  Type: ${trigger.eventType}');
        log('  Message: ${trigger.message}');
        log('  LegId: ${trigger.legId}');
        log('  Remaining Stops: ${trigger.remainingStops}');
      } else {
        log('  No alarm');
      }
    }

    log('\n=== EXPECTED BEHAVIOR ===');
    log(
      'Alarm should fire at ~1500m (where 2 stops remain to DN Nagar @ 2000m)',
    );
    log('NOT at a point relative to Andheri West (Leg 2 @ 2300m)');
  });
}
