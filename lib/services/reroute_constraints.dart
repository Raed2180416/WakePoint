/// Validates that rerouted paths respect original alarm constraints.
///
/// When a user deviates and we fetch a new route, this class ensures
/// the new route is compatible with the user's original alarm settings.
/// If constraints are violated, tracking should terminate gracefully.
library;

import 'package:geowake2/services/transfer_utils.dart';

/// Result of constraint validation with details about any failures.
class RerouteValidationResult {
  final bool isValid;
  final String? failureReason;
  final String? userMessage;

  const RerouteValidationResult.valid()
    : isValid = true,
      failureReason = null,
      userMessage = null;

  const RerouteValidationResult.invalid({
    required this.failureReason,
    required this.userMessage,
  }) : isValid = false;

  @override
  String toString() => isValid ? 'Valid' : 'Invalid: $failureReason';
}

/// Constraints that must be satisfied by any rerouted path.
class RerouteConstraints {
  /// The alarm mode: 'stops', 'time', or 'distance'
  final String alarmMode;

  /// The alarm threshold value (stops count, minutes, or km)
  final double alarmValue;

  /// Whether the original route was transit-based
  final bool transitMode;

  /// Maximum allowed transfers (if user specified)
  final int? maxTransfers;

  const RerouteConstraints({
    required this.alarmMode,
    required this.alarmValue,
    required this.transitMode,
    this.maxTransfers,
  });

  /// Validates whether a new directions response satisfies these constraints.
  ///
  /// Returns a [RerouteValidationResult] with details about any failures.
  RerouteValidationResult validate(Map<String, dynamic> newDirections) {
    try {
      // 1. Check transit mode compatibility
      if (transitMode) {
        final hasMetro = _routeHasMetroLeg(newDirections);
        if (!hasMetro) {
          return const RerouteValidationResult.invalid(
            failureReason:
                'transit (metro) mode required but new route has no metro legs',
            userMessage:
                'Tracking ended: Alternate route has no metro service (you selected metro mode)',
          );
        }
      }

      // 2. Check alarm mode compatibility
      if (alarmMode == 'stops') {
        final totalStops = _extractTotalStops(newDirections);
        if (totalStops == 0) {
          return const RerouteValidationResult.invalid(
            failureReason:
                'Stop-based alarm requires transit stops but route has none',
            userMessage:
                'Tracking ended: New route has no transit stops for your stops-based alarm',
          );
        }
        // Check if alarm value exceeds available stops
        if (alarmValue > totalStops) {
          return RerouteValidationResult.invalid(
            failureReason:
                'Alarm value ($alarmValue stops) exceeds available stops ($totalStops)',
            userMessage:
                'Tracking ended: New route only has $totalStops stops (alarm set for ${alarmValue.toInt()} stops before arrival)',
          );
        }
      }

      // 3. Check alarm value feasibility
      if (alarmMode == 'time') {
        final totalDurationMin = _getTotalDuration(newDirections) / 60.0;
        if (totalDurationMin <= 0) {
          return const RerouteValidationResult.invalid(
            failureReason: 'Could not determine route duration',
            userMessage:
                'Tracking ended: Unable to calculate travel time for new route',
          );
        }
        // If alarm value >= total duration, alarm would fire immediately or never
        if (alarmValue >= totalDurationMin) {
          return RerouteValidationResult.invalid(
            failureReason:
                'Time alarm ($alarmValue min) exceeds route duration (${totalDurationMin.toStringAsFixed(1)} min)',
            userMessage:
                'Tracking ended: New route is only ${totalDurationMin.toStringAsFixed(0)} minutes (your alarm is set for ${alarmValue.toInt()} min before arrival)',
          );
        }
      }

      if (alarmMode == 'distance') {
        final totalDistanceKm = _getTotalDistance(newDirections) / 1000.0;
        if (totalDistanceKm <= 0) {
          return const RerouteValidationResult.invalid(
            failureReason: 'Could not determine route distance',
            userMessage:
                'Tracking ended: Unable to calculate distance for new route',
          );
        }
        // If alarm value >= total distance, alarm would fire immediately or never
        if (alarmValue >= totalDistanceKm) {
          return RerouteValidationResult.invalid(
            failureReason:
                'Distance alarm ($alarmValue km) exceeds route distance (${totalDistanceKm.toStringAsFixed(1)} km)',
            userMessage:
                'Tracking ended: New route is only ${totalDistanceKm.toStringAsFixed(1)} km (your alarm is set for ${alarmValue.toStringAsFixed(1)} km before arrival)',
          );
        }
      }

      // 4. Check transfer count if constrained
      if (maxTransfers != null && transitMode) {
        final transfers = _countTransfers(newDirections);
        if (transfers > maxTransfers!) {
          return RerouteValidationResult.invalid(
            failureReason: 'Too many transfers: $transfers > $maxTransfers',
            userMessage:
                'Tracking ended: New route requires $transfers transfers (max allowed: $maxTransfers)',
          );
        }
      }

      return const RerouteValidationResult.valid();
    } catch (e) {
      return RerouteValidationResult.invalid(
        failureReason: 'Validation error: $e',
        userMessage: 'Tracking ended: Unable to validate alternate route',
      );
    }
  }

  /// Check if the route has any transit legs.
  bool _routeHasMetroLeg(Map<String, dynamic> directions) {
    try {
      final routes = directions['routes'] as List?;
      if (routes == null || routes.isEmpty) return false;

      final route = routes.first as Map<String, dynamic>;
      final legs = route['legs'] as List?;
      if (legs == null) return false;

      for (final leg in legs) {
        final steps = (leg as Map<String, dynamic>)['steps'] as List?;
        if (steps == null) continue;
        for (final s in steps) {
          final step = s as Map<String, dynamic>;
          final travelMode = (step['travel_mode'] as String?)?.toUpperCase();
          if (travelMode != 'TRANSIT') continue;
          final td = step['transit_details'] as Map<String, dynamic>?;
          final line = td?['line'] as Map<String, dynamic>?;
          final vehicle = line?['vehicle'] as Map<String, dynamic>?;
          final vType = (vehicle?['type'] as String?)?.toUpperCase();
          if (vType == null) continue;
          if (vType == 'SUBWAY' ||
              vType == 'HEAVY_RAIL' ||
              vType == 'RAIL' ||
              vType == 'METRO_RAIL' ||
              vType == 'MONORAIL') {
            return true;
          }
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Extract total number of transit stops from directions.
  int _extractTotalStops(Map<String, dynamic> directions) {
    try {
      final transitLegs = TransferUtils.extractTransitLegStops(directions);
      int total = 0;
      for (final leg in transitLegs) {
        total += leg.numStops;
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Get total route duration in seconds.
  double _getTotalDuration(Map<String, dynamic> directions) {
    try {
      final routes = directions['routes'] as List?;
      if (routes == null || routes.isEmpty) return 0;

      final route = routes.first as Map<String, dynamic>;
      final legs = route['legs'] as List?;
      if (legs == null) return 0;

      double total = 0;
      for (final leg in legs) {
        final duration =
            (leg as Map<String, dynamic>)['duration'] as Map<String, dynamic>?;
        if (duration != null) {
          total += (duration['value'] as num?)?.toDouble() ?? 0;
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Get total route distance in meters.
  double _getTotalDistance(Map<String, dynamic> directions) {
    try {
      final routes = directions['routes'] as List?;
      if (routes == null || routes.isEmpty) return 0;

      final route = routes.first as Map<String, dynamic>;
      final legs = route['legs'] as List?;
      if (legs == null) return 0;

      double total = 0;
      for (final leg in legs) {
        final distance =
            (leg as Map<String, dynamic>)['distance'] as Map<String, dynamic>?;
        if (distance != null) {
          total += (distance['value'] as num?)?.toDouble() ?? 0;
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Count number of transit transfers in the route.
  int _countTransfers(Map<String, dynamic> directions) {
    try {
      final routes = directions['routes'] as List?;
      if (routes == null || routes.isEmpty) return 0;

      final route = routes.first as Map<String, dynamic>;
      final legs = route['legs'] as List?;
      if (legs == null) return 0;

      int transitCount = 0;
      for (final leg in legs) {
        final steps = (leg as Map<String, dynamic>)['steps'] as List?;
        if (steps == null) continue;

        for (final step in steps) {
          final travelMode =
              (step as Map<String, dynamic>)['travel_mode'] as String?;
          if (travelMode?.toUpperCase() == 'TRANSIT') {
            transitCount++;
          }
        }
      }
      // Transfers = transit legs - 1 (first boarding is not a transfer)
      return transitCount > 0 ? transitCount - 1 : 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  String toString() =>
      'RerouteConstraints(mode=$alarmMode, value=$alarmValue, transit=$transitMode)';
}
