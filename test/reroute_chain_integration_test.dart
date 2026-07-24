import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/reroute_constraints.dart';
import 'package:geowake2/services/tracking_termination_policy.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Integration tests for the reroute chain:
/// DeviationMonitor → DeviationDetection → ReroutePolicy → RerouteHandler → RerouteConstraints → Termination
///
/// These tests verify the components work together correctly.
void main() {
  group('Reroute Chain Integration', () {
    group('RerouteConstraints', () {
      test('constraints validate new route candidates', () {
        // Simulate: User started with transit mode, stops alarm
        final constraints = RerouteConstraints(
          alarmMode: 'stops',
          alarmValue: 5.0,
          transitMode: true,
        );

        // New route candidate (transit with 8 stops - valid)
        final validRoute = _buildTransitDirections(stops: 8);
        final validResult = constraints.validate(validRoute);
        expect(validResult.isValid, isTrue);

        // New route candidate (only 3 stops - invalid, user needs 5)
        final invalidRoute = _buildTransitDirections(stops: 3);
        final invalidResult = constraints.validate(invalidRoute);
        expect(invalidResult.isValid, isFalse);
      });

      test('driving route rejected when transit is required', () {
        final constraints = RerouteConstraints(
          alarmMode: 'stops',
          alarmValue: 2.0,
          transitMode: true,
        );

        final drivingRoute = _buildDrivingDirections();
        final result = constraints.validate(drivingRoute);

        expect(result.isValid, isFalse);
        expect(result.failureReason, contains('transit'));
      });
    });

    group('TrackingTerminationPolicy states', () {
      test('progressive deviation triggers appropriate termination', () async {
        final policy = TrackingTerminationPolicy();
        final destination = const LatLng(28.6000, 77.2000);
        policy.setDestination(destination);

        // Stage 1: Small deviation (user hasn't moved far from deviation start), moving - should continue
        policy.onDeviationStart(
          position: const LatLng(28.6100, 77.2100),
          at: DateTime.now().subtract(const Duration(minutes: 2)),
        );

        final decision1 = policy.shouldTerminate(
          currentPosition: const LatLng(
            28.6110,
            77.2110,
          ), // ~1km from deviation start
          speedMps: 10.0,
        );
        expect(decision1.shouldTerminate, isFalse);

        // Reset for stage 2
        policy.onReturnToRoute();

        // Stage 2: Start deviation with failed reroutes, and user moves 2.5km+ from start
        policy.onDeviationStart(
          position: const LatLng(28.6100, 77.2100),
          at: DateTime.now().subtract(const Duration(minutes: 12)),
        );
        policy.onRerouteFailed();
        policy.onRerouteFailed();
        policy.onRerouteFailed();

        // User has moved ~2.5km north from deviation start
        final decision2 = policy.shouldTerminate(
          currentPosition: const LatLng(28.6325, 77.2100), // ~2.5km north
          speedMps: 5.0,
        );
        expect(decision2.shouldTerminate, isTrue);
      });

      test('extreme deviation when stopped triggers immediate termination', () {
        final policy = TrackingTerminationPolicy();
        policy.setDestination(const LatLng(28.6000, 77.2000));

        // Start deviation at a position
        policy.onDeviationStart(
          position: const LatLng(28.6100, 77.2100),
          at: DateTime.now().subtract(const Duration(minutes: 3)),
        );

        // User moved 5.5km from deviation start AND stopped
        final decision = policy.shouldTerminate(
          currentPosition: const LatLng(
            28.6600,
            77.2100,
          ), // ~5.5km north from start
          speedMps: 0.3, // Stopped
        );

        expect(decision.shouldTerminate, isTrue);
      });
    });

    group('Full Reroute Decision Flow', () {
      test('simulates complete reroute flow with validation', () async {
        // Setup: User on transit route with stops alarm
        final constraints = RerouteConstraints(
          alarmMode: 'stops',
          alarmValue: 3.0,
          transitMode: true,
        );

        // Simulate: Deviation detected, reroute triggered
        // New route fetched (transit with 10 stops)
        final newRoute = _buildTransitDirections(stops: 10);
        final validation = constraints.validate(newRoute);

        // Route should be valid
        expect(validation.isValid, isTrue);
      });

      test('simulates reroute rejection leading to termination', () async {
        final terminationPolicy = TrackingTerminationPolicy();
        terminationPolicy.setDestination(const LatLng(28.6000, 77.2000));

        final constraints = RerouteConstraints(
          alarmMode: 'stops',
          alarmValue: 5.0,
          transitMode: true,
        );

        int failedAttempts = 0;

        // Simulate multiple reroute attempts that fail validation
        for (int attempt = 0; attempt < 4; attempt++) {
          // Each reroute returns insufficient stops
          final badRoute = _buildTransitDirections(stops: 2);
          final validation = constraints.validate(badRoute);

          if (!validation.isValid) {
            failedAttempts++;
            terminationPolicy.onRerouteFailed();
          }
        }

        // Start deviation tracking from a known position
        terminationPolicy.onDeviationStart(
          position: const LatLng(28.6100, 77.2100),
          at: DateTime.now().subtract(const Duration(minutes: 15)),
        );
        // Re-apply the failed reroute counts
        for (int i = 0; i < failedAttempts; i++) {
          terminationPolicy.onRerouteFailed();
        }

        // User has moved 2.5km from deviation start (triggers moderate deviation rule)
        final decision = terminationPolicy.shouldTerminate(
          currentPosition: const LatLng(28.6325, 77.2100), // ~2.5km north
          speedMps: 5.0,
        );

        expect(failedAttempts, 4);
        expect(decision.shouldTerminate, isTrue);
      });
    });

    group('Time-based Alarm Constraints', () {
      test('validates time alarm against route duration', () {
        // User wants alarm 10 minutes before arrival
        final constraints = RerouteConstraints(
          alarmMode: 'time',
          alarmValue: 10.0, // 10 minutes
          transitMode: false,
        );

        // Route with 30 minute duration - valid (10 < 30)
        final longRoute = _buildDirectionsWithDuration(30 * 60);
        expect(constraints.validate(longRoute).isValid, isTrue);

        // Route with 5 minute duration - invalid (10 > 5)
        final shortRoute = _buildDirectionsWithDuration(5 * 60);
        final result = constraints.validate(shortRoute);
        expect(result.isValid, isFalse);
      });
    });

    group('Distance-based Alarm Constraints', () {
      test('validates distance alarm against route distance', () {
        // User wants alarm 2km before arrival
        final constraints = RerouteConstraints(
          alarmMode: 'distance',
          alarmValue: 2.0, // 2 km
          transitMode: false,
        );

        // Route with 10km distance - valid
        final longRoute = _buildDirectionsWithDistance(10000);
        expect(constraints.validate(longRoute).isValid, isTrue);

        // Route with 1.5km distance - invalid
        final shortRoute = _buildDirectionsWithDistance(1500);
        final result = constraints.validate(shortRoute);
        expect(result.isValid, isFalse);
      });
    });
  });
}

// Helper functions

Map<String, dynamic> _buildTransitDirections({required int stops}) {
  return {
    'routes': [
      {
        'legs': [
          {
            'duration': {'value': 3600},
            'distance': {'value': 15000},
            'steps': [
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 500},
                'duration': {'value': 300},
              },
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 14000},
                'duration': {'value': 3000},
                'transit_details': {
                  'num_stops': stops,
                  'departure_stop': {'name': 'Start'},
                  'arrival_stop': {'name': 'End'},
                  'line': {
                    'vehicle': {'type': 'SUBWAY'},
                    'name': 'Test Line',
                  },
                },
              },
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 500},
                'duration': {'value': 300},
              },
            ],
          },
        ],
      },
    ],
  };
}

Map<String, dynamic> _buildDrivingDirections() {
  return {
    'routes': [
      {
        'legs': [
          {
            'duration': {'value': 1800},
            'distance': {'value': 10000},
            'steps': [
              {
                'travel_mode': 'DRIVING',
                'distance': {'value': 10000},
                'duration': {'value': 1800},
              },
            ],
          },
        ],
      },
    ],
  };
}

Map<String, dynamic> _buildDirectionsWithDuration(int durationSeconds) {
  return {
    'routes': [
      {
        'legs': [
          {
            'duration': {'value': durationSeconds},
            'distance': {'value': 10000},
            'steps': [
              {
                'travel_mode': 'DRIVING',
                'distance': {'value': 10000},
                'duration': {'value': durationSeconds},
              },
            ],
          },
        ],
      },
    ],
  };
}

Map<String, dynamic> _buildDirectionsWithDistance(int distanceMeters) {
  return {
    'routes': [
      {
        'legs': [
          {
            'duration': {'value': 1800},
            'distance': {'value': distanceMeters},
            'steps': [
              {
                'travel_mode': 'DRIVING',
                'distance': {'value': distanceMeters},
                'duration': {'value': 1800},
              },
            ],
          },
        ],
      },
    ],
  };
}
