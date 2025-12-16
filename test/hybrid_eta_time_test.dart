import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/api_client.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

DateTime _mockTime = DateTime.now();
Position p(double lat, double lng, {double speed = 15.0}) {
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
    ApiClient.testMode = true;
    ApiClient.directionsCallCount = 0;
    _mockTime = DateTime.now();
  });

  tearDown(() async {
    final svc = TrackingService();
    await svc.stopTracking();
  });

  test(
    'Time-mode metro alarms use per-target ETA and throttle API refreshes',
    () async {
      final svc = TrackingService();
      final gps = StreamController<Position>();
      testGpsStream = gps.stream;

      final points = [
        const LatLng(0.0, 0.0),
        const LatLng(0.005, 0.0), // ~555m
        const LatLng(0.01, 0.0), // ~1.1km destination
      ];
      final stepBounds = [560.0, 1120.0];
      final stepStops = [0.0, 6.0];
      final routeEvents = [
        RouteEventBoundary(
          meters: 560.0,
          lat: 0.005,
          lng: 0.0,
          label: 'Switch A',
          type: 'transfer',
        ),
      ];

      await svc.registerRouteRaw(
        key: 'time_mode_test',
        points: points,
        stepBounds: stepBounds,
        stepStops: stepStops,
        routeEvents: routeEvents,
        destinationName: 'Final Stop',
        transitMode: true,
      );

      await svc.startTracking(
        destination: const LatLng(0.01, 0.0),
        destinationName: 'Final Stop',
        alarmMode: 'time',
        alarmValue: 0.4, // 24 seconds
      );

      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 25));
      }

      // Close to Switch A: onboard ETA ~3-4s so alarm should fire
      var nextState = svc.activeRouteStateStream.first;
      gps.add(p(0.00495, 0.0));
      await nextState.timeout(const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 250));

      final firstAlarms = NotificationService.testRecordedAlarms;
      expect(
        firstAlarms.any((a) => (a['body'] as String).contains('Switch A')),
        isTrue,
        reason: 'Should fire time-mode alarm for upcoming switch',
      );
      NotificationService.clearTestRecordedAlarms();

      // Closer to destination: should fire destination alarm; API call count stays throttled
      nextState = svc.activeRouteStateStream.first;
      gps.add(p(0.0095, 0.0));
      await nextState.timeout(const Duration(seconds: 2));
      await Future.delayed(const Duration(milliseconds: 250));

      final secondAlarms = NotificationService.testRecordedAlarms;
      expect(
        secondAlarms.any((a) => (a['body'] as String).contains('Final Stop')),
        isTrue,
        reason: 'Should fire destination alarm after switch alarm in time-mode',
      );

      // API ETA refresh should only have run once because of the 90s throttle
      await Future.delayed(const Duration(milliseconds: 200));
      expect(
        ApiClient.directionsCallCount,
        lessThanOrEqualTo(2),
        reason: 'API ETA refresh should be throttled across position updates',
      );

      await gps.close();
    },
  );
}
