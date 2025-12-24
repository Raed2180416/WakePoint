import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'polyline_decoder.dart';
import 'polyline_simplifier.dart';
import 'package:geowake2/services/api_client.dart'; // ADD THIS IMPORT
import 'package:geowake2/services/route_cache.dart';
import 'dart:convert' show utf8;
import 'package:crypto/crypto.dart' as crypto;
import 'dart:developer' as dev;

class DirectionService {
  final ApiClient _apiClient = ApiClient.instance;
  Map<String, dynamic>? _cachedDirections;
  DateTime? _lastFetchTime;
  String? _cachedDirectionsKey;
  // In-memory cache for decode+simplify keyed by hash 'len:md5' of polyline+tol
  final Map<String, List<LatLng>> _polylineSimplifyCache = {};

  // Tiered intervals for updating directions.
  final Duration farInterval = const Duration(minutes: 15);
  final Duration midInterval = const Duration(minutes: 7);
  final Duration nearInterval = const Duration(minutes: 3);

  DirectionService();

  String _makeRequestKey({
    required LatLng origin,
    required LatLng destination,
    required String mode,
    String? transitVariant,
  }) {
    return RouteCache.makeKey(
      origin: origin,
      destination: destination,
      mode: mode,
      transitVariant: transitVariant,
    );
  }

  /// Fetches directions using a tiered strategy through your secure API.
  Future<Map<String, dynamic>> getDirections(
    double startLat,
    double startLng,
    double endLat,
    double endLng, {
    required bool isDistanceMode,
    required double threshold,
    required bool transitMode,
    bool forceRefresh = false,
  }) async {
    // L2 persistent cache check (Hive)
    final origin = LatLng(startLat, startLng);
    final dest = LatLng(endLat, endLng);
    final mode = transitMode ? 'transit' : 'driving';
    if (!forceRefresh) {
      final cached = await RouteCache.get(
        origin: origin,
        destination: dest,
        mode: mode,
        transitVariant: transitMode ? 'rail' : null,
      );
      if (cached != null) {
        dev.log('Using RouteCache entry for $mode', name: 'DirectionService');
        _cachedDirections = cached.directions;
        _lastFetchTime = cached.timestamp;
      }
    }
    // Calculate the straight-line distance in meters.
    double straightDistance = Geolocator.distanceBetween(
      startLat,
      startLng,
      endLat,
      endLng,
    );

    // Determine the update interval.
    Duration updateInterval;
    if (isDistanceMode) {
      double thresholdMeters = threshold * 1000;
      if (straightDistance > 5 * thresholdMeters) {
        updateInterval = farInterval;
      } else if (straightDistance > 2 * thresholdMeters) {
        updateInterval = midInterval;
      } else {
        updateInterval = nearInterval;
      }
    } else {
      updateInterval = nearInterval;
    }

    // Return in-memory cached data if available, recent, AND for the same request.
    final requestKey = _makeRequestKey(
      origin: origin,
      destination: dest,
      mode: mode,
      transitVariant: transitMode ? 'rail' : null,
    );
    if (!forceRefresh &&
        _cachedDirections != null &&
        _lastFetchTime != null &&
        _cachedDirectionsKey == requestKey) {
      final elapsed = DateTime.now().difference(_lastFetchTime!);
      if (elapsed < updateInterval) {
        return _cachedDirections!;
      }
    }

    try {
      // REPLACE THE DIRECT HTTP CALL WITH API CLIENT
      final directions = await _apiClient.getDirections(
        origin: '$startLat,$startLng',
        destination: '$endLat,$endLng',
        mode: transitMode ? 'transit' : 'driving',
        transitMode: transitMode ? 'rail' : null,
      );

      if (directions['status'] != 'OK' ||
          (directions['routes'] as List).isEmpty) {
        throw Exception(
          "No feasible route found: ${directions['error_message'] ?? directions['status']}",
        );
      }

      // --- Simplify & compress the overview polyline ---
      String? simplifiedCompressed;
      if (directions['routes'] != null && directions['routes'].isNotEmpty) {
        final route = directions['routes'][0];
        if (route['overview_polyline'] != null &&
            route['overview_polyline']['points'] != null) {
          final String encodedPolyline =
              route['overview_polyline']['points'] as String;
          // Decode + simplify with small in-memory cache
          final simplifiedPoints = _decodeAndSimplifyCached(
            encodedPolyline,
            10,
          );
          // Compress the simplified polyline.
          String compressedPolyline = PolylineSimplifier.compressPolyline(
            simplifiedPoints,
          );
          // Add the simplified compressed polyline to the response.
          route['simplified_polyline'] = compressedPolyline;
          simplifiedCompressed = compressedPolyline;
        }
      }

      _cachedDirections = directions;
      _lastFetchTime = DateTime.now();
      _cachedDirectionsKey = requestKey;

      // Persist to RouteCache (L2)
      try {
        final key = RouteCache.makeKey(
          origin: origin,
          destination: dest,
          mode: mode,
          transitVariant: transitMode ? 'rail' : null,
        );
        await RouteCache.put(
          RouteCacheEntry(
            key: key,
            directions: directions,
            timestamp: _lastFetchTime!,
            origin: origin,
            destination: dest,
            mode: mode,
            simplifiedCompressedPolyline: simplifiedCompressed,
          ),
        );
      } catch (e) {
        dev.log('Failed to persist route cache: $e', name: 'DirectionService');
      }
      return directions;
    } catch (e) {
      dev.log(
        "Error fetching directions via API client: $e",
        name: "DirectionService",
      );
      // Retry logic
      if (!forceRefresh) {
        dev.log("Retrying directions fetch...", name: "DirectionService");
        return getDirections(
          startLat,
          startLng,
          endLat,
          endLng,
          isDistanceMode: isDistanceMode,
          threshold: threshold,
          transitMode: transitMode,
          forceRefresh: true,
        );
      }
      throw Exception("Failed to fetch directions: $e");
    }
  }

  List<Map<String, dynamic>> buildRawSegments(
    Map<String, dynamic> directions,
    bool transitMode,
  ) {
    List<Map<String, dynamic>> segments = [];
    if (directions['routes'] == null || directions['routes'].isEmpty) {
      return segments;
    }

    for (var leg in directions['routes'][0]['legs']) {
      List<dynamic> steps = leg['steps'];
      if (steps.isEmpty) continue;

      List<LatLng> groupPoints = [];
      String currentGroupType;
      // non_transit subtype to distinguish DRIVING vs WALKING for styling
      String?
      currentNonTransitMode; // 'DRIVING' | 'WALKING' | null when transit
      String? currentTransitLine;
      String? currentVehicleType;

      // Helper to process a step's mode info
      ModeInfo getModeInfo(dynamic s) {
        String mode = s['travel_mode'];
        bool isMetro = false;
        String? tLine;
        String? vType;
        if (mode == 'TRANSIT' && transitMode) {
          if (s.containsKey('transit_details') &&
              s['transit_details'] != null) {
            var td = s['transit_details'];
            var vehicle = td['line']['vehicle'];
            vType = vehicle['type'];
            isMetro =
                vType == 'SUBWAY' || vType == 'HEAVY_RAIL' || vType == 'RAIL';
            if (isMetro) {
              tLine = td['line']['short_name'] ?? td['line']['name'];
            }
          }
        }
        return ModeInfo(mode, isMetro, tLine, vType);
      }

      // Initialize first step
      var firstStep = steps[0];
      var firstInfo = getModeInfo(firstStep);

      if (firstInfo.isMetro) {
        currentGroupType = "transit";
        currentTransitLine = firstInfo.line;
      } else {
        currentGroupType = "non_transit";
        currentTransitLine = null;
      }
      currentNonTransitMode = firstInfo.isMetro ? null : firstInfo.mode;
      currentVehicleType = firstInfo.vehicleType;

      // Decode, simplify, then add first step points.
      List<LatLng> simplifiedPoints = _decodeAndSimplifyCached(
        firstStep['polyline']['points'],
        10,
      );
      groupPoints.addAll(simplifiedPoints);

      for (int i = 1; i < steps.length; i++) {
        var step = steps[i];
        var info = getModeInfo(step);

        String stepGroupType = info.isMetro ? "transit" : "non_transit";
        String? stepNonTransitMode = info.isMetro ? null : info.mode;

        bool sameGroup = false;
        if (currentGroupType == "non_transit" &&
            stepGroupType == "non_transit") {
          // keep grouping only if same non-transit mode
          sameGroup = (currentNonTransitMode == stepNonTransitMode);
        } else if (currentGroupType == "transit" &&
            stepGroupType == "transit") {
          sameGroup = (currentTransitLine == info.line);
        }

        if (sameGroup) {
          List<LatLng> simplifiedStepPoints = _decodeAndSimplifyCached(
            step['polyline']['points'],
            10,
          );
          groupPoints.addAll(simplifiedStepPoints);
        } else {
          // Finalize current segment
          segments.add({
            'mode':
                currentGroupType == 'transit'
                    ? 'transit'
                    : currentNonTransitMode?.toLowerCase() ?? 'driving',
            'points':
                groupPoints
                    .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                    .toList(),
            'transit_line': currentTransitLine,
            'vehicle_type': currentVehicleType,
          });

          // Start new segment
          groupPoints = [];
          currentGroupType = stepGroupType;
          currentTransitLine = info.line;
          currentNonTransitMode = stepNonTransitMode;
          currentVehicleType = info.vehicleType;

          List<LatLng> rawStepPoints = decodePolyline(
            step['polyline']['points'],
          );
          List<LatLng> simplifiedStepPoints =
              PolylineSimplifier.simplifyPolyline(rawStepPoints, 10);
          groupPoints.addAll(simplifiedStepPoints);
        }
      }

      if (groupPoints.isNotEmpty) {
        segments.add({
          'mode':
              currentGroupType == 'transit'
                  ? 'transit'
                  : currentNonTransitMode?.toLowerCase() ?? 'driving',
          'points':
              groupPoints
                  .map((p) => {'lat': p.latitude, 'lng': p.longitude})
                  .toList(),
          'transit_line': currentTransitLine,
          'vehicle_type': currentVehicleType,
        });
      }
    }
    return segments;
  }

  List<Polyline> buildSegmentedPolylines(
    Map<String, dynamic> directions,
    bool transitMode,
  ) {
    final rawSegments = buildRawSegments(directions, transitMode);
    List<Polyline> polylines = [];

    Map<String, Color> transitColorMap = {};
    final List<Color> transitColors = [Colors.green, Colors.purple];
    int transitColorIndex = 0;

    for (int i = 0; i < rawSegments.length; i++) {
      final seg = rawSegments[i];
      final mode = seg['mode'] as String;
      final pointsData = seg['points'] as List;
      final points = pointsData.map((p) => LatLng(p['lat'], p['lng'])).toList();
      final transitLine = seg['transit_line'] as String?;

      Color color;
      List<PatternItem> patterns = [];
      int zIndex = 2;

      if (mode == 'transit') {
        zIndex = 3;
        if (transitLine != null) {
          if (!transitColorMap.containsKey(transitLine)) {
            transitColorMap[transitLine] =
                transitColors[transitColorIndex % transitColors.length];
            transitColorIndex++;
          }
          color = transitColorMap[transitLine]!;
        } else {
          // Fallback if no line name but is transit (shouldn't happen for metro per logic, but safe fallback)
          color = Colors.blue;
        }
      } else {
        color = Colors.blue;
        if (mode == 'walking') {
          patterns = [PatternItem.dash(20), PatternItem.gap(12)];
        }
      }

      polylines.add(
        Polyline(
          polylineId: PolylineId('seg_$i'),
          points: points,
          color: color,
          width: 5,
          patterns: patterns,
          zIndex: zIndex,
        ),
      );
    }

    return polylines;
  }

  // Decode an encoded polyline and simplify it with caching keyed by md5 of input+tol
  List<LatLng> _decodeAndSimplifyCached(
    String encoded,
    double toleranceMeters,
  ) {
    final key = _polyKey(encoded, toleranceMeters);
    final cached = _polylineSimplifyCache[key];
    if (cached != null) return cached;
    final decoded = decodePolyline(encoded);
    final simplified = PolylineSimplifier.simplifyPolyline(
      decoded,
      toleranceMeters,
    );
    _polylineSimplifyCache[key] = simplified;
    return simplified;
  }

  String _polyKey(String encoded, double tol) {
    final bytes = utf8.encode('$tol|' + encoded);
    final digest = crypto.md5.convert(bytes).toString();
    return '${encoded.length}:$digest';
  }
}

class ModeInfo {
  final String mode;
  final bool isMetro;
  final String? line;
  final String? vehicleType;

  ModeInfo(this.mode, this.isMetro, this.line, this.vehicleType);
}
