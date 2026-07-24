// lib/services/trackingservice.dart
//
// +----------------------------------------------------------------------------+
// � TRACKING SERVICE - Main background location tracking orchestrator          �
// �----------------------------------------------------------------------------�
// � This file is intentionally large (~4400 lines) due to tight coupling       �
// � between GPS processing, alarm logic, state management, and UI sync.        �
// � Splitting would introduce race conditions and complex cross-file state.    �
// �                                                                            �
// � ARCHITECTURE OVERVIEW:                                                     �
// � - TrackingService: Singleton facade for foreground/background comm         �
// � - _onStart(): Background isolate entry point, runs position loop           �
// � - State flows: GPS ? snap-to-route ? progress calc ? alarm check ? notify  �
// �                                                                            �
// � KEY SECTIONS (search for these comments):                                  �
// � - "SECTION: GPS STREAM" - Position acquisition and filtering               �
// � - "SECTION: ROUTE PROGRESS" - Distance/stop calculations                   �
// � - "SECTION: ALARM LOGIC" - Threshold checking and firing                   �
// � - "SECTION: STATE SYNC" - Foreground/background communication              �
// � - "SECTION: POWER MANAGEMENT" - Battery optimization                       �
// +----------------------------------------------------------------------------+
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakepoint_native/wakepoint_native.dart';
import 'dart:developer' as dev;
import 'package:google_maps_flutter/google_maps_flutter.dart';

// Centralized logging - use trackingLog, alarmLog, gpsLog for structured output
import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/services/telemetry/telemetry_session.dart';

import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/location_manager.dart'; // NEW
import 'package:geowake2/services/sensor_fusion.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/route_session_manager.dart';
import 'package:geowake2/services/active_route_manager.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/telemetry/telemetry_service.dart';
import 'package:geowake2/core/clock/app_clock.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/eta_engine.dart';
import 'package:geowake2/services/reroute_policy.dart';
import 'package:geowake2/services/anti_theft_service.dart';
import 'package:geowake2/services/navigation_service.dart';
import 'package:geowake2/services/snap_to_route.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/config/power_policy.dart';
import 'package:geowake2/services/soft_lock_manager.dart';
import 'package:geowake2/services/deviation_monitor.dart';
import 'package:geowake2/services/offline_coordinator.dart';
import 'package:geowake2/services/reroute_constraints.dart';
import 'package:geowake2/services/tracking_termination_policy.dart';
import 'package:geowake2/core/ekf/ekf_types.dart';
// Modular tracking components (Phase 1 refactoring)
import 'package:geowake2/services/tracking/tracking.dart';
// ... rest of imports

// (Test code and other definitions remain the same)
Stream<Position>? testGpsStream;
@visibleForTesting
Stream<AccelerometerEvent>? testAccelerometerStream;
@visibleForTesting
Stream<GyroscopeEvent>? testGyroscopeStream;
@visibleForTesting
Duration gpsDropoutBuffer = const Duration(seconds: 25);

class _ResolvedAlarmRouteState {
  final double? progressMeters;
  final String? activeKey;

  const _ResolvedAlarmRouteState({
    required this.progressMeters,
    required this.activeKey,
  });
}

class TestServiceInstance implements ServiceInstance {
  final _eventControllers = <String, StreamController<Map<String, dynamic>?>>{};
  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    dev.log("Test service invoke: $method, args: $args", name: "TestService");
  }

  @override
  Future<void> stopSelf() async {
    dev.log("Test service stopped", name: "TestService");
  }

  @override
  Stream<Map<String, dynamic>?> on(String event) {
    _eventControllers.putIfAbsent(
      event,
      () => StreamController<Map<String, dynamic>?>.broadcast(),
    );
    return _eventControllers[event]!.stream;
  }

  void dispose() {
    for (var controller in _eventControllers.values) {
      controller.close();
    }
  }
}

class TrackingService {
  static bool isTestMode = false;
  static final TrackingService _instance = TrackingService._internal();
  factory TrackingService() => _instance;
  TrackingService._internal();

  /// Whether to bypass strict termination rules (for simulation/dashboard usage).
  bool _isSimulationMode = false;
  bool get isSimulationMode => _isSimulationMode;

  /// Enable/disable simulation mode (bypasses termination policies).
  void setSimulationMode(bool enabled) {
    _isSimulationMode = enabled;
    dev.log(
      'Simulation mode set to: $enabled (UI Isolate)',
      name: 'TrackingService',
    );

    // Propagate to background service if running
    if (!kIsWeb && _service != null) {
      _service.invoke('setSimulationMode', {'enabled': enabled});
    }
  }

  final FlutterBackgroundService? _service =
      kIsWeb ? null : FlutterBackgroundService();

  /// Manages foreground-to-background isolate communication.
  late final ForegroundBridge _foregroundBridge = ForegroundBridge(
    service: _service,
    isTestMode: () => TrackingService.isTestMode,
  );

  /// Returns true if [step] is a metro/rail TRANSIT step (SUBWAY, HEAVY_RAIL, RAIL, METRO_RAIL, MONORAIL).

  // Foreground <-> background invoke reliability (delegates to ForegroundBridge)

  void _ensureAckListenersRegistered() {
    if (TrackingService.isTestMode) return;

    // Delegate all listener registration to ForegroundBridge
    _foregroundBridge.ensureListenersRegistered();

    // Wire up alarm callback to show notifications
    _foregroundBridge.onAlarmTrigger ??= (
      title,
      body,
      allowContinue,
      playSound,
    ) async {
      dev.log(
        'DEBUG: Foreground received triggerAlarm from background (sound: $playSound)',
        name: 'TrackingService',
      );
      await NotificationService().showWakeUpAlarm(
        title: title,
        body: body,
        allowContinueTracking: allowContinue,
        playSound: playSound,
      );
    };

    // Pipe ForegroundBridge streams to TrackingService's exposed streams
    // This allows external callers to use TrackingService.routeSwitchStream etc
    _foregroundBridge.routeSwitchStream.listen((e) {
      // Migrate alarm state (fired flags) to the new route key so alarms don't re-fire
      _alarmController.migrateAlarmState(e.fromKey, e.toKey);
      _routeSwitchCtrl.add(e);
    });
    _foregroundBridge.activeRouteStateStream.listen(
      (s) => _routeStateCtrl.add(s),
    );
    _foregroundBridge.locationStream.listen((p) => _locationCtrl.add(p));
    _foregroundBridge.etaSecondsStream.listen((eta) => _etaCtrl.add(eta));
  }

  Future<bool> _invokeWithAckRetry({
    required String method,
    required Map<String, dynamic> args,
    required String ackEvent,
  }) async {
    if (TrackingService.isTestMode) return false;

    _ensureAckListenersRegistered();

    // Delegate the actual invoke with retry to ForegroundBridge
    return _foregroundBridge.invokeWithAckRetry(
      method: method,
      args: args,
      ackEvent: ackEvent,
    );
  }

  // Expose streams bound to background isolate controllers
  Stream<ActiveRouteState> get activeRouteStateStream => _routeStateCtrl.stream;
  Stream<RouteSwitchEvent> get routeSwitchStream => _routeSwitchCtrl.stream;
  Stream<RerouteDecision> get rerouteDecisionStream => _rerouteCtrl.stream;
  Stream<Position> get locationStream => _locationCtrl.stream;
  Stream<double?> get etaSecondsStream => _etaCtrl.stream;

  // Memoized so arming can await readiness: splash kicks this off
  // fire-and-forget, but a fast-tapping user could reach startTracking()
  // before configure() finished — the service would start unconfigured and
  // the session would silently never track. Re-invoking is a no-op once the
  // in-flight future exists; a failed attempt clears it so retry is possible.
  Future<void>? _initServiceFuture;

  Future<void> initializeService() {
    if (isTestMode) return Future.value();
    return _initServiceFuture ??= _initializeServiceImpl().catchError((
      Object e,
    ) {
      _initServiceFuture = null;
      throw e;
    });
  }

  Future<void> _initializeServiceImpl() async {
    _ensureAckListenersRegistered(); // Ensure bridge is wired up
    await _service?.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        // G4: after a device reboot, re-run the background entrypoint so the
        // recovery-from-snapshot path in _onStart (null initialData branch) can
        // resume an active session. Only re-arms if TrackingStateStore.isActive().
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: 'geowake_tracking_channel_v2',
        initialNotificationTitle: 'GeoWake Tracking',
        initialNotificationContent: 'Initializing...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  // MODIFIED: This method now accepts the alarm parameters from the UI
  Future<void> startTracking({
    required LatLng destination,
    required String destinationName,
    required String alarmMode,
    required double alarmValue,
    bool transitMode = false,
    bool allowNotificationsInTest = false,
    bool useInjectedPositions = false,
    List<LatLng>? routePoints,
  }) async {
    // Ensure foreground listeners are registered to receive alarm triggers from background
    _ensureAckListenersRegistered();

    // HANDOFF §3 reliability funnel: stamp device·OEM·Android-version context and
    // record session-start + arm permission states. Fire-and-forget + fail-open —
    // must never delay or break arming.
    unawaited(recordSessionStart(alarmMode: alarmMode, alarmValue: alarmValue));

    final Map<String, dynamic> params = {
      'destinationLat': destination.latitude,
      'destinationLng': destination.longitude,
      'destinationName': destinationName,
      'alarmMode': alarmMode,
      'alarmValue': alarmValue,
      'transitMode': transitMode,
      'useInjectedPositions': useInjectedPositions,
      'isSimulationMode': _isSimulationMode,
    };
    dev.log(
      'DEBUG: setAlarm - values: mode=$alarmMode value=$alarmValue useInjected=$useInjectedPositions',
      name: 'TrackingService',
    );
    if (routePoints != null) {
      params['routePoints'] =
          routePoints
              .map((p) => {'lat': p.latitude, 'lng': p.longitude})
              .toList();
    }
    if (isTestMode) {
      try {
        // In demo, allow real notifications even in test mode
        // ignore: invalid_use_of_visible_for_testing_member
        NotificationService.isTestMode = !allowNotificationsInTest;
      } catch (e) {
        trackingLog.debug(
          'Test mode notification setup skipped',
          data: {'error': e.toString()},
        );
      }
      // In test mode, we can directly call _onStart with the parameters
      await _onStart(TestServiceInstance(), initialData: params);
      return;
    }
    // Defense-in-depth for the splash/arm race: make sure configure() has
    // actually completed before starting the service. Memoized, so this is a
    // no-op in the normal path and only blocks when the user out-raced init.
    try {
      await initializeService().timeout(const Duration(seconds: 5));
    } catch (e) {
      trackingLog.error('initializeService before start failed', error: e);
    }
    if (!await (_service?.isRunning() ?? Future.value(false))) {
      await _service?.startService();
    }
    try {
      // Ensure notification state is unmuted for a new session
      await TrackingStateStore.setNotificationsMuted(false);
      // Mark session active (snapshot is persisted by UI when available)
      await TrackingStateStore.setActive(true);
      await TrackingStateStore.setPaused(false);
      await TrackingStateStore.setAlarmFired(false);
      await NotificationService().showJourneyProgress(
        title: 'Journey to $destinationName',
        subtitle: 'Starting�',
        progress0to1: 0,
        isTracking: true,
      );
    } catch (e) {
      // Best-effort state initialization - tracking continues even if notifications fail
      trackingLog.warn(
        'setAlarm: state init partially failed',
        data: {'error': e.toString()},
      );
    }
    dev.log(
      'DEBUG: Invoking startTracking on background service',
      name: 'TrackingService',
    );
    final acked = await _invokeWithAckRetry(
      method: 'startTracking',
      args: params,
      ackEvent: 'startTrackingAck',
    );
    if (!acked) {
      // The background isolate never ACKed within the retry budget (~2.9s).
      // Without escalation the UI arms while nothing tracks — the worst
      // possible failure for a wake-up product. Record it durably, then try a
      // full service (re)start + one more acked handshake before falling back
      // to a blind invoke.
      TelemetryService.instance.reliability(startAckFailed: true);
      trackingLog.error(
        'startTracking not ACKed by background isolate; attempting recovery',
      );
      bool recovered = false;
      try {
        if (!await (_service?.isRunning() ?? Future.value(false))) {
          await _service?.startService();
        }
        recovered = await _invokeWithAckRetry(
          method: 'startTracking',
          args: params,
          ackEvent: 'startTrackingAck',
        );
      } catch (e) {
        trackingLog.error('startTracking recovery attempt failed', error: e);
      }
      if (!recovered) {
        // Last resort: best-effort invoke (older background or unexpected ack
        // failures). The startAckFailed telemetry above keeps this diagnosable.
        try {
          _service?.invoke('startTracking', params);
        } catch (e) {
          trackingLog.error('startTracking fallback invoke failed', error: e);
        }
      }
    }
    // Start sending heartbeats to background service
    _startForegroundHeartbeat();
  }

  Future<void> stopTracking({bool stopServiceInstance = true}) async {
    dev.log(
      'STOP TRACKING CALLED. StackTrace: ${StackTrace.current}',
      name: 'TrackingService',
    );
    _trackingSessionActive = false;
    // Stop heartbeat sending
    _stopForegroundHeartbeat();
    // Make sure to stop the alarm in the foreground process first
    try {
      await AlarmPlayer.stop();
      NotificationService().stopVibration();
    } catch (e) {
      dev.log(
        'Error stopping alarm in foreground: $e',
        name: 'TrackingService',
      );
    }

    if (isTestMode) {
      _onStop();
      return;
    }

    final running = await _service?.isRunning() ?? false;
    if (running) {
      _service?.invoke("stopTracking", {'stopSelf': stopServiceInstance});
    } else {
      // If service already stopped, still clear foreground state
      _onStop();
    }
  }

  Future<void> muteJourneyNotifications() async {
    try {
      await TrackingStateStore.setNotificationsMuted(true);
      await NotificationService().cancelJourneyProgress();
    } catch (e) {
      trackingLog.warn(
        'muteJourneyNotifications failed',
        data: {'error': e.toString()},
      );
    }
  }

  Future<void> resumeFromNotification() async {
    try {
      await TrackingStateStore.setNotificationsMuted(false);

      final paused = await TrackingStateStore.isPaused();
      if (!paused) {
        return;
      }

      // If tracking was paused (app swiped away), restart from snapshot.
      final snapshot = await TrackingStateStore.loadSnapshot();
      if (snapshot != null) {
        // If threshold already satisfied on reopen, end tracking immediately.
        if (!TrackingService.isTestMode) {
          try {
            final pos = await Geolocator.getCurrentPosition();
            final d = Geolocator.distanceBetween(
              pos.latitude,
              pos.longitude,
              snapshot.destinationLat,
              snapshot.destinationLng,
            );
            if (snapshot.alarmMode == 'distance' &&
                d <= (snapshot.alarmValue * 1000.0)) {
              await completeEndTracking();
              return;
            }
          } catch (e) {
            // GPS unavailable on resume - continue with tracking anyway
            gpsLog.warn(
              'Could not get position on resume',
              data: {'error': e.toString()},
            );
          }
        }

        await TrackingStateStore.setActive(true);
        await TrackingStateStore.setPaused(false);
        await TrackingStateStore.setAlarmFired(false);
        try {
          await NotificationService().cancelTrackingPaused();
        } catch (e) {
          trackingLog.debug(
            'cancelTrackingPaused failed',
            data: {'error': e.toString()},
          );
        }

        if (!TrackingService.isTestMode) {
          final running = await _service?.isRunning() ?? false;
          if (!running) {
            await _service?.startService();
          }
          _service?.invoke('startTracking', {
            'destinationLat': snapshot.destinationLat,
            'destinationLng': snapshot.destinationLng,
            'destinationName': snapshot.destinationName,
            'alarmMode': snapshot.alarmMode,
            'alarmValue': snapshot.alarmValue,
            'transitMode': snapshot.metroMode,
            'useInjectedPositions': false,
          });

          // Restore route events/step bounds so alarms behave consistently.
          // Route will be freshly fetched by UI after resume; we avoid reusing stale directions.
        }

        await NotificationService().showJourneyProgress(
          title: 'Journey to ${snapshot.destinationName}',
          subtitle: 'Resumed',
          progress0to1: 0,
          isTracking: true,
        );
        return;
      }

      // Fallback: just restore the last journey notification content.
      final payload = await TrackingStateStore.loadProgressPayload();
      if (payload != null) {
        await NotificationService().showJourneyProgress(
          title: payload.title,
          subtitle: payload.subtitle,
          progress0to1: payload.progress,
          isTracking: true,
        );
      }
    } catch (e) {
      trackingLog.error('resumeFromNotification failed', error: e);
    }
  }

  /// Start sending heartbeats to the background service (delegates to ForegroundBridge).
  void _startForegroundHeartbeat() {
    if (_isBackgroundIsolate) return;
    _foregroundBridge.startHeartbeat();
  }

  /// Stop sending heartbeats (delegates to ForegroundBridge).
  void _stopForegroundHeartbeat() {
    _foregroundBridge.stopHeartbeat();
  }

  // Mirror app lifecycle transitions for bookkeeping
  void handleAppLifecycleChange(AppLifecycleState state) async {
    dev.log(
      'DEBUG: handleAppLifecycleChange called with state: $state',
      name: 'TrackingService',
    );

    if (TrackingService.isTestMode) return;

    // When app resumes, restart heartbeat sending
    if (state == AppLifecycleState.resumed) {
      dev.log(
        'DEBUG: App resumed - restarting foreground heartbeat',
        name: 'TrackingService',
      );
      _startForegroundHeartbeat();
      _startForegroundHeartbeat();
      // Also tell background we're back
      final running = await _service?.isRunning() ?? false;
      if (running) {
        try {
          _service?.invoke('foregroundResumed', {});
        } catch (e) {
          trackingLog.debug(
            'foregroundResumed invoke failed',
            data: {'error': e.toString()},
          );
        }
      }
      return;
    }

    // IMPORTANT: Do NOT stop heartbeats on paused state!
    // When app is simply backgrounded (paused), the Flutter timer continues to run
    // and heartbeats will still be sent. This is the CORRECT behavior.
    // Only when the app is truly killed (swiped away from recents) will the process
    // die and heartbeats will naturally stop, allowing background to detect the timeout.
    //
    // Stopping heartbeats on 'paused' caused the bug where tracking paused notification
    // appeared when app was simply backgrounded (not swiped away).
    if (state == AppLifecycleState.detached) {
      dev.log(
        'DEBUG: App detached - this typically means process is being killed',
        name: 'TrackingService',
      );
      // Note: detached state is rarely received reliably on Android.
      // The natural timeout detection is the primary mechanism.
    }
  }

  Future<void> completeEndTracking({bool navigateHome = true}) async {
    try {
      await NotificationService().cancelAllNotifications();
      await TrackingStateStore.clearSnapshot();
      await TrackingStateStore.setActive(false);
      await TrackingStateStore.setPaused(false);
      await TrackingStateStore.setAlarmFired(false);
      await TrackingStateStore.setNotificationsMuted(false);
    } catch (e) {
      trackingLog.warn(
        'completeEndTracking state cleanup failed',
        data: {'error': e.toString()},
      );
    }

    await stopTracking();

    // Stop anti-theft monitoring if active. Fire-and-forget so it can never
    // block or fail the end-tracking cleanup.
    unawaited(AntiTheftService.instance.stopMonitoring());

    // Optionally navigate back to a safe screen when not under test
    if (navigateHome && !TrackingService.isTestMode) {
      try {
        final nav = NavigationService.navigatorKey.currentState;
        nav?.pushNamedAndRemoveUntil('/', (route) => false);
      } catch (e) {
        trackingLog.debug(
          'Home navigation failed',
          data: {'error': e.toString()},
        );
      }
    }
  }

  @visibleForTesting
  bool get fusionActive => _fusionActive;
  @visibleForTesting
  bool get alarmTriggered => _alarmController.anyDestinationAlarmFired;
  @visibleForTesting
  DateTime? get lastGpsUpdateValue => _lastGpsUpdate;
  @visibleForTesting
  LatLng? get lastValidPosition => _lastProcessedPosition;

  @visibleForTesting
  LatLng? get destination => _destination;

  @visibleForTesting
  String? get alarmMode => _alarmMode;

  @visibleForTesting
  double? get alarmValue => _alarmValue;

  @visibleForTesting
  bool get trackingActive => _trackingSessionActive;

  /// Reset all state for testing purposes. Call in setUp to ensure clean state.
  @visibleForTesting
  void resetForTesting() {
    _trackingSessionActive = false;
    // Reset alarm state via AlarmController (single source of truth)
    _alarmController.resetAlarmState();
    _routeEventsByKey.clear();
    _stepBoundsMetersByKey.clear();
    _stepStopsCumulativeByKey.clear();
    _transitLegStopsByKey.clear();
    _firstTransitBoardingByKey.clear();
    _transitModeByKey.clear();
    _routeEvents = const [];
    _stepBoundsMeters = const [];
    _transitLegStops = const [];
    _firstTransitBoarding = null;
    _transitMode = false;
    _destination = null;
    _destinationName = null;
    _alarmMode = null;
    _lastActiveState = null;
    _lastProcessedPosition = null;
    _lastSnapResult = null;
    _lastEkfState = null;
    _lastEkfAlarmSnapshot = null;
    _cachedRoutePayload = null;
    _lastRouteBroadcastAt = null;
    // Reset session manager to pick up new isTestMode value
    _sessionManagerInstance = null;
    // Reset modular AlarmController (Phase 1 migration)
    _alarmController.clear();
    _alarmValue = null;
  }
}

@pragma('vm:entry-point')
bool onIosBackground(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

// ===================================================================
// BACKGROUND ISOLATE STATE
// ===================================================================
bool _isBackgroundIsolate = false;
bool _trackingSessionActive =
    false; // true only after startTracking is processed
StreamSubscription<Position>? _positionSubscription;
DateTime? _lastGpsUpdate;
SensorFusionManager? _sensorFusionManager;

Timer? _gpsCheckTimer;
LatLng? _lastProcessedPosition;
double? _smoothedETA;
final EtaEngine _etaEngine = EtaEngine();
double? _apiEtaSeconds;

final HeartbeatMonitor _heartbeatMonitor = HeartbeatMonitor(
  isEnabled: () => _isBackgroundIsolate && !TrackingService.isTestMode,
);

final LocationStreamHandler _locationStreamHandler = LocationStreamHandler();
bool _fusionActive = false;
double? _lastSpeedMps;
// Debug/telemetry for diagnosing "haywire" alarms (playground + real GPS).
double? _lastComputedProgressMeters;
double? _lastComputedOffsetMeters;
String? _lastComputedActiveKey;
double? _lastComputedProgressJumpMeters;
String? _lastComputedNextEventType;
double? _lastComputedToNextEventMeters;
double? _lastComputedPolylineTotalMeters;
double? _lastComputedStepTotalMeters;
EkfPublicState? _lastEkfState;
EkfPublicState? _lastEkfAlarmSnapshot;

// In playground/simulation runs the dashboard can request an alarm reset.
// If progress jitters slightly backwards due to snapping, we must NOT clear
// fired-leg state (otherwise preboarding can refire repeatedly at the same spot).
final Map<String, double> _maxProgressMetersSeenByKey = {};
// Support for injected test positions from foreground (demo path)
// Handled by LocationManager
// Time-alarm gating state
double _distanceTravelledMeters = 0.0;
int _etaSamples = 0;
bool _timeAlarmEligible = false;
// _lastAlarmFiredAt moved to AlarmController
// _alarmStopPollTimer moved to AlarmController

NotificationUpdater? _notificationUpdaterInstance;
NotificationUpdater get _notificationUpdater {
  final existing = _notificationUpdaterInstance;
  if (existing != null && existing.isTestMode == TrackingService.isTestMode) {
    return existing;
  }

  _notificationUpdaterInstance = NotificationUpdater(
    isTestMode: TrackingService.isTestMode,
    getLastRouteBroadcastAt: () => _lastRouteBroadcastAt,
    setLastRouteBroadcastAt: (v) => _lastRouteBroadcastAt = v,
  );
  return _notificationUpdaterInstance!;
}

void _broadcastSimulationState({
  bool alarmFired = false,
  double? remainingStops,
  Map<String, dynamic>? debugInfo,
}) {
  dev.log(
    'ETA_DEBUG trackingService broadcast: apiEta=$_apiEtaSeconds, smoothedETA=$_smoothedETA, '
    'distTravelled=$_distanceTravelledMeters, mode=$_alarmMode, val=$_alarmValue, '
    'progress=$_lastComputedProgressMeters, polyTotal=$_lastComputedPolylineTotalMeters',
    name: 'TrackingService',
  );
  _notificationUpdater.broadcastSimulationState(
    alarmFired: alarmFired,
    remainingStops: remainingStops,
    extraDebugInfo: debugInfo,
    context: BroadcastContext(
      apiEtaSeconds: _apiEtaSeconds,
      smoothedETA: _smoothedETA,
      distanceTravelledMeters: _distanceTravelledMeters,
      alarmMode: _alarmMode,
      alarmValue: _alarmValue,
      destinationAlarmFired: _alarmController.anyDestinationAlarmFired,
      lastAlarmFiredAt: _alarmController.lastAlarmFiredAt,
      destinationName: _destinationName,
      activeKey: _lastComputedActiveKey,
      snapOffsetMeters: _lastComputedOffsetMeters,
      progressMeters: _lastComputedProgressMeters,
      progressJumpMeters: _lastComputedProgressJumpMeters,
      nextEventType: _lastComputedNextEventType,
      toNextEventMeters: _lastComputedToNextEventMeters,
      polylineTotalMeters: _lastComputedPolylineTotalMeters,
      stepTotalMeters: _lastComputedStepTotalMeters,
      backstopPhysicsFireAt: _alarmController.backstopPhysicsFireAt,
    ),
  );
}

// --- NEW STATE VARIABLES FOR ALARM LOGIC ---
LatLng? _destination;
String? _destinationName;
String? _alarmMode;
double? _alarmValue;
Map<String, dynamic>?
_currentDirections; // Persist directions for snapshot restoration
double? _smoothedSpeed; // Smoothed speed from EtaEngine

// Central Session Manager - lazily initialized to respect isTestMode
RouteSessionManager? _sessionManagerInstance;
RouteSessionManager get _sessionManager {
  _sessionManagerInstance ??= RouteSessionManager(
    isTestMode: TrackingService.isTestMode,
    // Pass the singleton OfflineCoordinator so reroute logic can fetch new routes
    offlineCoordinator: OfflineCoordinator.instance,
  );
  return _sessionManagerInstance!;
}

// === MODULAR ALARM CONTROLLER (Phase 1 refactoring) ===
// AlarmController manages alarm state and evaluation.
// Currently running in parallel with legacy code for safe migration.
final AlarmController _alarmController = AlarmController();

// === TRACKING TERMINATION POLICY ===
// Smart termination using distance + time + behavior signals
final TrackingTerminationPolicy _terminationPolicy =
    TrackingTerminationPolicy();

// Reroute in-flight flag to prevent concurrent reroute attempts
bool _rerouteInFlight = false;

// Alarm state is keyed by route key - now managed solely by AlarmController
// (Legacy _destinationAlarmFiredByKey, _firedEventIndexesByKey removed)

// Route-derived alarm inputs, keyed by route key
// Route-derived alarm inputs (Delegated to SessionManager)
Map<String, List<RouteEventBoundary>> get _routeEventsByKey =>
    _sessionManager.routeEventsByKey;
Map<String, List<double>> get _stepBoundsMetersByKey =>
    _sessionManager.stepBoundsMetersByKey;
Map<String, List<double>> get _stepStopsCumulativeByKey =>
    _sessionManager.stepStopsCumulativeByKey;
Map<String, LatLng?> get _firstTransitBoardingByKey =>
    _sessionManager.firstTransitBoardingByKey;
Map<String, bool> get _transitModeByKey => _sessionManager.transitModeByKey;
Map<String, List<TransitLegStops>> get _transitLegStopsByKey =>
    _sessionManager.transitLegStopsByKey;

// Backward-compatible single-route fields (alarm state moved to AlarmController)
// _destinationAlarmFired and _firedEventIndexes now managed by AlarmController

List<RouteEventBoundary> _routeEvents = const [];
List<double> _stepBoundsMeters = const [];
List<int> _stepDurationsSeconds = const [];
// _stepStopsCumulative removed - delegated to _sessionManager.stepStopsCumulativeByKey
List<TransitLegStops> _transitLegStops = const [];

// Route management and deviation/reroute state
// Route management (Delegated to SessionManager)
RouteRegistry get _registry => _sessionManager.registry;
// Note: _offlineCoordinator is stored in _sessionManager but we also need to pass it in.
// Actually _offlineCoordinator WAS a nullable global here.
// _sessionManager will hold it. We can proxy it.
// However, _sessionManager.offlineCoordinator is final.
// We need to keep a local reference to initialize _sessionManager?
// No, we can init local _offlineCoordinator and pass to _sessionManager.
// But legacy code might set _offlineCoordinator?
// TrackingService only init it in _onStart.
// So getting it from _sessionManager is fine if _sessionManager holds the truth.

// Legacy StreamControllers (Pipes)
final _routeStateCtrl = StreamController<ActiveRouteState>.broadcast();
final _routeSwitchCtrl = StreamController<RouteSwitchEvent>.broadcast();
final _rerouteCtrl = StreamController<RerouteDecision>.broadcast();
// _locationCtrl was irrelevant to SessionManager, keep it?
final _locationCtrl = StreamController<Position>.broadcast();
final _etaCtrl = StreamController<double?>.broadcast();
SnapResult? _lastSnapResult;

// Subscriptions (Keep local to manage lifecycle in TrackingService if needed, or SessionManager handles its own?)
// TrackingService listened to these to trigger UI updates/Alarms.
// So we KEEP subscriptions to _sessionManager streams.
StreamSubscription<ActiveRouteState>? _mgrStateSub;
StreamSubscription<RouteSwitchEvent>? _mgrSwitchSub;
StreamSubscription<DeviationState>? _devSub;
StreamSubscription<RerouteDecision>? _rerouteSub;
StreamSubscription<DeviationState>? _devStateForTerminationSub;
// G14/G15: consumes wrong-direction alerts (opposite-direction train) and
// surfaces them to the rider via a high-importance heads-up notification.
StreamSubscription<WrongDirectionAlert>? _wrongDirSub;

// Manager Delegates (Mutable)
ActiveRouteManager? get _activeManager => _sessionManager.activeManager;
set _activeManager(ActiveRouteManager? v) => _sessionManager.activeManager = v;

DeviationMonitor? get _devMonitor => _sessionManager.devMonitor;
set _devMonitor(DeviationMonitor? v) => _sessionManager.devMonitor = v;

ReroutePolicy? get _reroutePolicy => _sessionManager.reroutePolicy;
set _reroutePolicy(ReroutePolicy? v) => _sessionManager.reroutePolicy = v;

OfflineCoordinator? get _offlineCoordinator =>
    _sessionManager.offlineCoordinator;
SoftLockManager get _softLockManager => _sessionManager.softLockManager;

// State Delegates (activeRouteInitialized accessed directly on _sessionManager)

bool get _transitMode => _sessionManager.transitMode;
set _transitMode(bool v) => _sessionManager.transitMode = v;

ActiveRouteState? get _lastActiveState => _sessionManager.lastActiveState;
set _lastActiveState(ActiveRouteState? v) =>
    _sessionManager.lastActiveState = v;

LatLng? get _firstTransitBoarding =>
    _sessionManager.firstTransitBoardingByKey[_sessionManager
            .activeManager
            ?.activeKey ??
        ''];
set _firstTransitBoarding(LatLng? v) {
  if (_sessionManager.activeManager?.activeKey != null) {
    _sessionManager.firstTransitBoardingByKey[_sessionManager
            .activeManager!
            .activeKey!] =
        v;
  }
}

// Payload Cache (Delegated)
Map<String, dynamic>? get _cachedRoutePayload =>
    _sessionManager.cachedRoutePayload;
set _cachedRoutePayload(Map<String, dynamic>? v) =>
    _sessionManager.cachedRoutePayload = v;

// _routePayloadsByKey accessed directly on _sessionManager when needed

DateTime? get _lastRouteBroadcastAt => _sessionManager.lastRouteBroadcastAt;
set _lastRouteBroadcastAt(DateTime? v) =>
    _sessionManager.lastRouteBroadcastAt = v;
// TrackingService used it check throttling. SessionManager handles throttling now.

void _maybeBroadcastCachedRoute({bool force = false}) {
  _notificationUpdater.maybeBroadcastCachedRoute(
    force: force,
    context: RouteContext(
      cachedPayload: _cachedRoutePayload,
      registry: _registry,
      activeKey: _activeManager?.activeKey,
      transitLegStops: _transitLegStops,
      transitMode: _transitMode,
    ),
  );
}

@pragma('vm:entry-point')
void _onStop() async {
  _isBackgroundIsolate = false;
  _trackingSessionActive = false;
  _heartbeatMonitor.stop();

  await _locationStreamHandler.stop();

  // Notify dashboard that tracking has ended
  try {
    LocationManager().broadcastState(
      alarmFired: false,
      active: false, // <-- Key change
      apiEtaSeconds: null,
      smoothedETA: null,
      distanceTravelledMeters: null,
      alarmMode: _alarmMode,
      alarmValue: _alarmValue,
      destinationAlarmFired: false,
      lastAlarmFiredAt: null,
    );
  } catch (e) {
    dev.log('broadcastState active:false failed: $e', name: 'TrackingService');
  }

  // Delegate location cleanup
  await LocationManager().stop();
  _positionSubscription?.cancel(); // We still hold the subscription
  _positionSubscription = null;

  // _simulationClient/injected vars removed

  _gpsCheckTimer?.cancel();
  _gpsCheckTimer = null;
  // Sensor Fusion cleanup should also be handled better, but keep here for now
  if (_sensorFusionManager != null) {
    _sensorFusionManager!.stopFusion();
    _sensorFusionManager!.dispose();
    _sensorFusionManager = null;
  }
  _fusionActive = false;

  // G1: release the session wake lock once tracking has fully stopped.
  // G5: also cancel any pending OS exact-alarm ETA backstop so it can't fire
  // after the session is intentionally stopped.
  if (!TrackingService.isTestMode) {
    // ignore: discarded_futures
    WakepointNative.releaseWakeLock();
    // ignore: discarded_futures
    NotificationService().cancelEtaBackstop();
  }
  _mgrStateSub?.cancel();
  _mgrStateSub = null;
  _mgrSwitchSub?.cancel();
  _mgrSwitchSub = null;
  _devSub?.cancel();
  _devSub = null;
  _rerouteSub?.cancel();
  _rerouteSub = null;
  _devStateForTerminationSub?.cancel();
  _devStateForTerminationSub = null;
  _wrongDirSub?.cancel();
  _wrongDirSub = null;
  _activeManager?.dispose();
  _activeManager = null;
  _devMonitor?.dispose();
  _devMonitor = null;
  _reroutePolicy?.dispose();
  _reroutePolicy = null;

  // Reset termination policy
  _terminationPolicy.reset();
  _rerouteInFlight = false;

  // Persist final ETA state
  await _etaEngine.saveState(force: true);

  // Reset per-session route/alarm state to avoid stale behavior on next run.
  try {
    _registry.clear();
  } catch (e) {
    trackingLog.debug('Registry clear failed', data: {'error': e.toString()});
  }
  _sessionManager.activeRouteInitialized = false;
  _lastActiveState = null;
  _routeEvents = const [];
  _stepBoundsMeters = const [];
  // _stepStopsCumulative reset handled by session manager
  _transitLegStops = const [];
  _firstTransitBoarding = null;

  _transitMode = false;
  _cachedRoutePayload = null;
  _lastRouteBroadcastAt = null;
  // Alarm state reset via AlarmController
  _alarmController.resetAlarmState();
  _routeEventsByKey.clear();
  _stepBoundsMetersByKey.clear();
  _stepStopsCumulativeByKey.clear();
  _transitLegStopsByKey.clear();
  _firstTransitBoardingByKey.clear();
  _transitModeByKey.clear();
  _destination = null;
  _destinationName = null;
  _alarmMode = null;
  _alarmValue = null;
  _lastEkfState = null;
  _lastEkfAlarmSnapshot = null;

  // Explicitly stop any playing alarm and vibration
  try {
    // Stop alarm sound
    await AlarmPlayer.stop();
    // Stop vibration
    NotificationService().stopVibration();

    // We'll rely on the NotificationService's cancelJourneyProgress() to handle
    // the progress notification, and the alarm notification should be handled
    // by AlarmPlayer.stop() and stopVibration()
  } catch (e) {
    dev.log(
      'Error stopping alarm during tracking stop: $e',
      name: 'TrackingService',
    );
  }

  // Cancel persistent progress notification
  try {
    if (!TrackingService.isTestMode) {
      await NotificationService().cancelJourneyProgress();
    }
  } catch (e) {
    trackingLog.debug(
      'cancelJourneyProgress on stop failed',
      data: {'error': e.toString()},
    );
  }
  dev.log("Tracking has been fully stopped.", name: "TrackingService");
}

/// Reset alarm state so alarms can fire again.
/// Called when dashboard progress slider is moved backwards,
/// or when a new route is registered.
void _resetAlarmState() {
  // Defensive gate: only accept reset requests if progress has moved backwards
  // by a meaningful amount (typical of a user dragging the progress slider).
  // This prevents spurious repeated alarms caused by small snapping jitter.
  const double minBacktrackMetersToReset = 150.0;
  final last = _lastActiveState;
  final key = last?.activeKey;
  final currentProgress = last?.progressMeters;
  if (key != null && currentProgress != null && currentProgress.isFinite) {
    final maxSeen = _maxProgressMetersSeenByKey[key];
    if (maxSeen != null && maxSeen.isFinite) {
      final backtrack = maxSeen - currentProgress;
      if (backtrack >= 0 && backtrack < minBacktrackMetersToReset) {
        dev.log(
          'DEBUG: _resetAlarmState ignored (minor backtrack ${backtrack.toStringAsFixed(1)}m < ${minBacktrackMetersToReset.toStringAsFixed(0)}m) for key=$key',
          name: 'TrackingService',
        );
        return;
      }
    }

    // If we accept the reset, treat the current progress as the new maximum.
    _maxProgressMetersSeenByKey[key] = currentProgress;
  }

  dev.log(
    'DEBUG: _resetAlarmState called - resetting alarm flags',
    name: 'TrackingService',
  );
  // Delegate entirely to AlarmController
  _alarmController.resetAlarmState();

  // Also stop any currently playing alarm
  AlarmPlayer.stop();
  NotificationService().stopVibration();
  dev.log('DEBUG: _resetAlarmState completed', name: 'TrackingService');
}

/// Handle route switch request from dashboard.
/// Called when user clicks "Revert to Previous Route" button.
void _handleDashboardRouteSwitch(String routeKey) {
  dev.log(
    'DEBUG: _handleDashboardRouteSwitch called for key: $routeKey',
    name: 'TrackingService',
  );

  final success = _sessionManager.switchToRoute(routeKey);
  if (success) {
    dev.log(
      'DEBUG: Successfully switched to route: $routeKey',
      name: 'TrackingService',
    );
    // Reset alarm state since we're on a different route now
    _resetAlarmState();
  } else {
    dev.log(
      'DEBUG: Failed to switch to route: $routeKey',
      name: 'TrackingService',
    );
  }
}

/// Helper to trigger alarm notification - handles background isolate case
/// where NotificationService can't show notifications directly due to
/// null Android Context. In that case, we send a request to the foreground.
// --- NEW FUNCTION: Contains the core alarm logic ---

_ResolvedAlarmRouteState _resolveAlarmRouteState(
  Position currentPosition, {
  bool deadReckoned = false,
}) {
  // Use latest progressMeters snapshot for stops/time event calculations.
  double? progressMeters;
  String? activeKey;

  try {
    progressMeters = _lastActiveState?.progressMeters;
    RouteEntry? active;
    if (_lastActiveState?.activeKey != null && _registry.entries.isNotEmpty) {
      try {
        active = _registry.entries.firstWhere(
          (e) => e.key == _lastActiveState!.activeKey,
          orElse: () => _registry.entries.first,
        );
      } catch (e) {
        trackingLog.debug(
          'Active route lookup failed',
          data: {'error': e.toString()},
        );
      }
    }
    active ??= _registry.entries.isNotEmpty ? _registry.entries.first : null;

    activeKey = _lastActiveState?.activeKey ?? active?.key;

    // G10: In a GPS blackout the evaluation is dead-reckoned. Do NOT snap the
    // stale last-known position — that would freeze registry/max-progress state
    // and pollute soft-lock with a non-moving fix. Take arc-progress straight
    // from the EKF and skip the snap/session-mutation entirely.
    final drEkf = _lastEkfState;
    if (deadReckoned && drEkf != null && drEkf.s.isFinite) {
      progressMeters = drEkf.s;
    } else if (active != null && _lastProcessedPosition != null) {
      print(
        'SNAP_DEBUG: Snapping to route ${active.key}, pos=$_lastProcessedPosition',
      );
      final snap = SnapToRouteEngine.snap(
        point: _lastProcessedPosition!,
        polyline: active.points,
        // Provide hint index from active route, OR use previous snap directly
        // The engine now handles history via previousResult
        previousResult: _lastSnapResult,
        // Also provide heading for alignment check (if moving)
        heading: currentPosition.speed > 0.5 ? currentPosition.heading : null,
        precomputedCumMeters: active.cumMeters,
      );

      _lastSnapResult = snap;

      final progress = snap.progressMeters;
      print(
        'SNAP_DEBUG: Snapped! progress=$progress, segIdx=${snap.segmentIndex}',
      );
      progressMeters = progress;
      _registry.updateSessionState(
        active.key,
        lastSnapIndex: snap.segmentIndex,
        lastProgressMeters: snap.progressMeters,
      );

      // Track maximum progress seen per route key (used to gate alarm-reset).
      final key = activeKey;
      if (key != null && progress.isFinite) {
        final prevMax = _maxProgressMetersSeenByKey[key];
        if (prevMax == null || !prevMax.isFinite || progress > prevMax) {
          _maxProgressMetersSeenByKey[key] = progress;
        }
      }
      // --- Soft Lock / Deviation Check (Bus Reality) ---
      // We perform this check for non-metro legs (Bus/Walk) where "Bus Reality" corridor logic applies.
      // Metro legs use "Ground Truth" GPS speed logic and effectively ignore position deviation (tunnels).

      // 1. Determine if current progress is on a Metro leg
      bool isMetroStep = false;
      // Resolve legs for this route
      final List<TransitLegStops> legsToCheck =
          (activeKey != null && _transitLegStopsByKey.containsKey(activeKey))
              ? (_transitLegStopsByKey[activeKey] ?? const [])
              : _transitLegStops;

      if (legsToCheck.isNotEmpty) {
        for (final leg in legsToCheck) {
          if (snap.progressMeters >= leg.legStartMeters &&
              snap.progressMeters <= leg.legEndMeters) {
            if (leg.isMetro) isMetroStep = true;
            break;
          }
        }
      }

      // 2. Perform Soft Lock if NOT Metro
      if (!isMetroStep) {
        final userLat = _lastProcessedPosition!.latitude;
        final userLng = _lastProcessedPosition!.longitude;

        // Calculate lateral offset manually to be safe
        final latOffset = Geolocator.distanceBetween(
          userLat,
          userLng,
          snap.snappedPoint.latitude,
          snap.snappedPoint.longitude,
        );

        final isLocked = _softLockManager.checkSoftLock(
          userLocation: LatLng(userLat, userLng),
          accuracy: currentPosition.accuracy,
          routePoints: active.points,
          closestSegmentIndex: snap.segmentIndex,
          projectedPoint: snap.snappedPoint,
          lateralOffsetMeters: latOffset,
        );

        if (!isLocked) {
          trackingLog.warn(
            'SoftLock Deviation Detected on non-metro leg',
            data: {'offset': latOffset, 'metro': isMetroStep},
          );
          // TODO: Trigger actual reroute if DeviationMonitor doesn't pick this up
          // For now, we rely on the log appearing in verification.
        }
      }
      // -------------------------------------------------

      // Prefer EKF progress for metro legs or when EKF is degraded.
      final ekfState = _lastEkfState;
      final useEkfForAlarmProgress =
          ekfState != null &&
          ekfState.s.isFinite &&
          (isMetroStep ||
              ekfState.mode == EkfMode.degraded ||
              ekfState.mode == EkfMode.metro);
      if (useEkfForAlarmProgress) {
        progressMeters = ekfState.s;
      }
    } else {
      // Fallback to latest cached registry progress
      RouteEntry? best;
      for (final e in _registry.entries) {
        if (e.lastProgressMeters != null) {
          if (best == null || e.lastUsed.isAfter(best.lastUsed)) {
            best = e;
          }
        }
      }
      final registryProgress = best?.lastProgressMeters;
      if (registryProgress != null) {
        if (progressMeters == null ||
            registryProgress > progressMeters + 1e-3) {
          progressMeters = registryProgress;
        }
      }
    }
  } catch (_) {}

  return _ResolvedAlarmRouteState(
    progressMeters: progressMeters,
    activeKey: activeKey,
  );
}

@pragma('vm:entry-point')
Future<void> _checkAndTriggerAlarm(
  Position currentPosition,
  ServiceInstance service,
) async {
  dev.log(
    'DEBUG: _checkAndTriggerAlarm called with pos=(${currentPosition.latitude.toStringAsFixed(5)}, ${currentPosition.longitude.toStringAsFixed(5)})',
    name: 'TrackingService',
  );
  dev.log(
    'DEBUG: _checkAndTriggerAlarm state: _alarmMode=$_alarmMode, _destination=$_destination, _alarmValue=$_alarmValue',
    name: 'TrackingService',
  );
  if (!_trackingSessionActive) {
    dev.log(
      'DEBUG: _checkAndTriggerAlarm early return - no active tracking session',
      name: 'TrackingService',
    );
    return;
  }
  if (_destination == null || _alarmValue == null) {
    dev.log(
      'DEBUG: _checkAndTriggerAlarm early return - destination=$_destination, alarmValue=$_alarmValue',
      name: 'TrackingService',
    );
    return;
  }

  // G10: A synthesized dead-reckoned evaluation (GPS blackout) carries a
  // sentinel accuracy and EKF velocity. It must NOT be treated as a real fix:
  // do not overwrite the last good position, and do not feed it to snap /
  // deviation / session ingestion. It is used only to pull EKF arc-progress.
  final bool isDeadReckoned =
      !currentPosition.accuracy.isFinite ||
      currentPosition.accuracy >= 9000.0;

  if (!isDeadReckoned) {
    // Keep a fresh snapshot of position/speed for snapping and deviation logic
    _lastProcessedPosition = LatLng(
      currentPosition.latitude,
      currentPosition.longitude,
    );
    _lastSpeedMps = currentPosition.speed;

    // Ingest position into RouteSessionManager to drive ActiveRouteManager and DeviationMonitor
    _sessionManager.ingestPosition(currentPosition);
  }

  // Resolve active route/progress for route-aware alarms.
  _lastEkfAlarmSnapshot = _lastEkfState;
  final resolved = _resolveAlarmRouteState(
    currentPosition,
    deadReckoned: isDeadReckoned,
  );
  final double? progressMeters = resolved.progressMeters;
  final String? alarmKey = resolved.activeKey;

  final context = AlarmContextBuilder.build(
    registry: _registry,
    destination: _destination,
    alarmMode: _alarmMode,
    alarmValue: _alarmValue,
    trackingSessionActive: _trackingSessionActive,
    isBackgroundIsolate: _isBackgroundIsolate,
    isTestMode: TrackingService.isTestMode,
    alarmKey: alarmKey,
    progressMeters: progressMeters,
    lastSnapResult: _lastSnapResult,
    routeEventsByKey: _sessionManager.routeEventsByKey,
    fallbackRouteEvents:
        _sessionManager.routeEventsByKey.values.firstOrNull ?? _routeEvents,
    transitLegStopsByKey: _sessionManager.transitLegStopsByKey,
    fallbackTransitLegStops:
        _sessionManager.transitLegStopsByKey.values.firstOrNull ??
        _transitLegStops,
    stepBoundsMetersByKey: _sessionManager.stepBoundsMetersByKey,
    fallbackStepBoundsMeters:
        _sessionManager.stepBoundsMetersByKey.values.firstOrNull ??
        _stepBoundsMeters,
    stepStopsCumulativeByKey: _sessionManager.stepStopsCumulativeByKey,
    fallbackStepStopsCumulative:
        _sessionManager.stepStopsCumulativeByKey.values.firstOrNull ?? const [],
    stepDurationsSecondsByKey: _sessionManager.stepDurationsSecondsByKey,
    fallbackStepDurationsSeconds: _stepDurationsSeconds,
    smoothedSpeed: _smoothedSpeed,
    smoothedETA: _smoothedETA,
    lastSpeedMps: _lastSpeedMps,
    timeAlarmEligible: _timeAlarmEligible,
    etaSamples: _etaSamples,
    distanceTravelledMeters: _distanceTravelledMeters,
    // G11/G12/G13: feed the EKF snapshot used for THIS evaluation.
    ekfSpeedMps: _lastEkfAlarmSnapshot?.v,
    ekfSigmaS: _lastEkfAlarmSnapshot?.sigmaS,
    ekfSigmaV: _lastEkfAlarmSnapshot?.sigmaV,
    preferEkfSpeed: (_lastEkfAlarmSnapshot != null) &&
        (isDeadReckoned ||
            _lastEkfAlarmSnapshot!.mode == EkfMode.metro ||
            _lastEkfAlarmSnapshot!.mode == EkfMode.degraded),
  );

  await _alarmController.checkAndTriggerAlarm(
    currentPosition: currentPosition,
    service: service,
    context: context,
    onAlarmFired: () {
      _alarmController.markAlarmFired();
      _broadcastSimulationState(alarmFired: true);
    },
  );
}

/// Handles reroute decision from deviation monitor.
///
/// This is the CRITICAL missing piece that was previously just forwarding
/// the event without actually doing anything. This method:
/// 1. Fetches new directions from user's current position to destination
/// 2. Validates the new route respects original alarm constraints
/// 3. Registers the new route if valid
/// 4. Terminates tracking gracefully if no valid route exists
@pragma('vm:entry-point')
Future<void> _handleRerouteDecision(RerouteDecision decision) async {
  if (!decision.shouldReroute) {
    return;
  }

  // CORRECTNESS: once the destination wake alarm has fired, the trip is over —
  // a deviation-triggered reroute here only produces a spurious post-arrival
  // alarm / resurrects a finished session. Keep the deviate→reroute pipeline
  // quiescent after arrival.
  if (_alarmController.anyDestinationAlarmFired) {
    dev.log('Reroute suppressed: destination alarm already fired',
        name: 'TrackingService');
    return;
  }

  if (_rerouteInFlight) {
    dev.log('Reroute already in flight, skipping', name: 'TrackingService');
    return;
  }

  if (_destination == null || _alarmMode == null || _alarmValue == null) {
    dev.log(
      'Cannot reroute: missing destination or alarm settings',
      name: 'TrackingService',
    );
    return;
  }

  final currentPosition = _lastProcessedPosition;
  if (currentPosition == null) {
    dev.log('Cannot reroute: no current position', name: 'TrackingService');
    _terminationPolicy.onRerouteFailed();
    return;
  }

  _rerouteInFlight = true;
  dev.log(
    'REROUTE: Starting reroute from ${currentPosition.latitude.toStringAsFixed(5)}, ${currentPosition.longitude.toStringAsFixed(5)}',
    name: 'TrackingService',
  );

  try {
    // Check termination policy first (unless in simulation mode)
    dev.log(
      'REROUTE: Checking termination. SimMode=${TrackingService().isSimulationMode}',
      name: 'TrackingService',
    );
    if (!TrackingService().isSimulationMode) {
      final terminationDecision = _terminationPolicy.shouldTerminate(
        currentPosition: currentPosition,
        speedMps: _lastSpeedMps ?? 0,
      );

      if (terminationDecision.shouldTerminate) {
        dev.log(
          'REROUTE: Termination policy triggered: ${terminationDecision.reason}',
          name: 'TrackingService',
        );
        await _terminateTrackingWithMessage(
          terminationDecision.userMessage ??
              'Tracking ended due to extended deviation',
        );
        return;
      }
    }

    // Fetch new directions
    final offlineCoord = _offlineCoordinator;
    if (offlineCoord == null || offlineCoord.isOffline) {
      dev.log(
        'REROUTE: Cannot fetch new route - offline or no coordinator',
        name: 'TrackingService',
      );
      _terminationPolicy.onRerouteFailed();
      return;
    }

    final newDirections = await offlineCoord.getRoute(
      origin: currentPosition,
      destination: _destination!,
      isDistanceMode: _alarmMode != 'time',
      threshold: _alarmValue!,
      transitMode: _transitMode,
      preferMetroEvenIfClosed: _transitMode,
      forceRefresh: true, // Always get fresh route for reroute
    );

    // CORRECTNESS: the route fetch above can take several seconds; the user may
    // have ended tracking (or the alarm fired) in the meantime. Bail before
    // registering the new route so a late reroute can't resurrect a stopped
    // session via the managers' lazy `??=` init.
    if (!_trackingSessionActive || _alarmController.anyDestinationAlarmFired) {
      dev.log('Reroute aborted: session ended/alarm fired during route fetch',
          name: 'TrackingService');
      return;
    }

    // Validate constraints
    final constraints = RerouteConstraints(
      alarmMode: _alarmMode!,
      alarmValue: _alarmValue!,
      transitMode: _transitMode,
    );

    final validation = constraints.validate(newDirections.directions);

    if (!validation.isValid) {
      dev.log(
        'REROUTE: Constraint validation failed: ${validation.failureReason}',
        name: 'TrackingService',
      );
      _terminationPolicy.onRerouteFailed();

      // If too many failures, terminate
      if (_terminationPolicy.failedRerouteAttempts >= 3) {
        await _terminateTrackingWithMessage(
          validation.userMessage ??
              'Tracking ended: No valid alternate route found',
        );
      } else {
        // Show notification about failed reroute but continue
        if (!TrackingService.isTestMode) {
          await NotificationService().showJourneyProgress(
            title: 'Route deviation detected',
            subtitle:
                'Unable to find valid alternate route (attempt ${_terminationPolicy.failedRerouteAttempts}/3)',
            progress0to1: 0,
            isTracking: true,
          );
        }
      }
      return;
    }

    // Success! Register the new route
    dev.log(
      'REROUTE: Constraint validation passed, registering new route',
      name: 'TrackingService',
    );

    await TrackingService().registerRouteFromDirections(
      directions: newDirections.directions,
      origin: currentPosition,
      destination: _destination!,
      transitMode: _transitMode,
      destinationName: _destinationName,
      activateRoute: true,
    );

    // Update termination policy
    _terminationPolicy.onRerouteSuccess();

    // Update notification
    if (!TrackingService.isTestMode) {
      await NotificationService().showJourneyProgress(
        title:
            _destinationName != null
                ? 'Journey to $_destinationName'
                : 'GeoWake journey',
        subtitle: 'Route updated',
        progress0to1: 0,
        isTracking: true,
      );
    }

    dev.log(
      'REROUTE: Successfully registered new route',
      name: 'TrackingService',
    );
  } catch (e) {
    dev.log('REROUTE: Error during reroute: $e', name: 'TrackingService');
    _terminationPolicy.onRerouteFailed();

    // Check if we should terminate after this failure
    if (_terminationPolicy.failedRerouteAttempts >= 3) {
      await _terminateTrackingWithMessage(
        'Tracking ended: Unable to find alternate route after multiple attempts',
      );
    }
  } finally {
    _rerouteInFlight = false;
  }
}

/// Gracefully terminates tracking with a user message.
Future<void> _terminateTrackingWithMessage(String message) async {
  dev.log('TERMINATION: $message', name: 'TrackingService');

  try {
    if (!TrackingService.isTestMode) {
      // Show termination notification
      await NotificationService().showWakeUpAlarm(
        title: 'Tracking Ended',
        body: message,
        allowContinueTracking: false,
      );
    }

    // Stop tracking
    await TrackingService().stopTracking();
  } catch (e) {
    dev.log('Error during termination: $e', name: 'TrackingService');
  }
}

@visibleForTesting
Future<void> triggerOnStartForRecoveryTest(ServiceInstance service) async =>
    _onStart(service, initialData: null);

void _handleBackgroundStartTracking({
  required LatLng destination,
  required String destinationName,
  required String alarmMode,
  required double alarmValue,
  required bool transitMode,
  required ServiceInstance service,
}) {
  dev.log(
    'DEBUG: Background received startTracking event: dest=$destinationName mode=$alarmMode value=$alarmValue transit=$transitMode',
    name: 'TrackingService',
  );

  dev.log(
    'DEBUG: startTracking received - resetting alarm state',
    name: 'TrackingService',
  );
  dev.log(
    'DEBUG: Previous alarm state: anyFired=${_alarmController.anyDestinationAlarmFired}',
    name: 'TrackingService',
  );

  // Reset stale state from any prior session (important for subsequent runs).
  try {
    _registry.clear();
  } catch (_) {}
  _etaEngine.reset();
  // Critical: clear any cached smoothed speed/ETA so the first alarm check
  // cannot use a stale (persisted) speed estimate.
  _locationStreamHandler.reset();
  _smoothedSpeed = null;
  _sessionManager.activeRouteInitialized = false;
  _routeEvents = const [];
  _stepBoundsMeters = const [];
  // _stepStopsCumulative reset handled by session manager
  _firstTransitBoarding = null;

  _transitMode = transitMode;
  _cachedRoutePayload = null;
  _lastRouteBroadcastAt = null;
  _alarmController.resetAlarmState();
  _lastEkfState = null;
  _lastEkfAlarmSnapshot = null;
  dev.log(
    'DEBUG: After reset anyDestinationAlarmFired=${_alarmController.anyDestinationAlarmFired}',
    name: 'TrackingService',
  );

  _destination = destination;
  _destinationName = destinationName;
  _alarmMode = alarmMode;
  _alarmValue = alarmValue;
  _trackingSessionActive = true;

  // GAP #1/#2 (BLOCK): seed the reachability anchor at ARM time. The route is
  // computed FROM the rider's current location, so route arc-progress 0 IS the
  // rider's position at arm — a known real position. Seeding s=0 at arm time
  // (rather than waiting for the first tick / first GPS fix) gives the physics
  // never-late net an honest wall clock from t0, so a rider who boards and goes
  // underground immediately — never getting a single fix — is still woken before
  // their stop by the cold-start reachability backstop. A later real GPS fix
  // re-anchors via onAcceptedFix; this seed is idempotent.
  _alarmController.seedReachabilityAnchorAtArm(sMeters: 0.0);

  // GAP #8: telemetry funnel denominator — record every armed trip (mode/value),
  // so field outcomes can be measured per device·OEM·SDK. Fail-open.
  try {
    TelemetryService.instance.alarmArmed(
      mode: alarmMode,
      value: alarmValue,
      line: _transitLegStops.isNotEmpty ? _transitLegStops.first.lineName : null,
      city: _transitLegStops.isNotEmpty
          ? _transitLegStops.first.cityKey
          : null,
    );
  } catch (_) {/* telemetry must never break arming */}

  // Initialize termination policy with destination
  _terminationPolicy.reset();
  _terminationPolicy.setDestination(destination);

  // Bridge RouteSessionManager streams to TrackingService controllers
  // This is critical for test mode where foreground listeners are skipped
  _mgrStateSub?.cancel();
  _mgrStateSub = _sessionManager.routeStateStream.listen((s) {
    _routeStateCtrl.add(s);
  });
  _mgrSwitchSub?.cancel();
  _mgrSwitchSub = _sessionManager.routeSwitchStream.listen((e) {
    // Critical: Migrate alarm history to new key so we don't re-fire alarms
    _alarmController.migrateAlarmState(e.fromKey, e.toKey);
    _locationStreamHandler.updateRouteGeometryForKey(e.toKey);
    _routeSwitchCtrl.add(e);
  });
  _rerouteSub?.cancel();
  _rerouteSub = _sessionManager.rerouteStream.listen((d) async {
    _rerouteCtrl.add(d);
    // CRITICAL: Actually handle the reroute decision
    await _handleRerouteDecision(d);
  });

  // Listen to deviation state for termination policy
  _devStateForTerminationSub?.cancel();
  _devStateForTerminationSub = _sessionManager.deviationStateStream.listen((
    ds,
  ) {
    if (ds.offroute && !_terminationPolicy.isDeviating) {
      // Deviation started
      _terminationPolicy.onDeviationStart(
        position: _lastProcessedPosition ?? const LatLng(0, 0),
        at: ds.at,
      );
    } else if (!ds.offroute && _terminationPolicy.isDeviating) {
      // Returned to route
      _terminationPolicy.onReturnToRoute();
    }
  });

  // G14/G15: consume wrong-direction alerts and warn the (possibly asleep)
  // rider they may be heading away from their stop. NotificationService
  // throttles so a sustained episode does not spam banners.
  _wrongDirSub?.cancel();
  _wrongDirSub = _sessionManager.wrongDirectionStream.listen((_) {
    // ignore: discarded_futures
    NotificationService().showWrongDirectionAlert(
      destinationName: _destinationName,
    );
  });

  // Persist session-active flag for restore flows.
  try {
    TrackingStateStore.setActive(true);
    TrackingStateStore.setPaused(false);
    TrackingStateStore.setAlarmFired(false);
  } catch (e) {
    trackingLog.warn(
      'Failed to persist session flags',
      data: {'error': e.toString()},
    );
  }

  // Ensure stop/time/event alarms have route context even if the
  // foreground->background route registration invoke is dropped.
  // HomeScreen persists directions into TrackingStateStore; restore from it here.
  unawaited(() async {
    await SnapshotRouteRestorer.restoreFromStoreIfActiveAndNotPaused(
      isActive: TrackingStateStore.isActive,
      isPaused: TrackingStateStore.isPaused,
      loadSnapshot: TrackingStateStore.loadSnapshot,
      registerRouteFromDirections: ({
        required directions,
        required origin,
        required destination,
        required transitMode,
        destinationName,
      }) {
        return TrackingService().registerRouteFromDirections(
          directions: directions,
          origin: origin,
          destination: destination,
          transitMode: transitMode,
          destinationName: destinationName,
          activateRoute: true, // Ensure route is activated on restore
        );
      },
    );
  }());

  _alarmController.resetAlarmState();
  _lastActiveState = null;
  _lastProcessedPosition = null;
  _distanceTravelledMeters = 0.0;
  _etaSamples = 0;
  _timeAlarmEligible = false;

  _smoothedETA = null;
  _smoothedSpeed = null;
  _locationStreamHandler.reset();
  if (_transitMode && _firstTransitBoarding == null) {
    try {
      final ev = _routeEvents.firstWhere(
        (e) => e.type == 'boarding' || e.type == 'transfer',
      );
      if (ev.lat != null && ev.lng != null) {
        _firstTransitBoarding = LatLng(ev.lat!, ev.lng!);
      }
    } catch (_) {}
    if (_firstTransitBoarding == null && _registry.entries.isNotEmpty) {
      final pts = _registry.entries.first.points;
      if (pts.length > 1) {
        _firstTransitBoarding = pts[1];
      }
    }
  }

  dev.log(
    "Tracking started with params: Dest='$_destinationName', Mode='$_alarmMode', Value='$_alarmValue'",
    name: "TrackingService",
  );

  // Show initial journey notification immediately
  try {
    if (!TrackingService.isTestMode) {
      NotificationService().showJourneyProgress(
        title:
            _destinationName != null
                ? 'Journey to $_destinationName'
                : 'GeoWake journey',
        subtitle: 'Starting�',
        progress0to1: 0.0,
        isTracking: true,
      );
    }
  } catch (_) {}

  // Start location stream (delegated to LocationManager)
  dev.log(
    'Starting TrackingService location stream via LocationManager',
    name: 'TrackingService',
  );
  startLocationStream(service);
}

Future<void> _handleBackgroundStopAlarm() async {
  dev.log(
    'Received stopAlarm event in background service',
    name: 'TrackingService',
  );
  // Process alarm cancellation FIRST, then cancel poll timer only on success.
  try {
    await NotificationService().cancelAlarm();
    await NotificationService().restoreJourneyProgressIfActive();
    _alarmController.cancelAlarmStopPollTimer();
  } catch (e) {
    dev.log('Error stopping alarm: $e', name: 'TrackingService');
  }
}

void _handleBackgroundRegisterRoute({
  required String key,
  required String mode,
  required String destinationName,
  required List<LatLng> points,
  List<Map<String, dynamic>>? segments,
  List<Map<String, dynamic>>? switchPoints,
  List<Map<String, dynamic>>? events,
  List<Map<String, dynamic>>? transitLegs, // New Param
}) {
  dev.log(
    'CRITICAL: Background: Received registerRoute for $key',
    name: 'TrackingService',
  );
  dev.log(
    'CRITICAL: Background: Segments: ${segments?.length}, Legs: ${transitLegs?.length}',
    name: 'TrackingService',
  );

  TrackingService().registerRoute(
    key: key,
    mode: mode,
    destinationName: destinationName,
    points: points,
    segments: segments,
    switchPoints: switchPoints,
    events: events,
    transitLegsJson: transitLegs, // Pass it as JSON
    activate: true, // Critical: Activate new route to trigger alarm migration
  );
}

Future<void> _handleBackgroundRegisterRouteDirections({
  required Map<String, dynamic> directions,
  required LatLng origin,
  required LatLng destination,
  required bool transitMode,
  String? destinationName,
}) async {
  await TrackingService().registerRouteFromDirections(
    directions: directions,
    origin: origin,
    destination: destination,
    transitMode: transitMode,
    destinationName: destinationName,
  );
}

Future<void> _handleBackgroundForegroundResumed(ServiceInstance service) async {
  dev.log(
    'DEBUG: Foreground resumed notification received',
    name: 'TrackingService',
  );
  _heartbeatMonitor.recordHeartbeat();
  _heartbeatMonitor.ensureStarted();

  try {
    final isPaused = await TrackingStateStore.isPaused();
    if (!isPaused) return;

    dev.log('DEBUG: Resuming from paused state', name: 'TrackingService');
    await TrackingStateStore.setPaused(false);
    await NotificationService().cancelTrackingPaused();

    final snapshot = await TrackingStateStore.loadSnapshot();
    if (snapshot != null) {
      await NotificationService().showJourneyProgress(
        title: 'Journey to ${snapshot.destinationName}',
        subtitle: 'Tracking resumed',
        progress0to1: 0,
        isTracking: true,
      );
    }
  } catch (e) {
    dev.log(
      'DEBUG: Error handling foreground resumed: $e',
      name: 'TrackingService',
    );
  }
}

@pragma('vm:entry-point')
Future<void> _onStart(
  ServiceInstance service, {
  Map<String, dynamic>? initialData,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  _isBackgroundIsolate = true;

  // Bridge RouteSessionManager streams to TrackingService controllers
  // This must be set up unconditionally to work in test mode
  _mgrStateSub?.cancel();
  _mgrStateSub = _sessionManager.routeStateStream.listen((s) {
    _routeStateCtrl.add(s);
  });
  _mgrSwitchSub?.cancel();
  _mgrSwitchSub = _sessionManager.routeSwitchStream.listen((e) {
    // Critical: Migrate alarm history to new key so we don't re-fire alarms
    _alarmController.migrateAlarmState(e.fromKey, e.toKey);
    _routeSwitchCtrl.add(e);
  });
  _rerouteSub?.cancel();
  _rerouteSub = _sessionManager.rerouteStream.listen((d) async {
    _rerouteCtrl.add(d);
    // CRITICAL: Actually handle the reroute decision
    await _handleRerouteDecision(d);
  });

  // Listen to deviation state for termination policy
  _devStateForTerminationSub?.cancel();
  _devStateForTerminationSub = _sessionManager.deviationStateStream.listen((
    ds,
  ) {
    if (ds.offroute && !_terminationPolicy.isDeviating) {
      // Deviation started
      _terminationPolicy.onDeviationStart(
        position: _lastProcessedPosition ?? const LatLng(0, 0),
        at: ds.at,
      );
    } else if (!ds.offroute && _terminationPolicy.isDeviating) {
      // Returned to route
      _terminationPolicy.onReturnToRoute();
    }
  });

  // G14/G15: consume wrong-direction alerts and warn the (possibly asleep)
  // rider they may be heading away from their stop. NotificationService
  // throttles so a sustained episode does not spam banners.
  _wrongDirSub?.cancel();
  _wrongDirSub = _sessionManager.wrongDirectionStream.listen((_) {
    // ignore: discarded_futures
    NotificationService().showWrongDirectionAlert(
      destinationName: _destinationName,
    );
  });

  // Initialize ETA engine
  await _etaEngine.loadState();
  dev.log('DEBUG: Background isolate _onStart called', name: 'TrackingService');

  // Initialize NotificationService for the background isolate
  // This is critical - the notification plugin needs to be initialized
  // in each isolate that uses it, otherwise the Android Context is null
  try {
    dev.log(
      'DEBUG: Initializing NotificationService in background isolate...',
      name: 'TrackingService',
    );
    if (!TrackingService.isTestMode) {
      await NotificationService().initialize();
      dev.log(
        'DEBUG: NotificationService initialized successfully in background',
        name: 'TrackingService',
      );
    } else {
      dev.log(
        'DEBUG: Skipping NotificationService init in test mode',
        name: 'TrackingService',
      );
    }
  } catch (e) {
    dev.log(
      'DEBUG: NotificationService init failed in background: $e',
      name: 'TrackingService',
    );
    dev.log(
      'NotificationService init failed in background isolate: $e',
      name: 'TrackingService',
    );
  }

  // --- REGISTER LISTENERS FIRST TO AVOID RACE CONDITIONS ---

  BackgroundHandlers(
    service: service,
    callbacks: BackgroundHandlerCallbacks(
      onStartTracking: ({
        required LatLng destination,
        required String destinationName,
        required String alarmMode,
        required double alarmValue,
        required bool transitMode,
        bool isSimulationMode = false,
        required ServiceInstance service,
      }) async {
        if (isSimulationMode) {
          TrackingService()._isSimulationMode = true;
          dev.log(
            'Simulation mode enabled via onStartTracking params',
            name: 'TrackingService',
          );
        } else {
          TrackingService()._isSimulationMode = false;
        }

        _handleBackgroundStartTracking(
          destination: destination,
          destinationName: destinationName,
          alarmMode: alarmMode,
          alarmValue: alarmValue,
          transitMode: transitMode,
          service: service,
        );
      },
      onStopTracking: ({bool stopSelf = true}) async {
        _onStop();
      },
      onRegisterRoute: ({
        required String key,
        required String mode,
        required String destinationName,
        required List<LatLng> points,
        List<Map<String, dynamic>>? segments,
        List<Map<String, dynamic>>? switchPoints,
        List<Map<String, dynamic>>? events,
        List<Map<String, dynamic>>? transitLegs, // New Param
      }) {
        _handleBackgroundRegisterRoute(
          key: key,
          mode: mode,
          destinationName: destinationName,
          points: points,
          segments: segments,
          switchPoints: switchPoints,
          events: events,
          transitLegs: transitLegs, // Pass it
        );
      },
      onRegisterRouteDirections: ({
        required Map<String, dynamic> directions,
        required LatLng origin,
        required LatLng destination,
        required bool transitMode,
        String? destinationName,
      }) async {
        await _handleBackgroundRegisterRouteDirections(
          directions: directions,
          origin: origin,
          destination: destination,
          transitMode: transitMode,
          destinationName: destinationName,
        );
      },
      onStopAlarm: () async {
        await _handleBackgroundStopAlarm();
      },
      onForegroundHeartbeat: () {
        _heartbeatMonitor.recordHeartbeat();
        dev.log(
          'DEBUG: Received foreground heartbeat',
          name: 'TrackingService',
        );
      },
      onForegroundResumed: () async {
        await _handleBackgroundForegroundResumed(service);
      },
      onSetSimulationMode: (bool enabled) {
        TrackingService()._isSimulationMode = enabled;
        dev.log(
          'DEBUG: Background received setSimulationMode: $enabled',
          name: 'TrackingService',
        );
      },
    ),
  ).registerAll();

  // --- INITIALIZATION AFTER LISTENERS ARE SET ---

  try {
    await NotificationService().initialize();
  } catch (e) {
    trackingLog.warn(
      'NotificationService.initialize() failed in background',
      data: {'error': e.toString()},
    );
  }

  // Set up alarm reset callback
  LocationManager().onAlarmReset = _resetAlarmState;

  // Set up route switch callback from dashboard
  LocationManager().onSwitchRoute = _handleDashboardRouteSwitch;

  // Handle data passed directly (for test mode)
  if (initialData != null) {
    _destination = LatLng(
      initialData['destinationLat'],
      initialData['destinationLng'],
    );
    // In test mode or direct-start flows, treat the session as active so
    // alarm evaluation is not gated off before any positions are processed.
    _trackingSessionActive = true;
    _destinationName = initialData['destinationName'];
    _alarmMode = initialData['alarmMode'];
    _alarmValue = (initialData['alarmValue'] as num).toDouble();

    // Injection handled by LocationManager's start() implicitly or via methods
    try {
      if (initialData['useInjectedPositions'] == true) {
        // LocationManager handles this internally if configured,
        // but technically we trigger it via startLocationStream(simulate:true) or similar?
        // Current implementation of startLocationStream just calls LocationManager().start().
        // If we need explicit injection mode, we might need to expose it.
        // However, LocationManager switches automatically on first injected position.
        // So we just need to insure injection happens.
        // The caller (test) will call injectPosition.
      }
    } catch (e) {
      trackingLog.debug(
        'Initial data injection setup failed',
        data: {'error': e.toString()},
      );
    }

    _alarmController.resetAlarmState(); // Reset modular alarm state
    // Reset time-alarm gating state
    _distanceTravelledMeters = 0.0;
    _etaSamples = 0;
    _timeAlarmEligible = false;
    _smoothedSpeed = null;
    _locationStreamHandler.reset();

    startLocationStream(service);
    // Start fast polling for notification action buttons (Stop Alarm, Ignore, End Tracking)
    _alarmController.startAlarmStopPollTimer(
      trackingSessionActive: () => _trackingSessionActive,
    );
  } else {
    // RECOVERY FLOW: Service restarted by OS (process death)
    dev.log(
      'DEBUG: _onStart with null initialData - checking for snapshot',
      name: 'TrackingService',
    );
    try {
      final isActive = await TrackingStateStore.isActive();
      if (isActive) {
        // BACKLOG #14: emit reliability telemetry — the FGS was restarted by the
        // OS after a kill. If wasCleanShutdown is false, the user did NOT stop
        // tracking; this was an unclean OS-kill recovery.
        final cleanShutdown = await TrackingStateStore.wasCleanShutdown();
        TelemetryService.instance.reliability(
          fgsSurvived: false,
          osKilled: !cleanShutdown,
        );
        final snapshot = await TrackingStateStore.loadSnapshot();
        if (snapshot != null) {
          dev.log(
            'DEBUG: Restoring session from snapshot: ${snapshot.destinationName}',
            name: 'TrackingService',
          );

          // 1. Restore State
          _destination = LatLng(
            snapshot.destinationLat,
            snapshot.destinationLng,
          );
          _destinationName = snapshot.destinationName;
          _alarmMode = snapshot.alarmMode;
          _alarmValue = snapshot.alarmValue;
          _transitMode = snapshot.metroMode; // Critical: restore transit mode!
          _trackingSessionActive = true;
          // _activeRouteInitialized = false;

          // GAP #2 (adversarial FINDING 1): seed the reachability anchor from the
          // RESTORED progress at the snapshot's time — NOT s=0/now. On an OS-kill
          // resume the train has kept moving during the kill; seeding s=0 would
          // make the worst-case bound climb from zero and give ZERO blackout
          // protection until it re-passed true progress (a real never-late hole).
          // Seeding (s=ekfS, t=createdAt) means the bound = ekfS + V_LINE·(now −
          // createdAt), which correctly over-bounds the distance the train could
          // have covered during the kill. The small EKF-error residual is
          // corrected by the first real fix on resume. If ekfS is absent, fall
          // back to seeding at the snapshot time (bound grows from t0, still
          // better than now).
          {
            final double sSeed =
                (snapshot.ekfS != null && snapshot.ekfS!.isFinite)
                    ? snapshot.ekfS!
                    : 0.0;
            // Reachability runs on a MONOTONIC clock (AppClock.monotonicSeconds,
            // to be immune to wall-clock jumps). The snapshot timestamp is
            // WALL-clock, so map its AGE into the monotonic frame:
            // tSeed = monotonicNow − snapshotAge. A raw wall-clock stamp would be
            // in the wrong frame (a huge epoch value) and make the bound freeze.
            // (Fully-robust across a wall-clock jump DURING the kill needs
            // SystemClock.elapsedRealtime persisted in the snapshot — device-side
            // follow-up; this age mapping is correct for the common no-jump case.)
            final double wallNow =
                AppClock().now().millisecondsSinceEpoch / 1000.0;
            final double snapWall =
                snapshot.createdAt.millisecondsSinceEpoch / 1000.0;
            final double age = wallNow - snapWall;
            final double monoNow = AppClock().monotonicSeconds();
            final double tSeed = (age.isFinite && age >= 0 && age < 86400)
                ? monoNow - age
                : monoNow;
            _alarmController.seedReachabilityAnchorAtArm(
                sMeters: sSeed, tSeconds: tSeed);
          }

          // 2. Register Route (if directions available)
          await SnapshotRouteRestorer.restoreFromSnapshotIfDirectionsPresent(
            snapshot: snapshot,
            destinationOverride: _destination,
            destinationNameOverride: _destinationName,
            registerRouteFromDirections: ({
              required directions,
              required origin,
              required destination,
              required transitMode,
              destinationName,
            }) {
              return TrackingService().registerRouteFromDirections(
                directions: directions,
                origin: origin,
                destination: destination,
                transitMode: transitMode,
                destinationName: destinationName,
                activateRoute: true, // Critical: activate restored route!
              );
            },
          );

          // 3. Start Location Stream
          startLocationStream(service);
          _alarmController.startAlarmStopPollTimer(
            trackingSessionActive: () => _trackingSessionActive,
          );

          // 4. Show Notification (Restored)
          await NotificationService().showJourneyProgress(
            title: 'Journey to $_destinationName',
            subtitle: 'Resumed',
            progress0to1: 0.0,
            isTracking: true,
          );
        } else {
          dev.log(
            'DEBUG: No snapshot found, stopping self',
            name: 'TrackingService',
          );
          service.stopSelf();
        }
      } else {
        dev.log(
          'DEBUG: Session not active, stopping self',
          name: 'TrackingService',
        );
        service.stopSelf();
      }
    } catch (e) {
      dev.log('DEBUG: Recovery failed: $e', name: 'TrackingService');
      service.stopSelf();
    }
  }
}

Future<void> startLocationStream(ServiceInstance service) async {
  // G1: hold a PARTIAL_WAKE_LOCK for the whole tracking session so the CPU stays
  // awake with the screen off and the accel/gyro streams + EKF keep advancing
  // through tunnels. Acquired here so it is re-taken on the recovery-after-death
  // path too (this runs in the background isolate on both fresh start and restart).
  if (!TrackingService.isTestMode) {
    // ignore: discarded_futures
    WakepointNative.acquireWakeLock();
  }
  // Start heartbeat monitoring to detect when foreground is swiped away
  _heartbeatMonitor.start();

  void syncGlobalsFromHandler() {
    _lastGpsUpdate = _locationStreamHandler.lastGpsUpdate;
    _lastProcessedPosition = _locationStreamHandler.lastProcessedPosition;
    _lastSpeedMps = _locationStreamHandler.lastSpeedMps;
    _smoothedETA = _locationStreamHandler.smoothedETA;
    _smoothedSpeed = _locationStreamHandler.smoothedSpeed;
    _distanceTravelledMeters = _locationStreamHandler.distanceTravelledMeters;
    _etaSamples = _locationStreamHandler.etaSamples;
    _timeAlarmEligible = _locationStreamHandler.timeAlarmEligible;
    _fusionActive = _locationStreamHandler.fusionActive;
  }

  await _positionSubscription?.cancel();
  int batteryLevel = 100;
  if (!TrackingService.isTestMode) {
    try {
      final Battery battery = Battery();
      batteryLevel = await battery.batteryLevel;
    } catch (e) {
      dev.log(
        'Battery read failed, defaulting to 100: $e',
        name: 'TrackingService',
      );
      batteryLevel = 100;
    }
  }
  // Select power tier
  final policy =
      TrackingService.isTestMode
          ? PowerPolicy.testing()
          : PowerPolicyManager.forBatteryLevel(batteryLevel);
  // Apply gps dropout and reroute cooldown based on policy
  gpsDropoutBuffer = policy.gpsDropoutBuffer;
  if (_reroutePolicy != null && !TrackingService.isTestMode) {
    try {
      _reroutePolicy!.setCooldown(policy.rerouteCooldown);
    } catch (e) {
      trackingLog.debug('setCooldown failed', data: {'error': e.toString()});
    }
  }

  // Determine policy but delegate stream creation to LocationManager
  // Note: LocationManager currently uses high-accuracy/0-filter by default
  // to support smoothing. We might want to pass these settings later.

  dev.log(
    'DEBUG: startLocationStream - delegating to LocationStreamHandler',
    name: 'TrackingService',
  );

  if (testGpsStream != null) {
    LocationManager().testModeStream = testGpsStream;
  }
  _locationStreamHandler.testAccelerometerStream = testAccelerometerStream;
  _locationStreamHandler.testGyroscopeStream = testGyroscopeStream;

  _locationStreamHandler.onEkfUpdate = (state) {
    _lastEkfState = state;
  };

  _locationStreamHandler.onCheckAlarm = (position, svc) async {
    syncGlobalsFromHandler();
    await _checkAndTriggerAlarm(position, svc);
    syncGlobalsFromHandler();
  };

  _locationStreamHandler.onUpdateNotification = (_) {
    syncGlobalsFromHandler();
    // When the EKF is in degraded mode we have lost GPS mid-journey and are
    // dead-reckoning from motion. Surface that in the ongoing notification so
    // the rider is reassured we're still counting down (not frozen).
    final gpsEstimating = _lastEkfState?.mode == EkfMode.degraded;
    _notificationUpdater.updateNotification(
      registry: _registry,
      allowRouteProgressFromRoutes: _activeManager != null,
      destination: _destination,
      destinationName: _destinationName,
      lastProcessedPosition: _lastProcessedPosition,
      gpsEstimating: gpsEstimating,
    );
  };

  _locationStreamHandler.onBroadcastState = ({
    bool alarmFired = false,
    double? remainingStops,
    Map<String, dynamic>? debugInfo,
  }) {
    syncGlobalsFromHandler();
    _broadcastSimulationState(
      alarmFired: alarmFired,
      remainingStops: remainingStops,
      debugInfo: {
        'destination': _destinationName,
        'is_alarm_fired': _alarmController.anyDestinationAlarmFired,
        if (_lastComputedActiveKey != null)
          'active_key': _lastComputedActiveKey,
        if (_lastComputedOffsetMeters != null)
          'snap_offset_m': (_lastComputedOffsetMeters ?? 0).toStringAsFixed(1),
        if (_lastComputedProgressMeters != null)
          'progress_m': (_lastComputedProgressMeters ?? 0).toStringAsFixed(0),
        if (_lastComputedProgressJumpMeters != null)
          'progress_jump_m': (_lastComputedProgressJumpMeters ?? 0)
              .toStringAsFixed(0),
        if (_lastComputedNextEventType != null)
          'next_event_type': _lastComputedNextEventType,
        if (_lastComputedToNextEventMeters != null)
          'to_next_event_m': (_lastComputedToNextEventMeters ?? 0)
              .toStringAsFixed(0),
        if (_lastComputedPolylineTotalMeters != null)
          'poly_total_m': (_lastComputedPolylineTotalMeters ?? 0)
              .toStringAsFixed(0),
        if (_lastComputedStepTotalMeters != null)
          'step_total_m': (_lastComputedStepTotalMeters ?? 0).toStringAsFixed(
            0,
          ),
        if (_lastEkfState != null) ...{
          'ekf_s': _lastEkfState!.s.toStringAsFixed(1),
          'ekf_sigma_s': _lastEkfState!.sigmaS.toStringAsFixed(1),
          'ekf_v': _lastEkfState!.v.toStringAsFixed(2),
          'ekf_mode': _lastEkfState!.mode.name,
          'ekf_motion': _lastEkfState!.motion.name,
        },
        if (_lastEkfAlarmSnapshot != null) ...{
          'ekf_alarm_s': _lastEkfAlarmSnapshot!.s.toStringAsFixed(1),
          'ekf_alarm_sigma_s': _lastEkfAlarmSnapshot!.sigmaS.toStringAsFixed(1),
          'ekf_alarm_v': _lastEkfAlarmSnapshot!.v.toStringAsFixed(2),
          'ekf_alarm_mode': _lastEkfAlarmSnapshot!.mode.name,
        },
      },
    );
  };

  _locationStreamHandler.onMaybeBroadcastRoute = ({bool force = false}) {
    _maybeBroadcastCachedRoute(force: force);
  };

  _locationStreamHandler.onEndTrackingRequested = (svc) async {
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

    _onStop();
    try {
      svc.stopSelf();
    } catch (_) {}
  };

  await _locationStreamHandler.start(
    LocationStreamContext(
      service: service,
      etaEngine: _etaEngine,
      registry: _registry,
      activeManager: _activeManager,
      isTestMode: TrackingService.isTestMode,
      isBackgroundIsolate: _isBackgroundIsolate,
      isFinalAlarmProvider: () => _alarmController.anyDestinationAlarmFired,
      destination: _destination,
      destinationName: _destinationName,
      alarmMode: _alarmMode,
      alarmValue: _alarmValue,
      transitMode: _transitMode,
      currentDirections: _currentDirections,
      stepBoundsMeters: _stepBoundsMeters,
      stepDurationsSeconds: _stepDurationsSeconds,
      polylineTotalMeters: _lastComputedPolylineTotalMeters,
      transitLegStopsByKey: _sessionManager.transitLegStopsByKey,
      fallbackTransitLegStops:
          _sessionManager.transitLegStopsByKey.values.firstOrNull ??
          _transitLegStops,
    ),
  );
}

// No top-level testing getters; use instance getters on TrackingService.

extension TrackingServiceRouteOps on TrackingService {
  @visibleForTesting
  Future<void> registerRouteRaw({
    required String key,
    required List<LatLng> points,
    required List<double> stepBounds,
    required List<double> stepStops,
    required List<RouteEventBoundary> routeEvents,
    required String destinationName,
    bool transitMode = false,
    LatLng? firstTransitBoarding,
    List<TransitLegStops>? transitLegStops,
  }) async {
    // Propagate step bounds and stops to session manager for alarm logic
    _sessionManager.stepBoundsMetersByKey[key] = List<double>.from(stepBounds);
    _sessionManager.stepStopsCumulativeByKey[key] = List<double>.from(
      stepStops,
    );
    _sessionManager.transitModeByKey[key] = transitMode;
    if (firstTransitBoarding != null) {
      _sessionManager.firstTransitBoardingByKey[key] = firstTransitBoarding;
    }

    // Set up transit leg stops if provided, or synthesize from step data
    if (transitLegStops != null && transitLegStops.isNotEmpty) {
      _sessionManager.transitLegStopsByKey[key] = transitLegStops;
    } else if (transitMode && stepStops.isNotEmpty) {
      // Synthesize transit legs from step data
      // A metro leg exists where cumulative stops increase between steps.
      // Also include non-metro legs (0 stops) so mixed-mode routes can still
      // evaluate destination alarms on the final leg.
      final synthesized = <TransitLegStops>[];
      double prevStops = 0.0;
      for (int i = 0; i < stepBounds.length; i++) {
        final currentStops = stepStops[i];
        final currentBound = stepBounds[i];
        final prevBound = i > 0 ? stepBounds[i - 1] : 0.0;
        final numStopsInStep = (currentStops - prevStops).round();
        final legLength = currentBound - prevBound;

        if (numStopsInStep > 0) {
          // Metro leg with intermediate stops (exclude endpoints)
          final stopMeters = <double>[];
          for (int s = 1; s <= numStopsInStep; s++) {
            stopMeters.add(prevBound + (legLength * s / (numStopsInStep + 1)));
          }

          synthesized.add(
            TransitLegStops(
              legStartMeters: prevBound,
              legEndMeters: currentBound,
              numStops: numStopsInStep,
              stopPositions: [], // No actual positions for synthetic
              stopMeters: stopMeters,
              isMetro: true,
              isActualPositions: false,
            ),
          );
        } else {
          // Non-metro leg (driving/walking) with 0 stops
          synthesized.add(
            TransitLegStops(
              legStartMeters: prevBound,
              legEndMeters: currentBound,
              numStops: 0,
              stopPositions: const [],
              stopMeters: const [],
              isMetro: false,
              isActualPositions: false,
            ),
          );
        }
        prevStops = currentStops;
      }
      if (synthesized.isNotEmpty) {
        _sessionManager.transitLegStopsByKey[key] = synthesized;
      }
    }

    // Build events list, adding synthetic destination if not present
    final eventsList =
        routeEvents
            .map(
              (e) => {
                'meters': e.meters,
                'type': e.type,
                'label': e.label,
                'lat': e.lat,
                'lng': e.lng,
              },
            )
            .toList();

    // Add synthetic destination event if not already present
    final hasDestination = routeEvents.any(
      (e) => e.type == 'destination' || e.type == 'final_destination',
    );
    if (!hasDestination && stepBounds.isNotEmpty) {
      eventsList.add({
        'meters': stepBounds.last,
        'type': 'destination',
        'label': destinationName,
        'lat': points.last.latitude,
        'lng': points.last.longitude,
      });
    }

    _sessionManager.registerRoute(
      key: key,
      points: points,
      mode: transitMode ? 'transit' : 'driving',
      destinationName: destinationName,
      events: eventsList,
      activate: true, // RAW is always active in tests
    );
  }

  @visibleForTesting
  List<RouteEventBoundary> get routeEvents {
    // Return events for the active route key, falling back to legacy _routeEvents
    final activeKey = _sessionManager.activeManager?.activeKey;
    if (activeKey != null) {
      return _sessionManager.routeEventsByKey[activeKey] ?? _routeEvents;
    }
    // Fallback: if only one route registered, return its events
    if (_sessionManager.routeEventsByKey.length == 1) {
      return _sessionManager.routeEventsByKey.values.first;
    }
    return _routeEvents;
  }

  @visibleForTesting
  List<TransitLegStops> get transitLegs {
    // Return transit legs for the active route key, falling back to legacy
    final activeKey = _sessionManager.activeManager?.activeKey;
    if (activeKey != null) {
      return _sessionManager.transitLegStopsByKey[activeKey] ??
          _transitLegStops;
    }
    // Fallback: if only one route registered, return its transit legs
    if (_sessionManager.transitLegStopsByKey.length == 1) {
      return _sessionManager.transitLegStopsByKey.values.first;
    }
    return _transitLegStops;
  }

  Iterable<String> get registeredRouteKeys =>
      _registry.entries.map((e) => e.key);

  @visibleForTesting
  Future<void> checkAlarmForTest(
    Position position,
    ServiceInstance service,
  ) async {
    await _checkAndTriggerAlarm(position, service);
  }

  // Public: update connectivity for reroute policy gating
  void setOnline(bool online) {
    _reroutePolicy?.setOnline(online);
    _offlineCoordinator?.setOffline(!online);
  }

  // Public: Register a fetched route into registry and initialize active manager if needed
  void registerRoute({
    required String key,
    required String mode,
    required String destinationName,
    required List<LatLng> points,
    List<Map<String, dynamic>>? segments,
    List<Map<String, dynamic>>? switchPoints,
    List<Map<String, dynamic>>? events,
    List<Map<String, dynamic>>?
    transitLegsJson, // New Param (optional from external)
    bool activate = false,
  }) {
    // If not provided externally (e.g. from UI), try to serialize from local session
    if (transitLegsJson == null &&
        _sessionManager.transitLegStopsByKey.containsKey(key)) {
      transitLegsJson =
          _sessionManager.transitLegStopsByKey[key]!
              .map((l) => l.toJson())
              .toList();
    }

    _sessionManager.registerRoute(
      key: key,
      mode: mode,
      destinationName: destinationName,
      points: points,
      segments: segments,
      switchPoints: switchPoints,
      events: events,
      transitLegsJson: transitLegsJson,
      activate: activate,
    );

    if (!_isBackgroundIsolate) {
      // Foreground: forward this route to the background service so it can
      // register it and broadcast it to the simulation.
      unawaited(
        _invokeWithAckRetry(
          method: 'registerRoute',
          ackEvent: 'registerRouteAck',
          args: {
            'key': key,
            'mode': mode,
            'destinationName': destinationName,
            'points':
                points
                    .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                    .toList(),
            'segments': segments,
            'switch_points': switchPoints,
            'events': events,
            'transitLegs': transitLegsJson, // Forward legs!
          },
        ),
      );
    }
  }

  // Convenience: register from a Directions response
  Future<void> registerRouteFromDirections({
    required Map<String, dynamic> directions,
    required LatLng origin,
    required LatLng destination,
    required bool transitMode,
    String? destinationName,
    bool activateRoute = false,
  }) async {
    // In test mode, we run everything in-process and often register routes
    // before startTracking() invokes _onStart() (which flips _isBackgroundIsolate).
    // Register locally so snapping/progress + alarm logic has the route available.
    if (TrackingService.isTestMode) {
      await _sessionManager.registerRouteFromDirections(
        directions: directions,
        origin: origin,
        destination: destination,
        transitMode: transitMode,
        destinationName: destinationName,
        activateRoute: activateRoute,
      );
      return;
    }

    // IMPORTANT: route registration must occur in the background isolate,
    // because snapping/progress (and therefore distance-mode alarms) are evaluated there.
    // If ACK retry fails, fall back to a best-effort invoke to the background service,
    // NOT a foreground-only registration.
    if (!_isBackgroundIsolate) {
      _ensureAckListenersRegistered();
      final args = {
        'directions': directions,
        'origin': {'lat': origin.latitude, 'lng': origin.longitude},
        'destination': {
          'lat': destination.latitude,
          'lng': destination.longitude,
        },
        'transitMode': transitMode,
        'destinationName': destinationName,
        'activateRoute': activateRoute,
      };

      final ok = await _invokeWithAckRetry(
        method: 'registerRouteDirections',
        ackEvent: 'registerRouteDirectionsAck',
        args: args,
      );
      if (ok) return;

      // Best-effort fallback: still try to send to background even if ACK is missing.
      try {
        if (!await (_service?.isRunning() ?? Future.value(false))) {
          await _service?.startService();
        }
        _service?.invoke('registerRouteDirections', args);
      } catch (e) {
        trackingLog.error(
          'registerRouteFromDirections fallback invoke failed',
          error: e,
        );
      }
      return;
    }

    // Background isolate: perform registration directly.
    await _sessionManager.registerRouteFromDirections(
      directions: directions,
      origin: origin,
      destination: destination,
      transitMode: transitMode,
      destinationName: destinationName,
      activateRoute: activateRoute,
    );
  }
}
