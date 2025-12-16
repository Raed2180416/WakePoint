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

Map<String, dynamic> mixedModeDirections() {
  // Step 1: Walk to Station A (0.0, 0.0) -> (0.01, 0.01) (approx 1.5km)
  // We want to test if alarm fires 1km before Station A.
  final step1Poly = encodePolyline([
    const LatLng(0.0, 0.0),
    const LatLng(0.01, 0.01),
  ]);

  // Step 2: Transit A -> B (0.01, 0.01) -> (0.02, 0.02)
  final step2Poly = encodePolyline([
    const LatLng(0.01, 0.01),
    const LatLng(0.02, 0.02),
  ]);

  return {
    'routes': [
      {
        'legs': [
          {
            'steps': [
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 1571}, // ~1.57km (accurate for 0.01 deg)
                'polyline': {'points': step1Poly},
              },
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 1571}, // ~1.57km
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
    'Mixed Mode: Alarm fires 1km (2 stops) before boarding',
    () async {
      final svc = TrackingService();
      final gps = StreamController<Position>();
      testGpsStream = gps.stream;

      final dir = mixedModeDirections();
      svc.registerRouteFromDirections(
        directions: dir,
        origin: const LatLng(0.0, 0.0),
        destination: const LatLng(0.02, 0.02),
        transitMode: true,
        destinationName: 'Station B',
      );

      // Alarm set to 2 stops prior (which should be 1km for walking)
      await svc.startTracking(
        destination: const LatLng(0.02, 0.02),
        destinationName: 'Station B',
        alarmMode: 'stops',
        alarmValue: 2.0,
      );

      // 1. Start at origin
      gps.add(pWithTime(0.0, 0.0));
      await Future.delayed(const Duration(milliseconds: 100));

      // 2. Move to ~940m from origin (0.006, 0.006)
      // Total leg = 1571m.
      // Remaining = 1571 - 940 = 631m.
      // Stops = 631 / 500 = 1.26 stops.
      // Alarm (2.0) should fire.
      gps.add(pWithTime(0.006, 0.006));
      await Future.delayed(const Duration(milliseconds: 500));

      // Check for alarms
      // Note: Trigger reason might be "Board transit" or "Approaching Station" depending on pre-board logic
      // But we fixed pre-board to not overwrite if stops logic fires first.
      final boardingAlarms =
          NotificationService.testRecordedAlarms
              .where(
                (e) =>
                    (e['body'] as String).contains('Board') ||
                    (e['body'] as String).contains('Approaching'),
              )
              .toList();

      print(
        'DEBUG: Recorded Alarms: ${NotificationService.testRecordedAlarms}',
      );

      expect(
        boardingAlarms.isNotEmpty,
        isTrue,
        reason: 'Alarm should fire ~600m (1.2 stops) before boarding Station A',
      );

      await svc.stopTracking();
      await gps.close();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
