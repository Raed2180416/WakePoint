// test/metro_alarm_reliability_test.dart
// Tests alarm reliability for metro routes with n=1 stop threshold

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
    '60% rule confirmation: only applies to walking legs in transit routes',
    () async {
      // This test confirms the 60% rule is only for walking legs, not metro legs

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();

      // Inject GPS stream for testing
      testGpsStream = gps.stream;

      // Create synthetic transit route with walking + metro
      final directions = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  // Walking leg: 1000m
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 1000},
                    'start_location': {'lat': 0.0, 'lng': 0.0},
                    'end_location': {'lat': 0.005, 'lng': 0.005},
                    'polyline': {'points': 'walking_polyline'},
                  },
                  // Metro leg: 2000m, 3 stops
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 2000},
                    'start_location': {'lat': 0.005, 'lng': 0.005},
                    'end_location': {'lat': 0.01, 'lng': 0.01},
                    'polyline': {'points': 'metro_polyline'},
                    'transit_details': {
                      'line': {
                        'short_name': 'M1',
                        'vehicle': {'type': 'SUBWAY'},
                      },
                      'num_stops': 3,
                      'departure_stop': {
                        'location': {'lat': 0.005, 'lng': 0.005},
                      },
                      'arrival_stop': {'name': 'Destination'},
                    },
                  },
                ],
              },
            ],
          },
        ],
      };

      await svc.registerRouteFromDirections(
        directions: directions,
        origin: const LatLng(0.0, 0.0),
        destination: const LatLng(0.01, 0.01),
        transitMode: true,
        destinationName: 'Destination',
      );

      await svc.startTracking(
        destination: const LatLng(0.01, 0.01),
        destinationName: 'Destination',
        alarmMode: 'stops',
        alarmValue: 2.0,
      );

      // Start at origin - should trigger 60% rule for walking leg
      gps.add(pWithTime(0.0, 0.0));
      await Future.delayed(const Duration(milliseconds: 250));

      // Move to 60% of walking leg (600m) - should trigger pre-boarding alert
      gps.add(pWithTime(0.003, 0.003)); // ~600m into walking leg
      await Future.delayed(const Duration(milliseconds: 250));

      // Check for pre-boarding alert (60% rule for walking)
      final preBoardingAlarms =
          NotificationService.testRecordedAlarms
              .where(
                (alarm) => (alarm['body'] as String).contains(
                  'Approaching metro station',
                ),
              )
              .toList();

      expect(
        preBoardingAlarms.isNotEmpty,
        isTrue,
        reason: '60% rule should trigger pre-boarding alert for walking leg',
      );

      // Clear alarms for next check
      NotificationService.clearTestRecordedAlarms();

      // Now move into metro leg - 60% rule should NOT apply
      gps.add(pWithTime(0.005, 0.005)); // At metro boarding
      await Future.delayed(const Duration(milliseconds: 250));

      // Move to 60% of metro leg - should NOT trigger 60% rule
      // Metro uses stop-based logic, not distance-based 60% rule
      gps.add(pWithTime(0.007, 0.007)); // ~60% into metro leg
      await Future.delayed(const Duration(milliseconds: 250));

      // Should NOT have pre-boarding alert for metro leg
      final metroPreBoardingAlarms =
          NotificationService.testRecordedAlarms
              .where(
                (alarm) => (alarm['body'] as String).contains(
                  'Approaching metro station',
                ),
              )
              .toList();

      expect(
        metroPreBoardingAlarms.isEmpty,
        isTrue,
        reason: '60% rule should NOT apply to metro legs - only walking legs',
      );

      await svc.stopTracking();
      await gps.close();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'Metro alarm reliability: n=1 stop threshold with mock transit route',
    () async {
      // Create mock directions response for a transit route with metro stops
      final directions = {
        'status': 'OK',
        'routes': [
          {
            'overview_polyline': {'points': 'encoded_polyline_here'},
            'legs': [
              {
                'steps': [
                  // Walking leg to metro station
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 500},
                    'start_location': {'lat': 12.9716, 'lng': 77.5946},
                    'end_location': {'lat': 12.975, 'lng': 77.590},
                    'polyline': {'points': 'walking_polyline'},
                  },
                  // Metro leg with 3 stops (boarding + 2 intermediate + destination)
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 3000},
                    'start_location': {'lat': 12.975, 'lng': 77.590},
                    'end_location': {'lat': 13.0012, 'lng': 77.5692},
                    'polyline': {'points': 'metro_polyline'},
                    'transit_details': {
                      'line': {
                        'short_name': 'M1',
                        'vehicle': {'type': 'SUBWAY'},
                      },
                      'num_stops': 3, // Boarding station + 2 stops = 3 total
                      'departure_stop': {
                        'location': {'lat': 12.975, 'lng': 77.590},
                        'name': 'Sumadhura Shikharam Metro Station',
                      },
                      'arrival_stop': {
                        'name': 'Rajajinagar Metro Station',
                        'location': {'lat': 13.0012, 'lng': 77.5692},
                      },
                    },
                  },
                ],
              },
            ],
          },
        ],
      };

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();

      // Inject GPS stream for testing
      testGpsStream = gps.stream;

      // Register the route using directions
      await svc.registerRouteFromDirections(
        directions: directions,
        origin: const LatLng(12.9716, 77.5946), // Sumadhura Shikharam
        destination: const LatLng(13.0012, 77.5692), // Rajajinagar Metro
        transitMode: true,
        destinationName: 'Rajajinagar Metro Station',
      );

      await svc.startTracking(
        destination: const LatLng(13.0012, 77.5692),
        destinationName: 'Rajajinagar Metro Station',
        alarmMode: 'stops',
        alarmValue: 1.0, // n=1: alarm when 1 stop remaining
      );

      // Simulate GPS positions along the route
      // Start from origin
      gps.add(pWithTime(12.9716, 77.5946)); // Sumadhura Shikharam
      await Future.delayed(const Duration(milliseconds: 250));

      // Move to metro boarding
      gps.add(pWithTime(12.975, 77.590)); // At metro station
      await Future.delayed(const Duration(milliseconds: 200));

      // Move along metro route - simulate being 2 stops away
      gps.add(pWithTime(12.985, 77.580)); // Midway (2 stops remaining)
      await Future.delayed(const Duration(milliseconds: 200));

      // Move closer - simulate being 1 stop away (should trigger alarm)
      gps.add(
        pWithTime(12.995, 77.575),
      ); // Close to destination (1 stop remaining)
      await Future.delayed(const Duration(milliseconds: 200));

      // At destination
      gps.add(pWithTime(13.0012, 77.5692)); // Rajajinagar Metro
      await Future.delayed(const Duration(milliseconds: 250));

      // Check if stop-based alarm fired
      final alarms =
          NotificationService.testRecordedAlarms.where((alarm) {
            final body = alarm['body'] as String;
            // Look for alarms that mention stops or approaching destination
            return body.contains('stop') ||
                body.contains('Stop') ||
                body.contains('approaching') ||
                body.contains('Approaching') ||
                body.contains('Wake Up');
          }).toList();

      expect(
        alarms.isNotEmpty,
        isTrue,
        reason:
            'At least one stop-based alarm should have fired for n=1 threshold',
      );

      await svc.stopTracking();
      await gps.close();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
