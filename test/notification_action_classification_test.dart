import 'package:flutter_test/flutter_test.dart';
import 'package:geowake2/services/notification_service.dart';

void main() {
  group('NotificationService.classifyAction', () {
    test('detects journey ignore mute outcome', () {
      final outcome = NotificationService.classifyAction(
        'IGNORE',
        'journey_active',
      );
      expect(outcome, NotificationActionOutcome.muteJourney);
    });

    test('detects alarm ignore outcome', () {
      final outcome = NotificationService.classifyAction(
        'IGNORE',
        'open_alarm:1',
      );
      expect(outcome, NotificationActionOutcome.cancelAlarm);
    });

    test('detects resume tracking outcome', () {
      final outcome = NotificationService.classifyAction(
        'RESUME_TRACKING',
        'journey_paused',
      );
      expect(outcome, NotificationActionOutcome.resumeTracking);
    });

    test('detects end tracking outcome', () {
      final outcome = NotificationService.classifyAction(
        'END_TRACKING',
        'journey_active',
      );
      expect(outcome, NotificationActionOutcome.endTracking);
    });

    test('detects stop alarm outcome', () {
      final outcome = NotificationService.classifyAction('STOP_ALARM', null);
      expect(outcome, NotificationActionOutcome.stopAlarm);
    });

    test('detects dismiss alarm outcome', () {
      final outcome = NotificationService.classifyAction('DISMISS_ALARM', null);
      expect(outcome, NotificationActionOutcome.dismissAlarm);
    });

    test(
      'returns none for null action (handled directly in handleNotificationResponse)',
      () {
        final outcome = NotificationService.classifyAction(
          null,
          'open_alarm:0',
        );
        expect(outcome, NotificationActionOutcome.none);
      },
    );

    test('returns none for unknown action', () {
      final outcome = NotificationService.classifyAction('UNKNOWN', null);
      expect(outcome, NotificationActionOutcome.none);
    });
  });
}
