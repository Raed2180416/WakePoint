// lib/services/trackingservice.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'dart:developer' as dev;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/services/notification_service.dart';
import 'package:geowake2/services/simulation_client.dart';
import 'package:geowake2/services/sensor_fusion.dart';
import 'package:geowake2/services/route_registry.dart';
import 'package:geowake2/services/eta_engine.dart';
import 'package:geowake2/services/active_route_manager.dart';
import 'package:geowake2/services/deviation_monitor.dart';
import 'package:geowake2/services/reroute_policy.dart';
import 'package:geowake2/services/route_cache.dart';
import 'package:geowake2/services/polyline_simplifier.dart';
import 'package:geowake2/services/polyline_decoder.dart';
import 'package:geowake2/services/transfer_utils.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/offline_coordinator.dart';
import 'package:geowake2/config/power_policy.dart';
import 'package:geowake2/services/snap_to_route.dart';
import 'package:geowake2/services/tracking_state_store.dart';
import 'package:geowake2/services/navigation_service.dart';

import 'package:sensors_plus/sensors_plus.dart';

// (Test code and other definitions remain the same)
Stream<Position>? testGpsStream;
@visibleForTesting
Stream<AccelerometerEvent>? testAccelerometerStream;
@visibleForTesting
Duration gpsDropoutBuffer = const Duration(seconds: 25);

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
  final FlutterBackgroundService _service = FlutterBackgroundService();

  // Foreground <-> background invoke reliability (route registration)
  bool _ackListenersRegistered = false;
  int _invokeRequestCounter = 0;
  final Map<String, Completer<void>> _pendingAcks = <String, Completer<void>>{};

  void _ensureAckListenersRegistered() {
    if (_ackListenersRegistered || TrackingService.isTestMode) return;
    _ackListenersRegistered = true;

    _service.on('registerRouteAck').listen((data) {
      final requestId = data?['requestId'] as String?;
      if (requestId == null) return;
      final completer = _pendingAcks.remove(requestId);
      completer?.complete();
    });

    _service.on('registerRouteDirectionsAck').listen((data) {
      final requestId = data?['requestId'] as String?;
      if (requestId == null) return;
      final completer = _pendingAcks.remove(requestId);
      completer?.complete();
    });

    _service.on('startTrackingAck').listen((data) {
      final requestId = data?['requestId'] as String?;
      if (requestId == null) return;
      final completer = _pendingAcks.remove(requestId);
      completer?.complete();
    });

    // Listen for alarm trigger requests from background isolate
    // Background isolate cannot show notifications directly (no Android Context)
    // so it sends the request here and the foreground isolate shows the notification
    _service.on('triggerAlarm').listen((data) async {
      print('DEBUG: Foreground received triggerAlarm from background');
      if (data == null) return;
      try {
        final title = data['title'] as String? ?? 'Time to Wake Up!';
        final body =
            data['body'] as String? ?? 'You are approaching your destination';
        final allowContinue = data['allowContinue'] as bool? ?? false;
        print('DEBUG: Foreground calling showWakeUpAlarm: title=$title');
        await NotificationService().showWakeUpAlarm(
          title: title,
          body: body,
          allowContinueTracking: allowContinue,
        );
        print('DEBUG: Foreground showWakeUpAlarm completed');
      } catch (e) {
        print('DEBUG: Foreground triggerAlarm handler error: $e');
        dev.log(
          'Foreground triggerAlarm handler error: $e',
          name: 'TrackingService',
        );
      }
    });
  }

  Future<bool> _invokeWithAckRetry({
    required String method,
    required Map<String, dynamic> args,
    required String ackEvent,
  }) async {
    if (TrackingService.isTestMode) return false;

    _ensureAckListenersRegistered();

    final delays = <Duration>[
      const Duration(milliseconds: 50),
      const Duration(milliseconds: 150),
      const Duration(milliseconds: 300),
      const Duration(milliseconds: 600),
      const Duration(milliseconds: 900),
    ];

    for (var attempt = 0; attempt < delays.length; attempt++) {
      final requestId =
          '${DateTime.now().millisecondsSinceEpoch}_${_invokeRequestCounter++}';
      final completer = Completer<void>();
      _pendingAcks[requestId] = completer;

      try {
        _service.invoke(method, {...args, 'requestId': requestId});
      } catch (_) {
        _pendingAcks.remove(requestId);
      }

      try {
        await completer.future.timeout(const Duration(milliseconds: 700));
        return true;
      } catch (_) {
        _pendingAcks.remove(requestId);
      }

      await Future<void>.delayed(delays[attempt]);
    }

    dev.log(
      'CRITICAL: Foreground: No ACK received for $method ($ackEvent), giving up',
      name: 'TrackingService',
    );
    return false;
  }

  // Expose streams bound to background isolate controllers
  Stream<ActiveRouteState> get activeRouteStateStream => _routeStateCtrl.stream;
  Stream<RouteSwitchEvent> get routeSwitchStream => _routeSwitchCtrl.stream;
  Stream<RerouteDecision> get rerouteDecisionStream => _rerouteCtrl.stream;

  Future<void> initializeService() async {
    if (isTestMode) return;
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        isForegroundMode: true,
        autoStart: false,
        notificationChannelId: 'geowake_tracking_channel_v2',
        initialNotificationTitle: 'GeoWake Tracking',
        initialNotificationContent: 'Starting…',
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
    bool allowNotificationsInTest = false,
    bool useInjectedPositions = false,
    List<LatLng>? routePoints,
  }) async {
    // Ensure foreground listeners are registered to receive alarm triggers from background
    _ensureAckListenersRegistered();

    final Map<String, dynamic> params = {
      'destinationLat': destination.latitude,
      'destinationLng': destination.longitude,
      'destinationName': destinationName,
      'alarmMode': alarmMode,
      'alarmValue': alarmValue,
      'useInjectedPositions': useInjectedPositions,
    };
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
      } catch (_) {}
      // In test mode, we can directly call _onStart with the parameters
      _onStart(TestServiceInstance(), initialData: params);
      return;
    }
    if (!await _service.isRunning()) {
      await _service.startService();
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
        subtitle: 'Starting…',
        progress0to1: 0,
        isTracking: true,
      );
    } catch (_) {}
    print('DEBUG: Invoking startTracking on background service');
    final acked = await _invokeWithAckRetry(
      method: 'startTracking',
      args: params,
      ackEvent: 'startTrackingAck',
    );
    if (!acked) {
      // Fallback: best-effort invoke (older background or unexpected ack failures)
      try {
        _service.invoke('startTracking', params);
      } catch (_) {}
    }
    // Start sending heartbeats to background service
    _startForegroundHeartbeat();
  }

  Future<void> stopTracking({bool stopServiceInstance = true}) async {
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
    final running = await _service.isRunning();
    if (running) {
      _service.invoke("stopTracking", {'stopSelf': stopServiceInstance});
    } else {
      // If service already stopped, still clear foreground state
      _onStop();
    }
  }

  Future<void> muteJourneyNotifications() async {
    try {
      await TrackingStateStore.setNotificationsMuted(true);
      await NotificationService().cancelJourneyProgress();
    } catch (_) {}
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
          } catch (_) {}
        }

        await TrackingStateStore.setActive(true);
        await TrackingStateStore.setPaused(false);
        await TrackingStateStore.setAlarmFired(false);
        try {
          await NotificationService().cancelTrackingPaused();
        } catch (_) {}

        if (!TrackingService.isTestMode) {
          final running = await _service.isRunning();
          if (!running) {
            await _service.startService();
          }
          _service.invoke('startTracking', {
            'destinationLat': snapshot.destinationLat,
            'destinationLng': snapshot.destinationLng,
            'destinationName': snapshot.destinationName,
            'alarmMode': snapshot.alarmMode,
            'alarmValue': snapshot.alarmValue,
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
    } catch (_) {}
  }

  // Timer for sending heartbeats to background service
  Timer? _heartbeatSendTimer;

  /// Start sending heartbeats to the background service.
  /// Call this when tracking starts and app is in foreground.
  void _startForegroundHeartbeat() async {
    if (_isBackgroundIsolate || isTestMode) return;
    _heartbeatSendTimer?.cancel();
    // Check if service is running before sending heartbeats
    final running = await _service.isRunning();
    if (!running) {
      print('DEBUG: _startForegroundHeartbeat - service not running, skipping');
      return;
    }
    // Send initial heartbeat immediately
    _sendHeartbeat();
    // Then send every second
    _heartbeatSendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sendHeartbeat();
    });
  }

  void _sendHeartbeat() async {
    if (_isBackgroundIsolate || isTestMode) return;
    // Check if service is running before invoking
    final running = await _service.isRunning();
    if (!running) return;
    try {
      _service.invoke('foregroundHeartbeat', {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}
  }

  void _stopForegroundHeartbeat() {
    _heartbeatSendTimer?.cancel();
    _heartbeatSendTimer = null;
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
      // Also tell background we're back
      final running = await _service.isRunning();
      if (running) {
        try {
          _service.invoke('foregroundResumed', {});
        } catch (_) {}
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
    } catch (_) {}

    await stopTracking();

    // Optionally navigate back to a safe screen when not under test
    if (navigateHome && !TrackingService.isTestMode) {
      try {
        final nav = NavigationService.navigatorKey.currentState;
        nav?.pushNamedAndRemoveUntil('/', (route) => false);
      } catch (_) {}
    }
  }

  @visibleForTesting
  bool get fusionActive => _fusionActive;
  @visibleForTesting
  bool get alarmTriggered => _destinationAlarmFired;
  @visibleForTesting
  DateTime? get lastGpsUpdateValue => _lastGpsUpdate;
  @visibleForTesting
  LatLng? get lastValidPosition => _lastProcessedPosition;
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
StreamSubscription<Position>? _positionSubscription;
DateTime? _lastGpsUpdate;
SensorFusionManager? _sensorFusionManager;
Timer? _gpsCheckTimer;
LatLng? _lastProcessedPosition;
double? _smoothedETA;
final EtaEngine _etaEngine = EtaEngine();
double? _apiEtaSeconds;

// Heartbeat mechanism for detecting when foreground app is swiped away
DateTime? _lastForegroundHeartbeat;
Timer? _heartbeatCheckTimer;
const Duration _heartbeatTimeout = Duration(
  seconds: 4,
); // If no heartbeat for 4s, app is gone
const Duration _heartbeatCheckInterval = Duration(seconds: 2); // Check every 2s
bool _fusionActive = false;
double? _lastSpeedMps;
// Support for injected test positions from foreground (demo path)
bool _useInjectedPositions = false;
StreamController<Position>? _injectedCtrl;
SimulationClient? _simulationClient;
// Track if simulation has received at least one position from dashboard.
// Only use simulation stream when dashboard is actively controlling positions.
bool _simulationPositionsReceived = false;
const double _kDefaultStopSpacingMeters = 500.0;
// Time-alarm gating state
DateTime? _startedAt;
LatLng? _startPosition;
double _distanceTravelledMeters = 0.0;
int _etaSamples = 0;
bool _timeAlarmEligible = false;
DateTime? _lastAlarmFiredAt;
// Fast poll timer for consuming alarm stop requests quickly after alarm fires.
Timer? _alarmStopPollTimer;

void _broadcastSimulationState({
  bool alarmFired = false,
  double? remainingStops,
  Map<String, dynamic>? debugInfo,
}) {
  if (_simulationClient == null || !_simulationClient!.active) return;

  final now = DateTime.now();
  final recentAlarm =
      _lastAlarmFiredAt != null &&
      now.difference(_lastAlarmFiredAt!).inSeconds <= 5;

  final double etaRaw = _apiEtaSeconds ?? _smoothedETA ?? 0.0;
  final int etaSeconds = etaRaw.isFinite ? etaRaw.round() : 0;
  final double distance =
      _distanceTravelledMeters.isFinite ? _distanceTravelledMeters : 0.0;

  _simulationClient!.broadcastState(
    etaSeconds: etaSeconds,
    distanceTravelled: distance,
    alarmMode: _alarmMode ?? 'distance',
    alarmValue: _alarmValue ?? 0.0,
    alarmFired: alarmFired || _destinationAlarmFired || recentAlarm,
    remainingStops: remainingStops,
    debugInfo: debugInfo,
  );
}

/// Starts a fast-polling timer that checks for notification action requests every 100ms.
/// This ensures the user's "Stop Alarm", "Ignore", and "End Tracking" buttons are responsive,
/// even when the main GPS check timer runs at 1-3 second intervals.
/// The timer auto-cancels after 60 seconds if no request is consumed.
void _startAlarmStopPollTimer() {
  _alarmStopPollTimer?.cancel();
  int tickCount = 0;
  const maxTicks = 600; // 60 seconds at 100ms intervals
  _alarmStopPollTimer = Timer.periodic(const Duration(milliseconds: 100), (
    timer,
  ) async {
    tickCount++;
    if (tickCount > maxTicks) {
      timer.cancel();
      _alarmStopPollTimer = null;
      return;
    }
    try {
      // Check stop alarm request
      final stopAlarmRequested =
          await NotificationService.consumeStopAlarmRequest();
      if (stopAlarmRequested) {
        dev.log(
          'Fast poll: Consumed stop alarm request (tick=$tickCount)',
          name: 'TrackingService',
        );
        try {
          await NotificationService().cancelAlarm();
        } catch (_) {}
        try {
          await NotificationService().restoreJourneyProgressIfActive();
        } catch (_) {}
        // Don't cancel timer - keep polling for other actions
      }

      // Check mute journey request
      final muteJourneyRequested =
          await NotificationService.consumeMuteJourneyRequest();
      if (muteJourneyRequested) {
        dev.log(
          'Fast poll: Consumed mute journey request (tick=$tickCount)',
          name: 'TrackingService',
        );
        try {
          await TrackingStateStore.setNotificationsMuted(true);
          await NotificationService().cancelJourneyProgress();
        } catch (_) {}
      }

      // Check end tracking request
      final endTrackingRequested =
          await NotificationService.consumeEndTrackingRequest();
      if (endTrackingRequested) {
        dev.log(
          'Fast poll: Consumed end tracking request (tick=$tickCount)',
          name: 'TrackingService',
        );
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
          FlutterBackgroundService().invoke('stopService');
        } catch (_) {}
        // Cancel this timer since tracking is ending
        timer.cancel();
        _alarmStopPollTimer = null;
        return;
      }
    } catch (e) {
      dev.log('Fast poll error: $e', name: 'TrackingService');
    }
  });
}

/// Cancels the fast alarm stop poll timer.
void _cancelAlarmStopPollTimer() {
  _alarmStopPollTimer?.cancel();
  _alarmStopPollTimer = null;
}

// --- NEW STATE VARIABLES FOR ALARM LOGIC ---
LatLng? _destination;
String? _destinationName;
String? _alarmMode;
double? _alarmValue;
bool _destinationAlarmFired = false; // fire destination alarm only once
final Set<int> _firedEventIndexes =
    <int>{}; // indices into _routeEvents already fired

// Event boundaries (transfers, mode changes) for multi-route safety
List<RouteEventBoundary> _routeEvents = const [];
List<double> _stepBoundsMeters = const [];
List<double> _stepStopsCumulative = const [];

// Route management and deviation/reroute state
final RouteRegistry _registry = RouteRegistry();
ActiveRouteManager? _activeManager;
DeviationMonitor? _devMonitor;
ReroutePolicy? _reroutePolicy;
OfflineCoordinator? _offlineCoordinator;
final _routeStateCtrl = StreamController<ActiveRouteState>.broadcast();
final _routeSwitchCtrl = StreamController<RouteSwitchEvent>.broadcast();
final _rerouteCtrl = StreamController<RerouteDecision>.broadcast();

StreamSubscription<ActiveRouteState>? _mgrStateSub;
StreamSubscription<RouteSwitchEvent>? _mgrSwitchSub;
StreamSubscription<DeviationState>? _devSub;
StreamSubscription<RerouteDecision>? _rerouteSub;
bool _activeRouteInitialized = false;
bool _rerouteInFlight = false;
bool _transitMode = false;
ActiveRouteState? _lastActiveState;
LatLng? _firstTransitBoarding;
bool _preBoardingAlertFired = false;

Map<String, dynamic>? _cachedRoutePayload;
DateTime? _lastRouteBroadcastAt;

void _maybeBroadcastCachedRoute({bool force = false}) {
  try {
    if (_simulationClient == null || !_simulationClient!.active) return;
    final payload = _cachedRoutePayload;
    if (payload == null) return;

    final last = _lastRouteBroadcastAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last).inSeconds < 20) {
      return;
    }

    _lastRouteBroadcastAt = DateTime.now();
    _simulationClient!.broadcastRoute(
      destinationName: payload['destinationName'] as String,
      points: (payload['points'] as List).cast<Map<String, dynamic>>(),
      segments: (payload['segments'] as List?)?.cast<Map<String, dynamic>>(),
      switchPoints:
          (payload['switch_points'] as List?)?.cast<Map<String, dynamic>>(),
      events: (payload['events'] as List?)?.cast<Map<String, dynamic>>(),
    );
  } catch (_) {}
}

@pragma('vm:entry-point')
void _onStop() async {
  _isBackgroundIsolate = false;
  _stopHeartbeatMonitoring();
  _positionSubscription?.cancel();
  _positionSubscription = null;
  _simulationClient?.disconnect();
  _simulationClient = null;
  _simulationPositionsReceived = false;
  _gpsCheckTimer?.cancel();
  _gpsCheckTimer = null;
  if (_sensorFusionManager != null) {
    _sensorFusionManager!.stopFusion();
    _sensorFusionManager!.dispose();
    _sensorFusionManager = null;
  }
  _fusionActive = false;
  _mgrStateSub?.cancel();
  _mgrStateSub = null;
  _mgrSwitchSub?.cancel();
  _mgrSwitchSub = null;
  _devSub?.cancel();
  _devSub = null;
  _rerouteSub?.cancel();
  _rerouteSub = null;
  _activeManager?.dispose();
  _activeManager = null;
  _devMonitor?.dispose();
  _devMonitor = null;
  _reroutePolicy?.dispose();
  _reroutePolicy = null;

  // Persist final ETA state
  await _etaEngine.saveState(force: true);

  // Reset per-session route/alarm state to avoid stale behavior on next run.
  try {
    _registry.clear();
  } catch (_) {}
  _activeRouteInitialized = false;
  _lastActiveState = null;
  _routeEvents = const [];
  _stepBoundsMeters = const [];
  _stepStopsCumulative = const [];
  _firstTransitBoarding = null;
  _preBoardingAlertFired = false;
  _transitMode = false;
  _cachedRoutePayload = null;
  _lastRouteBroadcastAt = null;
  _destinationAlarmFired = false;
  _firedEventIndexes.clear();

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
  } catch (_) {}
  dev.log("Tracking has been fully stopped.", name: "TrackingService");
}

/// Reset alarm state so alarms can fire again.
/// Called when dashboard progress slider is moved backwards,
/// or when a new route is registered.
void _resetAlarmState() {
  dev.log(
    'DEBUG: _resetAlarmState called - resetting alarm flags',
    name: 'TrackingService',
  );
  _destinationAlarmFired = false;
  _firedEventIndexes.clear();
  _preBoardingAlertFired = false;

  // Also stop any currently playing alarm
  AlarmPlayer.stop();
  NotificationService().stopVibration();
  dev.log(
    'DEBUG: _resetAlarmState completed - flags reset to false',
    name: 'TrackingService',
  );
}

/// Helper to trigger alarm notification - handles background isolate case
/// where NotificationService can't show notifications directly due to
/// null Android Context. In that case, we send a request to the foreground.
Future<void> _triggerAlarmNotification({
  required ServiceInstance service,
  required String title,
  required String body,
  required bool allowContinueTracking,
}) async {
  print(
    'DEBUG: _triggerAlarmNotification called - isBackground=$_isBackgroundIsolate, isTestMode=${TrackingService.isTestMode}',
  );

  if (TrackingService.isTestMode) {
    // In test mode, call notification service directly (it records without platform calls)
    await NotificationService().showWakeUpAlarm(
      title: title,
      body: body,
      allowContinueTracking: allowContinueTracking,
    );
    return;
  }

  if (_isBackgroundIsolate) {
    // Background isolate cannot show notifications directly - send to foreground
    print('DEBUG: Background isolate - sending triggerAlarm to foreground');
    service.invoke('triggerAlarm', {
      'title': title,
      'body': body,
      'allowContinue': allowContinueTracking,
    });
  } else {
    // Foreground isolate - can show notifications directly
    print('DEBUG: Foreground isolate - calling showWakeUpAlarm directly');
    await NotificationService().showWakeUpAlarm(
      title: title,
      body: body,
      allowContinueTracking: allowContinueTracking,
    );
  }
}

// --- NEW FUNCTION: Contains the core alarm logic ---
@pragma('vm:entry-point')
Future<void> _checkAndTriggerAlarm(
  Position currentPosition,
  ServiceInstance service,
) async {
  print(
    'DEBUG: _checkAndTriggerAlarm called with pos=(${currentPosition.latitude.toStringAsFixed(5)}, ${currentPosition.longitude.toStringAsFixed(5)})',
  );
  print(
    'DEBUG: _checkAndTriggerAlarm state: _alarmMode=$_alarmMode, _destination=$_destination, _alarmValue=$_alarmValue',
  );
  if (_destination == null || _alarmValue == null) {
    print(
      'DEBUG: _checkAndTriggerAlarm early return - destination=$_destination, alarmValue=$_alarmValue',
    );
    return;
  }

  // Keep a fresh snapshot of position/speed for snapping and deviation logic
  _lastProcessedPosition = LatLng(
    currentPosition.latitude,
    currentPosition.longitude,
  );
  _lastSpeedMps = currentPosition.speed;

  bool shouldTriggerDestination = false;
  String? destinationReasonLabel;

  double stopsAt(double meters) {
    if (_stepBoundsMeters.isEmpty || _stepStopsCumulative.isEmpty) {
      return 0.0;
    }
    double prevBound = 0.0;
    double prevStops = 0.0;
    for (int i = 0; i < _stepBoundsMeters.length; i++) {
      final bound = _stepBoundsMeters[i];
      final stopsHere = _stepStopsCumulative[i];
      if (meters <= bound) {
        final segmentLen = (bound - prevBound).abs();
        final deltaStops = stopsHere - prevStops;
        if (segmentLen <= 0.0) {
          return stopsHere;
        }
        final t = ((meters - prevBound) / segmentLen).clamp(0.0, 1.0);
        return prevStops + t * deltaStops;
      }
      prevBound = bound;
      prevStops = stopsHere;
    }
    return _stepStopsCumulative.last;
  }

  if (_alarmMode == 'distance') {
    double distanceInMeters = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      _destination!.latitude,
      _destination!.longitude,
    );
    if (distanceInMeters <= (_alarmValue! * 1000)) {
      // alarmValue is in km
      shouldTriggerDestination = true;
      destinationReasonLabel = _destinationName;
    }
    print(
      "DEBUG: Distance Check: ${distanceInMeters.toStringAsFixed(0)}m / ${(_alarmValue! * 1000).toStringAsFixed(0)}m shouldTrigger=$shouldTriggerDestination",
    );
  } else if (_alarmMode == 'time') {
    // Time-mode: avoid missing alarms. Use a soft eligibility signal (speed/movement/ETA samples)
    // instead of a hard gate that can block triggers in stop-and-go scenarios.
    final eligible =
        TrackingService.isTestMode ||
        _timeAlarmEligible ||
        (_etaSamples >= 1) ||
        (_distanceTravelledMeters >= 30.0) ||
        (_lastSpeedMps != null && _lastSpeedMps! >= 0.5);

    if (!eligible) {
      print(
        'DEBUG: Time alarm not yet eligible (soft). Samples=$_etaSamples, moved=${_distanceTravelledMeters.toStringAsFixed(1)}m, sinceStart=${_startedAt != null ? DateTime.now().difference(_startedAt!).inSeconds : -1}s',
      );
    } else if (_smoothedETA != null && _smoothedETA! <= (_alarmValue! * 60)) {
      // alarmValue is in minutes
      shouldTriggerDestination = true;
      destinationReasonLabel = _destinationName;
    }
    print(
      "DEBUG: Time Check: ETA=${_smoothedETA?.toStringAsFixed(0)}s / threshold=${(_alarmValue! * 60).toStringAsFixed(0)}s (eligible=$_timeAlarmEligible) shouldTrigger=$shouldTriggerDestination",
    );
  }

  // Metro pre-boarding alert: if stops-mode + transit route; trigger once near boarding point
  if (_alarmMode == 'stops' && _transitMode && !_preBoardingAlertFired) {
    try {
      if (_firstTransitBoarding != null) {
        final d = Geolocator.distanceBetween(
          currentPosition.latitude,
          currentPosition.longitude,
          _firstTransitBoarding!.latitude,
          _firstTransitBoarding!.longitude,
        );
        dev.log(
          'Pre-boarding check: mode=stops transit=$_transitMode d=${d.toStringAsFixed(1)}m to boarding=$_firstTransitBoarding',
          name: 'TrackingService',
        );
        // 1 stop == 1 km for pre-boarding alert
        if (d <= 1100.0) {
          if (TrackingService.isTestMode) {
            // Ensure observability even if the notification helper throws
            try {
              NotificationService.testRecordedAlarms.add({
                'title': 'Approaching metro station',
                'body': 'Approaching metro station - Get ready to board',
                'allow': true,
                'ts': DateTime.now().toIso8601String(),
              });
              dev.log(
                'PreBoard alert recorded (test mode) d=${d.toStringAsFixed(1)} count=${NotificationService.testRecordedAlarms.length}',
                name: 'TrackingService',
              );
            } catch (_) {}
          }
          try {
            dev.log(
              'Pre-boarding ALERT firing at d=${d.toStringAsFixed(1)}m',
              name: 'TrackingService',
            );
            await _triggerAlarmNotification(
              service: service,
              title: 'Approaching metro station',
              body: 'Approaching metro station - Get ready to board',
              allowContinueTracking: true,
            );
            _preBoardingAlertFired = true;
            // Start fast polling for Stop Alarm button responsiveness.
            _startAlarmStopPollTimer();
          } catch (_) {
            _preBoardingAlertFired = false; // allow retry if something failed
          }
        }
      }
    } catch (_) {}
  }

  // Also check upcoming route events (transfer/mode change) with the same threshold semantics
  // Use latest progressMeters snapshot for stops/time event calculations
  double? progressMeters;
  try {
    progressMeters = _lastActiveState?.progressMeters;
    RouteEntry? active;
    if (_lastActiveState?.activeKey != null && _registry.entries.isNotEmpty) {
      try {
        active = _registry.entries.firstWhere(
          (e) => e.key == _lastActiveState!.activeKey,
          orElse: () => _registry.entries.first,
        );
      } catch (_) {}
    }
    active ??= _registry.entries.isNotEmpty ? _registry.entries.first : null;

    if (active != null && _lastProcessedPosition != null) {
      final snap = SnapToRouteEngine.snap(
        point: _lastProcessedPosition!,
        polyline: active.points,
        hintIndex: active.lastSnapIndex,
        precomputedCumMeters: active.cumMeters,
      );
      progressMeters = snap.progressMeters;
      _registry.updateSessionState(
        active.key,
        lastSnapIndex: snap.segmentIndex,
        lastProgressMeters: snap.progressMeters,
      );
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

  // NOTE: For stops mode with route events, destination alarm is handled in the event loop below
  // to ensure intermediate switch points fire their alarms before the destination alarm.
  // However, we also need a FALLBACK for when route events aren't available (e.g., race condition
  // between startTracking and registerRouteDirections, or non-transit routes).
  // This fallback uses distance-based calculation to the destination.
  if (_alarmMode == 'stops' &&
      !_destinationAlarmFired &&
      _routeEvents.isEmpty) {
    // Fallback: use 1km per stop (500m avg stop spacing x 2 for safety margin)
    final distToDestM = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      _destination!.latitude,
      _destination!.longitude,
    );
    final effectiveStops = distToDestM / _kDefaultStopSpacingMeters;
    dev.log(
      'Stops fallback: distToDestM=${distToDestM.toStringAsFixed(0)} effectiveStops=${effectiveStops.toStringAsFixed(2)} threshold=${_alarmValue} routeEvents=${_routeEvents.length}',
      name: 'TrackingService',
    );
    if (effectiveStops <= _alarmValue!) {
      shouldTriggerDestination = true;
      destinationReasonLabel = _destinationName;
      dev.log(
        'Stops fallback TRIGGERED! effectiveStops <= threshold',
        name: 'TrackingService',
      );
    }
  }

  // Also check upcoming route events (transfer/mode change) with the same threshold semantics.
  // If the destination alarm is already due (or already fired), skip intermediate alarms to
  // avoid overlapping notifications in the same tick.
  final bool destinationPending =
      shouldTriggerDestination || _destinationAlarmFired;
  dev.log(
    'Event loop check: routeEvents=${_routeEvents.length} progressMeters=$progressMeters destinationPending=$destinationPending',
    name: 'TrackingService',
  );
  if (_routeEvents.isNotEmpty &&
      progressMeters != null &&
      !destinationPending) {
    bool destinationTriggeredThisTick = false;
    try {
      final thresholdMeters =
          _alarmMode == 'distance' ? (_alarmValue! * 1000.0) : null;
      final thresholdSeconds =
          _alarmMode == 'time' ? (_alarmValue! * 60.0) : null;
      final thresholdStops = _alarmMode == 'stops' ? (_alarmValue!) : null;
      final spd =
          _lastSpeedMps != null && _lastSpeedMps! > 0.3 ? _lastSpeedMps! : 10.0;
      double? progressStops;
      if (thresholdStops != null) {
        progressStops = stopsAt(progressMeters);
      }
      // If destination is already within the same threshold, suppress lower-priority
      // transfer/mode-change alarms to avoid double-firing when both coincide.
      bool destinationWithinThreshold = false;
      double? remainingStopsToDestination;
      if (thresholdStops != null && progressStops != null) {
        final destStopsTotal =
            _stepStopsCumulative.isNotEmpty
                ? _stepStopsCumulative.last
                : (_stepBoundsMeters.isNotEmpty
                    ? _stepBoundsMeters.last / _kDefaultStopSpacingMeters
                    : 0.0);
        remainingStopsToDestination = destStopsTotal - progressStops;
        // Allow transfer alarms when exactly at the threshold (e.g., 2 stops out);
        // suppress only when destination is strictly closer than the threshold.
        if (remainingStopsToDestination.isFinite &&
            remainingStopsToDestination < thresholdStops) {
          destinationWithinThreshold = true;
        }
      }
      for (int idx = 0; idx < _routeEvents.length; idx++) {
        if (destinationTriggeredThisTick || _destinationAlarmFired) {
          break; // Once destination fires, suppress remaining event alarms in this tick
        }
        final ev = _routeEvents[idx];
        if (_firedEventIndexes.contains(idx)) continue; // already alerted
        if (ev.meters < progressMeters - 200.0) {
          continue; // allow small overshoot window
        }
        final toEventM = ev.meters - progressMeters;
        bool eventAlarm = false;
        double? effectiveStopsToEvent;
        if (thresholdMeters != null) {
          eventAlarm = toEventM <= thresholdMeters;
        } else if (thresholdSeconds != null) {
          final estSec = toEventM / spd;
          eventAlarm = estSec <= thresholdSeconds;
        } else if (thresholdStops != null && progressStops != null) {
          final eventStops = stopsAt(ev.meters);
          final toEventStops = eventStops - progressStops;
          final toEventStopsFallback = toEventM / _kDefaultStopSpacingMeters;
          double effectiveStops;
          // If actual transit stops exist between progress and event, use them directly.
          // Only fall back to distance-based calculation when no actual stops are available
          // (e.g., walking segments or when stops data is missing/invalid).
          if (toEventStops.isFinite && toEventStops > 0.5) {
            // Use actual stops - this is more accurate for transit segments.
            effectiveStops = toEventStops;
          } else if (toEventStopsFallback.isFinite &&
              toEventStopsFallback >= 0) {
            // Fall back to distance-based (500m per "stop") for walking/unknown segments.
            effectiveStops = toEventStopsFallback;
          } else {
            // Safety fallback if both are invalid.
            effectiveStops = toEventM / _kDefaultStopSpacingMeters;
          }
          effectiveStopsToEvent = effectiveStops;
          dev.log(
            'Event check ev=${ev.label ?? ev.type} evM=${ev.meters.toStringAsFixed(0)} progM=${progressMeters.toStringAsFixed(0)} toM=${toEventM.toStringAsFixed(0)} progStops=${progressStops.toStringAsFixed(2)} evStops=${eventStops.toStringAsFixed(2)} toStops=${toEventStops.toStringAsFixed(2)} fallback=${toEventStopsFallback.toStringAsFixed(2)} eff=${effectiveStops.toStringAsFixed(2)} thr=$thresholdStops',
            name: 'TrackingService',
          );
          eventAlarm = effectiveStops <= thresholdStops;
          // Removed secondary distance-based trigger to ensure consistent alarm timing
          // based on the user's chosen stops threshold. The fallback in effectiveStops
          // already handles cases where actual stops data is unavailable.
        }
        if (eventAlarm) {
          if (destinationWithinThreshold && ev.type != 'destination') {
            if (remainingStopsToDestination != null &&
                effectiveStopsToEvent != null &&
                remainingStopsToDestination < effectiveStopsToEvent) {
              dev.log(
                'Suppressing ${ev.type} alarm because destination is closer within threshold (priority win)',
                name: 'TrackingService',
              );
              continue;
            }
            dev.log(
              'Destination is within threshold but transfer kept (destination not closer).',
              name: 'TrackingService',
            );
          }
          // Handle destination event separately with final alarm behavior
          if (ev.type == 'destination') {
            if (_destinationAlarmFired)
              continue; // already fired destination alarm
            _destinationAlarmFired = true;
            try {
              final title = 'Wake Up!';
              final body =
                  ev.label != null
                      ? 'Approaching: ${ev.label}'
                      : 'You are nearing your destination';
              _lastAlarmFiredAt = DateTime.now();
              _broadcastSimulationState(alarmFired: true);
              await _triggerAlarmNotification(
                service: service,
                title: title,
                body: body,
                allowContinueTracking: false,
              );
              _startAlarmStopPollTimer();
            } catch (_) {}
            _firedEventIndexes.add(idx);
            destinationTriggeredThisTick = true;
            continue;
          }
          // Handle intermediate events (transfer/mode_change/boarding/alighting)
          try {
            final title =
                ev.type == 'transfer' ? 'Upcoming transfer' : 'Upcoming change';
            final body =
                ev.label != null
                    ? ev.label!
                    : (ev.type == 'transfer'
                        ? 'Transfer ahead'
                        : 'Mode change ahead');

            _lastAlarmFiredAt = DateTime.now();
            _broadcastSimulationState(alarmFired: true);
            await _triggerAlarmNotification(
              service: service,
              title: title,
              body: body,
              allowContinueTracking: true,
            );
            // Start fast polling for Stop Alarm button responsiveness.
            _startAlarmStopPollTimer();
          } catch (_) {}
          _firedEventIndexes.add(idx);
        }
      }
    } catch (_) {}
  }

  dev.log(
    'DEBUG: Alarm check result - shouldTrigger=$shouldTriggerDestination, alreadyFired=$_destinationAlarmFired, mode=$_alarmMode, value=$_alarmValue',
    name: 'TrackingService',
  );

  if (shouldTriggerDestination && !_destinationAlarmFired) {
    print(
      "DEBUG: DESTINATION ALARM TRIGGERED! shouldTrigger=$shouldTriggerDestination alreadyFired=$_destinationAlarmFired",
    );
    _destinationAlarmFired = true;
    final title = 'Wake Up! ';
    final body =
        destinationReasonLabel != null
            ? 'Approaching: $destinationReasonLabel'
            : 'You are nearing your target';
    try {
      _lastAlarmFiredAt = DateTime.now();
      _broadcastSimulationState(alarmFired: true);
      print(
        "DEBUG: About to call _triggerAlarmNotification with title='$title', body='$body'",
      );
      await _triggerAlarmNotification(
        service: service,
        title: title,
        body: body,
        allowContinueTracking: false,
      );
      print("DEBUG: _triggerAlarmNotification completed");
      // Start fast polling for alarm stop button responsiveness.
      _startAlarmStopPollTimer();
    } catch (e) {
      print("DEBUG: _triggerAlarmNotification exception: $e");
    }
    // Do not stop the service here.
    // The user may want to use notification actions (STOP_ALARM / END_TRACKING),
    // which are processed by the running tracking isolate.
  }
}

@pragma('vm:entry-point')
void _onStart(
  ServiceInstance service, {
  Map<String, dynamic>? initialData,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  _isBackgroundIsolate = true;
  // Initialize ETA engine
  await _etaEngine.loadState();
  print('DEBUG: Background isolate _onStart called');

  // Initialize NotificationService for the background isolate
  // This is critical - the notification plugin needs to be initialized
  // in each isolate that uses it, otherwise the Android Context is null
  try {
    print('DEBUG: Initializing NotificationService in background isolate...');
    await NotificationService().initialize();
    print('DEBUG: NotificationService initialized successfully in background');
  } catch (e) {
    print('DEBUG: NotificationService init failed in background: $e');
    dev.log(
      'NotificationService init failed in background isolate: $e',
      name: 'TrackingService',
    );
  }

  // --- REGISTER LISTENERS FIRST TO AVOID RACE CONDITIONS ---

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  service.on('startTracking').listen((data) {
    print('DEBUG: Background received startTracking event with data: $data');
    final requestId = data?['requestId'] as String?;
    if (requestId != null) {
      try {
        service.invoke('startTrackingAck', {'requestId': requestId});
      } catch (_) {}
    }
    if (data != null) {
      dev.log(
        'DEBUG: startTracking received - resetting alarm state',
        name: 'TrackingService',
      );
      dev.log(
        'DEBUG: Previous _destinationAlarmFired=$_destinationAlarmFired',
        name: 'TrackingService',
      );
      // Reset stale state from any prior session (important for subsequent runs).
      try {
        _registry.clear();
      } catch (_) {}
      _activeRouteInitialized = false;
      _routeEvents = const [];
      _stepBoundsMeters = const [];
      _stepStopsCumulative = const [];
      _firstTransitBoarding = null;
      _preBoardingAlertFired = false;
      _transitMode = false;
      _cachedRoutePayload = null;
      _lastRouteBroadcastAt = null;
      _destinationAlarmFired = false;
      _simulationPositionsReceived =
          false; // Reset simulation state for new session
      _firedEventIndexes.clear();
      dev.log(
        'DEBUG: After reset _destinationAlarmFired=$_destinationAlarmFired, _firedEventIndexes=${_firedEventIndexes.length}',
        name: 'TrackingService',
      );

      _destination = LatLng(data['destinationLat'], data['destinationLng']);
      _destinationName = data['destinationName'];
      _alarmMode = data['alarmMode'];
      _alarmValue = (data['alarmValue'] as num).toDouble();

      // Persist session-active flag for restore flows.
      try {
        TrackingStateStore.setActive(true);
        TrackingStateStore.setPaused(false);
        TrackingStateStore.setAlarmFired(false);
      } catch (_) {}

      // Ensure stop/time/event alarms have route context even if the
      // foreground->background route registration invoke is dropped.
      // HomeScreen persists directions into TrackingStateStore; restore from it here.
      unawaited(() async {
        try {
          final active = await TrackingStateStore.isActive();
          final paused = await TrackingStateStore.isPaused();
          if (!active || paused) return;

          final snapshot = await TrackingStateStore.loadSnapshot();
          if (snapshot?.directions == null) return;

          await TrackingService().registerRouteFromDirections(
            directions: snapshot!.directions!,
            origin: LatLng(snapshot.userLat, snapshot.userLng),
            destination: LatLng(
              snapshot.destinationLat,
              snapshot.destinationLng,
            ),
            transitMode: snapshot.metroMode,
            destinationName: snapshot.destinationName,
          );
          dev.log(
            'Background: Restored route from snapshot directions',
            name: 'TrackingService',
          );
        } catch (e) {
          dev.log(
            'Background: Failed to restore route from snapshot: $e',
            name: 'TrackingService',
          );
        }
      }());

      // If caller requested injected positions, enable before starting stream
      try {
        if (data['useInjectedPositions'] == true) {
          _useInjectedPositions = true;
          _injectedCtrl ??= StreamController<Position>.broadcast();
        }
      } catch (_) {}
      _destinationAlarmFired = false; // Reset flags for a new trip
      _firedEventIndexes.clear();
      // Reset time-alarm gating state
      _startedAt = DateTime.now();
      _startPosition = null;
      _distanceTravelledMeters = 0.0;
      _etaSamples = 0;
      _timeAlarmEligible = false;
      _preBoardingAlertFired = false;
      _smoothedETA = null; // Reset ETA
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
            subtitle: 'Starting…',
            progress0to1: 0.0,
            isTracking: true,
          );
        }
      } catch (_) {}

      // Ensure Simulation Client is connected (reconnect if needed)
      print(
        'DEBUG: Checking simulation client - exists=${_simulationClient != null}, active=${_simulationClient?.active}',
      );
      if (_simulationClient == null) {
        // IMPORTANT: If we stopped tracking previously, `_onStop()` clears `_simulationClient`.
        // Subsequent sessions must recreate the client WITH callbacks; otherwise
        // `_simulationPositionsReceived` never flips true and the location stream
        // never switches to dashboard-provided simulation positions.
        _simulationClient = SimulationClient(
          onConnected: () {
            dev.log(
              'SimulationClient connected; re-broadcasting cached route',
              name: 'TrackingService',
            );
            _maybeBroadcastCachedRoute(force: true);
          },
          onFirstPositionReceived: () {
            _simulationPositionsReceived = true;
            dev.log(
              'SimulationClient received first position from dashboard',
              name: 'TrackingService',
            );
            // Switch to simulation stream as soon as the dashboard starts sending.
            startLocationStream(service);
          },
        );
        _simulationClient!.onAlarmReset = _resetAlarmState;
      }
      if (!_simulationClient!.active) {
        print('DEBUG: Simulation client not active, connecting...');
        // Try to connect, but ensure we start the stream regardless of success/failure
        _simulationClient!
            .connect()
            .then((_) {
              print('DEBUG: Simulation connected in startTracking');
              dev.log(
                'Simulation connected in startTracking',
                name: 'TrackingService',
              );
            })
            .catchError((e) {
              print('DEBUG: Simulation connection failed in startTracking: $e');
              dev.log(
                'Simulation connection failed in startTracking: $e',
                name: 'TrackingService',
              );
            })
            .whenComplete(() {
              print(
                'DEBUG: Calling startLocationStream after simulation connect',
              );
              startLocationStream(service);
            });
      } else {
        print(
          'DEBUG: Simulation client already active, calling startLocationStream directly',
        );
        startLocationStream(service);
      }
    }
  });

  // Enable injected positions (used by demo)
  service.on('useInjectedPositions').listen((event) {
    _useInjectedPositions = true;
    _injectedCtrl ??= StreamController<Position>.broadcast();
  });
  // Inject a single position sample
  service.on('injectPosition').listen((data) {
    try {
      if (_injectedCtrl == null) {
        _injectedCtrl = StreamController<Position>.broadcast();
      }
      if (data == null) return;
      final p = Position(
        latitude: (data['latitude'] as num).toDouble(),
        longitude: (data['longitude'] as num).toDouble(),
        timestamp: DateTime.now(),
        accuracy: (data['accuracy'] as num?)?.toDouble() ?? 5.0,
        altitude: (data['altitude'] as num?)?.toDouble() ?? 0.0,
        altitudeAccuracy: (data['altitudeAccuracy'] as num?)?.toDouble() ?? 0.0,
        heading: (data['heading'] as num?)?.toDouble() ?? 0.0,
        headingAccuracy: (data['headingAccuracy'] as num?)?.toDouble() ?? 0.0,
        speed: (data['speed'] as num?)?.toDouble() ?? 12.0,
        speedAccuracy: (data['speedAccuracy'] as num?)?.toDouble() ?? 1.0,
      );
      _injectedCtrl!.add(p);
    } catch (_) {}
  });

  // Heartbeat mechanism: foreground sends heartbeats, background detects timeout
  service.on('foregroundHeartbeat').listen((data) {
    _lastForegroundHeartbeat = DateTime.now();
    dev.log('DEBUG: Received foreground heartbeat', name: 'TrackingService');
  });

  // Foreground resumed: reset heartbeat state and cancel any pending pause
  service.on('foregroundResumed').listen((data) async {
    dev.log(
      'DEBUG: Foreground resumed notification received',
      name: 'TrackingService',
    );
    _lastForegroundHeartbeat = DateTime.now();

    // Restart heartbeat monitoring if it was stopped
    if (_heartbeatCheckTimer == null) {
      _startHeartbeatMonitoring(service);
    }

    // If we were paused due to timeout, resume tracking
    try {
      final isPaused = await TrackingStateStore.isPaused();
      if (isPaused) {
        dev.log('DEBUG: Resuming from paused state', name: 'TrackingService');
        await TrackingStateStore.setPaused(false);
        await NotificationService().cancelTrackingPaused();
        // Restore journey progress notification
        final snapshot = await TrackingStateStore.loadSnapshot();
        if (snapshot != null) {
          await NotificationService().showJourneyProgress(
            title: 'Journey to ${snapshot.destinationName}',
            subtitle: 'Tracking resumed',
            progress0to1: 0,
            isTracking: true,
          );
        }
      }
    } catch (e) {
      dev.log(
        'DEBUG: Error handling foreground resumed: $e',
        name: 'TrackingService',
      );
    }
  });

  service.on("stopTracking").listen((event) async {
    // Make sure to stop the alarm explicitly first
    try {
      await AlarmPlayer.stop();
    } catch (e) {
      dev.log(
        'Error stopping alarm during tracking stop: $e',
        name: 'TrackingService',
      );
    }

    // Then stop all tracking
    _onStop();

    if (event?['stopSelf'] == true) {
      service.stopSelf();
    }
  });

  service.on('stopAlarm').listen((event) async {
    dev.log(
      'Received stopAlarm event in background service',
      name: 'TrackingService',
    );
    // Cancel fast poll timer since alarm is being stopped.
    _cancelAlarmStopPollTimer();
    try {
      await NotificationService().cancelAlarm();
      await NotificationService().restoreJourneyProgressIfActive();
    } catch (e) {
      dev.log('Error stopping alarm: $e', name: 'TrackingService');
    }
  });

  // Handle route registration from foreground
  service.on('registerRoute').listen((data) {
    if (data != null) {
      try {
        final requestId = data['requestId'] as String?;
        final key = data['key'] as String;
        final mode = data['mode'] as String;
        final destinationName = data['destinationName'] as String;
        final pointsJson = data['points'] as List;
        final points =
            pointsJson.map((p) => LatLng(p['lat'], p['lng'])).toList();

        // Safely cast segments and switchPoints
        List<Map<String, dynamic>>? segments;
        if (data['segments'] != null) {
          segments =
              (data['segments'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        }

        List<Map<String, dynamic>>? switchPoints;
        if (data['switch_points'] != null) {
          switchPoints =
              (data['switch_points'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        }

        List<Map<String, dynamic>>? events;
        if (data['events'] != null) {
          events =
              (data['events'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        }

        dev.log(
          'CRITICAL: Background: Received registerRoute for $key',
          name: 'TrackingService',
        );
        dev.log(
          'CRITICAL: Background: Segments: ${segments?.length}',
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
        );

        if (requestId != null) {
          service.invoke('registerRouteAck', {'requestId': requestId});
        }
      } catch (e) {
        dev.log(
          'CRITICAL: Background: Error in registerRoute listener: $e',
          name: 'TrackingService',
        );
      }
    }
  });

  // Handle full Directions-based registration from foreground.
  // This avoids losing route events/step bounds that are needed for stops/time alarms.
  service.on('registerRouteDirections').listen((data) async {
    if (data == null) return;
    try {
      final requestId = data['requestId'] as String?;
      final directions = Map<String, dynamic>.from(data['directions'] as Map);
      final originMap = Map<String, dynamic>.from(data['origin'] as Map);
      final destMap = Map<String, dynamic>.from(data['destination'] as Map);
      final origin = LatLng(
        (originMap['lat'] as num).toDouble(),
        (originMap['lng'] as num).toDouble(),
      );
      final destination = LatLng(
        (destMap['lat'] as num).toDouble(),
        (destMap['lng'] as num).toDouble(),
      );
      final transitMode = (data['transitMode'] as bool?) ?? false;
      final destinationName = data['destinationName'] as String?;

      await TrackingService().registerRouteFromDirections(
        directions: directions,
        origin: origin,
        destination: destination,
        transitMode: transitMode,
        destinationName: destinationName,
      );

      if (requestId != null) {
        service.invoke('registerRouteDirectionsAck', {'requestId': requestId});
      }
    } catch (e) {
      dev.log(
        'CRITICAL: Background: Error in registerRouteDirections listener: $e',
        name: 'TrackingService',
      );
    }
  });

  // --- INITIALIZATION AFTER LISTENERS ARE SET ---

  try {
    await NotificationService().initialize();
  } catch (_) {}

  // Initialize Simulation Client (Debug only)
  _simulationClient = SimulationClient(
    onConnected: () {
      dev.log(
        'SimulationClient connected; re-broadcasting cached route',
        name: 'TrackingService',
      );
      _maybeBroadcastCachedRoute(force: true);
    },
    onFirstPositionReceived: () {
      // Dashboard has started sending positions - enable simulation stream.
      _simulationPositionsReceived = true;
      dev.log(
        'SimulationClient received first position from dashboard',
        name: 'TrackingService',
      );
      // CRITICAL: Restart the location stream so it switches to simulation stream.
      // Without this, the stream selection is made only once at startup, and if
      // _simulationPositionsReceived was false at that time (because dashboard
      // hadn't sent positions yet), the app would keep using Geolocator stream
      // and ignore dashboard positions entirely - breaking dashboard alarms.
      startLocationStream(service);
    },
  );
  // Set up alarm reset callback for dashboard control
  _simulationClient!.onAlarmReset = _resetAlarmState;
  // Uses PlaygroundBridgeConfig.relayUrl (default ws://127.0.0.1:8081).
  // For Android devices/emulators, this typically requires: adb reverse tcp:8081 tcp:8081
  // This await might take time, but listeners are already active.
  try {
    await _simulationClient!.connect();
  } catch (e) {
    dev.log(
      'CRITICAL: Background: Failed to connect to simulation: $e',
      name: 'TrackingService',
    );
  }

  // Handle data passed directly (for test mode)
  if (initialData != null) {
    _destination = LatLng(
      initialData['destinationLat'],
      initialData['destinationLng'],
    );
    _destinationName = initialData['destinationName'];
    _alarmMode = initialData['alarmMode'];
    _alarmValue = (initialData['alarmValue'] as num).toDouble();
    try {
      if (initialData['useInjectedPositions'] == true) {
        _useInjectedPositions = true;
        _injectedCtrl ??= StreamController<Position>.broadcast();
      }
    } catch (_) {}
    _destinationAlarmFired = false;
    _firedEventIndexes.clear();
    // Reset time-alarm gating state
    _startedAt = DateTime.now();
    _startPosition = null;
    _distanceTravelledMeters = 0.0;
    _etaSamples = 0;
    _timeAlarmEligible = false;
    _preBoardingAlertFired = false;
    startLocationStream(service);
    // Start fast polling for notification action buttons (Stop Alarm, Ignore, End Tracking)
    _startAlarmStopPollTimer();
  }
}

/// Start the heartbeat check timer that detects when foreground is gone.
/// This should be called when tracking starts in the background isolate.
void _startHeartbeatMonitoring(ServiceInstance service) {
  // Don't run heartbeat monitoring in test mode or if not in background isolate
  if (!_isBackgroundIsolate || TrackingService.isTestMode) return;
  _lastForegroundHeartbeat = DateTime.now();
  _heartbeatCheckTimer?.cancel();
  _heartbeatCheckTimer = Timer.periodic(_heartbeatCheckInterval, (_) async {
    if (_lastForegroundHeartbeat == null) return;

    final elapsed = DateTime.now().difference(_lastForegroundHeartbeat!);
    if (elapsed > _heartbeatTimeout) {
      // Foreground app is gone (swiped away or killed)
      dev.log(
        'DEBUG: Heartbeat timeout - foreground gone for ${elapsed.inSeconds}s',
        name: 'TrackingService',
      );

      try {
        final active = await TrackingStateStore.isActive();
        final alreadyPaused = await TrackingStateStore.isPaused();

        if (!active || alreadyPaused) {
          dev.log(
            'DEBUG: Not showing pause - active=$active, paused=$alreadyPaused',
            name: 'TrackingService',
          );
          return;
        }

        dev.log(
          'DEBUG: Showing tracking paused notification (heartbeat timeout)',
          name: 'TrackingService',
        );

        await TrackingStateStore.setPaused(true);
        final snapshot = await TrackingStateStore.loadSnapshot();
        await NotificationService().cancelJourneyProgress();
        await NotificationService().showTrackingPaused(
          destinationName: snapshot?.destinationName,
        );

        // Stop heartbeat monitoring since we're now in paused state
        _heartbeatCheckTimer?.cancel();
        _heartbeatCheckTimer = null;
      } catch (e) {
        dev.log(
          'DEBUG: Error handling heartbeat timeout: $e',
          name: 'TrackingService',
        );
      }
    }
  });
}

/// Stop heartbeat monitoring (call when tracking stops).
void _stopHeartbeatMonitoring() {
  _heartbeatCheckTimer?.cancel();
  _heartbeatCheckTimer = null;
  _lastForegroundHeartbeat = null;
}

Future<void> startLocationStream(ServiceInstance service) async {
  // Start heartbeat monitoring to detect when foreground is swiped away
  _startHeartbeatMonitoring(service);

  if (_positionSubscription != null) {
    await _positionSubscription!.cancel();
  }
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
    } catch (_) {}
  }

  LocationSettings settings = LocationSettings(
    accuracy: policy.accuracy,
    distanceFilter: policy.distanceFilterMeters,
  );

  Stream<Position> stream;
  String streamType = 'unknown';
  // Only use simulation stream if dashboard has sent at least one position.
  // Just being connected is not enough - the connection is mainly for broadcasting
  // app state to the dashboard, not for receiving positions.
  if (_simulationClient != null &&
      _simulationClient!.active &&
      _simulationPositionsReceived) {
    print('DEBUG: Using Simulation Stream');
    stream = _simulationClient!.positionStream;
    streamType = 'simulation';
  } else if (_useInjectedPositions && _injectedCtrl != null) {
    stream = _injectedCtrl!.stream;
    streamType = 'injected';
  } else {
    stream =
        testGpsStream ??
        Geolocator.getPositionStream(locationSettings: settings);
    streamType = testGpsStream != null ? 'testGps' : 'geolocator';
  }
  print(
    'DEBUG: startLocationStream - using stream type: $streamType, simulationClient=${_simulationClient != null}, simulationActive=${_simulationClient?.active}, simPosReceived=$_simulationPositionsReceived',
  );

  _positionSubscription = stream.listen((Position position) {
    print(
      'DEBUG: Position received in stream listener: (${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)})',
    );
    _lastGpsUpdate = DateTime.now();
    _lastProcessedPosition = LatLng(position.latitude, position.longitude);
    // Track movement distance since start for time-alarm eligibility
    try {
      if (_startedAt == null) {
        _startedAt = DateTime.now();
      }
      if (_startPosition == null) {
        _startPosition = _lastProcessedPosition;
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

    if (_fusionActive) {
      _sensorFusionManager?.stopFusion();
      _fusionActive = false;
    }

    // Simplified ETA calculation
    if (_destination != null) {
      double distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        _destination!.latitude,
        _destination!.longitude,
      );

      // Use efficient EtaEngine for time-to-arrival
      List<LatLng>? routeCoords;
      if (_lastActiveState != null && _registry.entries.isNotEmpty) {
        try {
          final entry = _registry.entries.firstWhere(
            (e) => e.key == _lastActiveState!.activeKey,
          );
          routeCoords = entry.points;
        } catch (_) {}
      }
      if (routeCoords == null && _registry.entries.isNotEmpty) {
        routeCoords = _registry.entries.first.points;
      }

      if (routeCoords != null && routeCoords.isNotEmpty) {
        final result = _etaEngine.computeEta(
          routeCoords: routeCoords,
          gps: position,
        );
        _smoothedETA = result.etaSeconds;
      } else {
        // Fallback if no route known
        double speed = position.speed > 1 ? position.speed : 12.0;
        _smoothedETA = distance / speed;
      }

      // Count ETA samples only when speed shows credible movement
      if (position.speed.isFinite && position.speed >= 0.5) {
        _etaSamples++;
      }
    }

    // Ingest into active route manager and deviation pipeline if present
    _lastSpeedMps = position.speed;
    if (_activeManager != null) {
      final raw = LatLng(position.latitude, position.longitude);
      _activeManager!.ingestPosition(raw);
    }

    // --- CHECK THE ALARM CONDITION ON EVERY UPDATE ---
    // ignore: discarded_futures
    _checkAndTriggerAlarm(position, service);

    service.invoke("updateLocation", {
      "latitude": position.latitude,
      "longitude": position.longitude,
      "eta": _smoothedETA,
    });
  });
  // Start GPS dropout checker to enable sensor fusion when GPS is silent.
  _gpsCheckTimer?.cancel();
  final Duration checkPeriod =
      TrackingService.isTestMode
          ? policy.notificationTick
          : policy.notificationTick;
  _gpsCheckTimer = Timer.periodic(checkPeriod, (_) {
    // Handle notification action requests persisted from background callbacks.
    // These callbacks may fire when the UI isolate is dead; the running
    // tracking isolate is the reliable place to execute the action.
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
            service.stopSelf();
          } catch (_) {}
          return;
        }
      } catch (_) {}
    }();

    final last = _lastGpsUpdate;
    if (last == null) return;
    final silentFor = DateTime.now().difference(last);
    if (silentFor >= gpsDropoutBuffer) {
      if (!_fusionActive && _lastProcessedPosition != null) {
        _sensorFusionManager = SensorFusionManager(
          initialPosition: _lastProcessedPosition!,
          accelerometerStream: testAccelerometerStream,
        );
        _sensorFusionManager!.startFusion();
        _fusionActive = true;
      }
    }

    // Regularly force notification updates even without state changes
    _updateNotification(service);

    // Broadcast state to simulation dashboard
    _broadcastSimulationState(
      debugInfo: {
        'destination': _destinationName,
        'is_alarm_fired': _destinationAlarmFired,
      },
    );

    // Re-broadcast route periodically (dashboard may reconnect after initial send)
    _maybeBroadcastCachedRoute();

    // Evaluate time-alarm eligibility periodically
    try {
      if (_alarmMode == 'time' && !_timeAlarmEligible) {
        final sinceStart =
            _startedAt != null
                ? DateTime.now().difference(_startedAt!)
                : Duration.zero;
        // Eligible after: moved >= 100m AND at least 3 ETA samples with speed >=0.5 m/s AND 30s since start
        if (_distanceTravelledMeters >= 100.0 &&
            _etaSamples >= 3 &&
            sinceStart.inSeconds >= 30) {
          _timeAlarmEligible = true;
          dev.log('Time alarm is now eligible', name: 'TrackingService');
        }
      }
    } catch (_) {}
  });
}

// Helper method to update notification based on current state
void _updateNotification(ServiceInstance service) {
  try {
    if (TrackingService.isTestMode || _destination == null) return;

    // Get latest state from active manager if available
    if (_activeManager != null && _registry.entries.isNotEmpty) {
      // We can't directly access the active key from the manager,
      // but we have some options to find it:
      RouteEntry? entry;

      try {
        // Find the most recently used route or one with the best progress data
        if (_registry.entries.isNotEmpty) {
          RouteEntry? bestEntry;
          for (final e in _registry.entries) {
            if (e.lastProgressMeters != null) {
              if (bestEntry == null || e.lastUsed.isAfter(bestEntry.lastUsed)) {
                bestEntry = e;
              }
            }
          }

          // If we found a route with progress data, use it
          if (bestEntry != null) {
            entry = bestEntry;
          } else {
            // Otherwise use the first one
            entry = _registry.entries.first;
          }
        }
      } catch (_) {
        // Fallback to first entry if any error occurs
        if (_registry.entries.isNotEmpty) {
          entry = _registry.entries.first;
        }
      }

      if (entry != null) {
        final total = entry.lengthMeters;
        final progressMeters = entry.lastProgressMeters ?? 0.0;
        final progress =
            total > 0 ? (progressMeters / total).clamp(0.0, 1.0) : 0.0;
        final remainingMeters = total - progressMeters;

        // Create progress notification
        final progressPercent = (progress * 100)
            .clamp(0.0, 100.0)
            .toStringAsFixed(1);
        final remainingKm = (remainingMeters / 1000.0).toStringAsFixed(1);

        dev.log(
          'Forced notification update: $progressPercent% | remaining $remainingKm km',
          name: 'TrackingService',
        );

        NotificationService().showJourneyProgress(
          title:
              _destinationName != null
                  ? 'Journey to $_destinationName'
                  : 'GeoWake journey',
          subtitle: 'Remaining: $remainingKm km',
          progress0to1: progress,
        );

        return;
      }
    }

    // Fallback if no active route: use straight-line distance
    if (_lastProcessedPosition != null && _destination != null) {
      final distanceInMeters = Geolocator.distanceBetween(
        _lastProcessedPosition!.latitude,
        _lastProcessedPosition!.longitude,
        _destination!.latitude,
        _destination!.longitude,
      );

      // Create a simple progress notification
      final remainingKm = (distanceInMeters / 1000.0).toStringAsFixed(1);
      dev.log(
        'Simple notification update: remaining $remainingKm km',
        name: 'TrackingService',
      );

      NotificationService().showJourneyProgress(
        title:
            _destinationName != null
                ? 'Journey to $_destinationName'
                : 'GeoWake journey',
        subtitle: 'Remaining: $remainingKm km',
        progress0to1: 0.0, // We don't know total journey distance in this case
      );
    }
  } catch (e) {
    dev.log('Error updating notification: $e', name: 'TrackingService');
  }
}

// No top-level testing getters; use instance getters on TrackingService.

extension TrackingServiceRouteOps on TrackingService {
  List<double> _buildCumulativeStops(
    List<double> bounds,
    List<double> rawStops,
  ) {
    if (bounds.isEmpty || rawStops.isEmpty) {
      return List<double>.from(rawStops);
    }
    final len =
        bounds.length < rawStops.length ? bounds.length : rawStops.length;
    double running = 0.0;
    double prevBound = 0.0;
    final result = <double>[];
    for (int i = 0; i < len; i++) {
      final bound = bounds[i];
      final provided = rawStops[i];
      final segLen = (bound - prevBound).abs();
      if (provided >= running) {
        // Trust provided cumulative stops when non-decreasing
        running = provided;
      } else {
        // Fallback spacing when provided regresses
        running += segLen > 0 ? segLen / _kDefaultStopSpacingMeters : 0.0;
      }
      result.add(running);
      prevBound = bound;
    }
    for (int i = len; i < bounds.length; i++) {
      final segLen = (bounds[i] - prevBound).abs();
      final delta = segLen > 0 ? segLen / _kDefaultStopSpacingMeters : 0.0;
      running += delta;
      result.add(running);
      prevBound = bounds[i];
    }
    return result;
  }

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
  }) async {
    final mutableEvents = List<RouteEventBoundary>.from(routeEvents);
    if (mutableEvents.isEmpty || mutableEvents.last.type != 'destination') {
      mutableEvents.add(
        RouteEventBoundary(
          meters: stepBounds.isNotEmpty ? stepBounds.last : 0.0,
          type: 'destination',
          label: destinationName,
          lat: points.isNotEmpty ? points.last.latitude : null,
          lng: points.isNotEmpty ? points.last.longitude : null,
        ),
      );
    }

    _routeEvents = mutableEvents;
    _stepBoundsMeters = stepBounds;
    _stepStopsCumulative = _buildCumulativeStops(stepBounds, stepStops);
    _transitMode = transitMode;
    if (transitMode) {
      if (firstTransitBoarding != null) {
        _firstTransitBoarding = firstTransitBoarding;
      } else {
        LatLng? boarding;
        try {
          final ev = mutableEvents.firstWhere(
            (e) => e.type == 'boarding',
            orElse: () => mutableEvents.first,
          );
          if (ev.lat != null && ev.lng != null) {
            boarding = LatLng(ev.lat!, ev.lng!);
          }
        } catch (_) {}
        boarding ??=
            points.length > 1
                ? points[1]
                : (points.isNotEmpty ? points.first : null);
        _firstTransitBoarding = boarding;
      }
      _preBoardingAlertFired = false;
    } else {
      _firstTransitBoarding = null;
      _preBoardingAlertFired = false;
    }

    final entry = RouteEntry(
      key: key,
      mode: transitMode ? 'transit' : 'driving',
      destinationName: destinationName,
      points: points,
    );
    _registry.upsert(entry);

    _activeManager?.dispose();
    _activeManager = ActiveRouteManager(registry: _registry);
    _activeManager!.setActive(key);

    _mgrStateSub?.cancel();
    _mgrStateSub = _activeManager!.stateStream.listen((state) {
      _lastActiveState = state;
      _routeStateCtrl.add(state);
    });

    if (points.isNotEmpty) {
      _activeManager!.ingestPosition(points.first);
    }
  }

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
  }) {
    _cachedRoutePayload = {
      'destinationName': destinationName,
      'points':
          points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
      if (segments != null) 'segments': segments,
      if (switchPoints != null) 'switch_points': switchPoints,
      if (events != null) 'events': events,
    };

    final entry = RouteEntry(
      key: key,
      mode: mode,
      destinationName: destinationName,
      points: points,
    );
    _registry.upsert(entry);

    // Broadcast route to simulation dashboard if active (Background)
    if (_simulationClient != null && _simulationClient!.active) {
      _lastRouteBroadcastAt = DateTime.now();
      dev.log(
        'Broadcasting route to dashboard: $destinationName (${points.length} points)',
        name: 'TrackingService',
      );
      _simulationClient!.broadcastRoute(
        destinationName: destinationName,
        points:
            points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
        segments: segments,
        switchPoints: switchPoints,
        events: events,
      );
    } else if (_simulationClient != null && !_simulationClient!.active) {
      // Try to reconnect so we can broadcast shortly after.
      dev.log(
        'SimulationClient not active, attempting reconnect for route broadcast',
        name: 'TrackingService',
      );
      try {
        _simulationClient!.connect();
      } catch (_) {}
    } else if (!_isBackgroundIsolate) {
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
          },
        ),
      );
    }

    // Initialize manager and pipelines if not exists
    _activeManager ??= ActiveRouteManager(
      registry: _registry,
      sustainDuration:
          TrackingService.isTestMode
              ? const Duration(milliseconds: 300)
              : const Duration(seconds: 6),
      switchMarginMeters: TrackingService.isTestMode ? 20 : 50,
      postSwitchBlackout:
          TrackingService.isTestMode
              ? const Duration(milliseconds: 300)
              : const Duration(seconds: 5),
    );
    _devMonitor ??= DeviationMonitor(
      sustainDuration:
          TrackingService.isTestMode
              ? const Duration(milliseconds: 300)
              : const Duration(seconds: 5),
    );
    // Cooldown from power policy will be applied in startLocationStream after battery read
    _reroutePolicy ??= ReroutePolicy(
      cooldown:
          TrackingService.isTestMode
              ? const Duration(seconds: 2)
              : const Duration(seconds: 20),
      initialOnline: true,
    );
    _offlineCoordinator ??= OfflineCoordinator(initialOffline: false);

    // Set this route as active if none
    if (!_activeRouteInitialized) {
      _activeManager!.setActive(key);
      _activeRouteInitialized = true;
    }

    // Bridge streams once
    _mgrStateSub ??= _activeManager!.stateStream.listen((s) {
      _routeStateCtrl.add(s);
      final spd = _lastSpeedMps ?? 0.0;
      double offForDeviation = s.offsetMeters;
      try {
        if (_lastProcessedPosition != null) {
          final entry = _registry.entries.firstWhere(
            (e) => e.key == s.activeKey,
            orElse: () => _registry.entries.first,
          );
          final snap = SnapToRouteEngine.snap(
            point: _lastProcessedPosition!,
            polyline: entry.points,
            hintIndex: entry.lastSnapIndex,
          );
          offForDeviation = snap.lateralOffsetMeters;
        }
      } catch (_) {}
      _devMonitor?.ingest(offsetMeters: offForDeviation, speedMps: spd);
      _lastActiveState = s;
      // Update route state in memory but let the timer handle notification updates
      // to prevent excessive notification updates that might get dropped
    });
    _mgrSwitchSub ??= _activeManager!.switchStream.listen((e) {
      _routeSwitchCtrl.add(e);
    });
    _devSub ??= _devMonitor!.stream.listen((ds) async {
      double off = _lastActiveState?.offsetMeters ?? double.infinity;
      try {
        if (_lastProcessedPosition != null &&
            _lastActiveState?.activeKey != null) {
          final entry = _registry.entries.firstWhere(
            (e) => e.key == _lastActiveState!.activeKey,
            orElse: () => _registry.entries.first,
          );
          final snap = SnapToRouteEngine.snap(
            point: _lastProcessedPosition!,
            polyline: entry.points,
            hintIndex: entry.lastSnapIndex,
          );
          off = snap.lateralOffsetMeters;
        }
      } catch (_) {}

      // In tests, allow immediate local switch in the 100ΓÇô150m band without waiting for sustain
      if (!ds.sustained) {
        if (off >= 100.0 && off <= 150.0) {
          try {
            if (_lastProcessedPosition != null &&
                _registry.entries.isNotEmpty) {
              double bestOffset = off;
              RouteEntry? best;
              for (final e in _registry.entries) {
                final snap = SnapToRouteEngine.snap(
                  point: _lastProcessedPosition!,
                  polyline: e.points,
                  hintIndex: e.lastSnapIndex,
                );
                if (snap.lateralOffsetMeters + 1e-6 < bestOffset) {
                  bestOffset = snap.lateralOffsetMeters;
                  best = e;
                }
              }
              final margin = TrackingService.isTestMode ? 20.0 : 50.0;
              if (best != null && (off - bestOffset) >= margin) {
                final fromKey = _lastActiveState?.activeKey ?? 'unknown';
                _activeManager?.setActive(best.key);
                _routeSwitchCtrl.add(
                  RouteSwitchEvent(
                    fromKey: fromKey,
                    toKey: best.key,
                    at: DateTime.now(),
                  ),
                );
                return;
              }
            }
          } catch (_) {}
        }
        // Not sustained and not in immediate switch band
        return;
      }

      // Sustained deviation handling
      if (off < 100.0) {
        // Ignore minor noise; do not reroute
        return;
      }
      if (off <= 150.0) {
        // Prefer local switch to a better registered route; avoid network reroute
        try {
          if (_lastProcessedPosition != null && _registry.entries.isNotEmpty) {
            double bestOffset = off;
            RouteEntry? best;
            for (final e in _registry.entries) {
              final snap = SnapToRouteEngine.snap(
                point: _lastProcessedPosition!,
                polyline: e.points,
                hintIndex: e.lastSnapIndex,
              );
              if (snap.lateralOffsetMeters + 1e-6 < bestOffset) {
                bestOffset = snap.lateralOffsetMeters;
                best = e;
              }
            }
            final margin = TrackingService.isTestMode ? 20.0 : 50.0;
            if (best != null && (off - bestOffset) >= margin) {
              final fromKey = _lastActiveState?.activeKey ?? 'unknown';
              _activeManager?.setActive(best.key);
              _routeSwitchCtrl.add(
                RouteSwitchEvent(
                  fromKey: fromKey,
                  toKey: best.key,
                  at: DateTime.now(),
                ),
              );
            }
          }
        } catch (_) {}
        return; // Do not trigger reroute
      }
      // >150m: allow reroute policy to decide (subject to cooldown/online)
      _reroutePolicy?.onSustainedDeviation(at: ds.at);
    });
    _rerouteSub ??= _reroutePolicy!.stream.listen((r) async {
      if (r.shouldReroute) {
        dev.log('Reroute triggered by policy', name: 'TrackingService');
        if (TrackingService.isTestMode) {
          _rerouteCtrl.add(r);
          return; // avoid network in tests
        }
        if (_rerouteInFlight) {
          _rerouteCtrl.add(r);
          return;
        }
        _rerouteInFlight = true;
        try {
          final origin = _lastProcessedPosition;
          if (origin == null ||
              _destination == null ||
              _offlineCoordinator == null) {
            return;
          }
          final res = await _offlineCoordinator!.getRoute(
            origin: origin,
            destination: _destination!,
            isDistanceMode: _alarmMode == 'distance',
            threshold: _alarmValue ?? 0,
            transitMode: _transitMode,
            forceRefresh: false,
          );
          registerRouteFromDirections(
            directions: res.directions,
            origin: origin,
            destination: _destination!,
            transitMode: _transitMode,
            destinationName: _destinationName,
          );
          dev.log(
            'Reroute registered from ${res.source}',
            name: 'TrackingService',
          );
        } catch (e) {
          dev.log('Reroute fetch failed: $e', name: 'TrackingService');
        } finally {
          _rerouteInFlight = false;
        }
      }
      _rerouteCtrl.add(r);
    });
  }

  // Convenience: register from a Directions response
  Future<void> registerRouteFromDirections({
    required Map<String, dynamic> directions,
    required LatLng origin,
    required LatLng destination,
    required bool transitMode,
    String? destinationName,
  }) async {
    // If called from the foreground isolate, forward the full Directions payload
    // to the background service so alarms (stops/time) have access to step bounds/events.
    // IMPORTANT: don't use SimulationClient connectivity as a proxy for isolate context.
    // During background startup the client may not be initialized/connected yet.
    if (!_isBackgroundIsolate) {
      final ok = await _invokeWithAckRetry(
        method: 'registerRouteDirections',
        ackEvent: 'registerRouteDirectionsAck',
        args: {
          'directions': directions,
          'origin': {'lat': origin.latitude, 'lng': origin.longitude},
          'destination': {
            'lat': destination.latitude,
            'lng': destination.longitude,
          },
          'transitMode': transitMode,
          'destinationName': destinationName,
        },
      );
      if (ok) return;
      // If invoke/ack fails, fall through to best-effort local computation.
    }

    // Reset alarm state for new route registration.
    // This ensures alarms fire again when a new route is loaded (e.g., from dashboard).
    dev.log(
      'DEBUG: registerRouteFromDirections - resetting alarm state for new route',
      name: 'TrackingService',
    );
    _destinationAlarmFired = false;
    _firedEventIndexes.clear();
    _preBoardingAlertFired = false;

    final mode = transitMode ? 'transit' : 'driving';
    _transitMode = transitMode;
    final key = RouteCache.makeKey(
      origin: origin,
      destination: destination,
      mode: mode,
      transitVariant: transitMode ? 'rail' : null,
    );
    // Extract polyline points
    List<LatLng> points = [];
    try {
      final route =
          (directions['routes'] as List).first as Map<String, dynamic>;
      final scp = route['simplified_polyline'] as String?;
      if (scp != null) {
        points = PolylineSimplifier.decompressPolyline(scp);
      } else if (route['overview_polyline'] != null &&
          route['overview_polyline']['points'] != null) {
        points = decodePolyline(route['overview_polyline']['points'] as String);
      }
    } catch (_) {}
    // Build step bounds and stops
    try {
      final m = TransferUtils.buildStepBoundariesAndStops(directions);
      _stepBoundsMeters = m.bounds;
      _stepStopsCumulative = _buildCumulativeStops(m.bounds, m.stops);
    } catch (_) {
      _stepBoundsMeters = const [];
      _stepStopsCumulative = const [];
    }
    // Fallback to straight line between origin/destination if no points decoded
    if (points.isEmpty) {
      points = [origin, destination];
    }
    // Build event boundaries and keep in memory
    try {
      _routeEvents = TransferUtils.buildRouteEvents(directions);
    } catch (_) {
      _routeEvents = const [];
    }
    // Compute first transit boarding meters and location for pre-boarding alert
    try {
      LatLng? boarding;
      final routes = (directions['routes'] as List?) ?? const [];
      if (routes.isNotEmpty) {
        final route = routes.first as Map<String, dynamic>;
        final legs = (route['legs'] as List?) ?? const [];
        outer:
        for (final leg in legs) {
          final steps = (leg['steps'] as List?) ?? const [];
          for (final s in steps) {
            final step = s as Map<String, dynamic>;
            // read-only
            if (step['travel_mode'] == 'TRANSIT') {
              // Try departure_stop location
              try {
                final dep =
                    (step['transit_details']
                            as Map<String, dynamic>?)?['departure_stop']
                        as Map<String, dynamic>?;
                final loc =
                    dep != null
                        ? dep['location'] as Map<String, dynamic>?
                        : null;
                if (loc != null) {
                  final lat = (loc['lat'] as num?)?.toDouble();
                  final lng = (loc['lng'] as num?)?.toDouble();
                  if (lat != null && lng != null) {
                    boarding = LatLng(lat, lng);
                  }
                }
              } catch (_) {}
              // Fallback to first point of step polyline
              if (boarding == null) {
                try {
                  final pts = decodePolyline(
                    (step['polyline'] as Map<String, dynamic>)['points']
                        as String,
                  );
                  if (pts.isNotEmpty) boarding = pts.first;
                } catch (_) {}
              }
              break outer;
            }
            // ignore step distance here
          }
        }
      }
      _firstTransitBoarding = boarding;
      dev.log(
        'Computed first transit boarding: $_firstTransitBoarding',
        name: 'TrackingService',
      );
      _preBoardingAlertFired = false;
    } catch (_) {
      _firstTransitBoarding = null;
      _preBoardingAlertFired = false;
    }

    if (_firstTransitBoarding == null && _routeEvents.isNotEmpty) {
      try {
        final ev = _routeEvents.firstWhere(
          (e) => e.type == 'boarding' || e.type == 'transfer',
        );
        if (ev.lat != null && ev.lng != null) {
          _firstTransitBoarding = LatLng(ev.lat!, ev.lng!);
        }
      } catch (_) {}
    }
    if (_firstTransitBoarding == null && points.length > 1) {
      _firstTransitBoarding = points[1];
    }

    // Extract Segments and Switch Points for Visualization
    List<Map<String, dynamic>> segments = [];
    List<Map<String, dynamic>> switchPoints = [];
    final List<LatLng> pointsFromSegments = <LatLng>[];
    try {
      final routes = (directions['routes'] as List?) ?? const [];
      dev.log(
        'CRITICAL: Extracting segments from ${routes.length} routes',
        name: 'TrackingService',
      );
      if (routes.isNotEmpty) {
        final route = routes.first as Map<String, dynamic>;
        final legs = (route['legs'] as List?) ?? const [];
        for (final leg in legs) {
          final steps = (leg['steps'] as List?) ?? const [];
          dev.log('Processing ${steps.length} steps', name: 'TrackingService');
          for (final s in steps) {
            final step = s as Map<String, dynamic>;
            final stepMode =
                (step['travel_mode'] as String?)?.toLowerCase() ?? 'walking';

            String? transitLine;
            if (stepMode == 'transit') {
              try {
                final td = step['transit_details'] as Map<String, dynamic>?;
                final line = td?['line'] as Map<String, dynamic>?;
                final shortName = line?['short_name'];
                final name = line?['name'];
                if (shortName is String && shortName.trim().isNotEmpty) {
                  transitLine = shortName.trim();
                } else if (name is String && name.trim().isNotEmpty) {
                  transitLine = name.trim();
                }
              } catch (_) {}
            }

            // Decode polyline for this step
            List<LatLng> stepPoints = [];
            try {
              final poly = step['polyline'] as Map<String, dynamic>;
              stepPoints = decodePolyline(poly['points'] as String);
            } catch (_) {}

            // Build a contiguous route polyline from step geometry to match
            // what MapTracking displays.
            if (stepPoints.isNotEmpty) {
              if (pointsFromSegments.isEmpty) {
                pointsFromSegments.addAll(stepPoints);
              } else {
                final last = pointsFromSegments.last;
                final first = stepPoints.first;
                final same =
                    (last.latitude - first.latitude).abs() < 1e-10 &&
                    (last.longitude - first.longitude).abs() < 1e-10;
                if (same) {
                  pointsFromSegments.addAll(stepPoints.skip(1));
                } else {
                  pointsFromSegments.addAll(stepPoints);
                }
              }
            }

            final seg = <String, dynamic>{
              'mode': stepMode,
              'points':
                  stepPoints
                      .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                      .toList(),
              'instruction': step['html_instructions'] ?? '',
            };
            if (transitLine != null) {
              seg['transit_line'] = transitLine;
            }
            segments.add(seg);
            dev.log(
              'Added segment: $stepMode with ${stepPoints.length} points',
              name: 'TrackingService',
            );

            if (stepMode == 'transit') {
              try {
                final dep =
                    (step['transit_details'] as Map?)?['departure_stop']
                        as Map?;
                if (dep != null) {
                  final loc = dep['location'] as Map?;
                  if (loc != null) {
                    switchPoints.add({
                      'lat': loc['lat'],
                      'lng': loc['lng'],
                      'type': 'boarding',
                      'label': dep['name'] ?? 'Boarding',
                    });
                  }
                }
                final arr =
                    (step['transit_details'] as Map?)?['arrival_stop'] as Map?;
                if (arr != null) {
                  final loc = arr['location'] as Map?;
                  if (loc != null) {
                    switchPoints.add({
                      'lat': loc['lat'],
                      'lng': loc['lng'],
                      'type': 'alighting',
                      'label': arr['name'] ?? 'Alighting',
                    });
                  }
                }
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}

    // Prefer step-derived points for exact visual match; fall back otherwise.
    if (pointsFromSegments.length >= 2) {
      points = pointsFromSegments;
    }

    registerRoute(
      key: key,
      mode: mode,
      destinationName: destinationName ?? 'Destination',
      points: points,
      segments: segments,
      switchPoints: switchPoints,
      events:
          _routeEvents
              .map(
                (e) => {
                  'meters': e.meters,
                  'type': e.type,
                  if (e.label != null) 'label': e.label,
                  if (e.lat != null) 'lat': e.lat,
                  if (e.lng != null) 'lng': e.lng,
                },
              )
              .toList(),
    );
  }
}
