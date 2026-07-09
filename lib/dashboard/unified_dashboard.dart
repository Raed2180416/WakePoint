/// Unified End-to-End Testing Dashboard for GeoWake.
///
/// Combines simulation (send) and monitoring (receive) capabilities:
/// - Active simulation with OSM-based deviation pathfinding
/// - Passive monitoring of real device state via WebSocket
/// - Time warp controls (dashboard-only, doesn't affect app)
/// - Constraint logging with typed events
/// - Inactive route visualization with color preservation
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import '../all_india_stops.dart';
import '../config/playground_bridge.dart';
import '../core/clock/app_clock.dart';
import '../services/trackingservice.dart';
import '../services/direction_service.dart';
import '../services/testing/osm_loader.dart';
import 'constraint_drawer.dart';
import 'constraint_logger.dart';
import 'deviation_simulation_controller.dart';
import 'ekf_test_panel.dart';
import 'osm_overlay_manager.dart';
import 'simulation_controls.dart';
import 'simulation_state.dart';
import 'speed_slider.dart';
import 'time_warp_slider.dart';
import '../core/ekf/ekf_test_controller.dart';

void main() {
  runApp(const UnifiedDashboardApp());
}

/// Entry point for the unified dashboard.
class UnifiedDashboardApp extends StatelessWidget {
  const UnifiedDashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoWake Unified Dashboard',
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(
          primary: Colors.orange,
          secondary: Colors.teal,
        ),
      ),
      home: const UnifiedDashboard(),
    );
  }
}

/// Main unified dashboard combining simulation and monitoring.
class UnifiedDashboard extends StatefulWidget {
  const UnifiedDashboard({super.key});

  @override
  State<UnifiedDashboard> createState() => _UnifiedDashboardState();
}

class _UnifiedDashboardState extends State<UnifiedDashboard> {
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Core Controllers
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  GoogleMapController? _mapController;
  DeviationSimulationController? _simController;
  bool _graphLoading = false;
  (double, double, double, double)? _lastGraphWindow;
  final OsmOverlayManager _osmOverlay = OsmOverlayManager();
  final DirectionService _directionService = DirectionService();

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Map Elements
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  final Set<Marker> _stopMarkers = {};

  // Available inactive routes (for "revert to previous route" feature)
  List<Map<String, dynamic>> _availableInactiveRoutes = [];

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // WebSocket State
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  html.WebSocket? _socket;
  bool _connected = false;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  DateTime? _lastPingReceived;

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Route State (from app via WebSocket)
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  List<LatLng> _activeRoute = [];
  List<Map<String, dynamic>> _activeRouteRawSegments = [];
  String? _lastRouteKey;
  String? _lastRouteSignature;
  // ignore: unused_field
  bool _transitMode = false;
  List<Map<String, dynamic>>? _lastTransitLegsJson;
  Map<String, dynamic>? _lastRouteDebug;

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // App State Metrics (received from device)
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  String _metricDistance = '---';
  String _metricTime = '---';
  String _metricStops = '---';
  String _metricAlarm = '---';
  String _metricDebug = '---';
  // ignore: unused_field
  String? _currentAlarmMode;
  bool _trackingActive = false;
  LatLng? _devicePosition;
  DateTime? _lastDeviceLogAt;

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Simulation UI State
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  bool _drawerOpen = false;
  double _warpFactor = 1.0;
  double _speedKmh = 40.0;
  bool _wasPlayingBeforeScrub = false;

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Map State & Settings
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  bool _showAllStopsOverlay = false;

  // Cached Icons
  BitmapDescriptor? _cachedCyanIcon;
  BitmapDescriptor? _cachedYellowIcon;

  // Latest polyline-domain progress (meters) received from app debug_info.
  double? _lastProgressMetersFromApp;

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // EKF Test Mode
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  bool _ekfTestModeEnabled = false;
  EkfTestVisualization? _lastEkfViz;
  double _lastSimHeading = 0.0;

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Constraint Events
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  List<ConstraintEvent> _events = [];
  StreamSubscription<ConstraintEvent>? _eventSub;
  StreamSubscription<SimulationTickResult>? _positionSub;
  StreamSubscription<SimulationState>? _stateSub;

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Demo Route (Bengaluru)
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  final List<LatLng> _demoRoute = [
    const LatLng(12.9716, 77.5946), // MG Road
    const LatLng(12.9766, 77.5993), // Trinity
    const LatLng(12.9850, 77.6050), // Indiranagar
    const LatLng(12.9900, 77.6150), // HAL
    const LatLng(12.9950, 77.6250), // Airport Road
  ];

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  List<LatLng> _ekfTestRoutePolyline = [];

  // Ghost marker state tracking
  LatLng? _ghostMarkerPosition; // Position where GPS was toggled off
  bool? _lastGpsAvailable; // Track GPS state changes (null = not initialized)

  // Cached filtered stations from allIndiaStops for current route
  List<(LatLng position, String name)> _filteredStationsCache = [];

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Lifecycle
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  void initState() {
    super.initState();
    // Enable simulation mode to prevent premature tracking termination
    TrackingService.isTestMode = true;
    TrackingService().setSimulationMode(true);

    _initializeSimulation();
    _connectToRelay();
    _subscribeToConstraints();
    _startHealthMonitor();
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

  void _startHealthMonitor() {
    Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_lastPingReceived != null) {
        final timeSinceLastPing = DateTime.now().difference(_lastPingReceived!);
        if (timeSinceLastPing.inSeconds > 90 && _connected) {
          _logInfo(
            'Connection timeout (no ping for ${timeSinceLastPing.inSeconds}s)',
          );
          setState(() => _connected = false);
          _socket?.close();
        }
      }
    });
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Simulation Initialization
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _initializeSimulation() async {
    // Performance: Do not load the full OSM graph at startup.
    // We'll lazily load a small window when starting deviation.
    final controller = DeviationSimulationController(
      graph: null,
      config: const DeviationSimulationConfig(
        deviationDistanceM: 300,
        routeAvoidanceRadiusM: 50,
        returnThresholdM: 25,
      ),
    );

    _positionSub?.cancel();
    _stateSub?.cancel();
    _positionSub = controller.positionStream.listen(_onSimulationTick);
    _stateSub = controller.stateStream.listen((_) => setState(() {}));

    setState(() {
      _simController = controller;
      _simController!.loadRoute(_demoRoute, routeId: 'demo_bengaluru');
      _activeRoute = _demoRoute;
      _renderMapState();
    });

    _logInfo('OSM graph loads on-demand (3km window) when starting deviation.');
  }

  LatLng _nearestRoutePoint(LatLng position, List<LatLng> route) {
    if (route.isEmpty) return position;
    LatLng best = route.first;
    double bestDist = double.infinity;
    for (final p in route) {
      final d = _haversineDistance(position, p);
      if (d < bestDist) {
        bestDist = d;
        best = p;
      }
    }
    return best;
  }

  Future<void> _ensureLocalGraphLoaded() async {
    final controller = _simController;
    if (controller == null) return;
    if (_graphLoading) return;

    final pos = controller.currentPosition;
    if (pos == null) {
      _logInfo('Cannot load graph: no current position');
      return;
    }

    // User-requested perf target: local window around the simulated position.
    const radiusM = 3000.0;
    final nearestOnRoute = _nearestRoutePoint(pos, controller.originalRoute);

    final latPad = radiusM / 111000.0;
    final lonPad =
        radiusM /
        (111000.0 * cos(_degToRad(pos.latitude)).abs().clamp(0.2, 1.0));
    final minLat = min(pos.latitude, nearestOnRoute.latitude) - latPad;
    final maxLat = max(pos.latitude, nearestOnRoute.latitude) + latPad;
    final minLon = min(pos.longitude, nearestOnRoute.longitude) - lonPad;
    final maxLon = max(pos.longitude, nearestOnRoute.longitude) + lonPad;
    final window = (minLat, minLon, maxLat, maxLon);

    if (_lastGraphWindow != null && controller.hasGraph) {
      final prev = _lastGraphWindow!;
      final stillInside =
          pos.latitude >= prev.$1 &&
          pos.latitude <= prev.$3 &&
          pos.longitude >= prev.$2 &&
          pos.longitude <= prev.$4;
      if (stillInside) return;
    }

    setState(() => _graphLoading = true);
    _logInfo('Loading local OSM window (~3km) for deviation...');

    try {
      final graph = await OsmLoader.loadAssetWindowed(
        'assets/osm/bengaluru.wkp',
        centers: [pos, nearestOnRoute],
        radiusM: radiusM,
      );

      controller.setGraph(graph);
      _lastGraphWindow = window;
      _logInfo('Local OSM window loaded: ${graph.nodeCount} nodes');
    } catch (e) {
      // Fallback: small synthetic local graph around the current position.
      final graph = OsmLoader.createTestGraph(
        centerLat: pos.latitude,
        centerLon: pos.longitude,
        radiusM: radiusM,
      );
      controller.setGraph(graph);
      _lastGraphWindow = window;
      _logInfo(
        'âš ï¸ Using local test graph fallback: ${graph.nodeCount} nodes ($e)',
      );
    } finally {
      if (mounted) setState(() => _graphLoading = false);
    }
  }

  Future<void> _startDeviationOptimized() async {
    if (_graphLoading) {
      _logInfo('Graph load in progress...');
      return;
    }
    await _ensureLocalGraphLoaded();
    _simController?.startDeviation();
  }

  void _subscribeToConstraints() {
    _eventSub = ConstraintLogger.instance.eventStream.listen((event) {
      setState(() {
        _events.insert(0, event);
        if (_events.length > 200) {
          _events = _events.sublist(0, 200);
        }
      });
      _broadcastConstraintEvent(event);
    });
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Simulation Tick Handler
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _onSimulationTick(SimulationTickResult tick) {
    _logInfo(
      'ETA_DEBUG simTick: pos=(${tick.position.latitude.toStringAsFixed(5)},${tick.position.longitude.toStringAsFixed(5)}), spd=${tick.speedMps.toStringAsFixed(2)}m/s (${(tick.speedMps * 3.6).toStringAsFixed(1)}km/h), distFromRoute=${tick.distanceFromRoute.toStringAsFixed(1)}m, warp=$_warpFactor',
    );

    _broadcastSimulationPosition(tick);
    _lastSimHeading = tick.heading;
    _renderMapState();
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // WebSocket Connection
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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
    if (_socket != null && _socket!.readyState == html.WebSocket.OPEN) return;

    try {
      _socket = html.WebSocket(_resolveRelayUrl());

      _socket!.onOpen.listen((_) {
        setState(() {
          _connected = true;
          _reconnectAttempts = 0;
          _lastPingReceived = DateTime.now();
        });
        _logInfo('Connected to Relay Server');
        _reconnectTimer?.cancel();
      });

      _socket!.onMessage.listen((event) {
        _handleMessage(event.data);
      });

      _socket!.onClose.listen((_) {
        setState(() => _connected = false);
        _logInfo('Disconnected from Relay');
        _scheduleReconnect();
      });

      _socket!.onError.listen((error) {
        setState(() => _connected = false);
        _logError('Connection Error: $error');
        _scheduleReconnect();
      });
    } catch (e) {
      _logError('Connection Error: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delay = Duration(seconds: (1 << _reconnectAttempts).clamp(1, 30));
    _logInfo('Reconnecting in ${delay.inSeconds}s...');
    _reconnectTimer = Timer(delay, () {
      _reconnectAttempts++;
      _connectToRelay();
    });
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Message Handling (Bidirectional)
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _handleMessage(String data) {
    try {
      final json = jsonDecode(data);
      final type = json['type'] as String?;

      switch (type) {
        case 'ping':
          _handlePing();
          break;
        case 'route_update':
          _handleRouteUpdate(json);
          break;
        case 'app_state':
          _handleAppState(json);
          break;
        case 'device_position':
          _handleDevicePosition(json);
          break;
        case 'simulation_control':
          _handleSimulationControl(json);
          break;
      }
    } catch (e) {
      _logError('Message parse error: $e');
    }
  }

  void _handlePing() {
    _lastPingReceived = DateTime.now();
    if (_socket != null && _socket!.readyState == html.WebSocket.OPEN) {
      _socket!.send(
        jsonEncode({
          'type': 'pong',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    }
  }

  void _handleRouteUpdate(Map<String, dynamic> json) {
    final routeKey = json['route_key'] as String?;
    final pointsJson = json['points'] as List?;
    if (pointsJson == null || pointsJson.isEmpty) return;

    final points = pointsJson.map((p) => LatLng(p['lat'], p['lng'])).toList();
    final segments = (json['segments'] as List?)?.cast<Map<String, dynamic>>();
    final inactiveRoutes =
        (json['inactive_routes'] as List?)?.cast<Map<String, dynamic>>();
    final transitMode = json['transit_mode'] as bool? ?? false;
    final transitLegs =
        (json['transit_legs'] as List?)?.cast<Map<String, dynamic>>();
    final routeDebug = (json['route_debug'] as Map?)?.cast<String, dynamic>();
    final destName = json['destinationName'] as String?;

    final sig = _computeRouteSignature(points, destName);
    final isSameRoute =
        routeKey != null
            ? (_lastRouteKey == routeKey)
            : (_lastRouteSignature == sig);

    setState(() {
      _transitMode = transitMode;
      // IMPORTANT: When the app is not in transit mode, do not retain or
      // display any metro stop data.
      _lastTransitLegsJson = transitMode ? transitLegs : null;
      _lastRouteDebug = routeDebug;

      // Store inactive routes for "revert to previous route" feature
      _availableInactiveRoutes = inactiveRoutes ?? [];

      if (!isSameRoute) {
        _activeRoute = points;
        _activeRouteRawSegments = segments ?? [];
        _lastRouteSignature = sig;
        _lastRouteKey = routeKey;

        // Also load into simulation controller for testing
        _simController?.loadRoute(points, routeId: routeKey ?? 'app_route');

        if (points.isNotEmpty) {
          _mapController?.animateCamera(
            CameraUpdate.newLatLngZoom(points.first, 14),
          );
        }
      } else {
        if (routeKey != null) _lastRouteKey = routeKey;
      }

      // Full re-render on any route update
      _renderMapState();
    });

    _logInfo(
      'RX Route: ${points.length} pts, ${segments?.length ?? 0} segs, transitMode=$transitMode',
    );
    if (segments == null || segments.isEmpty) {
      _logInfo('Route update missing segments; rendering raw points');
    }

    if (routeDebug != null) {
      _logInfo('Route debug: $routeDebug');
      final usedFallback = routeDebug['used_fallback_polyline'] == true;
      final usedSimplified = routeDebug['used_simplified_polyline'] == true;
      if (usedFallback || usedSimplified) {
        _logError(
          'Route quality warning: fallback=$usedFallback, simplified=$usedSimplified, source=${routeDebug['polyline_source']}',
        );
      }
    }
  }

  void _handleAppState(Map<String, dynamic> json) {
    // Debug: log raw state received
    _logInfo(
      'ETA_DEBUG dashboard RX: eta=${json['eta']}, dist=${json['distance_travelled']}, mode=${json['alarm_mode']}, val=${json['alarm_value']}, debug=${json['debug_info']}',
    );
    setState(() {
      if (json['eta'] != null) {
        final etaSec = (json['eta'] as num).toInt();
        _metricTime = '${(etaSec / 60).toStringAsFixed(1)} min';
        _logInfo('ETA_DEBUG dashboard: etaSec=$etaSec -> $_metricTime');
      }

      if (json['distance_travelled'] != null) {
        final dist = (json['distance_travelled'] as num).toDouble();
        _metricDistance = '${(dist / 1000).toStringAsFixed(2)} km traveled';
      }

      if (json['alarm_mode'] != null) {
        _currentAlarmMode = json['alarm_mode'] as String;
        _metricAlarm = '${json['alarm_mode']} (${json['alarm_value']})';
      }

      if (json['remaining_stops'] != null) {
        final stops = (json['remaining_stops'] as num).toDouble();
        _metricStops = stops.toStringAsFixed(1);
      }

      if (json['alarm_fired'] == true) {
        ConstraintLogger.instance.log(
          ConstraintEvent(
            type: ConstraintEventType.alarmTriggered,
            timestamp: AppClock().now(),
            title: 'ALARM FIRED',
            description: 'Device alarm triggered',
          ),
        );
      }

      if (json['debug_info'] != null) {
        final info = json['debug_info'] as Map<String, dynamic>;
        final parts = <String>[];
        if (info['destination'] != null) {
          parts.add('dest=${info['destination']}');
        }
        if (info['active_key'] != null) {
          parts.add('key=${info['active_key']}');
        }
        if (info['snap_offset_m'] != null) {
          parts.add('off=${info['snap_offset_m']}m');
        }
        if (info['progress_m'] != null) {
          parts.add('prog=${info['progress_m']}m');
          final pm = info['progress_m'];
          if (pm is num) {
            _lastProgressMetersFromApp = pm.toDouble();
          }
        }
        _metricDebug = parts.join(' | ');
      }

      if (json['active'] == false && _trackingActive) {
        _trackingActive = false;
        _logInfo('Tracking ended (active=false in app_state). Clearing route.');
        _clearRouteForIdle();
      } else if (json['active'] == true) {
        _trackingActive = true;
      }
    });

    // Progress updates can change the current leg; refresh markers.
    _renderMapState();
  }

  void _handleDevicePosition(Map<String, dynamic> json) {
    if ((_simController?.state ?? SimulationState.idle) !=
            SimulationState.idle ||
        _ekfTestModeEnabled) {
      return;
    }
    final lat = (json['lat'] as num).toDouble();
    final lng = (json['lng'] as num).toDouble();
    final newPos = LatLng(lat, lng);
    final isFirst = _devicePosition == null;
    _devicePosition = newPos;

    setState(() {
      _markers.removeWhere((m) => m.markerId.value == 'device_marker');
      _markers.add(
        Marker(
          markerId: const MarkerId('device_marker'),
          position: newPos,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueOrange,
          ),
          infoWindow: const InfoWindow(title: 'Your Device'),
          zIndexInt: 50,
        ),
      );
    });

    if (isFirst) {
      _mapController?.animateCamera(CameraUpdate.newLatLngZoom(newPos, 14));
    }

    final now = DateTime.now();
    if (_lastDeviceLogAt == null ||
        now.difference(_lastDeviceLogAt!).inSeconds >= 10) {
      _logInfo(
        'Device position: ${newPos.latitude.toStringAsFixed(5)}, ${newPos.longitude.toStringAsFixed(5)}',
      );
      _lastDeviceLogAt = now;
    }
  }

  void _handleSimulationControl(Map<String, dynamic> json) {
    final action = json['action'] as String?;
    switch (action) {
      case 'start_deviation':
        _startDeviationOptimized();
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

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Broadcasting (Outbound)
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _broadcastSimulationPosition(SimulationTickResult tick) {
    if (_socket == null || _socket!.readyState != html.WebSocket.OPEN) return;

    final payload = {
      'type': 'simulation_update',
      // Use real wall-clock timestamp for the receiving app. The dashboard may
      // apply time-warp to *virtualTime*, but the injected GPS stream should
      // carry a stable monotonic-ish wall time so the app doesn't infer
      // unrealistic speeds from large spatial jumps per tick.
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'lat': tick.position.latitude,
      'lng': tick.position.longitude,
      'heading': tick.heading,
      'speedMps': tick.speedMps,
      'virtualTime': tick.virtualTime.toIso8601String(),
      'distanceFromRoute': tick.distanceFromRoute,
      'state': _simController?.state.name,
      'warpFactor': _warpFactor,
    };
    _logInfo(
      'ETA_DEBUG broadcast sim: speedMps=${tick.speedMps.toStringAsFixed(2)}, warp=$_warpFactor, routeLen=${_activeRoute.length}',
    );
    _socket!.send(jsonEncode(payload));
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

  void _broadcastAlarmReset() {
    if (_socket == null || _socket!.readyState != html.WebSocket.OPEN) return;
    _socket!.send(
      jsonEncode({
        'type': 'reset_alarm_state',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  /// Sends a command to the app to switch to a different route.
  /// This allows reverting to a previous route after rerouting.
  void _broadcastRouteSwitch(String routeKey) {
    if (_socket == null || _socket!.readyState != html.WebSocket.OPEN) return;
    _socket!.send(
      jsonEncode({
        'type': 'switch_route',
        'route_key': routeKey,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    _logInfo('Sent switch_route command for key: $routeKey');
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // EKF Test Mode Helpers
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Broadcasts an EKF test position to the connected app
  void _broadcastEkfTestPosition(LatLng pos, double accuracy, double speed) {
    if (_socket == null || _socket!.readyState != html.WebSocket.OPEN) return;
    _socket!.send(
      jsonEncode({
        'type': 'ekf_test_position',
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy': accuracy,
        'speed': speed,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // EKF Helper Methods
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _handleEkfRouteChanged(
    List<LatLng> polyline,
    dynamic stations,
  ) async {
    if (polyline.isEmpty) return;

    // Filter stations logic (Stations within 200m of route)
    final stationsOnRoute = <(LatLng position, String name)>[];
    for (final station in allIndiaStops) {
      final sLat = (station['lat'] as num).toDouble();
      final sLng = (station['lng'] as num).toDouble();
      final pos = LatLng(sLat, sLng);

      double minDist = double.infinity;
      for (final pt in polyline) {
        final d = _haversineDistance(pos, pt);
        if (d < minDist) minDist = d;
      }
      if (minDist < 200) {
        stationsOnRoute.add((pos, station['name'] as String? ?? 'Station'));
      }
    }

    setState(() {
      _ekfTestRoutePolyline = polyline;
      _filteredStationsCache = stationsOnRoute;
    });
    _renderMapState();
  }

  void _updateEkfState(EkfTestVisualization viz) {
    final lastGps = _lastGpsAvailable;
    // Ghost Marker Logic
    LatLng? newGhostPos = _ghostMarkerPosition;

    if (lastGps != null) {
      if (!viz.gpsAvailable && lastGps) {
        // GPS went OFF
        newGhostPos = viz.truePosition;
      } else if (viz.gpsAvailable && !lastGps) {
        // GPS came ON
        newGhostPos = null;
      }
    } else {
      // First update
      if (!viz.gpsAvailable) {
        newGhostPos = viz.truePosition;
      }
    }

    setState(() {
      _lastGpsAvailable = viz.gpsAvailable;
      _ghostMarkerPosition = newGhostPos;
      _lastEkfViz = viz;
    });
    _renderMapState();
  }

  String _computeRouteSignature(List<LatLng> pts, String? dest) {
    if (pts.isEmpty) return dest ?? '';
    double sum = 0;
    final step = (pts.length / 20).ceil().clamp(1, 50);
    for (int i = 0; i < pts.length; i += step) {
      sum += pts[i].latitude.toStringAsFixed(5).hashCode;
      sum += pts[i].longitude.toStringAsFixed(5).hashCode;
    }
    final first = pts.first;
    final last = pts.last;
    return '${dest ?? ''}|${pts.length}|${first.latitude.toStringAsFixed(6)},${first.longitude.toStringAsFixed(6)}|${last.latitude.toStringAsFixed(6)},${last.longitude.toStringAsFixed(6)}|$sum';
  }

  Future<void> _renderMapState() async {
    // 1. Prepare icons if needed
    _cachedCyanIcon ??= await _createCustomMarkerBitmap(
        Colors.cyanAccent.shade200,
        size: 30,
      );
    _cachedYellowIcon ??= await _createCustomMarkerBitmap(
        Colors.yellowAccent,
        size: 36,
      );

    final newMarkers = <Marker>{};
    final newPolylines = <Polyline>{};

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // A. EKF TEST MODE RENDERING
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (_ekfTestModeEnabled) {
      // A.1. EKF Route (Blue/Cyan)
      if (_ekfTestRoutePolyline.isNotEmpty) {
        newPolylines.add(
          Polyline(
            polylineId: const PolylineId('ekf_route'),
            points: _ekfTestRoutePolyline,
            color: Colors.blueAccent,
            width: 5,
            zIndex: 1,
          ),
        );
      }

      // A.2. Visualization State
      if (_lastEkfViz != null) {
        final viz = _lastEkfViz!;

        // Raw GPS Trail
        if (viz.rawGpsTrail.isNotEmpty) {
          newPolylines.add(
            Polyline(
              polylineId: const PolylineId('ekf_raw_gps_trail'),
              points: viz.rawGpsTrail,
              color: Colors.green,
              width: 3,
              zIndex: 2,
            ),
          );
        }

        // Markers
        // Ghost Marker
        if (_ghostMarkerPosition != null && !viz.gpsAvailable) {
          newMarkers.add(
            Marker(
              markerId: const MarkerId('ghost_gps'),
              position: _ghostMarkerPosition!,
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueOrange,
              ),
              alpha: 0.6,
              infoWindow: const InfoWindow(title: 'GPS Dropout Point'),
              zIndexInt: 5,
            ),
          );
        }

        // Current Position (Ekf Test)
        newMarkers.add(
          Marker(
            markerId: const MarkerId('ekf_test_current'),
            position: viz.truePosition,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              viz.gpsAvailable
                  ? BitmapDescriptor.hueBlue
                  : BitmapDescriptor.hueAzure,
            ),
            infoWindow: InfoWindow(
              title: 'Current Position',
              snippet:
                  'Speed: ${(viz.speedMps * 3.6).toStringAsFixed(1)} km/h\nMotion: ${viz.motionState.name}',
            ),
            zIndexInt: 10,
          ),
        );

        // EKF Estimated
        final ekfPos =
            viz.gpsAvailable
                ? (viz.gpsPosition ?? viz.truePosition)
                : (viz.ekfPosition ?? viz.truePosition);

        newMarkers.add(
          Marker(
            markerId: const MarkerId('ekf_estimated'),
            position: ekfPos,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueCyan,
            ),
            infoWindow: InfoWindow(
              title: viz.gpsAvailable ? 'EKF (GPS)' : 'EKF (DR)',
            ),
            alpha: 0.8,
            zIndexInt: 8,
          ),
        );

        // ZUPT Markers
        for (int i = 0; i < viz.zuptPositions.length; i++) {
          newMarkers.add(
            Marker(
              markerId: MarkerId('zupt_$i'),
              position: viz.zuptPositions[i],
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueGreen,
              ),
              alpha: 0.7,
              infoWindow: InfoWindow(title: 'ZUPT #${i + 1}'),
              zIndexInt: 3,
            ),
          );
        }

        // EKF Snaps
        for (int i = 0; i < viz.ekfSnappedStations.length; i++) {
          newMarkers.add(
            Marker(
              markerId: MarkerId('snap_$i'),
              position: viz.ekfSnappedStations[i],
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueViolet,
              ),
              infoWindow: InfoWindow(title: 'EKF Snap #${i + 1}'),
              zIndexInt: 6,
            ),
          );
        }

        // Stations
        final stationIcon = _cachedCyanIcon ?? BitmapDescriptor.defaultMarker;
        for (int i = 0; i < _filteredStationsCache.length; i++) {
          final (pos, name) = _filteredStationsCache[i];
          newMarkers.add(
            Marker(
              markerId: MarkerId('station_$i'),
              position: pos,
              icon: stationIcon,
              infoWindow: InfoWindow(title: name),
              zIndexInt: 4,
            ),
          );
        }
      }
    } else {
      // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
      // B. NORMAL / SIMULATION MODE
      // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

      // B.1. Device Marker
      if (_devicePosition != null) {
        newMarkers.add(
          Marker(
            markerId: const MarkerId('device_marker'),
            position: _devicePosition!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
            infoWindow: const InfoWindow(title: 'Your Device'),
            zIndexInt: 100,
          ),
        );
      }

      // B.2. Simulation Marker
      if (_simController != null && _simController!.currentPosition != null) {
        final tickPos = _simController!.currentPosition!;
        // Check if heading is available in state or controller (handled by _lastSimHeading if needed)
        final heading = _lastSimHeading;
        final speed = _simController!.speedMps;
        final dist = _calculateDistanceFromRoute(tickPos);

        newMarkers.add(
          Marker(
            markerId: const MarkerId('sim_position'),
            position: tickPos,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
            infoWindow: InfoWindow(
              title: 'Simulated Position',
              snippet:
                  '${(speed * 3.6).toStringAsFixed(0)} km/h | ${dist.toStringAsFixed(0)}m from route',
            ),
            zIndexInt: 100,
            rotation: heading,
            anchor: const Offset(0.5, 0.5),
          ),
        );
      }

      // B.3. Route Polylines
      if (_activeRoute.isNotEmpty) {
        final isDeviating =
            _simController?.state == SimulationState.deviating ||
            _simController?.state == SimulationState.returning;

        if (_activeRouteRawSegments.isNotEmpty) {
          // Draw segmented polyline
          // If deviating -> Grey, else -> Colored
          if (isDeviating) {
            final greyPolys = _directionService
                .buildSegmentedPolylinesFromRawSegments(
                  _activeRouteRawSegments,
                );
            for (int i = 0; i < greyPolys.length; i++) {
              final p = greyPolys[i];
              newPolylines.add(
                Polyline(
                  polylineId: PolylineId('grey_route_seg_$i'),
                  points: p.points,
                  color: Colors.grey.withValues(alpha: 0.5),
                  width: p.width,
                  patterns: p.patterns,
                  zIndex: 0,
                ),
              );
            }
          } else {
            final coloredPolys = _directionService
                .buildSegmentedPolylinesFromRawSegments(
                  _activeRouteRawSegments,
                );
            for (int i = 0; i < coloredPolys.length; i++) {
              final p = coloredPolys[i];
              newPolylines.add(
                Polyline(
                  polylineId: PolylineId('route_seg_$i'),
                  points: p.points,
                  color: p.color,
                  width: p.width,
                  patterns: p.patterns,
                  zIndex: 10,
                ),
              );
            }
          }
        } else {
          // Simple fallback
          newPolylines.add(
            Polyline(
              polylineId: const PolylineId('route_simple'),
              points: _activeRoute,
              color: isDeviating ? Colors.grey : Colors.blue,
              width: 5,
              zIndex: 10,
            ),
          );
        }

        // Destination
        newMarkers.add(
          Marker(
            markerId: const MarkerId('destination'),
            position: _activeRoute.last,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            infoWindow: const InfoWindow(title: 'Destination'),
            zIndexInt: 90,
          ),
        );
      }

      // B.4. Deviation Polylines
      if (_simController != null) {
        final state = _simController!.state;
        if (_simController!.deviationPath.isNotEmpty &&
            (state == SimulationState.deviating ||
                state == SimulationState.returning)) {
          newPolylines.add(
            Polyline(
              polylineId: const PolylineId('deviation_path'),
              points: _simController!.deviationPath,
              color: Colors.orange,
              width: 4,
              patterns: [PatternItem.dash(20), PatternItem.gap(10)],
              zIndex: 2,
            ),
          );
        }
        if (_simController!.currentPath.isNotEmpty &&
            state == SimulationState.returning) {
          newPolylines.add(
            Polyline(
              polylineId: const PolylineId('current_path'),
              points: _simController!.currentPath,
              color: Colors.teal,
              width: 4,
              patterns: [PatternItem.dash(15), PatternItem.gap(8)],
              zIndex: 3,
            ),
          );
        }
      }

      // B.5. Snapped Stops (Yellow)
      if (_transitMode &&
          _lastTransitLegsJson != null &&
          _activeRoute.isNotEmpty) {
        final legs = _lastTransitLegsJson!;
        final pm = _lastProgressMetersFromApp;
        int? currentLegIndex;
        if (pm != null) {
          for (int li = 0; li < legs.length; li++) {
            final leg = legs[li];
            final start = (leg['legStartMeters'] as num?)?.toDouble();
            final end = (leg['legEndMeters'] as num?)?.toDouble();
            if (start == null || end == null) continue;
            if (pm >= start && pm <= end) {
              currentLegIndex = li;
              break;
            }
          }
        }

        if (currentLegIndex != null) {
          final leg = legs[currentLegIndex];
          if (leg['isMetro'] == true) {
            final positions = (leg['stopPositions'] as List?) ?? const [];
            final names = (leg['stopNames'] as List?) ?? const [];

            for (int i = 0; i < positions.length; i++) {
              final p = positions[i] as Map<String, dynamic>;
              final name = i < names.length ? names[i].toString() : 'Stop';
              final lat = (p['lat'] as num).toDouble();
              final lng = (p['lng'] as num).toDouble();

              newMarkers.add(
                Marker(
                  markerId: MarkerId('snapped_stop_${currentLegIndex}_$i'),
                  position: LatLng(lat, lng),
                  icon: _cachedYellowIcon!,
                  infoWindow: InfoWindow(title: name, snippet: 'Snapped Stop'),
                  zIndexInt: 50,
                ),
              );
            }
          }
        }
      }
    } // End ELSE (Normal Mode)

    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // C. COMMON OVERLAY (All Stops - Cyan)
    // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (_showAllStopsOverlay) {
      for (final stop in allIndiaStops) {
        final lat = (stop['lat'] as num).toDouble();
        final lng = (stop['lng'] as num).toDouble();
        newMarkers.add(
          Marker(
            markerId: MarkerId('overlay_stop_${stop['id']}'),
            position: LatLng(lat, lng),
            icon: _cachedCyanIcon!,
            infoWindow: InfoWindow(title: stop['name'], snippet: 'Overlay'),
            zIndexInt: 20,
          ),
        );
      }
    }

    // Apply to map
    setState(() {
      _markers.clear();
      _markers.addAll(newMarkers);
      _polylines.clear();
      _polylines.addAll(newPolylines);
    });
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Idle State
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _clearRouteForIdle() {
    setState(() {
      _polylines.clear();
      _markers.removeWhere((m) => m.markerId.value != 'device_marker');
      _stopMarkers.clear();
      _lastRouteSignature = null;
      _lastRouteKey = null;
      _activeRoute = [];
      _metricDistance = '---';
      _metricTime = '---';
      _metricStops = '---';
      _metricAlarm = '---';
    });
    if (_devicePosition != null) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(_devicePosition!, 14),
      );
    }
  }

  void _clearEvents() {
    setState(() => _events.clear());
    ConstraintLogger.instance.log(
      ConstraintEvent.info(
        timestamp: AppClock().now(),
        title: 'Logs Cleared',
        description: 'Event log was manually cleared',
      ),
    );
  }

  void _exportConstraintLogs(LogExportFormat format) {
    final events = ConstraintLogger.instance.events;
    if (events.isEmpty) {
      _logInfo('No constraint logs to export');
      return;
    }

    final now = DateTime.now().toIso8601String().replaceAll(':', '-');
    final filename =
        'constraint_logs_$now.${format == LogExportFormat.json ? 'json' : 'csv'}';

    if (format == LogExportFormat.json) {
      final payload = {
        'generatedAt': DateTime.now().toIso8601String(),
        'eventCount': events.length,
        'events':
            events
                .map(
                  (e) => {
                    'timestamp': e.timestamp.toIso8601String(),
                    'type': e.type.name,
                    'title': e.title,
                    'description': e.description,
                    'details': e.details,
                  },
                )
                .toList(),
      };
      final jsonText = const JsonEncoder.withIndent('  ').convert(payload);
      _downloadTextFile(filename, jsonText, 'application/json');
      _logInfo('Exported ${events.length} constraint logs (JSON)');
      return;
    }

    final header = 'timestamp,type,title,description,details';
    final rows = events.map((e) {
      final values = [
        e.timestamp.toIso8601String(),
        e.type.name,
        e.title,
        e.description ?? '',
        jsonEncode(e.details),
      ];
      return values.map(_escapeCsv).join(',');
    });
    final csv = ([header, ...rows]).join('\n');
    _downloadTextFile(filename, csv, 'text/csv');
    _logInfo('Exported ${events.length} constraint logs (CSV)');
  }

  String _escapeCsv(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  void _downloadTextFile(String filename, String content, String mimeType) {
    final bytes = utf8.encode(content);
    final blob = html.Blob([bytes], mimeType);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', filename)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Actions
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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

  /// Reverts to the most recent inactive (previous) route.
  /// This sends a command to the app to switch the active route.
  void _revertToPreviousRoute() {
    if (_availableInactiveRoutes.isEmpty) return;

    // Get the first (most recent) inactive route
    final previousRoute = _availableInactiveRoutes.first;
    final routeKey =
        previousRoute['route_key'] as String? ??
        previousRoute['key'] as String?;

    if (routeKey != null && routeKey.isNotEmpty) {
      _broadcastRouteSwitch(routeKey);
      _logInfo('Requested revert to previous route: $routeKey');
    } else {
      _logError('Cannot revert: inactive route has no key');
    }
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Logging
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Helpers
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  double _haversineDistance(LatLng p1, LatLng p2) {
    const R = 6371000.0;
    final dLat = _degToRad(p2.latitude - p1.latitude);
    final dLon = _degToRad(p2.longitude - p1.longitude);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_degToRad(p1.latitude)) *
            cos(_degToRad(p2.latitude)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  double _degToRad(double deg) => deg * (pi / 180.0);

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  String _formatRouteDebug(Map<String, dynamic> debug) {
    final source = debug['polyline_source'] ?? 'unknown';
    final pts = debug['points_count'] ?? '?';
    final segs = debug['segments_count'] ?? '?';
    final fallback = debug['used_fallback_polyline'] == true;
    final simplified = debug['used_simplified_polyline'] == true;
    final flags = [if (fallback) 'fallback', if (simplified) 'simplified'];
    final flagStr = flags.isEmpty ? '' : ' (${flags.join(', ')})';
    return 'route: src=$source pts=$pts segs=$segs$flagStr';
  }

  Future<BitmapDescriptor> _createCustomMarkerBitmap(
    Color color, {
    double size = 24,
  }) async {
    if (color == Colors.cyanAccent && _cachedCyanIcon != null) {
      return _cachedCyanIcon!;
    }
    if (color == Colors.yellowAccent && _cachedYellowIcon != null) {
      return _cachedYellowIcon!;
    }

    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);
    final paint = Paint()..color = color;
    final radius = size / 2;

    canvas.drawCircle(Offset(radius, radius), radius, paint);

    final borderPaint =
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;
    canvas.drawCircle(Offset(radius, radius), radius - 1, borderPaint);

    final image = await pictureRecorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final icon = BitmapDescriptor.bytes(byteData!.buffer.asUint8List());

    if (color == Colors.cyanAccent) _cachedCyanIcon = icon;
    if (color == Colors.yellowAccent) _cachedYellowIcon = icon;
    return icon;
  }

  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Build UI
  // â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final showControlPanel = screenWidth > 600;

    return Scaffold(
      appBar: _buildAppBar(),
      drawer: showControlPanel ? null : Drawer(child: _buildControlPanel()),
      body: Row(
        children: [
          if (showControlPanel) _buildControlPanel(),
          Expanded(child: _buildMap()),
          ConstraintDrawer(
            events: _events,
            isOpen: _drawerOpen,
            onToggle: () => setState(() => _drawerOpen = !_drawerOpen),
            onClear: _clearEvents,
            onExport: _exportConstraintLogs,
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Row(
        children: [
          const Text('GeoWake Unified Dashboard'),
          const SizedBox(width: 16),
          _buildConnectionIndicator(),
        ],
      ),
      actions: [
        // EKF Test Mode toggle
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color:
                _ekfTestModeEnabled
                    ? Colors.orange.withValues(alpha: 0.2)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _ekfTestModeEnabled ? Colors.orange : Colors.grey,
              width: _ekfTestModeEnabled ? 2 : 1,
            ),
          ),
          child: InkWell(
            onTap:
                () =>
                    setState(() => _ekfTestModeEnabled = !_ekfTestModeEnabled),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.science,
                    color: _ekfTestModeEnabled ? Colors.orange : Colors.grey,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'EKF TEST',
                    style: TextStyle(
                      color: _ekfTestModeEnabled ? Colors.orange : Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
      width: 380,
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // EKF Test Panel (when enabled)
            if (_ekfTestModeEnabled) ...[
              EkfTestPanel(
                externalWarpFactor: _warpFactor,
                onInjectGps: (pos, accuracy, speed) {
                  // Inject GPS into simulation client if connected
                  _broadcastEkfTestPosition(pos, accuracy, speed);
                },
                onRouteChanged: (polyline, stations) {
                  _handleEkfRouteChanged(polyline, stations);
                },
                onVisualizationUpdate: (viz) {
                  _updateEkfState(viz);
                },
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
            ],

            // Simulation controls (hidden in EKF test mode)
            if (!_ekfTestModeEnabled) ...[
              SimulationControls(
                state: state,
                onStart: () => _simController?.start(),
                onStop: () => _simController?.stop(),
                onStartDeviation: _startDeviationOptimized,
                onStopDeviation: () => _simController?.stopDeviation(),
                onGoBackToRoute: () => _simController?.goBackToRoute(),
                onPause: () => _simController?.pause(),
                onResume: () => _simController?.resume(),
                hasPreviousRoutes: _availableInactiveRoutes.isNotEmpty,
                onRevertToPreviousRoute:
                    _availableInactiveRoutes.isNotEmpty
                        ? _revertToPreviousRoute
                        : null,
              ),
              const SizedBox(height: 16),
            ],

            // Time warp slider
            TimeWarpSlider(
              warpFactor: _warpFactor,
              onChanged: _setWarpFactor,
              enabled: true,
            ),
            const SizedBox(height: 16),

            // Speed slider (hidden in EKF test mode)
            if (!_ekfTestModeEnabled) ...[
              SpeedSlider(
                speedKmh: _speedKmh,
                onChanged: _setSpeed,
                enabled: true,
              ),
              const SizedBox(height: 16),

              const Text(
                'Stop Visualization',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),

              SwitchListTile(
                value: _showAllStopsOverlay,
                onChanged: (v) {
                  setState(() => _showAllStopsOverlay = v);
                  _renderMapState();
                },
                title: const Text('Show all metro stops (India)'),
                subtitle: const Text('Cyan = active, Yellow = upcoming'),
                dense: true,
              ),

              // Progress slider
              const Text('Progress'),
              Slider(
                value: _simController?.progressOnOriginalRoute ?? 0.0,
                onChanged: (v) {
                  final controller = _simController;
                  if (controller == null) return;
                  final oldProgress = controller.progressOnOriginalRoute;
                  setState(() => controller.seek(v));
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
            ],

            // Divider
            const Divider(),
            const SizedBox(height: 8),

            // App State Metrics (from device)
            const Text(
              'Device Metrics',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _buildMetricRow('Distance', _metricDistance),
            _buildMetricRow('ETA', _metricTime),
            _buildMetricRow('Stops', _metricStops),
            _buildMetricRow('Alarm', _metricAlarm),
            if (_metricDebug != '---')
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _metricDebug,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
            if (_lastRouteDebug != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _formatRouteDebug(_lastRouteDebug!),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.orangeAccent,
                  ),
                ),
              ),

            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),

            // Stats card
            _buildStatsCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.bold),
              textAlign: TextAlign.right,
            ),
          ),
        ],
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
              'Simulation Stats',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
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
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ],
      ),
    );
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

  Widget _buildMap() {
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
            _loadOsmOverlay();
          },
          markers: _markers,
          polylines: allPolylines,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: true,
          onTap: (pos) {
            // Log tapped position for debugging
            _logInfo(
              'Map tapped at: ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}',
            );
          },
        ),
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
            _LegendItem(color: Colors.grey, label: 'Inactive Route'),
            _LegendItem(color: Colors.deepOrange, label: 'Deviation Path'),
            _LegendItem(color: Colors.teal, label: 'Return Path'),
            _LegendItem(
              color: Colors.orange,
              isMarker: true,
              label: 'Simulated Position',
            ),
            _LegendItem(
              color: Colors.cyanAccent,
              isMarker: true,
              label: 'Active Metro Stop',
            ),
            _LegendItem(
              color: Colors.yellowAccent,
              isMarker: true,
              label: 'Upcoming Metro Stop',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadOsmOverlay() async {
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
}

/// Legend item widget.
class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.color,
    required this.label,
    this.isMarker = false,
  });

  final Color color;
  final String label;
  final bool isMarker;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isMarker)
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1),
              ),
            )
          else
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
