import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/polyline_simplifier.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Event alarm uses manager progress (transfer within distance threshold)', () async {
    // Arrange test mode and notification hook
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();

    // Build a simple straight route ~2.2km long at equator: lon -0.01 -> +0.01 at lat 0
    final origin = const LatLng(0.0, -0.01);
    final dest = const LatLng(0.0, 0.01);
    final pts = line(origin, dest, 50);
    final compressed = PolylineSimplifier.compressPolyline(pts);

    // Directions with steps totaling ~2km and a transfer after first TRANSIT segment
    // Distances: 200m (walk), 800m (transit L1), 1000m (transit L2) => transfer event at cum=1000m
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
                    'arrival_stop': {'name': 'Xfer Point'}
                  }
                },
                {
                  'travel_mode': 'TRANSIT',
                  'distance': {'value': 1000},
                  'transit_details': {
                    'line': {'short_name': 'L2'}
                  }
                },
              ]
            }
          ]
        }
      ]
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
      alarmMode: 'distance',
      alarmValue: 0.5,
      useInjectedPositions: false,
    );

    // Feed positions progressing along the route to just beyond 500m before the 1000m event
    // Event at 1000m; threshold 500m => should trigger once progress >= 500m.
    // Roughly place at around 600m from start along the straight line.
    // Compute a point ~600m from origin along the line using fraction of total meters.
    final totalMeters = Geolocator.distanceBetween(
      origin.latitude,
      origin.longitude,
      dest.latitude,
      dest.longitude,
    );
    final frac600 = 600.0 / totalMeters;
    final lat600 = origin.latitude + (dest.latitude - origin.latitude) * frac600;
    final lon600 = origin.longitude + (dest.longitude - origin.longitude) * frac600;

    // Emit a couple of updates near origin, then the 600m point
    gps.add(p(origin.latitude, origin.longitude, speed: 12));
    await Future.delayed(const Duration(milliseconds: 120));
    gps.add(p((origin.latitude + dest.latitude) * 0.5, (origin.longitude + dest.longitude) * 0.5, speed: 12));
    await Future.delayed(const Duration(milliseconds: 120));
    gps.add(p(lat600, lon600, speed: 12));

    // Allow alarm evaluation
    await Future.delayed(const Duration(milliseconds: 500));

    // Assert an event alarm (transfer) was fired and recorded
    final alarms = NotificationService.testRecordedAlarms;
    expect(alarms.any((a) => (a['title'] as String).contains('Upcoming')), isTrue,
        reason: 'Expected an upcoming event alarm based on progress threshold');

    // Cleanup
    await svc.stopTracking();
    await gps.close();
    testGpsStream = null;
    NotificationService.isTestMode = false;
    NotificationService.clearTestRecordedAlarms();
  });
}
