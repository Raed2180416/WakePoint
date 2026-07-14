import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:developer' as dev;

/// Simple Hive-backed route cache for Directions API responses.
/// Keyed by a stable hash of origin+destination+mode.
class RouteCacheEntry {
  final String key; // computed hash
  final Map<String, dynamic> directions; // raw directions payload
  final DateTime timestamp; // retrieval time
  final LatLng origin; // origin used when fetched
  final LatLng destination; // destination used when fetched
  final String mode; // 'driving' | 'transit'
  final String? simplifiedCompressedPolyline; // optional preprocessed polyline

  /// G17: planned departure (unix epoch seconds) when the provider supplies a
  /// scheduled transit time. Null for scheduleless/driving routes.
  final int? plannedDepartureEpoch;

  /// G17: planned arrival (unix epoch seconds) when the provider supplies a
  /// scheduled transit time. Used to evict routes stale across a last-service
  /// boundary. Null for scheduleless/driving routes.
  final int? plannedArrivalEpoch;

  /// G17: schema version this entry was written under. Entries written by an
  /// older schema are treated as stale on read. Defaults to 0 for legacy entries.
  final int schemaVersion;

  RouteCacheEntry({
    required this.key,
    required this.directions,
    required this.timestamp,
    required this.origin,
    required this.destination,
    required this.mode,
    this.simplifiedCompressedPolyline,
    this.plannedDepartureEpoch,
    this.plannedArrivalEpoch,
    this.schemaVersion = 0,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'directions': directions,
    'timestamp': timestamp.toIso8601String(),
    'origin': {'lat': origin.latitude, 'lng': origin.longitude},
    'destination': {'lat': destination.latitude, 'lng': destination.longitude},
    'mode': mode,
    if (simplifiedCompressedPolyline != null)
      'scp': simplifiedCompressedPolyline,
    if (plannedDepartureEpoch != null)
      'plannedDepartureEpoch': plannedDepartureEpoch,
    if (plannedArrivalEpoch != null)
      'plannedArrivalEpoch': plannedArrivalEpoch,
    'schemaVersion': schemaVersion,
  };

  static RouteCacheEntry fromJson(Map<String, dynamic> json) {
    final o = json['origin'] as Map<String, dynamic>;
    final d = json['destination'] as Map<String, dynamic>;
    return RouteCacheEntry(
      key: json['key'] as String,
      directions: Map<String, dynamic>.from(json['directions'] as Map),
      timestamp: DateTime.parse(json['timestamp'] as String),
      origin: LatLng(
        (o['lat'] as num).toDouble(),
        (o['lng'] as num).toDouble(),
      ),
      destination: LatLng(
        (d['lat'] as num).toDouble(),
        (d['lng'] as num).toDouble(),
      ),
      mode: json['mode'] as String,
      simplifiedCompressedPolyline: json['scp'] as String?,
      plannedDepartureEpoch: json['plannedDepartureEpoch'] as int?,
      plannedArrivalEpoch: json['plannedArrivalEpoch'] as int?,
      schemaVersion: json['schemaVersion'] as int? ?? 0,
    );
  }
}

class RouteCache {
  static const String boxName = 'route_cache_v1';
  static const Duration defaultTtl = Duration(minutes: 5);
  static const double defaultOriginDeviationMeters = 300.0;

  /// G17: bump when the cached route/directions schema changes. Entries written
  /// by an older schema are treated as stale on read.
  static const int schemaVersion = 1;

  static Box<String>? _box; // store JSON strings

  static Future<void> _ensureOpen() async {
    if (_box != null && _box!.isOpen) return;
    try {
      _box = await Hive.openBox<String>(boxName);
    } catch (e) {
      dev.log(
        'Error opening route cache box: $e. Attempting recreate.',
        name: 'RouteCache',
      );
      try {
        await Hive.deleteBoxFromDisk(boxName);
        _box = await Hive.openBox<String>(boxName);
      } catch (e2) {
        dev.log('Failed to recreate route cache box: $e2', name: 'RouteCache');
        rethrow;
      }
    }
  }

  /// Create a stable key from origin, destination, and mode.
  static String makeKey({
    required LatLng origin,
    required LatLng destination,
    required String mode,
    String? transitVariant, // e.g., 'rail'
    int? departureTime, // unix epoch seconds; when set, route is time-anchored
  }) {
    // Round to ~5 decimal places (~1.1m) to improve cache hits for minor variations
    double r(double v) => double.parse(v.toStringAsFixed(5));
    final payload = jsonEncode({
      'o': {'lat': r(origin.latitude), 'lng': r(origin.longitude)},
      'd': {'lat': r(destination.latitude), 'lng': r(destination.longitude)},
      'm': mode,
      if (transitVariant != null) 'tv': transitVariant,
      if (departureTime != null) 'dt': departureTime,
    });
    return payload; // simple JSON string key; could hash if desired
  }

  static Future<RouteCacheEntry?> get({
    required LatLng origin,
    required LatLng destination,
    required String mode,
    String? transitVariant,
    int? departureTime,
    Duration ttl = defaultTtl,
    double originDeviationMeters = defaultOriginDeviationMeters,
  }) async {
    await _ensureOpen();
    final key = makeKey(
      origin: origin,
      destination: destination,
      mode: mode,
      transitVariant: transitVariant,
      departureTime: departureTime,
    );
    final jsonStr = _box!.get(key);
    if (jsonStr == null) return null;
    try {
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final entry = RouteCacheEntry.fromJson(decoded);

      // TTL check
      if (DateTime.now().difference(entry.timestamp) > ttl) {
        dev.log('RouteCache stale by TTL. Key evicted.', name: 'RouteCache');
        await _box!.delete(key);
        return null;
      }

      // G17: schema-version guard. Entries written by an older schema are stale.
      if (entry.schemaVersion != schemaVersion) {
        dev.log(
          'RouteCache schema mismatch (${entry.schemaVersion} != $schemaVersion). Evicting.',
          name: 'RouteCache',
        );
        await _box!.delete(key);
        return null;
      }

      // G17: planned-window guard. A route whose planned arrival is already in
      // the past is stale (esp. across a last-service boundary). Force a refresh.
      final arr = entry.plannedArrivalEpoch;
      if (arr != null) {
        final arrivalTime = DateTime.fromMillisecondsSinceEpoch(arr * 1000);
        if (DateTime.now().isAfter(arrivalTime)) {
          dev.log(
            'RouteCache planned arrival passed (last-service boundary). Evicting.',
            name: 'RouteCache',
          );
          await _box!.delete(key);
          return null;
        }
      }

      // Origin deviation check
      final devMeters = Geolocator.distanceBetween(
        origin.latitude,
        origin.longitude,
        entry.origin.latitude,
        entry.origin.longitude,
      );
      if (devMeters >= originDeviationMeters) {
        dev.log(
          'RouteCache invalid by origin deviation ${devMeters.toStringAsFixed(0)}m.',
          name: 'RouteCache',
        );
        await _box!.delete(key);
        return null;
      }

      return entry;
    } catch (e) {
      dev.log(
        'RouteCache decode failure: $e. Deleting key.',
        name: 'RouteCache',
      );
      await _box!.delete(key);
      return null;
    }
  }

  static Future<void> put(RouteCacheEntry entry) async {
    await _ensureOpen();
    final key = entry.key;
    final jsonStr = jsonEncode(entry.toJson());
    await _box!.put(key, jsonStr);
  }

  static Future<void> clear() async {
    await _ensureOpen();
    await _box!.clear();
  }
}
