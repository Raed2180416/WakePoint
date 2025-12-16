import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
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

Map<String, dynamic> syntheticOvershootDirections() {
  // Step 1: Walk to Station A (0.0, 0.0) -> (0.01, 0.01)
  final step1Poly = encodePolyline([
    const LatLng(0.0, 0.0),
    const LatLng(0.01, 0.01),
  ]);
  // Step 2: Transit A -> B (0.01, 0.01) -> (0.02, 0.02)
  // This is the critical leg. We want to simulate arriving at (0.02, 0.02)
  // which is a TRANSFER point.
  final step2Poly = encodePolyline([
    const LatLng(0.01, 0.01),
    const LatLng(0.02, 0.02),
  ]);
  // Step 3: Transit B -> C (0.02, 0.02) -> (0.03, 0.03)
  final step3Poly = encodePolyline([
    const LatLng(0.02, 0.02),
    const LatLng(0.03, 0.03),
  ]);

  return {
    'routes': [
      {
        'legs': [
          {
            'steps': [
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 1500}, // ~1.5km walk
                'polyline': {'points': step1Poly},
              },
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 1500}, // ~1.5km ride
                'polyline': {'points': step2Poly},
                'transit_details': {
                  'line': {
                    'short_name': 'L1',
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 3,
                  'departure_stop': {
                    'location': {'lat': 0.01, 'lng': 0.01},
                    'name': 'Station A',
                  },
                  'arrival_stop': {
                    'name': 'Station B (Transfer)',
                    'location': {'lat': 0.02, 'lng': 0.02},
                  },
                },
              },
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 1500},
                'polyline': {'points': step3Poly},
                'transit_details': {
                  'line': {
                    'short_name': 'L2',
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 3,
                  'departure_stop': {
                    'location': {'lat': 0.02, 'lng': 0.02},
                    'name': 'Station B (Transfer)',
                  },
                  'arrival_stop': {
                    'name': 'Station C (Final)',
                    'location': {'lat': 0.03, 'lng': 0.03},
                  },
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
    'Reproduce Overshoot: Alarm skipped when arriving at switch point',
    () async {
      final svc = TrackingService();
      final gps = StreamController<Position>();
      testGpsStream = gps.stream;

      final dir = syntheticOvershootDirections();
      svc.registerRouteFromDirections(
        directions: dir,
        origin: const LatLng(0.0, 0.0),
        destination: const LatLng(0.03, 0.03),
        transitMode: true,
        destinationName: 'Station C',
      );

      // Alarm set to 1 stop prior
      await svc.startTracking(
        destination: const LatLng(0.03, 0.03),
        destinationName: 'Station C',
        alarmMode: 'stops',
        alarmValue: 1.0,
      );

      // 1. Start at origin
      gps.add(pWithTime(0.0, 0.0));
      await Future.delayed(const Duration(milliseconds: 100));

      // 2. Teleport to Station A (Boarding)
      gps.add(pWithTime(0.01, 0.01));
      await Future.delayed(const Duration(milliseconds: 100));

      // 3. Move towards Station B (Transfer Point)
      // Station B is at (0.02, 0.02).
      // We simulate arriving EXACTLY at Station B.
      // WE MUST USE LOW SPEED TO TRIGGER autoSwitch (< 1.4 m/s)
      gps.add(
        pWithTime(0.02, 0.02, speed: 1.0),
      ); // Slow speed to trigger auto-switch
      await Future.delayed(const Duration(milliseconds: 500));

      // Check for alarms
      final transferAlarms =
          NotificationService.testRecordedAlarms
              .where(
                (e) =>
                    (e['body'] as String).contains('Station B') ||
                    (e['body'] as String).contains('Transfer'),
              )
              .toList();

      print(
        'DEBUG: Recorded Alarms: ${NotificationService.testRecordedAlarms}',
      );

      // EXPECTATION: This SHOULD fail if the bug exists.
      // The alarm should have fired for "Station B (Transfer)".
      expect(
        transferAlarms.isNotEmpty,
        isTrue,
        reason:
            'Alarm should fire for Station B transfer even if we arrive exactly at it',
      );

      await svc.stopTracking();
      await gps.close();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
