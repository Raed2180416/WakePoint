// Annotated copy of lib/services/transfer_utils.dart
// Purpose: Explain computation of transfer/mode-change boundaries and stops.

import 'dart:developer' as dev; // Logging for error diagnosis

class RouteEventBoundary {
  final double meters;      // Cumulative meters from route start to the event boundary
  final String type;        // 'transfer' or 'mode_change'
  final String? label;      // Optional label: stop name or mode label
  RouteEventBoundary({required this.meters, required this.type, this.label});
  Map<String, dynamic> toJson() => {
        'meters': meters,
        'type': type,
        if (label != null) 'label': label,
      };
  static RouteEventBoundary fromJson(Map<String, dynamic> m) => RouteEventBoundary(
        meters: (m['meters'] as num).toDouble(),
        type: m['type'] as String,
        label: m['label'] as String?,
      );
}

class TransferUtils {
  // For metroMode=true, return cumulative meter marks where transit lines change
  static List<double> buildTransferBoundariesMeters(Map<String, dynamic> directions, {bool metroMode = false}) {
    final result = <double>[];
    if (!metroMode) return result; // Only used in transit/metro mode
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) return result;
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];
      double cum = 0.0; // Cumulative meters
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (int i = 0; i < steps.length; i++) {
          final step = steps[i] as Map<String, dynamic>;
          final dist = ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          final mode = step['travel_mode'] as String?;
          if (dist != null) cum += dist.toDouble();
          if (mode == 'TRANSIT') {
            final curLine = ((step['transit_details'] as Map<String, dynamic>?)?['line']) as Map<String, dynamic>?;
            final curId = (curLine?['short_name'] ?? curLine?['name'] ?? curLine?['id'])?.toString();
            if (curId == null) continue;
            String? nextTransitId;
            for (int j = i + 1; j < steps.length; j++) {
              final nextStep = steps[j] as Map<String, dynamic>;
              final nextMode = nextStep['travel_mode'] as String?;
              if (nextMode == 'TRANSIT') {
                final nxtLine = ((nextStep['transit_details'] as Map<String, dynamic>?)?['line']) as Map<String, dynamic>?;
                nextTransitId = (nxtLine?['short_name'] ?? nxtLine?['name'] ?? nxtLine?['id'])?.toString();
                break;
              }
            }
            if (nextTransitId != null && nextTransitId != curId) {
              result.add(cum); // Transfer boundary at end of current transit step
            }
          }
        }
      }
    } catch (e) {
      dev.log('Failed to compute transfer boundaries: $e', name: 'TransferUtils');
    }
    return result;
  }

  // Produce rich event boundaries for mode changes and transfers across legs/steps
  static List<RouteEventBoundary> buildRouteEvents(Map<String, dynamic> directions) {
    final events = <RouteEventBoundary>[];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isEmpty) return events;
      final route = routes.first as Map<String, dynamic>;
      final legs = (route['legs'] as List?) ?? const [];
      double cum = 0.0; // meters
      String? prevMode;
      for (final leg in legs) {
        final steps = (leg['steps'] as List?) ?? const [];
        for (int i = 0; i < steps.length; i++) {
          final step = steps[i] as Map<String, dynamic>;
          final mode = step['travel_mode'] as String?;
          final dist = ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;

          // Mode change boundary recorded between steps
          if (prevMode != null && mode != null && mode != prevMode) {
            final label = _modeLabel(mode);
            events.add(RouteEventBoundary(meters: cum, type: 'mode_change', label: label));
          }
          if (dist != null) cum += dist.toDouble();

          // Transfer boundary: next transit line differs
          if (mode == 'TRANSIT') {
            final curLine = ((step['transit_details'] as Map<String, dynamic>?)?['line']) as Map<String, dynamic>?;
            final curId = (curLine?['short_name'] ?? curLine?['name'] ?? curLine?['id'])?.toString();
            String? nextTransitId;
            String? arrivalStopName;
            final arrivalStop = ((step['transit_details'] as Map<String, dynamic>?)?['arrival_stop']) as Map<String, dynamic>?;
            arrivalStopName = arrivalStop != null ? (arrivalStop['name'] as String?) : null;
            for (int j = i + 1; j < steps.length; j++) {
              final nextStep = steps[j] as Map<String, dynamic>;
              final nextMode = nextStep['travel_mode'] as String?;
              if (nextMode == 'TRANSIT') {
                final nxtLine = ((nextStep['transit_details'] as Map<String, dynamic>?)?['line']) as Map<String, dynamic>?;
                nextTransitId = (nxtLine?['short_name'] ?? nxtLine?['name'] ?? nxtLine?['id'])?.toString();
                break;
              }
            }
            if (curId != null && nextTransitId != null && nextTransitId != curId) {
              events.add(RouteEventBoundary(meters: cum, type: 'transfer', label: arrivalStopName));
            }
          }

          if (mode != null) prevMode = mode;
        }
      }
    } catch (e) {
      dev.log('Failed to compute route events: $e', name: 'TransferUtils');
    }

    // Deduplicate near-identical event positions
    events.sort((a, b) => a.meters.compareTo(b.meters));
    final dedup = <RouteEventBoundary>[];
    double? lastM;
    for (final ev in events) {
      if (lastM == null || (ev.meters - lastM).abs() > 1.0) {
        dedup.add(ev);
        lastM = ev.meters;
      }
    }
    return dedup;
  }

  // Build step boundary cumulative meters and stops count across the route
  static ({List<double> bounds, List<double> stops}) buildStepBoundariesAndStops(Map<String, dynamic> directions) {
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
          final dist = ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          if (dist != null) cumM += dist.toDouble();
          if (step['travel_mode'] == 'TRANSIT') {
            final td = (step['transit_details'] as Map<String, dynamic>?);
            final ns = td != null ? td['num_stops'] as num? : null;
            if (ns != null) cumStops += ns.toDouble();
          }
          bounds.add(cumM);
          stops.add(cumStops);
        }
      }
    } catch (e) {
      dev.log('Failed to compute step boundaries/stops: $e', name: 'TransferUtils');
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

  // Cumulative stops before boarding the first transit segment
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
          if (step['travel_mode'] == 'TRANSIT') {
            return cumStops; // stops before boarding first transit
          }
          if (step['travel_mode'] == 'TRANSIT') {
            final td = (step['transit_details'] as Map<String, dynamic>?);
            final ns = td != null ? td['num_stops'] as num? : null;
            if (ns != null) cumStops += ns.toDouble();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  // Compute target cumulative stops N stops prior to a given event index
  static double? nStopsPriorTarget({
    required ({List<double> bounds, List<double> stops}) stepData,
    required List<RouteEventBoundary> events,
    required int eventIndex,
    required double nStops,
  }) {
    if (eventIndex < 0 || eventIndex >= events.length) return null;
    final evM = events[eventIndex].meters;
    double? evStops;
    for (int i = 0; i < stepData.bounds.length; i++) {
      if (evM <= stepData.bounds[i]) { evStops = stepData.stops[i]; break; }
    }
    if (evStops == null) return null;
    final targetStops = (evStops - nStops).clamp(0.0, double.infinity);
    return targetStops;
  }
}
