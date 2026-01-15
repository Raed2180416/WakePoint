/// Integrated deviation simulation dashboard.
///
/// Combines OSM overlay, time warp controls, constraint logging,
/// and simulation control into a unified testing interface.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import '../config/playground_bridge.dart';
import '../core/clock/app_clock.dart';
import '../services/direction_service.dart';
import '../services/testing/osm_loader.dart';
import '../services/testing/osm_graph.dart';
import 'constraint_drawer.dart';
import 'constraint_logger.dart';
import 'deviation_simulation_controller.dart';
import 'osm_overlay_manager.dart';
import 'simulation_controls.dart';
import 'simulation_state.dart';
import 'speed_slider.dart';
import 'time_warp_slider.dart';

/// Entry point for the deviation simulation dashboard.
class DeviationDashboardApp extends StatelessWidget {
  const DeviationDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoWake Deviation Simulator',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(
          primary: Colors.orange,
          secondary: Colors.teal,
        ),
      ),
      home: const DeviationDashboard(),
    );
  }
}

/// Main deviation dashboard screen.
class DeviationDashboard extends StatefulWidget {
  const DeviationDashboard({super.key});

  @override
  State<DeviationDashboard> createState() => _DeviationDashboardState();
}

class _DeviationDashboardState extends State<DeviationDashboard> {
  // Map controller
  GoogleMapController? _mapController;

  // Simulation controller
  DeviationSimulationController? _simController;

  // OSM overlay
  final OsmOverlayManager _osmOverlay = OsmOverlayManager();
  bool _osmVisible = true;

  // Map elements
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  // UI state
  bool _drawerOpen = false;
  double _warpFactor = 1.0;
  double _speedKmh = 40.0;

  bool _wasPlayingBeforeScrub = false;

  // Constraint events
  List<ConstraintEvent> _events = [];
  StreamSubscription<ConstraintEvent>? _eventSub;

  // Position updates
  StreamSubscription<SimulationTickResult>? _positionSub;
  StreamSubscription<SimulationState>? _stateSub;

  // WebSocket
  html.WebSocket? _socket;
  bool _connected = false;
  Timer? _reconnectTimer;

  // Route data
  List<LatLng> _activeRoute = [];

  // Raw segments data for proper polyline coloring (like MapTrackingScreen)
  List<Map<String, dynamic>> _activeRouteRawSegments = [];

  // Stored polylines for original route (to restore after deviation)
  List<Polyline> _originalRoutePolylines = [];

  // Direction service for building colored polylines
  final DirectionService _directionService = DirectionService();

  // Demo route (Bengaluru)
  final List<LatLng> _demoRoute = [
    const LatLng(12.9716, 77.5946), // MG Road
    const LatLng(12.9766, 77.5993), // Trinity
    const LatLng(12.9850, 77.6050), // Indiranagar
    const LatLng(12.9900, 77.6150), // HAL
    const LatLng(12.9950, 77.6250), // Airport Road
  ];

  @override
  void initState() {
    super.initState();
    _initializeSimulation();
    _connectToRelay();
    _subscribeToConstraints();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _positionSub?.cancel();
    _stateSub?.cancel();
    _simController?.dispose();
    _reconnectTimer?.cancel();
    _socket?.close();
    super.dispose();
  }

  void _initializeSimulation() async {
    // Prefer real Bengaluru OSM graph (generated from tools/osm_preprocessor.py).
    // Fallback to a tiny synthetic grid if the asset isn't present yet.
    OsmGraph graph;
    try {
      graph = await OsmLoader.loadAsset('assets/osm/bengaluru.wkp');
      _logInfo('Loaded OSM graph: assets/osm/bengaluru.wkp');
    } catch (e) {
      graph = OsmLoader.createTestGraph();
      _logInfo('Using test OSM graph (no bengaluru.wkp yet): $e');
    }

    final controller = DeviationSimulationController(
      graph: graph,
      config: const DeviationSimulationConfig(
        deviationDistanceM: 300,
        routeAvoidanceRadiusM: 50,
        returnThresholdM: 25,
      ),
    );

    // Subscribe to position updates
    _positionSub?.cancel();
    _stateSub?.cancel();
    _positionSub = controller.positionStream.listen(_onPositionUpdate);
    _stateSub = controller.stateStream.listen((_) => setState(() {}));

    setState(() {
      _simController = controller;
      // Load demo route
      _simController!.loadRoute(_demoRoute, routeId: 'demo_bengaluru');
      _activeRoute = _demoRoute;
      _updateRoutePolylines();
    });
  }

  void _subscribeToConstraints() {
    _eventSub = ConstraintLogger.instance.eventStream.listen((event) {
      setState(() {
        _events.insert(0, event);
        // Keep last 200 events
        if (_events.length > 200) {
          _events = _events.sublist(0, 200);
        }
      });
      // Broadcast to connected WebSocket clients
      _broadcastConstraintEvent(event);
    });
  }

  void _onPositionUpdate(SimulationTickResult tick) {
    setState(() {
      _updateSimulationMarker(tick);
    });
    _broadcastPosition(tick);
  }

  void _clearEvents() {
    setState(() {
      _events.clear();
    });
    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Logs Cleared',
        description: 'Event log was manually cleared',
      ),
    );
  }

  void _updateSimulationMarker(SimulationTickResult tick) {
    _markers.removeWhere((m) => m.markerId.value == 'sim_position');
    _markers.add(
      Marker(
        markerId: const MarkerId('sim_position'),
        position: tick.position,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(
          title: 'Simulated Position',
          snippet:
              '${(tick.speedMps * 3.6).toStringAsFixed(0)} km/h | ${tick.distanceFromRoute.toStringAsFixed(0)}m from route',
        ),
        zIndexInt: 100,
        rotation: tick.heading,
        anchor: const Offset(0.5, 0.5),
      ),
    );

    // Update deviation path polyline
    _updateDeviationPolyline();
  }

  void _updateRoutePolylines() {
    // Remove route-related polylines
    _polylines.removeWhere(
      (p) =>
          p.polylineId.value.startsWith('route_seg_') ||
          p.polylineId.value == 'original_route' ||
          p.polylineId.value.startsWith('grey_route_seg_') ||
          p.polylineId.value == 'deviation_path' ||
          p.polylineId.value == 'current_path',
    );

    final controller = _simController;
    final isDeviating =
        controller?.state == SimulationState.deviating ||
        controller?.state == SimulationState.returning;

    if (_activeRoute.isEmpty) return;

    // If we have raw segments data, use colored polylines
    if (_activeRouteRawSegments.isNotEmpty) {
      if (isDeviating) {
        // Grey out the original route
        _addGreyRoutePolylines();
      } else {
        // Show colored original route
        _addColoredRoutePolylines();
      }
    } else {
      // Fallback to simple blue polyline
      final color = isDeviating ? Colors.grey : Colors.blue;
      _polylines.add(
        Polyline(
          polylineId: const PolylineId('original_route'),
          points: _activeRoute,
          color: color,
          width: 5,
          zIndex: 1,
        ),
      );
    }
  }

  /// Add colored polylines from raw segments (like MapTrackingScreen).
  void _addColoredRoutePolylines() {
    final polylines = _directionService.buildSegmentedPolylinesFromRawSegments(
      _activeRouteRawSegments,
    );

    // Store for later restoration
    _originalRoutePolylines = polylines;

    // Rename polyline IDs to avoid conflicts
    for (int i = 0; i < polylines.length; i++) {
      final p = polylines[i];
      _polylines.add(
        Polyline(
          polylineId: PolylineId('route_seg_$i'),
          points: p.points,
          color: p.color,
          width: p.width,
          patterns: p.patterns,
          zIndex: p.zIndex,
        ),
      );
    }
  }

  /// Add greyed-out polylines for original route when deviating.
  void _addGreyRoutePolylines() {
    // Use stored polylines but make them grey
    if (_originalRoutePolylines.isNotEmpty) {
      for (int i = 0; i < _originalRoutePolylines.length; i++) {
        final p = _originalRoutePolylines[i];
        _polylines.add(
          Polyline(
            polylineId: PolylineId('grey_route_seg_$i'),
            points: p.points,
            color: Colors.grey.withValues(alpha: 0.5),
            width: p.width,
            patterns: p.patterns,
            zIndex: 0, // Behind deviation path
          ),
        );
      }
    } else if (_activeRoute.isNotEmpty) {
      // Fallback if no stored polylines
      _polylines.add(
        Polyline(
          polylineId: const PolylineId('original_route'),
          points: _activeRoute,
          color: Colors.grey.withValues(alpha: 0.5),
          width: 5,
          zIndex: 0,
        ),
      );
    }
  }

  /// Load route with raw segments for proper coloring.
  void loadRouteWithSegments(
    List<LatLng> route,
    List<Map<String, dynamic>> rawSegments, {
    String? routeId,
  }) {
    setState(() {
      _activeRoute = route;
      _activeRouteRawSegments = rawSegments;
      _originalRoutePolylines = []; // Clear stored, will rebuild
      _simController?.loadRoute(route, routeId: routeId);
      _updateRoutePolylines();
    });
  }

  void _updateDeviationPolyline() {
    _polylines.removeWhere(
      (p) =>
          p.polylineId.value == 'deviation_path' ||
          p.polylineId.value == 'current_path',
    );

    final controller = _simController;
    if (controller == null) return;

    final state = controller.state;

    // Update route polylines based on state (grey when deviating)
    _updateRoutePolylines();

    // Deviation path (orange, dashed effect via pattern)
    if (controller.deviationPath.isNotEmpty &&
        (state == SimulationState.deviating ||
            state == SimulationState.returning)) {
      _polylines.add(
        Polyline(
          polylineId: const PolylineId('deviation_path'),
          points: controller.deviationPath,
          color: Colors.orange,
          width: 4,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
          zIndex: 2,
        ),
      );
    }

    // Current path being followed (green/teal)
    if (controller.currentPath.isNotEmpty && state != SimulationState.idle) {
      Color pathColor;
      int pathWidth;
      List<PatternItem> patterns = [];

      switch (state) {
        case SimulationState.onRoute:
          // When on route, current path IS the original route - no overlay needed
          // The route is already shown with proper coloring
          return;
        case SimulationState.deviating:
          pathColor = Colors.deepOrange;
          pathWidth = 5;
          break;
        case SimulationState.returning:
          pathColor = Colors.teal;
          pathWidth = 4;
          patterns = [PatternItem.dash(15), PatternItem.gap(8)];
          break;
        default:
          return;
      }

      _polylines.add(
        Polyline(
          polylineId: const PolylineId('current_path'),
          points: controller.currentPath,
          color: pathColor,
          width: pathWidth,
          patterns: patterns,
          zIndex: 3,
        ),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // WebSocket
  // ─────────────────────────────────────────────────────────────────────

  String _resolveRelayUrl() {
    final override = Uri.base.queryParameters['relay'];
    if (override != null && override.isNotEmpty) return override;
    final configured = PlaygroundBridgeConfig.relayUrl;
    if (configured.startsWith('ws://') &&
        html.window.location.protocol == 'https:') {
      return configured.replaceFirst('ws://', 'wss://');
    }
    return configured;
  }

  void _connectToRelay() {
    try {
      _socket = html.WebSocket(_resolveRelayUrl());

      _socket!.onOpen.listen((_) {
        setState(() => _connected = true);
        _logInfo('Connected to relay');
        _reconnectTimer?.cancel();
      });

      _socket!.onMessage.listen((event) {
        _handleMessage(event.data);
      });

      _socket!.onClose.listen((_) {
        setState(() => _connected = false);
        _scheduleReconnect();
      });

      _socket!.onError.listen((_) {
        setState(() => _connected = false);
        _scheduleReconnect();
      });
    } catch (e) {
      _logError('Connection error: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), _connectToRelay);
  }

  void _handleMessage(String data) {
    try {
      final json = jsonDecode(data);

      if (json['type'] == 'simulation_control') {
        _handleSimulationControl(json);
      } else if (json['type'] == 'route_update') {
        _handleRouteUpdate(json);
      } else if (json['type'] == 'ping') {
        _socket?.send(
          jsonEncode({
            'type': 'pong',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      }
    } catch (e) {
      _logError('Message parse error: $e');
    }
  }

  void _handleSimulationControl(Map<String, dynamic> json) {
    final action = json['action'] as String?;
    switch (action) {
      case 'start_deviation':
        _simController?.startDeviation();
        break;
      case 'stop_deviation':
        _simController?.stopDeviation();
        break;
      case 'go_back':
        _simController?.goBackToRoute();
        break;
      case 'set_warp':
        final factor = (json['warpFactor'] as num?)?.toDouble() ?? 1.0;
        _setWarpFactor(factor);
        break;
      case 'set_speed':
        final speedKmh = (json['speedKmh'] as num?)?.toDouble() ?? 40.0;
        _setSpeed(speedKmh);
        break;
      case 'start':
        _simController?.start();
        break;
      case 'stop':
        _simController?.stop();
        break;
      case 'pause':
        _simController?.pause();
        break;
      case 'resume':
        _simController?.resume();
        break;
    }
  }

  void _handleRouteUpdate(Map<String, dynamic> json) {
    final pointsJson = json['points'] as List?;
    if (pointsJson == null || pointsJson.isEmpty) return;

    final points = pointsJson.map((p) => LatLng(p['lat'], p['lng'])).toList();

    // Real app payload provides raw segments under `segments`.
    final rawSegmentsJson = json['segments'] as List?;
    List<Map<String, dynamic>> rawSegments = [];
    if (rawSegmentsJson != null) {
      rawSegments =
          rawSegmentsJson.map((s) => Map<String, dynamic>.from(s)).toList();
    }

    setState(() {
      _activeRoute = points;
      _activeRouteRawSegments = rawSegments;
      _originalRoutePolylines = []; // Clear stored polylines
      _simController?.loadRoute(points, routeId: json['routeId']);
      _updateRoutePolylines();
    });

    if (points.isNotEmpty) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(points.first, 14),
      );
    }
  }

  void _broadcastAlarmReset() {
    if (_socket == null || _socket!.readyState != html.WebSocket.OPEN) return;
    try {
      _socket!.send(jsonEncode({'type': 'alarm_reset'}));
    } catch (_) {}
  }

  void _broadcastPosition(SimulationTickResult tick) {
    if (_socket == null || _socket!.readyState != html.WebSocket.OPEN) return;

    _socket!.send(
      jsonEncode({
        'type': 'simulation_update',
        'lat': tick.position.latitude,
        'lng': tick.position.longitude,
        'heading': tick.heading,
        'speedMps': tick.speedMps,
        'virtualTime': tick.virtualTime.toIso8601String(),
        'distanceFromRoute': tick.distanceFromRoute,
        'state': _simController?.state.name,
        'warpFactor': _warpFactor,
      }),
    );
  }

  void _broadcastConstraintEvent(ConstraintEvent event) {
    if (_socket == null || _socket!.readyState != html.WebSocket.OPEN) return;

    _socket!.send(
      jsonEncode({
        'type': 'constraint_event',
        'eventType': event.type.name,
        'timestamp': event.timestamp.toIso8601String(),
        'title': event.title,
        'description': event.description,
        'details': event.details,
      }),
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // Actions
  // ─────────────────────────────────────────────────────────────────────

  void _setWarpFactor(double factor) {
    setState(() {
      _warpFactor = factor;
      _simController?.setWarpFactor(factor);
    });
  }

  void _setSpeed(double speedKmh) {
    setState(() {
      _speedKmh = speedKmh;
      _simController?.speedMps = SpeedSlider.kmhToMps(speedKmh);
    });
  }

  void _toggleOsmOverlay() {
    setState(() {
      _osmVisible = !_osmVisible;
      _osmOverlay.setVisible(_osmVisible);
    });
  }

  void _logInfo(String message) {
    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Dashboard',
        description: message,
      ),
    );
  }

  void _logError(String message) {
    ConstraintLogger.instance.log(
      ConstraintEvent(
        type: ConstraintEventType.error,
        timestamp: AppClock().now(),
        title: 'Error',
        description: message,
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Row(
        children: [
          // Left control panel
          _buildControlPanel(),
          // Map
          Expanded(child: _buildMap()),
          // Constraint drawer
          ConstraintDrawer(
            events: _events,
            isOpen: _drawerOpen,
            onToggle: () => setState(() => _drawerOpen = !_drawerOpen),
            onClear: _clearEvents,
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Row(
        children: [
          const Text('GeoWake Deviation Simulator'),
          const SizedBox(width: 16),
          _buildConnectionIndicator(),
        ],
      ),
      actions: [
        // Virtual time display
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Virtual: ${_formatTime(AppClock().now())}',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
        // OSM overlay toggle
        IconButton(
          icon: Icon(
            _osmVisible ? Icons.layers : Icons.layers_outlined,
            color: _osmVisible ? Colors.orange : Colors.grey,
          ),
          tooltip: 'Toggle OSM overlay',
          onPressed: _toggleOsmOverlay,
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildConnectionIndicator() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _connected ? Icons.link : Icons.link_off,
          color: _connected ? Colors.greenAccent : Colors.redAccent,
          size: 20,
        ),
        const SizedBox(width: 4),
        Text(
          _connected ? 'Connected' : 'Disconnected',
          style: TextStyle(
            color: _connected ? Colors.greenAccent : Colors.redAccent,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildControlPanel() {
    final state = _simController?.state ?? SimulationState.idle;

    return Container(
      width: 320,
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Simulation controls
            SimulationControls(
              state: state,
              onStart: () => _simController?.start(),
              onStop: () => _simController?.stop(),
              onStartDeviation: () => _simController?.startDeviation(),
              onStopDeviation: () => _simController?.stopDeviation(),
              onGoBackToRoute: () => _simController?.goBackToRoute(),
              onPause: () => _simController?.pause(),
              onResume: () => _simController?.resume(),
            ),
            const SizedBox(height: 16),
            // Time warp slider
            TimeWarpSlider(
              warpFactor: _warpFactor,
              onChanged: _setWarpFactor,
              enabled: true,
            ),
            const SizedBox(height: 16),
            // Speed slider
            SpeedSlider(
              speedKmh: _speedKmh,
              onChanged: _setSpeed,
              enabled: true,
            ),
            const SizedBox(height: 16),
            const Text('Progress'),
            Slider(
              value: _simController?.progress ?? 0.0,
              onChanged: (v) {
                final controller = _simController;
                if (controller == null) return;
                final oldProgress = controller.progress;
                setState(() {
                  controller.seek(v);
                });
                if (v < oldProgress - 0.05) {
                  _broadcastAlarmReset();
                }
              },
              onChangeStart: (_) {
                final controller = _simController;
                if (controller == null) return;
                _wasPlayingBeforeScrub =
                    controller.state != SimulationState.idle &&
                    controller.state != SimulationState.paused;
                controller.pause();
              },
              onChangeEnd: (_) {
                if (_wasPlayingBeforeScrub) {
                  _simController?.resume();
                }
              },
            ),
            const SizedBox(height: 16),
            // Stats card
            _buildStatsCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard() {
    final controller = _simController;
    final position = controller?.currentPosition;
    final distanceFromRoute =
        position != null ? _calculateDistanceFromRoute(position) : 0.0;

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Statistics',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Divider(),
            _buildStatRow('State', controller?.state.name ?? 'idle'),
            _buildStatRow('Warp', '${_warpFactor.toStringAsFixed(0)}x'),
            _buildStatRow('Speed', '${_speedKmh.toStringAsFixed(0)} km/h'),
            _buildStatRow(
              'Progress',
              '${((controller?.progress ?? 0) * 100).toStringAsFixed(1)}%',
            ),
            _buildStatRow(
              'Distance from route',
              '${distanceFromRoute.toStringAsFixed(1)}m',
            ),
            _buildStatRow('Events logged', '${_events.length}'),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildMap() {
    // Combine OSM overlay polylines with route polylines
    final allPolylines = <Polyline>{..._osmOverlay.polylines, ..._polylines};

    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target:
                _demoRoute.isNotEmpty
                    ? _demoRoute.first
                    : const LatLng(12.9716, 77.5946),
            zoom: 14,
          ),
          onMapCreated: (ctrl) {
            _mapController = ctrl;
            // Load OSM overlay after map is ready
            _loadOsmOverlay();
          },
          markers: _markers,
          polylines: allPolylines,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: true,
        ),
        // Legend
        Positioned(top: 12, left: 12, child: _buildLegend()),
      ],
    );
  }

  Widget _buildLegend() {
    return Material(
      color: Colors.black.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: const [
            _LegendItem(color: Colors.green, label: 'Transit (Metro)'),
            _LegendItem(color: Colors.purple, label: 'Transit (Other)'),
            _LegendItem(color: Colors.blue, label: 'Walking/Driving'),
            _LegendItem(color: Colors.grey, label: 'Previous Route'),
            _LegendItem(color: Colors.deepOrange, label: 'Deviation Path'),
            _LegendItem(color: Colors.teal, label: 'Return Path'),
          ],
        ),
      ),
    );
  }

  Future<void> _loadOsmOverlay() async {
    // For now, use the test graph to generate visualization
    // In production, this would load from assets/osm/bengaluru_viz.json
    final graph = OsmLoader.createTestGraph();
    final polylines = <Polyline>{};

    int idx = 0;
    for (final node in graph.nodes) {
      for (final edge in graph.edgesFrom(node.index)) {
        final toNode = graph.nodes[edge.toIndex];
        polylines.add(
          Polyline(
            polylineId: PolylineId('osm_$idx'),
            points: [
              LatLng(node.lat, node.lon),
              LatLng(toNode.lat, toNode.lon),
            ],
            color: Colors.grey.withValues(alpha: 0.3),
            width: 1,
            // ignore: deprecated_member_use
            zIndex: 0,
          ),
        );
        idx++;
      }
    }

    setState(() {
      _osmOverlay.setPolylines(polylines);
    });
  }

  double _calculateDistanceFromRoute(LatLng position) {
    if (_activeRoute.isEmpty) return 0.0;
    double minDist = double.infinity;
    for (final point in _activeRoute) {
      final dist = _haversineDistance(position, point);
      if (dist < minDist) minDist = dist;
    }
    return minDist;
  }

  double _haversineDistance(LatLng p1, LatLng p2) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = _degToRad(p2.latitude - p1.latitude);
    final dLon = _degToRad(p2.longitude - p1.longitude);
    final a =
        _sin(dLat / 2) * _sin(dLat / 2) +
        _cos(_degToRad(p1.latitude)) *
            _cos(_degToRad(p2.latitude)) *
            _sin(dLon / 2) *
            _sin(dLon / 2);
    final c = 2 * _atan2(_sqrt(a), _sqrt(1 - a));
    return R * c;
  }

  double _degToRad(double deg) => deg * 3.14159265359 / 180.0;
  double _sin(double x) => _sinImpl(x);
  double _cos(double x) => _sinImpl(x + 3.14159265359 / 2);
  double _sqrt(double x) => x >= 0 ? _sqrtImpl(x) : 0;
  double _atan2(double y, double x) => _atan2Impl(y, x);

  // Simple implementations for web compatibility
  static double _sinImpl(double x) {
    // Taylor series approximation
    x = x % (2 * 3.14159265359);
    if (x > 3.14159265359) x -= 2 * 3.14159265359;
    if (x < -3.14159265359) x += 2 * 3.14159265359;
    double result = x;
    double term = x;
    for (int i = 1; i <= 10; i++) {
      term *= -x * x / ((2 * i) * (2 * i + 1));
      result += term;
    }
    return result;
  }

  static double _sqrtImpl(double x) {
    if (x <= 0) return 0;
    double guess = x / 2;
    for (int i = 0; i < 20; i++) {
      guess = (guess + x / guess) / 2;
    }
    return guess;
  }

  static double _atan2Impl(double y, double x) {
    if (x > 0) return _atanImpl(y / x);
    if (x < 0 && y >= 0) return _atanImpl(y / x) + 3.14159265359;
    if (x < 0 && y < 0) return _atanImpl(y / x) - 3.14159265359;
    if (x == 0 && y > 0) return 3.14159265359 / 2;
    if (x == 0 && y < 0) return -3.14159265359 / 2;
    return 0;
  }

  static double _atanImpl(double x) {
    // Taylor series for small x
    if (x.abs() > 1) {
      return (x > 0 ? 3.14159265359 / 2 : -3.14159265359 / 2) -
          _atanImpl(1 / x);
    }
    double result = x;
    double term = x;
    for (int i = 1; i <= 20; i++) {
      term *= -x * x;
      result += term / (2 * i + 1);
    }
    return result;
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }
}

/// Legend item widget.
class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 20, height: 3, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
