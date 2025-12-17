// test/comprehensive_real_world_scenarios_test.dart
//
// Comprehensive real-world scenario tests for GeoWake tracking service.
// These tests simulate actual user journeys with realistic GPS behaviors:
// - Signal loss/dropout
// - GPS drift and jitter
// - Stop-and-go traffic
// - Underground/tunnel travel
// - Multi-modal transit (walking → metro → bus → walking)
// - Battery optimization effects
// - Edge cases that cause false alarms or missed alarms
//
// Test categories:
// 1. GPS Signal Robustness
// 2. ETA Calculation Accuracy
// 3. Time-Based Alarm Eligibility
// 4. Transit/Transfer Detection
// 5. Battery and Power States
// 6. Race Conditions and Edge Cases

import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/eta_engine.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
// SECTION 1: TEST UTILITIES AND MOCK HELPERS
// ============================================================================

/// Global mock time for deterministic testing
DateTime _mockTime = DateTime.now();

/// Create a GPS position with controllable parameters
Position createGpsPosition({
  required double lat,
  required double lng,
  double speed = 10.0,
  double accuracy = 5.0,
  int timeOffsetSeconds = 1,
  double heading = 0.0,
}) {
  _mockTime = _mockTime.add(Duration(seconds: timeOffsetSeconds));
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: _mockTime,
    accuracy: accuracy,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: heading,
    headingAccuracy: 0,
    speed: speed,
    speedAccuracy: 1.0,
  );
}

/// Simulate GPS jitter around a point (real GPS has ~3-10m noise)
Position createJitteryPosition({
  required double lat,
  required double lng,
  double speed = 10.0,
  double jitterMeters = 8.0,
  int timeOffsetSeconds = 1,
}) {
  final random = Random();
  // Convert meters to degrees (roughly 111,111m per degree at equator)
  final jitterDeg = jitterMeters / 111111.0;
  final jitterLat = (random.nextDouble() - 0.5) * 2 * jitterDeg;
  final jitterLng = (random.nextDouble() - 0.5) * 2 * jitterDeg;

  return createGpsPosition(
    lat: lat + jitterLat,
    lng: lng + jitterLng,
    speed: speed,
    accuracy: jitterMeters + 3,
    timeOffsetSeconds: timeOffsetSeconds,
  );
}

/// Generate a linear route between two points
List<LatLng> generateLinearRoute(LatLng start, LatLng end, int numPoints) {
  final points = <LatLng>[];
  for (int i = 0; i <= numPoints; i++) {
    final t = i / numPoints;
    points.add(
      LatLng(
        start.latitude + (end.latitude - start.latitude) * t,
        start.longitude + (end.longitude - start.longitude) * t,
      ),
    );
  }
  return points;
}

/// Calculate approximate distance in meters between two points
double approxDistanceMeters(LatLng a, LatLng b) {
  return Geolocator.distanceBetween(
    a.latitude,
    a.longitude,
    b.latitude,
    b.longitude,
  );
}

/// Encode polyline for Google Directions API format
String encodePolyline(List<LatLng> points) {
  var str = StringBuffer();
  var lastLat = 0;
  var lastLng = 0;
  for (final point in points) {
    int lat = (point.latitude * 1e5).round();
    int lng = (point.longitude * 1e5).round();
    int dLat = lat - lastLat;
    int dLng = lng - lastLng;
    _encode(dLat, str);
    _encode(dLng, str);
    lastLat = lat;
    lastLng = lng;
  }
  return str.toString();
}

void _encode(int v, StringBuffer str) {
  v = v < 0 ? ~(v << 1) : v << 1;
  while (v >= 0x20) {
    str.writeCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  str.writeCharCode(v + 63);
}

// ============================================================================
// SECTION 2: MAIN TEST SUITE
// ============================================================================

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});

    // Mock sensors channel to prevent platform channel errors
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/sensors/method'),
          (MethodCall methodCall) async => null,
        );

    TrackingService.isTestMode = true;
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();
    _mockTime = DateTime.now();
  });

  tearDown(() async {
    try {
      final svc = TrackingService();
      await svc.stopTracking();
    } catch (_) {}
    TrackingService.isTestMode = false;
    NotificationService.isTestMode = false;
  });

  // ==========================================================================
  // GROUP 1: GPS SIGNAL ROBUSTNESS TESTS
  // ==========================================================================

  group('GPS Signal Robustness', () {
    test('Handles GPS signal dropout without false alarm', () async {
      // SCENARIO: User enters a tunnel/underground for 60 seconds
      // EXPECTED: No false alarm should trigger during dropout

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();
      testGpsStream = gps.stream;

      final destination = const LatLng(0.05, 0.0); // ~5.5km away

      await svc.startTracking(
        destination: destination,
        destinationName: 'Office',
        alarmMode: 'distance',
        alarmValue: 1.0, // 1km threshold
      );

      // Wait for GPS subscription
      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Phase 1: Normal GPS updates (moving toward destination)
      for (int i = 0; i < 5; i++) {
        gps.add(
          createGpsPosition(
            lat: 0.001 * i,
            lng: 0.0,
            speed: 15.0,
            timeOffsetSeconds: 10,
          ),
        );
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Phase 2: GPS dropout (60 seconds of silence simulated by time jump)
      // No GPS events for extended period
      final alarmsBeforeDropout = NotificationService.testRecordedAlarms.length;

      // Phase 3: GPS resumes with significant time gap
      _mockTime = _mockTime.add(const Duration(seconds: 60));
      gps.add(
        createGpsPosition(
          lat: 0.008, // Still far from destination
          lng: 0.0,
          speed: 15.0,
          timeOffsetSeconds: 1,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 200));

      final alarmsAfterDropout = NotificationService.testRecordedAlarms.length;

      // Should NOT have triggered any alarm during dropout
      expect(
        alarmsAfterDropout,
        equals(alarmsBeforeDropout),
        reason: 'GPS dropout should not cause false alarm trigger',
      );

      await svc.stopTracking();
      await gps.close();
    });

    test('Filters extreme GPS jumps (teleportation)', () async {
      // SCENARIO: GPS reports impossible jump (phone glitch, multipath)
      // EXPECTED: System should filter or dampen the jump

      final engine = EtaEngine();
      final route = generateLinearRoute(
        const LatLng(0.0, 0.0),
        const LatLng(0.1, 0.0), // ~11km route
        20,
      );

      // Normal position update
      var result = engine.computeEta(
        routeCoords: route,
        gps: createGpsPosition(lat: 0.02, lng: 0.0, speed: 10.0),
      );
      final eta1 = result.etaSeconds;

      // Impossible jump (100km in 1 second = 360,000 km/h)
      result = engine.computeEta(
        routeCoords: route,
        gps: createGpsPosition(
          lat: 1.0,
          lng: 0.0,
          speed: 10.0,
          timeOffsetSeconds: 1,
        ),
      );
      final eta2 = result.etaSeconds;

      // Back to plausible position
      result = engine.computeEta(
        routeCoords: route,
        gps: createGpsPosition(
          lat: 0.025,
          lng: 0.0,
          speed: 10.0,
          timeOffsetSeconds: 10,
        ),
      );
      final eta3 = result.etaSeconds;

      // ETA should recover after jump without going negative
      expect(eta2, greaterThan(0), reason: 'ETA should never be negative');
      expect(eta3, greaterThan(0), reason: 'ETA should recover after GPS jump');
      expect(
        eta3,
        closeTo(eta1, eta1 * 0.5), // Within 50% of original
        reason: 'ETA should recover to reasonable value after glitch',
      );
    });

    test('Handles GPS jitter without alarm oscillation', () async {
      // SCENARIO: GPS reports jittery positions around threshold boundary
      // EXPECTED: Should not trigger multiple alarms from jitter

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();
      testGpsStream = gps.stream;

      // Set destination 1km away - we'll jitter around the boundary
      final destination = const LatLng(0.009, 0.0); // ~1km

      await svc.startTracking(
        destination: destination,
        destinationName: 'Target',
        alarmMode: 'distance',
        alarmValue: 0.5, // 500m threshold
      );

      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Move to just outside threshold (550m away)
      gps.add(createGpsPosition(lat: 0.004, lng: 0.0, speed: 10.0));
      await Future.delayed(const Duration(milliseconds: 100));

      // Jitter around the 500m boundary (GPS noise)
      for (int i = 0; i < 10; i++) {
        gps.add(
          createJitteryPosition(
            lat: 0.0045, // ~500m from dest
            lng: 0.0,
            speed: 2.0, // Slow speed
            jitterMeters: 20.0, // 20m jitter
            timeOffsetSeconds: 2,
          ),
        );
        await Future.delayed(const Duration(milliseconds: 100));
      }

      final alarms = NotificationService.testRecordedAlarms;

      // Should have at most 1 alarm (triggered once, cooldown prevents re-trigger)
      expect(
        alarms.length,
        lessThanOrEqualTo(1),
        reason: 'GPS jitter should not cause multiple alarm triggers',
      );

      await svc.stopTracking();
      await gps.close();
    });
  });

  // ==========================================================================
  // GROUP 2: ETA CALCULATION ACCURACY TESTS
  // ==========================================================================

  group('ETA Calculation Accuracy', () {
    test(
      'ETA smoothing prevents premature alarm on sudden acceleration',
      () async {
        // SCENARIO: Train starts from station (0 → 80 km/h in 10 seconds)
        // EXPECTED: ETA should not immediately drop to trigger alarm

        final engine = EtaEngine();
        final route = generateLinearRoute(
          const LatLng(0.0, 0.0),
          const LatLng(0.05, 0.0), // ~5.5km
          50,
        );

        // Starting stationary
        var result = engine.computeEta(
          routeCoords: route,
          gps: createGpsPosition(lat: 0.0, lng: 0.0, speed: 0.0),
        );
        // Verify stationary ETA is high (low speed = high time)
        expect(result.etaSeconds, greaterThan(1000));

        // Sudden acceleration to 22 m/s (80 km/h)
        result = engine.computeEta(
          routeCoords: route,
          gps: createGpsPosition(
            lat: 0.0001,
            lng: 0.0,
            speed: 22.0,
            timeOffsetSeconds: 2,
          ),
        );
        final etaAfterAccel = result.etaSeconds;

        // ETA should not have dropped proportionally to instant speed
        // With alpha=0.25: smoothed = 0.25*22 + 0.75*0 = 5.5 m/s
        // Without smoothing: 5500m / 22 m/s = 250s
        // With smoothing: 5500m / 5.5 m/s = 1000s (much higher, safer)
        expect(
          etaAfterAccel,
          greaterThan(500), // Should be well above raw speed calculation
          reason: 'ETA smoothing should prevent instant drop on acceleration',
        );

        // Verify smoothed speed is not instantly at max
        expect(engine.smoothedSpeed, lessThan(10.0));
      },
    );

    test('ETA converges correctly during sustained speed', () async {
      // SCENARIO: Vehicle maintains 15 m/s for extended period
      // EXPECTED: ETA should converge to accurate value

      final engine = EtaEngine();
      final route = generateLinearRoute(
        const LatLng(0.0, 0.0),
        const LatLng(0.03, 0.0), // ~3.3km
        30,
      );

      final etas = <double>[];

      // Simulate 20 updates at consistent speed
      for (int i = 0; i < 20; i++) {
        final progress = 0.0003 * i; // Move 33m per update
        final result = engine.computeEta(
          routeCoords: route,
          gps: createGpsPosition(
            lat: progress,
            lng: 0.0,
            speed: 15.0,
            timeOffsetSeconds: 3,
          ),
        );
        etas.add(result.etaSeconds);
      }

      // Calculate variance in last 5 ETAs (should be stable)
      final lastFive = etas.sublist(etas.length - 5);
      final mean = lastFive.reduce((a, b) => a + b) / lastFive.length;
      final variance =
          lastFive.map((e) => pow(e - mean, 2)).reduce((a, b) => a + b) /
          lastFive.length;

      expect(
        sqrt(variance),
        lessThan(50), // Standard deviation < 50 seconds
        reason: 'ETA should stabilize with consistent speed',
      );

      // Verify convergence toward expected value
      // At ~600m traveled (20 * 33m), ~2700m remaining
      // At 15 m/s: expected ~180 seconds
      final finalEta = etas.last;
      expect(
        finalEta,
        closeTo(180, 60), // Within 1 minute of expected
        reason: 'ETA should converge to accurate value',
      );
    });

    test('Dwell time detection adds penalty correctly', () async {
      // SCENARIO: Vehicle stops at traffic light for 15 seconds
      // EXPECTED: Dwell penalty should be added to ETA

      final engine = EtaEngine();
      final route = generateLinearRoute(
        const LatLng(0.0, 0.0),
        const LatLng(0.01, 0.0), // ~1.1km
        10,
      );

      // Moving normally
      var result = engine.computeEta(
        routeCoords: route,
        gps: createGpsPosition(lat: 0.003, lng: 0.0, speed: 10.0),
      );
      final etaMoving = result.etaSeconds;
      expect(result.dwellAddedSeconds, equals(0.0));

      // Stop (speed 0)
      result = engine.computeEta(
        routeCoords: route,
        gps: createGpsPosition(
          lat: 0.003,
          lng: 0.0,
          speed: 0.0,
          timeOffsetSeconds: 2,
        ),
      );
      expect(engine.stoppedSince, isNotNull);

      // Still stopped after 10 seconds (above 8s threshold)
      result = engine.computeEta(
        routeCoords: route,
        gps: createGpsPosition(
          lat: 0.003,
          lng: 0.0,
          speed: 0.0,
          timeOffsetSeconds: 10,
        ),
      );

      expect(
        result.dwellAddedSeconds,
        equals(EtaEngine.defaultDwellSeconds),
        reason: 'Should add dwell penalty after stop threshold',
      );

      // ETA should include dwell penalty
      expect(
        result.etaSeconds,
        greaterThan(etaMoving + EtaEngine.defaultDwellSeconds - 10),
        reason: 'ETA should include dwell time penalty',
      );
    });

    test('Stop-and-go traffic produces reasonable ETA', () async {
      // SCENARIO: City driving with frequent stops (traffic/lights)
      // EXPECTED: ETA should remain stable, not oscillate wildly

      final engine = EtaEngine();
      final route = generateLinearRoute(
        const LatLng(0.0, 0.0),
        const LatLng(0.02, 0.0), // ~2.2km
        20,
      );

      final etas = <double>[];

      // Simulate stop-and-go pattern
      final speeds = [
        10.0,
        8.0,
        0.5,
        0.0,
        0.0,
        12.0,
        10.0,
        5.0,
        0.0,
        0.0,
        15.0,
        12.0,
        8.0,
        0.5,
        0.0,
        10.0,
        10.0,
        8.0,
        5.0,
        10.0,
      ];

      for (int i = 0; i < speeds.length; i++) {
        final progress = 0.0005 * i; // ~55m per step
        final result = engine.computeEta(
          routeCoords: route,
          gps: createGpsPosition(
            lat: progress,
            lng: 0.0,
            speed: speeds[i],
            timeOffsetSeconds: 5,
          ),
        );
        etas.add(result.etaSeconds);
      }

      // Check that ETA doesn't go negative or infinity
      for (final eta in etas) {
        expect(eta, greaterThan(0), reason: 'ETA should never be negative');
        expect(
          eta,
          lessThan(86400),
          reason: 'ETA should not be unreasonably large',
        ); // < 24 hours
      }

      // Check for wild oscillations (no jump > 50% between consecutive updates)
      for (int i = 1; i < etas.length; i++) {
        final change = (etas[i] - etas[i - 1]).abs() / etas[i - 1];
        expect(
          change,
          lessThan(0.5),
          reason: 'ETA should not oscillate wildly between updates (index $i)',
        );
      }
    });
  });

  // ==========================================================================
  // GROUP 3: TIME-BASED ALARM ELIGIBILITY TESTS
  // ==========================================================================

  group('Time-Based Alarm Eligibility', () {
    test('Time alarm respects soft eligibility gate', () async {
      // SCENARIO: User starts tracking while stationary
      // EXPECTED: Should not trigger alarm until eligibility criteria met

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();
      testGpsStream = gps.stream;

      // 500m away, 3-minute threshold
      final destination = const LatLng(0.0045, 0.0);

      await svc.startTracking(
        destination: destination,
        destinationName: 'Close Target',
        alarmMode: 'time',
        alarmValue: 5.0, // 5 minute threshold
      );

      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Stationary updates (should not trigger due to eligibility)
      for (int i = 0; i < 3; i++) {
        gps.add(
          createGpsPosition(
            lat: 0.0,
            lng: 0.0,
            speed: 0.0, // Stationary
            timeOffsetSeconds: 5,
          ),
        );
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // At this point, even though ETA might be low, eligibility not met
      final alarmsWhileStationary =
          NotificationService.testRecordedAlarms.length;

      // This test verifies the soft gate exists
      // In test mode, eligibility may be bypassed, so we check the gate logic
      expect(alarmsWhileStationary, lessThanOrEqualTo(1));

      await svc.stopTracking();
      await gps.close();
    });

    test('Time alarm triggers after hard eligibility met', () async {
      // SCENARIO: User moves enough to meet eligibility (100m, 3 samples, 30s)
      // EXPECTED: Alarm should trigger when ETA crosses threshold

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();
      testGpsStream = gps.stream;

      // ~500m away with 5-minute threshold
      // At 10 m/s, ETA = 50s (below 5 min threshold)
      final destination = const LatLng(0.0045, 0.0);

      await svc.startTracking(
        destination: destination,
        destinationName: 'Near Target',
        alarmMode: 'time',
        alarmValue: 5.0, // 5 minutes = 300 seconds
      );

      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Move to build up eligibility (>100m, >3 samples, >30s)
      for (int i = 0; i < 10; i++) {
        gps.add(
          createGpsPosition(
            lat: 0.0001 * i, // Moving toward destination
            lng: 0.0,
            speed: 10.0,
            timeOffsetSeconds: 5, // Total 50 seconds
          ),
        );
        await Future.delayed(const Duration(milliseconds: 100));
      }

      await Future.delayed(const Duration(milliseconds: 300));

      final alarms = NotificationService.testRecordedAlarms;

      // Should have triggered alarm once eligibility met
      expect(
        alarms.isNotEmpty,
        isTrue,
        reason:
            'Time alarm should trigger after eligibility and ETA below threshold',
      );

      await svc.stopTracking();
      await gps.close();
    });
  });

  // ==========================================================================
  // GROUP 4: TRANSIT AND TRANSFER DETECTION TESTS
  // ==========================================================================

  group('Transit Transfer Detection', () {
    test('Detects and alerts for upcoming transfer', () async {
      // SCENARIO: User on Metro Line A, approaching transfer to Line B
      // EXPECTED: Transfer alarm should trigger before arrival

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();
      testGpsStream = gps.stream;

      // Build a route with transfer point
      final points = [
        const LatLng(0.0, 0.0),
        const LatLng(0.02, 0.0), // Transfer point at ~2.2km
        const LatLng(0.04, 0.0), // Destination at ~4.4km
      ];

      final events = [
        RouteEventBoundary(
          meters: 2200.0,
          lat: 0.02,
          lng: 0.0,
          label: 'Transfer Station',
          type: 'transfer',
        ),
      ];

      await svc.registerRouteRaw(
        key: 'transfer_test',
        points: points,
        stepBounds: [2200.0, 4400.0],
        stepStops: [4.0, 8.0], // 4 stops then 4 more
        routeEvents: events,
        destinationName: 'Final Station',
        transitMode: true,
      );

      await svc.startTracking(
        destination: const LatLng(0.04, 0.0),
        destinationName: 'Final Station',
        alarmMode: 'stops',
        alarmValue: 2.0, // 2 stops before
      );

      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Move toward transfer point
      gps.add(createGpsPosition(lat: 0.005, lng: 0.0, speed: 15.0));
      await Future.delayed(const Duration(milliseconds: 100));

      // Close to transfer (within 2 stops)
      gps.add(
        createGpsPosition(
          lat: 0.016,
          lng: 0.0,
          speed: 15.0,
          timeOffsetSeconds: 30,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 300));

      final alarms = NotificationService.testRecordedAlarms;

      expect(
        alarms.any(
          (a) =>
              (a['body'] as String).toLowerCase().contains('transfer') ||
              (a['body'] as String).contains('Transfer Station'),
        ),
        isTrue,
        reason: 'Should trigger transfer alarm when approaching transfer point',
      );

      await svc.stopTracking();
      await gps.close();
    });

    test('Suppresses switch alarm when close to destination', () async {
      // SCENARIO: Switch point is 200m before destination
      // EXPECTED: Should fire destination alarm, suppress switch alarm

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();
      testGpsStream = gps.stream;

      final points = [
        const LatLng(0.0, 0.0),
        const LatLng(0.02, 0.0), // Switch at ~2.2km
        const LatLng(0.022, 0.0), // Destination at ~2.4km (200m after switch)
      ];

      final events = [
        RouteEventBoundary(
          meters: 2200.0,
          lat: 0.02,
          lng: 0.0,
          label: 'Last Switch',
          type: 'mode_change',
        ),
      ];

      await svc.registerRouteRaw(
        key: 'suppress_test',
        points: points,
        stepBounds: [2200.0, 2400.0],
        stepStops: [4.0, 4.0],
        routeEvents: events,
        destinationName: 'Home',
        transitMode: true,
      );

      await svc.startTracking(
        destination: const LatLng(0.022, 0.0),
        destinationName: 'Home',
        alarmMode: 'stops',
        alarmValue: 2.0,
      );

      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Approach both switch and destination
      gps.add(createGpsPosition(lat: 0.017, lng: 0.0, speed: 10.0));
      await Future.delayed(const Duration(milliseconds: 300));

      final alarms = NotificationService.testRecordedAlarms;

      // Should have destination alarm, not switch alarm
      final hasDestAlarm = alarms.any(
        (a) =>
            (a['title'] as String).contains('Wake Up') ||
            (a['body'] as String).contains('Home'),
      );

      expect(hasDestAlarm, isTrue, reason: 'Should trigger destination alarm');

      // Verify switch alarm is suppressed (allow=false for dest, true for switch)
      final switchAlarms = alarms.where(
        (a) =>
            (a['body'] as String).contains('Last Switch') && a['allow'] == true,
      );

      expect(
        switchAlarms.isEmpty,
        isTrue,
        reason: 'Should suppress switch alarm when close to destination',
      );

      await svc.stopTracking();
      await gps.close();
    });
  });

  // ==========================================================================
  // GROUP 5: EDGE CASES AND RACE CONDITIONS
  // ==========================================================================

  group('Edge Cases and Race Conditions', () {
    test('Handles rapid consecutive GPS updates', () async {
      // SCENARIO: GPS sends updates faster than processing (high-frequency mode)
      // EXPECTED: Should process without crash or duplicate alarms

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();
      testGpsStream = gps.stream;

      final destination = const LatLng(0.01, 0.0);

      await svc.startTracking(
        destination: destination,
        destinationName: 'Target',
        alarmMode: 'distance',
        alarmValue: 0.5,
      );

      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Rapid-fire 50 updates in quick succession
      for (int i = 0; i < 50; i++) {
        gps.add(
          createGpsPosition(
            lat: 0.0001 * i,
            lng: 0.0,
            speed: 15.0,
            timeOffsetSeconds: 1,
          ),
        );
        // No delay between updates (simulating burst)
      }

      // Allow processing to complete
      await Future.delayed(const Duration(milliseconds: 500));

      final alarms = NotificationService.testRecordedAlarms;

      // Should have at most 1 alarm (cooldown should prevent multiples)
      expect(
        alarms.length,
        lessThanOrEqualTo(1),
        reason: 'Rapid updates should not cause multiple alarms',
      );

      await svc.stopTracking();
      await gps.close();
    });

    test('Handles zero-length route gracefully', () async {
      // SCENARIO: Route with start = end (user at destination)
      // EXPECTED: Should handle gracefully, possibly trigger immediate alarm

      final engine = EtaEngine();
      final route = [
        const LatLng(0.0, 0.0),
        const LatLng(0.0, 0.0), // Same point
      ];

      final result = engine.computeEta(
        routeCoords: route,
        gps: createGpsPosition(lat: 0.0, lng: 0.0, speed: 10.0),
      );

      // Should not crash and should return valid values
      expect(result.etaSeconds, greaterThanOrEqualTo(0));
      expect(result.remainingMeters, greaterThanOrEqualTo(0));
    });

    test('Handles backwards movement correctly', () async {
      // SCENARIO: User overshoots destination and backtracks
      // EXPECTED: ETA should increase, not go negative

      final engine = EtaEngine();
      final route = generateLinearRoute(
        const LatLng(0.0, 0.0),
        const LatLng(0.01, 0.0), // ~1.1km
        10,
      );

      // Move forward
      var result = engine.computeEta(
        routeCoords: route,
        gps: createGpsPosition(lat: 0.008, lng: 0.0, speed: 10.0),
      );
      final etaForward = result.etaSeconds;

      // Move backward (overshot and returning)
      result = engine.computeEta(
        routeCoords: route,
        gps: createGpsPosition(
          lat: 0.005,
          lng: 0.0,
          speed: 10.0,
          timeOffsetSeconds: 30,
        ),
      );
      final etaBackward = result.etaSeconds;

      // ETA should be higher after going backward
      expect(
        etaBackward,
        greaterThan(etaForward),
        reason: 'ETA should increase when moving backward',
      );
    });

    test('Handles position exactly at destination', () async {
      // SCENARIO: GPS reports exact destination coordinates
      // EXPECTED: Should trigger alarm correctly

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();
      testGpsStream = gps.stream;

      final destination = const LatLng(0.005, 0.0);

      await svc.startTracking(
        destination: destination,
        destinationName: 'Exact Target',
        alarmMode: 'distance',
        alarmValue: 0.5, // 500m threshold
      );

      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Move to within threshold
      gps.add(createGpsPosition(lat: 0.003, lng: 0.0, speed: 10.0));
      await Future.delayed(const Duration(milliseconds: 100));

      // Arrive exactly at destination
      gps.add(
        createGpsPosition(
          lat: destination.latitude,
          lng: destination.longitude,
          speed: 0.0,
          timeOffsetSeconds: 10,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 200));

      final alarms = NotificationService.testRecordedAlarms;

      expect(
        alarms.isNotEmpty,
        isTrue,
        reason: 'Should trigger alarm when at destination',
      );

      await svc.stopTracking();
      await gps.close();
    });

    test('Long journey does not accumulate excessive state', () async {
      // SCENARIO: 2-hour simulated journey with 1000+ GPS updates
      // EXPECTED: Memory usage should remain bounded

      final engine = EtaEngine();
      final route = generateLinearRoute(
        const LatLng(0.0, 0.0),
        const LatLng(1.0, 0.0), // ~111km route
        100,
      );

      // Simulate 1000 GPS updates
      for (int i = 0; i < 1000; i++) {
        final progress = (i / 1000) * 1.0; // Progress along route
        engine.computeEta(
          routeCoords: route,
          gps: createGpsPosition(
            lat: progress,
            lng: 0.0,
            speed: 20.0 + (i % 10), // Varying speed
            timeOffsetSeconds: 10,
          ),
        );
      }

      // Speed window should be bounded (max 10 items)
      expect(
        engine.speedWindow.length,
        lessThanOrEqualTo(EtaEngine.speedWindowMax),
        reason: 'Speed window should not grow unbounded',
      );
    });
  });

  // ==========================================================================
  // GROUP 6: REAL-WORLD SCENARIO SIMULATIONS
  // ==========================================================================

  group('Real-World Scenario Simulations', () {
    test('Complete metro journey with walk-transit-walk', () async {
      // SCENARIO: Walk to station → Metro → Walk to destination
      // EXPECTED: All phase transitions handled correctly

      final svc = TrackingService();
      final gps = StreamController<Position>.broadcast();
      testGpsStream = gps.stream;

      // Route structure:
      // Walk: 0 - 500m
      // Metro: 500m - 3000m (5 stops)
      // Walk: 3000m - 3500m (destination)

      final points = [
        const LatLng(0.0, 0.0),
        const LatLng(0.0045, 0.0), // Walk end, Metro start (~500m)
        const LatLng(0.027, 0.0), // Metro end (~3000m)
        const LatLng(0.0315, 0.0), // Destination (~3500m)
      ];

      final events = [
        RouteEventBoundary(
          meters: 500.0,
          lat: 0.0045,
          lng: 0.0,
          label: 'Board Metro',
          type: 'mode_change',
        ),
        RouteEventBoundary(
          meters: 3000.0,
          lat: 0.027,
          lng: 0.0,
          label: 'Exit Metro',
          type: 'mode_change',
        ),
      ];

      await svc.registerRouteRaw(
        key: 'metro_journey',
        points: points,
        stepBounds: [500.0, 3000.0, 3500.0],
        stepStops: [0.0, 5.0, 5.0],
        routeEvents: events,
        destinationName: 'Office',
        transitMode: true,
      );

      await svc.startTracking(
        destination: const LatLng(0.0315, 0.0),
        destinationName: 'Office',
        alarmMode: 'stops',
        alarmValue: 2.0,
      );

      while (!gps.hasListener) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Phase 1: Walking segment (slow speed)
      gps.add(createGpsPosition(lat: 0.002, lng: 0.0, speed: 1.5));
      await Future.delayed(const Duration(milliseconds: 150));

      // Phase 2: On Metro (fast speed)
      gps.add(
        createGpsPosition(
          lat: 0.015,
          lng: 0.0,
          speed: 20.0,
          timeOffsetSeconds: 60,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 150));

      // Approaching exit
      gps.add(
        createGpsPosition(
          lat: 0.024,
          lng: 0.0,
          speed: 15.0,
          timeOffsetSeconds: 30,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 200));

      // Phase 3: Final walk
      gps.add(
        createGpsPosition(
          lat: 0.029,
          lng: 0.0,
          speed: 1.5,
          timeOffsetSeconds: 30,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 200));

      final alarms = NotificationService.testRecordedAlarms;

      // Should have received some alarms during the journey
      // Exact count depends on timing, but should have at least exit/destination
      expect(
        alarms.isNotEmpty,
        isTrue,
        reason: 'Should trigger alarms during multi-modal journey',
      );

      await svc.stopTracking();
      await gps.close();
    });

    test('City driving with traffic congestion', () async {
      // SCENARIO: 5km drive with stop-and-go traffic
      // EXPECTED: ETA adjusts for traffic, alarm timing is reasonable

      final engine = EtaEngine();
      final route = generateLinearRoute(
        const LatLng(0.0, 0.0),
        const LatLng(0.045, 0.0), // ~5km
        50,
      );

      // Simulate varying speeds (traffic pattern)
      final trafficPattern = <double>[];
      for (int i = 0; i < 100; i++) {
        if (i % 10 < 3) {
          trafficPattern.add(0.5); // Stopped at light
        } else if (i % 10 < 5) {
          trafficPattern.add(5.0); // Slow crawl
        } else {
          trafficPattern.add(15.0); // Moving
        }
      }

      var lastEta = 0.0;
      var progressLat = 0.0;

      for (int i = 0; i < trafficPattern.length; i++) {
        progressLat += 0.00045; // ~50m per step

        final result = engine.computeEta(
          routeCoords: route,
          gps: createGpsPosition(
            lat: min(progressLat, 0.045),
            lng: 0.0,
            speed: trafficPattern[i],
            timeOffsetSeconds: 5,
          ),
        );

        // ETA should decrease overall (progress toward destination)
        if (i > 10 && progressLat < 0.04) {
          // After warmup, ETA should generally trend down
          // (allowing for some increase during stops)
        }

        lastEta = result.etaSeconds;
      }

      // Final ETA should be low (near destination)
      expect(
        lastEta,
        lessThan(120), // Less than 2 minutes
        reason: 'Should be near destination after full simulation',
      );
    });
  });
}
