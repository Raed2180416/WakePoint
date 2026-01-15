// lib/services/tracking/alarm_controller.dart
//
// Handles all alarm evaluation and triggering logic.
// - Evaluates alarm conditions based on position, mode, events
// - Triggers notifications via background isolate bridge
// - Manages alarm poll timer for responsive UI actions

import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/services/alarm_evaluator.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/snap_to_route.dart';
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

  // Track legs that are cooldown-suppressed (legId -> suppression timestamp)
  // These legs had triggers generated but were blocked by cooldown.
  // They can fire later when cooldown expires. Prevents infinite log spam.
  final Map<String, Map<String, DateTime>> _cooldownSuppressedByKey = {};

  // Legacy single-route state
  bool _destinationAlarmFired = false;
  final Set<int> _firedEventIndexes = {};
  final Set<String> _firedLegIds = {}; // Legacy single-route leg tracking
  final Map<String, DateTime> _cooldownSuppressed =
      {}; // Legacy cooldown tracking

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
    _lastAlarmFiredAt = AppClock().now();
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

  // ─────────────────────────────────────────────────────────────────────────
  // Cooldown-Suppressed Leg Tracking
  //
  // When a leg trigger is suppressed due to cooldown (not other reasons like
  // preboarding disabled), we track it here. This prevents infinite re-triggers
  // during cooldown while still allowing the leg to fire once cooldown expires.
  // ─────────────────────────────────────────────────────────────────────────

  /// Mark a leg as cooldown-suppressed (trigger was generated but blocked by cooldown).
  void _markCooldownSuppressed(String? key, String legId) {
    final now = AppClock().now();
    if (key == null) {
      _cooldownSuppressed[legId] = now;
    } else {
      _cooldownSuppressedByKey.putIfAbsent(key, () => <String, DateTime>{});
      _cooldownSuppressedByKey[key]![legId] = now;
    }
  }

  /// Clear a leg from cooldown-suppressed (when it actually fires).
  void _clearCooldownSuppressed(String? key, String legId) {
    if (key == null) {
      _cooldownSuppressed.remove(legId);
    } else {
      _cooldownSuppressedByKey[key]?.remove(legId);
    }
  }

  /// Check if a leg is currently cooldown-suppressed (and cooldown hasn't expired).
  /// Returns true if we should skip generating a new trigger for this leg.
  bool isLegCooldownSuppressed(String? key, String legId) {
    const cooldown = Duration(minutes: 3);
    final now = AppClock().now();
    DateTime? suppressedAt;
    if (key == null) {
      suppressedAt = _cooldownSuppressed[legId];
    } else {
      suppressedAt = _cooldownSuppressedByKey[key]?[legId];
    }
    if (suppressedAt == null) return false;
    // If cooldown has expired, clear and return false (leg can fire)
    if (now.difference(suppressedAt) >= cooldown) {
      _clearCooldownSuppressed(key, legId);
      return false;
    }
    return true;
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
    _cooldownSuppressed.clear();
    _cooldownSuppressedByKey.clear();

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

    _lastAlarmFiredAt = AppClock().now();

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
      // Background isolate cannot reliably start audio playback on all Android
      // builds (audio focus + routing may be delayed until user interaction).
      // Always delegate sound playback to the foreground isolate.
      service.invoke('triggerAlarm', {
        'title': title,
        'body': body,
        'allowContinue': allowContinueTracking,
        'playSound': true,
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
    // DEBUG: Print key context every call to trace alarm evaluation
    print(
      'ALARM_CHECK_ENTRY: mode=${context.alarmMode}, value=${context.alarmValue}, '
      'dest=${context.destination != null}, active=${context.trackingSessionActive}, '
      'progress=${context.progressMeters}, pos=(${currentPosition.latitude.toStringAsFixed(5)}, ${currentPosition.longitude.toStringAsFixed(5)})',
    );

    if (!context.trackingSessionActive) {
      dev.log(
        'ALARM_CHECK: Early return - tracking not active',
        name: 'AlarmController',
      );
      print('ALARM_CHECK: Early return - tracking NOT active');
      return;
    }
    if (context.destination == null || context.alarmValue == null) {
      dev.log(
        'ALARM_CHECK: Early return - dest=${context.destination}, value=${context.alarmValue}',
        name: 'AlarmController',
      );
      print(
        'ALARM_CHECK: Early return - dest=${context.destination}, value=${context.alarmValue}',
      );
      return;
    }

    final alarmKey = context.activeKey;
    final progressMeters = context.progressMeters;

    dev.log(
      'ALARM_CHECK: mode=${context.alarmMode}, alarmKey=$alarmKey, '
      'progressMeters=$progressMeters, alarmValue=${context.alarmValue}',
      name: 'AlarmController',
    );

    RouteEntry? activeEntry;
    try {
      if (alarmKey != null) {
        activeEntry = context.registry.getByKey(alarmKey);
      }
      activeEntry ??=
          context.registry.entries.isNotEmpty
              ? context.registry.entries.first
              : null;
    } catch (_) {
      // Best-effort only.
    }

    // Prepare active events
    final List<RouteEventBoundary> activeEvents = List<RouteEventBoundary>.from(
      context.routeEvents,
    );

    final mainRouteLen =
        context.stepBoundsMeters.isNotEmpty
            ? context.stepBoundsMeters.last
            : (activeEntry?.lengthMeters ?? 0.0);

    dev.log(
      'ALARM_CHECK_FLOW: registry.entries=${context.registry.entries.length}, '
      'activeEntry=${activeEntry?.key}, lengthMeters=${activeEntry?.lengthMeters}, '
      'stepBoundsMeters.length=${context.stepBoundsMeters.length}, '
      'mainRouteLen=$mainRouteLen, routeEvents.length=${context.routeEvents.length}',
      name: 'AlarmController',
    );

    // Add synthetic Destination event if missing
    if (mainRouteLen > 0 && !activeEvents.any((e) => e.type == 'destination')) {
      activeEvents.add(
        RouteEventBoundary(
          meters: mainRouteLen,
          type: 'destination',
          label: 'Destination',
        ),
      );
      dev.log(
        'ALARM_CHECK_FLOW: Added synthetic destination at $mainRouteLen m',
        name: 'AlarmController',
      );
    }

    dev.log(
      'ALARM_CHECK_FLOW: activeEvents.length=${activeEvents.length}, '
      'destEvents=${activeEvents.where((e) => e.type == "destination").length}, '
      'progressMeters=$progressMeters',
      name: 'AlarmController',
    );

    // DISTANCE MODE (NON-METRO): Trigger N km before final destination based on
    // remaining distance along the active route.
    //
    // Do this as an early, route-length/progress based check so it does NOT
    // depend on route events being present.
    // BLOCK 1: Distance Mode (Non-Metro)
    final isDistanceMode = context.alarmMode == 'distance';
    final hasAlarmValue = context.alarmValue != null;
    final alreadyFired = destinationAlarmFiredForKey(alarmKey);
    print(
      'ALARM_DIST_CHECK: isDistanceMode=$isDistanceMode, hasValue=$hasAlarmValue, alreadyFired=$alreadyFired',
    );

    if (isDistanceMode && hasAlarmValue && !alreadyFired) {
      // If progressMeters is null, we STILL want to fire based on straight-line
      // distance to destination. This handles cases where route snapping fails.
      if (progressMeters == null) {
        dev.log(
          'DISTANCE_MODE: progressMeters is NULL - using straight-line fallback',
          name: 'AlarmController',
        );
        print(
          'ALARM_DEBUG: progressMeters is NULL - trying straight-line fallback',
        );

        if (context.destination != null) {
          final distMeters = Geolocator.distanceBetween(
            currentPosition.latitude,
            currentPosition.longitude,
            context.destination!.latitude,
            context.destination!.longitude,
          );
          final thresholdMeters = context.alarmValue! * 1000.0;

          dev.log(
            'DISTANCE_MODE_STRAIGHTLINE: distMeters=$distMeters, thresholdMeters=$thresholdMeters, '
            'shouldFire=${distMeters <= thresholdMeters}',
            name: 'AlarmController',
          );
          print(
            'ALARM_DEBUG: StraightLine dist=$distMeters thresh=$thresholdMeters fire=${distMeters <= thresholdMeters}',
          );

          if (distMeters <= thresholdMeters) {
            setDestinationAlarmFiredForKey(alarmKey, true);
            triggerAlarmNotification(
              service: service,
              title: "Wake Up!",
              body: "You are ${context.alarmValue} km from your destination.",
              allowContinueTracking: false,
              isBackgroundIsolate: context.isBackgroundIsolate,
              isTestMode: context.isTestMode,
              debugReason:
                  'Distance straight-line <= ${context.alarmValue}km (no route progress)',
            );
            if (onAlarmFired != null) onAlarmFired();
            return;
          }
        }
      } else {
        // We have progressMeters - use route-based distance calculation
        // Calculate total meters
        double totalMeters = 0.0;
        RouteEntry? activeEntry;
        if (alarmKey != null) {
          activeEntry = context.registry.getByKey(alarmKey);
        }

        if (activeEntry != null) {
          totalMeters = activeEntry.lengthMeters;
        } else if (context.stepBoundsMeters.isNotEmpty) {
          totalMeters = context.stepBoundsMeters.last;
        }

        // Fallback
        if (totalMeters == 0) {
          try {
            final destEvent = context.routeEvents.firstWhere(
              (e) => e.type == 'destination',
            );
            totalMeters = destEvent.meters;
            dev.log(
              'ALARM_DEBUG: Used fallback destination event for totalMeters: $totalMeters',
              name: 'AlarmController',
            );
          } catch (_) {}
        }

        if (totalMeters > 0) {
          final remainingMeters = totalMeters - progressMeters;
          final thresholdMeters = context.alarmValue! * 1000.0;

          dev.log(
            'ALARM_DEBUG: Distance Check -- '
            'Total: ${totalMeters.toStringAsFixed(1)}, '
            'Progress: ${progressMeters.toStringAsFixed(1)}, '
            'Remaining: ${remainingMeters.toStringAsFixed(1)}, '
            'Threshold: ${thresholdMeters.toStringAsFixed(1)}',
            name: 'AlarmController',
          );
          // FORCE PRINT
          print(
            'ALARM_DEBUG: Total=${totalMeters} Prog=${progressMeters} Rem=${remainingMeters} Thresh=${thresholdMeters}',
          );

          if (remainingMeters <= thresholdMeters) {
            print('ALARM_DEBUG: Condition MET! Firing.');
            dev.log(
              'ALARM_DEBUG: FIRING ALARM! (Condition Met)',
              name: 'AlarmController',
            );
            setDestinationAlarmFiredForKey(alarmKey, true);
            triggerAlarmNotification(
              service: service,
              title: "Wake Up!",
              body: "You are ${context.alarmValue} km from your destination.",
              allowContinueTracking: false,
              isBackgroundIsolate: context.isBackgroundIsolate,
              isTestMode: context.isTestMode,
              debugReason: 'Distance <= ${context.alarmValue}km',
            );
            if (onAlarmFired != null) onAlarmFired();
            return;
          }
        } else {
          dev.log(
            'ALARM_DEBUG: Skipped Check (totalMeters=0)',
            name: 'AlarmController',
          );
        }
      }
    }

    // Use AlarmEvaluator if we have route context
    print('EVAL_GATE: events=${activeEvents.length}, progress=$progressMeters');
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

    print(
      'SPEED_DEBUG: smoothedSpeed=${context.smoothedSpeed?.toStringAsFixed(2)}, '
      'lastSpeedMps=${context.lastSpeedMps?.toStringAsFixed(2)}, '
      'finalSpeed=${currentSpeed?.toStringAsFixed(2)}, '
      'smoothedETA=${context.smoothedETA?.toStringAsFixed(1)}',
    );

    // Metro journeys need time-mode evaluation immediately on each leg to
    // support "fire at leg start if N > ETA" behavior. The general time-mode
    // eligibility gate remains in place for non-metro routes.
    final bool isMetroJourney = context.transitLegs.any((l) => l.isMetro);

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
        !context.isTestMode &&
        !isMetroJourney) {
      dev.log(
        'Time alarm evaluation skipped - eligibility not met '
        '(dist: ${context.distanceTravelledMeters.toStringAsFixed(0)}m, '
        'samples: ${context.etaSamples}, eligible: ${context.timeAlarmEligible})',
        name: 'AlarmController',
      );
      return;
    }

    // TIME MODE (NON-METRO): destination-only.
    // Fire exactly once when ETA to destination <= N minutes.
    // Other event types (transfer/mode-change/preboarding) are ignored.
    if (modeEnum == AlarmMode.time &&
        context.alarmValue != null &&
        !isMetroJourney &&
        !destinationAlarmFiredForKey(alarmKey)) {
      final thresholdSeconds = context.alarmValue! * 60.0;

      // Prefer authoritative ETA engine output (route-aware and smoothed).
      double? etaSeconds = context.smoothedETA;
      dev.log(
        'ETA_DEBUG time_alarm: smoothedETA=$etaSeconds, threshold=${thresholdSeconds}s (${context.alarmValue}min), progress=${progressMeters.toStringAsFixed(0)}m, speed=${currentSpeed?.toStringAsFixed(2)}m/s',
        name: 'AlarmController',
      );

      // Fallback: speed-based ETA to route end when smoothed ETA unavailable.
      if (etaSeconds == null || !etaSeconds.isFinite) {
        double? totalMeters;
        try {
          final entry =
              (alarmKey != null) ? context.registry.getByKey(alarmKey) : null;
          totalMeters = entry?.lengthMeters;
        } catch (_) {
          totalMeters = null;
        }

        // As a final fallback, try to use destination event meters.
        totalMeters ??=
            activeEvents.where((e) => e.type == 'destination').isNotEmpty
                ? activeEvents.where((e) => e.type == 'destination').last.meters
                : null;

        if (totalMeters != null) {
          etaSeconds = AlarmEvaluator.estimateEtaSecondsToMeters(
            progressMeters: progressMeters,
            targetMeters: totalMeters,
            stepBoundsMeters: const <double>[],
            stepDurationsSeconds: const <int>[],
            currentSpeedMps: currentSpeed,
          );
        }
      }

      if (etaSeconds != null &&
          etaSeconds.isFinite &&
          etaSeconds <= thresholdSeconds) {
        setDestinationAlarmFiredForKey(alarmKey, true);

        final key = context.activeKey;
        final name =
            (key != null
                    ? context.registry.getByKey(key)?.destinationName
                    : null)
                ?.trim();

        onAlarmFired?.call();

        await triggerAlarmNotification(
          service: service,
          title: 'Wake Up!',
          body:
              (name != null && name.isNotEmpty)
                  ? 'Wake Up!: Arriving at $name'
                  : 'Wake Up!: Arriving at Destination',
          allowContinueTracking: false,
          isBackgroundIsolate: context.isBackgroundIsolate,
          isTestMode: context.isTestMode,
          debugReason:
              'Time-mode (non-metro) destination (ETA ${etaSeconds.toStringAsFixed(0)}s <= ${thresholdSeconds.toStringAsFixed(0)}s)',
        );

        startAlarmStopPollTimer(
          trackingSessionActive: () => context.trackingSessionActive,
        );
      }

      return;
    }

    // DISTANCE MODE (NON-METRO): Trigger N km before final destination.
    //
    // When the user selects non-metro + distance mode, they expect a
    // destination alarm when remaining route distance <= N km.
    // The legacy AlarmEvaluator non-metro path uses a 60% rule and is
    // leg-based, which does not honor the user's N km threshold.
    if (modeEnum == AlarmMode.distance &&
        context.alarmValue != null &&
        !destinationAlarmFiredForKey(alarmKey)) {
      final destEvents =
          activeEvents.where((e) => e.type == 'destination').toList();

      dev.log(
        'DISTANCE_MODE_CHECK: destEvents=${destEvents.length}, '
        'alarmKey=$alarmKey, progressMeters=$progressMeters',
        name: 'AlarmController',
      );

      if (destEvents.isNotEmpty) {
        final dest = destEvents.last;

        // Prefer polyline-domain totals from RouteRegistry to avoid mismatch
        // between step-distance meters (events) and snap/progress meters.
        double? totalMeters;
        RouteEntry? entry;
        try {
          entry =
              (alarmKey != null) ? context.registry.getByKey(alarmKey) : null;
          totalMeters = entry?.lengthMeters;
        } catch (e) {
          dev.log(
            'DISTANCE_MODE_CHECK: Registry lookup failed: $e',
            name: 'AlarmController',
          );
        }

        dev.log(
          'DISTANCE_MODE_CHECK: entry=${entry?.key}, '
          'entry.lengthMeters=${entry?.lengthMeters}, '
          'dest.meters=${dest.meters}, totalMeters=$totalMeters',
          name: 'AlarmController',
        );

        totalMeters ??= dest.meters;

        final remainingMeters = (totalMeters - progressMeters).clamp(
          0.0,
          double.infinity,
        );
        final thresholdMeters = context.alarmValue! * 1000.0;

        dev.log(
          'DISTANCE_MODE_CHECK: totalMeters=$totalMeters, '
          'progressMeters=$progressMeters, '
          'remainingMeters=$remainingMeters, '
          'thresholdMeters=$thresholdMeters, '
          'shouldFire=${remainingMeters <= thresholdMeters}',
          name: 'AlarmController',
        );

        if (remainingMeters <= thresholdMeters) {
          setDestinationAlarmFiredForKey(alarmKey, true);

          final key = context.activeKey;
          final name =
              (key != null
                      ? context.registry.getByKey(key)?.destinationName
                      : null)
                  ?.trim();

          onAlarmFired?.call();

          await triggerAlarmNotification(
            service: service,
            title: 'Wake Up!',
            body:
                (name != null && name.isNotEmpty)
                    ? 'Wake Up!: Arriving at $name'
                    : 'Wake Up!: Arriving at Destination',
            allowContinueTracking: false,
            isBackgroundIsolate: context.isBackgroundIsolate,
            isTestMode: context.isTestMode,
            debugReason:
                'Distance-mode destination (remaining ${(remainingMeters / 1000).toStringAsFixed(2)}km <= ${context.alarmValue})',
          );

          startAlarmStopPollTimer(
            trackingSessionActive: () => context.trackingSessionActive,
          );
          return;
        }
      } else {
        // FALLBACK: No destination events but we're in distance mode.
        // Use straight-line distance to destination as a last resort.
        // This ensures the alarm fires even if route metadata is incomplete.
        if (context.destination != null) {
          final distMeters = Geolocator.distanceBetween(
            currentPosition.latitude,
            currentPosition.longitude,
            context.destination!.latitude,
            context.destination!.longitude,
          );
          final thresholdMeters = context.alarmValue! * 1000.0;

          dev.log(
            'DISTANCE_MODE_FALLBACK: No destEvents, using straight-line distance. '
            'distMeters=$distMeters, thresholdMeters=$thresholdMeters, '
            'shouldFire=${distMeters <= thresholdMeters}',
            name: 'AlarmController',
          );

          if (distMeters <= thresholdMeters) {
            setDestinationAlarmFiredForKey(alarmKey, true);

            final key = context.activeKey;
            final name =
                (key != null
                        ? context.registry.getByKey(key)?.destinationName
                        : null)
                    ?.trim();

            onAlarmFired?.call();

            await triggerAlarmNotification(
              service: service,
              title: 'Wake Up!',
              body:
                  (name != null && name.isNotEmpty)
                      ? 'Wake Up!: Arriving at $name'
                      : 'Wake Up!: Arriving at Destination',
              allowContinueTracking: false,
              isBackgroundIsolate: context.isBackgroundIsolate,
              isTestMode: context.isTestMode,
              debugReason:
                  'Distance-mode fallback (straight-line ${(distMeters / 1000).toStringAsFixed(2)}km <= ${context.alarmValue}km)',
            );

            startAlarmStopPollTimer(
              trackingSessionActive: () => context.trackingSessionActive,
            );
            return;
          }
        }
      }
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
    trackingLog.debug(
      'ALARM CHECK',
      data: {
        'now': DateTime.now().toIso8601String(),
        'controllerHash': hashCode,
        'mode': modeEnum.toString(),
        'progress_m': double.tryParse(progressMeters.toStringAsFixed(0)),
        'transitLegsLength': context.transitLegs.length,
        'currentLegIndex': currentLegIndex,
        'isFinalLeg': isFinalLeg,
        if (context.transitLegs.isNotEmpty)
          'leg0': {
            'hash': context.transitLegs[0].hashCode,
            'stops': context.transitLegs[0].numStops,
            'name': context.transitLegs[0].lineName,
          },
        if (context.transitLegs.isNotEmpty &&
            currentLegIndex >= 0 &&
            currentLegIndex < context.transitLegs.length)
          'currentLeg': {
            'name': context.transitLegs[currentLegIndex].lineName,
            'isMetro': context.transitLegs[currentLegIndex].isMetro,
            'start_m': context.transitLegs[currentLegIndex].legStartMeters,
            'end_m': context.transitLegs[currentLegIndex].legEndMeters,
          },
      },
    );

    // Eagerly fetch the fired set to debug its state
    final firedSet = firedLegIdsForKey(alarmKey);
    trackingLog.debug(
      'ALARM_CTRL_DEBUG',
      data: {'key': alarmKey, 'firedLegs': firedSet},
    );

    print(
      'STOPS_EVAL_PRE: mode=$modeEnum, value=${context.alarmValue}, '
      'progress=$progressMeters, transitLegs=${context.transitLegs.length}, '
      'currentLegIndex=$currentLegIndex, events=${activeEvents.length}',
    );

    // DEBUG: Log all transit legs for inspection
    if (context.transitLegs.isNotEmpty) {
      for (int i = 0; i < context.transitLegs.length; i++) {
        final tl = context.transitLegs[i];
        print(
          'TRANSIT_LEG[$i]: isMetro=${tl.isMetro}, name=${tl.lineName}, '
          'start=${tl.legStartMeters.toStringAsFixed(0)}, end=${tl.legEndMeters.toStringAsFixed(0)}, '
          'stops=${tl.numStops}, legId=${tl.legId.substring(0, tl.legId.length.clamp(0, 50))}',
        );
      }
    }

    // DEBUG: Log step bounds being passed
    print(
      'STEP_BOUNDS_CHECK: stepBoundsMeters.length=${context.stepBoundsMeters.length}, '
      'stepDurations.length=${context.stepDurationsSeconds.length}',
    );

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

      print(
        'STOPS_EVAL_POST: trigger=${trigger != null ? "FIRE(${trigger.reason})" : "null"}',
      );

      if (trigger != null) {
        bool suppress = false;
        String suppressReason = '';
        bool shouldMarkDestinationFired = false;

        // In metro + time mode, optionally fire ONLY destination alarm.
        if (context.alarmMode == 'time' && isMetroJourney) {
          final destinationOnly =
              await TrackingStateStore.destinationOnlyMetroTimeEnabled();
          print(
            'SUPPRESS_CHECK: metro+time mode, destinationOnly=$destinationOnly, eventType=${trigger.eventType}',
          );
          if (destinationOnly &&
              trigger.eventType != AlarmEventType.finalDestination) {
            suppress = true;
            suppressReason = 'destinationOnly mode (not a destination alarm)';
          }
        }

        // Settings: allow users to disable preboarding without affecting
        // other alarm types.
        // NOTE: Must use async method because background isolate has separate
        // SharedPreferences cache; reload() ensures fresh values.
        // IMPORTANT: Preboarding toggle only applies to STOPS MODE.
        // In TIME MODE, the "preBoarding" event type is used for walking legs
        // but should NOT be suppressed by the preboarding toggle - that toggle
        // is only relevant for stops-based preboarding alerts.
        if (trigger.eventType == AlarmEventType.preBoarding &&
            context.alarmMode == 'stops') {
          final preboardingOn = await TrackingStateStore.preboardingEnabled();
          print(
            'SUPPRESS_CHECK: preBoarding event in STOPS mode, preboardingOn=$preboardingOn',
          );
          if (!preboardingOn) {
            suppress = true;
            suppressReason = 'preboarding disabled (stops mode)';
          }
        } else if (trigger.eventType == AlarmEventType.preBoarding) {
          print(
            'SUPPRESS_CHECK: preBoarding event in TIME mode - preboarding toggle does NOT apply',
          );
        }

        // Destination protection
        if (trigger.eventType == AlarmEventType.finalDestination) {
          final alreadyFired = destinationAlarmFiredForKey(alarmKey);
          print(
            'SUPPRESS_CHECK: destination event, alreadyFired=$alreadyFired',
          );
          if (alreadyFired) {
            suppress = true;
            suppressReason = 'destination already fired';
          } else {
            // Only mark destination as fired after we successfully trigger a
            // notification. Otherwise, a notification failure would permanently
            // suppress future alarms for this journey.
            shouldMarkDestinationFired = true;
          }
        } else if (destinationAlarmFiredForKey(alarmKey)) {
          // If destination already fired, suppress everything else
          suppress = true;
          suppressReason = 'destination fired, suppressing other alarms';
          print(
            'SUPPRESS_CHECK: destination already fired for key, suppressing non-dest alarm',
          );
        }

        print(
          'SUPPRESS_RESULT: suppress=$suppress, reason=${suppressReason.isEmpty ? "none" : suppressReason}, '
          'eventType=${trigger.eventType}, legId=${trigger.legId}',
        );

        // NOTE: Metro time-mode cooldown has been REMOVED.
        // The one-alarm-per-leg logic (firedLegIds) already prevents duplicate
        // alarms on the same leg. The 3-minute cooldown was incorrectly blocking
        // alarms for DIFFERENT legs when they came in rapid succession (e.g.,
        // short interchange walks between metro lines).
        //
        // If spam becomes an issue in the future, implement per-leg cooldown
        // instead of global cooldown.

        if (!suppress) {
          final firedIndexes = firedIndexesForKey(alarmKey);
          final firedLegIds = firedLegIdsForKey(alarmKey);
          final int? eventIndexToMark = trigger.eventIndex;
          final String? legIdToMark =
              (trigger.legId != null && trigger.legId!.trim().isNotEmpty)
                  ? trigger.legId!.trim()
                  : null;

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

          try {
            await triggerAlarmNotification(
              service: service,
              title: title,
              body: body,
              allowContinueTracking: !isFinal,
              isBackgroundIsolate: context.isBackgroundIsolate,
              isTestMode: context.isTestMode,
              debugReason: trigger.reason,
            );

            // Single authoritative line for log-based auditing.
            print(
              'ALARM_FIRED: key=$alarmKey, type=${trigger.eventType}, title=$title, '
              'legIdx=${trigger.legIndex}, legId=$legIdToMark, '
              'progress=${context.progressMeters?.toStringAsFixed(0)}, '
              'remainingM=${trigger.remainingMeters?.toStringAsFixed(0)}, '
              'reason=${trigger.reason}',
            );

            // Only mark as fired AFTER notification triggering succeeds.
            // This avoids permanently skipping alarms when notification
            // triggering throws/fails.
            if (eventIndexToMark != null) {
              firedIndexes.add(eventIndexToMark);
            }
            if (legIdToMark != null) {
              markLegFired(alarmKey, legIdToMark);
              _clearCooldownSuppressed(alarmKey, legIdToMark);
            }

            if (shouldMarkDestinationFired) {
              setDestinationAlarmFiredForKey(alarmKey, true);
            }

            startAlarmStopPollTimer(
              trackingSessionActive: () => context.trackingSessionActive,
            );
          } catch (e, stack) {
            // Critical: if notification triggering fails, rollback the fired
            // markers so the alarm can retry on the next tick instead of being
            // stuck in ALREADY_FIRED state.
            dev.log(
              'Alarm notification failed; rolling back fired markers',
              name: 'AlarmController',
              error: e,
              stackTrace: stack,
            );
            return;
          }
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

  @visibleForTesting
  static Future<bool> shouldSuppressNonDestinationInMetroTime(
    String eventType,
  ) async {
    if (eventType == AlarmEventType.finalDestination) return false;
    return await TrackingStateStore.destinationOnlyMetroTimeEnabled();
  }

  /// Cancel the alarm stop poll timer.
  void cancelAlarmStopPollTimer() {
    _alarmStopPollTimer?.cancel();
    _alarmStopPollTimer = null;
  }
}
