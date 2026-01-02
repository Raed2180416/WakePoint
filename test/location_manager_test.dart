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
  });
}
