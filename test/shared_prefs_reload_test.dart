import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/tracking_state_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPreferences Cross-Isolate Reload', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TrackingStateStore.resetCacheForTests();
    });

    test('isActive reads fresh value after external write', () async {
      // Initial state: not active
      expect(await TrackingStateStore.isActive(), isFalse);

      // Set active
      await TrackingStateStore.setActive(true);
      expect(await TrackingStateStore.isActive(), isTrue);

      // Simulate external write (like from another isolate)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('tracking_active_v1', false);

      // With reload() in isActive, should see the new value
      expect(await TrackingStateStore.isActive(), isFalse);
    });

    test('isPaused reads fresh value after external write', () async {
      // Initial state: not paused
      expect(await TrackingStateStore.isPaused(), isFalse);

      // Set paused
      await TrackingStateStore.setPaused(true);
      expect(await TrackingStateStore.isPaused(), isTrue);

      // Simulate external write
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('tracking_paused_v1', false);

      // With reload(), should see the new value
      expect(await TrackingStateStore.isPaused(), isFalse);
    });

    test('isAlarmFired reads fresh value after external write', () async {
      expect(await TrackingStateStore.isAlarmFired(), isFalse);

      await TrackingStateStore.setAlarmFired(true);
      expect(await TrackingStateStore.isAlarmFired(), isTrue);

      // Simulate external write clearing the flag
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('tracking_alarm_fired_v1', false);

      // With reload(), should see the new value
      expect(await TrackingStateStore.isAlarmFired(), isFalse);
    });

    test('loadSnapshot reads fresh value after external update', () async {
      // Save initial snapshot
      final initial = TrackingSnapshot(
        destinationName: 'Initial',
        destinationLat: 28.6,
        destinationLng: 77.2,
        alarmMode: 'distance',
        alarmValue: 1.0,
        metroMode: false,
        userLat: 28.5,
        userLng: 77.1,
        createdAt: DateTime.now(),
      );
      await TrackingStateStore.saveSnapshot(initial);

      // Verify initial snapshot
      var loaded = await TrackingStateStore.loadSnapshot();
      expect(loaded!.destinationName, 'Initial');

      // Simulate external write updating the snapshot
      TrackingSnapshot(
        destinationName: 'Updated',
        destinationLat: 28.7,
        destinationLng: 77.3,
        alarmMode: 'stops',
        alarmValue: 3.0,
        metroMode: true,
        userLat: 28.6,
        userLng: 77.2,
        createdAt: DateTime.now(),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tracking_snapshot_v1',
        '{"destinationName":"Updated","destinationLat":28.7,"destinationLng":77.3,"alarmMode":"stops","alarmValue":3.0,"metroMode":true,"userLat":28.6,"userLng":77.2,"createdAt":"${DateTime.now().toIso8601String()}"}',
      );

      // With reload() in loadSnapshot, should see the updated value
      loaded = await TrackingStateStore.loadSnapshot();
      expect(loaded!.destinationName, 'Updated');
      expect(loaded.alarmMode, 'stops');
      expect(loaded.metroMode, isTrue);
    });
  });
}
