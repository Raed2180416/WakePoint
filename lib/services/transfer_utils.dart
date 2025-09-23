import 'dart:developer' as dev;

class RouteEventBoundary {
  final double meters;
  final String type; // 'transfer' | 'mode_change'
  final String? label; // e.g., station or mode label
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
  static List<double> buildTransferBoundariesMeters(Map<String, dynamic> directions, {bool metroMode = false}) {
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
          final dist = ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;
          final mode = step['travel_mode'] as String?;
          if (dist != null) cum += dist.toDouble();
          if (mode == 'TRANSIT') {
            // Identify current line id
            final curLine = ((step['transit_details'] as Map<String, dynamic>?)?['line']) as Map<String, dynamic>?;
            final curId = (curLine?['short_name'] ?? curLine?['name'] ?? curLine?['id'])?.toString();
            if (curId == null) continue;
            // Look ahead to the next transit step (skipping walking)
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
              // Boundary at the end of current transit step
              result.add(cum);
            }
          }
        }
      }
    } catch (e) {
      dev.log('Failed to compute transfer boundaries: $e', name: 'TransferUtils');
    }
    return result;
  }

  // Build rich event boundaries for transfers and mode changes along the route.
  static List<RouteEventBoundary> buildRouteEvents(Map<String, dynamic> directions) {
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
          final dist = ((step['distance'] as Map<String, dynamic>?)?['value']) as num?;

          // Mode change event recorded at the boundary between steps (before adding current step distance)
          if (prevMode != null && mode != null && mode != prevMode) {
            final label = _modeLabel(mode);
            events.add(RouteEventBoundary(meters: cum, type: 'mode_change', label: label));
          }
          if (dist != null) cum += dist.toDouble();

          // Transfer event inside TRANSIT: when next transit line differs
          if (mode == 'TRANSIT') {
            final curLine = ((step['transit_details'] as Map<String, dynamic>?)?['line']) as Map<String, dynamic>?;
            final curId = (curLine?['short_name'] ?? curLine?['name'] ?? curLine?['id'])?.toString();
            String? nextTransitId;
            String? arrivalStopName;
            // Use this step's arrival_stop as the transfer label if available
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
    // Deduplicate close events
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

  // Returns a tuple-like map with step boundaries in meters (cumulative across all steps)
  // and cumulative stops at each boundary (TRANSIT steps add num_stops, others add 0).
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
}
