import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/tracking/alarm_controller.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/trackingservice.dart'; // For TestServiceInstance

void main() {
  test(
    'Reproduction: Alarm fires in distance mode (non-metro) when remaining distance < threshold',
    () async {
      final controller = AlarmController();
      final registry = RouteRegistry();
      final service = TestServiceInstance();

      const routeKey = 'test_route';
      final routePoints = [const LatLng(0, 0), const LatLng(0, 0.1)];

      registry.upsert(
        RouteEntry(
          key: routeKey,
          points: routePoints,
          mode: 'driving',
          destinationName: 'Test Dest',
        ),
      );

      final lengthMeters = registry.getByKey(routeKey)!.lengthMeters;

      var alarmFired = false;

      final context = AlarmContext(
        destination: routePoints.last,
        alarmMode: 'distance',
        alarmValue: 1.0,
        trackingSessionActive: true,
        registry: registry,
        activeKey: routeKey,
        progressMeters: lengthMeters - 500.0,
        routeEvents: [],
        stepBoundsMeters: [],
        transitLegs: [],
      );

      await controller.checkAndTriggerAlarm(
        currentPosition: Position(
          latitude: 0,
          longitude: 0,
          timestamp: DateTime.now(),
          accuracy: 0,
          altitude: 0,
          heading: 0,
          speed: 0,
          speedAccuracy: 0,
          altitudeAccuracy: 0,
          headingAccuracy: 0,
        ),
        service: service,
        context: context,
        onAlarmFired: () {
          alarmFired = true;
        },
      );

      expect(
        alarmFired,
        isTrue,
        reason: 'Alarm should fire when 500m remaining and threshold is 1km',
      );
    },
  );

  test(
    'Reproduction: Alarm fires in distance mode (non-metro) via Fallback if registry is empty',
    () async {
      final controller = AlarmController();
      final registry = RouteRegistry();
      final service = TestServiceInstance();

      const dest = LatLng(0.01, 0);

      var alarmFired = false;

      final context = AlarmContext(
        destination: dest,
        alarmMode: 'distance',
        alarmValue: 1.5,
        trackingSessionActive: true,
        registry: registry,
        activeKey: null,
        progressMeters: 0.0,
        routeEvents: [],
        stepBoundsMeters: [],
        transitLegs: [],
      );

      await controller.checkAndTriggerAlarm(
        currentPosition: Position(
          latitude: 0,
          longitude: 0,
          timestamp: DateTime.now(),
          accuracy: 0,
          altitude: 0,
          heading: 0,
          speed: 0,
          speedAccuracy: 0,
          altitudeAccuracy: 0,
          headingAccuracy: 0,
        ),
        service: service,
        context: context,
        onAlarmFired: () {
          alarmFired = true;
        },
      );

      expect(
        alarmFired,
        isTrue,
        reason: 'Alarm should fire via straight-line fallback',
      );
    },
  );
}
