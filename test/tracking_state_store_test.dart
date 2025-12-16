import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/tracking_state_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrackingStateStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      TrackingStateStore.resetCacheForTests();
    });

    test('snapshot round-trips', () async {
      final snapshot = TrackingSnapshot(
        destinationName: 'Dest',
        destinationLat: 1.23,
        destinationLng: 4.56,
        alarmMode: 'distance',
        alarmValue: 1.0,
        metroMode: true,
        userLat: 9.87,
        userLng: 6.54,
        createdAt: DateTime(2024, 1, 1, 12, 30),
        directions: {
          'routes': [
            {
              'legs': [
                {'steps': []},
              ],
            },
          ],
        },
      );

      await TrackingStateStore.saveSnapshot(snapshot);
      final loaded = await TrackingStateStore.loadSnapshot();

      expect(loaded, isNotNull);
      expect(loaded!.destinationName, 'Dest');
      expect(loaded.metroMode, isTrue);
      expect(loaded.directions, isNotNull);
    });

    test('corrupt snapshot json returns null', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('tracking_snapshot_v1', '{not json');

      final loaded = await TrackingStateStore.loadSnapshot();
      expect(loaded, isNull);
    });

    test('notificationsMuted persists and clears correctly', () async {
      expect(await TrackingStateStore.notificationsMuted(), isFalse);

      await TrackingStateStore.setNotificationsMuted(true);
      expect(await TrackingStateStore.notificationsMuted(), isTrue);

      await TrackingStateStore.setNotificationsMuted(false);
      expect(await TrackingStateStore.notificationsMuted(), isFalse);
    });

    test('progress payload round-trips', () async {
      final payload = TrackingProgressPayload(
        title: 'Journey',
        subtitle: 'Remaining',
        progress: 0.5,
        isTracking: true,
      );

      await TrackingStateStore.saveProgressPayload(payload);
      final loaded = await TrackingStateStore.loadProgressPayload();

      expect(loaded, isNotNull);
      expect(loaded!.title, 'Journey');
      expect(loaded.progress, closeTo(0.5, 1e-9));
      expect(loaded.isTracking, isTrue);

      await TrackingStateStore.clearProgressPayload();
      expect(await TrackingStateStore.loadProgressPayload(), isNull);
    });

    test('alarm fired flag defaults false and toggles', () async {
      expect(await TrackingStateStore.isAlarmFired(), isFalse);
      await TrackingStateStore.setAlarmFired(true);
      expect(await TrackingStateStore.isAlarmFired(), isTrue);
      await TrackingStateStore.setAlarmFired(false);
      expect(await TrackingStateStore.isAlarmFired(), isFalse);
    });
  });
}
