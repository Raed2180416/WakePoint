import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/reroute_constraints.dart';

void main() {
  group('RerouteConstraints', () {
    group('validate', () {
      test('returns valid for compatible transit route with stops alarm', () {
        final constraints = RerouteConstraints(
          alarmMode: 'stops',
          alarmValue: 3.0,
          transitMode: true,
        );

        final directions = _buildDirectionsWithTransit(totalStops: 10);
        final result = constraints.validate(directions);

        expect(result.isValid, isTrue);
        expect(result.failureReason, isNull);
      });

      test(
        'returns invalid when transit required but route has no transit',
        () {
          final constraints = RerouteConstraints(
            alarmMode: 'stops',
            alarmValue: 3.0,
            transitMode: true,
          );

          final directions = _buildDrivingDirections();
          final result = constraints.validate(directions);

          expect(result.isValid, isFalse);
          expect(result.failureReason, contains('transit'));
        },
      );

      test('returns invalid when stops alarm exceeds available stops', () {
        final constraints = RerouteConstraints(
          alarmMode: 'stops',
          alarmValue: 15.0,
          transitMode: true,
        );

        final directions = _buildDirectionsWithTransit(totalStops: 10);
        final result = constraints.validate(directions);

        expect(result.isValid, isFalse);
        expect(result.failureReason, contains('stops'));
      });

      test(
        'returns invalid when stops mode but no transit stops available',
        () {
          final constraints = RerouteConstraints(
            alarmMode: 'stops',
            alarmValue: 3.0,
            transitMode: false, // Driving mode
          );

          final directions = _buildDrivingDirections();
          final result = constraints.validate(directions);

          expect(result.isValid, isFalse);
          expect(result.failureReason, contains('stops'));
        },
      );

      test('returns invalid when time alarm exceeds route duration', () {
        final constraints = RerouteConstraints(
          alarmMode: 'time',
          alarmValue: 60.0, // 60 minutes
          transitMode: false,
        );

        final directions = _buildDirectionsWithDuration(
          30 * 60,
        ); // 30 min route
        final result = constraints.validate(directions);

        expect(result.isValid, isFalse);
        expect(result.failureReason?.toLowerCase(), contains('duration'));
      });

      test('returns valid when time alarm is less than route duration', () {
        final constraints = RerouteConstraints(
          alarmMode: 'time',
          alarmValue: 15.0, // 15 minutes before arrival
          transitMode: false,
        );

        final directions = _buildDirectionsWithDuration(
          60 * 60,
        ); // 60 min route
        final result = constraints.validate(directions);

        expect(result.isValid, isTrue);
      });

      test('returns invalid when distance alarm exceeds route distance', () {
        final constraints = RerouteConstraints(
          alarmMode: 'distance',
          alarmValue: 10.0, // 10 km
          transitMode: false,
        );

        final directions = _buildDirectionsWithDistance(5000); // 5 km route
        final result = constraints.validate(directions);

        expect(result.isValid, isFalse);
        expect(result.failureReason?.toLowerCase(), contains('distance'));
      });

      test('returns valid when distance alarm is less than route distance', () {
        final constraints = RerouteConstraints(
          alarmMode: 'distance',
          alarmValue: 2.0, // 2 km before arrival
          transitMode: false,
        );

        final directions = _buildDirectionsWithDistance(10000); // 10 km route
        final result = constraints.validate(directions);

        expect(result.isValid, isTrue);
      });

      test('handles malformed directions gracefully', () {
        final constraints = RerouteConstraints(
          alarmMode: 'time',
          alarmValue: 10.0,
          transitMode: false,
        );

        final directions = <String, dynamic>{'routes': <dynamic>[]};
        final result = constraints.validate(directions);

        expect(result.isValid, isFalse);
      });

      test('validates transfer count when maxTransfers is set', () {
        final constraints = RerouteConstraints(
          alarmMode: 'stops',
          alarmValue: 3.0,
          transitMode: true,
          maxTransfers: 1,
        );

        final directions = _buildDirectionsWithMultipleTransitLegs(
          3,
        ); // 2 transfers
        final result = constraints.validate(directions);

        expect(result.isValid, isFalse);
        expect(result.failureReason?.toLowerCase(), contains('transfer'));
      });
    });

    test('toString returns readable format', () {
      final constraints = RerouteConstraints(
        alarmMode: 'stops',
        alarmValue: 5.0,
        transitMode: true,
      );

      final str = constraints.toString();
      // Just verify it doesn't throw
      expect(str, isNotNull);
    });
  });
}

// Helper functions to build test directions

Map<String, dynamic> _buildDirectionsWithTransit({required int totalStops}) {
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
                'duration': {'value': 600},
              },
              {
                'travel_mode': 'TRANSIT',
                'distance': {'value': 10000},
                'duration': {'value': 2400},
                'transit_details': {
                  'num_stops': totalStops,
                  'departure_stop': {'name': 'Start Station'},
                  'arrival_stop': {'name': 'End Station'},
                  'line': {
                    'vehicle': {'type': 'SUBWAY'},
                    'name': 'Blue Line',
                  },
                },
              },
              {
                'travel_mode': 'WALKING',
                'distance': {'value': 500},
                'duration': {'value': 600},
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

Map<String, dynamic> _buildDirectionsWithMultipleTransitLegs(int transitLegs) {
  final steps = <Map<String, dynamic>>[];

  for (int i = 0; i < transitLegs; i++) {
    // Walk to station
    steps.add({
      'travel_mode': 'WALKING',
      'distance': {'value': 200},
      'duration': {'value': 300},
    });
    // Transit leg
    steps.add({
      'travel_mode': 'TRANSIT',
      'distance': {'value': 5000},
      'duration': {'value': 600},
      'transit_details': {
        'num_stops': 5,
        'departure_stop': {'name': 'Station ${i * 2}'},
        'arrival_stop': {'name': 'Station ${i * 2 + 1}'},
        'line': {
          'vehicle': {'type': 'SUBWAY'},
          'name': 'Line $i',
        },
      },
    });
  }
  // Final walk
  steps.add({
    'travel_mode': 'WALKING',
    'distance': {'value': 200},
    'duration': {'value': 300},
  });

  return {
    'routes': [
      {
        'legs': [
          {
            'duration': {'value': 3600},
            'distance': {'value': 15000},
            'steps': steps,
          },
        ],
      },
    ],
  };
}
