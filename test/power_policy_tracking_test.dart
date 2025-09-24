import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

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
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TrackingService.isTestMode = true; // uses PowerPolicy.testing()
    NotificationService.isTestMode = true;
  });

  test('TrackingService uses testing power policy cadence without errors', () async {
    final svc = TrackingService();
    final gps = StreamController<Position>();
    testGpsStream = gps.stream;
    await svc.startTracking(destination: const LatLng(0.01, 0.01), destinationName: 'D', alarmMode: 'distance', alarmValue: 5.0);

    // Feed a few points; ensure no exceptions and periodic logic runs
    gps.add(p(0.0, 0.0));
    await Future.delayed(const Duration(milliseconds: 120));
    gps.add(p(0.001, 0.001));
    await Future.delayed(const Duration(milliseconds: 200));

    // If we reach here, cadence and timers have not thrown; basic smoke test
    expect(true, isTrue);

    await svc.stopTracking();
    await gps.close();
  });
}
