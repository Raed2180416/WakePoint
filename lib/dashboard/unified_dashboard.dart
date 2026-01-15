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
import 'osm_overlay_manager.dart';
import 'simulation_controls.dart';
import 'simulation_state.dart';
import 'speed_slider.dart';
import 'time_warp_slider.dart';

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

  // ─────────────────────────────────────────────────────────────────────
  // Simulation UI State
  // ─────────────────────────────────────────────────────────────────────

  bool _drawerOpen = false;
  double _warpFactor = 1.0;
  double _speedKmh = 40.0;
  bool _wasPlayingBeforeScrub = false;
  bool _osmVisible = true;

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
            m.markerId.value.startsWith('stop_'),
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
        _drawTransitStopMarkers(cyanMarkerIcon, points);
      } else {
        _stopMarkers.clear();
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

  void _drawTransitStopMarkers(BitmapDescriptor icon, List<LatLng> pathPoints) {
    // Prefer runtime-provided transit legs
    if (_lastTransitLegsJson != null) {
      final legs = _lastTransitLegsJson!;

      // If we can determine the current leg from progress meters, only render
      // metro stops for the current metro leg. If the current leg is not metro,
      // render no cyan dots.
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
        }
        return;
      }

      for (int li = 0; li < legs.length; li++) {
        final leg = legs[li];
        final isMetro = leg['isMetro'] == true;
        if (!isMetro) continue;

        final positions = (leg['stopPositions'] as List?) ?? const [];
        final names = (leg['stopNames'] as List?) ?? const [];

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
        }
      }
    } else {
      // Fallback: show nearby OSM stops
      _stopMarkers.clear();
      for (final stop in allIndiaStops) {
        final stopPos = LatLng(stop['lat'], stop['lng']);
        if (_isStationNearPath(stopPos, pathPoints, 500)) {
          _stopMarkers.add(
            Marker(
              markerId: MarkerId('stop_${stop['id']}'),
              position: stopPos,
              icon: icon,
              infoWindow: InfoWindow(title: stop['name']),
              zIndexInt: 10,
            ),
          );
        }
      }
      _markers.addAll(_stopMarkers);
    }
  }

  Future<void> _refreshTransitStopMarkers() async {
    if (_activeRoute.isEmpty) return;

    // If not in transit mode, ensure no cyan stop markers remain.
    if (!_transitMode) {
      const nextKey = 'none';
      if (_transitStopRenderKey == nextKey) return;
      setState(() {
        _markers.removeWhere(
          (m) =>
              m.markerId.value.startsWith('transit_stop_') ||
              m.markerId.value.startsWith('stop_'),
        );
        _stopMarkers.clear();
        _transitStopRenderKey = nextKey;
      });
      return;
    }

    String nextKey = 'all';
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

    if (_transitStopRenderKey == nextKey) return;

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
        _drawTransitStopMarkers(cyanMarkerIcon, _activeRoute);
      }
      _transitStopRenderKey = nextKey;
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
      width: 340,
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
