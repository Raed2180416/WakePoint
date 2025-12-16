import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

//##############################################################################
//# SECTION 1: MOCK HELPERS (Our Fake Tools)
//##############################################################################

/// A fake GPS provider that simulates a user moving along a predefined route.
class MockLocationProvider {
  final _controller = StreamController<Position>();
  Stream<Position> get positionStream => _controller.stream;

  /// Simulates the journey by feeding route points into the stream.
  Future<void> playRoute(List<LatLng> route) async {
    for (final point in route) {
      final fakePosition = Position(
        latitude: point.latitude,
        longitude: point.longitude,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: 0.0,
        headingAccuracy: 0.0,
        speed: 15.0, // meters per second (~54 km/h)
        speedAccuracy: 1.0,
      );
      _controller.add(fakePosition);
      // Wait for a tiny moment to allow the service to process the event.
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await _controller.close();
  }

  void dispose() {
    _controller.close();
  }
}

/// Contains predefined routes for testing purposes.
class TestRoutes {
  /// A sample route in Bengaluru from Majestic to Lalbagh.
  static const List<LatLng> majesticToLalbagh = [
    LatLng(12.9600, 77.5855),
    LatLng(12.9588, 77.5858),
    LatLng(12.9578, 77.5860), // within 1km
    LatLng(12.9569, 77.5862),
    LatLng(12.9559, 77.5865),
    LatLng(12.9515, 77.5868), // destination
  ];
}

//##############################################################################
//# SECTION 2: THE MAIN TEST
//##############################################################################

void main() {
  // Use `setUp` to reset state before each test.
  setUp(() {
    NotificationService.clearTestRecordedAlarms(); // Reset recorded alarms
    // This is a special setup for tests to handle native code.
    TestWidgetsFlutterBinding.ensureInitialized();
    // Prepare fake device storage.
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'Alarm should trigger when mock location enters the distance threshold',
    () async {
      // --- SETUP ---

      // 1. Create instances of our test tools.
      final mockLocationProvider = MockLocationProvider();

      // 2. Initialize service in test mode and silence notifications.
      TrackingService.isTestMode = true;
      NotificationService.isTestMode = true;
      final trackingService = TrackingService();

      // --- DEFINE TEST PARAMETERS ---

      final destination = TestRoutes.majesticToLalbagh.last;
      final destinationName = "Lalbagh Botanical Garden";
      final alarmDistanceKm = 1.0; // Trigger alarm 1km before arrival.

      // --- EXECUTION ---

      // 1. Inject our fake GPS stream into the TrackingService before start.
      testGpsStream = mockLocationProvider.positionStream;
      // 2. Start the tracking service with our test parameters.
      // 2. Start the tracking service with our test parameters.
      await trackingService.startTracking(
        destination: destination,
        destinationName: destinationName,
        alarmMode: 'distance',
        alarmValue: alarmDistanceKm,
      );

      // Allow service initialization to complete (async _onStart)
      await Future.delayed(const Duration(milliseconds: 500));

      // 3. "Play" the fake route, which feeds coordinates to the service.
      await mockLocationProvider.playRoute(TestRoutes.majesticToLalbagh);
      await Future.delayed(const Duration(milliseconds: 1000));

      // --- VERIFICATION ---

      // 4. Verify alarm logic via NotificationService hooks
      expect(
        NotificationService.testRecordedAlarms.isNotEmpty,
        isTrue,
        reason: "Alarm should have been recorded",
      );

      // Optional: Verify details of the alarm
      if (NotificationService.testRecordedAlarms.isNotEmpty) {
        final alarm = NotificationService.testRecordedAlarms.last;
        expect(alarm['title'], contains('Wake Up'));
        expect(
          alarm['allow'],
          isFalse,
        ); // Should be false for destination alarm
      }

      // --- CLEANUP ---
      await trackingService.stopTracking();
      mockLocationProvider.dispose();
    },
  );
}
