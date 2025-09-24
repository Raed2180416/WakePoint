import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';

Position p(double lat, double lng, {double speed = 10.0}) => Position(
  latitude: lat,
  longitude: lng,
  timestamp: DateTime.now(),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: speed,
  speedAccuracy: 0,
);

Map<String, dynamic> syntheticMetroDirections() {
  // Walk 1200m to Station1, then Transit A 5 stops to Station3 (transfer), then Transit B 4 stops to Final.
  // We emulate num_stops and step distances; not using real polylines.
  return {
    'routes': [
      {
        'legs': [
          {
            'steps': [
              {'travel_mode': 'WALKING', 'distance': {'value': 1200}, 'polyline': {'points': '}_se}Ff`miO??'}},
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 5000},
                'polyline': {'points': '}_se}Ff`miO??'},
                'transit_details': {
                  'line': {'short_name': 'A', 'vehicle': {'type': 'SUBWAY'}},
                  'num_stops': 5,
                  'departure_stop': {'location': {'lat': 0.0, 'lng': 0.0}},
                  'arrival_stop': {'name': 'Station3'}
                }
              },
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 4000},
                'polyline': {'points': '}_se}Ff`miO??'},
                'transit_details': {
                  'line': {'short_name': 'B', 'vehicle': {'type': 'SUBWAY'}},
                  'num_stops': 4,
                  'departure_stop': {'location': {'lat': 0.01, 'lng': 0.01}},
                  'arrival_stop': {'name': 'Final'}
                }
              },
            ]
          }
        ]
      }
    ]
  };
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();
  });

  test('Metro: pre-boarding 1km alert then stops-prior transfer alert', () async {
    final svc = TrackingService();
    final gps = StreamController<Position>();
    testGpsStream = gps.stream;

    // Register metro route with transit mode true via registerRouteFromDirections
    final dir = syntheticMetroDirections();
    svc.registerRouteFromDirections(
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
      alarmValue: 2.0, // two stops prior
    );

    // Approach Station1 within ~900m (should not fire), then ~950m, then 990m then 1000m
    gps.add(p(-0.004, -0.004));
    await Future.delayed(const Duration(milliseconds: 150));
    gps.add(p(-0.003, -0.003));
    await Future.delayed(const Duration(milliseconds: 150));
    gps.add(p(-0.002, -0.002));
    await Future.delayed(const Duration(milliseconds: 200));
    // Near enough to 1km threshold; alarm should trigger once
    gps.add(p(-0.001, -0.001));
    // Wait up to 2s for pre-boarding alarm to be recorded (reduce flakiness)
    {
      final start = DateTime.now();
      while (DateTime.now().difference(start) < const Duration(seconds: 2)) {
        final pre = NotificationService.testRecordedAlarms.where((e) => (e['title'] as String).contains('Approaching metro station')).toList();
        if (pre.isNotEmpty) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }
      final preBoardAlarms = NotificationService.testRecordedAlarms.where((e) => (e['title'] as String).contains('Approaching metro station')).toList();
      expect(preBoardAlarms.isNotEmpty, isTrue, reason: 'Pre-boarding alert should fire around 1km');
    }

    // Now simulate being on the metro (positions around the transit line area)
    // Feed a few positions to progress along; our test relies on event alarms recorded via NotificationService
    gps.add(p(0.0, 0.0));
    await Future.delayed(const Duration(milliseconds: 250));
    gps.add(p(0.005, 0.005));
    // Wait up to 2s for transfer alert to be recorded
    {
      final start = DateTime.now();
      while (DateTime.now().difference(start) < const Duration(seconds: 2)) {
        final ta = NotificationService.testRecordedAlarms.where((e) => (e['title'] as String).contains('Upcoming transfer')).toList();
        if (ta.isNotEmpty) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }
      final transferAlarms = NotificationService.testRecordedAlarms.where((e) => (e['title'] as String).contains('Upcoming transfer')).toList();
      expect(transferAlarms.isNotEmpty, isTrue, reason: 'Stops-prior transfer alert should be raised');
    }

    await svc.stopTracking();
    await gps.close();
  }, timeout: const Timeout(Duration(seconds: 20)));
}
