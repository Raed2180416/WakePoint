// lib/services/tracking/alarm_controller.dart
//
// Handles all alarm evaluation and triggering logic.
// - Evaluates alarm conditions based on position, mode, events
// - Triggers notifications via background isolate bridge
// - Manages alarm poll timer for responsive UI actions

import 'dart:async';
import 'dart:developer' as dev;
import 'dart:math';

import 'package:geowake2/config/fire_decision_config.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/core/reachability/reachability.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';
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

  // G11/G12/G13: dead-reckoned EKF signals for the fire decision.
  /// EKF velocity (m/s), used as the speed source when [preferEkfSpeed].
  final double? ekfSpeedMps;
  /// EKF position std-dev (m) for the critical-fractile stop cushion.
  final double? ekfSigmaS;
  /// EKF velocity std-dev (m/s) for ETA-variance inflation.
  final double? ekfSigmaV;
  /// True when the EKF is authoritative (metro / degraded / GPS blackout).
  final bool preferEkfSpeed;

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
    this.ekfSpeedMps,
    this.ekfSigmaS,
    this.ekfSigmaV,
    this.preferEkfSpeed = false,
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

  // P0 REACHABILITY PROTECTION LEVEL: physics "never fire late" state. Anchored
  // ONLY on accepted real fixes (not dead-reckoned sentinels); grows the
  // worst-case reachable arc-progress during a GPS blackout. See
  // lib/core/reachability/reachability.dart.
  // dwellMinSeconds defaults to 0 => the topology cap degrades to the
  // UNCONDITIONALLY-safe free-run bound. A positive dwell is only safe on a
  // confirmed all-stops service; assuming dwell an express/skip-stop train never
  // pays would push the bound below true progress and could fire late. The cap
  // stays available for per-line opt-in once stop patterns are known.
  final ReachabilityTracker _reach = ReachabilityTracker(
    config: const ReachabilityConfig(dwellMinSeconds: 0.0),
  );

  /// The clock the reachability never-late math runs on. MUST be monotonic —
  /// `s_max = s0 + V_LINE*(t - t0)` is only never-late if `(t - t0)` is true
  /// elapsed time. A backward wall-clock jump (NTP/DST/manual) would freeze the
  /// cone and fire LATE (found by clock-jump simulation). See
  /// AppClock.monotonicSeconds.
  double _nowSeconds() => AppClock().monotonicSeconds();

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
    // Fresh session => drop the stale reachability anchor from any prior trip.
    _reach.reset();

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

  /// GAP #1/#2 (BLOCK): seed the reachability anchor at ARM time so the physics
  /// never-late net has an honest wall-clock origin even for a rider who opens
  /// the app already underground and never gets a single GPS fix. [sMeters] is
  /// the rider's arc-progress at arm (0 for a fresh arm from the route origin;
  /// the restored snapshot progress on an OS-kill restore). [tSeconds] is the
  /// wall-clock time that position was true (arm time, or the snapshot's last
  /// real-fix time). Idempotent — a later accepted GPS fix re-anchors via
  /// onAcceptedFix; this only establishes t0 so the worst-case bound starts
  /// growing from the right moment (seeding on the first tick instead can start
  /// the clock late and shrink the bound below reality).
  void seedReachabilityAnchorAtArm({double sMeters = 0.0, double? tSeconds}) {
    _reach.seedColdStart(
      tSeconds: (tSeconds != null && tSeconds.isFinite) ? tSeconds : _nowSeconds(),
      sMeters: sMeters.isFinite ? sMeters : 0.0,
    );
  }

  /// GAP #1 (BLOCK): whole-route reachability backstop for cold-start-underground.
  ///
  /// Runs only when there is NO dead-reckoned progress (the rider opened the app
  /// already underground; no GPS fix has arrived) but the anchor was seeded at
  /// arm. It computes the worst-case reachable arc-progress to the FINAL
  /// destination using the FASTEST V_LINE across all legs — an overbound, so it
  /// is a valid upper bound whichever leg the rider is really on (a higher
  /// V_LINE only fires earlier, never late) — and fires the destination alarm the
  /// instant that physics bound reaches the fire target. Returns true if it fired.
  Future<bool> _maybeFireColdStartReachBackstop({
    required AlarmContext context,
    required String? alarmKey,
    required ServiceInstance service,
    void Function()? onAlarmFired,
  }) async {
    if (destinationAlarmFiredForKey(alarmKey)) return false;
    final anchor = _reach.anchor;
    if (anchor == null) return false;
    final legs = context.transitLegs;
    if (legs.isEmpty) return false;

    // Route end to aim at (max leg end, or a destination route event).
    double totalMeters = double.nan;
    for (final leg in legs) {
      if (leg.legEndMeters.isFinite) {
        totalMeters =
            totalMeters.isNaN ? leg.legEndMeters : max(totalMeters, leg.legEndMeters);
      }
    }
    if (totalMeters.isNaN) {
      final destEvt = context.routeEvents.where((e) => e.type == 'destination');
      if (destEvt.isNotEmpty) totalMeters = destEvt.last.meters;
    }
    if (!totalMeters.isFinite || totalMeters <= 0) return false;

    // Fastest V_LINE across all legs => valid upper bound on any leg (safe).
    double vMax = VLineTable.defaultMps;
    for (final leg in legs) {
      final v = _reach.vLineTable.forLine(city: leg.cityKey, lineName: leg.lineName);
      if (v.isFinite && v > vMax) vMax = v;
    }

    final bound = Reachability.bound(
      anchor: anchor,
      nowSeconds: _nowSeconds(),
      vLineMps: vMax,
    );
    final double sMax = bound.sMaxMeters; // may be +inf (T_max watchdog)
    final double target = coldStartFireTargetMeters(context, totalMeters, legs, vMax);
    if (!(sMax >= target)) return false; // NaN-safe: false unless provably reached

    setDestinationAlarmFiredForKey(alarmKey, true);
    final key = context.activeKey;
    final name = (key != null
            ? context.registry.getByKey(key)?.destinationName
            : null)
        ?.trim();
    onAlarmFired?.call();
    // FINDING 6: the fired-flag is already set; a throw here would leave a
    // permanent silent no-wake. Telemetry is fail-open by design, but wrap it
    // for defense-in-depth so nothing between the flag and the notification can
    // abort the wake.
    try {
      TelemetryService.instance.reachabilityActivated(
        dtSeconds: bound.dtSeconds,
        boundMeters: sMax.isFinite ? sMax : totalMeters,
        deadReckonedMeters: double.nan,
        watchdog: bound.watchdogTripped,
      );
    } catch (_) {/* never abort the wake */}
    await triggerAlarmNotification(
      service: service,
      title: 'Wake Up!',
      body: (name != null && name.isNotEmpty)
          ? 'Wake Up!: Arriving at $name'
          : 'Wake Up!: Arriving at Destination',
      allowContinueTracking: false,
      isBackgroundIsolate: context.isBackgroundIsolate,
      isTestMode: context.isTestMode,
      debugReason:
          'Cold-start reachability backstop (s_max=${sMax.toStringAsFixed(0)}m '
          '>= target ${target.toStringAsFixed(0)}m, V_LINE=${vMax.toStringAsFixed(0)}m/s)',
    );
    startAlarmStopPollTimer(
      trackingSessionActive: () => context.trackingSessionActive,
    );
    return true;
  }

  /// The arc-position (meters) at which the cold-start backstop should fire, per
  /// alarm mode. All variants are LOWER bounds on the true fire point (fire at or
  /// before), so the worst-case bound reaching them can never be late.
  @visibleForTesting
  double coldStartFireTargetMeters(
    AlarmContext context,
    double totalMeters,
    List<TransitLegStops> legs,
    double vMax,
  ) {
    final mode = context.alarmMode;
    final value = (context.alarmValue ?? 0).toDouble();
    if (mode == 'distance') {
      return max(0.0, totalMeters - value * 1000.0);
    }
    if (mode == 'time') {
      // Worst case: at vMax, `value` minutes covers value*60*vMax meters, so the
      // train could be within N minutes of the end once it reaches this point.
      return max(0.0, totalMeters - value * 60.0 * vMax);
    }
    // stops mode: N stops before the destination on the final leg.
    final finalLeg = legs.last;
    final stops = finalLeg.stopMeters.where((m) => m.isFinite).toList()..sort();
    if (stops.isNotEmpty) {
      final idx = stops.length - value.round();
      if (idx >= 0 && idx < stops.length) return stops[idx];
      return stops.first; // fewer intermediate stops than N => fire at the first
    }
    // No stop POSITIONS: when the stop COUNT is known, derive the per-stop
    // spacing from the final leg (legLen / numStops) so a sparse/regional line
    // with large inter-station gaps (e.g. RRTS ~5-10 km/stop) warns the requested
    // N stops ahead instead of a flat 1.2 km (FINDING 4); clamp to [0.8, 8]
    // km/stop. With no count info at all, fall back to the flat conservative
    // metro gap. Larger spacing => earlier fire (safe).
    final int nStops = finalLeg.numStops;
    final double legLen =
        (finalLeg.legEndMeters - finalLeg.legStartMeters).abs();
    final double perStop = (nStops > 0 && legLen > 0)
        ? (legLen / nStops).clamp(800.0, 8000.0)
        : 1200.0;
    return max(0.0, totalMeters - value * perStop);
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

    // GAP #8: the north-star funnel numerator — record that a destination alarm
    // fired, and via which lever, breakable down by device/OEM/SDK. Firing is
    // never-late by construction (outcome=onTime); a later feature can detect
    // late/missed from post-arrival ground truth. viaReach/backstop are inferred
    // from the fire reason. Fail-open — telemetry must never break the wake.
    try {
      final r = (debugReason ?? '').toLowerCase();
      final viaReach = r.contains('reach') || r.contains('backstop');
      final String? mode = r.contains('distance')
          ? 'distance'
          : r.contains('time')
              ? 'time'
              : (r.contains('stops') || r.contains('metro') ? 'stops' : null);
      TelemetryService.instance.alarmOutcome(
        outcome: AlarmOutcome.onTime,
        firedViaReachability: viaReach,
        mode: mode,
      );
    } catch (_) {/* never break the wake */}

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
      // G6: raise the alarm SELF-CONTAINED in the background isolate. The UI
      // isolate is frequently dead (app swiped away) at wake-up time, so
      // delegating via service.invoke('triggerAlarm') would drop the alarm.
      // NotificationService + AlarmPlayer(audioplayers) + Vibration are all pub
      // plugins registered on the background engine, so showing the full-screen
      // notification and starting audio/vibration here works directly.
      try {
        await NotificationService().showWakeUpAlarm(
          title: title,
          body: body,
          allowContinueTracking: allowContinueTracking,
          playSound: true,
        );
      } catch (e) {
        dev.log(
          'Background self-contained alarm raise failed, delegating to UI: $e',
          name: 'AlarmController',
        );
      }
      // Belt-and-suspenders: also notify the UI isolate IF it is alive, so an
      // open foreground can update its own alarm UI state. Harmless if dead
      // (NotificationService de-dupes via _alarmCurrentlyShowing).
      service.invoke('triggerAlarm', {
        'title': title,
        'body': body,
        'allowContinue': allowContinueTracking,
        'playSound': false,
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
    trackingLog.debug(
      'ALARM_CHECK_ENTRY',
      data: {
        'mode': context.alarmMode,
        'value': context.alarmValue,
        'dest': context.destination != null,
        'active': context.trackingSessionActive,
        'progress': context.progressMeters,
        'lat': double.tryParse(currentPosition.latitude.toStringAsFixed(5)),
        'lng': double.tryParse(currentPosition.longitude.toStringAsFixed(5)),
      },
    );

    if (!context.trackingSessionActive) {
      dev.log(
        'ALARM_CHECK: Early return - tracking not active',
        name: 'AlarmController',
      );
      return;
    }
    if (context.destination == null || context.alarmValue == null) {
      dev.log(
        'ALARM_CHECK: Early return - dest=${context.destination}, value=${context.alarmValue}',
        name: 'AlarmController',
      );
      return;
    }

    final alarmKey = context.activeKey;
    final progressMeters = context.progressMeters;

    // P0 REACHABILITY: maintain the physics anchor. Seed it at trip origin on
    // the first tick (safety net from t0), then re-anchor ONLY on accepted real
    // GPS fixes. Dead-reckoned positions carry the sentinel accuracy (9999m) and
    // must NEVER move the anchor (precondition iii) — that is what keeps the
    // wall-clock `t_since_last_true_fix` honest through a blackout.
    {
      final double nowSec = _nowSeconds(); // monotonic (see _nowSeconds)
      // Anchor at the fix's OWN acquisition time, not "now". A GPS fix delivered
      // late (queued behind a wake, a slow sensor bus) would otherwise reset
      // t_since_last_true_fix too recent and shrink the reach bound below reality
      // (a precondition-(iii) late-fire hazard). The fix timestamp is WALL-clock,
      // so map its wall-clock AGE into the monotonic frame: fixTs = nowSec − age.
      // Age is measured over the short (<~seconds) delivery window from the same
      // wall clock, so it is accurate and immune to the long-term wall-clock
      // jumps between anchors that the monotonic switch protects against.
      double fixTs = nowSec;
      try {
        final double fixWall =
            currentPosition.timestamp.millisecondsSinceEpoch / 1000.0;
        final double wallNow =
            AppClock().now().millisecondsSinceEpoch / 1000.0;
        final double age = wallNow - fixWall;
        if (age.isFinite && age >= 0.0 && age < 3600.0) {
          fixTs = nowSec - age;
        }
      } catch (_) {/* keep nowSec */}
      _reach.seedColdStart(
          tSeconds: nowSec, sMeters: progressMeters ?? 0.0);
      final double acc = currentPosition.accuracy;
      final bool isRealFix = acc.isFinite &&
          acc > 0 &&
          acc < FireDecisionConfig.deadReckonAccuracySentinel;
      if (isRealFix &&
          progressMeters != null &&
          progressMeters.isFinite) {
        _reach.onAcceptedFix(
          sMeters: progressMeters,
          accuracyMeters: acc,
          tSeconds: fixTs,
        );
      }
    }

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
    trackingLog.debug(
      'ALARM_DIST_CHECK',
      data: {
        'isDistanceMode': isDistanceMode,
        'hasValue': hasAlarmValue,
        'alreadyFired': alreadyFired,
      },
    );

    if (isDistanceMode && hasAlarmValue && !alreadyFired) {
      // If progressMeters is null, we STILL want to fire based on straight-line
      // distance to destination. This handles cases where route snapping fails.
      if (progressMeters == null) {
        dev.log(
          'DISTANCE_MODE: progressMeters is NULL - using straight-line fallback',
          name: 'AlarmController',
        );
        trackingLog.debug(
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
          trackingLog.debug(
            'ALARM_DEBUG_STRAIGHTLINE',
            data: {
              'distMeters': distMeters,
              'thresholdMeters': thresholdMeters,
              'fire': distMeters <= thresholdMeters,
            },
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
          trackingLog.debug(
            'ALARM_DEBUG_DISTANCE',
            data: {
              'total_m': totalMeters,
              'progress_m': progressMeters,
              'remaining_m': remainingMeters,
              'threshold_m': thresholdMeters,
            },
          );

          if (remainingMeters <= thresholdMeters) {
            trackingLog.debug('ALARM_DEBUG: Condition MET! Firing.');
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
    trackingLog.debug(
      'EVAL_GATE',
      data: {'events': activeEvents.length, 'progress': progressMeters},
    );
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
    } else if (progressMeters == null &&
        _reach.hasAnchor &&
        context.transitLegs.isNotEmpty &&
        !destinationAlarmFiredForKey(alarmKey)) {
      // GAP #1 (BLOCK): cold-start-underground. No dead-reckoned progress yet
      // (rider opened the app already underground; no GPS fix), so the normal
      // route eval can't run and the geofence fallback can't fire underground.
      // The reachability anchor (seeded at arm) lets the physics net wake the
      // rider on the wall clock alone. Fire the whole-route worst-case backstop
      // if the bound has reached the target; otherwise fall through.
      final fired = await _maybeFireColdStartReachBackstop(
        context: context,
        alarmKey: alarmKey,
        service: service,
        onAlarmFired: onAlarmFired,
      );
      if (!fired && context.destination != null) {
        await _evaluateGeofence(
          currentPosition: currentPosition,
          service: service,
          context: context,
          alarmKey: alarmKey,
          onAlarmFired: onAlarmFired,
        );
      }
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
    // Determine current speed.
    // G11: When the EKF is authoritative (metro leg, degraded, or GPS blackout)
    // the dead-reckoned EKF velocity is the correct speed source — GPS-derived
    // smoothed speed is stale/zero underground. On the surface, fall back to the
    // smoothed GPS speed then the raw last GPS speed.
    double? currentSpeed;
    if (context.preferEkfSpeed &&
        context.ekfSpeedMps != null &&
        context.ekfSpeedMps!.isFinite) {
      currentSpeed = context.ekfSpeedMps;
    } else {
      currentSpeed = context.smoothedSpeed;
      if (currentSpeed == null || currentSpeed <= 0.5) {
        currentSpeed = context.lastSpeedMps;
      }
    }

    trackingLog.debug(
      'SPEED_DEBUG',
      data: {
        'smoothedSpeed': context.smoothedSpeed,
        'lastSpeedMps': context.lastSpeedMps,
        'finalSpeed': currentSpeed,
        'smoothedETA': context.smoothedETA,
      },
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

    // GAP #3 (BLOCK): physics never-late bound for the DISTANCE and non-metro
    // TIME fire paths too — not just metro-stops. During a GPS blackout the
    // dead-reckoned progress/ETA can freeze while the train keeps moving; the
    // reachability bound (last real fix + wall clock) keeps growing, so feeding
    // it into these paths keeps them never-late. Free-run bound with the FASTEST
    // V_LINE across all legs => a valid upper bound whichever leg the rider is
    // really on (a higher V_LINE only fires earlier, never later). Inert when GPS
    // is healthy (fresh anchor => bound ~= current progress).
    double vMaxModes = VLineTable.defaultMps;
    for (final leg in context.transitLegs) {
      final v = _reach.vLineTable.forLine(city: leg.cityKey, lineName: leg.lineName);
      if (v.isFinite && v > vMaxModes) vMaxModes = v;
    }
    double? reachBoundModes;
    {
      final a = _reach.anchor;
      if (a != null) {
        final bb = Reachability.bound(
          anchor: a,
          nowSeconds: _nowSeconds(),
          vLineMps: vMaxModes,
        );
        // FINDING 3: stay inert while GPS is healthy — only let the physics bound
        // override the dead-reckoned progress once the last real fix is stale
        // enough to be a genuine blackout (else the between-fix gap would bias
        // every distance/time fire ~V_LINE·dt early). A fire-forcing +inf bound
        // (watchdog / corrupt anchor) always applies.
        if (!bb.sMaxMeters.isNaN &&
            (!bb.sMaxMeters.isFinite ||
                bb.dtSeconds >= FireDecisionConfig.reachBlackoutMinSeconds)) {
          reachBoundModes = bb.sMaxMeters;
        }
      }
    }

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

      // G12: fire on the critical fractile (median - k*sigma), never the median.
      final double etaSigma = (etaSeconds != null && etaSeconds.isFinite)
          ? _etaSigmaSeconds(
              etaSeconds: etaSeconds,
              speedMps: currentSpeed,
              sigmaSMeters: context.ekfSigmaS,
              sigmaVMps: context.ekfSigmaV,
            )
          : 0.0;
      // GAP #3: physics never-late lower bound for time mode. The earliest the
      // train could arrive is (remaining distance / fastest speed). If the
      // worst-case reachable position puts that within the threshold, fire —
      // this protects time mode when the dead-reckoned ETA is stale (frozen
      // underground) while the train physically keeps moving.
      bool reachFireTime = false;
      if (reachBoundModes != null) {
        if (!reachBoundModes.isFinite) {
          reachFireTime = true; // watchdog / fire-forcing bound
        } else {
          double? totalForReach;
          try {
            totalForReach = (alarmKey != null)
                ? context.registry.getByKey(alarmKey)?.lengthMeters
                : null;
          } catch (_) {}
          totalForReach ??=
              activeEvents.where((e) => e.type == 'destination').isNotEmpty
                  ? activeEvents.where((e) => e.type == 'destination').last.meters
                  : null;
          if (totalForReach != null && totalForReach.isFinite && vMaxModes > 0) {
            final remain = totalForReach - reachBoundModes;
            final etaReachLB = remain <= 0 ? 0.0 : remain / vMaxModes;
            if (etaReachLB <= thresholdSeconds) reachFireTime = true;
          }
        }
      }
      final bool etaFire = etaSeconds != null &&
          etaSeconds.isFinite &&
          (etaSeconds - FireDecisionConfig.fractileK * etaSigma) <=
              thresholdSeconds;
      if (etaFire || reachFireTime) {
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
          debugReason: etaFire
              ? 'Time-mode (non-metro) destination (ETA ${etaSeconds.toStringAsFixed(0)}s <= ${thresholdSeconds.toStringAsFixed(0)}s)'
              : 'Time-mode (non-metro) reachability backstop '
                  '(worst-case ETA <= ${thresholdSeconds.toStringAsFixed(0)}s)',
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

        // GAP #3: never-late — use the physics-effective progress (the greater
        // of the dead-reckoned progress and the reachability bound) so a
        // frozen-DR blackout cannot delay the fire. Inert when GPS is healthy
        // (bound ~= progress). A fire-forcing +inf bound => remaining clamps to 0.
        final double effProgress =
            (reachBoundModes != null && reachBoundModes > progressMeters)
                ? reachBoundModes
                : progressMeters;
        final remainingMeters = (totalMeters - effProgress).clamp(
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

    trackingLog.debug(
      'STOPS_EVAL_PRE',
      data: {
        'mode': modeEnum.toString(),
        'value': context.alarmValue,
        'progress': progressMeters,
        'transitLegs': context.transitLegs.length,
        'currentLegIndex': currentLegIndex,
        'events': activeEvents.length,
      },
    );

    // DEBUG: Log all transit legs for inspection
    if (context.transitLegs.isNotEmpty) {
      for (int i = 0; i < context.transitLegs.length; i++) {
        final tl = context.transitLegs[i];
        trackingLog.debug(
          'TRANSIT_LEG',
          data: {
            'i': i,
            'isMetro': tl.isMetro,
            'name': tl.lineName,
            'start_m': double.tryParse(tl.legStartMeters.toStringAsFixed(0)),
            'end_m': double.tryParse(tl.legEndMeters.toStringAsFixed(0)),
            'stops': tl.numStops,
            'legId': tl.legId.substring(0, tl.legId.length.clamp(0, 50)),
          },
        );
      }
    }

    // DEBUG: Log step bounds being passed
    trackingLog.debug(
      'STEP_BOUNDS_CHECK',
      data: {
        'stepBoundsMetersLength': context.stepBoundsMeters.length,
        'stepDurationsLength': context.stepDurationsSeconds.length,
      },
    );

    // P0 REACHABILITY: compute the worst-case reachable arc-progress now and
    // feed it to the fire decision. effectiveProgress = max(statistical, this)
    // guarantees never-late by physics while staying inert when GPS is healthy
    // (the anchor is fresh, so the bound ~= current progress).
    double? reachBoundMeters;
    {
      RouteTopology? reachTopo;
      // P1 multi-leg mode-max (validation-gaps): during a blackout the rider may
      // have progressed from the current leg into a FASTER forward leg — e.g. a
      // walk -> metro boarding as GPS drops at the tunnel mouth. Using only the
      // current leg's V_LINE would UNDER-bound (walk 2 m/s while the train does
      // 28) and fire LATE. Use the MAX V_LINE over the legs the rider could
      // plausibly be on now (current leg forward, incl. GAP #9 city keys for
      // RRTS) — a valid over-bound whichever leg they are really on. For a
      // single-leg metro journey this equals that leg's V_LINE (no change).
      double vMaxFwd = VLineTable.defaultMps;
      if (currentLegIndex >= 0 &&
          currentLegIndex < context.transitLegs.length) {
        for (var i = currentLegIndex; i < context.transitLegs.length; i++) {
          final l = context.transitLegs[i];
          final v = _reach.vLineTable.forLine(city: l.cityKey, lineName: l.lineName);
          if (v.isFinite && v > vMaxFwd) vMaxFwd = v;
        }
        // Stations the train must pass on the CURRENT leg tighten the early-firing
        // via the stop-count cap.
        final leg = context.transitLegs[currentLegIndex];
        final stops = <double>[
          ...leg.stopMeters.where((m) => m.isFinite),
          if (leg.legEndMeters.isFinite) leg.legEndMeters,
        ];
        if (stops.isNotEmpty) {
          reachTopo =
              RouteTopology(stationMeters: stops, dwellMinSeconds: 0.0);
        }
      }
      final anchor = _reach.anchor;
      final b = anchor == null
          ? null
          : Reachability.bound(
              anchor: anchor,
              nowSeconds: _nowSeconds(),
              vLineMps: vMaxFwd,
              topology: reachTopo,
              config: _reach.config,
            );
      // Pass the bound through unless it is NaN. A +infinity bound is the
      // fire-FORCING signal (T_max watchdog or a corrupt-input fail-safe) and
      // MUST reach the evaluator — filtering on isFinite here would silently drop
      // it and re-open the never-fire gap. Only NaN (no information) is dropped.
      // FINDING 3: stay inert while GPS is healthy — only feed the bound once the
      // anchor is stale enough to be a genuine blackout (the EKF carries the first
      // few seconds), so the (now ceiling-level) V_LINE cannot bias a healthy-GPS
      // metro fire early. A +inf fire-forcing bound always passes.
      if (b != null &&
          !b.sMaxMeters.isNaN &&
          (!b.sMaxMeters.isFinite ||
              b.dtSeconds >= FireDecisionConfig.reachBlackoutMinSeconds)) {
        reachBoundMeters = b.sMaxMeters;
        // Reliability funnel (HANDOFF §3): record when the physics bound is
        // materially carrying the fire decision — i.e. a GPS blackout where
        // dead-reckoning has fallen behind. Fail-open; never throws.
        if (progressMeters.isFinite &&
            (reachBoundMeters - progressMeters) > 50.0) {
          TelemetryService.instance.reachabilityActivated(
            dtSeconds: b.dtSeconds,
            boundMeters: reachBoundMeters,
            deadReckonedMeters: progressMeters,
            watchdog: b.watchdogTripped,
          );
        }
      }
    }

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
        // G12/G13: EKF uncertainty for critical-fractile stop-reach + ETA.
        positionSigmaMeters: context.ekfSigmaS,
        velocitySigmaMps: context.ekfSigmaV,
        fractileK: FireDecisionConfig.fractileK,
        reachableProgressBoundMeters: reachBoundMeters,
      );

      trackingLog.debug(
        'STOPS_EVAL_POST',
        data: {
          'trigger': trigger != null,
          if (trigger != null) 'reason': trigger.reason,
        },
      );

      if (trigger != null) {
        bool suppress = false;
        String suppressReason = '';
        bool shouldMarkDestinationFired = false;

        // In metro + time mode, optionally fire ONLY destination alarm.
        if (context.alarmMode == 'time' && isMetroJourney) {
          final destinationOnly =
              await TrackingStateStore.destinationOnlyMetroTimeEnabled();
          trackingLog.debug(
            'SUPPRESS_CHECK_METRO_TIME',
            data: {
              'destinationOnly': destinationOnly,
              'eventType': trigger.eventType.toString(),
            },
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
          trackingLog.debug(
            'SUPPRESS_CHECK_PREBOARDING_STOPS',
            data: {'preboardingOn': preboardingOn},
          );
          if (!preboardingOn) {
            suppress = true;
            suppressReason = 'preboarding disabled (stops mode)';
          }
        } else if (trigger.eventType == AlarmEventType.preBoarding) {
          trackingLog.debug(
            'SUPPRESS_CHECK_PREBOARDING_TIME',
            data: {'note': 'preboarding toggle does not apply'},
          );
        }

        // Destination protection
        if (trigger.eventType == AlarmEventType.finalDestination) {
          final alreadyFired = destinationAlarmFiredForKey(alarmKey);
          trackingLog.debug(
            'SUPPRESS_CHECK_DESTINATION',
            data: {'alreadyFired': alreadyFired},
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
          trackingLog.debug(
            'SUPPRESS_CHECK_DESTINATION_ALREADY_FIRED',
            data: {'note': 'suppressing non-destination alarm'},
          );
        }

        trackingLog.debug(
          'SUPPRESS_RESULT',
          data: {
            'suppress': suppress,
            'reason': suppressReason.isEmpty ? 'none' : suppressReason,
            'eventType': trigger.eventType.toString(),
            'legId': trigger.legId,
          },
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
            trackingLog.info(
              'ALARM_FIRED',
              data: {
                'key': alarmKey,
                'type': trigger.eventType.toString(),
                'title': title,
                'legIdx': trigger.legIndex,
                'legId': legIdToMark,
                'progress_m': context.progressMeters,
                'remaining_m': trigger.remainingMeters,
                'reason': trigger.reason,
              },
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

  /// First-order ETA std-dev (s): sigmaEta^2 = (sigmaS/v)^2 + (ETA*sigmaV/v)^2.
  /// Returns 0 when speed/sigmas are unusable (degrades to median firing).
  static double _etaSigmaSeconds({
    required double etaSeconds,
    required double? speedMps,
    required double? sigmaSMeters,
    required double? sigmaVMps,
  }) {
    if (!etaSeconds.isFinite) return 0.0;
    // GAP #21: floor the effective velocity to a realistic transit speed when
    // the measured speed is unobservable (stale <= 0.5 m/s underground), so the
    // ETA cushion doesn't collapse to 0 and degrade the fire test to the median.
    final v = (speedMps != null && speedMps.isFinite && speedMps > 0.5)
        ? speedMps
        : FireDecisionConfig.etaSigmaSpeedFloorMps;
    final sS =
        (sigmaSMeters != null && sigmaSMeters.isFinite && sigmaSMeters > 0)
            ? sigmaSMeters.clamp(0.0, FireDecisionConfig.maxFractileSigmaMeters)
            : 0.0;
    final sV = (sigmaVMps != null && sigmaVMps.isFinite && sigmaVMps > 0)
        ? sigmaVMps
        : 0.0;
    final termS = sS / v;
    final termV = etaSeconds * sV / v;
    final varc = termS * termS + termV * termV;
    return varc > 0 ? sqrt(varc) : 0.0;
  }

  /// Cancel the alarm stop poll timer.
  void cancelAlarmStopPollTimer() {
    _alarmStopPollTimer?.cancel();
    _alarmStopPollTimer = null;
  }
}
