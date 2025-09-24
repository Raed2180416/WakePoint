import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('NotificationService test hook records alarms in test mode', () async {
    NotificationService.isTestMode = true;
    NotificationService.clearTestRecordedAlarms();
    int hookCount = 0;
    NotificationService.testOnShowWakeUpAlarm = (title, body, allow) async {
      hookCount++;
    };

    await NotificationService().showWakeUpAlarm(
      title: 'Test Alarm',
      body: 'Body',
      allowContinueTracking: true,
    );

    expect(hookCount, 1);
    expect(NotificationService.testRecordedAlarms.length, 1);
    expect(NotificationService.testRecordedAlarms.first['title'], 'Test Alarm');
    expect(NotificationService.testRecordedAlarms.first['allow'], true);

    // cleanup
    NotificationService.isTestMode = false;
    NotificationService.testOnShowWakeUpAlarm = null;
    NotificationService.clearTestRecordedAlarms();
  });
}
