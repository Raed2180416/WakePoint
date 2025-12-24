// test/transit_leg_stops_test.dart
// Tests for discrete transit leg stop tracking

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/services/polyline_decoder.dart';
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

void main() {
  group('TransitLegStops discrete counting', () {
    test('stopsPassed counts correctly at each stop position', () {
      // Create a simple transit leg: 1000m with 4 stops
      final leg = TransitLegStops(
        legStartMeters: 500.0, // Route starts with 500m walking
        legEndMeters: 1500.0, // 1000m transit leg
        numStops: 4,
        stopPositions: [
          const LatLng(0.001, 0.001),
          const LatLng(0.002, 0.002),
          const LatLng(0.003, 0.003),
          const LatLng(0.004, 0.004),
        ],
        // 4 stops = 5 segments, stops at 1/5, 2/5, 3/5, 4/5 of leg
        // Leg is 1000m, so stops at: 200, 400, 600, 800m into leg
        // Cumulative: 700, 900, 1100, 1300m from route start
        stopMeters: [700.0, 900.0, 1100.0, 1300.0],
        lineName: 'Test Line',
      );

      // Before leg starts
      expect(leg.stopsPassed(400.0), equals(0));
      expect(leg.stopsRemaining(400.0), equals(4));

      // At leg start
      expect(leg.stopsPassed(500.0), equals(0));
      expect(leg.stopsRemaining(500.0), equals(4));

      // Between start and first stop
      expect(leg.stopsPassed(600.0), equals(0));
      expect(leg.stopsRemaining(600.0), equals(4));

      // At first stop
      expect(leg.stopsPassed(700.0), equals(1));
      expect(leg.stopsRemaining(700.0), equals(3));

      // Between first and second stop
      expect(leg.stopsPassed(800.0), equals(1));
      expect(leg.stopsRemaining(800.0), equals(3));

      // At second stop
      expect(leg.stopsPassed(900.0), equals(2));
      expect(leg.stopsRemaining(900.0), equals(2));

      // At third stop
      expect(leg.stopsPassed(1100.0), equals(3));
      expect(leg.stopsRemaining(1100.0), equals(1));

      // At fourth stop
      expect(leg.stopsPassed(1300.0), equals(4));
      expect(leg.stopsRemaining(1300.0), equals(0));

      // Past all stops but still in leg
      expect(leg.stopsPassed(1400.0), equals(4));
      expect(leg.stopsRemaining(1400.0), equals(0));

      // Past leg end
      expect(leg.stopsPassed(1600.0), equals(4));
      expect(leg.stopsRemaining(1600.0), equals(0));
    });

    test('countStopsPassed aggregates across multiple legs', () {
      final legs = [
        TransitLegStops(
          legStartMeters: 500.0,
          legEndMeters: 1500.0,
          numStops: 4,
          stopPositions: [],
          stopMeters: [700.0, 900.0, 1100.0, 1300.0],
          lineName: 'Line A',
        ),
        TransitLegStops(
          legStartMeters: 1500.0,
          legEndMeters: 3000.0,
          numStops: 3,
          stopPositions: [],
          // 3 stops = 4 segments, stops at 1/4, 2/4, 3/4 of 1500m leg
          // = 375, 750, 1125m into leg => 1875, 2250, 2625m cumulative
          stopMeters: [1875.0, 2250.0, 2625.0],
          lineName: 'Line B',
        ),
      ];

      // Before any transit
      expect(TransferUtils.countStopsPassed(legs, 400.0), equals(0));

      // In first leg, passed 2 stops
      expect(TransferUtils.countStopsPassed(legs, 950.0), equals(2));

      // End of first leg, all 4 stops passed
      expect(TransferUtils.countStopsPassed(legs, 1400.0), equals(4));

      // Into second leg, passed first stop
      expect(TransferUtils.countStopsPassed(legs, 2000.0), equals(4 + 1));

      // Into second leg, passed 2 stops
      expect(TransferUtils.countStopsPassed(legs, 2300.0), equals(4 + 2));

      // All stops passed
      expect(TransferUtils.countStopsPassed(legs, 3000.0), equals(4 + 3));
    });

    test('countStopsRemaining counts future stops correctly', () {
      final legs = [
        TransitLegStops(
          legStartMeters: 500.0,
          legEndMeters: 1500.0,
          numStops: 4,
          stopPositions: [],
          stopMeters: [700.0, 900.0, 1100.0, 1300.0],
          lineName: 'Line A',
        ),
        TransitLegStops(
          legStartMeters: 1500.0,
          legEndMeters: 3000.0,
          numStops: 3,
          stopPositions: [],
          stopMeters: [1875.0, 2250.0, 2625.0],
          lineName: 'Line B',
        ),
      ];

      // Before transit: all 7 stops remaining
      expect(TransferUtils.countStopsRemaining(legs, 400.0), equals(7));

      // In first leg, passed 2 stops: 5 remaining (2 in leg 1 + 3 in leg 2)
      expect(TransferUtils.countStopsRemaining(legs, 950.0), equals(2 + 3));

      // End of first leg: 3 remaining (all in leg 2)
      expect(TransferUtils.countStopsRemaining(legs, 1400.0), equals(3));

      // Into second leg, passed 1 stop: 2 remaining
      expect(TransferUtils.countStopsRemaining(legs, 2000.0), equals(2));

      // Past all stops
      expect(TransferUtils.countStopsRemaining(legs, 3000.0), equals(0));
    });

    test('extractTransitLegStops parses directions correctly', () {
      final step1Poly = encodePolyline([
        const LatLng(0.0, 0.0),
        const LatLng(0.005, 0.005),
      ]);
      final step2Poly = encodePolyline([
        const LatLng(0.005, 0.005),
        const LatLng(0.01, 0.01),
      ]);

      final directions = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 800},
                    'polyline': {'points': step1Poly},
                  },
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 2000},
                    'polyline': {'points': step2Poly},
                    'transit_details': {
                      'line': {
                        'short_name': 'M1',
                        'vehicle': {'type': 'SUBWAY'},
                      },
                      'num_stops': 5,
                    },
                  },
                ],
              },
            ],
          },
        ],
      };

      final legs = TransferUtils.extractTransitLegStops(directions);

      expect(legs.length, equals(1));
      expect(legs[0].legStartMeters, equals(800.0));
      expect(legs[0].legEndMeters, equals(2800.0));
      expect(legs[0].numStops, equals(5));
      expect(legs[0].lineName, equals('M1'));
      expect(legs[0].stopMeters.length, equals(5));

      // 5 stops = 6 segments, stops at 1/6, 2/6, 3/6, 4/6, 5/6 of 2000m
      // = 333.3, 666.7, 1000, 1333.3, 1666.7m into leg
      // + 800m walking = 1133.3, 1466.7, 1800, 2133.3, 2466.7m cumulative
      expect(legs[0].stopMeters[0], closeTo(1133.3, 1.0));
      expect(legs[0].stopMeters[1], closeTo(1466.7, 1.0));
      expect(legs[0].stopMeters[2], closeTo(1800.0, 1.0));
      expect(legs[0].stopMeters[3], closeTo(2133.3, 1.0));
      expect(legs[0].stopMeters[4], closeTo(2466.7, 1.0));
    });

    test('TransitLegStops serialization roundtrip', () {
      final original = TransitLegStops(
        legStartMeters: 1000.0,
        legEndMeters: 3000.0,
        numStops: 3,
        stopPositions: [
          const LatLng(0.001, 0.001),
          const LatLng(0.002, 0.002),
          const LatLng(0.003, 0.003),
        ],
        stopMeters: [1500.0, 2000.0, 2500.0],
        lineName: 'Red Line',
      );

      final json = original.toJson();
      final restored = TransitLegStops.fromJson(json);

      expect(restored.legStartMeters, equals(original.legStartMeters));
      expect(restored.legEndMeters, equals(original.legEndMeters));
      expect(restored.numStops, equals(original.numStops));
      expect(restored.lineName, equals(original.lineName));
      expect(restored.stopMeters.length, equals(original.stopMeters.length));
      expect(
        restored.stopPositions.length,
        equals(original.stopPositions.length),
      );

      for (int i = 0; i < original.stopMeters.length; i++) {
        expect(restored.stopMeters[i], equals(original.stopMeters[i]));
      }
      for (int i = 0; i < original.stopPositions.length; i++) {
        expect(
          restored.stopPositions[i].latitude,
          equals(original.stopPositions[i].latitude),
        );
        expect(
          restored.stopPositions[i].longitude,
          equals(original.stopPositions[i].longitude),
        );
      }
    });
  });

  group('Polyline utilities', () {
    test('haversineDistance calculates correct distances', () {
      // Two points 1 degree apart at equator ≈ 111km
      final d = haversineDistance(
        const LatLng(0.0, 0.0),
        const LatLng(0.0, 1.0),
      );
      expect(d, closeTo(111195, 100)); // ~111km
    });

    test('polylineLength sums segment distances', () {
      final points = [
        const LatLng(0.0, 0.0),
        const LatLng(0.001, 0.0), // ~111m
        const LatLng(0.001, 0.001), // ~111m
      ];
      final len = polylineLength(points);
      expect(len, closeTo(222, 5));
    });

    test('pointAlongPolyline finds correct point', () {
      final points = [
        const LatLng(0.0, 0.0),
        const LatLng(0.0, 0.01), // ~1.11km
      ];
      final totalLen = polylineLength(points);

      // Point at 50% should be at (0.0, 0.005)
      final mid = pointAlongPolyline(points, totalLen / 2);
      expect(mid, isNotNull);
      expect(mid!.latitude, closeTo(0.0, 0.0001));
      expect(mid.longitude, closeTo(0.005, 0.0001));
    });

    test('estimateStopPositions creates evenly spaced positions', () {
      final polyline = [
        const LatLng(0.0, 0.0),
        const LatLng(0.0, 0.012), // ~1.33km
      ];

      // 3 stops means 4 segments, stops at 1/4, 2/4, 3/4
      final stops = estimateStopPositions(polyline, 3);
      expect(stops.length, equals(3));

      expect(stops[0].longitude, closeTo(0.003, 0.0001)); // 1/4
      expect(stops[1].longitude, closeTo(0.006, 0.0001)); // 2/4
      expect(stops[2].longitude, closeTo(0.009, 0.0001)); // 3/4
    });
  });
}
