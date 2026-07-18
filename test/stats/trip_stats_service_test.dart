// Storage-level tests for TripStatsService. Uses a temp dir for both Hive and
// the background-isolate pending file (via debugPendingDirPathOverride), so no
// device / plugin is required.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:geowake2/services/stats/trip_record.dart';
import 'package:geowake2/services/stats/trip_stats_service.dart';

void main() {
  late Directory tmp;
  final svc = TripStatsService.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gw_trip_stats_test');
    Hive.init(tmp.path);
    TripStatsService.debugPendingDirPathOverride = tmp.path;
    await svc.resetForTest();
    // Start from a clean box each test.
    if (await Hive.boxExists(TripStatsService.boxName)) {
      await Hive.deleteBoxFromDisk(TripStatsService.boxName);
    }
  });

  tearDown(() async {
    await svc.resetForTest();
    await Hive.deleteFromDisk();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
    TripStatsService.debugPendingDirPathOverride = null;
  });

  TripRecord rec({bool onTime = true}) => TripRecord.build(
        mode: 'stops',
        outcome: onTime ? 'onTime' : 'late',
      );

  test('inline record + read round-trips', () async {
    await svc.recordTrip(rec());
    await svc.recordTrip(rec(onTime: false));
    final all = await svc.allTrips();
    expect(all.length, 2);
    expect(await svc.lifetimeWokenOnTime(), 1);
  });

  test('background-isolate record is buffered then drained exactly once',
      () async {
    // Simulate the alarm firing in the background isolate — no box write yet.
    await svc.recordTrip(rec(), fromBackgroundIsolate: true);
    await svc.recordTrip(rec(), fromBackgroundIsolate: true);

    // The pending file exists; the box is still empty until drained.
    final pending = File('${tmp.path}/gw_trip_stats_pending.log');
    expect(await pending.exists(), isTrue);

    // UI isolate drains (allTrips drains first).
    final all = await svc.allTrips();
    expect(all.length, 2);

    // Draining is idempotent — no double count on a second read.
    final again = await svc.allTrips();
    expect(again.length, 2);
    expect(await pending.exists(), isFalse);
  });

  test('a PII-looking record is rejected and never persisted', () async {
    final bad = TripRecord.build(
      mode: 'stops',
      outcome: 'onTime',
      destStation: '12.9716, 77.5946',
    );
    await svc.recordTrip(bad); // must not throw
    await svc.recordTrip(bad, fromBackgroundIsolate: true); // must not throw
    final all = await svc.allTrips();
    expect(all, isEmpty);
  });

  test('ring cap keeps only the newest records', () async {
    // Write cap + 5 records with increasing timestamps.
    const cap = 2000;
    final base = DateTime(2026, 1, 1).millisecondsSinceEpoch;
    // Build the list directly in the box to avoid 2005 sequential awaits.
    final box = await Hive.openBox(TripStatsService.boxName);
    final list = <Map<String, dynamic>>[];
    for (var i = 0; i < cap + 5; i++) {
      list.add(TripRecord.build(
        mode: 'stops',
        outcome: 'onTime',
        completedAtMs: base + i * 1000,
      ).toJson());
    }
    await box.put('records', list);
    await box.close();
    await svc.resetForTest();

    // One more inline write triggers the cap.
    await svc.recordTrip(TripRecord.build(
      mode: 'stops',
      outcome: 'onTime',
      completedAtMs: base + (cap + 100) * 1000,
    ));
    final all = await svc.allTrips();
    expect(all.length, cap);
    // The oldest record (i==0) must have been evicted; the newest is present.
    expect(all.first.completedAtMs, greaterThan(base));
    expect(all.last.completedAtMs, base + (cap + 100) * 1000);
  });

  test('clear empties the ledger and pending', () async {
    await svc.recordTrip(rec());
    await svc.recordTrip(rec(), fromBackgroundIsolate: true);
    await svc.clear();
    final all = await svc.allTrips();
    expect(all, isEmpty);
  });

  test('corrupt stored blob recovers to empty rather than throwing', () async {
    final box = await Hive.openBox(TripStatsService.boxName);
    // Store a non-list at the records key.
    await box.put('records', 'not-a-list');
    await box.close();
    await svc.resetForTest();
    final all = await svc.allTrips();
    expect(all, isEmpty);
    // And a subsequent write still works.
    await svc.recordTrip(rec());
    expect((await svc.allTrips()).length, 1);
  });
}
