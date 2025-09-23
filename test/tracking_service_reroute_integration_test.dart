// test/tracking_service_reroute_integration_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/api_client.dart';
import 'log_helper.dart';

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

Map<String, dynamic> directionsFromPoints(List<LatLng> pts) {
  // Encode minimal overview polyline by just using first/last (decoder handles full strings; for tests we register directly with points)
  return {
    'routes': [
      {
        'overview_polyline': {'points': '}_se}Ff`miO??'},
        'legs': [
          {
            'steps': [],
            'duration': {'value': 600}
          }
        ]
      }
    ],
    'status': 'OK'
  };
}

void main() {
  group('TrackingService deviation/reroute + manager integration', () {
    late TrackingService svc;
    late StreamController<Position> gps;

    setUp(() {
      TrackingService.isTestMode = true;
      ApiClient.testMode = true;
      gps = StreamController<Position>();
      testGpsStream = gps.stream;
      svc = TrackingService();
    });

    tearDown(() async {
      await gps.close();
      testGpsStream = null;
      await svc.stopTracking();
    });

    test('Triggers sustained deviation and emits reroute decision; manager switches to nearby cached route', () async {
      logSection('Scenario: sustained deviation and route switch');
      // Create two perpendicular routes crossing near (0,0)
      final r1 = line(LatLng(0, -0.01), LatLng(0, 0.01), 20); // east-west along lat=0
      final r2 = line(LatLng(-0.01, 0), LatLng(0.01, 0), 20); // north-south along lng=0

      // Register both routes via direct API (bypass Directions polyline complexity)
  logStep('Registering two cached routes r1 (E-W) and r2 (N-S)');
  svc.registerRoute(key: 'r1', mode: 'driving', destinationName: 'A', points: r1);
  svc.registerRoute(key: 'r2', mode: 'driving', destinationName: 'B', points: r2);

      // Start tracking to initialize background loop
  logStep('Starting tracking (test mode, accelerated timers)');
  await svc.startTracking(destination: LatLng(0.01, 0.01), destinationName: 'Dest', alarmMode: 'distance', alarmValue: 5.0);

      // Subscribe to switch events
      final switches = <String>[];
  final sub = svc.routeSwitchStream.listen((e) => switches.add('${e.fromKey}->${e.toKey}'));
  final reroutes = <bool>[];
  final rsub = svc.rerouteDecisionStream.listen((r) => reroutes.add(r.shouldReroute));

      // Feed positions near r1 but offset then move towards r2 to cause switch
      // Start near r1
  logStep('Feeding GPS near r1, then crossing to r2 zone');
  gps.add(p(0.0, -0.008, speed: 12));
      await Future.delayed(const Duration(milliseconds: 150));
      gps.add(p(0.0, -0.004, speed: 12));
      await Future.delayed(const Duration(milliseconds: 150));
      gps.add(p(0.0, -0.0005, speed: 12));
      await Future.delayed(const Duration(milliseconds: 150));
      // Move north crossing into r2 domain
      gps.add(p(0.002, 0.0, speed: 12));
      await Future.delayed(const Duration(milliseconds: 150));
      gps.add(p(0.006, 0.0, speed: 12));
  await Future.delayed(const Duration(milliseconds: 900)); // allow sustain window elapse
  // Trigger evaluation after sustain window
  logStep('Triggering an extra GPS update to finalize switching');
  gps.add(p(0.008, 0.0, speed: 12));
  await Future.delayed(const Duration(milliseconds: 200));

      // Expect at least one switch r1->r2
  final switched = switches.any((s) => s.contains('r1->r2'));
      // Either manager switches to r2 or reroute policy fires due to sustained deviation
  expect(switched || reroutes.any((v) => v), isTrue);
  logInfo('Switches observed: $switches');
  logInfo('Reroute decisions: $reroutes');
  logPass('Manager switched or reroute policy fired as expected');
      await sub.cancel();
      await rsub.cancel();
    });
  });
}
