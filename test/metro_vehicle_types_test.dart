// test/metro_vehicle_types_test.dart
//
// BACKLOG #13: One shared `kMetroVehicleTypes` set drives BOTH metro predicates
//   * TransferUtils._isMetroTransitStep (tracking / stop-enhancement)
//   * RerouteConstraints._routeHasMetroLeg (reroute validation)
// so a TRAM / COMMUTER_TRAIN alternate is no longer rejected on reroute while
// being accepted for tracking.
//
// BACKLOG #28 (minimal safe scope): an explicit geocoded city carried on the
// leg (`TransitLegStops.cityKey`) overrides the majority-vote-over-matched-OSM
// city used for line-sequence / line-filter resolution. The vote is demoted to
// a fallback used only when no explicit city is present.

import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/metro_vehicle_types.dart';
import 'package:geowake2/services/reroute_constraints.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// --- Polyline encoder (matches Google's algorithm), copied from sibling tests.
String _encodePolyline(List<LatLng> points) {
  final str = StringBuffer();
  var lastLat = 0;
  var lastLng = 0;
  for (final point in points) {
    final lat = (point.latitude * 1e5).round();
    final lng = (point.longitude * 1e5).round();
    _enc(lat - lastLat, str);
    _enc(lng - lastLng, str);
    lastLat = lat;
    lastLng = lng;
  }
  return str.toString();
}

void _enc(int v, StringBuffer str) {
  v = v < 0 ? ~(v << 1) : v << 1;
  while (v >= 0x20) {
    str.writeCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  str.writeCharCode(v + 63);
}

Map<String, dynamic> _directionsForVehicle(String vehicleType) {
  final poly = _encodePolyline(const [LatLng(0.0, 0.0), LatLng(0.02, 0.0)]);
  return {
    'routes': [
      {
        'legs': [
          {
            // Distance/duration so the distance-mode alarm gate (which runs
            // AFTER the transit-metro gate) can also pass — isolating the test
            // to the metro-vehicle-type predicate.
            'distance': {'value': 2224},
            'duration': {'value': 300},
            'steps': [
              {
                'travel_mode': 'TRANSIT',
                'polyline': {'points': poly},
                'transit_details': {
                  'line': {
                    'short_name': 'Test Line',
                    'vehicle': {'type': vehicleType},
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

void main() {
  group('BACKLOG #13 — shared kMetroVehicleTypes drives both predicates', () {
    test('set contains the union incl. TRAM / COMMUTER_TRAIN / LIGHT_RAIL', () {
      expect(
        kMetroVehicleTypes,
        containsAll(<String>[
          'SUBWAY',
          'HEAVY_RAIL',
          'RAIL',
          'METRO_RAIL',
          'MONORAIL',
          'TRAM',
          'COMMUTER_TRAIN',
          'LIGHT_RAIL',
        ]),
      );
    });

    // For each metro vehicle type, BOTH predicates must agree it is metro.
    for (final vType in const ['TRAM', 'COMMUTER_TRAIN', 'LIGHT_RAIL']) {
      test('$vType is accepted by BOTH predicates', () {
        final directions = _directionsForVehicle(vType);

        // Transfer side: extractTransitLegStops marks the leg isMetro via
        // _isMetroTransitStep.
        final legs = TransferUtils.extractTransitLegStops(directions);
        expect(legs, isNotEmpty);
        expect(
          legs.first.isMetro,
          isTrue,
          reason: '_isMetroTransitStep must treat $vType as metro',
        );

        // Reroute side: the transit gate (which calls _routeHasMetroLeg) must
        // NOT reject a $vType-only alternate. Use a distance alarm so only the
        // transit-mode gate is exercised.
        const constraints = RerouteConstraints(
          alarmMode: 'distance',
          alarmValue: 1.0, // < route distance so distance gate passes
          transitMode: true,
        );
        final result = constraints.validate(directions);
        expect(
          result.isValid,
          isTrue,
          reason: '_routeHasMetroLeg must accept a $vType-only alternate: '
              '${result.failureReason}',
        );
      });
    }

    test('a non-metro BUS alternate is still rejected in transit mode', () {
      final directions = _directionsForVehicle('BUS');
      const constraints = RerouteConstraints(
        alarmMode: 'distance',
        alarmValue: 1.0,
        transitMode: true,
      );
      final result = constraints.validate(directions);
      expect(result.isValid, isFalse);
    });
  });

  group('BACKLOG #28 — explicit leg cityKey overrides majority vote', () {
    // A polyline with three on-line stops. The OSM stops are all labelled
    // city "mumbai" (so the majority vote would pick "mumbai"). We assert that
    // supplying an explicit, DIFFERENT geocoded cityKey ("delhi") wins: the
    // city guard then drops the mumbai-labelled stops (no confident Delhi/Blue
    // sequence exists) and the API-uniform leg is kept — proving the vote no
    // longer decides the leg's city.
    final onLineStops = <Map<String, dynamic>>[
      {
        'id': 'S1',
        'city': 'mumbai',
        'name': 'Alpha',
        'lat': 0.005,
        'lng': 0.0,
        'line': 'Blue Line',
        'status': 'active',
      },
      {
        'id': 'S2',
        'city': 'mumbai',
        'name': 'Beta',
        'lat': 0.010,
        'lng': 0.0,
        'line': 'Blue Line',
        'status': 'active',
      },
      {
        'id': 'S3',
        'city': 'mumbai',
        'name': 'Gamma',
        'lat': 0.015,
        'lng': 0.0,
        'line': 'Blue Line',
        'status': 'active',
      },
    ];

    Map<String, dynamic> directions() => {
          'routes': [
            {
              'legs': [
                {
                  'steps': [
                    {
                      'travel_mode': 'TRANSIT',
                      'polyline': {
                        'points': _encodePolyline(
                          const [LatLng(0.0, 0.0), LatLng(0.02, 0.0)],
                        ),
                      },
                      'transit_details': {
                        'line': {
                          'short_name': 'Blue Line',
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

    TransitLegStops leg({String? cityKey}) => TransitLegStops(
          legStartMeters: 0.0,
          legEndMeters: 2224.0,
          numStops: 3,
          stopPositions: const [
            LatLng(0.005, 0.0),
            LatLng(0.010, 0.0),
            LatLng(0.015, 0.0),
          ],
          stopMeters: const [556.0, 1112.0, 1668.0],
          lineName: 'Blue Line',
          isMetro: true,
          cityKey: cityKey,
        );

    test('control: no cityKey => majority vote ("mumbai") keeps OSM stops',
        () async {
      final enhanced = await TransferUtils.enhanceTransitLegStopsWithOsm(
        [leg(cityKey: null)],
        directions(),
        stopsOverride: onLineStops,
      );
      final result = enhanced.single;
      // Vote picked "mumbai"; mumbai-labelled stops pass the city guard.
      expect(result.isActualPositions, isTrue);
      expect(
        result.stopNames,
        containsAll(<String>['Alpha', 'Beta', 'Gamma']),
      );
    });

    test('explicit cityKey ("delhi") overrides the vote and filters them out',
        () async {
      final enhanced = await TransferUtils.enhanceTransitLegStopsWithOsm(
        [leg(cityKey: 'delhi')],
        directions(),
        stopsOverride: onLineStops,
      );
      final result = enhanced.single;
      // legCityKey is now the explicit "delhi" (NOT the "mumbai" vote), so the
      // mumbai-labelled stops fail the city guard and the API-uniform leg is
      // preserved instead of snapping to the wrong-city stations.
      expect(
        result.isActualPositions,
        isFalse,
        reason: 'explicit city must veto the majority-vote city',
      );
      expect(result.stopNames, isNot(contains('Alpha')));
      expect(result.stopNames, isNot(contains('Beta')));
      expect(result.stopNames, isNot(contains('Gamma')));
      expect(result.numStops, equals(3)); // API leg kept intact
    });

    test('cityKey round-trips through toJson / fromJson', () {
      final json = leg(cityKey: 'delhi').toJson();
      expect(json['cityKey'], equals('delhi'));
      final back = TransitLegStops.fromJson(json);
      expect(back.cityKey, equals('delhi'));
    });
  });
}
