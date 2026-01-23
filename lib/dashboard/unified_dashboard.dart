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
  // ─────────────────────────────────────────────────────────────────────
  // Core Controllers
  // ─────────────────────────────────────────────────────────────────────

  GoogleMapController? _mapController;
  DeviationSimulationController? _simController;
  bool _graphLoading = false;
  (double, double, double, double)? _lastGraphWindow;
  final OsmOverlayManager _osmOverlay = OsmOverlayManager();
  final DirectionService _directionService = DirectionService();

  // ─────────────────────────────────────────────────────────────────────
  // Map Elements
  // ─────────────────────────────────────────────────────────────────────

  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  final Set<Marker> _stopMarkers = {};
  final Set<Marker> _osmStopMarkers = {};

  // Route polyline caches (keyed by route_key for color preservation)
  final Map<String, List<Polyline>> _routePolylinesByKey = {};
  final Map<String, List<Polyline>> _routeGreyPolylinesByKey = {};

  // Available inactive routes (for "revert to previous route" feature)
  List<Map<String, dynamic>> _availableInactiveRoutes = [];

  // ─────────────────────────────────────────────────────────────────────
  // WebSocket State
  // ─────────────────────────────────────────────────────────────────────

  html.WebSocket? _socket;
  bool _connected = false;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  DateTime? _lastPingReceived;

  // ─────────────────────────────────────────────────────────────────────
  // Route State (from app via WebSocket)
  // ─────────────────────────────────────────────────────────────────────

  List<LatLng> _activeRoute = [];
  List<Map<String, dynamic>> _activeRouteRawSegments = [];
  String? _lastRouteKey;
  String? _lastRouteSignature;
  // ignore: unused_field
  bool _transitMode = false;
  List<Map<String, dynamic>>? _lastTransitLegsJson;
  Map<String, dynamic>? _lastRouteDebug;

  // ─────────────────────────────────────────────────────────────────────
  // App State Metrics (received from device)
  // ─────────────────────────────────────────────────────────────────────

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

  // ─────────────────────────────────────────────────────────────────────
  // Simulation UI State
  // ─────────────────────────────────────────────────────────────────────

  bool _drawerOpen = false;
  double _warpFactor = 1.0;
  double _speedKmh = 40.0;
  bool _wasPlayingBeforeScrub = false;
  bool _osmVisible = true;

  // Stop visualization options
  bool _showAllTransitLegStops = true;
  bool _showOsmStops = true;
  bool _osmStopsShowAll = false;
  bool _osmStopsStrictRouteMatch = false;
  double _osmStopsRadiusMeters = 2000.0;

  // ─────────────────────────────────────────────────────────────────────
  // Constraint Events
  // ─────────────────────────────────────────────────────────────────────

  List<ConstraintEvent> _events = [];
  StreamSubscription<ConstraintEvent>? _eventSub;
  StreamSubscription<SimulationTickResult>? _positionSub;
  StreamSubscription<SimulationState>? _stateSub;

  // ─────────────────────────────────────────────────────────────────────
  // Demo Route (Bengaluru)
  // ─────────────────────────────────────────────────────────────────────

  final List<LatLng> _demoRoute = [
    const LatLng(12.9716, 77.5946), // MG Road
    const LatLng(12.9766, 77.5993), // Trinity
    const LatLng(12.9850, 77.6050), // Indiranagar
    const LatLng(12.9900, 77.6150), // HAL
    const LatLng(12.9950, 77.6250), // Airport Road
  ];

  // ─────────────────────────────────────────────────────────────────────
  // Cached Icons
  // ─────────────────────────────────────────────────────────────────────

  BitmapDescriptor? _cachedCyanIcon;

  // Latest polyline-domain progress (meters) received from app debug_info.
  double? _lastProgressMetersFromApp;

  // Track what transit-stop marker set is currently rendered.
  // Values: 'none', 'all', or 'leg:<index>'.
  String? _transitStopRenderKey;
  String? _osmStopRenderKey;

  // ─────────────────────────────────────────────────────────────────────
  // EKF Test Mode
  // ─────────────────────────────────────────────────────────────────────

  bool _ekfTestModeEnabled = false;
  List<LatLng> _ekfTestRoutePolyline = [];
  
  // Ghost marker state tracking
  LatLng? _ghostMarkerPosition; // Position where GPS was toggled off
  bool? _lastGpsAvailable; // Track GPS state changes (null = not initialized)
  
  // Cached filtered stations from allIndiaStops for current route
  List<(LatLng position, String name)> _filteredStationsCache = [];
  
  // Cached cyan dot icon for station markers
  BitmapDescriptor? _cyanDotIcon;

  // ─────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
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

  // ─────────────────────────────────────────────────────────────────────
  // Simulation Initialization
  // ─────────────────────────────────────────────────────────────────────

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
      _updateRoutePolylines();
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
        '⚠️ Using local test graph fallback: ${graph.nodeCount} nodes ($e)',
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

  // ─────────────────────────────────────────────────────────────────────
  // Simulation Tick Handler
  // ─────────────────────────────────────────────────────────────────────

  void _onSimulationTick(SimulationTickResult tick) {
    print(
      'ETA_DEBUG simTick: pos=(${tick.position.latitude.toStringAsFixed(5)},${tick.position.longitude.toStringAsFixed(5)}), spd=${tick.speedMps.toStringAsFixed(2)}m/s (${(tick.speedMps * 3.6).toStringAsFixed(1)}km/h), distFromRoute=${tick.distanceFromRoute.toStringAsFixed(1)}m, warp=$_warpFactor',
    );
    setState(() {
      _updateSimulationMarker(tick);
    });
    _broadcastSimulationPosition(tick);
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
    _updateDeviationPolyline();
  }

  // ─────────────────────────────────────────────────────────────────────
  // WebSocket Connection
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

  // ─────────────────────────────────────────────────────────────────────
  // Message Handling (Bidirectional)
  // ─────────────────────────────────────────────────────────────────────

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

        _updateMapRoute(
          points,
          segments: segments,
          inactiveRoutes: inactiveRoutes,
          transitMode: transitMode,
          routeKey: routeKey,
        );

        if (points.isNotEmpty) {
          _mapController?.animateCamera(
            CameraUpdate.newLatLngZoom(points.first, 14),
          );
        }
      } else {
        // Same route rebroadcast: just refresh inactive routes
        _updateMapRoute(
          points,
          segments: segments,
          inactiveRoutes: inactiveRoutes,
          transitMode: transitMode,
          routeKey: routeKey,
          forceRepaint: true,
        );
        if (routeKey != null) _lastRouteKey = routeKey;
      }
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

    // Ensure cyan stop dots reflect current leg promptly.
    _refreshTransitStopMarkers();
  }

  void _handleAppState(Map<String, dynamic> json) {
    // Debug: log raw state received
    print(
      'ETA_DEBUG dashboard RX: eta=${json['eta']}, dist=${json['distance_travelled']}, mode=${json['alarm_mode']}, val=${json['alarm_value']}, debug=${json['debug_info']}',
    );
    setState(() {
      if (json['eta'] != null) {
        final etaSec = (json['eta'] as num).toInt();
        _metricTime = '${(etaSec / 60).toStringAsFixed(1)} min';
        print('ETA_DEBUG dashboard: etaSec=$etaSec -> ${_metricTime}');
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
        _logInfo('Tracking ended. Clearing route.');
        _clearRouteForIdle();
      } else if (json['active'] == true) {
        _trackingActive = true;
      }
    });

    // Progress updates can change the current leg; refresh cyan markers.
    _refreshTransitStopMarkers();
  }

  void _handleDevicePosition(Map<String, dynamic> json) {
    if ((_simController?.state ?? SimulationState.idle) != SimulationState.idle ||
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

  // ─────────────────────────────────────────────────────────────────────
  // Broadcasting (Outbound)
  // ─────────────────────────────────────────────────────────────────────

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
    print(
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

  // ─────────────────────────────────────────────────────────────────────
  // EKF Test Mode Helpers
  // ─────────────────────────────────────────────────────────────────────

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

  /// Updates the map to show the EKF test route
  Future<void> _updateEkfTestRouteOnMap() async {
    final polyline = _ekfTestRoutePolyline;
    debugPrint('\\n\ud83d\uddfa\ufe0f _updateEkfTestRouteOnMap called, polyline points: ${polyline.length}');
    if (polyline.isEmpty) {
      debugPrint('   \u26a0\ufe0f Polyline is empty, returning early');
      return;
    }

    // Filter stations from allIndiaStops to only those within 200m of the route polyline
    debugPrint('   Filtering stations from allIndiaStops (${allIndiaStops.length} total)...');
    final stationsOnRoute = <(LatLng position, String name)>[];
    for (final station in allIndiaStops) {
      final stationPos = LatLng(
        (station['lat'] as num).toDouble(),
        (station['lng'] as num).toDouble(),
      );
      double minDist = double.infinity;
      for (final pt in polyline) {
        final dist = _haversineDistanceMeters(stationPos, pt);
        if (dist < minDist) minDist = dist;
      }
      if (minDist < 200) {
        stationsOnRoute.add((stationPos, station['name'] as String? ?? 'Station'));
      }
    }
    
    // Cache the filtered stations for use in real-time visualization
    _filteredStationsCache = stationsOnRoute;
    debugPrint('   \u2705 Found ${stationsOnRoute.length} stations within 200m of route');
    for (int i = 0; i < stationsOnRoute.length; i++) {
      final (pos, name) = stationsOnRoute[i];
      debugPrint('      Station $i: $name at ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}');
    }

    // Create and cache cyan dot icon (same as non-test mode)
    final cyanIcon = await _createCustomMarkerBitmap(Colors.cyanAccent, size: 30);
    _cyanDotIcon = cyanIcon;
    debugPrint('   \u2705 Cyan dot icon created and cached');

    setState(() {
      // Clear existing polylines and add test route
      _polylines.clear();
      _polylines.add(
        Polyline(
          polylineId: const PolylineId('ekf_test_route'),
          points: polyline,
          color: Colors.green.shade600,
          width: 5,
        ),
      );

      // Add station markers (only those on the route, with cyan dots)
      // Use 'station_' prefix consistently with _updateEkfTestVisualization
      _markers.clear();
      for (int i = 0; i < stationsOnRoute.length; i++) {
        final (position, name) = stationsOnRoute[i];
        _markers.add(
          Marker(
            markerId: MarkerId('station_$i'),
            position: position,
            icon: cyanIcon,
            infoWindow: InfoWindow(title: name),
            zIndex: 12,
          ),
        );
      }
    });
    debugPrint('   \ud83d\udccd Initial markers set: ${_markers.length}');

    // Move camera to fit the route
    if (_mapController != null && polyline.isNotEmpty) {
      // Calculate bounds
      double minLat = polyline[0].latitude;
      double maxLat = polyline[0].latitude;
      double minLng = polyline[0].longitude;
      double maxLng = polyline[0].longitude;

      for (final point in polyline) {
        if (point.latitude < minLat) minLat = point.latitude;
        if (point.latitude > maxLat) maxLat = point.latitude;
        if (point.longitude < minLng) minLng = point.longitude;
        if (point.longitude > maxLng) maxLng = point.longitude;
      }

      final bounds = LatLngBounds(
        southwest: LatLng(minLat, minLng),
        northeast: LatLng(maxLat, maxLng),
      );

      _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
    }
  }

  /// Haversine distance in meters between two LatLng points
  double _haversineDistanceMeters(LatLng a, LatLng b) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = (b.latitude - a.latitude) * 3.141592653589793 / 180;
    final dLon = (b.longitude - a.longitude) * 3.141592653589793 / 180;
    final lat1 = a.latitude * 3.141592653589793 / 180;
    final lat2 = b.latitude * 3.141592653589793 / 180;
    final h = _haversinePart(dLat) + _haversinePart(dLon) * cos(lat1) * cos(lat2);
    return 2 * R * asin(sqrt(h));
  }

  double _haversinePart(double x) => (1 - cos(x)) / 2;

  /// Tick counter for rate-limited logging
  int _vizUpdateCount = 0;
  
  /// Updates visualization from EKF test controller
  void _updateEkfTestVisualization(EkfTestVisualization viz) {
    final routePolyline = viz.routePolyline;
    _vizUpdateCount++;

    // ═══════════════════════════════════════════════════════════════════════
    // RATE-LIMITED EKF TEST LOGGING (every 50 ticks = ~5 seconds)
    // ═══════════════════════════════════════════════════════════════════════
    final shouldLogViz = _vizUpdateCount % 50 == 0;
    if (shouldLogViz) {
      debugPrint('\n╔══════════════════════════════════════════════════════════════');
      debugPrint('║ EKF TEST VISUALIZATION UPDATE (tick $_vizUpdateCount)');
      debugPrint('╠══════════════════════════════════════════════════════════════');
      debugPrint('║ GPS State:');
      debugPrint('║   - gpsAvailable: ${viz.gpsAvailable}');
      debugPrint('║   - lastGpsAvailable: $_lastGpsAvailable');
      debugPrint('║   - ghostMarkerPosition: $_ghostMarkerPosition');
      debugPrint('║ Position:');
      debugPrint('║   - truePosition: ${viz.truePosition}');
      debugPrint('║   - ekfPosition: ${viz.ekfPosition}');
      debugPrint('║   - rawGpsPosition: ${viz.rawGpsPosition}');
      debugPrint('║ EKF Metrics:');
      debugPrint('║   - ekfProgressMeters: ${viz.ekfProgressMeters?.toStringAsFixed(0) ?? "null"}');
      debugPrint('║   - trueProgressMeters: ${viz.trueProgressMeters.toStringAsFixed(0)}');
      debugPrint('║   - ekfSigmaS: ${viz.ekfSigmaS?.toStringAsFixed(1) ?? "null"}');
      debugPrint('║   - ekfSigmaV: ${viz.ekfSigmaV?.toStringAsFixed(2) ?? "null"}');
      debugPrint('║   - ekfDegraded: ${viz.ekfDegraded}');
      debugPrint('║ Route:');
      debugPrint('║   - routePolyline points: ${routePolyline.length}');
      debugPrint('║   - filteredStationsCache: ${_filteredStationsCache.length}');
      debugPrint('║ Markers before clear: ${_markers.length}');
      debugPrint('║ Motion: ${viz.motionState.name}, Speed: ${(viz.speedMps * 3.6).toStringAsFixed(1)} km/h');
      debugPrint('╚══════════════════════════════════════════════════════════════\n');
    }

    // Ghost Marker Logic - MUST be outside setState to track state properly
    // Track GPS state transitions
    final lastGps = _lastGpsAvailable;
    if (lastGps != null) {
      if (!viz.gpsAvailable && lastGps) {
        // GPS just went unavailable - spawn ghost at current true position
        _ghostMarkerPosition = viz.truePosition;
        debugPrint('🔴 GHOST SPAWN: GPS went OFF at ${viz.truePosition}');
      } else if (viz.gpsAvailable && !lastGps) {
        // GPS just came back - remove ghost marker
        debugPrint('🟢 GHOST CLEAR: GPS came back ON (was at $_ghostMarkerPosition)');
        _ghostMarkerPosition = null;
      }
    } else {
      debugPrint('⚪ GHOST INIT: First update, lastGps was null, gpsAvailable=${viz.gpsAvailable}');
    }
    _lastGpsAvailable = viz.gpsAvailable;

    setState(() {
      // Clear visualization markers (ghost, stations, ekf markers, etc.)
      _markers.removeWhere(
        (m) =>
            m.markerId.value.startsWith('ekf_') ||
            m.markerId.value.startsWith('zupt_') ||
            m.markerId.value.startsWith('snap_') ||
            m.markerId.value.startsWith('ghost_') ||
            m.markerId.value.startsWith('station_'),
      );

      // 1. Full Route Polyline (Green solid - entire route)
      _polylines.clear();
      if (routePolyline.isNotEmpty) {
        _polylines.add(
          Polyline(
            polylineId: const PolylineId('ekf_full_route'),
            points: routePolyline,
            color: Colors.green.shade600,
            width: 5,
            zIndex: 1,
          ),
        );
      }

      // 2. Ghost Marker - show only when GPS is unavailable
      if (_ghostMarkerPosition != null && !viz.gpsAvailable) {
        _markers.add(
          Marker(
            markerId: const MarkerId('ghost_gps'),
            position: _ghostMarkerPosition!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
            alpha: 0.6, // Semi-transparent ghost
            infoWindow: const InfoWindow(title: 'GPS Dropout Point'),
            zIndex: 5,
          ),
        );
      }

      // 3. Current Position Marker (true position - bright blue/azure)
      _markers.add(
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
                'Speed: ${(viz.speedMps * 3.6).toStringAsFixed(1)} km/h\n'
                'Motion: ${viz.motionState.name}',
          ),
          zIndex: 10,
        ),
      );

      // 5. EKF Estimated Position Marker (cyan - if available)
      if (viz.ekfPosition != null) {
        _markers.add(
          Marker(
            markerId: const MarkerId('ekf_estimated'),
            position: viz.ekfPosition!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueCyan,
            ),
            infoWindow: const InfoWindow(title: 'EKF Estimate'),
            alpha: 0.8,
            zIndex: 8,
          ),
        );
      }

      // 6. ZUPT Event Markers (Green dots - small markers where ZUPT occurred)
      for (int i = 0; i < viz.zuptPositions.length; i++) {
        _markers.add(
          Marker(
            markerId: MarkerId('zupt_$i'),
            position: viz.zuptPositions[i],
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueGreen,
            ),
            alpha: 0.7,
            infoWindow: InfoWindow(title: 'ZUPT #${i + 1}'),
            zIndex: 3,
          ),
        );
      }

      // 7. EKF-Detected Station Snap Markers (Purple dots - distinct from cyan actual)
      for (int i = 0; i < viz.ekfSnappedStations.length; i++) {
        _markers.add(
          Marker(
            markerId: MarkerId('snap_$i'),
            position: viz.ekfSnappedStations[i],
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueViolet,
            ),
            infoWindow: InfoWindow(title: 'EKF Snap #${i + 1}'),
            zIndex: 6,
          ),
        );
      }

      // 8. Station Markers - Use filtered stations from allIndiaStops (cyan dots)
      // Use cached cyan dot icon (created in _updateEkfTestRouteOnMap)
      final stationIcon = _cyanDotIcon ?? BitmapDescriptor.defaultMarker;
      for (int i = 0; i < _filteredStationsCache.length; i++) {
        final (position, name) = _filteredStationsCache[i];
        _markers.add(
          Marker(
            markerId: MarkerId('station_$i'),
            position: position,
            icon: stationIcon,
            infoWindow: InfoWindow(title: name),
            zIndex: 4,
          ),
        );
      }
    });

    // Post-setState logging (rate limited)
    if (shouldLogViz) {
      debugPrint('📍 MARKERS: ${_markers.length} total, ${_filteredStationsCache.length} stations, ghost=${_ghostMarkerPosition != null && !viz.gpsAvailable}');
    }

    // Broadcast position to app
    _broadcastEkfTestPosition(
      viz.truePosition,
      viz.gpsAvailable ? 5.0 : 50.0, // Degraded accuracy during dropout
      viz.speedMps,
    );

    // Move camera to follow
    _mapController?.animateCamera(CameraUpdate.newLatLng(viz.truePosition));
  }

  // ─────────────────────────────────────────────────────────────────────
  // Map Route Updates
  // ─────────────────────────────────────────────────────────────────────

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

  Future<void> _updateMapRoute(
    List<LatLng> points, {
    List<Map<String, dynamic>>? segments,
    List<Map<String, dynamic>>? inactiveRoutes,
    bool transitMode = false,
    String? routeKey,
    bool forceRepaint = false,
  }) async {
    final cyanMarkerIcon = await _createCustomMarkerBitmap(
      Colors.cyanAccent,
      size: 30,
    );

    setState(() {
      _polylines.clear();
      _markers.removeWhere(
        (m) =>
            m.markerId.value.startsWith('route_') ||
            m.markerId.value.startsWith('transit_stop_') ||
            m.markerId.value.startsWith('stop_') ||
            m.markerId.value.startsWith('osm_stop_'),
      );

      // 1. Draw Inactive Routes (Grey) with color preservation
      if (inactiveRoutes != null) {
        for (final route in inactiveRoutes) {
          _drawInactiveRoute(route);
        }
      }

      // 2. Draw Active Route
      if (segments != null && segments.isNotEmpty) {
        _drawActiveRouteWithSegments(segments, routeKey);
      } else {
        _polylines.add(
          Polyline(
            polylineId: const PolylineId('route_active'),
            points: points,
            color: Colors.blue,
            width: 5,
            zIndex: 5,
          ),
        );
      }

      // 3. Transit stop markers
      if (transitMode) {
        _drawTransitStopMarkers(
          cyanMarkerIcon,
          points,
          restrictToCurrentLeg: !_showAllTransitLegStops,
        );
      } else {
        _stopMarkers.clear();
      }

      if (_showOsmStops) {
        _drawOsmStopMarkers(cyanMarkerIcon, points);
      } else {
        _osmStopMarkers.clear();
      }

      // 4. Start/End markers
      if (points.isNotEmpty) {
        _markers.add(
          Marker(
            markerId: const MarkerId('route_start'),
            position: points.first,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueGreen,
            ),
            infoWindow: const InfoWindow(title: 'Start'),
            zIndexInt: 40,
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
            zIndexInt: 40,
          ),
        );
      }
    });
  }

  void _drawInactiveRoute(Map<String, dynamic> route) {
    final inactiveKeyRaw = route['route_key'] ?? route['key'];
    final inactiveKey =
        inactiveKeyRaw is String && inactiveKeyRaw.trim().isNotEmpty
            ? inactiveKeyRaw.trim()
            : null;

    // Prefer cached grey polylines
    if (inactiveKey != null) {
      final cachedGrey = _routeGreyPolylinesByKey[inactiveKey];
      if (cachedGrey != null && cachedGrey.isNotEmpty) {
        _polylines.addAll(cachedGrey);
        return;
      }
    }

    // Build from segments if provided
    final inactiveSegments =
        (route['segments'] as List?)?.cast<Map<String, dynamic>>();
    if (inactiveSegments != null && inactiveSegments.isNotEmpty) {
      final base = _directionService.buildSegmentedPolylinesFromRawSegments(
        inactiveSegments,
      );
      final derivedKey = inactiveKey ?? 'inactive_${route.hashCode}';
      final grey = _prefixPolylines(
        base,
        'inactive:$derivedKey:',
        colorOverride: Colors.grey,
        zIndexOverride: 0,
      );
      if (inactiveKey != null) {
        _routeGreyPolylinesByKey[inactiveKey] = grey;
      }
      _polylines.addAll(grey);
      return;
    }

    // Fallback: simple grey polyline
    final ptsJson = (route['points'] as List?) ?? const [];
    final pts = ptsJson.map((p) => LatLng(p['lat'], p['lng'])).toList();
    final derivedKey = inactiveKey ?? 'inactive_${pts.hashCode}';
    _polylines.add(
      Polyline(
        polylineId: PolylineId('inactive:$derivedKey'),
        points: pts,
        color: Colors.grey,
        width: 4,
        zIndex: 0,
      ),
    );
  }

  void _drawActiveRouteWithSegments(
    List<Map<String, dynamic>> segments,
    String? routeKey,
  ) {
    final hasKey = routeKey != null && routeKey.trim().isNotEmpty;
    if (hasKey) {
      final key = routeKey.trim();
      var cached = _routePolylinesByKey[key];
      if (cached == null || cached.isEmpty) {
        final base = _directionService.buildSegmentedPolylinesFromRawSegments(
          segments,
        );
        cached = _prefixPolylines(base, 'active:$key:');
        _routePolylinesByKey[key] = cached;
        // Also cache grey version for when it becomes inactive
        _routeGreyPolylinesByKey.putIfAbsent(
          key,
          () => _prefixPolylines(
            base,
            'inactive:$key:',
            colorOverride: Colors.grey,
            zIndexOverride: 0,
          ),
        );
      }
      _polylines.addAll(cached);
    } else {
      final base = _directionService.buildSegmentedPolylinesFromRawSegments(
        segments,
      );
      _polylines.addAll(_prefixPolylines(base, 'active:legacy:'));
    }
  }

  void _drawTransitStopMarkers(
    BitmapDescriptor icon,
    List<LatLng> pathPoints, {
    required bool restrictToCurrentLeg,
  }) {
    // Prefer runtime-provided transit legs
    if (_lastTransitLegsJson != null) {
      final legs = _lastTransitLegsJson!;

      // If we can determine the current leg from progress meters, only render
      // metro stops for the current metro leg. If the current leg is not metro,
      // render no cyan dots.
      if (restrictToCurrentLeg) {
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
          final currentLeg = legs[currentLegIndex];
          final isMetro = currentLeg['isMetro'] == true;
          if (!isMetro) return;

          final positions = (currentLeg['stopPositions'] as List?) ?? const [];
          final names = (currentLeg['stopNames'] as List?) ?? const [];
          int added = 0;

          for (int si = 0; si < positions.length; si++) {
            final p = positions[si] as Map<String, dynamic>;
            final name = si < names.length ? names[si].toString() : 'Stop';
            final lat = (p['lat'] as num).toDouble();
            final lng = (p['lng'] as num).toDouble();

            _markers.add(
              Marker(
                markerId: MarkerId('transit_stop_${currentLegIndex}_$si'),
                position: LatLng(lat, lng),
                icon: icon,
                infoWindow: InfoWindow(
                  title: name,
                  snippet: currentLeg['lineName']?.toString(),
                ),
                zIndexInt: 12,
              ),
            );
            added++;
          }
          _logInfo(
            'Transit stops (current leg $currentLegIndex): $added markers',
          );
          return;
        }
      }

      for (int li = 0; li < legs.length; li++) {
        final leg = legs[li];
        final isMetro = leg['isMetro'] == true;
        if (!isMetro) continue;

        final positions = (leg['stopPositions'] as List?) ?? const [];
        final names = (leg['stopNames'] as List?) ?? const [];
        int added = 0;

        for (int si = 0; si < positions.length; si++) {
          final p = positions[si] as Map<String, dynamic>;
          final name = si < names.length ? names[si].toString() : 'Stop';
          final lat = (p['lat'] as num).toDouble();
          final lng = (p['lng'] as num).toDouble();

          _markers.add(
            Marker(
              markerId: MarkerId('transit_stop_${li}_$si'),
              position: LatLng(lat, lng),
              icon: icon,
              infoWindow: InfoWindow(
                title: name,
                snippet: leg['lineName']?.toString(),
              ),
              zIndexInt: 12,
            ),
          );
          added++;
        }
        if (added > 0) {
          _logInfo('Transit stops (leg $li): $added markers');
        }
      }
    } else {
      // Fallback: show nearby OSM stops
      _stopMarkers.clear();
      int added = 0;
      for (final stop in allIndiaStops) {
        final stopPos = LatLng(stop['lat'], stop['lng']);
        if (_isStationNearPath(stopPos, pathPoints, _osmStopsRadiusMeters)) {
          _stopMarkers.add(
            Marker(
              markerId: MarkerId('stop_${stop['id']}'),
              position: stopPos,
              icon: icon,
              infoWindow: InfoWindow(title: stop['name']),
              zIndexInt: 10,
            ),
          );
          added++;
        }
      }
      _markers.addAll(_stopMarkers);
      _logInfo('Transit stops (OSM fallback): $added markers');
    }
  }

  void _drawOsmStopMarkers(BitmapDescriptor icon, List<LatLng> pathPoints) {
    if (pathPoints.isEmpty) return;

    final routeKey =
        _lastRouteKey ?? _lastRouteSignature ?? '${pathPoints.length}';
    final renderKey =
        'route:$routeKey|all:${_osmStopsShowAll}|radius:${_osmStopsRadiusMeters.toStringAsFixed(0)}|strict:${_osmStopsStrictRouteMatch}';

    if (_osmStopRenderKey == renderKey && _osmStopMarkers.isNotEmpty) {
      _markers.addAll(_osmStopMarkers);
      return;
    }

    double minLat = double.infinity;
    double maxLat = -double.infinity;
    double minLon = double.infinity;
    double maxLon = -double.infinity;

    for (final p in pathPoints) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }

    final midLat = (minLat + maxLat) / 2.0;
    final latPad = _osmStopsRadiusMeters / 111000.0;
    final lonPad =
        _osmStopsRadiusMeters /
        (111000.0 * cos(_degToRad(midLat)).abs().clamp(0.2, 1.0));

    _osmStopMarkers.clear();

    for (final stop in allIndiaStops) {
      final lat = (stop['lat'] as num).toDouble();
      final lng = (stop['lng'] as num).toDouble();

      if (!_osmStopsShowAll) {
        if (lat < minLat - latPad ||
            lat > maxLat + latPad ||
            lng < minLon - lonPad ||
            lng > maxLon + lonPad) {
          continue;
        }
      }

      final stopPos = LatLng(lat, lng);
      if (_osmStopsStrictRouteMatch &&
          !_isStationNearPath(stopPos, pathPoints, _osmStopsRadiusMeters)) {
        continue;
      }

      _osmStopMarkers.add(
        Marker(
          markerId: MarkerId('osm_stop_${stop['id']}'),
          position: stopPos,
          icon: icon,
          infoWindow: InfoWindow(title: stop['name']),
          zIndexInt: 11,
        ),
      );
    }

    _osmStopRenderKey = renderKey;
    _markers.addAll(_osmStopMarkers);
    _logInfo(
      'OSM stops overlay: ${_osmStopMarkers.length} markers (showAll=$_osmStopsShowAll, strict=$_osmStopsStrictRouteMatch)',
    );
  }

  Future<void> _refreshTransitStopMarkers() async {
    if (_activeRoute.isEmpty) return;

    // If not in transit mode, ensure no cyan stop markers remain.
    if (!_transitMode) {
      const nextKey = 'none';
      if (_transitStopRenderKey != nextKey) {
        setState(() {
          _markers.removeWhere(
            (m) =>
                m.markerId.value.startsWith('transit_stop_') ||
                m.markerId.value.startsWith('stop_'),
          );
          _stopMarkers.clear();
          _transitStopRenderKey = nextKey;
        });
      }
      if (_showOsmStops) {
        final cyanMarkerIcon = await _createCustomMarkerBitmap(
          Colors.cyanAccent,
          size: 30,
        );
        setState(() {
          _markers.removeWhere((m) => m.markerId.value.startsWith('osm_stop_'));
          _osmStopMarkers.clear();
          _drawOsmStopMarkers(cyanMarkerIcon, _activeRoute);
        });
      } else {
        setState(() {
          _markers.removeWhere((m) => m.markerId.value.startsWith('osm_stop_'));
          _osmStopMarkers.clear();
          _osmStopRenderKey = null;
        });
      }
      return;
    }

    String nextKey = 'all';
    if (!_showAllTransitLegStops) {
      final legs = _lastTransitLegsJson;
      final pm = _lastProgressMetersFromApp;
      if (legs != null && pm != null) {
        int? idx;
        for (int li = 0; li < legs.length; li++) {
          final leg = legs[li];
          final start = (leg['legStartMeters'] as num?)?.toDouble();
          final end = (leg['legEndMeters'] as num?)?.toDouble();
          if (start == null || end == null) continue;
          if (pm >= start && pm <= end) {
            idx = li;
            break;
          }
        }

        if (idx != null) {
          final isMetro = legs[idx]['isMetro'] == true;
          nextKey = isMetro ? 'leg:$idx' : 'none';
        }
      }
    }

    final shouldRefreshOsm = _showOsmStops;
    if (_transitStopRenderKey == nextKey && !shouldRefreshOsm) return;

    final cyanMarkerIcon = await _createCustomMarkerBitmap(
      Colors.cyanAccent,
      size: 30,
    );

    setState(() {
      _markers.removeWhere(
        (m) =>
            m.markerId.value.startsWith('transit_stop_') ||
            m.markerId.value.startsWith('stop_'),
      );
      _stopMarkers.clear();

      if (nextKey != 'none') {
        _drawTransitStopMarkers(
          cyanMarkerIcon,
          _activeRoute,
          restrictToCurrentLeg: !_showAllTransitLegStops,
        );
      }
      _transitStopRenderKey = nextKey;

      if (_showOsmStops) {
        _drawOsmStopMarkers(cyanMarkerIcon, _activeRoute);
      } else {
        _markers.removeWhere((m) => m.markerId.value.startsWith('osm_stop_'));
        _osmStopMarkers.clear();
        _osmStopRenderKey = null;
      }
    });
  }

  List<Polyline> _prefixPolylines(
    List<Polyline> src,
    String prefix, {
    Color? colorOverride,
    int? zIndexOverride,
  }) {
    return src
        .map(
          (p) => Polyline(
            polylineId: PolylineId('$prefix${p.polylineId.value}'),
            points: p.points,
            color: colorOverride ?? p.color,
            width: p.width,
            visible: p.visible,
            zIndex: zIndexOverride ?? p.zIndex,
            jointType: p.jointType,
            patterns: p.patterns,
            startCap: p.startCap,
            endCap: p.endCap,
            geodesic: p.geodesic,
            consumeTapEvents: p.consumeTapEvents,
          ),
        )
        .toList();
  }

  // ─────────────────────────────────────────────────────────────────────
  // Simulation Route Polylines
  // ─────────────────────────────────────────────────────────────────────

  void _updateRoutePolylines() {
    _polylines.removeWhere(
      (p) =>
          p.polylineId.value.startsWith('route_seg_') ||
          p.polylineId.value == 'original_route' ||
          p.polylineId.value.startsWith('grey_route_seg_'),
    );

    final controller = _simController;
    final isDeviating =
        controller?.state == SimulationState.deviating ||
        controller?.state == SimulationState.returning;

    if (_activeRoute.isEmpty) return;

    if (_activeRouteRawSegments.isNotEmpty) {
      if (isDeviating) {
        _addGreyRoutePolylines();
      } else {
        _addColoredRoutePolylines();
      }
    } else {
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

  void _addColoredRoutePolylines() {
    final polylines = _directionService.buildSegmentedPolylinesFromRawSegments(
      _activeRouteRawSegments,
    );

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

  void _addGreyRoutePolylines() {
    final polylines = _directionService.buildSegmentedPolylinesFromRawSegments(
      _activeRouteRawSegments,
    );

    for (int i = 0; i < polylines.length; i++) {
      final p = polylines[i];
      _polylines.add(
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
    _updateRoutePolylines();

    // Deviation path (orange, dashed)
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

    // Current path (teal for returning)
    if (controller.currentPath.isNotEmpty &&
        state == SimulationState.returning) {
      _polylines.add(
        Polyline(
          polylineId: const PolylineId('current_path'),
          points: controller.currentPath,
          color: Colors.teal,
          width: 4,
          patterns: [PatternItem.dash(15), PatternItem.gap(8)],
          zIndex: 3,
        ),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Idle State
  // ─────────────────────────────────────────────────────────────────────

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
    final filename = 'constraint_logs_$now.${format == LogExportFormat.json ? 'json' : 'csv'}';

    if (format == LogExportFormat.json) {
      final payload = {
        'generatedAt': DateTime.now().toIso8601String(),
        'eventCount': events.length,
        'events': events
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

  void _toggleOsmOverlay() {
    setState(() {
      _osmVisible = !_osmVisible;
      _osmOverlay.setVisible(_osmVisible);
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // Logging
  // ─────────────────────────────────────────────────────────────────────

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
  // Helpers
  // ─────────────────────────────────────────────────────────────────────

  bool _isStationNearPath(LatLng stop, List<LatLng> path, double radiusMeters) {
    for (int i = 0; i < path.length; i++) {
      if (_haversineDistance(stop, path[i]) <= radiusMeters) {
        return true;
      }
    }
    return false;
  }

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
    return icon;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Build UI
  // ─────────────────────────────────────────────────────────────────────

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
                    ? Colors.orange.withOpacity(0.2)
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
                  _ekfTestRoutePolyline = polyline;
                  // Note: stations from route JSON ignored - we use allIndiaStops instead
                  _updateEkfTestRouteOnMap(); // async, will call setState internally
                },
                onVisualizationUpdate: (viz) {
                  // Update map markers for EKF test mode
                  _updateEkfTestVisualization(viz);
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
                value: _showAllTransitLegStops,
                onChanged: (v) {
                  setState(() => _showAllTransitLegStops = v);
                  _refreshTransitStopMarkers();
                },
                title: const Text('Show all metro legs'),
                subtitle: const Text('Off = only current leg stops'),
                dense: true,
              ),
              SwitchListTile(
                value: _showOsmStops,
                onChanged: (v) {
                  setState(() => _showOsmStops = v);
                  _refreshTransitStopMarkers();
                },
                title: const Text('Show OSM stop overlay'),
                dense: true,
              ),
              if (_showOsmStops) ...[
                SwitchListTile(
                  value: _osmStopsShowAll,
                  onChanged: (v) {
                    setState(() => _osmStopsShowAll = v);
                    _refreshTransitStopMarkers();
                  },
                  title: const Text('Show all OSM stops'),
                  subtitle: const Text('Heavy; use with caution'),
                  dense: true,
                ),
                SwitchListTile(
                  value: _osmStopsStrictRouteMatch,
                  onChanged: (v) {
                    setState(() => _osmStopsStrictRouteMatch = v);
                    _refreshTransitStopMarkers();
                  },
                  title: const Text('Strict route match'),
                  subtitle: const Text('Require stops within radius of route'),
                  dense: true,
                ),
                const SizedBox(height: 4),
                Text(
                  'OSM radius: ${_osmStopsRadiusMeters.toStringAsFixed(0)} m',
                ),
                Slider(
                  value: _osmStopsRadiusMeters,
                  min: 200,
                  max: 5000,
                  divisions: 24,
                  label: '${_osmStopsRadiusMeters.toStringAsFixed(0)} m',
                  onChanged: (v) {
                    setState(() => _osmStopsRadiusMeters = v);
                    _refreshTransitStopMarkers();
                  },
                ),
              ],

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
              label: 'Transit Stop',
            ),
            _LegendItem(
              color: Colors.cyanAccent,
              isMarker: true,
              label: 'OSM Stop Overlay',
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
