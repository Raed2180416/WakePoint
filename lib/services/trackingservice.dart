// lib/services/trackingservice.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';
import 'dart:developer' as dev;
import 'package:google_maps_flutter/google_maps_flutter.dart';

// --- ADDED IMPORTS ---
import 'package:geowake2/services/notification_service.dart';
// Note: You may need to create these files if they don't exist yet,
// but the core alarm logic will work without them for now.
import 'package:geowake2/services/sensor_fusion.dart';
// ---

import 'package:meta/meta.dart';
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
        event, () => StreamController<Map<String, dynamic>?>.broadcast());
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

  Future<void> initializeService() async {
    if (isTestMode) return;
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        isForegroundMode: true,
        autoStart: false,
        notificationChannelId: 'geowake_tracking_channel',
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
  }) async {
    final Map<String, dynamic> params = {
      'destinationLat': destination.latitude,
      'destinationLng': destination.longitude,
      'destinationName': destinationName,
      'alarmMode': alarmMode,
      'alarmValue': alarmValue,
    };
    if (isTestMode) {
      // In test mode, we can directly call _onStart with the parameters
      _onStart(TestServiceInstance(), initialData: params);
      return;
    }
    if (!await _service.isRunning()) {
      await _service.startService();
    }
    _service.invoke("startTracking", params);
  }

  Future<void> stopTracking() async {
    if (isTestMode) {
      _onStop();
      return;
    }
    if (await _service.isRunning()) {
      _service.invoke("stopTracking");
    }
  }

  @visibleForTesting
  bool get fusionActive => _fusionActive;
}

@pragma('vm:entry-point')
bool onIosBackground(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

// ===================================================================
// BACKGROUND ISOLATE STATE
// ===================================================================
StreamSubscription<Position>? _positionSubscription;
DateTime? _lastGpsUpdate;
SensorFusionManager? _sensorFusionManager;
Timer? _gpsCheckTimer;
LatLng? _lastProcessedPosition;
double? _smoothedETA;
bool _fusionActive = false;

// --- NEW STATE VARIABLES FOR ALARM LOGIC ---
LatLng? _destination;
String? _destinationName;
String? _alarmMode;
double? _alarmValue;
bool _alarmTriggered = false; // Flag to ensure alarm only fires once

@pragma('vm:entry-point')
void _onStop() {
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
  dev.log("Tracking has been fully stopped.", name: "TrackingService");
}

// --- NEW FUNCTION: Contains the core alarm logic ---
@pragma('vm:entry-point')
void _checkAndTriggerAlarm(Position currentPosition, ServiceInstance service) {
  if (_destination == null || _alarmValue == null || _alarmTriggered) {
    return;
  }

  bool shouldTrigger = false;

  if (_alarmMode == 'distance') {
    double distanceInMeters = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      _destination!.latitude,
      _destination!.longitude,
    );
    if (distanceInMeters <= (_alarmValue! * 1000)) { // alarmValue is in km
      shouldTrigger = true;
    }
    dev.log("Distance Check: ${distanceInMeters.toStringAsFixed(0)}m / ${_alarmValue! * 1000}m", name: "TrackingService");
  } else if (_alarmMode == 'time') {
    if (_smoothedETA != null && _smoothedETA! <= (_alarmValue! * 60)) { // alarmValue is in minutes
      shouldTrigger = true;
    }
    dev.log("Time Check: ${_smoothedETA?.toStringAsFixed(0)}s / ${_alarmValue! * 60}s", name: "TrackingService");
  }

  if (shouldTrigger) {
    dev.log("ALARM TRIGGERED!", name: "TrackingService");
    _alarmTriggered = true;

    NotificationService().showWakeUpAlarm(
      title: 'Wake Up! You Are Arriving!',
      body: 'You are near your destination: $_destinationName',
    );
    
    // Stop the service to save battery
    service.invoke("stopTracking");
  }
}

@pragma('vm:entry-point')
void _onStart(ServiceInstance service, {Map<String, dynamic>? initialData}) async {
  WidgetsFlutterBinding.ensureInitialized();
  
  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  service.on('startTracking').listen((data) {
    if (data != null) {
      _destination = LatLng(data['destinationLat'], data['destinationLng']);
      _destinationName = data['destinationName'];
      _alarmMode = data['alarmMode'];
      _alarmValue = (data['alarmValue'] as num).toDouble();
      _alarmTriggered = false; // Reset the alarm trigger flag for a new trip
      _smoothedETA = null; // Reset ETA
      dev.log("Tracking started with params: Dest='$_destinationName', Mode='$_alarmMode', Value='$_alarmValue'", name: "TrackingService");
      startLocationStream(service);
    }
  });

  // Handle data passed directly (for test mode)
  if (initialData != null) {
      _destination = LatLng(initialData['destinationLat'], initialData['destinationLng']);
      _destinationName = initialData['destinationName'];
      _alarmMode = initialData['alarmMode'];
      _alarmValue = (initialData['alarmValue'] as num).toDouble();
      _alarmTriggered = false;
      startLocationStream(service);
  }
  
  service.on("stopTracking").listen((event) {
    _onStop();
    if(event?['stopSelf'] == true){
       service.stopSelf();
    }
  });

  dev.log("Background Service Instance Started", name: "TrackingService");
}

Future<void> startLocationStream(ServiceInstance service) async {
  if (_positionSubscription != null) {
    await _positionSubscription!.cancel();
  }

  final Battery battery = Battery();
  int batteryLevel = await battery.batteryLevel;
  
  LocationSettings settings = batteryLevel > 20
      ? const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20)
      : const LocationSettings(accuracy: LocationAccuracy.medium, distanceFilter: 50);

  final Stream<Position> stream = testGpsStream ?? Geolocator.getPositionStream(locationSettings: settings);
  
  _positionSubscription = stream.listen((Position position) {
    _lastGpsUpdate = DateTime.now();
    _lastProcessedPosition = LatLng(position.latitude, position.longitude);

    if (_fusionActive) {
      _sensorFusionManager?.stopFusion();
      _fusionActive = false;
    }

    // Simplified ETA calculation
    if (_destination != null) {
        double distance = Geolocator.distanceBetween(position.latitude, position.longitude, _destination!.latitude, _destination!.longitude);
        double speed = position.speed > 1 ? position.speed : 12.0;
        _smoothedETA = distance / speed;
    }

    // --- CRITICAL CHANGE: CHECK THE ALARM CONDITION ON EVERY UPDATE ---
    _checkAndTriggerAlarm(position, service);

    service.invoke("updateLocation", {
      "latitude": position.latitude,
      "longitude": position.longitude,
      "eta": _smoothedETA,
    });
  });

  // (GPS Dropout and Sensor Fusion logic can be added back here if needed)
}


// Expose testing getters.
@visibleForTesting
DateTime? get lastGpsUpdateValue => _lastGpsUpdate;
@visibleForTesting
LatLng? get lastValidPosition => _lastProcessedPosition;
@visibleForTesting
bool get fusionActive => _fusionActive;