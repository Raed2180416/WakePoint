import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:geowake2/services/saved_route.dart';
import 'package:geowake2/services/saved_routes_service.dart';

// Hive is initialized with a temp dir by test/flutter_test_config.dart.
//
// Route memory is AUTOMATIC: `record()` on every arm, upserting by a coarse
// destination signature; the last few distinct trips are "recents" and a trip
// armed >= frequentThreshold times becomes a pinned "frequent" route.
void main() {
  // A distinct destination per index (well outside the ~100 m signature cell).
  Future<RouteMemory> arm(
    int destIdx, {
    String mode = 'distance',
    double value = 5,
    bool metro = false,
    String? line,
    double? originLat,
    double? originLng,
    required int atMs,
  }) =>
      RouteMemoryService.record(
        destinationName: 'Dest $destIdx',
        lat: 12.0 + destIdx, // >> 0.001 apart => different signatures
        lng: 77.0 + destIdx,
        placeId: 'pid_$destIdx',
        alarmMode: mode,
        alarmValue: value,
        metroMode: metro,
        metroLine: line,
        originLat: originLat,
        originLng: originLng,
        now: DateTime.fromMillisecondsSinceEpoch(atMs),
      );

  setUp(() async {
    if (Hive.isBoxOpen(RouteMemoryService.boxName)) {
      await Hive.box<String>(RouteMemoryService.boxName).clear();
    } else {
      await Hive.deleteBoxFromDisk(RouteMemoryService.boxName);
    }
  });

  group('RouteMemory model', () {
    test('map round-trip preserves all fields', () {
      final r = RouteMemory(
        id: 'sig',
        signature: 'sig',
        destinationName: 'Whitefield',
        lat: 12.99,
        lng: 77.75,
        placeId: 'pid',
        alarmMode: 'stops',
        alarmValue: 3,
        metroMode: true,
        metroLine: 'purple',
        timesTravelled: 4,
        firstSeenAt: DateTime.fromMillisecondsSinceEpoch(1000),
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(2000),
        lastOriginLat: 12.9,
        lastOriginLng: 77.5,
      );
      final back = RouteMemory.fromMap(r.toMap());
      expect(back.signature, 'sig');
      expect(back.destinationName, 'Whitefield');
      expect(back.alarmMode, 'stops');
      expect(back.timesTravelled, 4);
      expect(back.isFrequent, isTrue);
      expect(back.metroLine, 'purple');
      expect(back.lastOriginLat, 12.9);
    });

    test('signature snaps tiny jitter to the same cell but splits mode/line',
        () {
      final a = RouteMemory.buildSignature(
          lat: 12.99000, lng: 77.75000, metroMode: true, metroLine: 'Purple');
      final b = RouteMemory.buildSignature(
          lat: 12.99004, lng: 77.75004, metroMode: true, metroLine: 'purple');
      expect(a, b, reason: '<100m + same line => same trip');
      final road = RouteMemory.buildSignature(
          lat: 12.99, lng: 77.75, metroMode: false);
      expect(a, isNot(road), reason: 'metro vs road are different trips');
    });
  });

  group('RouteMemoryService.record — recents + frequency', () {
    test('first arm creates an entry at count 1 (a recent, not frequent)',
        () async {
      final r = await arm(1, atMs: 1000);
      expect(r.timesTravelled, 1);
      expect(r.isFrequent, isFalse);
      final list = await RouteMemoryService.list();
      expect(list.length, 1);
      expect(list.first.destinationName, 'Dest 1');
    });

    test('re-arming the same destination bumps the counter in place', () async {
      await arm(1, value: 3, atMs: 1000);
      await arm(1, value: 7, atMs: 2000); // slider nudged, same trip
      final list = await RouteMemoryService.list();
      expect(list.length, 1, reason: 'same signature => one entry');
      expect(list.first.timesTravelled, 2);
      expect(list.first.alarmValue, 7, reason: 'keeps the latest config');
    });

    test('crossing the threshold pins the trip as frequent', () async {
      for (var i = 0; i < RouteMemoryService.frequentThreshold; i++) {
        await arm(1, atMs: 1000 + i);
      }
      final freq = await RouteMemoryService.frequent();
      expect(freq.length, 1);
      expect(freq.first.timesTravelled,
          greaterThanOrEqualTo(RouteMemoryService.frequentThreshold));
    });

    test('recents are capped at maxRecents (newest kept, oldest evicted)',
        () async {
      // Arm 5 distinct one-off destinations.
      for (var i = 1; i <= 5; i++) {
        await arm(i, atMs: 1000 * i);
      }
      final list = await RouteMemoryService.list();
      expect(list.length, RouteMemoryService.maxRecents);
      // Newest three survive: Dest 5, 4, 3 (in recency order).
      expect(list.map((r) => r.destinationName).toList(),
          ['Dest 5', 'Dest 4', 'Dest 3']);
    });

    test('frequent trips survive the recents window; new one-offs do not evict',
        () async {
      // Make Dest 1 frequent.
      for (var i = 0; i < RouteMemoryService.frequentThreshold; i++) {
        await arm(1, atMs: 100 + i);
      }
      // Now flood with fresh one-off destinations.
      for (var i = 2; i <= 6; i++) {
        await arm(i, atMs: 1000 * i);
      }
      final list = await RouteMemoryService.list();
      final names = list.map((r) => r.destinationName).toSet();
      expect(names.contains('Dest 1'), isTrue,
          reason: 'frequent trip must be pinned, not evicted');
      // Frequent is listed first.
      expect(list.first.destinationName, 'Dest 1');
      expect(list.first.isFrequent, isTrue);
    });
  });

  group('RouteMemoryService — cache-reuse origin check', () {
    test('isSameOrigin true within tolerance, false beyond', () async {
      final r = await arm(1, originLat: 12.9716, originLng: 77.5946, atMs: 1000);
      // ~50 m away
      expect(
          RouteMemoryService.isSameOrigin(r, 12.9720, 77.5946), isTrue);
      // ~5 km away
      expect(
          RouteMemoryService.isSameOrigin(r, 13.02, 77.60), isFalse);
    });

    test('isSameOrigin false when no origin was recorded', () async {
      final r = await arm(1, atMs: 1000); // no origin
      expect(RouteMemoryService.isSameOrigin(r, 12.0, 77.0), isFalse);
    });
  });

  test('remove and clear', () async {
    final r = await arm(1, atMs: 1000);
    await RouteMemoryService.remove(r.id);
    expect(await RouteMemoryService.list(), isEmpty);
    await arm(2, atMs: 2000);
    await RouteMemoryService.clear();
    expect(await RouteMemoryService.list(), isEmpty);
  });
}
