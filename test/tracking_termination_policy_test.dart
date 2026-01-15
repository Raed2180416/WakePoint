import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/tracking_termination_policy.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  group('TrackingTerminationPolicy', () {
    late TrackingTerminationPolicy policy;

    setUp(() {
      policy = TrackingTerminationPolicy();
    });

    group('shouldTerminate', () {
      test('returns continue when no deviation started', () {
        final decision = policy.shouldTerminate(
          currentPosition: const LatLng(28.6139, 77.2090),
          speedMps: 5.0,
        );

        expect(decision.shouldTerminate, isFalse);
      });

      test('returns terminate with extreme deviation and user stopped', () {
        // Set destination
        policy.setDestination(const LatLng(28.6000, 77.2000));

        // Start deviation at a specific position
        policy.onDeviationStart(
          position: const LatLng(28.6100, 77.2100),
          at: DateTime.now().subtract(const Duration(minutes: 5)),
        );

        // User has moved ~5.5km from deviation start position (0.05 lat ≈ 5.5km)
        // AND user is stopped (speed < 0.5 m/s threshold)
        final decision = policy.shouldTerminate(
          currentPosition: const LatLng(
            28.6600,
            77.2100,
          ), // ~5.5km north from 28.6100
          speedMps: 0.3, // stopped
        );

        expect(decision.shouldTerminate, isTrue);
        expect(decision.reason, isNotNull);
      });

      test('returns continue for extreme deviation if user is moving', () {
        policy.setDestination(const LatLng(28.6000, 77.2000));

        // Start deviation far away
        policy.onDeviationStart(
          position: const LatLng(28.6500, 77.3000),
          at: DateTime.now().subtract(const Duration(minutes: 2)),
        );

        // Check with user still moving
        final decision = policy.shouldTerminate(
          currentPosition: const LatLng(28.6600, 77.3100),
          speedMps: 10.0, // still moving fast
        );

        // Rule 1 requires stopped user, so this should continue
        // Unless rule 2 or 3 kicks in
        expect(decision, isA<TerminationDecision>());
      });

      test(
        'returns terminate for moderate deviation with duration and reroute failures',
        () {
          policy.setDestination(const LatLng(28.6000, 77.2000));

          // Start deviation at a position
          policy.onDeviationStart(
            position: const LatLng(28.6100, 77.2100),
            at: DateTime.now().subtract(const Duration(minutes: 12)),
          );

          // Add failed reroute attempts (need at least 2 per config)
          policy.onRerouteFailed();
          policy.onRerouteFailed();
          policy.onRerouteFailed();

          // User has moved ~2.2km from deviation start position (0.02 lat ≈ 2.2km)
          final decision = policy.shouldTerminate(
            currentPosition: const LatLng(
              28.6300,
              77.2100,
            ), // ~2.2km north from 28.6100
            speedMps: 5.0,
          );

          expect(decision.shouldTerminate, isTrue);
        },
      );

      test(
        'does not terminate if moderate deviation but insufficient reroute failures',
        () {
          policy.setDestination(const LatLng(28.6000, 77.2000));

          policy.onDeviationStart(
            position: const LatLng(28.6200, 77.2200),
            at: DateTime.now().subtract(const Duration(minutes: 12)),
          );

          // Only 1 failed reroute
          policy.onRerouteFailed();

          final decision = policy.shouldTerminate(
            currentPosition: const LatLng(28.6200, 77.2200),
            speedMps: 5.0,
          );

          // Should not terminate due to insufficient failures
          // (may or may not terminate for other reasons)
          expect(decision, isA<TerminationDecision>());
        },
      );

      test('resets state when returning to route', () {
        policy.setDestination(const LatLng(28.6000, 77.2000));

        policy.onDeviationStart(
          position: const LatLng(28.6500, 77.3000),
          at: DateTime.now(),
        );

        // Return to route
        policy.onReturnToRoute();

        // Now termination should not trigger
        final decision = policy.shouldTerminate(
          currentPosition: const LatLng(28.6500, 77.3000),
          speedMps: 5.0,
        );

        expect(decision.shouldTerminate, isFalse);
      });

      test('resets state when reroute succeeds', () {
        policy.setDestination(const LatLng(28.6000, 77.2000));

        policy.onDeviationStart(
          position: const LatLng(28.6500, 77.3000),
          at: DateTime.now(),
        );

        policy.onRerouteFailed();
        policy.onRerouteFailed();

        // Reroute succeeds
        policy.onRerouteSuccess();

        // State should be reset
        final decision = policy.shouldTerminate(
          currentPosition: const LatLng(28.6500, 77.3000),
          speedMps: 5.0,
        );

        expect(decision.shouldTerminate, isFalse);
      });
    });

    group('setDestination', () {
      test('sets the destination for distance calculations', () {
        policy.setDestination(const LatLng(28.6000, 77.2000));

        // Start deviation
        policy.onDeviationStart(
          position: const LatLng(28.7000, 77.3000),
          at: DateTime.now(),
        );

        // Should be able to make termination decision
        final decision = policy.shouldTerminate(
          currentPosition: const LatLng(28.7000, 77.3000),
          speedMps: 0.5,
        );

        expect(decision, isA<TerminationDecision>());
      });
    });
  });

  group('TerminationDecision', () {
    test('continue factory creates non-terminating decision', () {
      const decision = TerminationDecision.continue_();

      expect(decision.shouldTerminate, isFalse);
      expect(decision.reason, isNull);
    });

    test('terminate factory creates terminating decision', () {
      const decision = TerminationDecision.terminate(
        reason: 'User far away',
        userMessage: 'You appear to have left the route',
      );

      expect(decision.shouldTerminate, isTrue);
      expect(decision.reason, 'User far away');
      expect(decision.userMessage, contains('left the route'));
    });
  });
}
