import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class SimulationClient {
  WebSocketChannel? _channel;
  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();

  Stream<Position> get positionStream => _positionController.stream;
  bool get active => _channel != null;

  Future<void> connect({String host = 'ws://localhost:8080'}) async {
    if (!kDebugMode) return; // SAFETY: No-op in release

    try {
      _channel = WebSocketChannel.connect(Uri.parse(host));
      print('SimulationClient: Connected to $host');

      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onDone: () {
          print('SimulationClient: Disconnected');
          _channel = null;
        },
        onError: (error) {
          print('SimulationClient: Error $error');
          _channel = null;
        },
      );
    } catch (e) {
      print('SimulationClient: Connection failed $e');
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _channel = null;
  }

  void broadcastState(Map<String, dynamic> state) {
    if (!kDebugMode || _channel == null) return;
    try {
      _channel!.sink.add(jsonEncode(state));
    } catch (e) {
      print('SimulationClient: Send failed $e');
    }
  }

  void _handleMessage(dynamic data) {
    try {
      final json = jsonDecode(data);
      if (json['type'] == 'simulation_update') {
        final double lat = json['lat'];
        final double lng = json['lng'];
        final int timestamp =
            json['timestamp'] ?? DateTime.now().millisecondsSinceEpoch;

        final pos = Position(
          latitude: lat,
          longitude: lng,
          timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
          accuracy: 10.0,
          altitude: 0.0,
          heading: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
          altitudeAccuracy: 0.0,
          headingAccuracy: 0.0,
        );

        _positionController.add(pos);
      }
    } catch (e) {
      print('SimulationClient: Parse error $e');
    }
  }
}
