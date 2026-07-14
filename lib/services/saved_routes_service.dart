import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math' as math;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:geowake2/services/saved_route.dart';

/// Automatic memory of routes the rider actually travels.
///
/// No manual "save" — [record] is called on every arm. The store keeps:
///   • the last [maxRecents] distinct trips (rolling window), and
///   • every trip travelled at least [frequentThreshold] times ("frequent"),
///     which is PINNED and never evicted by the recents window.
///
/// This replaces the earlier manual Home/Work model, which doesn't fit a
/// position-dependent alarm. Storage mirrors the app's Hive convention (one
/// lazily-opened, self-healing `Box<String>` holding the whole list as JSON).
class RouteMemoryService {
  static const String boxName = 'route_memory_v1';
  static const String _key = 'routes';

  /// Travelled this many times ⇒ promoted to a pinned "frequent" route.
  static const int frequentThreshold = 3;

  /// How many NON-frequent trips to keep as one-tap "recents".
  static const int maxRecents = 3;

  /// Hard cap on stored entries (frequent + recents) so the box can't grow
  /// without bound if a user visits hundreds of distinct destinations.
  static const int maxFrequent = 12;

  /// A re-arm from within this radius of the last origin is treated as the same
  /// start point, so a cached Directions result can be reused (no API call).
  static const double sameOriginMeters = 300.0;

  static Box<String>? _box;
  static Future<void>? _opening;

  /// Ensures the box is open (once), recreating it if corrupt.
  static Future<void> _ensureBoxIsOpen() async {
    if (_box != null && _box!.isOpen) return;
    if (_opening != null) return _opening;
    _opening = () async {
      try {
        _box = await Hive.openBox<String>(boxName);
      } catch (e) {
        dev.log(
          'Error opening route memory box: $e. Attempting recreate.',
          name: 'RouteMemoryService',
        );
        try {
          await Hive.deleteBoxFromDisk(boxName);
          _box = await Hive.openBox<String>(boxName);
        } catch (e2) {
          dev.log(
            'Failed to recreate route memory box: $e2',
            name: 'RouteMemoryService',
          );
          rethrow;
        }
      }
    }();
    try {
      await _opening;
    } finally {
      _opening = null;
    }
  }

  /// All stored entries as persisted (unordered). Never throws — [] on error.
  static Future<List<RouteMemory>> _readAll() async {
    try {
      await _ensureBoxIsOpen();
      final raw = _box!.get(_key);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => RouteMemory.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } catch (e) {
      dev.log('Error reading route memory: $e', name: 'RouteMemoryService');
      return [];
    }
  }

  static Future<void> _writeAll(List<RouteMemory> routes) async {
    try {
      await _ensureBoxIsOpen();
      await _box!.put(_key, jsonEncode(routes.map((r) => r.toMap()).toList()));
    } catch (e) {
      dev.log('Error writing route memory: $e', name: 'RouteMemoryService');
    }
  }

  /// Frequent (pinned) trips first — most-travelled, then most-recent — then the
  /// most recent non-frequent trips. This is what the home screen renders.
  static Future<List<RouteMemory>> list() async {
    final all = await _readAll();
    final frequent = all.where((r) => r.isFrequent).toList()
      ..sort((a, b) {
        final c = b.timesTravelled.compareTo(a.timesTravelled);
        return c != 0 ? c : b.lastUsedAt.compareTo(a.lastUsedAt);
      });
    final recents = all.where((r) => !r.isFrequent).toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return [
      ...frequent.take(maxFrequent),
      ...recents.take(maxRecents),
    ];
  }

  static Future<List<RouteMemory>> frequent() async =>
      (await list()).where((r) => r.isFrequent).toList();

  static Future<List<RouteMemory>> recents() async =>
      (await list()).where((r) => !r.isFrequent).toList();

  static Future<RouteMemory?> getBySignature(String signature) async {
    for (final r in await _readAll()) {
      if (r.signature == signature) return r;
    }
    return null;
  }

  /// Record that a trip was just armed. Upserts by coarse signature: an existing
  /// trip has its counter bumped and recency/config refreshed; a new one starts
  /// at 1. Then prunes to (all frequent) + (the [maxRecents] newest others).
  ///
  /// Returns the stored entry (post-increment) so callers can read
  /// `timesTravelled` / `isFrequent` / `lastOrigin*` for cache decisions.
  static Future<RouteMemory> record({
    required String destinationName,
    required double lat,
    required double lng,
    String? placeId,
    required String alarmMode,
    required double alarmValue,
    required bool metroMode,
    String? metroLine,
    double? originLat,
    double? originLng,
    DateTime? now,
  }) async {
    final ts = now ?? DateTime.now();
    final signature = RouteMemory.buildSignature(
      lat: lat,
      lng: lng,
      metroMode: metroMode,
      metroLine: metroLine,
    );
    final all = await _readAll();
    final idx = all.indexWhere((r) => r.signature == signature);

    RouteMemory stored;
    if (idx >= 0) {
      final prev = all[idx];
      stored = prev.copyWith(
        destinationName: destinationName.isNotEmpty
            ? destinationName
            : prev.destinationName,
        lat: lat,
        lng: lng,
        placeId: placeId,
        alarmMode: alarmMode,
        alarmValue: alarmValue,
        metroMode: metroMode,
        metroLine: metroLine,
        timesTravelled: prev.timesTravelled + 1,
        lastUsedAt: ts,
        lastOriginLat: originLat,
        lastOriginLng: originLng,
      );
      all[idx] = stored;
    } else {
      stored = RouteMemory(
        id: signature,
        signature: signature,
        destinationName: destinationName,
        lat: lat,
        lng: lng,
        placeId: placeId,
        alarmMode: alarmMode,
        alarmValue: alarmValue,
        metroMode: metroMode,
        metroLine: metroLine,
        timesTravelled: 1,
        firstSeenAt: ts,
        lastUsedAt: ts,
        lastOriginLat: originLat,
        lastOriginLng: originLng,
      );
      all.add(stored);
    }

    await _writeAll(_prune(all));
    return stored;
  }

  /// Keep every frequent trip (capped at [maxFrequent]) plus the newest
  /// [maxRecents] non-frequent trips; drop the rest.
  static List<RouteMemory> _prune(List<RouteMemory> all) {
    final frequent = all.where((r) => r.isFrequent).toList()
      ..sort((a, b) {
        final c = b.timesTravelled.compareTo(a.timesTravelled);
        return c != 0 ? c : b.lastUsedAt.compareTo(a.lastUsedAt);
      });
    final recents = all.where((r) => !r.isFrequent).toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return [
      ...frequent.take(maxFrequent),
      ...recents.take(maxRecents),
    ];
  }

  /// Whether [originLat]/[originLng] is close enough to a remembered trip's last
  /// origin that a cached route for it can be reused without a new API call.
  static bool isSameOrigin(
    RouteMemory r,
    double originLat,
    double originLng, {
    double toleranceMeters = sameOriginMeters,
  }) {
    if (r.lastOriginLat == null || r.lastOriginLng == null) return false;
    final d = _haversineMeters(
      r.lastOriginLat!,
      r.lastOriginLng!,
      originLat,
      originLng,
    );
    return d <= toleranceMeters;
  }

  static Future<void> remove(String id) async {
    final all = await _readAll();
    all.removeWhere((r) => r.id == id || r.signature == id);
    await _writeAll(all);
  }

  static Future<void> clear() async {
    await _writeAll(const []);
  }

  static double _haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const r = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180.0;
}
