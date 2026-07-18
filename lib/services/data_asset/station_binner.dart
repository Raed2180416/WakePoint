// lib/services/data_asset/station_binner.dart
//
// GeoWake — station binning: THE ONLY PLACE IN THE MODULE THAT TOUCHES A
// COORDINATE (DATA_SURFACE_SPEC §2.3).
//
// A raw (lat,lng) is a FUNCTION-LOCAL parameter of [StationBinner.bin]. It is
// read to compute an opaque catalogue station token, then goes out of scope. It
// is never persisted, returned, or logged. Nothing coordinate-shaped leaves this
// function.
//
// Red-team fixes folded in:
//   R1 — NO geohash / coordinate-derived fallback. `stationId` is drawn ONLY
//        from the finite, enumerable transit-stop catalogue. If no catalogue
//        station is within [kStationSnapMaxRadiusMeters], bin() returns null:
//        unmatched = un-aggregatable = dropped = safe. A bounded, low-cardinality
//        token space is what makes k-anon suppression meaningful.
//   R2 — BOTH endpoints (boarding origin AND declared destination) are snapped
//        through this same function by the pipeline, so a precise destination POI
//        never survives as a re-identifying point.

import 'dart:math' as math;

import 'package:geowake2/all_india_stops.dart';

import 'data_asset_config.dart';
import 'od_cell.dart';

/// A snapped, coordinate-FREE trip endpoint. Carries only a catalogue station
/// token plus the coarse time bucket. **No coordinate field.**
class TripEndpoint {
  final String stationId;
  final int hourBin;
  final DayType dayType;

  const TripEndpoint({
    required this.stationId,
    required this.hourBin,
    required this.dayType,
  });

  @override
  String toString() => 'TripEndpoint($stationId,$hourBin,${dayType.name})';
}

/// Immutable, enumerable catalogue entry (id + position). The position is used
/// ONLY inside [StationBinner._nearestStationId] to measure distance; it is
/// never surfaced in any aggregate type.
class _CatalogueStation {
  final String id;
  final double lat;
  final double lng;
  const _CatalogueStation(this.id, this.lat, this.lng);
}

/// Snaps a raw fix to the nearest shipped transit-stop catalogue token.
class StationBinner {
  final List<_CatalogueStation> _catalogue;

  /// The set of every valid station token — used by tests to assert that every
  /// emitted `stationId` is a real catalogue member (never a coordinate-derived
  /// token that could round-trip back to a lat/lng).
  late final Set<String> catalogueIds =
      _catalogue.map((s) => s.id).toSet();

  StationBinner._(this._catalogue);

  /// Builds a binner over the shipped 875-station India catalogue
  /// (`all_india_stops.dart`). Rows with a non-numeric id/lat/lng are skipped.
  factory StationBinner.fromShippedCatalogue() {
    final stations = <_CatalogueStation>[];
    for (final row in allIndiaStops) {
      final id = row['id'];
      final lat = row['lat'];
      final lng = row['lng'];
      if (id is String && id.isNotEmpty && lat is num && lng is num) {
        stations.add(_CatalogueStation(id, lat.toDouble(), lng.toDouble()));
      }
    }
    return StationBinner._(stations);
  }

  /// Test/DI seam: build over an explicit catalogue of (id, lat, lng) triples.
  factory StationBinner.fromEntries(
      List<({String id, double lat, double lng})> entries) {
    return StationBinner._(
      entries.map((e) => _CatalogueStation(e.id, e.lat, e.lng)).toList(),
    );
  }

  /// Snap one raw fix to a catalogue token + coarse time bucket.
  ///
  /// Returns null when no catalogue station is within
  /// [kStationSnapMaxRadiusMeters] (R1: dropped = safe). `lat`/`lng` are
  /// read-only locals here and are neither returned nor stored.
  TripEndpoint? bin({
    required double lat,
    required double lng,
    required int epochMs,
    required int tzOffsetMinutes,
    double maxRadiusMeters = kStationSnapMaxRadiusMeters,
  }) {
    final stationId = _nearestStationId(lat, lng, maxRadiusMeters);
    if (stationId == null) return null; // un-aggregatable ⇒ dropped ⇒ safe.

    // Shift epoch into local wall-clock via the trip's own tz offset, then read
    // the hour and weekday. UTC construction keeps this deterministic and device
    // -timezone-independent (good for tests).
    final local = DateTime.fromMillisecondsSinceEpoch(
      epochMs + tzOffsetMinutes * 60000,
      isUtc: true,
    );
    final hourBin = local.hour; // 0–23
    // DateTime.weekday: Mon=1 … Sat=6, Sun=7.
    final dayType = (local.weekday == DateTime.saturday ||
            local.weekday == DateTime.sunday)
        ? DayType.weekend
        : DayType.weekday;

    return TripEndpoint(stationId: stationId, hourBin: hourBin, dayType: dayType);
  }

  /// Nearest catalogue station id within [maxRadiusMeters], else null. The only
  /// use of the coordinate.
  String? _nearestStationId(double lat, double lng, double maxRadiusMeters) {
    String? bestId;
    double bestMeters = double.infinity;
    for (final s in _catalogue) {
      final d = _haversineMeters(lat, lng, s.lat, s.lng);
      if (d < bestMeters) {
        bestMeters = d;
        bestId = s.id;
      }
    }
    if (bestId == null || bestMeters > maxRadiusMeters) return null;
    return bestId;
  }

  /// Great-circle distance in metres (self-contained; no geolocator dependency,
  /// so the binner is unit-testable off-device).
  static double _haversineMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const earthRadiusM = 6371000.0;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusM * c;
  }

  static double _toRad(double deg) => deg * (math.pi / 180.0);
}
