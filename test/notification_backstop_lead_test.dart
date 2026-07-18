import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/core/reachability/reachability.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/tracking/notification_updater.dart';

/// BACKLOG #10 + #11 — process-death backstop correctness.
///
/// #10: the OS ETA backstop lead must be derived per-mode from the alarm config
/// (not a flat hardcoded 60 s) and must be >= the real lead so it fires EARLY,
/// never late.
///
/// #11: the ETA backstop (id 991) must be cancelled on the End-Tracking cleanup
/// path so it can never fire a spurious wake after the trip is over.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('#10 per-mode backstop lead derivation', () {
    test('time / minutes mode: lead = value * 60', () {
      expect(NotificationUpdater.backstopLeadSeconds('time', 5), 300.0);
      expect(NotificationUpdater.backstopLeadSeconds('minutes', 2), 120.0);
    });

    test('stops mode: lead = value * inter-stop seconds', () {
      final lead = NotificationUpdater.backstopLeadSeconds('stops', 3);
      expect(lead, 3 * NotificationUpdater.kBackstopInterStopSeconds);
      expect(lead, 270.0); // 3 stops * 90 s
      // Never-late: at least a full inter-stop of lead per remaining stop.
      expect(lead, greaterThanOrEqualTo(3 * 60.0));
    });

    test('distance mode: lead = value_km*1000 / V_LINE, over-bounded for never-late',
        () {
      final lead = NotificationUpdater.backstopLeadSeconds('distance', 2);
      expect(
        lead,
        (2 * 1000.0) / NotificationUpdater.kBackstopDistanceVLineMps,
      );
      // The chosen V_LINE is the standard-metro ceiling (28 m/s); dividing by it
      // yields a LARGER (earlier-firing) lead than dividing by the absolute
      // ceiling (56 m/s). The larger lead is the never-late-safe choice.
      final leadAtAbsoluteCeiling = (2 * 1000.0) / VLineTable.absoluteCeilingMps;
      expect(lead, greaterThanOrEqualTo(leadAtAbsoluteCeiling));
      expect(
        NotificationUpdater.kBackstopDistanceVLineMps,
        VLineTable.defaultMps,
      );
    });

    test('missing / invalid / unknown mode falls back to a 60 s floor (never zero)',
        () {
      expect(NotificationUpdater.backstopLeadSeconds('stops', 0), 60.0);
      expect(NotificationUpdater.backstopLeadSeconds('distance', -1), 60.0);
      expect(NotificationUpdater.backstopLeadSeconds('geofence', 1), 60.0);
    });
  });

  group('#11 End Tracking cancels ETA backstop id 991', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      NotificationService.isTestMode = true;
      NotificationService.clearTestRecordedNotifications();
    });

    tearDown(() {
      NotificationService.isTestMode = false;
      NotificationService.clearTestRecordedNotifications();
    });

    test('cancelAllNotifications (End-Tracking cleanup) records a cancel of 991',
        () async {
      await NotificationService().cancelAllNotifications();
      expect(NotificationService.testRecordedCancels, contains(991));
    });
  });
}
