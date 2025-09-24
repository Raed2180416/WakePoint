import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';

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

List<LatLng> line(LatLng a, LatLng b, int n) {
  return List.generate(n, (i) {
    final t = i / (n - 1);
    return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
  });
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TrackingService.isTestMode = true;
  });

  test('Deviation thresholds: <100m ignored, 100–150m switch, >150m reroute possible', () async {
    final svc = TrackingService();
    final gps = StreamController<Position>();
    testGpsStream = gps.stream;

    // Two routes: corridor along lat=0 (r1) and lat=0.001 (~111m north, r2)
    final r1 = line(const LatLng(0, -0.01), const LatLng(0, 0.01), 20);
    final r2 = line(const LatLng(0.001, -0.01), const LatLng(0.001, 0.01), 20);
    svc.registerRoute(key: 'r1', mode: 'driving', destinationName: 'A', points: r1);
    svc.registerRoute(key: 'r2', mode: 'driving', destinationName: 'B', points: r2);

    await svc.startTracking(destination: const LatLng(0.01, 0.01), destinationName: 'D', alarmMode: 'distance', alarmValue: 5.0);

    bool switched = false;
    final sub = svc.routeSwitchStream.listen((_) => switched = true);

    // Near r1 with ~90m offset (simulate). Using LatLng slightly north of r1 but <100m
    gps.add(p(0.0008, -0.008));
    await Future.delayed(const Duration(milliseconds: 400));
    expect(switched, isFalse, reason: 'Below 100m should not switch');

    // Move to ~120m offset region near r2; should prefer local switch, not reroute
    gps.add(p(0.0011, 0.0));
    await Future.delayed(const Duration(milliseconds: 700));
    expect(switched, isTrue, reason: '100–150m should switch locally');

    await sub.cancel();
    await svc.stopTracking();
    await gps.close();
  }, timeout: const Timeout(Duration(seconds: 15)));
}
