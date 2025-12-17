import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- Section 1: Mocks & Helpers ---

class MockLocationProvider {
  final _controller = StreamController<Position>.broadcast();
  Stream<Position> get positionStream => _controller.stream;

  void emit(double lat, double lng, {double speed = 15.0}) {
    _controller.add(
      Position(
        latitude: lat,
        longitude: lng,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: 0.0,
        headingAccuracy: 0.0,
        speed: speed,
        speedAccuracy: 1.0,
      ),
    );
  }

  void dispose() {
    _controller.close();
  }
}

// Simple linear interpolation to generate points
List<LatLng> generateSegment(LatLng start, LatLng end, int steps) {
  final points = <LatLng>[];
  for (int i = 0; i <= steps; i++) {
    final t = i / steps;
    points.add(
      LatLng(
        start.latitude + (end.latitude - start.latitude) * t,
        start.longitude + (end.longitude - start.longitude) * t,
      ),
    );
  }
  return points;
}

// --- Section 2: Tests ---

void main() {
  setUp(() {
    NotificationService.clearTestRecordedAlarms();
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'Ghost Event Suppression: Events < 300m should NOT trigger alarm',
    () async {
      // 1. Setup
      final provider = MockLocationProvider();
      TrackingService.isTestMode = true;
      NotificationService.isTestMode = true;
      final service = TrackingService();
      testGpsStream = provider.positionStream; // Inject stream

      // 2. Start Service
      await service.startTracking(
        destination: const LatLng(0.1, 0.1), // Far away
        destinationName: "Ghost Town",
        alarmMode: 'stops',
        alarmValue: 2.0,
      );

      // 3. Inject Route with Ghost Event at 100m
      // Route: 0,0 -> 0.001, 0.001 (~150m) -> ...
      // Event at 100m
      final points = generateSegment(
        const LatLng(0, 0),
        const LatLng(0.01, 0.01),
        10,
      );
      final events = [
        RouteEventBoundary(
          meters: 100.0,
          type: 'mode_change',
          label: 'Ghost Stop',
        ),
      ];

      await service.registerRouteRaw(
        key: 'ghost_route',
        points: points,
        stepBounds: [1500.0],
        stepStops: [0.0], // No stop data
        routeEvents: events,
        destinationName: "Ghost Town",
      );

      // 4. Move to 100m (Simulate approach)
      // 0.0009 lat is roughly 100m
      provider.emit(0.0, 0.0); // Start
      await Future.delayed(const Duration(milliseconds: 100));
      provider.emit(0.0009, 0.0009); // At the event
      await Future.delayed(const Duration(milliseconds: 500));

      // 5. Verify NO Alarm
      final alarms = NotificationService.testRecordedAlarms;
      expect(
        alarms.isEmpty,
        isTrue,
        reason: "Alarm fired for ghost event at 100m!",
      );

      await service.stopTracking();
      provider.dispose();
    },
  );

  test('Extended 60% Rule: Intermediate Metro->Driving Leg', () async {
    // Scenario: Leg 1 (Metro) 0-2000m. Switch at 2000m.
    // Alarm should fire when 60% remaining (40% done), i.e., at 800m traveled.

    // 1. Setup
    final provider = MockLocationProvider();
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    final service = TrackingService();
    testGpsStream = provider.positionStream;

    await service.startTracking(
      destination: const LatLng(0.018, 0.018),
      destinationName: "Final Dest",
      alarmMode: 'stops',
      alarmValue: 2.0,
    );

    // WAIT for async background initialization to finish before registering route
    await Future.delayed(const Duration(milliseconds: 1000));

    // 2. Inject Route
    // Leg 1: 0,0 to 0.018, 0.018 (~2000m)
    // Leg 2: 0.018,0.018 to 0.036,0.036 (~4000m)
    final points = [
      ...generateSegment(const LatLng(0, 0), const LatLng(0.018, 0.018), 10),
      ...generateSegment(
        const LatLng(0.018, 0.018),
        const LatLng(0.036, 0.036),
        10,
      ),
    ];

    // Event at 2000m
    final events = [
      RouteEventBoundary(
        meters: 2000.0,
        type: 'mode_change',
        label: 'Switch to Driving',
      ),
    ];

    await service.registerRouteRaw(
      key: 'inter_route',
      points: points,
      stepBounds: [2000.0, 4000.0],
      stepStops: [0.0, 0.0], // Force fallback logic
      routeEvents: events,
      destinationName: "Final Dest",
    );

    // Debug check
    print("Test Debug: Registered route with ${events.length} events");

    // 3. Move to 500m (25% done) -> Expect NO Alarm
    provider.emit(0.0, 0.0); // Start
    await Future.delayed(const Duration(milliseconds: 100));
    provider.emit(0.0045, 0.0045); // ~500m
    await Future.delayed(const Duration(milliseconds: 500));
    expect(
      NotificationService.testRecordedAlarms.isEmpty,
      isTrue,
      reason: "Alarm fired too early at 25%",
    );

    // 4. Move to 1200m (60% done, 40% remaining) -> Expect ALARM
    // Wait, rule is: fire if remainingFraction <= 0.6.
    // At 500m: remaining = 1500m. 1500/2000 = 0.75 (> 0.6). No Alarm.
    // At 1200m: remaining = 800m. 800/2000 = 0.40 (<= 0.6). Alarm!
    provider.emit(0.0108, 0.0108); // ~1200m
    await Future.delayed(const Duration(milliseconds: 500));

    expect(
      NotificationService.testRecordedAlarms.isNotEmpty,
      isTrue,
      reason: "Alarm missed at 60% done",
    );
    final alarm = NotificationService.testRecordedAlarms.last;
    expect(alarm['title'], contains('Upcoming change'));
    expect(alarm['allow'], isTrue);

    await service.stopTracking();
    provider.dispose();
  });

  test('Extended 60% Rule: Destination Alarm', () async {
    // Scenario: Destination at 2000m.

    // 1. Setup
    final provider = MockLocationProvider();
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    final service = TrackingService();
    testGpsStream = provider.positionStream;

    await service.startTracking(
      destination: const LatLng(0.018, 0.018),
      destinationName: "Home",
      alarmMode: 'stops',
      alarmValue: 2.0,
    );

    // WAIT for async initialization
    await Future.delayed(const Duration(milliseconds: 1000));

    // 2. Inject Route
    final points = generateSegment(
      const LatLng(0, 0),
      const LatLng(0.018, 0.018),
      20,
    );
    // Destination Event logic adds destination automatically in registerRouteRaw if missing,
    // but better to be explicit or rely on stepBounds.
    // Let's rely on registerRouteRaw expecting a destination event or adding it.
    // We'll provide it explicitly to control the label.
    final events = [
      RouteEventBoundary(meters: 2000.0, type: 'destination', label: 'Home'),
    ];

    await service.registerRouteRaw(
      key: 'dest_route',
      points: points,
      stepBounds: [2000.0],
      stepStops: [0.0], // No stops data -> triggers fallback
      routeEvents: events,
      destinationName: "Home",
    );

    print("Test Debug: Destination route registered");

    // 3. Move to 1200m (60% done) -> Expect ALARM
    provider.emit(0.0108, 0.0108);
    await Future.delayed(const Duration(milliseconds: 500));

    expect(
      NotificationService.testRecordedAlarms.isNotEmpty,
      isTrue,
      reason: "Final alarm missed at 60% done",
    );
    final alarm = NotificationService.testRecordedAlarms.last;
    expect(alarm['title'], contains('Wake Up'));
    // 4. Verify 'allowContinue' is FALSE for destination
    expect(
      alarm['allow'],
      isFalse,
      reason: "Destination alarm must NOT allow continue tracking",
    );

    await service.stopTracking();
    provider.dispose();
  });

  test('Mixed Mode: Metro -> Driving -> Home', () async {
    // Scenario:
    // Leg 1: Metro (0-2000m). 4 stops.
    // Leg 2: Driving (2000-4000m). 0 stops (cumulative stays 4).
    // Destination at 4000m.
    // User is in "stops" mode with threshold 2.0.
    // Driving leg starts. At 60% remaining distance of the driving leg, alarm should fire.

    // 1. Setup
    final provider = MockLocationProvider();
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    final service = TrackingService();
    testGpsStream = provider.positionStream;

    await service.startTracking(
      destination: const LatLng(0.0254, 0.0254),
      destinationName: "Home",
      alarmMode: 'stops',
      alarmValue: 2.0,
    );

    await Future.delayed(const Duration(milliseconds: 1000));

    // 2. Inject Route
    // 0.0127 deg is approx 1414m along axis -> sqrt(2)*1414 = 2000m diagonal
    final mid = 0.0127;
    final end = 0.0254;

    final points = [
      ...generateSegment(const LatLng(0, 0), LatLng(mid, mid), 10),
      ...generateSegment(LatLng(mid, mid), LatLng(end, end), 10),
    ];

    final events = [
      RouteEventBoundary(
        meters: 2000.0,
        type: 'mode_change', // Switch from Metro to Driving
        label: 'Exit Metro',
      ),
      RouteEventBoundary(meters: 4000.0, type: 'destination', label: 'Home'),
    ];

    await service.registerRouteRaw(
      key: 'mixed_route',
      points: points,
      stepBounds: [2000.0, 4000.0],
      stepStops: [4.0, 4.0], // Stops increase then stay flat for driving
      routeEvents: events,
      destinationName: "Home",
    );

    print("Test Debug: Mixed route registered");

    // 3. Move along Metro Leg (500m) - Expect NO alarm
    // 500m is 1/4 of 2000m.
    // Corresponds to 0.25 * 0.0127 = 0.0031
    provider.emit(0.0031, 0.0031);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(
      NotificationService.testRecordedAlarms.isEmpty,
      isTrue,
      reason: "Alarm fired in Metro leg prematurely",
    );

    // 4. Cross the switch point (2000m) gradually
    // 0.0127 is 2000m.
    // Approach: 0.0120 (1890m) -> 0.0130 (2050m)
    provider.emit(0.0120, 0.0120);
    await Future.delayed(const Duration(milliseconds: 200));
    provider.emit(0.0130, 0.0130);
    await Future.delayed(const Duration(milliseconds: 500));

    // Clear alarms from the switch point crossing
    NotificationService.clearTestRecordedAlarms();

    // 5. Move to Start of Driving Leg (2100m) - Expect NO alarm
    // 2100m is 0.0133
    provider.emit(0.0133, 0.0133);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(
      NotificationService.testRecordedAlarms.isEmpty,
      isTrue,
      reason: "Alarm fired at start of driving leg",
    );

    // 6. Move to 60% remaining of Driving Leg (40% done = 2000 + 800 = 2800m)
    // Use 0.0180 to be safely inside 60% remaining (approx 58-59%)
    provider.emit(0.0180, 0.0180);
    await Future.delayed(const Duration(milliseconds: 1000));

    expect(
      NotificationService.testRecordedAlarms.isNotEmpty,
      isTrue,
      reason: "Alarm missed on final driving leg at 60% remaining",
    );

    final alarm = NotificationService.testRecordedAlarms.last;
    expect(alarm['title'], contains('Wake Up')); // Destination
    expect(alarm['allow'], isFalse);

    await service.stopTracking();
    provider.dispose();
  });

  test('Direct Fire: Destination < 200m', () async {
    // Scenario: Very short final leg (150m).
    // Should fire immediately regardless of 60% rule or other heuristics.

    // 1. Setup
    final provider = MockLocationProvider();
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    final service = TrackingService();
    testGpsStream = provider.positionStream;

    // Start close to 0,0
    await service.startTracking(
      destination: const LatLng(0.00135, 0.00135), // ~200m
      destinationName: "Close Home",
      alarmMode: 'stops',
      alarmValue: 2.0,
    );
    await Future.delayed(const Duration(milliseconds: 1000));

    // 2. Inject Short Route (150m)
    // 0.00135 deg is ~150m away from 0,0
    final points = generateSegment(
      const LatLng(0, 0),
      const LatLng(0.00135, 0.00135),
      5,
    );
    final events = [
      RouteEventBoundary(
        meters: 210.0,
        type: 'destination',
        label: 'Close Home',
      ),
    ];

    await service.registerRouteRaw(
      key: 'short_route',
      points: points,
      stepBounds: [210.0],
      stepStops: [0.0],
      routeEvents: events,
      destinationName: "Close Home",
    );

    // 3. Emit position at start (0m) -> 210m away? No wait.
    // If I want to test < 200m direct fire.
    // Let's say Event is at 150m.

    // Reset inputs for clarity
    // Route: 0-150m.

    // Register again with clearer data
    // Event at 150m.
    final eventsShort = [
      RouteEventBoundary(
        meters: 150.0,
        type: 'destination',
        label: 'Very Close',
      ),
    ];
    await service.registerRouteRaw(
      key: 'real_short_route',
      points: points,
      stepBounds: [150.0],
      stepStops: [0.0],
      routeEvents: eventsShort,
      destinationName: "Very Close",
    );

    // Move to 10m (Distance to dest = 140m < 200m)
    // Should fire!
    provider.emit(0.0001, 0.0001); // Near start
    await Future.delayed(const Duration(milliseconds: 500));

    expect(
      NotificationService.testRecordedAlarms.isNotEmpty,
      isTrue,
      reason: "Direct fire missed for destination < 200m",
    );
    final alarm = NotificationService.testRecordedAlarms.last;
    expect(alarm['title'], contains('Wake Up'));
    expect(alarm['allow'], isFalse);

    await service.stopTracking();
    provider.dispose();
  });

  test('Suppression: Switch Point < 300m from Destination', () async {
    // Scenario: Metro -> Driving. Switch point at 2000m. Destination at 2250m.
    // Distance = 250m. "Exit Metro" alarm should be suppressed.
    // Destination alarm should fire.

    // 1. Setup
    final provider = MockLocationProvider();
    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    // Clear alarms
    NotificationService.clearTestRecordedAlarms();
    final service = TrackingService();
    testGpsStream = provider.positionStream;

    await service.startTracking(
      destination: const LatLng(0.00225, 0.00225), // ~250m past switch
      destinationName: "Home",
      alarmMode: 'stops',
      alarmValue: 2.0,
    );
    await Future.delayed(const Duration(milliseconds: 1000));

    // 2. Inject Route
    // Leg 1: 0-2000m (Metro)
    // Leg 2: 2000-2250m (Driving)
    // Switch Point at 2000m.
    // 2000m ~ 0.0127 deg
    final mid = 0.0127;
    final end = 0.0127 + 0.0016; // 0.0016 * 1.414 * 111km ~  250m

    // Simplified points
    final points = [LatLng(0, 0), LatLng(mid, mid), LatLng(end, end)];

    final events = [
      RouteEventBoundary(
        meters: 2000.0,
        type: 'mode_change', // Switch from Metro to Driving
        label: 'Exit Metro',
      ),
      RouteEventBoundary(meters: 2250.0, type: 'destination', label: 'Home'),
    ];

    await service.registerRouteRaw(
      key: 'suppression_route',
      points: points,
      stepBounds: [2000.0, 2250.0],
      stepStops: [4.0, 4.0],
      routeEvents: events,
      destinationName: "Home",
    );

    // 3. Move to 1950m (Approaching Switch Point)
    // Should NOT fire "Exit Metro" because it's suppressed.
    // 1950 / 2000 * 0.0127 = 0.01238
    provider.emit(0.01238, 0.01238);
    await Future.delayed(const Duration(milliseconds: 1000));

    // Verify "Exit Metro" did NOT fire
    // Note: It might fire "Transfer ahead" if we didn't suppress.
    // Check alarms.
    final exitAlarms =
        NotificationService.testRecordedAlarms
            .where((a) => a['allow'] == true)
            .toList();
    expect(
      exitAlarms.isEmpty,
      isTrue,
      reason: "Switch point alarm should be suppressed (<300m from dest)",
    );

    // 4. Move to 2150m (Approaching Destination)
    // Should fire "Home"
    provider.emit(0.0136, 0.0136); // past 2000
    await Future.delayed(const Duration(milliseconds: 1000));

    final destAlarms =
        NotificationService.testRecordedAlarms
            .where((a) => a['allow'] == false)
            .toList();
    expect(
      destAlarms.isNotEmpty,
      isTrue,
      reason: "Destination alarm should fire",
    );

    await service.stopTracking();
    provider.dispose();
  });
}
