// docs/annotated/services/route_cache.annotated.dart
// Purpose: Line-by-line annotated copy of `lib/services/route_cache.dart`.
// Scope: Hive-backed cache entries, stable keying, TTL and origin deviation guards, clear/put/get lifecycle.
// P2 Improvement: Removed per-write flush operations in put/clear to cut synchronous I/O overhead.
//                 Durability is still acceptable for ephemeral navigation cache; flush can be deferred to
//                 app lifecycle or periodic maintenance if needed.

import 'dart:convert'; // JSON serialization for payload and key.
import 'package:geolocator/geolocator.dart'; // Distance computation for origin deviation checks.
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng type for origin/destination.
import 'package:hive_flutter/hive_flutter.dart'; // Hive box storage (String values).
import 'dart:developer' as dev; // Logging with categories.

/// Simple Hive-backed route cache for Directions API responses. // High-level module description.
/// Keyed by a stable hash of origin+destination+mode.               // Deterministic keying strategy.
class RouteCacheEntry { // Data container for cached route payloads and metadata.
  final String key; // computed hash // Cache key derived from inputs.
  final Map<String, dynamic> directions; // raw directions payload // JSON-like payload.
  final DateTime timestamp; // retrieval time // When entry was stored.
  final LatLng origin; // origin used when fetched // For deviation validation.
  final LatLng destination; // destination used when fetched // Informational; part of key.
  final String mode; // 'driving' | 'transit' // Mode that shaped the route.
  final String? simplifiedCompressedPolyline; // optional preprocessed polyline // Optional optimization artifact.

  RouteCacheEntry({ // Constructor with required fields.
    required this.key,
    required this.directions,
    required this.timestamp,
    required this.origin,
    required this.destination,
    required this.mode,
    this.simplifiedCompressedPolyline,
  });

  Map<String, dynamic> toJson() => { // Serialize for storage.
        'key': key, // Include key for sanity.
        'directions': directions, // Persist raw payload.
        'timestamp': timestamp.toIso8601String(), // ISO8601 for parseability.
        'origin': {'lat': origin.latitude, 'lng': origin.longitude}, // Numeric lat/lng.
        'destination': {'lat': destination.latitude, 'lng': destination.longitude}, // Numeric lat/lng.
        'mode': mode, // Persist mode.
    if (simplifiedCompressedPolyline != null) 'scp': simplifiedCompressedPolyline, // Optional field shorthanded.
      }; // End map.

  static RouteCacheEntry fromJson(Map<String, dynamic> json) { // Hydrate from storage JSON.
    final o = json['origin'] as Map<String, dynamic>; // Extract origin map.
    final d = json['destination'] as Map<String, dynamic>; // Extract destination map.
    return RouteCacheEntry( // Create a new instance.
      key: json['key'] as String, // Restore key.
      directions: Map<String, dynamic>.from(json['directions'] as Map), // Deep cast payload.
      timestamp: DateTime.parse(json['timestamp'] as String), // Parse ISO8601 timestamp.
      origin: LatLng((o['lat'] as num).toDouble(), (o['lng'] as num).toDouble()), // Make LatLng.
      destination: LatLng((d['lat'] as num).toDouble(), (d['lng'] as num).toDouble()), // Make LatLng.
      mode: json['mode'] as String, // Restore mode.
      simplifiedCompressedPolyline: json['scp'] as String?, // Optional polyline blob.
    ); // End ctor.
  }
}

class RouteCache { // Static utility for cache lifecycle.
  static const String boxName = 'route_cache_v1'; // Hive box name (String values).
  static const Duration defaultTtl = Duration(minutes: 5); // Default freshness window.
  static const double defaultOriginDeviationMeters = 300.0; // Permitted origin skew before invalidation.

  static Box<String>? _box; // store JSON strings // Lazily opened Hive box.

  static Future<void> _ensureOpen() async { // Internal: open or recreate box.
    if (_box != null && _box!.isOpen) return; // If already open, nothing to do.
    try {
      _box = await Hive.openBox<String>(boxName); // Open existing or create.
    } catch (e) { // On open failure, attempt repair.
      dev.log('Error opening route cache box: $e. Attempting recreate.', name: 'RouteCache'); // Log error.
      try {
        await Hive.deleteBoxFromDisk(boxName); // Remove corrupted box.
        _box = await Hive.openBox<String>(boxName); // Recreate fresh box.
      } catch (e2) { // If recreation fails, rethrow to caller.
        dev.log('Failed to recreate route cache box: $e2', name: 'RouteCache'); // Report failure.
        rethrow; // Propagate fatal error.
      }
    }
  }

  /// Create a stable key from origin, destination, and mode. // Deterministic key creation.
  static String makeKey({ // Static method to build cache key.
    required LatLng origin,
    required LatLng destination,
    required String mode,
    String? transitVariant, // e.g., 'rail' // Optional modifier for transit.
  }) {
    // Round to ~5 decimal places (~1.1m) to improve cache hits for minor variations // Quantize inputs for stability.
    double r(double v) => double.parse(v.toStringAsFixed(5)); // Helper rounding function.
    final payload = jsonEncode({ // Construct a JSON object that captures inputs.
      'o': {'lat': r(origin.latitude), 'lng': r(origin.longitude)}, // Rounded origin.
      'd': {'lat': r(destination.latitude), 'lng': r(destination.longitude)}, // Rounded destination.
      'm': mode, // Mode value.
      if (transitVariant != null) 'tv': transitVariant, // Optional transit variant.
    });
    return payload; // simple JSON string key; could hash if desired // Using JSON itself as key.
  }

  static Future<RouteCacheEntry?> get({ // Retrieve if valid, else null.
    required LatLng origin,
    required LatLng destination,
    required String mode,
    String? transitVariant,
    Duration ttl = defaultTtl, // TTL override permitted.
    double originDeviationMeters = defaultOriginDeviationMeters, // Deviation threshold override.
  }) async {
    await _ensureOpen(); // Make sure box is ready.
    final key = makeKey( // Build key from current query.
      origin: origin,
      destination: destination,
      mode: mode,
      transitVariant: transitVariant,
    );
    final jsonStr = _box!.get(key); // Fetch raw JSON string.
    if (jsonStr == null) return null; // Cache miss.
    try {
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>; // Parse entry JSON.
      final entry = RouteCacheEntry.fromJson(decoded); // Hydrate into entry.

      // TTL check // Ensure recency.
      if (DateTime.now().difference(entry.timestamp) > ttl) { // If expired
        dev.log('RouteCache stale by TTL. Key evicted.', name: 'RouteCache'); // Log eviction.
        await _box!.delete(key); // Remove stale entry.
        return null; // Treat as miss.
      }

      // Origin deviation check // Ensure spatial relevance.
      final devMeters = Geolocator.distanceBetween( // Compute meters between current and cached origin.
        origin.latitude,
        origin.longitude,
        entry.origin.latitude,
        entry.origin.longitude,
      );
      if (devMeters >= originDeviationMeters) { // If outside tolerance, invalidate.
        dev.log('RouteCache invalid by origin deviation ${devMeters.toStringAsFixed(0)}m.', name: 'RouteCache'); // Report.
        await _box!.delete(key); // Evict entry.
        return null; // Miss.
      }

      return entry; // Fresh and spatially valid.
    } catch (e) { // Failed to parse or hydrate.
      dev.log('RouteCache decode failure: $e. Deleting key.', name: 'RouteCache'); // Log issue.
      await _box!.delete(key); // Remove corrupt entry.
      return null; // Treat as miss to avoid propagating errors.
    }
  }

  static Future<void> put(RouteCacheEntry entry) async { // Store/overwrite cache entry.
    await _ensureOpen(); // Ensure box is open.
    final key = entry.key; // Use entry key.
    final jsonStr = jsonEncode(entry.toJson()); // Serialize entry.
    await _box!.put(key, jsonStr); // Write to box (no per-write flush; P2 change).
  }

  static Future<void> clear() async { // Purge all entries.
    await _ensureOpen(); // Ensure box is open.
    await _box!.clear(); // Clear contents (no immediate flush; P2 change).
  }
}

// Post-block notes:
// - Keying uses rounded coordinates in a JSON string to improve hit rates across tiny origin/destination jitter.
// - TTL ensures routes refresh periodically; origin-deviation ensures relevance when user has moved significantly.
// - Box recreation path guards against storage corruption; logging aids telemetry.
// - Values are stored as JSON strings to keep the box schema simple and resilient.

// End-of-file summary:
// - API: makeKey/get/put/clear; storage in Hive `boxName` String box.
// - Validations: TTL freshness and origin proximity; safe miss behavior on any error.
// - Performance: O(1) typical; JSON encode/decode costs on access; removed per-write flush reduces sync I/O.
//   If durability needs tighten later, add an app-lifecycle or periodic flush rather than flushing every write.
