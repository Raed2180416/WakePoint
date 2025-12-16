import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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

  static Future<void> saveSnapshot(TrackingSnapshot snapshot) async {
    final prefs = await _prefs();
    await prefs.setString(_snapshotKey, jsonEncode(snapshot.toJson()));
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

  static Future<void> setAlarmFired(bool fired) async {
    final prefs = await _prefs();
    await prefs.setBool(_alarmFiredKey, fired);
  }

  static Future<bool> isAlarmFired() async {
    final prefs = await _prefs();
    return prefs.getBool(_alarmFiredKey) ?? false;
  }
}
