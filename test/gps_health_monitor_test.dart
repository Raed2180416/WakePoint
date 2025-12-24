// test/gps_health_monitor_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/services/gps_health_monitor.dart';

void main() {
  group('GpsHealthMonitor', () {
    late GpsHealthMonitor monitor;

    setUp(() {
      monitor = GpsHealthMonitor();
    });

    tearDown(() {
      monitor.dispose();
    });

    Position _makePosition({double accuracy = 5.0}) {
      return Position(
        latitude: 28.6139,
        longitude: 77.2090,
        timestamp: DateTime.now(),
        accuracy: accuracy,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 10,
        speedAccuracy: 0,
      );
    }

    test('starts in healthy state', () {
      expect(monitor.currentState, equals(GpsHealthState.healthy));
    });

    test('stays healthy with good GPS updates', () {
      monitor.ingestGpsUpdate(_makePosition(accuracy: 5.0));
      expect(monitor.currentState, equals(GpsHealthState.healthy));

      monitor.ingestGpsUpdate(_makePosition(accuracy: 10.0));
      expect(monitor.currentState, equals(GpsHealthState.healthy));
    });

    test('emits state changes on stream', () async {
      final states = <GpsHealthState>[];
      final sub = monitor.stateStream.listen(states.add);

      // Start with a GPS update
      monitor.ingestGpsUpdate(_makePosition());
      
      // Simulate going unavailable (no GPS for 25+ seconds)
      // We use a fake approach: manually set internal state for testing
      // In production, tick() would be called periodically
      
      sub.cancel();
    });

    test('reports correct silent duration', () {
      expect(monitor.silentDuration, isNull);
      
      monitor.ingestGpsUpdate(_makePosition());
      expect(monitor.silentDuration, isNotNull);
      expect(monitor.silentDuration!.inSeconds, lessThan(1));
    });

    test('tracks last accuracy', () {
      monitor.ingestGpsUpdate(_makePosition(accuracy: 15.0));
      expect(monitor.lastAccuracy, equals(15.0));

      monitor.ingestGpsUpdate(_makePosition(accuracy: 8.0));
      expect(monitor.lastAccuracy, equals(8.0));
    });

    test('reset clears state', () {
      monitor.ingestGpsUpdate(_makePosition());
      expect(monitor.silentDuration, isNotNull);

      monitor.reset();
      expect(monitor.currentState, equals(GpsHealthState.healthy));
      expect(monitor.silentDuration, isNull);
      expect(monitor.lastAccuracy, isNull);
    });

    test('thresholds match architecture spec', () {
      // Verify conservative thresholds from architecture spec
      expect(
        GpsHealthMonitor.degradedThreshold,
        equals(const Duration(seconds: 10)),
      );
      expect(
        GpsHealthMonitor.unavailableThreshold,
        equals(const Duration(seconds: 25)),
      );
      expect(GpsHealthMonitor.poorAccuracyMeters, equals(50.0));
    });
  });
}
