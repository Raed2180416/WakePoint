// Behaviour tests for the FOLLOWER surface (FollowedRidesService + formatting).
// Uses a temp Hive dir; no device/plugin/network. Proves: follow/unfollow +
// persistence, coarse route-relative formatting (never raw GPS), and fail-safe
// polling (a throwing/absent reader never crashes and keeps last-known state).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:geowake2/services/share/followed_rides_service.dart';
import 'package:geowake2/services/share/journey_share_models.dart';
import 'package:geowake2/services/share/live_share_backend.dart';

/// A reader we can script: return a view, return null, or throw.
class _FakeReader implements ShareStatusReader {
  ShareStatusView? Function(String id)? onGet;
  bool willThrow = false; // persistent (not one-shot) so tests are race-free
  int calls = 0;

  @override
  Future<ShareStatusView?> getStatus(String id) async {
    calls++;
    if (willThrow) throw StateError('boom');
    return onGet?.call(id);
  }
}

ShareStatusView _view({
  String id = 'ride1',
  ShareStatus status = ShareStatus.enRoute,
  String? destLabel,
  int? etaEpochMs,
  double? lat,
  double? lng,
  bool gone = false,
}) =>
    ShareStatusView(
      id: id,
      status: status,
      destLabel: destLabel,
      etaEpochMs: etaEpochMs,
      lat: lat,
      lng: lng,
      gone: gone,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Box<String> box;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gw_followed_test');
    Hive.init(tmp.path);
    if (await Hive.boxExists(FollowedRidesService.boxName)) {
      await Hive.deleteBoxFromDisk(FollowedRidesService.boxName);
    }
    box = await Hive.openBox<String>(FollowedRidesService.boxName);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  FollowedRidesService svc({int Function()? nowMs}) =>
      FollowedRidesService.forTest(nowMs: nowMs, box: box);

  test('follow persists id/token and exposes the row; unfollow removes it',
      () async {
    final s = svc();
    final reader = _FakeReader()..onGet = (id) => _view(id: id);
    s.attachReader(reader);

    await s.follow('ride1', token: 'tok');
    expect(s.isFollowing('ride1'), isTrue);
    expect(s.rides.value.single.id, 'ride1');
    expect(s.rides.value.single.token, 'tok');
    // Persisted record carries NO coordinates — only id/token/addedAt.
    final raw = box.get('ride1')!;
    expect(raw.contains('lat'), isFalse);
    expect(raw.contains('ride1'), isTrue);

    await s.unfollow('ride1');
    expect(s.isFollowing('ride1'), isFalse);
    expect(s.rides.value, isEmpty);
    expect(box.get('ride1'), isNull);
    s.dispose();
  });

  test('follow is idempotent and adopts a later token', () async {
    final s = svc();
    s.attachReader(_FakeReader());
    await s.follow('ride1');
    await s.follow('ride1', token: 'late-tok');
    expect(s.rides.value.length, 1);
    expect(s.rides.value.single.token, 'late-tok');
    s.dispose();
  });

  test('persisted follows reload on init', () async {
    box.put(
        'r9',
        FollowedRide(id: 'r9', token: 't', addedAtMs: 5).encodeRecord());
    final s = svc();
    await s.init(autoPoll: false);
    expect(s.isFollowing('r9'), isTrue);
    s.dispose();
  });

  test('refresh stores the coarse view; formatting is route-relative only',
      () async {
    var now = 1000000;
    final s = svc(nowMs: () => now);
    final eta = now + 8 * 60000; // 8 minutes out
    final reader = _FakeReader()
      ..onGet = (id) => _view(
            id: id,
            destLabel: 'MG Road',
            etaEpochMs: eta,
            lat: 12.97123,
            lng: 77.59456,
          );
    s.attachReader(reader);
    await s.follow('ride1');
    await s.refreshAll();

    final row = s.rides.value.single;
    final headline = FollowedRideFormat.headline(row);
    final away = FollowedRideFormat.minutesAway(row, nowMs: now);

    expect(headline, contains('On the way to MG Road'));
    expect(headline, contains('arriving ~'));
    expect(away, '8 min away');
    // CRITICAL: coordinates never appear in any user-facing string.
    expect(headline.contains('12.9'), isFalse);
    expect(headline.contains('77.5'), isFalse);
    expect(away!.contains('12.9'), isFalse);
    s.dispose();
  });

  test('formatting covers arrived / expired / waiting states', () {
    final base = FollowedRide(id: 'r', addedAtMs: 0);
    expect(FollowedRideFormat.headline(base), 'Waiting for updates…');

    final arrived = base.copyWith(
        latest: _view(status: ShareStatus.arrived, destLabel: 'Home'));
    expect(FollowedRideFormat.headline(arrived), 'Arrived safely at Home');

    final gone = base.copyWith(latest: _view(gone: true));
    expect(FollowedRideFormat.headline(gone), 'Link expired');

    // No active ETA → no "min away" line.
    expect(
        FollowedRideFormat.minutesAway(arrived, nowMs: 0), isNull);
  });

  test('minutesAway clamps to "Arriving now" at/after ETA', () {
    final row = FollowedRide(id: 'r', addedAtMs: 0)
        .copyWith(latest: _view(etaEpochMs: 500));
    expect(FollowedRideFormat.minutesAway(row, nowMs: 1000), 'Arriving now');
  });

  test('a throwing reader never crashes and keeps the last-known view',
      () async {
    final s = svc();
    final reader = _FakeReader()
      ..onGet = (id) => _view(id: id, destLabel: 'MG Road', etaEpochMs: 999);
    s.attachReader(reader);
    await s.follow('ride1');
    await s.refreshAll();
    expect(s.rides.value.single.latest?.destLabel, 'MG Road');

    // Next poll throws — must not clear the previously-fetched view.
    reader.willThrow = true;
    await s.refreshAll();
    final row = s.rides.value.single;
    expect(row.latest?.destLabel, 'MG Road');
    expect(row.error, isNotNull);
    s.dispose();
  });

  test('with no reader (offline) following still works, shows Waiting',
      () async {
    final s = svc();
    // No attachReader → offline.
    await s.follow('ride1');
    await s.refreshAll(); // no-op, no throw
    expect(FollowedRideFormat.headline(s.rides.value.single),
        'Waiting for updates…');
    s.dispose();
  });

  test('a 410 gone view retires the row copy to expired', () async {
    final s = svc();
    final reader = _FakeReader()..onGet = (id) => ShareStatusView.gone(id);
    s.attachReader(reader);
    await s.follow('ride1');
    await s.refreshAll();
    expect(s.rides.value.single.latest?.gone, isTrue);
    expect(FollowedRideFormat.headline(s.rides.value.single), 'Link expired');
    s.dispose();
  });
}
