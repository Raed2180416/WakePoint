// test/metro_wrong_snap_test.dart
//
// Regression tests for the WRONG-METRO-STATION-SNAP bug.
//
// enhanceTransitLegStopsWithOsm used to inject ANY OSM station within 500m of a
// leg's polyline into that leg's stop list — including a parallel OTHER-line
// station ~150m away (e.g. Mumbai DN Nagar/Blue vs Andheri West/Yellow). The
// line filter must keep only stops whose canonical line matches the leg's line,
// while a safety net guarantees we never emit ZERO stops for an unknown line.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// --- Polyline encoder (matches Google's algorithm), copied from sibling tests.
String encodePolyline(List<LatLng> points) {
  final str = StringBuffer();
  var lastLat = 0;
  var lastLng = 0;
  for (final point in points) {
    final lat = (point.latitude * 1e5).round();
    final lng = (point.longitude * 1e5).round();
    _encode(lat - lastLat, str);
    _encode(lng - lastLng, str);
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

// A straight, north-running Blue-line polyline at longitude 0.0, from
// lat 0.0 to lat 0.02 (~2224 m long).
const LatLng _polyStart = LatLng(0.0, 0.0);
const LatLng _polyEnd = LatLng(0.02, 0.0);

// Three Blue-line intermediate stations sitting exactly on the polyline,
// clear of the 50 m endpoint tolerance.
final List<Map<String, dynamic>> _blueStops = [
  {
    'id': 'BLUE_1',
    'city': 'mumbai',
    'name': 'Blue Alpha',
    'lat': 0.005,
    'lng': 0.0,
    'line': '&#x25D9;  Blue Line', // dirty OSM label (HTML entity + spacing)
    'status': 'active',
  },
  {
    'id': 'BLUE_2',
    'city': 'mumbai',
    'name': 'Blue Beta',
    'lat': 0.010,
    'lng': 0.0,
    'line': '&#x25D9;  Blue Line',
    'status': 'active',
  },
  {
    'id': 'BLUE_3',
    'city': 'mumbai',
    'name': 'Blue Gamma',
    'lat': 0.015,
    'lng': 0.0,
    'line': '&#x25D9;  Blue Line',
    'status': 'active',
  },
];

// A parallel OTHER-line station ~145 m east of Blue Beta: within the 500 m
// match radius, so it snaps to the polyline — but it belongs to the Yellow line
// and MUST be excluded from a Blue-line leg.
final Map<String, dynamic> _yellowParallel = {
  'id': 'YELLOW_PARALLEL',
  'city': 'mumbai',
  'name': 'Yellow Parallel',
  'lat': 0.010,
  'lng': 0.0013, // ~145 m off the polyline
  'line': '&#x25D9;  Yellow Line',
  'status': 'active',
};

Map<String, dynamic> _directionsWithBluePolyline(String lineShortName) {
  final poly = encodePolyline([_polyStart, _polyEnd]);
  return {
    'routes': [
      {
        'legs': [
          {
            'steps': [
              {
                'travel_mode': 'TRANSIT',
                'polyline': {'points': poly},
                'transit_details': {
                  'line': {
                    'short_name': lineShortName,
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 3,
                },
              },
            ],
          },
        ],
      },
    ],
  };
}

TransitLegStops _blueLeg({
  required String lineName,
  required int numStops,
}) {
  return TransitLegStops(
    legStartMeters: 0.0,
    legEndMeters: 2224.0, // ~length of the polyline
    numStops: numStops,
    // Pre-enhancement placeholders (uniform); the enhancer replaces these.
    stopPositions: const [
      LatLng(0.005, 0.0),
      LatLng(0.010, 0.0),
      LatLng(0.015, 0.0),
    ],
    stopMeters: const [556.0, 1112.0, 1668.0],
    lineName: lineName,
    isMetro: true,
  );
}

void main() {
  group('WRONG-METRO-STATION-SNAP line filter', () {
    test(
      'wrong-line parallel station is excluded from a Blue-line leg',
      () async {
        final stops = [..._blueStops, _yellowParallel];
        // Google labels the leg cleanly as "Blue Line"; OSM labels are dirty.
        final leg = _blueLeg(lineName: 'Blue Line', numStops: 3);

        final enhanced = await TransferUtils.enhanceTransitLegStopsWithOsm(
          [leg],
          _directionsWithBluePolyline('Blue Line'),
          stopsOverride: stops,
        );

        expect(enhanced.length, equals(1));
        final result = enhanced.first;

        // Non-diverged path: positions came from real (filtered) OSM matches.
        expect(
          result.isActualPositions,
          isTrue,
          reason: 'Filtered Blue count (3) matches Google num_stops (3)',
        );

        // Only Blue-line stops survive; the Yellow parallel is gone.
        expect(
          result.stopNames,
          containsAll(<String>['Blue Alpha', 'Blue Beta', 'Blue Gamma']),
        );
        expect(
          result.stopNames,
          isNot(contains('Yellow Parallel')),
          reason: 'Parallel Yellow-line station must NOT snap into a Blue leg',
        );
        expect(result.stopNames.length, equals(3));
        expect(result.numStops, equals(3));
      },
    );

    test(
      'bare color name ("Blue") still matches the dirty OSM "Blue Line" label',
      () async {
        final stops = [..._blueStops, _yellowParallel];
        // Google sometimes gives just the color as short_name.
        final leg = _blueLeg(lineName: 'Blue', numStops: 3);

        final enhanced = await TransferUtils.enhanceTransitLegStopsWithOsm(
          [leg],
          _directionsWithBluePolyline('Blue'),
          stopsOverride: stops,
        );

        final result = enhanced.first;
        expect(
          result.stopNames,
          containsAll(<String>['Blue Alpha', 'Blue Beta', 'Blue Gamma']),
        );
        expect(result.stopNames, isNot(contains('Yellow Parallel')));
      },
    );

    test(
      'safety net: unknown line name keeps the API-uniform leg, NOT cross-line stops',
      () async {
        final stops = [..._blueStops, _yellowParallel];
        // A line name that canonicalizes to something no stop carries, so the
        // own-line filter empties out.
        final leg = _blueLeg(lineName: 'Nonexistent Silver Line', numStops: 4);

        final enhanced = await TransferUtils.enhanceTransitLegStopsWithOsm(
          [leg],
          _directionsWithBluePolyline('Nonexistent Silver Line'),
          stopsOverride: stops,
        );

        final result = enhanced.first;
        // CORRECTNESS FIX (off-route stops): the OLD behavior scooped the whole
        // 150m corridor — including the PARALLEL line's station — into this leg.
        // That counted a stop not on this route. Now an unknown line keeps the
        // API-derived leg (uniform num_stops, on-route by construction) and NEVER
        // injects a cross-line station.
        expect(
          result.stopNames,
          isNot(contains('Yellow Parallel')),
          reason: 'a parallel-line station must never be counted on this leg',
        );
        // The API num_stops is preserved (the leg is not emptied).
        expect(result.numStops, equals(4));
      },
    );
  });
}
