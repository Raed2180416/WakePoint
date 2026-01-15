import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:async';
import 'dart:convert';
import 'all_india_stops.dart'; // OSM Data for all cities
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:developer' as dev;

// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'config/playground_bridge.dart';
import 'simulation_engine.dart'; // Import the engine
import 'dashboard/alarm_debouncer.dart';
import 'services/direction_service.dart';
import 'services/testing/osm_loader.dart';
import 'services/testing/osm_graph.dart';

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

  // Route Data State
  // _segments removed as field, passed locally.
  // List<Map<String, dynamic>>? _routeEvents; // removed

  // Track last loaded route signature to avoid resetting the map on repeated broadcasts.
  String? _lastRouteSignature;

  // Preferred stable identifier for routes (sent by app as route_key).
  String? _lastRouteKey;

  // Cache polylines per route key so transit colors don't change across rebroadcasts,
  // and so inactive routes can be rendered using the same segmentation.
  final Map<String, List<Polyline>> _routePolylinesByKey = {};
  final Map<String, List<Polyline>> _routeGreyPolylinesByKey = {};

  final DirectionService _directionService = DirectionService();

  // OSM Graph and overlay state
  OsmGraph? _osmGraph;
  Set<Polyline> _osmOverlayPolylines = {};
  bool _osmOverlayVisible = true;
  bool _osmLoading = false;
  // ignore: unused_field
  String? _osmLoadError;

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
  final AlarmDebouncer _debouncer = AlarmDebouncer();
  bool _transitMode = false; // Track if current route is transit mode

  // Simulation Engine
  final SimulationEngine _engine = SimulationEngine();
  Timer? _loopTimer;

  // Demo Route (Bengaluru - within loaded OSM bbox)
  final List<LatLng> _demoRoute = [
    const LatLng(12.9716, 77.5946), // MG Road
    const LatLng(12.9766, 77.5993), // Trinity
    const LatLng(12.9850, 77.6050), // Indiranagar
    const LatLng(12.9900, 77.6150), // HAL
    const LatLng(12.9950, 77.6250), // Airport Road
  ];

  // Device Position State (from physical device)
  LatLng? _devicePosition;
  bool _trackingActive = false; // Tracks if device is actively tracking

  // State for naming
  // _currentDestinationName removed
  final List<String> _eventLogs = [];
  bool _wasPlayingBeforeScrub = false;

  @override
  void initState() {
    super.initState();
    super.initState();
    _connectToRelay();
    _logEvent('System initialized.');
    _loadOsmGraph(); // Load Bengaluru OSM roads

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

  /// Load Bengaluru OSM graph and build overlay polylines.
  Future<void> _loadOsmGraph() async {
    setState(() {
      _osmLoading = true;
      _osmLoadError = null;
    });

    try {
      final graph = await OsmLoader.loadAsset('assets/osm/bengaluru.wkp');
      _logEvent(
        'Loaded OSM graph: ${graph.nodes.length} nodes, ${graph.edges.length} edges',
      );

      // Build polylines from graph edges for overlay visualization
      final polylines = <Polyline>{};
      int polylineIdx = 0;

      // Group edges by road type for styling
      for (final edge in graph.edges) {
        final fromNode = graph.nodes[edge.fromIndex];
        final toNode = graph.nodes[edge.toIndex];

        final points = [
          LatLng(fromNode.lat, fromNode.lon),
          LatLng(toNode.lat, toNode.lon),
        ];

        // Style based on road type
        final color = _roadTypeColor(edge.roadType.value);
        final width = _roadTypeWidth(edge.roadType.value);

        polylines.add(
          Polyline(
            polylineId: PolylineId('osm_edge_$polylineIdx'),
            points: points,
            color: color.withValues(alpha: 0.4),
            width: width,
            zIndex: -10, // Below route polylines
          ),
        );
        polylineIdx++;
      }

      setState(() {
        _osmGraph = graph;
        _osmOverlayPolylines = polylines;
        _osmLoading = false;
      });
      _logEvent('OSM overlay ready: ${polylines.length} road segments');
    } catch (e) {
      setState(() {
        _osmLoading = false;
        _osmLoadError = e.toString();
      });
      _logEvent('OSM load failed: $e');
    }
  }

  Color _roadTypeColor(int roadType) {
    return switch (roadType) {
      1 || 2 => const Color(0xFFE65100), // motorway/link - orange
      3 || 4 => const Color(0xFFFF8F00), // trunk/link - amber
      5 || 6 => const Color(0xFFFFD600), // primary/link - yellow
      7 || 8 => const Color(0xFFAED581), // secondary/link - light green
      9 || 10 => const Color(0xFF81D4FA), // tertiary/link - light blue
      11 || 12 => const Color(0xFFB0BEC5), // residential/living - grey
      13 || 14 => const Color(0xFF90A4AE), // unclassified/service
      _ => const Color(0xFF78909C), // other
    };
  }

  int _roadTypeWidth(int roadType) {
    return switch (roadType) {
      1 || 2 => 4, // motorway
      3 || 4 => 3, // trunk
      5 || 6 => 3, // primary
      7 || 8 => 2, // secondary
      9 || 10 => 2, // tertiary
      _ => 1, // residential/other
    };
  }

  void _toggleOsmOverlay() {
    setState(() {
      _osmOverlayVisible = !_osmOverlayVisible;
    });
    _logEvent('OSM overlay: ${_osmOverlayVisible ? "visible" : "hidden"}');
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
        });
        _logEvent('Disconnected from Relay');
        _scheduleReconnect();
      });

      _socket!.onError.listen((error) {
        setState(() {
          _connected = false;
        });
        _logEvent('Connection Error: $error');
        _scheduleReconnect();
      });
    } catch (e) {
      // setState(() => _status = 'Error: $e');
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
        final routeKey = json['route_key'] as String?;
        final List<dynamic> pointsJson = json['points'];
        final List<LatLng> points =
            pointsJson.map((p) => LatLng(p['lat'], p['lng'])).toList();

        final segments =
            (json['segments'] as List?)?.cast<Map<String, dynamic>>();
        final switchPoints =
            (json['switch_points'] as List?)?.cast<Map<String, dynamic>>();
        final events = (json['events'] as List?)?.cast<Map<String, dynamic>>();
        final inactiveRoutes =
            (json['inactive_routes'] as List?)?.cast<Map<String, dynamic>>();
        if (inactiveRoutes != null) {
          dev.log(
            'DashDebug: Received ${inactiveRoutes.length} inactive routes',
          );
        }
        final transitMode = json['transit_mode'] as bool? ?? false;

        // Authoritative runtime transit legs payload (preferred).
        final transitLegs =
            (json['transit_legs'] as List?)?.cast<Map<String, dynamic>>();

        final destName = json['destinationName'] as String?;
        // _currentDestinationName = destName; // Unused
        final sig = _computeRouteSignature(points, destName);

        _logEvent(
          'RX Route: ${points.length} pts, ${segments?.length} segs, ${switchPoints?.length} switches, transitMode=$transitMode',
        );
        _logEvent('Keys: ${json.keys.toList()}'); // Debug keys

        final isSameRoute =
            routeKey != null
                ? (_lastRouteKey == routeKey)
                : (_lastRouteSignature == sig);

        final prevProgress = _engine.progress;
        final hadRoute = _engine.hasRoute;

        setState(() {
          // _segments field removed
          // _routeEvents = events; // removed
          _transitMode = transitMode; // Store transit mode for save/load

          if (!isSameRoute) {
            final oldRouteBefore = List<LatLng>.of(_engine.route);
            // New route. Reset the engine route.
            _engine.loadRoute(points);

            // Legacy sender (no routeKey): if endpoints are essentially unchanged,
            // preserve progress to avoid random resets on periodic rebroadcast.
            if (routeKey == null && hadRoute && prevProgress > 0.0) {
              if (oldRouteBefore.isNotEmpty && points.isNotEmpty) {
                final startDelta = _haversineDist(
                  oldRouteBefore.first,
                  points.first,
                );
                final endDelta = _haversineDist(
                  oldRouteBefore.last,
                  points.last,
                );
                if (startDelta < 120 && endDelta < 120) {
                  _engine.seek(prevProgress);
                }
              }
            }
            _updateMapRoute(
              points,
              segments: segments,
              switchPoints: switchPoints,
              routeEvents: events,
              inactiveRoutes: inactiveRoutes,
              transitMode: transitMode,
              routeKey: routeKey,
            );
            _lastRouteSignature = sig;
            _lastRouteKey = routeKey;

            _lastTransitLegsJson = transitLegs;

            // Move camera to start only when the route actually changes.
            if (points.isNotEmpty) {
              _mapController?.animateCamera(
                CameraUpdate.newLatLngZoom(points.first, 14),
              );
            }
          } else {
            // Same route rebroadcast: just refresh alarms/segments without resetting camera.
            // But we must update _segments and _routeEvents as they might contain new alarm info
            // _segments = segments; // removed
            // _routeEvents = events; // removed
            _updateMapRoute(
              points, // Pass current points to ensure map stays consistent
              segments: segments,
              switchPoints: switchPoints,
              routeEvents: events,
              inactiveRoutes: inactiveRoutes,
              transitMode: transitMode,
              routeKey: routeKey,
              forceRepaint: true, // Force marker updates
            );

            _lastTransitLegsJson = transitLegs;

            // If a key is present, keep it fresh.
            if (routeKey != null) {
              _lastRouteKey = routeKey;
            }
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
            _metricAlarm = '${json['alarm_mode']} (${json['alarm_value']})';
            // _currentAlarmValue field removed
            _updateAlarmMarkers();
          }

          if (json['remaining_stops'] != null) {
            final double stops = (json['remaining_stops'] as num).toDouble();
            _metricStops = stops.toStringAsFixed(1);
          }

          final serverAlarmFired = json['alarm_fired'] == true;
          final now = DateTime.now();

          final shouldLog = _debouncer.update(serverAlarmFired, now);
          if (shouldLog) {
            _logEvent('ALARM FIRED!');
          }

          if (json['debug_info'] != null) {
            final info = json['debug_info'] as Map<String, dynamic>;
            // Keep this lightweight; it's a diagnostics pane.
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
            }
            if (info['progress_jump_m'] != null) {
              parts.add('jump=${info['progress_jump_m']}m');
            }
            if (info['next_event_type'] != null) {
              parts.add('next=${info['next_event_type']}');
            }
            if (info['to_next_event_m'] != null) {
              parts.add('toNext=${info['to_next_event_m']}m');
            }
            if (info['poly_total_m'] != null && info['step_total_m'] != null) {
              parts.add(
                'poly/step=${info['poly_total_m']}/${info['step_total_m']}',
              );
            }
            // Backwards-compat with older debug keys.
            if (info['stepBounds'] != null) {
              parts.add('Bounds:${info['stepBounds']}');
            }
            if (info['stepStops'] != null) {
              parts.add('Stops:${info['stepStops']}');
            }
            if (info['routeEvents'] != null) {
              parts.add('Events:${info['routeEvents']}');
            }
            _metricDebug = parts.join(' | ');
          }
        });

        // Handle "End Tracking" signal
        if (json['active'] == false && _trackingActive) {
          _trackingActive = false;
          _logEvent('Tracking ended. Clearing route.');
          _clearRouteForIdle();
        } else if (json['active'] == true) {
          _trackingActive = true;
        }
      } else if (json['type'] == 'device_position') {
        // Received real device position from MapTrackingScreen
        final double lat = (json['lat'] as num).toDouble();
        final double lng = (json['lng'] as num).toDouble();
        final newPos = LatLng(lat, lng);
        final isFirst = _devicePosition == null;
        _devicePosition = newPos;

        // If no route is loaded, move camera to device position
        if (!_engine.hasRoute || !_engine.isPlaying) {
          setState(() {
            // Update device marker
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
          // Move camera on first device position or if no route
          if (isFirst || !_engine.hasRoute) {
            _mapController?.animateCamera(
              CameraUpdate.newLatLngZoom(newPos, 14),
            );
          }
        }
      }
    } catch (e) {
      dev.log('Dashboard: Error parsing message: $e');
    }
  }

  void _broadcastPosition() {
    if (_socket != null &&
        _socket!.readyState == html.WebSocket.OPEN &&
        _engine.currentPosition != null) {
      // _gpsEnabled check removed (Chaos Engineering removed)

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
      setState(() => _debouncer.reset());
    } else {
      dev.log(
        'DEBUG: main_dashboard - WebSocket not connected, cannot send reset',
        name: 'MainDashboard',
      );
    }
  }

  /// Clears the route and markers when tracking ends, keeping only the device marker.
  void _clearRouteForIdle() {
    setState(() {
      _polylines.clear();
      _markers.removeWhere((m) => m.markerId.value != 'device_marker');
      _stopMarkers.clear();
      _lastRouteSignature = null;
      // _routeEvents = null; // Unused
      _engine.loadRoute([]); // Clear engine route
      _metricDistance = '---';
      _metricTime = '---';
      _metricStops = '---';
      _metricAlarm = '---';
    });
    // Move camera back to device position
    if (_devicePosition != null) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(_devicePosition!, 14),
      );
    }
  }

  // _saveCurrentRoute, _deleteRoute, _loadSavedRoutes, _loadRoute, _forceDeviation, _loadDeviationRoute REMOVED

  Future<void> _updateMapRoute(
    List<LatLng> points, {
    List<Map<String, dynamic>>? segments,
    List<Map<String, dynamic>>? switchPoints,
    List<Map<String, dynamic>>? routeEvents,
    List<Map<String, dynamic>>? inactiveRoutes,
    bool transitMode = false,
    String? routeKey,
    bool forceRepaint = false,
  }) async {
    // Pre-generate marker icons (must be done outside setState)
    final cyanMarkerIcon = await _createCustomMarkerBitmap(
      Colors.cyanAccent,
      size: 30,
    );

    List<Polyline> prefixPolylines(
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
    // purpleIcon removed
    /*
    final purpleIcon = await _createCustomMarkerBitmap(
      Colors.purpleAccent,
      size: 26,
    );
    */

    setState(() {
      // _segments = segments; // removed
      // _routeEvents = routeEvents; // removed
      _polylines.clear();
      // Keep alarm markers, clear route markers?
      // Rebuild specific markers below
      _markers.removeWhere((m) => !m.markerId.value.startsWith('alarm_'));

      // Draw Inactive Routes (Grey)
      if (inactiveRoutes != null) {
        for (final route in inactiveRoutes) {
          final inactiveKeyRaw = route['route_key'] ?? route['key'];
          final inactiveKey =
              inactiveKeyRaw is String && inactiveKeyRaw.trim().isNotEmpty
                  ? inactiveKeyRaw.trim()
                  : null;

          // Preferred: reuse cached segmentation for this route key.
          if (inactiveKey != null) {
            final cachedGrey = _routeGreyPolylinesByKey[inactiveKey];
            if (cachedGrey != null && cachedGrey.isNotEmpty) {
              _polylines.addAll(cachedGrey);
              continue;
            }
          }

          // Next best: build from raw segments if provided.
          final inactiveSegments =
              (route['segments'] as List?)?.cast<Map<String, dynamic>>();
          if (inactiveSegments != null && inactiveSegments.isNotEmpty) {
            final base = _directionService
                .buildSegmentedPolylinesFromRawSegments(inactiveSegments);
            final derivedKey = inactiveKey ?? 'inactive_${route.hashCode}';
            final grey = prefixPolylines(
              base,
              'inactive:$derivedKey:',
              colorOverride: Colors.grey,
              zIndexOverride: 0,
            );
            if (inactiveKey != null) {
              _routeGreyPolylinesByKey[inactiveKey] = grey;
            }
            _polylines.addAll(grey);
            continue;
          }

          // Fallback: render provided points as a single grey polyline.
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
      }

      // Collect all polyline points to check against
      final List<LatLng> pathPoints = [];
      if (segments != null) {
        for (final seg in segments) {
          final pts = (seg['points'] as List).map(
            (p) => LatLng(p['lat'], p['lng']),
          );
          pathPoints.addAll(pts);
        }
      } else {
        pathPoints.addAll(points);
      }

      // 4. Station Markers (Cyan)
      // Prefer runtime-provided transit legs (exactly what alarm logic sees).
      // Fallback to legacy OSM-near-path visualization only if transit legs were not sent.
      final hasRuntimeTransitLegs = _lastTransitLegsJson != null;
      if (hasRuntimeTransitLegs) {
        _markers.removeWhere(
          (m) => m.markerId.value.startsWith('transit_stop_'),
        );

        final legs = _lastTransitLegsJson!;
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
                icon: cyanMarkerIcon,
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
        // Legacy dashboard visualization: show any nearby OSM stops.
        if (_stopMarkers.isEmpty || forceRepaint) {
          _stopMarkers.clear();
          for (final stop in allIndiaStops) {
            final stopPos = LatLng(stop['lat'], stop['lng']);
            if (_isStationNearPath(stopPos, pathPoints, 500)) {
              _stopMarkers.add(
                Marker(
                  markerId: MarkerId('stop_${stop['id']}'),
                  position: stopPos,
                  icon: cyanMarkerIcon,
                  infoWindow: InfoWindow(title: stop['name']),
                  zIndexInt: 10,
                ),
              );
            }
          }
        }
        _markers.addAll(_stopMarkers);
      }

      // 5. Switch Points (Purple) - REMOVED per user request
      /*
      if (switchPoints != null) {
        for (int i = 0; i < switchPoints.length; i++) {
          final sp = switchPoints[i];
          _markers.add(
            Marker(
              markerId: MarkerId('switch_\$i'),
              position: LatLng(sp['lat'], sp['lng']),
              icon: purpleIcon,
              infoWindow: InfoWindow(title: sp['label'] ?? 'Switch Point'),
              zIndex: 20,
            ),
          );
        }
      }
      */

      // 6. Polylines
      if (segments != null && segments.isNotEmpty) {
        final hasKey = routeKey != null && routeKey.trim().isNotEmpty;
        if (hasKey) {
          final key = routeKey.trim();
          var cached = _routePolylinesByKey[key];
          if (cached == null || cached.isEmpty) {
            final base = _directionService
                .buildSegmentedPolylinesFromRawSegments(segments);
            cached = prefixPolylines(base, 'active:$key:');
            _routePolylinesByKey[key] = cached;
            _routeGreyPolylinesByKey.putIfAbsent(
              key,
              () => prefixPolylines(
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
          _polylines.addAll(prefixPolylines(base, 'active:legacy:'));
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

      // 7. Start/End Markers
      if (points.isNotEmpty) {
        _markers.add(
          Marker(
            markerId: const MarkerId('route_start'),
            position: points.first,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
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

    // Update alarm markers
    await _updateAlarmMarkers();
  }

  void _updateGhostMarker() {
    if (_engine.currentPosition == null) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == 'ghost');
      _markers.add(
        Marker(
          markerId: const MarkerId('ghost'),
          position: _engine.currentPosition!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          infoWindow: const InfoWindow(title: 'Simulated User'),
          zIndexInt: 200,
        ),
      );
    });

    _mapController?.animateCamera(
      CameraUpdate.newLatLng(_engine.currentPosition!),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GeoWake Dashboard v2 (Optimized)'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Icon(
                    _connected ? Icons.link : Icons.link_off,
                    color: _connected ? Colors.greenAccent : Colors.redAccent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _connected ? 'Connected' : 'Disconnected',
                    style: TextStyle(
                      color: _connected ? Colors.greenAccent : Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
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
                            _debouncer.reset();
                          });
                        },
                      ),
                      // OSM overlay toggle
                      IconButton(
                        icon: Icon(
                          _osmOverlayVisible
                              ? Icons.layers
                              : Icons.layers_outlined,
                          color:
                              _osmLoading
                                  ? Colors.orange
                                  : (_osmGraph != null
                                      ? Colors.green
                                      : Colors.grey),
                        ),
                        tooltip:
                            _osmLoading
                                ? 'Loading Bengaluru roads...'
                                : (_osmGraph != null
                                    ? '${_osmOverlayPolylines.length} road segments'
                                    : 'OSM not loaded'),
                        onPressed:
                            _osmGraph != null
                                ? _toggleOsmOverlay
                                : _loadOsmGraph,
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
                          max: 200.0,
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
                        // Reset alarm state on significant scrub (robustness)
                        if ((v - oldProgress).abs() > 0.05) {
                          // _alarmTriggered = false; // removed
                          _debouncer.reset();
                          // Note: We don't clear the last fired *time* to prevent instant re-trigger
                          // if we land back in the zone, but we assume re-entering zone is a valid new event.
                        }
                      });
                      if (v < oldProgress - 0.05) {
                        _broadcastAlarmReset();
                      }
                    },
                    onChangeStart: (_) {
                      _wasPlayingBeforeScrub = _engine.isPlaying;
                      setState(() => _engine.isPlaying = false);
                    },
                    onChangeEnd: (_) {
                      if (_wasPlayingBeforeScrub) {
                        setState(() => _engine.isPlaying = true);
                      }
                    },
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

                  // Removed Reroute Latency UI
                  if (_debouncer.isTriggered)
                    Container(
                      padding: const EdgeInsets.all(8),
                      margin: const EdgeInsets.only(top: 10),
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
                  polylines: {
                    // OSM overlay (below route)
                    if (_osmOverlayVisible) ..._osmOverlayPolylines,
                    // Route polylines (on top)
                    ..._polylines,
                  },
                  onTap: (pos) {
                    setState(() {
                      _engine.currentPosition = pos;
                      _updateGhostMarker();
                      _broadcastPosition();
                    });
                  },
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.5),
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
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  // --- Helper Methods ---

  final Set<Marker> _stopMarkers = {};

  Future<void> _updateAlarmMarkers() async {
    // Optimization: Dont recreate if nothing changed?
    // Actually we need to check _routeEvents.

    // Check condition: if transitMode is true AND alarmMode is TIME,
    // user requested to remove yellow dots.
    if (_transitMode && _currentAlarmMode?.toLowerCase() == 'time') {
      setState(() {
        _markers.removeWhere((m) => m.markerId.value.startsWith('alarm_pred_'));
      });
      return;
    }

    // yellowIcon removed
    /*
    final yellowIcon = await _createCustomMarkerBitmap(
      Colors.yellowAccent,
      size: 28,
    );
    */
    /*
    setState(() {
      _markers.removeWhere((m) => m.markerId.value.startsWith('alarm_pred_'));

      if (_routeEvents != null) {
        for (int i = 0; i < _routeEvents!.length; i++) {
          final ev = _routeEvents![i];
          final lat = ev['lat'];
          final lng = ev['lng'];
          final label = ev['label'];

          if (lat != null && lng != null) {
            _markers.add(
              Marker(
                markerId: MarkerId('alarm_pred_ev_\$i'),
                position: LatLng(lat, lng),
                icon: yellowIcon,
                zIndex: 30,
                infoWindow: InfoWindow(title: label ?? 'Alarm Event'),
              ),
            );
          }
        }
      }
    });
    */
  }

  // Add state variables
  String? _currentAlarmMode;
  // _currentAlarmValue removed

  // Authoritative runtime transit legs payload from route_update.
  List<Map<String, dynamic>>? _lastTransitLegsJson;

  bool _isStationNearPath(LatLng stop, List<LatLng> path, double radiusMeters) {
    // Check every point to ensure we don't miss stops on long segments
    // (Performance trade-off acceptable for correctness)
    const step = 1;
    for (int i = 0; i < path.length; i += step) {
      if (_haversineDist(stop, path[i]) <= radiusMeters) {
        return true;
      }
    }
    return false;
  }

  double _haversineDist(LatLng p1, LatLng p2) {
    const R = 6371000.0; // Earth radius in meters
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

  // Cache icons
  BitmapDescriptor? _cachedCyanIcon;
  // Others removed
  /*
  BitmapDescriptor? _cachedPurpleIcon;
  BitmapDescriptor? _cachedYellowIcon;
  */

  Future<BitmapDescriptor> _createCustomMarkerBitmap(
    Color color, {
    double size = 24,
  }) async {
    // Use cached if available
    if (color == Colors.cyanAccent && _cachedCyanIcon != null) {
      return _cachedCyanIcon!;
    }
    // Purple and Yellow removed per user request
    /*
    if (color == Colors.purpleAccent && _cachedPurpleIcon != null)
      return _cachedPurpleIcon!;
    if (color == Colors.yellowAccent && _cachedYellowIcon != null)
      return _cachedYellowIcon!;
    */

    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = color;
    final double radius = size / 2;

    canvas.drawCircle(Offset(radius, radius), radius, paint);

    final Paint borderPaint =
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;
    canvas.drawCircle(Offset(radius, radius), radius - 1, borderPaint);

    final ui.Image image = await pictureRecorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final ByteData? byteData = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final icon = BitmapDescriptor.bytes(byteData!.buffer.asUint8List());

    // Cache
    if (color == Colors.cyanAccent) _cachedCyanIcon = icon;
    // Removed cache assignments for purple/yellow
    /*
    if (color == Colors.purpleAccent) _cachedPurpleIcon = icon;
    if (color == Colors.yellowAccent) _cachedYellowIcon = icon;
    */

    return icon;
  }
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
