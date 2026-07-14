import 'dart:convert';

import 'package:geowake2/services/saved_routes_service.dart';

/// A route the rider has actually travelled, remembered automatically.
///
/// GeoWake is position-dependent — you board wherever you are, so a manually
/// pinned "Home"/"Work" destination is the wrong model. Instead we *learn* from
/// behaviour: every armed trip is recorded here. The last few show up as
/// one-tap "recent trips", and a trip armed repeatedly is promoted to a pinned
/// "frequent" route that survives beyond the rolling recents window. The point
/// is twofold — muscle-memory re-arming, and cutting Directions API calls by
/// letting the arming path reuse a cached route for a trip we've seen before.
///
/// Identity is a coarse [signature] (destination rounded to a ~100 m cell +
/// travel mode + metro line), NOT the exact alarm threshold — nudging the
/// slider from "3 stops" to "4 stops" is the same route, and must bump the
/// existing entry's counter rather than fork a new one.
class RouteMemory {
  /// Stable id — equal to [signature] so re-arming the same trip updates in
  /// place instead of creating a duplicate.
  final String id;

  /// Coarse dedup/identity key: `<latCell>,<lngCell>|<mode>|<metroLine>`.
  final String signature;

  final String destinationName;
  final double lat;
  final double lng;

  /// Google place id when the destination came from search; null for map taps.
  final String? placeId;

  /// One of 'distance' | 'time' | 'stops' — the LATEST config used for this
  /// trip (we keep the most recent so re-arm reflects how you last set it).
  final String alarmMode;
  final double alarmValue;

  final bool metroMode;
  final String? metroLine;

  /// How many times this trip has been armed. Crossing
  /// [RouteMemoryService.frequentThreshold] pins it as "frequent".
  final int timesTravelled;

  final DateTime firstSeenAt;
  final DateTime lastUsedAt;

  /// Origin used the last time this trip was armed. Lets the arming path decide
  /// whether a cached Directions result is still reusable (same start ⇒ no API
  /// call). Null for entries migrated from before this was tracked.
  final double? lastOriginLat;
  final double? lastOriginLng;

  const RouteMemory({
    required this.id,
    required this.signature,
    required this.destinationName,
    required this.lat,
    required this.lng,
    this.placeId,
    required this.alarmMode,
    required this.alarmValue,
    this.metroMode = false,
    this.metroLine,
    this.timesTravelled = 1,
    required this.firstSeenAt,
    required this.lastUsedAt,
    this.lastOriginLat,
    this.lastOriginLng,
  });

  /// True once this route has been travelled at/above the frequent threshold.
  bool get isFrequent => timesTravelled >= RouteMemoryService.frequentThreshold;

  /// Build the coarse identity signature for a trip. Destination is snapped to
  /// a ~100 m grid (3 decimal places) so tiny GPS/search jitter on the same
  /// place collapses to one entry.
  static String buildSignature({
    required double lat,
    required double lng,
    required bool metroMode,
    String? metroLine,
  }) {
    final latCell = lat.toStringAsFixed(3);
    final lngCell = lng.toStringAsFixed(3);
    final mode = metroMode ? 'metro' : 'road';
    final line = (metroLine == null || metroLine.trim().isEmpty)
        ? '-'
        : metroLine.trim().toLowerCase();
    return '$latCell,$lngCell|$mode|$line';
  }

  RouteMemory copyWith({
    String? destinationName,
    double? lat,
    double? lng,
    String? placeId,
    String? alarmMode,
    double? alarmValue,
    bool? metroMode,
    String? metroLine,
    int? timesTravelled,
    DateTime? lastUsedAt,
    double? lastOriginLat,
    double? lastOriginLng,
  }) {
    return RouteMemory(
      id: id,
      signature: signature,
      destinationName: destinationName ?? this.destinationName,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      placeId: placeId ?? this.placeId,
      alarmMode: alarmMode ?? this.alarmMode,
      alarmValue: alarmValue ?? this.alarmValue,
      metroMode: metroMode ?? this.metroMode,
      metroLine: metroLine ?? this.metroLine,
      timesTravelled: timesTravelled ?? this.timesTravelled,
      firstSeenAt: firstSeenAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      lastOriginLat: lastOriginLat ?? this.lastOriginLat,
      lastOriginLng: lastOriginLng ?? this.lastOriginLng,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'signature': signature,
        'destinationName': destinationName,
        'lat': lat,
        'lng': lng,
        'placeId': placeId,
        'alarmMode': alarmMode,
        'alarmValue': alarmValue,
        'metroMode': metroMode,
        'metroLine': metroLine,
        'timesTravelled': timesTravelled,
        'firstSeenAt': firstSeenAt.millisecondsSinceEpoch,
        'lastUsedAt': lastUsedAt.millisecondsSinceEpoch,
        'lastOriginLat': lastOriginLat,
        'lastOriginLng': lastOriginLng,
      };

  factory RouteMemory.fromMap(Map<String, dynamic> m) {
    double toD(dynamic v, [double fallback = 0]) =>
        v is num ? v.toDouble() : (double.tryParse('$v') ?? fallback);
    double? toDN(dynamic v) => v == null ? null : toD(v);
    int toI(dynamic v, [int fallback = 0]) =>
        v is num ? v.toInt() : (int.tryParse('$v') ?? fallback);
    final lat = toD(m['lat']);
    final lng = toD(m['lng']);
    final metroMode = m['metroMode'] == true;
    final metroLine = m['metroLine'] as String?;
    final sig = (m['signature'] as String?) ??
        buildSignature(
          lat: lat,
          lng: lng,
          metroMode: metroMode,
          metroLine: metroLine,
        );
    return RouteMemory(
      id: (m['id'] ?? sig).toString(),
      signature: sig,
      destinationName: (m['destinationName'] ?? '').toString(),
      lat: lat,
      lng: lng,
      placeId: m['placeId'] as String?,
      alarmMode: (m['alarmMode'] ?? 'distance').toString(),
      alarmValue: toD(m['alarmValue'], 5),
      metroMode: metroMode,
      metroLine: metroLine,
      timesTravelled: toI(m['timesTravelled'], 1).clamp(1, 1 << 30),
      firstSeenAt: DateTime.fromMillisecondsSinceEpoch(toI(m['firstSeenAt'])),
      lastUsedAt: DateTime.fromMillisecondsSinceEpoch(
        toI(m['lastUsedAt'], toI(m['firstSeenAt'])),
      ),
      lastOriginLat: toDN(m['lastOriginLat']),
      lastOriginLng: toDN(m['lastOriginLng']),
    );
  }

  String toJson() => jsonEncode(toMap());

  factory RouteMemory.fromJson(String s) =>
      RouteMemory.fromMap(jsonDecode(s) as Map<String, dynamic>);
}
