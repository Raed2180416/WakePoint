import 'dart:convert';
import 'dart:developer' as dev;

import 'package:geowake2/services/transfer_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

const bool _isFlutterTest = bool.fromEnvironment('FLUTTER_TEST');

/// Encapsulates the persisted state required to resume or manage an active
/// tracking session. This lives in SharedPreferences so it can be shared across
/// both the Flutter and native Android layers.
class TrackingSnapshot {
  const TrackingSnapshot({
    required this.destinationName,
    required this.destinationLat,
    required this.destinationLng,
    required this.alarmMode,
    required this.alarmValue,
    required this.metroMode,
    required this.userLat,
    required this.userLng,
    required this.createdAt,
    this.directions,
  });

  final String destinationName;
  final double destinationLat;
  final double destinationLng;
  final String alarmMode;
  final double alarmValue;
  final bool metroMode;
  final double userLat;
  final double userLng;
  final DateTime createdAt;
  final Map<String, dynamic>? directions;

  Map<String, dynamic> toJson() => {
    'destinationName': destinationName,
    'destinationLat': destinationLat,
    'destinationLng': destinationLng,
    'alarmMode': alarmMode,
    'alarmValue': alarmValue,
    'metroMode': metroMode,
    'userLat': userLat,
    'userLng': userLng,
    'createdAt': createdAt.toIso8601String(),
    if (directions != null) 'directions': directions,
  };

  static TrackingSnapshot? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      return TrackingSnapshot(
        destinationName: json['destinationName'] as String? ?? 'Destination',
        destinationLat: (json['destinationLat'] as num).toDouble(),
        destinationLng: (json['destinationLng'] as num).toDouble(),
        alarmMode: json['alarmMode'] as String? ?? 'distance',
        alarmValue: (json['alarmValue'] as num).toDouble(),
        metroMode: json['metroMode'] as bool? ?? false,
        userLat: (json['userLat'] as num).toDouble(),
        userLng: (json['userLng'] as num).toDouble(),
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        directions:
            json['directions'] == null
                ? null
                : Map<String, dynamic>.from(
                  json['directions'] as Map<String, dynamic>,
                ),
      );
    } catch (_) {
      return null;
    }
  }
}

// Top-level function for compute() - minimizes AND encodes
String _encodeSnapshotInBackground(Map<String, dynamic> json) {
  // Extract directions if present to minimize
  if (json.containsKey('directions') && json['directions'] != null) {
    json['directions'] = _minimizeDirectionsForSnapshot(
      json['directions'] as Map<String, dynamic>,
    );
  }
  return jsonEncode(json);
}

Map<String, dynamic>? _minimizeDirectionsForSnapshot(
  Map<String, dynamic>? directions,
) {
  if (directions == null) return null;
  // ... (rest of existing minimization logic)
  try {
    final routes = (directions['routes'] as List?) ?? const [];
    if (routes.isEmpty) return null;
    final firstRoute = routes.first as Map;
    final legs = (firstRoute['legs'] as List?) ?? const [];

    Map<String, dynamic> sanitizeLocation(dynamic loc) {
      if (loc is! Map) return const {};
      final lat = loc['lat'];
      final lng = loc['lng'];
      return {if (lat is num) 'lat': lat, if (lng is num) 'lng': lng};
    }

    Map<String, dynamic> sanitizePolyline(dynamic poly) {
      if (poly is Map && poly['points'] is String) {
        return {'points': poly['points'] as String};
      }
      return const {};
    }

    Map<String, dynamic> sanitizeDurationOrDistance(dynamic dd) {
      if (dd is! Map) return const {};
      final value = dd['value'];
      return {if (value is num) 'value': value};
    }

    Map<String, dynamic> sanitizeTransitDetails(dynamic td) {
      if (td is! Map) return const {};

      Map<String, dynamic>? sanitizeStop(dynamic stop) {
        if (stop is! Map) return null;
        final name = stop['name'];
        final loc = stop['location'];
        return {
          if (name is String) 'name': name,
          if (loc is Map) 'location': sanitizeLocation(loc),
        };
      }

      Map<String, dynamic>? sanitizeLine(dynamic line) {
        if (line is! Map) return null;
        final shortName = line['short_name'];
        final name = line['name'];
        final id = line['id'];
        final vehicle = line['vehicle'];
        Map<String, dynamic>? vehicleOut;
        if (vehicle is Map) {
          final type = vehicle['type'];
          vehicleOut = {if (type is String) 'type': type};
        }
        return {
          if (shortName is String) 'short_name': shortName,
          if (name is String) 'name': name,
          if (id != null) 'id': id,
          if (vehicleOut != null && vehicleOut.isNotEmpty)
            'vehicle': vehicleOut,
        };
      }

      final numStops = td['num_stops'];
      final departureStop = sanitizeStop(td['departure_stop']);
      final arrivalStop = sanitizeStop(td['arrival_stop']);
      final lineOut = sanitizeLine(td['line']);

      return {
        if (numStops is num) 'num_stops': numStops,
        if (departureStop != null) 'departure_stop': departureStop,
        if (arrivalStop != null) 'arrival_stop': arrivalStop,
        if (lineOut != null) 'line': lineOut,
      };
    }

    final legsOut = <Map<String, dynamic>>[];
    for (final leg in legs) {
      if (leg is! Map) continue;
      final steps = (leg['steps'] as List?) ?? const [];
      final stepsOut = <Map<String, dynamic>>[];
      for (final s in steps) {
        if (s is! Map) continue;
        final travelMode = s['travel_mode'];
        final distance = s['distance'];
        final duration = s['duration'];
        final polyline = s['polyline'];
        final startLoc = s['start_location'];
        final endLoc = s['end_location'];
        final transitDetails = s['transit_details'];
        final stepOut = <String, dynamic>{
          if (travelMode is String) 'travel_mode': travelMode,
          if (distance is Map) 'distance': sanitizeDurationOrDistance(distance),
          if (duration is Map) 'duration': sanitizeDurationOrDistance(duration),
          if (polyline is Map) 'polyline': sanitizePolyline(polyline),
          if (startLoc is Map) 'start_location': sanitizeLocation(startLoc),
          if (endLoc is Map) 'end_location': sanitizeLocation(endLoc),
        };
        final tdOut = sanitizeTransitDetails(transitDetails);
        if (tdOut.isNotEmpty) {
          stepOut['transit_details'] = tdOut;
        }
        stepsOut.add(stepOut);
      }
      legsOut.add({
        'steps': stepsOut,
        if (leg['duration'] is Map)
          'duration': sanitizeDurationOrDistance(leg['duration']),
        if (leg['distance'] is Map)
          'distance': sanitizeDurationOrDistance(leg['distance']),
      });
    }

    final overview = firstRoute['overview_polyline'];
    final simplified = firstRoute['simplified_polyline'];

    final routeOut = <String, dynamic>{
      if (overview is Map) 'overview_polyline': sanitizePolyline(overview),
      if (simplified is String) 'simplified_polyline': simplified,
      'legs': legsOut,
    };

    return {
      if (directions['status'] is String) 'status': directions['status'],
      'routes': [routeOut],
    };
  } catch (e) {
    dev.log(
      'Failed to minimize directions for snapshot: $e',
      name: 'TrackingStateStore',
    );
    return directions; // fall back to original if minimization fails
  }
}

class TrackingProgressPayload {
  const TrackingProgressPayload({
    required this.title,
    required this.subtitle,
    required this.progress,
    required this.isTracking,
  });

  final String title;
  final String subtitle;
  final double progress;
  final bool isTracking;

  Map<String, dynamic> toJson() => {
    'title': title,
    'subtitle': subtitle,
    'progress': progress,
    'isTracking': isTracking,
  };

  static TrackingProgressPayload? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      return TrackingProgressPayload(
        title: json['title'] as String? ?? 'GeoWake',
        subtitle: json['subtitle'] as String? ?? '',
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        isTracking: json['isTracking'] as bool? ?? true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Centralized helper for reading/writing all tracking-related keys.
class TrackingStateStore {
  static const _activeKey = 'tracking_active_v1';
  static const _snapshotKey = 'tracking_snapshot_v1';
  static const _notificationsMutedKey = 'tracking_notifications_muted_v1';
  static const _progressPayloadKey = 'gw_progress_payload_v1';
  static const _pausedKey = 'tracking_paused_v1';
  static const _preboardingEnabledKey = 'gw_preboarding_enabled_v1';
  static const _destinationOnlyMetroTimeKey =
      'gw_destination_only_metro_time_v1';

  static SharedPreferences? _cachedPrefs;

  /// Test helper: SharedPreferences is cached for performance, but in unit
  /// tests we frequently swap mock initial values. Resetting avoids cross-test
  /// contamination.
  static void resetCacheForTests() {
    _cachedPrefs = null;
  }

  static Future<SharedPreferences> _prefs() async {
    if (_cachedPrefs != null) {
      return _cachedPrefs!;
    }

    _cachedPrefs = await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  static Future<void> setActive(bool value) async {
    final prefs = await _prefs();
    await prefs.setBool(_activeKey, value);
  }

  static Future<bool> isActive() async {
    final prefs = await _prefs();
    return prefs.getBool(_activeKey) ?? false;
  }

  static Future<void> setPaused(bool paused) async {
    final prefs = await _prefs();
    await prefs.setBool(_pausedKey, paused);
  }

  static Future<bool> isPaused() async {
    final prefs = await _prefs();
    return prefs.getBool(_pausedKey) ?? false;
  }

  /// When true (only applicable to metro + time mode), suppress all
  /// intermediate/leg alarms and fire only the final destination alarm.
  static Future<void> setDestinationOnlyMetroTimeEnabled(bool enabled) async {
    final prefs = await _prefs();
    await prefs.setBool(_destinationOnlyMetroTimeKey, enabled);
  }

  static Future<bool> destinationOnlyMetroTimeEnabled() async {
    final prefs = await _prefs();
    await prefs.reload();
    return prefs.getBool(_destinationOnlyMetroTimeKey) ?? false;
  }

  static bool destinationOnlyMetroTimeEnabledSync() {
    return _cachedPrefs?.getBool(_destinationOnlyMetroTimeKey) ?? false;
  }

  static Future<void> saveSnapshot(TrackingSnapshot snapshot) async {
    final prefs = await _prefs();
    try {
      final json = Map<String, dynamic>.from(snapshot.toJson());

      // Background components refresh the snapshot frequently with updated
      // userLat/userLng but may not have directions attached. Do not overwrite
      // an existing directions payload with null.
      Map<String, dynamic>? directionsToPersist = snapshot.directions;
      if (directionsToPersist == null) {
        try {
          final existingRaw = prefs.getString(_snapshotKey);
          if (existingRaw != null && existingRaw.isNotEmpty) {
            final existing = TrackingSnapshot.fromJson(
              Map<String, dynamic>.from(
                jsonDecode(existingRaw) as Map<String, dynamic>,
              ),
            );
            if (existing?.directions != null) {
              directionsToPersist = existing!.directions;
            }
          }
        } catch (_) {
          // Best-effort merge only.
        }
      }

      if (directionsToPersist != null) {
        json['directions'] = directionsToPersist;
      }

      // Offload heavy processing + verification to isolate
      final encodedString =
          _isFlutterTest
              ? _encodeSnapshotInBackground(json)
              : await compute(_encodeSnapshotInBackground, json);
      final ok = await prefs.setString(_snapshotKey, encodedString);
      if (!ok) {
        dev.log(
          'SharedPreferences refused snapshot write',
          name: 'TrackingStateStore',
        );
      }
    } catch (e) {
      // Most common failure mode here is snapshot payload too large.
      dev.log(
        'Failed to persist tracking snapshot: $e',
        name: 'TrackingStateStore',
      );
      rethrow;
    }
  }

  static Future<TrackingSnapshot?> loadSnapshot() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_snapshotKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return TrackingSnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map<String, dynamic>),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearSnapshot() async {
    final prefs = await _prefs();
    await prefs.remove(_snapshotKey);
  }

  static Future<void> setNotificationsMuted(bool muted) async {
    final prefs = await _prefs();
    if (muted) {
      await prefs.setBool(_notificationsMutedKey, true);
    } else {
      await prefs.remove(_notificationsMutedKey);
    }
  }

  static Future<bool> notificationsMuted() async {
    final prefs = await _prefs();
    await prefs.reload(); // Ensure freshness across isolates
    return prefs.getBool(_notificationsMutedKey) ?? false;
  }

  /// Controls whether preboarding alarms are allowed to fire.
  ///
  /// Default: enabled.
  static Future<void> setPreboardingEnabled(bool enabled) async {
    final prefs = await _prefs();
    await prefs.setBool(_preboardingEnabledKey, enabled);
  }

  /// Async getter (ensures SharedPreferences is initialized).
  /// Default: enabled.
  static Future<bool> preboardingEnabled() async {
    final prefs = await _prefs();
    await prefs.reload(); // Ensure freshness across isolates
    return prefs.getBool(_preboardingEnabledKey) ?? true;
  }

  /// Sync getter for hot paths. If prefs aren't initialized yet, defaults to enabled.
  static bool preboardingEnabledSync() {
    return _cachedPrefs?.getBool(_preboardingEnabledKey) ?? true;
  }

  static Future<void> saveProgressPayload(
    TrackingProgressPayload payload,
  ) async {
    final prefs = await _prefs();
    await prefs.setString(_progressPayloadKey, jsonEncode(payload.toJson()));
  }

  static Future<TrackingProgressPayload?> loadProgressPayload() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_progressPayloadKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return TrackingProgressPayload.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map<String, dynamic>),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearProgressPayload() async {
    final prefs = await _prefs();
    await prefs.remove(_progressPayloadKey);
  }

  static const _alarmFiredKey = 'tracking_alarm_fired_v1';
  // Version 4: Fixed meter domain mismatch - always use fresh extractTransitLegStops
  // Version 3: Fixed haversine distance calculation in TransferUtils
  // Version 2: Transit stop enrichment was refined, but TransferUtils._computeProgressAlongPolyline
  // still used Taylor series, causing incorrect stopMeters values
  static const _transitLegStopsKey =
      'tracking_transit_leg_stops_v5'; // Bumped for OSM-only mode

  static Future<void> setAlarmFired(bool fired) async {
    final prefs = await _prefs();
    await prefs.setBool(_alarmFiredKey, fired);
  }

  static Future<bool> isAlarmFired() async {
    final prefs = await _prefs();
    return prefs.getBool(_alarmFiredKey) ?? false;
  }

  /// Persist transit leg stops for session resume.
  /// These contain actual stop positions from stop matching (when available)
  /// and are keyed by route key for multi-route sessions.
  static Future<void> saveTransitLegStops(
    String routeKey,
    List<TransitLegStops> legs,
  ) async {
    final prefs = await _prefs();
    final stored = await _loadAllTransitLegStops(prefs);
    stored[routeKey] = legs.map((l) => l.toJson()).toList();
    await prefs.setString(_transitLegStopsKey, jsonEncode(stored));
  }

  /// Load transit leg stops for a specific route key.
  static Future<List<TransitLegStops>?> loadTransitLegStops(
    String routeKey,
  ) async {
    final prefs = await _prefs();
    final stored = await _loadAllTransitLegStops(prefs);
    final data = stored[routeKey];
    if (data == null) return null;
    try {
      return (data as List)
          .map((j) => TransitLegStops.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Clear transit leg stops for a specific route key.
  static Future<void> clearTransitLegStops(String routeKey) async {
    final prefs = await _prefs();
    final stored = await _loadAllTransitLegStops(prefs);
    stored.remove(routeKey);
    if (stored.isEmpty) {
      await prefs.remove(_transitLegStopsKey);
    } else {
      await prefs.setString(_transitLegStopsKey, jsonEncode(stored));
    }
  }

  /// Clear all transit leg stops.
  static Future<void> clearAllTransitLegStops() async {
    final prefs = await _prefs();
    await prefs.remove(_transitLegStopsKey);
  }

  static Future<Map<String, dynamic>> _loadAllTransitLegStops(
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString(_transitLegStopsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return {};
    }
  }
}
