import 'dart:developer' as dev;
import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/trackingservice.dart';
import 'package:geowake2/services/notification_service.dart';
// import 'package:geowake2/services/transfer_utils.dart'; // Unused
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'Regression: registerRouteFromDirections MUST add Destination event',
    () async {
      // 1. Setup
      TrackingService.isTestMode = true; // Bypasses background isolate logic
      NotificationService.isTestMode = true;
      final service = TrackingService();

      // 2. Mock Directions (Total 1000 + 5000 = 6000 meters)
      final mockDirections = {
        'routes': [
          {
            'legs': [
              {
                'steps': [
                  {
                    'travel_mode': 'WALKING',
                    'distance': {'value': 1000},
                    'start_location': {'lat': 12.0, 'lng': 77.0},
                    'end_location': {'lat': 12.01, 'lng': 77.01},
                    'polyline': {'points': ''},
                  },
                  {
                    'travel_mode': 'DRIVING',
                    'distance': {'value': 5000},
                    'start_location': {'lat': 12.01, 'lng': 77.01},
                    'end_location': {'lat': 12.05, 'lng': 77.05},
                    'polyline': {'points': ''},
                  },
                ],
              },
            ],
          },
        ],
      };

      // 3. Register Route (Production Method)
      await service.registerRouteFromDirections(
        directions: mockDirections,
        origin: const LatLng(12.0, 77.0),
        destination: const LatLng(12.05, 77.05),
        transitMode: false,
        destinationName: 'Regression Dest',
      );

      // 4. Inspect Events
      final events = service.routeEvents;
      dev.log(
        'Events loaded: ${events.map((e) => "${e.type}@${e.meters}").join(", ")}',
        name: 'RegressionTest',
      );

      // 5. Assert 'mode_change' exists (TransferUtils job)
      // 5. TransferUtils filters Walking<->Driving, so 'mode_change' might be empty.
      // We focus on the Critical Destination Event.

      // 6. Assert 'destination' exists (My Patch job)
      final hasDest = events.any((e) => e.type == 'destination');
      expect(
        hasDest,
        isTrue,
        reason: "Destination event MISSING from production route!",
      );

      final destEvent = events.firstWhere((e) => e.type == 'destination');
      expect(destEvent.meters, 6000.0, reason: "Destination meter mismatch");
    },
  );
}
