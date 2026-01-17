// lib/services/tracking/notification_updater.dart
//
// Handles periodic notification updates and state broadcasting.
// - Updates journey progress notification
// - Broadcasts simulation state for dashboard
// - Broadcasts cached route periodically

import 'dart:developer' as dev;

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/services/location_manager.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/transfer_utils.dart';

/// Context for broadcasting state updates.
class BroadcastContext {
  final double? apiEtaSeconds;
  final double? smoothedETA;
  final double distanceTravelledMeters;
  final String? alarmMode;
  final double? alarmValue;
  final bool destinationAlarmFired;
  final DateTime? lastAlarmFiredAt;
  final String? destinationName;

  // Debug telemetry
  final String? activeKey;
  final double? snapOffsetMeters;
  final double? progressMeters;
  final double? progressJumpMeters;
  final String? nextEventType;
  final double? toNextEventMeters;
  final double? polylineTotalMeters;
  final double? stepTotalMeters;

  BroadcastContext({
    this.apiEtaSeconds,
    this.smoothedETA,
    this.distanceTravelledMeters = 0.0,
    this.alarmMode,
    this.alarmValue,
    this.destinationAlarmFired = false,
    this.lastAlarmFiredAt,
    this.destinationName,
    this.activeKey,
    this.snapOffsetMeters,
    this.progressMeters,
    this.progressJumpMeters,
    this.nextEventType,
    this.toNextEventMeters,
    this.polylineTotalMeters,
    this.stepTotalMeters,
  });
}

/// Context for broadcasting route data.
class RouteContext {
  final Map<String, dynamic>? cachedPayload;
  final RouteRegistry registry;
  final String? activeKey;
  final List<TransitLegStops> transitLegStops;
  final bool transitMode;

  RouteContext({
    this.cachedPayload,
    required this.registry,
    this.activeKey,
    this.transitLegStops = const [],
    this.transitMode = false,
  });
}

/// Handles notification updates and state broadcasting.
class NotificationUpdater {
  final bool isTestMode;
  final DateTime? Function()? getLastRouteBroadcastAt;
  final void Function(DateTime?)? setLastRouteBroadcastAt;

  DateTime? _lastRouteBroadcastAt;

  NotificationUpdater({
    this.isTestMode = false,
    this.getLastRouteBroadcastAt,
    this.setLastRouteBroadcastAt,
  });

  DateTime? _getLastBroadcastAt() =>
      getLastRouteBroadcastAt != null
          ? getLastRouteBroadcastAt!()
          : _lastRouteBroadcastAt;

  void _setLastBroadcastAt(DateTime? v) {
    if (setLastRouteBroadcastAt != null) {
      setLastRouteBroadcastAt!(v);
      return;
    }
    _lastRouteBroadcastAt = v;
  }

  /// Broadcast simulation state to dashboard.
  void broadcastSimulationState({
    bool alarmFired = false,
    double? remainingStops,
    required BroadcastContext context,
    Map<String, dynamic>? extraDebugInfo,
  }) {
    final debugInfo = <String, dynamic>{
      'destination': context.destinationName,
      'is_alarm_fired': context.destinationAlarmFired,
    };

    if (extraDebugInfo != null) {
      debugInfo.addAll(extraDebugInfo);
    }

    if (context.activeKey != null) {
      debugInfo['active_key'] = context.activeKey;
    }
    if (context.snapOffsetMeters != null) {
      debugInfo['snap_offset_m'] = context.snapOffsetMeters!.toStringAsFixed(1);
    }
    if (context.progressMeters != null) {
      debugInfo['progress_m'] = context.progressMeters!.toStringAsFixed(0);
    }
    if (context.progressJumpMeters != null) {
      debugInfo['progress_jump_m'] = context.progressJumpMeters!
          .toStringAsFixed(0);
    }
    if (context.nextEventType != null) {
      debugInfo['next_event_type'] = context.nextEventType;
    }
    if (context.toNextEventMeters != null) {
      debugInfo['to_next_event_m'] = context.toNextEventMeters!.toStringAsFixed(
        0,
      );
    }
    if (context.polylineTotalMeters != null) {
      debugInfo['poly_total_m'] = context.polylineTotalMeters!.toStringAsFixed(
        0,
      );
    }
    if (context.stepTotalMeters != null) {
      debugInfo['step_total_m'] = context.stepTotalMeters!.toStringAsFixed(0);
    }

    LocationManager().broadcastState(
      alarmFired: alarmFired,
      remainingStops: remainingStops,
      debugInfo: debugInfo,
      apiEtaSeconds: context.apiEtaSeconds,
      smoothedETA: context.smoothedETA,
      distanceTravelledMeters: context.distanceTravelledMeters,
      alarmMode: context.alarmMode,
      alarmValue: context.alarmValue,
      destinationAlarmFired: context.destinationAlarmFired,
      lastAlarmFiredAt: context.lastAlarmFiredAt,
    );
  }

  /// Build list of inactive routes for dashboard visualization.
  List<Map<String, dynamic>> getInactiveRoutesPayload(RouteContext context) {
    final activeKey = context.activeKey;
    final inactive = <Map<String, dynamic>>[];

    for (final entry in context.registry.entries) {
      if (entry.key == activeKey) continue;
      inactive.add({
        'key': entry.key,
        'points':
            entry.points
                .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                .toList(),
        'destinationName': entry.destinationName,
      });
    }

    dev.log(
      'getInactiveRoutesPayload found ${inactive.length} routes (Active: $activeKey, Total: ${context.registry.entries.length})',
      name: 'NotificationUpdater',
    );
    return inactive;
  }

  /// Broadcast cached route to dashboard (throttled).
  void maybeBroadcastCachedRoute({
    required RouteContext context,
    bool force = false,
  }) {
    try {
      final payload = context.cachedPayload;
      if (payload == null) return;

      final last = _getLastBroadcastAt();
      if (!force &&
          last != null &&
          DateTime.now().difference(last).inSeconds < 20) {
        return;
      }

      final inactivePayload = getInactiveRoutesPayload(context);
      if (inactivePayload.isNotEmpty) {
        dev.log(
          'Broadcasting route with ${inactivePayload.length} inactive routes',
          name: 'NotificationUpdater',
        );
      }

      _setLastBroadcastAt(DateTime.now());

      // Flatten transit stop meters for dashboard visualization
      final List<double>? stopMeters =
          context.transitLegStops.isEmpty
              ? null
              : context.transitLegStops.expand((l) => l.stopMeters).toList();

      // Full transit legs payload (authoritative runtime view)
      final List<Map<String, dynamic>>? transitLegsJson =
          context.transitLegStops.isEmpty
              ? null
              : context.transitLegStops.map((l) => l.toJson()).toList();

      LocationManager().broadcastRoute(
        routeKey: context.activeKey,
        destinationName: payload['destinationName'] as String,
        points: (payload['points'] as List).cast<Map<String, dynamic>>(),
        segments: (payload['segments'] as List?)?.cast<Map<String, dynamic>>(),
        switchPoints:
            (payload['switch_points'] as List?)?.cast<Map<String, dynamic>>(),
        events: (payload['events'] as List?)?.cast<Map<String, dynamic>>(),
        stopMeters: stopMeters,
        transitLegs: transitLegsJson,
        inactiveRoutes: inactivePayload,
        transitMode: payload['transit_mode'] as bool?,
        routeDebug: (payload['route_debug'] as Map?)?.cast<String, dynamic>(),
      );
    } catch (e) {
      trackingLog.debug(
        'Route broadcast failed',
        data: {'error': e.toString()},
      );
    }
  }

  /// Update the journey progress notification based on current state.
  void updateNotification({
    required RouteRegistry registry,
    required bool allowRouteProgressFromRoutes,
    required LatLng? destination,
    required String? destinationName,
    required LatLng? lastProcessedPosition,
  }) {
    try {
      if (isTestMode || destination == null) return;

      // Preserve legacy TrackingService behavior: only show route-progress
      // notifications when an active route manager exists.
      if (!allowRouteProgressFromRoutes) {
        // Fallback: use straight-line distance
        if (lastProcessedPosition != null) {
          final distanceInMeters = Geolocator.distanceBetween(
            lastProcessedPosition.latitude,
            lastProcessedPosition.longitude,
            destination.latitude,
            destination.longitude,
          );

          final remainingKm = (distanceInMeters / 1000.0).toStringAsFixed(1);
          dev.log(
            'Simple notification update: remaining $remainingKm km',
            name: 'NotificationUpdater',
          );

          NotificationService().showJourneyProgress(
            title:
                destinationName != null
                    ? 'Journey to $destinationName'
                    : 'GeoWake journey',
            subtitle: 'Remaining: $remainingKm km',
            progress0to1: 0.0,
          );
        }

        return;
      }

      // Get latest state from registry
      if (registry.entries.isNotEmpty) {
        RouteEntry? entry;

        try {
          RouteEntry? bestEntry;
          for (final e in registry.entries) {
            if (e.lastProgressMeters != null) {
              if (bestEntry == null || e.lastUsed.isAfter(bestEntry.lastUsed)) {
                bestEntry = e;
              }
            }
          }

          entry = bestEntry ?? registry.entries.first;
        } catch (_) {
          if (registry.entries.isNotEmpty) {
            entry = registry.entries.first;
          }
        }

        if (entry != null) {
          final total = entry.lengthMeters;
          final progressMeters = entry.lastProgressMeters ?? 0.0;
          final progress =
              total > 0 ? (progressMeters / total).clamp(0.0, 1.0) : 0.0;
          final remainingMeters = total - progressMeters;

          final progressPercent = (progress * 100)
              .clamp(0.0, 100.0)
              .toStringAsFixed(1);
          final remainingKm = (remainingMeters / 1000.0).toStringAsFixed(1);

          dev.log(
            'Notification update: $progressPercent% | remaining $remainingKm km',
            name: 'NotificationUpdater',
          );

          NotificationService().showJourneyProgress(
            title:
                destinationName != null
                    ? 'Journey to $destinationName'
                    : 'GeoWake journey',
            subtitle: 'Remaining: $remainingKm km',
            progress0to1: progress,
          );

          return;
        }
      }

      // Fallback: use straight-line distance
      if (lastProcessedPosition != null) {
        final distanceInMeters = Geolocator.distanceBetween(
          lastProcessedPosition.latitude,
          lastProcessedPosition.longitude,
          destination.latitude,
          destination.longitude,
        );

        final remainingKm = (distanceInMeters / 1000.0).toStringAsFixed(1);
        dev.log(
          'Simple notification update: remaining $remainingKm km',
          name: 'NotificationUpdater',
        );

        NotificationService().showJourneyProgress(
          title:
              destinationName != null
                  ? 'Journey to $destinationName'
                  : 'GeoWake journey',
          subtitle: 'Remaining: $remainingKm km',
          progress0to1: 0.0,
        );
      }
    } catch (e) {
      dev.log('Error updating notification: $e', name: 'NotificationUpdater');
    }
  }
}
