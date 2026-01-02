// lib/services/tracking/alarm_controller.dart
//
// Handles all alarm evaluation and triggering logic.
// - Evaluates alarm conditions based on position, mode, events
// - Triggers notifications via background isolate bridge
// - Manages alarm poll timer for responsive UI actions

import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/snap_to_route.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/transfer_utils.dart';

/// Context needed for alarm evaluation.
class AlarmContext {
  final LatLng? destination;
  final String? alarmMode;
  final double? alarmValue;
  final bool trackingSessionActive;
  final bool isBackgroundIsolate;
  final bool isTestMode;

  // Route progress
  final RouteRegistry registry;
  final String? activeKey;
  final double? progressMeters;
  final SnapResult? lastSnapResult;

  // Events and legs
  final List<RouteEventBoundary> routeEvents;
  final List<TransitLegStops> transitLegs;
  final List<double> stepBoundsMeters;
  final List<double> stepStopsCumulative;
  final List<int> stepDurationsSeconds; // API step durations for hybrid ETA

  // Speed/ETA
  final double? smoothedSpeed;
  final double? smoothedETA;
  final double? lastSpeedMps;
  final bool timeAlarmEligible;
  final int etaSamples;
  final double distanceTravelledMeters;

  AlarmContext({
    this.destination,
    this.alarmMode,
    this.alarmValue,
    this.trackingSessionActive = false,
    this.isBackgroundIsolate = false,
    this.isTestMode = false,
    required this.registry,
    this.activeKey,
    this.progressMeters,
    this.lastSnapResult,
    this.routeEvents = const [],
    this.transitLegs = const [],
    this.stepBoundsMeters = const [],
    this.stepStopsCumulative = const [],
    this.stepDurationsSeconds = const [],
    this.smoothedSpeed,
    this.smoothedETA,
    this.lastSpeedMps,
    this.timeAlarmEligible = false,
    this.etaSamples = 0,
    this.distanceTravelledMeters = 0.0,
  });
}

/// Manages alarm evaluation, triggering, and related state.
class AlarmController {
  // Alarm state per route key
  final Map<String, bool> _destinationAlarmFiredByKey = {};
  final Map<String, Set<int>> _firedEventIndexesByKey = {};
  final Map<String, Set<String>> _firedLegIdsByKey =
      {}; // Track fired legs (one alarm per leg)

  // Legacy single-route state
  bool _destinationAlarmFired = false;
  final Set<int> _firedEventIndexes = {};
  final Set<String> _firedLegIds = {}; // Legacy single-route leg tracking

  // Alarm poll timer
  Timer? _alarmStopPollTimer;

  // Last alarm time for rate limiting
  DateTime? _lastAlarmFiredAt;

  // Callback for when destination alarm fires (to block route switching)
  void Function(bool fired)? onDestinationAlarmFired;

  /// Get whether destination alarm has fired for the given route key.
  bool destinationAlarmFiredForKey(String? key) {
    if (key == null) return _destinationAlarmFired;
    return _destinationAlarmFiredByKey[key] ?? false;
  }

  /// Set destination alarm fired state for the given route key.
  void setDestinationAlarmFiredForKey(String? key, bool value) {
    if (key == null) {
      _destinationAlarmFired = value;
    } else {
      _destinationAlarmFiredByKey[key] = value;
    }
    if (value) {
      onDestinationAlarmFired?.call(true);
    }
  }

  /// Get fired event indexes for the given route key.
  Set<int> firedIndexesForKey(String? key) {
    if (key == null) return _firedEventIndexes;
    return _firedEventIndexesByKey.putIfAbsent(key, () => <int>{});
  }

  /// Check if any destination alarm has fired (legacy single-route or keyed).
  bool get anyDestinationAlarmFired =>
      _destinationAlarmFired ||
      _destinationAlarmFiredByKey.values.any((v) => v);

  DateTime? get lastAlarmFiredAt => _lastAlarmFiredAt;

  /// Mark that an alarm has been fired (sets timestamp).
  /// Call this when triggering alarms directly without using triggerAlarmNotification.
  void markAlarmFired() {
    _lastAlarmFiredAt = DateTime.now();
  }

  /// Get fired leg IDs for the given route key (one alarm per leg enforcement).
  Set<String> firedLegIdsForKey(String? key) {
    if (key == null) return _firedLegIds;
    return _firedLegIdsByKey.putIfAbsent(key, () => <String>{});
  }

  /// Migrate alarm state from one key to another (e.g. on route switch).
  void migrateAlarmState(String fromKey, String toKey) {
    dev.log(
      'AlarmController: migrating state from $fromKey to $toKey',
      name: 'AlarmController',
    );
    if (_destinationAlarmFiredByKey.containsKey(fromKey)) {
      _destinationAlarmFiredByKey[toKey] =
          _destinationAlarmFiredByKey[fromKey]!;
    }
    if (_firedEventIndexesByKey.containsKey(fromKey)) {
      _firedEventIndexesByKey[toKey] = Set.from(
        _firedEventIndexesByKey[fromKey]!,
      );
    }
    if (_firedLegIdsByKey.containsKey(fromKey)) {
      _firedLegIdsByKey[toKey] = Set.from(_firedLegIdsByKey[fromKey]!);
    }
  }

  /// Mark a leg as having fired its alarm.
  void markLegFired(String? key, String legId) {
    if (key == null) {
      _firedLegIds.add(legId);
    } else {
      _firedLegIdsByKey.putIfAbsent(key, () => <String>{}).add(legId);
    }
  }

  /// Check if a leg has already fired its alarm.
  bool hasLegFired(String? key, String legId) {
    if (key == null) return _firedLegIds.contains(legId);
    return _firedLegIdsByKey[key]?.contains(legId) ?? false;
  }

  /// Reset all alarm state. Called when progress slider moves back or new route.
  void resetAlarmState() {
    dev.log('AlarmController: resetting alarm flags', name: 'AlarmController');
    _destinationAlarmFired = false;
    _firedEventIndexes.clear();
    _firedEventIndexesByKey.clear();
    _destinationAlarmFiredByKey.clear();
    _firedLegIds.clear();
    _firedLegIdsByKey.clear();

    // Stop any currently playing alarm
    AlarmPlayer.stop();
    NotificationService().stopVibration();
  }

  /// Clear all state for a fresh session.
  void clear() {
    resetAlarmState();
    _lastAlarmFiredAt = null;
    _alarmStopPollTimer?.cancel();
    _alarmStopPollTimer = null;
  }

  /// Trigger alarm notification - handles background isolate case.
  Future<void> triggerAlarmNotification({
    required ServiceInstance service,
    required String title,
    required String body,
    required bool allowContinueTracking,
    required bool isBackgroundIsolate,
    required bool isTestMode,
    String? debugReason,
  }) async {
    dev.log(
      'TRIGGERING ALARM [Reason: $debugReason]: $title - $body',
      name: 'AlarmController',
    );

    _lastAlarmFiredAt = DateTime.now();

    if (isTestMode) {
      // In test mode, call notification service directly
      await NotificationService().showWakeUpAlarm(
        title: title,
        body: body,
        allowContinueTracking: allowContinueTracking,
      );
      return;
    }

    if (isBackgroundIsolate) {
      // Background isolate cannot show notifications directly
      service.invoke('triggerAlarm', {
        'title': title,
        'body': body,
        'allowContinue': allowContinueTracking,
      });
    } else {
      // Foreground isolate - can show notifications directly
      await NotificationService().showWakeUpAlarm(
        title: title,
        body: body,
        allowContinueTracking: allowContinueTracking,
      );
    }
  }

  /// Check and trigger alarms based on current position and context.
  Future<void> checkAndTriggerAlarm({
    required Position currentPosition,
    required ServiceInstance service,
    required AlarmContext context,
    void Function()? onAlarmFired,
  }) async {
    if (!context.trackingSessionActive) return;
    if (context.destination == null || context.alarmValue == null) return;

    final alarmKey = context.activeKey;
    final progressMeters = context.progressMeters;

    // Prepare active events
    final List<RouteEventBoundary> activeEvents = List<RouteEventBoundary>.from(
      context.routeEvents,
    );

    final mainRouteLen =
        context.stepBoundsMeters.isNotEmpty
            ? context.stepBoundsMeters.last
            : 0.0;

    // Add synthetic Destination event if missing
    if (mainRouteLen > 0 && !activeEvents.any((e) => e.type == 'destination')) {
      activeEvents.add(
        RouteEventBoundary(
          meters: mainRouteLen,
          type: 'destination',
          label: 'Destination',
        ),
      );
    }

    // Use AlarmEvaluator if we have route context
    if (activeEvents.isNotEmpty && progressMeters != null) {
      await _evaluateWithRoute(
        currentPosition: currentPosition,
        service: service,
        context: context,
        alarmKey: alarmKey,
        progressMeters: progressMeters,
        activeEvents: activeEvents,
        onAlarmFired: onAlarmFired,
      );
    } else if (context.destination != null &&
        !destinationAlarmFiredForKey(alarmKey)) {
      // Fallback: Simple geofence without route
      await _evaluateGeofence(
        currentPosition: currentPosition,
        service: service,
        context: context,
        alarmKey: alarmKey,
        onAlarmFired: onAlarmFired,
      );
    }
  }

  Future<void> _evaluateWithRoute({
    required Position currentPosition,
    required ServiceInstance service,
    required AlarmContext context,
    required String? alarmKey,
    required double progressMeters,
    required List<RouteEventBoundary> activeEvents,
    void Function()? onAlarmFired,
  }) async {
    // Determine current speed
    double? currentSpeed = context.smoothedSpeed;
    if (currentSpeed == null || currentSpeed <= 0.5) {
      currentSpeed = context.lastSpeedMps;
    }

    // Determine leg start (for 60% rule)
    double legStartMeters = 0.0;
    try {
      final passedEvent = activeEvents.lastWhere(
        (e) => e.meters <= progressMeters,
        orElse: () => activeEvents.first,
      );
      if (passedEvent.meters <= progressMeters) {
        legStartMeters = passedEvent.meters;
      }
    } catch (_) {}

    // Map mode
    final modeEnum =
        context.alarmMode == 'stops'
            ? AlarmMode.stops
            : context.alarmMode == 'time'
            ? AlarmMode.time
            : AlarmMode.distance;

    // TIME ALARM ELIGIBILITY GATE:
    // Skip time alarm evaluation if eligibility gates not met
    // (100m traveled, 3 GPS samples, 30s tracking duration)
    if (modeEnum == AlarmMode.time &&
        !context.timeAlarmEligible &&
        !context.isTestMode) {
      dev.log(
        'Time alarm evaluation skipped - eligibility not met '
        '(dist: ${context.distanceTravelledMeters.toStringAsFixed(0)}m, '
        'samples: ${context.etaSamples}, eligible: ${context.timeAlarmEligible})',
        name: 'AlarmController',
      );
      return;
    }

    // Determine if on metro leg OR in an interchange walk between metro legs.
    // This prevents spurious preBoarding/modeChange alarms during platform transfers.
    bool isCurrentlyOnMetroLeg = false;
    bool hasEnteredAnyMetroLeg = false;
    double? lastMetroLegEnd;

    for (final leg in context.transitLegs) {
      if (leg.isMetro) {
        // Check if currently within this metro leg
        if (progressMeters >= leg.legStartMeters &&
            progressMeters <= leg.legEndMeters) {
          isCurrentlyOnMetroLeg = true;
        }
        // Track if user has entered any metro leg
        if (progressMeters >= leg.legStartMeters) {
          hasEnteredAnyMetroLeg = true;
        }
        // Track the end of the last metro leg
        if (lastMetroLegEnd == null || leg.legEndMeters > lastMetroLegEnd) {
          lastMetroLegEnd = leg.legEndMeters;
        }
      }
    }

    // If user has entered a metro leg but hasn't passed the last metro leg end,
    // they're in a "transit journey" (could be interchange walk between metros).
    // Treat interchange walks as metro context to prevent spurious preBoarding alarms.
    if (!isCurrentlyOnMetroLeg &&
        hasEnteredAnyMetroLeg &&
        lastMetroLegEnd != null &&
        progressMeters < lastMetroLegEnd) {
      // User is in an interchange walk between metro legs
      isCurrentlyOnMetroLeg = true;
    }

    // Determine current leg index based on progress
    int currentLegIndex = -1;
    bool isFinalLeg = false;

    if (context.transitLegs.isNotEmpty) {
      for (int i = 0; i < context.transitLegs.length; i++) {
        final leg = context.transitLegs[i];
        if (progressMeters >= leg.legStartMeters &&
            progressMeters <= leg.legEndMeters) {
          currentLegIndex = i;
          break;
        }
      }
      // Handle overshoot or undershoot
      if (currentLegIndex == -1) {
        if (progressMeters > context.transitLegs.last.legEndMeters) {
          currentLegIndex = context.transitLegs.length - 1;
        } else {
          currentLegIndex = 0; // Default to first if before start
        }
      }
      isFinalLeg = (currentLegIndex == context.transitLegs.length - 1);
    }

    // ============ ALARM CONTROLLER DEBUG ============
    print('┌─────────────────────────────────────────────────────────────');
    print('│ ALARM CHECK: ${DateTime.now()}');
    print('│ Controller Instance: ${hashCode}'); // Log Instance ID
    print(
      '│ ALARM_CTRL: mode=$modeEnum, progress=${progressMeters.toStringAsFixed(0)}m',
    );
    if (context.transitLegs.isNotEmpty) {
      final l0 = context.transitLegs[0];
      print(
        '│ Leg[0] hash: ${l0.hashCode}, stops: ${l0.numStops}, name: ${l0.lineName}',
      );
    }
    print(
      '│ transitLegs.length=${context.transitLegs.length}, currentLegIndex=$currentLegIndex',
    );
    if (context.transitLegs.isNotEmpty &&
        currentLegIndex >= 0 &&
        currentLegIndex < context.transitLegs.length) {
      final leg = context.transitLegs[currentLegIndex];
      print(
        '│ currentLeg: ${leg.lineName}, isMetro=${leg.isMetro}, range=${leg.legStartMeters.toStringAsFixed(0)}-${leg.legEndMeters.toStringAsFixed(0)}m',
      );
    }
    print('└─────────────────────────────────────────────────────────────');

    // Eagerly fetch the fired set to debug its state
    final firedSet = firedLegIdsForKey(alarmKey);
    print('│ ALARM_CTRL_DEBUG: key="$alarmKey", firedLegs=$firedSet');

    // Evaluate
    try {
      final trigger = AlarmEvaluator.evaluateCoinciding(
        mode: modeEnum,
        userValue: context.alarmValue!,
        progressMeters: progressMeters,
        allEvents: activeEvents,
        firedEventIndexes: firedIndexesForKey(alarmKey),
        firedLegIds: firedSet, // One alarm per leg
        isMetroLeg:
            isCurrentlyOnMetroLeg, // (Ignored by new logic in favor of leg.isMetro)
        transitLegs: context.transitLegs,
        currentLegIndex: currentLegIndex,
        isFinalLeg: isFinalLeg,
        stepBoundsMeters: context.stepBoundsMeters, // For hybrid ETA
        stepDurationsSeconds: context.stepDurationsSeconds, // API durations
        currentSpeedMps: currentSpeed,
        legStartMeters: legStartMeters,
      );

      if (trigger != null) {
        bool suppress = false;

        // Settings: allow users to disable preboarding without affecting
        // other alarm types.
        // NOTE: Must use async method because background isolate has separate
        // SharedPreferences cache; reload() ensures fresh values.
        if (trigger.eventType == AlarmEventType.preBoarding) {
          final preboardingOn = await TrackingStateStore.preboardingEnabled();
          if (!preboardingOn) {
            suppress = true;
          }
        }

        // Destination protection
        if (trigger.eventType == AlarmEventType.finalDestination) {
          if (destinationAlarmFiredForKey(alarmKey)) {
            suppress = true;
          } else {
            setDestinationAlarmFiredForKey(alarmKey, true);
          }
        } else if (destinationAlarmFiredForKey(alarmKey)) {
          // If destination already fired, suppress everything else
          suppress = true;
        }

        if (!suppress) {
          // Mark fired - event index
          if (trigger.eventIndex != null) {
            firedIndexesForKey(alarmKey).add(trigger.eventIndex!);
          }

          // Mark leg as fired (one alarm per leg)
          if (trigger.legId != null && trigger.legId!.isNotEmpty) {
            markLegFired(alarmKey, trigger.legId!);
          }

          dev.log(
            'ALARM TRIGGERED: ${trigger.reason} - ${trigger.message} (leg: ${trigger.legIndex ?? -1})',
            name: 'AlarmController',
          );

          // Determine title
          final isFinal = trigger.eventType == AlarmEventType.finalDestination;
          String title;
          if (isFinal) {
            title = "Wake Up!";
          } else if (trigger.eventType == AlarmEventType.modeChange ||
              trigger.eventType == AlarmEventType.finalStation) {
            title = "Upcoming change";
          } else if (trigger.eventType == AlarmEventType.transfer) {
            title = "Upcoming transfer";
          } else if (trigger.eventType == AlarmEventType.preBoarding) {
            title = "Prepare to board";
          } else {
            title = "Approaching...";
          }

          // Some tests (and some UX surfaces) key off the body content.
          // Ensure transfer alarms include the canonical phrase in the body.
          final String body;
          if (isFinal) {
            final key = context.activeKey;
            final name =
                (key != null
                        ? context.registry.getByKey(key)?.destinationName
                        : null)
                    ?.trim();
            body =
                (name != null && name.isNotEmpty)
                    ? '$title: Arriving at $name'
                    : trigger.message;
          } else if (trigger.eventType == AlarmEventType.transfer) {
            body = '$title: ${trigger.message}';
          } else {
            body = trigger.message;
          }

          onAlarmFired?.call();

          await triggerAlarmNotification(
            service: service,
            title: title,
            body: body,
            allowContinueTracking: !isFinal,
            isBackgroundIsolate: context.isBackgroundIsolate,
            isTestMode: context.isTestMode,
            debugReason: trigger.reason,
          );

          startAlarmStopPollTimer(
            trackingSessionActive: () => context.trackingSessionActive,
          );
        }
      }
    } catch (e, stack) {
      trackingLog.error('AlarmEvaluator failed', error: e, stack: stack);
    }
  }

  Future<void> _evaluateGeofence({
    required Position currentPosition,
    required ServiceInstance service,
    required AlarmContext context,
    required String? alarmKey,
    void Function()? onAlarmFired,
  }) async {
    final distMeters = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      context.destination!.latitude,
      context.destination!.longitude,
    );

    bool shouldFire = false;
    String reason = 'Simple Geofence';

    if (context.alarmMode == 'distance') {
      if (distMeters <= context.alarmValue! * 1000.0) {
        shouldFire = true;
        reason =
            'Distance threshold reached (${(distMeters / 1000).toStringAsFixed(1)}km)';
      }
    } else if (context.alarmMode == 'time') {
      // TIME ALARM ELIGIBILITY GATE (also applies to geofence fallback)
      if (!context.timeAlarmEligible) {
        dev.log(
          'Time alarm geofence fallback skipped - eligibility not met',
          name: 'AlarmController',
        );
        return;
      }

      double speed = 1.4; // walking speed default
      if (currentPosition.speed > 0.5) speed = currentPosition.speed;
      final etaSec = distMeters / speed;
      // Apply +30s buffer per spec: threshold = userMinutes * 60 + 30
      final thresholdSec = context.alarmValue! * 60.0 + 30.0;
      if (etaSec <= thresholdSec) {
        shouldFire = true;
        reason =
            'Time threshold reached (~${(etaSec / 60).toStringAsFixed(1)} min)';
      }
    }

    if (shouldFire) {
      setDestinationAlarmFiredForKey(alarmKey, true);
      trackingLog.info('ALARM TRIGGERED (Fallback): $reason');

      onAlarmFired?.call();

      await triggerAlarmNotification(
        service: service,
        title: "Wake Up!",
        body: "You are nearing your destination",
        allowContinueTracking: false,
        isBackgroundIsolate: context.isBackgroundIsolate,
        isTestMode: context.isTestMode,
        debugReason: reason,
      );

      startAlarmStopPollTimer(
        trackingSessionActive: () => context.trackingSessionActive,
      );
    }
  }

  /// Start fast-polling timer for notification action buttons.
  void startAlarmStopPollTimer({
    required bool Function() trackingSessionActive,
  }) {
    _alarmStopPollTimer?.cancel();

    _alarmStopPollTimer = Timer.periodic(const Duration(milliseconds: 200), (
      timer,
    ) async {
      if (!trackingSessionActive()) {
        timer.cancel();
        _alarmStopPollTimer = null;
        return;
      }

      try {
        // 1. Check Stop Alarm
        final stopAlarmRequested =
            await NotificationService.consumeStopAlarmRequest();
        if (stopAlarmRequested) {
          dev.log('Consuming STOP ALARM request', name: 'AlarmController');
          try {
            await NotificationService().cancelAlarm();
          } catch (e) {
            alarmLog.warn('cancelAlarm failed', data: {'error': e.toString()});
          }
          try {
            await NotificationService().restoreJourneyProgressIfActive();
          } catch (e) {
            trackingLog.debug(
              'restoreJourneyProgressIfActive failed',
              data: {'error': e.toString()},
            );
          }
        }

        // 2. Check Mute Journey
        final muteJourneyRequested =
            await NotificationService.consumeMuteJourneyRequest();
        if (muteJourneyRequested) {
          dev.log('Consuming MUTE JOURNEY request', name: 'AlarmController');
          try {
            await TrackingStateStore.setNotificationsMuted(true);
            await NotificationService().cancelJourneyProgress();
          } catch (e) {
            trackingLog.warn(
              'muteJourney failed',
              data: {'error': e.toString()},
            );
          }
        }

        // 3. Check End Tracking
        final endTrackingRequested =
            await NotificationService.consumeEndTrackingRequest();
        if (endTrackingRequested) {
          dev.log('Consuming END TRACKING request', name: 'AlarmController');
          try {
            await NotificationService().cancelAllNotifications();
          } catch (e) {
            trackingLog.warn(
              'cancelAllNotifications failed',
              data: {'error': e.toString()},
            );
          }
          try {
            await TrackingStateStore.clearSnapshot();
            await TrackingStateStore.setActive(false);
            await TrackingStateStore.setPaused(false);
            await TrackingStateStore.setAlarmFired(false);
            await TrackingStateStore.setNotificationsMuted(false);
          } catch (e) {
            trackingLog.warn(
              'End tracking state cleanup failed',
              data: {'error': e.toString()},
            );
          }

          // Signal caller to stop tracking
          timer.cancel();
          _alarmStopPollTimer = null;
          return;
        }
      } catch (e) {
        trackingLog.debug(
          'Alarm poll timer error',
          data: {'error': e.toString()},
        );
      }
    });
  }

  /// Cancel the alarm stop poll timer.
  void cancelAlarmStopPollTimer() {
    _alarmStopPollTimer?.cancel();
    _alarmStopPollTimer = null;
  }
}
