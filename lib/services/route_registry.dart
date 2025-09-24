import 'dart:math' show min, max, cos;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

class RouteEntry {
  final String key; // typically RouteCache key
  final String mode; // 'driving' | 'transit'
  final String destinationName;
  final List<LatLng> points; // simplified polyline
  final DateTime createdAt;
  DateTime lastUsed;
  int usageCount;
  final LatLngBounds bbox;
  // Cached geodesic length for the full route polyline
  final double lengthMeters;
  // Session-only
  int? lastSnapIndex;
  double? lastProgressMeters;

  RouteEntry({
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
        bbox = _computeBounds(points),
        lengthMeters = _computeLength(points),
        lastSnapIndex = lastSnapIndex,
        lastProgressMeters = lastProgressMeters;

  static LatLngBounds _computeBounds(List<LatLng> pts) {
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

  bool isNear(LatLng p, double radiusMeters) {
    // Quick bbox prefilter with padding by approximate degrees.
    const metersPerDegLat = 110540.0;
    final latPad = radiusMeters / metersPerDegLat;
    final midLat = (bbox.southwest.latitude + bbox.northeast.latitude) * 0.5;
    final metersPerDegLng = 111320.0 * (cos(midLat * 3.141592653589793 / 180.0)).abs();
    final lngPad = radiusMeters / metersPerDegLng;
    final sw = LatLng(bbox.southwest.latitude - latPad, bbox.southwest.longitude - lngPad);
    final ne = LatLng(bbox.northeast.latitude + latPad, bbox.northeast.longitude + lngPad);
    if (p.latitude < sw.latitude || p.latitude > ne.latitude || p.longitude < sw.longitude || p.longitude > ne.longitude) {
      return false;
    }
    // Fallback precise distance to bbox center
    final c = LatLng((bbox.southwest.latitude + bbox.northeast.latitude) / 2,
        (bbox.southwest.longitude + bbox.northeast.longitude) / 2);
    final d = Geolocator.distanceBetween(p.latitude, p.longitude, c.latitude, c.longitude);
    return d <= radiusMeters * 2.5; // generous since bbox check already passed
  }

  static double _computeLength(List<LatLng> pts) {
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

class RouteRegistry {
  RouteRegistry({this.capacity = 8});
  final int capacity;
  final Map<String, RouteEntry> _entries = {};

  List<RouteEntry> get entries => _entries.values.toList()..sort((a, b) => b.lastUsed.compareTo(a.lastUsed));

  void upsert(RouteEntry entry) {
    if (_entries.containsKey(entry.key)) {
      final existing = _entries[entry.key]!;
      existing.lastUsed = DateTime.now();
      existing.usageCount += 1;
      existing.lastSnapIndex = entry.lastSnapIndex ?? existing.lastSnapIndex;
      existing.lastProgressMeters = entry.lastProgressMeters ?? existing.lastProgressMeters;
    } else {
      _entries[entry.key] = entry;
      _evictIfNeeded();
    }
  }

  void markUsed(String key) {
    final e = _entries[key];
    if (e != null) {
      e.lastUsed = DateTime.now();
      e.usageCount += 1;
    }
  }

  void updateSessionState(String key, {int? lastSnapIndex, double? lastProgressMeters}) {
    final e = _entries[key];
    if (e != null) {
      if (lastSnapIndex != null) e.lastSnapIndex = lastSnapIndex;
      if (lastProgressMeters != null) e.lastProgressMeters = lastProgressMeters;
    }
  }

  void _evictIfNeeded() {
    if (_entries.length <= capacity) return;
    final sorted = entries; // sorted by lastUsed desc
    final toKeep = sorted.take(capacity).map((e) => e.key).toSet();
    final toRemove = _entries.keys.where((k) => !toKeep.contains(k)).toList();
    for (final k in toRemove) {
      _entries.remove(k);
    }
  }

  List<RouteEntry> candidatesNear(LatLng p, {double radiusMeters = 1200, int maxCandidates = 3}) {
    final list = <RouteEntry>[];
    for (final e in entries) {
      if (e.isNear(p, radiusMeters)) list.add(e);
      if (list.length >= maxCandidates) break;
    }
    return list;
  }
}
