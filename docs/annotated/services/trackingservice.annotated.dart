// Annotated copy of lib/services/trackingservice.dart
// Purpose: Full line-by-line explanations of background tracking, alarms, deviation/switch, reroute, and notifications.

// lib/services/trackingservice.dart
import 'dart:async'; // Timers, streams, subscriptions, async helpers
import 'package:flutter/material.dart'; // Widgets binding for background init
import 'package:flutter_background_service/flutter_background_service.dart'; // Background isolate service
import 'package:geolocator/geolocator.dart'; // GPS positions and distance utils
import 'package:battery_plus/battery_plus.dart'; // Battery level for power policy
import 'dart:developer' as dev; // Structured logging
import 'package:google_maps_flutter/google_maps_flutter.dart'; // LatLng for coordinates

// --- ADDED IMPORTS ---
import 'package:geowake2/services/notification_service.dart'; // Foreground notifications + alarm UI hooks
// Note: You may need to create these files if they don't exist yet,
// but the core alarm logic will work without them for now.
import 'package:geowake2/services/sensor_fusion.dart'; // Dead-reckoning when GPS drops
// ---
import 'package:geowake2/services/route_registry.dart'; // Registered route entries + session fields
import 'package:geowake2/services/active_route_manager.dart'; // Snapping and progress state
import 'package:geowake2/services/deviation_monitor.dart'; // Hysteresis + sustain deviation logic
import 'package:geowake2/services/reroute_policy.dart'; // Cooldown + online gate
import 'package:geowake2/services/route_cache.dart'; // Route caching and keying
import 'package:geowake2/services/polyline_simplifier.dart'; // Polyline simplify/compress
import 'package:geowake2/services/polyline_decoder.dart'; // Decode encoded polyline strings
import 'package:geowake2/services/transfer_utils.dart'; // Step boundaries + events
import 'package:geowake2/services/alarm_player.dart'; // Alarm sound controller
import 'package:geowake2/services/offline_coordinator.dart'; // Offline-first fetch orchestrator
import 'package:geowake2/config/power_policy.dart'; // Battery-tiered tracking settings
import 'package:geowake2/services/snap_to_route.dart'; // Lateral offset + progress via snapping

import 'package:meta/meta.dart'; // @visibleForTesting
import 'package:sensors_plus/sensors_plus.dart'; // Accelerometer stream for fusion


// (Test code and other definitions remain the same)
Stream<Position>? testGpsStream; // Optional injected GPS stream for tests
@visibleForTesting
Stream<AccelerometerEvent>? testAccelerometerStream; // Optional injected accelerometer stream
@visibleForTesting
Duration gpsDropoutBuffer = const Duration(seconds: 25); // Time without GPS before fusion kicks in

class TestServiceInstance implements ServiceInstance { // Lightweight ServiceInstance for tests
  final _eventControllers = <String, StreamController<Map<String, dynamic>?>>{}; // Per-event controllers
  @override
  void invoke(String method, [Map<String, dynamic>? args]) { // Emulate invoke by logging
    dev.log("Test service invoke: $method, args: $args", name: "TestService");
  }
  @override
  Future<void> stopSelf() async { // Emulate stop
    dev.log("Test service stopped", name: "TestService");
  }
  @override
  Stream<Map<String, dynamic>?> on(String event) { // Return/create broadcast event stream
    _eventControllers.putIfAbsent(
        event, () => StreamController<Map<String, dynamic>?>.broadcast());
    return _eventControllers[event]!.stream;
  }
  void dispose() { // Cleanup controllers in tests
    for (var controller in _eventControllers.values) {
      controller.close();
    }
  }
}

class TrackingService { // Foreground facade controlling background tracking service
  static bool isTestMode = false; // Global test toggle to use TestServiceInstance
  static final TrackingService _instance = TrackingService._internal(); // Singleton
  factory TrackingService() => _instance; // Factory returns singleton
  TrackingService._internal(); // Private ctor
  final FlutterBackgroundService _service = FlutterBackgroundService(); // Platform service handle

  // Expose streams bound to background isolate controllers
  Stream<ActiveRouteState> get activeRouteStateStream => _routeStateCtrl.stream; // Active route state updates
  Stream<RouteSwitchEvent> get routeSwitchStream => _routeSwitchCtrl.stream; // Local switch events
  Stream<RerouteDecision> get rerouteDecisionStream => _rerouteCtrl.stream; // Reroute policy decisions

  Future<void> initializeService() async { // Configure background service
    if (isTestMode) return; // Skip in tests
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart, // Entry point for background isolate
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
  Future<void> startTracking({ // Start background tracking with destination + alarm mode/value
    required LatLng destination,
    required String destinationName,
    required String alarmMode, // 'distance' | 'time' | 'stops'
    required double alarmValue, // km | minutes | stops
    bool allowNotificationsInTest = false, // Let tests see real notifications if desired
    bool useInjectedPositions = false, // Enable injected GPS for demos/tests
  }) async {
    final Map<String, dynamic> params = { // Bundle config for background
      'destinationLat': destination.latitude,
      'destinationLng': destination.longitude,
      'destinationName': destinationName,
      'alarmMode': alarmMode,
      'alarmValue': alarmValue,
      'useInjectedPositions': useInjectedPositions,
    };
    if (isTestMode) { // In tests, run the background logic inline
      try {
        // In demo, allow real notifications even in test mode
        // ignore: invalid_use_of_visible_for_testing_member
        NotificationService.isTestMode = !allowNotificationsInTest; // Flip test-mode for notifications as requested
      } catch (_) {}
      // In test mode, we can directly call _onStart with the parameters
      _onStart(TestServiceInstance(), initialData: params); // Start inline
      return;
    }
    if (!await _service.isRunning()) { // Ensure background service is running
      await _service.startService();
    }
    try {
      await NotificationService().showJourneyProgress( // Initial persistent progress notification
        title: 'Journey to $destinationName',
        subtitle: 'Starting…',
        progress0to1: 0,
      );
    } catch (_) {}
    _service.invoke("startTracking", params); // Kick off background run
  }

  Future<void> stopTracking() async { // Stop background tracking and alarms
    // Make sure to stop the alarm in the foreground process first
    try {
      await AlarmPlayer.stop(); // Stop any sound
      NotificationService().stopVibration(); // Stop vibration
    } catch (e) {
      dev.log('Error stopping alarm in foreground: $e', name: 'TrackingService');
    }
    
    if (isTestMode) { // Inline stop in tests
      _onStop();
      return;
    }
    if (await _service.isRunning()) {
      _service.invoke("stopTracking"); // Ask background to stop
    }
  }

  @visibleForTesting
  bool get fusionActive => _fusionActive; // Test hook: whether sensor fusion is active
  @visibleForTesting
  bool get alarmTriggered => _destinationAlarmFired; // Test hook: destination alarm fired
  @visibleForTesting
  DateTime? get lastGpsUpdateValue => _lastGpsUpdate; // Test hook: timestamp of last GPS
  @visibleForTesting
  LatLng? get lastValidPosition => _lastProcessedPosition; // Test hook: last processed LatLng
}

@pragma('vm:entry-point')
bool onIosBackground(ServiceInstance service) { // iOS background entry for FlutterBackgroundService
  WidgetsFlutterBinding.ensureInitialized(); // Make sure bindings are ready
  return true; // Required return
}

// ===================================================================
// BACKGROUND ISOLATE STATE
// ===================================================================
StreamSubscription<Position>? _positionSubscription; // Active GPS stream sub
DateTime? _lastGpsUpdate; // Last GPS timestamp
SensorFusionManager? _sensorFusionManager; // Fusion engine when GPS is silent
Timer? _gpsCheckTimer; // Periodic timer for dropout and notification ticks
LatLng? _lastProcessedPosition; // Last position used by pipelines
double? _smoothedETA; // Simplified ETA seconds
bool _fusionActive = false; // Fusion state
double? _lastSpeedMps; // Last speed (m/s)
// Support for injected test positions from foreground (demo path)
bool _useInjectedPositions = false; // Whether to consume injected stream
StreamController<Position>? _injectedCtrl; // Injected position controller
// Time-alarm gating state
DateTime? _startedAt; // Trip start time
LatLng? _startPosition; // Start location
double _distanceTravelledMeters = 0.0; // Moved since start
int _etaSamples = 0; // Count of ETA samples with credible movement
bool _timeAlarmEligible = false; // Gate for time-based alarms

// --- NEW STATE VARIABLES FOR ALARM LOGIC ---
LatLng? _destination; // Target destination
String? _destinationName; // Name for notifications
String? _alarmMode; // 'distance' | 'time' | 'stops'
double? _alarmValue; // threshold value
bool _destinationAlarmFired = false; // fire destination alarm only once
final Set<int> _firedEventIndexes = <int>{}; // indices into _routeEvents already fired

// Event boundaries (transfers, mode changes) for multi-route safety
List<RouteEventBoundary> _routeEvents = const []; // Upcoming events along route (meters + label)
List<double> _stepBoundsMeters = const []; // Cumulative step end meters
List<double> _stepStopsCumulative = const []; // Cumulative stops at step ends

// Route management and deviation/reroute state
final RouteRegistry _registry = RouteRegistry(); // Registered routes LRU
ActiveRouteManager? _activeManager; // Manager that computes snap/progress
DeviationMonitor? _devMonitor; // Deviation state monitor
ReroutePolicy? _reroutePolicy; // Gated reroute trigger
OfflineCoordinator? _offlineCoordinator; // Offline-first directions
final _routeStateCtrl = StreamController<ActiveRouteState>.broadcast(); // Exposed stream for UI/tests
final _routeSwitchCtrl = StreamController<RouteSwitchEvent>.broadcast(); // Exposed stream for UI/tests
final _rerouteCtrl = StreamController<RerouteDecision>.broadcast(); // Exposed stream for UI/tests

StreamSubscription<ActiveRouteState>? _mgrStateSub; // bridge manager state
StreamSubscription<RouteSwitchEvent>? _mgrSwitchSub; // bridge switch events
StreamSubscription<DeviationState>? _devSub; // bridge deviation
StreamSubscription<RerouteDecision>? _rerouteSub; // bridge reroute decisions
bool _activeRouteInitialized = false; // one-time setActive semantics
bool _rerouteInFlight = false; // prevent overlapping reroutes
bool _transitMode = false; // Used for stops-mode behaviors
ActiveRouteState? _lastActiveState; // Keep last state for context
LatLng? _firstTransitBoarding; // Pre-boarding alert target
bool _preBoardingAlertFired = false; // Ensure single pre-boarding alert

@pragma('vm:entry-point')
void _onStop() async { // Tear down background pipelines and notifications
  _positionSubscription?.cancel();
  _positionSubscription = null;
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
    dev.log('Error stopping alarm during tracking stop: $e', name: 'TrackingService');
  }
  
  // Cancel persistent progress notification
  try {
    if (!TrackingService.isTestMode) {
      await NotificationService().cancelJourneyProgress();
    }
  } catch (_) {}
  dev.log("Tracking has been fully stopped.", name: "TrackingService");
}

// --- NEW FUNCTION: Contains the core alarm logic ---
@pragma('vm:entry-point')
Future<void> _checkAndTriggerAlarm(Position currentPosition, ServiceInstance service) async { // Main alarm gate
  if (_destination == null || _alarmValue == null) {
    return; // No target defined
  }

  bool shouldTriggerDestination = false; // Whether to fire main destination alarm
  String? destinationReasonLabel; // Label for notification

  if (_alarmMode == 'distance') { // Distance-to-target threshold
    double distanceInMeters = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      _destination!.latitude,
      _destination!.longitude,
    );
    if (distanceInMeters <= (_alarmValue! * 1000)) { // alarmValue is in km
      shouldTriggerDestination = true;
      destinationReasonLabel = _destinationName;
    }
    dev.log("Distance Check: ${distanceInMeters.toStringAsFixed(0)}m / ${_alarmValue! * 1000}m", name: "TrackingService");
  } else if (_alarmMode == 'time') { // ETA-to-target threshold with eligibility gate
    // Gate time-based alarms to avoid immediate false triggers when stationary
    if (!_timeAlarmEligible) {
      dev.log('Time alarm not yet eligible. Samples=$_etaSamples, moved=${_distanceTravelledMeters.toStringAsFixed(1)}m, sinceStart=${_startedAt != null ? DateTime.now().difference(_startedAt!).inSeconds : -1}s', name: 'TrackingService');
    } else if (_smoothedETA != null && _smoothedETA! <= (_alarmValue! * 60)) { // alarmValue is in minutes
      shouldTriggerDestination = true;
      destinationReasonLabel = _destinationName;
    }
    dev.log("Time Check: ${_smoothedETA?.toStringAsFixed(0)}s / ${_alarmValue! * 60}s (eligible=$_timeAlarmEligible)", name: "TrackingService");
  }

  // Metro pre-boarding alert: if stops-mode + transit route; trigger once near boarding point
  if (_alarmMode == 'stops' && _transitMode && !_preBoardingAlertFired) {
    try {
      if (_firstTransitBoarding != null) {
        final d = Geolocator.distanceBetween(
          currentPosition.latitude, currentPosition.longitude,
          _firstTransitBoarding!.latitude, _firstTransitBoarding!.longitude,
        );
        dev.log('Pre-boarding check: mode=stops transit=$_transitMode d=${d.toStringAsFixed(1)}m to boarding=$_firstTransitBoarding', name: 'TrackingService');
        // 1 stop == 1 km for pre-boarding alert
        if (d <= 1000.0) {
          try {
            dev.log('Pre-boarding ALERT firing at d=${d.toStringAsFixed(1)}m', name: 'TrackingService');
            if (TrackingService.isTestMode) {
              await NotificationService().showWakeUpAlarm(
                title: 'Approaching metro station',
                body: 'Get ready to board',
                allowContinueTracking: true,
              );
            } else {
              service.invoke('fireAlarm', {
                'title': 'Approaching metro station',
                'body': 'Get ready to board',
                'allowContinueTracking': true,
              });
            }
            _preBoardingAlertFired = true;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // Also check upcoming route events (transfer/mode change) with the same threshold semantics
  if (_routeEvents.isNotEmpty) {
    // We need progressMeters along the active route; use authoritative manager state when available.
    try {
      double? progressMeters = _lastActiveState?.progressMeters;
      // Legacy proximity fallback, only if state is momentarily unavailable
      if (progressMeters == null && _lastProcessedPosition != null) {
        final near = _registry.candidatesNear(_lastProcessedPosition!, radiusMeters: 5000, maxCandidates: 1);
        if (near.isNotEmpty) progressMeters = near.first.lastProgressMeters;
      }
      if (progressMeters != null) {
        final thresholdMeters = _alarmMode == 'distance' ? (_alarmValue! * 1000.0) : null;
  final thresholdSeconds = _alarmMode == 'time' ? (_alarmValue! * 60.0) : null;
        final thresholdStops = _alarmMode == 'stops' ? (_alarmValue!) : null;
        // Compute simple speed for time threshold
        final spd = _lastSpeedMps != null && _lastSpeedMps! > 0.3 ? _lastSpeedMps! : 10.0;
        // Compute progressStops if needed
        double? progressStops;
        if (thresholdStops != null && _stepBoundsMeters.isNotEmpty && _stepStopsCumulative.isNotEmpty) {
          for (int i = 0; i < _stepBoundsMeters.length; i++) {
            if (progressMeters <= _stepBoundsMeters[i]) {
              progressStops = _stepStopsCumulative[i];
              break;
            }
          }
          progressStops ??= 0.0;
        }
        for (int idx = 0; idx < _routeEvents.length; idx++) {
          final ev = _routeEvents[idx];
          if (_firedEventIndexes.contains(idx)) continue; // already alerted
          if (ev.meters <= progressMeters) continue; // already passed
          final toEventM = ev.meters - progressMeters;
          bool eventAlarm = false;
          if (thresholdMeters != null) {
            eventAlarm = toEventM <= thresholdMeters;
          } else if (thresholdSeconds != null) {
            if (!_timeAlarmEligible) {
              // Do not raise time-based event alarms until eligible
              continue;
            }
            final estSec = toEventM / spd;
            eventAlarm = estSec <= thresholdSeconds;
          } else if (thresholdStops != null && progressStops != null) {
            // Map event meters to event stops
            double? eventStops;
            for (int i = 0; i < _stepBoundsMeters.length; i++) {
              if (ev.meters <= _stepBoundsMeters[i]) {
                eventStops = _stepStopsCumulative[i];
                break;
              }
            }
            if (eventStops != null) {
              final toEventStops = eventStops - progressStops;
              eventAlarm = toEventStops <= thresholdStops;
            }
          }
          if (eventAlarm) {
            // Fire an event alarm (do not stop service). In test mode, use NotificationService for observability.
            try {
              final title = ev.type == 'transfer' ? 'Upcoming transfer' : 'Upcoming change';
              final body = ev.label != null ? ev.label! : (ev.type == 'transfer' ? 'Transfer ahead' : 'Mode change ahead');
              if (TrackingService.isTestMode) {
                await NotificationService().showWakeUpAlarm(
                  title: title,
                  body: body,
                  allowContinueTracking: true,
                );
              } else {
                service.invoke('fireAlarm', {
                  'title': title,
                  'body': body,
                  'allowContinueTracking': true,
                });
              }
            } catch (_) {}
            _firedEventIndexes.add(idx);
            // Continue to check destination separately
          }
        }
      }
    } catch (_) {}
  }

  // Destination threshold check considering stops mode
  if (_alarmMode == 'stops' && !_destinationAlarmFired) { // Remaining stops to destination
    // Compute remaining stops based on progress
    try {
      if (_stepBoundsMeters.isNotEmpty && _stepStopsCumulative.isNotEmpty) {
        final progressMeters = _lastActiveState?.progressMeters ?? 0.0; // authoritative progress
          double progressStops = 0.0;
          for (int i = 0; i < _stepBoundsMeters.length; i++) {
            if (progressMeters <= _stepBoundsMeters[i]) {
              progressStops = _stepStopsCumulative[i];
              break;
            }
          }
          final totalStops = _stepStopsCumulative.isNotEmpty ? _stepStopsCumulative.last : 0.0;
          final remainingStops = (totalStops - progressStops);
          if (remainingStops <= _alarmValue!) {
            shouldTriggerDestination = true;
            destinationReasonLabel = _destinationName;
          }
      }
    } catch (_) {}
  }

  if (shouldTriggerDestination && !_destinationAlarmFired) { // Fire main alarm once
    dev.log("DESTINATION ALARM TRIGGERED!", name: "TrackingService");
    _destinationAlarmFired = true;
    final title = 'Wake Up! ';
    final body = destinationReasonLabel != null
        ? 'Approaching: $destinationReasonLabel'
        : 'You are nearing your target';
    try {
      if (TrackingService.isTestMode) {
        await NotificationService().showWakeUpAlarm(
          title: title,
          body: body,
          allowContinueTracking: false,
        );
      } else {
        service.invoke('fireAlarm', {
          'title': title,
          'body': body,
          'allowContinueTracking': false,
        });
      }
    } catch (_) {}
    // Stop the service to save battery once destination alarm fires
    service.invoke("stopTracking");
  }
}

@pragma('vm:entry-point')
void _onStart(ServiceInstance service, {Map<String, dynamic>? initialData}) async { // Background entrypoint
  WidgetsFlutterBinding.ensureInitialized(); // Initialize Flutter in background
  // Ensure notification channels are ready in the background isolate before any alarm/notification usage
  try { await NotificationService().initialize(); } catch (_) {}
  
  service.on('stopService').listen((event) { // Handle explicit stop
    service.stopSelf();
  });

  service.on('startTracking').listen((data) { // Foreground -> background config
    if (data != null) {
      _destination = LatLng(data['destinationLat'], data['destinationLng']);
      _destinationName = data['destinationName'];
      _alarmMode = data['alarmMode'];
      _alarmValue = (data['alarmValue'] as num).toDouble();
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
      _smoothedETA = null; // Reset ETA
      dev.log("Tracking started with params: Dest='$_destinationName', Mode='$_alarmMode', Value='$_alarmValue'", name: "TrackingService");
      // Show initial journey notification immediately
      try {
        if (!TrackingService.isTestMode) {
          NotificationService().showJourneyProgress(
            title: _destinationName != null ? 'Journey to $_destinationName' : 'GeoWake journey',
            subtitle: 'Starting…',
            progress0to1: 0.0,
          );
        }
      } catch (_) {}
      startLocationStream(service); // Begin GPS stream + pipelines
    }
  });

  // Enable injected positions (used by demo)
  service.on('useInjectedPositions').listen((event) { // Toggle injection
    _useInjectedPositions = true;
    _injectedCtrl ??= StreamController<Position>.broadcast();
  });
  // Inject a single position sample
  service.on('injectPosition').listen((data) { // Push injected GPS sample
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

  // Handle data passed directly (for test mode)
  if (initialData != null) { // Inline config for test mode
      _destination = LatLng(initialData['destinationLat'], initialData['destinationLng']);
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
    startLocationStream(service);
  }
  
  service.on("stopTracking").listen((event) async { // Foreground stop request
    // Make sure to stop the alarm explicitly first
    try {
      await AlarmPlayer.stop();
    } catch (e) {
      dev.log('Error stopping alarm during tracking stop: $e', name: 'TrackingService');
    }
    
    // Then stop all tracking
    _onStop();
    
    if(event?['stopSelf'] == true){
       service.stopSelf();
    }
  });

  service.on('stopAlarm').listen((event) async { // Stop only the alarm
    dev.log('Received stopAlarm event in background service', name: 'TrackingService');
    try { 
      // Stop playing sound
      await AlarmPlayer.stop();
      // Stop vibration through the notification service
      try {
        NotificationService().stopVibration();
      } catch (e) {
        dev.log('Error stopping vibration: $e', name: 'TrackingService');
      }
      // We can't directly cancel the notification from the background service
      // since we don't have access to the private members of NotificationService.
      // The notification will be dismissed when the app comes to foreground.
    } catch (e) {
      dev.log('Error stopping alarm: $e', name: 'TrackingService');
    }
  });

  dev.log("Background Service Instance Started", name: "TrackingService");
}

extension TrackingServiceRouteOps on TrackingService { // Route registration + pipeline wiring
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
  }) {
    final entry = RouteEntry(
      key: key,
      mode: mode,
      destinationName: destinationName,
      points: points,
    );
    _registry.upsert(entry);
    // Initialize manager and pipelines if not exists
    _activeManager ??= ActiveRouteManager(
      registry: _registry,
      sustainDuration: TrackingService.isTestMode ? const Duration(milliseconds: 300) : const Duration(seconds: 6),
      switchMarginMeters: TrackingService.isTestMode ? 20 : 50,
      postSwitchBlackout: TrackingService.isTestMode ? const Duration(milliseconds: 300) : const Duration(seconds: 5),
    );
    _devMonitor ??= DeviationMonitor(
      sustainDuration: TrackingService.isTestMode ? const Duration(milliseconds: 300) : const Duration(seconds: 5),
    );
    // Cooldown from power policy will be applied in startLocationStream after battery read
    _reroutePolicy ??= ReroutePolicy(
      cooldown: TrackingService.isTestMode ? const Duration(seconds: 2) : const Duration(seconds: 20),
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
          final entry = _registry.entries.firstWhere((e) => e.key == s.activeKey, orElse: () => _registry.entries.first);
          final snap = SnapToRouteEngine.snap(point: _lastProcessedPosition!, polyline: entry.points, hintIndex: entry.lastSnapIndex);
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
        if (_lastProcessedPosition != null && _lastActiveState?.activeKey != null) {
          final entry = _registry.entries.firstWhere((e) => e.key == _lastActiveState!.activeKey, orElse: () => _registry.entries.first);
          final snap = SnapToRouteEngine.snap(point: _lastProcessedPosition!, polyline: entry.points, hintIndex: entry.lastSnapIndex);
          off = snap.lateralOffsetMeters;
        }
      } catch (_) {}

      // In tests, allow immediate local switch in the 100–150m band without waiting for sustain
      if (!ds.sustained) {
        if (off >= 100.0 && off <= 150.0) {
          try {
            if (_lastProcessedPosition != null && _registry.entries.isNotEmpty) {
              double bestOffset = off;
              RouteEntry? best;
              for (final e in _registry.entries) {
                final snap = SnapToRouteEngine.snap(point: _lastProcessedPosition!, polyline: e.points, hintIndex: e.lastSnapIndex);
                if (snap.lateralOffsetMeters + 1e-6 < bestOffset) {
                  bestOffset = snap.lateralOffsetMeters;
                  best = e;
                }
              }
              final margin = TrackingService.isTestMode ? 20.0 : 50.0;
              if (best != null && (off - bestOffset) >= margin) {
                final fromKey = _lastActiveState?.activeKey ?? 'unknown';
                _activeManager?.setActive(best.key);
                _routeSwitchCtrl.add(RouteSwitchEvent(fromKey: fromKey, toKey: best.key, at: DateTime.now()));
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
              final snap = SnapToRouteEngine.snap(point: _lastProcessedPosition!, polyline: e.points, hintIndex: e.lastSnapIndex);
              if (snap.lateralOffsetMeters + 1e-6 < bestOffset) {
                bestOffset = snap.lateralOffsetMeters;
                best = e;
              }
            }
            final margin = TrackingService.isTestMode ? 20.0 : 50.0;
            if (best != null && (off - bestOffset) >= margin) {
              final fromKey = _lastActiveState?.activeKey ?? 'unknown';
              _activeManager?.setActive(best.key);
              _routeSwitchCtrl.add(RouteSwitchEvent(fromKey: fromKey, toKey: best.key, at: DateTime.now()));
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
          if (origin == null || _destination == null || _offlineCoordinator == null) {
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
          dev.log('Reroute registered from ${res.source}', name: 'TrackingService');
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
  void registerRouteFromDirections({
    required Map<String, dynamic> directions,
    required LatLng origin,
    required LatLng destination,
    required bool transitMode,
    String? destinationName,
  }) {
  final mode = transitMode ? 'transit' : 'driving';
    _transitMode = transitMode;
    final key = RouteCache.makeKey(origin: origin, destination: destination, mode: mode, transitVariant: transitMode ? 'rail' : null);
  // Extract polyline points
  List<LatLng> points = [];
    try {
      final route = (directions['routes'] as List).first as Map<String, dynamic>;
      final scp = route['simplified_polyline'] as String?;
      if (scp != null) {
        points = PolylineSimplifier.decompressPolyline(scp);
      } else if (route['overview_polyline'] != null && route['overview_polyline']['points'] != null) {
        points = decodePolyline(route['overview_polyline']['points'] as String);
      }
    } catch (_) {}
    // Build step bounds and stops
    try {
      final m = TransferUtils.buildStepBoundariesAndStops(directions);
      _stepBoundsMeters = m.bounds;
      _stepStopsCumulative = m.stops;
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
                final dep = (step['transit_details'] as Map<String, dynamic>?)?['departure_stop'] as Map<String, dynamic>?;
                final loc = dep != null ? dep['location'] as Map<String, dynamic>? : null;
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
                  final pts = decodePolyline((step['polyline'] as Map<String, dynamic>)['points'] as String);
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
      dev.log('Computed first transit boarding: $_firstTransitBoarding', name: 'TrackingService');
      _preBoardingAlertFired = false;
    } catch (_) {
      _firstTransitBoarding = null;
      _preBoardingAlertFired = false;
    }
    registerRoute(
      key: key,
      mode: mode,
      destinationName: destinationName ?? 'Destination',
      points: points,
    );
  }
}


Future<void> startLocationStream(ServiceInstance service) async { // Start and manage the GPS stream
  if (_positionSubscription != null) {
    await _positionSubscription!.cancel();
  }
  int batteryLevel = 100;
  if (!TrackingService.isTestMode) {
    final Battery battery = Battery();
    batteryLevel = await battery.batteryLevel; // Read battery level
  }
  // Select power tier
  final policy = TrackingService.isTestMode
      ? PowerPolicy.testing()
      : PowerPolicyManager.forBatteryLevel(batteryLevel);
  // Apply gps dropout and reroute cooldown based on policy
  gpsDropoutBuffer = policy.gpsDropoutBuffer;
  // IMPORTANT: update cooldown in-place to preserve stream subscribers
  if (_reroutePolicy != null) {
    _reroutePolicy!.setCooldown(policy.rerouteCooldown);
  }
  
  LocationSettings settings = LocationSettings(
    accuracy: policy.accuracy,
    distanceFilter: policy.distanceFilterMeters,
  );

  Stream<Position> stream;
  if (_useInjectedPositions && _injectedCtrl != null) {
    stream = _injectedCtrl!.stream; // Use injected stream for tests/demos
  } else {
    stream = testGpsStream ?? Geolocator.getPositionStream(locationSettings: settings); // Real GPS or injected test
  }
  
  _positionSubscription = stream.listen((Position position) {
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
      _fusionActive = false; // Stop fusion when GPS resumes
    }

    // Simplified ETA calculation
  if (_destination != null) {
    double distance = Geolocator.distanceBetween(position.latitude, position.longitude, _destination!.latitude, _destination!.longitude);
    double speed = position.speed > 1 ? position.speed : 12.0;
    _smoothedETA = distance / speed; // seconds
    // Count ETA samples only when speed shows credible movement
    if (position.speed.isFinite && position.speed >= 0.5) {
      _etaSamples++;
    }
  }

    // Ingest into active route manager and deviation pipeline if present
    _lastSpeedMps = position.speed;
    if (_activeManager != null) {
      final raw = LatLng(position.latitude, position.longitude);
      _activeManager!.ingestPosition(raw); // Snap + progress update
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
  final Duration checkPeriod = TrackingService.isTestMode ? policy.notificationTick : policy.notificationTick; // unify cadence
  _gpsCheckTimer = Timer.periodic(checkPeriod, (_) {
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
        _fusionActive = true; // Fusion now active
      }
    }
    
    // Regularly force notification updates even without state changes
    _updateNotification(service);
    // Evaluate time-alarm eligibility periodically
    try {
      if (_alarmMode == 'time' && !_timeAlarmEligible) {
        final sinceStart = _startedAt != null ? DateTime.now().difference(_startedAt!) : Duration.zero;
        // Eligible after: moved >= 100m AND at least 3 ETA samples with speed >=0.5 m/s AND 30s since start
        if (_distanceTravelledMeters >= 100.0 && _etaSamples >= 3 && sinceStart.inSeconds >= 30) {
          _timeAlarmEligible = true;
          dev.log('Time alarm is now eligible', name: 'TrackingService');
        }
      }
    } catch (_) {}
  });
}

// Helper method to update notification based on current state
void _updateNotification(ServiceInstance service) { // Build and show progress notification
  try {
    if (TrackingService.isTestMode || _destination == null) return; // Skip in tests or no target
    
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
        final progress = total > 0 ? (progressMeters / total).clamp(0.0, 1.0) : 0.0;
        final remainingMeters = total - progressMeters;
        
        // Create progress notification
        final progressPercent = (progress * 100).clamp(0.0, 100.0).toStringAsFixed(1);
        final remainingKm = (remainingMeters / 1000.0).toStringAsFixed(1);
        
        dev.log('Forced notification update: $progressPercent% | remaining $remainingKm km', 
               name: 'TrackingService');
        
        NotificationService().showJourneyProgress(
          title: _destinationName != null ? 'Journey to $_destinationName' : 'GeoWake journey',
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
      dev.log('Simple notification update: remaining $remainingKm km', name: 'TrackingService');
      
      NotificationService().showJourneyProgress(
        title: _destinationName != null ? 'Journey to $_destinationName' : 'GeoWake journey',
        subtitle: 'Remaining: $remainingKm km',
        progress0to1: 0.0, // We don't know total journey distance in this case
      );
    }
  } catch (e) {
    dev.log('Error updating notification: $e', name: 'TrackingService');
  }
}

// No top-level testing getters; use instance getters on TrackingService.
