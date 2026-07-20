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

  // --- Delivery MVP: composer deep links + user-mediated send ----------------

  test('composeDeepLink builds an sms: composer URI carrying the message body',
      () {
    final uri = GuardianService.composeDeepLink(
      const GuardianContact(
          id: 'x',
          displayName: 'Mom',
          channel: GuardianChannel.sms,
          address: '+91 12345'),
      'On my way · GeoWake\nhttps://x/j/abc',
    );
    expect(uri, isNotNull);
    expect(uri!.scheme, 'sms');
    expect(uri.path, '+9112345'); // spaces stripped, leading + kept
    expect(uri.queryParameters['body'], 'On my way · GeoWake\nhttps://x/j/abc');
  });

  test('composeDeepLink builds a wa.me URL for the WhatsApp channel', () {
    final uri = GuardianService.composeDeepLink(
      const GuardianContact(
          id: 'x',
          displayName: 'Mom',
          channel: GuardianChannel.whatsapp,
          address: '+91 98765 43210'),
      'hi',
    );
    expect(uri, isNotNull);
    expect(uri!.scheme, 'https');
    expect(uri.host, 'wa.me');
    expect(uri.pathSegments.single, '919876543210'); // digits only, no +
    expect(uri.queryParameters['text'], 'hi');
  });

  test('composeDeepLink returns null when the address has no usable digits', () {
    final uri = GuardianService.composeDeepLink(
      const GuardianContact(
          id: 'x',
          displayName: 'Mom',
          channel: GuardianChannel.whatsapp,
          address: '   '),
      'hi',
    );
    expect(uri, isNull);
  });

  test('pro arm composes the tracking link into the contact composer', () async {
    final share = JourneyShareService.forTest();
    final launched = <Uri>[];
    final g = GuardianService.forTest(
      entitlement: () => true,
      share: share,
      launcher: (uri) async {
        launched.add(uri);
        return true;
      },
    );
    await g.setContact(
        displayName: 'Mom', channel: GuardianChannel.sms, address: '+91123');
    await g.setEnabled(true);

    await g.onJourneyArmed(destLabel: 'Indiranagar');
    await _pump();

    expect(launched, hasLength(1));
    expect(launched.single.scheme, 'sms');
    // The composer body carries the /j/{id} tracking link.
    expect(launched.single.queryParameters['body'], contains('/j/'));
  });

  test('arrived-on-wake never opens a composer over the alarm; auto-sender '
      'delivers the "arrived safely" message when wired', () async {
    final share = JourneyShareService.forTest();
    final launched = <Uri>[];
    final autoMsgs = <String>[];
    final g = GuardianService.forTest(
      entitlement: () => true,
      share: share,
      launcher: (uri) async {
        launched.add(uri);
        return true;
      },
      autoSender: (contact, msg) async => autoMsgs.add(msg),
    );
    await g.setContact(
        displayName: 'Mom', channel: GuardianChannel.sms, address: '+91123');
    await g.setEnabled(true);
    g.registerPostAlarm();

    await g.onJourneyArmed(destLabel: 'Indiranagar');
    await _pump();
    launched.clear();
    autoMsgs.clear(); // drop the arm-time auto-send; isolate the arrival one

    PostAlarmMulticast.instance.dispatch();
    await _pump();

    // NEVER pop the user's SMS/WhatsApp composer at wake time (it would surface
    // over the just-fired alarm). The follower already sees "arrived safely"
    // via the backend; only a wired automatic sender delivers a message here.
    expect(launched, isEmpty);
    expect(autoMsgs, hasLength(1));
    expect(autoMsgs.single, contains('arrived safely'));
  });

  test('a wired auto-sender delivers without opening a composer', () async {
    final share = JourneyShareService.forTest();
    final launched = <Uri>[];
    final autoMsgs = <String>[];
    final g = GuardianService.forTest(
      entitlement: () => true,
      share: share,
      launcher: (uri) async {
        launched.add(uri);
        return true;
      },
      autoSender: (contact, msg) async => autoMsgs.add(msg),
    );
    await g.setContact(
        displayName: 'Mom', channel: GuardianChannel.sms, address: '+91123');
    await g.setEnabled(true);

    await g.onJourneyArmed(destLabel: 'Stop');
    await _pump();

    expect(launched, isEmpty); // composer NOT opened
    expect(autoMsgs, hasLength(1)); // automatic path took over
  });

  test('free user arm opens no composer', () async {
    final share = JourneyShareService.forTest();
    final launched = <Uri>[];
    final g = GuardianService.forTest(
      entitlement: () => false,
      share: share,
      launcher: (uri) async {
        launched.add(uri);
        return true;
      },
    );
    await g.onJourneyArmed(destLabel: 'Stop');
    await _pump();
    expect(launched, isEmpty);
  });
}
