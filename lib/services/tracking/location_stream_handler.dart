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
import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/config/power_policy.dart';
import 'package:geowake2/services/route_registry.dart';
// ignore: deprecated_member_use_from_same_package
import 'package:geowake2/services/sensor_fusion.dart';
import 'package:geowake2/services/tracking_state_store.dart';

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

  // GPS dropout buffer duration
  Duration gpsDropoutBuffer = const Duration(seconds: 5);

  // Last processed position
  LatLng? _lastProcessedPosition;
  double? _lastSpeedMps;
  DateTime? _lastPositionTimestamp;

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

  /// Optional callback invoked when an "end tracking" notification action is
  /// requested. If set, it becomes the single source of truth for cleanup and
  /// stopping the service.
  Future<void> Function(ServiceInstance service)? onEndTrackingRequested;

  // Test streams
  Stream<AccelerometerEvent>? testAccelerometerStream;

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

      _lastGpsUpdate = DateTime.now();
      _lastProcessedPosition = LatLng(position.latitude, position.longitude);
      _lastSpeedMps = position.speed;
      _lastPositionTimestamp = position.timestamp;

      // Track movement distance since start
      _trackMovement(position, ctx);

      // Stop sensor fusion if active (GPS is back)
      if (_fusionActive) {
        _sensorFusionManager?.stopFusion();
        _fusionActive = false;
      }

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
      final result = ctx.etaEngine.computeEta(
        routeCoords: routeCoords,
        gps: position,
        isMetroMode: ctx.transitMode,
        stepBoundsMeters: ctx.stepBoundsMeters,
        stepDurationsSeconds: ctx.stepDurationsSeconds,
        totalRouteMeters: ctx.polylineTotalMeters,
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
      if (!_fusionActive && _lastProcessedPosition != null) {
        // ignore: deprecated_member_use_from_same_package
        _sensorFusionManager = SensorFusionManager(
          initialPosition: _lastProcessedPosition!,
          accelerometerStream:
              ctx.isTestMode
                  ? (testAccelerometerStream ??
                      const Stream<AccelerometerEvent>.empty())
                  : null,
        );
        _sensorFusionManager!.startFusion();
        _fusionActive = true;
      }
    }
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
  }

  /// Reset state for a new journey.
  void reset() {
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
  }

  /// Clear all state for testing.
  void clear() {
    stop();
    reset();
  }
}
