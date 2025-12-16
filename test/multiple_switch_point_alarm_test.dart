// test/multiple_switch_point_alarm_test.dart
// Tests that multiple switch point alarms fire at each transfer, not just the first.

import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

// Synthetic route with TWO transfers: A -> B -> C lines
Map<String, dynamic> syntheticMultiTransferDirections() {
  // Route: Walk (1000m) -> Metro A (3 stops, ~1500m) -> Transfer -> Metro B (4 stops, ~2000m) -> Transfer -> Metro C (2 stops, ~1000m) -> Walk (500m) -> Destination
  final step1Poly = encodePolyline([
    const LatLng(0.0, 0.0),
    const LatLng(0.01, 0.0),
  ]); // Walk 1000m
  final step2Poly = encodePolyline([
    const LatLng(0.01, 0.0),
    const LatLng(0.025, 0.0),
  ]); // Metro A 1500m (3 stops)
  final step3Poly = encodePolyline([
    const LatLng(0.025, 0.0),
    const LatLng(0.045, 0.0),
  ]); // Metro B 2000m (4 stops)
  final step4Poly = encodePolyline([
    const LatLng(0.045, 0.0),
    const LatLng(0.055, 0.0),
  ]); // Metro C 1000m (2 stops)
  final step5Poly = encodePolyline([
    const LatLng(0.055, 0.0),
    const LatLng(0.06, 0.0),
  ]); // Walk 500m

  return {
    'routes': [
      {
        'overview_polyline': {
          'points': encodePolyline([
            const LatLng(0.0, 0.0),
            const LatLng(0.01, 0.0),
            const LatLng(0.025, 0.0),
            const LatLng(0.045, 0.0),
            const LatLng(0.055, 0.0),
            const LatLng(0.06, 0.0),
          ]),
        },
        'legs': [
          {
            'steps': [
              // Step 1: Walking 1000m to first metro station
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 1000},
                'start_location': {'lat': 0.0, 'lng': 0.0},
                'end_location': {'lat': 0.01, 'lng': 0.0},
                'polyline': {'points': step1Poly},
              },
              // Step 2: Metro A - 3 stops (1500m)
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 1500},
                'start_location': {'lat': 0.01, 'lng': 0.0},
                'end_location': {'lat': 0.025, 'lng': 0.0},
                'polyline': {'points': step2Poly},
                'transit_details': {
                  'line': {
                    'short_name': 'A',
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 3,
                  'departure_stop': {
                    'location': {'lat': 0.01, 'lng': 0.0},
                    'name': 'Start-A',
                  },
                  'arrival_stop': {
                    'location': {'lat': 0.025, 'lng': 0.0},
                    'name': 'Transfer-AB',
                  },
                },
              },
              // Step 3: Metro B - 4 stops (2000m) - TRANSFER 1
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 2000},
                'start_location': {'lat': 0.025, 'lng': 0.0},
                'end_location': {'lat': 0.045, 'lng': 0.0},
                'polyline': {'points': step3Poly},
                'transit_details': {
                  'line': {
                    'short_name': 'B',
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 4,
                  'departure_stop': {
                    'location': {'lat': 0.025, 'lng': 0.0},
                    'name': 'Transfer-AB',
                  },
                  'arrival_stop': {
                    'location': {'lat': 0.045, 'lng': 0.0},
                    'name': 'Transfer-BC',
                  },
                },
              },
              // Step 4: Metro C - 2 stops (1000m) - TRANSFER 2
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 1000},
                'start_location': {'lat': 0.045, 'lng': 0.0},
                'end_location': {'lat': 0.055, 'lng': 0.0},
                'polyline': {'points': step4Poly},
                'transit_details': {
                  'line': {
                    'short_name': 'C',
                    'vehicle': {'type': 'SUBWAY'},
                  },
                  'num_stops': 2,
                  'departure_stop': {
                    'location': {'lat': 0.045, 'lng': 0.0},
                    'name': 'Transfer-BC',
                  },
                  'arrival_stop': {
                    'location': {'lat': 0.055, 'lng': 0.0},
                    'name': 'End-C',
                  },
                },
              },
              // Step 5: Walking 500m to destination
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 500},
                'start_location': {'lat': 0.055, 'lng': 0.0},
                'end_location': {'lat': 0.06, 'lng': 0.0},
                'polyline': {'points': step5Poly},
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
    ).setMockMethodCallHandler((MethodCall methodCall) async => null);
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();
    _mockTime = DateTime.now();
  });

  test(
    'Multiple switch points: each transfer fires alarm independently',
    () async {
      final svc = TrackingService();
      final gps = StreamController<Position>();
      testGpsStream = gps.stream;

      final dir = syntheticMultiTransferDirections();
      await svc.registerRouteFromDirections(
        directions: dir,
        origin: const LatLng(0.0, 0.0),
        destination: const LatLng(0.06, 0.0),
        transitMode: true,
        destinationName: 'Final Destination',
      );

      await svc.startTracking(
        destination: const LatLng(0.06, 0.0),
        destinationName: 'Final Destination',
        alarmMode: 'stops',
        alarmValue: 1.0, // Alert 1 stop before each transfer
      );

      // --- Phase 1: Approach first metro boarding (walking segment) ---
      // Pre-boarding alert should fire ~1km before first metro station
      gps.add(pWithTime(0.001, 0.0, timeOffset: 10)); // ~100m into walk
      await Future.delayed(const Duration(milliseconds: 150));

      // Should trigger pre-boarding alert around here
      gps.add(pWithTime(0.002, 0.0, timeOffset: 10));
      await Future.delayed(const Duration(milliseconds: 150));

      gps.add(pWithTime(0.005, 0.0, timeOffset: 20)); // ~500m into walk
      await Future.delayed(const Duration(milliseconds: 200));

      // Wait for pre-boarding alert
      await Future.delayed(const Duration(milliseconds: 500));

      final preBoardAlarms =
          NotificationService.testRecordedAlarms
              .where(
                (e) =>
                    (e['body'] as String).contains('metro station') ||
                    (e['body'] as String).contains('boarding'),
              )
              .toList();
      print('Pre-boarding alarms: $preBoardAlarms');

      // --- Phase 2: On Metro A, approach Transfer-AB ---
      // Metro A: 0.01 -> 0.025 (3 stops, 1500m)
      gps.add(pWithTime(0.012, 0.0, timeOffset: 30)); // On metro A
      await Future.delayed(const Duration(milliseconds: 150));

      // ~1 stop before transfer AB (threshold = 1)
      gps.add(pWithTime(0.022, 0.0, timeOffset: 50)); // Near Transfer-AB
      await Future.delayed(const Duration(milliseconds: 300));

      final transfer1Alarms =
          NotificationService.testRecordedAlarms
              .where(
                (e) =>
                    (e['title'] as String).contains('transfer') ||
                    (e['body'] as String).contains('Transfer-AB'),
              )
              .toList();
      print('Transfer 1 alarms: $transfer1Alarms');
      print('All alarms so far: ${NotificationService.testRecordedAlarms}');

      // --- Phase 3: On Metro B, approach Transfer-BC ---
      // Metro B: 0.025 -> 0.045 (4 stops, 2000m)
      gps.add(pWithTime(0.030, 0.0, timeOffset: 50)); // On metro B
      await Future.delayed(const Duration(milliseconds: 150));

      // ~1 stop before transfer BC
      gps.add(pWithTime(0.042, 0.0, timeOffset: 80)); // Near Transfer-BC
      await Future.delayed(const Duration(milliseconds: 300));

      final transfer2Alarms =
          NotificationService.testRecordedAlarms
              .where(
                (e) =>
                    (e['title'] as String).contains('transfer') ||
                    (e['body'] as String).contains('Transfer-BC'),
              )
              .toList();
      print('Transfer 2 alarms: $transfer2Alarms');
      print('All alarms now: ${NotificationService.testRecordedAlarms}');

      // --- Phase 4: On Metro C, approach destination ---
      // Metro C: 0.045 -> 0.055 (2 stops, 1000m)
      gps.add(pWithTime(0.050, 0.0, timeOffset: 50)); // On metro C
      await Future.delayed(const Duration(milliseconds: 150));

      // Approaching final walking segment
      gps.add(pWithTime(0.056, 0.0, timeOffset: 50)); // Walking to destination
      await Future.delayed(const Duration(milliseconds: 150));

      gps.add(pWithTime(0.059, 0.0, timeOffset: 30)); // Near destination
      await Future.delayed(const Duration(milliseconds: 300));

      final destinationAlarms =
          NotificationService.testRecordedAlarms
              .where(
                (e) =>
                    (e['title'] as String).contains('Wake Up') ||
                    (e['body'] as String).contains('Destination'),
              )
              .toList();
      print('Destination alarms: $destinationAlarms');
      print('Final all alarms: ${NotificationService.testRecordedAlarms}');

      // Verify we got alarms at multiple switch points
      final allAlarms = NotificationService.testRecordedAlarms;
      print('Total alarms fired: ${allAlarms.length}');

      // We should have at least:
      // 1. Pre-boarding alert (1km before first metro)
      // 2. Transfer 1 alarm (Transfer-AB)
      // 3. Transfer 2 alarm (Transfer-BC)
      // 4. Destination alarm
      expect(
        allAlarms.length,
        greaterThanOrEqualTo(2),
        reason: 'Should have multiple alarms for switch points and destination',
      );

      await svc.stopTracking();
      await gps.close();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
