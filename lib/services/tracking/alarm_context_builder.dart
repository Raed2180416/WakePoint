// lib/services/tracking/alarm_context_builder.dart
//
// Builds an AlarmContext from TrackingService/session state.

import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/snap_to_route.dart';
import 'package:geowake2/services/transfer_utils.dart';

import 'alarm_controller.dart';

class AlarmContextBuilder {
  static AlarmContext build({
    required RouteRegistry registry,
    required LatLng? destination,
    required String? alarmMode,
    required double? alarmValue,
    required bool trackingSessionActive,
    required bool isBackgroundIsolate,
    required bool isTestMode,
    required String? alarmKey,
    required double? progressMeters,
    required SnapResult? lastSnapResult,
    required Map<String, List<RouteEventBoundary>> routeEventsByKey,
    required List<RouteEventBoundary> fallbackRouteEvents,
    required Map<String, List<TransitLegStops>> transitLegStopsByKey,
    required List<TransitLegStops> fallbackTransitLegStops,
    required Map<String, List<double>> stepBoundsMetersByKey,
    required List<double> fallbackStepBoundsMeters,
    required Map<String, List<double>> stepStopsCumulativeByKey,
    required List<double> fallbackStepStopsCumulative,
    required Map<String, List<int>> stepDurationsSecondsByKey,
    required List<int> fallbackStepDurationsSeconds,
    required double? smoothedSpeed,
    required double? smoothedETA,
    required double? lastSpeedMps,
    required bool timeAlarmEligible,
    required int etaSamples,
    required double distanceTravelledMeters,
  }) {
    final routeEvents =
        (alarmKey != null && routeEventsByKey.containsKey(alarmKey))
            ? (routeEventsByKey[alarmKey] ?? const <RouteEventBoundary>[])
            : fallbackRouteEvents;

    final transitLegs =
        (alarmKey != null && transitLegStopsByKey.containsKey(alarmKey))
            ? (transitLegStopsByKey[alarmKey] ?? const <TransitLegStops>[])
            : fallbackTransitLegStops;

    final stepBoundsMeters =
        (alarmKey != null && stepBoundsMetersByKey.containsKey(alarmKey))
            ? (stepBoundsMetersByKey[alarmKey] ?? const <double>[])
            : fallbackStepBoundsMeters;

    final stepDurationsSeconds =
        (alarmKey != null && stepDurationsSecondsByKey.containsKey(alarmKey))
            ? (stepDurationsSecondsByKey[alarmKey] ?? const <int>[])
            : fallbackStepDurationsSeconds;

    final stepStopsCumulative =
        (alarmKey != null && stepStopsCumulativeByKey.containsKey(alarmKey))
            ? (stepStopsCumulativeByKey[alarmKey] ?? const <double>[])
            : fallbackStepStopsCumulative;

    return AlarmContext(
      destination: destination,
      alarmMode: alarmMode,
      alarmValue: alarmValue,
      trackingSessionActive: trackingSessionActive,
      isBackgroundIsolate: isBackgroundIsolate,
      isTestMode: isTestMode,
      registry: registry,
      activeKey: alarmKey,
      progressMeters: progressMeters,
      lastSnapResult: lastSnapResult,
      routeEvents: routeEvents,
      transitLegs: transitLegs,
      stepBoundsMeters: stepBoundsMeters,
      stepStopsCumulative: stepStopsCumulative,
      stepDurationsSeconds: stepDurationsSeconds,
      smoothedSpeed: smoothedSpeed,
      smoothedETA: smoothedETA,
      lastSpeedMps: lastSpeedMps,
      timeAlarmEligible: timeAlarmEligible,
      etaSamples: etaSamples,
      distanceTravelledMeters: distanceTravelledMeters,
    );
  }
}
