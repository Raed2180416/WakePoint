import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/polyline_simplifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Helper to build a straight line of LatLng points from A to B
List<LatLng> line(LatLng a, LatLng b, int n) {
  return List.generate(n, (i) {
    final t = i / (n - 1);
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  });
}

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

DateTime _mockTime = DateTime.now();
Position pWithTime(double lat, double lng, {double speed = 10.0}) {
  _mockTime = _mockTime.add(const Duration(seconds: 10));
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
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  const MethodChannel(
    'dev.fluttercommunity.plus/sensors/method',
  ).setMockMethodCallHandler((MethodCall methodCall) async {
    return null;
  });

  test(
    'Event alarm uses manager progress (transfer within distance threshold)',
    () async {
      // Arrange test mode and notification hook
      TrackingService.isTestMode = true;
      NotificationService.isTestMode = true;
      NotificationService.clearTestRecordedAlarms();
      _mockTime = DateTime.now();

      // Build a simple straight route ~2.2km long at equator: lon -0.01 -> +0.01 at lat 0
      final origin = const LatLng(0.0, -0.01);
      final dest = const LatLng(0.0, 0.01);
      final pts = line(origin, dest, 50);
      final compressed = PolylineSimplifier.compressPolyline(pts);

      // Directions with steps totaling ~2km and a transfer after first TRANSIT segment
      // Distances: 200m (walk), 800m (transit L1), 1000m (transit L2) => transfer event at cum=1000m
      // Transfer location set to (0.006, 0.006) to be consistent with route geometry
      final directions = {
        'status': 'OK',
        'routes': [
          {
            'overview_polyline': {'points': 'ignored'},
            'simplified_polyline': compressed,
            'legs': [
              {
                'steps': [
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 200},
                    'transit_details': null,
                  },
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 800},
                    'transit_details': {
                      'line': {'short_name': 'L1'},
                      'arrival_stop': {
                        'name': 'Xfer Point',
                        'location': {'lat': 0.006, 'lng': 0.006},
                      },
                    },
                  },
                  {
                    'travel_mode': 'TRANSIT',
                    'distance': {'value': 1000},
                    'transit_details': {
                      'line': {'short_name': 'L2'},
                    },
                  },
                ],
              },
            ],
          },
        ],
      };

      // GPS stream
      final gps = StreamController<Position>();
      testGpsStream = gps.stream;

      final svc = TrackingService();
      // Register route from directions to wire events and steps
      svc.registerRouteFromDirections(
        directions: directions as Map<String, dynamic>,
        origin: origin,
        destination: dest,
        transitMode: true,
        destinationName: 'Dest',
      );

      // Start tracking with distance alarm 0.5 km (500 m) threshold for events
      await svc.startTracking(
        destination: dest,
        destinationName: 'Dest',
        alarmMode: 'stops',
        alarmValue: 1.0,
        useInjectedPositions: false,
      );

      // Feed positions progressing along the route
      // Origin (-0.01, 0.0)
      gps.add(pWithTime(origin.latitude, origin.longitude, speed: 12));
      await Future.delayed(const Duration(milliseconds: 120));

      // Mid-point
      gps.add(
        pWithTime(
          (origin.latitude + dest.latitude) * 0.5,
          (origin.longitude + dest.longitude) * 0.5,
          speed: 12,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 120));

      // Inject position just before transfer (approx 910m)
      // Transfer is at 1000m (0.006, 0.006).
      // (0.0058, 0.0058) is approx 910m.
      // Distance to transfer ~ 30m. Threshold 500m.
      gps.add(
        Position(
          longitude: 0.0058,
          latitude: 0.0058,
          timestamp: DateTime.now(),
          accuracy: 10,
          altitude: 0,
          heading: 0,
          speed: 10,
          speedAccuracy: 0,
          altitudeAccuracy: 0,
          headingAccuracy: 0,
        ),
      );

      // Allow alarm evaluation
      await Future.delayed(const Duration(milliseconds: 500));

      // Assert an event alarm (transfer) was fired and recorded
      final alarms = NotificationService.testRecordedAlarms;
      print('DEBUG: Recorded alarms in event test: $alarms');
      expect(
        alarms.any(
          (a) =>
              (a['body'] as String).contains('Approaching') ||
              (a['body'] as String).contains('Board'),
        ),
        isTrue,
        reason: 'Expected an upcoming event alarm based on progress threshold',
      );

      // Cleanup
      await svc.stopTracking();
      await gps.close();
      testGpsStream = null;
      NotificationService.isTestMode = false;
      NotificationService.clearTestRecordedAlarms();
    },
  );
}
