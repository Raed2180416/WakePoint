// Guardian mode gating + arrived-on-wake behaviour. Free users are blocked at
// every mutation; Pro users can configure, auto-share on arm, and the "arrived
// safely" signal fires exactly once via the post-alarm multicast.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/share/guardian_service.dart';
import 'package:geowake2/services/share/journey_share_models.dart';
import 'package:geowake2/services/share/journey_share_service.dart';
import 'package:geowake2/services/share/live_share_backend.dart';
import 'package:geowake2/services/tracking/post_alarm_multicast.dart';

class _RecBackend implements ShareBackend {
  @override
  bool get supportsLive => false;
  int arrived = 0;
  @override
  Future<String?> createShare(ShareSession session) async => null;
  @override
  Future<void> pushLocation(String id, ShareSnapshot s) async {}
  @override
  Future<void> markArrived(String id) async => arrived++;
  @override
  Future<void> revoke(String id) async {}
}

Future<void> _pump() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gw_guardian_test');
    Hive.init(tmp.path);
    SharedPreferences.setMockInitialValues({});
    PostAlarmMulticast.instance.clear();
  });

  tearDown(() async {
    PostAlarmMulticast.instance.clear();
    await Hive.deleteFromDisk();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  GuardianService freeGuard(JourneyShareService share) =>
      GuardianService.forTest(entitlement: () => false, share: share);
  GuardianService proGuard(JourneyShareService share) =>
      GuardianService.forTest(entitlement: () => true, share: share);

  test('free user is blocked at every mutation', () async {
    final g = freeGuard(JourneyShareService.forTest());
    expect(() => g.setEnabled(true), throwsA(isA<GuardianDenied>()));
    expect(
      () => g.setContact(
          displayName: 'Mom',
          channel: GuardianChannel.sms,
          address: '+91123'),
      throwsA(isA<GuardianDenied>()),
    );
    expect(await g.isEnabled(), isFalse);
  });

  test('free user onJourneyArmed is a silent no-op (no share created)',
      () async {
    final share = JourneyShareService.forTest();
    final g = freeGuard(share);
    await g.onJourneyArmed(destLabel: 'Stop');
    expect(await share.allSessions(), isEmpty);
  });

  test('pro user configures, enables, and defaults are opt-out', () async {
    final g = proGuard(JourneyShareService.forTest());
    expect(await g.isEnabled(), isFalse); // opt-out by default
    await g.setContact(
        displayName: 'Mom', channel: GuardianChannel.sms, address: '+91123');
    await g.setEnabled(true);
    expect(await g.isEnabled(), isTrue);
    expect((await g.getContact())!.displayName, 'Mom');
    expect(await g.isActiveGuard(), isTrue);
  });

  test('enable without a contact is refused', () async {
    final g = proGuard(JourneyShareService.forTest());
    expect(() => g.setEnabled(true), throwsA(isA<GuardianDenied>()));
  });

  test('pro auto-shares on arm and fires arrived exactly once on wake',
      () async {
    final share = JourneyShareService.forTest();
    final backend = _RecBackend();
    share.backend = backend;
    final g = proGuard(share);

    await g.setContact(
        displayName: 'Mom', channel: GuardianChannel.sms, address: '+91123');
    await g.setEnabled(true);
    g.registerPostAlarm();

    await g.onJourneyArmed(destLabel: 'Indiranagar');
    final active = await share.allSessions();
    expect(active.single.mode, ShareMode.guardian);
    expect(active.single.status, ShareStatus.enRoute);

    // Wake fires → multicast dispatches.
    PostAlarmMulticast.instance.dispatch();
    await _pump();

    final after = await share.allSessions();
    expect(after.single.status, ShareStatus.arrived);
    expect(backend.arrived, 1);

    // A second dispatch must not re-fire arrived (already terminal).
    PostAlarmMulticast.instance.dispatch();
    await _pump();
    expect(backend.arrived, 1);
  });
}
