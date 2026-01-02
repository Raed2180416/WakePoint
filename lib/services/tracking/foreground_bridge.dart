// lib/services/tracking/foreground_bridge.dart
//
// Handles foreground ↔ background isolate communication for TrackingService.
// - ACK-based reliable invoke with retry
// - Heartbeat sending to background service
// - Stream listeners for route switch events, location updates, alarm triggers

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:geowake2/core/logging/app_logger.dart';
// Re-export RouteSwitchEvent and ActiveRouteState from active_route_manager
import 'package:geowake2/services/active_route_manager.dart';
export 'package:geowake2/services/active_route_manager.dart'
    show RouteSwitchEvent, ActiveRouteState;
import 'package:geowake2/services/notification_service.dart';

/// Manages foreground-to-background isolate communication.
/// Handles reliable invoke with ACKs, heartbeat sending, and event forwarding.
class ForegroundBridge {
  final FlutterBackgroundService _service;
  final bool Function() _isTestMode;

  bool _ackListenersRegistered = false;
  int _invokeRequestCounter = 0;
  final Map<String, Completer<void>> _pendingAcks = {};

  Timer? _heartbeatSendTimer;

  // Stream controllers for forwarding events from background
  final _routeStateCtrl = StreamController<ActiveRouteState>.broadcast();
  final _routeSwitchCtrl = StreamController<RouteSwitchEvent>.broadcast();
  final _locationCtrl = StreamController<Position>.broadcast();

  // Callback for when alarm is triggered from background
  void Function(String title, String body, bool allowContinue)? onAlarmTrigger;

  ForegroundBridge({
    required FlutterBackgroundService service,
    required bool Function() isTestMode,
  }) : _service = service,
       _isTestMode = isTestMode;

  Stream<ActiveRouteState> get activeRouteStateStream => _routeStateCtrl.stream;
  Stream<RouteSwitchEvent> get routeSwitchStream => _routeSwitchCtrl.stream;
  Stream<Position> get locationStream => _locationCtrl.stream;

  /// Ensures all ACK and event listeners are registered on the service.
  /// Call this before any invoke operations.
  void ensureListenersRegistered() {
    if (_ackListenersRegistered || _isTestMode()) return;
    _ackListenersRegistered = true;

    // ACK listeners for reliable invokes
    _service.on('registerRouteAck').listen(_handleAck);
    _service.on('registerRouteDirectionsAck').listen(_handleAck);
    _service.on('startTrackingAck').listen(_handleAck);

    // Route switch events
    _service.on('activeRouteSwitch').listen(_handleActiveRouteSwitch);
    _service.on('activeRouteUpdate').listen(_handleActiveRouteUpdate);
    _service.on('routeSwitch').listen(_handleRouteSwitch);

    // Alarm trigger from background
    _service.on('triggerAlarm').listen(_handleTriggerAlarm);

    // Location updates
    _service.on('updateLocation').listen(_handleLocationUpdate);
  }

  void _handleAck(Map<String, dynamic>? data) {
    final requestId = data?['requestId'] as String?;
    if (requestId == null) return;
    final completer = _pendingAcks.remove(requestId);
    completer?.complete();
  }

  void _handleActiveRouteSwitch(Map<String, dynamic>? data) {
    if (data == null) return;
    try {
      final fromKey = data['fromKey'] as String;
      final toKey = data['toKey'] as String;
      final atStr = data['at'] as String?;
      final at = atStr != null ? DateTime.tryParse(atStr) : null;

      // Geometry decoding
      List<LatLng>? geom;
      try {
        dynamic geomRaw = data['geometry'];
        if (geomRaw is String) geomRaw = jsonDecode(geomRaw);
        if (geomRaw is List) {
          geom =
              geomRaw.map((p) {
                final m = p as Map;
                return LatLng(
                  (m['lat'] as num).toDouble(),
                  (m['lng'] as num).toDouble(),
                );
              }).toList();
        }
      } catch (e) {
        dev.log('Error decoding geometry: $e', name: 'ForegroundBridge');
      }

      // Inactive polylines decoding
      List<List<LatLng>>? inactivePolylines;
      try {
        dynamic inactiveRaw = data['inactivePolylines'];
        if (inactiveRaw is String) inactiveRaw = jsonDecode(inactiveRaw);
        if (inactiveRaw is List) {
          inactivePolylines =
              inactiveRaw.map((poly) {
                return (poly as List).map((p) {
                  final m = p as Map;
                  return LatLng(
                    (m['lat'] as num).toDouble(),
                    (m['lng'] as num).toDouble(),
                  );
                }).toList();
              }).toList();
        }
      } catch (e) {
        dev.log(
          'Error decoding inactivePolylines: $e',
          name: 'ForegroundBridge',
        );
      }

      _routeSwitchCtrl.add(
        RouteSwitchEvent(
          fromKey: fromKey,
          toKey: toKey,
          at: at,
          geometry: geom,
          inactivePolylines: inactivePolylines,
        ),
      );
    } catch (e) {
      dev.log(
        'Error processing activeRouteSwitch: $e',
        name: 'ForegroundBridge',
      );
    }
  }

  void _handleActiveRouteUpdate(Map<String, dynamic>? data) {
    if (data == null) return;
    try {
      final state = ActiveRouteState.fromJson(Map<String, dynamic>.from(data));
      _routeStateCtrl.add(state);
    } catch (e) {
      dev.log(
        'Failed to parse active route state: $e',
        name: 'ForegroundBridge',
      );
    }
  }

  void _handleRouteSwitch(Map<String, dynamic>? data) {
    if (data == null) return;
    try {
      final fromKey = data['fromKey'] as String;
      final toKey = data['toKey'] as String;
      final timestamp = DateTime.tryParse(data['timestamp'] as String? ?? '');
      final pointsList = data['points'] as List?;

      List<LatLng>? geometry;
      if (pointsList != null) {
        geometry =
            pointsList.map((p) {
              final m = p as Map;
              return LatLng(
                (m['lat'] as num).toDouble(),
                (m['lng'] as num).toDouble(),
              );
            }).toList();
      }

      _routeSwitchCtrl.add(
        RouteSwitchEvent(
          fromKey: fromKey,
          toKey: toKey,
          at: timestamp,
          geometry: geometry,
        ),
      );
    } catch (e) {
      dev.log(
        'Failed to parse routeSwitch event: $e',
        name: 'ForegroundBridge',
      );
    }
  }

  void _handleTriggerAlarm(Map<String, dynamic>? data) async {
    dev.log(
      'Foreground received triggerAlarm from background',
      name: 'ForegroundBridge',
    );
    if (data == null) return;
    try {
      final title = data['title'] as String? ?? 'Time to Wake Up!';
      final body =
          data['body'] as String? ?? 'You are approaching your destination';
      final allowContinue = data['allowContinue'] as bool? ?? false;

      if (onAlarmTrigger != null) {
        onAlarmTrigger!(title, body, allowContinue);
      } else {
        // Fallback: call notification service directly
        await NotificationService().showWakeUpAlarm(
          title: title,
          body: body,
          allowContinueTracking: allowContinue,
        );
      }
    } catch (e) {
      dev.log(
        'Foreground triggerAlarm handler error: $e',
        name: 'ForegroundBridge',
      );
    }
  }

  void _handleLocationUpdate(Map<String, dynamic>? data) {
    if (data == null) return;
    try {
      final lat = (data['latitude'] as num).toDouble();
      final lng = (data['longitude'] as num).toDouble();
      final pos = Position(
        latitude: lat,
        longitude: lng,
        timestamp: DateTime.now(),
        accuracy: 10.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: 0.0,
        headingAccuracy: 0.0,
        speed: (data['speed'] as num?)?.toDouble() ?? 0.0,
        speedAccuracy: 0.0,
      );
      _locationCtrl.add(pos);
    } catch (e) {
      trackingLog.warn(
        'Failed to parse updateLocation data',
        data: {'error': e.toString()},
      );
    }
  }

  /// Invoke a method on the background service with automatic retry and ACK.
  /// Returns true if ACK was received, false if all retries exhausted.
  Future<bool> invokeWithAckRetry({
    required String method,
    required Map<String, dynamic> args,
    required String ackEvent,
  }) async {
    if (_isTestMode()) return false;

    ensureListenersRegistered();

    // Optimized retry delays: fast initial attempt, escalating backoff
    final delays = <Duration>[
      const Duration(milliseconds: 30),
      const Duration(milliseconds: 80),
      const Duration(milliseconds: 150),
      const Duration(milliseconds: 300),
      const Duration(milliseconds: 500),
    ];
    const ackTimeout = Duration(milliseconds: 400);

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
        await completer.future.timeout(ackTimeout);
        return true;
      } catch (_) {
        _pendingAcks.remove(requestId);
      }

      await Future<void>.delayed(delays[attempt]);
    }

    dev.log(
      'CRITICAL: No ACK received for $method ($ackEvent), giving up',
      name: 'ForegroundBridge',
    );
    return false;
  }

  /// Start sending heartbeats to the background service.
  void startHeartbeat() async {
    if (_isTestMode()) return;
    _heartbeatSendTimer?.cancel();

    final running = await _service.isRunning();
    if (!running) return;

    // Send initial heartbeat immediately
    _sendHeartbeat();
    // Then send every second
    _heartbeatSendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sendHeartbeat();
    });
  }

  void _sendHeartbeat() async {
    if (_isTestMode()) return;
    final running = await _service.isRunning();
    if (!running) return;
    try {
      _service.invoke('foregroundHeartbeat', {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}
  }

  /// Stop sending heartbeats.
  void stopHeartbeat() {
    _heartbeatSendTimer?.cancel();
    _heartbeatSendTimer = null;
  }

  /// Notify background that foreground has resumed.
  Future<void> notifyForegroundResumed() async {
    if (_isTestMode()) return;
    final running = await _service.isRunning();
    if (running) {
      try {
        _service.invoke('foregroundResumed', {});
      } catch (e) {
        trackingLog.debug(
          'foregroundResumed invoke failed',
          data: {'error': e.toString()},
        );
      }
    }
  }

  /// Invoke a method on the background service (fire and forget).
  void invoke(String method, [Map<String, dynamic>? args]) {
    if (_isTestMode()) return;
    try {
      _service.invoke(method, args);
    } catch (_) {}
  }

  /// Check if background service is running.
  Future<bool> isRunning() => _service.isRunning();

  void dispose() {
    stopHeartbeat();
    _routeStateCtrl.close();
    _routeSwitchCtrl.close();
    _locationCtrl.close();
    _pendingAcks.clear();
  }
}
