// EKF Test Panel - Simplified Dashboard Widget for Route Replay Testing
//
// Provides:
// - 3 curated route options for selection
// - Start/Stop controls only
// - Read-only metrics display (speed, IMU, ZUPT, station info)
// - Time warp is controlled externally from main dashboard

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import '../services/trackingservice.dart' as ts;

import '../core/ekf/ekf_test_controller.dart';
import '../core/ekf/imu_replay_engine_v2.dart';

/// Curated test routes available for selection.
enum CuratedRoute {
  /// Purple Line: Majestic to Nallur Halli (Metro)
  purpleLine,

  /// Green Line: Nagasandra to Silk Institute (Metro)
  greenLine,

  /// Non-Metro: Koramangala to Indiranagar (Auto/Cab)
  nonMetro,

  /// Log Replay: Nallur Halli to Vijayanagar (Real Data)
  logReplay,
}

/// Widget providing simplified EKF testing controls for the dashboard.
class EkfTestPanel extends StatefulWidget {
  /// Callback when GPS position should be injected.
  final void Function(LatLng position, double accuracy, double speed)?
  onInjectGps;

  /// Callback when route polyline/stations change.
  final void Function(List<LatLng> polyline, List<LatLng> stations)?
  onRouteChanged;

  /// Callback when visualization updates.
  final void Function(EkfTestVisualization)? onVisualizationUpdate;

  /// External warp factor (from main dashboard slider).
  final double externalWarpFactor;

  const EkfTestPanel({
    super.key,
    this.onInjectGps,
    this.onRouteChanged,
    this.onVisualizationUpdate,
    this.externalWarpFactor = 1.0,
  });

  @override
  State<EkfTestPanel> createState() => _EkfTestPanelState();
}

class _EkfTestPanelState extends State<EkfTestPanel> {
  final EkfTestController _controller = EkfTestController();
  final ScrollController _logScrollController = ScrollController();

  // UI State
  CuratedRoute _selectedRoute = CuratedRoute.logReplay;
  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _gpsEnabled = true; // Toggle for GPS on/off

  // Visualization state
  EkfTestVisualization? _lastViz;

  // Log display
  final List<EkfTestLogEntry> _displayLogs = [];
  static const int _maxDisplayLogs = 100;

  @override
  void initState() {
    super.initState();
    _setupController();
  }

  void _setupController() {
    _controller.onVisualizationUpdate = _onVisualizationUpdate;
    _controller.onLogEntry = _onLogEntry;
    _controller.logVerbosity = 2; // Events + Info
  }

  @override
  void didUpdateWidget(EkfTestPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.externalWarpFactor != oldWidget.externalWarpFactor) {
      _controller.warpFactor = widget.externalWarpFactor;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _onVisualizationUpdate(EkfTestVisualization viz) {
    setState(() {
      _lastViz = viz;
      _isPlaying = _controller.isPlaying;
    });

    // Inject GPS if available
    if (viz.gpsAvailable && viz.gpsPosition != null) {
      widget.onInjectGps?.call(viz.gpsPosition!, 15.0, viz.speedMps);
    }

    widget.onVisualizationUpdate?.call(viz);
  }

  void _onLogEntry(EkfTestLogEntry entry) {
    // Only show important logs (ZUPT, stations, alarms)
    if (entry.category == EkfTestLogCategory.imu) return;

    setState(() {
      _displayLogs.insert(0, entry);
      if (_displayLogs.length > _maxDisplayLogs) {
        _displayLogs.removeLast();
      }
    });
  }

  TestRouteId _mapCuratedToTestRoute(CuratedRoute route) {
    return switch (route) {
      CuratedRoute.purpleLine => TestRouteId.majesticToNallurHalli,
      CuratedRoute.greenLine => TestRouteId.rajajinargarToNallurHalli,
      CuratedRoute.nonMetro => TestRouteId.koramangalaToIndiranagar,
      CuratedRoute.logReplay => TestRouteId.nallurHalliToVijayanagar,
    };
  }

  Future<void> _loadRoute() async {
    try {
      final testRouteId = _mapCuratedToTestRoute(_selectedRoute);

      if (_selectedRoute == CuratedRoute.logReplay) {
        // Hardcoded path for the specific log requirement
        await _controller.loadLog(
          'assets/logs/Nallur_to_Vijaynagar',
          testRouteId,
        );
      } else {
        await _controller.loadRoute(testRouteId);
      }

      final route = _controller.route;
      if (route != null) {
        widget.onRouteChanged?.call(
          route.fullPolyline,
          route.allStations.map((s) => s.position).toList(),
        );
      }

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      _showError('Failed to load route: $e');
    }
  }

  void _startTest() {
    // Wire up streams to TrackingService for injection
    // ignore: invalid_use_of_visible_for_testing_member
    ts.testAccelerometerStream = _controller.accelerometerStream;
    // ignore: invalid_use_of_visible_for_testing_member
    ts.testGyroscopeStream = _controller.gyroscopeStream;
    // Note: GPS is injected via onInjectGps callback which calls LocationManager,
    // but we can also set the stream here for completeness if TrackingService uses it directly.
    // _controller.gpsStream is a stream of Positions.
    // ts.testGpsStream = _controller.gpsStream; // GPS is injected via callback

    if (!_isInitialized) {
      _loadRoute().then((_) {
        if (_isInitialized) {
          _controller.play();
          setState(() => _isPlaying = true);
        }
      });
    } else {
      _controller.play();
      setState(() => _isPlaying = true);
    }
  }

  void _stopTest() {
    _controller.stop();
    // Clean up injection streams
    // ignore: invalid_use_of_visible_for_testing_member
    ts.testAccelerometerStream = null;
    // ignore: invalid_use_of_visible_for_testing_member
    ts.testGyroscopeStream = null;
    ts.testGpsStream = null;

    _displayLogs.clear();
    setState(() {
      _isPlaying = false;
      _lastViz = null;
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _exportEkfLogs(String format) {
    final logs = _controller.logs;
    if (logs.isEmpty) {
      _showError('No EKF logs to export');
      return;
    }

    final now = DateTime.now().toIso8601String().replaceAll(':', '-');
    final filename = 'ekf_logs_$now.$format';

    if (format == 'json') {
      final payload = {
        'generatedAt': DateTime.now().toIso8601String(),
        'scenario': _controller.scenario.name,
        'warpFactor': _controller.warpFactor,
        'logCount': logs.length,
        'logs': logs
            .map(
              (l) => {
                'timestamp': l.timestamp.toIso8601String(),
                'elapsedSeconds': l.elapsedSeconds,
                'category': l.category.name,
                'level': l.level,
                'message': l.message,
                'data': l.data,
              },
            )
            .toList(),
      };
      final jsonText = const JsonEncoder.withIndent('  ').convert(payload);
      _downloadTextFile(filename, jsonText, 'application/json');
      return;
    }

    final header =
        'timestamp,elapsedSeconds,category,level,message,data';
    final rows = logs.map((l) {
      final values = [
        l.timestamp.toIso8601String(),
        l.elapsedSeconds.toStringAsFixed(3),
        l.category.name,
        l.level,
        l.message,
        l.data != null ? jsonEncode(l.data) : '',
      ];
      return values.map(_escapeCsv).join(',');
    });
    final csv = ([header, ...rows]).join('\n');
    _downloadTextFile(filename, csv, 'text/csv');
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

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildRouteSelector(),
                    const SizedBox(height: 16),
                    _buildStartStopButton(),
                    const SizedBox(height: 12),
                    _buildGpsToggle(),
                    const SizedBox(height: 16),
                    _buildProgressIndicator(),
                    const SizedBox(height: 16),
                    _buildMetricsPanel(),
                    const SizedBox(height: 12),
                    _buildLogPanel(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.1),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.science, color: Colors.deepPurple, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'EKF Test Mode',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
          _buildStateChip(),
        ],
      ),
    );
  }

  Widget _buildStateChip() {
    final (color, label) =
        _isPlaying
            ? (Colors.green, 'RUNNING')
            : _isInitialized
            ? (Colors.blue, 'READY')
            : (Colors.grey, 'SELECT ROUTE');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _buildRouteSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Test Route',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        const SizedBox(height: 8),
        // Restricted to Log Replay only
        _buildRouteOption(CuratedRoute.logReplay),
      ],
    );
  }

  Widget _buildRouteOption(CuratedRoute route) {
    final isSelected = _selectedRoute == route;
    final (icon, name, description, color) = _routeInfo(route);

    return GestureDetector(
      onTap:
          _isPlaying
              ? null
              : () {
                setState(() {
                  _selectedRoute = route;
                  _isInitialized = false;
                });
              },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color:
              isSelected
                  ? color.withValues(alpha: 0.15)
                  : Colors.grey.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? color : Colors.grey.withValues(alpha: 0.3),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(icon, style: const TextStyle(fontSize: 20)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: isSelected ? color : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check_circle, color: color, size: 24),
          ],
        ),
      ),
    );
  }

  (String, String, String, Color) _routeInfo(CuratedRoute route) {
    return switch (route) {
      CuratedRoute.purpleLine => (
        '🚇',
        'Purple Line Metro',
        'Majestic → Nallur Halli (18 stations, ~22 km)',
        Colors.purple,
      ),
      CuratedRoute.greenLine => (
        '🟢',
        'Green Line Metro',
        'Rajajinagar → Nallur Halli (23 stations, ~30 km)',
        Colors.green,
      ),
      CuratedRoute.nonMetro => (
        '🚗',
        'Auto/Cab Route',
        'Koramangala → Indiranagar (no fixed stations)',
        Colors.orange,
      ),
      CuratedRoute.logReplay => (
        '📼',
        'Log Replay (Real Data)',
        'Nallur Halli → Vijayanagar (Ground Truth vs Log)',
        Colors.blue,
      ),
    };
  }

  Widget _buildStartStopButton() {
    return SizedBox(
      height: 48,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: _isPlaying ? Colors.red : Colors.green,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: _isPlaying ? _stopTest : _startTest,
        icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow, size: 28),
        label: Text(
          _isPlaying ? 'STOP TEST' : 'START TEST',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildGpsToggle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color:
            _gpsEnabled
                ? Colors.green.withValues(alpha: 0.1)
                : Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _gpsEnabled ? Colors.green : Colors.orange,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _gpsEnabled ? Icons.gps_fixed : Icons.gps_off,
            color: _gpsEnabled ? Colors.green : Colors.orange,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _gpsEnabled ? 'GPS Active' : 'GPS Disabled',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: _gpsEnabled ? Colors.green[700] : Colors.orange[700],
                  ),
                ),
                Text(
                  _gpsEnabled
                      ? 'Toggle off to test EKF without GPS'
                      : 'EKF is estimating position from IMU only',
                  style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          Switch(
            value: _gpsEnabled,
            activeColor: Colors.green,
            onChanged:
                _isPlaying
                    ? (value) {
                      setState(() {
                        _gpsEnabled = value;
                      });
                      _controller.toggleGpsDropout();
                    }
                    : null,
          ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    final viz = _lastViz;
    final progress = _controller.progress;
    final elapsed = _controller.elapsedSeconds;
    final route = _controller.route;
    final totalDuration = route?.totalDurationSeconds ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _formatTime(elapsed),
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
            Text(
              '${(progress * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            Text(
              _formatTime(totalDuration),
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.grey[300],
          valueColor: AlwaysStoppedAnimation<Color>(
            viz?.gpsAvailable == false ? Colors.orange : Colors.green,
          ),
          minHeight: 8,
          borderRadius: BorderRadius.circular(4),
        ),
        if (viz?.gpsAvailable == false)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Icon(Icons.gps_off, size: 14, color: Colors.orange[700]),
                const SizedBox(width: 4),
                Text(
                  'GPS Dropout Active',
                  style: TextStyle(fontSize: 10, color: Colors.orange[700]),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildMetricsPanel() {
    final viz = _lastViz;
    final stats = _controller.statistics;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Live Metrics',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              Row(
                children: [
                  _buildStatBadge(
                    'ZUPT',
                    stats['zuptEvents']?.toString() ?? '0',
                    Colors.purple,
                  ),
                  const SizedBox(width: 8),
                  _buildStatBadge(
                    'SNAPS',
                    stats['stationSnaps']?.toString() ?? '0',
                    Colors.orange,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (viz != null) ...[
            Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    'EKF Speed',
                    (viz.speedMps * 3.6).toStringAsFixed(1),
                    'km/h',
                    Icons.speed,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetricTile(
                    'EKF Dist',
                    ((viz.ekfProgressMeters ?? 0) / 1000).toStringAsFixed(2),
                    'km',
                    Icons.straighten,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    'σ_pos',
                    viz.ekfSigmaS?.toStringAsFixed(0) ?? '-',
                    'm',
                    Icons.radar,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetricTile(
                    'σ_vel',
                    viz.ekfSigmaV?.toStringAsFixed(2) ?? '-',
                    'm/s',
                    Icons.show_chart,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildMetricTile(
                    'GPS',
                    viz.gpsAvailable ? 'Active' : 'Dropout',
                    '',
                    viz.gpsAvailable ? Icons.gps_fixed : Icons.gps_off,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetricTile(
                    'EKF Mode',
                    viz.ekfDegraded ? 'DEGRADED' : 'Normal',
                    '',
                    viz.ekfDegraded ? Icons.warning : Icons.check_circle,
                  ),
                ),
              ],
            ),
            if (viz.currentStation != null || viz.nextStation != null) ...[
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 4),
              if (viz.currentStation != null)
                _buildStationRow(
                  'Last Station',
                  viz.currentStation!.name,
                  viz.isAtStation,
                ),
              if (viz.nextStation != null && viz.metersToNext != null)
                _buildStationRow(
                  'Next Station',
                  '${viz.nextStation!.name} (${viz.metersToNext!.toStringAsFixed(0)}m)',
                  false,
                ),
            ],
          ] else
            const Center(
              child: Text(
                'Start test to see live metrics',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildMetricTile(
    String label,
    String value,
    String unit,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 9, color: Colors.grey[600]),
                ),
                Row(
                  children: [
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (unit.isNotEmpty)
                      Text(
                        ' $unit',
                        style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStationRow(String label, String value, bool highlight) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            highlight ? Icons.location_on : Icons.location_on_outlined,
            size: 14,
            color: highlight ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11,
                fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                color: highlight ? Colors.green : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (highlight)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'AT STATION',
                style: TextStyle(
                  fontSize: 8,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Event Log',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            Row(
              children: [
                if (_controller.logs.isNotEmpty)
                  PopupMenuButton<String>(
                    tooltip: 'Export logs',
                    icon: const Icon(Icons.download, size: 18),
                    onSelected: _exportEkfLogs,
                    itemBuilder:
                        (context) => const [
                          PopupMenuItem(
                            value: 'json',
                            child: Text('Export JSON'),
                          ),
                          PopupMenuItem(
                            value: 'csv',
                            child: Text('Export CSV'),
                          ),
                        ],
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'Clear logs',
                  onPressed: () {
                    _controller.clearLogs();
                    setState(() => _displayLogs.clear());
                  },
                ),
              ],
            ),
          ],
        ),
        Container(
          height: 120,
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(6),
          ),
          child:
              _displayLogs.isEmpty
                  ? const Center(
                    child: Text(
                      'Events will appear here...',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  )
                  : ListView.builder(
                    controller: _logScrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _displayLogs.length,
                    itemBuilder: (ctx, i) {
                      final entry = _displayLogs[i];
                      return Text(
                        entry.toColoredString(),
                        style: TextStyle(
                          fontSize: 9,
                          fontFamily: 'monospace',
                          color: _logColor(entry.category),
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }

  Color _logColor(EkfTestLogCategory category) {
    return switch (category) {
      EkfTestLogCategory.gps => Colors.cyan,
      EkfTestLogCategory.imu => Colors.grey,
      EkfTestLogCategory.zupt => Colors.purple[300]!,
      EkfTestLogCategory.snap => Colors.orange,
      EkfTestLogCategory.station => Colors.green[300]!,
      EkfTestLogCategory.ekf => Colors.yellow,
      EkfTestLogCategory.control => Colors.white,
      EkfTestLogCategory.alarm => Colors.red,
    };
  }

  String _formatTime(double seconds) {
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor();
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
}
