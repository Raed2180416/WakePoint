import 'dart:developer' as dev;
import 'dart:math' as math;
import 'package:geowake2/services/stop_matcher.dart';
import 'package:geowake2/services/polyline_decoder.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geowake2/all_india_stops.dart'; // Source of Truth Fallback
import 'package:geowake2/data/metro_line_sequences.dart'; // hardcoded ordered per-line sequences

/// Represents a transit leg's stop positions along the route.
/// Used for accurate "N stops prior" alarm tracking.
class TransitLegStops {
  /// Cumulative meters at the start of this transit leg.
  final double legStartMeters;

  /// Cumulative meters at the end of this transit leg.
  final double legEndMeters;

  /// Number of intermediate stops on this leg (from transit_details.num_stops).
  final int numStops;

  /// Estimated positions of each intermediate stop along the polyline.
  /// Length equals [numStops].
  final List<LatLng> stopPositions;

  /// Cumulative meters from route start to each stop position.
  /// Length equals [numStops].
  final List<double> stopMeters;

  /// Line name/ID for this transit leg.
  final String? lineName;

  /// Whether stop positions are from actual data (stop asset match) vs estimated (uniform).
  /// True = stop positions snapped from stop assets (OSM) to the transit-step polyline.
  /// False = uniformly distributed estimates (legacy behavior).
  final bool isActualPositions;

  /// Whether this leg is a Metro/Rapid transit leg (vs Bus/Other).
  final bool isMetro;

  /// Names of each stop (from stop assets).
  /// Empty list if not available (legacy uniform estimation).
  final List<String> stopNames;

  /// G16: confidence in the intermediate stop COUNT (numStops).
  /// 1.0 = OSM and Google agree (or trusted OSM-derived count).
  /// <1.0 = OSM/Google diverged beyond tolerance; the count came from the
  /// conservative Google API fallback and downstream alarm logic should treat
  /// "N stops before" as low-confidence (prefer firing early).
  final double stopCountConfidence;

  String get legId {
    try {
      // 1. Metro Stability: Use Stop Names (Topology) if available
      if (isMetro && stopNames.isNotEmpty) {
        final first = stopNames.first.trim();
        final last = stopNames.last.trim();
        return '${lineName ?? "Metro"}_${first}_$last';
      }

      // 2. Named Walk Stability: If lineName is semantically unique (e.g. "Walk to Station"), use it directly.
      if (lineName != null && lineName!.startsWith('Walk to ')) {
        // IMPORTANT: Don't key dedupe logic off a dynamic station name.
        // Some routes can cause the inferred station name to change (e.g., multiple nearby stops),
        // which would otherwise re-trigger "one alarm per leg" alarms like preBoarding.
        final stableId =
            'Walk_${legStartMeters.toStringAsFixed(0)}_${legEndMeters.toStringAsFixed(0)}';
        print(
          '🔑 legId: Using stable Walk meters ID: $stableId (lineName=$lineName)',
        );
        return stableId;
      }

      String snap(double v) => v.toStringAsFixed(3);

      if (stopPositions.isNotEmpty) {
        final start = stopPositions.first;
        final end = stopPositions.last;
        final id =
            '${lineName ?? "Leg"}_${snap(start.latitude)},${snap(start.longitude)}_${snap(end.latitude)},${snap(end.longitude)}';
        // print('🔑 legId: Using geometry-based ID: $id'); // Noisy
        return id;
      } else {
        print('⚠️ legId: No stopPositions for $lineName (isMetro=$isMetro)');
      }

      // 4. Last Resort: Meters (Legacy)
      final fallbackId =
          '${lineName ?? "Unamed"}_${legStartMeters.toStringAsFixed(0)}_${legEndMeters.toStringAsFixed(0)}';
      print(
        '⚠️ legId: Using FALLBACK meters-based ID: $fallbackId (lineName=$lineName, stopPositions.length=${stopPositions.length})',
      );
      return fallbackId;
    } catch (e, stack) {
      print('ERROR generating legId: $e');
      print(stack);
      return 'ERROR_LEG_ID';
    }
  }

  TransitLegStops({
    required this.legStartMeters,
    required this.legEndMeters,
    required this.numStops,
    required this.stopPositions,
    required this.stopMeters,
    this.lineName,
    this.isActualPositions = false,
    this.isMetro = false,
    this.stopNames = const [],
    this.stopCountConfidence = 1.0,
  });

  /// Serialize for persistence.
  Map<String, dynamic> toJson() => {
    'legStartMeters': legStartMeters,
    'legEndMeters': legEndMeters,
    'numStops': numStops,
    'stopPositions':
        stopPositions
            .map((p) => {'lat': p.latitude, 'lng': p.longitude})
            .toList(),
    'stopMeters': stopMeters,
    if (lineName != null) 'lineName': lineName,
    'isActualPositions': isActualPositions,
    'isMetro': isMetro,
    'stopNames': stopNames,
    'stopCountConfidence': stopCountConfidence,
  };

  /// Deserialize from persistence.
  static TransitLegStops fromJson(Map<String, dynamic> m) {
    final stopPos =
        ((m['stopPositions'] as List?) ?? [])
            .map(
              (p) => LatLng(
                (p['lat'] as num).toDouble(),
                (p['lng'] as num).toDouble(),
              ),
            )
            .toList();
    final isActual = m['isActualPositions'] == true;
    final rawNum = m['numStops'] as int;

    // HEALING: Ensure consistency between declared stops and actual data points.
    final effectiveNum =
        (isActual && stopPos.isNotEmpty) ? stopPos.length : rawNum;

    return TransitLegStops(
      legStartMeters: (m['legStartMeters'] as num).toDouble(),
      legEndMeters: (m['legEndMeters'] as num).toDouble(),
      numStops: effectiveNum,
      stopPositions: stopPos,
      stopMeters:
          ((m['stopMeters'] as List?) ?? [])
              .map((e) => (e as num).toDouble())
              .toList(),
      lineName: m['lineName'] as String?,
      isActualPositions: isActual,
      isMetro: m['isMetro'] == true,
      stopNames:
          (m['stopNames'] as List?)?.map((e) => e.toString()).toList() ?? [],
      stopCountConfidence:
          (m['stopCountConfidence'] as num?)?.toDouble() ?? 1.0,
    );
  }

  /// Count how many stops the user has passed given their current progress in meters.
  int stopsPassed(double currentMeters) {
    int count = 0;
    for (final sm in stopMeters) {
      if (currentMeters >= sm) {
        count++;
      } else {
        break; // Stop meters are in order, no need to check further
      }
    }
    return count;
  }

  /// Remaining stops until arrival (total intermediate stops - stops passed).
  int stopsRemaining(double currentMeters) {
    return numStops - stopsPassed(currentMeters);
  }

  /// Create a copy with updated fields.
  TransitLegStops copyWith({
    double? legStartMeters,
    double? legEndMeters,
    int? numStops,
    List<LatLng>? stopPositions,
    List<double>? stopMeters,
    String? lineName,
    bool? isActualPositions,
    bool? isMetro,
    List<String>? stopNames,
    double? stopCountConfidence,
  }) {
    return TransitLegStops(
      legStartMeters: legStartMeters ?? this.legStartMeters,
      legEndMeters: legEndMeters ?? this.legEndMeters,
      numStops: numStops ?? this.numStops,
      stopPositions: stopPositions ?? this.stopPositions,
      stopMeters: stopMeters ?? this.stopMeters,
      lineName: lineName ?? this.lineName,
      isActualPositions: isActualPositions ?? this.isActualPositions,
      isMetro: isMetro ?? this.isMetro,
      stopNames: stopNames ?? this.stopNames,
      stopCountConfidence: stopCountConfidence ?? this.stopCountConfidence,
    );
  }
}

class RouteEventBoundary {
  final double meters;
  final String type; // 'transfer' | 'mode_change'
  final String? label; // e.g., station or mode label
  final double? lat;
  final double? lng;
  final int? associatedLegIndex; // Explicit mapping to transit leg index

  RouteEventBoundary({
    required this.meters,
    required this.type,
    this.label,
    this.lat,
    this.lng,
    this.associatedLegIndex,
  });
  Map<String, dynamic> toJson() => {
    'meters': meters,
    'type': type,
    if (label != null) 'label': label,
    if (lat != null) 'lat': lat,
    if (lng != null) 'lng': lng,
    if (associatedLegIndex != null) 'associatedLegIndex': associatedLegIndex,
  };
  static RouteEventBoundary fromJson(Map<String, dynamic> m) =>
      RouteEventBoundary(
        meters: (m['meters'] as num).toDouble(),
        type: m['type'] as String,
        label: m['label'] as String?,
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
        associatedLegIndex: m['associatedLegIndex'] as int?,
      );
}

class TransferUtils {
  static bool _isActiveStop(Map<String, dynamic> stop) {
    final raw = stop['status']?.toString().trim().toLowerCase() ?? '';
    if (raw.isEmpty) return true; // Default to active if missing
    if (raw == 'active' || raw == 'operational' || raw == 'open') return true;
    if (raw == 'upcoming' ||
        raw == 'under construction' ||
        raw == 'under-construction' ||
        raw == 'planned' ||
        raw == 'proposed' ||
        raw == 'approved') {
      return false;
    }
    return true;
  }

  static bool _isMetroTransitStep(Map<String, dynamic> step) {
    try {
      final mode = (step['travel_mode'] as String?)?.toUpperCase();
      if (mode != 'TRANSIT') return false;
      final td = step['transit_details'] as Map<String, dynamic>?;
      final line = td?['line'] as Map<String, dynamic>?;
      final vehicle = line?['vehicle'] as Map<String, dynamic>?;
      final vType = (vehicle?['type'] as String?)?.toUpperCase();
      // Include all rail-based transit types that should be treated as metro
      // METRO_RAIL = light rail transit (used by many metro systems)
      // SUBWAY = underground subway systems
      // HEAVY_RAIL = heavy rail systems
      // RAIL = general rail
      // MONORAIL = monorail systems (treated as metro for alarm purposes)
      return vType == 'SUBWAY' ||
          vType == 'HEAVY_RAIL' ||
          vType == 'RAIL' ||
          vType == 'METRO_RAIL' ||
          vType == 'MONORAIL' ||
          vType == 'TRAM' ||
          vType == 'COMMUTER_TRAIN';
    } catch (_) {
      return false;
    }
  }

  static String? _canonicalEventMode(Map<String, dynamic> step) {
    final mode = (step['travel_mode'] as String?)?.toUpperCase();
    if (mode == null) return null;
    if (mode == 'TRANSIT') {
      return _isMetroTransitStep(step) ? 'METRO' : 'OTHER_TRANSIT';
    }
    return mode;
  }

  static List<double> buildTransferBoundariesMeters(
    Map<String, dynamic> directions, {
    bool metroMode = false,
  }) {
    final result = <double>[];
    if (!metroMode) return result;
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) return result;
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];
      double cum = 0.0;
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (int i = 0; i < steps.length; i++) {
          final step = steps[i] as Map<String, dynamic>;
          final stepStartMeters = cum;
          final dist =
              ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          if (dist != null) cum += dist.toDouble();
          final stepEndMeters = cum;

          final mode = step['travel_mode'] as String?;
          final isMetroStep =
              mode?.toUpperCase() == 'TRANSIT' && _isMetroTransitStep(step);
          if (!isMetroStep) continue;

          // Identify current line id (best-effort; can be null)
          final curLine =
              ((step['transit_details'] as Map<String, dynamic>?)?['line'])
                  as Map<String, dynamic>?;
          final curId =
              (curLine?['short_name'] ?? curLine?['name'] ?? curLine?['id'])
                  ?.toString();

          // 1) Boarding boundary: start of this metro segment.
          final prevIsMetro =
              i > 0 &&
              ((steps[i - 1] as Map<String, dynamic>)['travel_mode'] as String?)
                      ?.toUpperCase() ==
                  'TRANSIT' &&
              _isMetroTransitStep(steps[i - 1] as Map<String, dynamic>);
          if (!prevIsMetro) {
            result.add(stepStartMeters);
          }

          // 2) Alight/switch boundary: end of this metro segment.
          // Add when the next metro segment is a different line OR there is no
          // upcoming metro segment (exit transit).
          String? nextTransitId;
          bool foundNextMetro = false;
          for (int j = i + 1; j < steps.length; j++) {
            final nextStep = steps[j] as Map<String, dynamic>;
            final nextMode = nextStep['travel_mode'] as String?;
            if (nextMode?.toUpperCase() == 'TRANSIT' &&
                _isMetroTransitStep(nextStep)) {
              final nxtLine =
                  ((nextStep['transit_details']
                          as Map<String, dynamic>?)?['line'])
                      as Map<String, dynamic>?;
              nextTransitId =
                  (nxtLine?['short_name'] ?? nxtLine?['name'] ?? nxtLine?['id'])
                      ?.toString();
              foundNextMetro = true;
              break;
            }
          }

          final shouldAddEndBoundary =
              !foundNextMetro ||
              (curId != null &&
                  nextTransitId != null &&
                  nextTransitId != curId) ||
              (curId == null && foundNextMetro && nextTransitId != null);
          if (shouldAddEndBoundary) {
            result.add(stepEndMeters);
          }
        }
      }
    } catch (e) {
      dev.log(
        'Failed to compute transfer boundaries: $e',
        name: 'TransferUtils',
      );
    }
    // Ensure monotonic increasing unique boundaries.
    result.sort();
    final uniq = <double>[];
    const eps = 1.0; // meter-level de-dup
    for (final m in result) {
      if (uniq.isEmpty || (m - uniq.last).abs() > eps) uniq.add(m);
    }
    return uniq;
  }

  // Build rich event boundaries for transfers and mode changes along the route.
  static List<RouteEventBoundary> buildRouteEvents(
    Map<String, dynamic> directions,
  ) {
    final events = <RouteEventBoundary>[];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) return events;
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];
      double cum = 0.0;
      String? prevMode;

      // Build a flat list of all steps across all legs for proper cross-leg lookahead/lookback
      final allSteps = <Map<String, dynamic>>[];
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (final s in steps) {
          allSteps.add(s as Map<String, dynamic>);
        }
      }

      // Pre-calculate Leg Indices to align EXACTLY with extractTransitLegStops
      // This ensures RouteEvents reference the correct runtime leg index.
      final stepIndexToLegIndex = <int, int>{};
      int currentLegIndex = -1;
      bool lastLegWasNonTransit = false;

      for (int k = 0; k < allSteps.length; k++) {
        final s = allSteps[k];
        final rawMode = s['travel_mode']?.toString().toUpperCase();

        if (rawMode == 'TRANSIT') {
          // Transit steps always start a new leg
          currentLegIndex++;
          stepIndexToLegIndex[k] = currentLegIndex;
          lastLegWasNonTransit = false;
        } else {
          // Non-transit (Walking/Driving)
          if (lastLegWasNonTransit) {
            // Coalesce with previous non-transit leg
            // So this step belongs to the SAME leg index as before
            stepIndexToLegIndex[k] = currentLegIndex;
          } else {
            // Start a new non-transit leg
            currentLegIndex++;
            stepIndexToLegIndex[k] = currentLegIndex;
            lastLegWasNonTransit = true;
          }
        }
      }

      // Track last step end point for gap calculation (align with stitched polyline domain)
      LatLng? lastStepEnd;

      for (int i = 0; i < allSteps.length; i++) {
        final step = allSteps[i];
        final mode = _canonicalEventMode(step);
        final apiDistanceMeters =
            ((step['distance'] as Map<String, dynamic>?)?['value'] as num?)
                ?.toDouble() ??
            0.0;

        // Use polyline distance if available (consistent with progressMeters domain)
        final polylineStr =
            (step['polyline'] as Map<String, dynamic>?)?['points'] as String?;
        final polylinePoints =
            polylineStr != null ? decodePolyline(polylineStr) : <LatLng>[];
        final stepPolylineLength = polylineLength(polylinePoints);
        // Fallback to API distance if polyline is empty/invalid (e.g., test placeholders)
        final dist =
            stepPolylineLength > 0 ? stepPolylineLength : apiDistanceMeters;

        double? startLat;
        double? startLng;
        try {
          final loc = step['start_location'] as Map<String, dynamic>?;
          if (loc != null) {
            startLat = (loc['lat'] as num?)?.toDouble();
            startLng = (loc['lng'] as num?)?.toDouble();
          }
        } catch (_) {}

        // Add gap distance from previous step if any (align with stitched polyline domain)
        try {
          if (lastStepEnd != null && polylinePoints.isNotEmpty) {
            final gap = Geolocator.distanceBetween(
              lastStepEnd.latitude,
              lastStepEnd.longitude,
              polylinePoints.first.latitude,
              polylinePoints.first.longitude,
            );
            if (gap > 5.0) {
              cum += gap;
            }
          }
          if (polylinePoints.isNotEmpty) {
            lastStepEnd = polylinePoints.last;
          }
        } catch (_) {
          // Ignore gap calculation errors
        }

        // Mode change event recorded at the boundary between steps (before adding current step distance)
        if (prevMode != null && mode != null && mode != prevMode) {
          final pm = prevMode.toUpperCase();
          final cm = mode.toUpperCase();

          // User requirement: only Walking <-> Metro boundaries are valid switch points.
          final isWalkingMetro =
              (pm == 'WALKING' && cm == 'METRO') ||
              (pm == 'METRO' && cm == 'WALKING');

          if (isWalkingMetro) {
            // Special case: METRO → WALKING where another METRO follows shortly.
            // This is an "interchange walk" (platform change during transfer), NOT
            // a genuine "Start walking" event. Skip the mode_change here; the
            // transfer detection below will handle it.
            bool isInterchangeWalk = false;
            if (pm == 'METRO' && cm == 'WALKING') {
              // Check if there's another METRO step coming up within ~600m (across all legs)
              double lookAheadDist = dist;
              for (
                int j = i + 1;
                j < allSteps.length && lookAheadDist < 600.0;
                j++
              ) {
                final nextStep = allSteps[j];
                final nextMode = _canonicalEventMode(nextStep);
                if (nextMode?.toUpperCase() == 'METRO') {
                  isInterchangeWalk = true;
                  break;
                }
                // Use polyline distance for consistency
                final nextPolyStr =
                    (nextStep['polyline'] as Map<String, dynamic>?)?['points']
                        as String?;
                final nextPolyPoints =
                    nextPolyStr != null
                        ? decodePolyline(nextPolyStr)
                        : <LatLng>[];
                final nextPolyLen = polylineLength(nextPolyPoints);
                final nextApiDist =
                    ((nextStep['distance'] as Map<String, dynamic>?)?['value'])
                        as num?;
                lookAheadDist +=
                    nextPolyLen > 0
                        ? nextPolyLen
                        : (nextApiDist?.toDouble() ?? 0.0);
              }
            }

            // Special case: WALKING → METRO after a recent METRO (interchange walk continuation).
            // This "Board transit" is part of the transfer sequence, not a new boarding event.
            bool isInterchangeBoarding = false;
            if (pm == 'WALKING' && cm == 'METRO') {
              // Check if there was a METRO step shortly before this walking segment (across all legs)
              double lookBackDist = 0.0;
              for (int j = i - 1; j >= 0 && lookBackDist < 600.0; j--) {
                final prevStep = allSteps[j];
                final prevStepMode = _canonicalEventMode(prevStep);
                if (prevStepMode?.toUpperCase() == 'METRO') {
                  isInterchangeBoarding = true;
                  break;
                }
                // Use polyline distance for consistency
                final prevPolyStr =
                    (prevStep['polyline'] as Map<String, dynamic>?)?['points']
                        as String?;
                final prevPolyPoints =
                    prevPolyStr != null
                        ? decodePolyline(prevPolyStr)
                        : <LatLng>[];
                final prevPolyLen = polylineLength(prevPolyPoints);
                final prevApiDist =
                    ((prevStep['distance'] as Map<String, dynamic>?)?['value'])
                        as num?;
                lookBackDist +=
                    prevPolyLen > 0
                        ? prevPolyLen
                        : (prevApiDist?.toDouble() ?? 0.0);
              }
            }

            if (!isInterchangeWalk && !isInterchangeBoarding) {
              // For WALKING/DRIVING → METRO, use preBoarding event (not mode_change)
              // For METRO → WALKING, use mode_change event
              if (cm == 'METRO' && (pm == 'WALKING' || pm == 'DRIVING')) {
                // Extract transit line info for the preBoarding label
                String? transitLineName;
                try {
                  final transitDetails =
                      step['transit_details'] as Map<String, dynamic>?;
                  final line = transitDetails?['line'] as Map<String, dynamic>?;
                  transitLineName =
                      (line?['short_name'] ?? line?['name'])?.toString();
                } catch (_) {}

                // Ensure we don't duplicate preBoarding events for the same leg
                // This handles cases where API might return fragmented steps or valid but redundant mode switches
                final legIdx = stepIndexToLegIndex[i];
                final alreadyHasPreBoarding = events.any(
                  (e) =>
                      e.type == 'preBoarding' && e.associatedLegIndex == legIdx,
                );

                if (!alreadyHasPreBoarding) {
                  events.add(
                    RouteEventBoundary(
                      meters: cum,
                      type: 'preBoarding',
                      label:
                          transitLineName != null
                              ? 'Board $transitLineName'
                              : 'Board metro',
                      lat: startLat,
                      lng: startLng,
                      associatedLegIndex:
                          legIdx, // Matches THIS leg (boarding it)
                    ),
                  );
                }
              } else {
                // METRO → WALKING: mode_change for "Start walking" event
                final label = _modeLabel(cm == 'METRO' ? 'TRANSIT' : 'WALKING');
                events.add(
                  RouteEventBoundary(
                    meters: cum,
                    type: 'mode_change',
                    label: label,
                    lat: startLat,
                    lng: startLng,
                    associatedLegIndex:
                        stepIndexToLegIndex[i -
                            1], // Matches PREVIOUS leg (just alighted)
                  ),
                );
              }
            }
          }
        }
        cum += dist;

        // Transfer event inside TRANSIT: when next transit line differs
        if (mode?.toUpperCase() == 'METRO') {
          final curLine =
              ((step['transit_details'] as Map<String, dynamic>?)?['line'])
                  as Map<String, dynamic>?;
          final curId =
              (curLine?['short_name'] ?? curLine?['name'] ?? curLine?['id'])
                  ?.toString();
          String? nextTransitId;
          String? arrivalStopName;
          // Use this step's arrival_stop as the transfer label if available
          final arrivalStop =
              ((step['transit_details']
                      as Map<String, dynamic>?)?['arrival_stop'])
                  as Map<String, dynamic>?;
          arrivalStopName =
              arrivalStop != null ? (arrivalStop['name'] as String?) : null;
          bool foundNextTransit = false;
          for (int j = i + 1; j < allSteps.length; j++) {
            final nextStep = allSteps[j];
            final nextMode = _canonicalEventMode(nextStep);
            if (nextMode?.toUpperCase() == 'METRO') {
              final nxtLine =
                  ((nextStep['transit_details']
                          as Map<String, dynamic>?)?['line'])
                      as Map<String, dynamic>?;
              nextTransitId =
                  (nxtLine?['short_name'] ?? nxtLine?['name'] ?? nxtLine?['id'])
                      ?.toString();
              foundNextTransit = true; // Mark that we found a transit step
              break;
            }
          }

          bool isTransfer = false;
          // Only check for transfer if we actually found a next transit step
          if (foundNextTransit) {
            if (nextTransitId != null ||
                (curId != null && nextTransitId == null)) {
              if (curId != null &&
                  nextTransitId != null &&
                  curId == nextTransitId) {
                isTransfer = false; // Same line
              } else {
                isTransfer =
                    true; // Different lines or unknown -> Alert as transfer
              }
            }
          }

          if (isTransfer) {
            // Extract location of the transfer (arrival stop of current step)
            final arrivalStop =
                ((step['transit_details']
                        as Map<String, dynamic>?)?['arrival_stop'])
                    as Map<String, dynamic>?;
            final loc = arrivalStop?['location'] as Map<String, dynamic>?;
            final lat = (loc?['lat'] as num?)?.toDouble();
            final lng = (loc?['lng'] as num?)?.toDouble();

            events.add(
              RouteEventBoundary(
                meters: cum,
                type: 'transfer',
                label: arrivalStopName,
                lat: lat,
                lng: lng,
                associatedLegIndex:
                    stepIndexToLegIndex[i], // Matches THIS leg (transfer happens at end)
              ),
            );
          }
        }

        if (mode != null) prevMode = mode;
      }
    } catch (e) {
      dev.log('Failed to compute route events: $e', name: 'TransferUtils');
    }
    // Deduplicate close events (within 400m radius)
    // User requirement: "if switch points are way too close ... under 400 m ... first point ... is given precidence"
    events.sort((a, b) => a.meters.compareTo(b.meters));
    final dedup = <RouteEventBoundary>[];
    double? lastM;
    for (final ev in events) {
      if (lastM == null || (ev.meters - lastM).abs() > 400.0) {
        dedup.add(ev);
        lastM = ev.meters;
      }
    }
    return dedup;
  }

  // Returns a tuple-like map with step boundaries in meters (cumulative across all steps),
  // cumulative stops at each boundary, and step duration in seconds.
  //
  // When [metroOnly] is true, only Metro/Rail transit stops are counted (Bus stops ignored).
  // This is used for stops-mode validation when user has metro mode enabled.
  static ({List<double> bounds, List<double> stops, List<int> durations})
  buildStepBoundariesAndStops(
    Map<String, dynamic> directions, {
    bool metroOnly = false,
  }) {
    final bounds = <double>[];
    final stops = <double>[];
    final durations = <int>[];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) {
        return (bounds: bounds, stops: stops, durations: durations);
      }
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];
      // IMPORTANT: Use polyline-domain meters so step bounds match the same
      // domain as route snapping/progress (RouteSessionManager builds the active
      // polyline primarily from step polylines).
      double cumM = 0.0;
      double cumStops = 0.0;
      LatLng? lastStepEnd;
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (final s in steps) {
          final step = s as Map<String, dynamic>;
          final dist =
              ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          final dur =
              ((step['duration'] as Map<String, dynamic>?)?['value']) as num?;

          final apiDistanceMeters = dist?.toDouble() ?? 0.0;

          // Prefer the step polyline length (same meters-domain as snapping).
          double stepMeters = 0.0;
          try {
            final polylineEncoded =
                (step['polyline'] as Map<String, dynamic>?)?['points']
                    as String? ??
                '';
            final pts = decodePolyline(polylineEncoded);
            final polyMeters = polylineLength(pts);
            stepMeters = polyMeters > 0 ? polyMeters : apiDistanceMeters;

            // Add gap distance between steps if polylines are not stitched.
            if (lastStepEnd != null && pts.isNotEmpty) {
              final gap = Geolocator.distanceBetween(
                lastStepEnd.latitude,
                lastStepEnd.longitude,
                pts.first.latitude,
                pts.first.longitude,
              );
              if (gap > 5.0) {
                cumM += gap;
              }
            }
            if (pts.isNotEmpty) {
              lastStepEnd = pts.last;
            }
          } catch (_) {
            stepMeters = apiDistanceMeters;
          }

          cumM += stepMeters;

          if (step['travel_mode']?.toString().toUpperCase() == 'TRANSIT') {
            // Only count stops if this is the right type of transit
            final shouldCount = !metroOnly || _isMetroTransitStep(step);
            if (shouldCount) {
              final td = (step['transit_details'] as Map<String, dynamic>?);
              final ns = td != null ? td['num_stops'] as num? : null;
              if (ns != null) cumStops += ns.toDouble();
            }
          }
          bounds.add(cumM);
          stops.add(cumStops);
          durations.add(dur?.toInt() ?? 0);
        }
      }
    } catch (e) {
      dev.log(
        'Failed to compute step boundaries/stops: $e',
        name: 'TransferUtils',
      );
    }
    return (bounds: bounds, stops: stops, durations: durations);
  }

  static String _modeLabel(String mode) {
    switch (mode) {
      case 'WALKING':
        return 'Start walking';
      case 'DRIVING':
        return 'Start driving';
      case 'TRANSIT':
        return 'Board transit';
      case 'BICYCLING':
        return 'Start cycling';
      default:
        return mode;
    }
  }

  // Identify the cumulative stops at the first boarding of a TRANSIT segment.
  static double? firstTransitBoardingStops(Map<String, dynamic> directions) {
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) return null;
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];
      double cumStops = 0.0;
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (final s in steps) {
          final step = s as Map<String, dynamic>;
          final mode = step['travel_mode']?.toString().toUpperCase();
          if (mode == 'TRANSIT') {
            // Return the cumulative "virtual stops" accrued before boarding.
            return cumStops;
          }

          // For non-transit legs, treat ~500m as one "virtual stop" so stops-mode
          // can also reason about approaching the first boarding point.
          final dist =
              ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          if (dist != null) {
            cumStops += dist.toDouble() / 500.0;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // Compute the target cumulative stops for an alert N stops prior to a given event index
  // in the events list (e.g., transfer or final arrival). Returns cumulative stop counts.
  static double? nStopsPriorTarget({
    required ({List<double> bounds, List<double> stops}) stepData,
    required List<RouteEventBoundary> events,
    required int eventIndex,
    required double nStops,
  }) {
    if (eventIndex < 0 || eventIndex >= events.length) return null;
    final evM = events[eventIndex].meters;
    // Find cumulative stops at event boundary
    double? evStops;
    for (int i = 0; i < stepData.bounds.length; i++) {
      if (evM <= stepData.bounds[i]) {
        evStops = stepData.stops[i];
        break;
      }
    }
    if (evStops == null) return null;
    final targetStops = (evStops - nStops).clamp(0.0, double.infinity);
    return targetStops;
  }

  /// Extract all transit leg stop positions from directions for accurate stop tracking.
  /// Returns a list of [TransitLegStops] for each transit leg in the route.
  /// G18: Sum of all leg `duration.value` seconds across the first route.
  /// Leg 0 alone under-counts multi-leg journeys, so callers that need the
  /// whole-journey duration (e.g. the creation-time sanity guard) use this.
  static int totalPlannedDurationSeconds(Map<String, dynamic> directions) {
    try {
      final legs = ((directions['routes'] as List).first
          as Map<String, dynamic>)['legs'] as List;
      int total = 0;
      for (final leg in legs) {
        final v = ((leg as Map<String, dynamic>)['duration']
            as Map<String, dynamic>?)?['value'] as num?;
        total += (v ?? 0).toInt();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static List<TransitLegStops> extractTransitLegStops(
    Map<String, dynamic> directions,
  ) {
    dev.log('🚀 extractTransitLegStops called!', name: 'TransferUtils');
    final result = <TransitLegStops>[];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) return result;
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];

      // Use polyline-based cumulative meters for consistency with progressMeters
      double cumulativeMeters = 0.0;
      LatLng? lastStepEnd;

      // Flatten steps to allow lookahead
      final allSteps = <Map<String, dynamic>>[];
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (final s in steps) {
          allSteps.add(s as Map<String, dynamic>);
        }
      }

      for (int i = 0; i < allSteps.length; i++) {
        final step = allSteps[i];
        final mode = step['travel_mode']?.toString().toUpperCase();

        // Get API-reported distance as fallback
        final apiDist =
            ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
        final apiDistanceMeters = apiDist?.toDouble() ?? 0.0;

        // Get the polyline for this step
        final polylineEncoded =
            (step['polyline'] as Map<String, dynamic>?)?['points'] as String? ??
            '';
        final polylinePoints = decodePolyline(polylineEncoded);

        // Calculate actual polyline length (same domain as progressMeters)
        final stepPolylineLength = polylineLength(polylinePoints);
        final stepLengthMeters =
            stepPolylineLength > 0 ? stepPolylineLength : apiDistanceMeters;

        // Add gap distance from previous step if any (aligns with stitched polyline physics)
        try {
          if (lastStepEnd != null && polylinePoints.isNotEmpty) {
            final gap = Geolocator.distanceBetween(
              lastStepEnd.latitude,
              lastStepEnd.longitude,
              polylinePoints.first.latitude,
              polylinePoints.first.longitude,
            );
            if (gap > 5.0) {
              cumulativeMeters += gap;
            }
          }
          if (polylinePoints.isNotEmpty) {
            lastStepEnd = polylinePoints.last;
          }
        } catch (_) {}

        // Create TransitLegStops for transit steps
        if (mode == 'TRANSIT') {
          final td = step['transit_details'] as Map<String, dynamic>?;
          final numStops = (td?['num_stops'] as num?)?.toInt() ?? 0;

          // Extract line name
          final line = td?['line'] as Map<String, dynamic>?;
          final lineName = (line?['short_name'] ?? line?['name'])?.toString();

          // Calculate stop positions along the polyline
          final stopPositions = estimateStopPositions(polylinePoints, numStops);

          final legStartMeters = cumulativeMeters;
          final legLengthMeters = stepLengthMeters;

          // Map stop positions to cumulative meters
          final stopMeters = <double>[];
          if (numStops > 0 && legLengthMeters > 0) {
            for (int j = 1; j <= numStops; j++) {
              // Google Directions `num_stops` is the number of intermediate stops
              // (excluding departure and arrival). So stops lie at 1/(n+1)..n/(n+1).
              final fractionAlongLeg = j / (numStops + 1);
              final metersAlongLeg = fractionAlongLeg * legLengthMeters;
              stopMeters.add(legStartMeters + metersAlongLeg);
            }
          }

          result.add(
            TransitLegStops(
              legStartMeters: legStartMeters,
              legEndMeters: legStartMeters + stepLengthMeters,
              numStops: numStops,
              stopPositions: stopPositions,
              stopMeters: stopMeters,
              lineName: lineName,
              isMetro: _isMetroTransitStep(step),
            ),
          );
        } else if (mode == 'DRIVING' || mode == 'WALKING') {
          String lineName = mode == 'DRIVING' ? 'Drive' : 'Walk';

          // STABLE ID LOGIC: Check if this is a walk to a Metro station
          if (mode == 'WALKING') {
            dev.log(
              '🔍 LOOKAHEAD: Walk at step $i, checking future steps...',
              name: 'TransferUtils',
            );
            for (int k = i + 1; k < allSteps.length; k++) {
              final next = allSteps[k];
              final nextMode = next['travel_mode']?.toString().toUpperCase();
              // Relaxed Logic: Allow naming for ANY transit type (Bus, Metro, etc.) to ensure ID stability
              dev.log('   Step $k Mode: $nextMode', name: 'TransferUtils');
              if (nextMode == 'TRANSIT') {
                // Found next Transit step!
                final td = next['transit_details'] as Map<String, dynamic>?;
                final departure =
                    td?['departure_stop'] as Map<String, dynamic>?;
                final stationName = departure?['name'] as String?;
                dev.log(
                  '   ✅ Found Transit! Station: $stationName',
                  name: 'TransferUtils',
                );
                if (stationName != null) {
                  lineName = 'Walk to $stationName';
                } else {
                  // Fallback for nameless stations to ensure ID stability
                  final lineInfo = td?['line'] as Map<String, dynamic>?;
                  final shortName = lineInfo?['short_name'] as String?;
                  final name = lineInfo?['name'] as String?;
                  final target = shortName ?? name ?? 'Transit';
                  lineName = 'Walk to $target';
                  dev.log(
                    '   ⚠️ Nameless Station. Using Fallback: $lineName',
                    name: 'TransferUtils',
                  );
                }
                break;
              } else if (nextMode == 'DRIVING') {
                // Found Driving -> Stop looking
                dev.log(
                  '   ❌ Found driving, stopping lookahead',
                  name: 'TransferUtils',
                );
                break;
              }
              // If Walking, continue looking ahead (could be fragmented walk steps)
              else {
                dev.log(
                  '   Skipping non-terminating mode: $nextMode',
                  name: 'TransferUtils',
                );
              }
            }
            dev.log('   Final lineName: $lineName', name: 'TransferUtils');
          }

          // COALESCING LOGIC: Match by lineName to merge fragments
          if (result.isNotEmpty &&
              !result.last.isMetro &&
              result.last.numStops == 0 &&
              result.last.lineName == lineName) {
            // Require same name to merge
            final last = result.removeLast();
            final mergedEndMeters = last.legEndMeters + stepLengthMeters;

            result.add(
              TransitLegStops(
                legStartMeters: last.legStartMeters,
                legEndMeters: mergedEndMeters,
                numStops: 0,
                stopPositions: const [],
                stopMeters: const [],
                lineName: lineName,
                isMetro: false,
              ),
            );
          } else {
            // New non-transit leg
            final legStartMeters = cumulativeMeters;
            result.add(
              TransitLegStops(
                legStartMeters: legStartMeters,
                legEndMeters: legStartMeters + stepLengthMeters,
                numStops: 0,
                stopPositions: const [],
                stopMeters: const [],
                lineName: lineName,
                isMetro: false,
              ),
            );
          }
        }

        cumulativeMeters += stepLengthMeters;
      }
    } catch (e) {
      dev.log('Failed to extract transit leg stops: $e', name: 'TransferUtils');
    }
    return result;
  }

  /// Count total stops passed across all transit legs given current progress.
  static int countStopsPassed(
    List<TransitLegStops> transitLegs,
    double currentMeters,
  ) {
    int total = 0;
    for (final leg in transitLegs) {
      if (currentMeters >= leg.legStartMeters) {
        total += leg.stopsPassed(currentMeters);
      }
    }
    return total;
  }

  /// Count total stops remaining across all transit legs given current progress.
  static int countStopsRemaining(
    List<TransitLegStops> transitLegs,
    double currentMeters,
  ) {
    int totalRemaining = 0;
    for (final leg in transitLegs) {
      if (currentMeters < leg.legEndMeters) {
        // User hasn't completed this leg yet
        if (currentMeters >= leg.legStartMeters) {
          // Currently in this leg
          totalRemaining += leg.stopsRemaining(currentMeters);
        } else {
          // Haven't reached this leg yet - all stops are remaining
          totalRemaining += leg.numStops;
        }
      }
    }
    return totalRemaining;
  }

  static List<Map<String, dynamic>> buildRouteSegments(
    Map<String, dynamic> directions,
  ) {
    final segments = <Map<String, dynamic>>[];
    try {
      final routes = directions['routes'] as List;
      if (routes.isNotEmpty) {
        final legs = routes[0]['legs'] as List;
        for (final leg in legs) {
          final steps = leg['steps'] as List;
          for (final step in steps) {
            final mode = (step['travel_mode'] as String).toLowerCase();
            String polyline = '';
            try {
              polyline = step['polyline']['points'];
            } catch (_) {}

            // Should we decode here? Yes, to keep consistent with previous logic
            if (polyline.isNotEmpty) {
              final pts = decodePolyline(polyline);
              segments.add({
                'mode': mode,
                'points':
                    pts
                        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                        .toList(),
              });
            }
          }
        }
      }
    } catch (e) {
      dev.log('Error building segments: $e', name: 'TransferUtils');
    }
    return segments;
  }

  /// Enhance transit leg stops with actual station positions from OSM List.
  ///
  /// G16: Decide whether the OSM-derived intermediate stop count diverges from
  /// Google's `num_stops` beyond tolerance. When true, the caller must fall back
  /// to the API count and mark the leg low-confidence (firing LATE is product
  /// death, so a smaller/inconsistent OSM count is never trusted blindly).
  ///
  /// Tolerance = max(1, round(20% of apiNumStops)). An OSM count of 0 against a
  /// positive API count always diverges.
  static bool osmStopCountDiverges({
    required int apiNumStops,
    required int osmNumStops,
  }) {
    if (apiNumStops <= 0) return false; // no API baseline to compare against
    if (osmNumStops == 0) return true; // OSM found nothing intermediate
    final divergence = (osmNumStops - apiNumStops).abs();
    final tolerance = math.max(1, (apiNumStops * 0.2).round());
    return divergence > tolerance;
  }

  /// Color/name tokens that anchor a line's canonical identity. Kept as-is
  /// (no synonym merging) so distinct lines that happen to share a family
  /// (e.g. Delhi's Magenta vs Pink, Violet vs Purple) never collapse together.
  static const Set<String> _lineColorTokens = {
    'blue',
    'green',
    'red',
    'yellow',
    'purple',
    'pink',
    'orange',
    'aqua',
    'magenta',
    'violet',
    'grey',
    'gray',
    'cyan',
    'teal',
    'brown',
    'silver',
    'gold',
    'black',
    'white',
  };

  /// Generic transit words that carry no line identity and are stripped before
  /// tokenising (so "Blue Line" and "Blue" canonicalize identically).
  static final RegExp _lineGenericWords = RegExp(
    r'\b(line|metro|rail|railway|subway|the|express|corridor|rapid|transit|route)\b',
  );

  /// HTML entity matcher: numeric refs (`&#x25D9;`, `&#123;`) and named
  /// entities (`&amp;`). OSM's `line` labels are polluted with these.
  static final RegExp _htmlEntity = RegExp(r'&#?[a-z0-9]+;');

  /// Reduce a raw line label to a stable, comparable token.
  ///
  /// Normalizes Google's clean `leg.lineName` (e.g. "Blue Line", "Blue") and
  /// OSM's dirty `line` (e.g. "&#x25D9;  Blue Line") to the same key ("blue").
  /// Strips HTML entities, punctuation and whitespace, lowercases, drops
  /// generic transit words, and prefers a color anchor token when present;
  /// otherwise joins the remaining alphanumeric tokens (e.g. "Line 7" → "7").
  static String _canonLine(String? s) {
    if (s == null) return '';
    var t = s.toLowerCase();
    t = t.replaceAll(_htmlEntity, ' '); // strip &#x25D9; &amp; etc.
    t = t.replaceAll(RegExp(r'[^a-z0-9]+'), ' '); // punctuation → space
    t = t.replaceAll(_lineGenericWords, ' '); // drop "line"/"metro"/...
    final tokens =
        t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (tokens.isEmpty) return '';
    // A color word is the strongest, most stable anchor for a line.
    for (final tok in tokens) {
      if (_lineColorTokens.contains(tok)) return tok;
    }
    // No color: fall back to the concatenation of remaining tokens
    // (e.g. numbered lines "M1" / "Line 1" → "m1" / "1").
    return tokens.join();
  }

  /// Reduce a city label to a stable, comparable token.
  static String _canonCity(String? s) {
    if (s == null) return '';
    return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  /// **OSM-ONLY MODE**: Completely ignores Google API's `num_stops`.
  /// Uses ONLY OSM stops that fall within 500m of the polyline, snapped directly.
  /// No interpolation, no uniform baseline, no slot-filling.
  ///
  /// The number of intermediate stops is determined by OSM matches, not API.
  /// This ensures consistent alarm behavior across all routes in Bengaluru
  /// where OSM coverage is complete.
  static Future<List<TransitLegStops>> enhanceTransitLegStopsWithOsm(
    List<TransitLegStops> legs,
    Map<String, dynamic> directions, {
    // Test-only seam: inject a synthetic stop bundle instead of the bundled
    // `allIndiaStops`. Production callers never pass this (default = null), so
    // runtime behavior is unchanged.
    List<Map<String, dynamic>>? stopsOverride,
  }) async {
    if (legs.isEmpty) return legs;

    final enhanced = <TransitLegStops>[];

    try {
      // Extract all transit step polylines from directions
      final transitPolylines = _extractTransitPolylines(directions);

      // Load OSM stops as the SINGLE source of truth. Carry the `line` and
      // `city` labels through so we can filter matches to the leg's own line
      // (fixes WRONG-METRO-STATION-SNAP: a parallel OTHER-line station ~150m
      // away must not be injected into this line's stop list).
      final stopSource = stopsOverride ?? allIndiaStops;
      final List<Stop> loadedStops =
          stopSource.where(_isActiveStop).map((m) {
            return Stop(
              id: m['id'] as String,
              name: m['name'] as String,
              location: LatLng(
                (m['lat'] as num).toDouble(),
                (m['lng'] as num).toDouble(),
              ),
              line: m['line'] as String?,
              city: m['city'] as String?,
            );
          }).toList();

      dev.log(
        'TransferUtils: OSM-ONLY MODE - Using ${loadedStops.length} stops from allIndiaStops',
        name: 'TransferUtils',
      );

      int transitPolylineIndex = 0;

      for (int i = 0; i < legs.length; i++) {
        final leg = legs[i];

        // Skip non-metro legs (Drive, Walk, Bus, etc.)
        if (!leg.isMetro) {
          enhanced.add(leg);
          continue;
        }

        final polylinePoints =
            transitPolylineIndex < transitPolylines.length
                ? transitPolylines[transitPolylineIndex]
                : <LatLng>[];
        transitPolylineIndex++;

        if (polylinePoints.isEmpty) {
          dev.log(
            '⚠️ TransferUtils: No polyline for metro leg $i (${leg.lineName}), keeping original',
            name: 'TransferUtils',
          );
          enhanced.add(leg);
          continue;
        }

        try {
          // Match OSM stops within 500m of the polyline
          final matchedAll = StopMatcher.matchStopsToPolyline(
            polyline: polylinePoints,
            stops: loadedStops,
            radiusMeters: 500.0,
            dedupeMeters: 80.0,
          );

          dev.log(
            'TransferUtils: Leg $i (${leg.lineName}) - Matched ${matchedAll.length} OSM stops',
            name: 'TransferUtils',
          );

          if (matchedAll.isEmpty) {
            dev.log(
              '⚠️ TransferUtils: NO OSM STOPS FOUND for ${leg.lineName}! Keeping original.',
              name: 'TransferUtils',
            );
            if (polylinePoints.isNotEmpty) {
              dev.log(
                '   Polyline: ${polylinePoints.first} → ${polylinePoints.last}',
                name: 'TransferUtils',
              );
            }
            enhanced.add(leg);
            continue;
          }

          // LINE FILTER (fixes WRONG-METRO-STATION-SNAP):
          // `matchedAll` contains EVERY active OSM station within 500m of the
          // polyline — across all cities/lines. A parallel OTHER-line station
          // (e.g. Mumbai DN Nagar/Blue vs Andheri West/Yellow ~140m apart)
          // therefore leaks into this leg's stop list. Keep only stops whose
          // canonical line matches this leg's line, in the same city.
          final legLineKey = _canonLine(leg.lineName);
          // Derive the leg's city from the majority city of the matched stops
          // (they are all geographically on/near this polyline, so the majority
          // is this leg's city).
          final cityVotes = <String, int>{};
          for (final m in matchedAll) {
            final c = _canonCity(m.stop.city);
            if (c.isEmpty) continue;
            cityVotes[c] = (cityVotes[c] ?? 0) + 1;
          }
          String legCityKey = '';
          int bestVotes = 0;
          cityVotes.forEach((c, v) {
            if (v > bestVotes) {
              bestVotes = v;
              legCityKey = c;
            }
          });

          // LINE-FIRST (ordered): if this line has a CONFIDENT hardcoded ordered
          // sequence, match THAT against the leg polyline. The 500m radius match
          // naturally slices to just this leg's segment, arc-length-ordered — so
          // stop-counting is exact and uses ONLY this line's own stations. Falls
          // through to the OSM line-filter below when no confident sequence
          // matches (unknown line / degenerate slice).
          List<MatchedStop>? orderedMatches;
          final orderedSeq = kMetroLineSequences[legCityKey]?[legLineKey];
          if (orderedSeq != null && orderedSeq.length >= 2) {
            final seqStops =
                orderedSeq
                    .map(
                      (s) => Stop(
                        id: 'seq_${legCityKey}_${legLineKey}_${s.name}',
                        name: s.name,
                        location: LatLng(s.lat, s.lng),
                        line: legLineKey,
                        city: legCityKey,
                      ),
                    )
                    .toList();
            final matchedSeq = StopMatcher.matchStopsToPolyline(
              polyline: polylinePoints,
              stops: seqStops,
              radiusMeters: 500.0,
              dedupeMeters: 80.0,
            );
            if (matchedSeq.length >= 2) {
              orderedMatches = matchedSeq;
              dev.log(
                'TransferUtils: Leg $i (${leg.lineName}) — using hardcoded ordered '
                'sequence ($legCityKey/$legLineKey): ${matchedSeq.length} stops.',
                name: 'TransferUtils',
              );
            }
          }

          final lineFiltered =
              matchedAll.where((m) {
                if (legLineKey.isEmpty) return false; // no line label to match
                if (_canonLine(m.stop.line) != legLineKey) return false;
                // City guard: only enforce when both sides carry a city label.
                if (legCityKey.isNotEmpty) {
                  final stopCity = _canonCity(m.stop.city);
                  if (stopCity.isNotEmpty && stopCity != legCityKey) {
                    return false;
                  }
                }
                return true;
              }).toList();

          // SAFETY NET: never produce ZERO stops. Prefer the line-filtered set,
          // but fall back to the unfiltered `matchedAll` when line filtering
          // wipes everything out (unknown/dirty line label) or drops FAR below
          // Google's num_stops while the unfiltered set is closer to it.
          final apiNumStopsForFilter = leg.numStops;
          List<MatchedStop> effectiveMatches;
          if (orderedMatches != null) {
            // Hardcoded ordered sequence wins: exact, own-line, in order.
            effectiveMatches = orderedMatches;
          } else if (lineFiltered.isEmpty) {
            // CORRECTNESS (off-route stops): do NOT scoop the unfiltered corridor
            // — `matchedAll`/`loadedStops` spans EVERY line and city, so an
            // unknown/dirty line label would inject parallel/crossing-line
            // stations at wrong positions. Keep the API-derived leg instead
            // (uniform num_stops, on-route by construction). Never count a stop
            // that isn't on this route's line.
            dev.log(
              '⚠️ TransferUtils: Line filter empty for "${leg.lineName}" '
              '(key="$legLineKey"); keeping API-uniform leg instead of the '
              'cross-line corridor (off-route safety).',
              name: 'TransferUtils',
            );
            enhanced.add(leg);
            continue;
          } else if (apiNumStopsForFilter > 0) {
            final farFewer =
                lineFiltered.length < (apiNumStopsForFilter * 0.5);
            final filteredDiff =
                (lineFiltered.length - apiNumStopsForFilter).abs();
            final allDiff = (matchedAll.length - apiNumStopsForFilter).abs();
            if (farFewer && allDiff < filteredDiff) {
              // CORRECTNESS (off-route stops): own-line OSM is incomplete here,
              // but the unfiltered corridor is cross-line contaminated —
              // preferring it because its COUNT is closer just substitutes
              // phantom stations of OTHER lines at wrong positions (the
              // divergence gate only checks count, not that stops are on-line).
              // Keep the API-uniform leg instead of scooping off-route stations.
              dev.log(
                '⚠️ TransferUtils: Line filter kept only ${lineFiltered.length} '
                'own-line stops vs API num_stops=$apiNumStopsForFilter for '
                '"${leg.lineName}"; keeping API-uniform leg (off-route safety).',
                name: 'TransferUtils',
              );
              enhanced.add(leg);
              continue;
            } else {
              effectiveMatches = lineFiltered;
              dev.log(
                'TransferUtils: Line filter kept ${lineFiltered.length}/'
                '${matchedAll.length} stops for "${leg.lineName}" '
                '(key="$legLineKey", city="$legCityKey").',
                name: 'TransferUtils',
              );
            }
          } else {
            effectiveMatches = lineFiltered;
            dev.log(
              'TransferUtils: Line filter kept ${lineFiltered.length}/'
              '${matchedAll.length} stops for "${leg.lineName}" '
              '(key="$legLineKey", city="$legCityKey").',
              name: 'TransferUtils',
            );
          }

          // Dedupe by stop ID (keep closest to polyline for each unique ID)
          final byId = <String, MatchedStop>{};
          for (final m in effectiveMatches) {
            final id = m.stop.id;
            if (!byId.containsKey(id) ||
                m.distanceToPolylineMeters <
                    byId[id]!.distanceToPolylineMeters) {
              byId[id] = m;
            }
          }

          // Order by position along polyline
          final uniqueOrdered =
              byId.values.toList()..sort(
                (a, b) =>
                    a.metersAlongPolyline.compareTo(b.metersAlongPolyline),
              );

          // Calculate polyline total length
          final polylineTotalMeters = polylineLength(polylinePoints);
          if (polylineTotalMeters <= 0) {
            dev.log(
              '⚠️ TransferUtils: Zero-length polyline for ${leg.lineName}',
              name: 'TransferUtils',
            );
            enhanced.add(leg);
            continue;
          }

          // Filter out stops too close to endpoints (within 50m of start/end)
          // These are likely the boarding/alighting stations, not intermediate stops
          //
          // MUMBAI FIX: Also filter out stops that belong to the NEXT metro leg.
          // If there's a walk between metro legs (DN Nagar → walk → Andheri West),
          // Andheri West stops should NOT be included in the first leg's intermediate stops.
          const endpointToleranceMeters = 50.0;

          // Calculate leg length for stop filtering
          final legLength = leg.legEndMeters - leg.legStartMeters;

          // Check if there's a later metro leg. Scan PAST intervening non-metro
          // (walk) legs — a transfer is usually metro → WALK → metro, so the old
          // legs[i+1]-only check was dead for exactly that interchange case and
          // let the next line's boarding station leak into this leg.
          int nextMetroIdx = -1;
          for (int j = i + 1; j < legs.length; j++) {
            if (legs[j].isMetro) {
              nextMetroIdx = j;
              break;
            }
          }
          final nextLegIsMetro = nextMetroIdx != -1;
          final nextLegStartMeters =
              nextLegIsMetro ? legs[nextMetroIdx].legStartMeters : double.infinity;

          final intermediateStops =
              uniqueOrdered
                  .where(
                    (s) {
                      // Basic endpoint filtering
                      if (s.metersAlongPolyline <= endpointToleranceMeters ||
                          s.metersAlongPolyline >= (polylineTotalMeters - endpointToleranceMeters)) {
                        return false;
                      }

                      // MUMBAI FIX: If next leg is metro and there's a gap (walk),
                      // exclude stops that are closer to next leg start than current leg end
                      if (nextLegIsMetro) {
                        final progress = (s.metersAlongPolyline / polylineTotalMeters).clamp(0.0, 1.0);
                        final absoluteMeters = leg.legStartMeters + (progress * legLength);

                        // If this stop is beyond current leg end and close to next leg start,
                        // it belongs to the next leg, not this one
                        if (absoluteMeters > leg.legEndMeters) {
                          final distToNextLeg = (nextLegStartMeters - absoluteMeters).abs();
                          if (distToNextLeg < 300.0) { // Within 300m of next leg start
                            return false;
                          }
                        }
                      }

                      return true;
                    },
                  )
                  .toList();

          dev.log(
            '   After endpoint filter: ${intermediateStops.length} intermediate stops '
            '(removed ${uniqueOrdered.length - intermediateStops.length} endpoint stops)',
            name: 'TransferUtils',
          );

          // Build stop data directly from OSM matches - NO INTERPOLATION
          final stopPositions = <LatLng>[];
          final stopMeters = <double>[];
          final stopNames = <String>[];

          for (final s in intermediateStops) {
            // Convert polyline-relative meters to leg-relative meters
            final progress = (s.metersAlongPolyline / polylineTotalMeters)
                .clamp(0.0, 1.0);
            final metersAlongLeg = progress * legLength;
            final absoluteMeters = leg.legStartMeters + metersAlongLeg;

            stopPositions.add(s.stop.location);
            stopMeters.add(absoluteMeters);
            stopNames.add(s.stop.name);
          }

          // The actual number of intermediate stops from OSM
          final actualNumStops = intermediateStops.length;

          // G16: cross-check OSM vs Google `num_stops`. `leg` here is the
          // pre-enhancement API-derived leg (API numStops + uniform stopMeters),
          // so falling back to it costs nothing and stays self-consistent.
          final apiNumStops = leg.numStops;
          final diverged = osmStopCountDiverges(
            apiNumStops: apiNumStops,
            osmNumStops: actualNumStops,
          );

          dev.log('''
🎯 OSM ENHANCEMENT (cross-checked): ${leg.lineName}
   Leg range: ${leg.legStartMeters.toStringAsFixed(0)}m - ${leg.legEndMeters.toStringAsFixed(0)}m (length: ${legLength.toStringAsFixed(0)}m)
   Polyline length: ${polylineTotalMeters.toStringAsFixed(0)}m
   API num_stops:           $apiNumStops
   OSM matched total:       ${matchedAll.length}
   Unique by ID:            ${uniqueOrdered.length}
   OSM intermediate stops:  $actualNumStops
   Diverged (fallback=$diverged)
   Stop names: ${stopNames.take(5).join(', ')}${stopNames.length > 5 ? '...' : ''}
   Stop meters: ${stopMeters.take(5).map((m) => m.toStringAsFixed(0)).join(', ')}${stopMeters.length > 5 ? '...' : ''}
''', name: 'TransferUtils');

          if (diverged) {
            dev.log(
              '⚠️ TransferUtils: OSM/API stop-count divergence for ${leg.lineName} '
              '(OSM=$actualNumStops, API=$apiNumStops). Falling back to API count '
              '(low confidence).',
              name: 'TransferUtils',
            );
            // Keep the API-derived leg (uniform stopMeters + API numStops) and
            // flag it. Never adopt a smaller/inconsistent OSM count that could
            // make the alarm fire late.
            enhanced.add(leg.copyWith(stopCountConfidence: 0.5));
          } else {
            enhanced.add(
              TransitLegStops(
                legStartMeters: leg.legStartMeters,
                legEndMeters: leg.legEndMeters,
                numStops: actualNumStops, // OSM count (agrees with API)
                stopPositions: stopPositions,
                stopMeters: stopMeters,
                lineName: leg.lineName,
                isActualPositions: true,
                isMetro: leg.isMetro,
                stopNames: stopNames,
                stopCountConfidence: 1.0,
              ),
            );
          }
        } catch (e) {
          dev.log(
            '⚠️ TransferUtils: OSM enhancement failed for ${leg.lineName}: $e',
            name: 'TransferUtils',
          );
          enhanced.add(leg);
        }
      }
    } catch (e) {
      dev.log(
        '⚠️ TransferUtils: Global OSM enhancement error: $e',
        name: 'TransferUtils',
      );
      return legs;
    }

    return enhanced;
  }

  // _extractTransitSteps removed - no longer used after simplification

  /// Extract polylines for each transit step from directions.
  /// Returns a list of decoded polyline points, one per transit step.
  static List<List<LatLng>> _extractTransitPolylines(
    Map<String, dynamic> directions,
  ) {
    final result = <List<LatLng>>[];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) return result;
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];

      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (final s in steps) {
          final step = s as Map<String, dynamic>;
          final mode = step['travel_mode']?.toString().toUpperCase();

          if (mode == 'TRANSIT' && _isMetroTransitStep(step)) {
            final polylineEncoded =
                (step['polyline'] as Map<String, dynamic>?)?['points']
                    as String? ??
                '';
            result.add(decodePolyline(polylineEncoded));
          }
        }
      }
    } catch (e) {
      dev.log('Failed to extract transit polylines: $e', name: 'TransferUtils');
    }
    return result;
  }

  /// Compute total length of a polyline in meters.
  static double _computePolylineLength(List<LatLng> polyline) {
    if (polyline.length < 2) return 0;
    double total = 0;
    for (int i = 0; i < polyline.length - 1; i++) {
      total += _haversineDistance(polyline[i], polyline[i + 1]);
    }
    return total;
  }

  /// Compute progress (0-1) of a point along a polyline.
  // ignore: unused_element
  static double _computeProgressAlongPolyline(
    LatLng point,
    List<LatLng> polyline,
  ) {
    if (polyline.length < 2) return 0;

    final totalLength = _computePolylineLength(polyline);
    if (totalLength == 0) return 0;

    double minDistance = double.infinity;
    double progressAtClosest = 0;
    double accumulatedLength = 0;

    for (int i = 0; i < polyline.length - 1; i++) {
      final segmentLength = _haversineDistance(polyline[i], polyline[i + 1]);
      final d = _distanceToSegment(point, polyline[i], polyline[i + 1]);

      if (d < minDistance) {
        minDistance = d;
        // Find projection point on segment
        final t = _projectionT(
          point,
          polyline[i],
          polyline[i + 1],
        ).clamp(0.0, 1.0);
        progressAtClosest =
            (accumulatedLength + t * segmentLength) / totalLength;
      }

      accumulatedLength += segmentLength;
    }

    return progressAtClosest.clamp(0.0, 1.0);
  }

  /// Haversine distance between two LatLng points in meters.
  static double _haversineDistance(LatLng p1, LatLng p2) {
    const R = 6371000.0; // Earth radius in meters
    final lat1 = p1.latitude * (3.141592653589793 / 180);
    final lat2 = p2.latitude * (3.141592653589793 / 180);
    final dLat = (p2.latitude - p1.latitude) * (3.141592653589793 / 180);
    final dLon = (p2.longitude - p1.longitude) * (3.141592653589793 / 180);

    final a =
        _sin(dLat / 2) * _sin(dLat / 2) +
        _cos(lat1) * _cos(lat2) * _sin(dLon / 2) * _sin(dLon / 2);
    final c = 2 * _atan2(_sqrt(a), _sqrt(1 - a));
    return R * c;
  }

  /// Distance from point to line segment.
  static double _distanceToSegment(LatLng p, LatLng a, LatLng b) {
    final t = _projectionT(p, a, b).clamp(0.0, 1.0);
    final projLat = a.latitude + t * (b.latitude - a.latitude);
    final projLng = a.longitude + t * (b.longitude - a.longitude);
    return _haversineDistance(p, LatLng(projLat, projLng));
  }

  /// Projection parameter t (0-1) of point onto line segment.
  static double _projectionT(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    if (dx == 0 && dy == 0) return 0;
    return ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
        (dx * dx + dy * dy);
  }

  // Math helpers using dart:math for accurate trigonometric calculations
  // IMPORTANT: Do NOT use Taylor series approximations - they cause ~3.4x distance errors
  static double _sin(double x) => math.sin(x);
  static double _cos(double x) => math.cos(x);
  static double _sqrt(double x) => math.sqrt(x);
  static double _atan2(double y, double x) => math.atan2(y, x);
}
