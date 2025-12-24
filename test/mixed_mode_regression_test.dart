import 'package:flutter_test/flutter_test.dart';
import 'dart:developer' as dev;
import 'package:geowake2/services/trackingservice.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/services/notification_service.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

// Mock ServiceInstance
import 'package:flutter_background_service/flutter_background_service.dart';

class MockServiceInstance implements ServiceInstance {
  final _controllers = <String, StreamController<Map<String, dynamic>?>>{};
  final List<Map<String, dynamic>> triggeredAlarms = [];

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    if (method == 'triggerAlarm') {
      triggeredAlarms.add(args ?? {});
    }
  }

  @override
  Stream<Map<String, dynamic>?> on(String event) {
    _controllers.putIfAbsent(event, () => StreamController.broadcast());
    return _controllers[event]!.stream;
  }

  @override
  Future<void> stopSelf() async {}
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TrackingService.isTestMode = false;
    NotificationService.isTestMode = false;
    NotificationService.clearTestRecordedAlarms();
    SharedPreferences.setMockInitialValues({});
  });

  test('Mixed Mode Regression Test: Walk -> Metro -> Transfer', () async {
    final service = MockServiceInstance();
    final trackingService = TrackingService();
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();

    // --- SETUP ROUTE ---
    // Leg 1: Walk 1000m (0.0,0.0 -> 0.01,0.0) approx
    // Leg 2: Metro 5 stops (0.01,0.0 -> 0.06,0.0)
    // Switch 0: Boarding at 0.01,0.0 (approx 1100m from start)
    // Switch 1: Transfer at 0.06,0.0

    // 1 deg lat approx 111km. 0.01 deg approx 1.1km.
    final start = LatLng(0.0, 0.0);
    final boarding = LatLng(0.01, 0.0); // ~1113m away
    final transfer = LatLng(0.06, 0.0); // ~5500m further

    final routePoints = [start, boarding, transfer];

    // Segments

    // Step Bounds (Meters)
    // Walk leg: 0 to 1113m
    // Transit leg: 1113m to 6678m
    final stepBounds = [1113.0, 6678.0];

    // Step Stops (Cumulative)
    // Walk leg: 0 stops
    // Transit leg: 5 stops
    final stepStops = [0.0, 5.0];

    // Route Events
    final routeEvents = [
      RouteEventBoundary(
        type: 'boarding',
        meters: 1113.0,
        lat: boarding.latitude,
        lng: boarding.longitude,
        label: 'Metro Station 1',
      ),
      RouteEventBoundary(
        type: 'transfer',
        meters: 6678.0,
        lat: transfer.latitude,
        lng: transfer.longitude,
        label: 'Metro Station 2',
      ),
    ];

    // Register Route
    await trackingService.registerRouteRaw(
      key: 'test_route',
      transitMode: true,
      destinationName: 'Final Dest',
      points: routePoints,
      stepBounds: stepBounds,
      stepStops: stepStops,
      routeEvents: routeEvents,
    );

    // Start Tracking with N=2 stops
    // 2 stops = 1000m for walking.
    await trackingService.startTracking(
      destination: transfer,
      destinationName: 'Final Dest',
      alarmMode: 'stops',
      alarmValue: 2.0,
      routePoints: routePoints,
    );

    // Wait for _onStart to initialize state (async)
    await Future.delayed(const Duration(milliseconds: 500));

    // --- TEST SCENARIO 1: WALKING TO BOARDING ---
    // Target: Boarding (1113m)
    // Alarm Threshold: 2 stops = 1000m.
    // Should fire when distance to boarding <= 1000m.
    // i.e., Progress >= 113m.

    dev.log('--- SIMULATING WALK ---', name: 'MixedModeTest');

    // 1. Start (0m progress). Dist to boarding = 1113m. Stops = 2.22. Should NOT fire.
    await trackingService.testInjectPosition(
      Position(
        latitude: 0.0,
        longitude: 0.0,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        heading: 0,
        speed: 1.4,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      ),
      service,
    );
    expect(
      NotificationService.testRecordedAlarms.isEmpty,
      true,
      reason: "Should not fire at start (2.2 stops away)",
    );

    // 2. Move to 200m progress. Dist to boarding = 913m. Ratio = 0.82. Should NOT fire (Ratio > 0.6).
    // 0.0018 deg lat approx 200m.
    await trackingService.testInjectPosition(
      Position(
        latitude: 0.0018,
        longitude: 0.0,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        heading: 0,
        speed: 1.4,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      ),
      service,
    );

    expect(
      NotificationService.testRecordedAlarms.isEmpty,
      true,
      reason: "Should not fire at 200m (ratio 0.82 > 0.6)",
    );

    // 3. Move to 500m progress. Dist to boarding = 613m. Total = 1113m. Ratio = 0.55. Should FIRE (<= 0.6)!
    // 0.0045 deg lat approx 500m.
    await trackingService.testInjectPosition(
      Position(
        latitude: 0.0045,
        longitude: 0.0,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        heading: 0,
        speed: 1.4,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      ),
      service,
    );

    expect(
      NotificationService.testRecordedAlarms.isNotEmpty,
      true,
      reason: "Should fire when 40% of leg is covered (60% rule)",
    );
    dev.log(
      'Alarms fired: ${NotificationService.testRecordedAlarms}',
      name: 'MixedModeTest',
    );
    NotificationService.clearTestRecordedAlarms(); // Reset

    // --- TEST SCENARIO 2: ON METRO ---
    // Simulate passing boarding point to switch to next leg
    // Move to 1120m (just past boarding).
    await trackingService.testInjectPosition(
      Position(
        latitude: 0.0101,
        longitude: 0.0,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        heading: 0,
        speed: 10.0,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      ),
      service,
    );
    // This might trigger "Just Arrived" or "Transfer" alarm if we didn't clear it, but we cleared triggeredAlarms.
    // We expect NO new alarm for *Transfer* yet, because Transfer is 5 stops away.
    // Boarding alarm might re-fire if logic isn't deduped, but we expect deduping.
    NotificationService.clearTestRecordedAlarms();

    // 3. Move along Metro.
    // Total Transit Dist = 6678 - 1113 = 5565m.
    // 5 stops. 1 stop approx 1113m.
    // Alarm threshold: 2 stops before Transfer.
    // Transfer is at 6678m.
    // Should fire when remaining stops <= 2.
    // i.e., Progress >= 6678 - (2 * 1113) = 4452m.

    // Move to 3000m total progress. Remaining stops ~ 3.3. Should NOT fire.
    // 3000m is approx 0.027 deg.
    await trackingService.testInjectPosition(
      Position(
        latitude: 0.027,
        longitude: 0.0,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        heading: 0,
        speed: 20.0,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      ),
      service,
    );
    expect(
      NotificationService.testRecordedAlarms.isEmpty,
      true,
      reason: "Should not fire when 3.3 stops away",
    );

    // Move to 5000m total progress. Remaining stops ~ 1.5. Should FIRE!
    // 5000m is approx 0.045 deg.
    await trackingService.testInjectPosition(
      Position(
        latitude: 0.045,
        longitude: 0.0,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        heading: 0,
        speed: 20.0,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      ),
      service,
    );
    expect(
      NotificationService.testRecordedAlarms.isNotEmpty,
      true,
      reason: "Should fire when 1.5 stops away from Transfer",
    );
    dev.log(
      'Alarms fired: ${NotificationService.testRecordedAlarms}',
      name: 'MixedModeTest',
    );
  });
}

// Helper to expose private method for testing
extension TrackingServiceTest on TrackingService {
  Future<void> testInjectPosition(Position p, ServiceInstance s) async {
    await checkAlarmForTest(p, s);
  }
}
