import 'dart:developer' as dev;

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
}
