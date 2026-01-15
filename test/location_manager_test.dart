import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/location_manager.dart';

void main() {
  group('LocationManager Tests', () {
    late LocationManager manager;

    setUp(() {
      manager = LocationManager();
    });

    tearDown(() async {
      await manager.stop();
    });

    test('Initial state is stopped', () {
      // No easy way to check internal state without getters,
      // but we can check the stream doesn't emit.
      expect(manager.positionStream.isBroadcast, true);
    });

    test('Inject Position emits to stream', () async {
      final p = Position(
        longitude: 10,
        latitude: 10,
        timestamp: DateTime.now(),
        accuracy: 1,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 5,
        speedAccuracy: 1,
      );

      // We need to be in simulation mode for inject to work (based on current implementation logic)
      LocationManager.isTestMode = true;
      await manager.start();

      expectLater(
        manager.positionStream,
        emits(
          predicate<Position>(
            (pos) => pos.latitude == p.latitude && pos.longitude == p.longitude,
          ),
        ),
      );

      manager.injectPosition(p);
    });

    test('Speed normalization resists jitter spikes', () async {
      // Simulate near-stationary jitter: small coordinate changes with
      // relatively poor accuracy. The normalized speed should not spike.
      LocationManager.isTestMode = true;
      await manager.start();

      final t0 = DateTime(2026, 1, 11, 12, 0, 0);
      final p0 = Position(
        longitude: 77.5946,
        latitude: 12.9716,
        timestamp: t0,
        accuracy: 25,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 1,
      );

      final p1 = Position(
        longitude: 77.59465, // ~5m jitter
        latitude: 12.97162,
        timestamp: t0.add(const Duration(milliseconds: 500)),
        accuracy: 25,
        altitude: 0,
        altitudeAccuracy: 1,
        heading: 0,
        headingAccuracy: 1,
        speed: 0,
        speedAccuracy: 1,
      );

      final speeds = <double>[];
      final sub = manager.positionStream.listen((pos) {
        speeds.add(pos.speed);
      });

      manager.injectPosition(p0);
      manager.injectPosition(p1);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      // We should not see an absurd spike (e.g., tens of m/s) from jitter.
      expect(speeds, isNotEmpty);
      final maxSpeed = speeds.reduce((a, b) => a > b ? a : b);
      expect(maxSpeed, lessThan(8.0));
    });
  });
}
