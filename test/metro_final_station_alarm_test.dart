import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

DateTime _mockTime = DateTime.now();

Position p(double lat, double lng, {double speed = 10.0}) {
  _mockTime = _mockTime.add(const Duration(seconds: 1));
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/sensors/method'),
          (MethodCall methodCall) async => null,
        );

    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();
    _mockTime = DateTime.now();
  });

  tearDown(() async {
    final svc = TrackingService();
    await svc.stopTracking();
    NotificationService.clearTestRecordedAlarms();
  });

  test(
    'Metro stops-mode: stop alarm at final station, then destination alarm on final walk leg',
    () async {
      final svc = TrackingService();
      final service = TestServiceInstance();

      // Geometry: straight line along longitude at equator.
      // 1 deg lon ~= 111km, so:
      // 500m  ~= 0.00450 deg
      // 4500m ~= 0.04054 deg
      // 5500m ~= 0.04955 deg
      const start = LatLng(0.0, 0.0);
      const boarding = LatLng(0.0, 0.00450);
      const finalStation = LatLng(0.0, 0.04054);
      const destination = LatLng(0.0, 0.04955);

      final stepBounds = <double>[500.0, 4500.0, 5500.0];
      // Stops are counted only during the metro segment (500m -> 4500m): 6 stops total.
      final stepStops = <double>[0.0, 6.0, 6.0];

      final routeEvents = <RouteEventBoundary>[
        RouteEventBoundary(
          meters: 4500.0,
          type: 'final_station',
          label: 'Final Station',
          lat: finalStation.latitude,
          lng: finalStation.longitude,
        ),
        // Note: registerRouteRaw appends a 'destination' event at 5500m automatically.
      ];

      await svc.registerRouteRaw(
        key: 'metro_final_station',
        points: const [start, boarding, finalStation, destination],
        stepBounds: stepBounds,
        stepStops: stepStops,
        routeEvents: routeEvents,
        destinationName: 'Dest',
        transitMode: true,
        // Avoid pre-boarding noise in this focused test.
        firstTransitBoarding: const LatLng(10.0, 10.0),
      );

      await svc.startTracking(
        destination: destination,
        destinationName: 'Dest',
        alarmMode: 'stops',
        alarmValue: 2.0,
        useInjectedPositions: true,
      );

      // startTracking() in test-mode kicks off async initialization via _onStart.
      // Give it a moment to apply the alarm config before manual alarm checks.
      await Future.delayed(const Duration(milliseconds: 250));

      // Position far enough that remaining stops >= threshold (no alarm).
      // With threshold=2, alarm fires when stopsRemaining < 2 (i.e., 0 or 1).
      // Metro leg: 500m to 4500m = 4000m with 6 stops
      // Stop positions using formula: prevBound + (legLength * s / numStops)
      // legLength = 4000m, numStops = 6
      // Stop 1: 500 + 667 = 1167m
      // Stop 2: 500 + 1333 = 1833m
      // Stop 3: 500 + 2000 = 2500m
      // Stop 4: 500 + 2667 = 3167m
      // Stop 5: 500 + 3333 = 3833m
      // Stop 6: 500 + 4000 = 4500m
      // At lon 0.015 (~1666m), we're past stop 1 (1167m), before stop 2 (1833m)
      // Stops remaining: 5 (1833, 2500, 3167, 3833, 4500)
      // 5 < 2 = false, so no alarm. Good.
      await svc.checkAlarmForTest(p(0.0, 0.015), service);
      expect(NotificationService.testRecordedAlarms.length, 0);

      // Move forward so remaining stops < 2 (alarm should fire once).
      // Need to be past stop 5 (3833m) so only 1 stop remains (4500m).
      // stopsRemaining = 1, and 1 < 2 is true, so alarm fires.
      // lon 0.035 ~= 3885m (past stop 5 at 3833m)
      await svc.checkAlarmForTest(p(0.0, 0.035), service);

      final alarms = NotificationService.testRecordedAlarms;
      expect(alarms.length, 1);
      expect(
        (alarms.first['title'] as String).contains('Upcoming change'),
        isTrue,
      );
      expect(
        (alarms.first['body'] as String).contains('Final Station'),
        isTrue,
      );

      // Now simulate being on the final walking leg. Destination should fire when
      // 60% of that final leg remains (i.e., after ~40% of it is traversed).
      // Final leg is 1000m (4500 -> 5500), so trigger once progress >= 4900m.
      await svc.checkAlarmForTest(p(0.0, 0.0441), service);

      final alarms2 = NotificationService.testRecordedAlarms;
      expect(alarms2.length, 2);
      expect((alarms2.last['title'] as String).contains('Wake Up'), isTrue);
      expect((alarms2.last['body'] as String).contains('Dest'), isTrue);
    },
  );
}
