import 'dart:developer' as dev;
import 'package:geowake2/services/polyline_decoder.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

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

  TransitLegStops({
    required this.legStartMeters,
    required this.legEndMeters,
    required this.numStops,
    required this.stopPositions,
    required this.stopMeters,
    this.lineName,
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
  };

  /// Deserialize from persistence.
  static TransitLegStops fromJson(Map<String, dynamic> m) => TransitLegStops(
    legStartMeters: (m['legStartMeters'] as num).toDouble(),
    legEndMeters: (m['legEndMeters'] as num).toDouble(),
    numStops: m['numStops'] as int,
    stopPositions:
        ((m['stopPositions'] as List?) ?? [])
            .map(
              (p) => LatLng(
                (p['lat'] as num).toDouble(),
                (p['lng'] as num).toDouble(),
              ),
            )
            .toList(),
    stopMeters:
        ((m['stopMeters'] as List?) ?? [])
            .map((v) => (v as num).toDouble())
            .toList(),
    lineName: m['lineName'] as String?,
  );

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
}

class RouteEventBoundary {
  final double meters;
  final String type; // 'transfer' | 'mode_change'
  final String? label; // e.g., station or mode label
  final double? lat;
  final double? lng;
  RouteEventBoundary({
    required this.meters,
    required this.type,
    this.label,
    this.lat,
    this.lng,
  });
  Map<String, dynamic> toJson() => {
    'meters': meters,
    'type': type,
    if (label != null) 'label': label,
    if (lat != null) 'lat': lat,
    if (lng != null) 'lng': lng,
  };
  static RouteEventBoundary fromJson(Map<String, dynamic> m) =>
      RouteEventBoundary(
        meters: (m['meters'] as num).toDouble(),
        type: m['type'] as String,
        label: m['label'] as String?,
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
      );
}

class TransferUtils {
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
          vType == 'MONORAIL';
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
          final dist =
              ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          final mode = step['travel_mode'] as String?;
          if (dist != null) cum += dist.toDouble();
          if (mode?.toUpperCase() == 'TRANSIT' && _isMetroTransitStep(step)) {
            // Identify current line id
            final curLine =
                ((step['transit_details'] as Map<String, dynamic>?)?['line'])
                    as Map<String, dynamic>?;
            final curId =
                (curLine?['short_name'] ?? curLine?['name'] ?? curLine?['id'])
                    ?.toString();
            if (curId == null) continue;
            // Look ahead to the next transit step (skipping walking)
            String? nextTransitId;
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
                    (nxtLine?['short_name'] ??
                            nxtLine?['name'] ??
                            nxtLine?['id'])
                        ?.toString();
                break;
              }
            }
            if (nextTransitId != null && nextTransitId != curId) {
              // Boundary at the end of current transit step
              result.add(cum);
            }
          }
        }
      }
    } catch (e) {
      dev.log(
        'Failed to compute transfer boundaries: $e',
        name: 'TransferUtils',
      );
    }
    return result;
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

      for (int i = 0; i < allSteps.length; i++) {
        final step = allSteps[i];
        final mode = _canonicalEventMode(step);
        final dist =
            ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;

        double? startLat;
        double? startLng;
        try {
          final loc = step['start_location'] as Map<String, dynamic>?;
          if (loc != null) {
            startLat = (loc['lat'] as num?)?.toDouble();
            startLng = (loc['lng'] as num?)?.toDouble();
          }
        } catch (_) {}

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
              double lookAheadDist = dist?.toDouble() ?? 0.0;
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
                final nextDist =
                    ((nextStep['distance'] as Map<String, dynamic>?)?['value'])
                        as num?;
                lookAheadDist += nextDist?.toDouble() ?? 0.0;
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
                final prevDist =
                    ((prevStep['distance'] as Map<String, dynamic>?)?['value'])
                        as num?;
                lookBackDist += prevDist?.toDouble() ?? 0.0;
              }
            }

            if (!isInterchangeWalk && !isInterchangeBoarding) {
              final label = _modeLabel(cm == 'METRO' ? 'TRANSIT' : 'WALKING');
              events.add(
                RouteEventBoundary(
                  meters: cum,
                  type: 'mode_change',
                  label: label,
                  lat: startLat,
                  lng: startLng,
                ),
              );
            }
          }
        }
        if (dist != null) cum += dist.toDouble();

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
  static ({List<double> bounds, List<double> stops, List<int> durations})
  buildStepBoundariesAndStops(Map<String, dynamic> directions) {
    final bounds = <double>[];
    final stops = <double>[];
    final durations = <int>[];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty)
        return (bounds: bounds, stops: stops, durations: durations);
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];
      double cumM = 0.0;
      double cumStops = 0.0;
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (final s in steps) {
          final step = s as Map<String, dynamic>;
          final dist =
              ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          final dur =
              ((step['duration'] as Map<String, dynamic>?)?['value']) as num?;

          if (dist != null) cumM += dist.toDouble();

          if (step['travel_mode']?.toString().toUpperCase() == 'TRANSIT') {
            final td = (step['transit_details'] as Map<String, dynamic>?);
            final ns = td != null ? td['num_stops'] as num? : null;
            if (ns != null) cumStops += ns.toDouble();
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
  static List<TransitLegStops> extractTransitLegStops(
    Map<String, dynamic> directions,
  ) {
    final result = <TransitLegStops>[];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) return result;
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];

      double cumulativeMeters = 0.0;

      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (final s in steps) {
          final step = s as Map<String, dynamic>;
          final dist =
              ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          final stepDistanceMeters = dist?.toDouble() ?? 0.0;
          final mode = step['travel_mode']?.toString().toUpperCase();

          if (mode == 'TRANSIT') {
            final td = step['transit_details'] as Map<String, dynamic>?;
            final numStops = (td?['num_stops'] as num?)?.toInt() ?? 0;

            // Extract line name
            final line = td?['line'] as Map<String, dynamic>?;
            final lineName = (line?['short_name'] ?? line?['name'])?.toString();

            // Get the polyline for this transit leg
            final polylineEncoded =
                (step['polyline'] as Map<String, dynamic>?)?['points']
                    as String? ??
                '';
            final polylinePoints = decodePolyline(polylineEncoded);

            // Calculate stop positions along the polyline
            final stopPositions = estimateStopPositions(
              polylinePoints,
              numStops,
            );

            // Calculate cumulative meters for each stop
            // IMPORTANT: Use stepDistanceMeters (from API) for consistency with progress tracking
            final legStartMeters = cumulativeMeters;
            final legLengthMeters = stepDistanceMeters;

            // Map stop positions to cumulative meters from route start
            // Use step distance (not polyline length) for consistency with progress tracking
            final stopMeters = <double>[];
            if (numStops > 0 && legLengthMeters > 0) {
              final numSegments = numStops + 1;
              for (int i = 1; i <= numStops; i++) {
                // Each stop is at i/(numStops+1) of the leg
                final fractionAlongLeg = i / numSegments;
                final metersAlongLeg = fractionAlongLeg * legLengthMeters;
                stopMeters.add(legStartMeters + metersAlongLeg);
              }
            }

            result.add(
              TransitLegStops(
                legStartMeters: legStartMeters,
                legEndMeters: legStartMeters + stepDistanceMeters,
                numStops: numStops,
                stopPositions: stopPositions,
                stopMeters: stopMeters,
                lineName: lineName,
              ),
            );
          }

          cumulativeMeters += stepDistanceMeters;
        }
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
}
