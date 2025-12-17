import 'dart:developer' as dev;
import 'package:geowake2/services/polyline_decoder.dart';

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
          if (mode?.toUpperCase() == 'TRANSIT') {
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
              if (nextMode?.toUpperCase() == 'TRANSIT') {
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
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (int i = 0; i < steps.length; i++) {
          final step = steps[i] as Map<String, dynamic>;
          final mode = step['travel_mode'] as String?;
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
            // Filter trivial Walking <-> Driving changes per user request
            final pm = prevMode.toUpperCase();
            final cm = mode.toUpperCase();
            final isWalkingDriving =
                (pm == 'WALKING' && cm == 'DRIVING') ||
                (pm == 'DRIVING' && cm == 'WALKING');

            if (!isWalkingDriving) {
              final label = _modeLabel(mode);
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
          if (dist != null) cum += dist.toDouble();

          // Transfer event inside TRANSIT: when next transit line differs
          if (mode?.toUpperCase() == 'TRANSIT') {
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
            for (int j = i + 1; j < steps.length; j++) {
              final nextStep = steps[j] as Map<String, dynamic>;
              final nextMode = nextStep['travel_mode'] as String?;
              if (nextMode?.toUpperCase() == 'TRANSIT') {
                final nxtLine =
                    ((nextStep['transit_details']
                            as Map<String, dynamic>?)?['line'])
                        as Map<String, dynamic>?;
                nextTransitId =
                    (nxtLine?['short_name'] ??
                            nxtLine?['name'] ??
                            nxtLine?['id'])
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

  // Returns a tuple-like map with step boundaries in meters (cumulative across all steps)
  // and cumulative stops at each boundary (TRANSIT steps add num_stops, others add 0).
  static ({List<double> bounds, List<double> stops})
  buildStepBoundariesAndStops(Map<String, dynamic> directions) {
    final bounds = <double>[];
    final stops = <double>[];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) return (bounds: bounds, stops: stops);
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
          if (dist != null) cumM += dist.toDouble();
          if (step['travel_mode']?.toString().toUpperCase() == 'TRANSIT') {
            final td = (step['transit_details'] as Map<String, dynamic>?);
            final ns = td != null ? td['num_stops'] as num? : null;
            if (ns != null) cumStops += ns.toDouble();
          }
          bounds.add(cumM);
          stops.add(cumStops);
        }
      }
    } catch (e) {
      dev.log(
        'Failed to compute step boundaries/stops: $e',
        name: 'TransferUtils',
      );
    }
    return (bounds: bounds, stops: stops);
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
