import 'dart:io' as java;
import 'dart:developer' as dev;
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  test('Compare Route 1 (Nagasandra) vs Route 2 (Peenya)', () async {
    // REALISTIC POLYLINE ENCODER
    String encodePoly(List<LatLng> points) {
      String encode(double val) {
        int v = (val * 1e5).round();
        v = (v < 0) ? ~(v << 1) : (v << 1);
        String s = '';
        while (v >= 0x20) {
          s += String.fromCharCode((0x20 | (v & 0x1f)) + 63);
          v >>= 5;
        }
        s += String.fromCharCode(v + 63);
        return s;
      }

      String str = '';
      double lastLat = 0;
      double lastLng = 0;
      for (final p in points) {
        str += encode(p.latitude - lastLat);
        str += encode(p.longitude - lastLng);
        lastLat = p.latitude;
        lastLng = p.longitude;
      }
      return str;
    }

    // Polyline points (approx Green Line):
    // Nagasandra -> Peenya Ind -> Peenya -> Goraguntepalya -> Yeshwantpur -> Sandal -> Majestic
    final points = [
      LatLng(13.048, 77.513), // Nagasandra
      LatLng(13.042, 77.520), // Dasarahalli
      LatLng(13.038, 77.523), // Jalahalli
      LatLng(13.036, 77.525), // Peenya Ind
      LatLng(13.032, 77.527), // Peenya
      LatLng(13.028, 77.534), // Goraguntepalya
      LatLng(13.023, 77.549), // Yeshwantpur
      LatLng(13.016, 77.555), // Sandal Soap
      LatLng(12.975, 77.572), // Majestic
    ];

    final fullPoly = encodePoly(points);
    // Route 2 starts at Peenya (Index 4)
    final partialPoly = encodePoly(points.sublist(4));

    // Route 1: Nagasandra -> Majestic
    final route1Directions = {
      'routes': [
        {
          'legs': [
            {
              'steps': [
                {
                  'travel_mode': 'TRANSIT',
                  'transit_details': {
                    'line': {
                      'vehicle': {'type': 'SUBWAY'},
                      'short_name': 'Green Line',
                    },
                    'num_stops': 8, // Peenya -> Majestic is 8 stops?
                    'departure_stop': {'name': 'Nagasandra'},
                    'arrival_stop': {'name': 'Majestic'},
                  },
                  'polyline': {'points': fullPoly},
                },
              ],
            },
          ],
        },
      ],
    };

    // Route 2: Peenya -> Majestic
    final route2Directions = {
      'routes': [
        {
          'legs': [
            {
              'steps': [
                {
                  'travel_mode': 'TRANSIT',
                  'transit_details': {
                    'line': {
                      'vehicle': {'type': 'SUBWAY'},
                      'short_name': 'Green Line',
                    },
                    'num_stops':
                        4, // Peenya, Gora, Yesh, Sandal, Majestic (5 stops)
                    'departure_stop': {'name': 'Peenya'},
                    'arrival_stop': {'name': 'Majestic'},
                  },
                  'polyline': {'points': partialPoly},
                },
              ],
            },
          ],
        },
      ],
    };

    final logFile = java.File('test_output.log');
    if (logFile.existsSync()) logFile.deleteSync();

    void log(String msg) {
      logFile.writeAsStringSync('$msg\n', mode: java.FileMode.append);
      dev.log(msg, name: 'CompareRoutes');
    }

    log('\n--- Analying Route 1 (Nagasandra) ---');
    final legs1 = TransferUtils.extractTransitLegStops(route1Directions);
    final enhanced1 = await TransferUtils.enhanceTransitLegStopsWithOsm(
      legs1,
      route1Directions,
    );
    final l1 = enhanced1.first;
    log('Route 1 isActualPositions: ${l1.isActualPositions}');
    log('Route 1 stops found: ${l1.stopNames.length}');
    log('Route 1 stops: ${l1.stopNames}');
    expect(
      l1.isActualPositions,
      isTrue,
      reason: 'Route 1 fell back to interpolation!',
    );

    log('\n--- Analying Route 2 (Peenya) ---');
    final legs2 = TransferUtils.extractTransitLegStops(route2Directions);
    final enhanced2 = await TransferUtils.enhanceTransitLegStopsWithOsm(
      legs2,
      route2Directions,
    );
    final l2 = enhanced2.first;
    log('Route 2 isActualPositions: ${l2.isActualPositions}');
    log('Route 2 stops found: ${l2.stopNames.length}');
    log('Route 2 stops: ${l2.stopNames}');
    expect(
      l2.isActualPositions,
      isTrue,
      reason: 'Route 2 fell back to interpolation!',
    );
  });
}
