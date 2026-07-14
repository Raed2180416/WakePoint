// test/metro_ordered_sequence_test.dart
//
// Proves the LINE-FIRST ordered-sequence path: when a metro leg is on a line
// that has a CONFIDENT hardcoded ordered sequence (lib/data/metro_line_sequences.dart),
// enhanceTransitLegStopsWithOsm uses THAT line's own stations, sliced to the leg
// segment and in along-line order — not a nearest-any-station radius grab.
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/data/metro_line_sequences.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

String encodePolyline(List<LatLng> points) {
  final str = StringBuffer();
  var lastLat = 0, lastLng = 0;
  for (final p in points) {
    final lat = (p.latitude * 1e5).round();
    final lng = (p.longitude * 1e5).round();
    _enc(lat - lastLat, str);
    _enc(lng - lastLng, str);
    lastLat = lat;
    lastLng = lng;
  }
  return str.toString();
}

void _enc(int v, StringBuffer s) {
  v = v < 0 ? ~(v << 1) : v << 1;
  while (v >= 0x20) {
    s.writeCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  s.writeCharCode(v + 63);
}

void main() {
  test('ordered hardcoded sequence is used and correctly ordered (Bengaluru Purple)',
      () async {
    final seq = kMetroLineSequences['bengaluru']?['purple'];
    expect(seq, isNotNull, reason: 'Bengaluru Purple must be a confident line');
    expect(seq!.length, greaterThan(12));

    // Take a mid-line window of the REAL sequence and build a polyline through it.
    const lo = 6, hi = 15; // inclusive-ish window
    final window = seq.sublist(lo, hi + 1);
    final polyPts = window.map((s) => LatLng(s.lat, s.lng)).toList();

    // stopsOverride carries Bengaluru stops on the polyline so the enhancer
    // derives city='bengaluru' from the OSM match; the ordered path then keys
    // (bengaluru, purple) into the hardcoded sequence.
    final stopsOverride = window
        .map((s) => {
              'id': 'osm_${s.name}',
              'city': 'bengaluru',
              'name': s.name,
              'lat': s.lat,
              'lng': s.lng,
              'line': 'Purple Line',
              'status': 'active',
            })
        .toList();

    final leg = TransitLegStops(
      legStartMeters: 0.0,
      legEndMeters: 10000.0,
      numStops: window.length - 2,
      stopPositions: polyPts,
      stopMeters: List.generate(polyPts.length, (i) => i * 1000.0),
      lineName: 'Purple',
      isMetro: true,
    );

    final enhanced = await TransferUtils.enhanceTransitLegStopsWithOsm(
      [leg],
      {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  {
                    'travel_mode': 'TRANSIT',
                    'polyline': {'points': encodePolyline(polyPts)},
                    'transit_details': {
                      'line': {
                        'short_name': 'Purple',
                        'vehicle': {'type': 'SUBWAY'},
                      },
                      'num_stops': window.length - 2,
                    },
                  },
                ],
              },
            ],
          },
        ],
      },
      stopsOverride: stopsOverride,
    );

    final names = enhanced.first.stopNames;
    expect(names, isNotEmpty);

    // Every returned stop must belong to the real Purple sequence...
    final seqNames = seq.map((s) => s.name).toList();
    for (final n in names) {
      expect(seqNames, contains(n), reason: '"$n" is not a real Purple station');
    }
    // ...and appear in strictly increasing along-line order (the key property).
    final idxs = names.map((n) => seqNames.indexOf(n)).toList();
    for (var i = 0; i < idxs.length - 1; i++) {
      expect(idxs[i] < idxs[i + 1], isTrue,
          reason: 'stops must be in along-line order: $names');
    }
    // ...and be a CONTIGUOUS run of the sequence (correct slice, no gaps).
    for (var i = 0; i < idxs.length - 1; i++) {
      expect(idxs[i + 1] - idxs[i], equals(1),
          reason: 'sliced stops must be contiguous on the line: $idxs');
    }
    expect(names.length, greaterThanOrEqualTo(4));
  });

  // Pan-India sweep: the ordered-sequence path must produce a correctly-ordered,
  // contiguous, own-line slice for a confident line in EVERY major city.
  for (final probe in const [
    ['bengaluru', 'purple'],
    ['delhi', 'yellow'],
    ['mumbai', 'blue'],
    ['kolkata', 'blue'],
    ['chennai', 'blue'],
    ['hyderabad', 'red'],
    ['kochi', '1'],
    ['pune', 'purple'],
  ]) {
    test('pan-India ordered slice is correct: ${probe[0]}/${probe[1]}', () async {
      final seq = kMetroLineSequences[probe[0]]?[probe[1]];
      if (seq == null || seq.length < 8) return; // skip if not a confident line here
      final lo = 2;
      final hi = (seq.length - 3).clamp(lo + 4, seq.length - 1);
      final window = seq.sublist(lo, hi + 1);
      final polyPts = window.map((s) => LatLng(s.lat, s.lng)).toList();
      final stopsOverride = window
          .map((s) => {
                'id': 'osm_${s.name}',
                'city': probe[0],
                'name': s.name,
                'lat': s.lat,
                'lng': s.lng,
                'line': probe[1],
                'status': 'active',
              })
          .toList();
      final leg = TransitLegStops(
        legStartMeters: 0.0,
        legEndMeters: 20000.0,
        numStops: window.length - 2,
        stopPositions: polyPts,
        stopMeters: List.generate(polyPts.length, (i) => i * 1000.0),
        lineName: probe[1],
        isMetro: true,
      );
      final enhanced = await TransferUtils.enhanceTransitLegStopsWithOsm(
        [leg],
        {
          'routes': [
            {
              'legs': [
                {
                  'steps': [
                    {
                      'travel_mode': 'TRANSIT',
                      'polyline': {'points': encodePolyline(polyPts)},
                      'transit_details': {
                        'line': {
                          'short_name': probe[1],
                          'vehicle': {'type': 'SUBWAY'},
                        },
                        'num_stops': window.length - 2,
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
        stopsOverride: stopsOverride,
      );
      final names = enhanced.first.stopNames;
      expect(names, isNotEmpty, reason: '${probe[0]}/${probe[1]} produced no stops');
      final seqNames = seq.map((s) => s.name).toList();
      final idxs = names.map((n) => seqNames.indexOf(n)).toList();
      for (final ix in idxs) {
        expect(ix, greaterThanOrEqualTo(0), reason: 'stop not on line: $names');
      }
      for (var i = 0; i < idxs.length - 1; i++) {
        expect(idxs[i + 1] - idxs[i], equals(1),
            reason: '${probe[0]}/${probe[1]} not contiguous/ordered: $idxs');
      }
    });
  }

  test('a line NOT in the hardcoded set still yields stops (fallback path)',
      () async {
    // canonicalizes to a token no confident sequence carries -> ordered path
    // is skipped, the OSM line-filter/fallback still produces stops.
    final stopsOverride = [
      {'id': 'a', 'city': 'testville', 'name': 'A', 'lat': 0.0, 'lng': 0.0, 'line': 'Zeta Line', 'status': 'active'},
      {'id': 'b', 'city': 'testville', 'name': 'B', 'lat': 0.01, 'lng': 0.0, 'line': 'Zeta Line', 'status': 'active'},
      {'id': 'c', 'city': 'testville', 'name': 'C', 'lat': 0.015, 'lng': 0.0, 'line': 'Zeta Line', 'status': 'active'},
    ];
    final leg = TransitLegStops(
      legStartMeters: 0.0, legEndMeters: 2000.0, numStops: 3,
      stopPositions: const [LatLng(0.005, 0.0), LatLng(0.01, 0.0), LatLng(0.015, 0.0)],
      stopMeters: const [500, 1000, 1500], lineName: 'Zeta', isMetro: true,
    );
    final enhanced = await TransferUtils.enhanceTransitLegStopsWithOsm(
      [leg],
      {'routes': [{'legs': [{'steps': [{'travel_mode': 'TRANSIT',
        'polyline': {'points': encodePolyline(const [LatLng(0.0, 0.0), LatLng(0.02, 0.0)])},
        'transit_details': {'line': {'short_name': 'Zeta', 'vehicle': {'type': 'SUBWAY'}}, 'num_stops': 3}}]}]}]},
      stopsOverride: stopsOverride,
    );
    expect(enhanced.first.stopNames, isNotEmpty);
  });
}
