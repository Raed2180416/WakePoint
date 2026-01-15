/// Metadata associated with each route in a tracking session.
///
/// Stores information that needs to be preserved when switching between
/// routes in the queue, including visual styling, alarm state, and
/// original constraint settings.
library;

import 'package:flutter/material.dart';
import 'package:geowake2/services/reroute_constraints.dart';

/// Metadata for a single route in the route queue.
class RouteMetadata {
  /// When this route was created/registered
  final DateTime createdAt;

  /// Type of route: 'original', 'reroute', or 'alternative'
  final String routeType;

  /// Original constraints this route was created to satisfy
  final RerouteConstraints? constraints;

  /// Line colors for UI restoration (segment id -> color)
  final Map<String, Color> lineColors;

  /// Which alarm event indices have already fired for this route
  final Set<int> firedEventIndices;

  /// Which leg IDs have had alarms fired (e.g., preboarding warnings)
  final Set<String> firedLegIds;

  /// Whether destination alarm has fired for this route
  bool destinationAlarmFired;

  /// The route key this metadata is associated with
  final String routeKey;

  /// Number of stops remaining when this route was created (for stops mode)
  final int? initialStopsRemaining;

  /// Distance remaining when this route was created (for distance mode)
  final double? initialDistanceRemainingKm;

  /// Duration remaining when this route was created (for time mode)
  final Duration? initialDurationRemaining;

  RouteMetadata({
    required this.routeKey,
    required this.routeType,
    DateTime? createdAt,
    this.constraints,
    Map<String, Color>? lineColors,
    Set<int>? firedEventIndices,
    Set<String>? firedLegIds,
    this.destinationAlarmFired = false,
    this.initialStopsRemaining,
    this.initialDistanceRemainingKm,
    this.initialDurationRemaining,
  }) : createdAt = createdAt ?? DateTime.now(),
       lineColors = lineColors ?? {},
       firedEventIndices = firedEventIndices ?? {},
       firedLegIds = firedLegIds ?? {};

  /// Create metadata for an original route (first route in session).
  factory RouteMetadata.original({
    required String routeKey,
    RerouteConstraints? constraints,
    int? stopsRemaining,
    double? distanceRemainingKm,
    Duration? durationRemaining,
  }) {
    return RouteMetadata(
      routeKey: routeKey,
      routeType: 'original',
      constraints: constraints,
      initialStopsRemaining: stopsRemaining,
      initialDistanceRemainingKm: distanceRemainingKm,
      initialDurationRemaining: durationRemaining,
    );
  }

  /// Create metadata for a rerouted path.
  factory RouteMetadata.reroute({
    required String routeKey,
    required RerouteConstraints constraints,
    int? stopsRemaining,
    double? distanceRemainingKm,
    Duration? durationRemaining,
  }) {
    return RouteMetadata(
      routeKey: routeKey,
      routeType: 'reroute',
      constraints: constraints,
      initialStopsRemaining: stopsRemaining,
      initialDistanceRemainingKm: distanceRemainingKm,
      initialDurationRemaining: durationRemaining,
    );
  }

  /// Create metadata for an alternative route (from Google's alternatives).
  factory RouteMetadata.alternative({
    required String routeKey,
    RerouteConstraints? constraints,
    int? stopsRemaining,
    double? distanceRemainingKm,
    Duration? durationRemaining,
  }) {
    return RouteMetadata(
      routeKey: routeKey,
      routeType: 'alternative',
      constraints: constraints,
      initialStopsRemaining: stopsRemaining,
      initialDistanceRemainingKm: distanceRemainingKm,
      initialDurationRemaining: durationRemaining,
    );
  }

  /// Mark an event index as fired.
  void markEventFired(int index) {
    firedEventIndices.add(index);
  }

  /// Mark a leg ID as having its alarm fired.
  void markLegFired(String legId) {
    firedLegIds.add(legId);
  }

  /// Check if an event has already fired.
  bool hasEventFired(int index) => firedEventIndices.contains(index);

  /// Check if a leg has already had its alarm fired.
  bool hasLegFired(String legId) => firedLegIds.contains(legId);

  /// Add or update a line color.
  void setLineColor(String segmentId, Color color) {
    lineColors[segmentId] = color;
  }

  /// Copy alarm state from another metadata (for route migration).
  void migrateAlarmStateFrom(RouteMetadata other) {
    // Don't copy fired states - new route should start fresh
    // But we preserve the constraints
    destinationAlarmFired = false;
  }

  /// Create a copy with updated values.
  RouteMetadata copyWith({
    String? routeKey,
    String? routeType,
    DateTime? createdAt,
    RerouteConstraints? constraints,
    Map<String, Color>? lineColors,
    Set<int>? firedEventIndices,
    Set<String>? firedLegIds,
    bool? destinationAlarmFired,
    int? initialStopsRemaining,
    double? initialDistanceRemainingKm,
    Duration? initialDurationRemaining,
  }) {
    return RouteMetadata(
      routeKey: routeKey ?? this.routeKey,
      routeType: routeType ?? this.routeType,
      createdAt: createdAt ?? this.createdAt,
      constraints: constraints ?? this.constraints,
      lineColors: lineColors ?? Map.from(this.lineColors),
      firedEventIndices: firedEventIndices ?? Set.from(this.firedEventIndices),
      firedLegIds: firedLegIds ?? Set.from(this.firedLegIds),
      destinationAlarmFired:
          destinationAlarmFired ?? this.destinationAlarmFired,
      initialStopsRemaining:
          initialStopsRemaining ?? this.initialStopsRemaining,
      initialDistanceRemainingKm:
          initialDistanceRemainingKm ?? this.initialDistanceRemainingKm,
      initialDurationRemaining:
          initialDurationRemaining ?? this.initialDurationRemaining,
    );
  }

  /// Convert to JSON for persistence.
  Map<String, dynamic> toJson() {
    return {
      'routeKey': routeKey,
      'routeType': routeType,
      'createdAt': createdAt.toIso8601String(),
      'constraints':
          constraints != null
              ? {
                'alarmMode': constraints!.alarmMode,
                'alarmValue': constraints!.alarmValue,
                'transitMode': constraints!.transitMode,
                'maxTransfers': constraints!.maxTransfers,
              }
              : null,
      'lineColors': lineColors.map((k, v) => MapEntry(k, v.value)),
      'firedEventIndices': firedEventIndices.toList(),
      'firedLegIds': firedLegIds.toList(),
      'destinationAlarmFired': destinationAlarmFired,
      'initialStopsRemaining': initialStopsRemaining,
      'initialDistanceRemainingKm': initialDistanceRemainingKm,
      'initialDurationRemaining': initialDurationRemaining?.inSeconds,
    };
  }

  /// Create from JSON.
  factory RouteMetadata.fromJson(Map<String, dynamic> json) {
    final constraintsJson = json['constraints'] as Map<String, dynamic>?;
    RerouteConstraints? constraints;
    if (constraintsJson != null) {
      constraints = RerouteConstraints(
        alarmMode: constraintsJson['alarmMode'] as String,
        alarmValue: (constraintsJson['alarmValue'] as num).toDouble(),
        transitMode: constraintsJson['transitMode'] as bool,
        maxTransfers: constraintsJson['maxTransfers'] as int?,
      );
    }

    final lineColorsJson = json['lineColors'] as Map<String, dynamic>?;
    Map<String, Color>? lineColors;
    if (lineColorsJson != null) {
      lineColors = lineColorsJson.map((k, v) => MapEntry(k, Color(v as int)));
    }

    final durationSeconds = json['initialDurationRemaining'] as int?;

    return RouteMetadata(
      routeKey: json['routeKey'] as String,
      routeType: json['routeType'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      constraints: constraints,
      lineColors: lineColors,
      firedEventIndices:
          (json['firedEventIndices'] as List?)?.map((e) => e as int).toSet() ??
          {},
      firedLegIds:
          (json['firedLegIds'] as List?)?.map((e) => e as String).toSet() ?? {},
      destinationAlarmFired: json['destinationAlarmFired'] as bool? ?? false,
      initialStopsRemaining: json['initialStopsRemaining'] as int?,
      initialDistanceRemainingKm:
          (json['initialDistanceRemainingKm'] as num?)?.toDouble(),
      initialDurationRemaining:
          durationSeconds != null ? Duration(seconds: durationSeconds) : null,
    );
  }

  @override
  String toString() {
    return 'RouteMetadata(key=$routeKey, type=$routeType, firedEvents=${firedEventIndices.length}, destFired=$destinationAlarmFired)';
  }
}

/// Manages metadata for all routes in a session.
class RouteMetadataManager {
  final Map<String, RouteMetadata> _metadataByKey = {};

  /// Get metadata for a route key.
  RouteMetadata? get(String key) => _metadataByKey[key];

  /// Set metadata for a route key.
  void set(String key, RouteMetadata metadata) {
    _metadataByKey[key] = metadata;
  }

  /// Remove metadata for a route key.
  void remove(String key) {
    _metadataByKey.remove(key);
  }

  /// Clear all metadata.
  void clear() {
    _metadataByKey.clear();
  }

  /// Get all route keys with metadata.
  Iterable<String> get keys => _metadataByKey.keys;

  /// Check if metadata exists for a key.
  bool contains(String key) => _metadataByKey.containsKey(key);

  /// Get all metadata as a list.
  List<RouteMetadata> get all => _metadataByKey.values.toList();

  /// Migrate alarm state from one route to another.
  void migrateAlarmState(String fromKey, String toKey) {
    final from = _metadataByKey[fromKey];
    final to = _metadataByKey[toKey];
    if (from != null && to != null) {
      to.migrateAlarmStateFrom(from);
    }
  }

  /// Convert to JSON for persistence.
  Map<String, dynamic> toJson() {
    return _metadataByKey.map((k, v) => MapEntry(k, v.toJson()));
  }

  /// Restore from JSON.
  void fromJson(Map<String, dynamic> json) {
    _metadataByKey.clear();
    json.forEach((k, v) {
      _metadataByKey[k] = RouteMetadata.fromJson(v as Map<String, dynamic>);
    });
  }
}
