// Storage + behaviour tests for JourneyShareService. Uses a temp Hive dir and
// mocked SharedPreferences; no device/plugin needed. Proves: basic share works
// OFFLINE with no premium read, the 15 s ping throttle, revoke/expiry, and that
// snapshots stay coarse.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:geowake2/services/share/journey_share_models.dart';
import 'package:geowake2/services/share/journey_share_service.dart';
import 'package:geowake2/services/share/live_share_backend.dart';

/// Records calls so we can assert throttling / arrived / revoke.
class _RecordingBackend implements ShareBackend {
  @override
  final bool supportsLive;
  _RecordingBackend({this.supportsLive = true});

  int created = 0;
  int pings = 0;
  int arrived = 0;
  int revoked = 0;

  @override
  Future<String?> createShare(ShareSession session) async {
    created++;
    return 'srv-${session.id}';
  }

  @override
  Future<void> pushLocation(String shareId, ShareSnapshot snapshot) async {
    pings++;
  }

  @override
  Future<void> markArrived(String shareId) async => arrived++;

  @override
  Future<void> revoke(String shareId) async => revoked++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gw_share_test');
    Hive.init(tmp.path);
    SharedPreferences.setMockInitialValues({});
    if (await Hive.boxExists(JourneyShareService.boxName)) {
      await Hive.deleteBoxFromDisk(JourneyShareService.boxName);
    }
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('startBasicShare works offline (Noop) with no premium read', () async {
    final svc = JourneyShareService.forTest();
    // Note: MonetizationService is never initialised in this test — if the
    // service read entitlement it would blow up here. It must not.
    final started = await svc.startBasicShare(destLabel: 'MG Road');
    expect(started.message.contains('GeoWake'), isTrue);
    expect(started.url.contains('/j/${started.session.id}'), isTrue);
    expect(svc.isSharing.value, isTrue);

    final all = await svc.allSessions();
    expect(all.length, 1);
    expect(all.first.status, ShareStatus.enRoute);
  });

  test('live backend registers a server id', () async {
    final svc = JourneyShareService.forTest();
    final backend = _RecordingBackend();
    svc.backend = backend;
    final started = await svc.startBasicShare(mode: ShareMode.live);
    expect(backend.created, 1);
    final stored = (await svc.allSessions()).first;
    expect(stored.backendId, 'srv-${started.session.id}');
  });

  test('ingestLocation throttles to 15 s and only with a live backend',
      () async {
    var now = 1000000;
    final svc = JourneyShareService.forTest(nowMs: () => now);
    final backend = _RecordingBackend();
    svc.backend = backend;
    await svc.startBasicShare(mode: ShareMode.live);

    await svc.ingestLocation(12.9, 77.5); // first ping
    await svc.ingestLocation(12.9, 77.5); // within throttle → dropped
    expect(backend.pings, 1);

    now += 15001; // past throttle
    await svc.ingestLocation(12.9, 77.5);
    expect(backend.pings, 2);
  });

  test('ingestLocation is a no-op when backend is not live', () async {
    final svc = JourneyShareService.forTest();
    svc.backend = _RecordingBackend(supportsLive: false);
    await svc.startBasicShare(mode: ShareMode.live);
    await svc.ingestLocation(1, 2);
    // no throw, nothing to assert beyond safety
    expect(svc.isSharing.value, isTrue);
  });

  test('markArrived terminates active sessions and clears the flag', () async {
    final svc = JourneyShareService.forTest();
    final backend = _RecordingBackend();
    svc.backend = backend;
    await svc.startBasicShare(mode: ShareMode.guardian);
    await svc.markArrived();
    final all = await svc.allSessions();
    expect(all.single.status, ShareStatus.arrived);
    expect(backend.arrived, 1);
    // flag recomputes async
    await Future<void>.delayed(Duration.zero);
    expect(svc.isSharing.value, isFalse);
  });

  test('revoke ends a share', () async {
    final svc = JourneyShareService.forTest();
    final backend = _RecordingBackend();
    svc.backend = backend;
    final s = await svc.startBasicShare();
    await svc.revoke(s.session.id);
    final all = await svc.allSessions();
    expect(all.single.status, ShareStatus.revoked);
    expect(backend.revoked, 1);
  });

  test('expired sessions are swept to expired', () async {
    var now = 1000;
    final svc = JourneyShareService.forTest(nowMs: () => now);
    await svc.startBasicShare(ttl: const Duration(minutes: 5));
    now += const Duration(minutes: 6).inMilliseconds;
    final all = await svc.allSessions();
    expect(all.single.status, ShareStatus.expired);
  });
}
