import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/api_client.dart';
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
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrackingService route registration activation', () {
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

    test(
      'registerRoute(activate:true) makes new route active and preserves old route',
      () async {
        final r1 = line(const LatLng(0, -0.01), const LatLng(0, 0.01), 20);
        final r2 = line(const LatLng(-0.01, 0), const LatLng(0.01, 0), 20);

        svc.registerRoute(
          key: 'r1',
          mode: 'driving',
          destinationName: 'A',
          points: r1,
        );

        await svc.startTracking(
          destination: const LatLng(0.01, 0.01),
          destinationName: 'Dest',
          alarmMode: 'distance',
          alarmValue: 5.0,
        );

        // Ensure we have an active state for r1 first.
        final s1Future = svc.activeRouteStateStream.first;
        gps.add(p(0.0, -0.008, speed: 12));
        final s1 = await s1Future;
        expect(s1.activeKey, 'r1');

        final switches = <String>[];
        final swSub = svc.routeSwitchStream.listen(
          (e) => switches.add('${e.fromKey}->${e.toKey}'),
        );

        // Register r2 as an activated reroute.
        svc.registerRoute(
          key: 'r2',
          mode: 'driving',
          destinationName: 'B',
          points: r2,
          activate: true,
        );

        // The implementation forces an immediate ingestPosition, but we also feed a GPS tick
        // to ensure state emission is deterministic.
        final s2Future = svc.activeRouteStateStream.firstWhere(
          (s) => s.activeKey == 'r2',
        );
        gps.add(p(0.002, 0.0, speed: 12));
        final s2 = await s2Future;
        expect(s2.activeKey, 'r2');

        // Old route must remain registered.
        expect(
          svc.registeredRouteKeys.toSet().containsAll({'r1', 'r2'}),
          isTrue,
        );

        // Route switch event should fire (best-effort; depends on having a previous activeKey).
        expect(switches.any((s) => s.contains('r1->r2')), isTrue);

        await swSub.cancel();
      },
    );
  });
}
