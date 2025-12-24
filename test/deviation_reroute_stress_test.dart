import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/deviation_monitor.dart';
import 'package:geowake2/services/reroute_policy.dart';
import 'package:geowake2/services/direction_service.dart';
import 'package:geowake2/services/api_client.dart';

void main() {
  group('DeviationMonitor', () {
    test('does not emit sustained until duration threshold met', () async {
      final m = DeviationMonitor(
        sustainDuration: const Duration(milliseconds: 200),
      );
      final events = <DeviationState>[];
      final sub = m.stream.listen(events.add);

      // Quick blip of deviation - should NOT be sustained
      m.ingest(offsetMeters: 50.0, speedMps: 5.0);
      await Future.delayed(const Duration(milliseconds: 50));
      m.ingest(offsetMeters: 10.0, speedMps: 5.0); // back on route

      await Future.delayed(const Duration(milliseconds: 100));
      expect(events.where((e) => e.sustained).length, 0);

      await sub.cancel();
      m.dispose();
    });

    test('emits sustained after duration threshold met', () async {
      final m = DeviationMonitor(
        sustainDuration: const Duration(milliseconds: 100),
      );
      final events = <DeviationState>[];
      final sub = m.stream.listen(events.add);

      // Sustained deviation above threshold
      m.ingest(offsetMeters: 50.0, speedMps: 5.0);
      await Future.delayed(const Duration(milliseconds: 50));
      m.ingest(offsetMeters: 55.0, speedMps: 5.0);
      await Future.delayed(const Duration(milliseconds: 80));
      m.ingest(offsetMeters: 60.0, speedMps: 5.0);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(events.where((e) => e.sustained).length, greaterThan(0));

      await sub.cancel();
      m.dispose();
    });
  });

  group('ReroutePolicy', () {
    test('does not emit shouldReroute when offline', () async {
      final p = ReroutePolicy(
        cooldown: const Duration(milliseconds: 100),
        initialOnline: false,
      );
      final events = <RerouteDecision>[];
      final sub = p.stream.listen(events.add);

      p.onSustainedDeviation(at: DateTime.now());
      await Future.delayed(const Duration(milliseconds: 50));

      expect(events.where((e) => e.shouldReroute).length, 0);

      await sub.cancel();
      p.dispose();
    });

    test('respects cooldown between reroutes', () async {
      final p = ReroutePolicy(
        cooldown: const Duration(milliseconds: 200),
        initialOnline: true,
      );
      final events = <RerouteDecision>[];
      final sub = p.stream.listen(events.add);

      final t0 = DateTime.now();
      p.onSustainedDeviation(at: t0);
      await Future.delayed(const Duration(milliseconds: 20));

      // First should trigger
      final first = events.where((e) => e.shouldReroute).length;
      expect(first, 1);

      // Second within cooldown should NOT trigger
      p.onSustainedDeviation(at: t0.add(const Duration(milliseconds: 50)));
      await Future.delayed(const Duration(milliseconds: 20));
      expect(events.where((e) => e.shouldReroute).length, 1);

      // After cooldown should trigger again
      p.onSustainedDeviation(at: t0.add(const Duration(milliseconds: 250)));
      await Future.delayed(const Duration(milliseconds: 20));
      expect(events.where((e) => e.shouldReroute).length, 2);

      await sub.cancel();
      p.dispose();
    });
  });

  group('DirectionService (cache correctness)', () {
    test(
      'does not reuse in-memory cache across different origin/destination',
      () async {
        ApiClient.testMode = true;
        ApiClient.directionsCallCount = 0;

        final s = DirectionService();

        // Seed cache with a forced fetch
        await s.getDirections(
          37.0,
          -122.0,
          37.1,
          -122.1,
          isDistanceMode: true,
          threshold: 1,
          transitMode: false,
          forceRefresh: true,
        );
        expect(ApiClient.directionsCallCount, 1);

        // Different origin - should NOT reuse cache
        await s.getDirections(
          38.0,
          -123.0,
          38.1,
          -123.1,
          isDistanceMode: true,
          threshold: 1,
          transitMode: false,
          forceRefresh: false,
        );
        expect(ApiClient.directionsCallCount, 2);

        // Same request again within interval - should reuse cache
        await s.getDirections(
          38.0,
          -123.0,
          38.1,
          -123.1,
          isDistanceMode: true,
          threshold: 1,
          transitMode: false,
          forceRefresh: false,
        );
        expect(ApiClient.directionsCallCount, 2);

        ApiClient.testMode = false;
      },
    );
  });
}
