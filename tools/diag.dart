// Simple diagnostic - runs extractTransitLegStops and buildRouteEvents
// and dumps the results

import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

String enc(List<LatLng> pts) {
  var s = StringBuffer();
  var pLat = 0, pLng = 0;
  for (final p in pts) {
    int lat = (p.latitude * 1e5).round();
    int lng = (p.longitude * 1e5).round();
    _e(lat - pLat, s);
    _e(lng - pLng, s);
    pLat = lat;
    pLng = lng;
  }
  return s.toString();
}

void _e(int v, StringBuffer s) {
  v = v < 0 ? ~(v << 1) : v << 1;
  while (v >= 0x20) {
    s.writeCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  s.writeCharCode(v + 63);
}

// Route: 3 fragmented walks -> Green Metro -> Walk interchange -> Purple Metro -> Walk
Map<String, dynamic> route() => {
  'routes': [
    {
      'legs': [
        {
          'steps': [
            // 3 fragmented walking steps
            {
              'travel_mode': 'WALKING',
              'distance': {'value': 100},
              'polyline': {
                'points': enc([LatLng(0.0, 0.0), LatLng(0.0007, 0.0007)]),
              },
            },
            {
              'travel_mode': 'WALKING',
              'distance': {'value': 100},
              'polyline': {
                'points': enc([LatLng(0.0007, 0.0007), LatLng(0.0014, 0.0014)]),
              },
            },
            {
              'travel_mode': 'WALKING',
              'distance': {'value': 100},
              'polyline': {
                'points': enc([LatLng(0.0014, 0.0014), LatLng(0.002, 0.002)]),
              },
            },
            // Green Metro
            {
              'travel_mode': 'TRANSIT',
              'distance': {'value': 1500},
              'polyline': {
                'points': enc([LatLng(0.002, 0.002), LatLng(0.015, 0.015)]),
              },
              'transit_details': {
                'line': {
                  'short_name': 'Green',
                  'vehicle': {'type': 'SUBWAY'},
                },
                'num_stops': 5,
                'departure_stop': {
                  'name': 'A',
                  'location': {'lat': 0.002, 'lng': 0.002},
                },
                'arrival_stop': {
                  'name': 'B',
                  'location': {'lat': 0.015, 'lng': 0.015},
                },
              },
            },
            // Interchange walk
            {
              'travel_mode': 'WALKING',
              'distance': {'value': 200},
              'polyline': {
                'points': enc([LatLng(0.015, 0.015), LatLng(0.017, 0.017)]),
              },
            },
            // Purple Metro
            {
              'travel_mode': 'TRANSIT',
              'distance': {'value': 2000},
              'polyline': {
                'points': enc([LatLng(0.017, 0.017), LatLng(0.035, 0.035)]),
              },
              'transit_details': {
                'line': {
                  'short_name': 'Purple',
                  'vehicle': {'type': 'SUBWAY'},
                },
                'num_stops': 6,
                'departure_stop': {
                  'name': 'B',
                  'location': {'lat': 0.017, 'lng': 0.017},
                },
                'arrival_stop': {
                  'name': 'C',
                  'location': {'lat': 0.035, 'lng': 0.035},
                },
              },
            },
            // Final walk
            {
              'travel_mode': 'WALKING',
              'distance': {'value': 400},
              'polyline': {
                'points': enc([LatLng(0.035, 0.035), LatLng(0.038, 0.038)]),
              },
            },
          ],
        },
      ],
    },
  ],
};

void main() {
  final d = route();

  print('--- LEGS ---');
  final legs = TransferUtils.extractTransitLegStops(d);
  print('Count: ${legs.length}');
  for (int i = 0; i < legs.length; i++) {
    final l = legs[i];
    print(
      '[$i] ${l.lineName} metro=${l.isMetro} ${l.legStartMeters.toInt()}-${l.legEndMeters.toInt()}m stops=${l.numStops}',
    );
  }

  print('');
  print('--- EVENTS ---');
  final ev = TransferUtils.buildRouteEvents(d);
  print('Count: ${ev.length}');
  for (int i = 0; i < ev.length; i++) {
    final e = ev[i];
    print(
      '[$i] ${e.type} @ ${e.meters.toInt()}m legIdx=${e.associatedLegIndex} "${e.label}"',
    );
  }

  print('');
  print('--- VALIDATION ---');
  // Check if preboarding events point to correct legs
  for (final e in ev) {
    if (e.type == 'preBoarding' && e.associatedLegIndex != null) {
      final idx = e.associatedLegIndex!;
      if (idx >= 0 && idx < legs.length) {
        final leg = legs[idx];
        print(
          'preBoard @ ${e.meters.toInt()}m -> Leg[$idx] ${leg.lineName} (${leg.legStartMeters.toInt()}-${leg.legEndMeters.toInt()}m)',
        );
        if (!leg.isMetro) {
          print(
            '  ERROR: preBoarding should point to a METRO leg, not ${leg.lineName}',
          );
        } else {
          print('  OK: Points to metro leg');
        }
      }
    }
  }
}
