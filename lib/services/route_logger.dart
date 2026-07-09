/// Route Logger Service
/// Captures and saves raw Google Directions API responses for route reconstruction.
///
/// Usage:
/// - Call [logRoute] whenever a directions response is received
/// - Files are saved to the app's documents directory under 'route_logs/'
/// - Each log contains the complete API response + metadata for full reconstruction
library;

import 'dart:convert';
import 'dart:io';
import 'dart:developer' as dev;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:path_provider/path_provider.dart';

class RouteLogger {
  static RouteLogger? _instance;
  static RouteLogger get instance => _instance ??= RouteLogger._();

  RouteLogger._();

  /// Whether route logging is enabled.
  /// Enabled by default to capture all routes for reconstruction.
  bool enabled = true;

  /// Log directory path (lazily initialized)
  String? _logDir;

  /// Initialize the log directory
  Future<String> _ensureLogDir() async {
    if (_logDir != null) return _logDir!;

    final docDir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${docDir.path}/route_logs');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    _logDir = logDir.path;
    dev.log('Route log directory: $_logDir', name: 'RouteLogger');
    return _logDir!;
  }

  /// Format DateTime as yyyy-MM-dd_HH-mm-ss
  String _formatTimestamp(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}_'
        '${dt.hour.toString().padLeft(2, '0')}-'
        '${dt.minute.toString().padLeft(2, '0')}-'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  /// Log a complete route with all details for reconstruction.
  ///
  /// [directions] - The raw Google Directions API response
  /// [origin] - Origin coordinates
  /// [destination] - Destination coordinates
  /// [destinationName] - Human-readable destination name
  /// [transitMode] - Whether transit mode was requested
  /// [metadata] - Optional additional metadata
  Future<String?> logRoute({
    required Map<String, dynamic> directions,
    required LatLng origin,
    required LatLng destination,
    String? destinationName,
    bool transitMode = false,
    Map<String, dynamic>? metadata,
  }) async {
    if (!enabled) return null;

    try {
      final dir = await _ensureLogDir();
      final timestamp = _formatTimestamp(DateTime.now());
      final sanitizedName =
          (destinationName ?? 'route')
              .replaceAll(RegExp(r'[^\w\s-]'), '')
              .replaceAll(RegExp(r'\s+'), '_')
              .toLowerCase();

      final filename = '${sanitizedName}_$timestamp.json';
      final filepath = '$dir/$filename';

      // Build the complete log entry
      final logEntry = {
        'version': 1,
        'timestamp': DateTime.now().toIso8601String(),
        'metadata': {
          'origin': {'lat': origin.latitude, 'lng': origin.longitude},
          'destination': {
            'lat': destination.latitude,
            'lng': destination.longitude,
          },
          'destination_name': destinationName,
          'transit_mode': transitMode,
          ...?metadata,
        },
        'directions': directions,
        // Extract key route info for quick reference
        'summary': _extractSummary(directions),
      };

      // Write to file with pretty formatting
      final file = File(filepath);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(logEntry),
      );

      dev.log('Route logged: $filepath', name: 'RouteLogger');
      return filepath;
    } catch (e, st) {
      dev.log('Failed to log route: $e\n$st', name: 'RouteLogger', error: e);
      return null;
    }
  }

  /// Extract a quick summary from the directions response
  Map<String, dynamic> _extractSummary(Map<String, dynamic> directions) {
    try {
      final routes = directions['routes'] as List?;
      if (routes == null || routes.isEmpty) {
        return {'error': 'No routes found'};
      }

      final route = routes[0] as Map<String, dynamic>;
      final legs = route['legs'] as List?;
      if (legs == null || legs.isEmpty) {
        return {'error': 'No legs found'};
      }

      final leg = legs[0] as Map<String, dynamic>;

      // Extract overview polyline
      String? overviewPolyline;
      if (route['overview_polyline'] != null) {
        overviewPolyline = route['overview_polyline']['points'] as String?;
      }

      // Count transit legs
      int transitSteps = 0;
      int walkingSteps = 0;
      List<Map<String, dynamic>> transitDetails = [];

      final steps = leg['steps'] as List? ?? [];
      for (final step in steps) {
        final travelMode = (step['travel_mode'] as String?)?.toUpperCase();
        if (travelMode == 'TRANSIT') {
          transitSteps++;
          // Extract transit details
          final td = step['transit_details'] as Map<String, dynamic>?;
          if (td != null) {
            transitDetails.add({
              'line_name': td['line']?['short_name'] ?? td['line']?['name'],
              'vehicle_type': td['line']?['vehicle']?['type'],
              'departure_stop': td['departure_stop']?['name'],
              'arrival_stop': td['arrival_stop']?['name'],
              'num_stops': td['num_stops'],
            });
          }
        } else if (travelMode == 'WALKING') {
          walkingSteps++;
        }
      }

      return {
        'total_distance_meters': leg['distance']?['value'],
        'total_duration_seconds': leg['duration']?['value'],
        'start_address': leg['start_address'],
        'end_address': leg['end_address'],
        'overview_polyline_length': overviewPolyline?.length,
        'transit_steps': transitSteps,
        'walking_steps': walkingSteps,
        'transit_details': transitDetails,
      };
    } catch (e) {
      return {'error': 'Failed to extract summary: $e'};
    }
  }

  /// List all logged routes
  Future<List<FileSystemEntity>> listLogs() async {
    final dir = await _ensureLogDir();
    final logDir = Directory(dir);
    return logDir.listSync().where((e) => e.path.endsWith('.json')).toList();
  }

  /// Read a specific log file
  Future<Map<String, dynamic>?> readLog(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      dev.log('Failed to read log: $e', name: 'RouteLogger');
      return null;
    }
  }

  /// Export a logged route to a format suitable for bengaluru_metro_routes.json
  Future<Map<String, dynamic>?> exportForTestRoutes(String logPath) async {
    final log = await readLog(logPath);
    if (log == null) return null;

    try {
      final directions = log['directions'] as Map<String, dynamic>;
      final metadata = log['metadata'] as Map<String, dynamic>;
      final routes = directions['routes'] as List;
      if (routes.isEmpty) return null;

      final route = routes[0] as Map<String, dynamic>;
      final legs = route['legs'] as List;
      if (legs.isEmpty) return null;

      final leg = legs[0] as Map<String, dynamic>;
      final steps = leg['steps'] as List;

      // Extract stations from transit steps
      List<Map<String, dynamic>> stations = [];
      List<List<double>> polylinePoints = [];
      List<double> cumulativeMeters = [];
      double totalMeters = 0;

      for (final step in steps) {
        final travelMode = (step['travel_mode'] as String?)?.toUpperCase();
        if (travelMode != 'TRANSIT') continue;

        final td = step['transit_details'] as Map<String, dynamic>?;
        if (td == null) continue;

        final departureStop = td['departure_stop'] as Map<String, dynamic>?;
        final arrivalStop = td['arrival_stop'] as Map<String, dynamic>?;

        if (departureStop != null && stations.isEmpty) {
          final loc = departureStop['location'] as Map<String, dynamic>;
          stations.add({
            'name': departureStop['name'],
            'lat': loc['lat'],
            'lng': loc['lng'],
            'cumulative_meters': 0.0,
          });
          polylinePoints.add([loc['lat'] as double, loc['lng'] as double]);
          cumulativeMeters.add(0.0);
        }

        if (arrivalStop != null) {
          final loc = arrivalStop['location'] as Map<String, dynamic>;
          totalMeters += (step['distance']?['value'] as num?)?.toDouble() ?? 0;
          stations.add({
            'name': arrivalStop['name'],
            'lat': loc['lat'],
            'lng': loc['lng'],
            'cumulative_meters': totalMeters,
          });
          polylinePoints.add([loc['lat'] as double, loc['lng'] as double]);
          cumulativeMeters.add(totalMeters);
        }
      }

      final destName = metadata['destination_name'] as String? ?? 'unknown';
      return {
        'id': destName.toLowerCase().replaceAll(RegExp(r'\s+'), '_'),
        'name': destName,
        'stations': stations,
        'polyline_points': polylinePoints,
        'cumulative_meters': cumulativeMeters,
        'total_meters': totalMeters,
        'raw_overview_polyline': route['overview_polyline']?['points'],
      };
    } catch (e) {
      dev.log('Failed to export: $e', name: 'RouteLogger');
      return null;
    }
  }
}
