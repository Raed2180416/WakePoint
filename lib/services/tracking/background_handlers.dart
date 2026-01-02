// lib/services/tracking/background_handlers.dart
//
// Handles all service.on() listener registrations for the background isolate.
// These handlers process commands from the foreground isolate.

import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/logging/app_logger.dart';
import 'package:geowake2/services/alarm_player.dart';
import 'package:geowake2/services/location_manager.dart';

/// Callbacks that BackgroundHandlers invokes when events are received.
class BackgroundHandlerCallbacks {
  /// Called when startTracking is received with all parameters.
  final Future<void> Function({
    required LatLng destination,
    required String destinationName,
    required String alarmMode,
    required double alarmValue,
    required bool transitMode,
    required ServiceInstance service,
  })
  onStartTracking;

  /// Called when stopTracking is received.
  final Future<void> Function({bool stopSelf}) onStopTracking;

  /// Called when registerRoute is received.
  final void Function({
    required String key,
    required String mode,
    required String destinationName,
    required List<LatLng> points,
    List<Map<String, dynamic>>? segments,
    List<Map<String, dynamic>>? switchPoints,
    List<Map<String, dynamic>>? events,
  })
  onRegisterRoute;

  /// Called when registerRouteDirections is received.
  final Future<void> Function({
    required Map<String, dynamic> directions,
    required LatLng origin,
    required LatLng destination,
    required bool transitMode,
    String? destinationName,
  })
  onRegisterRouteDirections;

  /// Called when stopAlarm is received.
  final Future<void> Function() onStopAlarm;

  /// Invoked on foreground heartbeat
  final void Function() onForegroundHeartbeat;

  /// Invoked when foreground resumed
  final Future<void> Function() onForegroundResumed;

  BackgroundHandlerCallbacks({
    required this.onStartTracking,
    required this.onStopTracking,
    required this.onRegisterRoute,
    required this.onRegisterRouteDirections,
    required this.onStopAlarm,
    required this.onForegroundHeartbeat,
    required this.onForegroundResumed,
  });
}

/// Registers all background service event handlers.
/// Should be called once during _onStart.
class BackgroundHandlers {
  final ServiceInstance _service;
  final BackgroundHandlerCallbacks _callbacks;

  BackgroundHandlers({
    required ServiceInstance service,
    required BackgroundHandlerCallbacks callbacks,
  }) : _service = service,
       _callbacks = callbacks;

  /// Registers all handlers on the service instance.
  void registerAll() {
    _service.on('stopService').listen((_) {
      _service.stopSelf();
    });

    _service.on('startTracking').listen(_handleStartTracking);
    _service.on('stopTracking').listen(_handleStopTracking);
    _service.on('stopAlarm').listen(_handleStopAlarm);
    _service.on('registerRoute').listen(_handleRegisterRoute);
    _service
        .on('registerRouteDirections')
        .listen(_handleRegisterRouteDirections);

    // Position injection for demo/testing
    _service.on('useInjectedPositions').listen((_) {
      // LocationManager handles auto-switch
    });

    _service.on('injectPosition').listen(_handleInjectPosition);

    // Heartbeat mechanism
    _service.on('foregroundHeartbeat').listen((_) {
      _callbacks.onForegroundHeartbeat();
    });

    _service.on('foregroundResumed').listen((_) async {
      await _callbacks.onForegroundResumed();
    });
  }

  void _handleStartTracking(Map<String, dynamic>? data) {
    dev.log(
      'Background received startTracking event',
      name: 'BackgroundHandlers',
    );

    final requestId = data?['requestId'] as String?;
    if (requestId != null) {
      try {
        _service.invoke('startTrackingAck', {'requestId': requestId});
      } catch (_) {}
    }

    if (data == null) return;

    final destination = LatLng(
      (data['destinationLat'] as num).toDouble(),
      (data['destinationLng'] as num).toDouble(),
    );
    final destinationName = data['destinationName'] as String;
    final alarmMode = data['alarmMode'] as String;
    final alarmValue = (data['alarmValue'] as num).toDouble();
    final transitMode = data['transitMode'] as bool? ?? false;

    _callbacks.onStartTracking(
      destination: destination,
      destinationName: destinationName,
      alarmMode: alarmMode,
      alarmValue: alarmValue,
      transitMode: transitMode,
      service: _service,
    );
  }

  void _handleStopTracking(Map<String, dynamic>? event) async {
    try {
      await AlarmPlayer.stop();
    } catch (e) {
      dev.log('Error stopping alarm: $e', name: 'BackgroundHandlers');
    }

    await _callbacks.onStopTracking(stopSelf: event?['stopSelf'] == true);

    if (event?['stopSelf'] == true) {
      _service.stopSelf();
    }
  }

  void _handleStopAlarm(Map<String, dynamic>? _) async {
    dev.log('Received stopAlarm event', name: 'BackgroundHandlers');
    try {
      await _callbacks.onStopAlarm();
    } catch (e) {
      dev.log('Error stopping alarm: $e', name: 'BackgroundHandlers');
    }
  }

  void _handleRegisterRoute(Map<String, dynamic>? data) {
    if (data == null) return;
    try {
      final requestId = data['requestId'] as String?;
      final key = data['key'] as String;
      final mode = data['mode'] as String;
      final destinationName = data['destinationName'] as String;
      final pointsJson = data['points'] as List;
      final points =
          pointsJson
              .map(
                (p) => LatLng(
                  (p['lat'] as num).toDouble(),
                  (p['lng'] as num).toDouble(),
                ),
              )
              .toList();

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
        'Background: Received registerRoute for $key',
        name: 'BackgroundHandlers',
      );

      _callbacks.onRegisterRoute(
        key: key,
        mode: mode,
        destinationName: destinationName,
        points: points,
        segments: segments,
        switchPoints: switchPoints,
        events: events,
      );

      if (requestId != null) {
        _service.invoke('registerRouteAck', {'requestId': requestId});
      }
    } catch (e) {
      dev.log(
        'Background: Error in registerRoute listener: $e',
        name: 'BackgroundHandlers',
      );
    }
  }

  void _handleRegisterRouteDirections(Map<String, dynamic>? data) async {
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

      await _callbacks.onRegisterRouteDirections(
        directions: directions,
        origin: origin,
        destination: destination,
        transitMode: transitMode,
        destinationName: destinationName,
      );

      if (requestId != null) {
        _service.invoke('registerRouteDirectionsAck', {'requestId': requestId});
      }
    } catch (e) {
      dev.log(
        'Background: Error in registerRouteDirections: $e',
        name: 'BackgroundHandlers',
      );
    }
  }

  void _handleInjectPosition(Map<String, dynamic>? data) {
    try {
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
      LocationManager().injectPosition(p);
    } catch (e) {
      gpsLog.warn(
        'Failed to parse injected position',
        data: {'error': e.toString()},
      );
    }
  }
}
