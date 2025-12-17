import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'config/playground_bridge.dart';
import 'simulation_engine.dart'; // Import the engine

void main() {
  runApp(const DashboardApp());
}

class DashboardApp extends StatelessWidget {
  const DashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoWake Simulation Dashboard',
      theme: ThemeData.dark(),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};

  // Route Data State
  List<Map<String, dynamic>>? _segments;

  List<Map<String, dynamic>>? _routeEvents; // For Alarm Markers

  // Track last loaded route signature to avoid resetting the map on repeated broadcasts.
  String? _lastRouteSignature;

  String _computeRouteSignature(List<LatLng> pts, String? dest) {
    if (pts.isEmpty) return dest ?? '';
    double sum = 0;
    // Sample points to avoid huge strings but remain robust against small changes.
    final step = (pts.length / 20).ceil().clamp(1, 50);
    for (int i = 0; i < pts.length; i += step) {
      sum += pts[i].latitude.toStringAsFixed(5).hashCode;
      sum += pts[i].longitude.toStringAsFixed(5).hashCode;
    }
    final first = pts.first;
    final last = pts.last;
    return '${dest ?? ''}|${pts.length}|${first.latitude.toStringAsFixed(6)},${first.longitude.toStringAsFixed(6)}|${last.latitude.toStringAsFixed(6)},${last.longitude.toStringAsFixed(6)}|$sum';
  }

  // WebSocket
  html.WebSocket? _socket;
  bool _connected = false;
  String _status = 'Disconnected';
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  DateTime? _lastPingReceived;

  String _resolveRelayUrl() {
    final override = Uri.base.queryParameters['relay'];
    if (override != null && override.isNotEmpty) {
      return override;
    }
    final configured = PlaygroundBridgeConfig.relayUrl;
    if (configured.startsWith('ws://') &&
        html.window.location.protocol == 'https:') {
      return configured.replaceFirst('ws://', 'wss://');
    }
    return configured;
  }

  // Metrics
  String _metricDistance = '---';
  String _metricTime = '---';
  String _metricStops = '---';

  String _metricAlarm = '---';
  String _metricDebug = '---';

  // Advanced Features State
  bool _gpsEnabled = true;
  bool _alarmTriggered = false;
  DateTime? _rerouteStartTime;
  int? _rerouteLatencyMs;
  List<Map<String, dynamic>> _savedRoutes = [];
  List<LatLng> _deviationRoute = []; // Secondary route for testing deviation
  bool _transitMode =
      false; // Track if current route is transit mode (for segment coloring)

  // Simulation Engine
  final SimulationEngine _engine = SimulationEngine();
  Timer? _loopTimer;

  // Demo Route (London)
  final List<LatLng> _demoRoute = [
    const LatLng(51.5074, -0.1278), // Trafalgar Sq
    const LatLng(51.5033, -0.1195), // London Eye
    const LatLng(51.5007, -0.1246), // Big Ben
    const LatLng(51.4995, -0.1273), // Westminster Abbey
  ];

  // State for naming
  String? _currentDestinationName;
  List<String> _eventLogs = [];
  bool _wasPlayingBeforeScrub = false;

  @override
  void initState() {
    super.initState();
    _loadSavedRoutes();
    _connectToRelay();
    _logEvent('System initialized.');

    // Load demo route initially
    _engine.loadRoute(_demoRoute);
    _updateMapRoute(_demoRoute);

    // Start Loop (30 FPS)
    _loopTimer = Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (_engine.isPlaying) {
        _engine.update(0.033);
        _updateGhostMarker();
        _broadcastPosition();
      }
    });

    // Connection health monitoring (check every 30 seconds)
    Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_lastPingReceived != null) {
        final timeSinceLastPing = DateTime.now().difference(_lastPingReceived!);
        if (timeSinceLastPing.inSeconds > 90 && _connected) {
          // No ping received for 90 seconds, trigger reconnection
          _logEvent(
            'Connection timeout (no ping for ${timeSinceLastPing.inSeconds}s)',
          );
          setState(() {
            _connected = false;
            _status = 'Timeout';
          });
          _socket?.close();
        }
      }
    });
  }

  void _logEvent(String message) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _eventLogs.insert(0, '[$time] $message');
      if (_eventLogs.length > 50) _eventLogs.removeLast();
    });
  }

  @override
  void dispose() {
    _loopTimer?.cancel();
    _reconnectTimer?.cancel();
    _socket?.close();
    super.dispose();
  }

  void _connectToRelay() {
    if (_socket != null && _socket!.readyState == html.WebSocket.OPEN) return;

    try {
      _socket = html.WebSocket(_resolveRelayUrl());

      _socket!.onOpen.listen((_) {
        setState(() {
          _connected = true;
          _status = 'Connected';
          _reconnectAttempts = 0; // Reset on successful connection
          _lastPingReceived = DateTime.now();
        });
        _logEvent('Connected to Relay Server');
        _reconnectTimer?.cancel(); // Cancel any pending reconnect
      });

      _socket!.onMessage.listen((event) {
        _handleMessage(event.data);
      });

      _socket!.onClose.listen((_) {
        setState(() {
          _connected = false;
          _status = 'Disconnected';
        });
        _logEvent('Disconnected from Relay');
        _scheduleReconnect();
      });

      _socket!.onError.listen((error) {
        setState(() {
          _connected = false;
          _status = 'Error: $error';
        });
        _logEvent('Connection Error: $error');
        _scheduleReconnect();
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
      _logEvent('Connection Error: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    // Exponential backoff: 1s, 2s, 4s, 8s, max 30s
    final delay = Duration(seconds: (1 << _reconnectAttempts).clamp(1, 30));

    _logEvent('Reconnecting in ${delay.inSeconds}s...');
    _reconnectTimer = Timer(delay, () {
      _reconnectAttempts++;
      _connectToRelay();
    });
  }

  void _handleMessage(String data) {
    try {
      final json = jsonDecode(data);

      // Handle ping from server
      if (json['type'] == 'ping') {
        _lastPingReceived = DateTime.now();
        // Send pong response
        if (_socket != null && _socket!.readyState == html.WebSocket.OPEN) {
          _socket!.send(
            jsonEncode({
              'type': 'pong',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }),
          );
        }
        return;
      }

      if (json['type'] == 'route_update') {
        final List<dynamic> pointsJson = json['points'];
        final List<LatLng> points =
            pointsJson.map((p) => LatLng(p['lat'], p['lng'])).toList();

        final segments =
            (json['segments'] as List?)?.cast<Map<String, dynamic>>();
        final switchPoints =
            (json['switch_points'] as List?)?.cast<Map<String, dynamic>>();
        final events = (json['events'] as List?)?.cast<Map<String, dynamic>>();
        final transitMode = json['transit_mode'] as bool? ?? false;

        final destName = json['destinationName'] as String?;
        _currentDestinationName = destName;
        final sig = _computeRouteSignature(points, destName);

        _logEvent(
          'RX Route: ${points.length} pts, ${segments?.length} segs, ${switchPoints?.length} switches, transitMode=$transitMode',
        );
        _logEvent('Keys: ${json.keys.toList()}'); // Debug keys
        final isSameRoute = _lastRouteSignature == sig;

        setState(() {
          _segments = segments; // Store for alarm updates
          _routeEvents = events;
          _transitMode = transitMode; // Store transit mode for save/load

          if (!isSameRoute) {
            _engine.loadRoute(points);
            _updateMapRoute(
              points,
              segments: segments,
              switchPoints: switchPoints,
              routeEvents: events,
              transitMode: transitMode,
            );
            _lastRouteSignature = sig;

            // Move camera to start only when the route actually changes.
            if (points.isNotEmpty) {
              _mapController?.animateCamera(
                CameraUpdate.newLatLngZoom(points.first, 14),
              );
            }

            // Reroute Latency Check
            if (_rerouteStartTime != null) {
              _rerouteLatencyMs =
                  DateTime.now().difference(_rerouteStartTime!).inMilliseconds;
              _rerouteStartTime = null; // Reset
            }
          } else {
            // Same route rebroadcast: just refresh alarms/segments without resetting camera.
            _updateAlarmMarkers();
          }
        });
      } else if (json['type'] == 'app_state') {
        setState(() {
          if (json['eta'] != null) {
            final int etaSec = (json['eta'] as num).toInt();
            _metricTime = '${(etaSec / 60).toStringAsFixed(1)} min';
          }

          if (json['distance_travelled'] != null) {
            final double dist = (json['distance_travelled'] as num).toDouble();
            _metricDistance = '${(dist / 1000).toStringAsFixed(2)} km traveled';
          }

          if (json['alarm_mode'] != null) {
            _currentAlarmMode = json['alarm_mode'] as String;
            _currentAlarmValue = (json['alarm_value'] as num).toDouble();
            _metricAlarm = '${json['alarm_mode']} (${json['alarm_value']})';
            _updateAlarmMarkers();
          }

          if (json['remaining_stops'] != null) {
            final double stops = (json['remaining_stops'] as num).toDouble();
            _metricStops = stops.toStringAsFixed(1);
          }

          if (json['alarm_fired'] == true) {
            if (!_alarmTriggered) _logEvent('ALARM FIRED!');
            _alarmTriggered = true;
            // Auto-reset after 5 seconds
            Timer(const Duration(seconds: 5), () {
              if (mounted) setState(() => _alarmTriggered = false);
            });
          }

          if (json['debug_info'] != null) {
            final info = json['debug_info'] as Map<String, dynamic>;
            // Keep this lightweight; it's a diagnostics pane.
            final parts = <String>[];
            if (info['destination'] != null)
              parts.add('dest=${info['destination']}');
            if (info['active_key'] != null)
              parts.add('key=${info['active_key']}');
            if (info['snap_offset_m'] != null)
              parts.add('off=${info['snap_offset_m']}m');
            if (info['progress_m'] != null)
              parts.add('prog=${info['progress_m']}m');
            if (info['progress_jump_m'] != null)
              parts.add('jump=${info['progress_jump_m']}m');
            if (info['next_event_type'] != null)
              parts.add('next=${info['next_event_type']}');
            if (info['to_next_event_m'] != null)
              parts.add('toNext=${info['to_next_event_m']}m');
            if (info['poly_total_m'] != null && info['step_total_m'] != null) {
              parts.add(
                'poly/step=${info['poly_total_m']}/${info['step_total_m']}',
              );
            }
            // Backwards-compat with older debug keys.
            if (info['stepBounds'] != null)
              parts.add('Bounds:${info['stepBounds']}');
            if (info['stepStops'] != null)
              parts.add('Stops:${info['stepStops']}');
            if (info['routeEvents'] != null)
              parts.add('Events:${info['routeEvents']}');
            _metricDebug = parts.join(' | ');
          }
        });
      }
    } catch (e) {
      print('Dashboard: Error parsing message: $e');
    }
  }

  void _broadcastPosition() {
    if (_socket != null &&
        _socket!.readyState == html.WebSocket.OPEN &&
        _engine.currentPosition != null) {
      if (!_gpsEnabled) return; // Simulate GPS Drop

      final pos = _engine.currentPosition!;
      final msg = jsonEncode({
        'type': 'simulation_update',
        'lat': pos.latitude,
        'lng': pos.longitude,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      _socket!.send(msg);
    }
  }

  void _broadcastAlarmReset() {
    dev.log(
      'DEBUG: main_dashboard - _broadcastAlarmReset called',
      name: 'MainDashboard',
    );
    if (_socket != null && _socket!.readyState == html.WebSocket.OPEN) {
      final msg = jsonEncode({
        'type': 'reset_alarm_state',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      _socket!.send(msg);
      dev.log(
        'DEBUG: main_dashboard - Sent alarm state reset message',
        name: 'MainDashboard',
      );
      // Also reset local alarm triggered flag
      setState(() => _alarmTriggered = false);
    } else {
      dev.log(
        'DEBUG: main_dashboard - WebSocket not connected, cannot send reset',
        name: 'MainDashboard',
      );
    }
  }

  void _saveCurrentRoute() {
    if (_engine.route.isEmpty) return;
    final points = _engine.route;

    String name = 'Route ${DateTime.now().toIso8601String().substring(11, 19)}';
    if (_currentDestinationName != null) {
      // Abbreviate to 2 words max
      final words = _currentDestinationName!.split(' ');
      if (words.length > 2) {
        name = '${words[0]} ${words[1]}';
      } else {
        name = _currentDestinationName!;
      }
    }

    final routeData = <String, dynamic>{
      'name': name,
      'points':
          points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
      // Save alarm parameters for re-running simulations with same settings
      if (_currentAlarmMode != null) 'alarmMode': _currentAlarmMode,
      if (_currentAlarmValue != null) 'alarmValue': _currentAlarmValue,
      // Save segments for consistent visual display when loading
      if (_segments != null && _segments!.isNotEmpty) 'segments': _segments,
      // Save route events for alarm position markers
      if (_routeEvents != null && _routeEvents!.isNotEmpty)
        'events': _routeEvents,
      // Save transit mode for correct segment coloring
      'transitMode': _transitMode,
    };

    setState(() {
      _savedRoutes.add(routeData);
    });
    html.window.localStorage['saved_routes'] = jsonEncode(_savedRoutes);
    _logEvent(
      'Route saved: $name (mode: $_currentAlarmMode, value: $_currentAlarmValue, transit: $_transitMode)',
    );
  }

  void _deleteRoute(int index) {
    setState(() {
      final removed = _savedRoutes.removeAt(index);
      _logEvent('Route deleted: ${removed['name']}');
    });
    html.window.localStorage['saved_routes'] = jsonEncode(_savedRoutes);
  }

  void _loadSavedRoutes() {
    final jsonStr = html.window.localStorage['saved_routes'];
    if (jsonStr != null) {
      try {
        final List<dynamic> list = jsonDecode(jsonStr);
        setState(() {
          _savedRoutes = list.cast<Map<String, dynamic>>();
        });
      } catch (e) {
        print('Error loading routes: $e');
      }
    }
  }

  void _loadRoute(Map<String, dynamic> routeData) {
    final List<dynamic> pointsJson = routeData['points'];
    final List<LatLng> points =
        pointsJson.map((p) => LatLng(p['lat'], p['lng'])).toList();

    // Restore saved segments if available
    final segments =
        (routeData['segments'] as List?)?.cast<Map<String, dynamic>>();
    final events = (routeData['events'] as List?)?.cast<Map<String, dynamic>>();
    final savedTransitMode = routeData['transitMode'] as bool? ?? false;

    // Restore saved alarm parameters if available
    final savedAlarmMode = routeData['alarmMode'] as String?;
    final savedAlarmValue = routeData['alarmValue'] as num?;

    setState(() {
      _engine.loadRoute(points);
      _segments = segments;
      _routeEvents = events;
      _transitMode = savedTransitMode;

      // Restore alarm display
      if (savedAlarmMode != null && savedAlarmValue != null) {
        _currentAlarmMode = savedAlarmMode;
        _currentAlarmValue = savedAlarmValue.toDouble();
        _metricAlarm = '$savedAlarmMode ($savedAlarmValue)';
      }

      _updateMapRoute(
        points,
        segments: segments,
        routeEvents: events,
        transitMode: savedTransitMode,
      );
      if (points.isNotEmpty) {
        _mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(points.first, 14),
        );
      }
    });
    _logEvent(
      'Loaded saved route: ${routeData['name']} (mode: $savedAlarmMode, value: $savedAlarmValue, transit: $savedTransitMode)',
    );
  }

  void _forceDeviation() {
    if (_engine.currentPosition == null) return;

    LatLng targetPos;

    if (_deviationRoute.isNotEmpty) {
      // Smart Deviation: Snap to closest point on deviation route
      // Simple implementation: find closest vertex
      double minDst = double.infinity;
      LatLng? closest;
      for (final p in _deviationRoute) {
        final d =
            (p.latitude - _engine.currentPosition!.latitude).abs() +
            (p.longitude - _engine.currentPosition!.longitude).abs();
        if (d < minDst) {
          minDst = d;
          closest = p;
        }
      }
      targetPos = closest!;

      // Switch engine to deviation route
      // Find index of closest point to start from there
      final idx = _deviationRoute.indexOf(closest);
      final remaining = _deviationRoute.sublist(idx);
      _engine.loadRoute(remaining);

      // Visual feedback: Make deviation route the "active" one (Blue/Solid) for now
      // In a real scenario, we'd want to see if the App *detects* this.
      // So we keep the App's route as "Active" (Green/Purple) and just move the ghost.
    } else {
      // Legacy: Move 500m North-East
      final current = _engine.currentPosition!;
      targetPos = LatLng(current.latitude + 0.005, current.longitude + 0.005);
    }

    setState(() {
      _engine.currentPosition = targetPos; // Teleport
      _rerouteStartTime = DateTime.now(); // Start timer
      _rerouteLatencyMs = null;
    });
    _updateGhostMarker();
    _logEvent('Forced Deviation triggered');
  }

  void _loadDeviationRoute(Map<String, dynamic> routeData) {
    final List<dynamic> pointsJson = routeData['points'];
    setState(() {
      _deviationRoute =
          pointsJson.map((p) => LatLng(p['lat'], p['lng'])).toList();
      _updateMapRoute(_polylines.first.points); // Refresh map to draw deviation
    });
    _logEvent('Loaded deviation route: ${routeData['name']}');
  }

  void _updateMapRoute(
    List<LatLng> points, {
    List<Map<String, dynamic>>? segments,
    List<Map<String, dynamic>>? switchPoints,
    List<Map<String, dynamic>>? routeEvents,
    bool transitMode = false,
  }) {
    setState(() {
      _segments = segments;
      _routeEvents = routeEvents;
      _polylines.clear();
      _polylines.clear();
      // Keep alarm markers, clear route markers?
      // Rebuild specific markers below
      _markers.removeWhere((m) => !m.markerId.value.startsWith('alarm_pred_'));

      // Draw Deviation Route (Grey Dashed) if exists
      if (_deviationRoute.isNotEmpty) {
        _polylines.add(
          Polyline(
            polylineId: const PolylineId('route_deviation'),
            points: _deviationRoute,
            color: Colors.grey,
            width: 4,
            patterns: [PatternItem.dash(20), PatternItem.gap(10)],
            zIndex: 0,
          ),
        );
      }

      if (segments != null && segments.isNotEmpty) {
        final transitColorMap = <String, Color>{};
        const transitColors = <Color>[Colors.green, Colors.purple];
        int transitColorIndex = 0;
        for (int i = 0; i < segments.length; i++) {
          final seg = segments[i];
          final mode = seg['mode'] as String;
          print(
            'Dash: Drawing seg $i mode=$mode pts=${(seg['points'] as List).length}',
          );
          final segPoints =
              (seg['points'] as List)
                  .map((p) => LatLng(p['lat'], p['lng']))
                  .toList();

          Color color;
          List<PatternItem> patterns = [];

          // Match App Styling (DirectionService.dart):
          // - Driving/Walking are non_transit: blue (walking is dashed)
          // - Transit in transitMode with SUBWAY/HEAVY_RAIL/RAIL: green/purple
          // - Other transit types (BUS etc.) or transit when transitMode=false: blue
          switch (mode) {
            case 'driving':
              color = Colors.blue;
              patterns = []; // Solid
              break;
            case 'transit':
              // Check if this is a metro-type transit (SUBWAY, HEAVY_RAIL, RAIL)
              // Only apply green/purple coloring if transitMode is true AND vehicle is metro type
              final vehicleType = seg['vehicle_type'] as String?;
              final isMetroTransit =
                  transitMode &&
                  (vehicleType == 'SUBWAY' ||
                      vehicleType == 'HEAVY_RAIL' ||
                      vehicleType == 'RAIL');

              if (isMetroTransit) {
                // Deterministic mapping by transit line label
                final rawLine = seg['transit_line'];
                final line = rawLine is String ? rawLine.trim() : '';
                if (line.isNotEmpty) {
                  if (!transitColorMap.containsKey(line)) {
                    transitColorMap[line] =
                        transitColors[transitColorIndex % transitColors.length];
                    transitColorIndex++;
                  }
                  color = transitColorMap[line]!;
                } else {
                  // Fallback for metro without line label
                  if (!transitColorMap.containsKey('_fallback_$i')) {
                    transitColorMap['_fallback_$i'] =
                        transitColors[transitColorIndex % transitColors.length];
                    transitColorIndex++;
                  }
                  color = transitColorMap['_fallback_$i']!;
                }
              } else {
                // Non-metro transit (BUS, etc.) or not in transitMode: use blue
                color = Colors.blue;
              }
              patterns = []; // Solid
              break;
            case 'walking':
              color = Colors.blue; // App uses Blue for walking
              patterns = [PatternItem.dash(20), PatternItem.gap(12)]; // Dashed
              break;
            default:
              color = Colors.blue;
              patterns = [];
          }

          _polylines.add(
            Polyline(
              polylineId: PolylineId('seg_$i'),
              points: segPoints,
              color: color,
              width: 5,
              patterns: patterns,
              // Metro transit gets higher zIndex like in the app
              zIndex: (mode == 'transit' && transitMode) ? 3 : 2,
            ),
          );
        }
      } else {
        _polylines.add(
          Polyline(
            polylineId: const PolylineId('route_active'),
            points: points,
            color: Colors.blue,
            width: 5,
          ),
        );
      }

      if (switchPoints != null) {
        for (int i = 0; i < switchPoints.length; i++) {
          final sp = switchPoints[i];
          _markers.add(
            Marker(
              markerId: MarkerId('switch_$i'),
              position: LatLng(sp['lat'], sp['lng']),
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor
                    .hueBlue, // User requested Blue for switch points
              ),
              infoWindow: InfoWindow(title: sp['label'] ?? 'Switch Point'),
            ),
          );
        }
      }

      // Add Start and End Markers (Red)
      if (points.isNotEmpty) {
        _markers.add(
          Marker(
            markerId: const MarkerId('route_start'),
            position: points.first,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            infoWindow: const InfoWindow(title: 'Start'),
          ),
        );
        _markers.add(
          Marker(
            markerId: const MarkerId('route_end'),
            position: points.last,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            infoWindow: const InfoWindow(title: 'Destination'),
          ),
        );
      }
    });
  }

  void _updateGhostMarker() {
    if (_engine.currentPosition == null) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == 'ghost');
      _markers.add(
        Marker(
          markerId: const MarkerId('ghost'),
          position: _engine.currentPosition!,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueBlue,
          ), // Blue for simulated user
          infoWindow: const InfoWindow(title: 'Simulated User'),
          zIndex: 10, // Ensure user is on top
        ),
      );
    });

    // Optional: Camera follow
    _mapController?.animateCamera(
      CameraUpdate.newLatLng(_engine.currentPosition!),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GeoWake Dashboard v2 (Active)'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                _status,
                style: TextStyle(
                  color: _connected ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left Panel: Controls
          Container(
            width: 300,
            color: Colors.grey[900],
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Simulation Controls',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: Icon(
                          _engine.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                        onPressed: () {
                          setState(
                            () => _engine.isPlaying = !_engine.isPlaying,
                          );
                          _logEvent(
                            _engine.isPlaying
                                ? 'Simulation Resumed'
                                : 'Simulation Paused',
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: () {
                          setState(() {
                            _engine.currentPosition = null;
                            _engine.seek(0.0);
                            _engine.isPlaying = false;
                            // Clear ghosts and alarm markers
                            _markers.removeWhere(
                              (m) =>
                                  m.markerId.value == 'ghost' ||
                                  m.markerId.value.startsWith('alarm_'),
                            );
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Speed Control
                  const Text('Speed Multiplier'),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: _engine.speedMultiplier,
                          min: 1.0,
                          max: 200.0, // Increased to 200x for 2hr -> 1min
                          divisions: 199,
                          label:
                              '${_engine.speedMultiplier.toStringAsFixed(0)}x',
                          onChanged:
                              (v) =>
                                  setState(() => _engine.speedMultiplier = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Progress Control
                  const Text('Progress'),
                  Slider(
                    value: _engine.progress,
                    onChanged: (v) {
                      final oldProgress = _engine.progress;
                      setState(() {
                        _engine.seek(v);
                        _updateGhostMarker();
                        _broadcastPosition();
                      });
                      // If progress moved backwards significantly, request alarm state reset
                      if (v < oldProgress - 0.05) {
                        _broadcastAlarmReset();
                      }
                    },
                    onChangeStart: (_) {
                      // Optional: Pause while scrubbing
                      _wasPlayingBeforeScrub = _engine.isPlaying;
                      setState(() => _engine.isPlaying = false);
                    },
                    onChangeEnd: (_) {
                      if (_wasPlayingBeforeScrub) {
                        setState(() => _engine.isPlaying = true);
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  // Chaos Controls
                  const Text(
                    'Chaos Engineering',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('GPS Signal'),
                      Switch(
                        value: _gpsEnabled,
                        onChanged: (v) {
                          setState(() => _gpsEnabled = v);
                          _logEvent('GPS Signal ${v ? "Restored" : "Lost"}');
                        },
                        activeColor: Colors.green,
                        inactiveThumbColor: Colors.red,
                      ),
                    ],
                  ),
                  ElevatedButton.icon(
                    onPressed: _forceDeviation,
                    icon: const Icon(Icons.fork_right),
                    label: const Text('Force Deviation'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                    ),
                  ),

                  const SizedBox(height: 20),
                  // Route Management
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Route Management',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.save),
                        onPressed: _saveCurrentRoute,
                        tooltip: 'Save Current Route',
                      ),
                    ],
                  ),
                  if (_savedRoutes.isNotEmpty)
                    SizedBox(
                      height: 150,
                      child: ListView.builder(
                        itemCount: _savedRoutes.length,
                        itemBuilder: (ctx, i) {
                          final route = _savedRoutes[i];
                          return ListTile(
                            dense: true,
                            title: Text(route['name']),
                            // Play = Load as Active
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    size: 16,
                                    color: Colors.red,
                                  ),
                                  onPressed: () => _deleteRoute(i),
                                  tooltip: 'Delete Route',
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.fork_right,
                                    size: 16,
                                    color: Colors.orange,
                                  ),
                                  onPressed: () => _loadDeviationRoute(route),
                                  tooltip: 'Load as Deviation',
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.play_arrow,
                                    size: 16,
                                    color: Colors.green,
                                  ),
                                  onPressed: () => _loadRoute(route),
                                  tooltip: 'Load as Active',
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),

                  const SizedBox(height: 20),
                  const Text(
                    'Alarm Metrics',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Divider(),
                  _buildMetric('Distance', _metricDistance),
                  _buildMetric('Time', _metricTime),
                  _buildMetric('Stops', _metricStops),

                  _buildMetric('Alarm', _metricAlarm),
                  _buildMetric('Debug', _metricDebug),
                  if (_rerouteLatencyMs != null)
                    _buildMetric('Reroute Latency', '${_rerouteLatencyMs}ms'),

                  if (_alarmTriggered)
                    Container(
                      padding: const EdgeInsets.all(8),
                      color: Colors.red,
                      child: const Text(
                        'ALARM TRIGGERED!',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),

                  const SizedBox(height: 20),
                  const Text(
                    'Event Log',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Divider(),
                  // Fixed height event log
                  SizedBox(
                    height: 200,
                    child: ListView.builder(
                      itemCount: _eventLogs.length,
                      itemBuilder: (ctx, i) {
                        return Text(
                          _eventLogs[i],
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Right Panel: Map
          Expanded(
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _demoRoute.first,
                    zoom: 14,
                  ),
                  onMapCreated: (ctrl) => _mapController = ctrl,
                  markers: _markers,
                  polylines: _polylines,
                ),
                // Route legend overlay (match MapTrackingScreen)
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Material(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return Wrap(
                            spacing: 12,
                            runSpacing: 6,
                            alignment: WrapAlignment.start,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: const [
                              _LegendItem(
                                color: Colors.blue,
                                dashed: false,
                                label: 'Driving',
                              ),
                              _LegendItem(
                                color: Colors.blue,
                                dashed: true,
                                label: 'Walking',
                              ),
                              _LegendItem(
                                color: Colors.green,
                                dashed: false,
                                label: 'Metro Line A',
                              ),
                              _LegendItem(
                                color: Colors.purple,
                                dashed: false,
                                label: 'Metro Line B',
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetric(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  // --- Helper Methods ---

  void _updateAlarmMarkers() {
    setState(() {
      _markers.removeWhere((m) => m.markerId.value.startsWith('alarm_pred_'));
    });
    if (_currentAlarmMode == null ||
        _currentAlarmValue == null ||
        _routeEvents == null) {
      // Fallback for purely distance based legacy/test routes without events
      if ((_routeEvents == null || _routeEvents!.isEmpty) &&
          _segments != null) {
        // Keep existing segment-based fallback or just return?
        // Let's keep a minimal fallback for walking start
      }
      if (_routeEvents == null) return;
    }

    print(
      'DashDebug: Updating Alarm Markers with ${_routeEvents!.length} events',
    );

    for (int i = 0; i < _routeEvents!.length; i++) {
      final ev = _routeEvents![i];
      final type = ev['type'];
      final label = ev['label'];
      final lat = ev['lat'];
      final lng = ev['lng'];

      if (lat == null || lng == null) continue;

      String title = 'Alarm Point';
      String snippet = label ?? '';
      String triggerNote = '';

      // Logic for Marker Title based on Alarm Mode & Event Type
      if (_currentAlarmMode == 'distance') {
        // Distance mode: Everything is "N km before"
        title = type == 'transfer' ? 'Transfer Point' : 'Switch Point';
        triggerNote = 'Alarm triggers ${_currentAlarmValue}km before';
      } else if (_currentAlarmMode == 'stops') {
        // Stops mode
        if (type == 'transfer') {
          title = 'Transfer Point';
          triggerNote =
              'Alarm triggers ${_currentAlarmValue?.toInt()} stops before';
        } else if (type == 'mode_change') {
          if (label.toString().contains('Board')) {
            // Walking -> Transit: use distance fallback
            title = 'Boarding Point';
            triggerNote =
                'Alarm triggers ~500m × ${_currentAlarmValue?.toInt()} before';
          } else if (label.toString().contains('Start walking')) {
            // Transit -> Walk (Alight)
            title = 'Alight Point';
            triggerNote =
                'Alarm triggers ${_currentAlarmValue?.toInt()} stops before';
          } else {
            title = 'Switch Point';
            triggerNote = 'Alarm triggers before this point';
          }
        }
      } else {
        // Time mode or unknown
        title = type == 'transfer' ? 'Transfer Point' : 'Switch Point';
        triggerNote = 'Alarm triggers before this point';
      }

      // Combine label and trigger note in snippet
      if (snippet.isNotEmpty && triggerNote.isNotEmpty) {
        snippet = '$snippet\n$triggerNote';
      } else if (triggerNote.isNotEmpty) {
        snippet = triggerNote;
      }

      _addPredictedMarker(
        LatLng(lat, lng),
        title,
        idSuffix: '_ev_$i',
        snippet: snippet,
        hue: BitmapDescriptor.hueViolet,
      );
    }

    // Always add a "Final Destination" distance alarm marker if purely walking/driving?
    // StopLogicEngine handles the logical triggering.
    // Dashboard just needs to show WHERE the trigger happens.
    // For "Switch Alarm", the marker is AT the switch point.
    // The "trigger" happens before it.
    // The previous logic calculated the "trigger point" (1km before).
    // The user wants to see the "Predicted Alarm Marker".
    // If it's 1km before, I should calculate it along the path.
    // But I don't have the path easily map-able to events here without complex logic.
    // The previous logic `_getPointAtDistanceFromEnd` worked on segments.
    // But segments were missing.

    // COMPROMISE: Place the marker AT the Switch Point (Violet),
    // but label it "Alarm triggers 1km before" or "N stops before".
    // This is clearer than guessing a point on a line that might be wrong.
    // User feedback: "translucent marker... only shows up for the first one".
    // If I place it AT the station, they know that's the target.
    // (Previously I tried to place it 1km BEFORE).

    // Let's stick to placing it AT the target for now, as calculating "1km back from event N"
    // requires mapping Event N to a specific Polyline Segment and traversing back.
    // Given the segment alignment issues, placing at Target is safer/robust.
  }

  void _addPredictedMarker(
    LatLng pos,
    String title, {
    String idSuffix = '',
    String? snippet,
    double hue = BitmapDescriptor.hueYellow,
  }) {
    setState(() {
      _markers.add(
        Marker(
          markerId: MarkerId('alarm_pred$idSuffix'),
          position: pos,
          icon: BitmapDescriptor.defaultMarkerWithHue(hue),
          alpha: 0.5, // Translucent for expected alarm markers
          infoWindow: InfoWindow(title: title, snippet: snippet),
        ),
      );
    });
  }

  // Add state variables
  String? _currentAlarmMode;
  double? _currentAlarmValue;
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final bool dashed;
  final String label;
  const _LegendItem({
    required this.color,
    required this.dashed,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          painter: _LineSamplePainter(color: color, dashed: dashed),
          size: const Size(28, 6),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      ],
    );
  }
}

class _LineSamplePainter extends CustomPainter {
  final Color color;
  final bool dashed;
  _LineSamplePainter({required this.color, required this.dashed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = color
          ..strokeWidth = 4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    } else {
      const double dashWidth = 8.0;
      const double dashSpace = 6.0;
      double x = 0.0;
      while (x < size.width) {
        final double x2 =
            (x + dashWidth) > size.width ? size.width : (x + dashWidth);
        canvas.drawLine(Offset(x, y), Offset(x2, y), paint);
        x += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
