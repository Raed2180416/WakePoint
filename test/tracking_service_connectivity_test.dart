// test/tracking_service_connectivity_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'log_helper.dart';

// Helper: Create a fake Position.
Position fakePosition(double lat, double lng, {double speed = 0.0}) {
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: DateTime.now(),
    accuracy: 5.0,
    altitude: 0.0,
    altitudeAccuracy: 0.0,
    heading: 0.0,
    headingAccuracy: 0.0,
    speed: speed,
    speedAccuracy: 0.0,
  );
}

enum AlarmMode { distance, time }

void main() {
  group('TrackingService Connectivity Simulation', () {
    late StreamController<Position> gpsController;
    late TrackingService trackingService;

    setUp(() {
  TrackingService.isTestMode = true;
  gpsDropoutBuffer = Duration(seconds: 2);
  // Create a fake GPS stream.
  gpsController = StreamController<Position>();
  testGpsStream = gpsController.stream;
  // Create a fake accelerometer stream to avoid MissingPluginException.
  testAccelerometerStream = Stream.fromIterable([
    AccelerometerEvent(0.5, 0.5, 0.0, DateTime.now()),
    AccelerometerEvent(0.2, 0.2, 0.0, DateTime.now())
  ]);
  trackingService = TrackingService();
});




    tearDown(() async {
      await gpsController.close();
      testGpsStream = null;
    });

    test('Activates sensor fusion after GPS dropout and stops when GPS resumes', () async {
      logSection('TrackingService: GPS dropout -> sensor fusion');
      // Emit an initial GPS update.
      logStep('Emit initial GPS update');
      final initialPos = fakePosition(37.422, -122.084);
      gpsController.add(initialPos);
      await trackingService.startTracking(
        destination: LatLng(37.422, -122.084),
        destinationName: 'Test Destination',
        alarmMode: AlarmMode.distance.name,
        alarmValue: 100.0,
      );

      // Wait 1 second.
      await Future.delayed(Duration(seconds: 1));
      expect(trackingService.fusionActive, isFalse);

      // Wait to exceed the dropout buffer.
  logStep('Wait past dropout buffer to trigger fusion');
  await Future.delayed(Duration(seconds: 3));
      expect(trackingService.fusionActive, isTrue);

      // Emit a resumed GPS update.
      final resumedPos = fakePosition(37.423, -122.083);
      gpsController.add(resumedPos);
  logStep('GPS resumes; fusion should stop');
  await Future.delayed(Duration(seconds: 1));
      expect(trackingService.fusionActive, isFalse);

      await trackingService.stopTracking();
    });
  });
}
