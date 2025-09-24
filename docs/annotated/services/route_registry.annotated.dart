// Annotated copy of lib/services/route_registry.dart
// Purpose: Explain route entry bookkeeping, bounds/length safety, and candidate selection.

import 'dart:math' show min, max, cos; // Min/max for bounds; cos for meters-per-degree longitude
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng and LatLngBounds
import 'package:geolocator/geolocator.dart'; // Geodesic distances

class RouteEntry { // Represents a registered route with derived metadata and session fields
  final String key; // typically RouteCache key
  final String mode; // 'driving' | 'transit'
  final String destinationName; // Display name for UX
  final List<LatLng> points; // simplified polyline vertices
  final DateTime createdAt; // When inserted
  DateTime lastUsed; // Recently accessed time (for LRU)
  int usageCount; // Access count (for tie-breaks/telemetry)
  final LatLngBounds bbox; // Bounding box for quick spatial checks
  // Cached geodesic length for the full route polyline
  final double lengthMeters; // Sum of segment distances
  // Session-only
  int? lastSnapIndex; // Last segment index used during snapping
  double? lastProgressMeters; // Cumulative progress along polyline

  RouteEntry({ // Constructs and derives bbox/length
    required this.key,
    required this.mode,
    required this.destinationName,
    required this.points,
    DateTime? createdAt,
    DateTime? lastUsed,
    int usageCount = 0,
    int? lastSnapIndex,
    double? lastProgressMeters,
  })  : createdAt = createdAt ?? DateTime.now(),
        lastUsed = lastUsed ?? DateTime.now(),
        usageCount = usageCount,
        bbox = _computeBounds(points), // Safe bounds computation with empty guard + proper ordering
        lengthMeters = _computeLength(points), // Precompute length once
        lastSnapIndex = lastSnapIndex,
        lastProgressMeters = lastProgressMeters;

  static LatLngBounds _computeBounds(List<LatLng> pts) { // Compute SW/NE bounds safely
    if (pts.isEmpty) {
      // Safe default: zero-area bounds at origin
      return LatLngBounds(
        southwest: const LatLng(0.0, 0.0),
        northeast: const LatLng(0.0, 0.0),
      );
    }
    double minLat = double.infinity, minLng = double.infinity;
    double maxLat = -double.infinity, maxLng = -double.infinity;
    for (final p in pts) {
      minLat = min(minLat, p.latitude);
      minLng = min(minLng, p.longitude);
      maxLat = max(maxLat, p.latitude);
      maxLng = max(maxLng, p.longitude);
    }
    // Ensure ordering respects southwest <= northeast constraints
    final swLat = min(minLat, maxLat);
    final neLat = max(minLat, maxLat);
    final swLng = min(minLng, maxLng);
    final neLng = max(minLng, maxLng);
    return LatLngBounds(
      southwest: LatLng(swLat, swLng),
      northeast: LatLng(neLat, neLng),
    );
  }

  bool isNear(LatLng p, double radiusMeters) { // Quick spatial filter using padded bbox then center distance
    // Quick bbox prefilter with padding by approximate degrees.
    const metersPerDegLat = 110540.0;
    final latPad = radiusMeters / metersPerDegLat;
    final midLat = (bbox.southwest.latitude + bbox.northeast.latitude) * 0.5;
    final metersPerDegLng = 111320.0 * (cos(midLat * 3.141592653589793 / 180.0)).abs();
    final lngPad = radiusMeters / metersPerDegLng;
    final sw = LatLng(bbox.southwest.latitude - latPad, bbox.southwest.longitude - lngPad);
    final ne = LatLng(bbox.northeast.latitude + latPad, bbox.northeast.longitude + lngPad);
    if (p.latitude < sw.latitude || p.latitude > ne.latitude || p.longitude < sw.longitude || p.longitude > ne.longitude) {
      return false; // Outside padded bbox
    }
    // Fallback precise distance to bbox center
    final c = LatLng((bbox.southwest.latitude + bbox.northeast.latitude) / 2,
        (bbox.southwest.longitude + bbox.northeast.longitude) / 2);
    final d = Geolocator.distanceBetween(p.latitude, p.longitude, c.latitude, c.longitude);
    return d <= radiusMeters * 2.5; // generous since bbox check already passed
  }

  static double _computeLength(List<LatLng> pts) { // Geodesic length sum
    if (pts.length < 2) return 0.0;
    double sum = 0.0;
    for (var i = 1; i < pts.length; i++) {
      sum += Geolocator.distanceBetween(
        pts[i - 1].latitude,
        pts[i - 1].longitude,
        pts[i].latitude,
        pts[i].longitude,
      );
    }
    return sum;
  }
}

class RouteRegistry { // LRU map of route entries + helpers for candidate selection
  RouteRegistry({this.capacity = 8}); // Keep a small working set
  final int capacity; // Max entries retained
  final Map<String, RouteEntry> _entries = {}; // Keyed by route key

  List<RouteEntry> get entries => _entries.values.toList()..sort((a, b) => b.lastUsed.compareTo(a.lastUsed)); // Sorted by recency

  void upsert(RouteEntry entry) { // Insert or update existing entry; refresh recency
    if (_entries.containsKey(entry.key)) {
      final existing = _entries[entry.key]!;
      existing.lastUsed = DateTime.now();
      existing.usageCount += 1;
      existing.lastSnapIndex = entry.lastSnapIndex ?? existing.lastSnapIndex;
      existing.lastProgressMeters = entry.lastProgressMeters ?? existing.lastProgressMeters;
    } else {
      _entries[entry.key] = entry;
      _evictIfNeeded(); // Enforce capacity
    }
  }

  void markUsed(String key) { // Touch an entry (recency + count)
    final e = _entries[key];
    if (e != null) {
      e.lastUsed = DateTime.now();
      e.usageCount += 1;
    }
  }

  void updateSessionState(String key, {int? lastSnapIndex, double? lastProgressMeters}) { // Update session fields
    final e = _entries[key];
    if (e != null) {
      if (lastSnapIndex != null) e.lastSnapIndex = lastSnapIndex;
      if (lastProgressMeters != null) e.lastProgressMeters = lastProgressMeters;
    }
  }

  void _evictIfNeeded() { // Remove least-recently-used beyond capacity
    if (_entries.length <= capacity) return;
    final sorted = entries; // sorted by lastUsed desc
    final toKeep = sorted.take(capacity).map((e) => e.key).toSet();
    final toRemove = _entries.keys.where((k) => !toKeep.contains(k)).toList();
    for (final k in toRemove) {
      _entries.remove(k);
    }
  }

  List<RouteEntry> candidatesNear(LatLng p, {double radiusMeters = 1200, int maxCandidates = 3}) { // Likely routes near a point
    final list = <RouteEntry>[];
    for (final e in entries) {
      if (e.isNear(p, radiusMeters)) list.add(e);
      if (list.length >= maxCandidates) break;
    }
    return list;
  }
}

/* File summary: RouteRegistry safely computes bounds and length for each route and tracks session progress/snap hints.
   It provides quick candidate selection near a point to support local switching and progress estimation in notifications. */
