import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
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
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  // WebSocket
  html.WebSocket? _socket;
  bool _connected = false;
  String _status = 'Disconnected';

  // Metrics
  String _metricDistance = '---';
  String _metricTime = '---';
  String _metricStops = '---';
  String _metricAlarm = '---';

  // Advanced Features State
  bool _gpsEnabled = true;
  bool _alarmTriggered = false;
  DateTime? _rerouteStartTime;
  int? _rerouteLatencyMs;
  List<Map<String, dynamic>> _savedRoutes = [];
  List<LatLng> _deviationRoute = []; // Secondary route for testing deviation

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
    _socket?.close();
    super.dispose();
  }

  void _connectToRelay() {
    try {
      _socket = html.WebSocket('ws://localhost:8080');
      _socket!.onOpen.listen((_) {
        setState(() {
          _connected = true;
          _status = 'Connected to Relay';
        });
        _logEvent('Connected to Relay Server');
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
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
      _logEvent('Connection Error: $e');
    }
  }

  void _handleMessage(String data) {
    try {
      final json = jsonDecode(data);

      if (json['type'] == 'route_update') {
        final List<dynamic> pointsJson = json['points'];
        final List<LatLng> points =
            pointsJson.map((p) => LatLng(p['lat'], p['lng'])).toList();

        final segments =
            (json['segments'] as List?)?.cast<Map<String, dynamic>>();
        final switchPoints =
            (json['switch_points'] as List?)?.cast<Map<String, dynamic>>();

        final destName = json['destinationName'] as String?;
        _currentDestinationName = destName;

        _logEvent(
          'Route received: ${points.length} pts, ${segments?.length} segs',
        );

        setState(() {
          _engine.loadRoute(points);
          _updateMapRoute(
            points,
            segments: segments,
            switchPoints: switchPoints,
          );
          // Move camera to start
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
            _metricAlarm = '${json['alarm_mode']} (${json['alarm_value']})';
          }

          if (json['alarm_fired'] == true) {
            if (!_alarmTriggered) _logEvent('ALARM FIRED!');
            _alarmTriggered = true;
            // Auto-reset after 5 seconds
            Timer(const Duration(seconds: 5), () {
              if (mounted) setState(() => _alarmTriggered = false);
            });
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

    final routeData = {
      'name': name,
      'points':
          points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
    };

    setState(() {
      _savedRoutes.add(routeData);
    });
    html.window.localStorage['saved_routes'] = jsonEncode(_savedRoutes);
    _logEvent('Route saved: $name');
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
    setState(() {
      _engine.loadRoute(points);
      _updateMapRoute(points);
      if (points.isNotEmpty) {
        _mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(points.first, 14),
        );
      }
    });
    _logEvent('Loaded saved route: ${routeData['name']}');
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
  }) {
    setState(() {
      _polylines.clear();
      _markers.removeWhere((m) => m.markerId.value.startsWith('switch_'));

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
        int transitIndex = 0;
        for (int i = 0; i < segments.length; i++) {
          final seg = segments[i];
          final mode = seg['mode'] as String;
          final segPoints =
              (seg['points'] as List)
                  .map((p) => LatLng(p['lat'], p['lng']))
                  .toList();

          Color color;
          List<PatternItem> patterns = [];

          // Match App Styling (DirectionService.dart)
          switch (mode) {
            case 'driving':
              color = Colors.blue;
              patterns = []; // Solid
              break;
            case 'transit':
              // Alternate Green/Purple for Metro lines
              color = transitIndex % 2 == 0 ? Colors.green : Colors.purple;
              transitIndex++;
              patterns = []; // Solid
              break;
            case 'walking':
              color = Colors.blue; // App uses Blue for walking too
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
              zIndex: mode == 'transit' ? 3 : 2,
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
                sp['type'] == 'boarding'
                    ? BitmapDescriptor.hueOrange
                    : BitmapDescriptor.hueViolet,
              ),
              infoWindow: InfoWindow(title: sp['label']),
            ),
          );
        }
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
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan),
          infoWindow: const InfoWindow(title: 'Simulated User'),
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
        title: const Text('GeoWake Playground'),
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
        children: [
          // Left Panel: Controls
          Container(
            width: 300,
            color: Colors.grey[900],
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Simulation Controls',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Divider(),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _engine.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                      onPressed: () {
                        setState(() => _engine.isPlaying = !_engine.isPlaying);
                        _logEvent(
                          _engine.isPlaying
                              ? 'Simulation Resumed'
                              : 'Simulation Paused',
                        );
                      },
                    ),
                    Expanded(
                      child: Slider(
                        value: _engine.speedMultiplier,
                        min: 1.0,
                        max: 200.0, // Increased to 200x for 2hr -> 1min
                        divisions: 199,
                        label: '${_engine.speedMultiplier.toStringAsFixed(0)}x',
                        onChanged:
                            (v) => setState(() => _engine.speedMultiplier = v),
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
                    setState(() {
                      _engine.seek(v);
                      _updateGhostMarker();
                      _broadcastPosition();
                    });
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

                const Spacer(),
                const Text(
                  'Event Log',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Divider(),
                Expanded(
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
          // Right Panel: Map
          Expanded(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _demoRoute.first,
                zoom: 14,
              ),
              onMapCreated: (ctrl) => _mapController = ctrl,
              markers: _markers,
              polylines: _polylines,
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
}
