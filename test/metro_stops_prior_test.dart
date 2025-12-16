// test/metro_stops_prior_test.dart

import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Helper to create Position with time increment
DateTime _mockTime = DateTime.now();
Position pWithTime(
  double lat,
  double lng, {
  double speed = 10.0,
  int timeOffset = 10,
}) {
  _mockTime = _mockTime.add(Duration(seconds: timeOffset));
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: _mockTime,
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: speed,
    speedAccuracy: 0,
  );
}

Map<String, dynamic> syntheticMetroDirections() {
  final step1Poly = encodePolyline([
    const LatLng(-0.01, -0.01),
    const LatLng(0.0, 0.0),
  ]);
  final step2Poly = encodePolyline([
    const LatLng(0.0, 0.0),
    const LatLng(0.01, 0.01),
  ]);
  final step3Poly = encodePolyline([
    const LatLng(0.01, 0.01),
    const LatLng(0.02, 0.02),
  ]);

  return {
    'routes': [
      {
        'overview_polyline': {
          'points': encodePolyline([
            const LatLng(-0.01, -0.01),
            const LatLng(0.0, 0.0),
            const LatLng(0.01, 0.01),
            const LatLng(0.02, 0.02),
          ]),
        },
        'legs': [
          {
            'steps': [
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 1200},
                'start_location': {'lat': -0.01, 'lng': -0.01},
                'end_location': {'lat': 0.0, 'lng': 0.0},
                'polyline': {'points': step1Poly},
              },
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 1600},
                'start_location': {'lat': 0.0, 'lng': 0.0},
                'end_location': {'lat': 0.01, 'lng': 0.01},
                'polyline': {'points': step2Poly},
                'transit_details': {
                  'line': {
                    'short_name': 'A',
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 5,
                  'departure_stop': {
                    'location': {'lat': 0.0, 'lng': 0.0},
                  },
                  'arrival_stop': {
                    'name': 'Station3',
                    'location': {'lat': 0.01, 'lng': 0.01},
                  },
                },
              },
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 4000},
                'polyline': {'points': step3Poly},
                'transit_details': {
                  'line': {
                    'short_name': 'B',
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 4,
                  'departure_stop': {
                    'location': {'lat': 0.01, 'lng': 0.01},
                  },
                  'arrival_stop': {'name': 'Final'},
                },
              },
            ],
          },
        ],
      },
    ],
  };
}

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
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    const MethodChannel(
      'dev.fluttercommunity.plus/sensors/method',
    ).setMockMethodCallHandler((MethodCall methodCall) async {
      return null;
    });
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();
    _mockTime = DateTime.now();
  });

  test(
    'Metro: pre-boarding 1km alert then stops-prior transfer alert',
    () async {
      final svc = TrackingService();
      final gps = StreamController<Position>();
      testGpsStream = gps.stream;

      final dir = syntheticMetroDirections();
      await svc.registerRouteFromDirections(
        directions: dir,
        origin: const LatLng(-0.01, -0.01),
        destination: const LatLng(0.02, 0.02),
        transitMode: true,
        destinationName: 'Final',
      );

      await svc.startTracking(
        destination: const LatLng(0.02, 0.02),
        destinationName: 'Final',
        alarmMode: 'stops',
        alarmValue: 2.0,
      );

      // Start 700m away from station (0,0) to avoid suppression (radius 200m)
      // (-0.005, -0.005) is approx 780m away.
      gps.add(pWithTime(-0.005, -0.005));
      await Future.delayed(const Duration(milliseconds: 250));

      gps.add(pWithTime(-0.004, -0.004));
      await Future.delayed(const Duration(milliseconds: 150));
      gps.add(pWithTime(-0.003, -0.003));
      await Future.delayed(const Duration(milliseconds: 150));
      gps.add(pWithTime(-0.002, -0.002));
      await Future.delayed(const Duration(milliseconds: 200));
      gps.add(pWithTime(-0.001, -0.001));
      await Future.delayed(const Duration(milliseconds: 250));

      {
        final start = DateTime.now();
        while (DateTime.now().difference(start) < const Duration(seconds: 2)) {
          final pre =
              NotificationService.testRecordedAlarms
                  .where(
                    (e) => (e['body'] as String).contains(
                      'Approaching metro station',
                    ),
                  )
                  .toList();
          if (pre.isNotEmpty) break;
          await Future.delayed(const Duration(milliseconds: 50));
        }

        final preBoardAlarms =
            NotificationService.testRecordedAlarms
                .where(
                  (e) => (e['body'] as String).contains(
                    'Approaching metro station',
                  ),
                )
                .toList();
        expect(
          preBoardAlarms.isNotEmpty,
          isTrue,
          reason: 'Pre-boarding alert should fire around 1km',
        );
      }

      gps.add(pWithTime(0.0, 0.0));
      await Future.delayed(const Duration(milliseconds: 250));
      gps.add(pWithTime(0.007, 0.007));

      // Inject position closer to transfer (within 2 stops)
      // Transfer at 2800m. Step 2 (1200-2800).
      // (0.008, 0.008) is approx 1280m into Step 2. Total 2480m.
      // Remaining dist = 320m. Remaining stops = 1.
      gps.add(pWithTime(0.008, 0.008, timeOffset: 200));
      await Future.delayed(const Duration(milliseconds: 100));

      // Inject final position (at transfer)
      gps.add(pWithTime(0.01, 0.01, timeOffset: 300));
      await Future.delayed(const Duration(milliseconds: 250));

      {
        final start = DateTime.now();
        while (DateTime.now().difference(start) < const Duration(seconds: 2)) {
          final ta =
              NotificationService.testRecordedAlarms
                  .where(
                    (e) =>
                        (e['body'] as String).contains('Upcoming transfer') ||
                        (e['body'] as String).contains('Station3') ||
                        (e['body'] as String).contains('Board transit'),
                  )
                  .toList();
          if (ta.isNotEmpty) break;
          await Future.delayed(const Duration(milliseconds: 50));
        }

        final transferAlarms =
            NotificationService.testRecordedAlarms
                .where(
                  (e) =>
                      (e['body'] as String).contains('Upcoming transfer') ||
                      (e['body'] as String).contains('Station3') ||
                      (e['body'] as String).contains('Board transit'),
                )
                .toList();

        expect(
          transferAlarms.isNotEmpty,
          isTrue,
          reason: 'Stops-prior transfer alert should be raised',
        );
      }

      await svc.stopTracking();
      await gps.close();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
