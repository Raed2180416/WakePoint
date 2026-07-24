// lib/services/tracking/location_stream_handler.dart
//
// Handles GPS position stream processing in the background isolate.
// - Receives Position updates from LocationManager
// - Computes ETA using EtaEngine
// - Updates journey state (distance traveled, speed, etc.)
// - Coordinates with AlarmController for alarm checking
// - Manages sensor fusion for GPS dropout recovery

import 'dart:async';
import 'dart:developer' as dev;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'package:geowake2/services/active_route_manager.dart';
import 'package:geowake2/services/eta_engine.dart';
import 'package:geowake2/services/location_manager.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/config/power_policy.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/core/ekf/route_geometry.dart';
// ignore: deprecated_member_use_from_same_package
import 'package:geowake2/services/sensor_fusion.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/config/fire_decision_config.dart';

/// Context needed for location stream processing.
class LocationStreamContext {
  final ServiceInstance service;
  final EtaEngine etaEngine;
  final RouteRegistry registry;
  final ActiveRouteManager? activeManager;
  final bool isTestMode;
  final bool isBackgroundIsolate;

  /// Optional provider for whether the current position update should be marked
  /// as the final-alarm state when ingesting into [ActiveRouteManager].
  final bool Function()? isFinalAlarmProvider;

  // Destination info
  final LatLng? destination;
  final String? destinationName;
  final String? alarmMode;
  final double? alarmValue;
  final bool transitMode;

  // Current directions for persistence
  final Map<String, dynamic>? currentDirections;

  // Step data for ETA
  final List<double> stepBoundsMeters;
  final List<int> stepDurationsSeconds;
  final double? polylineTotalMeters;
  final Map<String, List<TransitLegStops>> transitLegStopsByKey;
  final List<TransitLegStops> fallbackTransitLegStops;

  LocationStreamContext({
    required this.service,
    required this.etaEngine,
    required this.registry,
    this.activeManager,
    this.isTestMode = false,
    this.isBackgroundIsolate = false,
    this.isFinalAlarmProvider,
    this.destination,
    this.destinationName,
    this.alarmMode,
    this.alarmValue,
    this.transitMode = false,
    this.currentDirections,
    this.stepBoundsMeters = const [],
    this.stepDurationsSeconds = const [],
    this.polylineTotalMeters,
    this.transitLegStopsByKey = const {},
    this.fallbackTransitLegStops = const [],
  });
}

/// Handles GPS position stream and related processing.
class LocationStreamHandler {
  // Stream subscription
  StreamSubscription<Position>? _positionSubscription;

  // GPS check timer for dropout detection
  Timer? _gpsCheckTimer;

  // Sensor fusion for GPS dropout
  // ignore: deprecated_member_use_from_same_package
  SensorFusionManager? _sensorFusionManager;
  bool _fusionActive = false;

  // Last GPS update time for dropout detection
  DateTime? _lastGpsUpdate;
  // GAP #15: GPS-blackout telemetry funnel. True while GPS has been silent past
  // the dropout buffer; emits gpsLost on entry and gpsReacquired on the next
  // real fix. Fail-open (telemetry never throws into the alarm path).
  bool _inGpsBlackout = false;
  DateTime? _blackoutStartedAt;

  // GPS dropout buffer duration
  Duration gpsDropoutBuffer = const Duration(seconds: 5);

  bool _fftEnabled = true;
  LocationStreamContext? _ctx;

  // Last processed position
  LatLng? _lastProcessedPosition;
  double? _lastSpeedMps;
  DateTime? _lastPositionTimestamp;
  DateTime? _lastDashboardBroadcastAt;

  // Journey start tracking
  DateTime? _startedAt;
  LatLng? _startPosition;
  double _distanceTravelledMeters = 0.0;
  int _etaSamples = 0;
  bool _timeAlarmEligible = false;

  // ETA state
  double? _smoothedETA;
  double? _smoothedSpeed;

  // Last snapshot save time
  DateTime? _lastSnapshotSave;

  // Callback for alarm checking
  Future<void> Function(Position position, ServiceInstance service)?
  onCheckAlarm;

  // Guard for sequential alarm checking
  bool _isCheckingAlarm = false;

  // G10: last time a dead-reckoned alarm evaluation was driven by the dropout
  // tick, used to rate-limit re-evaluation during a GPS blackout.
  DateTime? _lastDropoutAlarmEvalAt;

  // Callback for notification update
  void Function(ServiceInstance service)? onUpdateNotification;

  // Callback for state broadcast
  void Function({
    bool alarmFired,
    double? remainingStops,
    Map<String, dynamic>? debugInfo,
  })?
  onBroadcastState;

  // Callback for route broadcast
  void Function({bool force})? onMaybeBroadcastRoute;

  // Callback for EKF updates (optional, for wiring without changing alarm logic).
  void Function(EkfPublicState state)? onEkfUpdate;

  /// Optional callback invoked when an "end tracking" notification action is
  /// requested. If set, it becomes the single source of truth for cleanup and
  /// stopping the service.
  Future<void> Function(ServiceInstance service)? onEndTrackingRequested;

  // Test streams
  Stream<AccelerometerEvent>? testAccelerometerStream;
  Stream<GyroscopeEvent>? testGyroscopeStream;

  StreamSubscription<EkfPublicState>? _ekfStateSubscription;
  EkfPublicState? _lastEkfState;

  // Getters for state
  DateTime? get lastGpsUpdate => _lastGpsUpdate;
  LatLng? get lastProcessedPosition => _lastProcessedPosition;
  double? get lastSpeedMps => _lastSpeedMps;
  double? get smoothedETA => _smoothedETA;
  double? get smoothedSpeed => _smoothedSpeed;
  double get distanceTravelledMeters => _distanceTravelledMeters;
  int get etaSamples => _etaSamples;
  bool get timeAlarmEligible => _timeAlarmEligible;
  bool get fusionActive => _fusionActive;

  /// Start the location stream with the given context.
  Future<void> start(LocationStreamContext ctx) async {
    _ctx = ctx;
    await _positionSubscription?.cancel();

    // Determine battery level for power policy
    int batteryLevel = 100;
    if (!ctx.isTestMode) {
      try {
        final Battery battery = Battery();
        batteryLevel = await battery.batteryLevel;
      } catch (e) {
        dev.log(
          'Battery read failed, defaulting to 100: $e',
          name: 'LocationStreamHandler',
        );
        batteryLevel = 100;
      }
    }

    // Select power policy
    final policy =
        ctx.isTestMode
            ? PowerPolicy.testing()
            : PowerPolicyManager.forBatteryLevel(batteryLevel);

    gpsDropoutBuffer = policy.gpsDropoutBuffer;
    _fftEnabled = batteryLevel >= 20;

    dev.log(
      'DEBUG: LocationStreamHandler.start - delegating to LocationManager',
      name: 'LocationStreamHandler',
    );

    await LocationManager().start();

    _positionSubscription = LocationManager().positionStream.listen((
      Position position,
    ) {
      _handlePositionUpdate(position, ctx);
    });

    // Start GPS dropout checker
    _startGpsCheckTimer(ctx, policy);
  }

  /// Handle a position update.
  void _handlePositionUpdate(Position position, LocationStreamContext ctx) {
    try {
      dev.log(
        'DEBUG: Position received: (${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)})',
        name: 'LocationStreamHandler',
      );

      final nowFix = DateTime.now();
      // GAP #15: a real fix ended a GPS blackout — record how long it lasted.
      if (_inGpsBlackout) {
        final start = _blackoutStartedAt;
        TelemetryService.instance.gpsReacquired(
          blackoutSeconds: start != null
              ? nowFix.difference(start).inMilliseconds / 1000.0
              : 0.0,
        );
        _inGpsBlackout = false;
        _blackoutStartedAt = null;
      }
      _lastGpsUpdate = nowFix;
      _lastProcessedPosition = LatLng(position.latitude, position.longitude);
      _lastSpeedMps = position.speed;
      _lastPositionTimestamp = position.timestamp;

      final now = DateTime.now();
      if (_lastDashboardBroadcastAt == null ||
          now.difference(_lastDashboardBroadcastAt!).inSeconds >= 1) {
        try {
          LocationManager().broadcastPosition(
            lat: position.latitude,
            lng: position.longitude,
            heading: position.heading,
            speed: position.speed,
          );
        } catch (_) {}
        _lastDashboardBroadcastAt = now;
      }

      _ensureFusionManager(position, ctx);
      _sensorFusionManager?.updateGps(position);

      // Track movement distance since start
      _trackMovement(position, ctx);

      // Stop sensor fusion if active (GPS is back)
      // Keep fusion running continuously to avoid cold starts.

      // Compute ETA
      _computeEta(position, ctx);

      // Evaluate time-alarm eligibility (must run before alarm check)
      _evaluateTimeAlarmEligibility(ctx);

      // Ingest into active route manager
      if (ctx.activeManager != null) {
        final raw = LatLng(position.latitude, position.longitude);
        ctx.activeManager!.ingestPosition(raw);
      }

      // Check alarm condition (Sequential Guard)
      if (!_isCheckingAlarm) {
        _isCheckingAlarm = true;
        onCheckAlarm?.call(position, ctx.service).whenComplete(() {
          _isCheckingAlarm = false;
        });
      }

      // Update foreground with location
      ctx.service.invoke("updateLocation", {
        "latitude": position.latitude,
        "longitude": position.longitude,
        "speed": position.speed,
        "eta": _smoothedETA,
      });

      // Periodic persistence
      _maybePersistSnapshot(position, ctx);
    } catch (e, stack) {
      dev.log(
        'CRITICAL: Error in location stream listener: $e',
        stackTrace: stack,
        name: 'LocationStreamHandler',
      );
    }
  }

  /// Track movement distance since journey start.
  void _trackMovement(Position position, LocationStreamContext ctx) {
    try {
      _startedAt ??= position.timestamp;
      _startPosition ??= _lastProcessedPosition;

      // Preserve legacy behavior where the active manager receives a position
      // ingest that can carry the current "final alarm" flag.
      if (ctx.activeManager != null && _lastProcessedPosition != null) {
        final isFinalAlarm = ctx.isFinalAlarmProvider?.call() ?? false;
        ctx.activeManager!.ingestPosition(
          _lastProcessedPosition!,
          isFinalAlarm: isFinalAlarm,
        );
      }

      if (_startPosition != null && _lastProcessedPosition != null) {
        final d = Geolocator.distanceBetween(
          _startPosition!.latitude,
          _startPosition!.longitude,
          _lastProcessedPosition!.latitude,
          _lastProcessedPosition!.longitude,
        );
        _distanceTravelledMeters = d;
      }
    } catch (_) {}
  }

  /// Compute ETA using EtaEngine.
  void _computeEta(Position position, LocationStreamContext ctx) {
    if (ctx.destination == null) return;

    double distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      ctx.destination!.latitude,
      ctx.destination!.longitude,
    );

    // Find route coords for ETA calculation
    List<LatLng>? routeCoords;
    if (ctx.registry.entries.isNotEmpty) {
      // Prefer the active route when available (matches TrackingService's
      // previous selection logic).
      final activeKey = ctx.activeManager?.activeKey;
      if (activeKey != null) {
        try {
          final entry = ctx.registry.entries.firstWhere(
            (e) => e.key == activeKey,
          );
          routeCoords = entry.points;
        } catch (_) {
          routeCoords = ctx.registry.entries.first.points;
        }
      } else {
        routeCoords = ctx.registry.entries.first.points;
      }
    }

    if (routeCoords != null && routeCoords.isNotEmpty) {
      // GAP #22: plumb remainingStopsOnMetro so the metro scheduled-ETA model
      // (9.2 m/s + 25s dwell/stop) is actually used instead of degrading to
      // the 0.5 m/s floor underground. Count stops remaining on legs the rider
      // has not yet completed based on arc-progress.
      int? remainingStops;
      if (ctx.transitMode) {
        final activeKey = ctx.activeManager?.activeKey;
        final legs = _resolveTransitLegStops(ctx, activeKey);
        if (legs.isNotEmpty) {
          final progress = _distanceTravelledMeters;
          int count = 0;
          for (final leg in legs) {
            if (!leg.legEndMeters.isFinite) continue;
            if (progress < leg.legEndMeters) {
              // Use the leg's own stopsRemaining for the current leg;
              // for future legs, count all stops.
              if (progress >= leg.legStartMeters) {
                count += leg.stopsRemaining(progress);
              } else {
                count += leg.numStops;
              }
            }
          }
          if (count > 0) remainingStops = count;
        }
      }
      final result = ctx.etaEngine.computeEta(
        routeCoords: routeCoords,
        gps: position,
        isMetroMode: ctx.transitMode,
        stepBoundsMeters: ctx.stepBoundsMeters,
        stepDurationsSeconds: ctx.stepDurationsSeconds,
        totalRouteMeters: ctx.polylineTotalMeters,
        remainingStopsOnMetro: remainingStops,
      );
      _smoothedETA = result.etaSeconds;
      _smoothedSpeed = result.vEst;
      dev.log(
        'ETA_DEBUG handler: smoothedETA=${_smoothedETA?.toStringAsFixed(1)}, smoothedSpeed=${_smoothedSpeed?.toStringAsFixed(2)}',
        name: 'LocationStreamHandler',
      );
    } else {
      // Fallback if no route known
      double speed = position.speed > 0.5 ? position.speed : 2.8;
      _smoothedETA = distance / speed;
    }

    // Count ETA samples only when speed shows credible movement
    if (position.speed.isFinite && position.speed >= 0.5) {
      _etaSamples++;
    }
  }

  /// Maybe persist snapshot every 30 seconds.
  void _maybePersistSnapshot(Position position, LocationStreamContext ctx) {
    if (ctx.destination == null) return;

    final now = DateTime.now();
    if (_lastSnapshotSave == null ||
        now.difference(_lastSnapshotSave!).inSeconds >= 30) {
      _lastSnapshotSave = now;

      () async {
        try {
          final snap = TrackingSnapshot(
            destinationName: ctx.destinationName ?? 'Destination',
            destinationLat: ctx.destination!.latitude,
            destinationLng: ctx.destination!.longitude,
            alarmMode: ctx.alarmMode ?? 'distance',
            alarmValue: ctx.alarmValue ?? 0.0,
            metroMode: ctx.transitMode,
            userLat: position.latitude,
            userLng: position.longitude,
            createdAt: _startedAt ?? now,
            directions: ctx.currentDirections,
            ekfS: _lastEkfState?.s,
            ekfSigmaS: _lastEkfState?.sigmaS,
            ekfMode: _lastEkfState?.mode.name,
          );
          await TrackingStateStore.saveSnapshot(snap);
        } catch (e) {
          dev.log(
            'DEBUG: Persistence failed: $e',
            name: 'LocationStreamHandler',
          );
        }
      }();
    }
  }

  /// Start GPS check timer for dropout detection.
  void _startGpsCheckTimer(LocationStreamContext ctx, PowerPolicy policy) {
    _gpsCheckTimer?.cancel();
    final Duration checkPeriod = policy.notificationTick;

    _gpsCheckTimer = Timer.periodic(checkPeriod, (_) {
      _handleGpsCheckTick(ctx);
    });
  }

  /// Handle GPS check tick.
  void _handleGpsCheckTick(LocationStreamContext ctx) {
    // Handle notification action requests
    _processNotificationActions(ctx);

    // Re-post critical notifications
    _ensureCriticalNotificationsVisible();

    // Check for GPS dropout and enable fusion
    _checkGpsDropout(ctx);

    // G10: During a GPS blackout, drive alarm evaluation from the EKF here —
    // the positionStream is silent, so this periodic tick is the only thing
    // running. Rate-limited and only when we already have a dead-reckoned EKF.
    _maybeEvaluateAlarmDuringDropout(ctx);

    // Update notification
    onUpdateNotification?.call(ctx.service);

    // Broadcast state
    onBroadcastState?.call(
      alarmFired: false,
      debugInfo: {'destination': ctx.destinationName},
    );

    // Re-broadcast route periodically
    onMaybeBroadcastRoute?.call(force: false);

    // Evaluate time-alarm eligibility
    _evaluateTimeAlarmEligibility(ctx);
  }

  /// Process notification action requests.
  void _processNotificationActions(LocationStreamContext ctx) {
    () async {
      try {
        final stopAlarmRequested =
            await NotificationService.consumeStopAlarmRequest();
        if (stopAlarmRequested) {
          try {
            await NotificationService().cancelAlarm();
          } catch (_) {}
          try {
            await NotificationService().restoreJourneyProgressIfActive();
          } catch (_) {}
        }

        final muteJourneyRequested =
            await NotificationService.consumeMuteJourneyRequest();
        if (muteJourneyRequested) {
          try {
            await TrackingStateStore.setNotificationsMuted(true);
            await NotificationService().cancelJourneyProgress();
          } catch (_) {}
        }

        final endTrackingRequested =
            await NotificationService.consumeEndTrackingRequest();
        if (endTrackingRequested) {
          final handler = onEndTrackingRequested;
          if (handler != null) {
            await handler(ctx.service);
            return;
          }

          try {
            await NotificationService().cancelAllNotifications();
          } catch (_) {}
          try {
            await TrackingStateStore.clearSnapshot();
            await TrackingStateStore.setActive(false);
            await TrackingStateStore.setPaused(false);
            await TrackingStateStore.setAlarmFired(false);
            await TrackingStateStore.setNotificationsMuted(false);
          } catch (_) {}

          // Signal stop via callback if needed
          try {
            ctx.service.stopSelf();
          } catch (_) {}
          return;
        }
      } catch (_) {}
    }();
  }

  /// Ensure critical notifications are visible.
  void _ensureCriticalNotificationsVisible() {
    () async {
      try {
        await NotificationService().ensureAlarmNotificationVisible();
      } catch (_) {}
      try {
        await NotificationService().ensureTrackingPausedNotificationVisible();
      } catch (_) {}
    }();
  }

  /// Check for GPS dropout and enable sensor fusion.
  void _checkGpsDropout(LocationStreamContext ctx) {
    final last = _lastGpsUpdate;
    if (last == null) return;

    final silentFor = DateTime.now().difference(last);
    if (silentFor >= gpsDropoutBuffer) {
      // GAP #15: mark the start of a GPS blackout once (not every tick) and
      // record it — the funnel that tells us how often/long riders go dark.
      if (!_inGpsBlackout) {
        _inGpsBlackout = true;
        _blackoutStartedAt = last;
        TelemetryService.instance.gpsLost(
          sinceLastFixSeconds: silentFor.inMilliseconds / 1000.0,
        );
      }
      if (_lastProcessedPosition != null) {
        _ensureFusionManagerPosition(_lastProcessedPosition!, ctx);
      }
    }
  }

  /// G10: When GPS has been silent past the dropout buffer, evaluate the alarm
  /// against the dead-reckoned EKF state. Synthesizes a Position whose speed is
  /// EKF.v and whose accuracy is a sentinel so _checkAndTriggerAlarm refuses to
  /// snap/ingest it (arc-progress is taken from EKF.s downstream). lat/lng carry
  /// the last known fix only for logging/geofence fallbacks.
  void _maybeEvaluateAlarmDuringDropout(LocationStreamContext ctx) {
    final now = DateTime.now();
    final last = _lastGpsUpdate;
    // If GPS is currently LIVE (a recent real fix), the positionStream is already
    // driving evaluation — don't double-eval here.
    if (last != null && now.difference(last) < gpsDropoutBuffer) return;

    // Otherwise we are in a GPS blackout OR cold-start-underground (no fix yet).
    // GAP #1 (BLOCK): the reachability physics net MUST run on the wall clock
    // regardless of EKF state — this is the never-late guarantee for the rider
    // who opens the app already underground. Previously this bailed when there
    // was no prior fix (`last == null`) or no EKF, leaving that rider a SILENT
    // no-wake. The synthesized position carries the sentinel accuracy so it is
    // never snapped/ingested as a real fix; arc-progress comes from the EKF when
    // one exists, else it is unknown (null) downstream and ONLY the reachability
    // bound governs the fire decision (see AlarmController cold-start backstop).

    // Rate-limit (tick can be ~1s; ~2s re-eval avoids notification churn).
    if (_lastDropoutAlarmEvalAt != null &&
        now.difference(_lastDropoutAlarmEvalAt!) <
            FireDecisionConfig.dropoutEvalMinInterval) {
      return;
    }
    _lastDropoutAlarmEvalAt = now;

    final ekf = _lastEkfState;
    final lastPos = _lastProcessedPosition;
    final synth = Position(
      latitude: lastPos?.latitude ?? 0.0,
      longitude: lastPos?.longitude ?? 0.0,
      timestamp: now,
      accuracy: FireDecisionConfig.deadReckonAccuracySentinel,
      altitude: 0.0,
      heading: 0.0,
      speed: (ekf != null && ekf.v.isFinite) ? ekf.v : 0.0,
      speedAccuracy: 0.0,
      altitudeAccuracy: 0.0,
      headingAccuracy: 0.0,
    );

    if (!_isCheckingAlarm) {
      _isCheckingAlarm = true;
      onCheckAlarm?.call(synth, ctx.service).whenComplete(() {
        _isCheckingAlarm = false;
      });
    }
  }

  void _ensureFusionManager(Position position, LocationStreamContext ctx) {
    if (_sensorFusionManager != null) return;
    _ensureFusionManagerPosition(
      LatLng(position.latitude, position.longitude),
      ctx,
    );
  }

  void _ensureFusionManagerPosition(
    LatLng position,
    LocationStreamContext ctx,
  ) {
    if (_sensorFusionManager != null) return;

    RouteGeometry? geometry;
    final activeKey = ctx.activeManager?.activeKey;
    if (activeKey != null) {
      final entry = ctx.registry.getByKey(activeKey);
      if (entry != null && entry.points.length >= 2) {
        geometry = RouteGeometry.fromPoints(
          entry.points,
          maxLateralErrorMeters: ctx.transitMode ? 50 : 75,
        );
      }
    }

    // ignore: deprecated_member_use_from_same_package
    _sensorFusionManager = SensorFusionManager(
      initialPosition: position,
      accelerometerStream:
        ctx.isTestMode
          ? (testAccelerometerStream ??
            const Stream<AccelerometerEvent>.empty())
          : null,
      gyroscopeStream:
        ctx.isTestMode
          ? (testGyroscopeStream ??
            const Stream<GyroscopeEvent>.empty())
          : null,
      routeGeometry: geometry,
      enableEkf: geometry != null,
    );
    // Wire station snap confirmed callback to ARM (§24.2).
    _sensorFusionManager!.onStationSnapConfirmed = (event) {
      ctx.activeManager?.onStationSnapConfirmed(event);
    };
    _sensorFusionManager!.updateTransitLegStops(
      _resolveTransitLegStops(ctx, activeKey),
    );
    _sensorFusionManager!.setFftEnabled(_fftEnabled);
    _sensorFusionManager!.startFusion();
    _ekfStateSubscription?.cancel();
    DateTime? lastEkfHealthEmit;
    _ekfStateSubscription = _sensorFusionManager!.ekfStateStream.listen((
      state,
    ) {
      _lastEkfState = state;
      onEkfUpdate?.call(state);
      // BACKLOG #16: emit ekfHealth ~every 30s to track filter convergence,
      // phantom rejections, and cold-start frequency in production.
      final now = DateTime.now();
      if (lastEkfHealthEmit == null ||
          now.difference(lastEkfHealthEmit!).inSeconds >= 30) {
        lastEkfHealthEmit = now;
        TelemetryService.instance.ekfHealth(
          sigmaSMeters: state.sigmaS,
          sigmaVMps: state.sigmaV,
          coldStart: state.mode.name == 'coldStart',
        );
      }
    });
    _fusionActive = true;
  }

  /// Evaluate time-alarm eligibility.
  void _evaluateTimeAlarmEligibility(LocationStreamContext ctx) {
    try {
      if (ctx.alarmMode == 'time' && !_timeAlarmEligible) {
        final nowTs = _lastPositionTimestamp ?? DateTime.now();
        final sinceStart =
            _startedAt != null ? nowTs.difference(_startedAt!) : Duration.zero;
        // Eligible after: moved >= 100m AND at least 3 ETA samples with speed >=0.5 m/s AND 30s since start
        if (_distanceTravelledMeters >= 100.0 &&
            _etaSamples >= 3 &&
            sinceStart.inSeconds >= 30) {
          _timeAlarmEligible = true;
          dev.log('Time alarm is now eligible', name: 'LocationStreamHandler');
        }
      }
    } catch (_) {}
  }

  /// Stop the location stream.
  Future<void> stop() async {
    _gpsCheckTimer?.cancel();
    _gpsCheckTimer = null;

    await _positionSubscription?.cancel();
    _positionSubscription = null;

    _sensorFusionManager?.stopFusion();
    _sensorFusionManager = null;
    _fusionActive = false;

    await _ekfStateSubscription?.cancel();
    _ekfStateSubscription = null;
    _ctx = null;
  }

  /// Reset state for a new journey.
  void reset() {
    _ctx = null;
    _lastGpsUpdate = null;
    _lastProcessedPosition = null;
    _lastSpeedMps = null;
    _startedAt = null;
    _startPosition = null;
    _distanceTravelledMeters = 0.0;
    _etaSamples = 0;
    _timeAlarmEligible = false;
    _smoothedETA = null;
    _smoothedSpeed = null;
    _lastSnapshotSave = null;
    _fusionActive = false;
    _lastEkfState = null;
  }

  /// Clear all state for testing.
  void clear() {
    stop();
    reset();
  }

  void updateRouteGeometryForKey(String? routeKey) {
    final ctx = _ctx;
    if (ctx == null) return;
    final key = routeKey ?? ctx.activeManager?.activeKey;
    if (key == null) return;

    RouteGeometry? geometry;
    final entry = ctx.registry.getByKey(key);
    if (entry != null && entry.points.length >= 2) {
      geometry = RouteGeometry.fromPoints(
        entry.points,
        maxLateralErrorMeters: ctx.transitMode ? 50 : 75,
      );
    }

    _sensorFusionManager?.updateRouteGeometry(geometry);
    _sensorFusionManager?.updateTransitLegStops(
      _resolveTransitLegStops(ctx, key),
    );
  }

  List<TransitLegStops> _resolveTransitLegStops(
    LocationStreamContext ctx,
    String? activeKey,
  ) {
    if (activeKey != null && ctx.transitLegStopsByKey.containsKey(activeKey)) {
      return ctx.transitLegStopsByKey[activeKey] ?? const [];
    }
    return ctx.fallbackTransitLegStops;
  }
}
