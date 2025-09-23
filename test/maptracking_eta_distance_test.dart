import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/polyline_simplifier.dart';
import 'package:geowake2/services/snap_to_route.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/services/eta_utils.dart';

void main() {
  test('Computes ETA from directions step durations given snapped progress', () {
    final routePoints = <LatLng>[
      const LatLng(37.0, -122.0),
      const LatLng(37.0, -121.99),
      const LatLng(37.01, -121.99),
    ];
    final simplified = PolylineSimplifier.compressPolyline(routePoints);
    final directions = {
      'routes': [
        {
          'simplified_polyline': simplified,
          'legs': [
            {
              'steps': [
                {
                  'travel_mode': 'DRIVING',
                  'distance': {'value': 1000},
                  'duration': {'value': 600}, // 10 min
                },
                {
                  'travel_mode': 'DRIVING',
                  'distance': {'value': 2000},
                  'duration': {'value': 1800}, // 30 min
                },
              ]
            }
          ]
        }
      ]
    };
    // Snap a point halfway into first segment
    final snap = SnapToRouteEngine.snap(point: const LatLng(37.0, -121.995), polyline: routePoints, hintIndex: null, searchWindow: 30);
    // Build boundaries/durations
  final legs = (directions['routes'] as List).first['legs'] as List;
    final boundaries = <double>[];
    final durations = <double>[];
    double cum = 0.0;
    for (final leg in legs) {
      for (final step in (leg['steps'] as List)) {
        final m = (step['distance']['value'] as num).toDouble();
        final s = (step['duration']['value'] as num).toDouble();
        cum += m;
        boundaries.add(cum);
        durations.add(s);
      }
    }
    final etaSec = EtaUtils.etaRemainingSeconds(progressMeters: snap.progressMeters, stepBoundariesMeters: boundaries, stepDurationsSeconds: durations);
    expect(etaSec, isNotNull);
    // Approximately 5 min remaining in step1 + full step2 (30 min) = ~35 min => 2100s
    expect(etaSec!, closeTo(2100, 120));
  });

  test('Detects transfer boundary and computes time-to-switch with simple speed', () {
    final routePoints = <LatLng>[
      const LatLng(37.0, -122.0),
      const LatLng(37.0, -121.99),
      const LatLng(37.01, -121.99),
    ];
    final simplified = PolylineSimplifier.compressPolyline(routePoints);
    final directions = {
      'routes': [
        {
          'simplified_polyline': simplified,
          'legs': [
            {
              'steps': [
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 1000},
                  'transit_details': {
                    'line': {'short_name': 'A'}
                  }
                },
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 1500},
                  'transit_details': {
                    'line': {'short_name': 'B'}
                  }
                },
              ]
            }
          ]
        }
      ]
    };
    // Progress 200m in; speed 10 m/s -> switch after 800m -> 80s
    final snap = SnapToRouteEngine.snap(point: const LatLng(37.0, -121.9982), polyline: routePoints, hintIndex: null, searchWindow: 30);
    final boundaries = TransferUtils.buildTransferBoundariesMeters(directions, metroMode: true);
    expect(boundaries, isNotEmpty);
    final next = boundaries.firstWhere((b) => b > snap.progressMeters, orElse: () => -1);
    expect(next, greaterThan(0));
    final toSwitchM = next - snap.progressMeters;
    final spd = 10.0;
    final tSec = toSwitchM / spd;
    expect(tSec, inInclusiveRange(60, 120));
  });
}
