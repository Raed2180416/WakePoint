import 'dart:math';

import 'package:geowake2/all_india_stops.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Legacy dashboard-only GTFS/OSM stop selection logic.
///
/// This file is a snapshot of the dashboard's prior approach:
/// - iterate through allIndiaStops
/// - keep any stop within `radiusMeters` of ANY route polyline point
///
/// It is intentionally simple and intentionally expensive (O(N*M))
/// because it was only used on route updates.
///
/// NOTE: This is NOT the runtime route-stop logic used for alarms.
/// The runtime should broadcast its authoritative `TransitLegStops`.
class LegacyDashboardGtfsStopScan {
  static List<Map<String, dynamic>> stopsNearPath({
    required List<LatLng> pathPoints,
    double radiusMeters = 500,
  }) {
    final result = <Map<String, dynamic>>[];

    for (final stop in allIndiaStops) {
      final stopPos = LatLng(stop['lat'], stop['lng']);
      if (isStationNearPath(stopPos, pathPoints, radiusMeters)) {
        result.add(stop);
      }
    }

    return result;
  }

  static bool isStationNearPath(
    LatLng stop,
    List<LatLng> path,
    double radiusMeters,
  ) {
    const step = 1; // legacy: check every point
    for (int i = 0; i < path.length; i += step) {
      if (haversineDist(stop, path[i]) <= radiusMeters) {
        return true;
      }
    }
    return false;
  }

  static double haversineDist(LatLng p1, LatLng p2) {
    const earthRadiusMeters = 6371000.0;
    final dLat = _degToRad(p2.latitude - p1.latitude);
    final dLon = _degToRad(p2.longitude - p1.longitude);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_degToRad(p1.latitude)) *
            cos(_degToRad(p2.latitude)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusMeters * c;
  }

  static double _degToRad(double deg) => deg * (pi / 180.0);
}
