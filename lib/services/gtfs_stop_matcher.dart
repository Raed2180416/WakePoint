import 'package:geowake2/services/polyline_decoder.dart' show haversineDistance;
import 'package:google_maps_flutter/google_maps_flutter.dart';

class GtfsStop {
  final String id;
  final String name;
  final LatLng location;

  const GtfsStop({
    required this.id,
    required this.name,
    required this.location,
  });
}

class MatchedStop {
  final GtfsStop stop;

  /// Closest point on the polyline (snapped).
  final LatLng snapped;

  /// Distance from stop.location to snapped point (meters).
  final double distanceToPolylineMeters;

  /// Meters from polyline start to [snapped].
  final double metersAlongPolyline;

  const MatchedStop({
    required this.stop,
    required this.snapped,
    required this.distanceToPolylineMeters,
    required this.metersAlongPolyline,
  });
}

class GtfsStopMatcher {
  /// Match GTFS stops to a polyline corridor and order them along the route.
  ///
  /// Typical use:
  /// - [polyline] is your decoded Google Directions step polyline (or overview polyline)
  /// - [stops] are the city GTFS stops (or prefiltered candidate stops)
  /// - returns stops within [radiusMeters], ordered by progress along polyline
  static List<MatchedStop> matchStopsToPolyline({
    required List<LatLng> polyline,
    required List<GtfsStop> stops,
    double radiusMeters = 150.0,
    double dedupeMeters = 80.0,
  }) {
    if (polyline.length < 2 || stops.isEmpty) return const [];

    // Precompute cumulative distances at polyline vertices.
    final cumulative = <double>[0.0];
    for (int i = 0; i < polyline.length - 1; i++) {
      cumulative.add(
        cumulative.last + haversineDistance(polyline[i], polyline[i + 1]),
      );
    }

    final matched = <MatchedStop>[];

    for (final stop in stops) {
      final snap = _snapPointToPolyline(stop.location, polyline, cumulative);
      if (snap == null) continue;
      if (snap.distanceMeters <= radiusMeters) {
        matched.add(
          MatchedStop(
            stop: stop,
            snapped: snap.snapped,
            distanceToPolylineMeters: snap.distanceMeters,
            metersAlongPolyline: snap.metersAlong,
          ),
        );
      }
    }

    if (matched.isEmpty) return const [];

    matched.sort(
      (a, b) => a.metersAlongPolyline.compareTo(b.metersAlongPolyline),
    );

    // Dedupe platform/entrance duplicates: merge stops with very similar names that are close.
    final deduped = <MatchedStop>[];
    for (final m in matched) {
      if (deduped.isEmpty) {
        deduped.add(m);
        continue;
      }

      final last = deduped.last;
      final close =
          haversineDistance(last.stop.location, m.stop.location) <=
          dedupeMeters;
      final nameSame =
          _normalizeStopName(last.stop.name) == _normalizeStopName(m.stop.name);

      if (close && nameSame) {
        // Keep the one that is closer to the polyline.
        if (m.distanceToPolylineMeters < last.distanceToPolylineMeters) {
          deduped[deduped.length - 1] = m;
        }
      } else {
        deduped.add(m);
      }
    }

    return deduped;
  }

  static String _normalizeStopName(String raw) {
    var s = raw.toLowerCase();
    s = s.replaceAll(RegExp(r'\b(metro|station|railway|subway)\b'), '');
    s = s.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static _SnapResult? _snapPointToPolyline(
    LatLng point,
    List<LatLng> polyline,
    List<double> cumulativeMeters,
  ) {
    double bestDistance = double.infinity;
    LatLng bestSnapped = polyline.first;
    double bestMetersAlong = 0.0;

    for (int i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];

      final proj = _projectPointOnSegment(a, b, point);
      final snapped = proj.point;
      final dist = haversineDistance(point, snapped);

      if (dist < bestDistance) {
        bestDistance = dist;
        bestSnapped = snapped;
        bestMetersAlong = cumulativeMeters[i] + haversineDistance(a, snapped);
      }
    }

    return _SnapResult(
      snapped: bestSnapped,
      distanceMeters: bestDistance,
      metersAlong: bestMetersAlong,
    );
  }

  /// Projection in lat/lng space (good enough at metro scale). Clamp t to [0,1].
  static ({LatLng point, double t}) _projectPointOnSegment(
    LatLng a,
    LatLng b,
    LatLng p,
  ) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    final lenSq = dx * dx + dy * dy;

    if (lenSq < 1e-12) {
      return (point: a, t: 0.0);
    }

    double t =
        ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
        lenSq;
    t = t.clamp(0.0, 1.0);

    return (point: LatLng(a.latitude + t * dy, a.longitude + t * dx), t: t);
  }
}

class _SnapResult {
  final LatLng snapped;
  final double distanceMeters;
  final double metersAlong;

  const _SnapResult({
    required this.snapped,
    required this.distanceMeters,
    required this.metersAlong,
  });
}
