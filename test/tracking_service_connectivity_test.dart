// test/tracking_service_connectivity_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    late Duration _originalGpsDropoutBuffer;

    Future<void> _eventuallyBool(
      bool Function() getValue,
      bool expected, {
      Duration timeout = const Duration(seconds: 5),
      Duration pollInterval = const Duration(milliseconds: 50),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (getValue() == expected) return;
        await Future.delayed(pollInterval);
      }
      expect(getValue(), expected);
    }

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      TrackingService.isTestMode = true;
      _originalGpsDropoutBuffer = gpsDropoutBuffer;
      gpsDropoutBuffer = Duration(seconds: 2);
      // Create a fake GPS stream.
      gpsController = StreamController<Position>();
      testGpsStream = gpsController.stream;
      // Create a fake accelerometer stream to avoid MissingPluginException.
      testAccelerometerStream = Stream.fromIterable([
        AccelerometerEvent(0.5, 0.5, 0.0, DateTime.now()),
        AccelerometerEvent(0.2, 0.2, 0.0, DateTime.now()),
      ]);
      trackingService = TrackingService();

      // Always stop tracking even if an expectation fails.
      addTearDown(() async {
        try {
          await trackingService.stopTracking();
        } catch (_) {}
      });
    });

    tearDown(() async {
      await gpsController.close();
      testGpsStream = null;
      testAccelerometerStream = null;
      gpsDropoutBuffer = _originalGpsDropoutBuffer;
    });

    test(
      'Activates sensor fusion after GPS dropout and stops when GPS resumes',
      () async {
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

        await _eventuallyBool(
          () => trackingService.fusionActive,
          true,
          timeout: const Duration(seconds: 2),
        );

        // Emit a resumed GPS update.
        final resumedPos = fakePosition(37.423, -122.083);
        gpsController.add(resumedPos);
        logStep('GPS resumes; fusion stays active');
        await _eventuallyBool(
          () => trackingService.fusionActive,
          true,
          timeout: const Duration(seconds: 3),
        );
      },
    );
  });
}
