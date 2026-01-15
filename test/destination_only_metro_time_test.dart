import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/tracking/alarm_controller.dart';
import 'package:geowake2/services/alarm_evaluator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TrackingStateStore.resetCacheForTests();
  });

  test('Metro time mode: defaults to full alarms (no suppression)', () async {
    final suppress =
        await AlarmController.shouldSuppressNonDestinationInMetroTime(
          AlarmEventType.preBoarding,
        );
    expect(suppress, isFalse);
  });

  test(
    'Metro time mode: destination-only suppresses non-destination alarms',
    () async {
      await TrackingStateStore.setDestinationOnlyMetroTimeEnabled(true);

      final suppressLeg =
          await AlarmController.shouldSuppressNonDestinationInMetroTime(
            AlarmEventType.preBoarding,
          );
      final suppressDest =
          await AlarmController.shouldSuppressNonDestinationInMetroTime(
            AlarmEventType.finalDestination,
          );

      expect(suppressLeg, isTrue);
      expect(suppressDest, isFalse);
    },
  );
}
