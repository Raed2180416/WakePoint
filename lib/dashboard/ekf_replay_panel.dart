// EKF Replay Panel for Unified Dashboard
//
// Provides controls for:
// - Loading recorded metro routes
// - Playing back IMU data with time warp
// - Toggling GPS dropout simulation
// - Visualizing EKF state (progress, ZUPT, station snaps)

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../core/ekf/imu_replay_engine.dart';

/// EKF Replay mode types.
enum EkfReplayMode {
  /// Not using EKF replay.
  disabled,

  /// Playing back recorded IMU data.
  replay,

  /// Live EKF with optional GPS dropout.
  live,
}

/// Result of EKF replay for visualization.
class EkfReplayVisualization {
  final double ekfProgressMeters;
  final double ekfSigmaMeters;
  final double? gpsProgressMeters;
  final bool gpsDroppedOut;
  final String? motionState; // 'STATIONARY', 'HUMAN', 'VEHICLE'
  final bool zuptActive;
  final String? lastStationSnapped;
  final LatLng? ekfPosition;
  final LatLng? gpsPosition;
  final List<LatLng> stationMarkers;
  final List<double> stationMeters;
  final List<String> stationNames;

  EkfReplayVisualization({
    required this.ekfProgressMeters,
    required this.ekfSigmaMeters,
    this.gpsProgressMeters,
    required this.gpsDroppedOut,
    this.motionState,
    required this.zuptActive,
    this.lastStationSnapped,
    this.ekfPosition,
    this.gpsPosition,
    required this.stationMarkers,
    required this.stationMeters,
    required this.stationNames,
  });
}

/// EKF Replay Panel Widget.
class EkfReplayPanel extends StatefulWidget {
  /// Callback when GPS position should be injected into the app.
  final void Function(LatLng position, double accuracy)? onInjectGps;

  /// Callback when EKF visualization changes.
  final void Function(EkfReplayVisualization)? onVisualizationUpdate;

  /// Callback when route polyline changes.
  final void Function(List<LatLng> polyline, List<LatLng> stations)? onRouteChanged;

  /// External time warp factor (from dashboard).
  final double externalWarpFactor;

  const EkfReplayPanel({
    super.key,
    this.onInjectGps,
    this.onVisualizationUpdate,
    this.onRouteChanged,
    this.externalWarpFactor = 1.0,
  });

  @override
  State<EkfReplayPanel> createState() => _EkfReplayPanelState();
}

class _EkfReplayPanelState extends State<EkfReplayPanel> {
  final ImuReplayEngine _engine = ImuReplayEngine();
  StreamSubscription<ReplayTickResult>? _tickSub;
  StreamSubscription<ReplayState>? _stateSub;

  // UI State
  // ignore: unused_field - Reserved for mode-based UI switching
  EkfReplayMode _mode = EkfReplayMode.disabled;
  String? _selectedRouteId;
  bool _gpsDropout = false;
  bool _showStations = true;
  bool _showEkfPath = true;
  bool _showGpsPath = true;
  double _progress = 0.0;

  // Available routes
  static const _availableRoutes = [
    {'id': 'majestic_to_nallur_halli', 'name': 'Majestic → Nallur Halli (18 stations)'},
    {'id': 'rajajinagar_to_nallur_halli', 'name': 'Rajajinagar → Nallur Halli (23 stations)'},
    {'id': 'nallur_halli_to_vijayanagar', 'name': 'Nallur Halli → Vijayanagar (21 stations)'},
  ];

  // Logged events
  final List<String> _logEvents = [];
  static const _maxLogEvents = 100;

  @override
  void initState() {
    super.initState();
    _tickSub = _engine.tickStream.listen(_onTick);
    _stateSub = _engine.stateStream.listen((_) => setState(() {}));
  }

  @override
  void didUpdateWidget(EkfReplayPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.externalWarpFactor != oldWidget.externalWarpFactor) {
      _engine.setWarpFactor(widget.externalWarpFactor);
    }
  }

  @override
  void dispose() {
    _tickSub?.cancel();
    _stateSub?.cancel();
    _engine.dispose();
    super.dispose();
  }

  void _onTick(ReplayTickResult tick) {
    setState(() {
      _progress = tick.progress;
    });

    // Log station transitions
    if (tick.currentStation != null) {
      final stationName = tick.currentStation!.officialName;
      if (_logEvents.isEmpty || !_logEvents.last.contains(stationName)) {
        _addLogEvent('📍 Station: $stationName @ ${tick.elapsedSeconds.toStringAsFixed(0)}s');
      }
    }

    // Log GPS dropout state changes
    if (tick.gpsDroppedOut && (_logEvents.isEmpty || !_logEvents.last.contains('GPS DROPOUT'))) {
      _addLogEvent('🚫 GPS DROPOUT started');
    }

    // Inject GPS if not dropped out
    if (!tick.gpsDroppedOut && tick.gpsPosition != null) {
      widget.onInjectGps?.call(tick.gpsPosition!, tick.gpsAccuracy ?? 15.0);
    }

    // Update visualization
    final route = _engine.route;
    if (route != null) {
      widget.onVisualizationUpdate?.call(EkfReplayVisualization(
        ekfProgressMeters: tick.elapsedSeconds / route.durationSeconds * route.totalMeters,
        ekfSigmaMeters: 50.0, // TODO: Get from actual EKF
        gpsProgressMeters: tick.gpsDroppedOut ? null : tick.elapsedSeconds / route.durationSeconds * route.totalMeters,
        gpsDroppedOut: tick.gpsDroppedOut,
        motionState: 'VEHICLE',
        zuptActive: false, // TODO: Get from EKF
        lastStationSnapped: tick.currentStation?.officialName,
        ekfPosition: tick.gpsPosition, // TODO: Get from EKF
        gpsPosition: tick.gpsDroppedOut ? null : tick.gpsPosition,
        stationMarkers: route.stations.map((s) => LatLng(
          // Get from route polyline at station index
          route.polyline.isNotEmpty ? route.polyline[route.stations.indexOf(s) % route.polyline.length].latitude : 0,
          route.polyline.isNotEmpty ? route.polyline[route.stations.indexOf(s) % route.polyline.length].longitude : 0,
        )).toList(),
        stationMeters: route.stationMeters,
        stationNames: route.stations.map((s) => s.officialName).toList(),
      ));
    }
  }

  void _addLogEvent(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _logEvents.insert(0, '[$timestamp] $message');
      if (_logEvents.length > _maxLogEvents) {
        _logEvents.removeLast();
      }
    });
  }

  Future<void> _loadRoute(String routeId) async {
    _addLogEvent('📂 Loading route: $routeId');
    try {
      await _engine.loadRoute(routeId);
      setState(() {
        _selectedRouteId = routeId;
        _mode = EkfReplayMode.replay;
      });

      final route = _engine.route;
      if (route != null) {
        widget.onRouteChanged?.call(
          route.polyline,
          route.stations.map((s) => LatLng(
            route.polyline.isNotEmpty ? route.polyline[route.stations.indexOf(s) % route.polyline.length].latitude : 0,
            route.polyline.isNotEmpty ? route.polyline[route.stations.indexOf(s) % route.polyline.length].longitude : 0,
          )).toList(),
        );
        _addLogEvent('✅ Loaded: ${route.stations.length} stations, ${(route.totalMeters/1000).toStringAsFixed(1)}km');
      }
    } catch (e) {
      _addLogEvent('❌ Load failed: $e');
    }
  }

  void _toggleGpsDropout() {
    setState(() {
      _gpsDropout = !_gpsDropout;
      _engine.setGpsDropout(_gpsDropout);
    });
    _addLogEvent(_gpsDropout ? '🚫 GPS DROPOUT enabled' : '📡 GPS restored');
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.science, color: Colors.orange),
                const SizedBox(width: 8),
                const Text(
                  'EKF Replay Testing',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const Spacer(),
                _buildStateChip(),
              ],
            ),
            const Divider(),

            // Route selector
            DropdownButtonFormField<String>(
              value: _selectedRouteId,
              decoration: const InputDecoration(
                labelText: 'Test Route',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _availableRoutes.map((r) => DropdownMenuItem(
                value: r['id'],
                child: Text(r['name']!, style: const TextStyle(fontSize: 12)),
              )).toList(),
              onChanged: (id) {
                if (id != null) _loadRoute(id);
              },
            ),
            const SizedBox(height: 12),

            // Playback controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.replay),
                  tooltip: 'Reset',
                  onPressed: _engine.state != ReplayState.idle ? () {
                    _engine.stop();
                    _addLogEvent('⏹️ Stopped');
                  } : null,
                ),
                IconButton(
                  icon: Icon(_engine.state == ReplayState.playing
                      ? Icons.pause
                      : Icons.play_arrow),
                  iconSize: 36,
                  color: Colors.green,
                  tooltip: _engine.state == ReplayState.playing ? 'Pause' : 'Play',
                  onPressed: _engine.state == ReplayState.ready ||
                          _engine.state == ReplayState.paused
                      ? () {
                          _engine.play();
                          _addLogEvent('▶️ Playing at ${widget.externalWarpFactor}x');
                        }
                      : _engine.state == ReplayState.playing
                          ? () {
                              _engine.pause();
                              _addLogEvent('⏸️ Paused');
                            }
                          : null,
                ),
                const SizedBox(width: 16),
                // GPS Dropout toggle
                Container(
                  decoration: BoxDecoration(
                    color: _gpsDropout ? Colors.red.withOpacity(0.2) : Colors.green.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _gpsDropout ? Colors.red : Colors.green,
                      width: 2,
                    ),
                  ),
                  child: InkWell(
                    onTap: _toggleGpsDropout,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _gpsDropout ? Icons.gps_off : Icons.gps_fixed,
                            color: _gpsDropout ? Colors.red : Colors.green,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _gpsDropout ? 'GPS OFF' : 'GPS ON',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _gpsDropout ? Colors.red : Colors.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Progress slider
            Row(
              children: [
                Text(
                  _formatTime(_engine.elapsedSeconds),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                Expanded(
                  child: Slider(
                    value: _progress,
                    onChanged: (v) {
                      _engine.seekToProgress(v);
                    },
                  ),
                ),
                Text(
                  _formatTime(_engine.durationSeconds),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Stats row
            _buildStatsRow(),
            const SizedBox(height: 8),

            // Visualization toggles
            Row(
              children: [
                _buildToggleChip('Stations', _showStations, (v) => setState(() => _showStations = v)),
                const SizedBox(width: 4),
                _buildToggleChip('EKF Path', _showEkfPath, (v) => setState(() => _showEkfPath = v)),
                const SizedBox(width: 4),
                _buildToggleChip('GPS Path', _showGpsPath, (v) => setState(() => _showGpsPath = v)),
              ],
            ),
            const SizedBox(height: 8),

            // Event log
            Container(
              height: 100,
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(4),
              ),
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _logEvents.length,
                itemBuilder: (ctx, i) => Text(
                  _logEvents[i],
                  style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: Colors.greenAccent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStateChip() {
    final state = _engine.state;
    final (color, label) = switch (state) {
      ReplayState.idle => (Colors.grey, 'IDLE'),
      ReplayState.loading => (Colors.orange, 'LOADING'),
      ReplayState.ready => (Colors.blue, 'READY'),
      ReplayState.playing => (Colors.green, 'PLAYING'),
      ReplayState.paused => (Colors.amber, 'PAUSED'),
      ReplayState.finished => (Colors.purple, 'FINISHED'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 10),
      ),
    );
  }

  Widget _buildStatsRow() {
    final route = _engine.route;
    final currentStation = _engine.currentStation;
    final nextStation = _engine.nextStation;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (currentStation != null)
            Text(
              '📍 ${currentStation.officialName}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          if (nextStation != null)
            Text(
              '→ ${nextStation.officialName} in ${(nextStation.secondsElapsed - _engine.elapsedSeconds).toStringAsFixed(0)}s',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Progress: ${(_progress * 100).toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 10),
              ),
              Text(
                'Distance: ${((_progress * (route?.totalMeters ?? 0)) / 1000).toStringAsFixed(1)}km',
                style: const TextStyle(fontSize: 10),
              ),
              Text(
                'Stations: ${route?.stations.length ?? 0}',
                style: const TextStyle(fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToggleChip(String label, bool value, ValueChanged<bool> onChanged) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 10)),
      selected: value,
      onSelected: onChanged,
      visualDensity: VisualDensity.compact,
    );
  }

  String _formatTime(double seconds) {
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor();
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
}
