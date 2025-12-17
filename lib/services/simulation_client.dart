import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'package:geowake2/config/playground_bridge.dart';
import 'package:geolocator/geolocator.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/foundation.dart';

class SimulationClient {
  SimulationClient({this.onConnected, this.onFirstPositionReceived});

  /// Optional hook to run when a connection is successfully established.
  final VoidCallback? onConnected;

  /// Optional hook to run when the first position is received from dashboard.
  /// This indicates the dashboard is actively sending positions.
  final VoidCallback? onFirstPositionReceived;

  /// Callback for when dashboard requests alarm state reset (e.g., progress slider moved backward)
  VoidCallback? _onAlarmReset;

  /// Tracks whether we've received at least one position from the dashboard.
  bool _hasReceivedPosition = false;

  WebSocketChannel? _channel;
  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();

  Position? _lastSimPosition;
  DateTime? _lastSimTimestamp;

  Timer? _reconnectTimer;
  Timer? _connectionCheckTimer;
  String _host = PlaygroundBridgeConfig.relayUrl;
  bool _shouldBeConnected = false;
  int _reconnectAttempts = 0;
  DateTime? _lastPingReceived;

  Stream<Position> get positionStream => _positionController.stream;
  bool get active => _channel != null;
  bool get isConnected => _channel != null && _lastPingReceived != null;

  /// Set the callback to be invoked when dashboard requests alarm reset
  set onAlarmReset(VoidCallback? callback) => _onAlarmReset = callback;

  Future<void> connect({String? host}) async {
    if (!PlaygroundBridgeConfig.enabled) return;

    _host = host ?? PlaygroundBridgeConfig.relayUrl;
    _shouldBeConnected = true;
    await _attemptConnection();
  }

  Future<void> _attemptConnection() async {
    if (!PlaygroundBridgeConfig.enabled) return;
    if (!_shouldBeConnected || _channel != null) return;

    try {
      print(
        'SimulationClient: Attempting connection to $_host (attempt ${_reconnectAttempts + 1})',
      );
      _channel = WebSocketChannel.connect(Uri.parse(_host));
      // IMPORTANT:
      // `WebSocketChannel.connect(...)` can return a channel whose underlying
      // connection handshake completes asynchronously via a `ready` Future.
      // If that `ready` Future completes with an error and nobody awaits/handles
      // it, the Dart runtime may report it as an unhandled exception, which can
      // kill the isolate and stop alarms entirely.
      try {
        final dynamic ch = _channel;
        final dynamic ready = ch?.ready;
        if (ready is Future) {
          unawaited(
            ready
                .then((_) {
                  _reconnectAttempts = 0; // Reset only after handshake success
                  print('SimulationClient: Connected to $_host');
                  try {
                    onConnected?.call();
                  } catch (_) {}
                  // Start connection health monitoring
                  _startConnectionMonitoring();
                })
                .catchError((e) {
                  print('SimulationClient: Connection failed (ready) $e');
                  _handleDisconnection();
                }),
          );
        } else {
          // Fallback for channel implementations without `ready`.
          _reconnectAttempts = 0;
          print('SimulationClient: Connected to $_host');
          try {
            onConnected?.call();
          } catch (_) {}
          _startConnectionMonitoring();
        }
      } catch (_) {
        // If introspecting `ready` fails for any reason, proceed with stream
        // listen and rely on onError/onDone to reconnect.
      }

      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onDone: () {
          print('SimulationClient: Disconnected');
          _handleDisconnection();
        },
        onError: (error) {
          print('SimulationClient: Error $error');
          _handleDisconnection();
        },
        cancelOnError: true,
      );
    } catch (e) {
      print('SimulationClient: Connection failed $e');
      _handleDisconnection();
    }
  }

  void _startConnectionMonitoring() {
    // Check connection health every 15 seconds
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(const Duration(seconds: 15), (
      timer,
    ) {
      if (_lastPingReceived != null) {
        final timeSinceLastPing = DateTime.now().difference(_lastPingReceived!);
        if (timeSinceLastPing.inSeconds > 90) {
          // No ping received for 90 seconds, connection is likely dead
          print(
            'SimulationClient: No ping received for ${timeSinceLastPing.inSeconds}s, reconnecting...',
          );
          _handleDisconnection();
        }
      }
    });
  }

  void _handleDisconnection() {
    final sink = _channel?.sink;
    if (sink != null) {
      try {
        // WebSocketSink.close() returns a Future; if it completes with an error
        // and nobody awaits/handles it, the runtime can treat it as unhandled.
        unawaited(sink.close().catchError((_) {}));
      } catch (_) {}
    }
    _channel = null;
    _connectionCheckTimer?.cancel();
    _lastPingReceived = null;

    if (_shouldBeConnected) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    // Exponential backoff: 1s, 2s, 4s, 8s, max 30s
    final delay = Duration(seconds: (1 << _reconnectAttempts).clamp(1, 30));

    print('SimulationClient: Reconnecting in ${delay.inSeconds}s...');
    _reconnectTimer = Timer(delay, () {
      _reconnectAttempts++;
      _attemptConnection();
    });
  }

  void disconnect() {
    _shouldBeConnected = false;
    _reconnectTimer?.cancel();
    _connectionCheckTimer?.cancel();
    final sink = _channel?.sink;
    if (sink != null) {
      try {
        unawaited(sink.close().catchError((_) {}));
      } catch (_) {}
    }
    _channel = null;
    _lastPingReceived = null;
    _hasReceivedPosition = false;
  }

  void broadcastRoute({
    required String destinationName,
    required List<Map<String, dynamic>> points,
    List<Map<String, dynamic>>? segments,
    List<Map<String, dynamic>>? switchPoints,
    List<Map<String, dynamic>>? events,
    bool? transitMode,
  }) {
    if (!PlaygroundBridgeConfig.enabled || _channel == null) return;
    try {
      final state = {
        'type': 'route_update',
        'destinationName': destinationName,
        'points': points,
        'segments': segments,
        'switch_points': switchPoints,
        'events': events,
        if (transitMode != null) 'transit_mode': transitMode,
      };
      _channel!.sink.add(jsonEncode(state));
    } catch (e) {
      print('SimulationClient: Send failed $e');
      _handleDisconnection();
    }
  }

  void broadcastState({
    required int etaSeconds,
    required double distanceTravelled,
    required String alarmMode,
    required double alarmValue,
    required bool alarmFired,
    double? remainingStops,
    Map<String, dynamic>? debugInfo,
  }) {
    if (!PlaygroundBridgeConfig.enabled || _channel == null) return;
    try {
      final state = {
        'type': 'app_state',
        'eta': etaSeconds,
        'distance_travelled': distanceTravelled,
        'alarm_mode': alarmMode,
        'alarm_value': alarmValue,
        'alarm_fired': alarmFired,
        if (remainingStops != null) 'remaining_stops': remainingStops,
        if (debugInfo != null) 'debug_info': debugInfo,
      };
      _channel!.sink.add(jsonEncode(state));
    } catch (e) {
      print('SimulationClient: Send failed $e');
      _handleDisconnection();
    }
  }

  void _handleMessage(dynamic data) {
    try {
      final json = jsonDecode(data);

      // Handle ping from server
      if (json['type'] == 'ping') {
        _lastPingReceived = DateTime.now();
        // Send pong response
        try {
          _channel?.sink.add(
            jsonEncode({
              'type': 'pong',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }),
          );
        } catch (e) {
          print('SimulationClient: Failed to send pong: $e');
        }
        return;
      }

      // Handle alarm state reset (e.g., when dashboard progress slider moves backward)
      if (json['type'] == 'reset_alarm_state') {
        print('SimulationClient: Received alarm state reset');
        _onAlarmReset?.call();
        dev.log(
          'DEBUG: simulation_client - called onAlarmReset callback',
          name: 'SimulationClient',
        );
        return;
      }

      if (json['type'] == 'simulation_update') {
        final double lat = json['lat'];
        final double lng = json['lng'];
        final int timestamp =
            json['timestamp'] ?? DateTime.now().millisecondsSinceEpoch;

        final ts = DateTime.fromMillisecondsSinceEpoch(timestamp);

        // Estimate speed from successive simulation points so time-based alarm
        // gating behaves realistically during playground runs.
        double speedMps = 0.0;
        try {
          if (_lastSimPosition != null && _lastSimTimestamp != null) {
            final dtSeconds =
                ts.difference(_lastSimTimestamp!).inMilliseconds / 1000.0;
            if (dtSeconds > 0.0) {
              final dMeters = Geolocator.distanceBetween(
                _lastSimPosition!.latitude,
                _lastSimPosition!.longitude,
                lat,
                lng,
              );
              final raw = dMeters / dtSeconds;
              // Clamp outliers (e.g., occasional timestamp jumps)
              speedMps = raw.isFinite ? raw.clamp(0.0, 60.0) : 0.0;
            }
          }
        } catch (_) {
          speedMps = 0.0;
        }

        final pos = Position(
          latitude: lat,
          longitude: lng,
          timestamp: ts,
          accuracy: 10.0,
          altitude: 0.0,
          heading: 0.0,
          speed: speedMps,
          speedAccuracy: 0.0,
          altitudeAccuracy: 0.0,
          headingAccuracy: 0.0,
        );

        _lastSimPosition = pos;
        _lastSimTimestamp = ts;

        // Notify that dashboard is actively sending positions
        if (!_hasReceivedPosition) {
          _hasReceivedPosition = true;
          try {
            onFirstPositionReceived?.call();
          } catch (_) {}
        }

        print(
          'DEBUG: SimulationClient adding position to stream: (${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}) speed=${speedMps.toStringAsFixed(2)}',
        );
        dev.log(
          'DEBUG: SimulationClient adding position to stream: (${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}) speed=${speedMps.toStringAsFixed(2)}',
          name: 'SimulationClient',
        );
        _positionController.add(pos);
      }
    } catch (e) {
      print('SimulationClient: Parse error $e');
    }
  }

  // Clean up resources
  void dispose() {
    disconnect();
    _positionController.close();
  }
}
